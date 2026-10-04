//// Page models built from what the viewer holds.
////
//// The web package draws a page from a plain record and never reads a
//// process, a socket or a clock. This module is where the viewer's data
//// becomes those records: the hub's ring of observations, the pins and plans
//// of the page's principal, the checkpoints and the audit trail. It is pure,
//// so a test can build every model from a hand-made `Inputs`.
////
//// Three rules carry through from the data. A reading that is not there is
//// a `Measurement` that says why, never a zero: a failed census section is
//// `Missing`, a column the agent does not collect is `Missing`, a change
//// against a baseline nobody chose is `NotApplicable`. Totals go through
//// the web package's own builders (`census/owners`), which refuse to add an
//// overlapping column. And a key a browser can send is derived from the
//// thing it names, never from its position: a process row's key is its pid
//// text, a pin's key is its token, a plan's key is its id. A click that was
//// in flight when the census moved therefore reaches the same process or
//// nothing.
////
//// Pages the viewer has no data for yet (supervision, profile, timeline,
//// compare, process detail) get no feed, and the web package draws them as
//// waiting. The viewer does not invent numbers to fill them.
////
//// ## Flow
////
//// - `feeds_for` builds the strip and the feed of one page.
//// - `rows_of` is the census as process rows, shared by the processes and
////   owners pages and by the key lookups the page mount makes.
//// - `slug_of` names the page a route slug asks for.
//// - `row_key`, `pin_key` and `plan_key` derive the keys a browser may
////   send from the things they name.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass/audit
import pickglass/calltrace_profile
import pickglass/deltas
import pickglass/gate
import pickglass/marks.{type Mark}
import pickglass/observation.{type Observation}
import pickglass/panel
import pickglass/probe_book.{type ProbeRecord}
import pickglass/seam
import pickglass/supervision_build
import pickglass/timeline_build
import pickglass_core/analysis/transform
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/profile/activity
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/build/profile as profile_page
import pickglass_web/census/owners as owners_builder
import pickglass_web/fmt
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/timeline_model

/// How many rows the processes page shows at once.
pub const window_size = 100

/// How many sparkline points the overview keeps.
pub const spark_points = 60

/// Which page a feed is for.
pub type Slug {
  Overview
  Owners
  Processes
  Memory
  Probes
  ProcessDetail
  Supervision
  Profile
  Timeline
  Compare
  Audit

  /// A page the viewer has no data for yet.
  Waiting
}

/// What a feed is built from.
pub type Inputs {
  Inputs(
    page: seam.Page,
    /// The ring's observations, newest first.
    observations: List(Observation),
    pins: List(seam.PinCard),
    plans: List(#(String, policy.Plan)),
    /// The checkpoints with their baselines, oldest first.
    marks: List(Mark),
    /// The index in `marks` the page compares against, if it chose one;
    /// otherwise the newest.
    baseline: Option(Int),
    /// The probes, newest first.
    probes: List(ProbeRecord),
    /// Which of a sampled profile's samples the profile page draws.
    samples: activity.Inclusion,
    /// What the profile page was asked to filter by and export.
    chain: List(transform.Step),
    exports: List(model.ExportNote),
    /// The compare page's state.
    comparison: Comparison,
    /// Wall-clock milliseconds now.
    now_ms: Int,
    /// The process the detail page was opened on, by the key in its address.
    subject: Option(Key),
    /// The agent's detail of that process, read by the feeder when it is
    /// pinned.
    detail: Option(Result(wire.ProcessDetail, String)),
    /// What collections and self-measures returned, newest first.
    results: List(seam.ProcessResult),
    /// The spawn edges, read by the feeder on the supervision page.
    supervision: Option(Result(wire.SupervisionSnapshot, String)),
    /// The newest audit entries, newest first.
    entries: List(audit.Entry),
    /// What this principal's pending profile plans were chosen from, by plan
    /// id.
    notes: List(seam.ProfileNote),
    /// Why the page's last profile button planned nothing, when it did not.
    refusal: Option(String),
    /// The probes the page confirmed and the agent refused at start.
    refused_starts: List(String),
    /// Why the target is gone, when it is.
    lost: Option(String),
    cadence_ms: Int,
    sort: model.SortColumn,
    offset: Int,
  )
}

/// What the compare page shows: the capture files on offer, which two are
/// chosen, and how reading them went.
pub type Comparison {
  Comparison(
    /// File names, newest first.
    offers: List(String),
    baseline: Option(String),
    candidate: Option(String),
    /// What reading the chosen pair gave, once both are chosen.
    outcome: Option(Result(model.CompareModel, String)),
  )
}

/// A comparison with nothing offered or chosen.
pub const no_comparison =
  Comparison(offers: [], baseline: None, candidate: None, outcome: None)

/// The page a route slug names.
///
/// ## Examples
///
/// ```gleam
/// feeds.slug_of("owners")
/// // -> Ok(Owners)
/// ```
pub fn slug_of(slug: String) -> Result(Slug, Nil) {
  case slug {
    "overview" -> Ok(Overview)
    "owners" -> Ok(Owners)
    "processes" -> Ok(Processes)
    "memory" -> Ok(Memory)
    "probes" -> Ok(Probes)
    "profile" -> Ok(Profile)
    "timeline" -> Ok(Timeline)
    "compare" -> Ok(Compare)
    "audit" -> Ok(Audit)
    "supervision" -> Ok(Supervision)
    "process-detail" | "process-detail:" <> _ -> Ok(ProcessDetail)
    _ -> Error(Nil)
  }
}

/// The feeds of a page: the strip, the one-click profile in flight, and the
/// page's own model when the viewer has data for it. With no observation yet
/// only the strip, the flow and the audit page are fed, so the other pages say
/// they are waiting.
///
/// ## Examples
///
/// ```gleam
/// feeds.feeds_for(feeds.Owners, inputs)
/// ```
pub fn feeds_for(slug: Slug, inputs: Inputs) -> List(msg.Feed) {
  [
    msg.FedStrip(strip(inputs)),
    msg.FedFlow(flow(inputs)),
    ..page_feeds(slug, inputs)
  ]
}

fn page_feeds(slug: Slug, inputs: Inputs) -> List(msg.Feed) {
  case slug, inputs.observations {
    Audit, _ -> [msg.FedAudit(audit_model(inputs))]
    Waiting, _ -> []
    Profile, _ -> profile_feed(inputs)
    Supervision, _ -> supervision_feed(inputs)
    Timeline, observations -> timeline_feed(inputs, observations)
    Compare, _ -> compare_feed(inputs)
    _, [] -> []
    Overview, [newest, ..] -> [
      msg.FedOverview(overview(inputs, newest)),
      ..movers_feed(inputs, newest)
    ]
    Owners, [newest, ..] -> owners_feed(inputs, newest)
    Processes, [newest, ..] -> processes_feed(inputs, newest)
    Memory, [newest, ..] -> [msg.FedMemory(memory(inputs, newest))]
    ProcessDetail, [newest, ..] -> detail_feed(inputs, newest)
    Probes, [newest, ..] -> [
      msg.FedProbes(probes(inputs, newest)),
      ..plan_target(inputs)
    ]
  }
}

// ------------------------------------------------------------------ keys

/// The key of a process row: its pid text with characters outside the key
/// alphabet replaced, so it names the process and not a position.
pub fn row_key(pid_text: String) -> Key {
  key.make(pid_text)
}

/// The key of a pin.
pub fn pin_key(token: String) -> Key {
  key.make(token)
}

/// The key of a plan.
pub fn plan_key(plan_id: String) -> Key {
  key.make("plan." <> plan_id)
}

/// The key of the nth checkpoint.
pub fn checkpoint_key(index: Int) -> Key {
  key.indexed("cp", index)
}

// ----------------------------------------------------------------- panels

fn info(
  inputs: Inputs,
  source: String,
  method: String,
  scope: String,
  requested: Int,
  achieved: Int,
  outcome: measure.Outcome,
  took_ms: Option(Int),
) -> model.PanelInfo {
  panel.info(panel.Facts(
    source:,
    method:,
    cadence_ms: inputs.cadence_ms,
    scope:,
    requested:,
    achieved:,
    outcome:,
    gap_ms: pass_gap(inputs.observations),
    took_ms:,
  ))
}

// The time between the starts of the two newest passes: the interval the
// collector actually kept, as against the one it was asked for. With fewer
// than two passes there is no interval to report.
fn pass_gap(observations: List(Observation)) -> Option(Int) {
  case observations {
    [newest, earlier, ..] -> Some(newest.at_ms - earlier.at_ms)
    [_] | [] -> None
  }
}

fn census_info(inputs: Inputs, newest: Observation) -> model.PanelInfo {
  case newest.census {
    Ok(census) -> {
      let coverage = census.coverage

      info(
        inputs,
        "census",
        "process_info bundle v1, label read; includes the agent's own reader",
        "processes",
        coverage.total,
        coverage.scanned,
        case coverage.stop {
          wire.WalkFinished -> measure.Complete
          wire.ScanBudgetReached ->
            measure.Partial(measure.Truncated(measure.BudgetReached))
          wire.DeadlineReached ->
            measure.Partial(measure.Truncated(measure.DeadlineHit))
        },
        Some(coverage.elapsed_ms),
      )
    }
    Error(reason) ->
      info(
        inputs,
        "census",
        "process_info bundle v1, label read",
        "processes",
        1,
        0,
        measure.Errored(reason),
        Some(newest.elapsed_ms),
      )
  }
}

// ------------------------------------------------------------------ strip

fn strip(inputs: Inputs) -> model.StripModel {
  let page = inputs.page
  let #(node, incarnation, os, source, role, line) = case page.mode {
    seam.Live(node, incarnation, os) -> #(
      node,
      incarnation,
      os,
      model.Live,
      model.AttachedFullTrust,
      "Attached over Erlang distribution: full code-execution authority on "
        <> "the target. The gate limits what pickglass sends, not the "
        <> "connection.",
    )
    seam.Viewing(name, incarnation, os) -> #(
      "(capture)",
      incarnation,
      os,
      model.Viewing(name),
      model.Diagnostic,
      "Viewing a capture file. No target is attached.",
    )
  }

  model.StripModel(
    node:,
    incarnation: case newest_system(inputs) {
      Some(#(_, facts)) ->
        identity.NodeIncarnation(..incarnation, creation: facts.creation)
      None -> incarnation
    },
    os:,
    uptime_ms: uptime_of(inputs),
    source: case inputs.lost, source {
      Some(reason), model.Live -> model.Detached(reason)
      _, _ -> source
    },
    banner: model.CapabilityBanner(
      role:,
      grants: page.grants,
      source_line: line,
    ),
    observer: observer(inputs),
    probes: active_probes(inputs),
  )
}

// The newest node facts the ring holds, with the time of the pass that read
// them. Facts are read on some passes only, so most observations have none.
fn newest_system(inputs: Inputs) -> Option(#(Int, wire.NodeFacts)) {
  inputs.observations
  |> list.find_map(fn(observation) {
    case observation.system {
      Ok(snapshot) -> Ok(#(observation.at_ms, snapshot.facts))
      Error(_) -> Error(Nil)
    }
  })
  |> option.from_result
}

// The node's uptime: what the agent read, plus the time since it read it.
// The agent's ping reports its own age and not the node's, so it is never
// used; until the facts are read the uptime is a word.
fn uptime_of(inputs: Inputs) -> measure.Measurement {
  case newest_system(inputs) {
    Some(#(read_at, facts)) ->
      Known(facts.uptime_ms + int.max(0, inputs.now_ms - read_at))
    None -> Missing(measure.UnsupportedOnRuntime)
  }
}

// The wall time of the newest pass against the cadence, in parts per ten
// thousand. It is the viewer's own clock around the whole pass, so it is an
// upper bound on how much of the cadence collecting occupies and not a
// measure of target CPU. A capture, or a viewer with no pass
// yet, has none.
fn observer(inputs: Inputs) -> model.ObserverEffect {
  case inputs.observations, inputs.page.mode, inputs.cadence_ms > 0 {
    [newest, ..], seam.Live(..), True ->
      model.ObserverEffect(
        duty: Known(newest.elapsed_ms * 10_000 / inputs.cadence_ms),
        note: "wall time of the newest collection pass in the viewer, as a share of its cadence; target CPU is not measured",
      )
    _, _, _ ->
      model.ObserverEffect(
        duty: Missing(measure.UnsupportedOnRuntime),
        note: "no collection pass has run in this view",
      )
  }
}

// --------------------------------------------------------------- overview

// The checkpoints as the page's references, each with the key a browser may
// send to name it.
fn checkpoint_refs(inputs: Inputs) -> List(model.CheckpointRef) {
  list.index_map(inputs.marks, fn(mark, index) {
    model.CheckpointRef(key: checkpoint_key(index), checkpoint: mark.checkpoint)
  })
}

// The checkpoint the page compares against and its reference, if any.
fn chosen_mark(inputs: Inputs) -> Option(#(model.CheckpointRef, Mark)) {
  case marks.chosen(inputs.marks, inputs.baseline) {
    Some(#(index, mark)) ->
      Some(#(
        model.CheckpointRef(
          key: checkpoint_key(index),
          checkpoint: mark.checkpoint,
        ),
        mark,
      ))
    None -> None
  }
}

// The baseline observation of the chosen checkpoint, when it has one.
fn baseline_observation(inputs: Inputs) -> Option(Observation) {
  case chosen_mark(inputs) {
    Some(#(_, mark)) -> mark.baseline
    None -> None
  }
}

fn overview(inputs: Inputs, newest: Observation) -> model.OverviewModel {
  model.OverviewModel(
    layers: model.Panel(
      info: memory_info(inputs, newest),
      body: layers_of(
        newest,
        baseline_observation(inputs),
        carrier_total(inputs),
      ),
    ),
    checkpoint: option.map(chosen_mark(inputs), fn(chosen) { chosen.0 }),
    checkpoints: checkpoint_refs(inputs),
    schedulers: model.Panel(info: scheduler_info(inputs, newest), body: [
      utilisation(inputs.observations),
    ]),
    counts: [
      model.CountTile(
        label: "processes",
        value: case newest.memory {
          Ok(memory) -> Known(memory.process_count)
          Error(reason) -> Missing(missing_for(reason))
        },
        limit: NotApplicable,
      ),
      ..scheduler_tiles(inputs)
    ],
    roles: model.Panel(info: os_info(inputs, newest), body: os_roles(newest)),
  )
}

// The scheduler counts of the node, from its facts: online of configured.
fn scheduler_tiles(inputs: Inputs) -> List(model.CountTile) {
  case newest_system(inputs) {
    None -> []
    Some(#(_, facts)) -> [
      model.CountTile(
        label: "schedulers online",
        value: Known(facts.schedulers_online),
        limit: Known(facts.schedulers),
      ),
      model.CountTile(
        label: "dirty CPU schedulers online",
        value: Known(facts.dirty_cpu_online),
        limit: Known(facts.dirty_cpu),
      ),
      model.CountTile(
        label: "dirty IO schedulers",
        value: Known(facts.dirty_io),
        limit: NotApplicable,
      ),
    ]
  }
}

// The owners that moved most since the checkpoint, in the figures the owners
// page shows. Without a checkpoint that has a baseline there is nothing to
// say, and the panel stays absent.
fn movers_feed(inputs: Inputs, newest: Observation) -> List(msg.Feed) {
  case chosen_mark(inputs) {
    Some(#(_, mark)) ->
      case mark.baseline, newest.census {
        Some(_), Ok(_) -> {
          let page = owners_page(inputs, newest)

          [
            msg.FedOwnerMovers(model.OwnerMovers(
              since: mark.checkpoint.name,
              rows: list.filter_map(page.rows, fn(row) {
                case row.kind {
                  model.OwnerGroup ->
                    Ok(model.OwnerMover(label: row.label, delta: row.delta))
                  model.RoleGroup | model.UnknownGroup -> Error(Nil)
                }
              })
                |> list.append([
                  model.OwnerMover(label: "unknown", delta: page.unknown.delta),
                ]),
            )),
          ]
        }
        _, _ -> []
      }
    None -> []
  }
}

// The OS panel: the target's own process and the processes it started, each
// with the figures the OS reader could take. A failed reading is the whole
// panel's outcome, never an empty table.
fn os_info(inputs: Inputs, newest: Observation) -> model.PanelInfo {
  let #(achieved, outcome) = case newest.os {
    Ok(readings) -> #(list.length(readings), measure.Complete)
    Error(reason) -> #(0, measure.Errored(reason))
  }

  info(
    inputs,
    "OS processes",
    "ps for resident set, CPU time and start; /proc for the anonymous part where it exists",
    "OS processes",
    case newest.os {
      Ok(readings) -> list.length(readings)
      Error(_) -> 1
    },
    achieved,
    outcome,
    None,
  )
}

fn os_roles(newest: Observation) -> List(model.OsRole) {
  case newest.os {
    Error(_) -> []
    Ok(readings) ->
      list.map(readings, fn(reading) {
        model.OsRole(
          role: reading.role,
          os: identity.OsProcess(pid: reading.pid, start: reading.start),
          rss: reading.rss,
          anon: reading.anon,
          note: case reading.start {
            identity.CoarseStart(_) -> "start time is good to a second"
            identity.PreciseStart(_) | identity.UnreadableStart -> ""
          },
        )
      })
  }
}

fn memory_info(inputs: Inputs, newest: Observation) -> model.PanelInfo {
  let outcome = case newest.memory {
    Ok(_) -> measure.Complete
    Error(reason) -> measure.Errored(reason)
  }

  info(
    inputs,
    "erlang:memory",
    "erlang:memory/0, not atomic",
    "categories",
    1,
    case newest.memory {
      Ok(_) -> 1
      Error(_) -> 0
    },
    outcome,
    None,
  )
}

fn scheduler_info(inputs: Inputs, newest: Observation) -> model.PanelInfo {
  info(
    inputs,
    "scheduler wall time",
    "scheduler_wall_time_all, between passes",
    "readings",
    1,
    case newest.scheduler {
      Ok(_) -> 1
      Error(_) -> 0
    },
    case newest.scheduler {
      Ok(_) -> measure.Complete
      Error(reason) -> measure.Errored(reason)
    },
    None,
  )
}

fn missing_for(reason: String) -> measure.MissingReason {
  case string.contains(reason, "in time") {
    True -> measure.DeadlineReached
    False -> measure.DecodeFailed
  }
}

// The layers of the node's memory, outermost last. The erlang:memory total
// comes first with its categories under it, nested as they are: `system`
// holds atoms, binaries, code and ETS, and `processes` holds the part of
// them in use. Then the allocators' carriers, then the OS's resident set,
// with the two differences between neighbouring layers as derived rows. The
// first difference is capacity the allocators hold and the VM does not
// count as in use; the second is what the OS charges the target for outside
// the allocators, or the reverse where carriers are reserved and not
// resident. A change is shown only against a baseline that has the same
// reading, and the carriers are read on some passes only, so their row and
// the two differences have no change.
fn layers_of(
  newest: Observation,
  baseline: Option(Observation),
  carriers: Measurement,
) -> List(model.LayerRow) {
  let #(vm, vm_total) = case newest.memory {
    Error(reason) -> #(
      [
        model.LayerRow(
          label: "erlang:memory total",
          depth: 0,
          value: Missing(missing_for(reason)),
          delta: NotApplicable,
          derivation: model.Measured,
        ),
      ],
      Missing(missing_for(reason)),
    )
    Ok(memory) -> #(
      list.map(memory.categories, fn(pair) {
        model.LayerRow(
          label: case pair.0 {
            "total" -> "erlang:memory total"
            other -> other
          },
          depth: depth_of(pair.0),
          value: Known(pair.1),
          delta: case baseline {
            Some(earlier) -> deltas.memory(newest, earlier, pair.0)
            None -> NotApplicable
          },
          derivation: model.Measured,
        )
      }),
      case list.key_find(memory.categories, "total") {
        Ok(total) -> Known(total)
        Error(Nil) -> Missing(measure.UnsupportedOnRuntime)
      },
    )
  }
  let rss = deltas.target_rss(newest)

  list.flatten([
    vm,
    [
      model.LayerRow(
        label: "allocator carriers",
        depth: 0,
        value: carriers,
        delta: NotApplicable,
        derivation: model.Derived(
          "the sum of every allocator's carrier size in the newest node read",
        ),
      ),
      model.LayerRow(
        label: "carriers beyond erlang:memory",
        depth: 1,
        value: gap(carriers, vm_total),
        delta: NotApplicable,
        derivation: model.Derived(
          "carriers minus the erlang:memory total: capacity the allocators hold that the VM does not count as in use, and allocator overhead; two readings taken at different moments",
        ),
      ),
      model.LayerRow(
        label: "OS resident set (target)",
        depth: 0,
        value: rss,
        delta: case baseline {
          Some(earlier) -> deltas.os_rss(newest, earlier)
          None -> NotApplicable
        },
        derivation: model.Derived("the OS's account, not the VM's"),
      ),
      model.LayerRow(
        label: "resident set beyond carriers",
        depth: 1,
        value: gap(rss, carriers),
        delta: NotApplicable,
        derivation: model.Derived(
          "resident set minus carriers: memory the OS charges the target outside the allocators, such as the emulator's own and shared libraries. It can be negative, because carriers count reserved address space and the resident set counts pages touched",
        ),
      ),
    ],
  ])
}

// How far a memory category nests under the total. `system` and `processes`
// are the two halves of the total; the rest are parts of one of them.
fn depth_of(category: String) -> Int {
  case category {
    "total" -> 0
    "processes" | "system" -> 1
    _ -> 2
  }
}

// The upper layer minus the lower, or the word for whichever side is not a
// number. A difference with an unknown end is not zero.
fn gap(upper: Measurement, lower: Measurement) -> Measurement {
  case upper, lower {
    Known(a), Known(b) -> Known(a - b)
    Missing(reason), _ | _, Missing(reason) -> Missing(reason)
    _, _ -> NotApplicable
  }
}

// The carriers of the newest node read that has them, as one reading. A
// pass that has not read the node yet, or a runtime that cannot report
// carriers, gives the word for why and not a sum of nothing.
fn carrier_total(inputs: Inputs) -> Measurement {
  let read =
    list.find_map(inputs.observations, fn(observation) {
      case observation.system {
        Ok(snapshot) -> Ok(snapshot.carriers)
        Error(_) -> Error(Nil)
      }
    })

  case read {
    Ok(wire.CarriersRead(rows:)) ->
      Known(list.fold(rows, 0, fn(sum, row) { sum + row.total_bytes }))
    Ok(wire.CarriersUnavailable(_)) -> Missing(measure.UnsupportedOnRuntime)
    Error(Nil) -> Missing(measure.NotCollected)
  }
}

// Scheduler utilisation between consecutive passes, oldest first: the change
// in active time over the change in total time, in parts per million, because
// an idle node is below the 0.01% a smaller scale resolves. A pair where wall
// time was not collected, or did not advance, has no point.
fn utilisation(observations: List(Observation)) -> model.Sparkline {
  let ordered = list.reverse(list.take(observations, spark_points + 1))
  let points =
    list.map2(ordered, list.drop(ordered, 1), fn(before, after) {
      case before.scheduler, after.scheduler {
        Ok(first), Ok(second) -> {
          let active =
            total_of(second, fn(r) { r.active })
            - total_of(first, fn(r) { r.active })
          let total =
            total_of(second, fn(r) { r.total })
            - total_of(first, fn(r) { r.total })

          case total > 0 && active >= 0 {
            True -> Known(active * 1_000_000 / total)
            False -> Missing(measure.CounterDisabled)
          }
        }
        _, _ -> Missing(measure.CounterDisabled)
      }
    })
  let known =
    list.filter_map(points, fn(point) {
      option.to_result(measure.to_option(point), Nil)
    })

  model.Sparkline(
    label: "utilisation",
    unit: unit.Ratio(per: 1_000_000),
    points:,
    summary: case known {
      [] -> Missing(measure.CounterDisabled)
      _ -> Known(int.sum(known) / list.length(known))
    },
    note: "mean over the window",
  )
}

fn total_of(
  snapshot: wire.SchedulerSnapshot,
  pick: fn(wire.SchedulerReading) -> Int,
) -> Int {
  list.fold(snapshot.readings, 0, fn(sum, reading) { sum + pick(reading) })
}

// ---------------------------------------------------------- owners, rows

/// The census of an observation as process rows, in the agent's order. A
/// failed census has none. A row's reductions are the process's lifetime
/// count, which the agent reads, and a rate needs two passes, so they are
/// absent here; `rated_rows_of` fills them in.
pub fn rows_of(newest: Observation, word_size: Int) -> List(model.ProcRow) {
  case newest.census {
    Error(_) -> []
    Ok(census) ->
      list.map(census.rows, fn(row) {
        let attribution = attribution_of(row.owner)

        model.ProcRow(
          key: row_key(row.pid_text),
          pid_text: row.pid_text,
          owner_label: label_of(attribution),
          attribution:,
          memory: Known(row.memory),
          heap_cap: Known(row.total_heap_words * word_size),
          mailbox: Known(row.queue_length),
          reductions: Missing(measure.NotInBothPasses),
          binary_refs: Missing(measure.NotCollected),
          current: case row.current_function {
            "" -> None
            function -> Some(function)
          },
        )
      })
  }
}

/// The process rows of the newest census with each row's reductions as a
/// rate per second: the change since the pass before, over the time between
/// the two. A process that was not in both passes has no rate, which is not
/// a rate of zero. The interval is returned so a page can say what the
/// rates are over.
///
/// ## Examples
///
/// ```gleam
/// feeds.rated_rows_of(observations, 8)
/// // -> #(rows, Some(2000))
/// ```
pub fn rated_rows_of(
  observations: List(Observation),
  word_size: Int,
) -> #(List(model.ProcRow), Option(Int)) {
  case observations {
    [newest, earlier, ..] -> {
      let rows = rows_of(newest, word_size)

      case earlier.census, newest.at_ms - earlier.at_ms {
        Ok(census), interval if interval > 0 -> {
          let before =
            list.map(census.rows, fn(row) { #(row.pid_text, row.reductions) })
          let now = case newest.census {
            Ok(current) ->
              list.map(current.rows, fn(row) { #(row.pid_text, row.reductions) })
            Error(_) -> []
          }

          #(
            list.map(rows, fn(row) {
              model.ProcRow(
                ..row,
                reductions: rate(
                  list.key_find(before, row.pid_text),
                  list.key_find(now, row.pid_text),
                  interval,
                ),
              )
            }),
            Some(interval),
          )
        }
        _, _ -> #(rows, None)
      }
    }
    [newest] -> #(rows_of(newest, word_size), None)
    [] -> #([], None)
  }
}

// The change in a process's lifetime reductions per second. A count that went
// down is a different process under a reused id, so it has no rate either.
fn rate(
  before: Result(Int, Nil),
  now: Result(Int, Nil),
  interval_ms: Int,
) -> measure.Measurement {
  case before, now {
    Ok(first), Ok(second) if second >= first ->
      Known({ second - first } * 1000 / interval_ms)
    _, _ -> Missing(measure.NotInBothPasses)
  }
}

fn attribution_of(reading: wire.OwnerReading) -> owner.Attribution {
  case reading {
    wire.Unlabelled -> owner.Unattributed
    wire.Labelled(path:, role:) ->
      owner.join([
        owner.Claim(
          path:,
          role:,
          source: owner.Declared,
          confidence: owner.High,
        ),
      ])
  }
}

fn label_of(attribution: owner.Attribution) -> String {
  case attribution {
    owner.Attributed(winner:, ..) ->
      owner.path_to_string(winner.path) <> " / " <> winner.role
    owner.Unattributed -> "unknown"
  }
}

fn word_size_of(newest: Observation, inputs: Inputs) -> Int {
  let from_ring =
    list.find_map(inputs.observations, fn(observation) { observation.memory })

  case newest.memory, from_ring {
    Ok(memory), _ -> memory.word_size
    Error(_), Ok(memory) -> memory.word_size
    Error(_), Error(Nil) -> 8
  }
}

/// The processes behind one row of the owners page, with the row's name as
/// the page writes it. An owner row's processes are those of the role rows
/// beneath it, a role row's are its own, and the unknown row's are the
/// processes nobody claimed. `Error` for a key no row has now, which a page
/// may send after the census moved on.
///
/// ## Examples
///
/// ```gleam
/// feeds.owner_members(inputs, newest, key.make("owner:session:abc"))
/// // -> Ok(#("session:abc", rows))
/// ```
pub fn owner_members(
  inputs: Inputs,
  newest: Observation,
  wanted: Key,
) -> Result(#(String, List(model.ProcRow)), Nil) {
  let page = owners_page(inputs, newest)

  members_behind(list.append(page.rows, [page.unknown]), wanted, "")
}

// Rows are in page order: an owner, then its roles, then the next owner, and
// the unknown row last. `owner` is the label of the owner row last passed.
fn members_behind(
  rows: List(model.OwnerRow),
  wanted: Key,
  owner: String,
) -> Result(#(String, List(model.ProcRow)), Nil) {
  case rows {
    [] -> Error(Nil)
    [row, ..rest] ->
      case row.kind, row.key == wanted {
        model.OwnerGroup, True ->
          Ok(#(
            row.label,
            list.flat_map(roles_of(rest), fn(role) { role.members }),
          ))
        model.OwnerGroup, False -> members_behind(rest, wanted, row.label)
        model.RoleGroup, True -> Ok(#(owner <> " / " <> row.label, row.members))
        model.UnknownGroup, True -> Ok(#("unknown", row.members))
        model.RoleGroup, False | model.UnknownGroup, False ->
          members_behind(rest, wanted, owner)
      }
  }
}

// The role rows that follow an owner row, up to the next row of another kind.
fn roles_of(rows: List(model.OwnerRow)) -> List(model.OwnerRow) {
  list.take_while(rows, fn(row) { row.kind == model.RoleGroup })
}

fn owners_feed(inputs: Inputs, newest: Observation) -> List(msg.Feed) {
  [msg.FedOwners(owners_page(inputs, newest))]
}

// The owners page for the newest census, with each group's heap capacity
// change since the chosen checkpoint when that checkpoint kept a census.
fn owners_page(inputs: Inputs, newest: Observation) -> model.OwnersModel {
  let word_size = word_size_of(newest, inputs)
  let #(rows, rate_ms) = rated_rows_of(inputs.observations, word_size)
  let chosen = chosen_mark(inputs)
  let without_change =
    owners_builder.build(
      census_info(inputs, newest),
      rows,
      checkpoint_refs(inputs),
      option.map(chosen, fn(pair) { pair.0 }),
      fn(_) { NotApplicable },
    )

  let page = case chosen {
    Some(#(_, marks.Mark(baseline: Some(earlier), ..))) ->
      with_changes(inputs, newest, earlier, rows, without_change, word_size)
    _ -> without_change
  }
  let page = model.OwnersModel(..page, rate_ms:)

  // The census lists only the top rows. What was scanned and not listed is
  // the remainder; the agent's per-owner aggregate carries memory and not
  // heap capacity, so the remainder's capacity is a word, not a figure.
  let left_out = case newest.census {
    Ok(census) -> census.coverage.scanned - list.length(census.rows)
    Error(_) -> 0
  }

  case newest.totals {
    Ok(totals) -> {
      // Totals cover every process scanned; the listed rows are the part
      // the page can name, so the rest is the difference.
      let listed = list.length(rows)
      let listed_heap =
        list.fold(rows, 0, fn(sum, row) {
          sum + option.unwrap(measure.to_option(row.heap_cap), 0)
        })

      owners_builder.with_remainder(
        page,
        procs: int.max(0, totals.processes - listed),
        heap_cap: Known(int.max(
          0,
          totals.total_heap_words * word_size - listed_heap,
        )),
      )
    }
    Error(_) ->
      owners_builder.with_remainder(
        page,
        procs: int.max(0, left_out),
        heap_cap: Missing(measure.UnsupportedOnRuntime),
      )
  }
}

fn with_changes(
  inputs: Inputs,
  newest: Observation,
  earlier: Observation,
  rows: List(model.ProcRow),
  current: model.OwnersModel,
  word_size: Int,
) -> model.OwnersModel {
  let baseline_page =
    owners_builder.build(
      census_info(inputs, earlier),
      rows_of(earlier, word_size),
      [],
      None,
      fn(_) { NotApplicable },
    )
  let completeness = case
    deltas.census_complete(earlier),
    deltas.census_complete(newest)
  {
    True, True -> deltas.BothComplete
    _, _ -> deltas.TopRowsOnly
  }

  owners_builder.build(
    census_info(inputs, newest),
    rows,
    checkpoint_refs(inputs),
    option.map(chosen_mark(inputs), fn(pair) { pair.0 }),
    case deltas.owner_heap_from_aggregates(newest, earlier, word_size) {
      Ok(from_aggregates) -> from_aggregates
      Error(Nil) -> deltas.owner_heap(current, baseline_page, completeness)
    },
  )
}

fn processes_feed(inputs: Inputs, newest: Observation) -> List(msg.Feed) {
  let #(all, rate_ms) =
    rated_rows_of(inputs.observations, word_size_of(newest, inputs))
  let sorted =
    list.sort(all, fn(a, b) {
      int.compare(sort_value(inputs.sort, b), sort_value(inputs.sort, a))
    })
  let total = list.length(sorted)
  let offset = int.max(0, int.min(inputs.offset, int.max(0, total - 1)))

  [
    msg.FedProcesses(model.ProcessesModel(
      info: census_info(inputs, newest),
      sort: inputs.sort,
      window: model.Window(offset:, size: window_size, total:),
      rows: list.take(list.drop(sorted, offset), window_size),
      rate_ms:,
    )),
  ]
}

fn sort_value(column: model.SortColumn, row: model.ProcRow) -> Int {
  let reading = case column {
    model.ByMemory -> row.memory
    model.ByMailbox -> row.mailbox
    model.ByReductions -> row.reductions
  }

  option.unwrap(measure.to_option(reading), 0)
}

// ----------------------------------------------------------------- memory

fn memory(inputs: Inputs, newest: Observation) -> model.MemoryModel {
  let categories = case newest.memory {
    Error(_) -> []
    Ok(snapshot) ->
      list.map(snapshot.categories, fn(pair) {
        model.CategoryRow(
          label: pair.0,
          unit: unit.Bytes,
          value: Known(pair.1),
          used: NotApplicable,
          additivity: case pair.0 {
            "processes" | "system" -> measure.Additive
            _ ->
              measure.Overlapping(
                "a part of another category, or the total itself",
              )
          },
          note: "",
        )
      })
  }
  let os_row =
    model.CategoryRow(
      label: "OS resident set (target)",
      unit: unit.Bytes,
      value: deltas.target_rss(newest),
      used: NotApplicable,
      additivity: measure.Overlapping(
        "the OS's account of the whole process: the VM's allocations, loaded code and shared libraries",
      ),
      note: "",
    )
  let unread = fn(source) {
    model.Panel(
      info: info(
        inputs,
        source,
        "not read yet",
        "rows",
        1,
        0,
        measure.Refused("the agent does not collect this yet"),
        None,
      ),
      body: [],
    )
  }

  model.MemoryModel(
    categories: model.Panel(
      info: memory_info(inputs, newest),
      body: list.append(categories, [os_row]),
    ),
    allocators: allocators_panel(inputs, unread("allocators")),
    tables: unread("ets tables"),
  )
}

// The allocator carriers from the node's facts: one row per allocator and
// pool, in bytes, with the used part and what the walk could not scan in the
// note. Where the VM cannot report them the panel says why and has no rows.
fn allocators_panel(
  inputs: Inputs,
  unread: model.Panel(List(model.CategoryRow)),
) -> model.Panel(List(model.CategoryRow)) {
  let read =
    list.find_map(inputs.observations, fn(observation) {
      case observation.system {
        Ok(snapshot) -> Ok(#(observation, snapshot.carriers))
        Error(_) -> Error(Nil)
      }
    })

  case read {
    Error(Nil) -> unread
    Ok(#(_, wire.CarriersUnavailable(reason:))) ->
      model.Panel(
        info: info(
          inputs,
          "allocators",
          "instrument:carriers",
          "rows",
          1,
          0,
          measure.Refused(reason),
          None,
        ),
        body: [],
      )
    Ok(#(_, wire.CarriersRead(rows:))) ->
      model.Panel(
        info: info(
          inputs,
          "allocators",
          "instrument:carriers",
          "rows",
          list.length(rows),
          list.length(rows),
          measure.Complete,
          None,
        ),
        body: list.map(rows, carrier_row),
      )
  }
}

fn carrier_row(row: wire.CarrierRow) -> model.CategoryRow {
  model.CategoryRow(
    label: row.allocator
      <> case row.pool {
      wire.InCarrierPool -> " (pool)"
      wire.NotInCarrierPool -> ""
    },
    unit: unit.Bytes,
    value: Known(row.total_bytes),
    used: Known(row.used_bytes),
    additivity: measure.Overlapping(
      "the used part is inside the total, and allocators share the VM's memory",
    ),
    note: fmt.count(row.carriers)
      <> " carriers"
      <> case row.unscanned_bytes {
      0 -> ""
      bytes -> ", " <> fmt.bytes(bytes) <> " not scanned"
    },
  )
}

// ----------------------------------------------------------------- probes

fn probes(inputs: Inputs, newest: Observation) -> model.ProbesModel {
  let rows = rated_rows_of(inputs.observations, word_size_of(newest, inputs)).0
  let live_pins =
    list.filter(inputs.pins, fn(pin) { pin.status == seam.PinLive })

  model.ProbesModel(
    info: info(
      inputs,
      "agent",
      "probe table",
      "probes",
      1,
      1,
      measure.Complete,
      None,
    ),
    targets: list.map(live_pins, fn(pin) {
      #(pin_key(pin.token), pin.pid_text <> label_for(rows, pin.pid_text))
    }),
    pending: list.first(plan_cards(inputs, rows)) |> option.from_result,
    active: active_probes(inputs),
    history: probe_history(inputs),
    refused: inputs.refused_starts,
    grants: inputs.page.grants,
  )
}

// The plans the principal has pending, as cards, in the order the gate holds
// them. A plan that no card can describe (it is not a probe, a collection or
// a measure) is left out.
fn plan_cards(
  inputs: Inputs,
  rows: List(model.ProcRow),
) -> List(model.PlanCard) {
  list.filter_map(inputs.plans, fn(entry) {
    let card = fn(what, tokens) {
      let note = list.find(inputs.notes, fn(note) { note.plan_id == entry.0 })

      Ok(
        model.PlanCard(
          key: plan_key(entry.0),
          what:,
          plan: entry.1,
          matched: NotApplicable,
          target_labels: list.map(tokens, fn(token) {
            target_label(inputs, rows, token)
          }),
          chosen: case note {
            Ok(found) -> found.chosen
            Error(Nil) -> ""
          },
          adjust: case note {
            Ok(seam.ProfileNote(
              method: seam.ByStacks(rate_hz),
              duration_ms:,
              processes:,
              ..,
            )) -> model.AdjustStacks(duration_ms:, rate_hz:, processes:)
            Ok(seam.ProfileNote(
              method: seam.ByCalls(_),
              duration_ms:,
              processes:,
              ..,
            )) -> model.AdjustCalls(duration_ms:, processes:)
            Ok(seam.ProfileNote(method: seam.ByEvents, ..)) | Error(Nil) ->
              model.NotAdjustable
          },
        ),
      )
    }

    case policy.plan_command(entry.1) {
      policy.StartProbe(spec:) -> card(model.ProbePlan(spec.kind), spec.targets)
      policy.TargetedGc(token:) -> card(model.GcPlan, [token])
      policy.SelfMeasure(token:) -> card(model.MeasurePlan, [token])
      policy.ReadCensus(_)
      | policy.ReadOwners
      | policy.ReadMemory
      | policy.ReadSupervision
      | policy.ReadAudit(_)
      | policy.PinProcess(_)
      | policy.UnpinProcess(_)
      | policy.ReadProcess(_)
      | policy.StopProbe(_)
      | policy.ExportCapture(..)
      | policy.Checkpoint(_)
      | policy.Detach -> Error(Nil)
    }
  })
}

// A target as the plan card names it: the process it pins and who owns it,
// or the token when the viewer holds no pin by that name.
fn target_label(
  inputs: Inputs,
  rows: List(model.ProcRow),
  token: identity.PinToken,
) -> String {
  let text = identity.pin_to_string(token)

  case list.find(inputs.pins, fn(pin) { pin.token == text }) {
    Ok(pin) -> pin.pid_text <> label_for(rows, pin.pid_text)
    Error(Nil) -> text
  }
}

/// How long after it ends a stack profile is still offered as "ready" above
/// every page, in milliseconds.
pub const ready_ms = 300_000

// The one-click profile in flight, for every page: the plan a profile button
// made, the stack probes running, and the profile that just finished.
fn flow(inputs: Inputs) -> model.FlowModel {
  let rows = case inputs.observations {
    [newest, ..] ->
      rated_rows_of(inputs.observations, word_size_of(newest, inputs)).0
    [] -> []
  }
  let probe_plans =
    list.filter(plan_cards(inputs, rows), fn(card) {
      case card.what {
        model.ProbePlan(_) -> True
        model.GcPlan | model.MeasurePlan -> False
      }
    })

  model.FlowModel(
    pending: list.first(probe_plans) |> option.from_result,
    running: active_probes(inputs),
    ready: ready_profile(inputs),
    refused: inputs.refusal,
  )
}

// The newest finished probe that has a result a page shows, while it is
// recent: a stack profile or a call tree, which the Profile page opens, or a
// scheduling recording, which the Timeline page opens.
fn ready_profile(inputs: Inputs) -> Option(model.ReadyProfile) {
  option.from_result(find_ready(inputs))
}

fn find_ready(inputs: Inputs) -> Result(model.ReadyProfile, Nil) {
  list.find_map(inputs.probes, fn(probe) {
    case probe.state {
      probe_book.Finished(ended_ms:, profile:, ..) -> {
        let age = int.max(0, inputs.now_ms - ended_ms)

        case age <= ready_ms, ready_summary(probe, profile) {
          True, Ok(#(summary, opens)) ->
            Ok(model.ReadyProfile(
              probe: probe.id,
              age_ms: age,
              summary:,
              opens:,
            ))
          _, _ -> Error(Nil)
        }
      }
      probe_book.Running -> Error(Nil)
    }
  })
}

// What a finished probe left that a page can show, and the page. A counters
// probe's profile is read on the Probes and Profile pages by those who ran
// it by hand, and is not announced above every page.
fn ready_summary(
  probe: ProbeRecord,
  found: Option(profile.Profile),
) -> Result(#(String, model.ReadyPage), Nil) {
  case probe.kind, found, probe.detail {
    policy.Sampling, Some(sampled), _ ->
      Ok(#(stack_summary(sampled), model.OpensProfile))
    policy.CallTree, Some(traced), _ ->
      Ok(#(call_summary(traced), model.OpensProfile))
    policy.SchedulingGc, _, probe_book.SchedulingDetail(snapshot:) ->
      Ok(#(
        fmt.count(list.length(snapshot.processes))
          <> " processes, "
          <> fmt.count(
          list.fold(snapshot.processes, 0, fn(total, process) {
            total + process.runs
          }),
        )
          <> " runs",
        model.OpensTimeline,
      ))
    _, _, _ -> Error(Nil)
  }
}

// The samples of a stack profile, split by what the processes were doing when
// the profile carries their statuses.
fn stack_summary(found: profile.Profile) -> String {
  let rate = case profile.source(found) {
    profile.SampledStacks(rate:, ..) -> " at " <> int.to_string(rate) <> " Hz"
    profile.TracedCalls | profile.TracedCounters | profile.AllocationCounts ->
      ""
  }

  case profile.columns(found) {
    [] -> "no samples"
    [first, ..] ->
      case activity.has_status(found) {
        True -> {
          let split = activity.split(found, first)

          fmt.count(split.on_scheduler + split.unstated)
          <> " running or runnable of "
          <> fmt.count(activity.split_total(split))
          <> " samples"
          <> rate
        }
        False -> fmt.count(profile.total(found, first)) <> " samples" <> rate
      }
  }
}

fn call_summary(found: profile.Profile) -> String {
  let calls = case profile.column_named(found, calltrace_profile.calls_column) {
    Ok(column) -> profile.total(found, column)
    Error(Nil) -> 0
  }

  fmt.count(calls)
  <> " traced calls over "
  <> fmt.count(list.length(profile.functions(found)))
  <> " functions"
}

/// The key of a probe, which names it by the agent's id.
pub fn probe_key(probe_id: String) -> Key {
  key.make("probe." <> probe_id)
}

// The newest live pin is offered as the plan form's first target, which is
// how "Plan probe" on a process ends: the process is pinned and the form is
// open with it chosen. The page ignores the offer once the operator has
// chosen a target of their own.
fn plan_target(inputs: Inputs) -> List(msg.Feed) {
  case
    list.filter(inputs.pins, fn(pin) { pin.status == seam.PinLive })
    |> list.last
  {
    Ok(pin) -> [msg.FedPlanTarget(pin_key(pin.token))]
    Error(Nil) -> []
  }
}

fn active_probes(inputs: Inputs) -> List(model.ActiveProbe) {
  list.filter_map(inputs.probes, fn(probe) {
    case probe.state {
      probe_book.Running ->
        Ok(model.ActiveProbe(
          key: probe_key(probe.id),
          kind: probe.kind,
          remaining_ms: Known(probe_book.remaining_ms(probe, inputs.now_ms)),
        ))
      probe_book.Finished(..) -> Error(Nil)
    }
  })
}

fn probe_history(inputs: Inputs) -> List(model.ProbeHistoryRow) {
  list.filter_map(inputs.probes, fn(probe) {
    case probe.state {
      probe_book.Running -> Error(Nil)
      probe_book.Finished(outcome:, cost:, ..) ->
        Ok(model.ProbeHistoryRow(
          key: probe_key(probe.id),
          kind: probe.kind,
          outcome:,
          cost:,
        ))
    }
  })
}

fn label_for(rows: List(model.ProcRow), pid_text: String) -> String {
  case list.find(rows, fn(row) { row.pid_text == pid_text }) {
    Ok(row) -> " " <> row.owner_label
    Error(Nil) -> ""
  }
}

// ------------------------------------------------------------------ audit

fn audit_model(inputs: Inputs) -> model.AuditModel {
  let now = case inputs.entries {
    [first, ..] -> entry_time(first)
    [] -> 0
  }

  model.AuditModel(
    info: info(
      inputs,
      "viewer audit log",
      "gate decisions and front-door refusals",
      "entries",
      list.length(inputs.entries),
      list.length(inputs.entries),
      measure.Complete,
      None,
    ),
    entries: list.map(inputs.entries, fn(entry) { policy_entry(entry, now) }),
  )
}

fn entry_time(entry: audit.Entry) -> Int {
  case entry {
    audit.Decision(decision) -> decision.at_ms
    audit.Host(at_ms, _) -> at_ms
  }
}

// A host event has no `policy` stage; it is shown as an authorize-stage line
// whose command is the event, allowed or denied by what happened.
fn policy_entry(entry: audit.Entry, _now: Int) -> policy.AuditEntry {
  case entry {
    audit.Decision(decision) -> decision
    audit.Host(at_ms, event) ->
      policy.AuditEntry(
        at_ms:,
        stage: policy.AuthorizeStage,
        principal: "host",
        command: audit.describe(entry),
        decision: case event {
          audit.TicketRedeemed(_)
          | audit.SocketAdmitted(_)
          | audit.DownloadServed(_)
          | audit.RecordsDropped(..) -> policy.Allowed
          audit.TicketRefused(_)
          | audit.RequestRefused(..)
          | audit.SocketRefused(_)
          | audit.FrameRefused(..)
          | audit.PlanUnknown(_)
          | audit.RequestMalformed(..)
          | audit.PinsInvalidated(_) -> policy.Denied(reason: "refused")
        },
      )
  }
}

// ---------------------------------------------------------------- profile

/// The most functions the profile page's chain can name before the viewer
/// stops growing it. A chain longer than this is a mistake, not an analysis.
pub const max_chain = 16

// The newest finished probe that measured something, drawn through the
// page's chain. A chain core refuses (a pattern that did not compile) is
// dropped whole and the profile drawn unfiltered, because a profile the
// operator cannot see is worse than a filter that did not apply.
fn profile_feed(inputs: Inputs) -> List(msg.Feed) {
  case profile_model(inputs, inputs.chain) {
    Ok(Some(page)) -> [msg.FedProfile(page)]
    Ok(None) -> []
    Error(_) ->
      case profile_model(inputs, []) {
        Ok(Some(page)) -> [msg.FedProfile(page)]
        Ok(None) | Error(_) -> []
      }
  }
}

/// The profile page for the newest probe that has a profile, after a chain.
/// `Ok(None)` when no probe has measured anything yet.
///
/// ## Examples
///
/// ```gleam
/// feeds.profile_model(inputs, [transform.Focus("lists")])
/// ```
pub fn profile_model(
  inputs: Inputs,
  chain: List(transform.Step),
) -> Result(Option(model.ProfileModel), profile_page.Failure) {
  case probe_book.latest_profiled(inputs.probes) {
    Error(Nil) -> Ok(None)
    Ok(#(probe, found)) ->
      case column_of(found) {
        Error(Nil) -> Ok(None)
        Ok(column) ->
          profile_page.build_with(
            profile_header(probe, found),
            found,
            column,
            inputs.samples,
            processes_of(probe),
            chain,
            inputs.exports,
          )
          |> result.map(Some)
      }
  }
}

// How many processes a stack probe sampled. Its match count is the number of
// targets; any other kind has no statuses to count them for.
fn processes_of(probe: ProbeRecord) -> Option(Int) {
  case probe.kind {
    policy.Sampling -> Some(probe.matched)
    policy.Counters | policy.CallTree | policy.SchedulingGc -> None
  }
}

// A counters profile is read by call time and a call tree by exclusive time,
// the column whose sums are the widths of a flame's boxes; any other by its
// first column, which for sampled stacks is the sample count. Core guarantees
// a profile has a value type, so the error is not reachable; it is handled as
// "nothing to draw" and not as a crash.
fn column_of(found: profile.Profile) -> Result(profile.Column, Nil) {
  result.lazy_or(profile.column_named(found, "call time"), fn() {
    result.lazy_or(
      profile.column_named(found, calltrace_profile.exclusive_column),
      fn() { profile.column(found, 0) },
    )
  })
}

fn profile_header(
  probe: ProbeRecord,
  found: profile.Profile,
) -> model.ProfileHeader {
  let notes = case probe.state {
    probe_book.Finished(notes:, ..) -> notes
    probe_book.Running -> []
  }
  let #(source, method) = case profile.source(found) {
    profile.SampledStacks(method:, rate:) -> #(
      "sampled stacks probe",
      method <> ", " <> int.to_string(rate) <> " Hz requested",
    )
    profile.TracedCounters -> #(
      "counters probe",
      "call_time trace session, silent, read at the deadline",
    )
    profile.TracedCalls -> #(
      "call trace probe",
      "call and return_to events, folded in the agent",
    )
    profile.AllocationCounts -> #("allocation counts", "allocator statistics")
  }

  // The kind of probe decides what the coverage counts, never the source
  // of the profile it produced. A stack probe is asked for a rate over a
  // duration on its targets, and it covers the samples it took against
  // that; the profile's own total is what it took. A counters probe covers
  // the functions it matched, and a function nobody called is a function
  // that was matched and not called.
  let #(coverage_scope, requested, achieved) = case probe.kind {
    policy.Sampling -> {
      let seconds = int.max(1, probe.duration_ms / 1000)
      let taken = case profile.columns(found) {
        [first, ..] -> profile.total(found, first)
        [] -> 0
      }

      // The rate is the one the agent ran, which the profile records.
      let rate = case profile.source(found) {
        profile.SampledStacks(rate:, ..) -> rate
        profile.TracedCalls
        | profile.TracedCounters
        | profile.AllocationCounts -> gate.sampling_hz
      }

      // The plan's estimate rounds the rate per process, so a probe can take
      // more than it; the figure is never shown as fewer than were taken.
      #(
        "samples",
        int.max(rate * seconds * int.max(1, probe.matched), taken),
        taken,
      )
    }

    // A call tree's coverage is the functions it matched and how many of
    // them were called in the window, which is what the profile's function
    // table holds.
    policy.CallTree -> #(
      "functions called",
      probe.matched,
      list.length(profile.functions(found)),
    )
    policy.Counters | policy.SchedulingGc -> #(
      "functions with calls",
      probe.matched,
      list.length(profile.samples(found)),
    )
  }
  let took = case probe.state {
    probe_book.Finished(cost: capture.ProbeCost(wall_ms: Known(ms), ..), ..) ->
      Some(ms)
    probe_book.Finished(..) | probe_book.Running -> None
  }

  model.ProfileHeader(
    title: "probe "
      <> probe.id
      <> case probe.modules {
      [] -> ""
      ["*"] -> " · all modules"
      modules -> " · " <> string.join(modules, ", ")
    },
    source: profile.source(found),
    // A probe runs once. Its panel has no cadence to keep or miss: the
    // collection cadence belongs to the census, and a probe's own wall time
    // is a duration, not an interval.
    info: panel.info(panel.Facts(
      source:,
      method:,
      cadence_ms: 0,
      scope: coverage_scope,
      requested:,
      achieved:,
      outcome: case probe.state {
        probe_book.Finished(outcome:, ..) -> outcome
        probe_book.Running -> measure.Complete
      },
      gap_ms: None,
      took_ms: took,
    )),
    caveats: notes,
  )
}

// --------------------------------------------------------------- timeline

fn timeline_feed(
  inputs: Inputs,
  observations: List(Observation),
) -> List(msg.Feed) {
  let rows = case observations {
    [newest, ..] -> rated_rows_of(observations, word_size_of(newest, inputs)).0
    [] -> []
  }

  case
    timeline_build.build_labelled(
      observations,
      inputs.marks,
      inputs.probes,
      inputs.cadence_ms,
      inputs.now_ms,
      fn(pid) { pid <> label_for(rows, pid) },
    )
  {
    Ok(page) -> [
      msg.FedTimeline(
        timeline_model.TimelineModel(..page, exports: inputs.exports),
      ),
    ]
    Error(_) -> []
  }
}

// ---------------------------------------------------------------- compare

/// The key of a capture file offered for comparison.
pub fn capture_key(name: String) -> Key {
  key.make("cap:" <> name)
}

fn compare_feed(inputs: Inputs) -> List(msg.Feed) {
  let state = inputs.comparison
  let chosen = fn(name) {
    case Some(name) == state.baseline, Some(name) == state.candidate {
      True, _ -> model.AsBaseline
      _, True -> model.AsCandidate
      _, _ -> model.NotChosen
    }
  }

  let note = case state.outcome, state.baseline, state.candidate {
    Some(Error(reason)), _, _ -> reason
    Some(Ok(_)), _, _ -> ""
    None, None, None -> "Choose a baseline and a candidate."
    None, Some(_), None -> "Choose a candidate."
    None, None, Some(_) -> "Choose a baseline."
    None, Some(_), Some(_) -> "Reading the chosen captures."
  }

  let offers =
    msg.FedCaptures(model.CapturesModel(
      info: info(
        inputs,
        "capture files",
        "the files in the save directory",
        "files",
        list.length(state.offers),
        list.length(state.offers),
        measure.Complete,
        None,
      ),
      offers: list.map(state.offers, fn(name) {
        model.CaptureOffer(key: capture_key(name), name:, chosen: chosen(name))
      }),
      note:,
    ))

  case state.outcome {
    Some(Ok(page)) -> [offers, msg.FedCompare(page)]
    Some(Error(_)) | None -> [offers]
  }
}

// ------------------------------------------------------------ supervision

fn supervision_feed(inputs: Inputs) -> List(msg.Feed) {
  case inputs.supervision {
    Some(Ok(snapshot)) -> [
      msg.FedSupervision(supervision_build.build(
        info(
          inputs,
          "spawn edges",
          "process_info parent over every scanned process",
          "processes",
          snapshot.coverage.total,
          snapshot.coverage.scanned,
          supervision_build.outcome(snapshot.coverage),
          Some(snapshot.coverage.elapsed_ms),
        ),
        snapshot,
      )),
    ]
    Some(Error(_)) | None -> []
  }
}

// ----------------------------------------------------------- process detail

// The detail page for one process: what the census holds about it, and the
// agent's detail when the process is pinned. A process the newest census does
// not list is not drawn, because the viewer would be inventing its figures.
fn detail_feed(inputs: Inputs, newest: Observation) -> List(msg.Feed) {
  let word_size = word_size_of(newest, inputs)

  case inputs.subject {
    None -> []
    Some(subject) ->
      case
        list.find(rated_rows_of(inputs.observations, word_size).0, fn(row) {
          row.key == subject
        })
      {
        Error(Nil) -> []
        Ok(row) -> [
          msg.FedProcessDetail(process_detail(inputs, row, word_size)),
        ]
      }
  }
}

fn process_detail(
  inputs: Inputs,
  row: model.ProcRow,
  word_size: Int,
) -> model.ProcessDetailModel {
  let pin =
    list.find(inputs.pins, fn(card) {
      card.pid_text == row.pid_text && card.status == seam.PinLive
    })
  let detail = case inputs.detail {
    Some(Ok(found)) -> Some(found)
    Some(Error(_)) | None -> None
  }

  // The history covers the newest passes the sparklines draw. The census
  // lists only its top rows, so a process is in some of those passes and not
  // in others, and the panel says how many.
  let window = list.take(inputs.observations, spark_points)
  let listed =
    list.filter(window, fn(observation) {
      case observation.census {
        Ok(census) ->
          list.any(census.rows, fn(found) { found.pid_text == row.pid_text })
        Error(_) -> False
      }
    })

  model.ProcessDetailModel(
    info: info(
      inputs,
      "process",
      case detail {
        Some(_) -> "census row and process_info detail of a pinned process"
        None -> "census row; pin the process to read its detail"
      },
      "passes",
      list.length(window),
      list.length(listed),
      measure.Complete,
      None,
    ),
    key: row.key,
    pid_text: row.pid_text,
    birth: birth_text(detail),
    liveness: model.Alive,
    pin: case pin {
      Ok(card) -> model.Pinned(pin_key(card.token))
      Error(Nil) -> model.NotPinned
    },
    attribution: row.attribution,
    successor: None,
    counters: list.append(
      census_counters(row),
      list.append(
        detail_counters(detail),
        measured_counters(inputs, row, word_size),
      ),
    ),
    gc: list.append(gc_counters(detail), collection_counters(inputs, row)),
    history: process_history(inputs, row),
    evidence: evidence_of(row),
    self_measure: case detail {
      Some(found) ->
        case list.contains(found.capabilities, "measure") {
          True -> model.Available
          False -> model.Unavailable
        }
      None -> model.Unavailable
    },
  )
}

fn birth_text(detail: Option(wire.ProcessDetail)) -> String {
  case detail {
    None -> "not read: pin the process to read its initial call and parent"
    Some(found) -> {
      let parent = case found.relations.parent_pid_text {
        "" -> "no known spawner"
        text -> "spawned by " <> text
      }

      case found.activity.initial_call {
        "" -> parent
        call -> "initial call " <> call <> ", " <> parent
      }
    }
  }
}

fn counter(
  label: String,
  u: unit.Unit,
  value: measure.Measurement,
) -> model.Counter {
  model.Counter(label:, unit: u, value:, inapplicable: "")
}

fn census_counters(row: model.ProcRow) -> List(model.Counter) {
  [
    counter("memory", unit.Bytes, row.memory),
    counter("total heap", unit.Bytes, row.heap_cap),
    counter("mailbox", unit.Count, row.mailbox),
    counter("reductions", unit.Reductions, row.reductions),
  ]
}

fn detail_counters(detail: Option(wire.ProcessDetail)) -> List(model.Counter) {
  case detail {
    None -> []
    Some(found) -> [
      counter("heap", unit.Bytes, Known(found.sizes.heap_bytes)),
      counter("stack", unit.Bytes, Known(found.sizes.stack_bytes)),
      counter("links", unit.Count, Known(found.relations.links)),
      counter("monitors", unit.Count, Known(found.relations.monitors)),
      counter("monitored by", unit.Count, Known(found.relations.monitored_by)),
    ]
  }
}

fn gc_counters(detail: Option(wire.ProcessDetail)) -> List(model.Counter) {
  case detail {
    None -> []
    Some(found) -> {
      let gc = found.gc

      [
        counter("minor collections", unit.Count, Known(gc.minor_gcs)),
        counter("fullsweep after", unit.Count, Known(gc.fullsweep_after)),
        counter("min heap", unit.Bytes, Known(gc.min_heap_bytes)),
        case gc.max_heap_bytes {
          // A zero is the VM's "no limit", which is a setting and not a
          // missing reading.
          0 ->
            model.Counter(
              label: "max heap",
              unit: unit.Bytes,
              value: NotApplicable,
              inapplicable: "no limit",
            )
          bytes -> counter("max heap", unit.Bytes, Known(bytes))
        },
        counter("heap block", unit.Bytes, Known(gc.heap_block_bytes)),
        counter("old heap", unit.Bytes, Known(gc.old_heap_bytes)),
        counter("old heap block", unit.Bytes, Known(gc.old_heap_block_bytes)),
        counter("message buffers", unit.Bytes, Known(gc.mbuf_bytes)),
        counter("binary vheap", unit.Bytes, Known(gc.bin_vheap_bytes)),
      ]
    }
  }
}

// The newest collection of this process: its total heap before and after.
// A target that exited before it was collected has words, not figures.
fn collection_counters(
  inputs: Inputs,
  row: model.ProcRow,
) -> List(model.Counter) {
  let found =
    list.find_map(inputs.results, fn(result) {
      case result {
        seam.GcRan(snapshot:, ..) if snapshot.pid_text == row.pid_text ->
          Ok(snapshot)
        seam.GcRan(..) | seam.SelfMeasured(..) -> Error(Nil)
      }
    })

  case found {
    Error(Nil) -> []
    Ok(snapshot) -> [
      counter(
        "total heap before the last collection",
        unit.Bytes,
        heap_of(snapshot.before),
      ),
      counter(
        "total heap after the last collection",
        unit.Bytes,
        heap_of(snapshot.after),
      ),
    ]
  }
}

fn heap_of(reading: wire.HeapReading) -> measure.Measurement {
  case reading {
    wire.HeapRead(sizes) -> Known(sizes.total_heap_bytes)
    wire.HeapGone -> Missing(measure.ProcessExited)
  }
}

// What the process reported when it was last asked to measure itself, in the
// units it named; words become bytes with the node's word size.
fn measured_counters(
  inputs: Inputs,
  row: model.ProcRow,
  word_size: Int,
) -> List(model.Counter) {
  let found =
    list.find_map(inputs.results, fn(result) {
      case result {
        seam.SelfMeasured(snapshot:, ..) if snapshot.pid_text == row.pid_text ->
          Ok(snapshot)
        seam.SelfMeasured(..) | seam.GcRan(..) -> Error(Nil)
      }
    })

  case found {
    Error(Nil) -> []
    Ok(snapshot) ->
      list.map(snapshot.readings, fn(reading) {
        case reading.unit {
          wire.ReadingWords ->
            counter(
              "self: " <> reading.name,
              unit.Bytes,
              Known(reading.value * word_size),
            )
          wire.ReadingBytes ->
            counter("self: " <> reading.name, unit.Bytes, Known(reading.value))
          wire.ReadingCount ->
            counter("self: " <> reading.name, unit.Count, Known(reading.value))
        }
      })
  }
}

// The process's memory and mailbox over the passes that listed it; a pass
// that did not list it has a word, because a process outside the top rows
// is not a process with no memory.
fn process_history(
  inputs: Inputs,
  row: model.ProcRow,
) -> List(model.Sparkline) {
  let ordered = list.reverse(list.take(inputs.observations, spark_points))
  let series = fn(label, u, pick) {
    let points =
      list.map(ordered, fn(observation) {
        case observation.census {
          Ok(census) ->
            case
              list.find(census.rows, fn(found) {
                found.pid_text == row.pid_text
              })
            {
              Ok(found) -> Known(pick(found))
              Error(Nil) -> Missing(measure.BudgetExhausted)
            }
          Error(_) -> Missing(measure.DecodeFailed)
        }
      })
    let known =
      list.filter_map(points, fn(point) {
        option.to_result(measure.to_option(point), Nil)
      })

    model.Sparkline(
      label:,
      unit: u,
      points:,
      summary: case list.last(known) {
        Ok(latest) -> Known(latest)
        Error(Nil) -> Missing(measure.BudgetExhausted)
      },
      note: "latest reading",
    )
  }

  [
    series("memory", unit.Bytes, fn(found) { found.memory }),
    series("mailbox", unit.Count, fn(found) { found.queue_length }),
  ]
}

fn evidence_of(row: model.ProcRow) -> List(model.Evidence) {
  case row.attribution {
    owner.Unattributed -> []
    owner.Attributed(winner:, dissent:) ->
      list.map([winner, ..dissent], fn(claim) {
        model.Evidence(
          kind: claim.role,
          target: owner.path_to_string(claim.path),
          source: claim.source,
        )
      })
  }
}
