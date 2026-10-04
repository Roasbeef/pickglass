# Pickglass design concept brief

You are one of three designers writing **independent, competing design
concepts** for pickglass. The owner will pick one (or merge parts of
several). Do not coordinate with the other designers and do not read their
output. A concept that takes a distinct, well-argued position is more useful
than a cautious average of every option.

## What pickglass is

Pickglass is a generic, best-in-class BEAM runtime inspector and
performance/trace viewer. It is written in nearly pure Gleam, uses Lustre
server components for its web UI, and ships as a self-contained static
release (bundled ERTS, no `erl` on PATH needed). It should be for the BEAM
what `go tool pprof`, `go tool trace` and `/debug/pprof` are for Go, and
better than them where the BEAM allows: per-process heaps, supervision
structure, process labels, trace sessions.

Its first concrete goal is to close loom issue #720. Read it in full:
`gh api repos/Roasbeef/loom/issues/720 --jq .body` (retry with the sandbox
disabled on TLS errors). Pickglass is generic: Loom is the first consumer,
not the only one. Anything Loom-specific (session, strand, op, step
ownership) must enter through a generic extension point, for example an
ownership/label provider the host application registers, not through
hard-coded Loom knowledge.

## Loom's existing diagnostic access

Loom already has an opt-in attach path; your deployment model must say how
it uses, extends or replaces it. Read
`/Users/roasbeef/gocode/src/github.com/roasbeef/loom/.claude/worktrees/loom-repo-naming-38bbed/docs/distribution.md`
("Installing for live profiling") and `scripts/profile-launcher.sh`,
`scripts/observer.sh`, `scripts/mem_report.erl` in that checkout. In short:
`loomd --profile` (or `[daemon] profile = true`) starts the daemon as a
distributed node `loom_daemon_profile_<pid>_<random>@127.0.0.1`, with the
distribution listener bound to loopback, a fresh random cookie in a 0600 file
under `<state-root>/tokens/` (masked from session tools), and `+Muatags true`
so `instrument` can group allocations per process. `loomd observer` finds the
profiled node from the process table and attaches a hidden GUI node through
that private cookie directory, without the cookie entering any argument
vector or environment. `loom-profile` runs a one-shot memory census. A debug
install (`make install-debug`) also carries OTP's `tools` (tprof) and
`LOOM_DEBUG_ARGS_FILE` for a prepared OTP argument file. None of this is
reachable from the browser, and it gives no ownership attribution.

## Fixed requirements

1. **Views**, each labelled with its data source (sampled stacks, traced
   calls, allocation counts, event timestamps), method, coverage and
   truncation:
   - Flame graphs and icicle graphs, including differential flame graphs.
   - A call-graph DAG like `go tool pprof`'s Graph view, with node/edge
     pruning, focus/ignore/hide/show filters, and the pprof distinction
     between filters that change totals and filters that only change
     display.
   - Top, Peek and Source tables. Source maps generated Erlang back to
     `.gleam` where debug metadata allows; otherwise it shows the
     generated name.
   - A timeline view (scheduler, GC, mailbox, operation events) that shows
     uncertainty, dropped events and incomplete coverage.
   - Process browser, supervision tree (shown separately from semantic
     ownership), memory categories, scheduler/run-queue trends, OS-process
     roles (daemon, clients, satellites, helpers).
   - Baseline/candidate comparison of captures, refusing an unlabelled
     improvement claim when builds or collection methods differ.
2. **Exports**: a versioned pickglass-native capture format with a
   provenance header, plus derived exports (Chrome trace JSON for Perfetto,
   speedscope, collapsed stacks, pprof proto), each with a documented loss
   list.
3. **Safety**: everything in #720's "Authority, confidentiality and probe
   budgets" section. Closed typed operations only, never evaluation or
   arbitrary MFA calls. Observation and expensive probes are separate
   capabilities. Every probe is bounded (processes scanned, samples, wall
   time, bytes, depth, events, concurrency), owns its trace session and
   timers, and releases them on every exit path without disturbing other
   tracers. A missing counter is never rendered as zero.
4. **Reachability**: the web UI binds to **localhost only** for now. Remote
   access, TLS and multi-user auth are out of scope, but the authority
   model must still enforce every action server-side (forged Lustre
   events and direct requests must fail) and must not preclude remote
   access later.
5. **House rules**: read `/Users/roasbeef/gocode/src/github.com/roasbeef/pickglass/CLAUDE.md`
   and `docs/gleam-style.md` (skim Parts III and IV closely), `docs/lustre.md`
   and `docs/weft.md` in that repo. In short: a pure `core` package with no
   I/O, no `@external`, no gleam_erlang/gleam_otp (lint R6 enforces it);
   FFI is a last resort, confined to `internal/ffi_*` modules with a
   written reason; process machinery goes through weft (the sibling
   checkout `/Users/roasbeef/gocode/src/github.com/roasbeef/weft`); total
   decoders at every wire boundary; no naked `Bool`; literate code.
   Lustre effects run synchronously in the server component's process, so
   collection must never run inside an effect.

## Research to read first

All three are in
`docs/research/`:

- `research-beam-inspectors.md`: Observer Web, observer, observer_cli,
  LiveDashboard, recon and the gaps none of them cover.
- `research-go-and-viewers.md`: pprof, `/debug/pprof`, `go tool trace`,
  perf/flamegraph, Perfetto, speedscope, Firefox Profiler, Pyroscope; and
  how pprof's Graph view is built.
- `research-beam-runtime-apis.md`: trace sessions, tprof, process_info
  costs, memory/allocator APIs, msacc, stack sampling, distribution,
  Gleam debug metadata, and a capability matrix with the minimum FFI
  surface.

Two pieces of prior art deserve a close look. **Spectator** is a Gleam
inspector on the same stack as pickglass (mist, Lustre server components,
gleam_otp). Say what you would take from it and what you would not: about
730 lines of FFI, a full `process_info` poll every second, and unguarded
kill/suspend. **observer_cli 2.0** is the closest existing match to #720's
principles: heap-capped, deadline-bounded collection workers, scan budgets,
and a versioned complete/partial/error envelope with per-probe coverage.
Its source was cloned locally during research.

Treat claims marked unverified or inferred as such. You may check facts
yourself (`erl`, `gleam`, `go doc`, the web), but this is a design task,
not more research.

## What your concept must contain

Write it as one markdown document. Plain, direct technical prose; tables
and diagrams (mermaid) where they help. It should cover:

1. **Thesis**: the one-paragraph position your design takes and why.
2. **Deployment model**: in-node library, sidecar hidden node, separate OS
   process attaching over distribution, or a combination; how pickglass
   reaches a Loom daemon; the trust boundary (distribution is full mutual
   trust, and the cookie must stay in owner-only storage); how the static
   release fits.
3. **Package layout**: the packages, what each owns, which are pure, and
   the dependency edges. Name every FFI binding you expect and why no pure
   alternative exists.
4. **Data model**: the capture format (samples, value columns with units,
   labels, provenance, coverage and truncation markers), identity of
   processes across restarts (node incarnation, birth identity, OS PID and
   start time), and the ownership/label provider extension point.
5. **Collectors and probes**: each collector's mechanism, budget and
   cleanup, built on weft primitives. The probe lifecycle as a state
   machine with a transitions table. How flame graph and DAG data are
   produced on the BEAM (traced calls versus polled stacks versus tprof),
   and what each one can and cannot claim.
6. **Authority model**: capabilities, how each request is authorized
   server-side, audit entries, and what changes when remote access arrives
   later.
7. **Web UI**: information architecture (page list and navigation), the
   key screens described concretely (what is on screen, what the operator
   does), how flame graphs and the DAG render in Lustre (SVG, canvas via a
   small client component, or server-rendered; justify against
   server-component bandwidth and the CSP rules in `docs/lustre.md`), and
   how the UI stays responsive under large captures. Include at least one
   ASCII or HTML-ish wireframe per key screen.
8. **Answering #720**: walk the idle-daemon memory question end to end
   ("resident memory grows while sessions appear idle: which actor owns
   it?") through your design, screen by screen, naming what evidence each
   step gives and what it cannot prove. Do the same briefly for a CPU
   question.
9. **Phasing**: milestones mapped onto #720's four phases, each with exit
   criteria, and what ships first to be useful soonest.
10. **Risks and open questions**: what needs measurement before it can be
    committed to, and what you would cut first.
11. **What you rejected**: the main alternatives and why.

Length: as long as it needs to be to be concrete, and no longer. Around
4,000 to 8,000 words is a reasonable range.

## Output

Write your concept to
`docs/design/concept-<your-label>.md`
where `<your-label>` is given in your assignment. Write no other files and
change nothing in any repo. Your final reply: the thesis paragraph plus a
10-line summary of the key choices.

## Prose rule from the owner

"Mannered prose substitutes metaphor and flourish for direct statement.
Instead of 'a parameter worth varying,' the mannered writer produces 'a
dial worth turning.' Instead of 'this point still matters,' they write
'this point earns its keep.' The phrases exist to display the writer, not
to convey the idea, and readers can tell. That is why mannered prose
irritates: it makes the reader work harder so the writer can perform. It
is also imprecise. Metaphors drag in connotations the writer did not choose
and cannot control. The fix is to say what you mean. When a literal phrase
is available, use it."
