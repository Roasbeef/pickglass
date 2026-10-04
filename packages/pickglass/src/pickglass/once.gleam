//// `pickglass attach --once --out FILE`: one reading, written as a capture.
////
//// It attaches, takes one pass (the memory categories, one census and the
//// scheduler wall-time readings, the same `observation.collect` the live hub
//// runs), assembles a capture with the provenance header, writes it, and
//// detaches. The detach runs whether or not the pass or the write succeeded,
//// so a failure never leaves the agent in the target.
////
//// The file is `pickglass.capture/1`, gzip, with a footer whose SHA-256
//// covers the body, so `pickglass view FILE` and any reader of the format
//// can verify it.
////
//// ## Flow
////
//// - `run` connects, calls `capture_once`, detaches, and prints one line.
//// - `capture_once` is the pass and the write.
//// - `fail` prints the reason and returns the exit status.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/result
import pickglass/attach.{type Session}
import pickglass/capture_build
import pickglass/capture_file
import pickglass/cli
import pickglass/clock
import pickglass/discover.{type Target}
import pickglass/internal/ffi_dist
import pickglass/observation
import pickglass/os_reader
import pickglass/remote
import pickglass/secret
import pickglass_core/identity
import pickglass_core/measure

/// What `once` needs to know about the version and the destination.
pub type Request {
  Request(
    selector: cli.Selector,
    agent_ebin: Option(String),
    out: String,
    /// The viewer's version, for the capture's producer block.
    version: String,
  )
}

/// Run the command and return the process exit status.
///
/// ## Examples
///
/// ```gleam
/// once.run(Request(cli.LoomTarget(None, None), None, "cut.pgcap", "0.1.0"))
/// // -> 0
/// ```
pub fn run(request: Request) -> Int {
  case cli.connect(request.selector, request.agent_ebin) {
    Error(message) -> fail(message)
    Ok(#(target, session)) -> {
      // Detach runs whether or not the capture was written.
      let written = capture_once(request, target, session)
      let _ = attach.detach(session)

      case written {
        Ok(line) -> {
          io.println(line)

          0
        }
        Error(message) -> fail(message)
      }
    }
  }
}

fn fail(message: String) -> Int {
  io.println_error("pickglass: " <> message)

  1
}

fn capture_once(
  request: Request,
  target: Target,
  session: Session,
) -> Result(String, String) {
  use remote <- result.try(remote.of_session(session))

  let observation =
    observation.collect(
      remote,
      observation.Budget(max_scanned: 200_000, top_k: 200),
      0,
      observation.TurnOnAndRead,
      ffi_dist.system_time_ms,
      fn() { os_reader.read(target.os_pid) },
    )
  let facts =
    capture_build.Facts(
      pickglass_version: request.version,
      node: target.node,
      os_pid: target.os_pid,
      boot: remote.boot,
      role: cli.role(request.selector),
      workload: "",
      top_k: 200,
      deadline_ms: observation.ask_deadline_ms,
      os_start: os_start_of(observation),
      clock: option.from_result(clock.measure(
        remote,
        ffi_dist.system_time_ms,
        ffi_dist.monotonic_ns,
      )),
    )

  use #(header, records) <- result.try(
    capture_build.assemble(
      facts,
      "cap-" <> secret.token(9),
      [observation],
      measure.OneShot,
      [],
      [],
      [],
    ),
  )
  use _ <- result.try(capture_file.write(request.out, header, records))

  Ok(
    "wrote "
    <> request.out
    <> " ("
    <> int.to_string(list.length(records))
    <> " records plus header and footer)",
  )
}

// The target's start identity from the OS reading taken with the pass, or
// the word that it could not be read.
fn os_start_of(observation: observation.Observation) -> identity.StartIdentity {
  case observation.os {
    Ok(readings) ->
      case os_reader.target_of(readings) {
        option.Some(reading) -> reading.start
        option.None -> identity.UnreadableStart
      }
    Error(_) -> identity.UnreadableStart
  }
}
