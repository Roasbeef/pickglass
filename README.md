# Pickglass

A runtime inspector and performance and trace viewer for the BEAM, written in
Gleam, with Lustre server components for the web UI.

**Status: pre-design.** The workspace, style rules, lint, doc graph, CI and
the self-contained release plumbing are in place; the product design is not
settled and no product code exists yet. Its first goal is closing
[Roasbeef/loom#720](https://github.com/Roasbeef/loom/issues/720).

## Layout

The repository is a workspace of Gleam packages under `packages/`, as in
Loom. Today there is one placeholder package, `packages/pickglass`. A pure
`core`, an impure collector host and a Lustre web package are expected to
join it once the design lands. `tools/lint` is Loom's house lint, vendored.

## Working in the repo

`make help` lists the commands. `make check` is the full gate: format check,
warning-free build, tests, lint and doc-check. `CLAUDE.md` has the ground
rules and `docs/gleam-style.md` the code style.

## Release

`make release` builds a self-contained OTP release into `build/release/pickglass`
with the Erlang runtime bundled, so it runs on a machine with no Erlang
installed. `make release-smoke` boots it with no `erl` on `PATH`. The copied
runtime is the build machine's, so a release is per-platform. It needs
`gleam`, `rebar3` and `erl` (OTP 29) at build time. `make dist` packages the
release as a tarball under `dist/`.

## Licence

Apache-2.0; see `LICENSE`.
