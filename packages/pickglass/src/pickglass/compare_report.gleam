//// `pickglass compare BASELINE CANDIDATE`: two captures side by side, as
//// text.
////
//// The command line shows what the compare page shows, from the same code.
//// It reads both files through the capture reader, checks each footer
//// digest, builds the figures with `compare_build`, and asks core's
//// `provenance.comparability` which fields differ and which of those block
//// a verdict. A figure's direction is stated only where core's
//// `compare_measurements` says it may be; where it may not, the line says
//// the verdict is withheld and names the fields that block it.
////
//// `render` is pure so it can be tested on two hand-made captures. `run`
//// reads the files and prints.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import pickglass/capture_file.{type Loaded}
import pickglass/compare_build
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/provenance
import pickglass_core/unit.{type Unit}
import pickglass_web/model
import pickglass_web/view/compare as compare_view

/// Read two captures and print the comparison. The exit status is zero when
/// both files were read, whatever the verdict, and one when either could
/// not be.
///
/// ## Examples
///
/// ```gleam
/// compare_report.run("before.pgcap", "after.pgcap")
/// // -> 0
/// ```
pub fn run(baseline: String, candidate: String) -> Int {
  let report = {
    use first <- result.try(capture_file.read(baseline))
    use second <- result.try(capture_file.read(candidate))
    use page <- result.map(compare_build.build(
      baseline,
      first,
      candidate,
      second,
    ))

    render(page, digest_line(first), digest_line(second))
  }

  case report {
    Ok(text) -> {
      io.println(text)

      0
    }
    Error(message) -> {
      io.println_error("pickglass: " <> message)

      1
    }
  }
}

fn digest_line(loaded: Loaded) -> String {
  case loaded.digest {
    capture_file.DigestVerified -> "footer digest verified"
    capture_file.DigestMismatched ->
      "FOOTER DIGEST DOES NOT MATCH, the file was changed after it was written"
    capture_file.NoDigestToCheck -> "no footer, the capture may be cut short"
  }
}

/// The report as text. `baseline_note` and `candidate_note` say how each
/// file's integrity check went.
///
/// ## Examples
///
/// ```gleam
/// compare_report.render(page, "footer digest verified", "no footer")
/// ```
pub fn render(
  page: model.CompareModel,
  baseline_note: String,
  candidate_note: String,
) -> String {
  let comparability = provenance.comparability(page.baseline, page.candidate)
  let blocking = provenance.blocking_fields(comparability)

  string.join(
    list.flatten([
      [
        "baseline:  " <> page.baseline_name <> " (" <> baseline_note <> ")",
        "candidate: " <> page.candidate_name <> " (" <> candidate_note <> ")",
        "",
        "comparability",
      ],
      list.map(comparability.fields, fn(entry) {
        field_line(entry, page.baseline, page.candidate)
      }),
      [
        "",
        case blocking {
          [] -> "verdict: comparable"
          fields ->
            "verdict: MISMATCH, "
            <> string.join(list.map(fields, provenance.field_name), ", ")
            <> " block a statement of direction"
        },
        "",
        "figures",
      ],
      list.map(page.rows, fn(row) { figure_line(row, comparability) }),
      [
        "",
        case page.diff {
          Some(_) -> "a differential flame is available on the compare page"
          None ->
            "no differential flame: both captures need a sampled-stacks profile"
        },
      ],
    ]),
    "\n",
  )
}

// A field's result and, beside it, the value each capture holds, as the page
// shows them. "Not recorded" means the capture lacks part of the field, which
// the values make visible: a budget with its top and deadline stated and its
// event limit absent is not an unknown budget.
fn field_line(
  entry: #(provenance.Field, provenance.FieldResult),
  baseline: provenance.Provenance,
  candidate: provenance.Provenance,
) -> String {
  let name = string.pad_end(provenance.field_name(entry.0), 10, " ")
  let values =
    "  ["
    <> compare_view.field_value(entry.0, baseline)
    <> " | "
    <> compare_view.field_value(entry.0, candidate)
    <> "]"

  case entry.1 {
    provenance.Same -> "  " <> name <> "same" <> values
    provenance.DiffersExpected -> "  " <> name <> "differs (expected)" <> values
    provenance.DiffersBlocking(detail:) ->
      "  " <> name <> "differs, blocks: " <> detail
    provenance.NotRecorded -> "  " <> name <> "not recorded" <> values
  }
}

fn figure_line(
  row: model.CompareRow,
  comparability: provenance.Comparability,
) -> String {
  let line =
    "  "
    <> string.pad_end(row.label, 30, " ")
    <> string.pad_start(text_of(row.baseline, row.unit), 16, " ")
    <> string.pad_start(text_of(row.candidate, row.unit), 16, " ")
    <> "  "
    <> verdict_text(
      provenance.compare_against_noise(
        comparability,
        row.kind,
        row.baseline,
        row.candidate,
        row.baseline_band,
        row.candidate_band,
      ),
      row.unit,
    )

  case row.baseline_band, row.candidate_band {
    None, None -> line
    base, cand ->
      line
      <> "\n"
      <> string.pad_end("", 32, " ")
      <> "varied inside each capture: "
      <> band_text(base, row.unit)
      <> " | "
      <> band_text(cand, row.unit)
  }
}

fn band_text(band: option.Option(provenance.Band), in u: Unit) -> String {
  case band {
    Some(seen) ->
      text_of(Known(seen.low), u) <> " to " <> text_of(Known(seen.high), u)
    None -> "no variation seen"
  }
}

fn verdict_text(judgement: provenance.Judgement, in u: Unit) -> String {
  case judgement {
    provenance.Moved(provenance.Increased) -> "higher"
    provenance.Moved(provenance.Decreased) -> "lower"
    provenance.Moved(provenance.Unchanged) -> "unchanged"
    provenance.InsideNoise(range:, ..) ->
      "within variation (" <> text_of(Known(range), u) <> ")"
    provenance.Withheld(blocking:) ->
      "withheld ("
      <> string.join(list.map(blocking, provenance.field_name), ", ")
      <> ")"
    provenance.NoReading -> "no reading"
  }
}

// A figure in the unit the page shows it in: bytes in MiB, ratios as a
// percentage, everything else as a count with its unit's name. A reading
// that is absent is the word the page shows.
fn text_of(reading: Measurement, in u: Unit) -> String {
  case reading, u {
    Known(value), unit.Bytes ->
      tenths(rounded(value, over: 1_048_576)) <> " MiB"
    Known(value), unit.Ratio(per:) ->
      tenths(rounded(value * 100, over: per)) <> " %"
    other, _ -> measure.render(other, u)
  }
}

fn tenths(value: Int) -> String {
  int.to_string(value / 10) <> "." <> int.to_string(value % 10)
}

// Rounds to the nearest tenth, as the page does, so 1.59 prints 1.6.
fn rounded(numerator: Int, over denominator: Int) -> Int {
  { numerator * 10 + denominator / 2 } / denominator
}
