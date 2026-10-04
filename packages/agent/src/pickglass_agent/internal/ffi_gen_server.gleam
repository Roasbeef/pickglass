//// The `gen_server` bindings behind the agent's process.
////
//// Gleam has no `receive`, and the agent may not use `gleam_erlang` or
//// `gleam_otp`, which provide it. A `gen_server` supplies the receive loop,
//// and its callbacks are ordinary exported functions of the agent's own
//// module (`init/1`, `handle_info/2`, `terminate/2`), so no Erlang source
//// file is needed. The agent still has a closed message set: everything
//// that arrives goes through one `handle_info`, and anything it does not
//// recognise is dropped.

import pickglass_agent/internal/ffi_proc.{type SpawnOption}
import pickglass_agent/internal/ffi_term.{type Atom, type Term}

/// What a `handle_info` callback tells the gen_server to do next. The
/// constructors are the tuples `gen_server` expects back: `{noreply, State}`
/// and `{stop, Reason, State}`. Every module that runs a gen_server shares
/// this type, so none of them declares its own copy.
pub type Next(state) {
  Noreply(state: state)
  Stop(reason: ExitReason, state: state)
}

/// The exit reason of an orderly stop.
pub type ExitReason {
  Normal
}

/// An option for `gen_server:start/3`. `spawn_opt` hands the options to the
/// process the VM creates, which is how a helper gets a heap cap.
pub type StartOption {
  SpawnOpt(options: List(SpawnOption))
}

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

@external(erlang, "gen_server", "start")
fn start_anonymous(module: Atom, args: Term, options: List(StartOption)) -> Term

/// Start an unregistered gen_server without linking it to the caller, so a
/// crash in the helper reaches the caller as a monitor message and never as
/// an exit signal. Returns `{ok, Pid}` or `{error, Reason}`.
///
/// ## Examples
///
/// ```gleam
/// start_unlinked(ffi_term.atom("pickglass_agent@sampler"), args, [
///   SpawnOpt([ffi_proc.heap_limit(4_000_000)]),
/// ])
/// ```
pub fn start_unlinked(
  module: Atom,
  args: Term,
  options: List(StartOption),
) -> Term {
  start_anonymous(module, args, options)
}
