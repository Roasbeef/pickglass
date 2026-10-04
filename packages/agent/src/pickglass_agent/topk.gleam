//// A bounded top-K selection.
////
//// The census must not build a list of every process, so it folds each
//// process into a structure that never holds more than K entries. `Top`
//// keeps its entries sorted by an integer key, smallest first, so the
//// common case, an item that does not beat the smallest kept key, is one
//// comparison. Only an item that enters the top costs a walk of at most K
//// entries.

/// The K largest items offered so far, by key, smallest key first.
pub type Top(a) {
  Top(items: List(#(Int, a)), size: Int, capacity: Int)
}

/// An empty selection that keeps at most `capacity` items. A capacity below
/// one keeps nothing.
///
/// ## Examples
///
/// ```gleam
/// topk.new(3)
/// // -> Top([], 0, 3)
/// ```
pub fn new(capacity: Int) -> Top(a) {
  Top(items: [], size: 0, capacity: capacity)
}

/// Offer an item. It is kept when there is room or when its key beats the
/// smallest key held, which it then replaces.
///
/// ## Examples
///
/// ```gleam
/// topk.new(2) |> topk.offer(5, "a") |> topk.offer(9, "b") |> topk.offer(7, "c")
/// // keeps "b" and "c"
/// ```
pub fn offer(top: Top(a), key: Int, item: a) -> Top(a) {
  case top.capacity < 1 {
    True -> top
    False ->
      case top.size < top.capacity {
        True ->
          Top(..top, items: insert(top.items, key, item), size: top.size + 1)
        False -> replace_smallest(top, key, item)
      }
  }
}

fn replace_smallest(top: Top(a), key: Int, item: a) -> Top(a) {
  case top.items {
    [] -> top
    [#(smallest, _), ..rest] ->
      case key > smallest {
        False -> top
        True -> Top(..top, items: insert(rest, key, item))
      }
  }
}

fn insert(items: List(#(Int, a)), key: Int, item: a) -> List(#(Int, a)) {
  case items {
    [] -> [#(key, item)]
    [#(head_key, _) as head, ..rest] ->
      case key > head_key {
        True -> [head, ..insert(rest, key, item)]
        False -> [#(key, item), head, ..rest]
      }
  }
}

/// The kept items, largest key first.
///
/// ## Examples
///
/// ```gleam
/// topk.new(2) |> topk.offer(5, "a") |> topk.offer(9, "b") |> topk.descending
/// // -> [#(9, "b"), #(5, "a")]
/// ```
pub fn descending(top: Top(a)) -> List(#(Int, a)) {
  reverse_onto(top.items, [])
}

fn reverse_onto(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [item, ..rest] -> reverse_onto(rest, [item, ..acc])
  }
}
