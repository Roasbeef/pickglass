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
//// - Requests the viewer cannot act on yet (a self-measure, a stop for a
////   probe it is not tracking, a profile export) are dropped, and the
////   Audit page is where a refusal from the gate shows.
////
//// The application and the feeder are linked to the socket process that
//// started them. `shutdown` stops both when the browser goes away.
////
//// ## Flow
////
//// - `mount` starts the feeder, then the application, registers the frame
////   callback, and hands the application to the feeder with `Attach`.
//// - `feed` rebuilds and sends the page's models.
//// - `ask` resolves one request and submits it.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/effect
import lustre/server_component
import pickglass/feeds
import pickglass/hub
import pickglass/seam
import pickglass_web/app
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page as web_page
import weft/actor

type Message {
  Updated(hub.Update)
  Asked(msg.Request)
  Attach(lustre.Runtime(msg.Msg))
  Stop
}

type State {
  State(
    page: seam.Page,
    slug: feeds.Slug,
    cadence_ms: Int,
    runtime: Option(lustre.Runtime(msg.Msg)),
    sort: model.SortColumn,
    offset: Int,
  )
}

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
  use web <- result.try(
    web_page_of(slug) |> result.replace_error("no such page"),
  )
  use feeder <- result.try(start_feeder(page, feed_slug, cadence_ms))

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
      let state = State(..state, runtime: Some(runtime))

      feed(state)
      actor.continue(state)
    }

    Updated(hub.Observed(_)) | Updated(hub.TargetLost(_)) -> {
      feed(state)
      actor.continue(state)
    }

    Asked(request) -> {
      let state = ask(state, request)

      feed(state)
      actor.continue(state)
    }
  }
}

fn inputs(state: State) -> feeds.Inputs {
  let page = state.page

  feeds.Inputs(
    page:,
    observations: page.latest(),
    pins: page.pins(),
    plans: page.plans(),
    checkpoints: page.checkpoints(),
    entries: case state.slug {
      feeds.Audit -> page.audit(100)
      _ -> []
    },
    cadence_ms: state.cadence_ms,
    sort: state.sort,
    offset: state.offset,
  )
}

fn feed(state: State) -> Nil {
  case state.runtime {
    None -> Nil
    Some(runtime) ->
      feeds.feeds_for(state.slug, inputs(state))
      |> list.each(fn(feed) {
        lustre.send(runtime, lustre.dispatch(msg.Fed(feed)))
      })
  }
}

// ----------------------------------------------------------------- asking

fn ask(state: State, request: msg.Request) -> State {
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
    msg.TakeCheckpoint ->
      submit(
        state,
        seam.Checkpoint(
          "checkpoint-" <> int.to_string(list.length(current.checkpoints) + 1),
        ),
      )

    // Not offered yet: the agent has no self-measure, the viewer tracks no
    // running probe to stop, and the profile and compare pages have no data.
    msg.RequestSelfMeasure(_)
    | msg.StopProbe(_)
    | msg.ChooseBaseline(_)
    | msg.AddFilter(..)
    | msg.TruncateChain(_)
    | msg.ExportProfile(_)
    | msg.AddFilterAt(..)
    | msg.PlanProbeFor(_) -> state
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
