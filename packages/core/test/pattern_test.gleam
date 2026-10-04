import pickglass_core/analysis/pattern

fn hit(source: String, text: String) -> Bool {
  let assert Ok(compiled) = pattern.compile(source)
  pattern.matches(compiled, text)
}

// A pattern with no operators is a substring match, as in pprof's
// `-focus=runtime`.
pub fn plain_text_is_a_substring_test() {
  assert hit("gateway", "loom@provider@gateway:run/2")
  assert !hit("gateway", "loom@provider@router:run/2")
  assert hit("", "anything")
}

pub fn anchors_pin_the_ends_test() {
  assert hit("^loom", "loom@a:f/0")
  assert !hit("^loom", "a:loom/0")
  assert hit("/0$", "a:f/0")
  assert !hit("/0$", "a:f/0x")
  assert hit("^a:f/0$", "a:f/0")
  assert !hit("^a:f/0$", "xa:f/0")
}

pub fn repetition_and_wildcards_test() {
  assert hit("^a.*z$", "a-anything-z")
  assert hit("^ab*c$", "ac")
  assert hit("^ab*c$", "abbbc")
  assert hit("^ab+c$", "abc")
  assert !hit("^ab+c$", "ac")
  assert hit("^ab?c$", "ac")
  assert hit("^ab?c$", "abc")
  assert !hit("^ab?c$", "abbc")
}

// Backtracking: the star must give characters back so the rest can match.
pub fn star_backtracks_test() {
  assert hit("^a.*bc$", "abcbc")
  assert hit("^.*:run/.$", "loom:run/2")
}

pub fn alternation_test() {
  assert hit("gateway|json", "json:decode/1")
  assert hit("gateway|json", "x:gateway/1")
  assert !hit("gateway|json", "x:other/1")
  assert hit("^a$|^b$", "b")
  assert !hit("^a$|^b$", "ab")
}

pub fn escapes_make_operators_literal_test() {
  assert hit("a\\.b", "a.b")
  assert !hit("a\\.b", "axb")
  assert hit("a\\|b", "a|b")
  assert !hit("a\\|b", "a")
  assert hit("cost\\$", "cost$")
  assert hit("^a\\\\$", "a\\")
}

pub fn malformed_patterns_are_refused_test() {
  assert pattern.compile("*a") == Error(pattern.NothingToRepeat("*a"))
  assert pattern.compile("a|+") == Error(pattern.NothingToRepeat("a|+"))
  assert pattern.compile("a\\") == Error(pattern.DanglingEscape("a\\"))
}

pub fn source_is_kept_test() {
  let assert Ok(compiled) = pattern.compile("a|b")
  assert pattern.source(compiled) == "a|b"
}

// A construct the matcher lacks is refused with its position, never read
// as literal text.
pub fn unsupported_syntax_is_refused_with_its_position_test() {
  assert pattern.compile("(a|b)")
    == Error(pattern.UnsupportedSyntax("(a|b)", "(", 0))
  assert pattern.compile("ab)")
    == Error(pattern.UnsupportedSyntax("ab)", ")", 2))
  assert pattern.compile("[ab]")
    == Error(pattern.UnsupportedSyntax("[ab]", "[", 0))
  assert pattern.compile("xy]")
    == Error(pattern.UnsupportedSyntax("xy]", "]", 2))
  assert pattern.compile("a{2}")
    == Error(pattern.UnsupportedSyntax("a{2}", "{", 1))
  assert pattern.compile("a}") == Error(pattern.UnsupportedSyntax("a}", "}", 1))
  assert pattern.compile("x\\d")
    == Error(pattern.UnsupportedSyntax("x\\d", "\\d", 1))
  assert pattern.compile("\\w")
    == Error(pattern.UnsupportedSyntax("\\w", "\\w", 0))
  assert pattern.compile("a|\\s")
    == Error(pattern.UnsupportedSyntax("a|\\s", "\\s", 2))
  assert pattern.compile("\\b")
    == Error(pattern.UnsupportedSyntax("\\b", "\\b", 0))
}

pub fn misplaced_anchors_are_refused_test() {
  assert pattern.compile("a^b")
    == Error(pattern.UnsupportedSyntax("a^b", "^", 1))
  assert pattern.compile("a$b")
    == Error(pattern.UnsupportedSyntax("a$b", "$", 1))
  assert pattern.compile("^a$|^b$") != Error(pattern.NothingToRepeat(""))
}

pub fn escaped_brackets_stay_literal_test() {
  assert hit("\\(a\\)", "f(a)")
  assert hit("\\[x\\]", "[x]")
  assert hit("a\\{2\\}", "a{2}")
  assert !hit("\\(a\\)", "fa")
}
