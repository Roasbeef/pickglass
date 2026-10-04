//// Event handlers and their total decoders.
////
//// Everything a browser sends reaches a page through a handler built here.
//// A handler is one of two kinds.
////
//// A *fixed* handler (`click`) sends a message that was fixed when the tree
//// was rendered. It reads nothing from the event, so a forged click can only
//// send what the view already offered on that element.
////
//// A *reading* handler (`key_chosen`, `code_chosen`, `text_entered`) decodes
//// one property of the event target, `target.value`, with a decoder that
//// can fail. A value that is not a key the alphabet allows, not one of a
//// closed set of codes, or longer than the text bound is a decode failure,
//// and Lustre's runtime then drops the event without calling `update`. The
//// decoders are exported so a test can run them on forged input.
////
//// No handler decodes a pid, a module name taken from the target, or a
//// function name. Key *membership* (did the viewer issue this key for this
//// page?) is not decidable here, because a decoder has no model; `app.update`
//// checks it against the page's data.
////
//// ## Reading order
////
//// `key_decoder`, `code_decoder` and `text_decoder` are the decoders;
//// `click`, `key_chosen`, `code_chosen` and `text_entered` wrap them in
//// attributes; `module_patterns` validates the one free-text field that
//// becomes part of a request.

import gleam/dynamic/decode.{type Decoder}
import gleam/list
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/event
import lustre/server_component
import pickglass_core/policy
import pickglass_web/key.{type Key}
import pickglass_web/msg.{type Msg}

/// The longest text a free-text field may carry.
pub const max_text: Int = 200

/// A handler whose message is fixed when the tree is rendered.
///
/// ## Examples
///
/// ```gleam
/// wire.click(msg.Ask(msg.RequestPin(row_key)))
/// ```
pub fn click(message: Msg) -> Attribute(Msg) {
  event.on_click(message)
}

/// Decode `target.value` as a key. Text outside the key alphabet fails.
///
/// ## Examples
///
/// ```gleam
/// decode.run(forged_dynamic, wire.key_decoder())
/// // -> Error(_) when the value held a tab or was too long
/// ```
pub fn key_decoder() -> Decoder(Key) {
  use text <- decode.subfield(["target", "value"], decode.string)

  case key.parse(text) {
    Ok(parsed) -> decode.success(parsed)
    Error(_) -> decode.failure(key.make("_"), "Key")
  }
}

/// Decode `target.value` as one of a closed set of codes, through the
/// code's own parser. Any other text fails.
///
/// ## Examples
///
/// ```gleam
/// wire.code_decoder(msg.parse_duration, msg.Seconds10)
/// ```
pub fn code_decoder(
  parse: fn(String) -> Result(a, Nil),
  placeholder: a,
) -> Decoder(a) {
  use text <- decode.subfield(["target", "value"], decode.string)

  case parse(text) {
    Ok(code) -> decode.success(code)
    Error(Nil) -> decode.failure(placeholder, "a known code")
  }
}

/// Decode `target.value` as text no longer than `max_text`.
pub fn text_decoder() -> Decoder(String) {
  use text <- decode.subfield(["target", "value"], decode.string)

  case string.length(text) <= max_text {
    True -> decode.success(text)
    False -> decode.failure("", "text within the bound")
  }
}

/// A `change` handler that sends the chosen key.
pub fn key_chosen(make: fn(Key) -> Msg) -> Attribute(Msg) {
  event.on("change", decode.map(key_decoder(), make))
  |> server_component.include(["target.value"])
}

/// A `change` handler that sends the chosen code.
pub fn code_chosen(
  parse: fn(String) -> Result(a, Nil),
  placeholder: a,
  make: fn(a) -> Msg,
) -> Attribute(Msg) {
  event.on("change", decode.map(code_decoder(parse, placeholder), make))
  |> server_component.include(["target.value"])
}

/// An `input` handler that sends bounded text, at most five times a second.
pub fn text_entered(make: fn(String) -> Msg) -> Attribute(Msg) {
  event.on("input", decode.map(text_decoder(), make))
  |> server_component.include(["target.value"])
  |> event.debounce(200)
}

/// Why a module pattern field was refused.
pub type PatternRefusal {
  /// Nothing was entered.
  NoPatterns

  /// More patterns than a probe may scope.
  TooManyPatterns

  /// A pattern held a character outside letters, digits, underscore and at
  /// sign, or was longer than 255 characters.
  BadPattern(text: String)

  /// A pattern held a `*`. The agent turns each name into a module the node
  /// already has and has no wildcard, so a pattern with a star can only be
  /// refused when the probe starts, after the operator confirmed it.
  WildcardPattern(text: String)
}

/// Read the module field of the plan form. Patterns are separated by commas
/// or spaces; each is the exact name of a module the node has loaded, which
/// is the only thing the agent resolves.
///
/// ## Examples
///
/// ```gleam
/// wire.module_patterns("loom@runtime@keeper lists")
/// // -> Ok(["loom@runtime@keeper", "lists"])
///
/// wire.module_patterns("loom@*")
/// // -> Error(WildcardPattern("loom@*"))
///
/// wire.module_patterns("../etc")
/// // -> Error(BadPattern("../etc"))
/// ```
pub fn module_patterns(text: String) -> Result(List(String), PatternRefusal) {
  let tokens =
    text
    |> string.replace(",", " ")
    |> string.split(" ")
    |> list.filter(fn(token) { token != "" })

  case tokens {
    [] -> Error(NoPatterns)
    _ ->
      case list.length(tokens) > policy.max_probe_modules {
        True -> Error(TooManyPatterns)
        False -> check_patterns(tokens)
      }
  }
}

fn check_patterns(
  tokens: List(String),
) -> Result(List(String), PatternRefusal) {
  case
    list.find(tokens, string.contains(_, "*")),
    list.find(tokens, fn(token) { !pattern_ok(token) })
  {
    Ok(starred), _ -> Error(WildcardPattern(starred))
    Error(Nil), Ok(bad) -> Error(BadPattern(bad))
    Error(Nil), Error(Nil) -> Ok(tokens)
  }
}

fn pattern_ok(token: String) -> Bool {
  string.length(token) <= 255
  && list.all(string.to_utf_codepoints(token), fn(cp) {
    let code = string.utf_codepoint_to_int(cp)

    { code >= 48 && code <= 57 }
    || { code >= 65 && code <= 90 }
    || { code >= 97 && code <= 122 }
    || code == 95
    || code == 64
  })
}
