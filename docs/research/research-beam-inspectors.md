# Prior art: BEAM runtime inspectors (for pickglass and loom #720)

Date of study: 2026-10-03. Author: research sub-agent.

## 0. Method, versions and confidence

I cloned and read source for these, at the commits named, and read the OTP 29 sources installed locally under `/opt/homebrew/lib/erlang/lib` (erts-17.0.5, observer-2.19, runtime_tools-2.4, tools-4.2.1, kernel-11.0.3):

| Tool | Version / commit read | Source |
|---|---|---|
| Observer Web | `b958b587dee789836ca330920e70326bf9f5c128` (main, 2026-09-22) | https://github.com/thiagoesteves/observer_web |
| observer_cli | main at clone time, documents 2.0.0 plus an "Unreleased" section | https://github.com/zhongwencool/observer_cli |
| Phoenix LiveDashboard | 0.9.1, `83a0bd1` (2026-09-16) | https://github.com/phoenixframework/phoenix_live_dashboard |
| recon | `cb45e7b` (2026-04-23) | https://github.com/ferd/recon |
| Spectator (Gleam) | 2.1.2, `5445530` (2026-04-21) | https://github.com/JonasGruenwald/spectator |
| wobserver | `7c6186b` (2017-07-27, unmaintained) | https://github.com/shinyscorpion/wobserver |
| erlyberly | `625f9fd` (2019-01-01, unmaintained) | https://github.com/andytill/erlyberly |
| Classic `observer`, `etop`, `msacc`, `lcnt`, `instrument`, `tprof`, `trace`, `dbg` | OTP 29 sources installed locally | https://github.com/erlang/otp |
| Voyager | blog post only, not source | https://swmansion.com/blog/voyager-beam-inspector/ |
| Kino.Process | hexdocs only | https://kino.hexdocs.pm/Kino.Process.html |

Everything stated as a fact below was read in source or docs unless it carries the marker **[inferred]**. I did not run any of these tools, and I did not exercise the Observer Web access-control path against a live server. Where I characterize cost (for example "linear in process count") I derived it from reading the code, not from measurement.

Two corrections to #720's text came out of the source read (details in 1.4):

1. `b958b587` is not v0.2.8. It is two commits after the `v0.2.8` tag (`36e9a74`): `f7c2e0d` and `b958b58`. The files the issue cites are unchanged between the tag and that commit for the lines it links, so the finding stands, but the pinned version should read "main after v0.2.8".
2. The same page that has the unguarded GC handler also has unguarded handlers for `Process.exit(pid, :kill)`, `Port.close`, and a "send message" action that runs `Code.eval_string` on a client-supplied string. The GC handler is the mildest of four.

---

## 1. Observer Web

### 1.1 What it is

A Phoenix LiveView dashboard library, mounted in a host Phoenix router with `observer_dashboard "/observer"`. It is part of the DeployEx project. It uses OTP distribution to reach other nodes and Phoenix PubSub plus ETS for its metrics store. Docs: https://hexdocs.pm/observer_web/ (source guides `guides/overview.md`, `guides/installation.md`).

It requires Phoenix and LiveView in the host. The installation guide states that it "requires your app to be clustered", otherwise only the local node is observable.

### 1.2 Pages and what each one answers

The routes are fixed in `IndexLive.resolve_page/2` ([lib/web/live/index.ex#L102-L126](https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/live/index.ex#L102-L126)). Default page is System. Custom pages can be registered through a `Page` behaviour.

| Page | Shows | Data source (read in source) | Notes |
|---|---|---|---|
| System | Runtime info, VM limits (processes, ports, atoms, ETS) with usage bars, allocator carrier utilization, optional OS data | `:erlang.system_info/1` via RPC (`lib/observer_web/system_info.ex`); OS data via `:os_mon` (`cpu_sup`, `memsup`, `disksup`), opt-in | Refresh options Paused/2s/5s/10s, default 5 s |
| Metrics | Time series of VM memory, process/port memory, run queue, limits, scheduler utilization, LiveView socket counts, Phoenix metrics, across nodes | Per-node pollers emit `:telemetry` events; stored in an ETS table; `Phoenix.PubSub` fans out (`lib/observer_web/telemetry/*`) | Pollers: VM stats 1 s, process/port memory 1 s, LiveView sockets 5 s, scheduler utilization 5 s and off by default. Retention is opt-in and not persisted across restarts. Two modes: standalone, or "hub" where broadcast nodes push to one observer node |
| Applications | Per-application supervision tree drawn as an ECharts tree with processes, ports, links, monitors; per-application summary table; process and port inspector with actions | `:application_controller.get_master`, `:application_master.get_child`, `:supervisor.which_children`, `process_info` via RPC (`lib/observer_web/apps.ex`) | Aggregates sum `process_info` over the tree, capped at 2,000 processes and flagged partial (`apps/aggregator.ex#L16`). Displays `Process.set_label/1` labels. Memory monitor for a selected pid/port polls at 1 s |
| Processes | etop-style ranking by reductions per interval, memory, or message queue; per-process drill-down | `:observer_backend.etop_collect` over RPC (`lib/observer_web/processes.ex`) | See 1.3: it collects every process and truncates afterward |
| Network | inet ports ranked by bytes in/out per interval, endpoints, owning process, NIF-socket entries | port info and `socket` registry via RPC | Default 5 s |
| ETS | ETS and Mnesia table metadata (owner, protection, type, size, memory); optional content preview | `:observer_backend.get_table_list` | Contents off unless `table_content_inspection: true`; at most 50 objects per request; docs state objects are copied from the node before truncation (`lib/observer_web/ets.ex#L8-L22`) |
| Tracing | Live function-call trace for chosen node/module/function with match-spec options (`return_trace`, `exception_trace`, `caller`, process dump) | `:dbg` (`lib/observer_web/tracer/server.ex`) | See 1.3 |
| Profiling | Count, Duration (sum/avg/min/max/distribution), Call Sequence trees, Flame Graph, each as an aggregate report after the session ends | Same `:dbg` session with tool-specific trace flags (`tracer/tool.ex#L37-L58`); flame graph via `:return_to` and local call tracing | Flame graph is call-stack time from traced calls, not sampled stacks; stack depth capped at 100 (`tool/flame_graph.ex#L34`) |
| Logs | Bounded tail of a file-backed `:logger` handler on a node | A pre-parsed `:erl_eval` expression run over RPC that `pread`s at most N bytes | Paths limited to configured handler files |
| Crashdump | Upload or browse (allowlisted dirs) an `erl_crash.dump`; slogan, VM state, every dumped process incl. stacks and message queues | OTP's own `:crashdump_viewer` on the dashboard node | Parses locally only, never fetches from remote nodes |
| JSON API | `/system`, `/processes`, `/ets`, `/apps`, read-only, bounded, for automation | Same collectors | Max limit 1,000 (`lib/web/api.ex#L40-L44`) |

The README also lists LiveView-specific state inspection and a Port inspector with close.

### 1.3 How it collects data and what that costs

Remote access: everything goes through `ObserverWeb.Rpc`, a wrapper over `:rpc.call` with a pluggable adapter (`lib/observer_web/rpc.ex`). Node discovery is `Node.list() ++ [Node.self()]` (`lib/web/pages/tracing/selection.ex#L49`). A browser session therefore causes the dashboard node to make full-trust distribution calls to every observed node. Several collectors run only stdlib or runtime_tools functions on the target, so the target needs no Observer Web code; the Metrics page does need Observer Web on each node (inferred from the telemetry producers living in Observer Web itself, **[inferred]**). A `Version.Server` polls peer nodes every 60 s with a 1 s RPC timeout to warn about version mismatch (`version/server.ex`).

Per-page cadence is a LiveView `Process.send_after` timer with a generation counter so a tick from a cancelled timer chain is ignored (`pages/processes/page.ex#L248-L264`). Closing the page stops the timer and, via a monitor, releases the `scheduler_wall_time` flag.

Specific costs, from source:

- **Processes page is a full census.** `etop_collect` is called with limit `infinity` (`runtime_tools-2.4/src/observer_backend.erl` lines 580-590): it iterates every process on the target, calls `process_info` with eight items, builds a list, and sends the whole list to the dashboard; Observer Web then sorts and takes the top N (`processes.ex#L107-L127`). Truncation happens after full collection. The classic GUI avoids this by using `procs_info`, which sends 10,000-process chunks (`observer_backend.erl` lines 563-575).
- **Side effect on a node-global flag.** If `scheduler_wall_time` is off, `etop_collect` turns it on and a helper process holds it until the collector dies (`observer_backend.erl` lines 595-612). Observer Web documents this in the module doc of `processes.ex`.
- **Application tree uses blocking calls on supervisors.** `:supervisor.which_children/1` (default 5 s timeout) per supervisor, `Rpc.call(..., :infinity)` for `get_master` and `get_child`, and `process_info(pid, :dictionary)` on supervisors to read `$ancestors` (`apps.ex#L50-L140`). A busy supervisor blocks the page's collection.
- **Tracing is all-process.** The tracer calls `:dbg.p(:all, flags)` (`tracer/server.ex#L137`) and applies patterns with `:dbg.tp` or `:dbg.tpl`. The limiting design is: one session at a time (`{:error, :already_started}`, line 60), a message cap (default 5 in `tracer.ex#L10`; UI default 3), a 30 s session timeout (`tracer.ex#L9`), a monitor on the requesting LiveView that calls `:dbg.stop()` on its death (line 76 and the `:DOWN` clause at ~L277), and a filter dropping events from unselected nodes. The tracer GenServer holds aggregation state for profiling tools; each event copies only the raw trace tuple to it. Display sessions exclude the requesting LiveView's own calls to avoid a feedback loop (changelog PR-68). The flame graph deliberately does not use the `running` flag because with `:dbg.p(:all)` it would emit scheduling events for every process (`tool/flame_graph.ex` moduledoc).
- **Cleanup is global.** `:dbg.stop()` clears the node's default `dbg` state, so it would also clear another tool's `dbg` tracing. In OTP 27 and later `dbg` has isolated sessions (`dbg:session_create/1`, whose server monitors the creating process; `runtime_tools-2.4/src/dbg.erl` lines 233-260, marked experimental in the OTP 27 note). Observer Web does not use them. I did not verify whether the default `dbg` in OTP 29 maps onto a trace session internally.
- **Profiling collection is bounded by message count only.** `Collect` accumulates every sample per key in a list (`tool/collect.ex`), so memory is bounded by `max_messages`, not by bytes.
- **Polling of the ETS metrics store** prunes expired entries every minute when a retention period is configured (`telemetry/storage.ex`).

### 1.4 Access-control model, with source evidence

Model: a `Resolver` behaviour with `resolve_user(conn)` and `resolve_access(user)` returning `:all`, `:read_only` or `{:forbidden, path}` ([lib/web/resolver.ex](https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/resolver.ex)). Authentication is the host app's pipeline; the dashboard adds a CSP nonce option and an `on_mount` hook list. The router puts the resolved `access` in the LiveView session (`lib/web/router.ex#L336`).

What I found:

1. **`:read_only` is never consulted by the LiveView pages.** `grep -rn access lib` shows `access` used only in the router (session assignment), the `Authentication.on_mount` hook (halts only on `{:forbidden, _}`), and the JSON API. No page, component, or `.heex` template references it, and the only tests mentioning `:read_only` check that the session contains it (`test/observer_web/web/router_test.exs#L22,#L64`). This matches the issue's source-level finding for mount ([index.ex#L24-L44](https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/live/index.ex#L24-L44)) and event dispatch ([#L96-L98](https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/live/index.ex#L96-L98)).
2. **Four mutating handlers on the Applications page, none guarded** ([lib/web/pages/apps/page.ex](https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/pages/apps/page.ex)):
   - GC, `:rpc.call(node, :erlang, :garbage_collect, [pid])`, lines 284-299 (the one #720 cites).
   - "Send message": `Code.eval_string(message)` then `send(pid, term)`, lines 301-312. The string comes from the event payload (`"process-send-message"`).
   - The form-validation handler `"process-message-form-update"` also runs `Code.eval_string` on the payload, "to validate syntax" (lines 372-390). So a client event reaches arbitrary Elixir evaluation on the dashboard node even without selecting the send action.
   - `Port.close` (lines 400-408) and `Process.exit(pid, :kill)` (lines 410-417); these are reached after a confirmation state, but the confirmation handler itself takes the id from the event payload.
3. The target of the actions comes from `current_selected_id` set by a prior selection event, and the kill/close confirmation events carry an `"id"` param directly. The issue's reasoning that process inspection supplies the target holds. **[inferred]**: a forged event could probably supply the id directly for the kill/close path since the handler pattern-matches `%{"id" => id_string}` from the payload. I did not run it.
4. **The contrast inside the same ecosystem:** LiveDashboard guards its kill action server-side: `true = socket.assigns.page.allow_destructive_actions` in the handler itself ([info/process_info_component.ex#L84-L88](https://github.com/phoenixframework/phoenix_live_dashboard/blob/83a0bd1/lib/phoenix/live_dashboard/info/process_info_component.ex#L84-L88)) and renders the button only when the flag is set. That is a per-action server check, but it is a single boolean for the whole dashboard, not a role.
5. The JSON API treats `:all` and `:read_only` identically because every endpoint is read-only (`lib/web/api.ex#L23-L24`). It is the only place in Observer Web where the access value is actually part of an enforcement path, and it enforces only `forbidden`.
6. Other safety knobs that are real and server-side: ETS contents are off by default and opt-in, the Logs page accepts only configured handler files, Crashdump browsing is limited to allowlisted directories with size-capped uploads, and OS data requires `:os_mon` to be started by the host.

Implication for #720: sidecar use of Observer Web in a daemon whose operators have different privileges is unsafe unless the dashboard sits behind a gate that denies all non-owner sessions, because per-role read-only does not exist at the event layer. The fix in a native inspector is as #720 says: each action is a closed typed operation authorized in the handler, with forged-event tests.

### 1.5 UX strengths

- **One ranked table per question.** Processes, Network and ETS pages pair a single sortable ranking with a drill-down panel. The control strip (node selector, count 25/50/100/250, refresh Paused/2/5/10 s) is small and complete.
- **A pause control and an explicit refresh button** on polling pages. Pausing is what lets an operator read a number.
- **Per-application summary table** (process, port count, memory, reductions, queue backlog) on top of the tree, flagged partial when capped.
- **Tracing flow:** pick node, then module, then function, then match-spec, then limits (max messages, timeout) in one form, with the limits visible before starting. Profiling re-uses the same selector and shows an aggregate report instead of a stream.
- **Honest attention banners.** Each page opens with a message about what it costs (for example the Processes page says it uses the same bounded collector as etop; the System page notes that low carrier utilization on a busy allocator is a signal). See `attention_msg/0` in each page.
- **Version-mismatch warning** across nodes.
- **Process labels** (`Process.set_label/1`) used as display names for unregistered processes in Applications, Processes and Profiling (PRs 51, 70).
- **Feature-gating by configuration** with in-page hints when `os_mon`, `crashdump_viewer`, or log handlers are absent.

### 1.6 UX and design weaknesses

- Applications page tree is a graph chart with processes as symbols; at production process counts it is a drawing, not a table. No filter by semantic owner.
- No sample metadata: values are shown without elapsed interval, coverage, or truncation labels, other than the partial flag on the application aggregate and a "results truncated" implicit in top-N.
- Reductions delta is a per-refresh-interval delta and the first sample ranks by cumulative value (noted in `processes.ex` docs); the unit is "reductions" and it is presented next to memory without a CPU caveat.
- Memory view in System shows allocator carrier utilization but no used-vs-capacity category explanation, and does not relate allocators to processes, binaries, ETS or OS RSS.
- No capture, export, or comparison: metrics are an in-memory ETS ring and lost on restart unless a hub is used. No saved profiling reports.
- Profiling output is a single report at session end; no live partial result, no "dropped events" figure, and `max_messages` counts events, not bytes or overhead.
- Control and observation are in the same page and share one authority (1.4).
- Everything keys on pid text; no incarnation or birth identity, so a pid reused or a restarted worker looks like the same entity (code takes `Helpers.string_to_pid` from the event string).

---

## 2. Classic `observer`, `etop`, `observer_cli`

### 2.1 The wx `observer` application

Source: `observer-2.19/src/*.erl` (OTP 29). Tabs are added in `observer_wx.erl` lines 176-215; the first tab (System) is created just before.

| Tab | Shows | Underlying calls |
|---|---|---|
| System | Memory (`erlang:memory`), system/architecture facts, schedulers, limits (process/port/atom/ETS counts vs limits), statistics | `observer_backend:sys_info/0` collects `erlang:memory()`, `system_info` keys, `statistics(run_queue|io|wall_clock)`, and `{allocator_sizes, ...}` for `alloc_util` allocators (`observer_backend.erl` lines 75-125) |
| Load Charts | Scheduler utilization per scheduler, memory, I/O over time | `observer_backend:fetch_stats/2` runs on the target, turning on `scheduler_wall_time` while it runs and sending `{stats, ...}` at the chosen frequency; flag turned off on exit (`observer_backend.erl` lines 540-560; `observer_perf_wx.erl` line 261) |
| Memory Allocators | Per-allocator carrier and block sizes over time | `observer_backend:sys_info/0` again (`observer_alloc_wx.erl` lines 202, 207) |
| Applications | Application and supervision tree view | `appmon_info` (runtime_tools) per selected app (`observer_app_wx.erl`) |
| Processes | etop-like table (pid, name, reductions, memory, message queue, current function) with a process-info window | `observer_backend:procs_info/1` (chunks of 10,000) or `etop_collect/1`; spawned on the target node via `spawn_link(Node, ...)` (`observer_pro_wx.erl` lines 486-566) |
| Ports | Port list and details | `observer_backend:get_port_list/0` |
| Sockets | OTP `socket` registry | `observer_backend:socket_info/0` |
| Table Viewer | ETS and Mnesia tables, contents in a virtual list | `observer_backend:get_table_list/2`; private tables are refused (`observer_tv_wx.erl` lines 153, 193) |
| Trace Overview | Choose processes, ports, trace events and function patterns; collect with `ttb`; show timestamped events | `ttb:tracer/2`, `ttb:p/2`, `ttb:tpl/4` (`observer_trace_wx.erl` lines 375-399, 1018-1040); `ttb:stop(nofetch)` on teardown |

Process-info window: `process_info` item list over RPC, a "state" view that first checks `proc_lib:translate_initial_call/1` and only then calls `sys:get_status(Pid, 200)` "with a small timeout in order not to lag the display" (`observer_procinfo.erl` lines 304-330), plus process dictionary and trace controls.

What it answers well: "what is the VM doing right now?" on a single node, locally or by selecting a remote node (distribution). The Load Charts and Memory Allocators tabs are the best-known OTP charts for scheduler utilization and allocator capacity.

What it cannot answer: ownership beyond the supervision tree, history beyond the open window (charts reset on tab close), comparison across runs. It needs a GUI (wx) and `observer` in the release.

Safety: no safety layer beyond the cookie. The Trace Overview can set `ttb` patterns on all processes. Process window can kill, suspend, send messages (menu items **[inferred]** from the module set, not verified line by line).

Perturbation: `scheduler_wall_time` flag enabled while Load Charts or Processes tab is active; full `etop_collect` per refresh for the Processes tab when the page uses the etop path; `procs_info` chunking is an explicit bounded-work design that the web tools above did not adopt.

Worth stealing: the **process-info `sys:get_status` pre-check plus 200 ms timeout**, the **chunked process collector**, and the **per-tab timer that stops when the tab is inactive** (`not_active` message in `observer_pro_wx.erl` line 268 and `observer_port_wx.erl` line 348).

### 2.2 `etop`

`etop` is a text tool in the observer app that connects as a hidden node. The module doc states it uses the Erlang trace facility by default, so no other tracing is possible on the measured node while it runs unless `tracing=off`; with tracing off, runtime is not measured and the default sort becomes reductions (`observer-2.19/src/etop.erl`, options table in the moduledoc). Options: `node`, `lines` (default 10), `interval` (5 s), `accumulate`, `sort` (runtime, reductions, memory, msg_q). Value for pickglass: the sentence in the docs that names the exclusion conflict is the right kind of disclosure.

### 2.3 `observer_cli`

Source: https://github.com/zhongwencool/observer_cli, docs under `docs/`. The 2.0 line has been redesigned around bounded diagnostics and is the closest existing tool to #720's operating principles. Key facts (all from `docs/explanation/core-concepts.md`, `docs/reference/cli.md`, `docs/reference/tui.md`, `src/observer_cli_snapshot.erl`):

- **Two interfaces over distribution:** a command CLI recommended for runbooks and agents, and a TUI for exploration. Pages in the TUI: Home, Network, Ports, Sockets, System, ETS, Mnesia, App, Doc, Plugin, plus Process detail and Port detail.
- **Controller model:** each CLI command starts a temporary hidden controller with no listening distribution port, connects, reads the target's capability record, dispatches one bounded request, validates the response, stops the controller, and confirms cleanup. A saved context stores a node name and a cookie *source* (env var name or file path), never the cookie value; context directory 0700 and file 0600.
- **Target-side bounded worker:** command probes run in a monitored target worker spawned with `max_heap_size` kill at 8M words (`MAX_HEAP_WORDS`), deadlines, response size (1 MiB) and depth (32) limits, and scan admission budgets: processes 100,000, binary holder scan 20,000, application scan 5,000, supervisor scan 300, ETS/ports/sockets 100,000, Mnesia 10,000 (`observer_cli_snapshot.erl` lines 168-193). "Success is reported only after the worker exits normally."
- **Versioned envelope:** every response has `schema` (`observer_cli.cli/v1`), `command`, `outcome` (`complete`, `partial`, `error`), `data`, `meta`, `issues`; JSON Schema published. Each probe records required/optional, status, reason code, duration, sample count and coverage. Findings are suppressed when required coverage is incomplete; "No findings" means only that named rules found nothing within the reported coverage. Exit codes derive from the envelope.
- **Observer-effect disclosure:** the docs say sampling changes the sample (controller, worker, scans, and scheduler measurement add processes and activity) and that field names use "contaminated-count" wording where appropriate.
- **Identity redaction with within-response aliases:** `pid-1`, `module-2`, and so on; the docs say an alias is not a handle and must not be used to build follow-up selectors.
- **Capability handshake:** `bundle_version` and `protocol_version` checked before dispatch; the CLI refuses to inject code into the target. The TUI can auto-load bytecode into the target (via recon) and the docs list that as a distinct, riskier mode.
- **Process detail views** have their own limits: messages only if queue length is at most 10,000; state via `recon:get_state(Pid, 2500)`; dictionary and stack (30 frames) separately; collected in a worker with a 5 s deadline and a `512 * 1024`-word heap cap; terms above 64 KiB external size or depth 32 are refused with `too_large`. The docs note that a delivered `sys:get_state` request can outlive its caller timeout and that transient copy work can still happen.
- **Trace:** `trace call` requires one exact MFA, one local pid, bounded duration (100 ms to 60 s), bounded events or recon rate, and an explicit `--replace-existing-trace` acknowledgement because setup and cleanup clear node-global tracing state. `trace stop --all` is the emergency cleanup. The docs state that OTP dynamic trace sessions are not directly cleared, and that terminating a fixed-name recon occupant can disable a session using it as tracer.
- **Time-window columns:** Home shows `Reds/s` computed from measured monotonic elapsed time rather than the configured refresh interval; it distinguishes "Refresh" (requested) from "Sample" (actual); window views start "warming up"; it counts `missing` and `reset` processes and treats decreasing reductions as a counter reset.
- **Diagnose:** default takes two samples about 1.5 s apart, warns at 85 percent and goes critical at 95 percent of process, port, atom or ETS limits. `--observe` takes five samples, tracks stable resource identities "so creation, termination, or replacement is not mistaken for growth", and `--deep` adds a binary-holder ranking. `--app APP` adds application-scoped samples and child identity context.

What it does not do: no capture comparison. `grep -i "compare|baseline|before/after"` over its CLI reference and agent-workflow guide finds nothing relevant. Ownership is application and supervisor child identity only. No web UI.

Worth stealing, in order: the envelope with outcome, probe coverage and reason codes; the worker-with-heap-cap collection pattern; scan admission budgets; wording of the observer effect; capability handshake; "refused is not healthy" rule; the explicit consent for node-global trace.

---

## 3. Phoenix LiveDashboard

Source: https://github.com/phoenixframework/phoenix_live_dashboard; guides: https://hexdocs.pm/phoenix_live_dashboard/.

### 3.1 Pages (from `lib/phoenix/live_dashboard/pages/`)

Home, OS Data, Metrics, Request Logger, Applications, Processes, Ports, Sockets, ETS, Memory Allocators, Ecto Stats. Additional pages can be registered through a `PageBuilder` behaviour; `:additional_pages`, `:env_keys`, `:csp_nonce_assign_key`, `:on_mount`, `:metrics_history`, `:request_logger`, `:allow_destructive_actions` are router options (`router.ex`).

- **Home:** Erlang and Elixir versions, system information card, I/O totals, run queue, whitelisted environment variables, atoms/ports/processes usage against limits, memory breakdown (from `:erlang.memory/0`).
- **OS Data:** `:os_mon` cpu, memory (used, buffered, cached, swap) and disk.
- **Metrics:** charts of host-defined `Telemetry.Metrics` (counter, last_value, sum, summary, distribution). Chart kind mapping is in `pages/metrics_page.ex#L117-L121`. Metrics are collected by a telemetry listener only while a page is open unless the host configures `metrics_history: {mod, fun, args}`; the guide `guides/metrics_history.md` shows a circular buffer storing recent events. Refresh interval is a reporter option (default 1 s) and pruning threshold default 1,000 points.
- **Request Logger:** live logs of one browser session's requests, correlated by a cookie or query parameter (`request_logger.ex`).
- **Applications:** list, with a tree for one application (v0.9 added a compact nested list view).
- **Processes, Ports, Sockets, ETS:** searchable, sortable tables with a limit selector; detail modals.
- **Memory Allocators:** carrier and block utilization per allocator (added in 0.8.0).
- **Ecto Stats:** database diagnostics via `ecto_psql_extras` and similar, per repository.

### 3.2 Data collection

All remote access is `:erpc.call(node, SystemInfo, callback, args)`. `SystemInfo.node_capabilities` checks whether LiveDashboard's own module is loaded on the target and, if not, `:code.load_binary` ships it there (`system_info.ex#L17-L38`). That is code injection into a target node by design; it is how a dashboard on one node can observe a node that lacks the package. Processes are listed with `Process.list()` plus `Process.info(pid, keys)` for each, then sorted and truncated (`system_info.ex#L273-L290`): the same census-then-truncate shape as Observer Web.

### 3.3 Safety model

Per-process kill is gated by a router option `allow_destructive_actions` and checked in the handler (see 1.4 item 4). Observation is not otherwise restricted; authentication belongs to the host app's pipeline. ETS content is shown through the ETS info modal (not gated in what I read; **[inferred]**, I did not trace the ETS info component).

### 3.4 UX strengths

- Telemetry-metrics definitions give a **declarative vocabulary** for charts (metric type, unit conversion, tags, reporter options) that a host can extend without UI code.
- Consistent table component with search, sort and a limit control; modals preserve URL state (links to a process or table are shareable).
- Memory and limit bars on the home page are the cheapest "is this node healthy" view.
- Extension API for host pages.

### 3.5 Weaknesses relative to #720

- By default metric history lives in the browser session; reload loses it, which makes before/after use awkward unless the host wires a history store.
- Census-then-truncate processes page; no sample-coverage metadata; reductions diff column is delta since previous page refresh.
- No tracing or profiling.
- Code push to target nodes as a built-in mechanism.

---

## 4. Other tools

### 4.1 recon, recon_alloc, recon_trace

Source: https://github.com/ferd/recon (`src/recon.erl`, `recon_alloc.erl`, `recon_trace.erl`).

**recon** exports `proc_count/2` and `proc_window/3` (rank by attribute absolutely or over a time window), `info/1..4` (grouped `process_info` into meta, signals, location, memory_used, work), `bin_leak/1`, `get_state/2`, `node_stats*`, `scheduler_usage/1`, port inspection, `rpc/*`, and `remote_load`. Note that `bin_leak/1` calls `erlang:garbage_collect(Pid)` on **every process** and ranks by the drop in binary references (`recon.erl` lines 317-335): a global GC pass is the measurement, which #720 forbids as an ordinary sample.

**recon_alloc** reports allocator memory in categories: `used` (block sizes), `allocated` (carrier sizes, "what you want if you're dealing with ulimit and OS-reported values"), `unused` (allocated minus used), `usage` ratio, per-type and per-instance breakdowns, plus `fragmentation/1`, `average_block_sizes/1`, `sbcs_to_mbcs/1`, `cache_hit_rates/0`. It documents that `allocated` should roughly match OS-reported memory, that a large gap suggests C allocation outside Erlang's allocators, and which three allocation sources are not counted (mseg cached segments, super carrier memory, early-startup allocations) (`recon_alloc.erl` lines 161-195). It also has `snapshot/0`, `snapshot_save/1`, `snapshot_load/1` to freeze allocator numbers into a file and analyze offline: the only capture/replay primitive in this study, but it holds one snapshot, not a labeled pair, and has no comparison function. Its own module doc says it helps decide "if there is a problem" but offers little for "what is wrong".

**recon_trace** safety design (`recon_trace.erl`):

- Structure: shell process, a **tracer process** that only counts and forwards, and a separate **formatter process** that does the I/O. The stated reason is that the tracer "can do as little work as possible and never block while building up a large mailbox" (lines 140-146).
- Limits are required: either an absolute count `N` (`count_tracer`) or a rate `{N, Millis}` (`rate_tracer`). The code comment says the rate form is a burst breaker: the event that trips the limit is still forwarded, and a window resets on the first event after it expires. Observer_cli's docs repeat this caveat.
- Cleanup: tracer is `spawn_link`ed to the shell; "killing the shell process" or remote shell disconnect stops tracing. `clear/0` runs `erlang:trace(all, false, [all])` and clears every trace pattern, so every `calls/2,3` first wipes any other tracer's settings (`setup/4` calls `clear()`); two tools cannot coexist.
- Guard against broad patterns: `validate_tspec` raises `dangerous_combo` for module `'_'`, `io`, `lists` or recon_trace itself with a match-anything pattern unless the pid spec is a list of explicit pids; the comment admits it can be bypassed with match specs. Pids of the shell, tracer, formatter and IO server are excluded from tracing.
- Fixed registered names (`recon_trace_tracer`, `recon_trace_formatter`) make it a singleton; it uses the legacy global `erlang:trace/3`, not OTP 27 trace sessions.
- The doc warns plainly that very large limits "negate most of the safe-guarding".
- **[inferred]:** because trace messages go to the tracer process's mailbox with no backpressure, a flood faster than the tracer can drain still queues until the limit trips; the limit bounds events forwarded, not events generated.

### 4.2 Spectator (Gleam)

Source: https://github.com/JonasGruenwald/spectator (package in `spectator/`). The only Gleam inspector found, and the only one built with the same stack as pickglass: Gleam, `mist` for HTTP, `lustre` 5 server components, `gleam_otp`. Run embedded in an app or as a standalone escript or Docker image connected to a target node via distribution.

Facts from source and README:

- Features: sortable process table, user tags, process details, OTP state, **suspend/resume** (`sys:suspend`/`sys:resume`), **kill** (`erlang:exit(Pid, kill)`), ETS list and content, ports, dashboard, switching target node.
- Data collection is one Erlang FFI module, `spectator_ffi.erl`, about 730 lines: `erpc:call` with 1 s timeout and 5 s bulk timeout; for remote nodes it lists `erlang:processes()` then issues one `erpc:send_request(process_info)` per pid in parallel and collects them (`spectator_ffi.erl` lines 125-160). It polls all processes each refresh (default 1,000 ms, `common.gleam#L12`).
- OTP detection avoids sending system messages to non-OTP processes (`proc_lib:translate_initial_call` check, same as observer).
- A **tag manager**: `spectator.tag(pid, "name")` stores a user label in a public ETS table and monitors the pid for cleanup (`spectator_tag_manager.erl`). This is the only explicit semantic-label mechanism in the tools studied, and it is exactly a minimal version of #720's "explicit bounded ownership metadata".
- README disclaimers: it may slow the system (`process_info` on every displayed process); it creates atoms from node names the user types ("possible to exhaust the memory of the BEAM instance"); it has **no access control** and exposes sensitive details. Changelog 2.1.0 removed the option to set the cookie through the web UI.
- Process actions run directly from Lustre `update` (`processes_live.gleam` lines 211-233) with no authorization check.

Takeaways: confirms the stack is viable for an inspector; it also shows the cost of the poll-everything model and of FFI breadth (30 exported functions), which #720's FFI constraint would force into a smaller surface.

### 4.3 Voyager

https://swmansion.com/blog/voyager-beam-inspector/. Desktop app (Tauri plus ElixirKit LiveView, like Livebook) for Erlang, Elixir and Gleam; node dashboard (memory, uptime, I/O, applications), supervision tree with ports and references, connects over plain distribution with optional SSH tunnel, exposes data over MCP for LLM analysis. Blog says early development with fewer features than observer or recon. Source is public but with a non-commercial/small-team license; I did not read the source.

### 4.4 Kino.Process (Livebook)

https://kino.hexdocs.pm/Kino.Process.html. `sup_tree`/`app_tree` draw a supervision hierarchy with solid lines for supervision and dotted lines for links; `seq_trace` renders a sequence diagram of message exchange by instrumenting chosen processes. Notable because it separates supervision edges from link edges in one picture (#720 asks to display supervision and links separately from ownership) and renders message flow as a sequence diagram.

### 4.5 erlyberly and wobserver

- **erlyberly** (JavaFX GUI; last commit 2019): tracing debugger. Shows all loaded modules; double-click a function to trace it for any process; shows args, results, exceptions, incomplete calls highlighted; **reapplies traces when modules are reloaded and when the node restarts**; experimental `seq_trace` message flow that its README warns can break the remote node and can only be stopped by quitting erlyberly or `seq_trace:reset_trace()`. README states that tracing needs no code changes or recompilation. Relevant to #720's "hot code reload" test: erlyberly treats reload as an event to recover from, tprof treats it as invalidating results.
- **wobserver** (Elixir; last commit 2017): web observer with a Prometheus `/metrics` endpoint, JSON API, node discovery, custom pages and metrics from config. Unmaintained; only worth noting as the origin of the application-tree code that Observer Web cites in `apps.ex`.

### 4.6 OTP built-ins that are data sources

- **`msacc`** and `erlang:statistics(microstate_accounting)`: per-thread time in states (emulator, gc, port, aux, check_io, sleep, other) per scheduler, dirty scheduler, async and aux threads. `msacc:start(1000)` collects for a duration, `to_file`/`from_file` save and reload. This is the best available attribution of *where scheduler time went* by VM activity class, and it is not per-process. Source: `runtime_tools-2.4/src/msacc.erl`.
- **`scheduler:sample/utilization`** and `erlang:statistics(scheduler_wall_time)`: utilization per scheduler; the flag is node-global and holds a small permanent cost (Observer Web docs say so for its opt-in poller).
- **`lcnt`**: lock counting. Requires an emulator built or started with lock counting (`erl -emu_type lcnt`; stated from my background knowledge, **[inferred]** since I only read the moduledoc here, which says counters update on every lock acquisition and that it is aimed at runtime developers). Not usable on a normal production emulator.
- **`instrument`**: `instrument:allocations/1` summarizes tagged allocations by origin and type with block-size histograms, `carriers/0,1` lists carriers; flags `per_process | per_port | per_mfa` allow grouping by pid or mfa (`instrument.erl` lines 150-190); the module doc says it "may differ greatly from one version to another" and gives no compatibility guarantee. Tagging is limited by default to binaries and NIF/driver allocations, extended per allocator with the `+M<S>atags` emulator option, and the doc warns that a carrier skipped to preserve responsiveness is reported as `UnscannedSize` (this is a coverage field in the API). This is the only OTP route to allocation attribution below the allocator level, and it needs emulator flags set at start.
- **`tprof`** (OTP 27+, experimental): `call_count` (global, no per-process), `call_time`, `call_memory`; ad-hoc `profile/1..4` or server-aided mode with an isolated server per `trace:session`. Documented caveats: slowdown; untraced callees fold into traced callers; hot code reload disables tracing and discards statistics (`tools-4.2.1/src/tprof.erl` moduledoc). The server owns a trace session created with `trace:session_create/3` (line 949).
- **`trace` sessions** (OTP 27): isolated sessions with their own tracer; destroying a session cleans all of its settings; a session handle has a strong ref whose garbage collection destroys the session unless a weak handle is used; local node only; for remote nodes use `dbg` or `ttb` (`kernel-11.0.3/src/trace.erl` lines 36-120, 150-166). This is the primitive that makes #720's "no probe outlives its owner" requirement implementable without recon's global `clear/0`.
- **`dbg:session_create/1`** (OTP 27, experimental): wraps the same isolation for `dbg`; the session server monitors its creator (`dbg.erl` lines 233-260).
- **`erlang:process_info/2`**: requests follow signal ordering guarantees (OTP docs, `erlang.erl` around line 8455), so reading a busy process waits behind its signal queue **[inferred]** (docs state ordering; the delay is the consequence). `memory` is "the size in bytes of the process", including stack, heap and internal structures; `binary` lists referenced binaries; `messages` copies the whole queue; `garbage_collection_info` content "can be changed without prior notice" (`erlang.erl` lines 8485-8560).
- **`erlang:processes_iterator/0`**: used by OTP 29's `observer_backend` to scan processes in bounded chunks.
- **`erl_crash.dump` plus `crashdump_viewer`**: parser reused by Observer Web.

---

## 5. Comparison

Legend: Y yes, P partial, N no, "-" not applicable. "Server-side authz" means a check in the event or API handler rather than control hiding.

| Capability | Observer Web | observer (wx) | etop | observer_cli | LiveDashboard | recon | Spectator |
|---|---|---|---|---|---|---|---|
| Process ranking | Y (full census, truncate) | Y (chunked) | Y | Y (window, budgeted) | Y (full census, truncate) | Y | Y (all, polled) |
| Allocator view | P (carrier utilization) | Y (charts) | N | Y | Y | Y (categories, snapshots) | N |
| Supervision / application tree | Y (chart) | Y | N | P (one root, direct children) | Y | N | N |
| Semantic ownership | N (labels only) | N | N | N | N | N | P (user tags) |
| Function profiling | Y (count, duration, sequence, flame) | N | N | N | N | N | N |
| Function trace | Y (`dbg`, all procs) | Y (`ttb`) | N | Y (one MFA, one pid) | N | Y (rate limited) | N |
| Mutating actions | GC, kill, close, send (eval), unguarded | kill, trace, GUI | N | N (trace, logs) | kill (flag) | N | kill, suspend/resume, none gated |
| Server-side authz per action | N | - | - | - (no web) | P (one boolean) | - | N |
| Sample metadata (interval, coverage, truncation) | N | N | N | Y (CLI envelope) | N | N | N |
| Capture export / comparison | N | N | N | P (envelope only) | N | P (alloc snapshot) | N |
| Bounded collectors on target | P (caps on a few) | P (chunks) | N | Y (heap cap, budgets) | N | P (trace limits) | N |
| Trace cleanup tied to owner death | Y (monitor, `:dbg.stop`, global) | P | - | P (cleanup confirmed; global clear) | - | Y (link to shell; global clear) | - |

---

## 6. Gaps: what no existing tool does well, mapped to #720

Each gap states what I found, then the #720 requirement it touches.

1. **Ownership attribution beyond the supervision tree.** Every tool shows supervision, links, monitors, registered names or initial calls. The only semantic mechanisms are Spectator's user tags (a public ETS table keyed by pid, cleaned by monitor) and `Process.set_label/1` labels used for display (Observer Web, LiveDashboard 0.9, `etop_collect`'s `$process_label`). None attributes a process, an allocation, or CPU to a higher-level owner (session, strand, restart keeper, provider manager) or records an ownership edge with a source and confidence. #720 asks for explicit bounded ownership metadata, unknown ownership shown, and registration/linkage/supervision treated as evidence, not proof. This is the largest gap.
2. **Per-owner memory and CPU accounting.** `process_info(memory)` is per pid; `erlang:memory` and allocators are node-wide; `instrument` can group tagged allocations by pid or mfa but only for emulator-tagged categories; `msacc` is per thread class. No tool joins these into "session X holds N bytes of heap, M of shared binary references, K of ETS". #720 asks for distinct columns (heap capacity, measured size, live after GC, shared binaries, ETS, allocator used and carriers, native, OS RSS) with overlap explained and no summing of binary references. No existing UI explains memory categories this way; the best explanation text is in `recon_alloc` docs and Observer Web's System banner.
3. **Bounded and safe probes as a first-class contract.** Only observer_cli 2.0 treats boundedness as a contract (heap-capped worker, scan admission, deadlines, response limits, coverage fields). Observer Web and LiveDashboard bound only the output list after a full process scan; Spectator probes all processes every second. recon_trace bounds events but cannot bound generation, and clears all other tracing. #720 wants aggregate limits on processes scanned, samples, wall time, retained bytes, depth, events and output, shared by collector, transport and browser, plus request coalescing across tabs. No web inspector coalesces collection across tabs: Observer Web and LiveDashboard start a timer chain per LiveView **[inferred]** from per-page `send_after`.
4. **Probe lifecycle owned by a resource scope.** Existing cleanup is either global (`:dbg.stop()`, recon `clear()`) or tied to a single owner pid by link or monitor. OTP 27 trace sessions and `dbg` sessions are the missing primitive but no inspector uses them: tprof is the only consumer. Observer Web's single-session guard returns `:already_started` and cannot coexist with other `dbg` users. observer_cli documents that session cleanup is not reached by its global clear. #720 asks for per-probe session ownership, no clearing of another profiler's state, and "mark unavailable where ownership cannot be provided". A design built on `trace:session_create/3` with a weak-handle-aware owner is unclaimed.
5. **Before/after comparison with provenance.** Only `recon_alloc` snapshots and observer_cli envelopes are exportable, and neither compares. Observer Web's metrics are an in-memory ring. No tool records build revision, runtime version, workload label, warmup, durations, or probe configuration, or refuses to compare captures that differ in those. #720's phase 3 is entirely unmet by prior art.
6. **Timeline alignment.** Tools show separate charts (scheduler utilization, memory, reductions) with their own clocks. `ttb` and `dbg` timestamps are one source, but no inspector aligns scheduler, GC, mailbox and application events with causal identifiers, nor shows dropped events or uncertainty. Kino's `seq_trace` sequence diagram and Observer Web's call-sequence tree are the closest, and both come from a single trace source.
7. **Sample semantics.** observer_cli is the only tool that labels requested versus actual interval, warming up, reset and missing processes, and distinguishes `processes_used` from `processes` memory. Others show deltas without elapsed time. #720 asks that every sample carry timestamp, elapsed interval, unit, method, coverage and truncation, and that reductions never be shown as CPU seconds.
8. **Process identity and incarnation.** Every tool addresses a pid or port string. observer_cli's observe mode tracks "stable resource identities", and its docs warn that aliases are not handles. None records node incarnation (creation number), collector-issued birth identity, or OS start identity, or revalidates a target before an action. #720 requires all three and historical display of terminated targets.
9. **Authorization.** Gap as in 1.4: no web tool has per-action server-side authorization with roles. LiveDashboard has one global boolean; Observer Web has a resolver value nothing consults; Spectator has none. Erlang distribution cookies are full-trust; observer_cli says so explicitly. #720 asks for a distinct owner/admin diagnostic authority, forged-event tests, and cookie confinement.
10. **Data minimization.** Observer Web ETS contents and LiveDashboard's process info modal expose data by default or by one flag; observer_cli's default snapshot "does not read mailbox contents, process dictionaries, ETS contents, application environment values" and makes content views explicit exceptions. #720 wants raw state, dictionaries, message bodies and ETS contents absent from browsing. observer_cli is the model; the others are weaker.
11. **Reconciling BEAM with OS and other processes.** No tool distinguishes daemon, clients, satellites, language servers and helpers, or shows OS RSS beside BEAM categories with process incarnation. Observer Web's OS data is `os_mon` for the host. #720's role-identification requirement is unmet.
12. **Source navigation for Gleam.** Observer Web and others show generated Erlang names (`module.fn/arity`). No tool maps to Gleam source. #720 says use debug metadata only where reliable; no precedent to copy.
13. **Retention graph and generic dominator analysis.** None exists; #720 already excludes it.

---

## 7. What to steal (design guidance)

From observer_cli:
- Response envelope with `outcome`, per-probe `required`/`status`/`reason`/`duration`/`coverage`, and `issues` separate from probes. Findings suppressed when required coverage is missing.
- Heap-capped, deadline-bounded, monitored worker for each collection, success reported only after normal worker exit.
- Scan admission budgets with refusal as a visible result.
- Capability record with bundle and protocol versions; never inject code.
- Within-response aliases for exports; do not treat aliases as handles.
- Explicit node-global consent wording for tracing and a named emergency cleanup.
- `Reds/s` computed from measured monotonic time; requested versus actual interval; warming-up and reset counts.

From Observer Web:
- Ranking table plus drill-down with pause and refresh controls; attention banner stating cost on every page.
- Single-session probe form showing limits before start; profiling as aggregate report; session generation counter to discard stale ticks.
- Feature gating with in-page explanation.
- Per-application summary with partial flag.
- JSON API next to the HTML pages for automation (the API is the one place in Observer Web where the same collectors serve a different consumer under the same authorization function).

From the classic observer:
- Chunked `procs_info` collector (10,000 per chunk) instead of one full list; per-tab timer that stops when the tab is inactive; `sys:get_status` only after a `proc_lib` check and with a short timeout.

From recon:
- Tracer that only counts and forwards, separate from the formatter; rate form with the documented boundary behavior; denial of dangerous pattern combinations by default; exclusion of the tracer's own pids; `recon_alloc` category definitions and the "allocated vs OS-reported gap suggests native allocation" explanation; allocator snapshots as a capture primitive.

From Spectator:
- The stack itself (mist plus Lustre server components plus `gleam_otp`), the tag manager (ETS plus monitor) as the minimal ownership-metadata mechanism, the OTP-compatible check before sending system messages.

From OTP:
- `trace:session_create/3` for isolated probes; `tprof` server mode as the profiling engine where its caveats are acceptable; `msacc` for scheduler-time attribution by activity class; `instrument` for allocation attribution when emulator flags permit; `processes_iterator` for bounded scans.

Avoid:
- Census then truncate; global `:dbg.stop()` or `clear()` as the only cleanup; unguarded actions; `Code.eval_string` or any evaluation of client text; shipping modules to the target; user-typed node names converted to atoms (Spectator's documented atom-exhaustion issue); bulk `process_info` of every process on a timer per client.

---

## 8. Capability questions this study did not settle

These are things a feasibility phase (#720 phase 1) should measure rather than assume:

- Whether OTP 29's default `dbg` runs on a trace session internally, and what `:dbg.stop()` clears in the presence of other sessions. I only confirmed `dbg:session_create/1` exists and monitors its creator.
- Actual cost of `process_info` on busy processes in a loom-shaped workload; I only read that it follows signal ordering.
- Whether `instrument:allocations` with `per_process` is usable without restarting the daemon with `+M...atags` flags; the module doc says tagging is limited by default and extended by emulator flags.
- Whether `scheduler_wall_time` has a measurable cost under loom's scheduler counts; Observer Web calls it "a small permanent cost".
- Behavior of `trace` sessions when the creating process is garbage collected versus when it exits, for a probe owned by a weft task.
- Overhead and sampling accuracy of `msacc` on Darwin versus Linux.
- Lustre server-component behavior for forged events: whether a client can send an event for a handler that is not in the current view tree. I did not read Lustre for this; #720 already requires a test.

## 9. Source index

Observer Web (commit `b958b587`):
- Mount and dispatch: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/live/index.ex
- Unguarded handlers: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/pages/apps/page.ex (lines 284-312, 372-390, 400-417)
- Resolver: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/resolver.ex
- Tracer server: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/observer_web/tracer/server.ex
- Processes collector: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/observer_web/processes.ex
- JSON API: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/lib/web/api.ex
- Changelog: https://github.com/thiagoesteves/observer_web/blob/b958b587dee789836ca330920e70326bf9f5c128/CHANGELOG.md

observer_cli: https://github.com/zhongwencool/observer_cli (`docs/explanation/core-concepts.md`, `docs/reference/cli.md`, `docs/reference/tui.md`, `src/observer_cli_snapshot.erl`)

LiveDashboard: https://github.com/phoenixframework/phoenix_live_dashboard (`lib/phoenix/live_dashboard/system_info.ex`, `info/process_info_component.ex`, `pages/*.ex`, `guides/metrics_history.md`)

recon: https://github.com/ferd/recon (`src/recon_trace.erl`, `src/recon_alloc.erl`, `src/recon.erl`)

Spectator: https://github.com/JonasGruenwald/spectator (`spectator/src/spectator_ffi.erl`, `spectator_tag_manager.erl`, `README.md`)

OTP (local installed sources, same paths exist in https://github.com/erlang/otp): `lib/observer/src/observer_wx.erl`, `observer_pro_wx.erl`, `observer_procinfo.erl`, `observer_trace_wx.erl`, `etop.erl`; `lib/runtime_tools/src/observer_backend.erl`, `msacc.erl`, `instrument.erl`, `dbg.erl`; `lib/tools/src/tprof.erl`, `lcnt.erl`; `lib/kernel/src/trace.erl`; `erts/preloaded/src/erlang.erl`.

Others: https://swmansion.com/blog/voyager-beam-inspector/, https://kino.hexdocs.pm/Kino.Process.html, https://github.com/andytill/erlyberly, https://github.com/shinyscorpion/wobserver, #720 body from `gh api repos/Roasbeef/loom/issues/720`.

Local clones used for reading are under the scratchpad `src/` directory next to this file.
