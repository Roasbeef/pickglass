//// The call graph's zoom: the step logic, and the events that drive it.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/dev/simulate
import lustre/element
import pickglass_web/app
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/wire
import pickglass_web/zoom
import support

fn on_graph() -> simulate.Simulation(app.Model, msg.Msg) {
  support.simulation(on: page.Profile)
  |> simulate.message(msg.Ui(msg.OpenTab(msg.GraphTab)))
}

fn wheel_turn(delta: json.Json) -> List(#(String, json.Json)) {
  [#("deltaY", delta)]
}

fn graph_html(sim: simulate.Simulation(app.Model, msg.Msg)) -> String {
  simulate.model(sim) |> app.view |> element.to_string
}

// ------------------------------------------------------------ step logic

pub fn a_step_moves_to_the_next_size_on_the_list_test() {
  zoom.apply(zoom.Scaled(100), zoom.ZoomIn) |> should.equal(zoom.Scaled(150))
  zoom.apply(zoom.Scaled(100), zoom.ZoomOut) |> should.equal(zoom.Scaled(75))
}

pub fn the_ends_of_the_list_clamp_test() {
  zoom.apply(zoom.Scaled(400), zoom.ZoomIn) |> should.equal(zoom.Scaled(400))
  zoom.apply(zoom.Scaled(25), zoom.ZoomOut) |> should.equal(zoom.Scaled(25))
}

pub fn repeated_steps_visit_every_size_and_stop_test() {
  let up =
    list.fold(list.repeat(Nil, 12), #(zoom.Scaled(25), []), fn(acc, _) {
      let next = zoom.apply(acc.0, zoom.ZoomIn)
      #(next, [next, ..acc.1])
    })

  up.1 |> list.unique |> list.length |> should.equal(7)
  up.0 |> should.equal(zoom.Scaled(400))
}

pub fn fit_leaves_by_the_natural_size_and_returns_on_request_test() {
  zoom.apply(zoom.Fit, zoom.ZoomIn) |> should.equal(zoom.Scaled(100))
  zoom.apply(zoom.Fit, zoom.ZoomOut) |> should.equal(zoom.Scaled(50))
  zoom.apply(zoom.Scaled(200), zoom.ZoomToFit) |> should.equal(zoom.Fit)
  zoom.apply(zoom.Scaled(200), zoom.ZoomActual)
  |> should.equal(zoom.Scaled(100))
}

pub fn a_level_off_the_list_steps_to_its_neighbours_test() {
  zoom.apply(zoom.Scaled(110), zoom.ZoomIn) |> should.equal(zoom.Scaled(150))
  zoom.apply(zoom.Scaled(110), zoom.ZoomOut) |> should.equal(zoom.Scaled(100))
}

pub fn a_scaled_length_is_never_zero_test() {
  zoom.scaled(zoom.Scaled(25), 301) |> should.equal(75)
  zoom.scaled(zoom.Scaled(25), 2) |> should.equal(1)
  zoom.scaled(zoom.Fit, 301) |> should.equal(301)
  zoom.label(zoom.Scaled(150)) |> should.equal("150%")
  zoom.label(zoom.Fit) |> should.equal("Fit")
}

// ------------------------------------------------------------ the decoder

fn run_wheel(value: json.Json) -> Result(zoom.Change, Nil) {
  let data = json.object([#("deltaY", value)]) |> json.to_string
  case json.parse(data, decode.dynamic) {
    Ok(dynamic) -> decode.run(dynamic, wire.wheel_decoder()) |> result_nil
    Error(_) -> Error(Nil)
  }
}

fn result_nil(r: Result(a, b)) -> Result(a, Nil) {
  case r {
    Ok(v) -> Ok(v)
    Error(_) -> Error(Nil)
  }
}

pub fn the_wheel_decoder_reads_the_sign_and_nothing_else_test() {
  run_wheel(json.float(-120.0)) |> should.equal(Ok(zoom.ZoomIn))
  run_wheel(json.int(-1)) |> should.equal(Ok(zoom.ZoomIn))
  run_wheel(json.float(0.5)) |> should.equal(Ok(zoom.ZoomOut))
  run_wheel(json.int(3000)) |> should.equal(Ok(zoom.ZoomOut))
  run_wheel(json.int(0)) |> should.equal(Error(Nil))
  run_wheel(json.string("up")) |> should.equal(Error(Nil))
  run_wheel(json.null()) |> should.equal(Error(Nil))
}

// ------------------------------------------------------------ the page

pub fn the_graph_starts_fitted_with_the_wheel_scrolling_test() {
  let html = graph_html(on_graph())

  string.contains(html, "Fit") |> should.be_true
  string.contains(html, "zoomed") |> should.be_false
  simulate.model(on_graph()).ui.wheel |> should.equal(zoom.WheelScrolls)
}

pub fn the_zoom_buttons_change_the_level_and_the_drawing_test() {
  let in_once =
    on_graph()
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.attribute("title", "Zoom in"),
      )),
    )

  simulate.model(in_once).ui.graph_zoom |> should.equal(zoom.Scaled(100))

  let html = graph_html(in_once)
  string.contains(html, "call-graph zoomed") |> should.be_true
  string.contains(html, "100%") |> should.be_true

  let out_twice =
    in_once
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.attribute("title", "Zoom out"),
      )),
    )

  simulate.model(out_twice).ui.graph_zoom |> should.equal(zoom.Scaled(75))

  let fitted =
    out_twice
    |> simulate.message(msg.Ui(msg.ZoomGraph(zoom.ZoomToFit)))

  simulate.model(fitted).ui.graph_zoom |> should.equal(zoom.Fit)
  string.contains(graph_html(fitted), "call-graph zoomed") |> should.be_false
}

pub fn the_wheel_has_no_handler_until_the_operator_turns_it_on_test() {
  let wheel = query.element(matching: query.class("graph-frame"))

  // With the wheel scrolling there is no handler, so a turn changes nothing
  // and is reported as having no handler.
  let ignored =
    on_graph()
    |> simulate.event(
      on: wheel,
      name: "wheel",
      data: wheel_turn(json.int(-100)),
    )

  simulate.model(ignored).ui.graph_zoom |> should.equal(zoom.Fit)

  simulate.history(ignored)
  |> list.any(fn(entry) {
    case entry {
      simulate.Problem(name: "EventHandlerNotFound", ..) -> True
      _ -> False
    }
  })
  |> should.be_true

  let armed =
    on_graph()
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.text("Wheel zoom"),
      )),
    )

  simulate.model(armed).ui.wheel |> should.equal(zoom.WheelZooms)

  let in_turn =
    armed
    |> simulate.event(
      on: wheel,
      name: "wheel",
      data: wheel_turn(json.int(-100)),
    )

  simulate.model(in_turn).ui.graph_zoom |> should.equal(zoom.Scaled(100))

  let out_turn =
    in_turn
    |> simulate.event(on: wheel, name: "wheel", data: wheel_turn(json.int(100)))

  simulate.model(out_turn).ui.graph_zoom |> should.equal(zoom.Scaled(75))
}

pub fn a_forged_wheel_event_is_dropped_test() {
  let wheel = query.element(matching: query.class("graph-frame"))

  let armed =
    on_graph()
    |> simulate.message(msg.Ui(msg.ToggleWheelZoom))

  let after =
    armed
    |> simulate.event(
      on: wheel,
      name: "wheel",
      data: wheel_turn(json.string("x")),
    )
    |> simulate.event(on: wheel, name: "wheel", data: wheel_turn(json.int(0)))
    |> simulate.event(on: wheel, name: "wheel", data: [])

  simulate.model(after).ui.graph_zoom |> should.equal(zoom.Fit)
}

pub fn turning_the_wheel_off_again_detaches_the_handler_test() {
  let wheel = query.element(matching: query.class("graph-frame"))

  let after =
    on_graph()
    |> simulate.message(msg.Ui(msg.ToggleWheelZoom))
    |> simulate.message(msg.Ui(msg.ToggleWheelZoom))
    |> simulate.event(
      on: wheel,
      name: "wheel",
      data: wheel_turn(json.int(-100)),
    )

  simulate.model(after).ui.wheel |> should.equal(zoom.WheelScrolls)
  simulate.model(after).ui.graph_zoom |> should.equal(zoom.Fit)
}
