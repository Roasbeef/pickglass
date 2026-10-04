//// The profile buttons resolved against the viewer's data: which processes
//// a key names, what is chosen when there are more than the agent takes,
//// and what is said when nothing can be profiled.

import fixture
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/feeds
import pickglass/hub
import pickglass/profile_scope.{Candidate}
import pickglass/remote
import pickglass/seam
import pickglass/web_mount
import pickglass_core/identity
import pickglass_core/policy
import pickglass_core/wire
import pickglass_web/key
import pickglass_web/msg

fn pid(n: Int) -> String {
  "<0." <> int.to_string(n) <> ".0>"
}

fn agent(
  rows: List(wire.ProcessRow),
) -> fn(wire.Request) -> Result(wire.Reply, remote.Failure) {
  fn(request) {
    case request {
      wire.AskCensus(..) -> Ok(wire.CensusReport(fixture.census(rows)))
      wire.Extended(wire.AskOwners(..)) -> {
        let census = fixture.census(rows)

        Ok(
          wire.OwnersReport(wire.OwnersSnapshot(
            coverage: census.coverage,
            rows: census.rows,
            owners: [],
            totals: wire.CensusTotals(list.length(rows), 5000, 0, 0, 100, 1, 1),
          )),
        )
      }
      wire.AskPin(text) -> {
        let serial = case string.split(text, ".") {
          [_, number, _] -> result_or_zero(int.parse(number))
          _ -> 0
        }
        let assert Ok(token) = identity.pin(fixture.boot(), serial)

        Ok(wire.Pinned(token, text))
      }
      other -> fixture.healthy(other)
    }
  }
}

fn result_or_zero(parsed: Result(Int, Nil)) -> Int {
  case parsed {
    Ok(n) -> n
    Error(Nil) -> 0
  }
}

fn session(n: Int) -> wire.ProcessRow {
  fixture.row(pid(n), 1000 * n, fixture.labelled("session", "s1", "worker"))
}

fn stray(n: Int) -> wire.ProcessRow {
  fixture.row(pid(n), 1000 * n, wire.Unlabelled)
}

// A page over a rig whose hub has taken two passes of `rows`.
fn page_over(rows: List(wire.ProcessRow)) -> #(harness.Rig, seam.Page) {
  let rig = harness.live(agent(rows), None)
  let page = harness.page(rig, "alice", harness.all)
  let updates = process.new_subject()
  let assert Ok(Nil) = page.subscribe(updates)

  list.each([1, 2], fn(_) {
    hub.tick(rig.hub)
    let _ = process.receive(updates, 1000)
    process.sleep(50)
  })

  #(rig, page)
}

fn on(page: seam.Page, slug: String) -> web_mount.State {
  let assert Ok(state) = web_mount.new_state(page, slug, 0)

  state
}

fn targets(page: seam.Page) -> Int {
  let assert [#(_, plan)] = page.plans()
  let assert policy.StartProbe(spec:) = policy.plan_command(plan)

  list.length(spec.targets)
}

pub fn an_owner_row_plans_a_profile_of_its_processes_test() {
  let #(_, page) = page_over([session(1), session(2), stray(3)])
  let state =
    web_mount.ask(
      on(page, "owners"),
      msg.ProfileOwner(key.make("owner:session:s1")),
    )

  assert targets(page) == 2
  assert web_mount.refusal_of(state) == None

  let assert [note] = page.profile_notes()
  assert note.chosen == "all 2 listed processes of session:s1"
  assert note.method == seam.ByStacks(seam.profile_rate_hz)
  assert note.duration_ms == seam.profile_duration_ms
}

pub fn the_unknown_row_profiles_the_unclaimed_processes_test() {
  let #(_, page) = page_over([session(1), stray(3)])
  let _ =
    web_mount.ask(on(page, "owners"), msg.ProfileOwner(key.make("unknown")))

  assert targets(page) == 1

  let assert [note] = page.profile_notes()
  assert note.chosen == "all 1 listed processes of the unknown owner"
}

// An owner with more processes than a probe takes is cut, and the plan says
// how many of how many.
pub fn an_owner_larger_than_the_limit_is_cut_and_says_so_test() {
  let rows = list.map(fixture.numbers(20), session)
  let #(_, page) = page_over(rows)
  let _ =
    web_mount.ask(
      on(page, "owners"),
      msg.ProfileOwner(key.make("owner:session:s1")),
    )

  assert targets(page) == seam.profile_limit

  let assert [note] = page.profile_notes()
  assert string.starts_with(
    note.chosen,
    "16 of 20 listed processes of session:s1, ",
  )
}

// The unknown row is always drawn, even with nothing in it: profiling it
// says why nothing was planned.
pub fn an_owner_with_no_live_processes_is_refused_in_words_test() {
  let #(_, page) = page_over([session(1)])
  let state =
    web_mount.ask(on(page, "owners"), msg.ProfileOwner(key.make("unknown")))

  assert page.plans() == []
  assert web_mount.refusal_of(state)
    == Some("the last pass lists no live process of the unknown owner")
}

pub fn a_key_that_names_no_row_makes_no_request_test() {
  let #(rig, page) = page_over([session(1)])
  let _ = fixture.drain(rig.seen, 50)
  let state =
    web_mount.ask(
      on(page, "owners"),
      msg.ProfileOwner(key.make("owner:session:gone")),
    )

  assert page.plans() == []
  assert web_mount.refusal_of(state) == None
  assert !list.any(fixture.drain(rig.seen, 50), fn(request) {
    case request {
      wire.AskPin(_) -> True
      _ -> False
    }
  })
}

pub fn the_busiest_button_plans_the_listed_processes_test() {
  let #(_, page) = page_over(list.map(fixture.numbers(30), session))
  let state = web_mount.ask(on(page, "overview"), msg.ProfileBusiest)

  assert targets(page) == 16
  assert web_mount.refusal_of(state) == None

  let assert [note] = page.profile_notes()
  assert string.contains(note.chosen, "of the node")
}

pub fn the_process_button_pins_and_plans_one_process_test() {
  let #(rig, page) = page_over([session(1), session(2)])
  let _ = fixture.drain(rig.seen, 50)
  let _ =
    web_mount.ask(on(page, "processes"), msg.ProfileProcess(key.make(pid(2))))

  assert targets(page) == 1
  assert list.contains(fixture.drain(rig.seen, 50), wire.AskPin(pid(2)))
}

pub fn a_refusal_clears_when_the_next_plan_is_made_test() {
  let #(_, page) = page_over([session(1)])
  let state =
    web_mount.ask(on(page, "owners"), msg.ProfileOwner(key.make("unknown")))
  let assert Some(_) = web_mount.refusal_of(state)

  let state = web_mount.ask(state, msg.ProfileBusiest)

  assert web_mount.refusal_of(state) == None
}

// The probe form has no rate field; a stack probe planned from it runs at the
// gate's default.
pub fn the_pages_limit_is_the_agents_limit_test() {
  assert msg.profile_limit == seam.profile_limit
  assert seam.profile_limit == policy.target_limit(policy.Sampling)
}

// ------------------------------------------------------------ the choice

pub fn the_busiest_by_reductions_come_first_then_the_largest_heap_test() {
  let candidates = [
    Candidate("<0.1.0>", Some(10), 100),
    Candidate("<0.2.0>", Some(500), 1),
    Candidate("<0.3.0>", None, 9999),
    Candidate("<0.4.0>", Some(10), 200),
  ]
  let assert Ok(chosen) =
    profile_scope.choose(candidates, 3, profile_scope.WholeNode)

  // A process with no rate ranks below every process with one.
  assert chosen.pids == ["<0.2.0>", "<0.4.0>", "<0.1.0>"]
  assert chosen.listed == 4
  assert chosen.sentence
    == "3 of 4 listed processes of the node, the busiest by reductions/s"
}

pub fn with_no_rates_the_order_is_by_heap_and_the_sentence_says_why_test() {
  let assert Ok(chosen) =
    profile_scope.choose(
      [Candidate("<0.1.0>", None, 1), Candidate("<0.2.0>", None, 5)],
      1,
      profile_scope.OwnerScope("session:s1"),
    )

  assert chosen.pids == ["<0.2.0>"]
  assert chosen.sentence
    == "1 of 2 listed processes of session:s1, the largest by heap, since reductions/s needs two census passes"
}

pub fn nothing_to_choose_from_is_refused_test() {
  assert profile_scope.choose([], 16, profile_scope.WholeNode)
    == Error(profile_scope.NothingToProfile("the last pass lists no process"))
}

// Whatever the candidates, the choice is at most the limit, is drawn from
// them, and is the same for any order they arrive in.
pub fn the_choice_is_bounded_drawn_from_the_candidates_and_order_free_test() {
  let candidates =
    list.map(fixture.numbers(40), fn(n) {
      Candidate(
        pid(n),
        case n % 3 {
          0 -> None
          _ -> Some(n * 7 % 11)
        },
        n * 13 % 17,
      )
    })
  let assert Ok(forward) =
    profile_scope.choose(candidates, 16, profile_scope.WholeNode)
  let assert Ok(backward) =
    profile_scope.choose(list.reverse(candidates), 16, profile_scope.WholeNode)

  assert list.length(forward.pids) == 16
  assert forward.pids == backward.pids
  assert list.all(forward.pids, fn(chosen) {
    list.any(candidates, fn(c) { c.pid_text == chosen })
  })
  assert list.unique(forward.pids) == forward.pids
}

// ---------------------------------------------------- tracing the processes

fn spec_of(page: seam.Page) -> policy.ProbeSpec {
  let assert [#(_, plan)] = page.plans()
  let assert policy.StartProbe(spec:) = policy.plan_command(plan)

  spec
}

// The detail page's "Trace calls…" pins the process and plans a call tree of
// the modules over it, for the window a call trace is run for.
pub fn the_trace_button_pins_and_plans_a_call_tree_of_one_process_test() {
  let #(rig, page) = page_over([session(1), session(2)])
  let _ = fixture.drain(rig.seen, 50)
  let state =
    web_mount.ask(
      on(page, "process-detail"),
      msg.TraceProcess(key.make(pid(2)), ["lists", "m@n"]),
    )
  let spec = spec_of(page)

  assert web_mount.refusal_of(state) == None
  assert list.contains(fixture.drain(rig.seen, 50), wire.AskPin(pid(2)))
  assert spec.kind == policy.CallTree
  assert spec.modules == ["lists", "m@n"]
  assert spec.duration_ms == seam.trace_duration_ms
  assert list.length(spec.targets) == 1

  let assert [note] = page.profile_notes()

  assert note.method == seam.ByCalls(["lists", "m@n"])
}

pub fn the_record_button_pins_and_plans_a_recording_of_one_process_test() {
  let #(_, page) = page_over([session(1), session(2)])
  let _ =
    web_mount.ask(
      on(page, "process-detail"),
      msg.RecordProcess(key.make(pid(1))),
    )
  let spec = spec_of(page)

  assert spec.kind == policy.SchedulingGc
  assert spec.modules == []
  assert spec.duration_ms == seam.recording_duration_ms
}

// An owner is recorded over up to eight of its processes, the busiest.
pub fn an_owner_row_plans_a_recording_of_at_most_eight_processes_test() {
  let rows = list.map(fixture.numbers(12), session)
  let #(_, page) = page_over(rows)
  let _ =
    web_mount.ask(
      on(page, "owners"),
      msg.RecordOwner(key.make("owner:session:s1")),
    )
  let spec = spec_of(page)

  assert spec.kind == policy.SchedulingGc
  assert list.length(spec.targets) == seam.recording_limit

  let assert [note] = page.profile_notes()

  assert string.starts_with(
    note.chosen,
    "8 of 12 listed processes of session:s1, ",
  )
}

pub fn recording_an_owner_with_no_live_processes_says_why_test() {
  let #(_, page) = page_over([session(1)])
  let state =
    web_mount.ask(on(page, "owners"), msg.RecordOwner(key.make("unknown")))

  assert page.plans() == []
  assert web_mount.refusal_of(state)
    == Some("the last pass lists no live process of the unknown owner")
}

// "Trace calls instead" on a pending stack profile keeps its pins and plans a
// call tree over them; "sample stacks instead" goes back.
pub fn a_pending_profile_is_swapped_between_stacks_and_calls_test() {
  let #(rig, page) = page_over([session(1), session(2)])
  let state =
    web_mount.ask(
      on(page, "owners"),
      msg.ProfileOwner(key.make("owner:session:s1")),
    )
  let _ = fixture.drain(rig.seen, 50)
  let assert [#(first, _)] = page.plans()
  let plan_key = key.make("plan." <> first)

  let state = web_mount.ask(state, msg.TraceCallsInstead(plan_key, ["lists"]))

  assert web_mount.refusal_of(state) == None
  assert spec_of(page).kind == policy.CallTree
  assert spec_of(page).modules == ["lists"]
  assert spec_of(page).duration_ms == seam.trace_duration_ms
  assert fixture.drain(rig.seen, 50) == []

  let assert [#(second, _)] = page.plans()
  let state =
    web_mount.ask(state, msg.SampleStacksInstead(key.make("plan." <> second)))

  assert web_mount.refusal_of(state) == None
  assert spec_of(page).kind == policy.Sampling
  assert spec_of(page).rate_hz == seam.profile_rate_hz
}

// Five processes are too many for a call trace; the viewer says so and keeps
// the stack profile the operator had.
pub fn a_swap_the_agent_would_refuse_is_said_and_changes_nothing_test() {
  let rows = list.map(fixture.numbers(5), session)
  let #(_, page) = page_over(rows)
  let state =
    web_mount.ask(
      on(page, "owners"),
      msg.ProfileOwner(key.make("owner:session:s1")),
    )
  let assert [#(first, _)] = page.plans()
  let state =
    web_mount.ask(
      state,
      msg.TraceCallsInstead(key.make("plan." <> first), ["lists"]),
    )

  assert string.contains(
    option.unwrap(web_mount.refusal_of(state), ""),
    "at most 4 processes",
  )
  assert spec_of(page).kind == policy.Sampling
}

// A key that names no pending plan makes no request.
pub fn a_swap_of_a_plan_that_is_gone_makes_no_request_test() {
  let #(rig, page) = page_over([session(1)])
  let _ = fixture.drain(rig.seen, 50)
  let _ =
    web_mount.ask(
      on(page, "owners"),
      msg.TraceCallsInstead(key.make("plan.gone"), ["lists"]),
    )

  assert page.plans() == []
  assert fixture.drain(rig.seen, 50) == []
}

// An agent that refuses every call trace at start, as it does for a module
// the node does not have.
fn refusing_agent(
  rows: List(wire.ProcessRow),
) -> fn(wire.Request) -> Result(wire.Reply, remote.Failure) {
  fn(request) {
    case request {
      wire.Extended(wire.AskStartCalltrace(..)) ->
        Error(remote.Refusal(
          "unknown_module",
          "the node has no such name loaded",
        ))
      other -> agent(rows)(other)
    }
  }
}

pub fn a_probe_the_agent_refuses_at_start_is_shown_on_the_page_that_asked_test() {
  let rows = [session(1), session(2)]
  let rig = harness.live(refusing_agent(rows), None)
  let page = harness.page(rig, "alice", harness.all)
  let updates = process.new_subject()
  let assert Ok(Nil) = page.subscribe(updates)

  list.each([1, 2], fn(_) {
    hub.tick(rig.hub)
    let _ = process.receive(updates, 1000)
    process.sleep(50)
  })

  let state =
    web_mount.ask(
      on(page, "process-detail"),
      msg.TraceProcess(key.make(pid(2)), ["runtime"]),
    )
  let assert [#(plan_id, _)] = page.plans()
  let state = web_mount.ask(state, msg.ConfirmPlan(feeds.plan_key(plan_id)))

  // No probe exists, so the notice is the only place the reason can be.
  let assert Some(notice) = web_mount.refusal_of(state)

  assert string.contains(
    notice,
    "A probe of runtime was refused when it started",
  )
  assert string.contains(notice, "unknown_module")
  assert page.probes() == []
  assert web_mount.refused_starts_of(state) == [notice]
}
