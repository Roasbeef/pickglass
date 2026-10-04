//// A profile as a file the operator can download.
////
//// The profile page offers three formats. Collapsed stacks and speedscope
//// need call stacks, and core refuses a profile whose source has none; that
//// refusal is returned as text for the page to show beside the button, so a
//// counters profile gets a stated reason and not an empty file. A Chrome
//// trace is built from the profile's function totals as counter events at
//// one instant, because a profile has no timeline of its own; it carries
//// one slice for the probe's own span, so the trace opens with a labelled
//// extent. What each format leaves out is core's own list, returned with
//// the file and shown on the page.
////
//// The export is made from the profile after the page's filter chain, so a
//// file is what the operator saw and not the unfiltered original.

import gleam/list
import gleam/option.{None}
import gleam/result
import pickglass/downloads.{type Download, Download}
import pickglass_core/analysis/top
import pickglass_core/export.{type Export}
import pickglass_core/export/chrome_trace
import pickglass_core/export/collapsed
import pickglass_core/export/speedscope
import pickglass_core/profile.{type Column, type Profile}
import pickglass_web/msg

/// A built file with the label the page shows for it.
pub type Built {
  Built(label: String, download: Download, losses: List(String))
}

/// Why a format could not be built, with the label of the format.
pub type Refused {
  Refused(label: String, reason: String)
}

/// Build the file for a format. `title` names the probe the profile came
/// from, and `span_ms` is how long it ran.
///
/// ## Examples
///
/// ```gleam
/// profile_export.make(msg.AsCollapsed, "probe-3", 30_000, profile, column)
/// ```
pub fn make(
  choice: msg.ExportChoice,
  title: String,
  span_ms: Int,
  profile: Profile,
  column: Column,
) -> Result(Built, Refused) {
  case choice {
    msg.AsCollapsed ->
      collapsed.export(profile, column)
      |> finish("Collapsed stacks", title <> ".collapsed", "text/plain")
    msg.AsSpeedscope ->
      speedscope.export(profile)
      |> finish("Speedscope", title <> ".speedscope.json", "application/json")
    msg.AsChromeTrace ->
      totals_trace(title, span_ms, profile, column)
      |> finish("Chrome trace", title <> ".trace.json", "application/json")
  }
}

fn finish(
  made: Result(Export, export.ExportError),
  label: String,
  file_name: String,
  content_type: String,
) -> Result(Built, Refused) {
  case made {
    Ok(file) ->
      Ok(Built(
        label:,
        download: Download(file_name:, content_type:, body: file.body),
        losses: file.losses,
      ))
    Error(export.NoCallStacks(source:)) ->
      Error(Refused(
        label:,
        reason: "this profile has no call stacks ("
          <> source_text(source)
          <> "), and this format needs them.",
      ))
  }
}

fn source_text(source: profile.Source) -> String {
  case source {
    profile.SampledStacks(..) -> "sampled stacks"
    profile.TracedCalls -> "traced calls"
    profile.TracedCounters -> "traced counters"
    profile.AllocationCounts -> "allocation counts"
  }
}

// The trace needs no stacks, so it is built for every source: one slice for
// the probe's span and one counter event per function with that function's
// flat value in each column. A table that cannot be built has no counters.
fn totals_trace(
  title: String,
  span_ms: Int,
  profile: Profile,
  column: Column,
) -> Result(Export, export.ExportError) {
  let counters =
    top.table(profile, None, top.Sort(column:, key: top.ByFlat))
    |> result.map(fn(table) {
      list.map(table.rows, fn(row) {
        chrome_trace.Counter(
          name: row.name,
          at_ns: 0,
          values: list.map2(
            table.value_types,
            row.totals,
            fn(value_type, totals) { #(value_type.name, totals.flat) },
          ),
        )
      })
    })
    |> result.unwrap([])

  Ok(
    chrome_trace.export("pickglass", [
      chrome_trace.Track(id: 1, name: title, events: [
        chrome_trace.Slice(
          name: title,
          start_ns: 0,
          duration_ns: span_ms * 1_000_000,
          args: [],
        ),
        ..counters
      ]),
    ]),
  )
}
