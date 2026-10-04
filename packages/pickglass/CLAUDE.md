# pickglass

## Purpose

The viewer: the pickglass program. It attaches to a running BEAM node the way
`observer` does, pushes the dependency-free agent (`pickglass_agent`) into it,
and talks to the agent. It joins the target as a hidden node with
`dist_listen` false, so it opens no listening socket, and reads the target's
cookie from an owner-only file, never from argv or the environment. For Loom
the target is a `loomd --profile` node, discovered the way
`scripts/observer.sh` in Loom discovers it. Today the program is the CLI
`pickglass attach`, which prints memory, a census top list and owner totals
and detaches, and `pickglass attach --probe-counters MODULE --seconds N`,
which runs a counters probe. With no arguments it prints the banner the
release smoke test compares.

## Key Types

`discover.Target` is a profiled node with its cookie directory. `attach.Session`
is one attach: the target node, the `link.Link` and the boot id.
`link.Link` is a weft actor that owns requests in flight and is the process
the agent monitors. `agent_beams.Beam` is one module to push. `cli.Command`
is a parsed command line. Requests and replies are `pickglass_core/wire` types.

## Relationships

Depends on `pickglass_core` (path `../core`) for the wire decoders and the
identity and owner vocabulary, on `weft`, `gleam_otp` and `gleam_erlang` for
the link actor, on `simplifile` for files and `argv` for the command line.
The agent package is not a dependency: its compiled beams are read as data,
from `priv/agent` in a release or from `packages/agent/build` in development.
The OTP bindings are in `internal/ffi_dist.gleam` and `internal/ffi_os.gleam`.

## Traffic

The viewer calls the target with `rpc:call` (`code:load_binary`, a release
check, `pickglass_agent@server:start`) and then sends `{<<"pg">>, 1, ReplyTo,
Ref, Request}` messages to the registered name `pickglass_agent`. The link
actor receives the replies as raw messages and decodes them with
`wire.decode_envelope`. It pings the agent every 5 s to renew a 30 s lease.

## Invariants

- The cookie is read from `<home>/.erlang.cookie` after a permission check
  (no group or other bits), set for the target node only, and never printed.
- Every attach ends with `attach.detach`, which asks the agent to tear down
  and waits for its modules to be unloaded. If the viewer dies instead, the
  agent notices the dead link process or lost connection by itself.
- The viewer's own distribution cookie is the ordinary `~/.erlang.cookie`.
  The VM creates that file if it is missing; it is not the target's cookie.
- `pickglass_agent@@main.beam` is never pushed.

## Deep Docs

`docs/design/plan.md` ("The shape", "Ownership is a protocol"),
`scripts/release.sh` for how the agent beams reach `priv/agent`, and
`packages/agent/CLAUDE.md` for the other end of the wire.
