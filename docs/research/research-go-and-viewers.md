# Prior art for pickglass: Go performance tooling and non-BEAM trace/profile viewers

Scope: what Go's profiling and tracing tools and the best general trace viewers do, what questions they answer, their data models, their costs, and what pickglass (loom issue #720) should take. Facts marked [src] were checked against a fetched page in this session (URLs in the Sources section). Facts about pprof and the Go runtime now cite a file and line in shallow clones under `research-src/` in the scratchpad (google/pprof `ebaad5f31b4d`, golang/go `6f5c275ebdc4`, sparse). Facts about other tools that were not checked against source are marked [unverified] (previously [kn], prior knowledge): they are likely right but should be verified before relying on an exact name or number. Anything marked [inference] is a design judgment, not a documented fact.

Revision note: sections 1 to 3 were rewritten against source after the first draft. Corrections to the first draft: there is one flame graph, not two (section 1.7); `-normalize` scales the main profile, not the base (1.6); `hide` rewrites stacks and can delete samples (1.4); the Graph view algorithm is specified in 1.8.

## 0. What #720 asks for, in one paragraph

An operator-facing, bounded, authorized inspector that attributes resource use (memory, CPU) to Loom's session, strand, service and restart owner, and supports baseline/candidate capture comparison with labelled provenance (runtime version, build revision, workload, probe configuration). Samples carry timestamp, interval, unit, method, coverage and truncation. Reductions are not CPU seconds. Flame graphs and timelines must state their source (sampled stacks, traced calls, allocation counts, event timestamps). Probes are narrow and owned by a managed task. The first release answers the idle-daemon ownership question.

Go's tooling is relevant for three reasons: its profile data model separates samples, values, locations and labels cleanly; its comparison mode is the closest thing to #720's baseline/candidate view; and its trace tooling (user tasks and regions, flight recorder) is the closest analogue to session attribution.


## 1. `go tool pprof` and `-http`

All paths below are in shallow clones under `research-src/` in the scratchpad: `pprof/` is google/pprof at `ebaad5f31b4d`, `go/` is golang/go at `6f5c275ebdc4` (sparse: src/cmd/trace, src/internal/trace, src/runtime/pprof, src/runtime/trace, src/net/http/pprof). A path like `pprof/internal/graph/graph.go:341` is relative to that directory.

### 1.1 Data model: profile.proto

From `pprof/proto/profile.proto` [src]:

- `sample_type` is a list of `ValueType` (type string plus unit string, both string-table indexes, :104-:105); every sample carries one value per sample type, in order (:119-:120). `default_sample_type` selects which one a viewer shows first (:95). `period_type` is at :84.
- `Label` (:136-:154) has `key`, then at most one of `str` or `num`, and `num_unit` only with `num`. Keys with the `pprof::` prefix are reserved for pprof itself. The unit is an arbitrary string; consumers may treat "bytes", "seconds", "nanoseconds" as measurable units and convert.
- Samples reference locations (stack, leaf first); locations carry one or more `Line` entries (inlined frames expand into several lines of one location), functions and mappings. Strings are interned.

Design points to copy: units travel in the data; several value columns share one stack table; labels are typed key/value pairs per sample; reserved-prefix keys carry viewer state (pprof uses `pprof::base` to mark diff-base samples, see 1.6). Not to copy as pickglass's native format: it cannot express truncation, coverage or collection method per sample [inference].

### 1.2 Sample types (Go runtime profiles)

Verified in `go/src/runtime/pprof/pprof.go` and `go/src/net/http/pprof/pprof.go`:

- `cpu`: sampled at `hz = 100` (`pprof.go:895`, comment at :890 explains the choice). On-CPU only. A second `StartCPUProfile` fails with "cpu profiling already in use" (`pprof.go:904`).
- `heap` / `allocs`: `writeHeapProto(w, p, int64(runtime.MemProfileRate), ...)` at `pprof.go:660`. The default value of `MemProfileRate` is documented at `pprof.go:856`-:859 as "one allocation per MemProfileRate bytes"; the numeric default (512 KiB) was not re-read in this pass [unverified]. Whether the four value types (alloc_objects, alloc_space, inuse_objects, inuse_space) are all emitted was not read line by line [unverified], but `defaultSampleType` is passed in at :660.
- `goroutine`, `threadcreate`, `block`, `mutex`: `block` rate is set by `runtime.SetBlockProfileRate` (`pprof.go:155`), `mutex` by `runtime.SetMutexProfileFraction` (:169).
- Tip also has a `goroutineleak` profile (`net/http/pprof/pprof.go:367`, :374, :355-:361): a newer addition than the author's memory.
- Which profiles carry labels: `goroutine` does (`runtimeProfile.Label` returns the stored label map, `pprof.go:866`; the goroutine profile is fetched with labels at :839-:848 and :1033). The heap profile does not: `stackProfile.Label(i)` returns nil (`pprof.go:426`). `threadcreate` is explicitly wrapped without labels because it has no useful stacks (`pprof.go:760-:768`). So the earlier claim that heap profiles carry no labels is confirmed. CPU profile label emission: the proto encoder writes `tagSample_Label` (`go/src/runtime/pprof/proto.go:94-:99`) and labels are written for samples where present; which profile writers pass them was not traced [unverified for CPU specifically].

### 1.3 Views in `pprof -http`

The menu is in `pprof/internal/driver/html/header.html:6-17` and the routes are in `pprof/internal/driver/webui.go:127-:144` [src]:

- View menu: Top (`/top`), Graph (`/graph`), Flame Graph (`/flamegraph`), Peek (`/peek`), Source (`/source`), Disassemble (`/disasm`). `/` redirects to `flamegraph` (`webui.go:128`).
- There is exactly one flame graph now. `/flamegraph2` and `/flamegraphold` are legacy URLs that 301-redirect to `/flamegraph` (`webui.go:143-:144`). The earlier report's "old and new flame graph" distinction is obsolete in current pprof: the d3 flame graph is gone, and the surviving view is the one implemented in `html/stacks.js` (see 1.7). A TODO mentions renaming "stacks" to "flamegraph" to finish moving off d3 (`pprof/internal/driver/webhtml.go:81`).
- Sample menu (`header.html:21-30`): one entry per sample type, `?si=<type>` in the URL.
- Refine menu (`header.html:36-48`): Focus, Ignore, Hide, Show, Show from, Reset. The menu has no tagfocus or tagignore entries; those are flags and `-tagfocus=` style config only (`driver_focus.go:34-:50`).
- Config menu (`header.html:52-64`): saved named configurations; Download (`webui.go:135-:139` serves `profile.pb.gz` with the merged profile).
- Top: `ui.top` forces `cfg.NodeCount = 500` (`webui.go:367`). For the text `top` and `topproto` formats the CLI default is node count 0, meaning unlimited (`driver.go:211-:213`); all other formats default to 80 (`driver.go:214-:217`), including Graph's `svg`. `cfg.NodeFraction` default 0.005, `EdgeFraction` default 0.001 (`driver/config.go:67-:68`). When `trim` is false (list, proto, raw, callgrind, and the flame graph, which sets `cfg.Trim = false` at `driver/stacks.go:30`), node count, node fraction and edge fraction are all forced to zero (`driver.go:225-:229`).
- Peek is `report.Tree` filtered by a regexp (`driver/commands.go:89`): for each node whose printable name matches, list incoming edges (callers with weights), the node (flat, flat%, sum%, cum, cum%), then outgoing edges (callees with weights) (`pprof/internal/report/report.go:1076-:1140`). Edge weight percentages are relative to the node's `cum`. Inline edges are marked " (inline)". Peek uses the same trimmed graph as Graph, so nodefraction and nodecount also hide rows.
- Source and Disassemble need source files and binaries on the machine running pprof (`report.PrintAssembly`, `report.go:391`); not read deeper.

UI composition [src]: each view calls `ui.makeReport` to build one filtered report from the profile and the current config, then renders it. State lives in query parameters (`?si=`, config params, `p=` pivot in the flame graph, `stacks.js:166-:226`).

### 1.4 Filters

Applied once to the in-memory profile before any view is built, in `applyFocus` (`pprof/internal/driver/driver_focus.go:32-:68`) [src]. All name filters are Go regexps matched against function name and file name of each location (`profile/filter.go:179-:211`).

- `focus`: keep a sample only if at least one of its locations matches focus and none matches ignore (`profile/filter.go:233-:253` `focusedAndNotIgnored`). Samples are dropped, so totals shrink.
- `ignore`: drop samples with any matching location (same function). Ignore wins over focus: it returns false immediately when it meets an ignored location (`filter.go:233-:253`, early return at the ignored location). Totals shrink.
- `hide`: remove matching lines from locations (`l.Line = l.unmatchedLines(hide)`); a location with no remaining lines is dropped from the stack, and a sample left with no locations is removed (`filter.go:42-:46` and the sample loop at :63-:81). The cost of a hidden frame is therefore charged to its caller's frame because the stack is simply shortened. Totals do not change, except samples that lose every frame.
- `show`: the opposite; keep only matching lines; locations with no matches are removed (`filter.go:48-:53`).
- `show_from`: drop all frames above (callers of) the highest matching frame; samples with no match are dropped (`filter.go:91-:120`, with the worked example in the comment at :84-:90). This is a root-trimming operation on the caller side.
- `prune_from`: applied after the others (`driver_focus.go:64-:66`); not read in detail [unverified].
- `tagfocus` / `tagignore` (`driver_focus.go:81-:166`, `profile/filter.go:256-:279`): per-sample predicates. The value is `key=value` or a bare value. A value that parses as a numeric range (`32kb`, `:64kb`, `4mb:`, `12kb:64mb`, `driver_focus.go:168-:222`) is matched against numeric labels with unit conversion; otherwise it is a comma-separated list of regexps matched against `key:value` strings of string labels (all regexps must match some label for the bare form; any regexp must match the given key's values for the `key=` form; `driver_focus.go:125-:166`). `FilterSamplesByTag` keeps samples that are focused and not ignored (`filter.go:256-:279`).
- `tagshow` / `taghide`: select which label keys survive (`FilterTagsByName`, `filter.go:148`), affecting graph nodelets, not sample membership; read only superficially [unverified].
- `warnNoMatches` prints a warning when a filter matched nothing (`driver_focus.go:46-:59`): a UX detail worth copying (a filter that selects nothing is reported rather than showing an empty chart silently).
- Pruning thresholds (`nodefraction`, `edgefraction`, `nodecount`) are covered in section 1.8.

Net: focus/ignore/tagfocus/tagignore/show_from remove samples; hide/show rewrite stacks; `prune_from` and node/edge thresholds are display-side. This matches the earlier distinction but with one correction: hide is also a stack rewrite that can delete samples, not purely a display setting.

### 1.5 Labels and `pprof.Do`

Label sets are stored in a context and goroutine: `Labels`, `WithLabels` (merging with the parent's labels; a same-key label overwrites, `go/src/runtime/pprof/label.go:56`), `Labels` (:99), `SetGoroutineLabels` (`runtime/pprof/runtime.go:41`). `pprof.Do(ctx, labels, f)` is at `runtime/pprof/runtime.go:53` and runs `f` with a copy of the parent context carrying the labels (doc at :46). The goroutine profile stores labels per goroutine (see 1.2), and pprof exposes them as sample labels, filterable with `-tagfocus=key=value`. The graph view draws labels as "nodelets" (section 1.8). The `-tags` command also lists label keys and values; that command was not read [unverified].

Confirmed limit: heap profile samples have no labels (`pprof.go:426`), so session attribution of memory by label is not possible in Go; the BEAM can attribute memory per process directly (section 8).

### 1.6 Comparison: `-base` and `-diff_base`

From `pprof/internal/driver/cli.go:49-:50`, `:174-:182` and `fetch.go:64-:76` [src]:

- `-base` and `-diff_base` are mutually exclusive ("cannot both be specified", `cli.go:176-:178`). Each takes a list of sources.
- Common mechanism (`fetch.go:64-:77`): if `-diff_base`, label every base sample `pprof::base=true`; if `-normalize`, scale the main profile `p` by `sum(base values)/sum(source values)` per sample type (`profile/merge.go:91-:118`; so it is the main profile that is scaled, the opposite of what the earlier draft said; `normalize` without a base is an error, `cli.go:158-:160`); then `pbase.Scale(-1)` and merge base into the main profile (`combineProfiles`). The comparison is plain addition of the negated base: samples with the same stack merge, so values may become negative.
- Percentages: `computeTotal` sums |value| over all samples, except that if any sample carries the `pprof::base` label the total is only over those base samples (`pprof/internal/report/report.go:1310-:1337`, `profile/profile.go:772-:775`). So with `-diff_base` the percentages are relative to the base profile's total; with `-base` they are relative to the total of absolute values of the merged profile (main plus negated base). That is the verified difference between the two flags.
- Negative values: `drop_negative` (`driver/config.go:39`, passed to `graph.Options.DropNegative` at `driver.go:319`) removes nodes with negative flat and cum (`graph.go:556`). The flame graph detects negative stack values and switches to a diff display (`stacks.js:23-:30`; the box rendering draws positive and negative separately, `stacks.js:306-:343` and the `sumpos`/`sumneg` fields).
- Matching key across profiles: stacks merge by location identity after symbolization, and graph nodes by `NodeInfo` (address, line, column, name, file, and optionally objfile). The merge itself normalizes addresses to survive address-space randomization (`profile/merge.go:324`, :387 by grep; not read in detail) [unverified in detail].
- pprof does not check that the two profiles came from comparable builds or workloads beyond a `compatible` check on sample types (`merge.go` `p.compatible(pb)` is called in Normalize; its exact tests were not read) [unverified]. The conclusion stands: pickglass needs its own provenance check.

### 1.7 The flame graph renderer (the only one)

Server side (`pprof/internal/driver/stacks.go:26-:55`, `pprof/internal/report/stacks.go`) [src]:

1. `stackView` builds a report with `CallTree = true` and `Trim = false`, default granularity `filefunctions`. It serializes a `StackSet` as JSON.
2. `StackSet` (`report/stacks.go:30-:80`): `Total`, `Scale` and `Unit`, a list of `Stacks`, and a list of `Sources`. A `Stack` is `{Value, Sources[]}` where `Sources` is an index list (callers first); each sample becomes one stack, starting with a synthesized `root` source (`makeInitialStacks`, `report/stacks.go:106-:184`). Inlined lines are separate entries flagged `Inlined`. Each `StackSource` has a `FullName`, a `UniqueName` (disambiguates same-named functions with `#<function id>`), `Self` (value where it is the leaf), `Color`, and `Places`: all stack slots where it occurs, listing only the outermost occurrence per stack, so recursion is not double counted (`fillPlaces`, `report/stacks.go:186-:198`).
3. Color: `pickColor(packageName(fn.Name))` or the directory for file granularity: a SHA-256 of the package name modulo 2^20 (`report/stacks.go:200-:206`). The client turns the index into an HSL hue by multiplying by the golden ratio, 50% saturation and 80% lightness (`stacks.js:603-:612`). So color encodes package, not value.

Client (`pprof/internal/driver/html/stacks.js`, 638 lines) [src]:

- Constants: row height 20 px, padding 2, minimum box width 4 px, minimum text width 16, font 12 (min 8) (`stacks.js:8-:14`).
- It is a renderer of DOM elements with positions computed in JS, not a d3 layout. The layout is a recursive partition: `renderStacks` groups the places by the next source (`partitionPlaces`), each group is a box whose width is `xscale * (sumpos + sumneg)`; groups whose width is under 4 px are skipped (`renderGroup`, `stacks.js:306-:343`). Child boxes sit one `ROW` below (callees, direction +1) or above (callers, direction -1). A box leaves a gap on its left of width `xscale*|self|` to show its own self time (`stacks.js:324-:328`), which is a distinguishing choice.
- Pivots: the chart is rooted at the selected "pivot" sources (default the synthetic root), drawing callees below and callers above, extended from the classic flame graph "to show callers" (file header comment, `stacks.js:1-:3`). Search with Enter switches the pivot to a regexp (`handleSearchKey`/`switchPivots`, `stacks.js:154-:180`), stored in the `p` URL parameter without a server round trip.
- Diff: if any stack value is negative, `diff = true` and positive and negative contributions are drawn separately with a separator row (`drawSep`, `stacks.js:482-:491`; text via `diffText`, `percentText`).
- Text fitting uses a hidden canvas to measure text and chooses the longest of the `Display` alternatives that fits (`fitText`, `stacks.js:514-:534`; `shortNameList` produces the alternatives).

Takeaway for a Lustre implementation: the data model (stacks as index lists plus per-source `Places`) is small and renders the whole view client-side from one JSON; for a server component the same `StackSet` can be rendered as SVG on the server, with the pivot as model state [inference].

### 1.8 The Graph view (call graph / DAG): reimplementable specification

All of this is verified in the source named at each step.

**Pipeline** (`report.newTrimmedGraph`, `pprof/internal/report/report.go:124-:185`):

1. Build the full graph from the filtered profile with `newGraph(nil)`. Total = sum over nodes of flat? No: `totalValue, _ := g.Nodes.Sum()` (`report.go:134`) gives the sum of flat values of all nodes. `nodeCutoff = |total * NodeFraction|`, `edgeCutoff = |total * EdgeFraction|` (:135-:136). Defaults are 0.005 and 0.001, i.e. nodes below 0.5% of the total and edges below 0.1% are dropped (`driver/config.go:67-:68`).
2. Drop nodes with `|cum| < nodeCutoff` (`getNodesAboveCumCutoff`, `graph.go:778-:786`). The graph is then rebuilt from the samples keeping only the surviving nodes (`rpt.newGraph(nodesKept)`, `report.go:149`), which is how residual edges arise (step 4).
3. Sort nodes for display (`SortNodes(cumSort, visualMode)`, `graph.go:828-:838`). In the visual (dot) mode the sort is `EntropyOrder`.
4. If `NodeCount > 0` (default 80 for graph): first trim low-frequency tags and edges (they affect selection), select the top N nodes (`selectTopNodes`, `graph.go:856-:877`) and rebuild the graph from the samples with only those (`report.go:166-:171`). In visual mode the count includes tag nodelets: for each node in sorted order, add `min(countTags(n), maxNodelets) + 1` to a counter and stop when the counter reaches `NodeCount` (`graph.go:858-:869`). `maxNodelets` is 4.
5. Final step (`report.go:178-:184`): trim low-frequency tags (`trimLowFreqTags`: keep tags with |flat| or |cum| >= cutoff, `graph.go:801-:809`), trim low-frequency edges (`TrimLowFrequencyEdges`: delete edges with |weight| < edgeCutoff and count them, `graph.go:813-:826`), and in visual mode call `RemoveRedundantEdges`.

**Node and edge construction** (`graph.newGraph`, `graph.go:341-:392`):

- One node per distinct `NodeInfo` (address, line, column, name, file; objfile only when requested). Granularity changes what goes in `NodeInfo` (`graph.go:606-:632`; `FindOrInsertNode` also creates a function-level node for line-level nodes, `graph.go:234-:262`).
- For each sample, walk its stack from the root (last location) to the leaf, and for each location from its outermost line to its innermost (`for ni := len(locNodes)-1 ...`). A location entry that maps to no node (not kept) sets `residual = true` and is skipped.
- Cum value is added once per node per sample (`seenNode`), so recursion does not inflate it. An edge from `parent` to `n` is added once per sample (`seenEdge`) with the sample weight, and `parent.AddToEdgeDiv(n, dw, w, residual, ni != len(locNodes)-1)` (`graph.go:359-:381`): the edge is marked `Residual` when it jumps over dropped nodes, and `Inline` when it connects two lines of one location (a call that was inlined). When an edge is merged from several samples, `Residual` is sticky-true, and `Inline` is true only if every contribution was inline (`AddToEdgeDiv`, `graph.go:128-:142`).
- Flat value is added to the leaf node only when the leaf was kept and there is no pending residual (`graph.go:385-:388`). Nodes with zero cum and zero flat are dropped (`selectNodesForGraph`, `graph.go:394-:413`).
- `call_tree` mode (`newTree`, `graph.go:416-:464`) makes a tree rather than a DAG by keying nodes per parent; it applies only to dot and callgrind output (`report.go:131`) and is how a flame graph is derived. Trimming a tree (`TrimTree`, `graph.go:479-:537`) removes a node by reattaching its children to its parent via edges marked residual; the residual edge is inline only if both joined edges were.

**Redundant edge removal** (`graph.go:899-:945`): iterate nodes from the end of the sorted list; for each node, take incoming edges sorted by weight and walk from the lightest. Stop at the first non-residual edge (do not remove edges heavier than a real edge). Remove a residual edge if a path from its source to its destination exists through other edges (BFS backwards along `In` edges). This preserves reachability while removing dotted shortcuts that the surviving nodes already explain.

**Node ordering heuristic for display (`EntropyOrder`)** (`graph.go:1075-:1134`): score = (entropy of incoming edge weights, or +1 if no incoming edges, plus entropy of outgoing edge weights with the node's own flat as an extra share, or +1 if no outgoing) x cum, plus flat. Entropy is Shannon entropy in bits over the fractions of each edge's weight in the total. The effect, as the source comment states, is to penalize nodes that merely pass weight from one caller to one callee, and favor entry nodes, leaves, and branching points when `NodeCount` forces a cut.

**DOT generation** (`ComposeDot`, `graph/dotgraph.go:57-:90`; the SVG comes from running Graphviz `dot -Tsvg` on that text, `driver/webui.go:347-:361`, so a Graphviz install is required):

- Header: `digraph "title" {`, default node style filled with fill `#f8f8f8` (`dotgraph.go:103-:106`), and a legend cluster `cluster_L` made of the report labels.
- Node ids are `N<index+1>` in sorted order (`dotgraph.go:75`). Node label: the name split on `::` and `.` into lines, then `flat (flat%)`, and, only if cum differs, `of cum (cum%)` (`addNode`, `dotgraph.go:141-:172`). Zero flat prints `0`.
- Font size grows with flat share: `8 + ceil(16 * sqrt(|flat| / maxFlat))` points (`dotgraph.go:174-:179`), a square-root scale to emphasize differences. `maxFlat` is the largest |flat| among displayed nodes.
- Color: both border and fill derive from the node's cum fraction `cum/|total|` through `dotColor` (`dotgraph.go:330-:372`): the score is clamped to [-1, 1]; near zero saturation fades to grey (below |0.2| saturation scales linearly); positive scores get `score^(1-0.7)`; positive means red (g reduced), negative green (r reduced); the background variant uses saturation 0.1 and value 0.93, the foreground variant saturation 1.0 and value 0.7. So hotter nodes are redder and, in diffs, regressions are red and improvements green.
- Shape: `box` by default; bold, peripheries and URL are optional attributes.
- Edges (`addEdge`, `dotgraph.go:285-:327`): label is the formatted weight, plus a second line " (inline)" for inline edges. If total is nonzero: Graphviz `weight = 1 + min(|w*100/total|, 100)` (set only if > 1), `penwidth = 1 + min(|w*5/total|, 5)` (only if > 1), and `color` from `dotColor(w/|total|)`. Residual edges are drawn with arrow text "..." in the tooltip and `style="dotted"`, meaning "calls through one or more removed nodes"; inline edges are labelled, not dashed. If the source node has nodelets, `minlen=2` separates children further. Edges are emitted sorted by weight as a layout hint (`edges.Sort()`, `dotgraph.go:84-:86`, `EdgeMap.Sort` at `graph.go:1136`).
- Nodelets (label tags): per node, up to `maxNodelets = 4` tag boxes (`shape=box3d`, font 8) connected by an edge of `weight=100`; for internal nodes (those with outgoing edges) the flat tag values are shown, for leaves the cumulative tag values (`addNodelets`, `dotgraph.go:216-:263`). Numeric tags (such as `bytes`) are collapsed to at most 4 buckets by nearest-value clustering and labelled "1MB..2MB" (`collapsedTags`, `dotgraph.go:399-:455`); a dotted style is used when the cum and flat of a numeric nodelet differ.
- Web page: the SVG is embedded with a node-name table indexed by dot node id so the UI can search and highlight (`webui.go:335-:343`, `html/graph.html`).

**What to reimplement for pickglass.** The DAG construction and trimming (steps 1-5, `seenNode`/`seenEdge` dedupe, residual/inline flags, redundant-edge removal, entropy ordering) are pure functions over `samples -> nodes/edges` and fit the pure Gleam packages. Layout is the expensive part: pprof delegates it to Graphviz. Options for pickglass [inference]: (a) emit DOT and render client side with a WASM Graphviz (adds a dependency); (b) implement a simple layered layout (Sugiyama-style: rank by longest path from roots, order within ranks by barycenter) in Gleam, which is enough for the trimmed graphs of at most about 80 nodes; (c) export DOT text and let the operator render. Because the node cap is 80 by default, option (b) is realistic.

## 2. `net/http/pprof`, `/debug/pprof`, expvar

Verified in `go/src/net/http/pprof/pprof.go` [src]:

- Registered handlers under `/debug/pprof/`: index, `cmdline`, `profile`, `symbol`, `trace`, plus a handler per named profile (`pprof.go:100-:104`, `Handler(name)` at :244). A `GODEBUG=httpmuxgo121` check decides the pattern style (`pprof.go:97`).
- Parameters (documented `pprof.go:30-:38`): `debug=N` (0 binary protobuf, greater than 0 plaintext), `gc=N` on heap (run a GC cycle before profiling when N > 0), `seconds=N` on allocs/block/goroutine/heap/mutex/threadcreate (return a delta profile), `seconds=N` on `profile` (CPU) and `trace` (duration).
- Delta profile: `serveDeltaProfile` (`pprof.go:275-:336`) rejects non-integer or non-positive `seconds`, rejects profiles not in `profileSupportsDelta` (allocs, block, goroutineleak, goroutine, heap, mutex, threadcreate; `pprof.go:353-:361`), rejects `seconds` combined with a non-zero `debug`, and sets a `Content-Disposition` of `<name>-delta`. CPU profile defaults to 30 seconds and trace to 1 second (`pprof.go:142-:143`, :168-:169).
- Write timeouts are extended by the requested duration (`configureWriteDeadline`, `pprof.go:123-:129`), a detail that matters for any long-running probe over HTTP.
- Errors set `X-Go-Pprof: 1` and plain text (`pprof.go:131-:137`).
- The index description of `goroutine` says `debug=2` prints the same format as an unrecovered panic (`pprof.go:367`).
- Security posture: the package registers on `http.DefaultServeMux` at import (header comment). The warning that this is why it should not be exposed publicly is common guidance, but this file's header was not read for it [unverified]; the single-CPU-profile and trace restrictions were checked for CPU (`pprof.go:904` in runtime/pprof) but for the trace case only by the existence of `trace.Start` errors [unverified].
- `expvar` (`/debug/vars`) is not in the sparse clone [unverified]: a JSON object of published variables with no history.

## 3. `go tool trace`

### 3.1 Views and endpoints

From `go/src/cmd/trace/main.go:205-:247` and the help page template `go/src/internal/trace/traceviewer/http.go:69-:235` [src]:

- Main: "View trace by proc" and "View trace by thread", each split into ranges for large traces (`main.go:209-:216`); the `/trace` endpoint is the Chrome trace viewer, `/jsontrace` serves its JSON (`main.go:218-:219`).
- `/goroutines` (Goroutine analysis, grouped by start function) and `/goroutine` (a group). Per goroutine time categories include "Execution time", sync block, syscall execution time, scheduler wait, and others (`cmd/trace/goroutines.go:171-:222` and the description text at :321-:392, including time spent helping the GC).
- Four profile pages rendered as pprof SVG graphs: `/io` (Network blocking), `/block` (Synchronization blocking), `/syscall`, `/sched` (Scheduler latency), each with `?raw=1` to download a pprof profile (`http.go:193-:196`, handlers `main.go:230-:233`). The same four exist per user region (`/regionio` etc., `main.go:236-:239`). These are generated from trace events, not sampled. `go tool trace -pprof=TYPE` (net, sync, syscall, sched) writes them to stdout (`doc.go`).
- `/usertasks`, `/usertask`, `/userregions`, `/userregion` (`main.go:242-:247`), `/mmu` minimum mutator utilization (`main.go:227`, computed by `trace.MutatorUtilizationV2`, `internal/trace/gc.go:55`).

### 3.2 Format

The trace viewer emits Chrome trace event JSON: `traceEvents`, `stackFrames`, `displayTimeUnit`; each event has `name`, `ph`, `s`, `ts`, `dur`, `pid`, `tid`, `id`, `bp`, `sf`/`esf` stack frame indexes, `args`, `cname` (color name) and `cat` (`go/src/internal/trace/traceviewer/format/format.go:16-:35`). Note the `stackFrames` map: the Chrome format can carry a shared frame table, not only repeated strings, which makes it a usable carrier for sampled stacks.

### 3.3 Annotations: tasks, regions, logs

`go/src/runtime/trace/annotation.go` [src]: `NewTask(pctx, taskType)` (:38) returns a context carrying a task, `Task.End`, `Log`/`Logf` (:95, :101), `WithRegion` (:122) and `StartRegion` (:152). The runtime hooks are `userTaskCreate(id, parentID, taskType)`, `userTaskEnd`, `userRegion`, `userLog` (:189-:198). A task has an id and a parent id, so tasks nest across goroutines; regions are per goroutine. The `/usertasks` and `/userregions` pages group them by type [src, `main.go:242-:247`]; the latency histograms and per-task timeline breakdown were not read in the viewer source [unverified].

### 3.4 Flight recorder (Go 1.25)

From the blog (fetched earlier) and `go/src/runtime/trace/flightrecorder.go` [src]:

- `FlightRecorderConfig{MinAge, MaxBytes}` (`flightrecorder.go:156-:176`): `MinAge` is a lower bound on event age in the window (the recorder discards older events promptly but may keep some); `MaxBytes` is an upper bound and takes precedence over `MinAge`, but is documented as a hint, not a guarantee, on both data size and memory overhead. Defaults when zero: 10 MiB and 10 seconds (`flightrecorder.go:53` and `:59`).
- At most one flight recorder may be active at a time, though it can run concurrently with a normal `trace.Start` consumer (`flightrecorder.go:20-:23`).
- Implementation: a ring of raw generations plus an active generation, a mutex around `WriteTo` (`flightrecorder.go:25-:45`).
- Blog figures: a few MB/s, up to about 10 MB/s on busy services (earlier fetch).

### 3.5 Older versus newer trace tooling

The new reader and viewer are `internal/trace` (`go/src/internal/trace`) and `cmd/trace`, which splits by ranges (`main.go:209-:216`). The overhead figure for the new tracer (1-2%) and the old tracer's scaling problems were not re-verified in source [unverified]. Perfetto import of Go traces is not a Go feature [unverified].

## 4. Linux `perf`, flamegraph.pl, differential flame graphs, icicle, off-CPU

[unverified]

- `perf record -F 99 -g -p PID -- sleep 30` samples on-CPU stacks via timer or hardware counters, kernel plus user. Cost is low (a few percent at 99 Hz). `perf script` dumps stacks as text; `stackcollapse-perf.pl` collapses to `frame;frame;frame count` lines; `flamegraph.pl` renders interactive SVG.
- **Collapsed stack format** ("folded stacks"): one line per unique stack, semicolon-joined frames root first, then a space and a count. It is the simplest interchange format in the field, trivially produced from any tracer, and is what eflame and eflambe emit for BEAM [src: search results on eflame and eflambe]. Speedscope and flamegraph.pl both read it.
- **Flame graph semantics**: x axis is the alphabetically sorted population of stacks, not time; width is share of samples; height is stack depth. It answers "where is the cost", not "when". This is the exact caveat #720 asks the UI to state. Misreading it as a timeline is the most common error.
- **Icicle** is the flipped flame graph (root at top), used by pprof's flame view and several others. **Reversed/inverted** (sandwich) views aggregate by leaf function to show the callers of a hot function.
- **Differential flame graph** (Gregg, `difffolded.pl`): fold two profiles, join on stack, produce `stack count_before count_after`; `flamegraph.pl` colors by delta (red growth, blue shrinkage), widths from the after profile. Known limitation noted by Gregg: stacks that vanished in the after profile do not appear, so a red-blue diff hides disappearances; his answer is to render a second flame graph with the profiles swapped, or use the "elided" form showing both. Parca, Pyroscope and speedscope-style tools implement variants. For #720 this is the second diff view to build after a Δ table.
- **Off-CPU analysis** (Gregg): measure time threads spend blocked, with stacks, by tracing scheduler switch events (`perf sched`, `offcputime` from bcc/bpftrace). A flame graph where width is blocked time answers "why is this slow though CPU is idle". It is high-overhead (tracing every context switch) and wall-clock-weighted, so it must be filtered to the interesting threads. BEAM analogue: process wait time in `receive`, mailbox queueing delay and run-queue wait, which the BEAM's tracing (`running`/`in`/`out` events with timestamps, and `receive`/`send` events) can measure for selected processes with similar overhead concerns [inference].
- **Hot/cold and wakeup graphs** link a waker's stack to a wakee's; the BEAM analogue is message-send to receive causality [inference].

### BEAM support

[src: erlang.org BeamAsm doc] `+JPperf true` enables frame pointers and perf support in the JIT; `perf record -- erl +JPperf true` or `perf record --pid $BEAM_PID` work, with `perf inject --jit` for post-processing; with frame pointers on, `perf record --call-graph=fp` gives call graphs through Erlang frames. The fetched page does not mention perf map files or `+JDdump` [src], so do not claim them. This is Linux-only and not available on Darwin where the issue says features are platform-dependent. The consequence: native-code sampling of the BEAM is a separate path from process-level tracing. It sees scheduler threads, not Erlang processes; process identity is not attached to a sample, so it cannot attribute CPU to a session without an extra mapping (for example sampling the `current_function`/`current_stacktrace` of the process a scheduler is running) [inference].

## 5. Trace and profile viewers and continuous profilers

### 5.1 Chrome Trace Event Format

[unverified] JSON: an array (or `{ "traceEvents": [...] }`) of events with fields `name`, `cat`, `ph` (phase), `ts` (microseconds), `dur`, `pid`, `tid`, `args`. Phases: `B`/`E` begin/end duration, `X` complete (with `dur`), `i` instant, `C` counter (args are series values), `M` metadata (thread/process names via `process_name`, `thread_name`), `s`/`t`/`f` flow start/step/finish (arrows between events, with `id`), `b`/`n`/`e` async nestable events with `id`, `O/N/D` object lifecycle. Simple, text, streamable (the closing bracket is optional). Opens in `chrome://tracing`, Perfetto UI, speedscope (partial), and Firefox Profiler via importer. Limits: no native stack/callsite tables (callstacks are repeated strings or a separate `stackFrames` map in the legacy format), no first-class labels, `ts` precision is microseconds.

### 5.2 Perfetto

[unverified] A trace processor (C++ and WASM) plus a web UI at ui.perfetto.dev that runs entirely in the browser. Native format is protobuf `TracePacket` streams (`perfetto.protos.Trace`) with typed data sources (ftrace, process stats, heap profiles, callstack samples, track events); it also imports Chrome JSON, Fuchsia, pprof, simpleperf, perf.data and others. The Trace Processor loads everything into SQLite tables and exposes **PerfettoSQL**: `slice` (spans with ts, dur, name, track_id, parent_id, depth), `thread`, `process`, `thread_track`/`track`, `counter`, `args`, `flow`, `sched`, `stack_profile_callsite`, `cpu_profile_stack_sample`, and so on. The UI is a timeline of **tracks** grouped into process and thread groups, with a query page, pinned tracks, area selection that aggregates (slices by name with count, total, avg; sched; counters), flow arrows, and debug tracks created from a SQL query result. Plugins and "tracks from SQL" let one build a view declaratively.

What is worth stealing:
1. The track model: a trace is a set of tracks, each track a typed time series of slices, counters, instants or flows, grouped under a process/thread-like parent. Process-per-track in a BEAM view is natural.
2. Area selection aggregation: drag a time range across tracks and get a table of aggregated slices. One interaction replaces many dedicated pages.
3. Counter tracks aligned under slices (memory, run queue length, mailbox length under the timeline).
4. Query as an escape hatch: expose a constrained SQL or typed query over a capture. #720 forbids arbitrary evaluation in the daemon; SQL running over an exported capture inside a separate tool (Perfetto) does not touch the daemon, which is a reason to export Chrome JSON/Perfetto rather than build a query engine [inference].
5. Perfetto's capability to import Chrome JSON means a single JSON exporter suffices to get its UI, including SQL, for free.

Cost: the WASM trace processor loads the whole trace into memory in the browser; large traces (hundreds of MB) are heavy. Native Perfetto protobuf export from Gleam is possible but heavier than JSON, and offers typed callstack samples (`cpu_profile_stack_sample`) and heap profile data; not needed at first [inference].

### 5.3 speedscope

[unverified] A single-page app that opens a file and renders three views: **Time Order** (a flame chart: x is time, for sampled or evented profiles), **Left Heavy** (a flame graph with children sorted by weight, same as a classic aggregated flame graph), and **Sandwich** (a table of functions by self and total time; selecting one shows its callers above and callees below, essentially pprof's Peek). It also has an inverted (reverse) call tree view. File formats [unverified]: its own JSON (`.speedscope.json`) with schema `https://www.speedscope.app/file-format-schema.json`, containing a shared `frames` table (name, file, line, col) and a list of `profiles`, each of type `evented` (open/close frame events with timestamps and units) or `sampled` (a list of stacks as frame-index arrays plus per-sample weights, with `startValue`/`endValue` and `unit` in none, nanoseconds, microseconds, milliseconds, seconds, bytes). Imports: Chrome trace/cpuprofile, perf script, pprof, collapsed stacks, Firefox, Instruments, and others, including eflambe output for Erlang/Elixir [src]. It is trivial to emit (a JSON file with two arrays) and gives the three views above for free. Cost: purely client side, local file, no server.

### 5.4 Firefox Profiler

[unverified] profiler.firefox.com, open source; processed profile JSON with columnar tables (`threads`, each with `samples`, `markers`, `stackTable`, `frameTable`, `funcTable`, `stringArray`, `resourceTable`) and shared libs. Views: call tree (inverted option), flame graph, stack chart (time axis), marker chart, marker table, network chart, and a track-based timeline with activity graph. Key UX ideas: samples drawn as a CPU-activity graph where the selected call node's samples are highlighted across the whole timeline (so you see when that function ran, not just how much); range selection with a committed-range breadcrumb stack; transforms (focus function, focus subtree, merge function, drop function, collapse resource, collapse recursion) applied as a visible, reversible chain in the URL, the same idea as pprof's filters but composable and shown as breadcrumbs; compare view for two profiles. It imports several formats (perf, Chrome, dhat, pprof). It is client side and can be hosted locally.

Transform chain in the URL plus breadcrumbs is the best UX answer to pprof's hide/ignore/focus ambiguity and fits Lustre well, because the chain is a list of typed values in the model [inference].

### 5.5 Pyroscope / Grafana Profiles, Parca

[unverified] Continuous profiling: agents sample all the time at low rate and ship profiles to a store; the UI shows a flame graph over a selected time range plus a timeline of total value, with label-based filtering (service, pod, version, custom labels) and **comparison** of two time ranges (diff flame graph) or two label sets. Pyroscope's data model is pprof-compatible profiles plus labels; Grafana Pyroscope stores profile series keyed by label set, queried with a label selector like Prometheus (`{service_name="x", session="y"}`) and a profile type id such as `process_cpu:cpu:nanoseconds:cpu:nanoseconds`. Parca (Polar Signals) stores pprof, adds eBPF whole-system CPU profiling agent, and a "diff" view; its UI is a flame graph with a table and a compare mode between two selections. Common ideas worth taking: (a) a profile type id that carries sample type and unit in one string; (b) label selectors as the only attribution mechanism, which keeps the store schema generic; (c) comparison across **time ranges within one store** and **across label sets** (here: two sessions, or before/after release), which is more general than two files. They are services with storage and an agent, so pickglass should not reimplement them; #720 says production storage of arbitrary dumps is explicitly out of scope. Pyroscope and Parca ingest pprof, so pprof export lets an operator push pickglass captures there if wanted [inference].

## 6. What the BEAM already has (and does not)

Findings from fetched sources and prior knowledge:

- OTP's own tools: `eprof` (time per function via tracing), `fprof` (call-tree profile via trace files, heavy overhead), `cprof` (call counts), and `tprof` (OTP 27+, call count, call time, call memory with a server mode) as cited in #720; `eprof` is documented in OTP 29.1.1 / tools 4.2.3 [src: search result title]. All trace-based; none is sampling.
- `+JPperf true` for Linux perf with the JIT [src], as above. Linux only.
- Third-party flame-graph tools [src from search]: **eflame** (`erlang:trace/3` based, emits collapsed stacks with the pid as the first item), **eflambe** (Stratus3D, generates `brendan_gregg` (default) and `svg` formats, speedscope-loadable output), **Flame On** for Elixir/LiveDashboard (DockYard blog), and **pprof** hex package (v0.1.0) that "serves fprof profiling data in the format expected by pprof visualization tools" for Elixir. There is therefore a precedent for fprof-to-pprof conversion, meaning the pprof proto mapping for BEAM has been done once, at small scale. The pprof hex package is a reference for mapping but is Elixir and v0.1.0, so treat as a design reference, not a dependency [inference].
- Observer Web and LiveDashboard per #720: process/port inspection, call count/duration profiling, flame graphs.
- Not found in these searches: an Erlang tool producing Chrome trace JSON or Perfetto with scheduler tracks. This may be a gap pickglass can fill; absence from a single search is not proof [inference].

## 7. Costs and perturbation, side by side

| Tool | Mechanism | Typical cost | Perturbation note |
|---|---|---|---|
| pprof CPU | SIGPROF at 100 Hz, stack walk | low (about 1-5%) [unverified] | on-CPU only; biased by signal delivery |
| pprof heap | allocation sampling 1 per 512 KiB | low | in-use is as of last GC |
| pprof goroutine debug=2 | stop-the-world snapshot | grows with goroutine count | brief STW |
| block/mutex | event sampling by threshold | adjustable | rate must be enabled first |
| go tool trace | all scheduler events | 1-2% in 1.22+ [unverified] | files tens of MB/s on busy services [src for flight recorder rate] |
| flight recorder | same as trace into ring | same, plus bounded memory | explicit MinAge/MaxBytes |
| perf on-CPU | sampling, kernel+user | low | needs frame pointers |
| off-CPU tracing | every context switch | high | filter to threads of interest |
| BEAM `erlang:trace` call/time | per-call trace messages | high, scales with call rate | per-process, order-of-magnitude slowdown possible with `fprof`; tprof less |

Use this table's last column to ground #720's requirement that the UI show expected scope and cost before starting a probe.

## 8. How the BEAM changes the picture

[inference throughout unless cited]

1. **Attribution is easier for memory, harder for CPU.** In Go, heap profiles aggregate by allocation stack and carry no goroutine or label; the heap is shared. On the BEAM each process has its own heap, so `process_info` gives per-process `memory`, `heap_size`, `total_heap_size`, `message_queue_len`, `reductions` for direct attribution to an owner; this is what #720 wants. Shared state (large binaries, ETS, atoms, code) is not attributed per process and must be shown as separate non-summing columns, as #720 requires.
2. **CPU time is not observable per process.** `reductions` count function calls and BIFs and are roughly proportional to work but not to time (a NIF, a large binary op, or a GC take little or much time per reduction). `erlang:statistics(scheduler_wall_time)` gives per-scheduler utilization (needs `erlang:system_flag(scheduler_wall_time, true)`, a flag with small overhead), and microstate accounting (`msacc`) breaks scheduler time into states (emulator, gc, port, check_io, aux, ...) at low cost [unverified]. Per-process CPU time exists only via tracing the `running`/`in`/`out` events with timestamps for selected processes [unverified]. So attribution to a session of CPU is by tracing a chosen set, or by sampling reductions deltas over time and displaying them as "work counter", not seconds.
3. **No stack sampling of arbitrary processes without cost.** `process_info(Pid, current_stacktrace)` works on any local process and returns the stack at a moment; polling it at an interval is a poor man's sampler (the approach of some Elixir profilers) with known bias: it needs the target to be scheduled out or briefly suspended, and is heavy per call [unverified]. It is safe enough at low rate and low process count, and gives a statistical sample of "where is this process", stated honestly as method = polled current_stacktrace. This is the only route to a sampled flame graph that does not require tracing, and it should be labelled with its coverage and bias.
4. **Process-per-session fits labels naturally.** Go needs context propagation of labels through goroutines. On the BEAM, a process's identity and registered name, its `$ancestors` and `$initial_call` in the process dictionary, plus ownership metadata Loom will provide, give the key for attribution. #720 asks for explicit bounded ownership metadata; this maps to a pprof-label-like set `{session, strand, service, role, restart_owner}` attached at census time, not at sample time. It remains a join against a registry sampled at the same time, and it can go stale if a process is restarted between ownership lookup and sample [inference].
5. **Message flow tracing has no Go analogue.** `erlang:trace` with `send`/`receive` plus `erlang:trace_pattern` lets one record message flow for selected processes; Go has no equivalent for channels. This allows flow arrows (Chrome `s`/`f` events) between processes for a message-flow view, at cost. It should remain narrow and capped, as #720 says.
6. **Scheduling observability is richer.** Run-queue lengths (`statistics(run_queue_lengths)`), per-scheduler wall time, `+scl` etc, `system_monitor` (long_gc, long_schedule, large_heap, busy_port) and `system_profile` give event streams that are rate-limited by thresholds; this is close to Go's trace scheduler-latency profile at lower cost. `long_schedule` and `long_gc` events with thresholds are a good seed for a flight-recorder-style retrospective ring.
7. **GC and memory events.** `erlang:trace` `garbage_collection` events for selected processes carry heap sizes before and after; there is also `gc_minor_start/end` data. This gives GC attribution per process for chosen targets.

## 9. What does not translate

- Go's CPU profiler: signal-based, per-thread, stack of the running goroutine at the instant. The BEAM has no per-process signal sampler; native `perf` sees scheduler threads and, without JIT frame pointers and Linux, nothing useful [src for the perf requirements].
- Heap profile by allocation site. The BEAM does not record the allocating function for terms. `tprof` can count allocated words per traced function (call memory) in OTP 27+, but only for traced functions and with the caveats #720 quotes. A flame graph by allocation is therefore a traced-calls flame graph, not a heap-dominator or sampled graph.
- Block profile with stacks of arbitrary processes. Only traced processes give events; a process waiting in `receive` shows the receive location only via `current_stacktrace` of that process at a moment.
- Retention graph (what keeps this term alive). Go's `pprof` doesn't provide this either (it needs a heap dump viewer); #720 already marks it out of scope.
- Reductions as time. State this in the UI and never convert.
- Goroutine-count style census at stack granularity: `process_info(P, current_stacktrace)` for all processes at once is O(n) with a per-process cost and can be non-atomic; present as a sampled census, which #720 already requires.

## 10. What pickglass should take (ranked)

### 10.1 Build natively in Lustre (server components), in this order

1. **Top table** (pprof Top), generalized: columns are per-sample-type values, flat, cum where a stack exists, plus Δ when a baseline is loaded. For the Observation page this becomes a ranked process/owner table with units and method labels per column. Highest value, lowest cost, and it is the first-release answer to "who owns the memory".
2. **Group-by attribution** (pprof tag breakdown, Pyroscope label selectors, Go goroutine analysis): group any ranked list by `session`, `strand`, `service`, `restart_owner`, `role`, `application`, or `initial_call`, with "unknown" as an explicit group (#720 requires unknown ownership to be visible). This is the BEAM equivalent of `-tagfocus`/`-tags` and the single most Loom-specific view.
3. **Peek / Sandwich** (callers and callees of a selected function or owner) for traced-call and message-flow data.
4. **Flame graph / icicle** native SVG rendering, labelled with its source (traced calls from tprof/eprof-style data, or polled `current_stacktrace`). Show the x-axis caveat on screen: width is share, not time. Include search, a focus-subtree and hide transforms.
5. **Transform chain with breadcrumbs** (Firefox Profiler) as the filter model, replacing pprof's four flag families. Keep focus/ignore (change totals) distinct from hide/show (display only), and show which one is applied.
6. **Timeline with tracks** (Perfetto-style, a restricted version): one track per selected process or owner, counter tracks for run queue, mailbox length, process memory; slices for traced-call or scheduling events, instants for GC and long_schedule events, flows for message sends. Include area-select aggregation. This is a large build, so it comes after the table, group-by and flame graph, and it needs the common-clock and causal-id rules that #720 states.
7. **Capture comparison view**: a two-column Top with Δ and Δ%, a diff flame graph built the Gregg way with a swap toggle so vanished stacks are visible, and a **provenance header** comparing runtime version, build revision, workload, session counts, warmup, durations, probe config and method. When a header field differs, refuse to label the result an improvement and show the mismatch list. This is beyond pprof and is explicitly asked for in #720.
8. **Flight-recorder-style ring** for sampled events with `min_age` and `max_bytes`, plus threshold-triggered retrospective capture (long_gc, long_schedule, mailbox over N, RSS growth while sessions idle). This both bounds memory per #720 and gives operators the "what happened just before" workflow without enabling heavy tracing in advance.

### 10.2 Export, do not reimplement

Ranked by return for effort:

1. **Chrome trace event JSON.** Smallest encoder (a JSON array of objects), opens in Perfetto UI (with SQL) and chrome://tracing. Use `X` slices for traced calls and operations, `C` counters for run queue and memory, `i` instants for GC/long_schedule, `s`/`f` flows for messages, `M` metadata naming processes after owners (`session`, `strand`). Put owner labels in `args`. Gives timeline and query tooling for free.
2. **Collapsed stacks and speedscope JSON.** Collapsed stacks are one line per stack (`frame;frame count`) and match eflame/eflambe, so it interoperates with flamegraph.pl and speedscope; speedscope's native JSON adds units, multiple profiles per file, and `evented` vs `sampled`. Speedscope's Time Order/Left Heavy/Sandwich views are then free for operators who want them. Choose speedscope JSON as the standalone-file export for flame data.
3. **pprof `profile.proto`** (gzipped) with sample types such as `("reductions","count")`, `("alloc_words","count")`, `("memory","bytes")`, labels for `session`, `strand`, `service`, `pid`, and `-diff_base`-compatible stacks. This gets pprof's whole UI, `-diff_base`/`-base`, `-tagfocus`, plus Pyroscope/Parca ingest. Cost: encoding protobuf in Gleam. Mitigation: the needed subset is small (a handful of messages, varints, string table) and can be hand-written with a total decoder for import checks. Do this after JSON exports, because pprof stack semantics need per-sample stacks, and sources like polled stack samples or traced call trees are what produce them [inference].
4. **Pickglass's own versioned capture format** (#720 phase 3: versioned redacted capture export/import) is separate from all of these; it holds the provenance header and sample metadata (timestamp, interval, unit, method, coverage, truncation), and the exports above are derived from it with a documented loss list (for example, pprof cannot carry coverage metadata except as comments or labels). Do not use pprof proto as the native capture format, because it cannot express truncation, method and coverage per sample cleanly [inference].
5. Skip native Perfetto protobuf and Firefox processed-profile JSON unless a user asks; Chrome JSON covers Perfetto, and speedscope covers flame graphs.

### 10.3 How diff and labels map onto BEAM concepts

- **pprof labels to ownership tags.** A "label" is `{key, value}` attached to a process census row: `session`, `strand`, `service`, `role`, `restart_owner`, `os_pid`, `incarnation`. In an exported pprof, these become sample labels so `-tagfocus=session=abc` works in stock pprof.
- **pprof.Do / runtime/trace tasks to Loom's `{session, strand, op, step}`.** Treat session and strand as labels (attribute), and an `op` as a task (span with start, end and a latency histogram). Emit tasks as Chrome `b`/`e` async events with `id`.
- **Sample types to measurement kinds.** `reductions` (count), `memory` (bytes, process), `message_queue_len` (count, gauge), `gc_count`, `heap_alloc_words` (tprof call memory). Each column keeps its unit, method and coverage, as in pprof's `sample_type` and as #720 requires. Never merge two kinds into one total.
- **`-diff_base` to baseline/candidate.** The base profile is the baseline capture; `-normalize` corresponds to normalizing by workload size or session count, but a normalized diff must display its normalization and must not hide a workload mismatch. A diff is only offered when the provenance header passes the comparability check; otherwise show the list of mismatched fields and an explicit "compare anyway, labelled unmatched" option [inference on UX].
- **`?seconds=N` delta profile to idle-window and lifecycle checkpoints.** pprof's built-in delta (start and end snapshots) is the pattern for #720's idle window, session close, worker restart and keeper retirement checkpoints: take labelled snapshots at each checkpoint and offer Δ between any two within one capture.
- **Function identity for matching across builds.** pprof matches by function name; pickglass should match by `{module, function, arity}` and expose the Gleam-to-Erlang name mapping only where debug metadata is reliable (#720); otherwise it matches generated names and says so.

### 10.4 Things to copy from the Go tooling's operational posture

- Live endpoint with explicit `seconds`: every probe has an explicit bounded duration and the UI shows it before starting. Mirror pprof's one-at-a-time CPU profile and trace restriction as "one probe per probe kind per node" (#720's concurrent-probe limit), with a clear error rather than queueing.
- `debug=` levels as response detail levels: summary (aggregates), detail (selected fields), full (never in the browser). The browser gets only aggregates, and the detail level beyond that needs the separate narrow authority #720 describes.
- Security: pprof's lesson is that exposing profile endpoints on a general listener is a recurring incident class. Pickglass's routes must live behind the diagnostic authority and never on a shared default route. This agrees with #720 and Observer Web's cautionary finding in the issue.
- Perturbation reporting is a UX property that pprof lacks and pickglass should include: show measured overhead (trace event rate, collector time, bytes) next to every capture.

## 11. Things to decide next (open questions, not recommendations)

1. Whether polled `current_stacktrace` sampling is acceptable as a "sampled flame graph" source on a production daemon, and at what rate and process cap. Needs measurement on a real Loom daemon (inference; the author did not measure it).
2. Whether `msacc` and `scheduler_wall_time` flags are acceptable for default-on observation. They have small documented overhead, but #720 requires measuring it before choosing defaults.
3. The exact set of tprof and trace-session features available on each supported OTP version; the OTP docs list this and the issue asks for a capability matrix.
4. The pprof proto encoder's cost versus the value of `-diff_base` tooling to operators who already use Go tools. A Parca or Pyroscope user will likely want it; a Loom-only operator is served by the in-UI diff.

## Sources

- Go flight recorder blog (fetched): https://go.dev/blog/flight-recorder
- BeamAsm and perf (fetched): https://www.erlang.org/doc/apps/erts/beamasm.html
- eprof (search result): https://www.erlang.org/doc/apps/tools/eprof.html
- eflambe: https://github.com/Stratus3D/eflambe
- eflame: https://github.com/2600hz/erlang-eflame and https://github.com/benoitc/erlang-eflame
- pprof hex package (fprof to pprof): https://hexdocs.pm/pprof/Pprof.html
- Flame On (Elixir): https://dockyard.com/blog/2022/02/22/profiling-elixir-applications-with-flame-graphs-and-flame-on
- Brendan Gregg, flame graphs: https://www.brendangregg.com/flamegraphs.html
- speedscope: https://github.com/jlfwong/speedscope and https://pkg.go.dev/github.com/jlfwong/speedscope
- Not fetched (cited from prior knowledge): pprof README https://github.com/google/pprof/blob/main/doc/README.md; profile.proto https://github.com/google/pprof/blob/main/proto/profile.proto; Go diagnostics https://go.dev/doc/diagnostics; net/http/pprof https://pkg.go.dev/net/http/pprof; runtime/trace https://pkg.go.dev/runtime/trace; Go 1.22 traces blog https://go.dev/blog/execution-traces-2024; Perfetto docs https://perfetto.dev/docs/; Chrome trace event format spec (Google doc "Trace Event Format"); Firefox Profiler docs https://profiler.firefox.com/docs/; Grafana Pyroscope https://grafana.com/docs/pyroscope/; Parca https://www.parca.dev/docs/; OTP tprof https://www.erlang.org/doc/apps/tools/tprof.html.
- Loom issue #720 body (read via gh api).
