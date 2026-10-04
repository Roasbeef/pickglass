import fixture
import gleam/erlang/process
import gleam/int
import gleam/list
import pickglass/hub
import pickglass/observation.{Budget}
import pickglass/remote
import pickglass_core/wire

fn config() -> hub.Config {
  hub.Config(
    cadence_ms: 0,
    ring_capacity: 5,
    budget: Budget(100, 10),
    clock: fn() { 1_790_000_000_000 },
    os: fn() { Error("no OS reader in this test") },
  )
}

fn censuses(requests: List(wire.Request)) -> Int {
  list.count(requests, fn(request) {
    case request {
      wire.AskCensus(..) -> True
      _ -> False
    }
  })
}

// An agent that takes a moment to answer a census, so a second tick lands
// while the first pass is still running.
fn slow(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskCensus(..) -> {
      process.sleep(150)

      fixture.healthy(request)
    }
    other -> fixture.healthy(other)
  }
}

pub fn pages_share_one_census_per_pass_test() {
  let seen = process.new_subject()
  let assert Ok(the_hub) =
    hub.start_live(fixture.fake_remote(seen, slow), config())
  let a = process.new_subject()
  let b = process.new_subject()

  hub.subscribe(the_hub, a)
  hub.subscribe(the_hub, b)

  // Both pages get the one observation.
  let assert Ok(hub.Observed(first_a)) = process.receive(a, 3000)
  let assert Ok(hub.Observed(first_b)) = process.receive(b, 3000)

  assert first_a.seq == first_b.seq
  assert censuses(fixture.drain(seen, 100)) == 1

  // Two ticks inside one pass still make one census.
  hub.tick(the_hub)
  hub.tick(the_hub)

  let assert Ok(hub.Observed(_)) = process.receive(a, 3000)
  let assert Ok(hub.Observed(_)) = process.receive(b, 3000)

  assert censuses(fixture.drain(seen, 400)) == 1
  assert hub.status(the_hub).passes == 2
}

pub fn nobody_watching_means_no_collection_test() {
  let seen = process.new_subject()
  let assert Ok(the_hub) =
    hub.start_live(fixture.fake_remote(seen, fixture.healthy), config())

  hub.tick(the_hub)
  hub.tick(the_hub)

  // Reading the ring is not a reason to collect either.
  assert hub.latest(the_hub) == []
  assert fixture.drain(seen, 150) == []
}

pub fn a_page_that_exits_is_dropped_test() {
  let seen = process.new_subject()
  let assert Ok(the_hub) =
    hub.start_live(fixture.fake_remote(seen, fixture.healthy), config())
  let done = process.new_subject()

  let _ =
    process.spawn(fn() {
      let mine = process.new_subject()

      hub.subscribe(the_hub, mine)
      process.send(done, Nil)
    })
  let assert Ok(Nil) = process.receive(done, 1000)

  assert wait_for_subscribers(the_hub, 0, 40)
}

fn wait_for_subscribers(the_hub: hub.Hub, wanted: Int, tries: Int) -> Bool {
  case hub.status(the_hub).subscribers == wanted, tries > 0 {
    True, _ -> True
    False, True -> {
      process.sleep(25)

      wait_for_subscribers(the_hub, wanted, tries - 1)
    }
    False, False -> False
  }
}

pub fn the_ring_keeps_the_newest_passes_test() {
  let seen = process.new_subject()
  let assert Ok(the_hub) =
    hub.start_live(fixture.fake_remote(seen, fixture.healthy), config())
  let updates = process.new_subject()

  hub.subscribe(the_hub, updates)

  list.each(fixture.numbers(7), fn(_) {
    let assert Ok(hub.Observed(_)) = process.receive(updates, 3000)

    // The pass ends a moment after its observation is published.
    process.sleep(50)
    hub.tick(the_hub)
  })
  let assert Ok(hub.Observed(_)) = process.receive(updates, 3000)

  let ring = hub.latest(the_hub)

  assert list.length(ring) == 5
  assert list.map(ring, fn(o) { o.seq })
    == list.sort(list.map(ring, fn(o) { o.seq }), fn(a, b) { int.compare(b, a) })
}

pub fn a_silent_target_is_reported_lost_once_test() {
  let seen = process.new_subject()
  let silent = fn(_) { Error(remote.TimedOut) }
  let assert Ok(the_hub) =
    hub.start_live(fixture.fake_remote(seen, silent), config())
  let updates = process.new_subject()

  hub.subscribe(the_hub, updates)
  list.each(fixture.numbers(6), fn(_) {
    hub.tick(the_hub)
    process.sleep(60)
  })
  process.sleep(150)

  let received = fixture.drain(updates, 50)
  let lost =
    list.count(received, fn(update) {
      case update {
        hub.TargetLost(_) -> True
        hub.Observed(_) -> False
      }
    })

  assert lost == 1
  assert hub.status(the_hub).health == hub.Lost
}

pub fn a_replay_hub_serves_its_observations_and_never_collects_test() {
  let assert Ok(the_hub) =
    hub.start_replay(
      [fixture.observation(0, 1000), fixture.observation(1, 3000)],
      config(),
    )
  let updates = process.new_subject()

  hub.subscribe(the_hub, updates)
  hub.tick(the_hub)

  let assert Ok(hub.Observed(newest)) = process.receive(updates, 1000)

  assert newest.seq == 1
  assert list.map(hub.latest(the_hub), fn(o) { o.seq }) == [1, 0]
  assert process.receive(updates, 150) == Error(Nil)
}
