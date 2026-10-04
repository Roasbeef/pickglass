//// Tests for what the first end-to-end run left open: the strip after a
//// detach, a request notice that outlives its answer, and the graph frame.

import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element
import pickglass_core/profile/activity
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page

fn page_html(strip: model.StripModel) -> String {
  let start = app.Start(page: page.Overview, links: page.Files, feeds: [])
  let #(model, _) =
    app.update(
      fn(_) { effect.none() },
      app.init(start),
      msg.Fed(msg.FedStrip(strip)),
    )

  element.to_string(app.view(model))
}

// A node that went away is not attached, so the banner may not say it is.
pub fn a_detached_strip_does_not_say_full_trust_test() {
  let live = page_html(fixture.strip())
  let detached =
    page_html(
      model.StripModel(..fixture.strip(), source: model.Detached("detached")),
    )

  assert string.contains(live, "Attached: full trust")
  assert !string.contains(detached, "full trust")
  assert string.contains(detached, "Detached: no target")
}

// No grant is offered once nothing can be done with it.
pub fn a_detached_banner_lists_no_grants_test() {
  let detached =
    page_html(
      model.StripModel(..fixture.strip(), source: model.Detached("detached")),
    )

  assert !string.contains(detached, "class=\"grant\"")
}

// "Requested: ..." is a promise, and the profile feed that answers it clears
// it. A refusal is not answered by a feed and stays.
pub fn the_requested_notice_clears_when_the_profile_arrives_test() {
  let start = app.Start(page: page.Profile, links: page.Files, feeds: [])
  let run = fn(model, message) {
    app.update(fn(_) { effect.none() }, model, message).0
  }
  let asked =
    app.init(start)
    |> run(msg.Ask(msg.ChooseSamples(activity.IncludeWaiting)))

  assert asked.ui.notice
    == Some(app.describe(msg.ChooseSamples(activity.IncludeWaiting)))

  let assert Ok(profile) = fixture.profile() as "the fixture profile builds"
  let answered = run(asked, msg.Fed(msg.FedProfile(profile)))

  assert answered.ui.notice == None
}

pub fn a_refusal_survives_a_profile_feed_test() {
  let start = app.Start(page: page.Profile, links: page.Files, feeds: [])
  let run = fn(model, message) {
    app.update(fn(_) { effect.none() }, model, message).0
  }
  let refused =
    app.init(start)
    |> run(msg.Ui(msg.SubmitDraft))

  let assert Some(sentence) = refused.ui.notice

  let assert Ok(profile) = fixture.profile() as "the fixture profile builds"
  let after = run(refused, msg.Fed(msg.FedProfile(profile)))

  assert after.ui.notice == Some(sentence)
}

pub fn a_notice_for_another_request_is_not_cleared_by_a_profile_feed_test() {
  let start = app.Start(page: page.Profile, links: page.Files, feeds: [])
  let run = fn(model, message) {
    app.update(fn(_) { effect.none() }, model, message).0
  }
  let asked = app.init(start) |> run(msg.Ask(msg.ProfileBusiest))

  let assert Ok(profile) = fixture.profile() as "the fixture profile builds"
  let after = run(asked, msg.Fed(msg.FedProfile(profile)))

  assert after.ui.notice == Some(app.describe(msg.ProfileBusiest))
}

// The graph frame scrolls, and the page says so beside the graph.
pub fn the_graph_note_says_the_frame_scrolls_test() {
  let model =
    app.init(fixture.start(page.Profile, page.Files))
    |> fn(model) {
      app.update(
        fn(_) { effect.none() },
        model,
        msg.Ui(msg.OpenTab(msg.GraphTab)),
      ).0
    }

  assert string.contains(
    element.to_string(app.view(model)),
    "scroll the frame sideways",
  )
}
