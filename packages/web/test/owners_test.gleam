import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import pickglass_core/measure.{Known, NotApplicable}
import pickglass_web/census/owners
import pickglass_web/fixture
import pickglass_web/model
import pickglass_web/page
import support

fn info() -> model.PanelInfo {
  fixture.owners().info
}

// The unknown row exists even for an empty census.
pub fn the_unknown_group_is_present_for_an_empty_census_test() {
  let page = owners.build(info(), [], [], None, fn(_) { Known(0) })

  page.rows |> should.equal([])
  page.unknown.label |> should.equal("unknown")
  page.unknown.procs |> should.equal(Known(0))
  page.unknown.heap_cap |> should.equal(NotApplicable)
}

pub fn the_unknown_row_is_drawn_even_when_empty_test() {
  let attributed =
    list.filter(fixture.census(), fn(p) { p.owner_label != "unknown" })

  let page = owners.build(info(), attributed, [], None, fn(_) { Known(0) })

  page.unknown.members |> should.equal([])
}

pub fn the_unknown_group_collects_unclaimed_processes_test() {
  let page = fixture.owners()

  list.length(page.unknown.members) |> should.equal(3)
  page.labelled |> should.equal(#(11, 3))
}

// Heap capacity is totalled; binary references never are.
pub fn the_overlapping_column_is_never_totalled_test() {
  let page = fixture.owners()

  list.each(list.append(page.rows, [page.unknown]), fn(row) {
    row.binary_refs |> should.equal(NotApplicable)
  })

  let html = support.html_of(page.Owners)
  string.contains(html, "≈ not summed") |> should.be_true
}

pub fn groups_are_ordered_by_heap_capacity_test() {
  let page = fixture.owners()

  let groups = list.filter(page.rows, fn(r) { r.kind == model.OwnerGroup })

  list.map(groups, fn(r) { r.label })
  |> should.equal(["session:s-12", "daemon:core", "session:s-07"])
}

pub fn a_group_total_is_the_sum_of_its_members_test() {
  let page = fixture.owners()
  let assert [first, ..] = page.rows as "has a first group"

  first.procs |> should.equal(Known(5))
  first.unread |> should.equal(0)
}

pub fn a_total_over_unread_members_is_marked_a_lower_bound_test() {
  let census =
    list.map(fixture.census(), fn(p) {
      case p.pid_text {
        "<0.4412.0>" ->
          model.ProcRow(..p, heap_cap: measure.Missing(measure.ProcessExited))
        _ -> p
      }
    })

  let page = owners.build(info(), census, [], None, fn(_) { Known(0) })
  let assert [first, ..] = page.rows as "has a first group"

  first.unread |> should.equal(1)
}

pub fn a_missing_total_is_not_a_zero_test() {
  let only_missing =
    list.map(list.take(fixture.census(), 1), fn(p) {
      model.ProcRow(..p, heap_cap: measure.Missing(measure.CounterDisabled))
    })

  let page = owners.build(info(), only_missing, [], None, fn(_) { Known(0) })
  let assert [first, ..] = page.rows as "has a group"

  first.heap_cap |> should.equal(measure.Missing(measure.CounterDisabled))
}
