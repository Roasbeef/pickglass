//// Who owns a process, read from its label.
////
//// A host declares ownership by labelling its processes with
//// `proc_lib:set_label({pickglass_owner, 1, Path, Role})`, where `Path` is a
//// list of `{Kind, Id}` binary pairs from outermost to innermost and `Role`
//// is a binary. The agent reads the label with `process_info(P, label)` and
//// decodes this one shape. A label of any other shape, a label that is too
//// large, or no label at all is `Unknown`: the census reports the process
//// but attributes it to no owner, and says so.
////
//// Labels are set by arbitrary code, so the decoder is total and bounded.
//// It accepts only printable ASCII, caps the path depth and the length of
//// every text, and never creates an atom. A label that fails any check is
//// not partially trusted; the whole process is `Unknown`.

import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Term}
import pickglass_agent/internal/seq

/// The owner of a process as far as its label says.
pub type Owner {
  /// No label, or one that is not a well-formed ownership label.
  Unknown

  /// A well-formed ownership label. `path` runs from the outermost owner to
  /// the innermost, each element a `#(kind, id)` pair.
  Owned(path: List(#(String, String)), role: String)
}

/// The atom that opens an ownership label.
type LabelTag {
  PickglassOwner
}

/// The deepest ownership path the decoder accepts.
pub const max_path_depth = 8

/// The longest text, in bytes, the decoder accepts for a kind, an id or a
/// role.
pub const max_text_bytes = 128

/// Decode a process label.
///
/// ## Examples
///
/// ```gleam
/// decode(coerce(#(PickglassOwner, 1, [#("session", "s1")], "worker")))
/// // -> Owned([#("session", "s1")], "worker")
/// decode(coerce(undefined))
/// // -> Unknown
/// ```
pub fn decode(label: Term) -> Owner {
  case is_ownership_tuple(label) {
    False -> Unknown
    True -> decode_body(label)
  }
}

fn is_ownership_tuple(label: Term) -> Bool {
  ffi_term.is_tuple(label)
  && ffi_term.tuple_size(label) == 4
  && ffi_term.element(1, label) == ffi_term.coerce(PickglassOwner)
  && ffi_term.element(2, label) == ffi_term.coerce(1)
}

fn decode_body(label: Term) -> Owner {
  let decoded = {
    use path <- fallible.then(decode_path(ffi_term.element(3, label)))
    use role <- fallible.then(text(ffi_term.element(4, label)))

    Ok(Owned(path, role))
  }

  case decoded {
    Ok(owner) -> owner
    Error(Nil) -> Unknown
  }
}

fn decode_path(term: Term) -> Result(List(#(String, String)), Nil) {
  use length <- fallible.then(ffi_safe.proper_length(term))

  case length > max_path_depth {
    True -> Error(Nil)
    False -> decode_pairs(ffi_term.coerce(term), [])
  }
}

fn decode_pairs(
  items: List(Term),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), Nil) {
  case items {
    [] -> Ok(seq.reverse(acc))
    [item, ..rest] -> {
      use pair <- fallible.then(decode_pair(item))

      decode_pairs(rest, [pair, ..acc])
    }
  }
}

fn decode_pair(term: Term) -> Result(#(String, String), Nil) {
  case ffi_term.is_tuple(term) && ffi_term.tuple_size(term) == 2 {
    False -> Error(Nil)
    True -> {
      use kind <- fallible.then(text(ffi_term.element(1, term)))
      use id <- fallible.then(text(ffi_term.element(2, term)))

      Ok(#(kind, id))
    }
  }
}

// Text must be a short printable ASCII binary. Anything else could carry
// control characters into a terminal or a capture file, and no ownership
// vocabulary in use needs more than identifiers.
fn text(term: Term) -> Result(String, Nil) {
  case ffi_term.is_binary(term) && ffi_term.byte_size(term) <= max_text_bytes {
    False -> Error(Nil)
    True ->
      case is_printable(ffi_term.coerce(term)) {
        True -> Ok(ffi_term.coerce(term))
        False -> Error(Nil)
      }
  }
}

fn is_printable(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> -> byte >= 32 && byte <= 126 && is_printable(rest)
    _ -> False
  }
}
