//// The transform chain: filters applied to a profile before any view.
////
//// pprof applies its filters in one place before it builds a report, and
//// the filters are not alike. Some choose which samples exist, so the
//// totals every percentage divides by change. Some rewrite stacks and
//// leave totals alone, except for samples left with no frames. Some only
//// decide what is drawn. A viewer that shows all of them as "filters"
//// invites the mistake of reading a percentage against the wrong total,
//// so each step here has a class, and the result reports what each step
//// did to the total.
////
//// | Class | Steps | Totals |
//// | --- | --- | --- |
//// | `SampleFilter` | focus, ignore, show_from, tagfocus, tagignore | change |
//// | `StackRewrite` | hide, show | unchanged, except samples left with no frames |
//// | `DisplayPrune` | node fraction, edge fraction, node count | unchanged |
////
//// A step that selects nothing is reported as `MatchedNothing` rather than
//// silently producing an empty picture (pprof's `warnNoMatches`).
////
//// Names are matched with `analysis/pattern` against each frame's printable
//// name and, when the function has one, its source file name.
////
//// ## Flow
////
//// `apply` folds the steps over the sample list in order with `run`. For
//// each step `rewrite` compiles the patterns and changes the list, through
//// `keep_where`, `drop_where`, `show_from` or `rewrite_frames`, and
//// `run_step` records a `StepReport`. Display steps are collected into a
//// `Display` for the graph view and leave the samples alone.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass_core/analysis/pattern.{type Pattern, type PatternError}
import pickglass_core/profile.{type Column, type Profile, type Sample}

/// A tag filter: which labels a sample must (or must not) carry.
///
/// With a key, the filter matches when any pattern matches any value of
/// that key. Without one, every pattern must match some `key:value` string
/// of the sample's labels. This is pprof's rule for `-tagfocus`.
pub type TagMatch {
  TagMatch(
    /// The label key the patterns apply to, or none for any label.
    key: Option(String),
    /// The pattern texts.
    patterns: List(String),
  )
}

/// One step of a chain.
pub type Step {
  /// Keep samples with at least one frame matching the pattern.
  Focus(pattern: String)

  /// Drop samples with any frame matching the pattern.
  Ignore(pattern: String)

  /// Drop the frames above (the callers of) the outermost matching frame,
  /// and the samples with no matching frame.
  ShowFrom(pattern: String)

  /// Keep samples whose labels match.
  TagFocus(tag: TagMatch)

  /// Drop samples whose labels match.
  TagIgnore(tag: TagMatch)

  /// Remove matching frames from every stack, charging their cost to the
  /// caller by shortening the stack.
  Hide(pattern: String)

  /// Keep only matching frames in every stack.
  Show(pattern: String)

  /// Hide graph nodes below this fraction of the total.
  NodeFraction(fraction: Float)

  /// Hide graph edges below this fraction of the total.
  EdgeFraction(fraction: Float)

  /// Show at most this many graph nodes.
  NodeCount(count: Int)
}

/// What kind of effect a step has on the profile.
pub type StepClass {
  /// Changes which samples exist, so totals change.
  SampleFilter

  /// Rewrites stacks; totals change only by samples left empty.
  StackRewrite

  /// Affects only what the graph draws.
  DisplayPrune
}

/// What a step found.
pub type Outcome {
  /// The step selected this many samples (or frames, for a rewrite).
  Matched(count: Int)

  /// The step selected nothing. A focus that matched nothing leaves an
  /// empty profile; the caller should say so instead of drawing it.
  MatchedNothing

  /// A display step has no match count.
  DisplayOnly
}

/// The effect of one step.
pub type StepReport {
  StepReport(
    /// The step.
    step: Step,
    /// Its class.
    class: StepClass,
    /// The column total before the step.
    total_before: Int,
    /// The column total after the step.
    total_after: Int,
    /// The number of samples before the step.
    samples_before: Int,
    /// The number of samples after the step.
    samples_after: Int,
    /// For a rewrite, the samples dropped because no frame was left.
    dropped_empty: Int,
    /// What the step selected.
    outcome: Outcome,
  )
}

/// The display settings collected from `DisplayPrune` steps. The last step
/// of each kind wins.
pub type Display {
  Display(
    node_fraction: Option(Float),
    edge_fraction: Option(Float),
    node_count: Option(Int),
  )
}

/// The result of applying a chain.
pub type Applied {
  Applied(
    /// The profile after every sample and rewrite step.
    profile: Profile,
    /// One report per step, in order.
    reports: List(StepReport),
    /// The display settings.
    display: Display,
  )
}

/// Why a chain could not be applied.
pub type ChainError {
  /// A step's pattern did not compile. `step` is its position from zero.
  InvalidPattern(step: Int, error: PatternError)
}

/// The class of a step.
///
/// ## Examples
///
/// ```gleam
/// transform.class(Hide("lists"))
/// // -> StackRewrite
/// ```
pub fn class(step: Step) -> StepClass {
  case step {
    Focus(_) | Ignore(_) | ShowFrom(_) | TagFocus(_) | TagIgnore(_) ->
      SampleFilter
    Hide(_) | Show(_) -> StackRewrite
    NodeFraction(_) | EdgeFraction(_) | NodeCount(_) -> DisplayPrune
  }
}

/// Read a tag filter written as `key=a,b` or as bare `a,b`.
///
/// ## Examples
///
/// ```gleam
/// transform.parse_tag("session=s_9f2")
/// // -> TagMatch(Some("session"), ["s_9f2"])
/// ```
pub fn parse_tag(text: String) -> TagMatch {
  case string.split_once(text, "=") {
    Ok(#(key, values)) ->
      TagMatch(key: Some(key), patterns: string.split(values, ","))
    Error(Nil) -> TagMatch(key: None, patterns: string.split(text, ","))
  }
}

/// Apply the steps in order and report each one's effect on the total of
/// `column`.
///
/// ## Examples
///
/// ```gleam
/// transform.apply(p, [Focus("gateway"), Hide("lists")], column)
/// ```
pub fn apply(
  profile: Profile,
  steps: List(Step),
  column: Column,
) -> Result(Applied, ChainError) {
  let texts = frame_texts(profile)
  let start = State(profile.samples(profile), [], Display(None, None, None))
  use end <- result.map(run(steps, 0, start, column, texts))
  Applied(
    profile: profile.with_samples(profile, end.samples),
    reports: list.reverse(end.reports),
    display: end.display,
  )
}

// The fold state: the samples so far, the reports so far (newest first)
// and the display settings.
type State {
  State(samples: List(Sample), reports: List(StepReport), display: Display)
}

fn run(
  steps: List(Step),
  position: Int,
  state: State,
  column: Column,
  texts: Texts,
) -> Result(State, ChainError) {
  case steps {
    [] -> Ok(state)
    [step, ..rest] -> {
      use next <- result.try(run_step(step, position, state, column, texts))
      run(rest, position + 1, next, column, texts)
    }
  }
}

fn run_step(
  step: Step,
  position: Int,
  state: State,
  column: Column,
  texts: Texts,
) -> Result(State, ChainError) {
  use outcome <- result.map(
    rewrite(step, state.samples, texts)
    |> result.map_error(fn(error) { InvalidPattern(position, error) }),
  )
  let report =
    StepReport(
      step: step,
      class: class(step),
      total_before: profile.samples_total(state.samples, column),
      total_after: profile.samples_total(outcome.samples, column),
      samples_before: list.length(state.samples),
      samples_after: list.length(outcome.samples),
      dropped_empty: outcome.dropped_empty,
      outcome: outcome.outcome,
    )
  State(
    samples: outcome.samples,
    reports: [report, ..state.reports],
    display: display_after(step, state.display),
  )
}

fn display_after(step: Step, display: Display) -> Display {
  case step {
    NodeFraction(fraction) -> Display(..display, node_fraction: Some(fraction))
    EdgeFraction(fraction) -> Display(..display, edge_fraction: Some(fraction))
    NodeCount(count) -> Display(..display, node_count: Some(count))
    Focus(_)
    | Ignore(_)
    | ShowFrom(_)
    | TagFocus(_)
    | TagIgnore(_)
    | Hide(_)
    | Show(_) -> display
  }
}

// The texts a pattern is matched against for each function id: its
// printable name and, when it has one, its source file.
type Texts =
  Dict(Int, List(String))

fn frame_texts(profile: Profile) -> Texts {
  profile.functions(profile)
  |> list.map(fn(function) {
    let file = case function.file {
      Some(name) -> [name]
      None -> []
    }
    #(function.id, [profile.function_name(function), ..file])
  })
  |> dict.from_list
}

// What one step did to the sample list.
type Rewritten {
  Rewritten(samples: List(Sample), dropped_empty: Int, outcome: Outcome)
}

fn rewrite(
  step: Step,
  samples: List(Sample),
  texts: Texts,
) -> Result(Rewritten, PatternError) {
  case step {
    Focus(text) -> {
      use p <- result.map(pattern.compile(text))
      keep_where(samples, fn(sample) { any_frame_matches(sample, p, texts) })
    }
    Ignore(text) -> {
      use p <- result.map(pattern.compile(text))
      drop_where(samples, fn(sample) { any_frame_matches(sample, p, texts) })
    }
    ShowFrom(text) -> {
      use p <- result.map(pattern.compile(text))
      show_from(samples, p, texts)
    }
    TagFocus(tag) -> {
      use compiled <- result.map(compile_tag(tag))
      keep_where(samples, fn(sample) { tag_matches(sample, compiled) })
    }
    TagIgnore(tag) -> {
      use compiled <- result.map(compile_tag(tag))
      drop_where(samples, fn(sample) { tag_matches(sample, compiled) })
    }
    Hide(text) -> {
      use p <- result.map(pattern.compile(text))
      rewrite_frames(
        samples,
        fn(frame) { !frame_matches(frame, p, texts) },
        fn(removed, _kept) { removed },
      )
    }
    Show(text) -> {
      use p <- result.map(pattern.compile(text))
      rewrite_frames(
        samples,
        fn(frame) { frame_matches(frame, p, texts) },
        fn(_removed, kept) { kept },
      )
    }
    NodeFraction(_) | EdgeFraction(_) | NodeCount(_) ->
      Ok(Rewritten(samples, 0, DisplayOnly))
  }
}

fn outcome_of(count: Int) -> Outcome {
  case count {
    0 -> MatchedNothing
    n -> Matched(n)
  }
}

fn keep_where(
  samples: List(Sample),
  predicate: fn(Sample) -> Bool,
) -> Rewritten {
  let kept = list.filter(samples, predicate)
  Rewritten(kept, 0, outcome_of(list.length(kept)))
}

fn drop_where(
  samples: List(Sample),
  predicate: fn(Sample) -> Bool,
) -> Rewritten {
  let #(dropped, kept) = list.partition(samples, predicate)
  Rewritten(kept, 0, outcome_of(list.length(dropped)))
}

// Keep each matching sample's frames from the leaf up to and including the
// outermost matching frame, which is the last match in a leaf-first list.
// A sample with no matching frame is dropped.
fn show_from(samples: List(Sample), p: Pattern, texts: Texts) -> Rewritten {
  let kept =
    list.filter_map(samples, fn(sample) {
      use count <- result.map(outermost_match(sample, p, texts))
      profile.Sample(..sample, frames: list.take(sample.frames, count))
    })
  Rewritten(kept, 0, outcome_of(list.length(kept)))
}

// The number of frames from the leaf through the outermost match.
fn outermost_match(
  sample: Sample,
  p: Pattern,
  texts: Texts,
) -> Result(Int, Nil) {
  sample.frames
  |> list.index_map(fn(frame, index) { #(frame, index) })
  |> list.filter(fn(pair) { frame_matches(pair.0, p, texts) })
  |> list.last
  |> result.map(fn(pair) { pair.1 + 1 })
}

// Filter the frames of every sample and drop the samples left empty. What
// counts as a match depends on the direction: a hide matches the frames it
// removed and a show the frames it kept, so `count_of` takes both numbers.
// Either is zero exactly when the pattern selected nothing.
fn rewrite_frames(
  samples: List(Sample),
  keep_frame: fn(Int) -> Bool,
  count_of: fn(Int, Int) -> Int,
) -> Rewritten {
  let rewritten =
    list.map(samples, fn(sample) {
      profile.Sample(..sample, frames: list.filter(sample.frames, keep_frame))
    })
  let before = frame_count(samples)
  let after = frame_count(rewritten)
  let #(empty, kept) =
    list.partition(rewritten, fn(sample) { sample.frames == [] })
  Rewritten(
    kept,
    list.length(empty),
    outcome_of(count_of(before - after, after)),
  )
}

fn frame_count(samples: List(Sample)) -> Int {
  list.fold(samples, 0, fn(count, sample) { count + list.length(sample.frames) })
}

fn any_frame_matches(sample: Sample, p: Pattern, texts: Texts) -> Bool {
  list.any(sample.frames, fn(frame) { frame_matches(frame, p, texts) })
}

fn frame_matches(frame: Int, p: Pattern, texts: Texts) -> Bool {
  case dict.get(texts, frame) {
    Ok(names) -> list.any(names, fn(text) { pattern.matches(p, text) })
    Error(Nil) -> False
  }
}

// A tag filter with its patterns compiled.
type CompiledTag {
  CompiledTag(key: Option(String), patterns: List(Pattern))
}

fn compile_tag(tag: TagMatch) -> Result(CompiledTag, PatternError) {
  use patterns <- result.map(list.try_map(tag.patterns, pattern.compile))
  CompiledTag(key: tag.key, patterns: patterns)
}

// With a key, any pattern must match some value of that key. Without one,
// every pattern must match some `key:value` string of the labels.
fn tag_matches(sample: Sample, tag: CompiledTag) -> Bool {
  case tag.key {
    Some(key) -> {
      let values =
        list.filter_map(sample.labels, fn(label) {
          case label.0 == key {
            True -> Ok(label.1)
            False -> Error(Nil)
          }
        })
      list.any(tag.patterns, fn(p) {
        list.any(values, fn(value) { pattern.matches(p, value) })
      })
    }
    None -> {
      let strings =
        list.map(sample.labels, fn(label) { label.0 <> ":" <> label.1 })
      list.all(tag.patterns, fn(p) {
        list.any(strings, fn(text) { pattern.matches(p, text) })
      })
    }
  }
}
