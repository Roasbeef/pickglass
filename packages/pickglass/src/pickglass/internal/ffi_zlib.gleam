//// Gzip bindings for capture files.
////
//// A capture is the gzip of its newline-delimited JSON body
//// (`docs/design/concept-opus.md` section 4.2). `gleam_stdlib`,
//// `gleam_erlang` and `gleam_crypto` have no compression, and no
//// `gleam_zlib` package exists, so these bind OTP's `zlib` directly. `gzip`
//// is total. `zlib:gunzip/1` raises on data that is not gzip, so `gunzip`
//// catches the raise with `exception.rescue` and returns a value.
////
//// `gunzip` inflates the whole input in memory, with no bound on the output.
//// The caller refuses oversized files before calling it, and the files are
//// ones the operator named, not network input.

import exception
import gleam/result

/// Compress with gzip. The header carries no modification time, so equal
/// input gives equal output.
///
/// ## Examples
///
/// ```gleam
/// gzip(<<"hello":utf8>>)
/// ```
@external(erlang, "zlib", "gzip")
pub fn gzip(data: BitArray) -> BitArray

@external(erlang, "zlib", "gunzip")
fn raw_gunzip(data: BitArray) -> BitArray

/// Decompress gzip data. `Error` when the input is not valid gzip.
///
/// ## Examples
///
/// ```gleam
/// gunzip(gzip(<<"hello":utf8>>))
/// // -> Ok(<<"hello":utf8>>)
///
/// gunzip(<<"not gzip":utf8>>)
/// // -> Error(Nil)
/// ```
pub fn gunzip(data: BitArray) -> Result(BitArray, Nil) {
  exception.rescue(fn() { raw_gunzip(data) })
  |> result.replace_error(Nil)
}
