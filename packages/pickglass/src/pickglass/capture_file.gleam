//// Capture files on disk: gzip of newline-delimited JSON, with a footer
//// whose SHA-256 covers the body.
////
//// `pickglass_core/capture` defines the records and computes no digest; this
//// module owns the bytes. To write, it encodes the header and records,
//// hashes exactly the text the footer's digest covers (every line before the
//// footer, each ending in a newline), builds the footer with the digest, and
//// writes the gzip of the whole text. To read, it inflates the file, hands
//// the text to the core's reader, and hashes the body again to report
//// whether the file's own digest still matches.
////
//// The file is written to a temporary name beside the destination and
//// renamed, so a reader never sees a half-written capture, and its mode is
//// `0600`: a capture names the target's processes. A file without the gzip
//// magic is read as plain NDJSON, which is how a capture looks after
//// `gunzip`. Files over `max_file_bytes` are refused before they are read.
////
//// ## Flow
////
//// - `render` builds the uncompressed text, footer included.
//// - `write` renders, compresses and writes.
//// - `read` reads, inflates, parses and verifies.

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/result
import gleam/string
import pickglass/internal/ffi_zlib
import pickglass_core/capture.{type Capture, type Header, type Record}
import pickglass_core/profile.{type Profile}
import pickglass_core/profile/codec as profile_codec
import simplifile

/// The largest capture file the viewer reads, in bytes.
pub const max_file_bytes = 268_435_456

/// Whether a capture's footer digest matches its body.
pub type DigestCheck {
  /// The digest computed over the body equals the footer's.
  DigestVerified

  /// It differs: the file was edited or damaged after it was written.
  DigestMismatched

  /// The file has no footer, so there is no digest to check.
  NoDigestToCheck
}

/// A capture read from disk.
pub type Loaded {
  Loaded(capture: Capture(Profile), digest: DigestCheck)
}

/// The SHA-256 of a text, as the capture format's digest. `Error` only if
/// the hash were not 64 hex digits, which a SHA-256 never is.
///
/// ## Examples
///
/// ```gleam
/// capture_file.digest_of("body")
/// ```
pub fn digest_of(text: String) -> Result(capture.Digest, Nil) {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
  |> string.lowercase
  |> capture.digest
}

/// The full text of a capture: the header, the records, and a footer whose
/// digest covers everything before it.
///
/// ## Examples
///
/// ```gleam
/// capture_file.render(header, records)
/// ```
pub fn render(
  header: Header,
  records: List(Record(Profile)),
) -> Result(String, String) {
  let body = capture.body_text(header, records, profile_codec.encode)

  use digest <- result.try(
    digest_of(body) |> result.replace_error("the body digest was malformed"),
  )

  let footer = capture.footer_for(header, records, digest)

  Ok(
    body
    <> capture.encode_record(capture.FooterRecord(footer), profile_codec.encode)
    <> "\n",
  )
}

/// Write a capture to `path` as gzip, atomically, with mode `0600`.
///
/// ## Examples
///
/// ```gleam
/// capture_file.write("cut.pgcap", header, records)
/// ```
pub fn write(
  path: String,
  header: Header,
  records: List(Record(Profile)),
) -> Result(Nil, String) {
  use text <- result.try(render(header, records))

  let compressed = text |> bit_array.from_string |> ffi_zlib.gzip
  let staging = path <> ".part"
  let described = fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  }

  use _ <- result.try(
    simplifile.write_bits(staging, compressed) |> result.map_error(described),
  )
  use _ <- result.try(
    simplifile.set_permissions_octal(staging, 0o600)
    |> result.map_error(described),
  )

  simplifile.rename(staging, path) |> result.map_error(described)
}

/// Read a capture from `path`, gzip or plain, and check its digest.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(loaded) = capture_file.read("cut.pgcap")
/// ```
pub fn read(path: String) -> Result(Loaded, String) {
  use size <- result.try(
    simplifile.file_info(path)
    |> result.map(fn(info) { info.size })
    |> result.map_error(fn(error) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(error)
    }),
  )
  use _ <- result.try(case size > max_file_bytes {
    True -> Error(path <> " is larger than the viewer reads")
    False -> Ok(Nil)
  })
  use bytes <- result.try(
    simplifile.read_bits(path)
    |> result.map_error(fn(error) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(error)
    }),
  )
  use text <- result.try(text_of(bytes))

  parse(text)
}

fn text_of(bytes: BitArray) -> Result(String, String) {
  use inflated <- result.try(case bytes {
    <<0x1f, 0x8b, _:bytes>> ->
      ffi_zlib.gunzip(bytes)
      |> result.replace_error("the file is not valid gzip")
    _ -> Ok(bytes)
  })

  bit_array.to_string(inflated)
  |> result.replace_error("the capture is not UTF-8 text")
}

/// Parse a capture's text and check its footer digest.
///
/// ## Examples
///
/// ```gleam
/// capture_file.parse(capture_file.render(header, records))
/// ```
pub fn parse(text: String) -> Result(Loaded, String) {
  use parsed <- result.try(
    capture.read(text, profile_codec.decoder())
    |> result.map_error(fn(error) {
      "the file is not a readable capture: " <> string.inspect(error)
    }),
  )

  let check = case digest_of(body_of(text)) {
    Error(Nil) -> DigestMismatched
    Ok(computed) ->
      case capture.verify_digest(parsed, computed) {
        Ok(Nil) -> DigestVerified
        Error(capture.NoDigest) -> NoDigestToCheck
        Error(capture.DigestMismatch) -> DigestMismatched
      }
  }

  Ok(Loaded(capture: parsed, digest: check))
}

// The text the digest covers: every line before the footer's, each with its
// newline. The footer is the line this module writes last, an object whose
// first key is `t` with the value `footer`.
fn body_of(text: String) -> String {
  let before =
    string.split(text, "\n")
    |> list.take_while(fn(line) {
      !string.starts_with(line, "{\"t\":\"footer\"")
    })

  case before {
    [] -> ""
    _ -> string.join(before, "\n") <> "\n"
  }
}
