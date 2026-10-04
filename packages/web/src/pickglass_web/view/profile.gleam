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
//// ## Flow
////
//// `view` draws the header (`header`), the chain (`chain_panel`), the tab bar
//// (`tab_bar`) and the open tab's body (`tab_body`), which hands the work to
//// `flame_tab`, `graph_tab`, `peek_tab`, `top_tab` or `source_tab`. The
//// profile's one total comes from `root_total`; a selection becomes a chain
//// step through `step_at`; and `search_text` and `peek_note` write the
//// sentences under the flame and Peek.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
import pickglass_core/profile/activity
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

/// The total of the profile's column before any step of the chain.
///
/// This is the number the chain's root chip reads. For sampled stacks it is
/// the number of samples collected, which the host also puts in the header's
/// coverage as the achieved count.
///
/// ## Examples
///
/// ```gleam
/// profile_view.root_total(data)
/// // -> 10708
/// ```
pub fn root_total(data: ProfileModel) -> Int {
  case data.chain {
    [first, ..] -> first.total_before
    [] -> profile.total(data.profile, data.column)
  }
}

/// The chain step a "focus here" or "show from here" request stands for: the
/// kind of step, with a pattern that matches exactly the function behind the
/// selected box or node and nothing else. The viewer calls this with the
/// profile it holds, so the browser names a key and never a function.
///
/// The root box and a key the profile does not draw give `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// profile_view.step_at(data, msg.FocusFilter, key)
/// // -> Ok(transform.Focus(pattern: "^loom@runtime@keeper:handle/2$"))
/// ```
pub fn step_at(
  data: ProfileModel,
  kind: msg.FilterKind,
  selected: Key,
) -> Result(transform.Step, Nil) {
  use id <- result.try(function_at(data, selected))

  let exact = "^" <> escape(profile.name_of(data.profile, id)) <> "$"

  Ok(case kind {
    msg.FocusFilter -> transform.Focus(pattern: exact)
    msg.IgnoreFilter -> transform.Ignore(pattern: exact)
    msg.ShowFromFilter -> transform.ShowFrom(pattern: exact)
    msg.HideFilter -> transform.Hide(pattern: exact)
    msg.ShowFilter -> transform.Show(pattern: exact)
  })
}

// The function id behind a box key or a node key, if the page draws it.
fn function_at(data: ProfileModel, selected: Key) -> Result(Int, Nil) {
  case data.stacks {
    model.NoStacks(..) -> Error(Nil)
    model.HasStacks(layout:, dag: placed, ..) -> {
      let by_box =
        list.find_map(layout.boxes, fn(box) {
          case flame_chart.box_key(box) == selected, box.frame {
            True, flame.Function(id:) -> Ok(id)
            _, _ -> Error(Nil)
          }
        })

      case by_box {
        Ok(id) -> Ok(id)
        Error(Nil) ->
          list.find_map(placed.nodes, fn(node) {
            case call_graph.node_key(node.function) == selected {
              True -> Ok(node.function)
              False -> Error(Nil)
            }
          })
      }
    }
  }
}

// Each character the pattern language treats as an operator is written with
// a backslash, so a name is matched as the text it is.
fn escape(text: String) -> String {
  text
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case string.contains(".*+?|\\^$()[]{}", grapheme) {
      True -> "\\" <> grapheme
      False -> grapheme
    }
  })
  |> string.concat
}

/// Draw the profile page.
pub fn view(data: ProfileModel, ui_state: UiState) -> Element(Msg) {
  let u = unit_of(data)

  case all_waiting(data) {
    // Not one sample caught a process on a scheduler, so there is nothing to
    // draw. The page says so, and offers the samples it left out.
    True ->
      html.div([attribute.class("stack")], [
        header(data),
        activity_panel(data),
      ])
    False ->
      html.div([attribute.class("stack")], [
        header(data),
        activity_panel(data),
        chain_panel(data, ui_state, u),
        html.section([attribute.class("panel tabbed")], [
          tab_bar(data, ui_state),
          html.div([attribute.class("panel-body")], [
            tab_body(data, ui_state, u),
          ]),
        ]),
      ])
  }
}

/// Whether the page is showing running and runnable samples only and the
/// profile has none: every sample was taken while its process waited.
///
/// ## Examples
///
/// ```gleam
/// profile_view.all_waiting(data)
/// // -> True for a profile of idle processes
/// ```
pub fn all_waiting(data: ProfileModel) -> Bool {
  case data.activity {
    model.Statuses(inclusion: activity.OnSchedulerOnly, split:, ..) ->
      split.on_scheduler == 0 && split.unstated == 0 && split.waiting > 0
    model.Statuses(inclusion: activity.IncludeWaiting, ..) | model.NoStatuses ->
      False
  }
}

/// The coverage sentence that splits a sampled profile by what its processes
/// were doing: the total, then how many samples were on a scheduler or ready
/// to run and how many were waiting.
///
/// ## Examples
///
/// ```gleam
/// profile_view.split_text(activity.Split(412, 2596, 0))
/// // -> "3,008 samples: 412 running/runnable, 2,596 waiting"
/// ```
pub fn split_text(split: activity.Split) -> String {
  fmt.count(activity.split_total(split))
  <> " samples: "
  <> fmt.count(split.on_scheduler)
  <> " running/runnable, "
  <> fmt.count(split.waiting)
  <> " waiting"
  <> case split.unstated {
    0 -> ""
    count -> ", " <> fmt.count(count) <> " with no status recorded"
  }
}

/// The sentence for a profile in which no sample caught a process on a
/// scheduler.
///
/// ## Examples
///
/// ```gleam
/// profile_view.idle_text(Some(16))
/// // -> "All 16 processes were waiting for messages for the whole window."
/// ```
pub fn idle_text(processes: Option(Int)) -> String {
  case processes {
    Some(1) -> "The process was waiting for a message for the whole window."
    Some(count) ->
      "All "
      <> int.to_string(count)
      <> " processes were waiting for messages for the whole window."
    None -> "Every process was waiting for a message for the whole window."
  }
}

// The split of the samples, and the one control that changes which are
// drawn. A profile with no statuses has nothing to split and draws nothing.
fn activity_panel(data: ProfileModel) -> Element(Msg) {
  case data.activity {
    model.NoStatuses -> element.none()
    model.Statuses(inclusion:, split:, processes:) -> {
      let #(shown, toggle_label, toggle_to) = case inclusion {
        activity.OnSchedulerOnly -> #(
          "Showing running and runnable samples only.",
          "Include waiting samples (" <> fmt.count(split.waiting) <> ")",
          activity.IncludeWaiting,
        )
        activity.IncludeWaiting -> #(
          "Showing every sample, waiting ones included: the heaviest functions on an idle node are often waits.",
          "Show running and runnable only",
          activity.OnSchedulerOnly,
        )
      }

      html.section(
        [
          attribute.class("panel activity"),
          attribute.data("test-id", "activity-split"),
        ],
        [
          html.p([attribute.class("activity-line")], [
            element.text(split_text(split) <> ". " <> shown),
          ]),
          case all_waiting(data) {
            True ->
              html.p(
                [
                  attribute.class("notice"),
                  attribute.role("status"),
                  attribute.data("test-id", "all-waiting"),
                ],
                [element.text(idle_text(processes))],
              )
            False -> element.none()
          },
          html.button(
            [
              attribute.class("btn btn-small"),
              attribute.type_("button"),
              wire.click(msg.Ask(msg.ChooseSamples(toggle_to))),
            ],
            [element.text(toggle_label)],
          ),
        ],
      )
    }
  }
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
    ui.meta(data.header.info),
    html.ul(
      [attribute.class("caveats")],
      list.map(h.caveats, fn(text) { html.li([], [element.text(text)]) }),
    ),
    export_notes(data.exports),
  ])
}

// The losses of an export as one sentence. Each loss is already a sentence
// that ends in a period, so joining them with "; " and adding another period
// gives ".;" and "..". Each is cut back to its words and the whole ends once.
fn loss_text(losses: List(String)) -> String {
  let words =
    list.map(losses, fn(loss) {
      case string.ends_with(loss, ".") {
        True -> string.drop_end(loss, 1)
        False -> loss
      }
    })

  string.join(words, "; ") <> "."
}

// Each export the operator asked for is either a one-time link, with what
// the format leaves out, or the reason the format cannot show this profile.
// The link's address is the viewer's own ticket, which `key` limits to a
// closed alphabet, so no text from the target is ever part of an address.
/// The exports the operator asked for: each a one-time link with what the
/// format leaves out, or the reason it could not be made. The Timeline page
/// draws the same list for its Chrome traces.
///
/// ## Examples
///
/// ```gleam
/// profile_view.export_notes(data.exports)
/// ```
pub fn export_notes(notes: List(model.ExportNote)) -> Element(Msg) {
  case notes {
    [] -> element.none()
    _ ->
      html.ul(
        [attribute.class("exports")],
        list.map(notes, fn(note) {
          case note {
            model.ExportReady(label:, ticket:, losses:) ->
              html.li([attribute.data("test-id", "export-ready")], [
                html.a(
                  [
                    attribute.href("/download/" <> key.to_string(ticket)),
                    attribute.download(label),
                  ],
                  [element.text(label <> " (one download)")],
                ),
                html.span([attribute.class("muted")], [
                  element.text(" does not carry: " <> loss_text(losses)),
                ]),
              ])
            model.ExportRefused(label:, reason:) ->
              html.li([attribute.data("test-id", "export-refused")], [
                ui.badge("warn", label <> " refused"),
                element.text(" " <> reason),
              ])
          }
        }),
      )
  }
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
        html.span([attribute.class("crumb-name")], [
          element.text(case data.activity {
            model.Statuses(inclusion: activity.OnSchedulerOnly, ..) ->
              "running/runnable"
            model.Statuses(inclusion: activity.IncludeWaiting, ..)
            | model.NoStatuses -> "all"
          }),
        ]),
        html.span([attribute.class("crumb-total num")], [
          element.text(fmt.known(root_total(data), u)),
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

// The pattern field and the button are one form, so the pattern travels in
// the submit. The kind is a select whose change is sent at once and arrives
// before the submit on the same socket.
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
    html.form(
      [
        attribute.class("inline-form filter-add"),
        wire.submitted("pattern", fn(text) { msg.Ui(msg.SubmitFilter(text)) }),
      ],
      [
        html.input([
          attribute.class("text mono"),
          attribute.type_("text"),
          attribute.name("pattern"),
          attribute.placeholder("module or function pattern"),
        ]),
        html.button([attribute.class("btn"), attribute.type_("submit")], [
          element.text("Add step"),
        ]),
      ],
    ),
  ])
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
      let class = case tab.1 == open_tab(data, ui_state) {
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

// The tab that is open. A profile with no stacks lists only Top and Source,
// but the page starts on the flame tab, so a request for a tab the profile
// does not list opens Top, the first tab that is listed.
fn open_tab(data: ProfileModel, ui_state: UiState) -> msg.ProfileTab {
  case data.stacks, ui_state.tab {
    model.NoStacks(..), msg.FlameTab
    | model.NoStacks(..), msg.IcicleTab
    | model.NoStacks(..), msg.GraphTab
    | model.NoStacks(..), msg.PeekTab
    -> msg.TopTab
    _, tab -> tab
  }
}

fn tab_body(data: ProfileModel, ui_state: UiState, u: Unit) -> Element(Msg) {
  case data.stacks, open_tab(data, ui_state) {
    // A profile that drew nothing has no frame worth showing on any tab; the
    // same sentence the Top tab gives says so and names the next step.
    model.HasStacks(layout:, ..), msg.FlameTab
    | model.HasStacks(layout:, ..), msg.IcicleTab
    | model.HasStacks(layout:, ..), msg.GraphTab
    | model.HasStacks(layout:, ..), msg.PeekTab
      if layout.total == 0
    -> nothing_measured(data)

    model.HasStacks(layout:, ..), msg.FlameTab ->
      flame_tab(data, layout, flame_chart.RootBelow, ui_state, u)
    model.HasStacks(layout:, ..), msg.IcicleTab ->
      flame_tab(data, layout, flame_chart.RootAbove, ui_state, u)
    model.HasStacks(graph: g, dag: placed, ..), msg.GraphTab ->
      graph_tab(data, g, placed, ui_state, u)
    model.HasStacks(graph: g, peeks:, ..), msg.PeekTab ->
      peek_tab(data, g, peeks, ui_state, u)
    _, msg.SourceTab -> source_tab(data, u)

    // `open_tab` has already turned a stack tab on a profile without stacks
    // into Top; these arms say the same for the compiler.
    model.NoStacks(..), msg.FlameTab
    | model.NoStacks(..), msg.IcicleTab
    | model.NoStacks(..), msg.GraphTab
    | model.NoStacks(..), msg.PeekTab
    | _, msg.TopTab
    -> top_tab(data, ui_state, u)
  }
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
    search_box(ui_state, layout, name_of, u),
    html.div([attribute.class("graph-frame")], [
      flame_chart.view(
        layout:,
        facing:,
        name_of:,
        unit: u,
        selected: ui_state.selected,
        search: ui_state.search,
        verdict: flame_chart.Directed,
        on_select: fn(box) { msg.Ui(msg.SelectBox(box)) },
      ),
    ]),
    selection(layout, name_of, ui_state.selected, u),
    ui.note(
      "Width is a share of the profile's value, not of time. "
      <> omitted_text(layout.omitted_boxes)
      <> "The synthetic root that holds every sample is not drawn.",
    ),
  ])
}

/// What the search text matches, written for the line under the box.
///
/// ## Examples
///
/// ```gleam
/// profile_view.search_text(flame.SearchSummary(boxes: 24, value: 334, total: 1070), unit.Count)
/// // -> "24 boxes, 31.2% of the value (334)"
/// ```
pub fn search_text(summary: flame_chart.SearchSummary, u: Unit) -> String {
  case summary.boxes {
    0 -> "No box matches."
    1 ->
      "1 box, "
      <> fmt.share(summary.value, of: summary.total)
      <> " of the value ("
      <> fmt.known(summary.value, u)
      <> ")"
    n ->
      int.to_string(n)
      <> " boxes, "
      <> fmt.share(summary.value, of: summary.total)
      <> " of the value ("
      <> fmt.known(summary.value, u)
      <> ")"
  }
}

fn omitted_text(count: Int) -> String {
  case count {
    0 -> ""
    1 -> "1 box narrower than the minimum was folded into its parent. "
    n ->
      int.to_string(n)
      <> " boxes narrower than the minimum were folded into their parents. "
  }
}

fn search_box(
  ui_state: UiState,
  layout: flame.Layout,
  name_of: fn(Int) -> String,
  u: Unit,
) -> Element(Msg) {
  let matched = case ui_state.search {
    "" -> element.none()
    needle ->
      html.span([attribute.class("search-result")], [
        element.text(search_text(
          flame_chart.search_summary(layout, name_of, needle),
          u,
        )),
      ])
  }

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
    matched,
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
        focus_buttons(flame_chart.box_key(box)),
      ])
    }
    Error(Nil) -> ui.note("Click a box to select it.")
  }
}

// Two requests that add a chain step on the selected function. They carry
// the selection's key and nothing else; the viewer finds the function.
fn focus_buttons(selected: Key) -> Element(Msg) {
  html.span([attribute.class("selection-actions")], [
    html.button(
      [
        attribute.class("btn btn-small"),
        attribute.type_("button"),
        attribute.title("Keep only the samples that pass through this function"),
        wire.click(msg.Ask(msg.AddFilterAt(msg.FocusFilter, selected))),
      ],
      [element.text("Focus here")],
    ),
    html.button(
      [
        attribute.class("btn btn-small"),
        attribute.type_("button"),
        attribute.title("Start every stack at this function"),
        wire.click(msg.Ask(msg.AddFilterAt(msg.ShowFromFilter, selected))),
      ],
      [element.text("Show from here")],
    ),
  ])
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
    single_path_note(g, u),
    size_toggle(),
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
    node_selection(placed, name_of, g.total, ui_state.selected, u),
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
      <> "cumulative share. Each box shows flat, then cumulative, with their "
      <> "shares of the total; an edge shows its weight when that is at least "
      <> "2% of the total. The graph is scaled to fit the frame; choose Full size "
      <> "to draw it at its natural size and scroll the frame.",
    ),
  ])
}

// A checkbox and the label that toggles it, with no handler: the stylesheet
// reads the checkbox's state through the sibling selector, so the choice
// needs no script and no round trip, and a re-render leaves it alone. The
// frame has to follow them in the tree for that selector to reach it.
fn size_toggle() -> Element(Msg) {
  element.fragment([
    html.input([
      attribute.class("graph-size"),
      attribute.type_("checkbox"),
      attribute.id("graph-size"),
    ]),
    html.label(
      [
        attribute.class("btn btn-small graph-size-label"),
        attribute.for("graph-size"),
      ],
      [
        html.span([attribute.class("when-fit")], [element.text("Full size")]),
        html.span([attribute.class("when-full")], [element.text("Fit to frame")]),
      ],
    ),
  ])
}

// When every sample took the same path, each box reads 100% and four red
// boxes look like four hot spots. Said once above the graph, it reads as
// one stack that was always there.
fn single_path_note(g: graph.Graph, u: Unit) -> Element(Msg) {
  let callers = list.map(g.edges, fn(edge) { edge.from })
  let callees = list.map(g.edges, fn(edge) { edge.to })
  let one_each =
    list.unique(callers) == callers && list.unique(callees) == callees

  case g.edges, one_each {
    [_, ..], True ->
      ui.note(
        "One call path: every sample ("
        <> fmt.known(g.total, u)
        <> ") passed through all of these functions, so each is at 100% "
        <> "cumulative.",
      )
    _, _ -> element.none()
  }
}

// The persistent line for the Graph tab, the counterpart of the flame's: the
// numbers hover text carries are also here, where a touch screen or a
// screenshot can read them.
fn node_selection(
  placed: dag.Layout,
  name_of: fn(Int) -> String,
  total: Int,
  selected: Option(Key),
  u: Unit,
) -> Element(Msg) {
  let chosen =
    list.find(placed.nodes, fn(node) {
      Some(call_graph.node_key(node.function)) == selected
    })

  case chosen {
    Ok(node) ->
      html.p([attribute.class("selection")], [
        html.strong([attribute.class("mono")], [
          element.text(name_of(node.function)),
        ]),
        element.text(
          "  flat "
          <> fmt.known(node.flat, u)
          <> " ("
          <> fmt.share(node.flat, of: total)
          <> ") · cum "
          <> fmt.known(node.cum, u)
          <> " ("
          <> fmt.share(node.cum, of: total)
          <> ")",
        ),
        focus_buttons(call_graph.node_key(node.function)),
      ])
    Error(Nil) ->
      ui.note(
        "Click a node to select it. Each node reads flat (self) · cumulative, "
        <> "as a share of the samples; a darker node has a larger "
        <> "cumulative share.",
      )
  }
}

// ------------------------------------------------------------ peek

fn peek_tab(
  data: ProfileModel,
  g: graph.Graph,
  peeks: List(peek.Peek),
  ui_state: UiState,
  u: Unit,
) -> Element(Msg) {
  let profile_data = data.profile
  let name_of = fn(id) { profile.name_of(profile_data, id) }

  // One selection serves every tab: a box in Flame or Icicle, a node in
  // Graph or a row in Top all name a function, and Peek lists that
  // function's callers and callees.
  let chosen = case ui_state.selected {
    Some(selected) ->
      function_at(data, selected)
      |> result.try(fn(id) {
        list.find(peeks, fn(entry) { entry.function == id })
      })
    None -> Error(Nil)
  }

  case chosen {
    Error(Nil) ->
      ui.note(
        "Select a box in Flame or Icicle, a node in Graph or a row in Top to see its callers and callees.",
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
        ui.note(peek_note(g)),
      ])
  }
}

/// What Peek says about where its lists come from. They are the edges of the
/// trimmed graph the Graph tab draws, so a function can have more callers or
/// callees in the full profile than are listed here.
///
/// ## Examples
///
/// ```gleam
/// profile_view.peek_note(g)
/// // -> "Callers and callees are those of the Graph tab ..."
/// ```
pub fn peek_note(g: graph.Graph) -> String {
  let base = "Callers and callees are those of the Graph tab's graph. "

  case g.dropped_nodes + g.dropped_edges {
    0 -> base <> "Nothing was pruned from it, so these lists are complete."
    pruned ->
      base
      <> int.to_string(pruned)
      <> " nodes or edges were pruned from it, so the full profile may have more."
  }
}

fn links_table(
  links: List(peek.Link),
  name_of: fn(Int) -> String,
  u: Unit,
) -> Element(Msg) {
  case links {
    [] -> ui.note("none in the drawn graph")
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

  case table.rows {
    [] -> nothing_measured(data)
    [_, ..] -> top_table(data, ui_state, u, index, total, shown)
  }
}

// The Top tab of a profile with no function in it. The honest sentence says
// what was asked and that nothing answered: a counters probe that matched
// functions and saw no call is a result, not a refusal to draw.
fn nothing_measured(data: ProfileModel) -> Element(Msg) {
  let info = data.header.info
  let matched = fmt.count(info.coverage.requested)
  let span = case info.took_ms {
    Some(ms) -> " in " <> fmt.duration_ms(ms)
    None -> ""
  }

  html.div([attribute.class("refusal")], [
    html.h3([], [element.text("Nothing was measured")]),
    html.p([], [
      element.text(case data.header.source {
        profile.SampledStacks(..) -> "The probe took no samples" <> span <> "."
        profile.TracedCounters
        | profile.TracedCalls
        | profile.AllocationCounts ->
          "No calls to the "
          <> matched
          <> " matched functions"
          <> span
          <> ". A function nobody called has no row."
      }),
    ]),
    html.p([], [
      element.text(
        "Trace again while the process is doing the work, or widen the module pattern.",
      ),
    ]),
  ])
}

fn top_table(
  data: ProfileModel,
  ui_state: UiState,
  u: Unit,
  index: Int,
  total: Int,
  shown: List(top.Row),
) -> Element(Msg) {
  let table = data.top

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
          ui.th("precision", None),
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
    html.td([], [ui.badge("muted", precision)]),
    html.td([attribute.class("num")], [flat]),
  ])
}
