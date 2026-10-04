//// Who a thing is: a node incarnation, an OS process, a BEAM process, and
//// the pin tokens that let the operator act on one.
////
//// Identity has three strengths and pickglass keeps them apart. A node
//// incarnation says which run of which node a reading came from, so a
//// daemon restart is visible as a different incarnation rather than a
//// discontinuity. An OS process identity says whether two readings are of
//// the same OS process. A BEAM process's display identity is a pid text and
//// the census epoch it was first seen in; it is for showing, never for
//// authority. Authority is a pin token, which is bound to one agent boot id
//// and is refused by any other incarnation.
////
//// A `LivePin` is the proof that a pin token was checked against the
//// current incarnation. Only `check_pin` builds one, and the policy module
//// requires one before it will authorize a command that names a target.
////
//// ## Flow
////
//// - `boot_id` and `pin` build the validated identifiers.
//// - `check_pin` turns a token and the current boot id into a `LivePin`.
//// - `same_os_process` compares two OS process identities.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The identifier the agent generates at start. A restart of the daemon
/// changes it, which invalidates every pin and cached reference.
pub opaque type BootId {
  BootId(text: String)
}

/// The longest boot id accepted.
pub const max_boot_id_length = 64

/// Validate a boot id: one to 64 characters from `[0-9A-Za-z_-]`. The
/// restricted alphabet keeps pin tokens parseable and safe to place in a
/// page key.
///
/// ## Examples
///
/// ```gleam
/// identity.boot_id("7f3a9c")
/// // -> Ok(_)
///
/// identity.boot_id("has:colon")
/// // -> Error(Nil)
/// ```
pub fn boot_id(text: String) -> Result(BootId, Nil) {
  let length = string.length(text)
  let in_alphabet = list.all(string.to_graphemes(text), is_token_char)

  case length >= 1 && length <= max_boot_id_length && in_alphabet {
    True -> Ok(BootId(text))
    False -> Error(Nil)
  }
}

fn is_token_char(grapheme: String) -> Bool {
  case grapheme {
    "-" | "_" -> True
    _ ->
      string.contains(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
        grapheme,
      )
  }
}

/// A boot id that no agent issues. Decoders return it as the placeholder
/// that gleam's decoder protocol requires on failure; it is never the
/// value of a successful decode.
pub const unknown_boot: BootId = BootId(text: "unknown")

/// The text of a boot id.
pub fn boot_id_text(id: BootId) -> String {
  id.text
}

// ------------------------------------------------------------ incarnation

/// Which run of which node a reading came from.
pub type NodeIncarnation {
  NodeIncarnation(
    /// A digest of the node name, so a capture does not carry the name
    /// itself.
    node_digest: String,
    /// The node's `creation`, which is zero on a node that is not
    /// distributed and so cannot discriminate there.
    creation: Int,
    /// The agent's boot id.
    boot: BootId,
  )
}

/// Whether two readings come from the same incarnation of the same node.
///
/// ## Examples
///
/// ```gleam
/// identity.same_incarnation(a, a)
/// // -> True
/// ```
pub fn same_incarnation(a: NodeIncarnation, b: NodeIncarnation) -> Bool {
  a == b
}

// ------------------------------------------------------------ OS process

/// A token that says when an OS process started, with the resolution it
/// has.
pub type StartIdentity {
  /// A start identity that distinguishes any two processes, such as the
  /// start time field of `/proc/<pid>/stat` joined with the kernel boot id.
  PreciseStart(token: String)

  /// A start identity with one-second resolution, such as `ps -o lstart=`.
  /// The UI marks it `coarse`.
  CoarseStart(token: String)

  /// The start identity could not be read. It is never guessed.
  UnreadableStart
}

/// An OS process: a pid and when it started.
pub type OsProcess {
  OsProcess(pid: Int, start: StartIdentity)
}

/// The answer to "are these the same OS process".
pub type SameProcess {
  /// Same pid and same precise start identity.
  Same

  /// Same pid and same coarse start identity: a different process that
  /// started in the same second with the same pid cannot be ruled out.
  SameWithinCoarseResolution

  /// A different pid, or a different start identity.
  Different

  /// A start identity was unreadable, so the answer is unknown.
  Indeterminate
}

/// Compare two OS process identities.
///
/// ## Examples
///
/// ```gleam
/// identity.same_os_process(
///   OsProcess(7, PreciseStart("a")),
///   OsProcess(7, PreciseStart("a")),
/// )
/// // -> Same
///
/// identity.same_os_process(
///   OsProcess(7, PreciseStart("a")),
///   OsProcess(7, UnreadableStart),
/// )
/// // -> Indeterminate
/// ```
pub fn same_os_process(a: OsProcess, b: OsProcess) -> SameProcess {
  case a.pid == b.pid, a.start, b.start {
    False, _, _ -> Different
    True, UnreadableStart, _ | True, _, UnreadableStart -> Indeterminate
    True, PreciseStart(x), PreciseStart(y) if x == y -> Same
    True, CoarseStart(x), CoarseStart(y) if x == y -> SameWithinCoarseResolution
    True, PreciseStart(_), _ | True, CoarseStart(_), _ -> Different
  }
}

// ---------------------------------------------------------- BEAM process

/// The identity a census row shows for a BEAM process. It is for display:
/// a pid text can be reused, and nothing authorizes on it.
pub type ProcessDisplay {
  ProcessDisplay(
    /// The pid as the agent printed it, such as `<0.4112.0>`.
    pid_text: String,
    /// The census epoch in which the agent first saw this pid.
    first_seen_epoch: Int,
  )
}

/// Render a process display identity as `<0.4112.0>@18204`.
///
/// ## Examples
///
/// ```gleam
/// identity.display_text(ProcessDisplay("<0.4112.0>", 18_204))
/// // -> "<0.4112.0>@18204"
/// ```
pub fn display_text(display: ProcessDisplay) -> String {
  display.pid_text <> "@" <> int.to_string(display.first_seen_epoch)
}

// ------------------------------------------------------------------ pins

/// A token naming one pinned process, bound to the boot id of the agent
/// that issued it. Opaque: it is built by `pin` or `parse_pin` and checked
/// by `check_pin`.
pub opaque type PinToken {
  PinToken(boot: BootId, serial: Int)
}

/// The most pins an agent holds at once by default.
pub const default_pin_limit = 64

/// Build the token for pin number `serial` issued by the agent with this
/// boot id. A negative serial is refused.
///
/// ## Examples
///
/// ```gleam
/// identity.pin(boot, 3)
/// // -> Ok(_)
/// ```
pub fn pin(boot: BootId, serial: Int) -> Result(PinToken, Nil) {
  case serial >= 0 {
    True -> Ok(PinToken(boot:, serial:))
    False -> Error(Nil)
  }
}

/// The boot id a token is bound to.
pub fn pin_boot(token: PinToken) -> BootId {
  token.boot
}

/// The serial of a token within its boot id.
pub fn pin_serial(token: PinToken) -> Int {
  token.serial
}

/// The text form of a token, `<boot>:<serial>`.
///
/// ## Examples
///
/// ```gleam
/// identity.pin_to_string(token)
/// // -> "7f3a9c:3"
/// ```
pub fn pin_to_string(token: PinToken) -> String {
  token.boot.text <> ":" <> int.to_string(token.serial)
}

/// Parse the text form of a token. Anything that is not exactly a valid
/// boot id, a colon, and a non-negative integer is refused.
///
/// ## Examples
///
/// ```gleam
/// identity.parse_pin("7f3a9c:3")
/// // -> Ok(_)
///
/// identity.parse_pin("7f3a9c")
/// // -> Error(Nil)
/// ```
pub fn parse_pin(text: String) -> Result(PinToken, Nil) {
  case string.split(text, ":") {
    [boot, serial] -> {
      use boot <- result.try(boot_id(boot))
      use serial <- result.try(int.parse(serial))
      pin(boot, serial)
    }
    _ -> Error(Nil)
  }
}

/// Why a pin token was refused.
pub type PinRefusal {
  /// The token was issued by a different agent boot, so its target may be
  /// a different process or gone.
  OtherIncarnation(token_boot: String, current_boot: String)
}

/// Proof that a pin token was checked against the current incarnation.
/// Opaque: only `check_pin` builds one.
pub opaque type LivePin {
  LivePin(token: PinToken)
}

/// Check a token against the boot id of the incarnation being talked to.
/// A token from another incarnation is refused.
///
/// This checks the incarnation only. Whether the pinned process is still
/// alive is the agent's check; a `DOWN` there invalidates the token.
///
/// ## Examples
///
/// ```gleam
/// identity.check_pin(token, current_boot)
/// // -> Ok(_) when the token was issued by that boot
/// ```
pub fn check_pin(
  token: PinToken,
  current: BootId,
) -> Result(LivePin, PinRefusal) {
  case token.boot == current {
    True -> Ok(LivePin(token:))
    False ->
      Error(OtherIncarnation(
        token_boot: token.boot.text,
        current_boot: current.text,
      ))
  }
}

/// The token a `LivePin` proves.
pub fn live_token(live: LivePin) -> PinToken {
  live.token
}
