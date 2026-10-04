//// Calls that may raise, turned into values.
////
//// Gleam has no `try`/`catch`, and a request from outside must never be
//// able to crash the agent: an exception in the agent process would end
//// the attach and tear down every probe. `rpc:call/4` against the local
//// node runs the function under a `catch` and returns `{badrpc, Reason}`
//// instead of raising, so it is the one construct available without a
//// dependency that converts an exception into data. It is used only for
//// calls whose arguments come from outside or whose target may have died.
////
//// The module and function are passed as `Name` values, a closed
//// vocabulary of the atoms the agent calls through here. A new call adds a
//// constructor, which keeps the set of atoms the agent can mention in one
//// reviewable place.

import pickglass_agent/internal/ffi_term.{type Atom, type Term}

/// The atoms the agent names when it calls through `call`: module names,
/// function names and the single error tag `rpc` uses. Each constructor is
/// the snake_case atom of the same name.
pub type Name {
  Erlang
  Length
  BinaryToExistingAtom
  ListToPid
  Badrpc
  Utf8
  Maps
  Get
  Size
  Instrument
  Carriers
}

@external(erlang, "erlang", "node")
fn local_node() -> Atom

@external(erlang, "rpc", "call")
fn rpc_call(node: Atom, module: m, function: f, args: List(Term)) -> Term

/// Apply `module:function(args)` on this node and return `Ok` with the
/// result, or `Error(Nil)` if the call raised.
///
/// ## Examples
///
/// ```gleam
/// call(Erlang, Length, [coerce([1, 2, 3])])
/// // -> Ok(coerce(3))
/// ```
pub fn call(module: m, function: f, args: List(Term)) -> Result(Term, Nil) {
  let result = rpc_call(local_node(), module, function, args)

  case failed(result) {
    True -> Error(Nil)
    False -> Ok(result)
  }
}

// A raised call comes back as `{badrpc, Reason}`. None of the functions the
// agent calls through here returns a two-tuple tagged `badrpc` itself.
fn failed(result: Term) -> Bool {
  ffi_term.is_tuple(result)
  && ffi_term.tuple_size(result) == 2
  && ffi_term.element(1, result) == ffi_term.coerce(Badrpc)
}

/// The length of a list that came from outside, or `Error(Nil)` when it is
/// not a proper list. Walking an improper list with a `case` would raise,
/// so every external list passes this check first.
///
/// ## Examples
///
/// ```gleam
/// proper_length(coerce([1, 2]))
/// // -> Ok(2)
/// ```
pub fn proper_length(term: Term) -> Result(Int, Nil) {
  case ffi_term.is_list(term) {
    False -> Error(Nil)
    True ->
      case call(Erlang, Length, [term]) {
        Ok(length) -> Ok(ffi_term.coerce(length))
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Resolve a binary to an atom that already exists on this node. A name the
/// node has never seen resolves to `Error(Nil)` rather than creating an
/// atom, which is how a request naming an unknown module is refused.
///
/// ## Examples
///
/// ```gleam
/// existing_atom("lists")
/// // -> Ok(the atom lists)
/// existing_atom("never_seen_before_zzqq")
/// // -> Error(Nil)
/// ```
pub fn existing_atom(name: String) -> Result(Atom, Nil) {
  case
    call(Erlang, BinaryToExistingAtom, [
      ffi_term.coerce(name),
      ffi_term.coerce(Utf8),
    ])
  {
    Ok(atom) -> Ok(ffi_term.coerce(atom))
    Error(Nil) -> Error(Nil)
  }
}
