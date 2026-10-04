//// Random secrets and ids from the operating system's random source.
////
//// Tickets, cookies, page nonces and plan ids are all drawn here, so there
//// is one place that says how a secret is made: random bytes from
//// `gleam/crypto`, encoded as URL-safe base64 without padding so the value
//// can sit in a URL path or a cookie without escaping.

import gleam/bit_array
import gleam/crypto

/// A secret of `bytes` random bytes, URL-safe and unpadded.
///
/// ## Examples
///
/// ```gleam
/// secret.token(32)
/// // -> "q3Zr...", 43 characters
/// ```
pub fn token(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base64_url_encode(False)
}
