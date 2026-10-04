//// The profile page: filter chain, tabs and the six views.
////
//// One profile, one value column and one transform chain feed every tab, so
//// the tabs agree: the flame, the icicle, the graph, the Top table, Peek and
//// Source all describe the same samples after the same steps.
////
//// The chain is drawn as breadcrumbs, as in the Firefox Profiler. Each step
//// is a chip that says what it did and what class of step it is, because the
//// three classes mean different things. A *sample filter* (focus, ignore,
//// show-from, tag-focus, tag-ignore) changes the totals, and its chip shows
//// the total before and after. A *stack rewrite* (hide, show) leaves totals
//// alone except for samples it empties, which are counted. A *display prune*
//// (node and edge fractions, node count) changes only what is drawn. A step
//// that matched nothing says so, instead of leaving an empty chart.
////
//// A source with no call stacks (counters, allocation counts) has no flame,
//// icicle, graph or peek. The page says so and offers Top and Source; it does
//// not draw an empty picture.
////
//// ## Reading order
////
//// `view` draws the header, the chain (`chain_panel`), the tab bar and the
//// open tab's body; each tab has a function of its own.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/analysis/graph
import pickglass_core/analysis/peek
import pickglass_core/analysis/top
import pickglass_core/analysis/transform.{type StepReport}
import pickglass_core/layout/dag
import pickglass_core/layout/flame
import pickglass_core/profile
import pickglass_core/unit.{type Unit}
import pickglass_web/chart/call_graph
import pickglass_web/chart/flame as flame_chart
import pickglass_web/fmt
import pickglass_web/key.{type Key}
import pickglass_web/model.{type ProfileModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/state.{type UiState}
import pickglass_web/view/ui
import pickglass_web/wire

/// The most rows the Top and Source tabs draw.
pub const max_table_rows: Int = 100

/// Draw the profile page.
pub fn view(data: ProfileModel, ui_state: UiState) -> Element(Msg) {
  let u = unit_of(data)

  html.div([attribute.class("stack")], [
    header(data),
    chain_panel(data, ui_state, u),
    html.section([attribute.class("panel tabbed")], [
      tab_bar(data, ui_state),
      html.div([attribute.class("panel-body")], [tab_body(data, ui_state, u)]),
    ]),
  ])
}

fn unit_of(data: ProfileModel) -> Unit {
  case profile.column_type(data.profile, data.column) {
    Ok(value_type) -> value_type.unit
    Error(Nil) -> unit.Count
  }
}

fn header(data: ProfileModel) -> Element(Msg) {
  let h = data.header

  html.section([attribute.class("panel profile-head")], [
    html.header([attribute.class("panel-bar")], [
      html.h2([], [element.text("Profile · " <> h.title)]),
      html.div([attribute.class("panel-controls")], [
        ui.badge("source", source_text(h.source)),
        export_button("Collapsed", msg.AsCollapsed),
        export_button("Speedscope", msg.AsSpeedscope),
        export_button("Chrome trace", msg.AsChromeTrace),
      ]),
    ]),
    ui.meta(h.info),
    html.ul(
      [attribute.class("caveats")],
      list.map(h.caveats, fn(text) { html.li([], [element.text(text)]) }),
    ),
  ])
}

fn export_button(label: String, choice: msg.ExportChoice) -> Element(Msg) {
  html.button(
    [
      attribute.class("btn btn-small"),
      attribute.type_("button"),
      wire.click(msg.Ask(msg.ExportProfile(choice))),
    ],
    [element.text(label)],
  )
}

fn source_text(source: profile.Source) -> String {
  case source {
    profile.SampledStacks(method:, rate:) ->
      "sampled stacks · " <> method <> " · " <> int.to_string(rate) <> " Hz"
    profile.TracedCalls -> "traced calls"
    profile.TracedCounters -> "traced counters, no call stacks"
    profile.AllocationCounts -> "allocation counts, no call stacks"
  }
}

// ------------------------------------------------------------ the chain

fn chain_panel(data: ProfileModel, ui_state: UiState, u: Unit) -> Element(Msg) {
  ui.plain_panel(title: "Filter chain", body: [
    html.ol([attribute.class("crumbs")], [
      html.li([attribute.class("crumb crumb-root")], [
        html.span([attribute.class("crumb-name")], [element.text("all")]),
        html.span([attribute.class("crumb-total num")], [
          element.text(fmt.known(data.total_before, u)),
        ]),
      ]),
      ..list.index_map(data.chain, fn(report, index) { crumb(report, index, u) })
    ]),
    filter_form(ui_state),
    class_table(),
  ])
}

fn crumb(report: StepReport, index: Int, u: Unit) -> Element(Msg) {
  let #(name, argument) = step_label(report.step)

  html.li([attribute.class("crumb " <> class_css(report.class))], [
    html.span([attribute.class("crumb-name")], [element.text(name)]),
    html.span([attribute.class("crumb-arg mono")], [element.text(argument)]),
    html.span([attribute.class("crumb-class")], [
      element.text(class_text(report.class)),
    ]),
    html.span([attribute.class("crumb-total num")], [
      element.text(totals_text(report, u)),
    ]),
    outcome_text(report),
    html.button(
      [
        attribute.class("crumb-remove"),
        attribute.type_("button"),
        attribute.title("Remove this step and every step after it"),
        wire.click(msg.Ask(msg.TruncateChain(index))),
      ],
      [element.text("×")],
    ),
  ])
}

fn class_css(class: transform.StepClass) -> String {
  case class {
    transform.SampleFilter -> "class-filter"
    transform.StackRewrite -> "class-rewrite"
    transform.DisplayPrune -> "class-prune"
  }
}

fn class_text(class: transform.StepClass) -> String {
  case class {
    transform.SampleFilter -> "changes totals"
    transform.StackRewrite -> "rewrites stacks"
    transform.DisplayPrune -> "display only"
  }
}

// A sample filter changes the total, so the chip shows both ends; the other
// classes show that the total held, and what they dropped.
fn totals_text(report: StepReport, u: Unit) -> String {
  case report.class {
    transform.SampleFilter ->
      fmt.known(report.total_before, u)
      <> " → "
      <> fmt.known(report.total_after, u)
    transform.StackRewrite ->
      case report.dropped_empty {
        0 -> "totals unchanged"
        n -> int.to_string(n) <> " emptied samples dropped"
      }
    transform.DisplayPrune -> "totals unchanged"
  }
}

fn outcome_text(report: StepReport) -> Element(Msg) {
  case report.outcome {
    transform.MatchedNothing ->
      ui.badge("warn", "matched nothing: this step changed no sample")
    transform.Matched(count:) ->
      ui.badge("muted", int.to_string(count) <> " matched")
    transform.DisplayOnly -> element.none()
  }
}

fn step_label(step: transform.Step) -> #(String, String) {
  case step {
    transform.Focus(pattern:) -> #("focus", pattern)
    transform.Ignore(pattern:) -> #("ignore", pattern)
    transform.ShowFrom(pattern:) -> #("show from", pattern)
    transform.TagFocus(tag:) -> #("tag focus", tag_text(tag))
    transform.TagIgnore(tag:) -> #("tag ignore", tag_text(tag))
    transform.Hide(pattern:) -> #("hide", pattern)
    transform.Show(pattern:) -> #("show", pattern)
    transform.NodeFraction(fraction:) -> #(
      "node fraction",
      float.to_string(fraction),
    )
    transform.EdgeFraction(fraction:) -> #(
      "edge fraction",
      float.to_string(fraction),
    )
    transform.NodeCount(count:) -> #("node count", int.to_string(count))
  }
}

fn tag_text(tag: transform.TagMatch) -> String {
  case tag.key {
    Some(name) -> name <> "=" <> list.fold(tag.patterns, "", join)
    None -> list.fold(tag.patterns, "", join)
  }
}

fn join(acc: String, text: String) -> String {
  case acc {
    "" -> text
    _ -> acc <> "|" <> text
  }
}

fn filter_form(ui_state: UiState) -> Element(Msg) {
  let draft = ui_state.filter

  html.div([attribute.class("filter-form")], [
    html.select(
      [
        wire.code_chosen(msg.parse_filter, msg.FocusFilter, fn(kind) {
          msg.Ui(msg.FilterKindChosen(kind))
        }),
      ],
      list.map(
        [
          msg.FocusFilter,
          msg.IgnoreFilter,
          msg.ShowFromFilter,
          msg.HideFilter,
          msg.ShowFilter,
        ],
        fn(kind) {
          html.option(
            [
              attribute.value(msg.filter_code(kind)),
              attribute.selected(kind == draft.kind),
            ],
            msg.filter_code(kind),
          )
        },
      ),
    ),
    html.input([
      attribute.class("text mono"),
      attribute.type_("text"),
      attribute.placeholder("module or function pattern"),
      attribute.value(draft.pattern),
      wire.text_entered(fn(text) { msg.Ui(msg.FilterPattern(text)) }),
    ]),
    html.button(
      [
        attribute.class("btn"),
        attribute.type_("button"),
        wire.click(msg.Ui(msg.SubmitFilter)),
      ],
      [element.text("Add step")],
    ),
    notice(ui_state.notice),
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

// The three classes of step, as a table, because the difference between them
// is the thing the chain exists to make visible.
fn class_table() -> Element(Msg) {
  html.details([attribute.class("legend")], [
    html.summary([], [element.text("What the three kinds of step do")]),
    html.table([attribute.class("tbl compact")], [
      html.thead([], [
        html.tr([], [
          ui.th("steps", None),
          ui.th("class", None),
          ui.th("effect on totals", None),
        ]),
      ]),
      html.tbody([], [
        legend_row(
          "focus, ignore, show from, tag focus, tag ignore",
          "sample filter",
          "changes: samples are dropped, and the chip shows total before → after",
        ),
        legend_row(
          "hide, show",
          "stack rewrite",
          "unchanged, except samples left with no frames, which are dropped and counted",
        ),
        legend_row(
          "node fraction, edge fraction, node count",
          "display prune",
          "unchanged: only what is drawn is pruned",
        ),
      ]),
    ]),
  ])
}

fn legend_row(steps: String, class: String, effect: String) -> Element(Msg) {
  html.tr([], [
    html.td([], [element.text(steps)]),
    html.td([], [element.text(class)]),
    html.td([], [element.text(effect)]),
  ])
}

// ------------------------------------------------------------ tabs

fn tab_bar(data: ProfileModel, ui_state: UiState) -> Element(Msg) {
  let tabs = case data.stacks {
    model.HasStacks(..) -> [
      #("Flame", msg.FlameTab),
      #("Icicle", msg.IcicleTab),
      #("Graph", msg.GraphTab),
      #("Top", msg.TopTab),
      #("Peek", msg.PeekTab),
      #("Source", msg.SourceTab),
    ]
    model.NoStacks(..) -> [#("Top", msg.TopTab), #("Source", msg.SourceTab)]
  }

  html.div(
    [attribute.class("tabs"), attribute.role("tablist")],
    list.map(tabs, fn(tab) {
      let class = case tab.1 == ui_state.tab {
        True -> "tab tab-active"
        False -> "tab"
      }

      html.button(
        [
          attribute.class(class),
          attribute.type_("button"),
          attribute.role("tab"),
          wire.click(msg.Ui(msg.OpenTab(tab.1))),
        ],
        [element.text(tab.0)],
      )
    }),
  )
}

fn tab_body(data: ProfileModel, ui_state: UiState, u: Unit) -> Element(Msg) {
  case data.stacks, ui_state.tab {
    model.HasStacks(layout:, ..), msg.FlameTab ->
      flame_tab(data, layout, flame_chart.RootBelow, ui_state, u)
    model.HasStacks(layout:, ..), msg.IcicleTab ->
      flame_tab(data, layout, flame_chart.RootAbove, ui_state, u)
    model.HasStacks(graph: g, dag: placed, ..), msg.GraphTab ->
      graph_tab(data, g, placed, ui_state, u)
    model.HasStacks(peeks:, dag: placed, ..), msg.PeekTab ->
      peek_tab(data, peeks, placed, ui_state, u)
    model.NoStacks(source:), msg.PeekTab
    | model.NoStacks(source:), msg.FlameTab
    | model.NoStacks(source:), msg.IcicleTab
    | model.NoStacks(source:), msg.GraphTab
    -> no_stacks(source)
    _, msg.SourceTab -> source_tab(data, u)
    _, msg.TopTab -> top_tab(data, ui_state, u)
  }
}

fn no_stacks(source: profile.Source) -> Element(Msg) {
  html.div([attribute.class("refusal")], [
    html.h3([], [element.text("No call stacks in this source")]),
    html.p([], [
      element.text(
        "A profile from "
        <> source_text(source)
        <> " records totals per function, not stacks, so a flame graph, "
        <> "icicle or call graph would have nothing to draw. Top and Source "
        <> "are available.",
      ),
    ]),
  ])
}

// ------------------------------------------------------------ flame

fn flame_tab(
  data: ProfileModel,
  layout: flame.Layout,
  facing: flame_chart.Facing,
  ui_state: UiState,
  u: Unit,
) -> Element(Msg) {
  let profile_data = data.profile
  let name_of = fn(id) { profile.name_of(profile_data, id) }

  html.div([], [
    search_box(ui_state),
    html.div([attribute.class("graph-frame")], [
      flame_chart.view(
        layout:,
        facing:,
        name_of:,
        unit: u,
        selected: ui_state.selected,
        search: ui_state.search,
        on_select: fn(box) { msg.Ui(msg.SelectBox(box)) },
      ),
    ]),
    selection(layout, name_of, ui_state.selected, u),
    ui.note(
      "Width is a share of the profile's value, not of time. "
      <> int.to_string(layout.omitted_boxes)
      <> " boxes narrower than the minimum were folded into their parents.",
    ),
  ])
}

fn search_box(ui_state: UiState) -> Element(Msg) {
  html.div([attribute.class("search")], [
    html.input([
      attribute.class("text mono"),
      attribute.type_("search"),
      attribute.placeholder("search function names"),
      attribute.value(ui_state.search),
      wire.text_entered(fn(text) { msg.Ui(msg.Search(text)) }),
    ]),
    html.button(
      [
        attribute.class("btn btn-small"),
        attribute.type_("button"),
        wire.click(msg.Ui(msg.ClearSelection)),
      ],
      [element.text("Clear selection")],
    ),
  ])
}

fn selection(
  layout: flame.Layout,
  name_of: fn(Int) -> String,
  selected: Option(Key),
  u: Unit,
) -> Element(Msg) {
  let chosen = case selected {
    Some(chosen_key) ->
      list.find(layout.boxes, fn(box) { flame_chart.box_key(box) == chosen_key })
    None -> Error(Nil)
  }

  case chosen {
    Ok(box) -> {
      let name = case box.frame {
        flame.Root -> "all"
        flame.Function(id:) -> name_of(id)
      }

      html.p([attribute.class("selection")], [
        html.strong([attribute.class("mono")], [element.text(name)]),
        element.text(
          "  "
          <> fmt.known(box.value, u)
          <> " ("
          <> fmt.share(box.value, of: layout.total)
          <> ") · self "
          <> fmt.known(box.self, u),
        ),
      ])
    }
    Error(Nil) -> ui.note("Click a box to select it.")
  }
}

// ------------------------------------------------------------ graph

fn graph_tab(
  data: ProfileModel,
  g: graph.Graph,
  placed: dag.Layout,
  ui_state: UiState,
  u: Unit,
) -> Element(Msg) {
  let profile_data = data.profile
  let name_of = fn(id) { profile.name_of(profile_data, id) }

  html.div([], [
    html.div([attribute.class("graph-frame scroll")], [
      call_graph.view(
        layout: placed,
        total: g.total,
        name_of:,
        unit: u,
        selected: ui_state.selected,
        on_select: fn(node) { msg.Ui(msg.SelectNode(node)) },
      ),
    ]),
    ui.note(
      "Showing "
      <> int.to_string(list.length(g.nodes))
      <> " of "
      <> int.to_string(g.original_nodes)
      <> " functions; "
      <> int.to_string(g.dropped_nodes)
      <> " nodes and "
      <> int.to_string(g.dropped_edges)
      <> " edges were pruned. A dotted edge stands for removed functions "
      <> "between its ends. Text size follows flat value; shade follows "
      <> "cumulative share.",
    ),
  ])
}

// ------------------------------------------------------------ peek

fn peek_tab(
  data: ProfileModel,
  peeks: List(peek.Peek),
  placed: dag.Layout,
  ui_state: UiState,
  u: Unit,
) -> Element(Msg) {
  let profile_data = data.profile
  let name_of = fn(id) { profile.name_of(profile_data, id) }

  let chosen =
    list.find(placed.nodes, fn(node) {
      Some(call_graph.node_key(node.function)) == ui_state.selected
    })
    |> result.try(fn(node) {
      list.find(peeks, fn(entry) { entry.function == node.function })
    })

  case chosen {
    Error(Nil) ->
      ui.note(
        "Select a node in the Graph tab or a row in Top to see its callers and callees.",
      )
    Ok(entry) ->
      html.div([attribute.class("grid two")], [
        html.div([], [
          html.h3([], [element.text("Callers")]),
          links_table(entry.callers, name_of, u),
        ]),
        html.div([], [
          html.h3([], [element.text(name_of(entry.function))]),
          html.p([attribute.class("num")], [
            element.text(
              "flat "
              <> fmt.known(entry.flat, u)
              <> " · cum "
              <> fmt.known(entry.cum, u),
            ),
          ]),
          html.h3([], [element.text("Callees")]),
          links_table(entry.callees, name_of, u),
        ]),
      ])
  }
}

fn links_table(
  links: List(peek.Link),
  name_of: fn(Int) -> String,
  u: Unit,
) -> Element(Msg) {
  case links {
    [] -> ui.note("none")
    _ ->
      html.table([attribute.class("tbl compact")], [
        html.tbody(
          [],
          list.map(links, fn(link) {
            let mark = case link.kind {
              graph.Direct -> ""
              graph.Residual -> " (via removed functions)"
            }

            html.tr([], [
              html.td([attribute.class("mono")], [
                element.text(name_of(link.function) <> mark),
              ]),
              html.td([attribute.class("num")], [
                element.text(fmt.known(link.weight, u)),
              ]),
            ])
          }),
        ),
      ])
  }
}

// ------------------------------------------------------------ top

fn top_tab(data: ProfileModel, ui_state: UiState, u: Unit) -> Element(Msg) {
  let index = profile.column_index(data.column)
  let table = data.top
  let total = result.unwrap(list.first(list.drop(table.totals, index)), 0)
  let shown = list.take(table.rows, max_table_rows)

  html.div([], [
    html.table([attribute.class("tbl top")], [
      html.thead([], [
        html.tr([], [
          ui.th("function", None),
          ui.th_num("flat", None),
          ui.th_num("flat %", None),
          ui.th_num("cum", None),
          ui.th_num("cum %", None),
        ]),
      ]),
      html.tbody(
        [],
        list.map(shown, fn(row) { top_row(row, index, total, ui_state, u) }),
      ),
    ]),
    ui.note(
      "Showing the first "
      <> int.to_string(list.length(shown))
      <> " of "
      <> int.to_string(list.length(table.rows))
      <> " functions by flat value.",
    ),
  ])
}

fn top_row(
  row: top.Row,
  index: Int,
  total: Int,
  ui_state: UiState,
  u: Unit,
) -> Element(Msg) {
  let totals =
    result.unwrap(
      list.first(list.drop(row.totals, index)),
      top.Totals(flat: 0, cum: 0),
    )

  let name_cell = case row.function {
    Some(id) ->
      html.button(
        [
          attribute.class("link-button mono"),
          attribute.type_("button"),
          wire.click(msg.Ui(msg.SelectNode(call_graph.node_key(id)))),
        ],
        [element.text(row.name)],
      )
    None -> html.span([attribute.class("mono")], [element.text(row.name)])
  }

  let selected = case row.function {
    Some(id) ->
      case Some(call_graph.node_key(id)) == ui_state.selected {
        True -> "sel-row"
        False -> ""
      }
    None -> ""
  }

  html.tr([attribute.class(selected)], [
    html.td([], [name_cell]),
    html.td([attribute.class("num")], [element.text(fmt.known(totals.flat, u))]),
    html.td([attribute.class("num")], [
      element.text(fmt.share(totals.flat, of: total)),
    ]),
    html.td([attribute.class("num")], [element.text(fmt.known(totals.cum, u))]),
    html.td([attribute.class("num")], [
      element.text(fmt.share(totals.cum, of: total)),
    ]),
  ])
}

// ------------------------------------------------------------ source

fn source_tab(data: ProfileModel, u: Unit) -> Element(Msg) {
  let index = profile.column_index(data.column)

  let flat_by_function =
    list.fold(data.top.rows, dict.new(), fn(acc, row) {
      case row.function {
        Some(id) ->
          dict.insert(
            acc,
            id,
            result.unwrap(
              list.first(list.drop(row.totals, index)),
              top.Totals(flat: 0, cum: 0),
            ),
          )
        None -> acc
      }
    })

  let functions =
    profile.functions(data.profile)
    |> list.sort(profile.compare_functions)
    |> list.take(max_table_rows)

  html.div([], [
    html.table([attribute.class("tbl source")], [
      html.thead([], [
        html.tr([], [
          ui.th("function", None),
          ui.th("location", None),
          ui.th("line", None),
          ui.th_num("flat", None),
        ]),
      ]),
      html.tbody(
        [],
        list.map(functions, fn(function) {
          source_row(function, dict.get(flat_by_function, function.id), u)
        }),
      ),
    ]),
    ui.note(
      "Lines are exact only where the compiler recorded them; "
      <> "function-level lines point at the function's definition. Source "
      <> "text is shown only when a read-only source root is configured.",
    ),
  ])
}

fn source_row(
  function: profile.Function,
  totals: Result(top.Totals, Nil),
  u: Unit,
) -> Element(Msg) {
  let location = case function.file, function.line {
    Some(file), Some(line) -> file <> ":" <> int.to_string(line)
    Some(file), None -> file
    None, _ -> "no source location"
  }

  let precision = case function.precision {
    profile.Exact -> "exact"
    profile.FunctionLevel -> "function-level"
    profile.NoLine -> "no line"
  }

  let flat = case totals {
    Ok(found) -> element.text(fmt.known(found.flat, u))
    Error(Nil) ->
      html.span([attribute.class("word")], [element.text("not in table")])
  }

  html.tr([], [
    html.td([attribute.class("mono")], [
      element.text(profile.function_name(function)),
    ]),
    html.td([attribute.class("mono")], [element.text(location)]),
    html.td([attribute.class("muted")], [element.text(precision)]),
    html.td([attribute.class("num")], [flat]),
  ])
}
