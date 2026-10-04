# Pickglass

Pickglass is a runtime inspector and a performance and trace viewer for the
BEAM, written in Gleam with Lustre server components for the web UI. It
attaches to a running Erlang, Elixir or Gleam node the way `observer` does,
from outside, with no change to the program it inspects. Its first goal was
closing [Roasbeef/loom#720](https://github.com/Roasbeef/loom/issues/720): find
out who holds a daemon's memory and where its work goes, per session, without
restarting it.

What it shows, each on a page of its own:

- **Memory.** `erlang:memory` categories, allocator carriers and how much of
  each is used, the OS resident set, and the largest ETS tables (properties
  only, never contents).
- **Owners.** Processes grouped by who owns them, from labels the program sets
  with `proc_lib:set_label/1`, with heap capacity, mailbox, reductions per
  second, ETS bytes and the change since a named checkpoint. Processes nobody
  claimed are always shown as `unknown`.
- **Process.** One process: sizes, garbage collection settings, the binaries it
  holds, and actions on it (profile, trace calls, record scheduling, collect
  garbage).
- **Profile.** Flame, icicle, call graph and top-functions views over stack
  samples or traced calls, with filters and exports (speedscope, collapsed
  stacks, Chrome trace).
- **Timeline, Supervision, Compare, Audit.** When processes ran and collected
  garbage, the spawn tree, two captures side by side with the fields that make
  a comparison unsafe called out, and every decision the viewer made.

## Quick start

Building needs `gleam`, `rebar3` and Erlang/OTP 29. Running the release needs
nothing else.

```sh
make release          # self-contained release in build/release/pickglass

P=build/release/pickglass/bin/pickglass

# A Loom daemon started with --profile, found from its state directory.
$P open --state-dir ~/.loom

# Any node on this machine, started with a name (see docs/attach.md).
$P open --node app@127.0.0.1

# One reading written to a capture file, and a profile from a terminal.
$P attach --node app@127.0.0.1 --once --out baseline.pgcap
$P profile --node app@127.0.0.1 --top 8 --format text
$P profile --node app@127.0.0.1 --top 2 --trace-calls --module 'my_app*'

# Two captures side by side, with the checks on whether they can be compared.
$P compare baseline.pgcap candidate.pgcap
```

`open` joins the target, prints a single-use URL on `127.0.0.1` and serves the
pages there until you press Ctrl-C, which detaches. `pickglass view FILE`
serves the same pages over a capture with no target. `docs/attach.md` is the
operator's guide: what a distributed node is, how to start yours so pickglass
can attach, how to label your processes, and what to check when attaching
fails. `docs/design/plan.md` is the plan of record that the code is built to.

## Safety model

Attaching to a node grants full code-execution authority over it, as it does
for `observer`, so pickglass limits what it sends and says so on every page.
It pushes a small agent that depends on nothing into the target; the agent
reads process information, ETS table properties and reference-counted binary
lists, and never a mailbox, a process dictionary or a state. The agent unloads
itself and releases every trace flag when the viewer detaches or dies. The
viewer opens no listening port for distribution, reads the cookie from an
owner-only file and never from the command line or environment, and serves its
pages on `127.0.0.1` behind a single-use ticket. Anything that disturbs the
target (a stack probe, a call trace, a scheduling recording, a collection, a
binaries read) is planned first, shows its scope and cost, and runs only after
you confirm. Every decision is recorded in the audit trail.

## Layout

The repository is a workspace of Gleam packages under `packages/`:

- `packages/core` is the pure core: measurements and units, the ownership
  vocabulary, the agent's wire decoders, the capture format, the authority
  policy and every analysis and layout.
- `packages/agent` is the code pushed into the target. It has no dependencies.
- `packages/web` is every page as a Lustre application.
- `packages/pickglass` is the viewer: attach, the collector, the HTTP and
  WebSocket host, captures and the command line.
- `tools/lint` is Loom's house lint, vendored.

## Working in the repo

`make help` lists the commands. `make check` is the full gate: format check,
warning-free build, tests, lint, doc-check, and the agent's import and
end-to-end checks against a peer node. `CLAUDE.md` has the ground rules and
`docs/gleam-style.md` the code style. Each package carries a `CLAUDE.md`
describing its types, traffic and invariants.

## Release

`make release` builds a self-contained OTP release into `build/release/pickglass`
with the Erlang runtime bundled, so it runs on a machine with no Erlang
installed. `make release-smoke` boots it with no `erl` on `PATH`. The copied
runtime is the build machine's, so a release is per-platform. `make dist`
packages the release as a tarball under `dist/`.

## Licence

Apache-2.0; see `LICENSE`.
