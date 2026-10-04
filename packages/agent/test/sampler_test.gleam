import gleam/list
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{
  type Pid, type Reference, type Term, coerce,
}
import pickglass_agent/sampler

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

@external(erlang, "pg_test_ffi", "await")
fn await(reference: Reference, timeout_ms: Int) -> Term

type Meter =
  #(String, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int)

type Snapshot =
  #(
    String,
    Int,
    String,
    String,
    Meter,
    List(#(String, String, Int, Term)),
    List(#(Int, String, List(Int))),
  )

// A process that never blocks, so every sample finds it in `spin`.
fn spin(count: Int) -> Nil {
  spin(count + 1)
}

fn busy_target() -> Pid {
  let #(pid, _) = ffi_proc.spawn_opt(fn() { spin(0) }, [ffi_proc.Monitor])

  pid
}

fn config(
  targets: List(Pid),
  rate_hz: Int,
  duration_ms: Int,
  max_samples: Int,
) -> sampler.Config {
  sampler.Config(ffi_proc.self(), 7, targets, rate_hz, duration_ms, max_samples)
}

fn start(config: sampler.Config) -> Pid {
  let assert Ok(pid) = sampler.start(config, 4_000_000) as "a sampler starts"

  pid
}

fn snapshot(pid: Pid) -> Snapshot {
  let reference = ffi_proc.make_ref()

  sampler.read(pid, ffi_proc.self(), reference)

  coerce(await(reference, 3000))
}

// A probe samples its target at about the requested rate, stops itself at
// its deadline, and its stacks name the function the target was running.
pub fn a_probe_stops_at_its_deadline_test() {
  let target = busy_target()
  let pid = start(config([target], 100, 300, 100_000))

  sleep(700)

  let #(tag, id, phase, why, meter, frames, stacks) = snapshot(pid)
  let #(method, requested, _, rounds, samples, elapsed, depth, _, _, _, _, _) =
    meter

  assert tag == "stacks"
  assert id == 7
  assert phase == "finished"
  assert why == "deadline"
  assert method == "polled_current_stacktrace"
  assert requested == 100
  assert rounds >= 5
  assert samples == rounds
  assert elapsed >= 290 && elapsed <= 700
  assert depth >= 1 && depth <= sampler.depth_probe
  assert stacks != []
  assert list.any(frames, fn(frame) {
    frame.0 == "sampler_test" && frame.1 == "spin"
  })

  let _ = ffi_proc.exit_with(target, ffi_proc.Kill)
  let _ = ffi_proc.exit_with(pid, ffi_proc.Kill)
}

// The sample budget is exact: it is checked before each sample, not rounded
// up to a whole round.
pub fn the_sample_budget_stops_the_probe_test() {
  let target = busy_target()
  let other = busy_target()
  let pid = start(config([target, other], 200, 5000, 5))

  sleep(300)

  let #(_, _, phase, why, meter, _, _) = snapshot(pid)

  assert phase == "finished"
  assert why == "sample_budget"
  assert meter.4 == 5

  let _ = ffi_proc.exit_with(target, ffi_proc.Kill)
  let _ = ffi_proc.exit_with(other, ffi_proc.Kill)
  let _ = ffi_proc.exit_with(pid, ffi_proc.Kill)
}

// When every target has exited the probe ends and says so, with the targets
// counted as gone.
pub fn a_probe_ends_when_its_targets_are_gone_test() {
  let #(target, _) = ffi_proc.spawn_opt(fn() { sleep(100) }, [ffi_proc.Monitor])
  let pid = start(config([target], 50, 5000, 100_000))

  sleep(500)

  let #(_, _, phase, why, meter, _, _) = snapshot(pid)

  assert phase == "finished"
  assert why == "targets_gone"
  assert meter.8 == 1

  let _ = ffi_proc.exit_with(pid, ffi_proc.Kill)
}

// A stop reply carries the final snapshot, marks a running probe stopped and
// ends the sampler.
pub fn a_stop_replies_and_ends_the_sampler_test() {
  let target = busy_target()
  let pid = start(config([target], 100, 5000, 100_000))

  sleep(200)

  let reference = ffi_proc.make_ref()

  sampler.stop(pid, ffi_proc.self(), reference)

  let reply: Snapshot = coerce(await(reference, 3000))

  assert reply.2 == "stopped"
  assert reply.3 == "stopped"

  sleep(100)

  assert !ffi_proc.is_alive(pid)

  let _ = ffi_proc.exit_with(target, ffi_proc.Kill)
}

// A sampler never outlives its agent: it monitors the agent and exits when
// the agent does, so a killed agent leaves no sampler running.
pub fn a_sampler_ends_with_its_agent_test() {
  let target = busy_target()
  let #(agent, _) =
    ffi_proc.spawn_opt(fn() { sleep(60_000) }, [ffi_proc.Monitor])
  let pid = start(sampler.Config(agent, 7, [target], 100, 60_000, 1_000_000))

  sleep(100)

  assert ffi_proc.is_alive(pid)

  let _ = ffi_proc.exit_with(agent, ffi_proc.Kill)

  sleep(200)

  assert !ffi_proc.is_alive(pid)

  let _ = ffi_proc.exit_with(target, ffi_proc.Kill)
}

// The depth measurement sees the node's limit and not the length of the
// measuring recursion: the default `backtrace_depth` is 8, and a node that
// raises it reports a larger number, up to the probe's own depth.
pub fn the_backtrace_depth_is_measured_test() {
  assert sampler.depth_limit() >= 8
  assert sampler.depth_limit() <= sampler.depth_probe
}
