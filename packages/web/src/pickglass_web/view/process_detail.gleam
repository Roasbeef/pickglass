//// One process.
////
//// The page separates two kinds of fact that tools often blur. *Ownership*
//// is the join of declared labels, provider claims, registry names and
//// supervision, with the winning source and any dissenting claims shown.
//// *Evidence* is what links, monitors and the supervisor edge say; it is
//// listed with its source and is explicitly not ownership, because a link
//// proves two processes are connected, not that one belongs to the other.
////
//// If the process replaced an earlier one under the same owner and role, as
//// a restarted keeper does, the page shows that lineage, so a drop in memory
//// after a restart reads as a restart and not as a leak fixed.
////
//// Buttons here only send requests. A button appears only when the page's
//// principal holds the capability the action needs, because every handler in
//// the tree is callable by anyone holding the socket and an offered button
//// is an attached handler. The viewer still checks the request.
////
//// The page never shows or fetches a mailbox, a process dictionary or a
//// state, and says so.
////
//// ## Reading order
////
//// `view` draws the header with its actions, the ownership and evidence
//// panels, the counters, and the histories.

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/policy.{type Capability}
import pickglass_web/chart/spark
import pickglass_web/fmt
import pickglass_web/model.{type Counter, type Evidence, type ProcessDetailModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links}
import pickglass_web/view/ui
import pickglass_web/wire

/// Draw the process detail page for a principal holding `grants`. `modules`
/// is the module pattern text the operator has typed in the plan form, which
/// the call trace button sends.
pub fn view(
  data: ProcessDetailModel,
  grants: List(Capability),
  links: Links,
  modules: String,
) -> Element(Msg) {
  html.div([attribute.class("stack")], [
    header(data, grants, modules),
    html.div([attribute.class("grid two")], [
      ownership_panel(data, links),
      evidence_panel(data),
    ]),
    ui.panel(title: "Counters", info: data.info, controls: [], body: [
      html.div([attribute.class("grid two")], [
        counter_list("Memory and queue", data.counters),
        counter_list("Garbage collection", data.gc),
      ]),
      ui.note(
        "Not shown by design: mailbox contents, process dictionary, state.",
      ),
    ]),
    history_panel(data),
  ])
}

fn header(
  data: ProcessDetailModel,
  grants: List(Capability),
  modules: String,
) -> Element(Msg) {
  let life = case data.liveness {
    model.Alive -> ui.badge("ok", "alive")
    model.Exited(at:) -> ui.badge("warn", "exited " <> at)
  }

  let pin = case data.pin {
    model.Pinned(_) -> ui.badge("pin", "pinned")
    model.NotPinned -> ui.badge("muted", "not pinned")
  }

  html.section([attribute.class("panel detail-head")], [
    html.div([attribute.class("detail-title")], [
      html.h2([attribute.class("mono")], [element.text(data.pid_text)]),
      html.span([attribute.class("muted")], [
        element.text(data.birth),
      ]),
      life,
      pin,
    ]),
    html.div([attribute.class("actions")], actions(data, grants, modules)),
  ])
}

// Each action is offered only when the principal holds the capability it
// needs, and the pin-bound ones only once the process is pinned.
fn actions(
  data: ProcessDetailModel,
  grants: List(Capability),
  modules: String,
) -> List(Element(Msg)) {
  let pin_button = case data.pin {
    model.NotPinned -> button("Pin", "btn", msg.Ask(msg.RequestPin(data.key)))
    model.Pinned(pin:) -> button("Unpin", "btn", msg.Ask(msg.RequestUnpin(pin)))
  }

  let gc = case data.pin, list.contains(grants, policy.Perturb) {
    model.Pinned(pin:), True -> [
      button("Plan targeted GC…", "btn btn-warn", msg.Ask(msg.PlanGc(pin))),
    ]
    _, _ -> []
  }

  let summary = case
    data.pin,
    data.self_measure,
    list.contains(grants, policy.Summarize)
  {
    model.Pinned(pin:), model.Available, True -> [
      button("Self-measure", "btn", msg.Ask(msg.RequestSelfMeasure(pin))),
    ]
    _, _, _ -> []
  }

  // A probe is planned from the Probes page, so this only carries the
  // process there; it plans nothing and needs the capability to plan one.
  let probe = case list.contains(grants, policy.Profile) {
    True -> [
      button("Plan probe…", "btn", msg.Ask(msg.PlanProbeFor(data.key))),
    ]
    False -> []
  }

  // A profile pins the process when it is not pinned and plans one stack
  // probe over it, so it is the short way to what "Plan probe" reaches in
  // several steps. It still ends in a plan that waits for Confirm.
  let profile = [
    ui.profile_button(
      grants,
      "Profile this process",
      "Plan a stack probe of this process, pinning it first if needed",
      msg.ProfileProcess(data.key),
    ),
  ]

  [
    pin_button,
    ..list.flatten([profile, tracing(data, grants, modules), probe, gc, summary])
  ]
}

// The two probes that watch one process more closely than a stack profile.
// Each pins the process when it is not pinned and ends in a plan that waits
// for Confirm. A recording needs nothing more; a call trace names the modules
// whose functions to trace, because the agent will not trace every function of
// a node, so it has a field for them.
fn tracing(
  data: ProcessDetailModel,
  grants: List(Capability),
  modules: String,
) -> List(Element(Msg)) {
  case list.contains(grants, policy.Profile) {
    False -> []
    True -> [
      button("Record scheduling…", "btn", msg.Ask(msg.RecordProcess(data.key))),
      html.span([attribute.class("inline-form")], [
        html.input([
          attribute.class("text mono"),
          attribute.type_("text"),
          attribute.placeholder("modules to trace, such as loom@runtime@keeper"),
          attribute.aria("label", "Modules to trace"),
          attribute.value(modules),
          wire.text_entered(fn(text) { msg.Ui(msg.DraftModules(text)) }),
        ]),
        button("Trace calls…", "btn", msg.Ui(msg.SubmitTraceProcess(data.key))),
      ]),
    ]
  }
}

fn button(label: String, class: String, message: Msg) -> Element(Msg) {
  html.button(
    [
      attribute.class(class),
      attribute.type_("button"),
      wire.click(message),
    ],
    [element.text(label)],
  )
}

fn ownership_panel(data: ProcessDetailModel, links: Links) -> Element(Msg) {
  ui.plain_panel(title: "Ownership", body: [
    ownership_body(data.attribution),
    owner_link(data.attribution, links),
    lineage(data.successor),
  ])
}

// The way back to the group this process belongs to. It is a plain link to
// the Owners page, where the group is one row, so nothing in the address is
// built from the owner's name.
fn owner_link(attribution: owner.Attribution, links: Links) -> Element(Msg) {
  let text = case attribution {
    owner.Attributed(winner:, ..) ->
      "All processes of " <> owner.path_to_string(winner.path) <> " on Owners"
    owner.Unattributed -> "The unknown group on Owners"
  }

  html.p([attribute.class("owner-back")], [
    html.a([attribute.href(page.href(links, page.Owners))], [
      element.text(text),
    ]),
  ])
}

fn ownership_body(attribution: owner.Attribution) -> Element(Msg) {
  case attribution {
    owner.Unattributed ->
      html.p([], [
        ui.badge("source source-none", "unknown"),
        element.text(" No claim names an owner for this process."),
      ])
    owner.Attributed(winner:, dissent:) ->
      html.div([], [
        html.p([attribute.class("owner-line")], [
          html.span([attribute.class("owner-path")], [
            element.text(
              owner.path_to_string(winner.path) <> " / " <> winner.role,
            ),
          ]),
          ui.badge("source", owner.source_code(winner.source)),
          ui.badge("muted", owner.confidence_code(winner.confidence)),
        ]),
        dissent_list(dissent),
      ])
  }
}

fn dissent_list(dissent: List(owner.Claim)) -> Element(Msg) {
  case dissent {
    [] -> element.none()
    claims ->
      html.div([attribute.class("dissent")], [
        html.p([attribute.class("muted")], [
          element.text("Weaker claims that disagree:"),
        ]),
        html.ul(
          [],
          list.map(claims, fn(claim) {
            html.li([], [
              element.text(
                owner.path_to_string(claim.path)
                <> " / "
                <> claim.role
                <> " ("
                <> owner.source_code(claim.source)
                <> ")",
              ),
            ])
          }),
        ),
      ])
  }
}

fn lineage(successor: Option(model.Successor)) -> Element(Msg) {
  case successor {
    None -> element.none()
    Some(previous) ->
      html.p([attribute.class("lineage")], [
        html.strong([], [element.text("Successor of ")]),
        element.text(
          "birth seq "
          <> previous.predecessor
          <> ", exited "
          <> previous.exited
          <> ", under the same owner and role.",
        ),
      ])
  }
}

fn evidence_panel(data: ProcessDetailModel) -> Element(Msg) {
  ui.plain_panel(title: "Evidence, not ownership", body: [
    case data.evidence {
      [] -> ui.note("No links, monitors or supervisor edge were read.")
      edges ->
        html.table([attribute.class("tbl compact")], [
          html.tbody([], list.map(edges, evidence_row)),
        ])
    },
    ui.note(
      "A link or monitor shows that two processes are connected. It does not "
      <> "show that one belongs to the other.",
    ),
  ])
}

fn evidence_row(edge: Evidence) -> Element(Msg) {
  html.tr([], [
    html.td([attribute.class("muted")], [element.text(edge.kind)]),
    html.td([attribute.class("mono")], [element.text(edge.target)]),
    html.td([], [ui.badge("source", owner.source_code(edge.source))]),
  ])
}

fn counter_list(title: String, counters: List(Counter)) -> Element(Msg) {
  html.div([], [
    html.h3([], [element.text(title)]),
    html.dl(
      [attribute.class("kv")],
      list.flat_map(counters, fn(counter) {
        let value_class = case counter.value, counter.inapplicable {
          measure.NotApplicable, word if word != "" -> "num"
          _, _ ->
            case fmt.is_word(counter.value) {
              fmt.Number -> "num"
              fmt.Word -> "num word"
            }
        }

        [
          html.dt([], [element.text(counter.label)]),
          html.dd([attribute.class(value_class)], [
            element.text(case counter.value, counter.inapplicable {
              measure.NotApplicable, word if word != "" -> word
              _, _ -> fmt.cell(counter.value, counter.unit)
            }),
          ]),
        ]
      }),
    ),
  ])
}

fn history_panel(data: ProcessDetailModel) -> Element(Msg) {
  ui.panel(title: "History", info: data.info, controls: [], body: [
    html.table([attribute.class("tbl spark-table")], [
      html.tbody(
        [],
        list.map(data.history, fn(series) {
          html.tr([], [
            html.td([attribute.class("spark-label")], [
              element.text(series.label),
            ]),
            html.td([attribute.class("spark-cell")], [
              spark.view(series.points, unit: series.unit),
            ]),
            ui.num(series.summary, unit: series.unit),
            html.td([attribute.class("note-cell")], [
              element.text(series.note),
            ]),
          ])
        }),
      ),
    ]),
  ])
}
