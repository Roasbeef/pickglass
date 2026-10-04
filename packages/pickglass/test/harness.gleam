//// Starts the viewer's parts against a fake agent, for the service and host
//// tests.

import fixture
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import pickglass/audit
import pickglass/hub
import pickglass/observation.{Budget}
import pickglass/probe_book
import pickglass/remote
import pickglass/seam
import pickglass/service
import pickglass_core/identity
import pickglass_core/policy
import pickglass_core/wire

pub type Rig {
  Rig(
    service: service.Service,
    hub: hub.Hub,
    log: audit.Log,
    seen: Subject(wire.Request),
  )
}

pub fn clock() -> Int {
  1_790_000_000_000
}

pub fn mode() -> seam.Mode {
  seam.Live(
    "fake@127.0.0.1",
    identity.NodeIncarnation("digest", 0, fixture.boot()),
    identity.OsProcess(1, identity.UnreadableStart),
  )
}

/// A rig whose hub never polls on a timer, over a fake agent that answers
/// from `script`.
pub fn live(
  script: fn(wire.Request) -> Result(wire.Reply, remote.Failure),
  saver: option.Option(service.Saver),
) -> Rig {
  let seen = process.new_subject()
  let agent = fixture.fake_remote(seen, script)
  let config =
    hub.Config(
      cadence_ms: 0,
      ring_capacity: 10,
      budget: Budget(100, 10),
      clock:,
      os: fn() { Error("no OS reader in this test") },
    )
  let assert Ok(log) = audit.start()
  let assert Ok(the_hub) = hub.start_live(agent, config)
  let assert Ok(the_service) =
    service.start(
      service.Config(
        remote: Some(agent),
        hub: the_hub,
        audit: log,
        clock:,
        mode: mode(),
        saver:,
        marks: [],
        probes: [],
      ),
    )

  Rig(service: the_service, hub: the_hub, log:, seen:)
}

/// A rig over a replay hub: no agent at all.
pub fn replay(
  observations: List(observation.Observation),
  saver: option.Option(service.Saver),
) -> Rig {
  replay_with(observations, [], saver)
}

/// A replay rig that already holds probes, as a capture with probe records
/// would.
pub fn replay_with(
  observations: List(observation.Observation),
  probes: List(probe_book.ProbeRecord),
  saver: option.Option(service.Saver),
) -> Rig {
  let config =
    hub.Config(
      cadence_ms: 0,
      ring_capacity: 10,
      budget: Budget(100, 10),
      clock:,
      os: fn() { Error("no OS reader in this test") },
    )
  let assert Ok(log) = audit.start()
  let assert Ok(the_hub) = hub.start_replay(observations, config)
  let assert Ok(the_service) =
    service.start(service.Config(
      remote: None,
      hub: the_hub,
      audit: log,
      clock:,
      mode: mode(),
      saver:,
      marks: [],
      probes:,
    ))

  Rig(service: the_service, hub: the_hub, log:, seen: process.new_subject())
}

pub const all = [
  policy.Observe,
  policy.Summarize,
  policy.Profile,
  policy.Perturb,
  policy.Export,
  policy.Administer,
]

pub fn page(
  rig: Rig,
  name: String,
  grants: List(policy.Capability),
) -> seam.Page {
  service.page_for(rig.service, fixture.principal(name, grants))
}

/// The audit entries as one-line descriptions, oldest first.
pub fn trail(rig: Rig) -> List(String) {
  audit.tail(rig.log, 200)
  |> list_reverse
  |> list_map(audit.describe)
}

import gleam/list

fn list_reverse(items: List(a)) -> List(a) {
  list.reverse(items)
}

fn list_map(items: List(a), f: fn(a) -> b) -> List(b) {
  list.map(items, f)
}
