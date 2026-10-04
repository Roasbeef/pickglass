//// Fixture data: a Loom-like daemon, for the preview and the tests.
////
//// Every page needs realistic data to be judged by eye, and every test needs
//// a model it can build without a node. This module builds both from the
//// same functions: a daemon with sessions `s-12` and `s-07` and their
//// strands, a restart keeper holding about 180 MiB, processes nobody
//// claimed, a flame graph from a synthetic profile of about forty functions
//// with Gleam-style module names, a call graph and Top table from the same
//// profile, a differential flame, and a comparison with one blocking
//// mismatch.
////
//// It lives under `dev/` and not `src/` on purpose. Fixtures are invented
//// numbers, and nothing the viewer ships should be able to import them and
//// show an operator a figure that was never measured. `dev/` is compiled for
//// `gleam run -m` and for tests, and `gleam export erlang-shipment` leaves it
//// out.
////
//// ## Flow
////
//// `start` assembles every feed for a page; the functions above it build
//// one model each (`strip`, `overview`, `owners`, `processes`,
//// `process_detail`, `memory`, `supervision`, `probes`, `profile`,
//// `timeline`, `compare`, `audit`), sharing the same census and keys.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import pickglass_core/analysis/diff
import pickglass_core/analysis/graph
import pickglass_core/analysis/peek
import pickglass_core/analysis/top
import pickglass_core/analysis/transform
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/layout/dag
import pickglass_core/layout/flame
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/provenance
import pickglass_core/unit
import pickglass_web/app
import pickglass_web/census/owners as owners_builder
import pickglass_web/fixture/stacks
import pickglass_web/fixture/traced
import pickglass_web/fmt
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page.{type Links, type Page}
import pickglass_web/timeline_model
import pickglass_web/view/overview as overview_view

// ------------------------------------------------------------ helpers

const mib: Int = 1_048_576

const gib: Int = 1_073_741_824

/// The time the fixture pretends it is, in Unix milliseconds.
pub const now_ms: Int = 1_790_000_000_000

fn info(
  source: String,
  method: String,
  achieved: Int,
  requested: Int,
  scope: String,
) -> model.PanelInfo {
  model.PanelInfo(
    source:,
    method:,
    cadence: measure.EveryMs(interval_ms: 10_000),
    achieved_ms: Some(10_020),
    took_ms: Some(12),
    coverage: measure.Coverage(
      scope:,
      requested:,
      achieved:,
      outcome: measure.Complete,
      dropped_events: NotApplicable,
      in_flight_events: NotApplicable,
      unscanned_bytes: NotApplicable,
    ),
  )
}

fn cut(
  base: model.PanelInfo,
  reason: measure.TruncationReason,
) -> model.PanelInfo {
  model.PanelInfo(
    ..base,
    coverage: measure.Coverage(
      ..base.coverage,
      outcome: measure.Partial(reason: measure.Truncated(reason:)),
    ),
  )
}

fn boot() -> identity.BootId {
  result.unwrap(identity.boot_id("7f3a9c01"), identity.unknown_boot)
}

fn checkpoints() -> List(model.CheckpointRef) {
  [
    model.CheckpointRef(
      key: key.make("cp.idle-0"),
      checkpoint: capture.Checkpoint(
        name: "idle-0",
        agent_monotonic_ns: 4_200_000_000_000,
        system_ms: now_ms - 1_800_000,
      ),
    ),
    model.CheckpointRef(
      key: key.make("cp.pre-restart"),
      checkpoint: capture.Checkpoint(
        name: "pre-restart",
        agent_monotonic_ns: 5_000_000_000_000,
        system_ms: now_ms - 600_000,
      ),
    ),
  ]
}

fn idle_0() -> Option(model.CheckpointRef) {
  list.first(checkpoints()) |> option.from_result
}

// ------------------------------------------------------------ strip

/// The top strip: a live, full-trust attachment to `loomd`.
pub fn strip() -> model.StripModel {
  model.StripModel(
    node: "loom_daemon@127.0.0.1",
    incarnation: identity.NodeIncarnation(
      node_digest: "7f3a9c01d2e4",
      creation: 3,
      boot: boot(),
    ),
    os: identity.OsProcess(
      pid: 48_211,
      start: identity.PreciseStart(token: "1790000000.04"),
    ),
    uptime_ms: Known(11_520_000),
    source: model.Live,
    banner: model.CapabilityBanner(
      role: model.AttachedFullTrust,
      grants: policy.all_capabilities,
      source_line: "census gen 418 · 2.0 s ago · 112 ms · 3,412 of 3,412 processes",
    ),
    observer: model.ObserverEffect(
      duty: Known(30),
      note: "collector duty cycle: census, polled gauges and one counters probe",
    ),
    probes: [
      model.ActiveProbe(
        key: key.make("probe.p-41"),
        kind: policy.Sampling,
        remaining_ms: Known(38_000),
      ),
    ],
  )
}

// ------------------------------------------------------------ overview

fn layer(label: String, depth: Int, value: Int, delta: Int) -> model.LayerRow {
  model.LayerRow(
    label:,
    depth:,
    value: Known(value),
    delta: Known(delta),
    derivation: model.Measured,
  )
}

fn derived(
  label: String,
  upper: model.LayerRow,
  lower: model.LayerRow,
  note: String,
) -> model.LayerRow {
  model.LayerRow(
    label:,
    depth: 1,
    value: overview_view.gap(upper.value, lower.value),
    delta: overview_view.gap(upper.delta, lower.delta),
    derivation: model.Derived(note:),
  )
}

/// The overview page's data.
pub fn overview() -> model.OverviewModel {
  let rss =
    layer("OS resident set (viewer, /proc)", 0, 1932 * mib + 700_000, 410 * mib)
  let carriers = layer("allocator carriers", 0, 1751 * mib, 398 * mib)
  let total = layer("erlang:memory total", 0, 1208 * mib, 22 * mib)

  model.OverviewModel(
    layers: model.Panel(
      info: info(
        "VM gauges and /proc",
        "erlang:memory, allocator info, RssAnon",
        4,
        4,
        "layers",
      ),
      body: [
        rss,
        carriers,
        total,
        layer("processes", 1, 727 * mib, 19 * mib),
        layer("binary", 1, 215 * mib, 2 * mib),
        layer("ets", 1, 92 * mib, mib),
        model.LayerRow(
          label: "atom",
          depth: 1,
          value: Known(3 * mib),
          delta: Known(0),
          derivation: model.Measured,
        ),
        derived(
          "gap: carriers − total",
          carriers,
          total,
          "allocator capacity the VM does not count as in use",
        ),
        derived(
          "gap: RSS − carriers",
          rss,
          carriers,
          "native code, thread stacks and memory outside the VM allocators",
        ),
        model.LayerRow(
          label: "code",
          depth: 1,
          value: Missing(measure.UnsupportedOnRuntime),
          delta: Missing(measure.UnsupportedOnRuntime),
          derivation: model.Measured,
        ),
      ],
    ),
    checkpoint: idle_0(),
    checkpoints: checkpoints(),
    schedulers: model.Panel(
      info: model.PanelInfo(
        ..info(
          "scheduler wall time",
          "scheduler_wall_time, 2 s window",
          16,
          16,
          "readings",
        ),
        cadence: measure.EveryMs(interval_ms: 2000),
      ),
      body: [
        model.Sparkline(
          label: "utilisation",
          unit: unit.Ratio(per: 10_000),
          points: ratios([
            120,
            180,
            160,
            240,
            210,
            190,
            260,
            300,
            280,
            220,
            180,
            210,
            230,
            250,
            240,
            270,
          ]),
          summary: Known(110),
          note: "mean over the window",
        ),
        model.Sparkline(
          label: "run queue",
          unit: unit.Count,
          points: counts([0, 1, 0, 0, 2, 1, 0, 0, 3, 1, 0, 0, 1, 0, 0, 1]),
          summary: Known(3),
          note: "maximum in the window",
        ),
        model.Sparkline(
          label: "reductions/s",
          unit: unit.Reductions,
          points: with_gap(
            counts([
              38_000,
              41_000,
              39_500,
              44_000,
              52_000,
              47_000,
              43_000,
              41_000,
              40_000,
              42_000,
            ]),
            6,
          ),
          summary: Known(41_000),
          note: "work done, not CPU time",
        ),
      ],
    ),
    counts: [
      model.CountTile(
        label: "processes",
        value: Known(3412),
        limit: Known(1_048_576),
      ),
      model.CountTile(label: "ports", value: Known(61), limit: Known(65_536)),
      model.CountTile(
        label: "ets tables",
        value: Known(210),
        limit: NotApplicable,
      ),
      model.CountTile(
        label: "atoms",
        value: Known(31_004),
        limit: Known(1_048_576),
      ),
    ],
    roles: model.Panel(
      info: info("OS", "ps and /proc readings by role", 6, 6, "OS processes"),
      body: [
        os_role(
          "daemon",
          48_211,
          1932 * mib + 700_000,
          Known(1751 * mib),
          "loomd, the node pickglass is attached to",
          identity.PreciseStart(token: "a"),
        ),
        os_role(
          "client",
          48_390,
          96 * mib,
          Known(71 * mib),
          "loom tui",
          identity.PreciseStart(token: "b"),
        ),
        os_role(
          "satellite",
          48_512,
          310 * mib,
          Known(280 * mib),
          "code-mode satellite",
          identity.PreciseStart(token: "c"),
        ),
        os_role(
          "satellite",
          48_513,
          305 * mib,
          Known(277 * mib),
          "code-mode satellite",
          identity.CoarseStart(token: "d"),
        ),
        os_role(
          "helper",
          48_620,
          18 * mib,
          NotApplicable,
          "sandbox helper",
          identity.PreciseStart(token: "e"),
        ),
        os_role(
          "language server",
          48_701,
          640 * mib,
          Known(590 * mib),
          "gopls",
          identity.UnreadableStart,
        ),
      ],
    ),
  )
}

fn os_role(
  role: String,
  pid: Int,
  rss: Int,
  anon: Measurement,
  note: String,
  start: identity.StartIdentity,
) -> model.OsRole {
  model.OsRole(
    role:,
    os: identity.OsProcess(pid:, start:),
    rss: Known(rss),
    anon:,
    note:,
  )
}

fn ratios(values: List(Int)) -> List(Measurement) {
  list.map(values, Known)
}

fn counts(values: List(Int)) -> List(Measurement) {
  list.map(values, Known)
}

// Replace the reading at one position with a missing one.
fn with_gap(points: List(Measurement), at: Int) -> List(Measurement) {
  list.index_map(points, fn(point, index) {
    case index == at {
      True -> Missing(measure.BudgetExhausted)
      False -> point
    }
  })
}

// ------------------------------------------------------------ census

fn claim(
  path: List(#(String, String)),
  role: String,
  source: owner.Source,
) -> owner.Attribution {
  let segments =
    list.filter_map(path, fn(pair) { owner.segment(pair.0, pair.1) })

  owner.join([
    owner.Claim(path: segments, role:, source:, confidence: owner.High),
  ])
}

fn process(
  index: Int,
  pid: String,
  attribution: owner.Attribution,
  memory_mib: Int,
  mailbox: Int,
  reductions: Int,
  binary_refs: Int,
  current: String,
) -> model.ProcRow {
  model.ProcRow(
    key: key.indexed("proc", index),
    pid_text: pid,
    owner_label: label_of(attribution),
    attribution:,
    memory: Known(memory_mib * mib),
    heap_cap: Known(memory_mib * mib - 40_000),
    mailbox: Known(mailbox),
    reductions: Known(reductions),
    binary_refs: Known(binary_refs),
    current: Some(current),
  )
}

fn label_of(attribution: owner.Attribution) -> String {
  case attribution {
    owner.Attributed(winner:, ..) ->
      owner.path_to_string(winner.path) <> " / " <> winner.role
    owner.Unattributed -> "unknown"
  }
}

fn s12(role: String) -> owner.Attribution {
  claim([#("session", "s-12"), #("strand", "main")], role, owner.Declared)
}

fn s07(role: String) -> owner.Attribution {
  claim([#("session", "s-07"), #("strand", "main")], role, owner.Declared)
}

fn agent(role: String) -> owner.Attribution {
  claim([#("daemon", "core")], role, owner.Registry)
}

/// The census every page draws from.
pub fn census() -> List(model.ProcRow) {
  [
    process(
      1,
      "<0.4411.0>",
      s12("restart_keeper"),
      181,
      0,
      0,
      0,
      "gleam@erlang@process:receive_forever/1",
    ),
    process(
      2,
      "<0.4412.0>",
      s12("worker"),
      12,
      0,
      8420,
      31,
      "loom@runtime@strand:step/4",
    ),
    process(
      3,
      "<0.4413.0>",
      s12("worker"),
      7,
      2,
      3110,
      9,
      "loom@provider@gateway:stream/2",
    ),
    process(
      4,
      "<0.4414.0>",
      s12("advisor"),
      4,
      0,
      940,
      0,
      "weft@actor:handle/3",
    ),
    process(
      5,
      "<0.4415.0>",
      s12("provider"),
      9,
      0,
      5900,
      24,
      "ssl_gen_statem:handle_info/4",
    ),
    process(
      6,
      "<0.4511.0>",
      s07("restart_keeper"),
      6,
      0,
      0,
      0,
      "gleam@erlang@process:receive_forever/1",
    ),
    process(
      7,
      "<0.4512.0>",
      s07("worker"),
      5,
      0,
      2050,
      4,
      "loom@runtime@strand:step/4",
    ),
    process(
      8,
      "<0.4513.0>",
      s07("provider"),
      3,
      0,
      1400,
      6,
      "loom@provider@gateway:request/3",
    ),
    process(
      9,
      "<0.610.0>",
      agent("conversation_store"),
      22,
      1,
      4300,
      0,
      "esqlite3:exec/2",
    ),
    process(
      10,
      "<0.611.0>",
      agent("broker"),
      3,
      0,
      700,
      0,
      "loom@tools@broker:call/3",
    ),
    process(
      11,
      "<0.612.0>",
      agent("telemetry"),
      2,
      0,
      1900,
      0,
      "loom@telemetry@metrics:emit/3",
    ),
    process(
      12,
      "<0.901.0>",
      owner.Unattributed,
      11,
      0,
      910,
      2,
      "gen_server:loop/7",
    ),
    process(
      13,
      "<0.902.0>",
      owner.Unattributed,
      3,
      4,
      4100,
      0,
      "prim_inet:recv0/3",
    ),
    process(
      14,
      "<0.903.0>",
      owner.Unattributed,
      2,
      0,
      12,
      0,
      "logger_h_common:log/2",
    ),
  ]
}

fn delta_for(label: String) -> Measurement {
  case label {
    "session:s-12" -> Known(188 * mib)
    "session:s-12 / restart_keeper" -> Known(182 * mib)
    "session:s-12 / worker" -> Known(6 * mib)
    "session:s-07" -> Known(206_000)
    "daemon:core" -> Known(mib)
    _ -> Known(0)
  }
}

// ------------------------------------------------------------ owners

/// The owners page's data, built through `census/owners` so the unknown row
/// and the overlap rule are the production ones.
pub fn owners() -> model.OwnersModel {
  let listed = list.length(census())

  owners_builder.build(
    cut(
      info(
        "census",
        "process_info bundle v1, label read, top owners by heap capacity",
        listed,
        3412,
        "processes",
      ),
      measure.TopKLimit,
    ),
    census(),
    checkpoints(),
    idle_0(),
    delta_for,
  )
  |> owners_builder.with_remainder(
    procs: 3412 - listed,
    heap_cap: Known(44 * mib),
  )
}

/// The owners whose heap capacity moved most since the checkpoint, in the
/// same figures the owners page shows for its groups.
pub fn owner_movers() -> model.OwnerMovers {
  model.OwnerMovers(since: "idle-0", rows: [
    model.OwnerMover(label: "daemon:core", delta: Known(mib)),
    model.OwnerMover(label: "session:s-12", delta: delta_for("session:s-12")),
    model.OwnerMover(label: "session:s-07", delta: delta_for("session:s-07")),
    model.OwnerMover(label: "unknown", delta: Known(0)),
  ])
}

// ------------------------------------------------------------ processes

/// The processes page's data: the first window of 3,412 by memory.
pub fn processes() -> model.ProcessesModel {
  let rows =
    census()
    |> list.sort(fn(a, b) { int.compare(memory_of(b), memory_of(a)) })

  model.ProcessesModel(
    info: cut(
      info("census", "process_info bundle v1", 3412, 3412, "processes"),
      measure.TopKLimit,
    ),
    sort: model.ByMemory,
    window: model.Window(offset: 0, size: 100, total: 3412),
    rows:,
    rate_ms: Some(2000),
  )
}

fn memory_of(row: model.ProcRow) -> Int {
  case row.memory {
    Known(value:) -> value
    _ -> 0
  }
}

// ------------------------------------------------------------ detail

/// The restart keeper's detail page.
pub fn process_detail() -> model.ProcessDetailModel {
  let attribution =
    owner.join([
      owner.Claim(
        path: segments([#("session", "s-12"), #("strand", "main")]),
        role: "restart_keeper",
        source: owner.Declared,
        confidence: owner.High,
      ),
      owner.Claim(
        path: segments([#("daemon", "core")]),
        role: "supervised",
        source: owner.Supervision,
        confidence: owner.Low,
      ),
    ])

  model.ProcessDetailModel(
    info: info("process_info", "selected counters, one read", 1, 1, "process"),
    key: key.indexed("proc", 1),
    pid_text: "<0.4411.0>",
    birth: "initial call erlang:apply/2, spawned by <0.49.0>",
    liveness: model.Alive,
    pin: model.Pinned(pin: key.make("pin.p-17")),
    attribution:,
    successor: Some(model.Successor(predecessor: "17,990", exited: "14:07:11")),
    counters: [
      counter("memory", unit.Bytes, Known(181 * mib)),
      counter("total heap", unit.Bytes, Known(181 * mib)),
      counter("heap", unit.Bytes, Known(2 * mib)),
      counter("old heap", unit.Bytes, Known(179 * mib)),
      counter("stack", unit.Bytes, Known(1024)),
      counter("mailbox", unit.Count, Known(0)),
      counter("reductions", unit.Reductions, Known(2_840_113)),
      counter("binary refs", unit.Count, Missing(measure.CounterDisabled)),
    ],
    gc: [
      counter("minor collections", unit.Count, Known(3)),
      counter("full sweep after", unit.Count, Known(65_535)),
      counter("message buffer", unit.Bytes, Known(0)),
      counter("binary virtual heap", unit.Bytes, Known(0)),
    ],
    history: [
      model.Sparkline(
        label: "heap capacity",
        unit: unit.Bytes,
        points: counts([4, 4, 5, 5, 7, 181, 181, 181, 181, 181, 181, 181])
          |> scale_mib,
        summary: Known(181 * mib),
        note: "grew 36× in one step and has not shrunk",
      ),
      model.Sparkline(
        label: "mailbox",
        unit: unit.Count,
        points: counts([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        summary: Known(0),
        note: "",
      ),
    ],
    evidence: [
      model.Evidence(
        kind: "supervisor",
        target: "<0.4400.0>",
        source: owner.Supervision,
      ),
      model.Evidence(
        kind: "link",
        target: "<0.4400.0>",
        source: owner.Supervision,
      ),
      model.Evidence(
        kind: "monitor",
        target: "<0.4412.0>",
        source: owner.Provider,
      ),
    ],
    self_measure: model.Available,
  )
}

fn counter(label: String, u: unit.Unit, value: Measurement) -> model.Counter {
  model.Counter(label:, unit: u, value:, inapplicable: "")
}

fn scale_mib(points: List(Measurement)) -> List(Measurement) {
  list.map(points, fn(point) {
    case point {
      Known(value) -> Known(value * mib)
      other -> other
    }
  })
}

fn segments(path: List(#(String, String))) -> List(owner.Segment) {
  list.filter_map(path, fn(pair) { owner.segment(pair.0, pair.1) })
}

// ------------------------------------------------------------ memory

fn category(
  label: String,
  value: Measurement,
  additivity: measure.Additivity,
  note: String,
) -> model.CategoryRow {
  model.CategoryRow(
    label:,
    unit: unit.Bytes,
    value:,
    used: NotApplicable,
    additivity:,
    note:,
  )
}

/// The memory page's data.
pub fn memory() -> model.MemoryModel {
  model.MemoryModel(
    categories: model.Panel(
      info: info(
        "erlang:memory",
        "erlang:memory/0, not atomic",
        9,
        9,
        "categories",
      ),
      body: [
        category(
          "processes",
          Known(727 * mib),
          measure.Additive,
          "heaps, stacks and mailboxes of processes",
        ),
        category(
          "system",
          Known(481 * mib),
          measure.Additive,
          "everything the VM holds that is not a process",
        ),
        category(
          "processes_used",
          Known(702 * mib),
          measure.Overlapping("part of processes"),
          "the part of processes in use",
        ),
        category(
          "binary",
          Known(215 * mib),
          measure.Overlapping("also referenced from process heaps"),
          "reference-counted binaries",
        ),
        category(
          "ets",
          Known(92 * mib),
          measure.Overlapping("part of system"),
          "ETS table storage",
        ),
        category(
          "code",
          Missing(measure.UnsupportedOnRuntime),
          measure.Overlapping("part of system"),
          "loaded code",
        ),
        category(
          "atom",
          Known(3 * mib),
          measure.Overlapping("part of system"),
          "the atom table",
        ),
        category(
          "total",
          Known(1208 * mib),
          measure.Overlapping("sum of processes and system"),
          "processes plus system",
        ),
      ],
    ),
    allocators: model.Panel(
      info: info(
        "allocator info",
        "erlang:system_info(allocator), carriers",
        7,
        7,
        "allocators",
      ),
      body: [
        category(
          "eheap_alloc carriers",
          Known(790 * mib),
          measure.Additive,
          "capacity held for process heaps",
        ),
        category(
          "binary_alloc carriers",
          Known(260 * mib),
          measure.Additive,
          "capacity held for binaries",
        ),
        category(
          "ets_alloc carriers",
          Known(101 * mib),
          measure.Additive,
          "capacity held for ETS",
        ),
        category(
          "ll_alloc carriers",
          Known(310 * mib),
          measure.Additive,
          "capacity held for long-lived data",
        ),
        category(
          "literal_alloc carriers",
          Known(6 * mib),
          measure.Additive,
          "capacity held for literals",
        ),
        category(
          "other allocators carriers",
          Known(284 * mib),
          measure.Additive,
          "temp, short-lived, standard and driver allocators together",
        ),
        category(
          "fragmentation",
          Missing(measure.UnsupportedOnPlatform),
          measure.Overlapping("would be derived from carriers and use"),
          "unused part of carriers; this platform does not report allocator use",
        ),
      ],
    ),
    tables: model.Panel(
      info: info("tables", "ets:info/1 over 210 tables", 210, 210, "tables"),
      body: [
        category(
          "conversation index",
          Known(41 * mib),
          measure.Additive,
          "ETS, 1 table",
        ),
        category(
          "session registry",
          Known(7 * mib),
          measure.Additive,
          "ETS, 12 tables",
        ),
        category("pg scopes", Known(2 * mib), measure.Additive, "ETS, 4 tables"),
        category(
          "refc binaries held by processes",
          Known(215 * mib),
          measure.Overlapping("shared between processes"),
          "count differs by holder",
        ),
      ],
    ),
  )
}

// ------------------------------------------------------------ supervision

fn node(
  index: Int,
  label: String,
  kind: model.SupKind,
  owner_label: Option(String),
  children: List(model.SupNode),
) -> model.SupNode {
  model.SupNode(
    key: key.indexed("sup", index),
    label:,
    kind:,
    owner_label:,
    children:,
  )
}

/// The supervision page's data.
pub fn supervision() -> model.SupervisionModel {
  model.SupervisionModel(
    info: info(
      "supervision walk",
      "process_info(parent) and $ancestors",
      3412,
      3412,
      "processes",
    ),
    roots: [
      node(1, "loom_sup", model.Supervisor, None, [
        node(2, "session_sup", model.Supervisor, None, [
          node(3, "strand_sup s-12", model.Supervisor, Some("session s-12"), [
            node(
              4,
              "keeper",
              model.Leaf,
              Some("session s-12 / restart_keeper"),
              [],
            ),
            node(
              5,
              "strand main",
              model.Leaf,
              Some("session s-12 / worker"),
              [],
            ),
            node(6, "advisor", model.Leaf, Some("session s-12 / advisor"), []),
          ]),
          node(7, "strand_sup s-07", model.Supervisor, Some("session s-07"), [
            node(
              8,
              "keeper",
              model.Leaf,
              Some("session s-07 / restart_keeper"),
              [],
            ),
            node(
              9,
              "strand main",
              model.Leaf,
              Some("session s-07 / worker"),
              [],
            ),
          ]),
        ]),
        node(10, "store_sup", model.Supervisor, None, [
          node(
            11,
            "conversation_store",
            model.Leaf,
            Some("daemon core / conversation_store"),
            [],
          ),
        ]),
        node(12, "telemetry", model.Leaf, Some("daemon core / telemetry"), []),
      ]),
      node(13, "<0.901.0>", model.UnknownKind, None, []),
    ],
    caveat: "Loom's root starts outside an application, so the tree is built from parent links and has no application master. Read it as evidence of structure, not as who owns what.",
    omitted: 0,
  )
}

// ------------------------------------------------------------ probes

fn principal() -> policy.Principal {
  policy.Principal(
    id: policy.PrincipalId(text: "tab-1"),
    grants: set.from_list(policy.all_capabilities),
  )
}

fn live_pin() -> Result(identity.LivePin, Nil) {
  use token <- result.try(identity.pin(boot(), 17))
  result.replace_error(identity.check_pin(token, boot()), Nil)
}

fn plan_card() -> Option(model.PlanCard) {
  plan_card_of(policy.Counters, ["loom@runtime@keeper"], 30_000)
}

/// A plan card for a probe of any kind over the keeper, for the dialog's
/// tests: the same plan the Probes page draws, with the kind, modules and
/// duration given.
///
/// ## Examples
///
/// ```gleam
/// fixture.plan_card_of(policy.CallTree, ["lists"], 5000)
/// ```
pub fn plan_card_of(
  kind: policy.ProbeKind,
  modules: List(String),
  duration_ms: Int,
) -> Option(model.PlanCard) {
  let planned = {
    use pin <- result.try(live_pin())

    let spec =
      policy.ProbeSpec(
        kind:,
        targets: [identity.live_token(pin)],
        modules:,
        duration_ms:,
        rate_hz: 0,
      )

    let estimate =
      policy.Estimate(
        events_low: 4000,
        events_high: 22_000,
        bytes_high: 1_800_000,
        wall_ms: 30_000,
      )

    policy.plan(principal(), policy.StartProbe(spec), [pin], estimate, now_ms).result
    |> result.replace_error(Nil)
  }

  case planned {
    Ok(plan) ->
      Some(model.PlanCard(
        key: key.make("plan.1"),
        what: model.ProbePlan(kind),
        plan:,
        matched: Known(23),
        target_labels: ["<0.4411.0> session s-12 / restart_keeper (pin p-17)"],
        chosen: "",
        adjust: model.NotAdjustable,
      ))
    Error(Nil) -> None
  }
}

// A stack probe over three pinned processes, as a profile button plans it.
fn profile_plan_card() -> Option(model.PlanCard) {
  let planned = {
    use first <- result.try(live_pin())
    use token_two <- result.try(identity.pin(boot(), 18))
    use second <- result.try(result.replace_error(
      identity.check_pin(token_two, boot()),
      Nil,
    ))
    use token_three <- result.try(identity.pin(boot(), 19))
    use third <- result.try(result.replace_error(
      identity.check_pin(token_three, boot()),
      Nil,
    ))

    let spec =
      policy.ProbeSpec(
        kind: policy.Sampling,
        targets: [
          identity.live_token(first),
          identity.live_token(second),
          identity.live_token(third),
        ],
        modules: [],
        duration_ms: 10_000,
        rate_hz: 100,
      )

    let estimate =
      policy.Estimate(
        events_low: 0,
        events_high: 3000,
        bytes_high: 384_000,
        wall_ms: 10_000,
      )

    policy.plan(
      principal(),
      policy.StartProbe(spec),
      [first, second, third],
      estimate,
      now_ms,
    ).result
    |> result.replace_error(Nil)
  }

  case planned {
    Ok(plan) ->
      Some(model.PlanCard(
        key: key.make("plan.2"),
        what: model.ProbePlan(policy.Sampling),
        plan:,
        matched: NotApplicable,
        target_labels: [
          "<0.4411.0> session s-12 / restart_keeper",
          "<0.4412.0> session s-12 / worker",
          "<0.4413.0> session s-12 / worker",
        ],
        chosen: "3 of 3 processes of session s-12, the busiest by reductions/s",
        adjust: model.AdjustStacks(
          duration_ms: 10_000,
          rate_hz: 100,
          processes: 2,
        ),
      ))
    Error(Nil) -> None
  }
}

/// The flow above every page but Probes: a profile button's plan waiting for
/// confirmation, one probe running and a finished profile to open.
pub fn flow() -> model.FlowModel {
  model.FlowModel(
    pending: profile_plan_card(),
    running: [
      model.ActiveProbe(
        key: key.make("probe.p-41"),
        kind: policy.Sampling,
        remaining_ms: Known(6000),
      ),
    ],
    ready: Some(model.ReadyProfile(
      probe: "p-40",
      age_ms: 12_000,
      summary: "1,840 samples at 100 Hz",
      opens: model.OpensProfile,
    )),
    refused: None,
  )
}

/// The probes page's data, with one plan waiting for confirmation.
pub fn probes() -> model.ProbesModel {
  model.ProbesModel(
    info: info("agent", "probe table and capture", 3, 3, "probes"),
    targets: [
      #(key.indexed("proc", 1), "<0.4411.0> session s-12 / restart_keeper"),
      #(key.indexed("proc", 2), "<0.4412.0> session s-12 / worker"),
      #(key.indexed("proc", 9), "<0.610.0> daemon core / conversation_store"),
    ],
    pending: plan_card(),
    active: [
      model.ActiveProbe(
        key: key.make("probe.p-41"),
        kind: policy.Sampling,
        remaining_ms: Known(38_000),
      ),
    ],
    history: [
      model.ProbeHistoryRow(
        key: key.make("probe.p-40"),
        kind: policy.Counters,
        outcome: measure.Complete,
        cost: capture.ProbeCost(
          probe: "p-40",
          enabled: ["call_time"],
          events: measure.NotApplicable,
          collector_reductions: measure.NotApplicable,
          bytes: Known(1_400_000),
          wall_ms: Known(30_004),
          outcome: measure.Complete,
          matched: Some(12),
        ),
      ),
      model.ProbeHistoryRow(
        key: key.make("probe.p-39"),
        kind: policy.Sampling,
        outcome: measure.Partial(reason: measure.Truncated(
          reason: measure.BudgetReached,
        )),
        cost: capture.ProbeCost(
          probe: "p-39",
          enabled: ["current_stacktrace"],
          events: Known(9812),
          collector_reductions: Known(880_000),
          bytes: Missing(measure.CounterDisabled),
          wall_ms: Known(10_011),
          outcome: measure.Partial(reason: measure.Truncated(
            reason: measure.BudgetReached,
          )),
          matched: None,
        ),
      ),
    ],
    grants: policy.all_capabilities,
  )
}

// ------------------------------------------------------------ profile

/// The steps of the fixture's filter chain: focus on Loom's modules, hide the
/// actor loop frames, and a pattern that matches nothing.
pub fn chain() -> List(transform.Step) {
  [
    transform.Focus(pattern: "loom@"),
    transform.Hide(pattern: "gleam@otp@actor"),
    transform.Ignore(pattern: "no_such_module"),
    transform.NodeFraction(fraction: 0.005),
  ]
}

/// The profile page's data, built through core's analyses.
pub fn profile() -> Result(model.ProfileModel, String) {
  use base <- result.try(
    stacks.build(stacks.Base) |> result.replace_error("profile did not build"),
  )
  use column <- result.try(
    profile.column_named(base, "samples")
    |> result.replace_error("no samples column"),
  )
  use applied <- result.try(
    transform.apply(base, chain(), column)
    |> result.replace_error("chain refused"),
  )
  use layout <- result.try(
    flame.layout(applied.profile, column, flame.default_config)
    |> result.replace_error("flame refused"),
  )
  use call_graph <- result.try(
    graph.build(
      applied.profile,
      column,
      graph.with_display(graph.default_config, applied.display),
    )
    |> result.replace_error("graph refused"),
  )
  use table <- result.try(
    top.table(applied.profile, None, top.Sort(column:, key: top.ByFlat))
    |> result.replace_error("top refused"),
  )

  let name_of = fn(id) { profile.name_of(applied.profile, id) }
  let placed = dag.layout(call_graph, name_of, dag.default_config)

  let peeks =
    list.filter_map(call_graph.nodes, fn(n) { peek.at(call_graph, n.function) })

  Ok(
    model.ProfileModel(
      header: model.ProfileHeader(
        title: "probe p-41",
        source: profile.source(applied.profile),
        info: model.PanelInfo(
          source: "polled current_stacktrace",
          method: "sampled at reduction safe points, 50 Hz requested",
          cadence: measure.EveryMs(interval_ms: 20),
          achieved_ms: Some(20),
          took_ms: None,
          coverage: measure.Coverage(
            scope: "samples over 2 targets",
            requested: 12_000,
            achieved: profile.total(base, column),
            outcome: measure.Partial(reason: measure.Truncated(
              reason: measure.BudgetReached,
            )),
            dropped_events: Known(12_000 - profile.total(base, column)),
            in_flight_events: NotApplicable,
            unscanned_bytes: NotApplicable,
          ),
        ),
        caveats: [
          "Width is a share of samples, not of time.",
          "Long BIFs and NIFs are under-sampled.",
          "Stack depth is limited to 8; truncated roots are drawn at the base.",
        ],
      ),
      profile: applied.profile,
      column:,
      chain: applied.reports,
      stacks: model.HasStacks(layout:, graph: call_graph, dag: placed, peeks:),
      activity: model.NoStatuses,
      top: table,
      exports: [],
    ),
  )
}

// ------------------------------------------------------------ timeline

fn steps(
  values: List(Measurement),
  width_ms: Int,
) -> List(timeline_model.Step) {
  list.index_map(values, fn(value, index) {
    timeline_model.Step(at_ms: index * width_ms, width_ms:, value:)
  })
}

/// The timeline page's data: scheduler counters polled at two seconds, a heap
/// counter polled at ten, spans from the host and a gap where the collector
/// went over budget.
pub fn timeline() -> timeline_model.TimelineModel {
  timeline_model.TimelineModel(
    info: model.PanelInfo(
      ..info(
        "agent rings",
        "polled gauges and host operation events",
        6,
        6,
        "tracks",
      ),
      cadence: measure.EveryMs(interval_ms: 2000),
    ),
    window_ms: 60_000,
    clock_note: "agent monotonic clock, viewer readings ±0.4 ms",
    tracks: [
      timeline_model.CounterTrack(
        label: "scheduler util",
        unit: unit.Ratio(per: 10_000),
        steps: steps(
          with_gap(
            ratios([
              120,
              140,
              210,
              700,
              780,
              240,
              160,
              130,
              150,
              190,
              210,
              300,
              320,
              180,
              140,
              120,
              110,
              100,
              130,
              150,
              160,
              170,
              140,
              130,
              120,
              110,
              120,
              140,
              130,
              120,
            ]),
            21,
          ),
          2000,
        ),
      ),
      timeline_model.CounterTrack(
        label: "run queue",
        unit: unit.Count,
        steps: steps(
          counts([
            0,
            0,
            1,
            3,
            2,
            1,
            0,
            0,
            0,
            1,
            1,
            2,
            2,
            1,
            0,
            0,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
          ]),
          2000,
        ),
      ),
      timeline_model.CounterTrack(
        label: "s-12 keeper heap",
        unit: unit.Bytes,
        steps: steps(scale_mib(counts([5, 7, 181, 181, 181, 181])), 10_000),
      ),
      timeline_model.SpanTrack(label: "s-12 operations", spans: [
        timeline_model.Span(
          at_ms: 1000,
          length_ms: 6000,
          label: "provider call",
        ),
        timeline_model.Span(at_ms: 8200, length_ms: 2300, label: "tool exec"),
        timeline_model.Span(
          at_ms: 14_000,
          length_ms: 9000,
          label: "provider call",
        ),
        timeline_model.Span(at_ms: 26_000, length_ms: 1500, label: "tool exec"),
        timeline_model.Span(
          at_ms: 41_000,
          length_ms: 12_000,
          label: "provider call",
        ),
      ]),
    ],
    gaps: [
      timeline_model.CoverageGap(
        from_ms: 42_000,
        to_ms: 46_000,
        dropped: Known(1204),
        reason: "collector over its event budget",
      ),
    ],
    events: None,
    calls: None,
  )
}

/// The timeline with a scheduling and collection probe and a call tree
/// probe drawn below the polled tracks.
pub fn timeline_traced() -> timeline_model.TimelineModel {
  timeline_model.TimelineModel(
    ..timeline(),
    events: Some(traced.events()),
    calls: Some(traced.calls()),
  )
}

/// The timeline with a scheduling probe that stopped before its window did.
pub fn timeline_overrun() -> timeline_model.TimelineModel {
  timeline_model.TimelineModel(
    ..timeline(),
    events: Some(traced.events_overrun()),
    calls: None,
  )
}

// ------------------------------------------------------------ compare

fn provenance_for(
  revision: String,
  workload: String,
  sessions: Int,
  cadence_ms: Int,
) -> provenance.Provenance {
  provenance.Provenance(
    producer: provenance.Producer(
      pickglass: "0.1.0",
      agent: "0.1.0",
      schema: "pickglass.capture/1",
    ),
    target: provenance.Target(
      incarnation: identity.NodeIncarnation(
        node_digest: "7f3a9c01d2e4",
        creation: 3,
        boot: boot(),
      ),
      os: identity.OsProcess(
        pid: 48_211,
        start: identity.PreciseStart(token: "a"),
      ),
      role: "daemon",
    ),
    runtime: provenance.Runtime(
      otp_release: "29.0.5",
      erts_version: "17.0",
      emulator_flavor: "jit",
      wordsize: 8,
      schedulers: 16,
      dirty_cpu_schedulers: Some(16),
      flags: ["+Muatags true"],
    ),
    build: provenance.Build(
      application: "loom",
      version: "0.9.0",
      revision:,
      compiler: "gleam 1.19",
    ),
    workload: provenance.Workload(
      label: workload,
      sessions: [#("idle", sessions)],
      warmup_ms: Some(300_000),
      notes: "",
    ),
    collection: provenance.Collection(
      method: "census K=200",
      cadence: measure.EveryMs(interval_ms: cadence_ms),
      budgets: provenance.Budgets(
        top_k: 200,
        max_events: Some(100_000),
        deadline_ms: 5000,
      ),
    ),
  )
}

/// The compare page's data: build revisions differ (expected) and the
/// workload differs (blocking), so verdicts are withheld.
pub fn compare() -> Result(model.CompareModel, String) {
  use base <- result.try(
    stacks.build(stacks.Base) |> result.replace_error("base profile"),
  )
  use candidate <- result.try(
    stacks.build(stacks.Candidate) |> result.replace_error("candidate profile"),
  )
  use merged <- result.try(
    diff.merge(base, candidate, diff.Unnormalized)
    |> result.replace_error("merge"),
  )
  use column <- result.try(
    profile.column_named(merged, "samples") |> result.replace_error("column"),
  )
  use layout <- result.try(
    flame.layout(
      merged,
      column,
      flame.Config(..flame.default_config, mode: flame.Differential),
    )
    |> result.replace_error("diff layout"),
  )

  Ok(model.CompareModel(
    baseline_name: "idle-before.pgcap",
    candidate_name: "idle-after.pgcap",
    baseline: provenance_for("22bc9b5", "12 sessions idle 30 min", 12, 10_000),
    candidate: provenance_for("4ed357f", "8 sessions idle 30 min", 8, 10_000),
    rows: [
      model.CompareRow(
        label: "keeper heap capacity",
        kind: measure.Gauge,
        unit: unit.Bytes,
        baseline: Known(181 * mib),
        candidate: Known(4 * mib),
      ),
      model.CompareRow(
        label: "daemon RSS (anon)",
        kind: measure.Gauge,
        unit: unit.Bytes,
        baseline: Known(1751 * mib),
        candidate: Known(1741 * mib),
      ),
      model.CompareRow(
        label: "reductions/s",
        kind: measure.DeltaOverInterval,
        unit: unit.Reductions,
        baseline: Known(41_000),
        candidate: Missing(measure.BudgetExhausted),
      ),
      model.CompareRow(
        label: "process count",
        kind: measure.Gauge,
        unit: unit.Count,
        baseline: Known(3412),
        candidate: Known(2760),
      ),
    ],
    diff: Some(model.DiffFlame(
      profile: merged,
      layout:,
      sources: model.SameSource,
    )),
  ))
}

// ------------------------------------------------------------ audit

/// The audit page's data: allowed requests and two denials.
pub fn audit() -> model.AuditModel {
  model.AuditModel(
    info: info("viewer audit log", "authority gate decisions", 6, 6, "entries"),
    entries: [
      entry(
        now_ms - 4000,
        policy.ConfirmStage,
        "tab-1",
        "start_probe counters",
        policy.Allowed,
      ),
      entry(
        now_ms - 21_000,
        policy.PlanStage,
        "tab-1",
        "start_probe counters",
        policy.Allowed,
      ),
      entry(
        now_ms - 95_000,
        policy.AuthorizeStage,
        "tab-2",
        "targeted_gc",
        policy.Denied(reason: "missing capability: perturb"),
      ),
      entry(
        now_ms - 140_000,
        policy.AuthorizeStage,
        "tab-1",
        "pin_process",
        policy.Allowed,
      ),
      entry(
        now_ms - 190_000,
        policy.AuthorizeStage,
        "tab-1",
        "read_owners",
        policy.Allowed,
      ),
      entry(
        now_ms - 260_000,
        policy.ConfirmStage,
        "tab-2",
        "start_probe sampling",
        policy.Denied(reason: "plan expired"),
      ),
    ],
  )
}

fn entry(
  at_ms: Int,
  stage: policy.Stage,
  principal: String,
  command: String,
  decision: policy.AuditDecision,
) -> policy.AuditEntry {
  policy.AuditEntry(at_ms:, stage:, principal:, command:, decision:)
}

// ------------------------------------------------------------ assembly

/// Every feed a page could need, in one list. A feed that could not be built
/// is left out, so its page shows the waiting state; the error names which.
pub fn feeds() -> List(msg.Feed) {
  let optional = fn(built: Result(a, String), wrap: fn(a) -> msg.Feed) {
    case built {
      Ok(value) -> [wrap(value)]
      Error(_) -> []
    }
  }

  list.flatten([
    [
      msg.FedStrip(strip()),
      msg.FedOverview(overview()),
      msg.FedOwnerMovers(owner_movers()),
      msg.FedOwners(owners()),
      msg.FedProcesses(processes()),
      msg.FedProcessDetail(process_detail()),
      msg.FedMemory(memory()),
      msg.FedSupervision(supervision()),
      msg.FedProbes(probes()),
      msg.FedFlow(flow()),
      msg.FedTimeline(timeline()),
      msg.FedAudit(audit()),
    ],
    optional(profile(), msg.FedProfile),
    optional(compare(), msg.FedCompare),
  ])
}

/// The start arguments for a page.
pub fn start(target: Page, links: Links) -> app.Start {
  app.Start(page: target, links:, feeds: feeds())
}

/// A short description of a byte figure, used by the preview index.
pub fn describe_bytes(n: Int) -> String {
  fmt.bytes(n) <> " (" <> int.to_string(n / gib) <> " GiB whole)"
}

/// The key of the keeper's row, for tests that click it.
pub fn keeper_key() -> Key {
  key.indexed("proc", 1)
}
