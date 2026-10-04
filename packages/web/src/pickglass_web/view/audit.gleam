//// The audit log.
////
//// Every decision the viewer's authority gate makes is recorded, allowed or
//// denied, at three stages: authorize, plan and confirm. The page lists them
//// newest first with the principal, the command and the reason for a denial.
//// Principals here are the identities fixed at admission, never anything a
//// browser event carried.
////
//// ## Reading order
////
//// `view` draws one table; `entry_row` one decision.

import gleam/list
import gleam/option.{None}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/policy.{type AuditEntry}
import pickglass_web/fmt
import pickglass_web/model.{type AuditModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/view/ui

/// Draw the audit page.
pub fn view(data: AuditModel) -> Element(Msg) {
  ui.panel(title: "Audit", info: data.info, controls: [], body: [
    html.table([attribute.class("tbl audit")], [
      html.thead([], [
        html.tr([], [
          ui.th("time (UTC)", None),
          ui.th("stage", None),
          ui.th("principal", None),
          ui.th("command", None),
          ui.th("decision", None),
        ]),
      ]),
      html.tbody([], list.map(data.entries, entry_row)),
    ]),
    ui.note(
      "Every allow and every deny is recorded, including requests that were refused before they reached the agent.",
    ),
  ])
}

fn entry_row(entry: AuditEntry) -> Element(Msg) {
  let decision = case entry.decision {
    policy.Allowed -> ui.badge("ok", "allowed")
    policy.Denied(reason:) -> ui.badge("block", "denied: " <> reason)
  }

  html.tr([], [
    html.td([attribute.class("num mono")], [
      element.text(fmt.clock(entry.at_ms)),
    ]),
    html.td([], [element.text(stage(entry.stage))]),
    html.td([attribute.class("mono")], [element.text(entry.principal)]),
    html.td([attribute.class("mono")], [element.text(entry.command)]),
    html.td([], [decision]),
  ])
}

fn stage(stage: policy.Stage) -> String {
  case stage {
    policy.AuthorizeStage -> "authorize"
    policy.PlanStage -> "plan"
    policy.ConfirmStage -> "confirm"
  }
}
