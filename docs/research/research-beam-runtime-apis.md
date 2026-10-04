# pickglass: raw BEAM runtime facilities, costs and safety

Research input for pickglass (generic BEAM inspector in Gleam/Lustre) and loom issue #720.
Target releases: OTP 28 and 29.

## 0. How to read this

Every claim carries one of three tags.

- **[doc]** stated in the OTP documentation. Read from the documentation chunks and man pages installed with OTP 29.0.5 (`code:get_doc/1`), which match the pages under https://www.erlang.org/doc/. Where a URL is cited, it follows the site layout for that module; the text was verified locally, not fetched.
- **[measured]** observed in an experiment I ran. Scripts are in `scratchpad/beam-api-experiments/` (`t1`..`t19`, `gl/`).
- **[inferred]** my reasoning from the above, not tested.

Machines.

- **Darwin**: MacBook (model Mac16,6), 16 cores, macOS 15.5 (Darwin 24.5), Homebrew OTP 29.0.5 (erts-17.0.5, JIT, built with dtrace support, `emu_type=opt`), 16 schedulers, 16 dirty CPU, 10 dirty IO.
- **Linux**: Docker Desktop VM (kernel 6.12, aarch64), images `erlang:28` (erts-16.4.0.6) and `erlang:29.0.5`, run with `--network none`, 16 vCPUs. This is not bare metal; Linux numbers are for API behavior, not absolute cost.
- **Gleam**: local `gleam 1.19.0-rc2` and docker `ghcr.io/gleam-lang/gleam:v1.18.1-erlang`.
- OTP 27 was not available locally. Its column in the matrix is **[doc]** only.

Corrections to premises in the brief.

1. Process labels are not OTP 28. `proc_lib:set_label/1` and `get_label/1` are OTP 27.0; the `{label, L}` item of `process_info/2` is OTP 27.2 [doc].
2. Per-session system monitoring (`trace:system/3`, which includes `long_message_queue`) is OTP 28.0. On 27 only the node-global `erlang:system_monitor/2` exists, and it has exactly one owner [doc, measured].
3. `erlang:processes_iterator/0` and `processes_next/1` are OTP 28.0 [doc].

## 1. Trace sessions (`trace` module, kernel)

### API [doc, OTP 27.0 unless noted]

Docs: https://www.erlang.org/doc/apps/kernel/trace.html

```
trace:session_create(Name :: atom(), Tracer :: pid() | port() | {module(), term()}, Opts :: []) -> session()
trace:session_destroy(session()) -> boolean()
trace:session_info(all | pid() | port() | new | new_processes | new_ports | MFA | on_load | send | 'receive') -> [weak_ref()] | undefined
trace:process(S, Pid | all | existing | new, How :: boolean(), [Flag]) -> non_neg_integer()
trace:port(S, Port | all | existing | new, boolean(), [Flag]) -> integer()
trace:function(S, {M,F,A} | on_load | send | 'receive', MatchSpec | boolean() | restart | pause, [Flag]) -> non_neg_integer()
trace:send(S, ...), trace:recv(S, ...)
trace:info(S, PidPortFuncEvent, Item) -> term()
trace:delivered(S, Tracee | all) -> reference()
trace:system(S, Event, Value) -> ok          %% OTP 28.0
```

`trace:function` flags include `global | local | meta | call_count | call_time | call_memory`. Process flags include `call | send | 'receive' | procs | garbage_collection | running | return_to | silent | timestamp | monotonic_timestamp | set_on_spawn ...`. `{tracer, T}` and `{meta, T}` options are not allowed; the tracer is always the session tracer.

### Isolation [measured, t1]

- Two sessions (`sa` with `[call, send]`, `sb` with `[call]`) on the same pid and the same function each received their own `call` message. Each had independent flags.
- The legacy default session (`erlang:trace/3`, `dbg`, `fprof`, `eprof`, `cprof`) appears in `session_info/1` as `{legacy, default}` and coexists with named sessions. A pid can be traced by both.
- Destroying `sa` removed only its flags; `sb` and `legacy` stayed. Second `session_destroy(SA)` with a strong handle returns `false`.

So a pickglass session does not clobber a user's `dbg`, and the reverse holds as long as the user's tool uses the legacy session. Risk remains from legacy tools that wipe the legacy session only: `fprof` states it "erase[s] all previous tracing in the node" [doc, tools fprof]. That clears the legacy session, not ours.

### Ownership and cleanup semantics [measured, t1, t13, t14]

The strong handle `{Ref, {Name, Id}}` holds the session alive. The weak handle `{Name, Id}` does not.

| Event | Result |
|---|---|
| Process that created the handle (sole holder) is killed | Session destroyed before the `'DOWN'` for that process is delivered. Flags and function patterns removed. |
| Handle copied to another long-lived process (even just returned to a caller) | Session survives creator death. It dies only when the last holder process is garbage collected or exits. |
| Caller only fetched the handle once (`tprof:get_session/1`), then dropped it | Handle stays in that caller's heap until its next GC. After `exit(Server, kill)` the session, its pattern on `work/1` and its listing in `session_info(all)` persisted until I called `erlang:garbage_collect()` in the caller. |
| Tracer process dies, session handle still held | Process trace flags are removed (`flags` becomes `[]`, `tracer` becomes `[]`), but the session and its function patterns stay. `call_count`/`call_time`/`call_memory` and local call tracing keep running until the handle is destroyed. |
| `session_destroy/1` with a weak handle | Works, even while the owner is alive and holds the strong handle. So a weak handle is a destroy capability. |
| `session_destroy/1` with a weak handle for an already-gone session | Raises `badarg` (`cause badopt`), unlike a strong handle (`false`). |
| Module reload (`code:load_file/1`) of a module with local trace patterns | Patterns for that module are dropped from every session (`session_info({M,F,A})` becomes `[]`). tprof documents this and says accumulated results become wrong [doc]. |

Design consequences for "a probe owns its trace session and releases it on any exit":

1. The strong handle must live only in the probe process. Never send it, return it from a call, or log it. A single copy delays cleanup until that process's next GC, which for an idle process may be never. Hand out weak handles for display.
2. The probe process must be the tracer, or must monitor the tracer. Otherwise a dead tracer leaves function patterns (and their counters) running with no one to read them.
3. On every normal exit path (completion, cancel, deadline) call `session_destroy/1` explicitly. Process death is the backstop, not the mechanism.
4. A separate janitor holding only the weak handle is possible (destroy on `'DOWN'`), but the VM already destroys at owner death before `'DOWN'` is delivered when rule 1 holds, so the janitor adds nothing and must tolerate `badarg`.
5. Hot code reload silently removes local patterns. A deadline-bound probe should re-read `trace:info(S, MFA, traced)` at collection time and label the result incomplete if it is `false`.

### Delivery and backpressure [measured, t2, t3, t15]

Process or port tracers receive plain messages. There is no backpressure and no drop policy [doc: only a tracer module can discard; see below].

- Local call trace on a hot function (2,000,000 calls) with a tracer that sleeps 1 ms per 1000 messages: tracee finished in 645-810 ms; tracer mailbox reached about 1.7M messages and 320-368 MB of heap. Untraced the same loop takes 3 ms (JIT), so the ratio is meaningless; the absolute per-event cost is about 300-400 ns on this machine.
- After `session_destroy/1`, messages already sent stay in the tracer mailbox (1.61M of 1.66M remained). Destroying stops new events; it does not recall queued ones.
- `max_heap_size` with `kill => true` on the tracer did not stop growth in my test, because the tracer never ran a GC (a process only checks the limit at GC). I do not recommend relying on it as a bound. [measured; mechanism inferred]
- A self-limiting tracer (counts events, calls `session_destroy` at 10,000) stopped the flood; 553 more events were already in flight (544 on the OTP 28 Linux run). Overshoot is bounded by how fast the tracer is scheduled, not by a constant.
- Counting-only measurement does not send messages at all. `call_count`, `call_time`, `call_memory` keep counters inside the VM and trace nothing to the mailbox. With `silent` plus `call` flag, tprof uses exactly this [doc, tprof.erl]. Overhead on the same 2M-call loop: `call_count` 124 ms, `call_time` 227 ms, `call_memory` 163 ms (62, 113, 82 ns per call). [measured]
- A trace port as tracer works with sessions. `dbg:trace_port(file, {File, wrap, ".trc", 1000000, 3})()` gave a port; `trace:session_create(S, Port, [])` accepted it. 2M events cost 1099 ms and wrote three 1 MB wrap files (oldest data overwritten). Memory is bounded; evidence is dropped by design. [measured, t15] The `dbg:trace_port(ip, {Port, QueSize})` variant has a documented queue limit [doc, dbg].
- Tracer modules (`{Module, State}`) run in the tracee's context and can drop or aggregate events, but **must be implemented as NIFs** [doc, erl_tracer]. Not available to pure Gleam without C.
- Trace messages are not ordered against other system events. `trace:delivered(S, Tracee)` (or `erlang:trace_delivered/1`) delivers `{trace_delivered, Tracee, Ref}` after all queued trace messages have been delivered [doc].

Bounded-probe recipe that is expressible in pure Gleam plus bindings [inferred from the above]:

- Prefer counters (`call_count`, `call_time`, `call_memory` with `silent`) for "how much" questions. Memory use does not scale with call volume.
- For event streams, a dedicated high-priority tracer process with an event budget that calls `session_destroy` at the limit. Report overshoot as dropped/in-flight, and drain with `trace:delivered`.
- Always give `{M,F,A}` patterns with concrete module and function. A `{'_','_','_'}` pattern covers every loaded function (the tprof documentation example reports 16,728 on its sample node; I did not count it here), while `tprof:set_pattern(Srv, t13, '_', '_')` matched 8 functions in my test module. [doc/measured]

Constraints from `trace:process/4` [doc]: `new`, `existing`, `all` and `set_on_spawn` extend tracing to unnamed processes. Do not expose them as defaults, per #720.

### System events [doc, measured t9, t17]

`trace:system(S, long_gc | long_schedule | large_heap | long_message_queue | busy_port | busy_dist_port, Value)` (OTP 28.0). The session tracer must be a local process. `long_message_queue` takes `{Disable, Enable}` mailbox lengths (OTP 28). The legacy `erlang:system_monitor/2` is node-global and has a single owner; another caller replaces it.

Measured: with a legacy `system_monitor` owner and a `trace:system` session on the same node, both received all 13 `long_gc` events from the same GC burst. Setting `erlang:system_monitor/2` from a second process replaced the first owner. Minimum thresholds exist (`{long_gc, 0}` is raised to a minimum) [doc]. A tracer that does heavy work can itself trigger monitor messages [doc].

### Gleam wrappers

None. gleam_erlang 1.3.0 `process` exports spawn/link/monitor/selectors/timers/register only (full list in section 11). Everything above is an `@external(erlang, "trace", ...)` binding.

## 2. tprof, eprof, fprof, cprof

Docs: https://www.erlang.org/doc/apps/tools/tprof.html, `eprof.html`, `fprof.html`, `cprof.html`.

| Tool | Mechanism | Messages to a tracer | Session | Status |
|---|---|---|---|---|
| `tprof` (OTP 27.0, experimental label in docs) | `trace:function` with `call_count/call_time/call_memory`, `silent` flag | none | own trace session per server | "aims to replace eprof and cprof" [doc] |
| `cprof` | legacy `erlang:trace_pattern` `call_count` | none | legacy default | ~10% slowdown per docs |
| `eprof` | legacy `erlang:trace` with `call`, local | yes | legacy default | slower |
| `fprof` | trace to file; sets call trace on all functions | file | legacy default; erases other legacy tracing | heaviest |

tprof details [doc, tprof.erl, measured t13]:

- Types: `call_count` (default, not per-process), `call_time`, `call_memory` (words allocated on the heap). `call_time` and `call_memory` only count processes that carry the `call` trace flag.
- Ad-hoc `tprof:profile/1..4`: runs the function in a spawned process; `timeout` kills the target with reason `kill`. #720 forbids this for production targets.
- Server-aided: `tprof:start(#{type => T, session => atom()})` starts a gen_server that calls `trace:session_create(Name, self(), [])`, traps exits, and calls `trace:session_destroy` in `terminate/2`. API with an explicit server: `enable_trace/3`, `disable_trace/3`, `set_pattern/4`, `clear_pattern/4`, `collect/1`, `pause/1`, `continue/1`, `restart/1`, `inspect/3`, `format/2`, `stop/1`. `get_session/1` returns the strong handle (see the leak above; do not call it).
- The no-server variants (`tprof:enable_trace(Spec)`, `tprof:collect()`) go to a registered server named `tprof`. When started with another `session` name, use the server-argument forms (my first attempt failed with `noproc` on `gen_server:call(tprof, get_session)`).
- Caveats [doc]: untraced callees' cost is attributed to the nearest traced caller; call count is not per-process; profiling slows the target; reload invalidates results.
- Measured cost: see the per-call numbers in section 1. Server kill test: killed tprof server (owner = tracer) removed process flags immediately and removed patterns once no process held a handle copy.

Recommendation [inferred]: implement pickglass's profile probe directly on `trace:function` counters (one owner process, one session) or wrap tprof's server. Direct use avoids tprof's `get_session` copy hazard and its gen_server callback layer; tprof is simpler to review and already handles `set_on_spawn`, `rootset`, `all_children` expansion. Either way the probe owns the session handle.

No pure-time flame graph comes from `call_time`: it gives per-function totals per process, not a call tree [doc, #720 says the same]. A tree needs `call` plus `return_to` or `return_trace` events (message volume), or sampling (section 6).

## 3. Process inspection

### `erlang:process_info/2` items [doc, measured t4]

Docs: https://www.erlang.org/doc/apps/erts/erlang.html#process_info/2

Cost per call on 100,000 idle processes, one calling process, Darwin OTP 29 (the OTP 28 Linux run is within 10-25% of these):

| Item | ns per process | Notes |
|---|---:|---|
| `parent`, `stack_size`, `registered_name`, `priority`, `message_queue_data`, `reductions`, `status`, `initial_call`, `message_queue_len`, `heap_size` | 35-110 | no target interruption evident |
| `last_calls` | 136 | |
| `garbage_collection` | 399 | small list |
| `memory`, `total_heap_size`, `current_function`, `current_location`, `label`, `links`, `monitors`, `monitored_by`, `dictionary`, `binary`, `garbage_collection_info` | 740-910 | the target is asked to compute it (signal); copy size depends on content |
| `current_stacktrace` | 1017 | |
| `backtrace` | 1587 | returns a binary |
| 8-item bundle `[memory, message_queue_len, reductions, status, current_function, heap_size, stack_size, total_heap_size]` | 1056 total | cost is dominated by the slowest item, not additive |

A census of 100k processes with the 8-item bundle took 106 ms in one process (about 1 us per process). Extrapolating to 1M processes is about 1 s of caller time [inferred, linear]. The census is not an atomic snapshot [doc].

Which items copy [measured on a "fat" process: 200,000 queued messages, 5,000 dictionary keys, 50 refc binaries of 100 KB]:

| Item | Time | Result size |
|---|---:|---|
| `messages` | 8.8 ms | 5.2M words (about 41 MB) copied to the caller heap |
| `dictionary` | 137 us | 40,003 words |
| `backtrace` | 370 us | 11 words (binary) |
| `binary` | 3 us | 303 words (list of `{Id, Size, RefcCount}`) |
| `message_queue_len`, `memory`, `total_heap_size`, `garbage_collection_info`, `current_stacktrace` | 0-415 us | tiny results |

Therefore: `messages`, `dictionary`, `{dictionary, Key}` for large values, `sys:get_state/1` and `sys:get_status/1` copy target-owned data. Ordinary browsing uses only numeric and atom items. `message_queue_len` is O(1).

Other facts:

- `process_info/2` on another process is signal-based and follows signal ordering [doc].
- A process executing a dirty NIF answered `process_info` in 13 us (`status`, `memory`, `message_queue_len`, `reductions`) and `current_stacktrace` in 3 us [measured, t18].
- Under 48 spinning processes on 16 schedulers, `process_info(W, [current_stacktrace, memory])` latency was p50 100 us, p99 1.4 ms, max 77 ms on Darwin; p50 15 us, p99 52 us, max 1.1 ms in the Linux VM [measured, t10]. Collectors need deadlines per request, not per census.
- Result is `undefined` for a dead pid, `[]` for `registered_name` with a single-item call when none exists [doc].

### Enumeration [doc, measured t4]

- `erlang:processes/0`: 2.6-8.2 ms for 101,044 processes (varies with run) and allocates a 101k-element list in the caller.
- `erlang:processes_iterator/0` + `processes_next/1` (OTP 28.0): 3.8-6.7 ms for the same count, no list, "no locking" [doc]. Weaker consistency: a process alive for the whole walk is guaranteed to appear once; others may or may not [doc]. Required behavior for pickglass: use the iterator when available, and chunk the walk so a deadline can stop it.
- `erlang:system_info(process_count)`: 1 us.
- Exiting processes still appear in `processes/0` but fail `is_process_alive/1` [doc].

### Sizes: `erts_debug` [measured, t4]

`erts_debug:flat_size/1` and `erts_debug:size/1` are undocumented ("There is no documentation" in the chunk) but stable and already used by loom tests (`packages/runtime/test/support/internal/ffi_memory.gleam`).

- `flat_size` on a 1M-element list: 1.0 ms (2,000,000 words).
- `size` on the same list: 4.2 s (about 4000 times slower, because it tracks sharing). Do not call `size` on large terms.
- `flat_size` of a 10 MB refc binary: 8 words. It counts the process-heap reference only, not off-heap payload. `flat_size([Big,Big,Big])` for the same shared list counted it three times (6,000,006) while `size` counted 2,000,006. So `flat_size` is the copy cost, not retained bytes, which matches the #720 warning.
- Neither function can be applied to another process's heap. It measures a term the caller already holds, which means it already has been copied to the collector. Use it only on bounded, domain-provided summaries.

### Garbage collection [doc, measured t5]

```
erlang:garbage_collect(Pid, [{type, major | minor}, {async, RequestId}]) -> boolean() | async   %% since OTP 17.0
```

- Default type is major (fullsweep). `minor` is "a hint" and may become major [doc].
- Without `async`, the caller blocks until the target handles it. With `async`, returns `async` immediately (1 us) and sends `{garbage_collect, RequestId, GCResult}` to the caller.
- Measured on a process with 2M live tuples (306.6 MB heap): minor GC 57 ms and total process memory rose to 417.4 MB (live data promoted to a new old heap while the young heap block was still counted); a following major GC took 42 ms and returned it to 306.6 MB. So a "minor" request can increase `memory` transiently and a GC changes the number being measured. Record before and after, with `garbage_collection_info`.
- The target is stopped for the collection duration. Other `process_info` calls answered within 1 us during an async major GC of the same process in my test only because the request was queued; I did not measure the stall seen by the target's own work. [inferred]
- `process_info(P, garbage_collection_info)` returns `heap_size`, `heap_block_size`, `old_heap_size`, `old_heap_block_size`, `mbuf_size`, `recent_size`, `stack_size`, `bin_vheap_size`, `bin_vheap_block_size`, `bin_old_vheap_size`, `bin_old_vheap_block_size` (words) [measured]. Meanings are in `trace:process/4` under `gc_minor_start` [doc]. `garbage_collection` returns `max_heap_size`, `min_bin_vheap_size`, `min_heap_size`, `fullsweep_after`, `minor_gcs`.
- `heap_size` (words) times 8 equalled `memory` (bytes) within 800 bytes for that process (38,323,372 words vs 306,587,752 bytes), so `memory` is dominated by heap block capacity [measured].
- `trace:process` flag `garbage_collection` produces `gc_minor_start/end`, `gc_major_start/end` events per GC [doc]; `trace:system(S, long_gc, Ms)` reports only slow ones (min threshold above 0) [doc].

### Binaries [doc, measured t5]

`process_info(P, binary)` returns `[{BinaryId, ByteSize, RefcCount}]` for refc binaries referenced from that process heap ("can be changed or removed without prior notice") [doc]. Two processes holding the same 1 MB binary reported the same `Id` (`4773117992`), size 1,000,000 and refc 3 (two processes plus my test shell). Per-process sums double count. Dedupe by `BinaryId` across a census to get unique bytes, but the id is an address and is only valid within one census interval [inferred]. `erlang:memory(binary)` is the node total. Binaries of 64 bytes or less are on-heap and absent from this list [doc, erts].

### Process labels (ownership attribution) [doc, measured]

- `proc_lib:set_label(Label)` (OTP 27.0) is exactly `put('$process_label', Label)` in the calling process; it only labels `self()` [source, `proc_lib.erl` lines 853-870]. It does not require the process to have been started with `proc_lib`.
- `proc_lib:get_label(Pid)` handles `self()` and remote pids (via `process_info(Pid, {dictionary, '$process_label'})` in 27.0/27.1). `process_info(Pid, label)` returns `{label, L}` directly in OTP 27.2+ [doc].
- Labels can be any term. Measured: `{sess, 1}` returned through `process_info(P, label)` on OTP 29 and OTP 28. Label read cost on 100k unlabeled processes: 786 ns each; 1000 labeled: 1.0 ms total.
- Labels appear in `proc_lib` crash reports and OTP tooling [doc].
- Gleam notes: loom spawns weft actors as closures, so they have no `$initial_call`/proc_lib entry and their raw `initial_call` is `erlang:apply` [existing census test `assembly_heap_census_test.gleam`, daemon-memory design note]. A label is the only ownership channel that does not depend on spawn shape. A Gleam custom type value labels as an Erlang tuple tagged with the snake-case constructor atom and decodes with `gleam/dynamic/decode`. Label content must be redacted; it is readable through `process_info` by any local code and by any distribution peer.
- Dictionary key `'$process_label'` is visible to `process_info(P, dictionary)`; ordinary browsing must not request the dictionary.
- Other attribution inputs: `registered_name`, `links`, `monitors`, `monitored_by`, `parent` (OTP 25), `group_leader`, `$ancestors`/`$initial_call` (proc_lib), `ets:info(T, owner)`, `erlang:port_info(P, connected)` and `os_pid`. These are evidence, not ownership proof [per #720].

## 4. Memory

### Node-level numbers [doc, measured t6]

- `erlang:memory/0`: 57 us, 9 entries on a fresh node. `total = processes + system`. Direct `malloc` memory, emulator code and thread stacks are not counted [doc]. Components are not gathered atomically [doc].
- `erlang:system_info({allocator, A})`: 35 us per allocator on a fresh node; all 10 `alloc_util` allocators 521 us, producing a 446 KB term (flat). Contents are highly implementation-dependent [doc]. **Side effect**: the second and third value of each size are "maximum since the last call to `system_info({allocator, A})`" [doc]. A second tool calling it resets the interval the first sees.
- `erlang:system_info({allocator_sizes, A})`: 20 us for `binary_alloc`. Same implementation-dependent warning.
- `erlang:system_info(allocated_areas)`: debugging aid, unstable [doc].
- `instrument:carriers/0,1` (OTP 21.0, runtime_tools): 0.9-1.1 ms on a node with about 570 carriers and 690 MB of carriers. Returns `[{Allocator, InPool, TotalSize, UnscannedSize, [{Type, Count, Size}], FreeBlockHistogram}]`. It reports `UnscannedSize` when it had to skip carriers to keep the system responsive. `{error, not_enabled}` if the allocator type is disabled [doc].
- `instrument:allocations/0,1`: 2.1-2.9 ms. By default only binaries and NIF/driver allocations are tagged [doc]. Per-process attribution needs a boot flag: with `+MHatags true` (eheap allocator tags) `allocations(#{flags => [per_process]})` produced 210 pid keys and showed the 5M-element process's `heap` block-size histogram; without it only 2 pid keys appeared and the big process was absent [measured, t7]. Allocator letters: `+MH` is `eheap_alloc`, `+ME` ets, `+MB` binary, `+MS` sl, `+MD` std, `+ML` ll, `+MF` fix, `+MR` driver, `+MT` temp [erts_alloc, https://www.erlang.org/doc/apps/erts/erts_alloc.html]. (I tried `+Meatags` first; the emulator rejects it as a bad `+M` parameter.) Tagging adds per-block overhead and must be decided at daemon start. [doc/measured]
- `recon_alloc` methodology (https://ferd.github.io/recon/recon_alloc.html) [doc]: compare `used` (blocks) against `allocated` (carriers) per allocator, compute fragmentation as `1 - used/allocated`, and read `usage` against `memory(total)`. It is not an approved dependency; the same numbers come from `system_info({allocator, A})` / `instrument:carriers/0`, which pickglass can read directly.

### Why RSS differs from `erlang:memory(total)` [doc + measured]

- `memory(total)` counts allocated blocks. RSS also includes carrier slack (free blocks inside carriers, unreturned carriers, `erts_mmap` super carrier), the executable and shared libraries, JIT code, thread stacks, kernel/NIF/`malloc` memory, and other OS-level mappings [doc].
- Measured on Linux/OTP 29 (t9): VmRSS 74.8 MB at boot while `memory(total)` was 223 MB after allocating; after loading 100k ETS rows, `memory(total)` 223.3 MB and VmRSS 254.9 MB. The gap changed sign between phases, so the two cannot be reconciled with one constant.
- Carrier total (`instrument:carriers`) was 692 MB vs `memory(total)` 646 MB on a node with 5M-element lists and 200 processes of 100k elements (Darwin, t7). Carriers are an upper bound on what the allocator keeps; untouched pages need not be resident.
- A drop in `process_info(P, memory)` after GC does not imply an RSS drop [per #720; consistent with allocator carriers being retained].

### ETS, persistent_term, atoms, literals [doc, measured]

- `ets:info(T, memory)` is in **words** (3,056 bytes for a 10-row table, wordsize 8) [measured]. `ets:info/2` takes a single item, not a list (my first test with a list raised `badarg`) [measured]. Six single-item calls over 8,019 tables took 2.4 ms total, about 50 ns per call. `ets:all/0` is cheap. `ets:info(T, owner)` gives the owner pid, which is an attribution input.
- `persistent_term:info/0` returns `#{count, memory}` (21.2); 25 terms, 32,704 bytes on a fresh node [measured]. Updating a persistent term can trigger a global GC [doc, persistent_term].
- Atoms: `system_info(atom_count)` 11,029 of limit 1,048,576; `memory(atom)` and `atom_used` [measured]. Atoms are never collected. Do not create atoms from untrusted or session-derived strings in the collector (`binary_to_atom`); use `binary_to_existing_atom` or keep names as binaries. [inferred, standard]
- Literal area: `system_info(literal_area)` does not exist (`badarg`). Literal memory shows up as `literal_alloc` in `system_info({allocator, literal_alloc})` and `instrument:carriers` [measured/inferred].

### OS RSS per OS process, portable approach

| Need | Linux | Darwin |
|---|---|---|
| This VM's OS pid | `os:getpid/0` | same |
| Resident set | `file:read_file("/proc/<pid>/status")` (`VmRSS`, `RssAnon`, `RssFile`, `RssShmem`, `VmHWM`), `/proc/<pid>/statm`. `smaps_rollup` has `Rss`, `Pss`, `Pss_Anon`, `Private_Dirty`, `Shared_*`. | `ps -o rss=,vsz= -p PID` (3 ms) |
| Better memory metric | `Pss`/`RssAnon` from `smaps_rollup` | `footprint -p PID` (26 ms; "Physical footprint", includes compressed pages), `vmmap -summary PID` (0.9 s, heavy) |
| Process start identity | `/proc/<pid>/stat` field 22 (starttime in clock ticks since boot), combined with boot id | `ps -o lstart= -p PID` (1-second resolution) [inferred] |
| Children (native helpers) | `erlang:port_info(Port, os_pid)`; process tree via `/proc/<pid>/task/*/children` | `port_info(os_pid)`; `pgrep -P` / `ps -o ppid=` |

Measured (t6, t9, shell): `file:read_file` on `/proc/self/status`, `/proc/self/statm`, `/proc/<pid>/smaps_rollup` works from Erlang on Linux (OTP 28 and 29 images). Reading `/proc` needs no FFI beyond a file-read binding (loom already depends on `simplifile`). On Darwin there is no Erlang-native source for another process's RSS. `os_mon` (below) reports system-wide numbers only. `erlang:port_info(P, os_pid)` returned the OS pid for a `/bin/sleep` child [measured, t12].

`os_mon` `memsup` (https://www.erlang.org/doc/apps/os_mon/memsup.html) [measured on Darwin, OTP 29]: `memsup:get_system_memory_data()` returned `system_total_memory`, `free_memory`, `total_memory`, `available_memory`; `memsup:get_memory_data()` returned `{Total, Allocated, {LargestPid, Bytes}}` system-wide (not the VM's RSS). `cpu_sup:util()` worked. Side effects: starting `os_mon` starts three supervisors/port programs (`memsup`, `cpu_sup`, `disksup`) and logged an `alarm_handler` event for a nearly full disk through the OTP logger. It also starts `sasl`. For a library embedded in a daemon, prefer reading `/proc` and running `ps`/`footprint` through a bounded port, and leave `os_mon` out.

## 5. Scheduler and CPU

Docs: https://www.erlang.org/doc/apps/erts/erlang.html#statistics/1, https://www.erlang.org/doc/apps/runtime_tools/msacc.html, https://www.erlang.org/doc/apps/runtime_tools/scheduler.html

- **`statistics(scheduler_wall_time)`** / `scheduler_wall_time_all` (includes dirty IO): `[{Id, Active, Total}]`, `undefined` while disabled. Enabled with `erlang:system_flag(scheduler_wall_time, true)`. **The flag is reference counted per calling process**: a `true` call increments the caller's counter, `false` decrements it, and the node-global state stays on while any live process has a counter above zero; the counter vanishes when the process dies [doc]. So the collector process that enabled it must stay alive, and tools do not clobber each other. [doc; the second `true` call returned the previous node state `true`, measured t8.] After the last disable, `statistics(scheduler_wall_time)` still returned the last values rather than `undefined` in my run (frozen counters); a collector must track its own enabled state. [measured]
- Active time counts waiting for an internal lock but not busy-wait spinning when extra msacc states exist [doc]. Compute utilization from two samples: `(A1 - A0) / (T1 - T0)` per scheduler. Normal schedulers are ids 1..N, dirty CPU follow, dirty IO are in `_all` only [doc, measured: 42 entries on a 16/16/10 node; ids 17..32 are dirty CPU, 33..42 dirty IO].
- `scheduler:utilization/1,2`, `scheduler:sample/0`, `scheduler:sample_all/0` (OTP 21.0, runtime_tools) turn two samples into percentages. They enable the flag in the calling process.
- Overhead: "do consume some CPU overhead and should not be left turned on unless used" [doc]. On a 16-process compute-bound benchmark (16 workers x 300M iterations, 2.0-2.3 s) I saw no difference outside the 10% run-to-run noise with the flag or msacc on [measured, t16]. Overhead on event-heavy workloads was not measured.
- **`msacc`** (OTP 19.0): `erlang:system_flag(microstate_accounting, true|false|reset)`, `erlang:statistics(microstate_accounting)` (`undefined` while off). This flag is **node-global and not reference counted** [doc]: any caller's `msacc:stop()` or `msacc:start(Ms)` (which stops itself) or `reset` disrupts every user. Counters are cumulative; `reset` clobbers other readers. Collectors should read deltas, never `reset`, and treat `undefined` as "disabled by someone else". Measured: `msacc:start()` returned `false` (previous state), `msacc:stats()` took 158 us for 45 threads, thread types `async, aux, scheduler, dirty_cpu_scheduler, dirty_io_scheduler, poll`.
- States in this build: `aux, check_io, emulator, gc, other, port, sleep` [measured]. Extra states (`alloc, bif, busy_wait, ets, gc_full, nif, send, timers`) exist only in a build configured with `--with-microstate-accounting=extra`; such builds pay overhead even when accounting is off [doc]. The Homebrew build has the standard set; the official Docker images have not been checked for extra states (their `statistics` output was not inspected). [measured for Homebrew; unverified for Docker]
- **Run queues**: `statistics(run_queue_lengths)` / `_all`, `total_run_queue_lengths(_all)`, `active_tasks(_all)` (OTP 20.0). "Gathered ... not atomically"; the single-number `statistics(run_queue)` is atomic but "much more expensive" [doc]. Dirty CPU and dirty IO each have one shared queue appended at the end of the `_all` lists [doc, measured: 18 entries = 16 normal + 1 dirty CPU + 1 dirty IO].
- **Reductions**: `statistics(reductions)` returns `{Total, SinceLastCall}`; exact variant `exact_reductions` costs more [doc]. Reductions are a work counter, not CPU seconds [per #720].
- **"Since last call" scope** [measured, t19]: `reductions` since-last is tracked per calling process (a second process calling in between did not change my delta). `wall_clock` since-last is node-global: a call from another process reset it and my next call got 0. Do not depend on since-last values from `runtime`/`wall_clock`; compute deltas from totals.
- `statistics(runtime)` is VM CPU time summed over threads (`{95,95}` ms at idle), including busy-wait; `statistics(garbage_collection)` returns `{Collections, WordsReclaimed, 0}` [doc, measured].
- **Dirty schedulers**: configured counts from `system_info(dirty_cpu_schedulers | dirty_io_schedulers)`; a process in a dirty NIF still answers `process_info` [measured].
- **`lcnt`** (https://www.erlang.org/doc/apps/tools/lcnt.html): needs an emulator built with lock counting (`-emu_type lcnt`). The Homebrew build has only the `jit` flavor and `opt` type [measured: `-emu_type lcnt` is rejected, listing `-emu_flavor smp` only]. Treat lcnt as unavailable and mark it so; it is a runtime-developer tool for internal ethread locks and needs a separate build [doc].

## 6. Stack sampling and native profiling

### Polling `process_info(P, current_stacktrace)` [measured t10]

- Cost: 92 us per sample on Darwin and 53 us on Linux VM for one target when the target is running, including the Erlang-side loop. The call itself is 1.0 us per process when idle (section 3).
- Depth is bounded by the `backtrace_depth` system flag [doc].
- **The samples are biased toward reduction-heavy code.** Test: one process alternates a reduction-heavy sort (45% of wall time) and a long BIF (`binary:copy` plus `binary:matches`, 55% of wall time). 4,000 `current_stacktrace` samples put 98.4% in the reduction-heavy function and 1.6% in the BIF function (Darwin; 98.4% vs 1.6% also on Linux VM). A signal is handled at a safe point reached through reduction accounting, so time inside long non-yielding built-ins is under-sampled. A flame graph built this way must be labelled "sampled at reduction safe points, not wall time". [measured; mechanism inferred]
- For tail-recursive loops, `current_location` reports the function head after a tail call (Gleam test: `spin_inner/2` was reported at its `fn` line). [measured]

### Tracing-based stack views [doc]

- `trace:process(S, P, true, [call, return_to])` plus `trace:function(S, MFA, [], [local])` reports when execution returns to a function; "together they make it possible to know exactly in which function a process executes at any time" [doc]. Event volume is per call (measured costs in section 1). Only with `local` patterns. Tail calls collapse as documented.
- `running`/`garbage_collection` flags give scheduling and GC timestamps for a pid [doc].

### Linux: perf and JIT [doc, partly measured]

Docs: https://www.erlang.org/doc/apps/erts/erl_cmd.html (`+JPperf`), https://www.erlang.org/doc/apps/erts/beamasm.html

- `+JPperf true|false|dump|map|fp|no_fp` is "when running with the JIT on Linux" and a **boot flag only** [doc]. `map` writes a map file and enables frame pointers (one extra word per stack frame); `dump` writes jitdump for `perf annotate`; `fp` enables frame pointers alone; `+JPperfdirectory` sets where files go (default `/tmp`). `+JPperf` forces `+JMsingle true` [doc].
- Measured on `erlang:29.0.5` Linux: `erl +JPperf map` wrote `/tmp/perf-<ospid>.map` (18,855 lines for a node with the probe project loaded; 998,906 bytes). Lines are `<hexaddr> <hexsize> $<module>:<function>/<arity>`, e.g. `$pickglass_probe:area/1` and `$pickglass@inner@worker_pool:run/1` (module names keep their `@`). Shared fragments are listed as `$global::...`. Map files are updated as modules load. `+JPperf dump` wrote `/tmp/jit-<pid>.dump`.
- `perf` itself is not installed in the images (`which perf` empty), so I did not run `perf record` and cannot confirm end-to-end flame graphs from a shell-out. Requirements for it [inferred]: the `perf` binary, `perf_event_paranoid` low enough or CAP_PERFMON, the same PID namespace, and the target started with `+JPperf map`. A pickglass that shells out to `perf record -g -p PID` can resolve BEAM frames by reading the map file; the Erlang call chain needs frame pointers (`map` or `fp`). Resolving the Erlang function to a Gleam source line needs `dump` mode or a separate mapping (section 9).
- A map file lists every loaded module's functions: its size scales with loaded code. It leaks module and function names to anything that can read the directory (default `/tmp`); put it in an owner-only directory.

### Darwin [measured]

- `+JPperf` is rejected: "`+JPperf is not supported on this platform`" (with `true`, `map`, `fp`).
- `/usr/bin/sample PID 2 -file out.txt` works on the user's own process without sudo (macOS 15.5, SIP enabled) and shows native threads (`erts_sched_1`, `erts_ssig_disp`...) but JIT frames appear as `???  (in <unknown binary>)  [0x...]`. No symbolization of Erlang functions is possible without a map file, and Darwin has none.
- `vmmap`, `footprint`, `spindump` exist. `dtrace` exists but this OTP build has `[dtrace]` in its system version string; use of dtrace needs privileges and is restricted by SIP [inferred, not tested].
- Conclusion: native/OS profiling is Linux-only for BEAM-symbolized output. On Darwin, report "native profiling unavailable for BEAM frames; use `sample` for native-thread structure only".

### `erl_debugger` (OTP 28.0, experimental)

`erl_debugger:stack_frames(Pid, MaxTermSize)` returns frame slot contents of a **suspended** process; it requires the emulator started with `+D`, one registered debugger process per node, and the docs state "highly experimental ... frequent incompatible changes" [doc]. It exposes live variable values. Exclude from pickglass.

## 7. Remote access

### Distribution facts [doc, measured t11]

- Distribution is full mutual trust: a connected node can run any function. Measured: a hidden sidecar executed `erpc:call(T, os, cmd, ["echo remote-exec-as-$(whoami)"])` on the target and got `"remote-exec-as-roasbeef\n"`; it also loaded `crashdump_viewer` through `code:ensure_loaded`. The erl man page says an unsecured distributed node gives an attacker "complete access to the node" [doc, erl.1].
- `-hidden` nodes do not appear in `nodes/0` on the peers; they appear in `nodes(hidden)`. Measured: target `nodes()` was `[]`, `nodes(hidden)` `[sidecar1@Mac]`. `-dist_listen false` implies `-hidden` and stops the node accepting inbound distribution [doc]. A sidecar started with both connected outward to the target and worked.
- `erlang:nodes(connected)` lists hidden peers [measured].
- Transport and restriction knobs [doc]: `-proto_dist inet_tls` (TLS distribution), `-kernel inet_dist_use_interface`, `-setcookie` / `~/.erlang.cookie` (a shared secret, not a per-user authorization), `net_kernel:allow/1` and, new in OTP 28.0, `net_kernel:allowed/0` to read the allow list, and `-start_epmd`/`-erl_epmd_port` for port control. The cookie authenticates the node; it does not authorize individual calls.
- Cost over loopback (50,000-process target, sidecar on the same host): `erpc:call(T, erlang, processes, [])` 3.2 ms for 50,051 pids; 2,000 sequential `erpc:call(T, erlang, process_info, [P, [memory, message_queue_len, reductions]])` averaged 38 us each; a census closure shipped with `erpc:call(T, erlang, apply, [Fun, []])` over all 50k processes ran in 90 ms (the fun is shipped by value and needs `erl_eval`-style availability on the target). [measured]
- Existing `scripts/mem_report.erl` follows this model with `net_kernel:connect_node/1`, noting that `net_adm:ping/1` can fail on macOS due to host name resolution [existing script, citing its own header].
- **`erpc` runs each call in a temporary process on the target that exits when the call returns** [doc, erpc]. A trace session created in such a call is destroyed as soon as the call returns (sole holder dies), per section 1 [inferred from the measured ownership rules]. A probe that must live across calls needs a long-lived owner process on the target, which means target-side code (in-node library) or shipping a closure into `erlang:spawn`. Observation calls (`process_info`, `statistics`, `memory`, `system_info`, `instrument`, `ets:info`) need nothing on the target.
- The target's epmd currently lists other nodes (`observer_web_...`, `loom_daemon_profile_...`) from unrelated work on this machine. I did not connect to them.

### Which model

My judgment [inferred]:

- **In-node library (required)**. It is the only place that can read Loom ownership (labels, domain-owned summaries), own trace sessions with deterministic cleanup, enforce a typed closed protocol, and sit behind the existing web authentication. It needs no distribution at all.
- **Sidecar node (optional second mode)**. Suitable for inspecting a VM that is wedged or is not running the web host, for offloading heavy post-processing (crash dump parsing, capture comparison) from the target, and for diagnosing another node. It must be an explicit owner-only configuration, with `-hidden -dist_listen false` on the sidecar, `inet_tls` or a loopback-only listener on the target, and the cookie in owner-only storage. A sidecar that executes only an allow-listed set of OTP MFAs is still using an authority (the node cookie) that grants arbitrary execution on the target. That authority must not be presented as "read-only" to the UI.
- Do not offer a probe over distribution without target-side code, for the lifetime reason above.

## 8. Crash dumps

Docs: https://www.erlang.org/doc/apps/erts/crash_dump.html, https://www.erlang.org/doc/apps/observer/crashdump_viewer.html

Measured on a 2 MB dump (OTP 29, tiny node, 64,668 lines). It begins with `=erl_crash_dump:0.5` (format version; `crashdump_viewer.erl` declares `-define(max_dump_version,[0,5])`), a date line, `Slogan:`, `System version:`, `Taints:`, `Atoms:`, `Calling Thread:`. Sections are line oriented, header `=tag:id` followed by `Key: value` lines or raw payload. Section counts in that dump: `=fun` 729, `=allocator` 177, `=mod` 106, `=proc`/`=proc_heap`/`=proc_stack` 42 each, `=proc_dictionary` 25, `=ets` 19, `=scheduler` 16, `=hash_table` 9, `=timer`/`=index_table` 4, plus single `=memory`, `=node`, `=port`, `=binary`, `=atoms`, `=loaded_modules`, `=persistent_terms`, `=literals`, `=allocated_areas`, `=end`.

- `crashdump_viewer` is 3,467 lines of Erlang (observer 2.19) with a separate wx GUI layer (`cdv_*`, about 3,100 lines). Its gen_server API (`read_file/1`, `processes/0`, `proc_details/1`, `ets_tables/1`, `memory/0`, `allocator_info/0`, `loaded_modules/0`, `atoms/0`, `expand_binary/1`, ...) loaded and started without wx in my test (`crashdump_viewer:start_link()` returned `{ok, Pid}`) [measured]. Whether `read_file/1` fully works headless on a large dump was not tested.
- Dump size scales with the node; `ERL_CRASH_DUMP`, `ERL_CRASH_DUMP_SECONDS` and `ERL_CRASH_DUMP_BYTES` control location and limits [doc]. Dump files contain process dictionaries, messages and heap terms. They are confidential artifacts.
- Gleam parser feasibility [inferred]: a streaming line reader that builds an offset index (`=tag:id` to byte offset) and parses sections lazily is straightforward and needs no FFI beyond file IO. Process heap and stack terms are printed in a tagged text encoding with pointer references; decoding them is the expensive part (the viewer itself defers it and has `expand_binary/1`). A first version that lists processes/ETS/memory/allocators/modules from key-value sections is small. Parsing GB-sized dumps in-process needs bounded streaming; a sidecar is the better home.
- Dump version `0.5` is recorded in the header; support it explicitly and refuse unknown versions.

## 9. Gleam specifics

### Names [doc/measured, `gl/`]

- Module `pickglass/inner/worker_pool` compiles to Erlang module `pickglass@inner@worker_pool`. A module `pickglass_probe` stays `pickglass_probe`. `gleam run` adds a stub module `pickglass_probe@@main`.
- Function names are unchanged, including private functions (`apply_twice/2` appears as a local function). Anonymous functions are named by the Erlang compiler: `'-run/1-fun-0-'`. Calls are tail calls where Gleam writes them, so a recursive loop shows a single frame (measured: `current_stacktrace` of `spin_inner/2` has one frame).
- Custom type constructors become tagged tuples with the snake-case constructor name: `Circle(radius: Int)` is `{circle, 3}`. Field names do not survive. `-type shape() :: {circle, integer()} | {square, integer()}` in generated code. Bool, Nil, Result and String map to Erlang `true/false`, `nil`, `{ok, V}/{error, E}` and binaries.

### Source mapping [measured, `gl/`, both compilers]

| | Gleam 1.18.1 (docker) | Gleam 1.19.0-rc2 (local) |
|---|---|---|
| Intermediate | generated `.erl` per module in `_gleam_artefacts/`, compiled by `erlc` | `.abstr` abstract-form files; no `.erl` except the `@@main` stub |
| `-file` attributes | one `-file("src/x.gleam", N)` before each function; first attribute is the absolute path of the generated `.erl` | one `{attribute,0,file,{"src/x.gleam",0}}` per module; forms carry Gleam line numbers |
| Line chunk file table | contains the `.gleam` relative path | same |
| Stacktrace line for a `panic` at Gleam line 32 | 35 (drift: generated lines counted from the function's `-file` line) | 32 (exact) |
| `current_location` of a recursive loop | 43 (source loop at 44, function head at 41) | 41 (function head, as expected for a tail call jump) |
| Module `compile_info` | `{options,[debug_info]}` | `{options,[debug_info]}` |

- Gleam also puts the exact line in `panic`, `todo`, `assert`, `let assert` errors (`#{gleam_error => panic, line => 32, file => <<"src/pickglass_probe.gleam">>, module, function}`) [measured, both compilers].
- Both compilers keep the `debug_info` chunk (`beam_lib:chunks(F, [debug_info])`, or `code:get_debug_info/1`, OTP 28.0) and the `Line` chunk. Real loom shipment beams (`gleam@list`, `gleam@otp@actor`, `weft@actor`) have `-file("src/...gleam", N)` attributes per function and the absolute build-host path of the generated `.erl` as the first `-file` attribute [measured, `loom/build/erlang-shipment`]. That absolute path is a build-environment leak; pickglass must display only the `{file, ...}` entries from stack frames or the relative `src/...gleam` paths.
- Rule for pickglass [inferred]: file path is reliable for both compilers (stack frame `{file, "src/....gleam"}` is relative to the package root, so the package name must come from `application:get_application(Module)`). On 1.18 the per-function start line from the `-file` attribute in the `debug_info` forms is exact and the in-function line is not; on 1.19 the frame line is the Gleam line. A mapping service should expose the compiler version it relied on and label line numbers "function-level" on 1.18.
- `+L` (erl flag) suppresses file and line info in exceptions and stack traces [doc, erl.1]. Check the release's emulator flags before promising source navigation.
- A release built from `gleam export erlang-shipment` still carries both chunks (above). Stripping (`beam_lib:strip_files`) would remove them.

### Existing Gleam wrappers vs FFI

Measured by loading the exports of loom's current `build/erlang-shipment`:

- `gleam_erlang` 1.3.0: `gleam/erlang/process` (self, spawn, spawn_unlinked, send, receive, selectors, monitor/demonitor, link/unlink, kill, send_exit, trap_exits, register/unregister, send_after, cancel_timer, call, is_alive, sleep, new_name/named), `node` (self, visible, connect, name), `atom`, `reference`, `application` (`priv_directory`), `port` (empty), `charlist`. **No** `process_info`, `garbage_collect`, `statistics`, `memory`, `system_info`, `system_flag`, `trace`, `erpc`, `ets`.
- `gleam_otp` 1.3.0: `actor`, `static_supervisor`, `factory_supervisor`, `supervision`, `system` (`get_state/1`, `debug_state/1`, `suspend/1`, `resume/1`), `port` (empty).
- `exception` 2.1.1: `rescue/1`, `defer/2`, `on_crash/2`. A total wrapper for calls that raise (trace on a destroyed session, `process_info` on a non-local pid).
- weft (sibling repo) wraps spawn/actor/state-machine/poll/timer/registry; it has no runtime introspection.
- Loom already binds OTP functions directly with `@external(erlang, "erts_debug", "flat_size")` and `@external(erlang, "sys", "get_state")` in test support, with no `.erl` file, and decodes `process_info` output with `gleam/dynamic/decode` (`assembly_heap_census_test.gleam`).

## 10. Capability matrix

Legend. Perturbation: **none** = reads node state without interrupting targets; **low** = interrupts a target for about 1 us per call; **medium** = per-call cost on traced functions or per-process counters; **high** = a message per event or target-visible stop; **intrusive** = copies large target data or stops the target for a collection. FFI: **bind** = typed `@external` to an existing OTP function in `internal/ffi_*.gleam`, no `.erl`; **bind+rescue** = also wrap with `exception.rescue` because it raises on bad input; **OS** = needs `os`/port/file access (loom has `simplifile`, `broker/internal/ffi_port`).

Version columns: OTP 27 is [doc] only; OTP 28 and 29 were run (28 on Linux VM only, 29 on both). `y` = available, `n` = not available, `~` = available with the stated limit.

| Facility | 27 | 28 | 29 | Linux | Darwin | FFI | Perturbation |
|---|---|---|---|---|---|---|---|
| `trace:session_create/destroy/info`, `process`, `function`, `info` | y | y (m) | y (m) | y | y | bind+rescue | process/function-dependent (below) |
| Trace to process tracer, event stream | y | y | y | y | y | bind | high; mailbox unbounded; needs a budget |
| Trace to file/ip port (`dbg:trace_port`) | y | y | y (m) | y | y | bind (+ `dbg`) | high per event; bounded storage |
| Tracer module (`erl_tracer`) | y | y | y | y | y | needs a NIF (C) | low; not available to pure Gleam |
| `call_count` / `call_time` / `call_memory` (via session or tprof) | y | y (m) | y (m) | y | y | bind | medium; 60-110 ns per call, no mailbox |
| `tprof` ad-hoc (`profile/*`) | y | y | y | y | y | bind | medium; kills target on timeout. Not for production |
| `tprof` server-aided | y | y | y (m) | y | y | bind | medium; owns one session |
| `eprof`, `fprof`, `cprof` (legacy session) | y | y | y | y | y | bind | high / very high / medium; `fprof` erases other legacy tracing |
| `trace:system/3` per-session monitors | n | y (m) | y (m) | y | y | bind | low |
| `erlang:system_monitor/2` (global) | y | y | y | y | y | bind | low; single owner, clobbers |
| `process_info/2` cheap items (counters, status, mqlen) | y | y (m) | y (m) | y | y | bind + decode | low (35-110 ns) |
| `process_info/2` memory-class items (`memory`, `current_function`, `links`...) | y | y (m) | y (m) | y | y | bind + decode | low (about 0.9 us) |
| `process_info/2` `messages`, `dictionary` | y | y (m) | y (m) | y | y | bind | intrusive (41 MB copy for 200k msgs) |
| `process_info(P, label)` | `{dictionary,'$process_label'}` only (27.0/27.1); `label` item from 27.2 | y | y | y | y | bind | low |
| `proc_lib:set_label/1` (self only) | y | y | y | y | y | bind | none |
| `erlang:processes/0` | y | y | y | y | y | bind | low-medium; allocates list |
| `processes_iterator/0` + `processes_next/1` | n | y | y | y | y | bind | low; no list |
| `garbage_collect/2` `{type, minor|major}`, `{async, Ref}` | y | y | y (m) | y | y | bind | intrusive (target paused; memory can rise on minor) |
| `erts_debug:flat_size/1` | y | y | y (m) | y | y | bind | caller-side only; do not use `size/1` on big terms |
| `process_info(P, binary)` | y | y | y (m) | y | y | bind + decode | low |
| `erlang:memory/0`, `memory/1` | y | y | y (m) | y | y | bind | none (57 us) |
| `system_info({allocator, A})`, `{allocator_sizes, A}` | y | y | y (m) | y | y | bind | low; **resets "max since last call"** for all callers |
| `instrument:carriers/0,1`, `allocations/0,1` | y | y | y (m) | y | y | bind | low-medium (1-3 ms); reports `UnscannedSize` |
| per-process allocation tags (`+MHatags true`) | y | y | y (m) | y | y | boot flag; bind | adds block overhead; boot-time decision |
| `ets:all/0`, `ets:info(T, Item)` | y | y | y (m) | y | y | bind (single item) | none (about 50 ns per item) |
| `persistent_term:info/0` | y | y | y (m) | y | y | bind | none |
| `statistics(scheduler_wall_time[_all])` | y | y | y (m) | y | y | bind (`system_flag`) | low; ref-counted per process; owner must stay alive |
| `statistics(microstate_accounting)` / `msacc` | y | y | y (m) | y | y | bind (`system_flag`) | low (standard states); node-global flag, not ref-counted |
| msacc extra states (`send`, `nif`, `bif`, `busy_wait`...) | needs `--with-microstate-accounting=extra` build | same | same (Homebrew: absent) | build-dependent | build-dependent | bind | none to medium; costs when off |
| `statistics(run_queue_lengths_all)`, `total_run_queue_lengths_all`, `active_tasks_all` | y | y | y (m) | y | y | bind | none |
| `statistics(reductions | runtime | wall_clock | io | garbage_collection)` | y | y | y (m) | y | y | bind | none; `wall_clock`/`runtime` since-last is node-global |
| `lcnt` | needs lcnt emulator build | same | same (not in Homebrew) | build-dependent | build-dependent | n/a | high; separate emulator |
| `current_stacktrace` polling (sampling) | y | y | y (m) | y | y | bind | low per sample (50-100 us incl. loop); **biased to reduction-heavy code** |
| JIT `perf` map/dump (`+JPperf`) | y (OTP 24+) | y | y (m, map) | y (boot flag) | n (rejected) | OS (spawn `perf`) | medium (frame pointers: one word per frame) |
| `sample`, `footprint`, `vmmap` (native, no BEAM symbols) | n/a | n/a | n/a | n/a | y (m) | OS | low-medium |
| `/proc/<pid>/{status,statm,smaps_rollup}` | n/a | n/a | n/a | y (m) | n | OS (file read) | none |
| `ps -o rss= -p PID` | n/a | n/a | n/a | y | y (m) | OS (port) | none (3 ms) |
| `erlang:ports/0`, `port_info(P, os_pid | memory | queue_size | connected)` | y | y | y (m) | y | y | bind | none |
| `os_mon` (`memsup`, `cpu_sup`, `disksup`) | y | y | y (m, Darwin) | y | y | bind (app start) | side effects (ports, `sasl`, alarms); system-wide only |
| `erpc:call/4`, `multicall` | y | y | y (m) | y | y | bind | per call; temp process on target |
| Hidden node (`-hidden`, `-dist_listen false`) | y | y | y (m) | y | y | boot flags | none; full trust |
| `net_kernel:allowed/0` | n | y | y | y | y | bind | none |
| Crash dump read (own parser) | y | y | y (m, 0.5 format) | y | y | file IO only | none (offline) |
| `crashdump_viewer` headless parser | y | y | y (started in m) | y | y | bind | offline |
| `erl_debugger` (stack slots of a suspended process) | n | y (experimental, needs `+D`) | y | y | y | not recommended | intrusive |
| Gleam source map via `Line`/`debug_info`/`-file` | y | y | y (m) | y | y | `beam_lib` or `code:get_debug_info/1` (28+) bind | none (offline) |

(m) = exercised in my experiments on that version.

## 11. Minimum FFI surface for pickglass

All of these are direct bindings to existing OTP functions with typed Gleam signatures. None requires a new `.erl` file and none needs a NIF. They belong in `internal/ffi_*.gleam` modules, per the loom rule that FFI is a last resort and confined. A bare `@external` cannot catch exceptions, so calls that can raise are wrapped with `exception.rescue` (an existing package; it carries its own `exception_ffi.erl`).

1. **Process census** (`ffi_proc`): `erlang:process_info/2` (item list; decode result with `decode`), `erlang:processes_iterator/0` and `processes_next/1` (OTP 28+; `erlang:processes/0` fallback is unnecessary if 28 is the floor), `erlang:garbage_collect/2`, `erlang:port_info/2`, `erlang:ports/0`, `ets:all/0`, `ets:info/2`, `erts_debug:flat_size/1`.
2. **Self labelling** (`ffi_proc` or a tiny `ffi_label`): `proc_lib:set_label/1` (self only). Reads go through `process_info(P, label)`, so no `get_label` binding is needed on 27.2+.
3. **Node counters** (`ffi_vm`): `erlang:memory/0`, `erlang:system_info/1` (finite list of keys), `erlang:statistics/1` (finite list of keys), `erlang:system_flag/2` for `scheduler_wall_time` only, `os:getpid/0`.
4. **Allocators** (`ffi_alloc`): `erlang:system_info({allocator, A})` and `{allocator_sizes, A}` (keep one reader to avoid resetting "since last call" maxima), `instrument:carriers/1`, `instrument:allocations/1`. The application `runtime_tools` must be in the release; confirm it is bundled (loom already uses `instrument:carriers` from its script).
5. **Trace sessions** (`ffi_trace`): `trace:session_create/3`, `session_destroy/1`, `session_info/1`, `process/4`, `function/4`, `info/3`, `system/3` (OTP 28+), `trace:delivered/2`. The session type is an opaque external type. Wrap `session_destroy/1`, `info/3`, `function/4` in `rescue` (they raise `badarg` on a destroyed session or dead tracee).
6. **tprof** (optional, `ffi_tprof`): `tprof:start/1`, `enable_trace/3`, `set_pattern/4`, `collect/1`, `inspect/3`, `stop/1` if the probe uses tprof's server instead of its own session owner. Never `tprof:profile/*` with `timeout`, and never `tprof:get_session/1`.
7. **msacc** (optional): `erlang:system_flag(microstate_accounting, true|false)` and `erlang:statistics(microstate_accounting)`. Never `reset`. A pickglass that turns it on must record that it did, and treat later `undefined` as "stopped by another party".
8. **OS reads** (`ffi_os`): file read for `/proc/<pid>/status` and `smaps_rollup` (the existing `simplifile` suffices); a bounded port to run `ps`, `footprint`, `perf` with a fixed argument vector and deadline (loom's `broker/internal/ffi_port` and `client/internal/ffi_os` are the precedent; confirm reuse before adding any new Erlang).
9. **Sidecar** (optional): `erpc:call/4`, `net_kernel:connect_node/1` (`gleam/erlang/node.connect` exists), `erlang:nodes/1`.
10. **Offline source mapping** (build or sidecar, not in the daemon): `beam_lib:chunks/2` with `debug_info`, or `code:get_debug_info/1` (OTP 28+); `application:get_application/1`.

Total: about 35 OTP functions, no custom Erlang file, no NIF. Two items can only be done with a custom NIF and are out of scope: tracer modules (`erl_tracer`) and extra msacc states (a different emulator build).

What cannot be done with any of this, for completeness [doc/inferred]:

- A heap retention (dominator) graph. There is no API for it; `process_info(P, binary)` and `flat_size` give references and copy cost only.
- Stack sampling that is unbiased by reductions without `perf`. On Linux with `+JPperf map` it is possible (perf side); on Darwin it is not.
- Reading another process's term state without copying it. `sys:get_state/1` copies the state to the caller and blocks if the target is busy.

## 12. Hazard checklist for the design work

1. The strong trace session handle must stay in one process and never be copied. Stale copies defer cleanup to a GC that may not come. (measured)
2. Tracer death removes process flags but leaves function patterns active until the session is destroyed. The probe owner must be the tracer or must monitor it. (measured)
3. Reload of a traced module drops local patterns for every session. Detect and label results. (measured)
4. Process-tracer mailboxes grow without bound; destroying the session does not recall queued messages. Prefer counters; otherwise a budgeted tracer and `trace:delivered/2`. (measured)
5. `msacc` is global and not reference counted; `system_info({allocator, A})` resets shared "since last call" maxima; `erlang:system_monitor/2` has one owner; `wall_clock` since-last is shared. Anything that depends on these values must say so. (doc, measured)
6. `scheduler_wall_time` stays on only while the enabling process lives. (doc)
7. `erts_debug:size/1` is about 4000 times slower than `flat_size/1` on a large list. `flat_size` ignores off-heap binary payload and counts shared subterms per reference. (measured)
8. `process_info(P, messages | dictionary)` and `sys:get_state/1` copy target data. A minor GC can raise `process_info(P, memory)`. (measured)
9. Stack polling is biased toward reduction-heavy code (98% vs 45% true share in the test). Label sampled views as such. (measured)
10. Per-process allocator attribution needs `+MHatags true` at boot; without it `instrument:allocations(#{flags => [per_process]})` has no per-process heap data. (measured)
11. `os_mon` starts ports, `sasl` and may raise alarms. Prefer direct `/proc` and bounded ports. (measured)
12. `erpc` calls run in a temporary process, so a session or timer started inside one dies with it. (doc, inferred)
13. Distribution grants arbitrary execution. A hidden sidecar is not read-only. (measured)
14. Generated code carries an absolute build path in the first `-file` attribute of its `debug_info`. Do not display it. On Gleam 1.18, in-function line numbers drift from the source; on 1.19.0-rc2 they match. (measured)
15. Docs for several internals are explicit that they may change: `process_info` `binary`/`garbage_collection*` items, allocator info, `instrument` ("may differ greatly from one version to another" [doc]), `erlang:statistics(microstate_accounting)` thread and state sets. Decode totally and treat unknown keys as unknown, never as zero.

## 13. Files

- Experiments: `scratchpad/beam-api-experiments/` (`t1.escript` sessions; `t2,t3` flood; `t4` census costs; `t5` GC and binaries; `t6,t7` memory and allocators; `t8` scheduler/msacc; `t9` Linux `/proc` and `trace:system`; `t10` sampling; `t11.sh` distribution; `t12` ports/ETS; `t13` tprof; `t14` weak handles; `t15` trace port; `t16` overhead; `t17` system monitors; `t18` dirty NIF; `t19` since-last; `gl/` Gleam project; `doc.escript` renders OTP doc chunks).
- Relevant existing loom material: `scripts/mem_report.erl`, `scripts/mem_dig.erl`, `docs/design-notes/daemon-memory.md` (process census of a real daemon), `packages/client/test/client/assembly_heap_census_test.gleam` (Gleam `process_info` decoding), `packages/runtime/test/support/internal/ffi_memory.gleam` (direct `@external` to `erts_debug`).
