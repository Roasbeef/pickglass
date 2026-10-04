//// One observation of the target: what the hub's poller gathered in one
//// pass, with what it could not gather said in words.
////
//// A pass asks the agent for three things: the memory categories, one
//// bounded census, and the scheduler wall-time readings. Each answer is a
//// `Result`, so a reading that failed is an explicit `Error` carrying the
//// reason and never a zero or an empty table. The pages draw an `Error`
//// section as the reason, the capture writer records it as a coverage
//// record whose outcome is `Errored`, and the replay reads it back the same
//// way.
////
//// `collect` is the whole pass. It runs in a short-lived worker the hub
//// starts under a deadline, so a slow agent costs a skipped tick and never
//// blocks the hub.

import gleam/list
import gleam/result
import pickglass/os_reader
import pickglass/remote.{type Remote}
import pickglass_core/wire

/// How long each ask in a pass waits, in milliseconds.
pub const ask_deadline_ms = 15_000

/// What one pass gathered.
pub type Observation {
  Observation(
    /// The pass's number, from zero, in the order the hub ran them.
    seq: Int,
    /// When the pass began, in wall-clock milliseconds.
    at_ms: Int,
    /// How long the whole pass took.
    elapsed_ms: Int,
    memory: Result(wire.MemorySnapshot, String),
    census: Result(wire.CensusSnapshot, String),
    scheduler: Result(wire.SchedulerSnapshot, String),
    /// The OS's account of the target's process and the processes it
    /// started. Not part of `answered`: the agent has nothing to do with it.
    os: Result(List(os_reader.Reading), String),
    /// Totals over every process the census scanned, listed or not. Not
    /// part of a capture.
    totals: Result(wire.CensusTotals, String),
    /// The heap capacity of each owner the agent listed, over every process
    /// the walk scanned and not only the processes listed as rows. An owner
    /// change between two passes is computed from these when the walks
    /// finished. Not part of a capture.
    owner_heaps: Result(List(wire.OwnerHeapTotal), String),
    /// Node facts and allocator carriers. Read on the first pass and every
    /// `system_every` passes after, since the carrier walk is the most
    /// expensive thing the agent does for the viewer; `Error` on the others.
    /// Not part of a capture: its facts go into the capture's header.
    system: Result(wire.SystemSnapshot, String),
  )
}

/// How many passes apart the node facts are read.
pub const system_every = 15

/// The reason a pass that did not read the node facts gives.
pub const system_skipped = "not read in this pass"

/// The reason an observation read back from a capture gives for its census
/// totals.
pub const totals_not_recorded = "a capture does not record the census totals"

/// Whether the pass asks the agent to turn scheduler wall time on first.
/// The agent holds the flag until it detaches, so the first pass turns it on
/// and later ones only read.
pub type SchedulerStep {
  TurnOnAndRead
  ReadOnly
}

/// The census budget of a pass.
pub type Budget {
  Budget(max_scanned: Int, top_k: Int)
}

/// Whether any of the three readings succeeded. A pass where none did is a
/// failure of the link and not of one request.
///
/// ## Examples
///
/// ```gleam
/// observation.answered(observation)
/// // -> True
/// ```
pub fn answered(observation: Observation) -> Bool {
  result.is_ok(observation.memory)
  || result.is_ok(observation.census)
  || result.is_ok(observation.scheduler)
}

/// Run one pass against the remote. `clock` returns wall-clock
/// milliseconds, and `os` reads the OS's account of the target.
///
/// ## Examples
///
/// ```gleam
/// observation.collect(remote, Budget(200_000, 200), 0, ReadOnly, clock, os)
/// ```
pub fn collect(
  remote: Remote,
  budget: Budget,
  seq: Int,
  step: SchedulerStep,
  clock: fn() -> Int,
  os: fn() -> Result(List(os_reader.Reading), String),
) -> Observation {
  let started = clock()
  let memory = case remote.ask(wire.AskMemory, ask_deadline_ms) {
    Ok(wire.MemoryReport(snapshot)) -> Ok(snapshot)
    other -> Error(reason_of(other, "memory"))
  }
  let owners = case
    remote.ask(
      wire.Extended(wire.AskOwners(budget.max_scanned, budget.top_k)),
      ask_deadline_ms,
    )
  {
    Ok(wire.OwnersReport(snapshot)) -> Ok(snapshot)
    other -> Error(reason_of(other, "census"))
  }

  // One owners reply feeds three readings of the pass: the census rows, the
  // totals over every scanned process, and each owner's heap. They stand or
  // fall together, so a failed reply is the same reason in all three.
  let census = result.map(owners, census_of)
  let totals = result.map(owners, fn(snapshot) { snapshot.totals })
  let owner_heaps = result.map(owners, fn(snapshot) { snapshot.owners })

  // The node's facts and carriers are the dearest read, so they are taken on
  // the first pass and every `system_every` passes after.
  let system = case seq % system_every {
    0 ->
      case remote.ask(wire.Extended(wire.AskSystem), ask_deadline_ms) {
        Ok(wire.SystemReport(snapshot)) -> Ok(snapshot)
        other -> Error(reason_of(other, "system"))
      }
    _ -> Error(system_skipped)
  }
  let scheduler = read_scheduler(remote, step)
  let os = os()

  Observation(
    seq:,
    at_ms: started,
    elapsed_ms: clock() - started,
    memory:,
    census:,
    scheduler:,
    os:,
    totals:,
    owner_heaps:,
    system:,
  )
}

// The owners reply carries the census's own shape and, beside it, the heap
// of each owner and the totals. The census view drops the heap, and the
// pass keeps it separately as `owner_heaps`, so the rows stay the census's
// own shape and a capture does not have to record the heap.
fn census_of(snapshot: wire.OwnersSnapshot) -> wire.CensusSnapshot {
  wire.CensusSnapshot(
    coverage: snapshot.coverage,
    rows: snapshot.rows,
    owners: list.map(snapshot.owners, fn(owner) { owner.total }),
  )
}

fn read_scheduler(
  remote: Remote,
  step: SchedulerStep,
) -> Result(wire.SchedulerSnapshot, String) {
  let enabled = case step {
    TurnOnAndRead ->
      remote.ask(wire.AskScheduler(wire.SchedulerOn), ask_deadline_ms)
      |> result.replace(Nil)
      |> result.map_error(remote.describe)
    ReadOnly -> Ok(Nil)
  }

  use _ <- result.try(enabled)

  case remote.ask(wire.AskScheduler(wire.SchedulerRead), ask_deadline_ms) {
    Ok(wire.SchedulerReport(snapshot)) -> Ok(snapshot)
    other -> Error(reason_of(other, "scheduler"))
  }
}

fn reason_of(
  answer: Result(wire.Reply, remote.Failure),
  asked: String,
) -> String {
  case answer {
    Error(failure) -> remote.describe(failure)
    Ok(_) -> "the agent answered the " <> asked <> " request with another reply"
  }
}
