//// What the pages say when "Profile the busiest" is confirmed after some of
//// its processes exited: the notice that names them, and the refusal that
//// offers the button again when none is left.

import fixture
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/feeds
import pickglass/hub
import pickglass/remote
import pickglass/seam
import pickglass/web_mount
import pickglass_core/identity
import pickglass_core/wire
import pickglass_web/key
import pickglass_web/msg
import pickglass_web/replan

fn pid(n: Int) -> String {
  "<0." <> int.to_string(n) <> ".0>"
}

fn serial_of(text: String) -> Int {
  case string.split(text, ".") {
    [_, number, _] ->
      case int.parse(number) {
        Ok(n) -> n
        Error(Nil) -> 0
      }
    _ -> 0
  }
}

// A node of six busy processes, of which those numbered in `dead` exit after
// they are pinned and before the probe starts.
fn agent(
  dead: List(Int),
) -> fn(wire.Request) -> Result(wire.Reply, remote.Failure) {
  let rows =
    list.map(fixture.numbers(6), fn(n) {
      fixture.row(pid(n), 1000 * n, fixture.labelled("session", "s1", "worker"))
    })

  fn(request) {
    case request {
      wire.AskCensus(..) -> Ok(wire.CensusReport(fixture.census(rows)))
      wire.Extended(wire.AskOwnersDetail(..)) -> {
        let census = fixture.census(rows)

        Ok(fixture.owners_detail(
          census.coverage,
          census.rows,
          wire.CensusTotals(list.length(rows), 5000, 0, 0, 100, 1, 1),
        ))
      }
      wire.AskPin(text) -> {
        let assert Ok(token) = identity.pin(fixture.boot(), serial_of(text))

        Ok(wire.Pinned(token, text))
      }
      wire.Extended(wire.AskStartStacks(tokens, _, duration, _, _)) -> {
        let #(gone, live) =
          list.map(tokens, identity.pin_serial)
          |> list.partition(fn(serial) { list.contains(dead, serial) })

        case live {
          [] -> Error(remote.Refusal("stale_pin", "no pin exists"))
          _ ->
            Ok(wire.StacksStarted(
              11,
              list.length(live),
              100,
              duration,
              8000,
              gone,
            ))
        }
      }
      other -> fixture.healthy(other)
    }
  }
}

fn planned_state(dead: List(Int)) -> #(seam.Page, web_mount.State, String) {
  let rig = harness.live(agent(dead), None)
  let page = harness.page(rig, "alice", harness.all)
  let updates = process.new_subject()
  let assert Ok(Nil) = page.subscribe(updates)

  list.each([1, 2], fn(_) {
    hub.tick(rig.hub)
    let _ = process.receive(updates, 1000)
    process.sleep(50)
  })

  let assert Ok(state) = web_mount.new_state(page, "overview", 0)
  let state = web_mount.ask(state, msg.ProfileBusiest)
  let assert [#(plan_id, _)] = page.plans()

  #(page, state, plan_id)
}

pub fn a_survivor_probe_shows_who_was_left_out_and_refuses_nothing_test() {
  let #(page, state, plan_id) = planned_state([2, 5])
  let state = web_mount.ask(state, msg.ConfirmPlan(feeds.plan_key(plan_id)))

  assert web_mount.refusal_of(state) == None
  assert web_mount.again_of(state) == None
  assert web_mount.notice_of(state)
    == Some(
      "2 of 6 selected processes exited before the probe started and were left out: "
      <> pid(5)
      <> ", "
      <> pid(2),
    )

  let assert [record] = page.probes()
  // Left-out processes are named in the plan's order, the busiest first.
  assert record.left_out == [pid(5), pid(2)]
}

pub fn a_new_plan_clears_the_notice_of_the_probe_before_it_test() {
  let #(_, state, plan_id) = planned_state([3])
  let state = web_mount.ask(state, msg.ConfirmPlan(feeds.plan_key(plan_id)))
  let assert Some(_) = web_mount.notice_of(state)

  let state = web_mount.ask(state, msg.ProfileBusiest)

  assert web_mount.notice_of(state) == None
}

pub fn every_process_gone_refuses_in_words_and_offers_the_button_again_test() {
  let #(page, state, plan_id) = planned_state([1, 2, 3, 4, 5, 6])
  let state = web_mount.ask(state, msg.ConfirmPlan(feeds.plan_key(plan_id)))
  let assert Some(refusal) = web_mount.refusal_of(state)

  assert string.starts_with(refusal, "All 6 selected processes exited")
  assert !string.contains(refusal, "stale_pin")
  assert web_mount.again_of(state) == Some(replan.AgainBusiest)
  assert web_mount.notice_of(state) == None
  assert web_mount.refused_starts_of(state) == [refusal]
  assert page.probes() == []
}

// Choosing again plans afresh from the census and the refusal is gone.
pub fn the_offered_button_plans_again_test() {
  let #(page, state, plan_id) = planned_state([1, 2, 3, 4, 5, 6])
  let state = web_mount.ask(state, msg.ConfirmPlan(feeds.plan_key(plan_id)))
  let assert Some(replan.AgainBusiest) = web_mount.again_of(state)
  let state = web_mount.ask(state, msg.ProfileBusiest)

  assert web_mount.refusal_of(state) == None
  assert web_mount.again_of(state) == None
  let assert [_] = page.plans()
}

// A later refusal replaces the all-exited one, and the button goes with it.
pub fn a_different_refusal_drops_the_offered_button_test() {
  let #(_, state, plan_id) = planned_state([1, 2, 3, 4, 5, 6])
  let state = web_mount.ask(state, msg.ConfirmPlan(feeds.plan_key(plan_id)))
  let assert Some(_) = web_mount.again_of(state)
  let state = web_mount.ask(state, msg.ProfileOwner(key.make("unknown")))

  // No process is unclaimed on this node, so the new refusal replaces the old.
  let assert Some(_) = web_mount.refusal_of(state)

  assert web_mount.again_of(state) == None
}
