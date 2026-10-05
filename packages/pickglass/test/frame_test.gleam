import gleam/list
import gleam/string
import pickglass/frame

const click = "{\"kind\":1,\"path\":\"0\\t1\",\"name\":\"click\",\"event\":{}}"

pub fn an_event_with_exactly_its_keys_passes_test() {
  assert frame.check(click) == Ok(Nil)
  assert frame.check(
      "{\"event\":{\"target\":{\"value\":\"x\"}},\"name\":\"input\",\"kind\":1,\"path\":\"2\"}",
    )
    == Ok(Nil)
}

pub fn a_wheel_event_with_exactly_its_keys_passes_test() {
  assert frame.check(
      "{\"kind\":1,\"path\":\"0\\t1\",\"name\":\"wheel\",\"event\":{\"deltaY\":-100}}",
    )
    == Ok(Nil)
  assert frame.check(
      "{\"kind\":1,\"path\":\"0\",\"name\":\"wheel\",\"event\":{},\"principal\":\"x\"}",
    )
    == Error("unexpected keys")
}

pub fn an_extra_key_is_refused_test() {
  assert frame.check(
      "{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{},\"principal\":\"admin\"}",
    )
    == Error("unexpected keys")
  assert frame.check(
      "{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{},\"command\":\"detach\"}",
    )
    == Error("unexpected keys")
}

pub fn a_missing_key_is_refused_test() {
  assert frame.check("{\"kind\":1,\"path\":\"0\",\"name\":\"click\"}")
    == Error("unexpected keys")
}

pub fn only_events_and_batches_pass_test() {
  // Attribute, property and context messages: the application registers none.
  assert frame.check("{\"kind\":0,\"name\":\"a\",\"value\":\"b\"}")
    == Error("not an event or a batch of events")
  assert frame.check("{\"kind\":2,\"name\":\"a\",\"value\":1}")
    == Error("not an event or a batch of events")
  assert frame.check("{\"kind\":4,\"key\":\"a\",\"value\":1}")
    == Error("not an event or a batch of events")
  assert frame.check("{\"name\":\"click\"}")
    == Error("not an event or a batch of events")
}

pub fn an_event_the_views_never_attach_is_refused_test() {
  assert frame.check(
      "{\"kind\":1,\"path\":\"0\",\"name\":\"mouseover\",\"event\":{}}",
    )
    == Error("an event the views do not attach")
}

pub fn malformed_events_are_refused_test() {
  assert frame.check("{\"kind\":1,\"path\":0,\"name\":\"click\",\"event\":{}}")
    == Error("malformed event")
  assert frame.check(
      "{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":[]}",
    )
    == Error("malformed event")
}

pub fn not_json_is_refused_test() {
  assert frame.check("hello") == Error("not a JSON object")
  assert frame.check("[1,2]") == Error("not a JSON object")
  assert frame.check("") == Error("not a JSON object")
}

pub fn a_batch_of_events_passes_test() {
  assert frame.check(
      "{\"kind\":3,\"messages\":[" <> click <> "," <> click <> "]}",
    )
    == Ok(Nil)
}

pub fn one_bad_message_refuses_the_whole_batch_test() {
  let bad =
    "{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{},\"x\":1}"

  assert frame.check(
      "{\"kind\":3,\"messages\":[" <> click <> "," <> bad <> "]}",
    )
    == Error("unexpected keys")
}

pub fn batches_do_not_nest_and_are_bounded_test() {
  let nested =
    "{\"kind\":3,\"messages\":[{\"kind\":3,\"messages\":[" <> click <> "]}]}"
  let many =
    "{\"kind\":3,\"messages\":["
    <> string.join(list.repeat(click, frame.max_batch + 1), ",")
    <> "]}"

  assert frame.check(nested) == Error("not an event or a batch of events")
  assert frame.check(many) == Error("batch too large")
  assert frame.check("{\"kind\":3,\"messages\":[]}") == Error("malformed batch")
}

pub fn an_oversized_frame_is_refused_test() {
  let big = string.repeat("a", frame.max_bytes + 1)

  assert frame.check(big) == Error("frame too large")
}
