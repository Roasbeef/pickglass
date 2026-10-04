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
