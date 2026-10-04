import pickglass_agent/internal/ffi_term.{coerce}
import pickglass_agent/owner.{Owned, Unknown}

type Tag {
  PickglassOwner
}

fn label(path: a, role: b) -> ffi_term.Term {
  coerce(#(PickglassOwner, 1, path, role))
}

// A well-formed label decodes to its path and role, outermost first.
pub fn well_formed_label_decodes_test() {
  let path = [#("session", "s1"), #("strand", "t9")]

  assert owner.decode(label(path, "worker")) == Owned(path, "worker")
}

// No label at all reads as the atom `undefined`, which is not an owner.
pub fn missing_label_is_unknown_test() {
  assert owner.decode(coerce(ffi_term.atom("undefined"))) == Unknown
}

// Every way a label can be malformed must give `Unknown`, never a crash and
// never a partial owner.
pub fn malformed_labels_are_unknown_test() {
  assert owner.decode(coerce(7)) == Unknown
  assert owner.decode(coerce(#(PickglassOwner, 2, [], "r"))) == Unknown
  assert owner.decode(coerce(#(PickglassOwner, 1, [], 5))) == Unknown
  assert owner.decode(label([#("a", 1)], "r")) == Unknown
  assert owner.decode(label("not a list", "r")) == Unknown
  assert owner.decode(label([#("tab\there", "x")], "r")) == Unknown
}

// An improper list must be refused without walking it.
pub fn improper_path_is_unknown_test() {
  let improper: ffi_term.Term = coerce(append([1], 2))

  assert owner.decode(coerce(#(PickglassOwner, 1, improper, "r"))) == Unknown
}

// `[1] ++ 2` is the improper list `[1 | 2]`.
@external(erlang, "erlang", "++")
fn append(front: List(Int), back: Int) -> Int

// A slash or an empty text would collide with the viewer's path syntax.
pub fn slash_and_empty_text_are_unknown_test() {
  assert owner.decode(label([#("a/b", "x")], "r")) == Unknown
  assert owner.decode(label([#("", "x")], "r")) == Unknown
  assert owner.decode(label([], "")) == Unknown
}

// The optional fifth element advertises capabilities. It never changes who
// owns the process, so a capable and an incapable label group together.
pub fn capabilities_are_read_from_the_fifth_element_test() {
  let capable = coerce(#(PickglassOwner, 1, [], "worker", ["measure"]))

  assert owner.decode(capable) == Owned([], "worker")
  assert owner.capabilities(capable) == ["measure"]
  assert owner.capabilities(label([], "worker")) == []
  assert owner.capabilities(coerce(7)) == []
}

// A malformed capability list makes the whole label unknown and advertises
// nothing, so a process cannot claim `measure` through a label the decoder
// would refuse.
pub fn malformed_capabilities_are_refused_test() {
  let bad_text = coerce(#(PickglassOwner, 1, [], "worker", [7]))
  let bad_list = coerce(#(PickglassOwner, 1, [], "worker", "measure"))
  let too_many =
    coerce(
      #(PickglassOwner, 1, [], "worker", [
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
        "g",
        "h",
        "i",
      ]),
    )
  let six = coerce(#(PickglassOwner, 1, [], "worker", [], "extra"))

  assert owner.decode(bad_text) == Unknown
  assert owner.decode(bad_list) == Unknown
  assert owner.decode(too_many) == Unknown
  assert owner.decode(six) == Unknown
  assert owner.capabilities(bad_text) == []
  assert owner.capabilities(too_many) == []
}

// The agent's own processes read back as the tool's owner, which is how its
// cost shows up as a row of its own.
pub fn the_agent_labels_itself_test() {
  owner.claim_self()

  assert owner.decode(own_label()) == Owned([#("tool", "pickglass")], "agent")
}

@external(erlang, "erlang", "get")
fn dictionary_entry(key: ffi_term.Atom) -> ffi_term.Term

fn own_label() -> ffi_term.Term {
  dictionary_entry(ffi_term.atom("$process_label"))
}
