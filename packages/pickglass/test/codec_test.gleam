import fixture
import gleam/list
import gleam/option.{None}
import gleam/string
import pickglass/capture_build
import pickglass/capture_file
import pickglass/internal/ffi_zlib
import pickglass/observation.{type Observation, Observation}
import pickglass/observation_codec
import pickglass/os_reader
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/wire
import simplifile

fn facts() -> capture_build.Facts {
  capture_build.Facts(
    pickglass_version: "test",
    node: "fake@127.0.0.1",
    os_pid: 4242,
    boot: fixture.boot(),
    role: "loomd",
    workload: "idle",
    top_k: 200,
    deadline_ms: 15_000,
    os_start: identity.UnreadableStart,
    clock: option.None,
  )
}

fn nested() -> wire.OwnerReading {
  let assert Ok(session) = owner.segment("session", "s-12")
  let assert Ok(strand) = owner.segment("strand", "main")

  wire.Labelled([session, strand], "restart_keeper")
}

// Rows sorted by memory, then pid, as `of_records` returns them.
fn rich(seq: Int, at_ms: Int) -> Observation {
  let big = fixture.row("<0.30.0>", 9000 + seq, nested())
  let named =
    wire.ProcessRow(
      ..fixture.row(
        "<0.10.0>",
        5000,
        fixture.labelled("session", "s1", "worker"),
      ),
      registered_name: "conversation_store",
    )
  let loose = fixture.row("<0.11.0>", 4000, wire.Unlabelled)

  Observation(
    ..fixture.observation(seq, at_ms),
    census: Ok(fixture.census([big, named, loose])),
  )
}

fn round_trip(observations: List(Observation)) -> List(Observation) {
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts(),
      "cap-test",
      observations,
      measure.EveryMs(2000),
      [],
      [],
      [],
    )
  let assert Ok(text) = capture_file.render(header, records)
  let assert Ok(loaded) = capture_file.parse(text)

  assert loaded.digest == capture_file.DigestVerified
  assert loaded.capture.status == measure.Complete

  let assert Ok(back) =
    observation_codec.of_records(
      loaded.capture.records,
      capture_build.runtime_of(loaded.capture.header),
    )

  back
}

pub fn observations_survive_a_capture_test() {
  let observations = [rich(0, 1000), rich(1, 3000), rich(2, 5000)]

  assert round_trip(observations) == observations
}

pub fn a_process_missing_from_one_census_reads_back_missing_test() {
  // The second census has only one of the two processes: the other is
  // Missing for that time and must not read back as a zero row.
  let first = rich(0, 1000)
  let second =
    Observation(
      ..rich(1, 3000),
      census: Ok(fixture.census([fixture.row("<0.30.0>", 9001, nested())])),
    )

  assert round_trip([first, second]) == [first, second]
}

pub fn a_failed_section_reads_back_as_the_same_failure_test() {
  let broken =
    Observation(
      ..rich(1, 3000),
      census: Error("the agent did not answer in time"),
      scheduler: Error("the agent refused (busy): two censuses are running"),
    )
  let observations = [rich(0, 1000), broken]

  assert round_trip(observations) == observations
}

pub fn a_truncated_census_reads_back_truncated_test() {
  let cut =
    Observation(
      ..rich(0, 1000),
      census: Ok(
        wire.CensusSnapshot(
          wire.CensusCoverage(
            scanned: 3,
            total: 900,
            stop: wire.ScanBudgetReached,
            elapsed_ms: 40,
          ),
          [fixture.row("<0.10.0>", 5000, wire.Unlabelled)],
          [],
        ),
      ),
    )
  let assert [back] = round_trip([cut])
  let assert Ok(census) = back.census

  assert census.coverage.stop == wire.ScanBudgetReached
  assert census.coverage.total == 900
  assert census.coverage.scanned == 3
}

pub fn memory_categories_are_declared_overlapping_test() {
  let assert Ok(#(_, records)) =
    capture_build.assemble(
      facts(),
      "cap-test",
      [rich(0, 1000)],
      measure.OneShot,
      [],
      [],
      [],
    )
  let memory_series =
    list.filter_map(records, fn(record) {
      case record {
        capture.SeriesRecord(series) ->
          case series.method == "erlang:memory/0" {
            True -> Ok(series)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })

  assert memory_series != []
  assert list.all(memory_series, fn(series) {
    case series.additivity {
      measure.Overlapping(_) -> True
      measure.Additive -> False
    }
  })
}

pub fn a_capture_needs_a_memory_report_test() {
  let none = Observation(..fixture.observation(0, 1000), memory: Error("down"))

  assert capture_build.assemble(
      facts(),
      "id",
      [none],
      measure.OneShot,
      [],
      [],
      [],
    )
    |> result_is_error
}

fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

fn text_of_capture() -> String {
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts(),
      "cap-test",
      [rich(0, 1000)],
      measure.OneShot,
      [capture.Checkpoint("idle", 0, 1500)],
      [],
      [],
    )
  let assert Ok(text) = capture_file.render(header, records)

  text
}

pub fn the_footer_digest_verifies_test() {
  let assert Ok(loaded) = capture_file.parse(text_of_capture())

  assert loaded.digest == capture_file.DigestVerified
  assert option_is_some(loaded.capture.footer)
}

fn option_is_some(option: option.Option(a)) -> Bool {
  option != None
}

pub fn an_edited_body_fails_the_digest_test() {
  let tampered =
    string.replace(
      text_of_capture(),
      "\"kind\":\"gauge\"",
      "\"kind\":\"counter\"",
    )
  let assert Ok(loaded) = capture_file.parse(tampered)

  assert loaded.digest == capture_file.DigestMismatched
}

pub fn a_file_with_no_footer_is_partial_test() {
  let lines = string.split(text_of_capture(), "\n")
  let without =
    lines
    |> list.filter(fn(line) { !string.starts_with(line, "{\"t\":\"footer\"") })
    |> string.join("\n")
  let assert Ok(loaded) = capture_file.parse(without)

  assert loaded.digest == capture_file.NoDigestToCheck
  assert loaded.capture.status == measure.Partial(measure.NoFooter)
}

pub fn a_capture_written_to_disk_reads_back_gzipped_test() {
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts(),
      "cap-disk",
      [rich(0, 1000)],
      measure.OneShot,
      [],
      [],
      [],
    )
  let path = "build/codec_test.pgcap"

  assert capture_file.write(path, header, records) == Ok(Nil)

  let assert Ok(bytes) = simplifile.read_bits(path)

  // Gzip magic: the file is compressed, not plain text.
  assert case bytes {
    <<0x1f, 0x8b, _:bytes>> -> True
    _ -> False
  }

  let assert Ok(loaded) = capture_file.read(path)

  assert loaded.digest == capture_file.DigestVerified
  assert loaded.capture.header.capture_id == "cap-disk"

  let _ = simplifile.delete(path)
}

pub fn plain_text_and_bad_gzip_are_handled_test() {
  let plain = "build/codec_test_plain.ndjson"
  let assert Ok(Nil) = simplifile.write(plain, text_of_capture())
  let assert Ok(loaded) = capture_file.read(plain)

  assert loaded.digest == capture_file.DigestVerified

  let bad = "build/codec_test_bad.pgcap"
  let assert Ok(Nil) = simplifile.write_bits(bad, <<0x1f, 0x8b, 1, 2, 3>>)

  assert capture_file.read(bad) == Error("the file is not valid gzip")
  assert capture_file.read("build/does_not_exist.pgcap")
    |> result_is_error

  let _ = simplifile.delete(plain)
  let _ = simplifile.delete(bad)
}

pub fn gzip_round_trips_and_rejects_garbage_test() {
  assert ffi_zlib.gunzip(ffi_zlib.gzip(<<"hello":utf8>>))
    == Ok(<<"hello":utf8>>)
  assert ffi_zlib.gunzip(<<"nope":utf8>>) == Error(Nil)
  assert ffi_zlib.gzip(<<"same":utf8>>) == ffi_zlib.gzip(<<"same":utf8>>)
}

pub fn a_capture_with_no_passes_is_refused_test() {
  let assert Ok(loaded) = capture_file.parse(text_of_capture())
  let without =
    list.filter(loaded.capture.records, fn(record) {
      case record {
        capture.EventsRecord(_) -> False
        _ -> True
      }
    })

  assert observation_codec.of_records(
      without,
      capture_build.runtime_of(loaded.capture.header),
    )
    == Error("the capture has no pass record")
}

fn os_reading(
  pid: Int,
  role: String,
  rss: measure.Measurement,
) -> os_reader.Reading {
  os_reader.Reading(
    pid:,
    role:,
    rss:,
    anon: measure.Missing(measure.UnsupportedOnPlatform),
    cpu_ms: measure.Known(1500),
    start: identity.UnreadableStart,
  )
}

pub fn os_readings_round_trip_with_their_missing_parts_test() {
  let with_os =
    Observation(
      ..rich(0, 1000),
      os: Ok([
        os_reading(4242, "target", measure.Known(900_000)),
        os_reading(4300, "child sh", measure.Known(4096)),
      ]),
    )

  assert round_trip([with_os]) == [with_os]
}

pub fn a_pass_whose_os_reading_failed_reads_back_as_words_test() {
  let ok =
    Observation(
      ..rich(0, 1000),
      os: Ok([os_reading(4242, "target", measure.Known(900_000))]),
    )
  let failed =
    Observation(
      ..rich(1, 3000),
      os: Error("the OS process table could not be read"),
    )

  let back = round_trip([ok, failed])
  let assert [first, second] = back

  assert first == ok

  // The failure's wording is not kept, but every figure of the pass is a
  // word and not a zero.
  let assert Ok([target]) = second.os

  assert target.rss == measure.Missing(measure.DecodeFailed)
  assert target.cpu_ms == measure.Missing(measure.DecodeFailed)
  assert second.memory == failed.memory
}

pub fn the_os_series_are_declared_overlapping_and_scoped_to_the_os_test() {
  let assert Ok(#(_, records)) =
    capture_build.assemble(
      facts(),
      "cap-test",
      [
        Observation(
          ..rich(0, 1000),
          os: Ok([os_reading(4242, "target", measure.Known(900_000))]),
        ),
      ],
      measure.OneShot,
      [],
      [],
      [],
    )
  let os_series =
    list.filter_map(records, fn(record) {
      case record {
        capture.SeriesRecord(series) if series.scope == measure.OsProcessScope ->
          Ok(series)
        _ -> Error(Nil)
      }
    })

  assert list.length(os_series) == 3
  assert list.all(os_series, fn(series) {
    case series.additivity {
      measure.Overlapping(_) -> True
      measure.Additive -> False
    }
  })
}
