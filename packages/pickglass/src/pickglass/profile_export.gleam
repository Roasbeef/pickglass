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
//// file is what the operator saw and not the unfiltered original. That
//// includes the choice of samples: when the page shows only the samples taken
//// on a scheduler, the file holds only those, and the list of what it does
//// not carry says how many waiting samples were left out.

import gleam/list
import gleam/option.{None}
import gleam/result
import pickglass/downloads.{type Download, Download}
import pickglass/probe_book.{type ProbeRecord}
import pickglass_core/analysis/top
import pickglass_core/export.{type Export}
import pickglass_core/export/chrome_trace
import pickglass_core/export/collapsed
import pickglass_core/export/speedscope
import pickglass_core/profile.{type Column, type Profile}
import pickglass_core/profile/activity
import pickglass_web/fmt
import pickglass_web/model
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
/// from, and `span_ms` is how long it ran. `samples` says which of the
/// probe's samples `profile` holds, so the list of what the file does not
/// carry can name the ones left out.
///
/// ## Examples
///
/// ```gleam
/// profile_export.make(
///   msg.AsCollapsed,
///   "probe-3",
///   30_000,
///   profile,
///   column,
///   model.NoStatuses,
/// )
/// ```
pub fn make(
  choice: msg.ExportChoice,
  title: String,
  span_ms: Int,
  profile: Profile,
  column: Column,
  samples: model.ActivityView,
) -> Result(Built, Refused) {
  use built <- result.map(case choice {
    msg.AsCollapsed ->
      collapsed.export(profile, column)
      |> finish("Collapsed stacks", title <> ".collapsed", "text/plain")
    msg.AsSpeedscope ->
      speedscope.export(profile)
      |> finish("Speedscope", title <> ".speedscope.json", "application/json")
    msg.AsChromeTrace ->
      totals_trace(title, span_ms, profile, column)
      |> finish("Chrome trace", title <> ".trace.json", "application/json")
  })

  Built(..built, losses: list.append(left_out(samples), built.losses))
}

/// What a file made from a profile drawn this way leaves out because of the
/// choice of samples: the waiting samples, with how many, when the profile
/// is cut to the samples taken on a scheduler. Nothing is left out when
/// every sample is included or the profile has no statuses.
///
/// ## Examples
///
/// ```gleam
/// profile_export.left_out(model.Statuses(OnSchedulerOnly, split, None))
/// // -> ["Waiting samples: 2,596 ..."]
/// ```
pub fn left_out(samples: model.ActivityView) -> List(String) {
  case samples {
    model.NoStatuses -> []
    model.Statuses(inclusion: activity.IncludeWaiting, ..) -> []
    model.Statuses(inclusion: activity.OnSchedulerOnly, split:, ..) ->
      case split.waiting {
        0 -> []
        waiting -> [
          "Waiting samples: only the "
          <> fmt.count(split.on_scheduler + split.unstated)
          <> " samples taken on a scheduler are included; "
          <> fmt.count(waiting)
          <> " taken while a process waited are left out.",
        ]
      }
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

/// Build the Chrome trace of a tracing probe's timeline from what the probe
/// kept. `label_of` names a traced process from its pid text for the thread
/// names. A probe of the other kind, or one that kept no slices, is refused
/// with the reason.
///
/// ## Examples
///
/// ```gleam
/// profile_export.make_trace(msg.EventsTrace, probe, fn(pid) { pid })
/// ```
pub fn make_trace(
  which: msg.TraceExport,
  probe: ProbeRecord,
  label_of: fn(String) -> String,
) -> Result(Built, Refused) {
  let title = "probe-" <> probe.id

  case which, probe.detail {
    msg.EventsTrace, probe_book.SchedulingDetail(snapshot:) ->
      Ok(trace_built(
        "Scheduling trace",
        title <> ".scheduling.trace.json",
        chrome_trace.events("pickglass " <> title, snapshot, label_of),
      ))
    msg.CallsTrace, probe_book.CallSlices(snapshot:) ->
      Ok(trace_built(
        "Call trace",
        title <> ".calls.trace.json",
        chrome_trace.calls("pickglass " <> title, snapshot, label_of),
      ))
    msg.EventsTrace, _ ->
      Error(Refused(
        label: "Scheduling trace",
        reason: "no scheduling and collection recording is held to export.",
      ))
    msg.CallsTrace, _ ->
      Error(Refused(
        label: "Call trace",
        reason: "no call tree probe that kept call slices is held to export.",
      ))
  }
}

fn trace_built(label: String, file_name: String, file: Export) -> Built {
  Built(
    label:,
    download: Download(
      file_name:,
      content_type: "application/json",
      body: file.body,
    ),
    losses: file.losses,
  )
}
