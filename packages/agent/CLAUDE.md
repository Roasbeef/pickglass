# pickglass_agent

## Purpose

The agent pickglass pushes into a running BEAM node. The viewer loads these
modules with `code:load_binary` over distribution and starts `server` as one
registered process, `pickglass_agent`. The agent is the only code that touches
the target's runtime: it owns every trace session, the pin table, the
`scheduler_wall_time` reference and the census workers, because those die with
the process that created them and a request over distribution runs in a
temporary process.

## Key Types

`request.Request` is the closed set of things the viewer may ask, and
`request.decode` the total decoder for it. `server.State` holds the pins, the
probes (`counters.Probe`, whose `Running` phase holds the only strong trace
session handle), the census workers and the lease. `census.Report` and
`counters.Snapshot` are the bounded results. `owner.Owner` is `Unknown` or
`Owned(path, role)`, decoded from a `{pickglass_owner, 1, Path, Role}` label.

## Relationships

No dependencies at all (gleeunit and gleam_stdlib are dev only). Loading any
library into the target would replace the target's own copy of the module, and
purging it would kill the target's processes running it. Everything under
`src/pickglass_agent/` compiles to `pickglass_agent@*` modules. OTP is reached
through `internal/ffi_*.gleam` externals. The viewer (`pickglass`) pushes the
beams and decodes replies with `pickglass_core/wire`.

## Traffic

Requests are `{<<"pg">>, 1, ReplyTo, Ref, {<<"tag">>, ...}}` messages sent to
the registered name; replies are `{<<"pg">>, 1, Ref, {<<"tag">>, ...}}`. The
wire uses binaries, integers, lists, tuples and `true`/`false` only, never an
atom, so the agent creates no atom from input. Names in a probe spec resolve
with `binary_to_existing_atom`. The agent monitors the viewer's link process
and node, and ticks every 250 ms to enforce a lease and probe deadlines.

## Invariants

- Imports stay inside `pickglass_agent@*`, `erlang`, `trace`, `code`, `maps`,
  `gen_server` and `rpc` (plus the plan's other OTP modules). `make
  agent-imports` checks the compiled beams. `pickglass_agent@@main` is the
  compiler's entry module, is never pushed, and is skipped.
- The strong trace session handle is held only in `server.State`. It is never
  sent, returned or logged.
- Every exit path calls `shut_down`: detach, viewer link DOWN, `nodedown`,
  lease expiry, and `terminate` after a crash. A kill signal skips it and the
  VM destroys the sessions because the agent was their sole holder.
- The janitor calls no other agent module while it runs, because it purges
  them. It purges its own module last, which ends it.
- Calls that can raise on outside input go through `ffi_safe.call`.
- `make agent-e2e` pushes the beams into a peer and checks teardown after a
  killed link, a detach and `kill -9` of the viewer.

## Deep Docs

`docs/design/plan.md` ("The agent has no dependencies", "The wire is Erlang
terms") and `docs/research/research-beam-runtime-apis.md` (trace sessions).
