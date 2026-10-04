//// Keys: the only names a browser event may carry.
////
//// A page never lets the browser name a target. A pid, a module, a function
//// or an owner path is text from the node under inspection, and an event
//// that carried one would let anything that can reach the socket choose what
//// the viewer acts on. Instead the viewer issues a `Key` for every row, box,
//// node and checkpoint it draws, the view puts the key in the message its
//// handler sends, and the viewer maps a key back to a target only if it
//// issued it for the page the sender holds.
////
//// A `Key` is opaque and short: one to 64 characters from letters, digits,
//// underscore, dot, colon and hyphen. The alphabet excludes tab, carriage
//// return and newline, which Lustre uses to separate path segments, and
//// every character that could close an attribute or start markup. `parse`
//// is the total decoder for text arriving from a browser. `make` is for the
//// server side: it builds a key from text the server controls and replaces
//// anything outside the alphabet, so a fixture or a row builder cannot
//// produce a key `parse` would refuse.
////
//// ## Reading order
////
//// The server calls `make` or `indexed` while it builds a model, the view
//// calls `to_string` to put the key in an attribute or a list key, and
//// `parse` runs in the event decoders in `wire`.

import gleam/int
import gleam/list
import gleam/string

/// A server-issued name for one thing on a page.
pub opaque type Key {
  Key(text: String)
}

/// Why a piece of text is not a key.
pub type KeyError {
  /// The text was empty.
  Empty

  /// The text was longer than `max_length`.
  TooLong

  /// The text held a character outside the key alphabet.
  BadCharacter
}

/// The longest key, in characters.
pub const max_length: Int = 64

/// Read a key from text that came from a browser. The check is the whole
/// alphabet and length rule; whether the viewer issued this key is decided
/// later, against the page the sender holds.
///
/// ## Examples
///
/// ```gleam
/// key.parse("row:s-12.keeper")
/// // -> Ok(key)
///
/// key.parse("a\tb")
/// // -> Error(BadCharacter)
/// ```
pub fn parse(text: String) -> Result(Key, KeyError) {
  case string.length(text) {
    0 -> Error(Empty)
    n if n > max_length -> Error(TooLong)
    _ ->
      case list.all(string.to_graphemes(text), in_alphabet) {
        True -> Ok(Key(text))
        False -> Error(BadCharacter)
      }
  }
}

/// Build a key from text the server controls. Characters outside the
/// alphabet become underscores and an over-long text is cut, so the result
/// always satisfies `parse`; an empty text becomes `_`.
///
/// ## Examples
///
/// ```gleam
/// key.to_string(key.make("session s-12"))
/// // -> "session_s-12"
/// ```
pub fn make(text: String) -> Key {
  let cleaned =
    text
    |> string.to_graphemes
    |> list.map(fn(g) {
      case in_alphabet(g) {
        True -> g
        False -> "_"
      }
    })
    |> string.concat
    |> string.slice(0, max_length)

  case cleaned {
    "" -> Key("_")
    _ -> Key(cleaned)
  }
}

/// A key made of a prefix and a position, for a list whose items have no
/// name of their own.
///
/// ## Examples
///
/// ```gleam
/// key.to_string(key.indexed("box", 17))
/// // -> "box.17"
/// ```
pub fn indexed(prefix: String, index: Int) -> Key {
  make(prefix <> "." <> int.to_string(index))
}

/// The key's text, for an attribute or a list key.
pub fn to_string(key: Key) -> String {
  key.text
}

fn in_alphabet(grapheme: String) -> Bool {
  case string.to_utf_codepoints(grapheme) {
    [cp] -> {
      let code = string.utf_codepoint_to_int(cp)

      { code >= 48 && code <= 57 }
      || { code >= 65 && code <= 90 }
      || { code >= 97 && code <= 122 }
      || code == 95
      || code == 46
      || code == 58
      || code == 45
    }
    _ -> False
  }
}
