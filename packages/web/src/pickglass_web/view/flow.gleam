//// The one-click profile, drawn above any page.
////
//// A profile button (on Owners, Overview, Processes and Process) asks the
//// viewer to pin some processes and plan one stack probe over them. The plan
//// is the same dialog the Probes page draws and is confirmed the same way,
//// so a button is never a way around the plan: it saves the pinning and the
//// form, nothing else. This module draws what follows from the click, on the
//// page where the operator already is:
////
//// - the plan, waiting for Confirm, with the processes chosen, the rate, the
////   duration and the sample budget stated;
//// - the probe while it runs, with Stop;
//// - when it ends, a link to the Profile page.
////
//// The link is a plain `<a>`, not a navigation the server performs. A page
//// here is a server component whose only script is Lustre's own, and the
//// server cannot move the browser to another address without more script
//// than the strict content security policy allows, so the operator follows
//// the link. The profile is the newest finished stack probe, which is what
//// the Profile page opens.
////
//// The Probes page draws its own plan and running probes, and the Profile
//// page needs no link to itself, so each leaves out what it already shows.
////
//// ## Reading order
////
//// `view` composes `refusal`, `plan`, `running` and `ready`.

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/measure
import pickglass_web/fmt
import pickglass_web/model.{type FlowModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links, type Page}
import pickglass_web/view/probes
import pickglass_web/wire

/// Draw the flow for the page being served. Nothing is drawn when nothing is
/// in flight, so a page with no profile in progress is unchanged.
///
/// ## Examples
///
/// ```gleam
/// flow.view(data, links, page.Overview)
/// ```
pub fn view(data: FlowModel, links: Links, current: Page) -> Element(Msg) {
  let parts = case current {
    page.Probes -> [refusal(data.refused)]
    page.Profile -> [
      refusal(data.refused),
      plan(data.pending),
      running(data),
    ]
    _ -> [
      refusal(data.refused),
      plan(data.pending),
      running(data),
      ready(data.ready, links),
    ]
  }

  case list.filter(parts, fn(part) { part != element.none() }) {
    [] -> element.none()
    shown -> html.div([attribute.class("flow stack")], shown)
  }
}

fn refusal(reason: Option(String)) -> Element(Msg) {
  case reason {
    Some(text) ->
      html.div(
        [
          attribute.class("flow-refused notice"),
          attribute.role("status"),
          attribute.data("test-id", "profile-refused"),
        ],
        [element.text("No profile was planned: " <> text)],
      )
    None -> element.none()
  }
}

fn plan(pending: Option(model.PlanCard)) -> Element(Msg) {
  case pending {
    Some(card) -> probes.plan_dialog(card)
    None -> element.none()
  }
}

fn running(data: FlowModel) -> Element(Msg) {
  case data.running {
    [] -> element.none()
    probes ->
      html.div(
        [attribute.class("flow-running"), attribute.role("status")],
        list.map(probes, fn(probe) {
          html.p([], [
            html.span([attribute.class("dot dot-active")], []),
            element.text(
              "Sampling stacks"
              <> case probe.remaining_ms {
                measure.Known(ms) -> ": " <> fmt.duration_ms(ms) <> " left. "
                _ -> ". "
              },
            ),
            html.button(
              [
                attribute.class("btn btn-small"),
                attribute.type_("button"),
                wire.click(msg.Ask(msg.StopProbe(probe.key))),
              ],
              [element.text("Stop")],
            ),
          ])
        }),
      )
  }
}

fn ready(done: Option(model.ReadyProfile), links: Links) -> Element(Msg) {
  case done {
    None -> element.none()
    Some(profile) ->
      html.div(
        [
          attribute.class("flow-ready"),
          attribute.role("status"),
          attribute.data("test-id", "profile-ready"),
        ],
        [
          html.span([], [
            element.text(
              "Profile ready: probe "
              <> profile.probe
              <> ", "
              <> profile.summary
              <> ", finished "
              <> fmt.duration_ms(profile.age_ms)
              <> " ago. ",
            ),
          ]),
          html.a(
            [
              attribute.class("btn btn-primary btn-small"),
              attribute.href(page.href(links, page.Profile)),
            ],
            [element.text("Open profile")],
          ),
        ],
      )
  }
}
