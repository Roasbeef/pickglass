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
import pickglass/discover.{type Target}
import pickglass/internal/ffi_dist
import pickglass/observation
import pickglass/remote
import pickglass/secret
import pickglass_core/measure

/// What `once` needs to know about the version and the destination.
pub type Request {
  Request(
    state_dir: Option(String),
    pid: Option(Int),
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
/// once.run(Request(None, None, None, "cut.pgcap", "0.1.0"))
/// // -> 0
/// ```
pub fn run(request: Request) -> Int {
  case cli.connect(request.state_dir, request.pid, request.agent_ebin) {
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
    )
  let facts =
    capture_build.Facts(
      pickglass_version: request.version,
      node: target.node,
      os_pid: target.os_pid,
      boot: remote.boot,
      role: "loomd",
      workload: "",
      top_k: 200,
      deadline_ms: observation.ask_deadline_ms,
    )

  use #(header, records) <- result.try(
    capture_build.assemble(
      facts,
      "cap-" <> secret.token(9),
      [observation],
      measure.OneShot,
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
