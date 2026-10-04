import fixtures
import gleam/list
import gleam/option.{None, Some}
import pickglass_core/analysis/pattern
import pickglass_core/analysis/transform.{
  Display, DisplayOnly, DisplayPrune, EdgeFraction, Focus, Hide, Ignore,
  InvalidPattern, Matched, MatchedNothing, NodeCount, NodeFraction, SampleFilter,
  Show, ShowFrom, StackRewrite, TagFocus, TagIgnore, TagMatch,
}
import pickglass_core/profile
import pickglass_core/unit

// main calls a (which calls lists_map) and b.
fn sample_profile() -> profile.Profile {
  fixtures.labelled([
    #(["main", "a", "lists_map"], 10, [#("session", "s1")]),
    #(["main", "a"], 5, [#("session", "s1")]),
    #(["main", "b"], 20, [#("session", "s2"), #("role", "keeper")]),
    #(["main"], 1, []),
  ])
}

fn apply(steps: List(transform.Step)) -> transform.Applied {
  let p = sample_profile()
  let assert Ok(applied) = transform.apply(p, steps, fixtures.column(p))
  applied
}

fn total(applied: transform.Applied) -> Int {
  profile.total(applied.profile, fixtures.column(applied.profile))
}

pub fn an_empty_chain_changes_nothing_test() {
  let applied = apply([])
  assert applied.reports == []
  assert total(applied) == 36
  assert applied.profile == sample_profile()
}

pub fn focus_keeps_samples_through_a_function_test() {
  let applied = apply([Focus("^m:a/")])
  assert total(applied) == 15
  let assert [report] = applied.reports
  assert report.class == SampleFilter
  assert report.total_before == 36
  assert report.total_after == 15
  assert report.samples_before == 4
  assert report.samples_after == 2
  assert report.outcome == Matched(2)
}

pub fn ignore_drops_samples_through_a_function_test() {
  let applied = apply([Ignore("lists_map")])
  assert total(applied) == 26
  let assert [report] = applied.reports
  assert report.outcome == Matched(1)
}

pub fn a_filter_that_selects_nothing_says_so_test() {
  let applied = apply([Focus("nonexistent"), Ignore("also_nothing")])
  let assert [focus, ignore] = applied.reports
  assert focus.outcome == MatchedNothing
  assert focus.total_after == 0
  // The ignore after an empty focus has nothing to drop either.
  assert ignore.outcome == MatchedNothing
}

pub fn ignore_that_matches_nothing_changes_nothing_test() {
  let applied = apply([Ignore("nonexistent")])
  let assert [report] = applied.reports
  assert report.outcome == MatchedNothing
  assert report.total_before == report.total_after
}

// Hide shortens stacks and keeps the cost, charging it to the caller.
pub fn hide_rewrites_without_changing_totals_test() {
  let applied = apply([Hide("lists_map")])
  assert total(applied) == 36
  let assert [report] = applied.reports
  assert report.class == StackRewrite
  assert report.dropped_empty == 0
  assert report.outcome == Matched(1)
  // The 10 samples now end in a.
  let p = applied.profile
  let a = fixtures.id(p, "a")
  assert list.count(profile.samples(p), fn(s) { list.first(s.frames) == Ok(a) })
    == 2
}

// A sample left with no frames is dropped and counted, so the total
// falls by exactly its value.
pub fn hide_drops_and_counts_emptied_samples_test() {
  let applied = apply([Hide("^m:main/0$")])
  let assert [report] = applied.reports
  assert report.dropped_empty == 1
  assert report.total_before == 36
  assert report.total_after == 35
  assert report.samples_after == 3
}

pub fn show_keeps_only_matching_frames_test() {
  let applied = apply([Show("^m:b/")])
  // Only the sample through b keeps a frame; the others are emptied.
  assert total(applied) == 20
  let assert [report] = applied.reports
  assert report.class == StackRewrite
  assert report.dropped_empty == 3
  assert report.outcome == Matched(1)
}

// show_from drops the callers above the outermost match.
pub fn show_from_trims_the_root_side_test() {
  let applied = apply([ShowFrom("^m:a/")])
  assert total(applied) == 15
  let p = applied.profile
  let a = fixtures.id(p, "a")
  let map = fixtures.id(p, "lists_map")
  assert list.map(profile.samples(p), fn(s) { s.frames }) == [[map, a], [a]]
}

pub fn tag_focus_with_a_key_test() {
  let applied = apply([TagFocus(transform.parse_tag("session=s2"))])
  assert total(applied) == 20
  let applied = apply([TagFocus(transform.parse_tag("session=s1,s2"))])
  assert total(applied) == 35
}

// Without a key every pattern must match some key:value label.
pub fn tag_focus_without_a_key_needs_every_pattern_test() {
  let applied = apply([TagFocus(TagMatch(None, ["session:s2", "role:keeper"]))])
  assert total(applied) == 20
  let applied = apply([TagFocus(TagMatch(None, ["session:s2", "role:other"]))])
  assert total(applied) == 0
}

pub fn tag_ignore_drops_matching_samples_test() {
  let applied = apply([TagIgnore(transform.parse_tag("session=s1"))])
  assert total(applied) == 21
  let assert [report] = applied.reports
  assert report.outcome == Matched(2)
}

pub fn parse_tag_reads_both_forms_test() {
  assert transform.parse_tag("session=a,b")
    == TagMatch(Some("session"), ["a", "b"])
  assert transform.parse_tag("a") == TagMatch(None, ["a"])
}

// The chain reports the total before and after every step, in order.
pub fn reports_chain_totals_per_step_test() {
  let applied =
    apply([Focus("^m:a/"), Hide("lists_map"), Ignore("never_matches")])
  let totals =
    list.map(applied.reports, fn(r) { #(r.total_before, r.total_after) })
  assert totals == [#(36, 15), #(15, 15), #(15, 15)]
}

pub fn display_steps_collect_and_leave_samples_alone_test() {
  let applied =
    apply([NodeFraction(0.1), EdgeFraction(0.2), NodeCount(7), NodeCount(9)])
  assert applied.display == Display(Some(0.1), Some(0.2), Some(9))
  assert total(applied) == 36
  assert list.all(applied.reports, fn(r) {
    r.class == DisplayPrune && r.outcome == DisplayOnly
  })
}

pub fn classes_follow_the_table_test() {
  assert transform.class(Focus("a")) == SampleFilter
  assert transform.class(Ignore("a")) == SampleFilter
  assert transform.class(ShowFrom("a")) == SampleFilter
  assert transform.class(TagFocus(TagMatch(None, []))) == SampleFilter
  assert transform.class(TagIgnore(TagMatch(None, []))) == SampleFilter
  assert transform.class(Hide("a")) == StackRewrite
  assert transform.class(Show("a")) == StackRewrite
  assert transform.class(NodeFraction(0.1)) == DisplayPrune
}

pub fn a_bad_pattern_names_its_step_test() {
  let p = sample_profile()
  assert transform.apply(p, [Focus("a"), Hide("*oops")], fixtures.column(p))
    == Error(InvalidPattern(1, pattern.NothingToRepeat("*oops")))
}

// Patterns also match the source file of a function.
pub fn patterns_match_file_names_test() {
  let assert Ok(p) =
    profile.new(
      profile.TracedCalls,
      [profile.ValueType("t", unit.Count)],
      [
        profile.Function(
          0,
          "m",
          "f",
          0,
          Some("src/loom/f.gleam"),
          None,
          profile.NoLine,
        ),
        profile.Function(1, "m", "g", 0, None, None, profile.NoLine),
      ],
      [
        profile.Sample([0], [4], []),
        profile.Sample([1], [6], []),
      ],
    )
  let assert Ok(column) = profile.column(p, 0)
  let assert Ok(applied) = transform.apply(p, [Focus("loom/f.gleam")], column)
  assert profile.total(applied.profile, column) == 4
}

// An unsupported construct reaches the chain as an error naming its step.
pub fn unsupported_syntax_names_its_step_test() {
  let p = sample_profile()
  assert transform.apply(p, [Focus("a"), Ignore("(a|b)")], fixtures.column(p))
    == Error(InvalidPattern(1, pattern.UnsupportedSyntax("(a|b)", "(", 0)))
}
