import gleam/int
import gleam/list
import pickglass/downloads.{Download}

fn file(name: String) -> downloads.Download {
  Download(
    file_name: name,
    content_type: "text/plain",
    body: "body of " <> name,
  )
}

pub fn a_ticket_is_single_use_test() {
  let registry = downloads.put(downloads.new(), "ticket-a", file("a"), 100)

  let #(registry, first) = downloads.take(registry, "ticket-a", 200)
  let #(_, second) = downloads.take(registry, "ticket-a", 300)

  assert first == Ok(file("a"))
  assert second == Error(downloads.UnknownTicket)
}

pub fn a_wrong_ticket_gets_nothing_and_leaves_the_file_test() {
  let registry = downloads.put(downloads.new(), "ticket-a", file("a"), 100)

  let #(registry, wrong) = downloads.take(registry, "ticket-b", 200)
  let #(_, right) = downloads.take(registry, "ticket-a", 200)

  assert wrong == Error(downloads.UnknownTicket)
  assert right == Ok(file("a"))
}

pub fn an_old_ticket_expires_and_is_consumed_by_the_attempt_test() {
  let registry = downloads.put(downloads.new(), "ticket-a", file("a"), 0)

  let #(registry, late) =
    downloads.take(registry, "ticket-a", downloads.ttl_ms + 1)
  let #(_, again) = downloads.take(registry, "ticket-a", 1)

  assert late == Error(downloads.ExpiredTicket)
  assert again == Error(downloads.UnknownTicket)
}

pub fn the_registry_holds_at_most_its_capacity_test() {
  let registry =
    harness_numbers(downloads.capacity + 4)
    |> list.fold(downloads.new(), fn(registry, number) {
      downloads.put(registry, "t" <> int.to_string(number), file("f"), number)
    })

  assert downloads.size(registry) == downloads.capacity

  // The oldest were dropped, the newest kept.
  let #(registry, oldest) = downloads.take(registry, "t1", 100)
  let #(_, newest) =
    downloads.take(registry, "t" <> int.to_string(downloads.capacity + 4), 100)

  assert oldest == Error(downloads.UnknownTicket)
  assert newest == Ok(file("f"))
}

fn harness_numbers(n: Int) -> List(Int) {
  list.repeat(Nil, n) |> list.index_map(fn(_, index) { index + 1 })
}
