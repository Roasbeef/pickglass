//// Who owns a process, read from its label.
////
//// A host declares ownership by labelling its processes with
//// `proc_lib:set_label({pickglass_owner, 1, Path, Role})`, where `Path` is a
//// list of `{Kind, Id}` binary pairs from outermost to innermost and `Role`
//// is a binary. The agent reads the label with `process_info(P, label)` and
//// decodes this one shape, with one optional extension: a fifth element
//// listing capability binaries, such as `<<"measure">>`, which a process
//// uses to say it answers `pickglass_measure` requests. A label of any other
//// shape, a label that is too large, or no label at all is `Unknown`: the
//// census reports the process but attributes it to no owner, and says so.
////
//// Labels are set by arbitrary code, so the decoder is total and bounded.
//// It accepts only printable ASCII, caps the path depth and the length of
//// every text, and never creates an atom. A label that fails any check is
//// not partially trusted; the whole process is `Unknown`.

import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_proc
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

/// Label the calling process as the agent's own, so that what pickglass
/// costs the node is attributed to `tool=pickglass`, role `agent`, and not to
/// the unknown remainder. Every process the agent starts calls this first
/// thing in its own body: a label belongs to one process and is not
/// inherited by a spawn.
///
/// ## Examples
///
/// ```gleam
/// claim_self()
/// ```
pub fn claim_self() -> Nil {
  ffi_proc.set_label(
    ffi_term.coerce(#(PickglassOwner, 1, [#("tool", "pickglass")], "agent")),
  )
}

/// The deepest ownership path the decoder accepts.
pub const max_path_depth = 8

/// The most capabilities a label may advertise.
pub const max_capabilities = 8

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
  && has_known_size(label)
  && ffi_term.element(1, label) == ffi_term.coerce(PickglassOwner)
  && ffi_term.element(2, label) == ffi_term.coerce(1)
}

// The four-element form is the whole protocol; the five-element form adds
// capabilities, and anything else is not an ownership label.
fn has_known_size(label: Term) -> Bool {
  ffi_term.tuple_size(label) == 4 || ffi_term.tuple_size(label) == 5
}

/// The capabilities a well-formed label advertises, or none. A label whose
/// capability list is malformed is not an ownership label at all, so it
/// advertises nothing.
///
/// ## Examples
///
/// ```gleam
/// capabilities(coerce(#(PickglassOwner, 1, [], "worker", ["measure"])))
/// // -> ["measure"]
/// capabilities(coerce(#(PickglassOwner, 1, [], "worker")))
/// // -> []
/// ```
pub fn capabilities(label: Term) -> List(String) {
  case decode(label), ffi_term.is_tuple(label) {
    Owned(_, _), True ->
      case ffi_term.tuple_size(label) == 5 {
        True ->
          case decode_capabilities(ffi_term.element(5, label)) {
            Ok(names) -> names
            Error(Nil) -> []
          }
        False -> []
      }
    _, _ -> []
  }
}

fn decode_capabilities(term: Term) -> Result(List(String), Nil) {
  use length <- fallible.then(ffi_safe.proper_length(term))

  case length > max_capabilities {
    True -> Error(Nil)
    False -> decode_names(ffi_term.coerce(term), [])
  }
}

fn decode_names(
  items: List(Term),
  acc: List(String),
) -> Result(List(String), Nil) {
  case items {
    [] -> Ok(seq.reverse(acc))
    [item, ..rest] -> {
      use name <- fallible.then(text(item))

      decode_names(rest, [name, ..acc])
    }
  }
}

fn decode_body(label: Term) -> Owner {
  let decoded = {
    use path <- fallible.then(decode_path(ffi_term.element(3, label)))
    use role <- fallible.then(text(ffi_term.element(4, label)))
    use _ <- fallible.then(check_capabilities(label))

    Ok(Owned(path, role))
  }

  case decoded {
    Ok(owner) -> owner
    Error(Nil) -> Unknown
  }
}

fn check_capabilities(label: Term) -> Result(Nil, Nil) {
  case ffi_term.tuple_size(label) {
    5 -> {
      use _ <- fallible.then(decode_capabilities(ffi_term.element(5, label)))

      Ok(Nil)
    }
    _ -> Ok(Nil)
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

// Text must be a short, non-empty printable ASCII binary without a slash.
// Anything else could carry control characters into a terminal or a capture
// file, and the viewer's owner paths use the slash as their separator, so a
// label containing one could not be told apart from a deeper path.
fn text(term: Term) -> Result(String, Nil) {
  case
    ffi_term.is_binary(term)
    && ffi_term.byte_size(term) >= 1
    && ffi_term.byte_size(term) <= max_text_bytes
  {
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
    <<byte, rest:bytes>> ->
      byte >= 32 && byte <= 126 && byte != 47 && is_printable(rest)
    _ -> False
  }
}
