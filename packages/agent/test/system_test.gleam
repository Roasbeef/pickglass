import gleam/list
import pickglass_agent/system.{Available, Unavailable}

// The facts describe this node: at least one scheduler, a release and a
// positive uptime.
pub fn facts_describe_the_node_test() {
  let facts = system.read().facts

  assert facts.schedulers >= 1
  assert facts.schedulers_online >= 1
  assert facts.uptime_ms >= 0
  assert facts.word_size == 8 || facts.word_size == 4
  assert facts.otp_release != ""
  assert facts.emulator_flavor != ""
}

// Carriers are summed per allocator, and bytes in allocated blocks never
// exceed the bytes the carriers hold. A node without the `instrument` module
// says why instead of reporting zero.
pub fn carriers_are_summed_or_unavailable_test() {
  case system.read().carriers {
    Unavailable(reason) -> {
      assert reason != ""
    }
    Available(rows) -> {
      assert rows != []
      assert list.all(rows, fn(row) {
        row.carriers >= 1 && row.used_bytes <= row.total_bytes
      })
    }
  }
}
