import gleam/string
import pickglass/agent_beams.{Beam}
import pickglass/attach

fn beam(module: String, bytes: BitArray) {
  Beam(module: module, file_name: module <> ".beam", bytes: bytes)
}

// Two viewers of one build must compute the same identity from the beams
// they read, wherever the directory listing put each file, or the second
// would be refused a join it is entitled to.
pub fn identity_does_not_depend_on_the_order_the_beams_were_read_test() {
  let server = beam("pickglass_agent@server", <<1, 2, 3>>)
  let census = beam("pickglass_agent@census", <<4, 5>>)

  assert agent_beams.identity([server, census])
    == agent_beams.identity([census, server])
}

// Any change to any module is a different build, since a join shares the code
// already running.
pub fn identity_changes_with_any_byte_of_any_module_test() {
  let server = beam("pickglass_agent@server", <<1, 2, 3>>)
  let census = beam("pickglass_agent@census", <<4, 5>>)
  let base = agent_beams.identity([server, census])

  assert base
    != agent_beams.identity([beam(server.module, <<1, 2, 4>>), census])
  assert base != agent_beams.identity([server])
  assert base
    != agent_beams.identity([server, beam("pickglass_agent@census2", <<4, 5>>)])
}

// The bytes of one module cannot be moved into the name of the next to give
// the same digest: the module name is separated from its bytes.
pub fn identity_separates_names_from_bytes_test() {
  assert agent_beams.identity([beam("a", <<98>>)])
    != agent_beams.identity([beam("ab", <<>>)])
}

pub fn identity_is_sixteen_lowercase_hex_digits_test() {
  let id = agent_beams.identity([beam("pickglass_agent@server", <<1>>)])

  assert string.length(id) == 16
  assert string.lowercase(id) == id
}

// A refusal for a running agent of another build names both builds, so the
// operator can tell which side to change.
pub fn a_build_mismatch_names_both_builds_test() {
  let message = attach.describe(attach.AgentBuildMismatch("build 1111", "2222"))

  assert string.contains(message, "build 1111")
  assert string.contains(message, "2222")
  assert string.contains(message, "another build")
}

pub fn a_full_agent_is_described_test() {
  assert string.contains(
    attach.describe(attach.TooManyViewers),
    "most viewers it allows",
  )
}
