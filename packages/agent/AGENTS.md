# pickglass_agent

## Purpose

The agent pickglass pushes into a running BEAM node. The viewer loads these
modules with `code:load_binary` over distribution and starts `server` as one
registered process, `pickglass_agent`. The agent is the only code that touches
the target's runtime: it owns every trace session, the pin table, the
`scheduler_wall_time` reference and the census workers, because those die with
the process that created them and a request over distribution runs in a
temporary process.

## Key Types

`request.Request` is the closed set of things the viewer may ask, and
`request.decode` the total decoder for it. `server.State` holds the pins, the
counters probes (`counters.Probe`, whose `Running` phase holds the only strong
trace session handle), the stack probes (`server.StackProbe`, a sampler pid and
its monitor), the workers and the lease. `census.Report`,
`supervision.Report`, `detail.Detail`, `system.Report`,
`counters.Snapshot` and `stacks.Built` are the bounded results.
`owner.Owner` is `Unknown` or `Owned(path, role)`, decoded from a
`{pickglass_owner, 1, Path, Role}` label with an optional fifth element of
capability binaries; the agent labels every process it starts as
`tool=pickglass`, role `agent`.

Three kinds of process do the work. A **worker** (`server.start_worker`)
computes one read-only reply (census, detail, supervision, system, targeted
collection) under a heap cap and a deadline the tick enforces. A **helper**
(`measure`) is a gen_server that waits for one self-measurement reply and
validates it. A **sampler** (`sampler`) is a gen_server per stack probe that
polls `current_stacktrace` and aggregates in `stacks`. Each replies to the
viewer itself, so the agent never copies a result and never blocks on a
target.

## Relationships

No dependencies at all (gleeunit and gleam_stdlib are dev only). Loading any
library into the target would replace the target's own copy of the module, and
purging it would kill the target's processes running it. Everything under
`src/pickglass_agent/` compiles to `pickglass_agent@*` modules. OTP is reached
through `internal/ffi_*.gleam` externals. The viewer (`pickglass`) pushes the
beams and decodes replies with `pickglass_core/wire`.

## Traffic

Requests are `{<<"pg">>, 1, ReplyTo, Ref, {<<"tag">>, ...}}` messages sent to
the registered name; replies are `{<<"pg">>, 1, Ref, {<<"tag">>, ...}}`. The
wire uses binaries, integers, lists, tuples and `true`/`false` only, never an
atom, so the agent creates no atom from input. Names in a probe spec resolve
with `binary_to_existing_atom`. The agent monitors the viewer's link process
and node, and ticks every 250 ms to enforce a lease and probe deadlines.

## Wire requests and replies

Every request is `{<<"pg">>, 1, ReplyTo, Ref, Body}` and every reply is
`{<<"pg">>, 1, Ref, Body}`. A body is a tuple whose first element is a binary
tag. Only binaries, integers, lists, tuples and `true`/`false` cross the
wire. A pin token is `{BootId, PinId}`. "Words" are VM words (multiply by the
`memory` reply's `word_size`); a field named `Bytes` is already bytes. The
decoders for all of these are in `pickglass_core/wire.gleam`: the first
release's requests are `wire.Request`, the ones added since are
`wire.ExtendedRequest` (encoded by `wire.encode_extended_request`), and every
reply is a `wire.Reply` variant. Any request may instead be answered
`{<<"error">>, Code, Detail}`; the codes a request can produce are listed with
it. A worker or helper that dies before answering is a `<request>_failed`
refusal (`census_failed`, `gc_failed`, `measure_failed` and so on), and one
that overruns its deadline is `deadline`. A reply the viewer never receives
(a sampler killed by its heap cap while a read was in flight) is covered by
the viewer's own request timeout, and `ping`'s `probes` count tells it what
is still running.

**Existing, unchanged.** `{<<"ping">>}` gives `{<<"pong">>, BootId, Node,
OtpRelease, UptimeMs, Pins, Probes}` (`Probes` counts running counters probes
and running stack probes). `{<<"memory">>}` gives `{<<"memory">>,
[{Category, Bytes}], WordSize, ProcessCount, OtpRelease, ErtsVersion,
SchedulersOnline}`. `{<<"pin">>, PidText}` gives `{<<"pinned">>, BootId,
PinId, PidText}`; `{<<"unpin">>, Token}` gives `{<<"unpinned">>, PinId}`.
`{<<"scheduler">>, <<"on"|"off"|"read">>}` gives `{<<"scheduler">>,
<<"collecting"|"not_collecting">>, [{Id, Active, Total}]}`. `{<<"detach">>}`
gives `{<<"detached">>, Reason}` after every session and sampler is gone.

**Census.** `{<<"census">>, MaxScanned, TopK}` gives `{<<"census">>,
Coverage, Rows, Owners}`, the shape of the first wire release, which does not
change.
- `Coverage` is `{Scanned, Total, Stop, ElapsedMs}`; `Stop` is
  `<<"finished"|"scan_budget"|"deadline">>`.
- A row is `{PidText, MemoryBytes, TotalHeapWords, HeapWords, StackWords,
  QueueLength, Reductions, Status, CurrentFunction, RegisteredName, Owner}`.
- An owner aggregate is `{Owner, Processes, MemoryBytes, QueueLength,
  Reductions}`. At most 100 are listed, largest memory first, plus the
  `unknown` one when any process is unlabelled.
- `Owner` is `{<<"unknown">>}` or `{<<"owner">>, [{Kind, Id}], Role}`. The
  agent labels its own processes `{pickglass_owner, 1, [{<<"tool">>,
  <<"pickglass">>}], <<"agent">>}`, so its cost appears as that owner.
- Errors: `busy` (four workers already running).

**Owners.** `{<<"owners">>, MaxScanned, TopK}` runs the same census and gives
`{<<"owners">>, Coverage, Rows, Owners, Totals}`: `Coverage` and rows as above,
an owner aggregate with a sixth field, `TotalHeapWords` (the sum of the
owner's `total_heap_size`, every heap fragment its processes hold), and:
- `Totals` over every process the walk scanned, listed or not:
  `{Processes, MemoryBytes, QueueLength, Reductions, TotalHeapWords,
  OwnersTracked, OwnersListed}`. The Owners remainder row is `Totals` minus
  the sum of the listed aggregates, and `OwnersTracked - OwnersListed` is how
  many owners it stands for.
- Reductions deltas between censuses are not computed by the agent. A sum per
  owner falls when a process exits, so a correct rate needs a per-pid
  baseline, which the viewer owns.
- Errors: `busy`.

**Process detail.** `{<<"process_detail">>, Token}` gives
`{<<"process_detail">>, PidText, Sizes, Activity, Gc, Relations, Owner,
Capabilities}`:
- `Sizes` is `{MemoryBytes, TotalHeapBytes, HeapBytes, StackBytes}`.
- `Activity` is `{QueueLength, Reductions, Status, CurrentFunction,
  InitialCall, RegisteredName}`. Function texts are `module:function/arity`
  or `""`.
- `Gc` is `{MinorGcs, FullsweepAfter, MinHeapBytes, MaxHeapBytes,
  HeapBlockBytes, OldHeapBytes, OldHeapBlockBytes, MbufBytes,
  BinVheapBytes}`. `MaxHeapBytes` 0 is the VM's "no limit".
- `Relations` is `{Links, Monitors, MonitoredBy, ParentPidText}`, counts
  and a parent (`""` when the process has none).
- `Capabilities` is the list of binaries in the label's optional fifth
  element, for example `[<<"measure">>]`.
- Never read: `messages`, `dictionary`, `backtrace`, process state.
- Errors: `stale_pin`, `busy`, `target_gone`, `deadline` (2 s).

**Supervision walk.** `{<<"supervision">>, MaxScanned, MaxEdges}` gives
`{<<"supervision">>, Coverage, Edges}`. `Coverage` is `{Scanned, Total, Stop,
ElapsedMs}` with `Stop` one of `<<"finished"|"scan_budget"|"deadline"|
"edge_budget">>`. An edge is `{ChildPidText, ParentPidText, RegisteredName,
InitialCall, Owner}`, from `process_info(P, parent)`. `ParentPidText` is `""`
for a process whose parent is not known. At most 10,000 edges; a walk that
stops early says so in `Stop`. A parent is whoever spawned the process, which
for an OTP child is its supervisor and for any other process may be an
unrelated spawner. Errors: `busy`.

**System.** `{<<"system">>}` gives `{<<"system">>, Facts, Carriers}`.
`Facts` is `{UptimeMs, Creation, EmuFlavor, EmuType, ErtsVersion,
OtpRelease, Schedulers, SchedulersOnline, DirtyCpu, DirtyCpuOnline,
DirtyIo, WordSize}`. `Carriers` is `{<<"unavailable">>, Reason}` (the
`instrument` module or its allocator is missing, never a zero) or
`{<<"carriers">>, Rows}` with a row `{Allocator, InPool, CarrierCount,
TotalBytes, UsedBytes, UnscannedBytes}`; `InPool` is `true`/`false`, and
`UnscannedBytes` is what `instrument:carriers` skipped. Errors: `busy`,
`deadline`.

**Targeted garbage collection (intrusive).** `{<<"gc">>, Token,
DeadlineMs}` (100 to 10,000) gives `{<<"gc">>, <<"intrusive">>, PidText,
Outcome, ElapsedMs, Before, After}`. `Outcome` is `<<"completed"|
"target_gone">>`. `Before` and `After` are `{<<"heap">>, MemoryBytes,
TotalHeapBytes, HeapBytes, HeapBlockBytes, OldHeapBytes, OldHeapBlockBytes,
MbufBytes, StackBytes, BinVheapBytes}` or `{<<"gone">>}`. The collection is a
major `garbage_collect/2` that stops the target while it runs. It is called
synchronously from a worker, not asynchronously from the agent, because the
agent never blocks on a target: the worker's deadline is the request's
deadline. A target that does not get to the collection in time is the
`deadline` refusal, and the before reading is lost with the killed worker.
Errors: `stale_pin`, `busy`, `deadline`, `gc_failed`.

**Self-measure.** `{<<"measure">>, Token, BudgetMs}` (50 to 5,000) gives
`{<<"measure">>, PidText, ElapsedMs, Readings}` with a reading `{Name,
Value, Unit}`, `Unit` one of `<<"words"|"bytes"|"count">>`. The agent sends
the target `{pickglass_measure, BudgetMs, AgentPid, Ref}` and expects
`{pickglass_measure_reply, Ref, [{Name, Value, Unit}]}` back; at most 32
readings of printable ASCII names up to 64 bytes are kept. Only a process
whose label advertises `<<"measure">>` is asked. Errors: `stale_pin`,
`busy`, `not_measurable`, `measure_deadline`, `target_gone`, `bad_reply`.

**Stack sampling probe.** `{<<"start_stacks">>, Tokens, RateHz, DurationMs,
MaxSamples}` (1 to 16 tokens, `RateHz` 1 to 1,000 and cut to `1000 /
targets`, `DurationMs` 100 to 60,000, `MaxSamples` 1 to 200,000) gives
`{<<"stacks_started">>, ProbeId, Targets, RateHz, DurationMs, MaxSamples}`
with the values after clamping. `{<<"read_stacks">>, ProbeId}` and
`{<<"stop_stacks">>, ProbeId}` give `{<<"stacks">>, ProbeId, State, Stop,
Meter, Frames, Stacks}`:
- `State` is `<<"running"|"finished"|"stopped">>`; `Stop` is
  `<<"running"|"deadline"|"sample_budget"|"targets_gone"|"stopped">>`.
- `Meter` is `{Method, RequestedHz, AchievedMilliHz, Rounds, Samples,
  ElapsedMs, DepthLimit, AtDepthLimit, TargetsGone, DroppedSamples,
  DistinctStacks, TruncatedSamples}`. `Method` is
  `<<"polled_current_stacktrace">>`: samples are taken at reduction safe
  points, so time in long BIFs is under-sampled and the result is not wall
  time. `AchievedMilliHz` is rounds per second times 1,000. `DepthLimit` is
  the node's `backtrace_depth`, measured by the agent (capped at 256);
  `AtDepthLimit` counts samples whose stack reached it. `DroppedSamples`
  were not stored because 5,000 distinct stacks were already held;
  `TruncatedSamples` were stored but left out of the reply by its frame
  bound. `Samples` equals the sum of the returned counts plus both.
- `Frames` is `[{Module, Function, Arity, Location}]` with `Location`
  `{<<"none">>}`, `{<<"file">>, File}` or `{<<"at">>, File, Line}`. A
  relative path such as `src/weft/actor.gleam` is kept whole. An absolute
  path, which some dependencies' generated Erlang carries and which names the
  build host's directories, is cut to its last component.
- `Stacks` is `[{Count, Status, [FrameIndex]}]`, largest count first, each
  stack leaf first, `Status` the process status atom as a binary.
- Aggregation happens in the agent. The sampler is its own process, ends
  itself at the deadline or sample budget, and keeps its result until read,
  stopped, or evicted (two finished probes are kept).
- Errors: `stale_pin`, `probe_limit` (two probes running in all, one of
  them a stack probe at most), `no_such_probe`.

**Counters probe.** `{<<"start_counters">>, Module, Function, Targets,
DeadlineMs}` is unchanged. `{<<"start_counter_set">>, Patterns, Targets,
DeadlineMs, Mode}` takes 1 to 8 `{Module, Function}` patterns (`Function`
`<<"_">>` for every function) and `Mode` `<<"time">>` or
`<<"time_and_memory">>`; `time_and_memory` also turns on `call_memory` and is
refused with `memory_unavailable` where the VM lacks it. Both reply
`{<<"counters_started">>, ProbeId, MatchedFunctions, DeadlineMs}` and share
`read_counters` and `stop_counters`, which give `{<<"counters">>, ProbeId,
State, MatchedFunctions, ElapsedMs, {Functions, WithCalls, Invalidated},
Rows}` with rows `{Module, Function, Arity, Calls, TimeUs}`, unchanged from
the first release and merged over all the patterns. Allocation is read apart:
`{<<"read_counter_memory">>, ProbeId}` gives `{<<"counter_memory">>, ProbeId,
State, Memory}`, where `Memory` is `{<<"none">>}` for a probe that did not ask
for `time_and_memory` (not a list of zeros) and otherwise `{<<"words">>,
[{Module, Function, Arity, Words}]}`, the words allocated while each called
function ran in the traced processes, largest first, at most 200. Read memory
before stopping the probe, since a stop removes it. The 5,000-function cap and
the deny list of hot modules apply to the whole set. A repeated pattern, or one a
wildcard on the same module covers, is dropped before arming. Errors:
`unknown_module`, `unknown_function` (names the node has never seen, never
turned into atoms), `no_match` (any one pattern matching nothing refuses the
set), `pattern_too_broad`, `too_many_functions`, `memory_unavailable`,
`probe_limit`, `stale_pin`.

## Invariants

- Imports stay inside `pickglass_agent@*`, `erlang`, `trace`, `code`, `maps`,
  `gen_server` and `rpc` (plus the plan's other OTP modules). `make
  agent-imports` checks the compiled beams. `pickglass_agent@@main` is the
  compiler's entry module, is never pushed, and is skipped.
- The strong trace session handle is held only in `server.State`. It is never
  sent, returned or logged.
- The agent process never sends a signal that waits on a target
  (`process_info`, `garbage_collect`): those run in workers, helpers or
  samplers that have deadlines. A target that does not answer therefore
  cannot stall the lease or teardown.
- Every worker, helper and sampler is monitored by the agent, killed by
  `shut_down`. A sampler monitors the agent and ends with it, and a helper
  ends at its own budget (five seconds at most), so a viewer killed
  mid-probe leaves no process.
- Every exit path calls `shut_down`: detach, viewer link DOWN, `nodedown`,
  lease expiry, and `terminate` after a crash. A kill signal skips it and the
  VM destroys the sessions because the agent was their sole holder.
- The janitor calls no other agent module while it runs, because it purges
  them. It purges its own module last, which ends it.
- Calls that can raise on outside input go through `ffi_safe.call`.
- `make agent-e2e` pushes the beams into a peer and checks teardown after a
  killed link, a detach and `kill -9` of the viewer.

## Deep Docs

`docs/design/plan.md` ("The agent has no dependencies", "The wire is Erlang
terms") and `docs/research/research-beam-runtime-apis.md` (trace sessions).
