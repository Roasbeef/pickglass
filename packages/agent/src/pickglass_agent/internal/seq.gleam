//// Small list helpers.
////
//// The agent may not import `gleam/list`, so the handful of list
//// operations it needs are here. Each is a plain recursion over a proper
//// list. Lists that arrive from outside are checked with
//// `ffi_safe.proper_length` before they reach any of these.

/// The list with its elements in the opposite order.
///
/// ## Examples
///
/// ```gleam
/// seq.reverse([1, 2, 3])
/// // -> [3, 2, 1]
/// ```
pub fn reverse(items: List(a)) -> List(a) {
  reverse_onto(items, [])
}

fn reverse_onto(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [item, ..rest] -> reverse_onto(rest, [item, ..acc])
  }
}

/// Apply a function to every element, keeping the order.
///
/// ## Examples
///
/// ```gleam
/// seq.map([1, 2], fn(n) { n * 2 })
/// // -> [2, 4]
/// ```
pub fn map(items: List(a), with transform: fn(a) -> b) -> List(b) {
  map_onto(items, transform, [])
}

fn map_onto(items: List(a), transform: fn(a) -> b, acc: List(b)) -> List(b) {
  case items {
    [] -> reverse(acc)
    [item, ..rest] -> map_onto(rest, transform, [transform(item), ..acc])
  }
}

/// Fold a list from the left.
///
/// ## Examples
///
/// ```gleam
/// seq.fold([1, 2, 3], 0, fn(sum, n) { sum + n })
/// // -> 6
/// ```
pub fn fold(items: List(a), from acc: b, with step: fn(b, a) -> b) -> b {
  case items {
    [] -> acc
    [item, ..rest] -> fold(rest, step(acc, item), step)
  }
}

/// Keep the elements for which a predicate holds.
///
/// ## Examples
///
/// ```gleam
/// seq.filter([1, 2, 3], fn(n) { n > 1 })
/// // -> [2, 3]
/// ```
pub fn filter(items: List(a), keeping keep: fn(a) -> Bool) -> List(a) {
  filter_onto(items, keep, [])
}

fn filter_onto(items: List(a), keep: fn(a) -> Bool, acc: List(a)) -> List(a) {
  case items {
    [] -> reverse(acc)
    [item, ..rest] ->
      case keep(item) {
        True -> filter_onto(rest, keep, [item, ..acc])
        False -> filter_onto(rest, keep, acc)
      }
  }
}

/// Run an action for every element.
///
/// ## Examples
///
/// ```gleam
/// seq.each([1, 2], fn(_) { Nil })
/// ```
pub fn each(items: List(a), run action: fn(a) -> b) -> Nil {
  case items {
    [] -> Nil
    [item, ..rest] -> {
      action(item)

      each(rest, action)
    }
  }
}

/// The number of elements.
///
/// ## Examples
///
/// ```gleam
/// seq.length([1, 2, 3])
/// // -> 3
/// ```
pub fn length(items: List(a)) -> Int {
  length_from(items, 0)
}

fn length_from(items: List(a), count: Int) -> Int {
  case items {
    [] -> count
    [_, ..rest] -> length_from(rest, count + 1)
  }
}

/// The first `count` elements, or the whole list when it is shorter.
///
/// ## Examples
///
/// ```gleam
/// seq.take([1, 2, 3], 2)
/// // -> [1, 2]
/// ```
pub fn take(items: List(a), count: Int) -> List(a) {
  take_onto(items, count, [])
}

fn take_onto(items: List(a), count: Int, acc: List(a)) -> List(a) {
  case count > 0, items {
    True, [item, ..rest] -> take_onto(rest, count - 1, [item, ..acc])
    True, [] -> reverse(acc)
    False, _ -> reverse(acc)
  }
}

/// Whether any element satisfies a predicate.
///
/// ## Examples
///
/// ```gleam
/// seq.any([1, 2], fn(n) { n == 2 })
/// // -> True
/// ```
pub fn any(items: List(a), satisfying predicate: fn(a) -> Bool) -> Bool {
  case items {
    [] -> False
    [item, ..rest] ->
      case predicate(item) {
        True -> True
        False -> any(rest, predicate)
      }
  }
}
