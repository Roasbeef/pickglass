//// Tests for what the first end-to-end run left open: the strip after a
//// detach, a request notice that outlives its answer, and the graph frame.

import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import lustre/effect
import lustre/element
import pickglass_core/policy
import pickglass_core/profile/activity
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/state
import pickglass_web/view/owners

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

// "Asked the viewer to ..." is a promise, and the profile feed that answers it clears
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
    |> run(msg.Ui(msg.SubmitDraft("")))

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

// An owner row holds no processes itself, so it opens onto its role rows;
// without a twisty those rows, and the processes under them, cannot be reached.
pub fn an_owner_row_with_roles_can_be_opened_test() {
  let data = fixture.owners()
  let shown =
    element.to_string(owners.view(
      data,
      state.initial(),
      page.Files,
      policy.all_capabilities,
    ))
  let roles = list.count(data.rows, fn(row) { row.kind == model.RoleGroup })

  assert roles > 0
  assert string.contains(shown, "aria-expanded=\"false\"")

  let opened_owner_keys =
    list.filter(data.rows, fn(row) { row.kind == model.OwnerGroup })
    |> list.map(fn(row) { row.key })
  let ui_open =
    state.UiState(..state.initial(), expanded: set.from_list(opened_owner_keys))
  let open =
    element.to_string(owners.view(
      data,
      ui_open,
      page.Files,
      policy.all_capabilities,
    ))

  assert string.contains(open, "aria-expanded=\"true\"")
}

// A request the flow answers (a plan, a refusal, a running probe) clears its
// "Asked the viewer to" notice when the flow is fed, so the page does not go on saying
// it asked after the answer is on the screen.
pub fn the_requested_notice_clears_when_the_flow_is_fed_test() {
  let start = app.Start(page: page.Overview, links: page.Files, feeds: [])
  let run = fn(model, message) {
    app.update(fn(_) { effect.none() }, model, message).0
  }
  let asked = app.init(start) |> run(msg.Ask(msg.ProfileBusiest))

  assert asked.ui.notice == Some(app.describe(msg.ProfileBusiest))
  assert run(asked, msg.Fed(msg.FedFlow(fixture.flow()))).ui.notice == None
}

// Nothing is fed to a detached page but the strip, which says the node is
// gone; that answers the detach request that caused it.
pub fn a_detach_notice_clears_when_the_strip_says_detached_test() {
  let start = app.Start(page: page.Overview, links: page.Files, feeds: [])
  let run = fn(model, message) {
    app.update(fn(_) { effect.none() }, model, message).0
  }
  let asked = app.init(start) |> run(msg.Ask(msg.DetachViewer))
  let detached =
    model.StripModel(..fixture.strip(), source: model.Detached("detached"))

  assert asked.ui.notice == Some(app.describe(msg.DetachViewer))
  assert run(asked, msg.Fed(msg.FedStrip(detached))).ui.notice == None
}
