//// Helpers shared by the web tests: simulations, string counting and the
//// fixture models.

import gleam/list
import gleam/string
import lustre/dev/simulate
import lustre/effect
import lustre/element
import pickglass_web/app.{type Model}
import pickglass_web/fixture
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Page}

/// A simulation of the application on a page, with every request handler a
/// no-op, so a test sees the model the request left behind.
pub fn simulation(on target: Page) -> simulate.Simulation(Model, Msg) {
  simulate.application(
    init: fn(start) { #(app.init(start), effect.none()) },
    update: fn(model, message) {
      app.update(fn(_) { effect.none() }, model, message)
    },
    view: app.view,
  )
  |> simulate.start(fixture.start(target, page.Files))
}

/// The page's HTML text.
pub fn html_of(target: Page) -> String {
  element.to_string(app.view(app.init(fixture.start(target, page.Files))))
}

/// How many times `needle` occurs in `text`.
pub fn count(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}
