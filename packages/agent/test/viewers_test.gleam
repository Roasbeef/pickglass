import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Atom, type Pid}
import pickglass_agent/internal/seq
import pickglass_agent/viewers.{
  type Viewer, Collecting, Keep, NotCollecting, TurnOff, TurnOn, Viewer,
}

@external(erlang, "erlang", "spawn")
fn spawn_idle(function: fn() -> Nil) -> Pid

@external(erlang, "timer", "sleep")
fn sleep_forever(milliseconds: Int) -> Nil

fn idle_pid() -> Pid {
  spawn_idle(fn() { sleep_forever(60_000) })
}

fn viewer_at(pid: Pid, node: Atom, now: Int) -> Viewer {
  Viewer(
    pid: pid,
    boot_id: "boot",
    monitor: ffi_proc.make_ref(),
    node: node,
    lease_ms: 1000,
    last_heard_ms: now,
    scheduler: NotCollecting,
  )
}

fn viewer(pid: Pid) -> Viewer {
  viewer_at(pid, ffi_term.atom("a@127.0.0.1"), 0)
}

fn table(count: Int) -> List(Viewer) {
  case count {
    0 -> []
    _ -> [viewer(idle_pid()), ..table(count - 1)]
  }
}

// The table has room for exactly `max_viewers` viewers, so the cap is a
// property of the count and not of any one viewer.
pub fn the_table_is_capped_test() {
  assert viewers.has_room(table(viewers.max_viewers - 1))
  assert !viewers.has_room(table(viewers.max_viewers))
}

pub fn a_viewer_is_found_by_its_pid_and_its_monitor_test() {
  let one = idle_pid()
  let two = idle_pid()
  let first = viewer(one)
  let second = viewer(two)
  let both = viewers.add(viewers.add([], first), second)

  assert viewers.find(both, one) == Ok(first)
  assert viewers.find(both, two) == Ok(second)
  assert viewers.find(both, idle_pid()) == Error(Nil)
  assert viewers.find_by_monitor(both, second.monitor) == Ok(second)
  assert viewers.find_by_monitor(both, ffi_proc.make_ref()) == Error(Nil)
}

// Hearing from one viewer renews its lease and leaves the other's alone, so a
// quiet viewer is still dropped while a busy one keeps the agent alive.
pub fn a_lease_is_renewed_per_viewer_test() {
  let busy = idle_pid()
  let quiet = idle_pid()
  let both =
    viewers.add(viewers.add([], viewer(busy)), viewer(quiet))
    |> viewers.touch(busy, 5000)

  let lapsed = viewers.lapsed(both, 5500)

  assert seq.map(lapsed, fn(found) { found.pid }) == [quiet]
}

pub fn a_lease_lapses_only_after_its_length_test() {
  let pid = idle_pid()
  let one = viewers.add([], viewer(pid))

  assert viewers.lapsed(one, 1000) == []
  assert seq.length(viewers.lapsed(one, 1001)) == 1
}

pub fn leaving_removes_only_that_viewer_test() {
  let one = idle_pid()
  let two = idle_pid()
  let both = viewers.add(viewers.add([], viewer(one)), viewer(two))
  let #(remaining, switch) = viewers.leave(both, one)

  assert seq.map(remaining, fn(found) { found.pid }) == [two]
  assert switch == Keep
  assert viewers.leave(remaining, idle_pid()) == #(remaining, Keep)
}

pub fn viewers_on_a_lost_node_are_found_together_test() {
  let lost = ffi_term.atom("lost@127.0.0.1")
  let here = idle_pid()
  let gone_one = idle_pid()
  let gone_two = idle_pid()
  let all =
    viewers.add([], viewer(here))
    |> viewers.add(viewer_at(gone_one, lost, 0))
    |> viewers.add(viewer_at(gone_two, lost, 0))

  assert seq.length(viewers.on_node(all, lost)) == 2
  assert viewers.on_node(all, ffi_term.atom("other@127.0.0.1")) == []
}

// The accounting flag is shared: it goes on for the first request and off for
// the last release, and every request or release between those changes nothing.
pub fn the_accounting_flag_follows_the_edges_of_demand_test() {
  let one = idle_pid()
  let two = idle_pid()
  let both = viewers.add(viewers.add([], viewer(one)), viewer(two))

  let #(first_on, switch) = viewers.set_scheduler(both, one, Collecting)
  assert switch == TurnOn
  assert viewers.demand(first_on) == Collecting

  let #(second_on, switch) = viewers.set_scheduler(first_on, two, Collecting)
  assert switch == Keep

  let #(one_off, switch) = viewers.set_scheduler(second_on, one, NotCollecting)
  assert switch == Keep
  assert viewers.demand(one_off) == Collecting

  let #(none, switch) = viewers.set_scheduler(one_off, two, NotCollecting)
  assert switch == TurnOff
  assert viewers.demand(none) == NotCollecting
}

// A viewer that leaves while it holds the flag releases its share, and the
// flag goes off only if nobody else wants it.
pub fn leaving_releases_the_viewers_share_of_the_flag_test() {
  let one = idle_pid()
  let two = idle_pid()
  let both = viewers.add(viewers.add([], viewer(one)), viewer(two))
  let #(held_by_one, _) = viewers.set_scheduler(both, one, Collecting)
  let #(held_by_both, _) = viewers.set_scheduler(held_by_one, two, Collecting)

  let #(after_one, switch) = viewers.leave(held_by_both, one)
  assert switch == Keep

  let #(after_two, switch) = viewers.leave(after_one, two)
  assert switch == TurnOff
  assert after_two == []
}

pub fn asking_twice_does_not_stack_the_flag_test() {
  let one = idle_pid()
  let single = viewers.add([], viewer(one))
  let #(on, _) = viewers.set_scheduler(single, one, Collecting)

  assert viewers.set_scheduler(on, one, Collecting).1 == Keep
  assert viewers.set_scheduler(on, one, NotCollecting).1 == TurnOff
}
