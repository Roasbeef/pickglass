import fixtures
import gleam/json
import gleam/list
import pickglass_core/profile
import pickglass_core/profile/activity.{
  IncludeWaiting, OnScheduler, OnSchedulerOnly, Unstated, Waiting,
}
import pickglass_core/profile/codec

fn status(text: String) -> List(#(String, String)) {
  [activity.status_label(text)]
}

fn mixed() -> profile.Profile {
  fixtures.labelled([
    #(["main", "work"], 4, status("running")),
    #(["main", "work", "sort"], 3, status("runnable")),
    #(["main", "loop", "recv"], 20, status("waiting")),
    #(["main", "loop", "recv"], 2, status("suspended")),
    #(["main", "gc"], 1, status("garbage_collecting")),
  ])
}

pub fn statuses_classify_test() {
  assert activity.of_status("running") == OnScheduler
  assert activity.of_status("runnable") == OnScheduler
  assert activity.of_status("garbage_collecting") == OnScheduler
  assert activity.of_status("waiting") == Waiting
  assert activity.of_status("suspended") == Waiting
  assert activity.of_status("exiting") == Unstated
  assert activity.of_status("") == Unstated
}

// The three counts partition the total, so the coverage line can quote them
// side by side without any sample counted twice or lost.
pub fn split_adds_up_to_the_total_test() {
  let p = mixed()
  let column = fixtures.column(p)
  let counts = activity.split(p, column)

  assert counts == activity.Split(on_scheduler: 8, waiting: 22, unstated: 0)
  assert activity.split_total(counts) == profile.total(p, column)
}

pub fn restrict_keeps_only_scheduler_samples_test() {
  let p = mixed()
  let column = fixtures.column(p)
  let on_cpu = activity.restrict(p, OnSchedulerOnly)

  assert profile.total(on_cpu, column) == 8
  assert list.length(profile.samples(on_cpu)) == 3
  assert activity.split(on_cpu, column).waiting == 0

  // Including waiting samples changes nothing about the profile.
  assert activity.restrict(p, IncludeWaiting) == p
}

// A profile read from a capture written before statuses were kept has no
// label at all. Nothing says those samples were idle, so they stay.
pub fn unlabelled_samples_are_kept_and_counted_apart_test() {
  let p = fixtures.calls([#(["a"], 5), #(["b"], 7)])
  let column = fixtures.column(p)

  assert activity.has_status(p) == False
  assert activity.split(p, column)
    == activity.Split(on_scheduler: 0, waiting: 0, unstated: 12)
  assert profile.total(activity.restrict(p, OnSchedulerOnly), column) == 12
}

pub fn all_waiting_profile_restricts_to_nothing_test() {
  let p =
    fixtures.labelled([
      #(["main", "recv"], 9, status("waiting")),
      #(["main", "recv"], 1, status("waiting")),
    ])
  let column = fixtures.column(p)

  assert profile.total(activity.restrict(p, OnSchedulerOnly), column) == 0
  assert activity.split(p, column).waiting == 10
}

// The status travels in a capture as an ordinary label, so a profile read
// back from a capture splits the same way.
pub fn status_survives_the_capture_codec_test() {
  let p = mixed()
  let text = json.to_string(codec.encode(p))
  let assert Ok(back) = json.parse(text, codec.decoder())
  let column = fixtures.column(back)

  assert activity.split(back, column) == activity.split(p, column)
}

pub fn inclusion_text_names_the_choice_test() {
  assert activity.inclusion_text(OnSchedulerOnly)
    == "running and runnable samples"
}
