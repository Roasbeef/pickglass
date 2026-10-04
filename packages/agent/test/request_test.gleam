import gleam/list
import pickglass_agent/internal/ffi_term.{type Term, coerce}
import pickglass_agent/internal/ffi_trace.{TimeAndMemory, TimeOnly}
import pickglass_agent/request.{
  AllProcesses, Census, Detach, Malformed, NotARequest, Ping, Valid,
}

@external(erlang, "erlang", "self")
fn self() -> ffi_term.Pid

@external(erlang, "erlang", "make_ref")
fn make_ref() -> ffi_term.Reference

fn envelope(request: a) -> Term {
  coerce(#("pg", 1, self(), make_ref(), request))
}

fn decoded_request(message: Term) -> Result(request.Request, String) {
  case request.decode(message) {
    Valid(envelope) -> Ok(envelope.request)
    Malformed(_, _, detail) -> Error(detail)
    NotARequest -> Error("not a request")
  }
}

pub fn simple_requests_decode_test() {
  assert decoded_request(envelope(#("ping"))) == Ok(Ping)
  assert decoded_request(envelope(#("detach"))) == Ok(Detach)
}

// Numeric limits are clamped to the agent's budget, not refused.
pub fn census_limits_are_clamped_test() {
  assert decoded_request(envelope(#("census", 999_999_999, 0)))
    == Ok(Census(request.max_scan, 1))
}

pub fn targets_decode_test() {
  assert decoded_request(
      envelope(#("start_counters", "lists", "sort", #("all"), 5)),
    )
    == Ok(request.StartCounters(
      [request.Pattern("lists", "sort")],
      AllProcesses,
      request.min_deadline_ms,
      TimeOnly,
    ))
}

// A pattern set names several modules, each with its own function or `_`,
// and chooses whether `call_memory` is counted too.
pub fn counter_sets_decode_test() {
  assert decoded_request(
      envelope(#(
        "start_counter_set",
        [#("a", "run"), #("b", "_")],
        #("all"),
        5000,
        "time_and_memory",
      )),
    )
    == Ok(request.StartCounters(
      [request.Pattern("a", "run"), request.Pattern("b", "_")],
      AllProcesses,
      5000,
      TimeAndMemory,
    ))
  assert decoded_request(
      envelope(#("start_counter_set", [#("a", "run")], #("all"), 5000, "time")),
    )
    == Ok(request.StartCounters(
      [request.Pattern("a", "run")],
      AllProcesses,
      5000,
      TimeOnly,
    ))
}

pub fn malformed_counter_sets_are_refused_test() {
  let none: List(#(String, String)) = []
  let nine = [
    #("a", "_"),
    #("b", "_"),
    #("c", "_"),
    #("d", "_"),
    #("e", "_"),
    #("f", "_"),
    #("g", "_"),
    #("h", "_"),
    #("i", "_"),
  ]

  assert decoded_request(
      envelope(#("start_counter_set", none, #("all"), 5000, "time")),
    )
    |> is_error
  assert decoded_request(
      envelope(#("start_counter_set", nine, #("all"), 5000, "time")),
    )
    |> is_error
  assert decoded_request(
      envelope(#("start_counter_set", [#("a", 1)], #("all"), 5000, "time")),
    )
    |> is_error
  assert decoded_request(
      envelope(#("start_counter_set", [#("a", "b")], #("all"), 5000, "sideways")),
    )
    |> is_error
  assert decoded_request(
      envelope(#("start_counter_set", "lists", #("all"), 5000, "time")),
    )
    |> is_error
}

pub fn supervision_and_system_decode_test() {
  assert decoded_request(envelope(#("supervision", 999_999_999, 999_999_999)))
    == Ok(request.Supervision(request.max_scan, request.max_edges))
  assert decoded_request(envelope(#("supervision", 0, 0)))
    == Ok(request.Supervision(1, 1))
  assert decoded_request(envelope(#("system"))) == Ok(request.SystemReport)
  assert decoded_request(envelope(#("supervision", "a", 5))) |> is_error
  assert decoded_request(envelope(#("system", 1))) |> is_error
}

pub fn gc_and_measure_clamp_their_waits_test() {
  let token = request.Token("boot-1", 4)

  assert decoded_request(envelope(#("gc", #("boot-1", 4), 1)))
    == Ok(request.TargetedGc(token, request.min_gc_wait_ms))
  assert decoded_request(envelope(#("gc", #("boot-1", 4), 999_999)))
    == Ok(request.TargetedGc(token, request.max_gc_wait_ms))
  assert decoded_request(envelope(#("measure", #("boot-1", 4), 1)))
    == Ok(request.SelfMeasure(token, request.min_measure_wait_ms))
  assert decoded_request(envelope(#("measure", #("boot-1", 4), 999_999)))
    == Ok(request.SelfMeasure(token, request.max_measure_wait_ms))
  assert decoded_request(envelope(#("gc", "<0.1.0>", 100))) |> is_error
}

// The rate ceiling is a total across targets, so a probe over more pins gets
// a lower per-pin ceiling; the duration and the sample budget clamp to their
// own bounds.
pub fn stack_probes_clamp_their_budgets_test() {
  let one = [#("boot-1", 1)]
  let sixteen = pins(16)

  assert decoded_request(envelope(#("start_stacks", one, 999_999, 1, 0)))
    == Ok(request.StartStacks(
      [request.Token("boot-1", 1)],
      request.max_total_hz,
      request.min_stack_ms,
      1,
    ))
  assert decoded_request(
      envelope(#("start_stacks", one, 0, 999_999_999, 999_999_999)),
    )
    == Ok(request.StartStacks(
      [request.Token("boot-1", 1)],
      1,
      request.max_stack_ms,
      request.max_stack_samples,
    ))
  assert case
    decoded_request(envelope(#("start_stacks", sixteen, 999_999, 1000, 10)))
  {
    Ok(request.StartStacks(tokens, rate, _, _)) ->
      list.length(tokens) == 16 && rate == request.max_total_hz / 16
    _ -> False
  }
}

pub fn malformed_stack_probes_are_refused_test() {
  let none: List(#(String, Int)) = []
  let seventeen = pins(17)

  assert decoded_request(envelope(#("start_stacks", none, 10, 1000, 10)))
    |> is_error
  assert decoded_request(envelope(#("start_stacks", seventeen, 10, 1000, 10)))
    |> is_error
  assert decoded_request(
      envelope(#("start_stacks", [#("boot-1", 1)], "fast", 1000, 10)),
    )
    |> is_error
  assert decoded_request(envelope(#("start_stacks", "all", 10, 1000, 10)))
    |> is_error
  assert decoded_request(envelope(#("read_stacks", 3)))
    == Ok(request.ReadStacks(3))
  assert decoded_request(envelope(#("stop_stacks", 3)))
    == Ok(request.StopStacks(3))
  assert decoded_request(envelope(#("read_stacks", "x"))) |> is_error
}

// `owners` takes the census budget and clamps it the same way, and the
// allocation read takes a probe id.
pub fn owners_and_counter_memory_decode_test() {
  assert decoded_request(envelope(#("owners", 999_999_999, 0)))
    == Ok(request.Owners(request.max_scan, 1))
  assert decoded_request(envelope(#("owners", 100, 10)))
    == Ok(request.Owners(100, 10))
  assert decoded_request(envelope(#("read_counter_memory", 4)))
    == Ok(request.ReadCounterMemory(4))
  assert decoded_request(envelope(#("owners", 100))) |> is_error
  assert decoded_request(envelope(#("read_counter_memory", "x"))) |> is_error
}

pub fn process_detail_takes_a_token_test() {
  assert decoded_request(envelope(#("process_detail", #("boot-1", 4))))
    == Ok(request.ProcessDetail(request.Token("boot-1", 4)))
  assert decoded_request(envelope(#("process_detail", "<0.1.0>"))) |> is_error
  assert decoded_request(envelope(#("process_detail"))) |> is_error
}

// Anything that is not a well-formed envelope is ignored, and a bad request
// inside a good envelope is refused with a reason.
pub fn malformed_messages_are_classified_test() {
  assert request.decode(coerce(42)) == NotARequest
  assert request.decode(coerce(#("pg", 2, self(), make_ref(), #("ping"))))
    == NotARequest
  assert decoded_request(envelope(#("ping", "extra"))) |> is_error
  assert decoded_request(envelope(coerce(7))) |> is_error
  assert decoded_request(envelope(#("pin", 5))) |> is_error
  assert decoded_request(envelope(#("scheduler", "sideways"))) |> is_error
  assert decoded_request(
      envelope(#("start_counters", "lists", "sort", #("pins", []), 5)),
    )
    |> is_error
}

fn is_error(result: Result(a, e)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn clamp_test() {
  assert request.clamp(5, 1, 3) == 3
  assert request.clamp(-5, 1, 3) == 1
  assert request.clamp(2, 1, 3) == 2
}

fn pins(count: Int) -> List(#(String, Int)) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { #("boot-1", index + 1) })
}
