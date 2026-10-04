//// ETS, binaries and initial-call readings as the JSON a capture carries.
////
//// Three readings are kept beside the census in a capture, each as a record
//// of its own so a capture written before they existed reads as before and a
//// reader that does not know them keeps them as unknown records:
////
//// - `OwnersDetail` is the part of an `owners_detail` reply the census does
////   not already carry: the `proc_lib` initial call of each process that has
////   one, each owner's ETS tables and bytes, and the totals of the ETS pass
////   with the reason it stopped. The census rows, owner heaps and totals are
////   the ones the pass's `census` records hold, so they are not written twice.
//// - `EtsListing` is an `ets_tables` reply: the largest tables by memory,
////   their owners, and how much of the node the listing covered. It holds
////   table properties and never a table's contents, because the agent reads
////   no contents.
//// - `BinariesReading` is a `binaries` reply for one process.
////
//// Each carries the viewer's wall-clock time in milliseconds, which is how a
//// reader places it beside the passes. The decoders are total: a code this
//// build does not know, a missing field or a field of the wrong type is a
//// decode failure that says what was expected, never a default.
////
//// ## Flow
////
//// - `owners_detail_fields`, `ets_listing_fields` and `binaries_fields` write
////   a record's fields; the capture module adds the kind.
//// - `owners_detail_decoder`, `ets_listing_decoder` and `binaries_decoder`
////   read them back.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{None, Some}
import pickglass_core/codec
import pickglass_core/wire.{
  type BinariesSnapshot, type BinaryRef, type EtsCoverage, type EtsPass,
  type EtsSnapshot, type EtsStop, type EtsTable, type EtsTotals,
  type OwnerReading,
}

/// One owner's ETS tables: how many its processes own and their memory in
/// bytes. Tables of an unlabelled process are under `wire.Unlabelled`.
pub type OwnerEts {
  OwnerEts(owner: OwnerReading, tables: Int, bytes: Int)
}

/// What an `owners_detail` reply adds to a census: which processes `proc_lib`
/// started and from what call, each owner's ETS, and the ETS pass's totals.
/// `initial_calls` lists only the processes that have one, as `#(pid text,
/// "module:function/arity")`.
pub type OwnersDetail {
  OwnersDetail(
    at_ms: Int,
    initial_calls: List(#(String, String)),
    owners: List(OwnerEts),
    ets: EtsPass,
  )
}

/// An `ets_tables` reply and when the viewer read it.
pub type EtsListing {
  EtsListing(at_ms: Int, snapshot: EtsSnapshot)
}

/// A `binaries` reply and when the viewer read it.
pub type BinariesReading {
  BinariesReading(at_ms: Int, snapshot: BinariesSnapshot)
}

// ---------------------------------------------------------------- owners

/// The fields of an `owners_detail` record.
///
/// ## Examples
///
/// ```gleam
/// readings.owners_detail_fields(detail)
/// ```
pub fn owners_detail_fields(detail: OwnersDetail) -> List(#(String, Json)) {
  [
    #("at_ms", json.int(detail.at_ms)),
    #(
      "initial_calls",
      json.array(detail.initial_calls, fn(pair) {
        json.object([
          #("pid", json.string(pair.0)),
          #("call", json.string(pair.1)),
        ])
      }),
    ),
    #("owners", json.array(detail.owners, owner_ets_json)),
    #("ets", ets_pass_json(detail.ets)),
  ]
}

/// Read an `owners_detail` record.
pub fn owners_detail_decoder() -> Decoder(OwnersDetail) {
  use at_ms <- decode.field("at_ms", decode.int)
  use initial_calls <- decode.field(
    "initial_calls",
    decode.list(initial_call_decoder()),
  )
  use owners <- decode.field("owners", decode.list(owner_ets_decoder()))
  use ets <- decode.field("ets", ets_pass_decoder())

  decode.success(OwnersDetail(at_ms:, initial_calls:, owners:, ets:))
}

fn initial_call_decoder() -> Decoder(#(String, String)) {
  use pid <- decode.field("pid", decode.string)
  use call <- decode.field("call", decode.string)

  decode.success(#(pid, call))
}

fn owner_ets_json(entry: OwnerEts) -> Json {
  json.object([
    #("owner", owner_json(entry.owner)),
    #("tables", json.int(entry.tables)),
    #("bytes", json.int(entry.bytes)),
  ])
}

fn owner_ets_decoder() -> Decoder(OwnerEts) {
  use owner <- decode.field("owner", owner_decoder())
  use tables <- decode.field("tables", decode.int)
  use bytes <- decode.field("bytes", decode.int)

  decode.success(OwnerEts(owner:, tables:, bytes:))
}

// An owner is `null` for a process with no ownership label, and otherwise its
// path and role. Path segments go through the vocabulary's own constructor,
// so a segment it refuses is a decode failure here too.
fn owner_json(owner: OwnerReading) -> Json {
  case owner {
    wire.Unlabelled -> json.null()
    wire.Labelled(path:, role:) ->
      json.object([
        #("path", json.array(path, codec.segment_json)),
        #("role", json.string(role)),
      ])
  }
}

fn owner_decoder() -> Decoder(OwnerReading) {
  decode.optional(labelled_decoder())
  |> decode.map(fn(found) {
    case found {
      Some(reading) -> reading
      None -> wire.Unlabelled
    }
  })
}

fn labelled_decoder() -> Decoder(OwnerReading) {
  use path <- decode.field("path", decode.list(codec.segment_decoder()))
  use role <- decode.field("role", decode.string)

  decode.success(wire.Labelled(path:, role:))
}

fn ets_pass_json(pass: EtsPass) -> Json {
  json.object([
    #("tables", json.int(pass.tables)),
    #("bytes", json.int(pass.memory_bytes)),
    #("skipped", json.int(pass.skipped)),
    #("stop", json.string(stop_code(pass.stop))),
  ])
}

fn ets_pass_decoder() -> Decoder(EtsPass) {
  use tables <- decode.field("tables", decode.int)
  use memory_bytes <- decode.field("bytes", decode.int)
  use skipped <- decode.field("skipped", decode.int)
  use stop <- decode.field("stop", stop_decoder())

  decode.success(wire.EtsPass(tables:, memory_bytes:, skipped:, stop:))
}

fn stop_code(stop: EtsStop) -> String {
  case stop {
    wire.EtsFinished -> "finished"
    wire.EtsDeadline -> "deadline"
  }
}

fn stop_decoder() -> Decoder(EtsStop) {
  use code <- decode.then(decode.string)

  case code {
    "finished" -> decode.success(wire.EtsFinished)
    "deadline" -> decode.success(wire.EtsDeadline)
    _ -> decode.failure(wire.EtsFinished, "an ETS stop reason")
  }
}

// ---------------------------------------------------------------- tables

/// The fields of an `ets_tables` record.
///
/// ## Examples
///
/// ```gleam
/// readings.ets_listing_fields(listing)
/// ```
pub fn ets_listing_fields(listing: EtsListing) -> List(#(String, Json)) {
  let snapshot = listing.snapshot

  [
    #("at_ms", json.int(listing.at_ms)),
    #("coverage", coverage_json(snapshot.coverage)),
    #("tables", json.array(snapshot.tables, table_json)),
    #("totals", totals_json(snapshot.totals)),
  ]
}

/// Read an `ets_tables` record.
pub fn ets_listing_decoder() -> Decoder(EtsListing) {
  use at_ms <- decode.field("at_ms", decode.int)
  use coverage <- decode.field("coverage", coverage_decoder())
  use tables <- decode.field("tables", decode.list(table_decoder()))
  use totals <- decode.field("totals", totals_decoder())

  decode.success(EtsListing(
    at_ms:,
    snapshot: wire.EtsSnapshot(coverage:, tables:, totals:),
  ))
}

fn coverage_json(coverage: EtsCoverage) -> Json {
  json.object([
    #("total", json.int(coverage.total)),
    #("counted", json.int(coverage.counted)),
    #("skipped", json.int(coverage.skipped)),
    #("stop", json.string(stop_code(coverage.stop))),
    #("elapsed_ms", json.int(coverage.elapsed_ms)),
  ])
}

fn coverage_decoder() -> Decoder(EtsCoverage) {
  use total <- decode.field("total", decode.int)
  use counted <- decode.field("counted", decode.int)
  use skipped <- decode.field("skipped", decode.int)
  use stop <- decode.field("stop", stop_decoder())
  use elapsed_ms <- decode.field("elapsed_ms", decode.int)

  decode.success(wire.EtsCoverage(
    total:,
    counted:,
    skipped:,
    stop:,
    elapsed_ms:,
  ))
}

fn table_json(table: EtsTable) -> Json {
  json.object([
    #("id", json.string(table.id_text)),
    #("name", json.string(table.name)),
    #("owner_pid", json.string(table.owner_pid_text)),
    #("owner", owner_json(table.owner)),
    #("type", json.string(table.kind)),
    #("objects", json.int(table.objects)),
    #("bytes", json.int(table.memory_bytes)),
    #("protection", json.string(table.protection)),
    #("heir", json.string(table.heir_pid_text)),
    #("owner_name", json.string(table.owner_name)),
  ])
}

fn table_decoder() -> Decoder(EtsTable) {
  use id_text <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use owner_pid_text <- decode.field("owner_pid", decode.string)
  use owner <- decode.field("owner", owner_decoder())
  use kind <- decode.field("type", decode.string)
  use objects <- decode.field("objects", decode.int)
  use memory_bytes <- decode.field("bytes", decode.int)
  use protection <- decode.field("protection", decode.string)
  use heir_pid_text <- decode.field("heir", decode.string)

  // A capture written before the agent sent the owner's registered name has
  // no such field; it reads as no name.
  use owner_name <- decode.optional_field("owner_name", "", decode.string)

  decode.success(wire.EtsTable(
    id_text:,
    name:,
    owner_pid_text:,
    owner:,
    owner_name:,
    kind:,
    objects:,
    memory_bytes:,
    protection:,
    heir_pid_text:,
  ))
}

fn totals_json(totals: EtsTotals) -> Json {
  json.object([
    #("tables", json.int(totals.tables)),
    #("objects", json.int(totals.objects)),
    #("bytes", json.int(totals.memory_bytes)),
  ])
}

fn totals_decoder() -> Decoder(EtsTotals) {
  use tables <- decode.field("tables", decode.int)
  use objects <- decode.field("objects", decode.int)
  use memory_bytes <- decode.field("bytes", decode.int)

  decode.success(wire.EtsTotals(tables:, objects:, memory_bytes:))
}

// -------------------------------------------------------------- binaries

/// The fields of a `binaries` record.
///
/// ## Examples
///
/// ```gleam
/// readings.binaries_fields(reading)
/// ```
pub fn binaries_fields(reading: BinariesReading) -> List(#(String, Json)) {
  let snapshot = reading.snapshot

  [
    #("at_ms", json.int(reading.at_ms)),
    #("pid", json.string(snapshot.pid_text)),
    #("distinct", json.int(snapshot.distinct)),
    #("bytes", json.int(snapshot.bytes)),
    #("references", json.int(snapshot.references)),
    #("binaries", json.array(snapshot.binaries, binary_json)),
  ]
}

/// Read a `binaries` record.
pub fn binaries_decoder() -> Decoder(BinariesReading) {
  use at_ms <- decode.field("at_ms", decode.int)
  use pid_text <- decode.field("pid", decode.string)
  use distinct <- decode.field("distinct", decode.int)
  use bytes <- decode.field("bytes", decode.int)
  use references <- decode.field("references", decode.int)
  use binaries <- decode.field("binaries", decode.list(binary_decoder()))

  decode.success(BinariesReading(
    at_ms:,
    snapshot: wire.BinariesSnapshot(
      pid_text:,
      distinct:,
      bytes:,
      references:,
      binaries:,
    ),
  ))
}

fn binary_json(binary: BinaryRef) -> Json {
  json.object([
    #("address", json.string(binary.address_text)),
    #("bytes", json.int(binary.bytes)),
    #("refc", json.int(binary.refc)),
  ])
}

fn binary_decoder() -> Decoder(BinaryRef) {
  use address_text <- decode.field("address", decode.string)
  use bytes <- decode.field("bytes", decode.int)
  use refc <- decode.field("refc", decode.int)

  decode.success(wire.BinaryRef(address_text:, bytes:, refc:))
}
