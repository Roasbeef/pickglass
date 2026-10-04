//// ETS bindings: the table list, a table's metadata and the small map the
//// walk uses to remember who owns what.
////
//// Each function is a direct binding to an OTP function with no Gleam
//// alternative. None reads a table's contents: `info/1` returns the table's
//// properties (size, memory, owner, type) and never an object, so the walk
//// can describe a table whose objects are secret without seeing them.

import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}

/// The identifiers of every table on the node: an atom for a named table and
/// a reference for the rest. The list is built in the caller's heap, so a node
/// with a very large number of tables costs the worker that asks, which runs
/// under a heap cap.
@external(erlang, "ets", "all")
pub fn all() -> List(Term)

/// A table's properties as a `{Key, Value}` list, or the atom `undefined`
/// when the table was deleted after `all` listed it. The call returns
/// metadata only, whichever protection the table has.
@external(erlang, "ets", "info")
pub fn info(table: Term) -> Term

/// Find the tuple whose element at `position` is `key`, or `false`.
@external(erlang, "lists", "keyfind")
pub fn key_find(key: Atom, position: Int, list: Term) -> Term

/// Owners already looked up during one walk, by pid, so a process that owns a
/// thousand tables is asked for its label once.
pub type Cache

/// An empty cache.
@external(erlang, "maps", "new")
pub fn cache_new() -> Cache

/// The cached owner term for a pid, or `default` when it was not looked up.
@external(erlang, "maps", "get")
pub fn cache_get(pid: Pid, cache: Cache, default: Term) -> Term

/// Remember an owner term for a pid.
@external(erlang, "maps", "put")
pub fn cache_put(pid: Pid, owner: Term, cache: Cache) -> Cache
