//// The supervision tree, labelled as evidence.
////
//// The tree is built from parent links, and where a root starts outside an
//// application, from nothing: the page states that gap in a caveat instead of
//// presenting the drawn tree as complete. It is evidence about structure,
//// the same class of fact as a link, and it never decides ownership; the
//// owner label beside a node is the label join's answer, shown for
//// comparison.
////
//// The tree is drawn as nested keyed lists, so a restart that replaces one
//// worker moves one item. Depth is bounded, and the viewer bounds the node
//// count and reports how many nodes it left out.
////
//// ## Reading order
////
//// `view` draws the roots; `node` recurses through the children.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import pickglass_web/key
import pickglass_web/model.{type SupNode, type SupervisionModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links}
import pickglass_web/view/ui

/// The deepest level drawn; deeper nodes are counted in the note instead.
pub const max_depth: Int = 12

/// Draw the supervision page.
pub fn view(data: SupervisionModel, links: Links) -> Element(Msg) {
  ui.panel(
    title: "Supervision tree",
    info: data.info,
    controls: [ui.badge("evidence", "evidence, not ownership")],
    body: [
      keyed.ul(
        [attribute.class("tree")],
        list.map(data.roots, fn(root) {
          #(key.to_string(root.key), node(root, links, 0))
        }),
      ),
      ui.note(data.caveat),
      omitted_note(data.omitted),
    ],
  )
}

fn omitted_note(omitted: Int) -> Element(Msg) {
  case omitted {
    0 -> element.none()
    n ->
      ui.note(
        int.to_string(n) <> " nodes beyond the drawing bound are not shown.",
      )
  }
}

fn node(item: SupNode, links: Links, depth: Int) -> Element(Msg) {
  let kind = case item.kind {
    model.Supervisor -> ui.badge("sup", "supervisor")
    model.Worker -> ui.badge("worker", "worker")
    model.UnknownKind -> ui.badge("muted", "kind unknown")
  }

  let owner_tag = case item.owner_label {
    Some(label) ->
      html.span([attribute.class("owner-label muted")], [element.text(label)])
    None -> element.none()
  }

  let children = case depth >= max_depth, item.children {
    _, [] -> element.none()
    True, _ -> ui.note("deeper levels are not drawn")
    False, kids ->
      keyed.ul(
        [attribute.class("tree")],
        list.map(kids, fn(kid) {
          #(key.to_string(kid.key), node(kid, links, depth + 1))
        }),
      )
  }

  html.li([attribute.class("tree-node")], [
    html.div([attribute.class("tree-row")], [
      kind,
      html.a(
        [
          attribute.class("mono"),
          attribute.href(page.process_href(links, item.key)),
        ],
        [element.text(item.label)],
      ),
      owner_tag,
    ]),
    children,
  ])
}
