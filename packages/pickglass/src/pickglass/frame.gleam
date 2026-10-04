//// The frames a page's browser may send, checked before the component sees
//// them.
////
//// Lustre's server runtime already drops an event that names no handler in
//// the tree it last rendered, and one whose decoder fails. This is the layer
//// in front of it, and it is stricter on purpose: a socket holder is
//// untrusted input, and the cheapest place to refuse something the page
//// could never have sent is before it costs the component a diff and a
//// render.
////
//// The client runtime sends exactly two kinds of message, and only for what
//// the view attaches: an `EventFired` (kind 1) with the keys `kind`, `path`,
//// `name` and `event`, and a `Batch` (kind 3) of them with the keys `kind`
//// and `messages`. Both are required to have exactly those keys, so a frame
//// with an extra key, a `principal` or a `command` or anything else, is
//// refused and never reaches a decoder that would ignore it. Attribute,
//// property and context messages are refused outright, because the
//// application registers none, and so are event names the views never
//// attach.
////
//// A refused frame costs the sender nothing but the entry in the audit log:
//// the socket stays open, as Lustre's own example does.
////
//// ## Flow
////
//// - `check` returns `Ok(Nil)` for a frame to forward and `Error(reason)`
////   for one to drop and audit.
//// - `check_object` reads the message kind and picks the rule.
//// - `check_event` and `check_batch` enforce the exact key sets.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string

/// The largest frame the host reads, in bytes.
pub const max_bytes = 65_536

/// The most events one batch may carry.
pub const max_batch = 32

/// The event names the views attach.
const event_names = ["click", "input", "change", "submit"]

/// Check one text frame from a browser.
///
/// ## Examples
///
/// ```gleam
/// frame.check("{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{}}")
/// // -> Ok(Nil)
///
/// frame.check("{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{},\"principal\":\"x\"}")
/// // -> Error("unexpected keys")
/// ```
pub fn check(text: String) -> Result(Nil, String) {
  case bit_array.byte_size(bit_array.from_string(text)) > max_bytes {
    True -> Error("frame too large")
    False ->
      json.parse(text, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error("not a JSON object")
      |> result.try(fn(object) { check_object(object, 0) })
  }
}

fn check_object(
  object: Dict(String, Dynamic),
  depth: Int,
) -> Result(Nil, String) {
  let keys = dict.keys(object) |> list.sort(fn(a, b) { compare_text(a, b) })

  case dict.get(object, "kind") |> result.try(as_int) {
    Ok(1) -> check_event(object, keys)
    Ok(3) if depth == 0 -> check_batch(object, keys)
    Ok(_) | Error(Nil) -> Error("not an event or a batch of events")
  }
}

fn check_event(
  object: Dict(String, Dynamic),
  keys: List(String),
) -> Result(Nil, String) {
  case keys == ["event", "kind", "name", "path"] {
    False -> Error("unexpected keys")
    True -> {
      let name = dict.get(object, "name") |> result.try(as_string)
      let path = dict.get(object, "path") |> result.try(as_string)
      let event =
        dict.get(object, "event")
        |> result.try(fn(value) {
          decode.run(value, decode.dict(decode.string, decode.dynamic))
          |> result.replace_error(Nil)
        })

      case name, path, event {
        Ok(name), Ok(_), Ok(_) ->
          case list.contains(event_names, name) {
            True -> Ok(Nil)
            False -> Error("an event the views do not attach")
          }
        _, _, _ -> Error("malformed event")
      }
    }
  }
}

fn check_batch(
  object: Dict(String, Dynamic),
  keys: List(String),
) -> Result(Nil, String) {
  case keys == ["kind", "messages"] {
    False -> Error("unexpected keys")
    True -> {
      let messages =
        dict.get(object, "messages")
        |> result.try(fn(value) {
          decode.run(
            value,
            decode.list(decode.dict(decode.string, decode.dynamic)),
          )
          |> result.replace_error(Nil)
        })

      case messages {
        Ok([_, ..] as events) ->
          case list.length(events) <= max_batch {
            True -> list.try_each(events, fn(event) { check_object(event, 1) })
            False -> Error("batch too large")
          }
        Ok([]) | Error(Nil) -> Error("malformed batch")
      }
    }
  }
}

fn as_int(value: Dynamic) -> Result(Int, Nil) {
  decode.run(value, decode.int) |> result.replace_error(Nil)
}

fn as_string(value: Dynamic) -> Result(String, Nil) {
  decode.run(value, decode.string) |> result.replace_error(Nil)
}

fn compare_text(a: String, b: String) -> order.Order {
  string.compare(a, b)
}
