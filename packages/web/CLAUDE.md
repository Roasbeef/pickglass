# pickglass_web

## Purpose

Every pickglass page as a Lustre view, plus a static preview renderer. The
viewer mounts `app.application` as a server component, feeds it page models
built from core types, and receives *requests* back. The package performs no
I/O: it imports `lustre` and `pickglass_core` and nothing else impure. It
depends on `gleam_erlang` and `gleam_otp` only because Lustre does; no module
here uses them.

## Key Types

`msg.Msg` is closed and has three families. `Fed(Feed)` carries data in and
is built by no handler. `Ui(UiEvent)` changes page-local view state
(`state.UiState`: tab, expanded rows, selection, form drafts). `Ask(Request)`
names a request such as `RequestPin(Key)`, `PlanProbe(ProbeDraft)` or
`ConfirmPlan(Key)`; it carries no authority.

Two requests name a selection or a process and nothing else:
`AddFilterAt(kind, frame)` ("Focus here", "Show from here" on a flame box or
graph node) and `PlanProbeFor(process)` (the detail page's "Plan probe…").
The viewer turns the first into a chain step with `view/profile.step_at`,
which builds an exact-match pattern from the function it holds, so no function
name travels from the browser. `Feed` also has `FedOwnerMovers` (the overview's "largest change by
owner" list), `FedCaptures` (the capture files the compare page offers, chosen
with `ChooseBaseline` and `ChooseCandidate`) and `SaveCapture` is a request that writes the live window to the save directory. `FedPlanTarget` (a pin the
plan form offers first, applied only if it is among the targets). `Ui(SelectReading)`
selects a timeline bar or span.

The one-click profile: `ProfileOwner(Key)`, `ProfileBusiest`,
`ProfileProcess(Key)` and `AdjustProfile(plan, DurationChoice, RateChoice)` are
requests, never commands. The viewer pins and plans; the plan arrives as
`FedFlow(FlowModel)` (pending plan, running stack probes, a recent finished
profile, and why the last button planned nothing). `view/flow` draws it above
every page but Probes and gives a link to the Profile page, because a server
component cannot navigate the browser without more script than the CSP allows.
`PlanCard` has `chosen` and `adjust`; its dialog (`probes.plan_dialog`) is the
same on both pages.

The profile page opens on the samples taken on a scheduler
(`ProfileModel.activity`, `msg.ChooseSamples`) and states the split; with none
running it says every process was waiting and draws no chart. A plan card from a
profile button offers "Trace calls instead" (at most four processes, modules
typed in the plan form's field) and "Sample stacks instead". `TraceProcess`,
`RecordProcess` and `RecordOwner` plan a call trace or a scheduling recording.
`timeline_model` holds the Timeline page's types, including the scheduling and
call timelines that `chart/activity` draws on a time axis of their own, and
`ExportTrace` asks for their Chrome traces.

`key.Key` is the only name a browser event may carry:`key.Key` is the only name a browser event may carry: 1 to 64 characters from
a closed alphabet, issued by the viewer for rows, boxes, nodes, plans and
checkpoints. Pids, module names and function names never travel from the
browser.

`model` holds the page models (`OverviewModel`, `OwnersModel`,
`ProcessesModel`, `ProcessDetailModel`, `MemoryModel`, `SupervisionModel`,
`ProbesModel`, `ProfileModel` with `Stacks`, `TimelineModel`, `CompareModel`,
`AuditModel`) and the shared `PanelInfo` that every data panel renders as its
title-bar line (source, method, interval, coverage, truncation). Readings are
`measure.Measurement`, never `Int`.

`app.Model` holds one `Loadable` per page and the `UiState`. `app.update`
checks every key a message names against the current data before it records a
request or changes a selection.

## Relationships

Depends on `gleam_stdlib`, `lustre` (pinned `== 5.7.1`) and `pickglass_core`
(path dependency). Layout and analysis come from core (`layout/flame`,
`layout/dag`, `analysis/*`); this package only draws them. The viewer
(`pickglass`) will depend on it. `census/owners` turns a census into the
owners model through core's `owner.group_by`, and `build/profile` turns a
profile and a chain into the profile page's model (`NoStacks` where core
refuses a flame).

`chart/*` draws SVG from core layouts: `flame` (flame, icicle, differential),
`call_graph`, `spark`, `timeline`. `view/*` has one module per page and
`view/ui` for the shared panel and cell builders. `wire` builds event
attributes and their total decoders. `priv/pickglass.css` is the whole
stylesheet; it is a static file the viewer serves.

`dev/` is not shipped: `pickglass_web/fixture` (a Loom-like daemon),
`fixture/stacks` (a synthetic profile) and `pickglass_web/preview`
(`gleam run -m pickglass_web/preview -- <out dir>` in this package writes every
page as standalone HTML linking the stylesheet). Fixtures live in `dev/` so
nothing in the release can show invented numbers.

## Traffic

Browser to page: `click` handlers send fixed messages; `change` and `input`
handlers decode `target.value` with `wire.key_decoder`, `code_decoder` or
`text_decoder`, and a failing decoder drops the event. Page to viewer: the
`on_request` function given to `app.application`, called only for a request
that passed `app.update`'s membership check. Viewer to page: `Fed` messages.

## Invariants

- No `unsafe_raw_html`, no `style` attribute, no attribute name, `href`, key
  or class built from target content; colour is a class from a closed set
  (`chart/colour`, `heat-*`), geometry is numeric attributes.
- Every list whose rows carry handlers is keyed by a viewer-issued key.
- A missing value renders as a word through `fmt.cell` (`measure.render`),
  never as zero. An overlapping column is marked and never totalled. The
  `unknown` owner row is always drawn.
- A handler is attached only when the principal holds the capability the
  action needs; the viewer still re-checks.
- Chart element counts are bounded by core's layouts (`max_boxes`, the 80
  node graph); the views add none.
- The profile's root total is not a field: `view/profile.root_total` reads it
  from the first chain step (or the profile), and the header's sampled-stacks
  coverage is written from it, so the two cannot disagree.
- A comparison that blocks a verdict gives no direction anywhere: the figures'
  change is plain ink and the differential flame is one colour
  (`chart/flame.Withheld`).
- A counters probe sends no trace message; `policy.Counting` is its
  perturbation class, its plan says "calls counted", and its history row has
  `n/a` for events and collector reductions.
- A request is only a request: the page says it is pending and never shows
  the outcome as done until the viewer feeds new data.

## Deep Docs

- `docs/design/plan.md`, "Views" and "Authority".
- `docs/design/concept-opus.md` section 7 and `concept-sonnet.md` section 7.
- `docs/lustre.md` sections 2 to 4 and 7.
