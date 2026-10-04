//// Module name prefixes: a trailing `*` on a module name in a probe request.
////
//// A probe names modules that already exist as atoms on the target, because
//// the agent never makes an atom from request text (`ffi_safe.existing_atom`).
//// That rule cannot express "every module of this application", which is the
//// question an operator has about code such as `runtime@strand_runtime` and
//// its neighbours. A name that ends in `*` is therefore read as a prefix and
//// matched against the names of the modules the code server has loaded, which
//// are atoms already. Nothing is created: the prefix is compared as bytes and
//// the answer is a list of atoms the node holds.
////
//// Three limits keep a prefix from becoming a node-wide trace. A prefix with
//// nothing before the `*` is refused, because it names every module. A prefix
//// that matches more than `max_expanded` modules is refused before any is
//// armed, so the cost of arming is bounded. And the expanded modules go
//// through the same deny list and function cap as modules named one by one,
//// which the probe's own start applies.
////
//// ## Flow
////
//// - `prefix_of` says whether a name is a prefix and what the prefix is.
//// - `expand` lists the loaded modules that start with it.
//// - `starts_with` is the byte comparison both use.

import pickglass_agent/internal/ffi_code
import pickglass_agent/internal/ffi_term.{type Atom}
import pickglass_agent/internal/seq

/// The most modules one prefix may expand to. A module is one trace pattern
/// to arm, so the limit bounds the time the agent spends arming before the
/// function cap can refuse the set.
pub const max_expanded = 1000

/// Why a prefix was refused.
pub type Refusal {
  /// A `*` with nothing before it, which names every module.
  BareWildcard

  /// No loaded module starts with the prefix.
  NoModule

  /// More than `max_expanded` modules start with the prefix.
  TooManyModules
}

/// The prefix a module name stands for, or `Error(Nil)` when the name is an
/// ordinary module name. Only a trailing `*` makes a prefix; a `*` anywhere
/// else is part of a name no module has and is refused as an unknown module.
///
/// ## Examples
///
/// ```gleam
/// prefix_of("runtime@*")
/// // -> Ok("runtime@")
/// prefix_of("lists")
/// // -> Error(Nil)
/// ```
pub fn prefix_of(name: String) -> Result(String, Nil) {
  let size = ffi_term.byte_size(ffi_term.coerce(name)) - 1

  case size >= 0 {
    False -> Error(Nil)
    True ->
      case <<name:utf8>> {
        <<head:bytes-size(size), 42>> -> Ok(ffi_term.coerce(head))
        _ -> Error(Nil)
      }
  }
}

/// Whether a name begins with a prefix, compared as bytes.
///
/// ## Examples
///
/// ```gleam
/// starts_with("runtime@strand", "runtime@")
/// // -> True
/// ```
pub fn starts_with(name: String, prefix: String) -> Bool {
  let size = ffi_term.byte_size(ffi_term.coerce(prefix))

  case <<name:utf8>> {
    <<head:bytes-size(size), _:bytes>> -> head == <<prefix:utf8>>
    _ -> False
  }
}

/// The loaded modules whose names start with a prefix, in the order the code
/// server lists them, or why there are none to use.
///
/// ## Examples
///
/// ```gleam
/// expand("runtime@")
/// // -> Ok([the atoms runtime@strand_runtime, runtime@session, ...])
/// ```
pub fn expand(prefix: String) -> Result(List(Atom), Refusal) {
  expand_from(prefix, seq.map(ffi_code.all_loaded(), fn(entry) { entry.0 }))
}

/// `expand` over a given list of module atoms, so a test can supply the list.
///
/// ## Examples
///
/// ```gleam
/// expand_from("pg_", [atom("pg_a"), atom("other")])
/// // -> Ok([atom("pg_a")])
/// ```
pub fn expand_from(
  prefix: String,
  loaded: List(Atom),
) -> Result(List(Atom), Refusal) {
  case ffi_term.byte_size(ffi_term.coerce(prefix)) {
    0 -> Error(BareWildcard)
    _ -> {
      let found =
        seq.filter(loaded, fn(module) {
          starts_with(ffi_term.atom_name(module), prefix)
        })

      case seq.length(found) {
        0 -> Error(NoModule)
        count if count > max_expanded -> Error(TooManyModules)
        _ -> Ok(found)
      }
    }
  }
}
