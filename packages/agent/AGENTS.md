# pickglass_agent

## Purpose

The agent pickglass pushes into a running BEAM node. The first viewer loads
these modules with `code:load_binary` over distribution and starts `server` as
one registered process, `pickglass_agent`. Later viewers do not load anything:
they ask the running agent to `join`, so one agent serves up to eight viewers.
The agent is the only code that touches the target's runtime: it owns every
trace session, the pin table, the `scheduler_wall_time` reference and the
census workers, because those die with the process that created them and a
request over distribution runs in a temporary process.

## Key Types

`request.Request` is the closed set of things a viewer may ask, and
`request.decode` the total decoder for it; a `join` is classified apart from it
(`request.Joining`) because it is the one message an unadmitted pid may send.
`viewers.Viewer` is one attached viewer: its link process, boot id, monitor,
node, lease and whether it asked for `scheduler_wall_time`; `viewers` is the
pure table of them and the rules about joining, leases and the shared flag.
`server.State` holds the viewers, the pins, the
counters probes (`counters.Probe`, whose `Running` phase holds the only strong
trace session handle), the stack probes (`server.StackProbe`, a sampler pid and
its monitor), the event probes (`server.TraceProbe`, a tracer pid, its monitor
and, while it runs, the only strong session handle of its kind) and the workers.
Every pin, probe and worker carries an `owner`, the link process of the viewer
that made it, and every lookup by token or probe id also names the requester,
so a viewer finds only its own. `census.Report`, `ets.Report`, `binaries.Report`,
`supervision.Report`, `detail.Detail`, `system.Report`,
`counters.Snapshot`, `stacks.Built`, `calltree.Built` and `activity.Built` are
the bounded results.
`owner.Owner` is `Unknown` or `Owned(path, role)`, decoded from a
`{pickglass_owner, 1, Path, Role}` label with an optional fifth element of
capability binaries; the agent labels every process it starts as
`tool=pickglass`, role `agent`.

Four kinds of process do the work. A **worker** (`server.start_worker`)
computes one read-only reply (census, detail, supervision, system, targeted
collection) under a heap cap and a deadline the tick enforces. A **helper**
(`measure`) is a gen_server that waits for one self-measurement reply and
validates it. A **sampler** (`sampler`) is a gen_server per stack probe that
polls `current_stacktrace` and aggregates in `stacks`. A **tracer**
(`tracer`) is a gen_server per call tree or events probe that owns the events of
one trace session: the VM sends it one message per event, and it folds each
into `calltree` or `activity` as it arrives and keeps none. Each replies to the
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
with `binary_to_existing_atom`. The agent monitors each viewer's link
process and node, and ticks every 250 ms to enforce each viewer's lease and the
probe deadlines. A tracer sends
the agent `{pickglass_trace_finished, ProbeId}` when its probe stops, and the
agent sends it the session's weak handle `{pickglass_trace_session, Weak}`,
`{pickglass_trace_read, ReplyTo, Ref}` and `{pickglass_trace_stop, ReplyTo, Ref}`.

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

**Viewers.** A viewer is known by the process its requests name as `ReplyTo`,
its link process. The first viewer is the one that starts the agent, with
`start({ViewerPid, BootId, LeaseMs, Build})` (`Build` is a digest of the beams
the viewer pushed). Another viewer sends `{<<"join">>, BootId, LeaseMs, Build}`
and gets `{<<"joined">>, Viewers}`, the count the agent serves now. `BootId` is
that viewer's own, and its pin tokens carry it; `LeaseMs` is clamped to 1,000
to 600,000. The join is answered only if `Build` equals the build the agent was
started with. A request from a pid that has not joined is refused
`not_attached`, and a `join` is the only message an unadmitted pid may send.
Errors: `build_mismatch` (the detail is the running build, and nothing is
replaced), `too_many_viewers` (eight are attached), `already_attached`.
- Pins, probes and workers belong to the viewer that made them. A token, probe
  id or `unpin` from another viewer is `stale_pin` or `no_such_probe`, the same
  answers as for something that was never issued.
- The limits that protect the target are counted over the node, not per
  viewer: two probes in all (one stack probe, one call tree probe, one events
  probe), four workers, and the finished-probe bounds. A viewer that finds the
  slot taken gets `probe_limit` or `busy`. A pin table is bounded per viewer
  (64).
- `scheduler` `on` and `off` are per viewer, and the agent holds the one
  `scheduler_wall_time` reference on the node while any viewer wants it: it is
  turned on for the first request and off after the last release. A viewer's
  reply says whether it asked, and it gets readings only if it did.
- A viewer ends by `detach`, by its link process or node dying, or by its
  lease lapsing. Only that viewer's pins, probes, samplers, tracers and workers
  are released. The agent exits, and unloads its modules, when none is left.

**Existing, unchanged.** `{<<"ping">>}` gives `{<<"pong">>, BootId, Node,
OtpRelease, UptimeMs, Pins, Probes}` for the requesting viewer (`BootId` is its
own, `Pins` its pins, and `Probes` counts its running counters probes, stack
probes and call tree and events probes). `{<<"memory">>}` gives `{<<"memory">>,
[{Category, Bytes}], WordSize, ProcessCount, OtpRelease, ErtsVersion,
SchedulersOnline}`. `{<<"pin">>, PidText}` gives `{<<"pinned">>, BootId,
PinId, PidText}`; `{<<"unpin">>, Token}` gives `{<<"unpinned">>, PinId}`.
`{<<"scheduler">>, <<"on"|"off"|"read">>}` gives `{<<"scheduler">>,
<<"collecting"|"not_collecting">>, [{Id, Active, Total}]}`. `{<<"detach">>}`
gives `{<<"detached">>, Reason}` after every session and sampler is gone, when
the detaching viewer was the last, and `{<<"left">>, Remaining}` when other
viewers are still attached and the agent stays.

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

**Owners with initial calls and ETS.** `{<<"owners_detail">>, MaxScanned,
TopK}` runs the owners census and then walks every ETS table, and gives
`{<<"owners_detail">>, Coverage, Rows, Owners, Totals, Ets}`. It is a separate
request so that `owners` keeps its shape and a view pays for the table walk
only when it asks. Each part is the `owners` part with fields appended, so a
reader of `owners` reads the prefix of every tuple unchanged:
- A row has a twelfth field, `InitialCall`: the `proc_lib` `'$initial_call'`
  as `module:function/arity`, or `""` for a process `proc_lib` did not start.
  A supervisor reads `supervisor:my_sup/1`, which is how a view tells it from
  a worker; a `gen_server` reads `my_server:init/1`. It is read with
  `process_info(P, {dictionary, '$initial_call'})`, which looks the one key up
  and copies nothing else, in the same signal as the other census items, so a
  process with a large dictionary costs the same as one with none.
  `proc_lib:initial_call/1` does the same read but also makes an atom for each
  argument of a dummy argument list, so the agent does not use it.
- An owner aggregate has two more fields after `TotalHeapWords`: `EtsTables`
  and `EtsBytes`, the tables owned by the owner's processes and their memory.
  A table is attributed through its owner process's label, so tables of an
  unlabelled process count under the `unknown` owner. When the scan stopped
  early, an owner may hold tables without any scanned process, and its
  `Processes` is then 0.
- `Totals` is unchanged. `Ets` is `{Tables, MemoryBytes, Skipped, Stop}` over
  every table the pass read, listed owner or not, so a remainder row's ETS
  figures are `Ets` minus the listed owners'. `Stop` is `<<"finished"|
  "deadline">>`; `deadline` means the pass ran out of the census's 2 s with
  tables unread and the ETS figures understate. `Skipped` tables were deleted
  before they could be read.
- Errors: `busy`.

**ETS tables.** `{<<"ets_tables">>, TopK}` (1 to 500, clamped) or
`{<<"ets_tables">>}` (100) gives `{<<"ets_tables">>, Coverage, Tables,
Totals}`:
- `Coverage` is `{Total, Counted, Skipped, Stop, ElapsedMs}`. `Total` is the
  length of `ets:all()` when the walk began, `Counted` the tables read and
  `Skipped` the tables deleted between the listing and the read. A table
  deleted mid-walk is counted as skipped and the walk goes on. `Stop` is
  `<<"finished"|"deadline">>`; the walk checks a 2 s deadline every 256
  tables. A table created after the list was built is in none of the counts.
- A table is `{Id, Name, OwnerPid, Owner, Type, Objects, MemoryBytes,
  Protection, Heir}`: `Id` the table identifier's text (`#Ref<...>`), `Name`
  the name of a named table and `""` otherwise, `OwnerPid` and `Heir` pid
  texts (`Heir` `""` for none), `Owner` the decoded label of the owning
  process as everywhere else, `Type` and `Protection` atom names as binaries
  (`set`, `ordered_set`, `bag`, `duplicate_bag`; `public`, `protected`,
  `private`), `Objects` the object count and `MemoryBytes` in bytes. The list
  is the largest `TopK` by memory, largest first.
- `Totals` is `{Tables, Objects, MemoryBytes}` over every table read, listed or
  not.
- Table contents are never read: the walk calls `ets:info/1`, which returns
  the table's properties and no object, so a table with secret contents is
  described without being seen. `info/1` and not `info/2` per property
  because it is one call that is consistent for a table deleted halfway
  through, where seven calls could return a mix of values and `undefined`. The
  owner's label is read only for the listed tables, once per owner.
- The list `ets:all()` builds is in the worker's heap; a node with enough
  tables to pass the 1,000,000-word cap gets `ets_failed`.
- Errors: `busy`, `ets_failed`.

**Binaries of a pinned process.** `{<<"binaries">>, Token, TopK}` (1 to 200,
clamped) gives `{<<"binaries">>, PidText, Distinct, Bytes, References,
Binaries}` with a binary `{Address, Bytes, RefCount}`, largest first:
- It reads `process_info(P, binary)` of the pinned process only, in a worker
  with a 2 s deadline. It is never part of a census. The VM lists one entry per
  reference, and a process often holds one binary through many references, so
  the agent counts each binary once by its address: `Distinct` is the number
  of different binaries, `Bytes` their total size, and `References` how many
  references the process holds to them. Measured on an idle Loom daemon, one
  supervisor held a 121 KB binary through 100 references; summing entries would
  have said 3.9 MB. A sub-binary counts the whole binary's size, so `Bytes` is
  what the process keeps alive and not memory unique to it. `Address` is
  hexadecimal text and identifies the same binary across processes while it
  lives, and `RefCount` is how many references to it exist on the whole node.
  `Distinct` minus the length of the list is how many the list leaves out.
- It is costly for a process that holds many binaries: the target builds a
  tuple per reference and the answer is copied into the worker, so the cost
  grows with the count and is paid by the target as well. The count is not known
  before the list exists, so the budget has two parts. A process with more than
  50,000 references is refused with `too_many_binaries` after the list arrives,
  and a process with so many that receiving the list passes the worker's
  1,000,000-word heap cap (between 80,000 and 100,000 references, measured with
  70-byte binaries) has its worker killed, which the agent also reports as
  `too_many_binaries`. No partial figure is ever returned for a process over
  the budget.
- Errors: `stale_pin`, `busy`, `target_gone`, `deadline`, `too_many_binaries`.

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
Rows, Read, Unread, Words}`. Each row is `{Module, Function, Arity, Words,
Calls, TimeUs}`: the words allocated on the process heap while each called
function ran in the traced processes, with the calls and call time the same
read found (so a viewer need not find the function in the time rows, which are
the 200 largest by time), largest allocator first, at most 200. A traced
function's words exclude those of the traced functions it calls. `Read` and
`Unread` count the called functions that did and did not have a `call_memory`
reading (one the VM no longer answers for, after a module reload, is unread and
not a row), and `Words` sums the readings of every function read, so the rows
can be put against the whole. Read memory before stopping the probe, since a
stop removes it. `ElapsedMs` of `counters` is the time the probe has counted so
far while it runs, and the whole window once it has ended, however long after
it is read. A counters probe takes one of the two probe slots and has no slot of
its own. The 5,000-function cap and the deny list of hot modules apply to the
whole set. A module name ending in `*` is a prefix: the agent lists the loaded modules whose
names start with it (`code:all_loaded()`, compared as bytes, no atom made) and
arms each with `Function` `_`; any other function is `unknown_function`, a bare `*`
and a prefix over 1,000 modules are `pattern_too_broad`, and a prefix no loaded
module starts with is `unknown_module`. The expanded set goes through the deny
list and the function cap as one. A repeated pattern, or one a
wildcard on the same module covers, is dropped before arming. Errors:
`unknown_module`, `unknown_function` (names the node has never seen, never
turned into atoms), `no_match` (any one pattern matching nothing refuses the
set), `pattern_too_broad`, `too_many_functions`, `memory_unavailable`,
`probe_limit`, `stale_pin`.

**Call tree probe.** `{<<"start_calltrace">>, Tokens, Patterns, DurationMs,
MaxEvents, Timeline}` takes 1 to 4 pin tokens, 1 to 8 `{Module, Function}`
patterns resolved and checked exactly as a counters probe's are (existing
atoms only, a trailing `*` prefix over loaded modules, the hot-module deny list, the 5,000-function cap, a pattern that
matches nothing refuses the set), `DurationMs` 100 to 10,000, `MaxEvents` 1 to
200,000 and `Timeline` 0 to 2,000, all clamped, and gives
`{<<"calltrace_started">>, ProbeId, Targets, MatchedFunctions, DurationMs,
MaxEvents, Timeline}` with the values after clamping. `{<<"read_calltrace">>,
ProbeId}` and `{<<"stop_calltrace">>, ProbeId}` give `{<<"calltrace">>,
ProbeId, State, Stop, Meter, Frames, Paths, {Processes, Slices}}`:
- The probe traces `call` and `return_to` with `arity` and
  `monotonic_timestamp`, `local` patterns, on the pinned processes only. It
  uses `return_to` and not `{return_trace}` because a return trace makes a
  tail-recursive function non-tail, so a looping target would grow its stack
  for the whole window, and copies every return value into a message.
  `return_to` copies nothing and leaves tail calls alone. The match
  specification is `[{'_', [], [{message, {caller}}]}]`, which adds the
  caller to each call: the function the call will return to, which for a tail
  call is the caller of the chain.
- The tracer folds events into a call tree as they arrive (`calltree`) and
  keeps no event. Each open frame remembers what it returns to. A call with a
  known caller first ends the frames on top that return to the same function,
  since they tail-called it, then pushes its frame, so a callback from an
  untraced framework, a nested call, a tail call and a state machine of
  mutually tail-calling functions all rebuild correctly. A `return_to` ends the
  frame on top, and also any frames above the named function when it is on the
  stack. The caller is `undefined` at the bottom of a process, and then a call
  to the function already on top is folded into that frame and counted, which
  is how a loop started by `spawn` reads. Directly recursive calls more than
  one level deep share a continuation with the level above and read as two
  levels. Frames open at the stop are closed at the latest timestamp seen.
  Time is traced time: it includes time the process was descheduled and
  excludes everything outside the traced functions.
- `State` is `<<"running"|"finished"|"stopped">>`. `Stop` is
  `<<"running"|"deadline"|"event_budget"|"overrun"|"targets_gone"|"stopped">>`.
  The window ends the probe at its deadline, the event budget at exactly the
  budgeted event, and `overrun` when the tracer's mailbox is longer than
  50,000 messages at a check made every 64 events. The tracer clears the
  targets' flags and destroys the session itself, through the weak handle,
  before it messages the agent.
- `Meter` is `{<<"traced_call_return_to">>, ElapsedMs, Events, MaxEvents,
  DroppedEvents, InFlightAtStop, PeakQueue, QueueLimit, TargetsGone,
  ForcedCloses, DistinctPaths, DroppedCalls, ElidedCalls, Strays,
  DepthLimit}`. `Events` were folded. `DroppedEvents` arrived after the stop
  and were discarded unread, and `InFlightAtStop` were already queued at the
  stop; the first is a little larger. `DroppedCalls` were on a path past the
  5,000-path table, `ElidedCalls` were deeper than `DepthLimit` (64), whose
  time stays in the deepest recorded frame, and `Strays` were events for
  another process or of a bad shape. `Calls` over all paths plus `DroppedCalls`
  plus `ElidedCalls` equals the number of call events folded.
- `Frames` is `[{Module, Function, Arity, {<<"none">>}}]`, the stack probe's
  shape with no location, so one reader serves both. `Paths` is `[{Calls,
  InclusiveNs, ExclusiveNs, [FrameIndex]}]`, largest inclusive time first, each
  path leaf first. Exclusive times over all paths sum to the traced time.
- `Processes` are the targets' pid texts in request order, and `Slices` are
  `{ProcessIndex, FrameIndex, StartNs, DurationNs, Depth}` for the first
  frames to close, at most `Timeline`, with `StartNs` counted from the
  tracer's start.
- Errors: those of `start_counter_set` (`unknown_module`, `unknown_function`,
  `no_match`, `pattern_too_broad`, `too_many_functions`), and `stale_pin`,
  `agent_process` (a target is one of the agent's own processes),
  `target_gone`, `probe_limit` (a call tree probe is already running, or two
  probes run in all), `no_such_probe`, `start_failed`.
- A module reloaded during the window drops its patterns from the session
  silently. The probe does not detect it; the module's events stop.

**Scheduling and garbage collection probe.** `{<<"start_events">>, Tokens,
DurationMs, MaxEvents, MaxSlices, LongGcMs, LongScheduleMs}` takes 1 to 8 pin
tokens, `DurationMs` 100 to 60,000, `MaxEvents` 1 to 200,000, `MaxSlices` 0 to
5,000 and two thresholds 0 to 10,000, where 0 is off, all clamped, and gives
`{<<"events_started">>, ProbeId, Targets, DurationMs, MaxEvents, MaxSlices,
LongGcMs, LongScheduleMs}`. `{<<"read_events">>, ProbeId}` and
`{<<"stop_events">>, ProbeId}` give `{<<"events">>, ProbeId, State, Stop,
Meter, Processes, Slices, Long}`:
- The probe sets `running` and `garbage_collection` with `monotonic_timestamp`
  on the pinned processes. A nonzero threshold also sets `trace:system/3`
  `long_gc` or `long_schedule` on the probe's session, which reports slow
  collections and timeslices of any process on the node and exists on OTP 28
  and later. On an older release a probe that sets one is refused with
  `thresholds_unavailable` and nothing is armed.
- `State` and `Stop` are as for the call tree probe, and the window, the
  event budget (scheduling and collection events, not threshold events) and
  the mailbox check are the same.
- `Meter` is `{<<"traced_running_gc">>, ElapsedMs, Events, MaxEvents,
  DroppedEvents, InFlightAtStop, PeakQueue, QueueLimit, TargetsGone,
  UnpairedEvents, DroppedSlices, LongEventsSeen, Strays, LongGcMs,
  LongScheduleMs}`. `UnpairedEvents` had no start or end to pair with, such as
  an `out` of a run that began before the probe, and are never turned into a
  slice. `DroppedSlices` were past `MaxSlices`. `LongEventsSeen` counts every
  threshold event, including those past the 200 kept in `Long`.
- `Processes` is `[{PidText, Runs, RunNs, MinorGcs, MajorGcs, GcNs}]` in
  request order. `RunNs` is time on a scheduler, which is the closest the BEAM
  comes to per-process CPU time and includes any time the operating system
  took the scheduler thread away. `Slices` is `[{ProcessIndex, Kind, StartNs,
  DurationNs}]` for the first runs and collections to close, `Kind` one of
  `<<"run"|"gc_minor"|"gc_major">>`. Runs and collections still open at the
  stop are closed at the latest timestamp seen.
- `Long` is `[{<<"long_gc">>, PidText, DurationMs, HeapWords}` or
  `{<<"long_schedule">>, PidText, DurationMs, Function}]` where `Function`
  is `module:function/arity` or `""`. Events about the agent and its tracers
  are dropped.
- Errors: `stale_pin`, `agent_process`, `target_gone`, `probe_limit` (an
  events probe is already running, or two probes run in all),
  `thresholds_unavailable`, `no_such_probe`, `start_failed`.

**Tracers and backpressure.** A process tracer has no backpressure: the VM
queues every event whatever the mailbox holds, and destroying the session
does not recall the events already queued. A tracer therefore folds instead of
storing, runs at high priority with its mailbox off its heap (so a backlog
does not enlarge each collection and spiral), and stops the probe itself when
its mailbox passes the limit. A flooded probe reports `overrun`, with the
backlog it left in `InFlightAtStop` and `DroppedEvents`. Measured with four
targets in a tight call loop, a call tree probe stops in about ten
milliseconds with the mailbox near 50,000, having folded 20,000 to 30,000 events
and dropped 60,000 to 70,000.

## Invariants

- Imports stay inside `pickglass_agent@*`, `erlang`, `trace`, `code`, `maps`,
  `gen_server` and `rpc` (plus the plan's other OTP modules). `make
  agent-imports` checks the compiled beams. `pickglass_agent@@main` is the
  compiler's entry module, is never pushed, and is skipped.
- The strong trace session handle is held only in `server.State`. It is never
  sent, returned or logged. A tracer holds the weak handle, which cannot delay
  the session's destruction and is enough to clear flags and destroy the
  session.
- The agent process never sends a signal that waits on a target
  (`process_info`, `garbage_collect`): those run in workers, helpers or
  samplers that have deadlines. A target that does not answer therefore
  cannot stall the lease or teardown.
- Every worker, helper, sampler and tracer is monitored by the agent, killed by
  `shut_down`. A sampler or a tracer monitors the agent and ends with it, and a
  helper ends at its own budget (five seconds at most), so a viewer killed
  mid-probe leaves no process. A tracer that dies leaves its session's patterns
  running, so the agent destroys the session on the tracer's `DOWN`.
- An event probe is bounded three ways and always says which bound stopped
  it: a window, an event budget and a mailbox limit. A tracer past its window
  by more than a second is killed by the agent's tick with its session. At most
  one call tree probe and one events probe run at once, and both count toward
  the two-probe limit. A probe never traces the agent's own processes.
- Every exit path of one viewer calls `release`: detach, link DOWN, `nodedown`
  and lease expiry. `release` touches nothing another viewer owns, and the
  agent stops when it leaves none. The decision is made in the agent's own
  mailbox order with the count it holds, so a `join` handled before the last
  `detach` keeps the agent and its modules, and one handled after it gets no
  answer from an agent that is stopping; the viewer then waits for the
  janitor and pushes a fresh agent. `terminate` after a crash calls
  `shut_down` for every viewer. A kill signal skips both and the VM destroys
  the sessions because the agent was their sole holder.
- Nothing the agent owns on the node is counted per request: the
  `scheduler_wall_time` reference is one per process, so the agent switches it
  on the first viewer's request and off the last viewer's release
  (`viewers.Switch`), never once per viewer. Every probe has its own trace
  session, so viewers share no session.
- Joining never loads code. A viewer of another build is refused, because a
  second push would reload the modules under a live agent and a purge kills
  the processes running the old code.
- The janitor calls no other agent module while it runs, because it purges
  them. It purges its own module last, which ends it.
- Calls that can raise on outside input go through `ffi_safe.call`.
- ETS and binaries reads are bounded by what the target holds, not by the
  agent: the table walk by its deadline and the worker's heap cap, the binaries
  read by its count budget and the same cap. Neither runs in the census,
  `owners` or `supervision`.
- `make agent-e2e` pushes the beams into a peer and checks teardown after a
  killed link, a detach and `kill -9` of the viewer, with counters, stack, call
  tree and events probes running, and drives each event probe to its window, its
  budget and, with flooding targets, to `overrun`. It also attaches several
  viewers to one agent and checks that each sees only its own pins and probes,
  that one viewer's detach, `kill -9` or lease expiry leaves the others
  running, that a build mismatch, the cap and a non-viewer are refused, that a
  join and the last detach are decided in mailbox order, and that after the
  last viewer leaves nothing remains.

## Deep Docs

`docs/design/plan.md` ("The agent has no dependencies", "The wire is Erlang
terms") and `docs/research/research-beam-runtime-apis.md` (trace sessions).
