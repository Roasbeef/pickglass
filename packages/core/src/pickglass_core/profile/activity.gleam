//// Whether a stack sample was taken while its process was on a scheduler or
//// waiting for a message.
////
//// A stack probe reads each target's current stack at a fixed rate, and the
//// BEAM reports the process status with every reading. On a node that is
//// mostly idle, nearly every reading finds a process in `receive`, so the
//// functions at the top of a profile are the ones that wait
//// (`gen_server:loop/5`, `gleam_erlang_ffi:select/2`) and not the ones that
//// work. The status is what tells the two apart, so `profile_from_stacks`
//// keeps it as a sample label under `status_key`, and this module reads it
//// back.
////
//// The choice of what to show is a typed one, `Inclusion`, and not a filter
//// pattern: `restrict` takes the choice and returns the profile with only
//// the samples it admits. Running and runnable samples are "on a scheduler
//// or ready to run", and so is a collecting process, because a collection
//// runs on the scheduler. Waiting and suspended samples are not. A sample
//// with no status, which is what a capture written before the status was
//// kept holds, is `Unstated`: it is neither claimed as running nor dropped
//// as idle, because nothing says which it was, and the split reports how
//// many there are.
////
//// ## Flow
////
//// `status_label` builds the label a sample carries. `of_sample` reads it
//// back, `split` counts a column by activity, and `restrict` applies an
//// `Inclusion`.

import gleam/int
import gleam/list
import pickglass_core/profile.{type Column, type Profile, type Sample}

/// The label key a sample's process status is stored under. The value is the
/// status text the agent reported, such as `"running"` or `"waiting"`.
pub const status_key = "pickglass::status"

/// What a sample's status says about the process at the moment it was read.
pub type Activity {
  /// The process was running, runnable, or collecting: on a scheduler or
  /// ready to run.
  OnScheduler

  /// The process was waiting for a message or suspended.
  Waiting

  /// The sample carries no status, or one this build does not classify.
  Unstated
}

/// Which samples a view includes.
pub type Inclusion {
  /// Samples on a scheduler or ready to run, and samples with no status.
  OnSchedulerOnly

  /// Every sample, waiting ones included.
  IncludeWaiting
}

/// A column's total, split by activity. Each count is a sum of absolute
/// values, as `profile.total` computes it, so the three add up to the
/// profile's total.
pub type Split {
  Split(
    /// Samples taken on a scheduler or ready to run.
    on_scheduler: Int,
    /// Samples taken while the process waited.
    waiting: Int,
    /// Samples that carry no status.
    unstated: Int,
  )
}

/// The label that records a sampled status.
///
/// ## Examples
///
/// ```gleam
/// activity.status_label("waiting")
/// // -> #("pickglass::status", "waiting")
/// ```
pub fn status_label(status: String) -> #(String, String) {
  #(status_key, status)
}

/// What a status text means. The agent reports the status atom of
/// `process_info/2` as text.
///
/// ## Examples
///
/// ```gleam
/// activity.of_status("runnable")
/// // -> OnScheduler
///
/// activity.of_status("waiting")
/// // -> Waiting
/// ```
pub fn of_status(status: String) -> Activity {
  case status {
    "running" | "runnable" | "garbage_collecting" -> OnScheduler
    "waiting" | "suspended" -> Waiting
    _ -> Unstated
  }
}

/// The activity a sample's label records, or `Unstated` when it has none.
///
/// ## Examples
///
/// ```gleam
/// activity.of_sample(Sample([0], [1], [#("pickglass::status", "running")]))
/// // -> OnScheduler
/// ```
pub fn of_sample(sample: Sample) -> Activity {
  case list.key_find(sample.labels, status_key) {
    Ok(status) -> of_status(status)
    Error(Nil) -> Unstated
  }
}

/// Whether an inclusion admits an activity.
///
/// ## Examples
///
/// ```gleam
/// activity.admits(OnSchedulerOnly, Waiting)
/// // -> False
/// ```
pub fn admits(inclusion: Inclusion, activity: Activity) -> Bool {
  case inclusion, activity {
    IncludeWaiting, _ -> True
    OnSchedulerOnly, Waiting -> False
    OnSchedulerOnly, OnScheduler | OnSchedulerOnly, Unstated -> True
  }
}

/// Count a column by activity.
///
/// ## Examples
///
/// ```gleam
/// activity.split(profile, column)
/// // -> Split(on_scheduler: 412, waiting: 2596, unstated: 0)
/// ```
pub fn split(profile: Profile, column: Column) -> Split {
  list.fold(
    profile.samples(profile),
    Split(on_scheduler: 0, waiting: 0, unstated: 0),
    fn(counts, sample) {
      let size = int.absolute_value(profile.sample_value(sample, column))

      case of_sample(sample) {
        OnScheduler -> Split(..counts, on_scheduler: counts.on_scheduler + size)
        Waiting -> Split(..counts, waiting: counts.waiting + size)
        Unstated -> Split(..counts, unstated: counts.unstated + size)
      }
    },
  )
}

/// The sum of all three counts.
///
/// ## Examples
///
/// ```gleam
/// activity.split_total(Split(412, 2596, 0))
/// // -> 3008
/// ```
pub fn split_total(counts: Split) -> Int {
  counts.on_scheduler + counts.waiting + counts.unstated
}

/// The profile with only the samples the inclusion admits.
///
/// ## Examples
///
/// ```gleam
/// activity.restrict(profile, OnSchedulerOnly)
/// ```
pub fn restrict(profile: Profile, inclusion: Inclusion) -> Profile {
  case inclusion {
    IncludeWaiting -> profile
    OnSchedulerOnly ->
      profile.with_samples(
        profile,
        list.filter(profile.samples(profile), fn(sample) {
          admits(inclusion, of_sample(sample))
        }),
      )
  }
}

/// Whether the profile has a sample that records a status. A profile of
/// counters or traced calls has none, and nothing about waiting applies to
/// it.
///
/// ## Examples
///
/// ```gleam
/// activity.has_status(profile)
/// // -> True
/// ```
pub fn has_status(profile: Profile) -> Bool {
  list.any(profile.samples(profile), fn(sample) {
    of_sample(sample) != Unstated
  })
}

/// A short phrase for what an inclusion shows.
///
/// ## Examples
///
/// ```gleam
/// activity.inclusion_text(OnSchedulerOnly)
/// // -> "running and runnable samples"
/// ```
pub fn inclusion_text(inclusion: Inclusion) -> String {
  case inclusion {
    OnSchedulerOnly -> "running and runnable samples"
    IncludeWaiting -> "all samples, waiting ones included"
  }
}
