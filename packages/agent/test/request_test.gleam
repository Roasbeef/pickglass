import pickglass_agent/internal/ffi_term.{type Term, coerce}
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
      "lists",
      "sort",
      AllProcesses,
      request.min_deadline_ms,
    ))
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
