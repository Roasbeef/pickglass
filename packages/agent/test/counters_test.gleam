import pickglass_agent/counters.{Pattern}
import pickglass_agent/internal/ffi_term

fn atom(name: String) -> ffi_term.Atom {
  ffi_term.atom(name)
}

// A wildcard on a module covers every other pattern on it, and a repeated
// pattern is armed once, so no function is counted twice.
pub fn patterns_are_reduced_to_a_covering_set_test() {
  let run = Pattern(atom("pg_a"), atom("run"))
  let stop = Pattern(atom("pg_a"), atom("stop"))
  let every = Pattern(atom("pg_a"), atom("_"))
  let other = Pattern(atom("pg_b"), atom("run"))

  assert counters.distinct_patterns([run, stop, run]) == [run, stop]
  assert counters.distinct_patterns([run, every, other]) == [every, other]
  assert counters.distinct_patterns([every, run]) == [every]
  assert counters.distinct_patterns([]) == []
}
