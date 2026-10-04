//// Shared test data: observations, a fake agent, principals.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/set
import pickglass/hub
import pickglass/observation.{type Observation, Observation}
import pickglass/observation_codec
import pickglass/remote.{type Remote}
import pickglass_core/identity
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/wire

pub fn boot() -> identity.BootId {
  let assert Ok(boot) = identity.boot_id("pgtestboot1")

  boot
}

pub fn pin_token(serial: Int) -> identity.PinToken {
  let assert Ok(token) = identity.pin(boot(), serial)

  token
}

pub fn principal(
  name: String,
  grants: List(policy.Capability),
) -> policy.Principal {
  policy.Principal(id: policy.PrincipalId(name), grants: set.from_list(grants))
}

pub fn row(
  pid: String,
  memory: Int,
  owner: wire.OwnerReading,
) -> wire.ProcessRow {
  wire.ProcessRow(
    pid_text: pid,
    memory:,
    total_heap_words: memory / 16,
    heap_words: memory / 32,
    stack_words: 4,
    queue_length: 2,
    reductions: memory * 3,
    status: "waiting",
    current_function: "gleam@otp@actor:loop/3",
    registered_name: "",
    owner:,
  )
}

pub fn labelled(kind: String, id: String, role: String) -> wire.OwnerReading {
  let assert Ok(segment) = owner.segment(kind, id)

  wire.Labelled([segment], role)
}

pub fn census(rows: List(wire.ProcessRow)) -> wire.CensusSnapshot {
  // One total per distinct owner, largest memory first, as the agent sends.
  let owners =
    list.fold(rows, [], fn(totals: List(wire.OwnerTotal), r) {
      case list.find(totals, fn(t) { t.owner == r.owner }) {
        Ok(_) ->
          list.map(totals, fn(t) {
            case t.owner == r.owner {
              True ->
                wire.OwnerTotal(
                  ..t,
                  processes: t.processes + 1,
                  memory: t.memory + r.memory,
                  queue_length: t.queue_length + r.queue_length,
                  reductions: t.reductions + r.reductions,
                )
              False -> t
            }
          })
        Error(Nil) ->
          list.append(totals, [
            wire.OwnerTotal(
              owner: r.owner,
              processes: 1,
              memory: r.memory,
              queue_length: r.queue_length,
              reductions: r.reductions,
            ),
          ])
      }
    })
    |> list.sort(fn(a, b) { int.compare(b.memory, a.memory) })

  wire.CensusSnapshot(
    coverage: wire.CensusCoverage(
      scanned: list.length(rows),
      total: list.length(rows),
      stop: wire.WalkFinished,
      elapsed_ms: 3,
    ),
    rows:,
    owners:,
  )
}

pub fn memory(total: Int) -> wire.MemorySnapshot {
  wire.MemorySnapshot(
    categories: [
      #("total", total),
      #("processes", total / 2),
      #("system", total / 2),
    ],
    word_size: 8,
    process_count: 12,
    otp_release: "29",
    erts_version: "17.0.5",
    schedulers_online: 2,
  )
}

pub fn scheduler(active: Int, total: Int) -> wire.SchedulerSnapshot {
  wire.SchedulerSnapshot(wire.Collecting, [
    wire.SchedulerReading(1, active, total),
    wire.SchedulerReading(2, active / 2, total),
  ])
}

pub fn observation(seq: Int, at_ms: Int) -> Observation {
  Observation(
    seq:,
    at_ms:,
    elapsed_ms: 7,
    memory: Ok(memory(1_000_000 + seq * 1000)),
    census: Ok(
      census([
        row("<0.10.0>", 5000 + seq, labelled("session", "s1", "worker")),
        row("<0.11.0>", 4000, wire.Unlabelled),
      ]),
    ),
    scheduler: Ok(scheduler(seq * 100, seq * 200 + 1000)),
    os: Error(observation_codec.no_os_readings),
    totals: Error(observation.totals_not_recorded),
    system: Error(observation.system_skipped),
  )
}

/// A fake agent. Every request is sent to `seen`; the reply comes from
/// `script`. The boot id is the fixture boot.
pub fn fake_remote(
  seen: Subject(wire.Request),
  script: fn(wire.Request) -> Result(wire.Reply, remote.Failure),
) -> Remote {
  remote.Remote(
    node: "fake@127.0.0.1",
    boot: boot(),
    ask: fn(request, _timeout) {
      process.send(seen, request)

      script(request)
    },
    detach: fn() { Nil },
  )
}

/// The agent's answers for a healthy node.
pub fn healthy(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskMemory -> Ok(wire.MemoryReport(memory(2_000_000)))
    wire.Extended(wire.AskOwners(..)) ->
      Ok(
        wire.OwnersReport(wire.OwnersSnapshot(
          coverage: census_coverage(1),
          rows: [row("<0.10.0>", 5000, wire.Unlabelled)],
          owners: [],
          totals: wire.CensusTotals(1, 5000, 0, 0, 100, 1, 1),
        )),
      )
    wire.Extended(_) ->
      Error(remote.Refusal("unexpected", "the fake agent has no such request"))
    wire.AskCensus(..) ->
      Ok(wire.CensusReport(census([row("<0.10.0>", 5000, wire.Unlabelled)])))
    wire.AskScheduler(wire.SchedulerRead) ->
      Ok(wire.SchedulerReport(scheduler(10, 20)))
    wire.AskScheduler(_) ->
      Ok(wire.SchedulerReport(wire.SchedulerSnapshot(wire.Collecting, [])))
    wire.AskPing ->
      Error(remote.Refusal("unexpected", "the fake agent has no ping"))
    wire.AskPin(text) -> Ok(wire.Pinned(pin_token(1), text))
    wire.AskUnpin(_) -> Ok(wire.Unpinned(1))
    wire.AskStartCounters(..) -> Ok(wire.CountersStarted(7, 3, 30_000))
    wire.AskReadCounters(_) | wire.AskStopCounters(_) ->
      Error(remote.Refusal("no_such_probe", "no such probe"))
    wire.AskDetach -> Ok(wire.Detached("requested"))
  }
}

/// The healthy agent, except that a probe it started never ends: reading it
/// finds it still running.
pub fn healthy_with_open_probe(
  request: wire.Request,
) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskReadCounters(7) ->
      Ok(
        wire.CountersReport(
          wire.CountersSnapshot(
            probe_id: 7,
            state: wire.ProbeRunning,
            matched_functions: 3,
            elapsed_ms: 100,
            functions: 3,
            with_calls: 0,
            invalidated: 0,
            rows: [],
          ),
        ),
      )
    other -> healthy(other)
  }
}

/// A subject to subscribe to the hub with.
pub fn updates() -> Subject(hub.Update) {
  process.new_subject()
}

/// Collect every message currently in `subject`, waiting `wait_ms` for
/// each, oldest first.
pub fn drain(subject: Subject(a), wait_ms: Int) -> List(a) {
  case process.receive(subject, wait_ms) {
    Ok(item) -> [item, ..drain(subject, wait_ms)]
    Error(Nil) -> []
  }
}

/// The integers from one to `n`.
pub fn numbers(n: Int) -> List(Int) {
  list.repeat(Nil, n) |> list.index_map(fn(_, index) { index + 1 })
}

fn census_coverage(count: Int) -> wire.CensusCoverage {
  wire.CensusCoverage(
    scanned: count,
    total: count,
    stop: wire.WalkFinished,
    elapsed_ms: 3,
  )
}
