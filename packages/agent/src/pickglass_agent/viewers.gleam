//// The viewers attached to one agent, as pure bookkeeping.
////
//// One agent serves one node, and several viewers may be attached to it at
//// once. The agent cannot hand each viewer an agent of its own, because the
//// agent's modules have fixed names: a second push would reload code under a
//// live agent, and the purge that follows kills the processes still running
//// the old code. So the agent is shared, and each viewer is a row in this
//// table: its link process, its own boot id, its lease and whether it has
//// asked for `scheduler_wall_time`.
////
//// A viewer is known to the agent by its link process, the `ReplyTo` its
//// requests carry. Everything the agent keeps for a viewer (pins, probes,
//// workers) is tagged with that pid, and a lookup that names a pin or a probe
//// also names the requester, so one viewer can neither read nor cancel nor
//// unpin what another holds. `server` owns the processes and the monitors;
//// this module owns only the rows and the rules about them, so the rules can
//// be tested without a running agent.
////
//// ## Flow
////
//// - `has_room` says whether another viewer may join, and `add` records it
////   once the caller has monitored it.
//// - `find`, `find_by_monitor`, `on_node` and `lapsed` answer which rows an
////   event concerns, and `touch` renews a lease.
//// - `leave` removes a row, and `set_scheduler` changes its accounting
////   request. Both also say whether the node-wide flag must change, because
////   the flag is shared by every viewer and the agent must switch it on for
////   the first request and off after the last release.

import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Reference}
import pickglass_agent/internal/seq

/// The most viewers attached to one agent at once.
pub const max_viewers = 8

/// Whether one viewer has asked the agent to hold `scheduler_wall_time`.
pub type Scheduler {
  Collecting
  NotCollecting
}

/// What the agent must do to the node-wide `scheduler_wall_time` flag after a
/// change in the viewers' requests. The flag is reference counted per
/// process, and the agent is one process however many viewers there are, so it
/// is switched on once and off once.
pub type Switch {
  TurnOn
  TurnOff
  Keep
}

/// One attached viewer.
pub type Viewer {
  Viewer(
    /// The viewer's link process, which every request of the viewer names as
    /// its reply address and which the agent monitors.
    pid: Pid,
    /// The identifier the viewer generated for its attach. Its pin tokens are
    /// bound to it, so a token from another viewer or an earlier attach is
    /// refused.
    boot_id: String,
    /// The agent's monitor on `pid`.
    monitor: Reference,
    /// The node `pid` runs on, watched so that a lost connection ends the
    /// attach even before the monitor message arrives.
    node: Atom,
    /// How long the agent waits without hearing from this viewer before it
    /// drops it, in milliseconds.
    lease_ms: Int,
    /// When the agent last heard from this viewer, in monotonic milliseconds.
    last_heard_ms: Int,
    /// Whether this viewer has asked for `scheduler_wall_time`.
    scheduler: Scheduler,
  )
}

/// Whether the agent has room for another viewer. The caller has already
/// found that the joining pid is not attached, since a pid that is attached
/// never reaches a join.
///
/// ## Examples
///
/// ```gleam
/// has_room([])
/// // -> True
/// ```
pub fn has_room(viewers: List(Viewer)) -> Bool {
  seq.length(viewers) < max_viewers
}

/// Record a viewer that `has_room` allowed. The newest viewer is first.
pub fn add(viewers: List(Viewer), viewer: Viewer) -> List(Viewer) {
  [viewer, ..viewers]
}

/// The viewer whose link process is `pid`.
pub fn find(viewers: List(Viewer), pid: Pid) -> Result(Viewer, Nil) {
  seq.find(viewers, fn(viewer) { viewer.pid == pid })
}

/// The viewer the agent monitors with `monitor`.
pub fn find_by_monitor(
  viewers: List(Viewer),
  monitor: Reference,
) -> Result(Viewer, Nil) {
  seq.find(viewers, fn(viewer) { viewer.monitor == monitor })
}

/// Every viewer that runs on `node`.
pub fn on_node(viewers: List(Viewer), node: Atom) -> List(Viewer) {
  seq.filter(viewers, fn(viewer) { viewer.node == node })
}

/// Every viewer the agent has not heard from within its lease at `now`.
pub fn lapsed(viewers: List(Viewer), now: Int) -> List(Viewer) {
  seq.filter(viewers, fn(viewer) {
    now - viewer.last_heard_ms > viewer.lease_ms
  })
}

/// Record that `pid` was heard from at `now`. Another viewer's lease is not
/// renewed by it.
pub fn touch(viewers: List(Viewer), pid: Pid, now: Int) -> List(Viewer) {
  seq.map(viewers, fn(viewer) {
    case viewer.pid == pid {
      True -> Viewer(..viewer, last_heard_ms: now)
      False -> viewer
    }
  })
}

/// Remove the viewer `pid`, and say what the removal does to the shared
/// accounting flag. A pid that is not attached changes nothing.
///
/// ## Examples
///
/// ```gleam
/// leave(viewers, pid)
/// // -> #(remaining, Keep)
/// ```
pub fn leave(viewers: List(Viewer), pid: Pid) -> #(List(Viewer), Switch) {
  let remaining = seq.filter(viewers, fn(viewer) { viewer.pid != pid })

  #(remaining, switch(demand(viewers), demand(remaining)))
}

/// Record whether `pid` wants `scheduler_wall_time`, and say what that does
/// to the shared flag. A second viewer asking while the flag is on, or one
/// releasing while another still holds it, changes nothing.
///
/// ## Examples
///
/// ```gleam
/// set_scheduler(viewers, pid, Collecting)
/// // -> #(updated, TurnOn)
/// ```
pub fn set_scheduler(
  viewers: List(Viewer),
  pid: Pid,
  wanted: Scheduler,
) -> #(List(Viewer), Switch) {
  let updated =
    seq.map(viewers, fn(viewer) {
      case viewer.pid == pid {
        True -> Viewer(..viewer, scheduler: wanted)
        False -> viewer
      }
    })

  #(updated, switch(demand(viewers), demand(updated)))
}

/// Whether any viewer wants `scheduler_wall_time`, which is whether the agent
/// must hold the flag.
pub fn demand(viewers: List(Viewer)) -> Scheduler {
  case seq.any(viewers, fn(viewer) { viewer.scheduler == Collecting }) {
    True -> Collecting
    False -> NotCollecting
  }
}

// The flag changes only on the edges of the demand: the first request turns
// it on and the last release turns it off.
fn switch(before: Scheduler, after: Scheduler) -> Switch {
  case before, after {
    NotCollecting, Collecting -> TurnOn
    Collecting, NotCollecting -> TurnOff
    Collecting, Collecting -> Keep
    NotCollecting, NotCollecting -> Keep
  }
}
