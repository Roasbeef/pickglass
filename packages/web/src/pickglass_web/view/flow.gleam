//// The one-click profile, drawn above any page.
////
//// A profile button (on Owners, Overview, Processes and Process) asks the
//// viewer to pin some processes and plan one probe over them: a stack probe,
//// a call trace or a scheduling and collection recording. The plan is the
//// same dialog the Probes page draws and is confirmed the same way, so a
//// button is never a way around the plan: it saves the pinning and the form,
//// nothing else. This module draws what follows from the click, on the page
//// where the operator already is:
////
//// - the plan, waiting for Confirm, with the processes chosen and the rate,
////   duration and budget stated;
//// - the probe while it runs, with Stop;
//// - when it ends, a link to the page that shows its result: the Profile
////   page for stacks and traced calls, the Timeline page for scheduling and
////   collection events.
////
//// The link is a plain `<a>`, not a navigation the server performs. A page
//// here is a server component whose only script is Lustre's own, and the
//// server cannot move the browser to another address without more script
//// than the strict content security policy allows, so the operator follows
//// the link. The result is the newest finished probe that has one, which is
//// what those pages open.
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
import pickglass_core/policy
import pickglass_web/fmt
import pickglass_web/model.{type FlowModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links, type Page}
import pickglass_web/state.{type UiState}
import pickglass_web/view/probes
import pickglass_web/wire

/// Draw the flow for the page being served. Nothing is drawn when nothing is
/// in flight, so a page with no profile in progress is unchanged.
///
/// ## Examples
///
/// ```gleam
/// flow.view(data, links, page.Overview, ui_state)
/// ```
pub fn view(
  data: FlowModel,
  links: Links,
  current: Page,
  ui_state: UiState,
) -> Element(Msg) {
  let modules = ui_state.plan.modules
  let parts = case current {
    page.Probes -> [refusal(data.refused)]
    page.Profile -> [
      refusal(data.refused),
      plan(data.pending, modules),
      running(data),
    ]
    _ -> [
      refusal(data.refused),
      plan(data.pending, modules),
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

fn plan(pending: Option(model.PlanCard), modules: String) -> Element(Msg) {
  case pending {
    Some(card) -> probes.plan_dialog(card, modules)
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
              running_text(probe.kind)
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

fn running_text(kind: policy.ProbeKind) -> String {
  case kind {
    policy.Sampling -> "Sampling stacks"
    policy.CallTree -> "Tracing calls"
    policy.SchedulingGc -> "Recording scheduling and collections"
    policy.Counters -> "Counting calls"
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
              ready_text(profile.opens)
              <> ": probe "
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
              attribute.href(
                page.href(links, case profile.opens {
                  model.OpensProfile -> page.Profile
                  model.OpensTimeline -> page.Timeline
                }),
              ),
            ],
            [
              element.text(case profile.opens {
                model.OpensProfile -> "Open profile"
                model.OpensTimeline -> "Open timeline"
              }),
            ],
          ),
        ],
      )
  }
}

fn ready_text(opens: model.ReadyPage) -> String {
  case opens {
    model.OpensProfile -> "Profile ready"
    model.OpensTimeline -> "Recording ready"
  }
}
