//// Node-wide readings: memory, system information and scheduler
//// utilization.
////
//// Each is a direct binding to an existing OTP function. The key types
//// follow the same rule as `ffi_proc`: a nullary constructor is the atom
//// the VM expects, so the closed list of readings the agent can take is
//// one type, and a request cannot ask the agent to read anything else.

import pickglass_agent/internal/ffi_term.{type Atom, type Term}

/// Integer-valued `system_info/1` keys the agent reads.
pub type IntKey {
  ProcessCount
  Wordsize
  SchedulersOnline
}

/// String-valued `system_info/1` keys, returned as charlists.
pub type TextKey {
  OtpRelease
  Version
}

/// The name `system_flag/2` and `statistics/1` share for scheduler wall
/// time accounting.
pub type Accounting {
  SchedulerWallTime
}

/// The name of this node.
@external(erlang, "erlang", "node")
pub fn node_name() -> Atom

/// The node's current memory by category, in bytes. The categories are
/// atoms chosen by the VM.
@external(erlang, "erlang", "memory")
pub fn memory() -> List(#(Atom, Int))

@external(erlang, "erlang", "system_info")
fn system_info_int(key: IntKey) -> Int

@external(erlang, "erlang", "system_info")
fn system_info_text(key: TextKey) -> List(Int)

/// The number of processes on the node right now.
pub fn process_count() -> Int {
  system_info_int(ProcessCount)
}

/// Bytes per machine word on the node.
pub fn word_size() -> Int {
  system_info_int(Wordsize)
}

/// The number of online schedulers.
pub fn schedulers_online() -> Int {
  system_info_int(SchedulersOnline)
}

/// The OTP release, such as `"29"`.
pub fn otp_release() -> String {
  ffi_term.text_from_charlist(system_info_text(OtpRelease))
}

/// The runtime system version, such as `"17.0.5"`.
pub fn erts_version() -> String {
  ffi_term.text_from_charlist(system_info_text(Version))
}

@external(erlang, "erlang", "system_flag")
fn system_flag(flag: Accounting, value: Term) -> Term

/// Turn scheduler wall time accounting on for this process's reference. The
/// flag is reference counted per process, so the agent's own death
/// releases it even when it cannot ask.
pub fn enable_scheduler_wall_time() -> Nil {
  let _ = system_flag(SchedulerWallTime, ffi_term.coerce(True))

  Nil
}

/// Release this process's scheduler wall time reference.
pub fn disable_scheduler_wall_time() -> Nil {
  let _ = system_flag(SchedulerWallTime, ffi_term.coerce(False))

  Nil
}

/// The `scheduler_wall_time` statistic: the atom `undefined` when no process
/// has the flag on, and otherwise a list of `{SchedulerId, Active, Total}`
/// tuples with times in the VM's native units.
pub fn scheduler_wall_time() -> Term {
  statistics(SchedulerWallTime)
}

@external(erlang, "erlang", "statistics")
fn statistics(item: Accounting) -> Term
