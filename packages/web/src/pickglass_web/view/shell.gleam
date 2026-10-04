//// The frame around every page: the top strip, the capability banner and the
//// navigation.
////
//// The strip answers four questions before the operator reads a number. Which
//// node and which incarnation of it is this (a restarted node is a different
//// incarnation, and figures from two incarnations must not be mixed)? Is the
//// page live or showing a saved capture? What is pickglass itself costing the
//// node, in the observer-effect meter? And is a probe running? The banner
//// below says what the principal may do and where the data on the page came
//// from.
////
//// ## Reading order
////
//// `view` composes `strip`, `banner` and `nav` above the page body.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import pickglass_core/identity
import pickglass_core/measure.{Known}
import pickglass_core/policy
import pickglass_core/unit
import pickglass_web/chart/svg_util
import pickglass_web/fmt
import pickglass_web/model.{type StripModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links, type Page}
import pickglass_web/wire

/// The strip, banner, navigation and body of a page.
pub fn view(
  strip strip: StripModel,
  links links: Links,
  current current: Page,
  body body: Element(Msg),
) -> Element(Msg) {
  html.div([attribute.class("app")], [
    html.header([attribute.class("top")], [
      self_strip(strip, links),
      banner(strip),
      nav(links, current),
    ]),
    html.main([attribute.class("page")], [body]),
  ])
}

fn self_strip(strip: StripModel, links: Links) -> Element(Msg) {
  html.div([attribute.class("strip")], [
    html.span([attribute.class("brand")], [element.text("pickglass")]),
    html.span([attribute.class("node"), attribute.title(strip.node)], [
      element.text(strip.node),
    ]),
    incarnation(strip),
    source_pill(strip),
    html.span([attribute.class("spacer")], []),
    detach_control(strip),
    observer_meter(strip),
    probe_indicator(strip, links),
  ])
}

fn incarnation(strip: StripModel) -> Element(msg) {
  let inc = strip.incarnation

  html.span(
    [
      attribute.class("incarnation"),
      attribute.title(
        "incarnation: node digest, creation "
        <> int.to_string(inc.creation)
        <> ", agent boot "
        <> identity.boot_id_text(inc.boot),
      ),
    ],
    [
      element.text(
        "incarnation "
        <> string.slice(inc.node_digest, 0, 4)
        <> " · os "
        <> int.to_string(strip.os.pid)
        <> " · up "
        <> uptime(strip),
      ),
    ],
  )
}

// An unknown uptime is a word, not a duration of zero.
fn uptime(strip: StripModel) -> String {
  case strip.uptime_ms {
    Known(ms) -> fmt.duration_ms(ms)
    absent -> measure.render(absent, unit.Nanoseconds)
  }
}

fn source_pill(strip: StripModel) -> Element(msg) {
  case strip.source {
    model.Live ->
      html.span([attribute.class("pill pill-live")], [
        html.span([attribute.class("dot")], []),
        element.text("live"),
      ])
    model.Viewing(capture:) ->
      html.span([attribute.class("pill pill-capture")], [
        element.text("viewing capture " <> capture),
      ])
    model.Detached(reason:) ->
      html.span(
        [
          attribute.class("pill pill-detached"),
          attribute.title(reason),
          attribute.data("test-id", "detached-pill"),
        ],
        [element.text("detached")],
      )
  }
}

// The control that ends the attachment: the agent unloads from the node, and
// every pin and running probe ends. It is drawn only while attached and only
// for a principal who holds the capability, as the other controls are; the
// viewer checks the grant again.
fn detach_control(strip: StripModel) -> Element(Msg) {
  case strip.source, list.contains(strip.banner.grants, policy.Administer) {
    model.Live, True ->
      html.button(
        [
          attribute.class("btn"),
          attribute.type_("button"),
          attribute.title(
            "Unload pickglass from the node and end every pin and running probe",
          ),
          attribute.data("test-id", "detach"),
          wire.click(msg.Ask(msg.DetachViewer)),
        ],
        [element.text("Detach")],
      )
    _, _ -> element.none()
  }
}

// The meter is an SVG bar on a five percent scale; a duty above the scale
// fills the bar. An unreadable duty is a word.
fn observer_meter(strip: StripModel) -> Element(msg) {
  let observer = strip.observer

  case observer.duty {
    Known(duty) ->
      html.span(
        [
          attribute.class("meter"),
          attribute.title(observer.note),
        ],
        [
          html.span([attribute.class("meter-label")], [
            element.text("pass time / cadence"),
          ]),
          svg.svg([svg_util.view_box(60, 8), attribute.class("meter-bar")], [
            svg.rect([
              svg_util.num("width", 60),
              svg_util.num("height", 8),
              svg_util.num("rx", 2),
              attribute.class("meter-track"),
            ]),
            svg.rect([
              svg_util.num("width", int.min(duty * 60 / 500, 60)),
              svg_util.num("height", 8),
              svg_util.num("rx", 2),
              attribute.class("meter-fill"),
            ]),
          ]),
          html.span([attribute.class("meter-value num")], [
            element.text(fmt.ratio(duty, 10_000)),
          ]),
        ],
      )
    absent ->
      html.span([attribute.class("meter"), attribute.title(observer.note)], [
        html.span([attribute.class("meter-label")], [element.text("effect")]),
        html.span([attribute.class("word")], [
          element.text(measure.render(absent, unit.Ratio(per: 10_000))),
        ]),
      ])
  }
}

fn probe_indicator(strip: StripModel, links: Links) -> Element(msg) {
  case list.length(strip.probes) {
    0 ->
      html.a(
        [
          attribute.class("probe-indicator idle"),
          attribute.href(page.href(links, page.Probes)),
        ],
        [element.text("no probe running")],
      )
    n ->
      html.a(
        [
          attribute.class("probe-indicator active"),
          attribute.href(page.href(links, page.Probes)),
        ],
        [
          html.span([attribute.class("dot dot-active")], []),
          element.text(int.to_string(n) <> " probe running"),
        ],
      )
  }
}

fn banner(strip: StripModel) -> Element(msg) {
  let b = strip.banner

  // A strip whose node is gone is no longer attached, whatever role the
  // attachment had: no command can run and no grant can be used, so the
  // banner must not go on saying "full trust".
  let #(role, role_class, grants) = case strip.source, b.role {
    model.Detached(_), _ -> #("Detached: no target", "role role-diagnostic", [])
    _, model.Diagnostic -> #(
      "Diagnostic: read-only",
      "role role-diagnostic",
      b.grants,
    )
    _, model.AttachedFullTrust -> #(
      "Attached: full trust",
      "role role-trust",
      b.grants,
    )
  }

  html.div([attribute.class("banner")], [
    html.span([attribute.class(role_class)], [element.text(role)]),
    html.span(
      [attribute.class("grants")],
      list.map(grants, fn(grant) {
        html.span([attribute.class("grant")], [element.text(capability(grant))])
      }),
    ),
    html.span([attribute.class("banner-source")], [element.text(b.source_line)]),
  ])
}

fn capability(grant: policy.Capability) -> String {
  case grant {
    policy.Observe -> "observe"
    policy.Summarize -> "summarize"
    policy.Profile -> "profile"
    policy.Perturb -> "perturb"
    policy.Export -> "export"
    policy.Administer -> "administer"
  }
}

fn nav(links: Links, current: Page) -> Element(msg) {
  html.nav(
    [attribute.class("nav"), attribute.aria("label", "Pages")],
    list.map(page.nav_pages, fn(target) {
      let attrs = [attribute.href(page.href(links, target))]

      let attrs = case target == current {
        True -> [attribute.aria("current", "page"), ..attrs]
        False -> attrs
      }

      html.a(attrs, [element.text(page.title(target))])
    }),
  )
}
