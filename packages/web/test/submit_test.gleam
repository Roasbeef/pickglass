//// Every form that acts on typed text carries the text in its own submit.
////
//// These tests send a `submit` event whose form data holds the field's value
//// and send no `input` event first. Before the fix the text reached the
//// server on a debounced `input` event, so a submit inside that window acted
//// on the previous value. A pass here means the request was built from the
//// submit alone.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import lustre/dev/query
import lustre/dev/simulate
import lustre/element
import pickglass_core/policy
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/key
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/wire
import support

fn form(class: String) -> query.Query {
  query.element(matching: query.and(query.tag("form"), query.class(class)))
}

fn forged(fields: List(#(String, json.Json))) -> decode.Dynamic {
  let text =
    json.object([
      #(
        "detail",
        json.object([
          #(
            "formData",
            json.array(fields, fn(entry) {
              json.preprocessed_array([json.string(entry.0), entry.1])
            }),
          ),
        ]),
      ),
    ])
    |> json.to_string

  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

// The checkpoint name used is the one in the submit, so a name typed an
// instant before Enter is not replaced by an older draft or by a numbered
// default.
pub fn a_checkpoint_name_comes_from_the_submit_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.submit(on: form("checkpoint-form"), fields: [
      #("name", "after-the-fix"),
    ])

  assert simulate.model(sim).ui.last_request
    == Some(msg.TakeCheckpoint("after-the-fix"))
}

// The filter step is built from the pattern in the submit.
pub fn a_filter_step_uses_the_pattern_in_the_submit_test() {
  let sim =
    support.simulation(on: page.Profile)
    |> simulate.submit(on: form("filter-add"), fields: [
      #("pattern", "loom@runtime"),
    ])

  assert simulate.model(sim).ui.last_request
    == Some(msg.AddFilter(msg.FocusFilter, "loom@runtime"))
}

// The plan form sends the modules in the submit. The target is a select whose
// change is sent as soon as it is made, so it is chosen first.
pub fn a_plan_uses_the_modules_in_the_submit_test() {
  let sim =
    support.simulation(on: page.Probes)
    |> simulate.event(
      on: query.element(matching: query.test_id("draft-target")),
      name: "change",
      data: [
        #(
          "target",
          json.object([
            #("value", json.string(key.to_string(key.indexed("proc", 1)))),
          ]),
        ),
      ],
    )
    |> simulate.submit(on: form("plan-form"), fields: [
      #("modules", "loom@runtime@keeper lists"),
    ])

  let assert Some(msg.PlanProbe(draft)) = simulate.model(sim).ui.last_request

  assert draft.kind == policy.Counters
  assert draft.modules == ["loom@runtime@keeper", "lists"]
}

// The call trace of one process is made from the submit's modules.
pub fn a_process_call_trace_uses_the_modules_in_the_submit_test() {
  let sim =
    support.simulation(on: page.ProcessDetail)
    |> simulate.submit(on: form("trace-process"), fields: [
      #("modules", "lists gleam@list"),
    ])

  assert simulate.model(sim).ui.last_request
    == Some(msg.TraceProcess(fixture.keeper_key(), ["lists", "gleam@list"]))
}

// The "trace calls instead" form of a pending plan does the same.
pub fn a_trace_instead_uses_the_modules_in_the_submit_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.submit(on: form("trace-instead"), fields: [
      #("modules", "lists"),
    ])

  let assert Some(msg.TraceCallsInstead(_, modules)) =
    simulate.model(sim).ui.last_request

  assert modules == ["lists"]
}

// A submit that names a different field, names two, or carries text that is
// not text or is past the bound is a decode failure, so `update` never runs.
pub fn a_forged_submit_is_refused_by_its_decoder_test() {
  let decoder = wire.form_decoder("modules")
  let accepted = fn(fields) {
    decode.run(forged(fields), decoder) |> result.is_ok
  }

  assert accepted([#("modules", json.string("lists"))])
  assert !accepted([#("other", json.string("lists"))])
  assert !accepted([])
  assert !accepted([
    #("modules", json.string("lists")),
    #("extra", json.string("x")),
  ])
  assert !accepted([
    #("modules", json.string(string.repeat("a", wire.max_text + 1))),
  ])
  assert !accepted([#("modules", json.int(3))])
}

// The plan form carries exactly one `modules` field whatever the kind, so the
// submit names one field and text typed before a kind switch is not thrown
// away with the element. Only the class says whether the kind uses it.
pub fn the_modules_field_is_one_element_for_every_kind_test() {
  let drawn = fn(kind) {
    let #(model, _) =
      app.update(
        fn(_) { panic as "no request expected" },
        app.init(fixture.start(page.Probes, page.Files)),
        msg.Ui(msg.DraftKind(kind)),
      )

    app.view(model) |> element.to_string
  }

  list.each(
    [policy.Counters, policy.Sampling, policy.CallTree, policy.SchedulingGc],
    fn(kind) {
      let html = drawn(kind)

      assert support.count(html, "name=\"modules\"") == 1
      assert !string.contains(html, "type=\"hidden\" name=\"modules\"")
    },
  )

  assert string.contains(drawn(policy.Sampling), "field field-off")
  assert !string.contains(drawn(policy.CallTree), "field field-off")
}
