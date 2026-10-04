import gleam/list
import pickglass/ring
import qcheck

pub fn newest_first_and_bounded_test() {
  let full =
    list.fold([1, 2, 3, 4, 5], ring.new(3), fn(r, item) { ring.push(r, item) })

  assert ring.to_list(full) == [5, 4, 3]
  assert ring.size(full) == 3
  assert ring.overwritten(full) == 2
  assert ring.newest(full) == Ok(5)
}

pub fn an_empty_ring_has_no_newest_test() {
  assert ring.newest(ring.new(2)) == Error(Nil)
  assert ring.to_list(ring.new(2)) == []
}

pub fn a_capacity_below_one_still_holds_the_newest_test() {
  let tiny = ring.new(0) |> ring.push("a") |> ring.push("b")

  assert ring.capacity(tiny) == 1
  assert ring.to_list(tiny) == ["b"]
}

// Whatever is pushed, the ring never holds more than its capacity, holds
// the newest items, and counts exactly what it dropped.
pub fn the_ring_is_bounded_test() {
  use #(capacity, items) <- qcheck.given(qcheck.tuple2(
    qcheck.bounded_int(1, 8),
    qcheck.list_from(qcheck.bounded_int(0, 100)),
  ))

  let filled = list.fold(items, ring.new(capacity), ring.push)
  let expected = list.take(list.reverse(items), capacity)

  assert ring.to_list(filled) == expected
  assert ring.size(filled) <= capacity
  assert ring.size(filled) + ring.overwritten(filled) == list.length(items)
}
