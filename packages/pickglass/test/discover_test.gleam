import gleam/option.{None, Some}
import pickglass/discover.{Ambiguous, Candidate, Daemon, NoTarget, Target}
import simplifile

const hex = "0b12ba1025aafe7ec2a794467929938a"

fn node(role: String, pid: String) -> String {
  "loom_" <> role <> "_profile_" <> pid <> "_" <> hex <> "@127.0.0.1"
}

fn line(pid: String, role: String, home: String) -> String {
  pid
  <> " /x/beam.smp -- -noshell -name "
  <> node(role, pid)
  <> " -home "
  <> home
  <> " -kernel inet_dist_use_interface {127,0,0,1}"
}

// A profiled node is recognised only when the pid embedded in its name is
// the pid `ps` reports, which rejects stale credentials and other emulators.
pub fn candidates_require_a_matching_embedded_pid_test() {
  let good = line("100", "daemon", "/s/tokens/loom-daemon-profile.A")
  let stale = "200 /x/beam.smp -name " <> node("daemon", "999") <> " -home /s/h"
  let table =
    good <> "\n" <> stale <> "\n  300 /usr/bin/vim notes.txt\n\ngarbage"

  assert discover.candidates(table)
    == [
      Candidate(
        100,
        node("daemon", "100"),
        Daemon,
        " " <> command_of(good) <> " ",
      ),
    ]
}

fn command_of(line: String) -> String {
  case line {
    "100 " <> rest -> rest
    other -> other
  }
}

// A node name that is almost right must not match.
pub fn malformed_node_names_are_not_candidates_test() {
  assert discover.candidates("5 beam -name loom_daemon_profile_5_xyz@127.0.0.1")
    == []
  assert discover.candidates(
      "5 beam -name loom_daemon_profile_5_" <> hex <> "@example.com",
    )
    == []
  assert discover.candidates("5 beam -name other_5_" <> hex <> "@127.0.0.1")
    == []
  assert discover.candidates("5 beam -name loom_daemon_profile_5_" <> hex) == []
}

pub fn choose_matches_a_cookie_directory_test() {
  let candidates =
    discover.candidates(line("100", "daemon", "/s/tokens/loom-daemon-profile.A"))
  let directories = [
    "/s/tokens/loom-daemon-profile.A",
    "/s/tokens/loom-daemon-profile.B",
  ]

  assert discover.choose(candidates, directories, None)
    == Ok(Target(100, node("daemon", "100"), "/s/tokens/loom-daemon-profile.A"))
  assert discover.choose(candidates, ["/s/tokens/loom-daemon-profile.B"], None)
    == Error(NoTarget)
}

// Without a pid only daemons are considered; naming a pid admits a client.
// Two daemons are ambiguous until the caller picks one.
pub fn choose_filters_by_role_and_pid_test() {
  let table =
    line("100", "daemon", "/s/tokens/loom-daemon-profile.A")
    <> "\n"
    <> line("101", "daemon", "/s/tokens/loom-daemon-profile.B")
    <> "\n"
    <> line("102", "client", "/s/tokens/loom-client-profile.C")
  let directories = [
    "/s/tokens/loom-daemon-profile.A",
    "/s/tokens/loom-daemon-profile.B",
    "/s/tokens/loom-client-profile.C",
  ]
  let candidates = discover.candidates(table)

  assert discover.choose(candidates, directories, None)
    == Error(Ambiguous([100, 101]))
  assert discover.choose(candidates, directories, Some(101))
    == Ok(Target(101, node("daemon", "101"), "/s/tokens/loom-daemon-profile.B"))
  assert discover.choose(candidates, directories, Some(102))
    == Ok(Target(102, node("client", "102"), "/s/tokens/loom-client-profile.C"))
}

// A directory name that is a prefix of another must not match its sibling:
// the match is on the whole `-home` argument.
pub fn home_match_is_exact_test() {
  let candidates =
    discover.candidates(line(
      "100",
      "daemon",
      "/s/tokens/loom-daemon-profile.AB",
    ))

  assert discover.choose(candidates, ["/s/tokens/loom-daemon-profile.A"], None)
    == Error(NoTarget)
}

// The cookie grants full control of the target, so a file other users can
// read is refused, and the refusal never contains the cookie.
pub fn cookie_permissions_are_enforced_test() {
  let directory = "build/discover_test_cookie"
  let path = directory <> "/.erlang.cookie"

  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "test directory"
  let assert Ok(Nil) = simplifile.write(path, "SECRETCOOKIE\n")
    as "write cookie"
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
    as "private permissions"

  assert discover.read_cookie(directory) == Ok("SECRETCOOKIE")

  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)
    as "open permissions"

  assert discover.read_cookie(directory)
    == Error(discover.CookieRefused(
      "the cookie file is readable by group or others",
    ))
  assert discover.read_cookie("build/no_such_directory")
    == Error(discover.CookieRefused("the cookie file cannot be read"))
}
