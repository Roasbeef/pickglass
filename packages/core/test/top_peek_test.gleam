import fixtures
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pickglass_core/analysis/graph.{Config, Direct, Residual}
import pickglass_core/analysis/pattern
import pickglass_core/analysis/peek
import pickglass_core/analysis/top.{ByCum, ByFlat, Sort, Totals}
import pickglass_core/analysis/transform
import pickglass_core/profile.{type Profile}
import pickglass_core/unit

fn short(name: String) -> String {
  name |> string.replace("m:", "") |> string.replace("/0", "")
}

fn table(
  p: Profile,
  base: option.Option(Profile),
  key: top.SortKey,
) -> top.Table {
  let assert Ok(t) = top.table(p, base, Sort(fixtures.column(p), key))
  t
}

fn rows(t: top.Table) -> List(#(String, Int, Int)) {
  list.map(t.rows, fn(r) {
    let assert [Totals(flat, cum)] = r.totals
    #(short(r.name), flat, cum)
  })
}

pub fn flat_and_cum_per_function_test() {
  let p = fixtures.calls([#(["a", "b"], 7), #(["a", "c"], 3), #(["a"], 2)])
  assert rows(table(p, None, ByFlat))
    == [#("b", 7, 7), #("c", 3, 3), #("a", 2, 12)]
  assert rows(table(p, None, ByCum))
    == [#("a", 2, 12), #("b", 7, 7), #("c", 3, 3)]
}

pub fn recursion_counts_cum_once_test() {
  let p = fixtures.calls([#(["a", "b", "b"], 10)])
  assert rows(table(p, None, ByFlat)) == [#("b", 10, 10), #("a", 0, 10)]
}

pub fn ties_break_by_name_test() {
  let p = fixtures.calls([#(["z"], 5), #(["y"], 5), #(["x"], 5)])
  assert list.map(rows(table(p, None, ByFlat)), fn(r) { r.0 })
    == ["x", "y", "z"]
}

pub fn the_table_carries_the_column_totals_test() {
  let p = fixtures.calls([#(["a"], 4), #(["b"], 6)])
  assert table(p, None, ByFlat).totals == [10]
  assert list.all(table(p, None, ByFlat).rows, fn(r) { r.delta == [] })
}

pub fn there_is_a_column_per_value_type_test() {
  let assert Ok(p) =
    profile.new(
      profile.TracedCalls,
      [
        profile.ValueType("samples", unit.Count),
        profile.ValueType("time", unit.Nanoseconds),
      ],
      [profile.Function(0, "m", "a", 0, None, None, profile.NoLine)],
      [
        profile.Sample([0], [2, 200], []),
        profile.Sample([0], [3, 300], []),
      ],
    )
  let assert Ok(time) = profile.column(p, 1)
  let assert Ok(t) = top.table(p, None, Sort(time, ByFlat))
  let assert [row] = t.rows
  assert row.totals == [Totals(5, 5), Totals(500, 500)]
  assert t.totals == [5, 500]
}

pub fn deltas_against_a_base_test() {
  let base = fixtures.calls([#(["a", "b"], 5), #(["a", "gone"], 4)])
  let candidate = fixtures.calls([#(["a", "b"], 8), #(["a", "new"], 1)])
  let t = table(candidate, Some(base), ByCum)
  let delta = fn(wanted: String) {
    let assert Ok(row) = list.find(t.rows, fn(r) { short(r.name) == wanted })
    row
  }
  assert { delta("b") }.delta == [Totals(3, 3)]
  assert { delta("new") }.delta == [Totals(1, 1)]
  // A function only in the base has zero totals and a negative delta.
  assert { delta("gone") }.delta == [Totals(-4, -4)]
  assert { delta("gone") }.totals == [Totals(0, 0)]
  assert { delta("gone") }.function == None
  assert { delta("a") }.delta == [Totals(0, 0)]
}

pub fn identical_profiles_have_zero_deltas_test() {
  let p = fixtures.calls([#(["a", "b"], 5), #(["c"], 2)])
  let t = table(p, Some(p), ByFlat)
  assert list.all(t.rows, fn(r) { r.delta == [Totals(0, 0)] })
}

pub fn a_base_with_other_value_types_is_refused_test() {
  let p = fixtures.calls([#(["a"], 1)])
  let assert Ok(other) =
    profile.new(
      profile.TracedCalls,
      [profile.ValueType("time", unit.Nanoseconds)],
      [],
      [],
    )
  assert top.table(p, Some(other), Sort(fixtures.column(p), ByFlat))
    == Error(top.IncompatibleBase)
}

// ------------------------------------------------------------------- peek

fn diamond() -> Profile {
  fixtures.calls([
    #(["main", "left", "work"], 30),
    #(["main", "right", "work"], 10),
    #(["main", "left"], 5),
  ])
}

fn graph_of(p: Profile) -> graph.Graph {
  let assert Ok(g) =
    graph.build(
      p,
      fixtures.column(p),
      Config(..graph.default_config, node_count: 0),
    )
  g
}

pub fn peek_lists_callers_and_callees_test() {
  let p = diamond()
  let g = graph_of(p)
  let assert Ok(left) = peek.at(g, fixtures.id(p, "left"))
  assert left.flat == 5
  assert left.cum == 35
  assert list.map(left.callers, fn(l) { #(l.function, l.weight) })
    == [#(fixtures.id(p, "main"), 35)]
  assert list.map(left.callees, fn(l) { #(l.function, l.weight, l.kind) })
    == [#(fixtures.id(p, "work"), 30, Direct)]
}

pub fn callers_are_heaviest_first_test() {
  let p = diamond()
  let g = graph_of(p)
  let assert Ok(work) = peek.at(g, fixtures.id(p, "work"))
  assert list.map(work.callers, fn(l) { l.weight }) == [30, 10]
  assert work.callees == []
}

pub fn peek_of_an_absent_function_is_nothing_test() {
  let p = diamond()
  assert peek.at(graph_of(p), 99) == Error(Nil)
}

pub fn peek_matches_by_name_test() {
  let p = diamond()
  let assert Ok(found) = peek.matching(p, graph_of(p), "m:left|m:right")
  assert list.length(found) == 2
  let assert Ok(none) = peek.matching(p, graph_of(p), "nonexistent")
  assert none == []
  assert peek.matching(p, graph_of(p), "*bad")
    == Error(pattern.NothingToRepeat("*bad"))
}

pub fn peek_marks_residual_calls_test() {
  let p = fixtures.calls([#(["main", "mid", "leaf"], 10)])
  let g =
    graph.build(
      p,
      fixtures.column(p),
      Config(..graph.default_config, node_count: 2),
    )
  let assert Ok(g) = g
  let assert Ok(leaf) = peek.at(g, fixtures.id(p, "leaf"))
  assert list.map(leaf.callers, fn(l) { l.kind }) == [Residual]
}

pub fn display_settings_override_the_config_test() {
  let applied = transform.Display(Some(0.1), None, Some(5))
  assert graph.with_display(graph.default_config, applied)
    == Config(node_fraction: 0.1, edge_fraction: 0.001, node_count: 5)
}
