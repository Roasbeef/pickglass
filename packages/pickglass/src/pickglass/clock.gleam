//// Relating the agent's clock to the viewer's by timing a ping.
////
//// A capture's `clock` record says how the agent's time and the viewer's
//// time relate, so a reader can place an agent-side reading on the viewer's
//// wall clock and knows how far to trust the placement. The viewer cannot
//// read the agent's clock directly; what it can measure is the round trip
//// of a ping, and that bounds the error of any single placement: the
//// reply was sent some time inside the round trip.
////
//// What the record holds and where each part comes from:
////
//// - `viewer_system_ms` is the midpoint of the viewer's wall clock before
////   the ping and after the reply.
//// - `round_trip_ns` is the monotonic time between the two.
//// - `agent_monotonic_ns` is how long the agent had been running when it
////   answered, from the pong. Its origin is the agent's start, not the
////   node's, and it is only ever differenced against another reading of
////   the same clock, as a checkpoint is.
//// - `agent_system_ms` is the agent's wall clock, which the pong does not
////   carry. `pickglass open` attaches only to a node on its own host (the
////   target is found through the local process table), and every process on
////   one host reads the same system clock, so the viewer's midpoint stands
////   in for it. The assumption is stated here, and the round trip is the
////   bound that goes with it.

import gleam/result
import pickglass/remote.{type Remote}
import pickglass_core/capture
import pickglass_core/wire

/// The most a clock record's round trip may be and still be written. A
/// ping that took longer than this says little about when the agent
/// answered.
pub const max_round_trip_ms = 2000

/// Ping the agent once and relate its clock to the viewer's. `wall_ms` and
/// `monotonic_ns` are the viewer's clocks.
///
/// ## Examples
///
/// ```gleam
/// clock.measure(remote, ffi_dist.system_time_ms, ffi_dist.monotonic_ns)
/// ```
pub fn measure(
  remote: Remote,
  wall_ms: fn() -> Int,
  monotonic_ns: fn() -> Int,
) -> Result(capture.Clock, String) {
  let wall_before = wall_ms()
  let started = monotonic_ns()

  use reply <- result.try(
    remote.ask(wire.AskPing, max_round_trip_ms)
    |> result.map_error(remote.describe),
  )

  let round_trip_ns = monotonic_ns() - started
  let wall_after = wall_ms()

  case reply {
    wire.Pong(info) -> {
      let midpoint = { wall_before + wall_after } / 2

      Ok(capture.Clock(
        agent_monotonic_ns: info.uptime_ms * 1_000_000,
        agent_system_ms: midpoint,
        viewer_system_ms: midpoint,
        round_trip_ns:,
      ))
    }
    _ -> Error("the agent answered a ping with another reply")
  }
}
