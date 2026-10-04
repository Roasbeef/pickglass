//// A bounded ring of the newest items.
////
//// The viewer keeps "the newest capture plus a ring" of recent
//// observations: a page that opens late can draw the last few minutes
//// without the viewer asking the target again. The ring is the bound. It
//// holds at most `capacity` items, newest first, and counts what it let go
//// so a reader can say that older readings were overwritten
//// (`measure.RingOverflow`) rather than imply the history is complete.
////
//// The ring is a plain value with no process behind it: the hub actor owns
//// one and nothing else mutates it.

import gleam/int
import gleam/list

/// A ring holding at most `capacity` items, newest first.
pub opaque type Ring(a) {
  Ring(capacity: Int, items: List(a), size: Int, overwritten: Int)
}

/// An empty ring. A capacity below one is raised to one, so the ring always
/// holds the newest item.
///
/// ## Examples
///
/// ```gleam
/// ring.new(3) |> ring.push(1) |> ring.to_list
/// // -> [1]
/// ```
pub fn new(capacity: Int) -> Ring(a) {
  Ring(capacity: int.max(capacity, 1), items: [], size: 0, overwritten: 0)
}

/// Add an item as the newest. When the ring is full the oldest is dropped
/// and counted.
///
/// ## Examples
///
/// ```gleam
/// ring.new(2) |> ring.push(1) |> ring.push(2) |> ring.push(3) |> ring.to_list
/// // -> [3, 2]
/// ```
pub fn push(ring: Ring(a), item: a) -> Ring(a) {
  case ring.size >= ring.capacity {
    True ->
      Ring(
        ..ring,
        items: [item, ..list.take(ring.items, ring.capacity - 1)],
        overwritten: ring.overwritten + 1,
      )
    False -> Ring(..ring, items: [item, ..ring.items], size: ring.size + 1)
  }
}

/// The items, newest first.
pub fn to_list(ring: Ring(a)) -> List(a) {
  ring.items
}

/// The newest item, or `Error` for an empty ring.
pub fn newest(ring: Ring(a)) -> Result(a, Nil) {
  list.first(ring.items)
}

/// How many items the ring holds.
pub fn size(ring: Ring(a)) -> Int {
  ring.size
}

/// The most items the ring holds.
pub fn capacity(ring: Ring(a)) -> Int {
  ring.capacity
}

/// How many items were dropped to make room.
pub fn overwritten(ring: Ring(a)) -> Int {
  ring.overwritten
}
