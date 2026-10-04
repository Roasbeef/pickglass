import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleeunit/should
import lustre/element
import pickglass_core/layout/flame
import pickglass_core/measure.{Known, Missing}
import pickglass_core/profile
import pickglass_core/unit
import pickglass_web/chart/colour
import pickglass_web/chart/flame as flame_chart
import pickglass_web/chart/spark
import pickglass_web/fixture/stacks
import pickglass_web/key
import support

fn base_profile() -> profile.Profile {
  let assert Ok(p) = stacks.build(stacks.Base) as "the fixture profile builds"
  p
}

fn column(p: profile.Profile) -> profile.Column {
  let assert Ok(c) = profile.column_named(p, "samples") as "samples column"
  c
}

fn draw(layout: flame.Layout, facing: flame_chart.Facing) -> String {
  let p = base_profile()

  flame_chart.view(
    layout:,
    facing:,
    name_of: fn(id) { profile.name_of(p, id) },
    unit: unit.Count,
    selected: None,
    search: "",
    verdict: flame_chart.Directed,
    on_select: fn(box) { key.to_string(box) },
  )
  |> element.to_string
}

// The drawn rectangles are the layout's boxes and no more, so the element
// count inherits core's bound.
pub fn the_number_of_drawn_boxes_stays_within_the_layout_bound_test() {
  let p = base_profile()

  list.each([5, 12, 40, 2000], fn(limit) {
    let config = flame.Config(..flame.default_config, max_boxes: limit)
    let assert Ok(layout) = flame.layout(p, column(p), config)
      as "layout succeeds"

    let html = draw(layout, flame_chart.RootBelow)

    { support.count(html, "<rect") <= limit } |> should.be_true
    // The synthetic root is not drawn.
    support.count(html, "<rect") |> should.equal(list.length(layout.boxes) - 1)
  })
}

pub fn every_box_has_a_native_title_and_a_closed_colour_class_test() {
  let p = base_profile()
  let assert Ok(layout) = flame.layout(p, column(p), flame.default_config)
    as "layout succeeds"

  let html = draw(layout, flame_chart.RootBelow)

  support.count(html, "<title>") |> should.equal(list.length(layout.boxes) - 1)
  string.contains(html, "style=") |> should.be_false
}

pub fn the_icicle_mirrors_the_flame_test() {
  let p = base_profile()
  let assert Ok(layout) = flame.layout(p, column(p), flame.default_config)
    as "layout succeeds"

  let flame_html = draw(layout, flame_chart.RootBelow)
  let icicle_html = draw(layout, flame_chart.RootAbove)

  { flame_html != icicle_html } |> should.be_true
  support.count(flame_html, "<rect")
  |> should.equal(support.count(icicle_html, "<rect"))
}

pub fn colour_classes_come_from_a_closed_set_test() {
  [-5, -1, 0, 1, 11, 23, 24, 25, 59]
  |> list.each(fn(bucket) {
    colour.hue(bucket) |> string.starts_with("hue-") |> should.be_true
  })

  colour.diff(delta: 0, of: 10) |> should.equal("diff-same")
  colour.diff(delta: 5, of: 100) |> should.equal("diff-up-2")
  colour.diff(delta: -50, of: 100) |> should.equal("diff-down-3")
  colour.diff(delta: 1, of: 0) |> should.equal("diff-up-3")
}

pub fn a_gap_in_a_sparkline_breaks_the_line_and_is_not_zero_test() {
  let html =
    spark.view(
      [Known(3), Known(5), Missing(measure.BudgetExhausted), Known(4), Known(6)],
      unit: unit.Count,
    )
    |> element.to_string

  support.count(html, "spark-line") |> should.equal(2)
  support.count(html, "spark-gap") |> should.equal(1)
  string.contains(html, "1 missing") |> should.be_true
}

pub fn a_series_with_nothing_known_says_so_test() {
  let html =
    spark.view([Missing(measure.CounterDisabled)], unit: unit.Count)
    |> element.to_string

  string.contains(html, "no data") |> should.be_true
  string.contains(html, "<svg") |> should.be_false
}

pub fn keys_made_from_any_text_always_parse_test() {
  ["", "a b", "tab\there", "naïve ☃", string.repeat("x", 500), "ok-1.2:3_4"]
  |> list.each(fn(text) {
    key.parse(key.to_string(key.make(text))) |> result.is_ok |> should.be_true
  })
}
