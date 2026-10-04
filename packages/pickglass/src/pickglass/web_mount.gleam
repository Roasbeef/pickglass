//// Mounting the web package's application for one browser page.
////
//// `pickglass_web/app.application` is a Lustre application that draws a page
//// from models it is fed and answers with requests. This module is the
//// viewer's end of that arrangement, one instance per WebSocket:
////
//// - A **feeder** actor subscribes to the hub through the page's `subscribe`
////   closure and, on every observation, rebuilds the page's models
////   (`feeds`) and sends them to the application as `Fed` messages. It is
////   also where the application's requests arrive.
//// - A request is a `pickglass_web/msg.Request`: it names rows, pins, plans
////   and checkpoints by key. The feeder resolves each key against the
////   viewer's current data, never against a table it kept, and so a key that
////   names nothing now (a process that left the census, a plan that was
////   confirmed) resolves to nothing and no request is made. A key that does
////   resolve becomes a `seam.Request`, which goes through the page's
////   `submit` closure to the gate. The principal is in that closure, fixed
////   when the socket was admitted; nothing in a request can change it.
//// - The feeder also holds what belongs to one browser page and to no one
////   else: the filter chain of the profile page, the exports it asked for,
////   the checkpoint it compares against, and the two capture files chosen on
////   the compare page. Two tabs therefore filter and compare independently
////   over the same probes.
//// - A refusal from the gate is not shown by the page that asked; the Audit
////   page is where it shows.
////
//// The application and the feeder are linked to the socket process that
//// started them. `shutdown` stops both when the browser goes away.
////
//// ## Flow
////
//// - `mount` starts the feeder, then the application, registers the frame
////   callback, and hands the application to the feeder with `Attach`.
//// - `feed` rebuilds and sends the page's models.
//// - `ask` resolves one request and submits it, or changes the feeder's own
////   state (the chain, the baseline, the compared captures).

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/effect
import lustre/server_component
import pickglass/compare_build
import pickglass/feeds
import pickglass/hub
import pickglass/internal/ffi_dist
import pickglass/probe_book
import pickglass/profile_export
import pickglass/seam
import pickglass_core/analysis/transform
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/wire
import pickglass_web/app
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page as web_page
import pickglass_web/view/profile as profile_view
import weft/actor

type Message {
  Updated(hub.Update)
  Asked(msg.Request)
  Attach(lustre.Runtime(msg.Msg))
  Stop
}

/// What the feeder of one browser page holds: the page's closures, the page,
/// and the state that belongs to that page alone.
pub opaque type State {
  State(
    page: seam.Page,
    slug: feeds.Slug,
    cadence_ms: Int,
    runtime: Option(lustre.Runtime(msg.Msg)),
    sort: model.SortColumn,
    offset: Int,
    /// The checkpoint this page compares against, by its index; the newest
    /// when none was chosen or the chosen one is gone.
    baseline: Option(Int),
    /// The profile page's filter chain.
    chain: List(transform.Step),
    /// What the profile page was asked to export, newest first.
    exports: List(model.ExportNote),
    /// The compare page's chosen files and what reading them gave.
    baseline_file: Option(String),
    candidate_file: Option(String),
    compared: Option(Result(model.CompareModel, String)),
    /// The process the detail page was opened on.
    subject: Option(Key),
    /// The newest spawn edges and when they were read. A walk visits every
    /// process, so the page rereads it at most every `supervision_ms`.
    supervision: Option(#(Int, Result(wire.SupervisionSnapshot, String))),
  )
}

/// How old the spawn edges may be before the supervision page rereads them.
const supervision_ms = 10_000

/// How many export notes a page keeps.
const max_exports = 6

/// The mount for the real web application. `cadence_ms` is the hub's, shown
/// in each panel's title bar.
///
/// ## Examples
///
/// ```gleam
/// let mount = web_mount.mount(2000)
/// ```
pub fn mount(cadence_ms: Int) -> seam.Mount {
  fn(page, slug, deliver) { start(page, slug, cadence_ms, deliver) }
}

fn start(
  page: seam.Page,
  slug: String,
  cadence_ms: Int,
  deliver: fn(json.Json) -> Nil,
) -> Result(seam.Running, String) {
  use feed_slug <- result.try(
    feeds.slug_of(slug) |> result.replace_error("no such page"),
  )
  let #(base, subject) = split_subject(slug)

  use web <- result.try(
    web_page_of(base) |> result.replace_error("no such page"),
  )
  use feeder <- result.try(start_feeder(page, feed_slug, subject, cadence_ms))

  let application =
    app.application(fn(request) {
      effect.from(fn(_dispatch) { process.send(feeder, Asked(request)) })
    })

  case
    lustre.start_server_component(
      application,
      app.Start(page: web, links: web_page.Routes, feeds: []),
    )
  {
    Error(_) -> {
      process.send(feeder, Stop)

      Error("the page's application did not start")
    }
    Ok(runtime) -> {
      lustre.send(
        runtime,
        server_component.register_callback(fn(client_message) {
          deliver(server_component.client_message_to_json(client_message))
        }),
      )
      process.send(feeder, Attach(runtime))

      Ok(
        seam.Running(
          forward: fn(text) {
            case json.parse(text, server_component.runtime_message_decoder()) {
              Ok(message) -> lustre.send(runtime, message)
              Error(_) -> Nil
            }
          },
          shutdown: fn() {
            lustre.send(runtime, lustre.shutdown())
            process.send(feeder, Stop)
          },
        ),
      )
    }
  }
}

// The page's route slug, and the key of the process a detail page was opened
// on when the slug carries one (`process-detail:<key>`). A key that is not
// in the key alphabet is no subject, so the page opens on nothing.
fn split_subject(slug: String) -> #(String, Option(Key)) {
  case slug {
    "process-detail:" <> text -> #(
      "process-detail",
      option.from_result(key.parse(text)),
    )
    other -> #(other, None)
  }
}

fn web_page_of(slug: String) -> Result(web_page.Page, Nil) {
  case slug {
    "overview" -> Ok(web_page.Overview)
    "owners" -> Ok(web_page.Owners)
    "processes" -> Ok(web_page.Processes)
    "process-detail" -> Ok(web_page.ProcessDetail)
    "memory" -> Ok(web_page.Memory)
    "supervision" -> Ok(web_page.Supervision)
    "probes" -> Ok(web_page.Probes)
    "profile" -> Ok(web_page.Profile)
    "timeline" -> Ok(web_page.Timeline)
    "compare" -> Ok(web_page.Compare)
    "audit" -> Ok(web_page.Audit)
    _ -> Error(Nil)
  }
}

// The feeder owns the subscription's subject, so it is the process the hub
// monitors; stopping it ends the subscription.
fn start_feeder(
  page: seam.Page,
  slug: feeds.Slug,
  opened: Option(Key),
  cadence_ms: Int,
) -> Result(Subject(Message), String) {
  let builder =
    actor.new_with_initialiser(3000, fn(subject) {
      let updates = process.new_subject()

      use _ <- result.try(page.subscribe(updates))

      actor.initialised(State(
        page:,
        slug:,
        cadence_ms:,
        runtime: None,
        sort: model.ByMemory,
        offset: 0,
        baseline: None,
        chain: [],
        exports: [],
        baseline_file: None,
        candidate_file: None,
        compared: None,
        subject: opened,
        supervision: None,
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(updates, Updated),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(_) ->
      Error("this principal may not observe, or the hub is not running")
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Stop -> actor.stop()

    // The application is up: draw what the hub already holds.
    Attach(runtime) -> {
      actor.continue(feed(State(..state, runtime: Some(runtime))))
    }

    Updated(hub.Observed(_)) | Updated(hub.TargetLost(_)) ->
      actor.continue(feed(state))

    Asked(request) -> actor.continue(feed(ask(state, request)))
  }
}

/// The feeder state of a page, as `mount` starts it. `Error` for a slug no
/// page has.
///
/// ## Examples
///
/// ```gleam
/// web_mount.new_state(page, "profile", 2000)
/// ```
pub fn new_state(
  page: seam.Page,
  slug: String,
  cadence_ms: Int,
) -> Result(State, String) {
  use feed_slug <- result.map(
    feeds.slug_of(slug) |> result.replace_error("no such page"),
  )
  let #(_, subject) = split_subject(slug)

  State(
    page:,
    slug: feed_slug,
    cadence_ms:,
    runtime: None,
    sort: model.ByMemory,
    offset: 0,
    baseline: None,
    chain: [],
    exports: [],
    baseline_file: None,
    candidate_file: None,
    compared: None,
    subject:,
    supervision: None,
  )
}

/// The filter chain the page has built.
pub fn chain_of(state: State) -> List(transform.Step) {
  state.chain
}

/// What the page was asked to export, newest first.
pub fn exports_of(state: State) -> List(model.ExportNote) {
  state.exports
}

/// What reading the two chosen capture files gave, if both are chosen.
pub fn comparison_of(
  state: State,
) -> Option(Result(model.CompareModel, String)) {
  state.compared
}

/// The checkpoint index the page compares against, if it chose one.
pub fn baseline_of(state: State) -> Option(Int) {
  state.baseline
}

/// The feeds the page would be sent now.
pub fn fed(state: State) -> List(msg.Feed) {
  feeds.feeds_for(state.slug, inputs(state))
}

fn inputs(state: State) -> feeds.Inputs {
  let page = state.page

  feeds.Inputs(
    page:,
    observations: page.latest(),
    pins: page.pins(),
    plans: page.plans(),
    marks: page.checkpoints(),
    baseline: state.baseline,
    probes: page.probes(),
    chain: state.chain,
    exports: state.exports,
    comparison: case state.slug {
      feeds.Compare ->
        feeds.Comparison(
          offers: page.captures(),
          baseline: state.baseline_file,
          candidate: state.candidate_file,
          outcome: state.compared,
        )
      _ -> feeds.no_comparison
    },
    now_ms: ffi_dist.system_time_ms(),
    subject: state.subject,
    detail: read_detail(state),
    results: page.results(),
    supervision: option.map(state.supervision, fn(read) { read.1 }),
    entries: case state.slug {
      feeds.Audit -> page.audit(100)
      _ -> []
    },
    cadence_ms: state.cadence_ms,
    sort: state.sort,
    offset: state.offset,
  )
}

// Rebuild and send the page's models. The feeder first refreshes what it
// reads from the agent for this page alone: the spawn edges, which are old
// enough to reread only every few seconds.
fn feed(state: State) -> State {
  let state = refresh(state)

  case state.runtime {
    None -> state
    Some(runtime) -> {
      feeds.feeds_for(state.slug, inputs(state))
      |> list.each(fn(feed) {
        lustre.send(runtime, lustre.dispatch(msg.Fed(feed)))
      })

      state
    }
  }
}

fn refresh(state: State) -> State {
  case state.slug, state.supervision {
    feeds.Supervision, None -> read_supervision(state)
    feeds.Supervision, Some(#(read_at, _)) ->
      case ffi_dist.system_time_ms() - read_at >= supervision_ms {
        True -> read_supervision(state)
        False -> state
      }
    _, _ -> state
  }
}

fn read_supervision(state: State) -> State {
  let outcome = case state.page.submit(seam.ReadSupervision) {
    seam.SupervisionRead(snapshot) -> Ok(snapshot)
    seam.Rejected(reason) -> Error(reason)
    _ -> Error("the viewer did not read the supervision tree")
  }

  State(..state, supervision: Some(#(ffi_dist.system_time_ms(), outcome)))
}

// The agent's detail of the page's process, read when the process is pinned.
// A process that is not pinned has only the census row, and says so.
fn read_detail(state: State) -> Option(Result(wire.ProcessDetail, String)) {
  case state.slug, state.subject, state.page.latest() {
    feeds.ProcessDetail, Some(subject), [newest, ..] ->
      case list.find(feeds.rows_of(newest, 8), fn(row) { row.key == subject }) {
        Ok(row) -> read_pinned(state, row.pid_text)
        Error(Nil) -> None
      }
    _, _, _ -> None
  }
}

fn read_pinned(
  state: State,
  pid_text: String,
) -> Option(Result(wire.ProcessDetail, String)) {
  let pin =
    list.find(state.page.pins(), fn(card) {
      card.pid_text == pid_text && card.status == seam.PinLive
    })

  case pin {
    Error(Nil) -> None
    Ok(card) ->
      Some(case state.page.submit(seam.ReadProcess(card.token)) {
        seam.ProcessRead(detail) -> Ok(detail)
        seam.Rejected(reason) -> Error(reason)
        _ -> Error("the viewer did not read the process")
      })
  }
}

// ----------------------------------------------------------------- asking

/// Apply one request the application sent. A key it names is resolved
/// against the viewer's current data; a request that resolves to nothing
/// changes nothing.
///
/// ## Examples
///
/// ```gleam
/// web_mount.ask(state, msg.AddFilter(msg.FocusFilter, "lists"))
/// ```
pub fn ask(state: State, request: msg.Request) -> State {
  let current = inputs(state)

  case request {
    msg.SortProcesses(column) -> State(..state, sort: column, offset: 0)
    msg.MovePage(step) -> State(..state, offset: moved(state.offset, step))

    msg.RequestPin(row) ->
      submit_with(state, resolve_row(current, row), seam.PinProcess)
    msg.RequestUnpin(pin) ->
      submit_with(state, resolve_pin(current, pin), seam.UnpinProcess)
    msg.PlanGc(pin) ->
      submit_with(state, resolve_pin(current, pin), seam.PlanTargetedGc)
    msg.ConfirmPlan(plan) ->
      submit_with(state, resolve_plan(current, plan), seam.ConfirmPlan)
    msg.CancelPlan(plan) ->
      submit_with(state, resolve_plan(current, plan), seam.CancelPlan)
    msg.PlanProbe(draft) -> {
      case resolve_targets(current, draft.targets) {
        Ok(targets) ->
          submit(
            state,
            seam.PlanProbe(
              kind: draft.kind,
              targets:,
              modules: draft.modules,
              duration_ms: msg.duration_ms(draft.duration),
            ),
          )
        Error(Nil) -> state
      }
    }

    // A new checkpoint becomes what the page compares against.
    msg.TakeCheckpoint ->
      State(
        ..submit(
          state,
          seam.Checkpoint(
            "checkpoint-" <> int.to_string(list.length(current.marks) + 1),
          ),
        ),
        baseline: None,
      )

    msg.SaveCapture -> submit(state, seam.SaveCapture)
    msg.ChooseBaseline(choice) -> choose_baseline(state, current, choice)
    msg.ChooseCandidate(choice) -> choose_candidate(state, current, choice)

    msg.StopProbe(probe) ->
      case resolve_running(current, probe) {
        Ok(id) -> submit(state, seam.StopProbe(id))
        Error(Nil) -> state
      }

    // The detail page's "Plan probe": a process needs a live pin before a
    // probe can name it. The pin is issued here, and the Probes page offers
    // the newest live pin as its first target.
    msg.PlanProbeFor(row) -> pin_for_probe(state, current, row)

    msg.AddFilter(kind, pattern) -> add_step(state, step_of(kind, pattern))
    msg.AddFilterAt(kind, frame) -> add_step_at(state, current, kind, frame)
    msg.TruncateChain(from) ->
      State(..state, chain: list.take(state.chain, int.max(0, from)))
    msg.ExportProfile(choice) -> export_profile(state, current, choice)

    msg.RequestSelfMeasure(pin) ->
      submit_with(state, resolve_pin(current, pin), seam.PlanSelfMeasure)
  }
}

fn moved(offset: Int, step: msg.PageStep) -> Int {
  case step {
    msg.FirstPage -> 0
    msg.PreviousPage -> int.max(0, offset - feeds.window_size)
    msg.NextPage -> offset + feeds.window_size
  }
}

fn submit_with(
  state: State,
  resolved: Result(String, Nil),
  make: fn(String) -> seam.Request,
) -> State {
  case resolved {
    Ok(text) -> submit(state, make(text))
    Error(Nil) -> state
  }
}

fn submit(state: State, request: seam.Request) -> State {
  let _ = state.page.submit(request)

  state
}

// A row key names a process in the newest census, or nothing.
fn resolve_row(current: feeds.Inputs, row: Key) -> Result(String, Nil) {
  case current.observations {
    [] -> Error(Nil)
    [newest, ..] ->
      feeds.rows_of(newest, 8)
      |> list.find(fn(candidate) { candidate.key == row })
      |> result.map(fn(candidate) { candidate.pid_text })
  }
}

fn resolve_pin(current: feeds.Inputs, wanted: Key) -> Result(String, Nil) {
  current.pins
  |> list.find(fn(pin) { feeds.pin_key(pin.token) == wanted })
  |> result.map(fn(pin) { pin.token })
}

fn resolve_plan(current: feeds.Inputs, wanted: Key) -> Result(String, Nil) {
  current.plans
  |> list.find(fn(entry) { feeds.plan_key(entry.0) == wanted })
  |> result.map(fn(entry) { entry.0 })
}

fn resolve_targets(
  current: feeds.Inputs,
  wanted: List(Key),
) -> Result(List(String), Nil) {
  wanted
  |> list.map(fn(target) { resolve_pin(current, target) })
  |> result.all
}

// ---------------------------------------------------------- the profile page

// The chain step a filter form describes. The pattern was compiled by the
// page before it was sent, and `transform.apply` compiles it again, so a
// pattern core refuses never reaches a profile.
fn step_of(kind: msg.FilterKind, pattern: String) -> transform.Step {
  case kind {
    msg.FocusFilter -> transform.Focus(pattern:)
    msg.IgnoreFilter -> transform.Ignore(pattern:)
    msg.ShowFromFilter -> transform.ShowFrom(pattern:)
    msg.HideFilter -> transform.Hide(pattern:)
    msg.ShowFilter -> transform.Show(pattern:)
  }
}

// A step is added only if the chain with it applies; a chain core refuses is
// left as it was, so the page never loses the profile it was showing.
fn add_step(state: State, step: transform.Step) -> State {
  let chain = list.append(state.chain, [step])

  case list.length(chain) <= feeds.max_chain {
    False -> state
    True ->
      case feeds.profile_model(inputs_with(state, chain), chain) {
        Ok(_) -> State(..state, chain:)
        Error(_) -> state
      }
  }
}

fn inputs_with(state: State, chain: List(transform.Step)) -> feeds.Inputs {
  feeds.Inputs(..inputs(state), chain:)
}

// "Focus here" names a box or a node by key. The step is built from the
// function the viewer's own model of the page draws behind that key, so no
// function name travels from the browser.
fn add_step_at(
  state: State,
  current: feeds.Inputs,
  kind: msg.FilterKind,
  frame: Key,
) -> State {
  case feeds.profile_model(current, state.chain) {
    Ok(Some(drawn)) ->
      case profile_view.step_at(drawn, kind, frame) {
        Ok(step) -> add_step(state, step)
        Error(Nil) -> state
      }
    Ok(None) | Error(_) -> state
  }
}

fn export_profile(
  state: State,
  current: feeds.Inputs,
  choice: msg.ExportChoice,
) -> State {
  case
    feeds.profile_model(current, state.chain),
    probe_book.latest_profiled(current.probes)
  {
    Ok(Some(drawn)), Ok(#(probe, _)) -> {
      let span = case probe.state {
        probe_book.Finished(cost:, ..) ->
          option.unwrap(measure_to_option(cost.wall_ms), 0)
        probe_book.Running -> 0
      }

      case
        profile_export.make(
          choice,
          "probe-" <> probe.id,
          span,
          drawn.profile,
          drawn.column,
        )
      {
        Error(profile_export.Refused(label:, reason:)) ->
          noted(state, model.ExportRefused(label:, reason:))
        Ok(built) ->
          case
            state.page.submit(seam.ExportProfile(
              probe.id,
              format_of(choice),
              built.download,
            ))
          {
            seam.DownloadReady(ticket) ->
              noted(
                state,
                model.ExportReady(
                  label: built.label,
                  ticket: key.make(ticket),
                  losses: built.losses,
                ),
              )
            seam.Rejected(reason) ->
              noted(state, model.ExportRefused(label: built.label, reason:))
            _ ->
              noted(
                state,
                model.ExportRefused(
                  label: built.label,
                  reason: "the viewer did not offer a download",
                ),
              )
          }
      }
    }
    _, _ -> state
  }
}

fn measure_to_option(reading: measure.Measurement) -> Option(Int) {
  measure.to_option(reading)
}

fn format_of(choice: msg.ExportChoice) -> policy.ExportFormat {
  case choice {
    msg.AsCollapsed -> policy.CollapsedStacks
    msg.AsSpeedscope -> policy.Speedscope
    msg.AsChromeTrace -> policy.ChromeTrace
  }
}

fn noted(state: State, note: model.ExportNote) -> State {
  State(..state, exports: list.take([note, ..state.exports], max_exports))
}

// A key names a probe that is running now, or nothing.
fn resolve_running(current: feeds.Inputs, wanted: Key) -> Result(String, Nil) {
  current.probes
  |> list.filter(probe_book.is_running)
  |> list.find(fn(probe) { feeds.probe_key(probe.id) == wanted })
  |> result.map(fn(probe) { probe.id })
}

fn pin_for_probe(state: State, current: feeds.Inputs, row: Key) -> State {
  case resolve_row(current, row) {
    Error(Nil) -> state
    Ok(pid_text) ->
      case
        list.any(current.pins, fn(pin) {
          pin.pid_text == pid_text && pin.status == seam.PinLive
        })
      {
        True -> state
        False -> submit(state, seam.PinProcess(pid_text))
      }
  }
}

// -------------------------------------------------------- baselines, captures

// A key is a checkpoint's, or a capture file's. Checkpoints change what the
// owners and overview pages compare against; a capture file becomes the
// baseline of the compare page.
fn choose_baseline(state: State, current: feeds.Inputs, choice: Key) -> State {
  case
    list.index_map(current.marks, fn(_, index) { index })
    |> list.find(fn(index) { feeds.checkpoint_key(index) == choice })
  {
    Ok(index) -> State(..state, baseline: Some(index))
    Error(Nil) ->
      case resolve_capture(current, choice) {
        Ok(name) -> compare_files(State(..state, baseline_file: Some(name)))
        Error(Nil) -> state
      }
  }
}

fn choose_candidate(state: State, current: feeds.Inputs, choice: Key) -> State {
  case resolve_capture(current, choice) {
    Ok(name) -> compare_files(State(..state, candidate_file: Some(name)))
    Error(Nil) -> state
  }
}

fn resolve_capture(current: feeds.Inputs, wanted: Key) -> Result(String, Nil) {
  state_offers(current)
  |> list.find(fn(name) { feeds.capture_key(name) == wanted })
}

fn state_offers(current: feeds.Inputs) -> List(String) {
  current.comparison.offers
}

// Both files are read when both are chosen, and the outcome is kept, a
// failure with its reason, so the page can say what went wrong.
fn compare_files(state: State) -> State {
  case state.baseline_file, state.candidate_file {
    Some(first), Some(second) ->
      State(
        ..state,
        compared: Some({
          use before <- result.try(state.page.read_capture(first))
          use after <- result.try(state.page.read_capture(second))

          compare_build.build(first, before, second, after)
        }),
      )
    _, _ -> State(..state, compared: None)
  }
}
