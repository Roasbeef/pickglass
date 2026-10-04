//// `pickglass open` and `pickglass view`: start the host and print the URL.
////
//// `open` attaches to a target, starts the observation hub over it, the
//// service that holds the gate, the admission actor, and the HTTP host, then
//// issues one ticket and prints the URL that redeems it. `view` does the
//// same over a capture file with no target: the hub is a replay of the
//// file's observations, the gate has no target, and the ticket carries only
//// the grants to observe and export.
////
//// Both run until the process is stopped. When the VM exits, the agent sees
//// the link process die and tears down what it holds, so a stopped viewer
//// leaves nothing running in the target.
////
//// ## Flow
////
//// - `run_open` and `run_view` build their parts and call `serve`.
//// - `serve` starts the host, issues the ticket, prints, and waits.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass/admission
import pickglass/assets
import pickglass/attach
import pickglass/audit
import pickglass/capture_build
import pickglass/capture_file
import pickglass/cli
import pickglass/host
import pickglass/hub
import pickglass/internal/ffi_dist
import pickglass/observation.{type Observation}
import pickglass/observation_codec
import pickglass/remote.{type Remote}
import pickglass/seam
import pickglass/service
import pickglass/web_mount
import pickglass_core/identity
import pickglass_core/policy

/// Run `pickglass open` and return an exit status. It returns only if
/// starting fails.
///
/// ## Examples
///
/// ```gleam
/// serve.run_open(options, "0.1.0")
/// ```
pub fn run_open(options: cli.OpenOptions, version: String) -> Int {
  case open(options, version) {
    Ok(Nil) -> 0
    Error(message) -> {
      io.println_error("pickglass: " <> message)

      1
    }
  }
}

fn open(options: cli.OpenOptions, version: String) -> Result(Nil, String) {
  use #(target, session) <- result.try(cli.connect(
    options.state_dir,
    options.pid,
    options.agent_ebin,
  ))
  use remote <- result.try(remote.of_session(session))

  let cadence_ms = option.unwrap(options.cadence_s, 2) * 1000
  let facts =
    capture_build.Facts(
      pickglass_version: version,
      node: target.node,
      os_pid: target.os_pid,
      boot: remote.boot,
      role: "loomd",
      workload: "",
      top_k: 200,
      deadline_ms: 15_000,
    )
  let mode =
    seam.Live(
      node: target.node,
      incarnation: identity.NodeIncarnation(
        node_digest: capture_build.sha256_hex(target.node),
        creation: 0,
        boot: remote.boot,
      ),
      os: identity.OsProcess(
        pid: target.os_pid,
        start: identity.UnreadableStart,
      ),
    )

  let started =
    serve(
      Some(remote),
      [],
      mode,
      host.operator_grants(),
      Some(service.Saver(
        directory: option.unwrap(options.save_dir, "."),
        facts:,
        cadence_ms:,
      )),
      cadence_ms,
      options.port,
    )

  // Reaching here means the host stopped or never started; either way the
  // attach ends.
  let _ = attach.detach(session)

  started
}

/// Run `pickglass view` and return an exit status. It returns only if
/// starting fails.
///
/// ## Examples
///
/// ```gleam
/// serve.run_view(options)
/// ```
pub fn run_view(options: cli.ViewOptions) -> Int {
  case view(options) {
    Ok(Nil) -> 0
    Error(message) -> {
      io.println_error("pickglass: " <> message)

      1
    }
  }
}

fn view(options: cli.ViewOptions) -> Result(Nil, String) {
  use loaded <- result.try(capture_file.read(options.file))

  let capture = loaded.capture
  let header = capture.header
  use observations <- result.try(observation_codec.of_records(
    capture.records,
    capture_build.runtime_of(header),
  ))

  io.println(
    "pickglass: "
    <> options.file
    <> ": "
    <> int.to_string(list.length(observations))
    <> " observations, "
    <> verdict(loaded),
  )

  let target = header.provenance.target
  let mode =
    seam.Viewing(
      source: file_name(options.file),
      incarnation: target.incarnation,
      os: target.os,
    )

  serve(None, observations, mode, host.viewer_grants(), None, 0, options.port)
}

fn verdict(loaded: capture_file.Loaded) -> String {
  case loaded.digest {
    capture_file.DigestVerified -> "footer digest verified"
    capture_file.DigestMismatched ->
      "FOOTER DIGEST DOES NOT MATCH, the file was changed after it was written"
    capture_file.NoDigestToCheck -> "no footer, the capture may be cut short"
  }
}

fn file_name(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }
}

// The parts are started in dependency order and linked to this process; the
// last step blocks until the VM is stopped.
fn serve(
  remote: Option(Remote),
  observations: List(Observation),
  mode: seam.Mode,
  grants: List(policy.Capability),
  saver: Option(service.Saver),
  cadence_ms: Int,
  port: Option(Int),
) -> Result(Nil, String) {
  let clock = ffi_dist.system_time_ms

  use log <- result.try(audit.start())
  use loaded_assets <- result.try(assets.load())
  use admission <- result.try(admission.start(clock))

  let config = hub.Config(..hub.default_config(clock), cadence_ms:)

  use hub <- result.try(case remote {
    Some(remote) -> hub.start_live(remote, config)
    None -> hub.start_replay(list.reverse(observations), config)
  })
  use service <- result.try(
    service.start(service.Config(
      remote:,
      hub:,
      audit: log,
      clock:,
      mode:,
      saver:,
    )),
  )
  use running <- result.try(
    host.start(host.Config(
      admission:,
      service:,
      audit: log,
      mount: web_mount.mount(cadence_ms),
      assets: loaded_assets,
      clock:,
      port: option.unwrap(port, 0),
    )),
  )
  use ticket <- result.try(
    admission.issue_ticket(admission, grants)
    |> result.replace_error("could not issue a ticket"),
  )

  io.println("open: " <> host.ticket_url(running, ticket))
  io.println(
    "single use, valid for two minutes; the pages are served on 127.0.0.1 only",
  )

  process.sleep_forever()

  Ok(Nil)
}
