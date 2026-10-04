//// Probes: plan, confirm, active and history.
////
//// A probe perturbs the node it measures, so none starts from one click. The
//// operator drafts a probe in the form; the viewer turns the draft into a
//// *plan*; and the page shows the plan in a dialog that states what it will
//// touch (the scope, revalidated against the live process), what it costs
//// (an event estimate, a byte bound, a wall time), how much it perturbs, and
//// what it does *not* prove, which is the line that stops a result being
//// read as more than it is. Only then does a Confirm button send a request,
//// and the viewer re-checks the plan: same principal, unexpired, unchanged.
////
//// The plan form and its buttons are drawn only for a principal holding the
//// capability the probe needs. Hiding is a courtesy; the handler's absence
//// is what makes it real, since a handler that is in the tree can be called
//// by anyone with the socket.
////
//// ## Reading order
////
//// `view` draws the form (`draft_form`), the pending plan (`plan_dialog`),
//// the running probes and the history.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/capture
import pickglass_core/measure
import pickglass_core/policy.{type Capability}
import pickglass_core/unit
import pickglass_web/fmt
import pickglass_web/key.{type Key}
import pickglass_web/model.{
  type PlanCard, type ProbeHistoryRow, type ProbesModel,
}
import pickglass_web/msg.{type Msg}
import pickglass_web/state.{type UiState}
import pickglass_web/view/ui
import pickglass_web/wire

/// How a plan's estimate is worded. Each kind of plan counts something
/// different: a counters probe tallies calls inside the VM and sends no
/// event, a stack probe takes samples, a tracing probe sends events to a
/// collector, and a collection or a self-measure is one action. Calling every
/// one of them "events" would put a number beside the wrong noun.
///
/// ## Examples
///
/// ```gleam
/// cost_text(policy.Counting, estimate, 30_000)
/// // -> "0 to 22,000 calls counted, no events sent · snapshot at most ..."
/// cost_text(policy.ForcedGc, estimate, 0)
/// // -> "one collection · about 50 ms · the process is stopped meanwhile"
/// ```
pub fn cost_text(
  level: policy.Perturbation,
  estimate: policy.Estimate,
  stops_after_ms: Int,
) -> String {
  let span =
    fmt.count(estimate.events_low) <> " to " <> fmt.count(estimate.events_high)
  let tail =
    " · "
    <> fmt.duration_ms(estimate.wall_ms)
    <> " · stops after "
    <> fmt.duration_ms(stops_after_ms)

  case level {
    policy.Counting ->
      span
      <> " calls counted, no events sent · snapshot at most "
      <> fmt.bytes(estimate.bytes_high)
      <> tail
    policy.ForcedGc ->
      "one collection · about "
      <> fmt.duration_ms(estimate.wall_ms)
      <> " · the process is stopped meanwhile"
    policy.Polling ->
      case estimate.events_high > 1 {
        True ->
          "up to "
          <> fmt.count(estimate.events_high)
          <> " samples · at most "
          <> fmt.bytes(estimate.bytes_high)
          <> tail
        False ->
          "one request · waits at most " <> fmt.duration_ms(estimate.wall_ms)
      }
    policy.Passive | policy.Tracing ->
      span <> " events · at most " <> fmt.bytes(estimate.bytes_high) <> tail
  }
}

/// The title of a probe kind.
pub fn kind_title(kind: policy.ProbeKind) -> String {
  case kind {
    policy.Counters -> "Trace counters"
    policy.Sampling -> "Sample stacks"
    policy.CallTree -> "Trace call tree"
    policy.SchedulingGc -> "Scheduling and GC events"
  }
}

fn kind_action(kind: policy.ProbeKind) -> String {
  case kind {
    policy.Counters ->
      "Counts calls and measures call time for the matched functions in the "
      <> "targets, in a trace session of its own. No trace message is sent; "
      <> "the VM keeps the counters and one snapshot is read at the end."
    policy.Sampling ->
      "Reads the current stack of each target at a fixed rate and merges "
      <> "the stacks into a profile."
    policy.CallTree ->
      "Traces calls and returns to the caller of the named modules' "
      <> "functions in the targets, and folds them as they arrive into a "
      <> "call tree with exact call counts and times. Nothing is kept per "
      <> "event; the probe stops at its event budget."
    policy.SchedulingGc ->
      "Records when each target runs on a scheduler and when it collects "
      <> "garbage, as slices on a timeline with per-process totals, and "
      <> "reports any collection or timeslice on the node longer than the "
      <> "thresholds."
  }
}

fn what_title(what: model.PlanWhat) -> String {
  case what {
    model.ProbePlan(kind:) -> kind_title(kind)
    model.GcPlan -> "Collect garbage in one process"
    model.MeasurePlan -> "Ask one process to measure itself"
  }
}

fn what_action(what: model.PlanWhat) -> String {
  case what {
    model.ProbePlan(kind:) -> kind_action(kind)
    model.GcPlan ->
      "Runs a full garbage collection of the pinned process. The process "
      <> "stops while it collects; its heap is read before and after."
    model.MeasurePlan ->
      "Sends the pinned process a request to measure a term it holds and "
      <> "waits for its answer. Only a process that advertises the "
      <> "capability is asked."
  }
}

fn what_does_not_prove(what: model.PlanWhat) -> String {
  case what {
    model.ProbePlan(kind:) -> does_not_prove(kind)
    model.GcPlan ->
      "That the memory was needed: a collection frees what is garbage now, "
      <> "and the process may fill its heap again at once."
    model.MeasurePlan ->
      "That the reading is complete: the process reports what it chooses to "
      <> "and the viewer does not check it against its heap."
  }
}

fn does_not_prove(kind: policy.ProbeKind) -> String {
  case kind {
    policy.Counters ->
      "That callees that were not traced are cheap: their time is charged "
      <> "to the traced caller. That the workload is unaffected."
    policy.Sampling ->
      "That time was spent where samples landed: long BIFs and NIFs are "
      <> "under-sampled. Width is a share of samples, not of time."
    policy.CallTree ->
      "That untraced callees are cheap: their time counts as the caller's. "
      <> "That the window was complete: calls to modules reloaded during it "
      <> "are lost, and a target that calls faster than the collector folds "
      <> "stops the probe early."
    policy.SchedulingGc ->
      "That time on a scheduler is CPU time: it includes any time the "
      <> "operating system took the scheduler thread away. That every "
      <> "threshold event was kept: the agent keeps the first 200."
  }
}

/// What a perturbation class means for the target, in one phrase.
pub fn perturbation_text(level: policy.Perturbation) -> String {
  case level {
    policy.Passive -> "none: reads only"
    policy.Polling -> "light: periodic reads of process information"
    policy.Counting ->
      "light: the VM counts calls and call time in the matched functions; "
      <> "no trace message is sent"
    policy.Tracing ->
      "moderate: every traced event is sent to a collector process, and "
      <> "a target that calls very fast stops the probe early"
    policy.ForcedGc -> "intrusive: the process is stopped for the collection"
  }
}

fn capability_name(grant: Capability) -> String {
  case grant {
    policy.Observe -> "observe"
    policy.Summarize -> "summarize"
    policy.Profile -> "profile"
    policy.Perturb -> "perturb"
    policy.Export -> "export"
    policy.Administer -> "administer"
  }
}

/// Draw the probes page.
pub fn view(data: ProbesModel, ui_state: UiState) -> Element(Msg) {
  let form = case list.contains(data.grants, policy.Profile) {
    True -> [draft_form(data, ui_state)]
    False -> [
      ui.plain_panel(title: "Plan a probe", body: [
        ui.note(
          "This principal does not hold the profile capability, so no probe "
          <> "can be planned.",
        ),
      ]),
    ]
  }

  let pending = case data.pending {
    Some(card) -> [plan_dialog(card, ui_state.plan.modules)]
    None -> []
  }

  html.div(
    [attribute.class("stack")],
    list.flatten([
      form,
      pending,
      [active_panel(data), history_panel(data)],
      refused_panel(data),
    ]),
  )
}

fn draft_form(data: ProbesModel, ui_state: UiState) -> Element(Msg) {
  let draft = ui_state.plan

  ui.plain_panel(title: "Plan a probe", body: [
    html.div([attribute.class("form-grid")], [
      field("Kind", [
        html.select(
          [
            wire.code_chosen(msg.parse_probe, policy.Counters, fn(kind) {
              msg.Ui(msg.DraftKind(kind))
            }),
          ],
          list.map(
            [
              policy.Counters,
              policy.Sampling,
              policy.CallTree,
              policy.SchedulingGc,
            ],
            fn(kind) {
              html.option(
                [
                  attribute.value(msg.probe_code(kind)),
                  attribute.selected(kind == draft.kind),
                ],
                kind_title(kind),
              )
            },
          ),
        ),
      ]),
      field("Target", [
        html.select(
          [wire.key_chosen(fn(target) { msg.Ui(msg.DraftTarget(target)) })],
          list.map(data.targets, fn(target) {
            html.option(
              [
                attribute.value(key.to_string(target.0)),
                attribute.selected(Some(target.0) == draft.target),
              ],
              target.1,
            )
          }),
        ),
      ]),
      modules_field(draft),
      field("Duration", [
        html.select(
          [
            wire.code_chosen(msg.parse_duration, msg.Seconds30, fn(choice) {
              msg.Ui(msg.DraftDuration(choice))
            }),
          ],
          list.map(msg.durations_for(draft.kind), fn(choice) {
            html.option(
              [
                attribute.value(msg.duration_code(choice)),
                attribute.selected(choice == draft.duration),
              ],
              fmt.duration_ms(msg.duration_ms(choice)),
            )
          }),
        ),
      ]),
    ]),
    html.div([attribute.class("form-actions")], [
      html.button(
        [
          attribute.class("btn btn-primary"),
          attribute.type_("button"),
          wire.click(msg.Ui(msg.SubmitDraft)),
        ],
        [element.text("Plan probe…")],
      ),
      notice(ui_state.notice),
    ]),
    ui.note(
      "Planning does not start anything. The plan below states what it "
      <> "would do and must be confirmed.",
    ),
  ])
}

// A stack or events probe names no modules, so its form has no field for
// them; a counters or call tree probe names the modules it traces.
fn modules_field(draft: state.PlanDraft) -> Element(Msg) {
  case policy.needs_modules(draft.kind) {
    False -> element.none()
    True ->
      field("Module patterns", [
        html.input([
          attribute.class("text mono"),
          attribute.type_("text"),
          attribute.placeholder("loom@runtime@keeper  lists"),
          attribute.value(draft.modules),
          wire.text_entered(fn(text) { msg.Ui(msg.DraftModules(text)) }),
        ]),
      ])
  }
}

fn field(label: String, controls: List(Element(Msg))) -> Element(Msg) {
  html.label([attribute.class("field")], [
    html.span([attribute.class("field-label")], [element.text(label)]),
    ..controls
  ])
}

fn notice(text: Option(String)) -> Element(Msg) {
  case text {
    Some(sentence) ->
      html.span([attribute.class("notice"), attribute.role("status")], [
        element.text(sentence),
      ])
    None -> element.none()
  }
}

/// Draw a pending plan as a dialog: what it will touch, what it costs, what
/// it perturbs and what it does not prove, with Cancel and Confirm. A plan a
/// profile button made also says how its processes were chosen and offers the
/// duration and rate as buttons that plan again. The Probes page and the
/// one-click flow draw the same dialog, so a plan reads the same wherever it
/// is confirmed.
///
/// `modules` is the module pattern text the operator has typed in the plan
/// form, which a stack profile's "trace calls instead" control sends.
///
/// ## Examples
///
/// ```gleam
/// probes.plan_dialog(card, "")
/// ```
pub fn plan_dialog(card: PlanCard, modules: String) -> Element(Msg) {
  let scope = policy.plan_scope(card.plan)
  let estimate = policy.plan_estimate(card.plan)
  let needs =
    policy.required_capabilities(policy.plan_command(card.plan))
    |> list.map(capability_name)

  html.section(
    [
      attribute.class("panel dialog"),
      attribute.role("dialog"),
      attribute.aria("label", "Probe plan"),
    ],
    [
      html.header([attribute.class("panel-bar")], [
        html.h2([], [element.text("Plan: " <> what_title(card.what))]),
        html.span([attribute.class("chip")], [
          element.text("needs " <> list.fold(needs, "", join_words)),
        ]),
      ]),
      html.dl(
        [attribute.class("kv wide")],
        list.flatten([
          scope_rows(card, scope),
          sampling_rows(card),
          trace_rows(card),
          [
            html.dt([], [element.text("Action")]),
            html.dd([], [element.text(what_action(card.what))]),
            html.dt([], [element.text("Cost")]),
            html.dd([attribute.class("num")], [
              element.text(cost_text(
                policy.plan_perturbation(card.plan),
                estimate,
                scope.duration_ms,
              )),
            ]),
            html.dt([], [element.text("Perturbation")]),
            html.dd([], [
              element.text(
                perturbation_text(policy.plan_perturbation(card.plan)),
              ),
            ]),
            html.dt([], [element.text("Does not prove")]),
            html.dd([attribute.class("does-not-prove")], [
              element.text(what_does_not_prove(card.what)),
            ]),
          ],
        ]),
      ),
      adjust_controls(card, modules),
      html.div([attribute.class("dialog-actions")], [
        html.button(
          [
            attribute.class("btn"),
            attribute.type_("button"),
            wire.click(msg.Ask(msg.CancelPlan(card.key))),
          ],
          [element.text("Cancel")],
        ),
        html.button(
          [
            attribute.class("btn btn-primary"),
            attribute.type_("button"),
            wire.click(msg.Ask(msg.ConfirmPlan(card.key))),
          ],
          [element.text("Confirm and run")],
        ),
      ]),
    ],
  )
}

// The scope of a plan: the processes it names, how they were chosen when a
// profile button chose them, and the modules and matches of a trace probe. A
// stack probe has no modules, so it does not print an empty list of them.
fn scope_rows(card: PlanCard, scope: policy.PlanScope) -> List(Element(Msg)) {
  let processes =
    int.to_string(list.length(scope.targets))
    <> " process(es) revalidated: "
    <> list.fold(card.target_labels, "", join_words)

  let chosen = case card.chosen {
    "" -> []
    text -> [
      html.dt([], [element.text("Chosen")]),
      html.dd([], [element.text(text)]),
    ]
  }

  let modules = case card.what {
    model.ProbePlan(kind: policy.Sampling)
    | model.ProbePlan(kind: policy.SchedulingGc) -> ""

    // A collection or a self-measure acts on the processes only; it names no
    // module and matches no function.
    model.GcPlan | model.MeasurePlan -> ""
    model.ProbePlan(..) ->
      " · modules "
      <> list.fold(scope.modules, "", join_words)
      <> " · "
      <> matched_text(card.matched)
  }

  list.append(chosen, [
    html.dt([], [element.text("Scope")]),
    html.dd([], [element.text(processes <> modules)]),
  ])
}

// What a stack probe will run, stated apart from the cost line so the rate
// the agent will really use, and the budget of samples it may take, are
// each a figure the operator can find: the rate asked, the rate after the
// agent shares its ceiling between the processes, the duration, and the most
// samples the run can hold.
fn sampling_rows(card: PlanCard) -> List(Element(Msg)) {
  case policy.plan_command(card.plan) {
    policy.StartProbe(spec: policy.ProbeSpec(kind: policy.Sampling, ..) as spec) -> {
      let targets = list.length(spec.targets)
      let effective = policy.sampling_rate_hz(spec.rate_hz, targets)
      let estimate = policy.plan_estimate(card.plan)

      [
        html.dt([], [element.text("Rate")]),
        html.dd([attribute.class("num")], [
          element.text(case effective == spec.rate_hz {
            True -> int.to_string(effective) <> " Hz per process"
            False ->
              int.to_string(effective)
              <> " Hz per process ("
              <> int.to_string(spec.rate_hz)
              <> " Hz asked; the agent shares "
              <> fmt.count(policy.max_total_sampling_hz)
              <> " samples a second between "
              <> int.to_string(targets)
              <> " processes)"
          }),
        ]),
        html.dt([], [element.text("Duration")]),
        html.dd([attribute.class("num")], [
          element.text(fmt.duration_ms(spec.duration_ms)),
        ]),
        html.dt([], [element.text("Sample budget")]),
        html.dd([attribute.class("num")], [
          element.text(
            "at most "
            <> fmt.count(estimate.events_high)
            <> " samples ("
            <> int.to_string(effective)
            <> " Hz × "
            <> int.to_string(targets)
            <> " processes × "
            <> fmt.duration_ms(spec.duration_ms)
            <> ")",
          ),
        ]),
      ]
    }
    _ -> []
  }
}

// What a tracing probe will run, stated apart from the cost line: its window,
// the budget of events it folds before it stops itself, and for an events
// probe the thresholds it sets on the whole node.
fn trace_rows(card: PlanCard) -> List(Element(Msg)) {
  case policy.plan_command(card.plan) {
    policy.StartProbe(spec: policy.ProbeSpec(kind: policy.CallTree, ..) as spec) -> [
      html.dt([], [element.text("Window")]),
      html.dd([attribute.class("num")], [
        element.text(fmt.duration_ms(spec.duration_ms)),
      ]),
      html.dt([], [element.text("Event budget")]),
      html.dd([attribute.class("num")], [
        element.text(
          "stops after "
          <> fmt.count(policy.trace_event_budget)
          <> " call and return events, or when the collector falls behind",
        ),
      ]),
    ]
    policy.StartProbe(
      spec: policy.ProbeSpec(kind: policy.SchedulingGc, ..) as spec,
    ) -> [
      html.dt([], [element.text("Window")]),
      html.dd([attribute.class("num")], [
        element.text(fmt.duration_ms(spec.duration_ms)),
      ]),
      html.dt([], [element.text("Event budget")]),
      html.dd([attribute.class("num")], [
        element.text(
          "stops after "
          <> fmt.count(policy.trace_event_budget)
          <> " scheduling and collection events; up to "
          <> fmt.count(policy.timeline_slice_limit)
          <> " slices are kept for the timeline",
        ),
      ]),
      html.dt([], [element.text("Node-wide thresholds")]),
      html.dd([attribute.class("num")], [
        element.text(
          "collections of "
          <> int.to_string(policy.long_gc_ms)
          <> " ms or more and timeslices of "
          <> int.to_string(policy.long_schedule_ms)
          <> " ms or more, of any process on the node; on a node older than "
          <> "OTP 28 the probe runs without them",
        ),
      ]),
    ]
    _ -> []
  }
}

// The controls of a plan a profile button made, as buttons. Each is a fixed
// request to plan the same processes again, so nothing the browser sends names
// a duration or a rate; the current choices are marked. A stack profile of few
// enough processes also offers the call trace, which needs the modules to
// trace: the field takes them and the button sends them as a request the
// viewer checks again.
fn adjust_controls(card: PlanCard, modules: String) -> Element(Msg) {
  case card.adjust {
    model.NotAdjustable -> element.none()
    model.AdjustStacks(duration_ms:, rate_hz:, processes:) ->
      html.div([attribute.class("dialog-adjust")], [
        html.span([attribute.class("field-label")], [element.text("Duration")]),
        ..list.flatten([
          list.map([msg.Seconds10, msg.Seconds30, msg.Seconds60], fn(choice) {
            adjust_button(
              int.to_string(msg.duration_ms(choice) / 1000) <> " s",
              choice_of(duration_ms, msg.duration_ms(choice)),
              msg.AdjustProfile(card.key, choice, rate_or(rate_hz)),
            )
          }),
          [
            html.span([attribute.class("field-label")], [element.text("Rate")]),
            ..list.map([msg.Hz50, msg.Hz100, msg.Hz250], fn(choice) {
              adjust_button(
                int.to_string(msg.rate_hz(choice)) <> " Hz",
                choice_of(rate_hz, msg.rate_hz(choice)),
                msg.AdjustProfile(card.key, duration_or(duration_ms), choice),
              )
            })
          ],
          trace_instead(card.key, processes, modules),
        ])
      ])
    model.AdjustCalls(processes: _, duration_ms: _) ->
      html.div([attribute.class("dialog-adjust")], [
        adjust_button(
          "Sample stacks instead",
          Offered,
          msg.SampleStacksInstead(card.key),
        ),
      ])
  }
}

fn trace_instead(
  plan: Key,
  processes: Int,
  modules: String,
) -> List(Element(Msg)) {
  case processes <= policy.target_limit(policy.CallTree) {
    False -> []
    True -> [
      html.span([attribute.class("field-label")], [
        element.text("Or trace calls of"),
      ]),
      html.input([
        attribute.class("text mono"),
        attribute.type_("text"),
        attribute.placeholder("loom@runtime@keeper"),
        attribute.value(modules),
        attribute.aria("label", "Modules to trace"),
        wire.text_entered(fn(text) { msg.Ui(msg.DraftModules(text)) }),
      ]),
      html.button(
        [
          attribute.class("btn btn-small"),
          attribute.type_("button"),
          attribute.data("test-id", "trace-calls-instead"),
          wire.click(msg.Ui(msg.SubmitTraceInstead(plan))),
        ],
        [element.text("Trace calls instead")],
      ),
    ]
  }
}

// The choice in force, or the default when the plan's own value is not one
// of the closed choices.
fn rate_or(hz: Int) -> msg.RateChoice {
  case msg.rate_choice(hz) {
    Ok(choice) -> choice
    Error(Nil) -> msg.Hz100
  }
}

fn duration_or(ms: Int) -> msg.DurationChoice {
  case msg.duration_choice(ms) {
    Ok(choice) -> choice
    Error(Nil) -> msg.Seconds10
  }
}

// Whether a button names the choice the plan already has.
type Choice {
  InForce
  Offered
}

fn choice_of(current: Int, mine: Int) -> Choice {
  case current == mine {
    True -> InForce
    False -> Offered
  }
}

fn adjust_button(
  label: String,
  choice: Choice,
  request: msg.Request,
) -> Element(Msg) {
  let class = case choice {
    InForce -> "btn btn-small btn-current"
    Offered -> "btn btn-small"
  }

  html.button(
    [
      attribute.class(class),
      attribute.type_("button"),
      attribute.aria("pressed", case choice {
        InForce -> "true"
        Offered -> "false"
      }),
      wire.click(msg.Ask(request)),
    ],
    [element.text(label)],
  )
}

// What the scope says about matched functions. The agent matches them when
// the probe starts, so a plan has no count to show, and a bare "n/a" beside
// a noun reads as a failed reading.
fn matched_text(matched: measure.Measurement) -> String {
  case matched {
    measure.Known(count) ->
      fmt.count(count) <> " functions matched by the agent"
    measure.Missing(_) | measure.NotApplicable ->
      "functions are matched when the probe starts"
  }
}

fn join_words(acc: String, word: String) -> String {
  case acc {
    "" -> word
    _ -> acc <> ", " <> word
  }
}

fn active_panel(data: ProbesModel) -> Element(Msg) {
  ui.panel(title: "Running", info: data.info, controls: [], body: [
    case data.active {
      [] -> ui.note("No probe is running.")
      probes ->
        html.table([attribute.class("tbl")], [
          html.thead([], [
            html.tr([], [
              ui.th("probe", None),
              ui.th_num("time remaining", None),
              ui.th("", None),
            ]),
          ]),
          html.tbody(
            [],
            list.map(probes, fn(probe) {
              html.tr([], [
                html.td([], [element.text(kind_title(probe.kind))]),
                ms_cell(probe.remaining_ms),
                html.td([], [stop_button(probe.key, data.grants)]),
              ])
            }),
          ),
        ])
    },
  ])
}

// A duration in milliseconds is written as a duration; an absent one is a
// word, as in every other cell.
fn ms_cell(m: measure.Measurement) -> Element(Msg) {
  case m {
    measure.Known(value:) ->
      html.td([attribute.class("num")], [element.text(fmt.duration_ms(value))])
    absent -> ui.num(absent, unit.Count)
  }
}

fn stop_button(probe: Key, grants: List(Capability)) -> Element(Msg) {
  case list.contains(grants, policy.Profile) {
    True ->
      html.button(
        [
          attribute.class("btn btn-small"),
          attribute.type_("button"),
          wire.click(msg.Ask(msg.StopProbe(probe))),
        ],
        [element.text("Stop")],
      )
    False -> element.none()
  }
}

fn history_panel(data: ProbesModel) -> Element(Msg) {
  ui.panel(title: "History", info: data.info, controls: [], body: [
    html.table([attribute.class("tbl")], [
      html.thead([], [
        html.tr([], [
          ui.th("probe", None),
          ui.th("outcome", None),
          ui.th_num(
            "events",
            Some(
              "trace messages the collector received; a counters probe sends none",
            ),
          ),
          ui.th_num(
            "collector reductions",
            Some("work done by the collector, not CPU time"),
          ),
          ui.th_num("bytes", None),
          ui.th_num("wall", None),
        ]),
      ]),
      html.tbody([], list.map(data.history, history_row)),
    ]),
  ])
}

// The probes the agent refused when they started. They never got an id, so
// they are not rows of the history table above, but the operator who
// confirmed one is owed the reason.
fn refused_panel(data: ProbesModel) -> List(Element(Msg)) {
  case data.refused {
    [] -> []
    sentences -> [
      ui.plain_panel(title: "Refused at start", body: [
        html.ul(
          [attribute.data("test-id", "refused-starts")],
          list.map(sentences, fn(sentence) {
            html.li([], [element.text(sentence)])
          }),
        ),
      ]),
    ]
  }
}

fn history_row(row: ProbeHistoryRow) -> Element(Msg) {
  let cost: capture.ProbeCost = row.cost

  html.tr([], [
    html.td([], [element.text(kind_title(row.kind))]),
    html.td([], [outcome_badge(row.outcome)]),
    ui.num(cost.events, unit.Count),
    ui.num(cost.collector_reductions, unit.Reductions),
    ui.num(cost.bytes, unit.Bytes),
    ms_cell(cost.wall_ms),
  ])
}

fn outcome_badge(outcome: measure.Outcome) -> Element(Msg) {
  case outcome {
    measure.Complete -> ui.badge("ok", "complete")
    other -> ui.badge("warn", ui.truncation_text(other))
  }
}
