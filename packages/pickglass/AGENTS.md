# pickglass

## Purpose

The placeholder package. Pickglass is a BEAM runtime inspector and
performance and trace viewer, but its product design is not settled, so
this package holds only what the build, the self-contained release and the
smoke test need: a version, a one-line banner and a `main` the release
launcher calls. It performs one effect, printing the banner, and has no
dependency beyond `gleam_stdlib`.

The workspace is expected to grow a pure `core`, an impure collector host
and a Lustre web package beside this one. This package is not their
foundation, and nothing should be added here that one of them will need.

## Key Types

None. `pickglass.version` is the package version as a constant, `pickglass.
banner()` renders `pickglass <version>`, and `pickglass.main()` prints it.

## Relationships

Depends on `gleam_stdlib` only (`gleam/io`). Nothing depends on it. The
release scripts export it as an erlang shipment and run its generated entry
module, `pickglass@@main`, which calls `pickglass.main`.

## Traffic

No actors, registers or wire formats. The only output is one line on
standard output.

## Invariants

- `pickglass.version` equals `version` in `gleam.toml`. `make release-smoke`
  reads both and fails when they differ, which is how a release proves it
  reports the version it was built from.
- The package has no `@external` and no `.erl` file. Keep it that way until
  a design needs one, and then put it in `internal/ffi_*.gleam`.

## Deep Docs

`docs/gleam-style.md` for style, `scripts/release.sh` for how the package
becomes a release, and the root `CLAUDE.md` for the ground rules.
