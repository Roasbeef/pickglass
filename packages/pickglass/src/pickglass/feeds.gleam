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
import pickglass/deltas
import pickglass/marks.{type Mark}
import pickglass/observation.{type Observation}
import pickglass/panel
import pickglass/probe_book.{type ProbeRecord}
import pickglass/seam
import pickglass/timeline_build
import pickglass_core/analysis/transform
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure.{Known, Missing, NotApplicable}
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/build/profile as profile_page
import pickglass_web/census/owners as owners_builder
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/msg

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
    /// What the profile page was asked to filter by and export.
    chain: List(transform.Step),
    exports: List(model.ExportNote),
    /// The compare page's state.
    comparison: Comparison,
    /// Wall-clock milliseconds now.
    now_ms: Int,
    /// The newest audit entries, newest first.
    entries: List(audit.Entry),
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
    "supervision" | "process-detail" -> Ok(Waiting)
    _ -> Error(Nil)
  }
}

/// The feeds of a page: the strip, and the page's own model when the viewer
/// has data for it. With no observation yet only the strip and the audit page
/// are fed, so the other pages say they are waiting.
///
/// ## Examples
///
/// ```gleam
/// feeds.feeds_for(feeds.Owners, inputs)
/// ```
pub fn feeds_for(slug: Slug, inputs: Inputs) -> List(msg.Feed) {
  let strip = msg.FedStrip(strip(inputs))

  case slug, inputs.observations {
    Audit, _ -> [strip, msg.FedAudit(audit_model(inputs))]
    Waiting, _ -> [strip]
    Profile, _ -> [strip, ..profile_feed(inputs)]
    Timeline, observations -> [strip, ..timeline_feed(inputs, observations)]
    Compare, _ -> [strip, ..compare_feed(inputs)]
    _, [] -> [strip]
    Overview, [newest, ..] -> [
      strip,
      msg.FedOverview(overview(inputs, newest)),
      ..movers_feed(inputs, newest)
    ]
    Owners, [newest, ..] -> [strip, ..owners_feed(inputs, newest)]
    Processes, [newest, ..] -> [strip, ..processes_feed(inputs, newest)]
    Memory, [newest, ..] -> [strip, msg.FedMemory(memory(inputs, newest))]
    Probes, [newest, ..] -> [
      strip,
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
  elapsed_ms: Int,
) -> model.PanelInfo {
  panel.info(panel.Facts(
    source:,
    method:,
    cadence_ms: inputs.cadence_ms,
    scope:,
    requested:,
    achieved:,
    outcome:,
    elapsed_ms:,
  ))
}

fn census_info(inputs: Inputs, newest: Observation) -> model.PanelInfo {
  case newest.census {
    Ok(census) -> {
      let coverage = census.coverage

      info(
        inputs,
        "census",
        "process_info bundle v1, label read",
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
        coverage.elapsed_ms,
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
        newest.elapsed_ms,
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
      "Attached over Erlang distribution. This connection holds full "
        <> "code-execution authority on the target; pickglass issues only "
        <> "the commands its gate admits, but the authority is not reduced "
        <> "by that.",
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
    incarnation:,
    os:,
    uptime_ms: Missing(measure.UnsupportedOnRuntime),
    source:,
    banner: model.CapabilityBanner(
      role:,
      grants: page.grants,
      source_line: line,
    ),
    observer: observer(inputs),
    probes: active_probes(inputs),
  )
}

// The duty cycle of the collector: how long the newest pass took against the
// cadence, in parts per ten thousand. A capture, or a viewer with no pass
// yet, has none.
fn observer(inputs: Inputs) -> model.ObserverEffect {
  case inputs.observations, inputs.page.mode, inputs.cadence_ms > 0 {
    [newest, ..], seam.Live(..), True ->
      model.ObserverEffect(
        duty: Known(newest.elapsed_ms * 10_000 / inputs.cadence_ms),
        note: "the newest collection pass against its cadence",
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
      body: layers_of(newest, baseline_observation(inputs)),
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
    ],
    roles: model.Panel(info: os_info(inputs, newest), body: os_roles(newest)),
  )
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
    newest.elapsed_ms,
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
    newest.elapsed_ms,
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
    newest.elapsed_ms,
  )
}

fn missing_for(reason: String) -> measure.MissingReason {
  case string.contains(reason, "in time") {
    True -> measure.DeadlineReached
    False -> measure.DecodeFailed
  }
}

// The erlang:memory total first, then each category under it, then the OS's
// account of the target. A failed memory reading is one row that says so. A
// change is shown only against a baseline that has the same reading.
fn layers_of(
  newest: Observation,
  baseline: Option(Observation),
) -> List(model.LayerRow) {
  let vm = case newest.memory {
    Error(reason) -> [
      model.LayerRow(
        label: "erlang:memory total",
        depth: 0,
        value: Missing(missing_for(reason)),
        delta: NotApplicable,
        derivation: model.Measured,
      ),
    ]
    Ok(memory) ->
      list.map(memory.categories, fn(pair) {
        model.LayerRow(
          label: case pair.0 {
            "total" -> "erlang:memory total"
            other -> other
          },
          depth: case pair.0 {
            "total" -> 0
            _ -> 1
          },
          value: Known(pair.1),
          delta: case baseline {
            Some(earlier) -> deltas.memory(newest, earlier, pair.0)
            None -> NotApplicable
          },
          derivation: model.Measured,
        )
      })
  }

  list.append(vm, [
    model.LayerRow(
      label: "OS resident set (target)",
      depth: 0,
      value: deltas.target_rss(newest),
      delta: case baseline {
        Some(earlier) -> deltas.os_rss(newest, earlier)
        None -> NotApplicable
      },
      derivation: model.Derived("the OS's account, not the VM's"),
    ),
  ])
}

// Scheduler utilisation between consecutive passes, oldest first: the change
// in active time over the change in total time, in parts per ten thousand.
// A pair where wall time was not collected, or did not advance, has no point.
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
            True -> Known(active * 10_000 / total)
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
    unit: unit.Ratio(per: 10_000),
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
/// failed census has none.
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
          reductions: Known(row.reductions),
          binary_refs: Missing(measure.UnsupportedOnRuntime),
          current: case row.current_function {
            "" -> None
            function -> Some(function)
          },
        )
      })
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

fn owners_feed(inputs: Inputs, newest: Observation) -> List(msg.Feed) {
  [msg.FedOwners(owners_page(inputs, newest))]
}

// The owners page for the newest census, with each group's heap capacity
// change since the chosen checkpoint when that checkpoint kept a census.
fn owners_page(inputs: Inputs, newest: Observation) -> model.OwnersModel {
  let word_size = word_size_of(newest, inputs)
  let rows = rows_of(newest, word_size)
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

  // The census lists only the top rows. What was scanned and not listed is
  // the remainder; the agent's per-owner aggregate carries memory and not
  // heap capacity, so the remainder's capacity is a word, not a figure.
  let left_out = case newest.census {
    Ok(census) -> census.coverage.scanned - list.length(census.rows)
    Error(_) -> 0
  }

  owners_builder.with_remainder(
    page,
    procs: int.max(0, left_out),
    heap_cap: Missing(measure.UnsupportedOnRuntime),
  )
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
  let completeness = case deltas.census_complete(earlier) {
    True -> deltas.BaselineComplete
    False -> deltas.BaselineTopRows
  }

  owners_builder.build(
    census_info(inputs, newest),
    rows,
    checkpoint_refs(inputs),
    option.map(chosen_mark(inputs), fn(pair) { pair.0 }),
    deltas.owner_heap(current, baseline_page, completeness),
  )
}

fn processes_feed(inputs: Inputs, newest: Observation) -> List(msg.Feed) {
  let all = rows_of(newest, word_size_of(newest, inputs))
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
        0,
      ),
      body: [],
    )
  }

  model.MemoryModel(
    categories: model.Panel(
      info: memory_info(inputs, newest),
      body: list.append(categories, [os_row]),
    ),
    allocators: unread("allocators"),
    tables: unread("ets tables"),
  )
}

// ----------------------------------------------------------------- probes

fn probes(inputs: Inputs, newest: Observation) -> model.ProbesModel {
  let rows = rows_of(newest, word_size_of(newest, inputs))
  let live_pins =
    list.filter(inputs.pins, fn(pin) { pin.status == seam.PinLive })
  let pending =
    list.find_map(inputs.plans, fn(entry) {
      case policy.plan_command(entry.1) {
        policy.StartProbe(spec:) ->
          Ok(model.PlanCard(
            key: plan_key(entry.0),
            kind: spec.kind,
            plan: entry.1,
            matched: NotApplicable,
            target_labels: list.map(spec.targets, fn(token) {
              identity.pin_to_string(token)
            }),
          ))
        _ -> Error(Nil)
      }
    })

  model.ProbesModel(
    info: info(
      inputs,
      "agent",
      "probe table",
      "probes",
      1,
      1,
      measure.Complete,
      0,
    ),
    targets: list.map(live_pins, fn(pin) {
      #(pin_key(pin.token), pin.pid_text <> label_for(rows, pin.pid_text))
    }),
    pending: option.from_result(pending),
    active: active_probes(inputs),
    history: probe_history(inputs),
    grants: inputs.page.grants,
  )
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
      0,
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
          | audit.DownloadServed(_) -> policy.Allowed
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
          profile_page.build(
            profile_header(inputs, probe, found),
            found,
            column,
            chain,
            inputs.exports,
          )
          |> result.map(Some)
      }
  }
}

// A counters profile is read by call time; any other by its first column,
// which for sampled stacks is the sample count. Core guarantees a profile has
// a value type, so the error is not reachable; it is handled as "nothing to
// draw" and not as a crash.
fn column_of(found: profile.Profile) -> Result(profile.Column, Nil) {
  result.lazy_or(profile.column_named(found, "call time"), fn() {
    profile.column(found, 0)
  })
}

fn profile_header(
  inputs: Inputs,
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
      "trace messages to a collector",
    )
    profile.AllocationCounts -> #("allocation counts", "allocator statistics")
  }

  model.ProfileHeader(
    title: "probe "
      <> probe.id
      <> case probe.modules {
      [] -> ""
      modules -> " · " <> string.join(modules, ", ")
    },
    source: profile.source(found),
    info: info(
      inputs,
      source,
      method,
      "functions",
      probe.matched,
      list.length(profile.samples(found)),
      case probe.state {
        probe_book.Finished(outcome:, ..) -> outcome
        probe_book.Running -> measure.Complete
      },
      case probe.state {
        probe_book.Finished(cost: capture.ProbeCost(wall_ms: Known(ms), ..), ..) ->
          ms
        _ -> 0
      },
    ),
    caveats: notes,
  )
}

// --------------------------------------------------------------- timeline

fn timeline_feed(
  inputs: Inputs,
  observations: List(Observation),
) -> List(msg.Feed) {
  case
    timeline_build.build(
      observations,
      inputs.marks,
      inputs.probes,
      inputs.cadence_ms,
      inputs.now_ms,
    )
  {
    Ok(page) -> [msg.FedTimeline(page)]
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
        0,
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
