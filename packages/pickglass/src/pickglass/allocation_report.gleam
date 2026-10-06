//// An allocation profile as text: what was counted, how well, and the
//// functions that allocated the most.
////
//// `pickglass profile --allocation` prints it when the probe ends, and the
//// same text is what `--format text` writes, so a report on the terminal and
//// one in a file say the same thing. The report is built from facts a capture
//// also keeps (the profile, the probe's cost record and counter facts, and the
//// target's word size), so it can be rebuilt from a file.
////
//// Three rules decide what it may say. A figure the probe did not measure is
//// a phrase and never zero: a called function with no allocation reading is
//// counted in a sentence of its own and is not a row. A count of words is
//// shown beside the word size it was taken with, and bytes appear only when
//// that size is known, as words times it. And the report states, in every
//// copy, that the words are cumulative allocation and are function totals, so
//// that no reader takes them for retained heap or reads a call stack into
//// them.
////
//// ## Flow
////
//// - `rows` reads the functions out of a profile, largest first.
//// - `render` writes the whole report, with a bounded number of functions.
//// - `table` writes the functions alone.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import pickglass/allocation_profile
import pickglass_core/capture
import pickglass_core/export/text
import pickglass_core/measure.{type Measurement, type Outcome}
import pickglass_core/profile.{type Profile}
import pickglass_web/fmt
import pickglass_web/view/ui

/// One traced function's totals.
pub type Row {
  Row(name: String, calls: Int, time_ns: Int, words: Int)
}

/// What a report is built from.
pub type Report {
  Report(
    /// How the processes were chosen, as a sentence, or empty when it is not
    /// known, as for a probe read back from a capture.
    scope: String,
    /// The agent's id for the probe.
    probe: String,
    /// The modules named, or none when they are not known.
    modules: List(String),
    /// How many functions the modules matched, when it is known.
    matched: Option(Int),
    /// What the probe asked for and could read.
    facts: capture.CounterFacts,
    /// The window the probe ran for, as the agent measured it.
    observed_ms: Measurement,
    outcome: Outcome,
    /// The size of a word on the target, in bytes, when it was read.
    word_size: Option(Int),
    rows: List(Row),
  )
}

/// The functions of an allocation profile, the largest allocator first and
/// ties in name order, so the same capture always prints the same table. A
/// profile that is not an allocation profile has none.
///
/// ## Examples
///
/// ```gleam
/// allocation_report.rows(profile)
/// // -> [Row("m:f/1", 5, 40_000, 300), ..]
/// ```
pub fn rows(found: Profile) -> List(Row) {
  case
    profile.column_named(found, allocation_profile.calls_column),
    profile.column_named(found, allocation_profile.time_column),
    profile.column_named(found, allocation_profile.words_column)
  {
    Ok(calls), Ok(time), Ok(words) ->
      list.filter_map(profile.samples(found), fn(sample) {
        case sample.frames {
          [id] ->
            Ok(Row(
              name: profile.name_of(found, id),
              calls: profile.sample_value(sample, calls),
              time_ns: profile.sample_value(sample, time),
              words: profile.sample_value(sample, words),
            ))
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) {
        order.break_tie(
          int.compare(b.words, a.words),
          string.compare(a.name, b.name),
        )
      })
    _, _, _ -> []
  }
}

/// The report, with at most `shown` functions in its table.
///
/// ## Examples
///
/// ```gleam
/// allocation_report.render(report, 15)
/// // -> "allocation profile of ...\n..."
/// ```
pub fn render(report: Report, shown: Int) -> String {
  let facts = report.facts
  let listed = list.length(report.rows)
  let caveats = [
    "caveats:",
    ..list.map(allocation_profile.caveats(facts, listed), fn(caveat) {
      "  " <> caveat
    })
  ]

  string.join(
    list.flatten([
      [
        "allocation profile"
          <> case report.scope {
          "" -> ""
          scope -> " of " <> scope
        },
        "probe "
          <> report.probe
          <> " counted calls, call time and allocated words"
          <> case report.modules {
          [] -> ""
          modules -> " of " <> string.join(modules, ", ")
        }
          <> " in "
          <> processes_text(facts.processes),
        "window: "
          <> fmt.duration_ms(facts.requested_ms)
          <> " asked for, "
          <> observed_text(report.observed_ms)
          <> " observed, "
          <> ui.truncation_text(report.outcome),
        functions_text(report.matched, facts, listed),
      ],
      unavailable_lines(facts),
      [
        totals_text(facts, report.word_size, listed),
        "",
        table(report.rows, report.word_size, shown),
        "",
      ],
      caveats,
    ]),
    "\n",
  )
}

fn processes_text(processes: Option(Int)) -> String {
  case processes {
    Some(1) -> "1 process"
    Some(count) -> fmt.count(count) <> " processes"
    None -> "an unrecorded number of processes"
  }
}

fn observed_text(observed: Measurement) -> String {
  case observed {
    measure.Known(ms) -> fmt.duration_ms(ms)
    measure.Missing(_) | measure.NotApplicable -> "not recorded"
  }
}

// How many functions the modules matched, how many were called, and how many
// of those the report lists, so a short table is not mistaken for a short
// profile.
fn functions_text(
  matched: Option(Int),
  facts: capture.CounterFacts,
  listed: Int,
) -> String {
  "functions: "
  <> case matched {
    Some(count) -> fmt.count(count) <> " matched, "
    None -> ""
  }
  <> fmt.count(facts.called)
  <> " called, "
  <> fmt.count(facts.read)
  <> " with an allocation reading, "
  <> fmt.count(listed)
  <> " listed"
}

// The counters the VM could not give, said as sentences. A probe with none
// says so, so a reader looking for the failure is told it did not happen.
fn unavailable_lines(facts: capture.CounterFacts) -> List(String) {
  case facts.unread, facts.invalidated {
    0, 0 -> [
      "unavailable: none; every called function had an allocation reading and no module was reloaded",
    ]
    unread, invalidated ->
      list.flatten([
        case unread {
          0 -> []
          _ -> [
            "unavailable: "
            <> fmt.count(unread)
            <> " called functions have no allocation reading; they are not listed and are not zero",
          ]
        },
        case invalidated {
          0 -> []
          _ -> [
            "invalidated: "
            <> fmt.count(invalidated)
            <> " traced functions were invalidated by a module reload, so this snapshot is suspect",
          ]
        },
      ])
  }
}

// The words allocated, in the unit the VM counts them and, when the size of a
// word is known, in bytes. The sum is over every function that was read, and
// the listed functions are put against it when the list was cut.
fn totals_text(
  facts: capture.CounterFacts,
  word_size: Option(Int),
  listed: Int,
) -> String {
  "allocated words: "
  <> fmt.count(facts.total_words)
  <> " over "
  <> fmt.count(facts.read)
  <> " functions read, "
  <> case word_size {
    Some(size) ->
      "word size "
      <> int.to_string(size)
      <> " bytes, "
      <> fmt.count(facts.total_words * size)
      <> " bytes"
    None -> "word size not read, so no bytes are derived"
  }
  <> case facts.read > listed {
    True -> "; the table lists the " <> fmt.count(listed) <> " largest"
    False -> ""
  }
}

/// The functions as a table, at most `shown` of them, in the order given. The
/// bytes column is there only when the size of a word is known.
///
/// ## Examples
///
/// ```gleam
/// allocation_report.table(rows, Some(8), 15)
/// ```
pub fn table(rows: List(Row), word_size: Option(Int), shown: Int) -> String {
  let header =
    "  "
    <> string.pad_end("function", 46, " ")
    <> string.pad_start("calls", 12, " ")
    <> string.pad_start("call time", 14, " ")
    <> string.pad_start("words", 16, " ")
    <> case word_size {
      Some(_) -> string.pad_start("bytes", 16, " ")
      None -> ""
    }
    <> string.pad_start("words/call", 12, " ")

  case rows {
    [] -> "  no function was called with an allocation reading"
    _ ->
      string.join(
        [header, ..list.map(list.take(rows, shown), row_line(_, word_size))],
        "\n",
      )
  }
}

fn row_line(row: Row, word_size: Option(Int)) -> String {
  "  "
  <> string.pad_end(string.slice(row.name, 0, 45), 46, " ")
  <> string.pad_start(fmt.count(row.calls), 12, " ")
  <> string.pad_start(text.time_text(row.time_ns), 14, " ")
  <> string.pad_start(fmt.count(row.words), 16, " ")
  <> case word_size {
    Some(size) -> string.pad_start(fmt.count(row.words * size), 16, " ")
    None -> ""
  }
  <> string.pad_start(per_call(row), 12, " ")
}

/// Words per call to a tenth of a word, which stays comparable between probes
/// of different windows. A function is only listed when it was called, so the
/// division is by a positive count; a malformed capture with none reads "not
/// defined" and does not divide by zero.
///
/// ## Examples
///
/// ```gleam
/// allocation_report.per_call(Row("m:f/1", 4, 10_000, 10))
/// // -> "2.5"
/// ```
pub fn per_call(row: Row) -> String {
  case row.calls > 0 {
    True -> {
      let tenths = row.words * 10 / row.calls

      fmt.count(tenths / 10) <> "." <> int.to_string(tenths % 10)
    }
    False -> "not defined"
  }
}
