import gleam/int
import gleam/option.{None, Some}
import pickglass/os_reader
import pickglass_core/measure

// The two formats `ps -ww -axo pid=,ppid=,rss=,time=,lstart=,comm=` prints.
const macos =
  "  501     1  10240   0:01.50 Fri Oct  3 12:00:00 2026 /usr/bin/beam.smp
  777   501   2048   1:02.25 Fri Oct  3 12:00:05 2026 /opt/helper app
garbage line
"

const linux =
  "    42     1 204800 1-02:03:04 Fri Oct  3 12:00:00 2026 beam.smp
    43    42   4096 00:00:09 Fri Oct  3 12:00:07 2026 inet_gethost
    44    43   1024 00:00:00 Fri Oct  3 12:00:08 2026 sh
"

pub fn the_macos_table_parses_and_skips_what_it_cannot_read_test() {
  let rows = os_reader.parse_table(macos)

  assert rows
    == [
      os_reader.Row(
        pid: 501,
        parent: 1,
        rss_kib: 10_240,
        cpu_ms: 1500,
        started: "Fri Oct 3 12:00:00 2026",
        command: "/usr/bin/beam.smp",
      ),
      os_reader.Row(
        pid: 777,
        parent: 501,
        rss_kib: 2048,
        cpu_ms: 62_250,
        started: "Fri Oct 3 12:00:05 2026",
        command: "/opt/helper app",
      ),
    ]
}

pub fn the_linux_table_parses_with_day_prefixed_cpu_time_test() {
  let assert [first, ..] = os_reader.parse_table(linux)

  assert first.pid == 42
  assert first.cpu_ms == 86_400_000 + 2 * 3_600_000 + 3 * 60_000 + 4000
}

pub fn cpu_time_parses_every_form_ps_prints_test() {
  assert os_reader.parse_cpu_time("0:01.50") == Ok(1500)
  assert os_reader.parse_cpu_time("12:34") == Ok(754_000)
  assert os_reader.parse_cpu_time("01:02:03") == Ok(3_723_000)
  assert os_reader.parse_cpu_time("2-00:00:01") == Ok(172_801_000)
  assert os_reader.parse_cpu_time("soon") == Error(Nil)
  assert os_reader.parse_cpu_time("") == Error(Nil)
}

pub fn proc_status_gives_the_resident_set_and_its_anonymous_part_test() {
  let text =
    "Name:\tbeam.smp\nVmRSS:\t  2048 kB\nRssAnon:\t  1024 kB\nRssFile:\t 1024 kB\n"

  assert os_reader.parse_proc_status(text)
    == os_reader.ProcStatus(rss_kib: Some(2048), anon_kib: Some(1024))
}

pub fn a_status_without_the_fields_has_none_not_zero_test() {
  assert os_reader.parse_proc_status("Name:\tx\n")
    == os_reader.ProcStatus(rss_kib: None, anon_kib: None)
}

pub fn the_start_time_is_counted_from_the_last_parenthesis_test() {
  // A command name may contain spaces and parentheses.
  let stat =
    "42 (beam (smp) x) S 1 42 42 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 8 0 987654 1 2"

  assert os_reader.parse_proc_start(stat) == Ok("987654")
  assert os_reader.parse_proc_start("42 (short") == Error(Nil)
}

pub fn children_are_the_descendants_nearest_first_test() {
  let rows = os_reader.parse_table(linux)
  let children = os_reader.children_of(rows, 42)

  assert children
    == [
      os_reader.Row(
        pid: 43,
        parent: 42,
        rss_kib: 4096,
        cpu_ms: 9000,
        started: "Fri Oct 3 12:00:07 2026",
        command: "inet_gethost",
      ),
      os_reader.Row(
        pid: 44,
        parent: 43,
        rss_kib: 1024,
        cpu_ms: 0,
        started: "Fri Oct 3 12:00:08 2026",
        command: "sh",
      ),
    ]
}

pub fn a_cycle_in_the_table_cannot_loop_test() {
  let rows = [
    os_reader.Row(1, 2, 0, 0, "x", "a"),
    os_reader.Row(2, 1, 0, 0, "x", "b"),
  ]

  assert os_reader.children_of(rows, 1) == [os_reader.Row(2, 1, 0, 0, "x", "b")]
}

pub fn the_reader_reports_the_machines_own_process_test() {
  // The test VM is a process the table lists; its resident set is read, and
  // never reported as zero.
  let assert Ok(readings) = os_reader.read(own_pid())
  let assert Some(target) = os_reader.target_of(readings)
  let assert measure.Known(rss) = target.rss

  assert target.pid == own_pid()
  assert rss > 0
}

@external(erlang, "os", "getpid")
fn charlist_pid() -> List(Int)

@external(erlang, "erlang", "list_to_binary")
fn charlist_text(chars: List(Int)) -> String

fn own_pid() -> Int {
  let assert Ok(pid) = int.parse(charlist_text(charlist_pid()))

  pid
}
