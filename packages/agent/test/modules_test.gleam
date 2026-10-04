import gleam/int
import gleam/list
import pickglass_agent/internal/ffi_term
import pickglass_agent/modules

fn atom(name: String) -> ffi_term.Atom {
  ffi_term.atom(name)
}

// Only a trailing `*` makes a prefix; the prefix is what lies before it.
pub fn a_trailing_star_is_a_prefix_test() {
  assert modules.prefix_of("runtime@*") == Ok("runtime@")
  assert modules.prefix_of("a*") == Ok("a")
  assert modules.prefix_of("*") == Ok("")
}

// A star anywhere else, or none at all, is an ordinary name.
pub fn other_names_are_not_prefixes_test() {
  assert modules.prefix_of("lists") == Error(Nil)
  assert modules.prefix_of("run*time") == Error(Nil)
  assert modules.prefix_of("*lists") == Error(Nil)
  assert modules.prefix_of("") == Error(Nil)
}

pub fn starts_with_compares_bytes_test() {
  assert modules.starts_with("runtime@strand", "runtime@")
  assert modules.starts_with("runtime@", "runtime@")
  assert !modules.starts_with("runtime", "runtime@")
  assert !modules.starts_with("other@runtime@", "runtime@")
  assert modules.starts_with("anything", "")
}

pub fn a_prefix_expands_to_the_modules_that_start_with_it_test() {
  let loaded = [atom("pg_p_a"), atom("other"), atom("pg_p_b"), atom("pg_q")]

  assert modules.expand_from("pg_p_", loaded)
    == Ok([atom("pg_p_a"), atom("pg_p_b")])
  assert modules.expand_from("pg_", loaded)
    == Ok([atom("pg_p_a"), atom("pg_p_b"), atom("pg_q")])
}

pub fn a_prefix_with_no_module_is_refused_test() {
  assert modules.expand_from("zz_", [atom("pg_a")]) == Error(modules.NoModule)
}

// A bare `*` names every module, so it is refused whatever is loaded.
pub fn a_bare_star_is_refused_test() {
  assert modules.expand_from("", [atom("pg_a")]) == Error(modules.BareWildcard)
}

pub fn a_prefix_over_the_limit_is_refused_test() {
  let many =
    list.repeat(0, modules.max_expanded + 1)
    |> list.index_map(fn(_, n) { n })
    |> list.map(fn(n) { atom("pg_many_" <> int.to_string(n)) })

  assert modules.expand_from("pg_many_", many) == Error(modules.TooManyModules)
  assert modules.expand_from("pg_many_", list.take(many, modules.max_expanded))
    == Ok(list.take(many, modules.max_expanded))
}

// The real code server lists the agent's own modules, so a live expansion
// finds at least the module under test.
pub fn the_code_server_is_the_default_source_test() {
  let assert Ok(found) = modules.expand("pickglass_agent@modules")

  assert list.any(found, fn(module) {
    ffi_term.atom_name(module) == "pickglass_agent@modules"
  })
}
