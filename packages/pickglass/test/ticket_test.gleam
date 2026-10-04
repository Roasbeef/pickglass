import fixture
import gleam/int
import gleam/list
import gleam/set
import pickglass/ticket
import pickglass_core/policy
import qcheck

fn registry_with(secret: String) -> ticket.Registry {
  let assert Ok(registry) =
    ticket.issue(ticket.new(), secret, [policy.Observe], 0)

  registry
}

fn alice() -> policy.PrincipalId {
  policy.PrincipalId("alice")
}

pub fn a_ticket_redeems_once_test() {
  let #(registry, first) =
    ticket.redeem(registry_with("t"), "t", "cookie", alice(), 10)
  let #(_, second) = ticket.redeem(registry, "t", "cookie2", alice(), 11)

  let assert Ok(session) = first

  assert session.principal == alice()
  assert set.contains(session.grants, policy.Observe)
  assert second == Error(ticket.UnknownTicket)
}

pub fn a_refused_exchange_still_consumes_the_ticket_test() {
  let late = ticket.ticket_ttl_ms + 1
  let #(registry, expired) =
    ticket.redeem(registry_with("t"), "t", "cookie", alice(), late)
  let #(_, again) = ticket.redeem(registry, "t", "cookie", alice(), 5)

  assert expired == Error(ticket.ExpiredTicket)
  assert again == Error(ticket.UnknownTicket)
}

pub fn an_unknown_ticket_is_refused_test() {
  let #(_, outcome) =
    ticket.redeem(registry_with("t"), "other", "c", alice(), 0)

  assert outcome == Error(ticket.UnknownTicket)
}

pub fn the_cookie_finds_its_session_test() {
  let #(registry, _) =
    ticket.redeem(registry_with("t"), "t", "cookie", alice(), 0)

  let assert Ok(#(_, session)) =
    ticket.session_for(registry, ["planted", "cookie"], 5)

  assert session.principal == alice()
  assert ticket.session_for(registry, [], 5) == Error(ticket.NoCookie)
  assert ticket.session_for(registry, ["other"], 5)
    == Error(ticket.NoSuchSession)
}

pub fn a_session_expires_test() {
  let #(registry, _) =
    ticket.redeem(registry_with("t"), "t", "cookie", alice(), 0)

  assert ticket.session_for(registry, ["cookie"], ticket.session_ttl_ms + 1)
    == Error(ticket.NoSuchSession)
}

pub fn only_handed_out_nonces_are_accepted_test() {
  let #(registry, _) =
    ticket.redeem(registry_with("t"), "t", "cookie", alice(), 0)
  let assert Ok(#(digest, _)) = ticket.session_for(registry, ["cookie"], 0)
  let registry = ticket.add_nonce(registry, digest, "page-nonce")
  let assert Ok(#(_, session)) = ticket.session_for(registry, ["cookie"], 0)

  assert ticket.has_nonce(session, "page-nonce")
  assert !ticket.has_nonce(session, "forged")
}

pub fn the_oldest_nonce_is_dropped_test() {
  let #(registry, _) =
    ticket.redeem(registry_with("t"), "t", "cookie", alice(), 0)
  let assert Ok(#(digest, _)) = ticket.session_for(registry, ["cookie"], 0)
  let registry =
    list.fold(fixture.numbers(ticket.max_nonces + 1), registry, fn(r, n) {
      ticket.add_nonce(r, digest, "n" <> int.to_string(n))
    })
  let assert Ok(#(_, session)) = ticket.session_for(registry, ["cookie"], 0)

  assert !ticket.has_nonce(session, "n1")
  assert ticket.has_nonce(session, "n" <> int.to_string(ticket.max_nonces + 1))
}

pub fn the_registry_holds_digests_not_secrets_test() {
  assert ticket.digest("secret") != "secret"
  assert ticket.digest("secret") == ticket.digest("secret")
  assert ticket.digest("a") != ticket.digest("b")
}

pub fn outstanding_tickets_are_bounded_test() {
  let full =
    list.fold(fixture.numbers(ticket.max_tickets), ticket.new(), fn(r, n) {
      let assert Ok(next) =
        ticket.issue(r, "ticket-" <> int.to_string(n), [policy.Observe], 0)

      next
    })

  assert ticket.issue(full, "one-more", [policy.Observe], 0) == Error(Nil)

  // Once the outstanding tickets expire there is room again.
  let later = ticket.ticket_ttl_ms + 1

  assert result_is_ok(ticket.issue(full, "one-more", [policy.Observe], later))
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// However many times a ticket is presented, exactly one exchange succeeds.
pub fn a_ticket_succeeds_at_most_once_test() {
  use attempts <- qcheck.given(qcheck.bounded_int(1, 6))

  let #(_, outcomes) =
    list.fold(
      fixture.numbers(attempts),
      #(registry_with("t"), []),
      fn(state, n) {
        let #(registry, outcomes) = state
        let #(registry, outcome) =
          ticket.redeem(registry, "t", "c" <> int.to_string(n), alice(), 1)

        #(registry, [outcome, ..outcomes])
      },
    )

  assert list.count(outcomes, fn(outcome) {
      case outcome {
        Ok(_) -> True
        Error(_) -> False
      }
    })
    == 1
}
