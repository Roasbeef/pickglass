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
      "Counts calls and measures call time and memory for the matched "
      <> "functions in the targets, in a trace session of its own."
    policy.Sampling ->
      "Reads the current stack of each target at a fixed rate and merges "
      <> "the stacks into a profile."
    policy.CallTree ->
      "Records call and return events in the targets and builds a call "
      <> "tree from them."
    policy.SchedulingGc ->
      "Records scheduling and garbage-collection events for the targets."
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
      "That the call tree is complete: calls to modules reloaded during the "
      <> "probe are lost."
    policy.SchedulingGc ->
      "That events dropped under the budget did not matter; each gap is "
      <> "reported where it happened."
  }
}

fn perturbation_text(level: policy.Perturbation) -> String {
  case level {
    policy.Passive -> "none: reads only"
    policy.Polling -> "light: periodic reads of process information"
    policy.Tracing -> "moderate: every traced call emits an event"
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
    Some(card) -> [plan_dialog(card)]
    None -> []
  }

  html.div(
    [attribute.class("stack")],
    list.flatten([
      form,
      pending,
      [active_panel(data), history_panel(data)],
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
      field("Module patterns", [
        html.input([
          attribute.class("text mono"),
          attribute.type_("text"),
          attribute.placeholder("loom@runtime@keeper  loom@*"),
          attribute.value(draft.modules),
          wire.text_entered(fn(text) { msg.Ui(msg.DraftModules(text)) }),
        ]),
      ]),
      field("Duration", [
        html.select(
          [
            wire.code_chosen(msg.parse_duration, msg.Seconds30, fn(choice) {
              msg.Ui(msg.DraftDuration(choice))
            }),
          ],
          list.map(
            [msg.Seconds10, msg.Seconds30, msg.Seconds60, msg.Seconds300],
            fn(choice) {
              html.option(
                [
                  attribute.value(msg.duration_code(choice)),
                  attribute.selected(choice == draft.duration),
                ],
                fmt.duration_ms(msg.duration_ms(choice)),
              )
            },
          ),
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

fn plan_dialog(card: PlanCard) -> Element(Msg) {
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
        html.h2([], [element.text("Plan: " <> kind_title(card.kind))]),
        html.span([attribute.class("chip")], [
          element.text("needs " <> list.fold(needs, "", join_words)),
        ]),
      ]),
      html.dl([attribute.class("kv wide")], [
        html.dt([], [element.text("Scope")]),
        html.dd([], [
          element.text(
            list.fold(card.target_labels, "", join_words)
            <> " · "
            <> int.to_string(list.length(scope.targets))
            <> " target(s) revalidated · modules "
            <> list.fold(scope.modules, "", join_words)
            <> " · "
            <> fmt.cell(card.matched, unit.Count)
            <> " functions matched by the agent",
          ),
        ]),
        html.dt([], [element.text("Action")]),
        html.dd([], [element.text(kind_action(card.kind))]),
        html.dt([], [element.text("Cost")]),
        html.dd([attribute.class("num")], [
          element.text(
            fmt.count(estimate.events_low)
            <> " to "
            <> fmt.count(estimate.events_high)
            <> " events · at most "
            <> fmt.bytes(estimate.bytes_high)
            <> " · "
            <> fmt.duration_ms(estimate.wall_ms)
            <> " · stops after "
            <> fmt.duration_ms(scope.duration_ms),
          ),
        ]),
        html.dt([], [element.text("Perturbation")]),
        html.dd([], [
          element.text(perturbation_text(policy.plan_perturbation(card.plan))),
        ]),
        html.dt([], [element.text("Does not prove")]),
        html.dd([attribute.class("does-not-prove")], [
          element.text(does_not_prove(card.kind)),
        ]),
      ]),
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
          ui.th_num("events", None),
          ui.th_num("collector reductions", None),
          ui.th_num("bytes", None),
          ui.th_num("wall", None),
        ]),
      ]),
      html.tbody([], list.map(data.history, history_row)),
    ]),
  ])
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
