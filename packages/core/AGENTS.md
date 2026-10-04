# pickglass_core

## Purpose

The pure core of pickglass. Everything that can be decided without touching
a runtime lives here: units and measurements, identity, the ownership
vocabulary, the decoders for what the agent sends, the capture format, the
authority policy, and every analysis and layout behind the views. It
performs no I/O and holds no `@external`, so the whole state space is
testable without spawning a process and the package compiles to JavaScript
for a future offline viewer. Lint R6 enforces that.

## Key Types

`unit.Unit` is the closed list of units every measurement carries:
`Bytes`, `Count`, `Reductions`, `Nanoseconds` and `Ratio(per:)`.
`Reductions` is a work counter and never converts to time.

## Relationships

Depends on `gleam_stdlib` and `gleam_json`. The viewer (`pickglass`) and the
web views (`pickglass_web`) depend on it. The pushed agent
(`pickglass_agent`) does not: it carries no dependencies at all, and the
viewer decodes its replies with this package's decoders.

## Traffic

None. This package defines wire and capture vocabulary but sends nothing.

## Invariants

- No I/O, no `@external`, no `gleam_erlang` or `gleam_otp`, in source or in
  `gleam.toml` (lint R6).
- A unit name read from a capture either parses exactly or is refused;
  there is no default unit.

## Deep Docs

- `docs/design/plan.md` is the plan of record.
- `docs/design/concept-opus.md` sections 4 and 5 describe the data model
  and the analyses in detail.
