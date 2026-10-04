//// Untyped Erlang terms, and the few checks the agent runs on them.
////
//// The agent is loaded into a node it does not own, and any process on that
//// node may send it any message. Gleam's standard library offers `Dynamic`
//// and its decoders for this, but the agent may not import the standard
//// library (loading it would replace the target's own copy of the module),
//// so this module is the small substitute: an opaque `Term`, the type tests
//// the VM provides as BIFs, and an identity cast.
////
//// Nothing here creates an atom. The wire carries binaries and integers
//// where a richer protocol would use atoms, which is what makes "the agent
//// never creates an atom from viewer input" a property of the data rather
//// than of the code that reads it.

/// Any Erlang term. Nothing can be done with one until a type test has
/// said what shape it has.
pub type Term

/// An Erlang atom. The agent only ever receives atoms from the VM
/// (function names, process states) and never builds one from a message.
pub type Atom

/// A process identifier.
pub type Pid

/// A reference, such as a monitor reference or a request tag.
pub type Reference

// `erlang:max/2` returns its first argument when the two compare equal, so
// it is the identity function the cast below needs. No OTP function
// returns its argument unchanged under a one-argument signature, and a
// hand-written Erlang module is the alternative this avoids.
@external(erlang, "erlang", "max")
fn identity_pair(first: a, second: a) -> b

/// Reinterpret a value as another type without inspecting it. The caller
/// owns the claim that the representation matches: use it only after a type
/// test, or on the result of an OTP function whose documented shape the
/// target type mirrors.
///
/// ## Examples
///
/// ```gleam
/// let term: Term = coerce(7)
/// ```
pub fn coerce(value: a) -> b {
  identity_pair(value, value)
}

/// Whether a term is a tuple.
@external(erlang, "erlang", "is_tuple")
pub fn is_tuple(term: Term) -> Bool

/// Whether a term is a list, proper or not. A list that came from outside
/// must also pass `ffi_safe.proper_length` before it is walked.
@external(erlang, "erlang", "is_list")
pub fn is_list(term: Term) -> Bool

/// Whether a term is a binary.
@external(erlang, "erlang", "is_binary")
pub fn is_binary(term: Term) -> Bool

/// Whether a term is an integer.
@external(erlang, "erlang", "is_integer")
pub fn is_integer(term: Term) -> Bool

/// Whether a term is an atom.
@external(erlang, "erlang", "is_atom")
pub fn is_atom(term: Term) -> Bool

/// Whether a term is a process identifier.
@external(erlang, "erlang", "is_pid")
pub fn is_pid(term: Term) -> Bool

/// Whether a term is a reference.
@external(erlang, "erlang", "is_reference")
pub fn is_reference(term: Term) -> Bool

/// The number of elements in a tuple. The VM raises on anything else, so
/// call `is_tuple` first.
@external(erlang, "erlang", "tuple_size")
pub fn tuple_size(term: Term) -> Int

/// The element at a one-based position of a tuple. The VM raises when the
/// term is not a tuple or the position is out of range, so call
/// `is_tuple` and `tuple_size` first.
@external(erlang, "erlang", "element")
pub fn element(position: Int, term: Term) -> Term

/// The byte length of a binary. The VM raises on anything else, so call
/// `is_binary` first.
@external(erlang, "erlang", "byte_size")
pub fn byte_size(term: Term) -> Int

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Atom

/// The atom with a given name. Call it only with a string literal written in
/// this package's source, never with text from a message: the atom table is
/// never freed, and the agent's promise is that outside input cannot grow it.
///
/// ## Examples
///
/// ```gleam
/// atom("DOWN")
/// ```
pub fn atom(literal: String) -> Atom {
  binary_to_atom(literal)
}

/// The name of an atom as a binary. Atoms the VM hands the agent, such as a
/// process status or a function name, cross the wire as these.
@external(erlang, "erlang", "atom_to_binary")
pub fn atom_name(atom: Atom) -> String

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> List(Int)

@external(erlang, "erlang", "list_to_binary")
fn list_to_binary(bytes: List(Int)) -> String

/// The text of a process identifier, such as `<0.91.0>`. Pids cross the wire
/// as text because the viewer only displays them and hands the text back to
/// pin one; the agent resolves it again on its own node.
///
/// ## Examples
///
/// ```gleam
/// pid_text(self())
/// // -> "<0.91.0>"
/// ```
pub fn pid_text(pid: Pid) -> String {
  list_to_binary(pid_to_list(pid))
}

/// The text of a term that is a pid, or the empty string for anything else,
/// such as the atom `undefined` a process with no recorded parent reports.
///
/// ## Examples
///
/// ```gleam
/// pid_text_or_empty(coerce(atom("undefined")))
/// // -> ""
/// ```
pub fn pid_text_or_empty(term: Term) -> String {
  case is_pid(term) {
    True -> pid_text(coerce(term))
    False -> ""
  }
}

@external(erlang, "erlang", "binary_to_list")
fn binary_to_list(text: String) -> List(Int)

/// A binary as the charlist some OTP functions expect.
///
/// ## Examples
///
/// ```gleam
/// charlist("<0.91.0>")
/// // -> [60, 48, ...]
/// ```
pub fn charlist(text: String) -> List(Int) {
  binary_to_list(text)
}

/// A charlist, as `system_info(otp_release)` returns, as a binary.
///
/// ## Examples
///
/// ```gleam
/// text_from_charlist([50, 57])
/// // -> "29"
/// ```
pub fn text_from_charlist(chars: List(Int)) -> String {
  list_to_binary(chars)
}

@external(erlang, "erlang", "ref_to_list")
fn ref_to_list(reference: Reference) -> List(Int)

/// The text of a reference, such as `#Ref<0.1.2.3>`. An ETS table identifier
/// is a reference, and the viewer only displays it.
///
/// ## Examples
///
/// ```gleam
/// ref_text(make_ref())
/// // -> "#Ref<0.3401925212.2147483651.226107>"
/// ```
pub fn ref_text(reference: Reference) -> String {
  list_to_binary(ref_to_list(reference))
}

@external(erlang, "erlang", "integer_to_binary")
fn integer_to_binary(value: Int, base: Int) -> String

/// An integer in hexadecimal, such as the address of a reference-counted
/// binary. It crosses the wire as text because an address can pass the
/// largest integer a JavaScript reader holds exactly.
///
/// ## Examples
///
/// ```gleam
/// hex_text(255)
/// // -> "FF"
/// ```
pub fn hex_text(value: Int) -> String {
  integer_to_binary(value, 16)
}
