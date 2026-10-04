import gleam/list
import pickglass_agent/binaries
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid}

@external(erlang, "binary", "copy")
fn copy(text: String, times: Int) -> String

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

// A process that holds `count` distinct large binaries until it is killed.
fn holder(count: Int, size: Int) -> Pid {
  let #(pid, _) =
    ffi_proc.spawn_opt(
      fn() {
        let held = list.map(list.repeat(0, count), fn(_) { copy("x", size) })

        sleep(30_000)

        let _ = list.length(held)

        Nil
      },
      [ffi_proc.Monitor],
    )

  sleep(200)

  pid
}

fn stop(pid: Pid) -> Nil {
  let _ = ffi_proc.exit_with(pid, ffi_proc.Kill)

  Nil
}

// The count and byte total cover every reference, and the listing is the
// largest K in size order with a reference count each.
pub fn a_holder_reports_its_binaries_test() {
  let pid = holder(30, 1000)
  let assert Ok(report) = binaries.read(pid, 5)

  assert report.count >= 30
  assert report.bytes >= 30_000
  assert list.length(report.entries) == 5

  let assert [first, ..] = report.entries

  assert first.bytes >= 1000
  assert first.refc >= 1
  assert first.address != ""

  stop(pid)
}

// A process holding more references than the budget is refused, and the count
// says how many it holds.
pub fn a_holder_past_the_budget_is_refused_test() {
  let pid = holder(binaries.max_binaries + 1, 70)

  assert binaries.read(pid, 5)
    == Error(binaries.TooMany(binaries.max_binaries + 1))

  stop(pid)
}

// A process that has exited is gone, not an empty report.
pub fn an_exited_process_is_gone_test() {
  let pid = holder(1, 100)

  stop(pid)
  sleep(100)

  assert binaries.read(pid, 5) == Error(binaries.Gone)
}
