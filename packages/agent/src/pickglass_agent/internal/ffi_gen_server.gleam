//// The `gen_server` bindings behind the agent's process.
////
//// Gleam has no `receive`, and the agent may not use `gleam_erlang` or
//// `gleam_otp`, which provide it. A `gen_server` supplies the receive loop,
//// and its callbacks are ordinary exported functions of the agent's own
//// module (`init/1`, `handle_info/2`, `terminate/2`), so no Erlang source
//// file is needed. The agent still has a closed message set: everything
//// that arrives goes through one `handle_info`, and anything it does not
//// recognise is dropped.

import pickglass_agent/internal/ffi_term.{type Atom, type Term}

/// The registration `gen_server:start/4` takes: `{local, Name}`.
pub type ServerName {
  Local(name: RegisteredName)
}

/// The one name the agent registers under, so a second attach to the same
/// node fails with `already_started` instead of creating a second agent.
pub type RegisteredName {
  PickglassAgent
}

/// Start a gen_server without linking it to the caller. The caller is
/// usually a temporary `erpc` process on the target, and the agent must
/// outlive it.
@external(erlang, "gen_server", "start")
fn start_server(
  name: ServerName,
  module: Atom,
  args: Term,
  options: List(Term),
) -> Term

/// Start the agent under its fixed registered name, running the callbacks of
/// `module`. Returns `{ok, Pid}`, `{error, {already_started, Pid}}` or
/// another `{error, Reason}`.
///
/// ## Examples
///
/// ```gleam
/// start(ffi_term.atom("pickglass_agent@server"), config)
/// ```
pub fn start(module: Atom, args: Term) -> Term {
  start_server(Local(PickglassAgent), module, args, [])
}
