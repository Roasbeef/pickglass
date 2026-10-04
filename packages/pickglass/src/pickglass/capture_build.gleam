//// Assembling a capture from what the viewer holds: observations, the
//// operator's checkpoints, and the audit trail.
////
//// A capture's header says what was measured, on what, and how
//// (`provenance`), and two captures are comparable only if those fields
//// agree. The viewer fills the header from what it actually knows: the node
//// name (kept only as a digest, so a capture does not carry it), the agent's
//// boot id, the OS process id, and the runtime fields of the first memory
//// report. A field the agent does not report yet, such as the emulator
//// flavor or the host build, is written as the word `unknown` and never
//// guessed. The OS process start identity comes from the OS reader and is
//// `UnreadableStart` when it could not be read.
////
//// The agent has no clock request, so the `clock` record comes from timing
//// a ping (`clock`), and is written only when a ping was timed. A
//// checkpoint's `agent_monotonic_ns` is placed on the agent's clock from
//// that record by the service, and is zero when there is none.
////
//// ## Flow
////
//// - `assemble` builds the header and every record between header and
////   footer, in the order the format expects.
//// - `runtime_of` reads the runtime facts back out of a header, which a
////   replay needs to rebuild memory snapshots.
//// - `sha256_hex` is how a node's identity is recorded in place of its name.
//// - The caller then renders and stores the result with the capture file
////   module.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass/audit
import pickglass/observation.{type Observation}
import pickglass/observation_codec
import pickglass/probe_book.{type ProbeRecord}
import pickglass_core/capture.{type Header, type Record}
import pickglass_core/identity.{type BootId}
import pickglass_core/measure.{type Cadence}
import pickglass_core/policy.{type AuditEntry}
import pickglass_core/profile.{type Profile}
import pickglass_core/provenance
import pickglass_core/readings
import pickglass_core/wire

/// What the viewer knows about the target outside the observations.
pub type Facts {
  Facts(
    /// The viewer's version, for the producer block.
    pickglass_version: String,
    /// The node's name. Only its digest is written.
    node: String,
    /// The OS process id of the target's emulator, from discovery.
    os_pid: Int,
    boot: BootId,
    /// What the host calls the node's role, such as `loomd`.
    role: String,
    /// The operator's label for the workload.
    workload: String,
    /// The census budget that produced the observations.
    top_k: Int,
    deadline_ms: Int,
    /// How the target's OS process is told from another that reused its
    /// pid, from the OS reader.
    os_start: identity.StartIdentity,
    /// The agent's clock against the viewer's, when a ping was timed.
    clock: Option(capture.Clock),
  )
}

/// The redaction policy of captures this module writes: none is applied,
/// because the agent never reads message contents, dictionaries or state.
pub const redaction = "none; the agent reads no message contents"

/// Build the header and the records of a capture. `observations` is oldest
/// first, and `entries` newest first as `audit.tail` returns them. `binaries`
/// are the binaries reads the operator made, oldest first. `Error`
/// when no observation has a memory report, because the
/// header's runtime block comes from one.
///
/// ## Examples
///
/// ```gleam
/// capture_build.assemble(facts, "id", observations, OneShot, [], [], [], [])
/// ```
pub fn assemble(
  facts: Facts,
  capture_id: String,
  observations: List(Observation),
  cadence: Cadence,
  checkpoints: List(capture.Checkpoint),
  entries: List(audit.Entry),
  probes: List(ProbeRecord),
  binaries: List(readings.BinariesReading),
) -> Result(#(Header, List(Record(Profile))), String) {
  use memory <- result.try(
    list.find_map(observations, fn(observation) { observation.memory })
    |> result.replace_error(
      "no observation holds a memory report to describe the runtime",
    ),
  )

  let header =
    capture.Header(
      capture_id:,
      provenance: provenance_of(
        facts,
        memory,
        cadence,
        list.find_map(observations, fn(observation) {
          observation.system |> result.map(fn(snapshot) { snapshot.facts })
        })
          |> option.from_result,
      ),
      redaction:,
    )

  Ok(#(
    header,
    list.flatten([
      case facts.clock {
        Some(clock) -> [capture.ClockRecord(clock)]
        None -> []
      },
      observation_codec.to_records(observations, cadence, memory.word_size),
      list.map(checkpoints, capture.CheckpointRecord),
      probe_book.to_records(probes),
      list.map(binaries, capture.BinariesRecord),
      list.map(decisions(entries), capture.AuditRecord),
    ]),
  ))
}

/// The runtime facts a replay needs, read back from a header.
///
/// ## Examples
///
/// ```gleam
/// capture_build.runtime_of(header)
/// ```
pub fn runtime_of(header: Header) -> observation_codec.Runtime {
  let runtime = header.provenance.runtime

  observation_codec.Runtime(
    word_size: runtime.wordsize,
    otp_release: runtime.otp_release,
    erts_version: runtime.erts_version,
    schedulers_online: runtime.schedulers,
  )
}

fn decisions(entries: List(audit.Entry)) -> List(AuditEntry) {
  list.filter_map(entries, fn(entry) {
    case entry {
      audit.Decision(decision) -> Ok(decision)
      audit.Host(..) -> Error(Nil)
    }
  })
  |> list.reverse
}

fn provenance_of(
  facts: Facts,
  memory: wire.MemorySnapshot,
  cadence: Cadence,
  node: Option(wire.NodeFacts),
) -> provenance.Provenance {
  provenance.Provenance(
    producer: provenance.Producer(
      pickglass: facts.pickglass_version,
      agent: "wire." <> int.to_string(wire.wire_version),
      schema: capture.schema,
    ),
    target: provenance.Target(
      incarnation: identity.NodeIncarnation(
        node_digest: sha256_hex(facts.node),
        creation: case node {
          Some(known) -> known.creation
          None -> 0
        },
        boot: facts.boot,
      ),
      os: identity.OsProcess(pid: facts.os_pid, start: facts.os_start),
      role: facts.role,
    ),
    runtime: provenance.Runtime(
      otp_release: memory.otp_release,
      erts_version: memory.erts_version,
      emulator_flavor: case node {
        Some(known) -> known.emulator_flavor
        None -> "unknown"
      },
      wordsize: memory.word_size,
      schedulers: memory.schedulers_online,
      dirty_cpu_schedulers: option.map(node, fn(known) { known.dirty_cpu }),
      flags: [],
    ),
    build: provenance.Build(
      application: provenance.unstated,
      version: "unknown",
      revision: provenance.unstated,
      compiler: "unknown",
    ),
    workload: provenance.Workload(
      label: facts.workload,
      sessions: [],
      warmup_ms: None,
      notes: "",
    ),
    collection: provenance.Collection(
      method: "pickglass.hub/1",
      cadence:,
      budgets: provenance.Budgets(
        top_k: facts.top_k,
        max_events: None,
        deadline_ms: facts.deadline_ms,
      ),
    ),
  )
}

/// The SHA-256 of a text as lowercase hex, which is how a node's identity is
/// recorded in place of its name.
///
/// ## Examples
///
/// ```gleam
/// capture_build.sha256_hex("node@127.0.0.1")
/// ```
pub fn sha256_hex(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
  |> string.lowercase
}
