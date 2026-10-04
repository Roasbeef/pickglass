//// Unloading the agent from the node it was pushed into.
////
//// The agent leaves nothing behind: when it exits, every `pickglass_agent@`
//// module it was pushed as is deleted and purged. That cannot be done by
//// the agent itself, because a process cannot purge code it is executing,
//// and it cannot be done by a process running any of the agent's modules for
//// the same reason, except for one trick this module relies on. `code:purge`
//// is carried out by the code server, so when the janitor purges its own
//// module the code server finishes the purge and the janitor, which was
//// running that code, is killed by it. The janitor therefore deletes every
//// module first, purges every module but its own, and purges its own last.
////
//// The janitor is started by `erlang:spawn/3` with this module's `run/1` as
//// the initial call, not with a closure. A process holding a closure of a
//// module counts as running that module's code, and a closure of the
//// server's module would get the janitor killed in the middle of purging the
//// server.
////
//// The agent calls `unload_after_exit` from `terminate`, so the unload runs
//// whether the agent stopped on request, on a lost viewer, on a deadline or
//// on a crash. When the agent is killed outright, `terminate` does not run
//// and the modules stay loaded; the viewer's next attach finds and purges
//// them before it pushes new ones.

import pickglass_agent/internal/ffi_code
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Atom, type Pid}
import pickglass_agent/internal/seq

/// The prefix of every module the agent is pushed as.
pub const module_prefix = "pickglass_agent@"

/// How many times the janitor yields while waiting for the agent to finish
/// exiting. The agent is on its way out when the janitor starts, so the
/// wait is normally a few turns.
const patience = 100_000

/// The modules currently loaded under the agent's prefix.
///
/// ## Examples
///
/// ```gleam
/// loaded_modules()
/// // -> [the atoms pickglass_agent@server, pickglass_agent@census, ...]
/// ```
pub fn loaded_modules() -> List(Atom) {
  let loaded = seq.map(ffi_code.all_loaded(), fn(entry) { entry.0 })

  seq.filter(loaded, has_prefix)
}

fn has_prefix(module: Atom) -> Bool {
  case ffi_term.atom_name(module) {
    "pickglass_agent@" <> _ -> True
    _ -> False
  }
}

/// Start the janitor for the agent process `agent`. It returns at once; the
/// unload happens once the agent has exited.
///
/// ## Examples
///
/// ```gleam
/// unload_after_exit(ffi_proc.self())
/// ```
pub fn unload_after_exit(agent: Pid) -> Nil {
  let _ =
    ffi_proc.spawn_call(
      ffi_term.atom("pickglass_agent@janitor"),
      ffi_term.atom("run"),
      [ffi_term.coerce(agent), ffi_term.coerce(loaded_modules())],
    )

  Nil
}

/// The janitor's entry point, exported so `spawn/3` can name it. Waits for
/// the agent to exit, deletes and purges every module, and ends by purging
/// its own.
///
/// Nothing here may call another module of the agent, including the helpers
/// in `internal/`: the janitor purges those modules while it runs, and a
/// process executing a module's old code when it is purged is killed. The
/// janitor's bindings are therefore declared locally, and the walks are
/// plain recursion.
pub fn run(agent: Pid, modules: List(Atom)) -> Nil {
  wait_for_exit(agent, patience)
  delete_all(modules)
  purge_all(modules, own_module())

  // The last purge ends this process, so nothing may follow it.
  let _ = purge(own_module())

  Nil
}

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(name: String) -> Atom

fn own_module() -> Atom {
  binary_to_atom("pickglass_agent@janitor")
}

@external(erlang, "code", "delete")
fn delete(module: Atom) -> Bool

@external(erlang, "code", "purge")
fn purge(module: Atom) -> Bool

@external(erlang, "erlang", "is_process_alive")
fn is_alive(pid: Pid) -> Bool

@external(erlang, "erlang", "yield")
fn yield() -> Bool

fn wait_for_exit(agent: Pid, remaining: Int) -> Nil {
  case remaining > 0 && is_alive(agent) {
    True -> {
      let _ = yield()

      wait_for_exit(agent, remaining - 1)
    }
    False -> Nil
  }
}

fn delete_all(modules: List(Atom)) -> Nil {
  case modules {
    [] -> Nil
    [module, ..rest] -> {
      let _ = delete(module)

      delete_all(rest)
    }
  }
}

// Every module but the janitor's own. The janitor's is purged last, by the
// caller, because purging it ends this process.
fn purge_all(modules: List(Atom), own: Atom) -> Nil {
  case modules {
    [] -> Nil
    [module, ..rest] if module == own -> purge_all(rest, own)
    [module, ..rest] -> {
      let _ = purge(module)

      purge_all(rest, own)
    }
  }
}
