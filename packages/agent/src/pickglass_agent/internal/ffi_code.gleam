//// The code server's view of loaded modules.
////
//// The agent leaves no trace of itself in the target: when it detaches,
//// every module it was pushed as is deleted and purged, which the janitor
//// does with bindings of its own. This module binds the one reading the
//// agent needs to find its modules. The agent never loads code itself; the
//// viewer pushes it.

import pickglass_agent/internal/ffi_term.{type Atom, type Term}

/// Every loaded module as `{Module, Where}`. The agent filters this by name
/// prefix to find its own modules.
@external(erlang, "code", "all_loaded")
pub fn all_loaded() -> List(#(Atom, Term))
