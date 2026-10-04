//// The plan store: where a plan waits for its confirmation, and is
//// consumed by it.
////
//// `policy.plan` returns a `Plan` and `policy.confirm` accepts one, but the
//// core holds no state, so nothing in the core stops the same plan being
//// confirmed twice. A probe plan is the operator's single approval of a
//// scope and a cost. If it could be replayed, one click would authorize
//// every later start. This store is what makes it single-use: `take`
//// removes the plan, and a second `take` of the same id finds nothing.
////
//// A plan is named by a random id the page holds. The id is not a secret
//// that authorizes anything, because `policy.confirm` still demands the
//// planning principal, but it is unguessable all the same so one page
//// cannot probe another's pending plans.
////
//// The store is bounded. Expired plans are swept on every `put`, and when
//// `capacity` live plans remain a new one is refused rather than evicting
//// somebody's pending approval.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import pickglass_core/policy.{type Plan, type PrincipalId}

/// The most pending plans held at once.
pub const capacity = 32

/// The pending plans, by id.
pub opaque type Store {
  Store(held: Dict(String, Plan))
}

/// An empty store.
pub fn new() -> Store {
  Store(held: dict.new())
}

/// Hold a plan under an id. Expired plans are swept first. `Error` when
/// `capacity` live plans remain.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(store) = plans.put(plans.new(), "id", plan, now)
/// ```
pub fn put(
  store: Store,
  id: String,
  plan: Plan,
  now_ms: Int,
) -> Result(Store, Nil) {
  let live = sweep(store, now_ms).held

  case dict.size(live) >= capacity {
    True -> Error(Nil)
    False -> Ok(Store(held: dict.insert(live, id, plan)))
  }
}

/// A held plan, left in place.
pub fn peek(store: Store, id: String) -> Result(Plan, Nil) {
  dict.get(store.held, id)
}

/// Remove a plan and return it. The same id finds nothing afterwards.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(store, plan)) = plans.take(store, "id")
/// plans.take(store, "id")
/// // -> Error(Nil)
/// ```
pub fn take(store: Store, id: String) -> Result(#(Store, Plan), Nil) {
  case dict.get(store.held, id) {
    Error(Nil) -> Error(Nil)
    Ok(plan) -> Ok(#(Store(held: dict.delete(store.held, id)), plan))
  }
}

/// The live plans a principal made, soonest-expiring first.
pub fn pending(
  store: Store,
  principal: PrincipalId,
  now_ms: Int,
) -> List(#(String, Plan)) {
  store.held
  |> dict.to_list
  |> list.filter(fn(entry) {
    policy.plan_principal(entry.1) == principal
    && policy.plan_expires_at(entry.1) > now_ms
  })
  |> list.sort(fn(a, b) {
    int.compare(policy.plan_expires_at(a.1), policy.plan_expires_at(b.1))
  })
}

/// Drop every plan whose expiry has passed.
pub fn sweep(store: Store, now_ms: Int) -> Store {
  Store(
    held: dict.filter(store.held, fn(_, plan) {
      policy.plan_expires_at(plan) > now_ms
    }),
  )
}

/// How many plans are held.
pub fn size(store: Store) -> Int {
  dict.size(store.held)
}
