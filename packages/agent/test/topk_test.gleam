import gleam/list
import pickglass_agent/topk

// The selection keeps the K largest keys, largest first, whatever the
// order they were offered in.
pub fn keeps_the_largest_test() {
  let top =
    list.fold([5, 1, 9, 3, 7, 9, 2], topk.new(3), fn(top, key) {
      topk.offer(top, key, key)
    })

  assert list.map(topk.descending(top), fn(entry) { entry.0 }) == [9, 9, 7]
  assert top.size == 3
}

// A capacity of zero keeps nothing, and a shorter input keeps everything.
pub fn degenerate_capacities_test() {
  assert topk.descending(topk.offer(topk.new(0), 5, "a")) == []
  assert topk.descending(topk.offer(topk.new(4), 5, "a")) == [#(5, "a")]
}
