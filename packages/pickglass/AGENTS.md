# pickglass

## Purpose

The viewer: the pickglass program. It attaches to a running BEAM node the
way `observer` does, pushes the dependency-free agent (`pickglass_agent`)
into it, and talks to the agent. It joins the target as a hidden node with
`dist_listen` false, so it opens no listening socket, and reads the target's
cookie from an owner-only file, never from argv or the environment. For Loom
the target is a `loomd --profile` node, discovered the way
`scripts/observer.sh` in Loom discovers it.

Commands: `pickglass open` attaches, starts the HTTP and WebSocket host on
`127.0.0.1` and prints a single-use URL; `pickglass view FILE` serves the
same pages over a capture file with no target; `pickglass attach --once
--out FILE` takes one reading and writes a capture; `pickglass attach`
prints memory, a census top list and owner totals and detaches, and
`--probe-counters MODULE --seconds N` runs a counters probe. With no
arguments it prints the banner the release smoke test compares.

## Key Types

Attach: `discover.Target` is a profiled node with its cookie directory.
`attach.Session` is one attach. `link.Link` is a weft actor that owns
requests in flight and is the process the agent monitors. `remote.Remote` is
what everything above the link sees of a target: node, boot id, `ask` and
`detach`, so tests play the agent with a function. `agent_beams.Beam` is one
module to push.

Collection: `observation.Observation` is one pass (memory, one census,
scheduler readings), each section a `Result` so a failed reading says why.
`hub` is the single collector: one census per cadence for any number of
pages, a `ring.Ring` of recent observations, `Subscribe`, and `TargetLost`
after three empty passes. A replay hub (`start_replay`) serves a capture.

Authority: `gate.Gate` is the pure state behind `policy`: the pin table (only
tokens the agent issued this boot and that are still live become a
`LivePin`), the `plans.Store` (a plan is consumed by its owner's confirm,
whatever the outcome), and the entries each decision returns. `exec.run`
takes only an `Authorized(Command)` and is the one module that sends
commands on the link. `service` is the actor that owns the gate, runs the
executor, and appends every entry to `audit.Log`.

Front door: `ticket.Registry` (pure) and `admission` (its actor) hold tickets,
sessions and page nonces by SHA-256 digest. `rules` is the pure request
checks (loopback `Host`, `Sec-Fetch-Site`, `Origin`, cookies, CSP). `frame`
checks the browser's WebSocket frames. `host` is the mist server.
`assets` is the closed list of static files.

Pages: `seam` is the contract with the web package: `seam.Request` (what a
page may ask), `seam.intent` (request to policy command), `seam.Page` (the
closures a page's application gets, bound to the principal fixed at socket
admission) and `seam.Mount`. `web_mount` mounts `pickglass_web`'s real
application per socket: a feeder actor subscribes to the hub, builds the
page models (`feeds`) and sends `Fed` messages, and resolves the
application's `msg.Request` keys against current data into `seam.Request`s.

Captures: `observation_codec` maps observations to `pickglass.capture/1`
records and back, `capture_build` assembles header and records,
`capture_file` writes gzip NDJSON with the footer SHA-256 and reads and
verifies it.

## Relationships

Depends on `pickglass_core` (path `../core`) for the wire decoders, policy
and capture format, on `pickglass_web` (path `../web`) for the pages, on
`weft`, `gleam_otp` and `gleam_erlang` for the actors, on `mist` and `lustre`
(pinned `== 5.7.1`, as the web package pins it) for the host, on
`gleam_crypto` for digests and secrets, on `simplifile` for files and `argv`
for the command line. The agent package is not a dependency: its compiled
beams are read as data, from `priv/agent` in a release or from
`packages/agent/build` in development. The OTP bindings are in
`internal/ffi_dist.gleam`, `internal/ffi_os.gleam` and
`internal/ffi_zlib.gleam`.

## Traffic

The viewer calls the target with `rpc:call` (`code:load_binary`, a release
check, `pickglass_agent@server:start`) and then sends `{<<"pg">>, 1, ReplyTo,
Ref, Request}` messages to the registered name `pickglass_agent`. The link
actor receives the replies as raw messages and decodes them with
`wire.decode_envelope`. It pings the agent every 5 s to renew a 30 s lease.

Browser to host: `GET /t/<ticket>` (exchange, 303 and a cookie), `GET
/<page>` (HTML shell with a per-page nonce), `GET /ws?page=<slug>&csrf-token=`
(Lustre's WebSocket), `GET /assets/<name>`. Page to service: `seam.Page`
closures, which message the service and hub actors. Hub to page: `Update`
messages to the feeder's subject.

## Invariants

- The cookie of the target is read from `<home>/.erlang.cookie` after a
  permission check (no group or other bits), set for the target node only,
  and never printed.
- The viewer's own VM has no distribution cookie: the release launcher
  passes `-nocookie`, and `ffi_dist.start_hidden_node` refuses to start
  distribution in a VM that has neither `-nocookie` nor `-setcookie`, because
  OTP would then create `~/.erlang.cookie` in the operator's home. In
  development run with `ERL_FLAGS=-nocookie`.
- Every attach ends with `attach.detach`, which asks the agent to tear down
  and waits for its modules to be unloaded. If the viewer dies instead, the
  agent notices the dead link process or lost connection by itself.
- The only path from a page to the agent link is `service` then `gate` then
  `exec`. A command reaches `exec` only as `policy.Authorized`. A probe or
  targeted GC needs `policy.plan` then `policy.confirm`, and the plan store
  removes a plan when its owner confirms it, so a replayed confirm finds
  nothing. A viewer probe names pins and never every process.
- A page's principal and grants are fixed from the session at WebSocket
  admission and are closed over by its `seam.Page`; nothing read from an
  event can change them. A frame must have exactly the keys of an event or a
  batch (`frame.check`), or it is dropped and audited.
- A ticket is consumed by the attempt to redeem it. Tickets, cookies and
  nonces are stored only as digests. A page response carries the strict CSP
  with its nonce, and that nonce is the `csrf-token` its socket must present.
- A key a browser sends names a thing by identity (pid text, pin token, plan
  id), and `web_mount` resolves it against current data. A key that names
  nothing now makes no request.
- Pages the viewer has no data for (supervision, profile, timeline, compare,
  process detail) get no feed and say they are waiting; nothing is invented.
- A capture's footer digest is the SHA-256 of every line before the footer,
  each with its newline; `capture_file.read` recomputes it from the file text.
- `pickglass_agent@@main.beam` is never pushed.

## Deep Docs

`docs/design/plan.md` ("The shape", "Authority"), `docs/lustre.md` (server
components, CSP, the nonce), `scripts/release.sh` for how the agent beams and
the `-nocookie` launcher are built, and `packages/agent/CLAUDE.md` for the
other end of the wire. `packages/web/CLAUDE.md` describes the application the
host mounts.
