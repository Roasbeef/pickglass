//// Two captures' allocation profiles side by side, as text.
////
//// `pickglass compare` prints it after its figures when either capture holds a
//// probe that counted allocation. It reads the newest such probe of each
//// capture, puts the functions of the two against each other by name, and
//// says for each whether the allocated words moved.
////
//// What it compares is a function total over a window, so it states the
//// limits of that in the output and not only here. The totals are cumulative
//// over each probe's own window and processes, so two probes that ran for
//// different times are put against each other by words per call as well as by
//// words. The functions are the ones each probe listed (the agent keeps the
//// 200 that allocated the most), so a function one capture lists and the other
//// does not is shown as not listed there, which is neither zero nor absent
//// from the code. A direction is stated only where core's comparability
//// allows it, as for the figures, and a word count is never compared across
//// two different word sizes.
////
//// ## Flow
////
//// - `side_of` reads one capture's newest allocation probe.
//// - `lines` compares two sides and returns the section's lines, or none when
////   neither capture has an allocation probe.
//// - `both` builds the section from two sides, `functions` lines their
////   functions up by name and `function_line` writes one of them.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import pickglass/allocation_report.{type Row}
import pickglass/capture_build
import pickglass/capture_file.{type Loaded}
import pickglass/probe_book
import pickglass_core/capture
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/policy
import pickglass_core/provenance
import pickglass_web/fmt

/// How many functions the comparison lists.
pub const functions_shown = 20

/// Whether the two captures counted in words of the same size. A word count
/// from a 4-byte-word target and one from an 8-byte-word target are not the
/// same quantity.
type WordSizes {
  SameWordSize
  DifferentWordSizes
}

/// One capture's newest allocation probe.
pub type Side {
  Side(
    probe: String,
    facts: capture.CounterFacts,
    observed_ms: Measurement,
    word_size: Int,
    rows: List(Row),
  )
}

/// The newest allocation probe of a capture that finished with a profile and
/// the facts about it, or `Error(Nil)` when there is none.
///
/// ## Examples
///
/// ```gleam
/// allocation_compare.side_of(loaded)
/// // -> Ok(Side(probe: "7", ..))
/// ```
pub fn side_of(loaded: Loaded) -> Result(Side, Nil) {
  probe_book.of_records(loaded.capture.records)
  |> list.find_map(fn(probe) {
    case probe.kind, probe.state {
      policy.CallMemory,
        probe_book.Finished(
          profile: Some(found),
          cost: capture.ProbeCost(counters: Some(facts), wall_ms:, ..),
          ..,
        )
      ->
        Ok(Side(
          probe: probe.id,
          facts:,
          observed_ms: wall_ms,
          word_size: capture_build.runtime_of(loaded.capture.header).word_size,
          rows: allocation_report.rows(found),
        ))
      _, _ -> Error(Nil)
    }
  })
}

/// The comparison's lines. Empty when neither capture has an allocation
/// probe, so a capture of anything else compares exactly as it did.
///
/// ## Examples
///
/// ```gleam
/// allocation_compare.lines(baseline, candidate, comparability)
/// // -> ["allocation: ...", ..]
/// ```
pub fn lines(
  baseline: Loaded,
  candidate: Loaded,
  comparability: provenance.Comparability,
) -> List(String) {
  case side_of(baseline), side_of(candidate) {
    Error(Nil), Error(Nil) -> []
    Ok(_), Error(Nil) -> [
      "",
      "allocation: only the baseline holds an allocation probe, so there is nothing to compare",
    ]
    Error(Nil), Ok(_) -> [
      "",
      "allocation: only the candidate holds an allocation probe, so there is nothing to compare",
    ]
    Ok(before), Ok(after) -> both(before, after, comparability)
  }
}

fn both(
  before: Side,
  after: Side,
  comparability: provenance.Comparability,
) -> List(String) {
  let judge = fn(a: Int, b: Int) {
    provenance.compare_measurements(
      comparability,
      measure.Counter,
      Known(a),
      Known(b),
    )
  }
  let sizes = case before.word_size == after.word_size {
    True -> SameWordSize
    False -> DifferentWordSizes
  }

  list.flatten([
    [
      "",
      "allocation: function totals of the newest allocation probe in each capture",
      "  baseline:  " <> side_text(before),
      "  candidate: " <> side_text(after),
      case sizes {
        SameWordSize ->
          "  word size: " <> int.to_string(before.word_size) <> " bytes in both"
        DifferentWordSizes ->
          "  word size differs ("
          <> int.to_string(before.word_size)
          <> " | "
          <> int.to_string(after.word_size)
          <> " bytes): a word count is not compared across them, and no direction is stated"
      },
      "  totals are cumulative over each probe's own window; when the windows or the traced processes differ, compare the words per call",
      "",
      "  "
        <> string.pad_end("allocated words, every function read", 46, " ")
        <> string.pad_start(fmt.count(before.facts.total_words), 16, " ")
        <> string.pad_start(fmt.count(after.facts.total_words), 16, " ")
        <> "  "
        <> verdict(case sizes {
        SameWordSize -> judge(before.facts.total_words, after.facts.total_words)
        DifferentWordSizes -> provenance.NoReading
      }),
      "  "
        <> string.pad_end("function", 46, " ")
        <> string.pad_start("baseline", 16, " ")
        <> string.pad_start("candidate", 16, " ")
        <> "  change",
    ],
    list.map(functions(before, after), fn(entry) {
      function_line(entry, sizes, judge)
    }),
    [
      "  functions a probe lists are the ones that allocated the most, at most 200; one listed by only one capture is not listed in the other, which is not zero words",
    ],
  ])
}

fn side_text(side: Side) -> String {
  "probe "
  <> side.probe
  <> ", "
  <> fmt.duration_ms(side.facts.requested_ms)
  <> " asked for, "
  <> case side.observed_ms {
    Known(ms) -> fmt.duration_ms(ms)
    measure.Missing(_) | measure.NotApplicable -> "not recorded"
  }
  <> " observed, "
  <> case side.facts.processes {
    Some(count) -> int.to_string(count) <> " processes"
    None -> "an unrecorded number of processes"
  }
  <> ", "
  <> fmt.count(side.facts.called)
  <> " called, "
  <> fmt.count(side.facts.read)
  <> " read, "
  <> fmt.count(side.facts.unread)
  <> " unread, "
  <> fmt.count(side.facts.invalidated)
  <> " invalidated"
}

// A function in either capture, with what each one listed for it.
type Entry {
  Entry(name: String, before: Option(Row), after: Option(Row))
}

// The functions of both captures by name, those listed by both first and by
// how far their words moved, then those listed by one, largest first. The list
// is cut at `functions_shown`.
fn functions(before: Side, after: Side) -> List(Entry) {
  let earlier =
    dict.from_list(list.map(before.rows, fn(row) { #(row.name, row) }))
  let later = dict.from_list(list.map(after.rows, fn(row) { #(row.name, row) }))
  let names =
    list.append(
      list.map(before.rows, fn(row) { row.name }),
      list.map(after.rows, fn(row) { row.name }),
    )
    |> list.unique

  names
  |> list.map(fn(name) {
    Entry(
      name:,
      before: option.from_result(dict.get(earlier, name)),
      after: option.from_result(dict.get(later, name)),
    )
  })
  |> list.sort(fn(a, b) {
    order.break_tie(
      int.compare(weight(b), weight(a)),
      string.compare(a.name, b.name),
    )
  })
  |> list.take(functions_shown)
}

// How far apart the two captures' words are, or how many words the one that
// listed it had. A function listed by both ranks by its movement, and one
// listed by one by its size, both in words, so the largest changes come first.
fn weight(entry: Entry) -> Int {
  case entry.before, entry.after {
    Some(a), Some(b) -> int.absolute_value(b.words - a.words)
    Some(only), None | None, Some(only) -> only.words
    None, None -> 0
  }
}

fn function_line(
  entry: Entry,
  sizes: WordSizes,
  judge: fn(Int, Int) -> provenance.Judgement,
) -> String {
  let words = fn(row: Option(Row)) {
    case row {
      Some(found) -> fmt.count(found.words)
      None -> "not listed"
    }
  }

  "  "
  <> string.pad_end(string.slice(entry.name, 0, 45), 46, " ")
  <> string.pad_start(words(entry.before), 16, " ")
  <> string.pad_start(words(entry.after), 16, " ")
  <> "  "
  <> case entry.before, entry.after, sizes {
    Some(a), Some(b), SameWordSize ->
      "words "
      <> verdict(judge(a.words, b.words))
      <> ", per call "
      <> per_call_verdict(a, b, judge)
    Some(_), Some(_), DifferentWordSizes -> "no direction: word sizes differ"
    Some(_), None, _ -> "not listed in the candidate"
    None, Some(_), _ -> "not listed in the baseline"
    None, None, _ -> ""
  }
}

// What a function allocated per call, in tenths of a word, which is the figure
// that stays comparable when the two windows saw different amounts of work. A
// function listed with no calls has no per-call figure.
fn per_call_verdict(
  before: Row,
  after: Row,
  judge: fn(Int, Int) -> provenance.Judgement,
) -> String {
  case before.calls > 0, after.calls > 0 {
    True, True ->
      verdict(judge(
        before.words * 10 / before.calls,
        after.words * 10 / after.calls,
      ))
      <> " ("
      <> allocation_report.per_call(before)
      <> " | "
      <> allocation_report.per_call(after)
      <> ")"
    _, _ -> "no reading"
  }
}

fn verdict(judgement: provenance.Judgement) -> String {
  case judgement {
    provenance.Moved(provenance.Increased) -> "higher"
    provenance.Moved(provenance.Decreased) -> "lower"
    provenance.Moved(provenance.Unchanged) -> "unchanged"
    provenance.InsideNoise(..) -> "within variation"
    provenance.Withheld(blocking:) ->
      "withheld ("
      <> string.join(list.map(blocking, provenance.field_name), ", ")
      <> ")"
    provenance.NoReading -> "no reading"
  }
}
