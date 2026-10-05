# Pickglass

Pickglass is a BEAM runtime inspector and performance and trace viewer,
written in nearly pure Gleam, with Lustre server components for the web UI.
It is a sibling of [Loom](https://github.com/Roasbeef/loom) and follows
Loom's Gleam house style. Its first goal is closing
[loom#720](https://github.com/Roasbeef/loom/issues/720).

**Status: working.** The viewer, the pushed agent, the pure core and the web
pages exist and have been driven against a live Loom daemon. `README.md` says
what it does and how to run it, `docs/attach.md` is the operator's guide and
`docs/design/plan.md` is the plan of record that the code is built to; read the
plan before changing a boundary it draws.

## Required reading

Before writing any code, read `docs/gleam-style.md`: code style, idiomatic
Gleam, and a brief language tour. Gleam is a new language for most
contributors, so do not carry habits over from others. Part III (idioms:
error handling, type design, actors, FFI) and Part IV (Pickglass policy:
total decoders, no panics outside tests, FFI confinement, the pure `core`)
are the parts the lint partially enforces.

`docs/weft.md` says which process shapes are weft primitives. `docs/lustre.md`
is the Lustre 5.7.1 server-component guide, copied from Loom's web view; read
it before writing the web package. All three guides are copies that track the
Loom originals, so a rule change is made in Loom first.

## Layout

- `packages/` — the workspace: `core` (pure), `agent` (pushed into the
  target, no dependencies), `web` (the Lustre pages) and `pickglass` (the
  viewer). Each has a `CLAUDE.md`.
- `tools/lint` — Loom's house lint, vendored. Keep local changes to it at
  the minimum; a rule that needs changing is changed in Loom first and
  re-vendored.
- `scripts/` — the gates (`lint.sh`, `doc_check.sh`), the release build and
  the installer (`install.sh`).
- `docs/` — the style guides.

## Literate code

Comments are part of the design, not decoration added after the code. A
reader should be able to follow a module's ownership model, state
transitions and failure behaviour by reading its prose in order. Start every
module with `////` documentation that explains why the boundary exists and
how work moves through it. Document every public type, constructor field,
variant and function with `///`, including an `## Examples` section for
functions.

Write the reasoning the syntax cannot show: the invariant being preserved,
the failure or race which shaped the code, and why this mechanism owns the
responsibility. Do not narrate the next line. Comments are full sentences
ending in a period.

The layout is part of the rule. **A comment has a blank line above it** —
inside a function body, between `case` arms, and between the variants of a
custom type. Lint R10 gates on it, so a welded comment fails the build. A
body does not run more than about eight statements without a break (R11, a
warning). `docs/gleam-style.md` Part II, "Stanzas: how code breathes", has
the two places `gleam format` deletes a blank line and so exempts. Treat
missing explanatory prose as unfinished work when reviewing a change.

## Ground rules

- Design priorities, in order: correctness, robustness, performance,
  capability. Pickglass reads runtime data it did not produce, so a decoder
  that guesses is a bug.
- Gleam >= 1.19.0-rc2, Erlang/OTP >= 29, erlang target. All code passes
  `gleam format --check` and compiles warning-free before commit.
- `core` (when it exists) is pure: no I/O, no `@external` of any target, and
  no `gleam_erlang` or `gleam_otp`, in source or in `gleam.toml`. Lint R6
  gates on it at error level. Two properties rest on it: the analysis stays
  property-testable without spawning processes, and `core` stays
  compilable to the JavaScript target so a browser can decode and analyse a
  trace with the server's own code. Portable means *decide but not act*; the
  collector that reads the live VM is never portable.
- **No naked `Bool`** in a function parameter or a record field. `Bool`
  carries no domain meaning, so `render(document, True)` names nothing at the
  call site. Model the question with a two-variant type named for the
  domain. Return position is outside the rule. Lint R9 counts them;
  `docs/gleam-style.md` Part III, "No naked `Bool`", has the escapes.
- **Custom Erlang FFI is a last resort, kept to the minimum.** A new
  `@external` or `.erl` file is taken only when `gleam_stdlib`,
  `gleam_erlang`, `gleam_otp` or weft cannot express the thing at all, never
  for convenience, and it lives in an `internal/ffi_*.gleam` module with a
  comment saying why no pure alternative exists. A runtime inspector will
  want VM introspection that has no binding; look for the existing binding
  first and say in the module doc what was not found.
- **Process machinery goes through weft.** A deadline-bounded spawn, a phase
  machine written as mutually recursive functions, a timer whose handler
  checks for a stale fire, a list of waiters flushed on a state change, a
  poll-until-deadline loop: each is a weft primitive, and a hand-rolled copy
  is a review finding. `docs/weft.md` says which shape maps to which
  primitive. Weft is the sibling checkout `../weft`; extending it is part of
  the job, not a workaround. `core` never imports it.
- Chain fallible steps with `use` + `result.try`; `case` is for ADT dispatch,
  never for stacking `Result`s, and never buy a shallower shape with a
  catch-all `_ ->`. `bool.guard`'s `return:` and every `unwrap` fallback are
  computed on every call; anything that recurses or allocates belongs in the
  `lazy_*` form.

## Working in the repo

`make help` lists the commands. `make check` is the full gate: format check,
warning-free build, tests, lint and doc-check, and it is exactly what CI
runs. `make fmt` before committing. `make release` builds a self-contained
release into `build/release/pickglass` with the runtime bundled, `make
release-smoke` boots it with no `erl` on `PATH`, and `make dist` packages it
into `dist/`.

`make install` runs both, then copies the release into a fresh directory
under `$(PREFIX)/lib/pickglass`, repoints the `current` link there and writes
the `$(PREFIX)/bin/pickglass` shim (`PREFIX` defaults to `~/.local`). It never
rewrites or prunes an earlier copy, because a running VM loads modules from its
release directory for as long as it lives. Keep that property if you change
`scripts/install.sh`.

**Verify a gate by its own exit code.** Backgrounding
`make check > log; echo $?; tail log` reports `tail`'s status, not `make`'s,
and has produced a confident false "green" in Loom. Run `make check; echo
"exit=$?"` with no pipe, then read the log for failures.

`make lint` gates on R0, R2, R4, R6, R10, R13, R14, R15 and R16 and warns on
the rest; read the warnings. `make doc-check` enforces the `AGENTS.md`
mirror and that every package with source has a `CLAUDE.md`.

`main` is the primary branch. Work happens on short-lived topic branches
named for the work itself (`core/trace-decoder`), never for the tool or agent
that produced it. One fix or feature per branch.

## Per-package docs

Each package with source carries a `CLAUDE.md`: purpose, key types, real
dependency edges, its message traffic with concrete type names, and the
invariants that break things when violated. Read the one for the package you
are about to change. `AGENTS.md` beside it is a byte-identical mirror,
produced by `cp`, never hand-edited; `make doc-check` enforces it. After
changing a package's types, messages or dependencies, refresh its
`CLAUDE.md`, then `cp CLAUDE.md AGENTS.md`.

## Commits

Make incremental, atomic commits that each tell one part of the story.
**Every commit is authored by the repository owner** — the repo-local
`user.name` and `user.email` (Olaoluwa Osuntokun <laolu32@gmail.com>) —
never by a tool or agent identity, and commit messages carry no AI co-author
trailers or tool names. Check `git config user.name` before the first commit
of a session.

Format: `subsystem: imperative summary under 50 chars`, then a body in
natural prose explaining the why more than the what, not bullet-point dumps.
Prefixes: the package name for single-package changes (`core:`), `multi:`
across packages, `docs:`, `build:`, `ci:`, `test:`, `lint:`. Lock files,
generated files and vendored code (`tools/lint`) get their own commits.
