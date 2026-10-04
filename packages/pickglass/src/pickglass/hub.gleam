//// The observation hub: one collector, many pages.
////
//// Collecting from the target costs the target something, and a viewer with
//// five tabs open must not cost it five times. The hub is the single owner
//// of the agent link's polling. It runs one pass (`observation.collect`) per
//// cadence, keeps the newest observation and a bounded ring of earlier ones,
//// and pushes each new observation to every subscriber. A page subscribes
//// and reads; it has no way to start a collection.
////
//// A pass runs only while someone is subscribed: a viewer with no page open
//// leaves the target alone. When the first page subscribes and the newest
//// observation is older than one cadence (or there is none), the hub starts
//// a pass at once, so a page that opens is not blank for a whole interval.
//// Pages that subscribe while that pass runs wait for it, and the tick that
//// arrives mid-pass is skipped, so two pages and a timer still make one
//// census.
////
//// The pass runs in a weft task with a deadline, started relayed so the
//// hub's receive loop never blocks on the agent. Three passes in a row where
//// no reading succeeded mean the target is gone: the hub tells subscribers
//// once with `TargetLost`, and the service marks every pin dead.
////
//// A replay hub has no remote. It holds the observations of a capture file,
//// answers `latest` from them, and never collects, which is what
//// `pickglass view` serves.
////
//// ## Flow
////
//// - `start_live` and `start_replay` create the actor.
//// - `subscribe` adds a page; the hub monitors its process and drops it
////   when it exits.
//// - `Tick` (the timer, or `tick` in tests) starts a pass when idle and
////   someone is subscribed; `Collected` ends it.

import gleam/erlang/process.{type Down, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import pickglass/observation.{type Observation}
import pickglass/remote.{type Remote}
import pickglass/ring.{type Ring}
import weft
import weft/actor

/// How many passes in a row may find nothing before the target is called
/// lost.
pub const lost_after_failures = 3

/// How long a whole pass may run, in milliseconds. The pass makes four asks
/// of up to `observation.ask_deadline_ms` each, and the deadline kills it
/// if they do not finish.
pub const pass_deadline_ms = 45_000

/// The hub's settings.
pub type Config {
  Config(
    /// How often a pass runs while a page is subscribed, in milliseconds.
    /// Zero disables the timer, which tests use to drive `tick` by hand.
    cadence_ms: Int,
    /// How many observations the ring keeps.
    ring_capacity: Int,
    budget: observation.Budget,
    /// Wall-clock milliseconds.
    clock: fn() -> Int,
  )
}

/// What a subscriber receives.
pub type Update {
  /// A new observation.
  Observed(Observation)

  /// The target stopped answering. Sent once.
  TargetLost(reason: String)
}

/// A handle to the hub.
pub type Hub {
  Hub(subject: Subject(Message))
}

/// What the hub knows about itself, for tests and the Overview's header.
pub type Status {
  Status(subscribers: Int, passes: Int, failures: Int, health: Health)
}

/// Whether the target is answering.
pub type Health {
  Healthy
  Lost
}

/// What the actor receives.
pub opaque type Message {
  Subscribe(Subject(Update))
  Watch(Subject(Update))
  Unsubscribe(Subject(Update))
  Latest(reply: Subject(List(Observation)))
  GetStatus(reply: Subject(Status))
  Tick
  Collected(weft.Pulled(Observation, String))
  SubscriberDown(Down)
}

type Subscriber {
  Subscriber(subject: Subject(Update), monitor: process.Monitor)
}

type Phase {
  Idle
  Collecting
}

type State {
  State(
    remote: Option(Remote),
    config: Config,
    sink: Subject(weft.Pulled(Observation, String)),
    ring: Ring(Observation),
    subscribers: List(Subscriber),
    watchers: List(Subject(Update)),
    phase: Phase,
    passes: Int,
    failures: Int,
    health: Health,
    step: observation.SchedulerStep,
  )
}

/// Settings with a two-second cadence and a ring of 300 observations, ten
/// minutes at that cadence.
///
/// ## Examples
///
/// ```gleam
/// hub.default_config(ffi_dist.system_time_ms)
/// ```
pub fn default_config(clock: fn() -> Int) -> Config {
  Config(
    cadence_ms: 2000,
    ring_capacity: 300,
    budget: observation.Budget(max_scanned: 200_000, top_k: 200),
    clock:,
  )
}

/// Start a hub that polls a remote.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(hub) = hub.start_live(remote, hub.default_config(clock))
/// ```
pub fn start_live(remote: Remote, config: Config) -> Result(Hub, String) {
  start(Some(remote), [], config)
}

/// Start a hub that serves the observations of a capture and never
/// collects. `observations` is oldest first.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(hub) = hub.start_replay(observations, config)
/// ```
pub fn start_replay(
  observations: List(Observation),
  config: Config,
) -> Result(Hub, String) {
  start(None, observations, config)
}

fn start(
  remote: Option(Remote),
  observations: List(Observation),
  config: Config,
) -> Result(Hub, String) {
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      let sink = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(sink, Collected)
        |> process.select_monitors(SubscriberDown)
      let ring =
        list.fold(observations, ring.new(config.ring_capacity), ring.push)

      actor.initialised(State(
        remote:,
        config:,
        sink:,
        ring:,
        subscribers: [],
        watchers: [],
        phase: Idle,
        passes: list.length(observations),
        failures: 0,
        health: Healthy,
        step: observation.TurnOnAndRead,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)

  let builder = case remote, config.cadence_ms > 0 {
    Some(_), True ->
      actor.periodic(builder, every: config.cadence_ms, sending: Tick)
    Some(_), False | None, _ -> builder
  }

  case actor.start(builder) {
    Ok(started) -> Ok(Hub(subject: started.data))
    Error(_) -> Error("the observation hub did not start")
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Subscribe(subject) -> actor.continue(subscribe_to(state, subject))
    Watch(subject) ->
      actor.continue(State(..state, watchers: [subject, ..state.watchers]))
    Unsubscribe(subject) -> actor.continue(unsubscribe_from(state, subject))

    Latest(reply) -> {
      process.send(reply, ring.to_list(state.ring))

      actor.continue(state)
    }

    GetStatus(reply) -> {
      process.send(
        reply,
        Status(
          subscribers: list.length(state.subscribers),
          passes: state.passes,
          failures: state.failures,
          health: state.health,
        ),
      )

      actor.continue(state)
    }

    // The timer fired, or a test asked for a pass. A pass starts only when
    // none is running and someone is watching.
    Tick -> actor.continue(maybe_collect(state))

    Collected(pulled) -> actor.continue(finish_pass(state, pulled))

    // A page's process exited; its subscription goes with it.
    SubscriberDown(down) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(subscriber) {
            subscriber.monitor != down_monitor(down)
          }),
        ),
      )
  }
}

fn down_monitor(down: Down) -> process.Monitor {
  case down {
    process.ProcessDown(monitor:, ..) -> monitor
    process.PortDown(monitor:, ..) -> monitor
  }
}

// A new subscriber gets the newest observation at once, so a page that opens
// draws immediately. It also starts a pass when the newest observation is
// older than a cadence, which is how a hub with no timer reading still serves
// a first page.
fn subscribe_to(state: State, subject: Subject(Update)) -> State {
  case process.subject_owner(subject) {
    Error(Nil) -> state
    Ok(pid) -> {
      let subscriber = Subscriber(subject:, monitor: process.monitor(pid))

      case ring.newest(state.ring) {
        Ok(newest) -> process.send(subject, Observed(newest))
        Error(Nil) -> Nil
      }

      let state = State(..state, subscribers: [subscriber, ..state.subscribers])

      case is_stale(state) {
        True -> maybe_collect(state)
        False -> state
      }
    }
  }
}

fn unsubscribe_from(state: State, subject: Subject(Update)) -> State {
  State(
    ..state,
    subscribers: list.filter(state.subscribers, fn(subscriber) {
      case subscriber.subject == subject {
        True -> {
          process.demonitor_process(subscriber.monitor)

          False
        }
        False -> True
      }
    }),
  )
}

fn is_stale(state: State) -> Bool {
  case ring.newest(state.ring) {
    Error(Nil) -> True
    Ok(newest) -> state.config.clock() - newest.at_ms >= state.config.cadence_ms
  }
}

fn maybe_collect(state: State) -> State {
  case state.remote, state.phase, state.subscribers {
    Some(remote), Idle, [_, ..] -> start_pass(state, remote)
    Some(_), Idle, [] | Some(_), Collecting, _ | None, _, _ -> state
  }
}

fn start_pass(state: State, remote: Remote) -> State {
  let seq = state.passes
  let step = state.step
  let config = state.config

  let _ =
    weft.new([
      fn() {
        Ok(observation.collect(remote, config.budget, seq, step, config.clock))
      },
    ])
    |> weft.deadline(pass_deadline_ms)
    |> weft.start_relayed(to: state.sink)

  State(..state, phase: Collecting, step: observation.ReadOnly)
}

fn finish_pass(
  state: State,
  pulled: weft.Pulled(Observation, String),
) -> State {
  case pulled {
    weft.PulledOutcome(weft.Completed(_, observation)) ->
      record(state, observation)

    // Every other end of the pass, a crash, a deadline or a cancellation,
    // is a pass that found nothing.
    weft.PulledOutcome(_) -> record_failure(state)

    // The run is over; the next tick may start another.
    weft.AllDelivered | weft.RunLost(_) -> State(..state, phase: Idle)

    weft.NotYet -> state
  }
}

fn record(state: State, observation: Observation) -> State {
  let state =
    State(
      ..state,
      ring: ring.push(state.ring, observation),
      passes: state.passes + 1,
    )

  case observation.answered(observation) {
    True -> {
      broadcast(state, Observed(observation))

      State(..state, failures: 0, health: Healthy)
    }
    False -> record_failure(state)
  }
}

fn record_failure(state: State) -> State {
  let failures = state.failures + 1

  case failures >= lost_after_failures, state.health {
    True, Healthy -> {
      let lost = TargetLost("the agent stopped answering")

      broadcast(state, lost)
      list.each(state.watchers, fn(watcher) { process.send(watcher, lost) })

      State(..state, failures:, health: Lost)
    }
    True, Lost | False, _ -> State(..state, failures:)
  }
}

fn broadcast(state: State, update: Update) -> Nil {
  list.each(state.subscribers, fn(subscriber) {
    process.send(subscriber.subject, update)
  })
}

/// Subscribe a page. Its process is monitored, and the subscription ends
/// when the process exits or `unsubscribe` is called. The newest
/// observation, if any, is sent at once.
///
/// ## Examples
///
/// ```gleam
/// hub.subscribe(hub, updates)
/// ```
pub fn subscribe(hub: Hub, subscriber: Subject(Update)) -> Nil {
  process.send(hub.subject, Subscribe(subscriber))
}

/// Register a watcher. It is sent `TargetLost` and nothing else, and it does
/// not count as a subscriber, so watching never causes a collection.
pub fn watch(hub: Hub, watcher: Subject(Update)) -> Nil {
  process.send(hub.subject, Watch(watcher))
}

/// End a subscription.
pub fn unsubscribe(hub: Hub, subscriber: Subject(Update)) -> Nil {
  process.send(hub.subject, Unsubscribe(subscriber))
}

/// The ring's observations, newest first.
///
/// ## Examples
///
/// ```gleam
/// hub.latest(hub)
/// ```
pub fn latest(hub: Hub) -> List(Observation) {
  process.call(hub.subject, 5000, fn(reply) { Latest(reply) })
}

/// Ask the hub for a pass, as its timer does. The hub runs one only if none
/// is running and a page is subscribed.
pub fn tick(hub: Hub) -> Nil {
  process.send(hub.subject, Tick)
}

/// The hub's counters and health.
pub fn status(hub: Hub) -> Status {
  process.call(hub.subject, 5000, fn(reply) { GetStatus(reply) })
}
