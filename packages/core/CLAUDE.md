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
`Bytes`, `Count`, `Reductions`, `Words`, `Nanoseconds` and `Ratio(per:)`.
`Reductions` is a work counter and never converts to time. `Words` is the unit
of an allocation profile's allocated-words column, kept as the VM counted it;
words become bytes only by the word size a capture's runtime facts record, and
a reader without it shows words.

`measure.Measurement` is `Known(Int)`, `Missing(MissingReason)` or
`NotApplicable`. There is no accessor that defaults an absent reading:
`to_option` gives `None`, `render` gives a word, and `sum` counts absent
rows beside the total. `measure.Additivity` (`Additive` or
`Overlapping(why)`) is declared per `Series`; `sum` refuses an overlapping
column, a ratio column, and a column with no known row. `measure.Coverage`
and `Outcome` (`Complete`, `Partial(PartialReason)`, `Refused`, `Errored`)
describe what a collection achieved and why it stopped.

`identity.NodeIncarnation` is the node digest, creation and agent
`BootId`. `identity.OsProcess` pairs a pid with a `StartIdentity` (precise,
coarse or unreadable). `identity.PinToken` is bound to a boot id;
`check_pin` turns it into a `LivePin` or refuses a token from another
incarnation, and `policy` demands a `LivePin` for any command that names a
target.

`owner.Segment`, `Claim` (path, role, `Source`, `Confidence`) and
`owner.join` implement Label over Provider over Registry over Supervision,
keeping disagreeing weaker claims as dissent. `owner.group_by` returns a
`Grouping` whose `unknown` group is a field, so it exists even when empty.

`capture` is the `pickglass.capture/1` NDJSON format: a `Record(p)` variant
per kind (the profile payload `p` is a type parameter the analysis modules
supply), `encode_record`, the total `decode_line`, and an incremental
`Reader`. A file with no footer reads as `Partial(NoFooter)`; an unknown
schema major is refused; unknown record kinds are kept as `UnknownRecord`
and counted. The footer's `Digest` is a slot the I/O side fills; core
computes no hash. `codec` holds the JSON codecs for the leaf types the
records share.

`provenance.Provenance` is the header's origin block, and
`provenance.comparability` compares two of them field by field (`Same`,
`DiffersExpected`, `DiffersBlocking`). A blocking field withholds any
direction of change; a cadence mismatch withholds only rates and deltas.

`profile.Profile` is opaque: samples (leaf-first frames, one value per
`ValueType`, owner labels) over a function table, validated by
`profile.new`. Analyses take a `profile.Column`, a handle minted by the
profile, so a value index cannot be out of range. `profile/codec` is the
JSON payload of a capture's `profile` record (`encode`, total `decoder`).
`Source` decides what may be drawn: counters and allocation counts have no
stacks, so flame, graph and stack exports refuse them with `NoCallStacks`.
Totals sum absolute values and, when a sample carries `profile.base_label`,
only those samples (pprof's `-diff_base` percentages).

`analysis/transform` applies a chain of `Step`s, each classed
`SampleFilter` (focus, ignore, show_from, tagfocus, tagignore: totals
change), `StackRewrite` (hide, show: totals change only by emptied samples)
or `DisplayPrune` (collected into `Display`), and reports totals and
`MatchedNothing` per step. Patterns are `analysis/pattern`, a regex subset
(no groups or classes) because core has no regexp dependency.
`analysis/graph` is pprof's trimmed call graph (node fraction 0.005, edge
fraction 0.001, node count 80, residual and redundant edges, entropy
order); nodelets and inline frames are not modelled. `analysis/diff.merge`
negates and merges a base into a candidate; `analysis/top` and
`analysis/peek` are the Top table and Peek.

`layout/dag` is a deterministic layered layout of a `Graph` (cycle
breaking, longest-path layers, barycentre sweeps, and a least-squares
placement of each layer that keeps its order and gaps, so width stays
bounded; edge-routing nodes take `edge_gap`, not `node_gap`).
`layout/flame` builds the merged stack tree, folds boxes under a minimum
width into their parent, caps the box count, and reports omitted boxes
(drawn plus omitted equals the tree's size); icicle only changes `row`.
`export` and `export/{collapsed,speedscope,chrome_trace,text}` return an
`Export` with text and a loss list. `export/text` is the terminal summary: the
top functions with flat and cumulative shares and an indented call tree.
`policy.ProbeSpec` carries `rate_hz`; `sampling_rate_hz` is the rate the agent
will run once its ceiling is shared between the targets. `policy.CallMemory` is
a counters probe that also counts allocated words: it needs modules (at most
8), at most 8 pinned targets and at most a minute, and is `Counting`.
`wire.FunctionMemory` is an allocation row with the calls and call time of the
same read, and `wire.CounterMemory` carries `wire.MemoryTotals` (functions
read, functions unread, words summed over every one read) beside the rows.
`capture.ProbeCost.counters` is `Some(capture.CounterFacts)` for an allocation
probe: the window asked for, the processes traced, and the called, read, unread
and invalidated functions, so a function missing from the profile is not read
as one that allocated nothing.

`profile/activity` splits stack samples by the process status the agent
reports: `profile_from_stacks` keeps it as the `pickglass::status` label, an
`Inclusion` (`OnSchedulerOnly` or `IncludeWaiting`) restricts a profile, and
`split` counts running or runnable, waiting and unstated samples (a sample with
no status is kept, never called idle). `trace_codec` writes and reads a call
tree or events probe's result as JSON, and `capture.Events` carries it in an
optional `traced` field beside the generic millisecond fields. `export/chrome_trace`
has `events` and `calls` for the two probes' timelines, and `export/text`
writes nanosecond columns as times. `policy` holds the agent's limits for call
trees (four processes, ten seconds, eight modules) and the trace budgets.

`wire` holds the agent's reply decoders and the request encoders. It grows
additively: the original `Request` and the first-release records keep their
shapes, new replies are new `Reply` variants, and the requests added later
(`wire.ExtendedRequest`, encoded by `encode_extended_request`) are a type of
their own, so the viewer's exhaustive matches keep compiling. The agent's
`CLAUDE.md` lists every request and reply shape.

`readings` holds the capture's three memory-reading records and their JSON:
`OwnersDetail` (the initial calls and per-owner ETS an `owners_detail` reply
adds to a census, with the ETS pass's totals), `EtsListing` (an `ets_tables`
reply) and `BinariesReading` (a `binaries` reply). They are the `owners_detail`,
`ets_tables` and `binaries` kinds of `capture.Record`, each with the viewer's
wall-clock `at_ms`; a capture written before they existed has none and reads as
it always did.

`policy.Command` is the closed set of viewer-to-agent actions.
`required_capabilities` is an exhaustive `case`. `ReadEtsTables` is a direct
passive read the hub makes; `ReadBinaries(token)` is plan-first (a polling read
of a pinned process, costly for one that holds many binaries). `Authorized(a)` is opaque
and only `authorize` and `confirm` build it. Probes and targeted GC go
through `plan` then `confirm` (same principal, unexpired, digest unchanged).
Every gate returns `Audited(a)`: the decision and its `AuditEntry`.

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
  there is no default unit. The same holds for every closed code
  (missing reason, source, scope, probe kind): unknown text is an error.
- A missing reading is never a number: no function turns `Missing` or
  `NotApplicable` into an `Int`, and a samples column with neither a value
  nor a reason at a position is refused by the decoder.
- An `Overlapping` series is never summed, and an owner grouping always
  has an unknown group.
- `Authorized` and `Plan` cannot be forged: both are opaque and only
  `policy` constructs them. A module that tries will not compile.
- A pin token is only live under the boot id that issued it.
- Capture decoders are total; a record of a known kind with the wrong
  shape is an error, never a default-filled record. A plan is single-use
  only if its caller discards it on confirm: core holds no state.
- Tests use `qcheck` (a dev dependency) for round trips and decoder
  totality; generators live in `test/pg_data_gen.gleam`.

## Deep Docs

- `docs/design/plan.md` is the plan of record.
- `docs/design/concept-opus.md` sections 4 and 5 describe the data model
  and the analyses in detail.

`wire.Request` has an `Extended(ExtendedRequest)` variant so the viewer's single `ask` carries the requests added after the first wire release. `ExtendedRequest.AskJoin` and the replies `Joined` and `Left` belong to the shared attach: a viewer joins an agent that is already running instead of pushing one, and a detach that leaves other viewers on the agent is answered `Left` and not `Detached`. `policy.Checkpoint` records a viewer-side checkpoint (Observe) and `SelfMeasure` is plan-first.
