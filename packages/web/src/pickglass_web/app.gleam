//// The pickglass application: one Lustre application, one page per mount.
////
//// The viewer mounts this as a server component. Each browser tab gets one
//// runtime whose model holds the page it was opened on, the data the viewer
//// has fed it for that page and the operator's view state. The package
//// performs no I/O: `update` returns an effect only to hand a *request* to
//// the function the viewer supplied, and it is the viewer that decides what
//// a request is worth.
////
//// `update` is where the page checks what a browser event claims against what
//// the page actually drew. A handler's message is fixed when the tree is
//// rendered and can arrive after the data moved on, and a socket holder can
//// send any key it likes through a decoder that only checks shape. So every
//// message that names a key is checked against the current data: a row key
//// must belong to a row the page has, a plan key to the pending plan, a
//// checkpoint to the list offered. A key the page never issued is refused
//// with a notice and changes nothing, and no request leaves the page for it.
//// The viewer repeats the check against its own tables; this one stops stale
//// and forged messages from reaching it at all.
////
//// ## Reading order
////
//// `init` builds the model from a `Start`; `update` applies one `Msg`,
//// routing `Fed` to `store`, `Ui` to `ui_event`, and `Ask` to `ask`, which
//// consults `check_request`; `view` draws the shell and the page body.

import gleam/list
import gleam/option.{None, Some}
import gleam/set
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/analysis/pattern
import pickglass_core/policy
import pickglass_web/chart/call_graph
import pickglass_web/chart/flame as flame_chart
import pickglass_web/chart/timeline as timeline_chart
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/msg.{type Feed, type Msg, type Request}
import pickglass_web/page.{type Links, type Page}
import pickglass_web/state.{type UiState}
import pickglass_web/view/audit
import pickglass_web/view/compare
import pickglass_web/view/flow
import pickglass_web/view/memory
import pickglass_web/view/overview
import pickglass_web/view/owners
import pickglass_web/view/probes
import pickglass_web/view/process_detail
import pickglass_web/view/processes
import pickglass_web/view/profile
import pickglass_web/view/shell
import pickglass_web/view/supervision
import pickglass_web/view/timeline
import pickglass_web/view/ui
import pickglass_web/wire

/// Data that may not have arrived yet. A page with `Waiting` data says so,
/// which an empty table would not.
pub type Loadable(a) {
  /// The viewer has not fed this yet.
  Waiting

  /// The viewer's latest feed.
  Ready(a)
}

/// What the viewer gives a new runtime: the page, how to write links, and the
/// first feeds.
pub type Start {
  Start(
    /// The page the tab opened.
    page: Page,
    /// How addresses are written.
    links: Links,
    /// The data available now.
    feeds: List(Feed),
  )
}

/// The runtime's state.
pub type Model {
  Model(
    /// The page this runtime serves.
    page: Page,
    /// How addresses are written.
    links: Links,
    /// The top strip.
    strip: Loadable(model.StripModel),
    /// The overview data.
    overview: Loadable(model.OverviewModel),
    /// The owners that moved most, for the overview.
    movers: Loadable(model.OwnerMovers),
    /// The owners data.
    owners: Loadable(model.OwnersModel),
    /// The processes data.
    processes: Loadable(model.ProcessesModel),
    /// The process detail data.
    process_detail: Loadable(model.ProcessDetailModel),
    /// The memory data.
    memory: Loadable(model.MemoryModel),
    /// The supervision data.
    supervision: Loadable(model.SupervisionModel),
    /// The probes data.
    probes: Loadable(model.ProbesModel),
    /// The profile data.
    profile: Loadable(model.ProfileModel),
    /// The timeline data.
    timeline: Loadable(model.TimelineModel),
    /// The compare data.
    compare: Loadable(model.CompareModel),
    /// The capture files offered on the compare page.
    captures: Loadable(model.CapturesModel),
    /// The audit data.
    audit: Loadable(model.AuditModel),
    /// The one-click profile in flight, drawn above every page but Probes.
    flow: Loadable(model.FlowModel),
    /// The operator's view state.
    ui: UiState,
  )
}

/// Build the application. `on_request` is how the viewer receives a request;
/// the page calls it only for a request that passed `update`'s checks.
pub fn application(
  on_request: fn(Request) -> Effect(Msg),
) -> lustre.App(Start, Model, Msg) {
  lustre.application(
    init: fn(start) { #(init(start), effect.none()) },
    update: fn(model, message) { update(on_request, model, message) },
    view: view,
  )
}

/// The model for a new runtime, with the first feeds stored.
pub fn init(start: Start) -> Model {
  let empty =
    Model(
      page: start.page,
      links: start.links,
      strip: Waiting,
      overview: Waiting,
      movers: Waiting,
      owners: Waiting,
      processes: Waiting,
      process_detail: Waiting,
      memory: Waiting,
      supervision: Waiting,
      probes: Waiting,
      profile: Waiting,
      timeline: Waiting,
      compare: Waiting,
      captures: Waiting,
      audit: Waiting,
      flow: Waiting,
      ui: state.initial(),
    )

  list.fold(start.feeds, empty, store)
}

// ------------------------------------------------------------ update

/// Apply one message. Data from the viewer is stored; a view-state change is
/// applied if the keys it names are on the page; a request is checked and, if
/// it passes, handed to `on_request`.
pub fn update(
  on_request: fn(Request) -> Effect(Msg),
  model: Model,
  message: Msg,
) -> #(Model, Effect(Msg)) {
  case message {
    msg.Fed(feed) -> #(store(model, feed), effect.none())
    msg.Ui(event) -> ui_event(on_request, model, event)
    msg.Ask(request) -> ask(on_request, model, request)
  }
}

// A feed replaces the data for its page and nothing else.
fn store(model: Model, feed: Feed) -> Model {
  case feed {
    msg.FedStrip(data) -> Model(..model, strip: Ready(data))
    msg.FedOverview(data) -> Model(..model, overview: Ready(data))
    msg.FedOwnerMovers(data) -> Model(..model, movers: Ready(data))
    msg.FedOwners(data) -> Model(..model, owners: Ready(data))
    msg.FedProcesses(data) -> Model(..model, processes: Ready(data))
    msg.FedProcessDetail(data) -> Model(..model, process_detail: Ready(data))
    msg.FedMemory(data) -> Model(..model, memory: Ready(data))
    msg.FedSupervision(data) -> Model(..model, supervision: Ready(data))
    msg.FedProbes(data) -> Model(..model, probes: Ready(data))
    msg.FedProfile(data) -> Model(..model, profile: Ready(data))
    msg.FedTimeline(data) -> Model(..model, timeline: Ready(data))
    msg.FedCompare(data) -> Model(..model, compare: Ready(data))
    msg.FedAudit(data) -> Model(..model, audit: Ready(data))
    msg.FedCaptures(data) -> Model(..model, captures: Ready(data))
    msg.FedPlanTarget(target) -> offer_target(model, target)
    msg.FedFlow(data) -> Model(..model, flow: Ready(data))
  }
}

// The viewer suggests a target for the plan form, for instance the process
// whose "Plan probe" was pressed. It is applied only when the form has none
// yet and the target is one the page offers, so a stale suggestion cannot
// replace the operator's own choice.
fn offer_target(model: Model, target: Key) -> Model {
  let draft = model.ui.plan

  case draft.target, target_known(model, target) {
    None, True ->
      Model(
        ..model,
        ui: state.UiState(
          ..model.ui,
          plan: state.PlanDraft(..draft, target: Some(target)),
        ),
      )
    _, _ -> model
  }
}

fn with_ui(model: Model, ui_state: UiState) -> #(Model, Effect(Msg)) {
  #(Model(..model, ui: ui_state), effect.none())
}

fn refuse(model: Model, sentence: String) -> #(Model, Effect(Msg)) {
  with_ui(model, state.UiState(..model.ui, notice: Some(sentence)))
}

fn ui_event(
  on_request: fn(Request) -> Effect(Msg),
  model: Model,
  event: msg.UiEvent,
) -> #(Model, Effect(Msg)) {
  let current = model.ui

  case event {
    msg.OpenTab(tab) ->
      with_ui(model, state.UiState(..current, tab:, notice: None))

    msg.ToggleRow(row) ->
      case owner_key_known(model, row) {
        True ->
          with_ui(
            model,
            state.UiState(..current, expanded: toggle(current.expanded, row)),
          )
        False -> refuse(model, "That row is not on this page.")
      }

    msg.SelectBox(box) ->
      case box_known(model, box) {
        True -> with_ui(model, state.UiState(..current, selected: Some(box)))
        False -> refuse(model, "That box is not in the drawn graph.")
      }

    msg.SelectNode(node) ->
      case node_known(model, node) {
        True -> with_ui(model, state.UiState(..current, selected: Some(node)))
        False -> refuse(model, "That function is not in the drawn graph.")
      }

    msg.SelectReading(item) ->
      case reading_known(model, item) {
        True -> with_ui(model, state.UiState(..current, selected: Some(item)))
        False -> refuse(model, "That reading is not on the timeline.")
      }

    msg.ClearSelection ->
      with_ui(model, state.UiState(..current, selected: None))

    msg.Search(text) -> with_ui(model, state.UiState(..current, search: text))

    msg.DraftKind(kind) ->
      with_ui(
        model,
        state.UiState(..current, plan: state.PlanDraft(..current.plan, kind:)),
      )

    msg.DraftModules(text) ->
      with_ui(
        model,
        state.UiState(
          ..current,
          plan: state.PlanDraft(..current.plan, modules: text),
        ),
      )

    msg.DraftDuration(duration) ->
      with_ui(
        model,
        state.UiState(
          ..current,
          plan: state.PlanDraft(..current.plan, duration:),
        ),
      )

    msg.DraftTarget(target) ->
      case target_known(model, target) {
        True ->
          with_ui(
            model,
            state.UiState(
              ..current,
              plan: state.PlanDraft(..current.plan, target: Some(target)),
            ),
          )
        False -> refuse(model, "That process is not offered as a target.")
      }

    msg.SubmitDraft -> submit_draft(on_request, model)

    msg.FilterKindChosen(kind) ->
      with_ui(
        model,
        state.UiState(
          ..current,
          filter: state.FilterDraft(..current.filter, kind:),
        ),
      )

    msg.FilterPattern(text) ->
      with_ui(
        model,
        state.UiState(
          ..current,
          filter: state.FilterDraft(..current.filter, pattern: text),
        ),
      )

    msg.SubmitFilter -> submit_filter(on_request, model)
  }
}

fn toggle(rows: set.Set(Key), row: Key) -> set.Set(Key) {
  case set.contains(rows, row) {
    True -> set.delete(rows, row)
    False -> set.insert(rows, row)
  }
}

// The plan form becomes a request only when it names a target the page
// offered and module patterns that pass the pattern alphabet. The duration
// and kind are closed types already.
fn submit_draft(
  on_request: fn(Request) -> Effect(Msg),
  model: Model,
) -> #(Model, Effect(Msg)) {
  let draft = model.ui.plan

  case draft.target, wire.module_patterns(draft.modules) {
    None, _ -> refuse(model, "Choose a target process first.")

    Some(_), Error(wire.NoPatterns) ->
      refuse(model, "Enter at least one module pattern.")

    Some(_), Error(wire.TooManyPatterns) ->
      refuse(model, "Too many module patterns for one probe.")

    Some(_), Error(wire.BadPattern(text:)) ->
      refuse(
        model,
        "Module patterns use letters, digits, _, @ and * only; refused: "
          <> text,
      )

    Some(target), Ok(modules) ->
      ask(
        on_request,
        model,
        msg.PlanProbe(msg.ProbeDraft(
          kind: draft.kind,
          targets: [target],
          modules:,
          duration: draft.duration,
        )),
      )
  }
}

// A filter step is sent only if core's pattern compiler accepts the text,
// so the viewer never receives a pattern the analysis would reject.
fn submit_filter(
  on_request: fn(Request) -> Effect(Msg),
  model: Model,
) -> #(Model, Effect(Msg)) {
  let draft = model.ui.filter

  case pattern.compile(draft.pattern) {
    Ok(compiled) ->
      ask(
        on_request,
        model,
        msg.AddFilter(draft.kind, pattern.source(compiled)),
      )
    Error(error) ->
      refuse(model, "Pattern not accepted: " <> pattern_error(error))
  }
}

fn pattern_error(error: pattern.PatternError) -> String {
  case error {
    pattern.NothingToRepeat(pattern:) -> "nothing to repeat in " <> pattern
    pattern.DanglingEscape(pattern:) -> "dangling escape in " <> pattern
    pattern.UnsupportedSyntax(pattern:, text:, ..) ->
      text <> " is not supported in " <> pattern
  }
}

fn ask(
  on_request: fn(Request) -> Effect(Msg),
  model: Model,
  request: Request,
) -> #(Model, Effect(Msg)) {
  case check_request(model, request) {
    Ok(Nil) -> #(
      Model(
        ..model,
        ui: state.UiState(
          ..model.ui,
          last_request: Some(request),
          notice: Some(describe(request)),
        ),
      ),
      on_request(request),
    )
    Error(sentence) -> refuse(model, sentence)
  }
}

/// The sentence shown after a request is sent. It says the request is
/// pending, because the viewer, not the page, decides.
pub fn describe(request: Request) -> String {
  let what = case request {
    msg.RequestPin(_) -> "pin a process"
    msg.RequestUnpin(_) -> "release a pin"
    msg.PlanProbe(_) -> "plan a probe"
    msg.PlanGc(_) -> "plan a targeted collection"
    msg.RequestSelfMeasure(_) -> "ask a process to measure itself"
    msg.ConfirmPlan(_) -> "confirm the plan"
    msg.CancelPlan(_) -> "cancel the plan"
    msg.StopProbe(_) -> "stop a probe"
    msg.ChooseBaseline(_) -> "compare against another baseline"
    msg.ChooseCandidate(_) -> "use a capture as the candidate"
    msg.TakeCheckpoint -> "take a checkpoint"
    msg.SaveCapture -> "save a capture"
    msg.SortProcesses(_) -> "sort the processes"
    msg.MovePage(_) -> "move the window"
    msg.AddFilter(..) -> "add a filter step"
    msg.AddFilterAt(..) -> "add a filter step on the selected function"
    msg.PlanProbeFor(_) -> "open the probe form for this process"
    msg.ProfileOwner(_) -> "plan a profile of this owner's processes"
    msg.ProfileBusiest -> "plan a profile of the busiest processes"
    msg.ProfileProcess(_) -> "plan a profile of this process"
    msg.AdjustProfile(..) -> "plan the profile again with another setting"
    msg.TruncateChain(_) -> "remove filter steps"
    msg.ExportProfile(_) -> "export the profile"
  }

  "Requested: " <> what <> ". The viewer decides whether to allow it."
}

// ------------------------------------------------------------ checks

// A request that names a key must name one the current data holds.
fn check_request(model: Model, request: Request) -> Result(Nil, String) {
  case request {
    msg.RequestPin(row) ->
      require(process_known(model, row), "That process is not on this page.")
    msg.RequestUnpin(pin) ->
      require(pin_known(model, pin), "That pin is not held by this page.")
    msg.PlanGc(pin) ->
      require(pin_known(model, pin), "That pin is not held by this page.")
    msg.RequestSelfMeasure(pin) ->
      require(pin_known(model, pin), "That pin is not held by this page.")
    msg.ConfirmPlan(plan) ->
      require(plan_known(model, plan), "That plan is not the one shown.")
    msg.CancelPlan(plan) ->
      require(plan_known(model, plan), "That plan is not the one shown.")
    msg.StopProbe(probe) ->
      require(probe_known(model, probe), "That probe is not running.")
    msg.ChooseBaseline(choice) ->
      case checkpoint_known(model, choice), capture_known(model, choice) {
        Absent, Absent -> Error("That checkpoint is not offered.")
        _, _ -> Ok(Nil)
      }
    msg.ChooseCandidate(choice) ->
      require(capture_known(model, choice), "That capture is not offered.")
    msg.PlanProbe(draft) -> check_draft(model, draft)
    msg.PlanProbeFor(process) ->
      require(
        process_known(model, process),
        "That process is not on this page.",
      )
    msg.ProfileOwner(owner) ->
      require(
        bool_presence(owner_key_known(model, owner)),
        "That owner is not on this page.",
      )
    msg.ProfileBusiest -> Ok(Nil)
    msg.ProfileProcess(process) ->
      require(
        process_known(model, process),
        "That process is not on this page.",
      )
    msg.AdjustProfile(plan:, ..) ->
      require(plan_known(model, plan), "That plan is not the one shown.")
    msg.AddFilterAt(kind:, frame:) -> check_filter_at(model, kind, frame)
    msg.TruncateChain(from:) -> check_chain_index(model, from)
    msg.TakeCheckpoint -> Ok(Nil)
    msg.SaveCapture -> Ok(Nil)
    msg.SortProcesses(_) -> Ok(Nil)
    msg.MovePage(_) -> Ok(Nil)
    msg.AddFilter(..) -> Ok(Nil)
    msg.ExportProfile(_) -> Ok(Nil)
  }
}

fn require(known: Presence, sentence: String) -> Result(Nil, String) {
  case known {
    Present -> Ok(Nil)
    Absent -> Error(sentence)
  }
}

/// Whether a key is among the keys the page holds.
type Presence {
  Present
  Absent
}

fn present(items: List(a), matches: fn(a) -> Bool) -> Presence {
  case list.find(items, matches) {
    Ok(_) -> Present
    Error(Nil) -> Absent
  }
}

fn check_draft(model: Model, draft: msg.ProbeDraft) -> Result(Nil, String) {
  case list.all(draft.targets, fn(target) { target_known(model, target) }) {
    True -> Ok(Nil)
    False -> Error("A target in that plan is not offered.")
  }
}

// A "focus here" names a key; it passes only when the profile on the page
// draws a function behind it, which is also what the viewer will look up.
fn check_filter_at(
  model: Model,
  kind: msg.FilterKind,
  frame: Key,
) -> Result(Nil, String) {
  case model.profile {
    Ready(data) ->
      case profile.step_at(data, kind, frame) {
        Ok(_) -> Ok(Nil)
        Error(Nil) -> Error("That is not a function in the drawn profile.")
      }
    Waiting -> Error("There is no profile to change.")
  }
}

fn check_chain_index(model: Model, from: Int) -> Result(Nil, String) {
  case model.profile {
    Ready(data) ->
      case from >= 0 && from < list.length(data.chain) {
        True -> Ok(Nil)
        False -> Error("That step is not in the chain.")
      }
    Waiting -> Error("There is no profile to change.")
  }
}

fn process_known(model: Model, row: Key) -> Presence {
  let in_table = case model.processes {
    Ready(data) -> present(data.rows, fn(process) { process.key == row })
    Waiting -> Absent
  }

  let in_owners = case model.owners {
    Ready(data) ->
      present(list.append(data.rows, [data.unknown]), fn(group) {
        present(group.members, fn(process) { process.key == row }) == Present
      })
    Waiting -> Absent
  }

  let is_detail = case model.process_detail {
    Ready(data) -> present([data.key], fn(held) { held == row })
    Waiting -> Absent
  }

  case in_table, in_owners, is_detail {
    Absent, Absent, Absent -> Absent
    _, _, _ -> Present
  }
}

fn pin_known(model: Model, pin: Key) -> Presence {
  case model.process_detail {
    Ready(data) ->
      case data.pin {
        model.Pinned(held) -> present([held], fn(item) { item == pin })
        model.NotPinned -> Absent
      }
    Waiting -> Absent
  }
}

fn bool_presence(known: Bool) -> Presence {
  case known {
    True -> Present
    False -> Absent
  }
}

// The plan the page shows: the Probes page's, or the flow's above any other
// page. Either is the viewer's current pending plan.
fn plan_known(model: Model, plan: Key) -> Presence {
  let on_probes = case model.probes {
    Ready(data) ->
      case data.pending {
        Some(card) -> present([card.key], fn(item) { item == plan })
        None -> Absent
      }
    Waiting -> Absent
  }

  let in_flow = case model.flow {
    Ready(data) ->
      case data.pending {
        Some(card) -> present([card.key], fn(item) { item == plan })
        None -> Absent
      }
    Waiting -> Absent
  }

  case on_probes, in_flow {
    Absent, Absent -> Absent
    _, _ -> Present
  }
}

fn probe_known(model: Model, probe: Key) -> Presence {
  let on_probes = case model.probes {
    Ready(data) -> present(data.active, fn(item) { item.key == probe })
    Waiting -> Absent
  }

  let in_flow = case model.flow {
    Ready(data) -> present(data.running, fn(item) { item.key == probe })
    Waiting -> Absent
  }

  case on_probes, in_flow {
    Absent, Absent -> Absent
    _, _ -> Present
  }
}

fn checkpoint_known(model: Model, checkpoint: Key) -> Presence {
  let offered = case model.overview, model.owners {
    Ready(data), _ -> data.checkpoints
    Waiting, Ready(data) -> data.checkpoints
    Waiting, Waiting -> []
  }

  present(offered, fn(ref) { ref.key == checkpoint })
}

fn capture_known(model: Model, choice: Key) -> Presence {
  case model.captures {
    Ready(data) -> present(data.offers, fn(offer) { offer.key == choice })
    Waiting -> Absent
  }
}

fn target_known(model: Model, target: Key) -> Bool {
  case model.probes {
    Ready(data) -> list.any(data.targets, fn(item) { item.0 == target })
    Waiting -> False
  }
}

fn owner_key_known(model: Model, row: Key) -> Bool {
  case model.owners {
    Ready(data) ->
      list.any(list.append(data.rows, [data.unknown]), fn(group) {
        group.key == row
      })
    Waiting -> False
  }
}

fn box_known(model: Model, box: Key) -> Bool {
  let in_profile = case model.profile {
    Ready(data) ->
      case data.stacks {
        model.HasStacks(layout:, ..) ->
          list.any(layout.boxes, fn(b) { flame_chart.box_key(b) == box })
        model.NoStacks(..) -> False
      }
    Waiting -> False
  }

  let in_diff = case model.compare {
    Ready(data) ->
      case data.diff {
        Some(diff) ->
          list.any(diff.layout.boxes, fn(b) { flame_chart.box_key(b) == box })
        None -> False
      }
    Waiting -> False
  }

  in_profile || in_diff
}

fn reading_known(model: Model, item: Key) -> Bool {
  case model.timeline {
    Ready(data) -> timeline_chart.knows(data.tracks, item)
    Waiting -> False
  }
}

fn node_known(model: Model, node: Key) -> Bool {
  case model.profile {
    Ready(data) -> {
      let in_graph = case data.stacks {
        model.HasStacks(dag: placed, ..) ->
          list.any(placed.nodes, fn(n) {
            call_graph.node_key(n.function) == node
          })
        model.NoStacks(..) -> False
      }

      let in_top =
        list.any(data.top.rows, fn(row) {
          case row.function {
            Some(id) -> call_graph.node_key(id) == node
            None -> False
          }
        })

      in_graph || in_top
    }
    Waiting -> False
  }
}

// ------------------------------------------------------------ view

/// Draw the page: the shell around the body for the page this runtime
/// serves.
pub fn view(model: Model) -> Element(Msg) {
  let body = html.div([], [toast(model.ui), flow_view(model), page_body(model)])

  case model.strip {
    Ready(strip) ->
      shell.view(
        strip:,
        links: model.links,
        current: nav_current(model.page),
        body:,
      )
    Waiting ->
      html.div([attribute.class("app")], [
        html.main([attribute.class("page")], [ui.waiting("Connecting"), body]),
      ])
  }
}

// The detail page belongs to the Processes entry of the navigation.
fn nav_current(current: Page) -> Page {
  case current {
    page.ProcessDetail -> page.Processes
    other -> other
  }
}

fn toast(ui_state: UiState) -> Element(Msg) {
  case ui_state.notice {
    Some(sentence) ->
      html.div(
        [
          attribute.class("toast"),
          attribute.role("status"),
          attribute.data("test-id", "toast"),
        ],
        [element.text(sentence)],
      )
    None -> element.none()
  }
}

// The one-click profile above the page body, once the viewer has fed it.
fn flow_view(model: Model) -> Element(Msg) {
  case model.flow {
    Ready(data) -> flow.view(data, model.links, model.page)
    Waiting -> element.none()
  }
}

fn grants(model: Model) -> List(policy.Capability) {
  case model.strip {
    Ready(strip) -> strip.banner.grants
    Waiting -> []
  }
}

fn page_body(model: Model) -> Element(Msg) {
  case model.page {
    page.Overview ->
      loaded("Overview", model.overview, fn(data) {
        overview.view(
          data,
          case model.movers {
            Ready(movers) -> Some(movers)
            Waiting -> None
          },
          grants(model),
        )
      })
    page.Owners ->
      loaded("Owners", model.owners, fn(data) {
        owners.view(data, model.ui, model.links, grants(model))
      })
    page.Processes ->
      loaded("Processes", model.processes, fn(data) {
        processes.view(data, model.links, grants(model))
      })
    page.ProcessDetail ->
      loaded("Process", model.process_detail, fn(data) {
        process_detail.view(data, grants(model), model.links)
      })
    page.Memory -> loaded("Memory", model.memory, memory.view)
    page.Supervision ->
      loaded("Supervision", model.supervision, fn(data) {
        supervision.view(data, model.links)
      })
    page.Probes ->
      loaded("Probes", model.probes, fn(data) { probes.view(data, model.ui) })
    page.Profile ->
      loaded("Profile", model.profile, fn(data) { profile.view(data, model.ui) })
    page.Timeline ->
      loaded("Timeline", model.timeline, fn(data) {
        timeline.view(data, model.ui)
      })
    page.Compare -> compare_body(model)
    page.Audit -> loaded("Audit", model.audit, audit.view)
  }
}

// The compare page has two parts: the captures on offer, which exist as soon
// as the viewer has a directory to look in, and the comparison, which exists
// once a baseline and a candidate are chosen and read.
fn compare_body(model: Model) -> Element(Msg) {
  case model.captures, model.compare {
    Ready(offers), Ready(data) ->
      html.div([attribute.class("stack")], [
        compare.offers_view(offers),
        compare.view(data),
      ])
    Ready(offers), Waiting ->
      html.div([attribute.class("stack")], [
        compare.offers_view(offers),
        ui.waiting("Compare"),
      ])
    Waiting, Ready(data) -> compare.view(data)
    Waiting, Waiting -> ui.waiting("Compare")
  }
}

fn loaded(
  name: String,
  data: Loadable(a),
  draw: fn(a) -> Element(Msg),
) -> Element(Msg) {
  case data {
    Ready(value) -> draw(value)
    Waiting -> ui.waiting(name)
  }
}
