# Pickglass plan of record

This is the design pickglass is built to. It adopts the Opus concept
(`concept-opus.md`), adapted to attach to a running node as described in
`selection.md`, and takes named parts of the Sonnet and Fable concepts. Where
this file and a concept disagree, this file wins. Where this file is silent, the
Opus concept is the reference.

## The shape

Pickglass is an independent program. It does not ask the target to embed it,
depend on it, or be rebuilt with it. It attaches to any running BEAM node the
operator can reach with that node's cookie, the way `observer` does.

There are two pieces of code:

- **The viewer** is the pickglass release, a self-contained OS process with its
  own VM. It holds the Lustre UI on localhost, the capture store, analysis and
  layout, comparison, exports and OS-level readings. Nothing the viewer does
  allocates in the target's heap.
- **The agent** is a small set of modules the viewer pushes into the target over
  distribution with `code:load_binary`, then starts as one long-lived registered
  process. It is the only code that touches the target's runtime. It owns every
  trace session, the pin table, budgets and the `scheduler_wall_time`
  reference. It monitors the viewer and, on disconnect, viewer death or explicit
  detach, destroys every session, releases every flag, exits, and purges its own
  modules.

The viewer joins as a hidden node with `dist_listen` false, so no third node can
reach it, and reads the cookie from an owner-only file, never from argv or the
environment. For Loom, the target is the existing `loomd --profile` node and its
`<state-root>/tokens/` cookie directory, discovered the way `scripts/observer.sh`
discovers it.

The web UI binds to `127.0.0.1` only. Remote access is out of scope.

## Packages

| Package | Gleam name | Pure | Depends on | Owns |
|---|---|---|---|---|
| `packages/core` | `pickglass_core` | yes (R6) | gleam_stdlib, gleam_json | measurement and unit types, `Cell`/`Additivity`, identity, ownership vocabulary, the agent wire vocabulary and its total decoders, the capture format and its codecs, provenance and comparability, the authority policy, and every analysis: profile model, pprof-style graph, flame and icicle layout, layered DAG layout, Top, Peek, the transform chain, diffs, timeline layout, exports |
| `packages/agent` | `pickglass_agent` | no | **nothing** | the pushed agent |
| `packages/web` | `pickglass_web` | no I/O | core, lustre | every page as a Lustre server-component application |
| `packages/pickglass` | `pickglass` | no | core, web, lustre, mist, weft | the viewer: attach, agent push and link, capture store, analysis pool, OS readers, HTTP and WebSocket host, tickets, CLI |

### The agent has no dependencies

The agent is loaded into someone else's VM, so it cannot carry `gleam_stdlib`,
`gleam_erlang`, `gleam_otp` or weft: loading those would replace the target's
own copies of the same modules, and purging them later would kill the target's
processes running that code. Its modules all live under
`src/pickglass_agent/`, so they compile to `pickglass_agent@*` names, and it
imports nothing outside its own package. Its OTP access is `@external` bindings
in `pickglass_agent/internal/ffi_*.gleam` modules. A check over the generated
`.beam` files (xref, or `beam_lib` imports) proves no call leaves the
`pickglass_agent@*`, `erlang`, `trace`, `instrument`, `ets`, `code`, `erts_debug`,
`proc_lib`, `lists`, `maps` and `os` modules, and `make check` runs it.

This is the one documented exemption from the weft rule. The agent stays small
(a receive loop, the census worker, probe controllers and tracers) so its
hand-written process code is a few hundred lines with the reason written at the
top of each module. Everything weft-shaped in the viewer uses weft.

### The wire is Erlang terms

Viewer and agent exchange plain Erlang terms over distribution: tuples, lists,
integers, binaries and a closed set of atoms that the agent defines. The viewer
decodes every reply with total decoders in `core` into domain types. The agent
never creates an atom from viewer input; module names in probe specs are
resolved with existing-atom semantics. A capture file records the decoded
records as NDJSON (`pickglass.capture/1`, Opus concept section 4.2), with
Sonnet's rule that a file with no footer reads as `Partial(NoFooter)`.

## Taken from the other concepts

From Sonnet: the authority `policy` with an opaque `Authorized(Command)` that
only `policy.authorize` can construct and an exhaustive
`required_capabilities`; plan-then-confirm for every probe and targeted GC;
`Cell = Value | Absent(reason)` and `Additivity = Additive | Overlapping(why)`;
the supervision walk from `process_info(parent)`; the observer-effect meter;
per-column verdicts in Compare.

From Fable: attribution carrying `source` and `confidence`, joined Label over
Registry over Supervision; the capability banner on every page; `pickglass attach
--once --out cut.pgcap` as the first shipped command; refusing a flame graph
when the source is counters only.

### Ownership is a protocol, not a library call

A host declares ownership by setting a process label with
`proc_lib:set_label({pickglass_owner, 1, Path, Role})`, where `Path` is a list
of `{Kind, Id}` binary pairs from outermost to innermost (for Loom,
`[{<<"session">>, Id}, {<<"strand">>, Id}]`) and `Role` is a binary. The agent
reads labels with `process_info(P, label)` and decodes this one shape;
anything else is `unknown`. A process that can measure a term it holds may also
answer `{pickglass_measure, Budget, ReplyTo, Ref}` with its own `flat_size`
reading, and advertises that by listing `<<"measure">>` in an optional third
label element. Loom adopts both by a `protocol-change/NNN.md` in its own repo.

## Authority

The viewer is a fully trusted administrative component: it holds a credential
that grants full control of the target. The gate that matters is therefore in
the viewer, between the browser and the agent link. A page's principal is set
once at WebSocket admission from a single-use ticket and is never read from an
event. Every command passes through `policy.authorize` before it can reach the
link. Every allow and deny is audited. Targets are named only by pin tokens.
The agent enforces budgets, admission and pin validity again as defense in
depth. Tests send forged Lustre events and direct HTTP requests and show they
fail.

## Views

All views are server-rendered SVG built from Lustre's `svg` elements with
layout in `core`, element counts bounded, native `<title>` hover, and no client
script.

Overview (memory layers with checkpoint deltas, schedulers, OS roles), Owners
(grouped by owner path with deltas), Processes and Process detail, Memory,
Supervision, Probes (plan, confirm, active, history), Profile (Flame, Icicle,
Graph, Top, Peek, Source), Timeline, Captures, Compare, Audit. Every panel shows
source, method, interval, coverage and truncation. A missing value is a word,
never zero.

## Work packages

Each package lands on `main` only when `make check` exits 0. Every worker gets a
fresh worktree; one builder per worktree.

**W1. Foundations (parallel).**

- *A. Agent and attach.* The `agent` package and the viewer's attach path:
  hidden-node start, cookie from file, discovery of a `loomd --profile` node,
  push, start, a ping, one census (bounded top-K plus per-owner aggregate over
  `processes_iterator`), one counters probe in its own trace session, detach.
  Exit: on a live `loomd --profile`, the probe's session survives many
  requests; `kill -9` of the viewer destroys it (`trace:session_info(all)`),
  releases `scheduler_wall_time`, purges the agent's modules and kills no
  target process; the beam import check passes.
- *B. Core data.* Measurement, units, `Cell`, `Additivity`, identity, owner
  vocabulary, the wire vocabulary decoders, the NDJSON capture codec,
  provenance and comparability, the authority policy. Exit: round-trip and
  totality property tests; comparability refuses mismatched method or
  workload.
- *C. Core analysis.* Profile model, pprof graph build and trim
  (`docs/research/research-go-and-viewers.md` section 1.8), flame and icicle
  layout with width budget, layered DAG layout, Top, Peek, transform chain with
  the three filter classes, differential profiles, collapsed-stack, speedscope
  and Chrome trace exports. Exit: tests against hand-built profiles, including
  pprof's default fractions and the dotted residual edges.

**W2. Observation UI.** The viewer's HTTP and WebSocket host on localhost with
tickets and CSP, the agent link with coalesced census, capture store and
`attach --once`; Overview, Owners, Processes, Process detail, Memory and
Supervision pages; Loom's label protocol-change and labels in the Loom repo.
Fable critiques the UI as it lands.

**W3. Probes and profile views.** Plan-and-confirm probes (counters, polled
stacks, targeted GC, self-measure), Flame, Icicle, Graph, Top, Peek, Source,
Timeline, Compare and Audit pages. Fable critiques the UI.

**W4. End to end.** Attach to a live `loomd --profile` with real sessions,
drive every page in a browser, run the probe lifecycle matrix (cancel,
deadline, disconnect, target death, viewer `kill -9`, concurrent `dbg`), and
answer the idle-daemon memory question with a baseline and candidate capture.
Opus or Fable reviews the whole change set.

Done means W4 passes against a live `loomd`, with the UI exercised in a browser.
