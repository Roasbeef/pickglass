//// A map keyed and valued by terms, for the few walks that need to ask
//// "have I seen this one".
////
//// Each function binds a `maps` function directly. The key and value types
//// are `Term` because the callers hold addresses and sentinels the type
//// system has no better name for; a walk that wants a typed map defines its
//// own opaque type and externals, as the census does for its owners.

import pickglass_agent/internal/ffi_term.{type Term}

/// A map from terms to terms.
pub type Map

/// An empty map.
@external(erlang, "maps", "new")
pub fn new() -> Map

/// Whether a key has been put.
@external(erlang, "maps", "is_key")
pub fn has_key(key: Term, map: Map) -> Bool

/// Put a key with a value, replacing any earlier value.
@external(erlang, "maps", "put")
pub fn put(key: Term, value: Term, map: Map) -> Map
