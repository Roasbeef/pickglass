# pickglass

## Purpose

The viewer: the pickglass program. It attaches to a running BEAM node the
way `observer` does, pushes the dependency-free agent (`pickglass_agent`)
into it, and talks to the agent. It joins the target as a hidden node with
`dist_listen` false, so it opens no listening socket, and reads the target's
cookie from an owner-only file, never from argv or the environment. A target
is found one of two ways, exclusive of each other: the Loom way (a `loomd
--profile` node, discovered the way `scripts/observer.sh` in Loom discovers
it, with `--state-dir` and `--pid`) or by name (`--node NAME@HOST`, any node
on this machine, with `--cookie-file` or `~/.erlang.cookie`). `docs/attach.md`
is the operator's guide.

Commands: `pickglass open` attaches, starts the HTTP and WebSocket host on
`127.0.0.1` and prints a single-use URL; `pickglass view FILE` serves the
same pages over a capture file with no target; `pickglass attach --once
--out FILE` takes one reading and writes a capture; `pickglass attach`
prints memory, a census top list and owner totals and detaches, and
`--probe-counters MODULE --seconds N` runs a counters probe. `pickglass
compare BASELINE CANDIDATE` prints two capture files side by side with core's
comparability verdicts. `pickglass profile` runs one stack probe for an owner,
the busiest N or one pid through the service's page as the local owner and
writes speedscope, collapsed, Chrome, capture or text output (`profile_run`). With no
arguments it prints the banner the release smoke test compares.

## Key Types

Attach: `cli.Selector` says how the target is found (`LoomTarget` or
`NamedNode`); `endpoint.Endpoint` is a node name split at the `@`, its naming
mode (chosen from the host: a dot or colon is a long name) and its cookie
file, and `endpoint.check_loopback` is the single place that scopes targets to
this machine. `discover.Target` is a node with its OS pid and cookie file.
`attach.AttachError` is the typed failure of an attach (node not running,
cookie mismatch, naming-mode mismatch, OTP too old, an agent of another build
already running, an agent that is full), with `attach.describe`
for the one-line message.
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

Memory readings: a pass asks `owners_detail` and not `owners`, so one reply feeds
the census, the totals, each owner's heap and `Observation.detail` (each
process's `proc_lib` initial call, each owner's ETS tables and bytes, the ETS
pass's totals), and every `ets_every` (5th) pass also lists the largest ETS
tables as `Observation.ets`. `observation_codec` writes them as `owners_detail`
and `ets_tables` records and reads them back; a capture without them gives
`Error(detail_not_recorded)`. `feeds` draws the owners page's ETS column from
the aggregates (a row with none is a word unless the agent listed every owner
and read every table), the memory page's table panel from the newest listing,
and `supervision_build` takes the pass's initial calls so a process whose
`$initial_call` is known is a supervisor or a `Worker` and one the census did
not list keeps the name hints. `ReadBinaries(token)` is plan-first: `exec`
asks `binaries`, `service` keeps a `BinariesRan` or `BinariesRefused` result,
`capture_build` writes the reads as `binaries` records, and `feeds` shows the
newest on the process page. `feeds.flow` carries every pending plan, so the
plan of a collection or a binaries read is confirmed on the page that planned
it.

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

Agent features: `exec` runs counters (one module, or a counter set for
several) and stack-sampling probes, targeted collections, self-measures,
process detail and the supervision walk; a stop or poll names the probe's
kind. A finished stack probe goes through `profile_from_stacks`.
`supervision_build` turns the spawn edges into the page's tree, bounded at
400 nodes. `feeds` also builds the process detail page (address
`/process/<key>`, carried to the feeder as the slug `process-detail:<key>`),
node facts (uptime, creation, scheduler counts, allocator carriers, read by
the hub every 15th pass) and the owners remainder from the agent's totals.
A collection and a self-measure are planned and confirmed like a probe, and
the service keeps their results for the process's page.

Pages: `seam` is the contract with the web package: `seam.Request` (what a
page may ask), `seam.intent` (request to policy command), `seam.Page` (the
closures a page's application gets, bound to the principal fixed at socket
admission) and `seam.Mount`. `web_mount` mounts `pickglass_web`'s real
application per socket: a feeder actor subscribes to the hub, builds the
page models (`feeds`) and sends `Fed` messages, and resolves the
application's `msg.Request` keys against current data into `seam.Request`s.

One-click profiles: `profile_scope` (pure) chooses at most sixteen processes by
reductions per second, then heap, and words the choice. A node-wide choice
leaves out pickglass's own agent processes (owner `tool:pickglass`,
`without_own`) and the sentence says how many; profiling that owner by name or
one process is not filtered. `service.profile` is
the one request that is several commands: it pins what is not pinned, plans a
stack probe over the pins (`seam.PlanProbe` carries `rate_hz`), and records what
it pinned as `service.Held` against the plan. The service releases those pins
(through the gate, in a weft run) when the plan is cancelled, replaced or
lapses, when the start fails, and when the probe ends; a pin the operator held
first is never in `Held`. `seam.Page.profile` and `profile_notes` carry it to
the pages, and `feeds.flow` is what every page but Probes draws above its body.

the four probe kinds are run by `exec`. `calltrace_profile` turns a call tree
into a `TracedCalls` profile (calls, inclusive and exclusive ns, drawn from
exclusive) with the stop reason and drops as caveats; a scheduling probe has no
profile and keeps its result as `probe_book.Detail`, which `to_records` writes as
an `events` record and `timeline_build` draws. A pending profile plan can be
re-planned by another `seam.ProfileMethod` over the pins it holds. Stack
profiles default to running samples in pages, exports and compare;
`pickglass profile` takes `--include-waiting`, and `--trace-calls --module`.
Earlier: `probe_book`Probes and profiles: `probe_book` is the viewer's record of each probe (running,
or finished with its profile, outcome and cost); `service` polls running
probes once a second and takes a result into `counters_profile` before the
agent discards it. `profile_from_stacks` turns an aggregated-stacks result
(its own input type) into a `SampledStacks` profile whose total equals the
input counts. `profile_export` builds collapsed, speedscope and Chrome trace
files; `downloads` holds them as one-time tickets served at
`/download/<ticket>`.

OS and checkpoints: `os_reader` reads `ps` (one fixed command line) and
`/proc` for the target and its children; `Observation.os` carries them.
`marks.Mark` is a checkpoint with a copy of the observation it is compared
against, and `deltas` computes every change since it. `timeline_build`,
`compare_build` and `compare_report` build the Timeline and Compare pages
and the `compare` command; `clock` relates the agent's clock to the viewer's
by timing a ping.

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

The viewer calls the target with `rpc:call` (a release check, `whereis`, and
when no agent is registered the push claim, `code:load_binary` and
`pickglass_agent@server:start`) and then sends `{<<"pg">>, 1, ReplyTo,
Ref, Request}` messages to the registered name `pickglass_agent`. The link
actor receives the replies as raw messages and decodes them with
`wire.decode_envelope`. It pings the agent every 5 s to renew a 30 s lease.

Browser to host: `GET /t/<ticket>` (exchange, 303 and a cookie), `GET
/<page>` (HTML shell with a per-page nonce), `GET /ws?page=<slug>&csrf-token=`
(Lustre's WebSocket), `GET /assets/<name>`. Page to service: `seam.Page`
closures, which message the service and hub actors. Hub to page: `Update`
messages to the feeder's subject.

## Invariants

- The cookie of the target is read from a file after a permission check (no
  group or other bits), set for the target node only, and never printed. It is
  never taken from argv (`--cookie`, `--cookie=`, `--setcookie` are refused)
  or the environment.
- `--node` and `--state-dir`/`--pid` are mutually exclusive, and the viewer's
  hidden node uses the target's naming mode. OTP's `connect_node` answers
  `false` for a down node, a wrong cookie and a wrong mode alike, so
  `attach.diagnose` asks epmd and retries in the other mode to tell them apart.
- The viewer's own VM has no distribution cookie: the release launcher
  passes `-nocookie`, and `ffi_dist.start_hidden_node` refuses to start
  distribution in a VM that has neither `-nocookie` nor `-setcookie`, because
  OTP would then create `~/.erlang.cookie` in the operator's home. In
  development run with `ERL_FLAGS=-nocookie`.
- Several viewers share one agent per node. A viewer never pushes over a
  registered agent: it asks to `join`, and the agent admits it only if
  `agent_beams.identity` (a digest of the beams) equals the build the agent
  started with, so a viewer of another build gets `AgentBuildMismatch` naming
  both builds and nothing is replaced. When no agent is registered the viewer
  takes the push claim (a registered name, `pickglass_agent_claim`, on a
  process that sleeps 15 s on the target), looks again, then pushes and
  starts; a viewer that loses the claim waits and joins the winner's agent.
  A join that gets no answer means the agent stopped, and the viewer waits for
  the old modules to leave before it starts over.
- Every attach ends with `attach.detach`, which asks the agent to release this
  viewer. When it was the last viewer the agent unloads its modules and
  `detach` waits for that; when others remain the agent answers `left` and
  `detach` reports `OtherViewersRemain`. If the viewer dies instead, the agent
  notices the dead link process or lost connection by itself and releases only
  that viewer.
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
- Pages the viewer has no data for (supervision, process detail) get no feed
  and say they are waiting; nothing is invented. A missing figure (OS reading
  not taken, run queue, node uptime) is a word, never zero. The pong's
  `uptime_ms` is the agent's age, not the node's, so the strip's uptime stays
  missing.
- A page's filter chain, exports, baseline and chosen captures live in its own
  feeder, so two tabs are independent. A download ticket is stored as a digest,
  consumed by the attempt, and needs the session cookie.
- `exec.poll_counters` is the one agent request made outside `exec.run`: it
  reads a probe an authorized command already started.
- A capture's footer digest is the SHA-256 of every line before the footer,
  each with its newline; `capture_file.read` recomputes it from the file text.
- `pickglass_agent@@main.beam` is never pushed.
- A one-click profile never starts without a confirmed plan, and what it
  pinned is released when the plan or the probe ends. A lost target clears
  `Held` without asking the agent.

## Deep Docs

`docs/design/plan.md` ("The shape", "Authority"), `docs/lustre.md` (server
components, CSP, the nonce), `scripts/release.sh` for how the agent beams and
the `-nocookie` launcher are built, and `packages/agent/CLAUDE.md` for the
other end of the wire. `packages/web/CLAUDE.md` describes the application the
host mounts.
