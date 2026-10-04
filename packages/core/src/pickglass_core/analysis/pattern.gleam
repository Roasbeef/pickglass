//// A small pattern language for the profile filters.
////
//// pprof matches its focus, ignore, hide and show filters with Go regular
//// expressions. Pickglass's core is pure and takes no dependency beyond the
//// standard library, and the standard library has no regular expressions,
//// so this module implements the subset that profile filters actually use:
//// literal text, `.` for any character, the repetition suffixes `*`, `+`
//// and `?`, the anchors `^` and `$`, `|` between alternatives, and `\` to
//// make the next character literal. There are no groups and no character
//// classes. A pattern with no operators is a substring match, which is how
//// pprof's own examples (`-focus=runtime`) read.
////
//// A pattern is compiled once into a closed structure, so a malformed
//// pattern is reported when the filter is built and never while a profile
//// is being filtered. Matching is a backtracking walk over graphemes. Its
//// cost is bounded by the pattern times the text, because no construct
//// nests: a repetition applies to one character, never to a group.
////
//// ## Flow
////
//// `compile` parses the text into alternatives, each a list of pieces.
//// `matches` tries every alternative at every start position the anchors
//// allow, and `match_here` walks one alternative's pieces, backtracking
//// over `*`, `+` and `?`.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A compiled pattern: the alternatives separated by `|`.
pub opaque type Pattern {
  Pattern(source: String, alternatives: List(Alternative))
}

// One alternative: its anchors and the pieces between them.
type Alternative {
  Alternative(start: Anchoring, pieces: List(Piece), end: Anchoring)
}

// Whether an end of the alternative is pinned to an end of the text.
type Anchoring {
  Anchored
  Floating
}

// A single character matcher and how many times it may repeat.
type Piece {
  Piece(atom: Atom, repeat: Repeat)
}

type Atom {
  Literal(String)
  AnyCharacter
}

type Repeat {
  Once
  ZeroOrMore
  OneOrMore
  ZeroOrOne
}

/// Why a pattern text could not be compiled.
pub type PatternError {
  /// A repetition suffix (`*`, `+` or `?`) with nothing before it to repeat.
  NothingToRepeat(pattern: String)

  /// A trailing backslash with no character to make literal.
  DanglingEscape(pattern: String)

  /// Syntax that RE2 and pprof accept but this matcher does not implement:
  /// groups, classes, counted repetition, class escapes such as `\d`, and
  /// an anchor in the middle of an alternative. `text` is the offending
  /// character or escape sequence and `position` its grapheme offset in the
  /// pattern, counted from zero.
  UnsupportedSyntax(pattern: String, text: String, position: Int)
}

/// Compile pattern text. The empty pattern matches every text.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(p) = pattern.compile("^loom@.*:run/[0-9]")
/// ```
pub fn compile(text: String) -> Result(Pattern, PatternError) {
  use _ <- result.try(reject_unsupported(
    string.to_graphemes(text),
    0,
    True,
    text,
  ))
  let parts = split_alternatives(string.to_graphemes(text), [], [])
  use alternatives <- result.try(
    list.try_map(parts, fn(part) { parse_alternative(part, text) }),
  )
  Ok(Pattern(source: text, alternatives: alternatives))
}

/// The text a pattern was compiled from.
pub fn source(pattern: Pattern) -> String {
  pattern.source
}

/// Whether the pattern matches anywhere in `text`, unless anchored.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(p) = pattern.compile("gateway|json")
/// pattern.matches(p, "loom@provider@gateway:run/2")
/// // -> True
/// ```
pub fn matches(pattern: Pattern, text: String) -> Bool {
  let graphemes = string.to_graphemes(text)
  list.any(pattern.alternatives, fn(alternative) {
    alternative_matches(alternative, graphemes)
  })
}

// Refuse every construct the matcher does not implement, so a pattern is
// never read as something other than what its author wrote. `at_start` is
// true at the start of an alternative, the only place `^` is an anchor.
fn reject_unsupported(
  rest: List(String),
  position: Int,
  at_start: Bool,
  text: String,
) -> Result(Nil, PatternError) {
  case rest {
    [] -> Ok(Nil)

    ["\\"] -> Error(DanglingEscape(text))

    // An escape of a letter or digit is a class or assertion in RE2.
    ["\\", escaped, ..tail] ->
      case is_word_character(escaped) {
        True -> Error(UnsupportedSyntax(text, "\\" <> escaped, position))
        False -> reject_unsupported(tail, position + 2, False, text)
      }

    ["|", ..tail] -> reject_unsupported(tail, position + 1, True, text)

    ["^", ..tail] ->
      case at_start {
        True -> reject_unsupported(tail, position + 1, True, text)
        False -> Error(UnsupportedSyntax(text, "^", position))
      }

    // A `$` is an anchor only at the end of an alternative.
    ["$", ..tail] ->
      case tail {
        [] | ["|", ..] -> reject_unsupported(tail, position + 1, False, text)
        [_, ..] -> Error(UnsupportedSyntax(text, "$", position))
      }

    [grapheme, ..tail] ->
      case list.contains(["(", ")", "[", "]", "{", "}"], grapheme) {
        True -> Error(UnsupportedSyntax(text, grapheme, position))
        False -> reject_unsupported(tail, position + 1, False, text)
      }
  }
}

fn is_word_character(grapheme: String) -> Bool {
  string.contains(
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_",
    grapheme,
  )
}

// Split the grapheme list on unescaped `|`. Each part keeps its escapes
// so that `parse_alternative` can see them.
fn split_alternatives(
  rest: List(String),
  current: List(String),
  done: List(List(String)),
) -> List(List(String)) {
  case rest {
    [] -> list.reverse([list.reverse(current), ..done])

    // An escape pair is copied whole so an escaped bar never splits.
    ["\\", next, ..tail] ->
      split_alternatives(tail, [next, "\\", ..current], done)

    ["|", ..tail] ->
      split_alternatives(tail, [], [list.reverse(current), ..done])

    [grapheme, ..tail] -> split_alternatives(tail, [grapheme, ..current], done)
  }
}

fn parse_alternative(
  graphemes: List(String),
  text: String,
) -> Result(Alternative, PatternError) {
  let #(start, body) = case graphemes {
    ["^", ..tail] -> #(Anchored, tail)
    other -> #(Floating, other)
  }

  // A trailing unescaped `$` anchors the end. An escaped one is a literal
  // and stays in the body, where `parse_pieces` reads the escape.
  let #(end, body) = split_end_anchor(body)

  use pieces <- result.map(parse_pieces(body, [], text))
  Alternative(start: start, pieces: pieces, end: end)
}

// A `$` is an anchor only when an even number of backslashes (possibly
// none) precede it; an odd number makes it an escaped literal.
fn split_end_anchor(body: List(String)) -> #(Anchoring, List(String)) {
  case list.reverse(body) {
    ["$", ..reversed] ->
      case int.is_even(list.length(list.take_while(reversed, is_backslash))) {
        True -> #(Anchored, list.reverse(reversed))
        False -> #(Floating, body)
      }
    _ -> #(Floating, body)
  }
}

fn is_backslash(grapheme: String) -> Bool {
  grapheme == "\\"
}

fn parse_pieces(
  rest: List(String),
  acc: List(Piece),
  text: String,
) -> Result(List(Piece), PatternError) {
  case rest {
    [] -> Ok(list.reverse(acc))

    ["\\"] -> Error(DanglingEscape(text))

    ["\\", escaped, ..tail] -> parse_repeat(tail, Literal(escaped), acc, text)

    ["*", ..] | ["+", ..] | ["?", ..] -> Error(NothingToRepeat(text))

    [".", ..tail] -> parse_repeat(tail, AnyCharacter, acc, text)

    [grapheme, ..tail] -> parse_repeat(tail, Literal(grapheme), acc, text)
  }
}

// Read an optional repetition suffix after an atom.
fn parse_repeat(
  rest: List(String),
  atom: Atom,
  acc: List(Piece),
  text: String,
) -> Result(List(Piece), PatternError) {
  let #(repeat, tail) = case rest {
    ["*", ..tail] -> #(ZeroOrMore, tail)
    ["+", ..tail] -> #(OneOrMore, tail)
    ["?", ..tail] -> #(ZeroOrOne, tail)
    other -> #(Once, other)
  }
  parse_pieces(tail, [Piece(atom: atom, repeat: repeat), ..acc], text)
}

fn alternative_matches(
  alternative: Alternative,
  graphemes: List(String),
) -> Bool {
  case alternative.start {
    Anchored -> match_here(alternative.pieces, graphemes, alternative.end)
    Floating -> match_anywhere(alternative, graphemes)
  }
}

// Try the pieces at this position and then at every later one.
fn match_anywhere(alternative: Alternative, graphemes: List(String)) -> Bool {
  case match_here(alternative.pieces, graphemes, alternative.end) {
    True -> True
    False ->
      case graphemes {
        [] -> False
        [_, ..tail] -> match_anywhere(alternative, tail)
      }
  }
}

// Match the pieces against the front of the text. When the pieces run out
// an end anchor requires the text to run out too.
fn match_here(
  pieces: List(Piece),
  graphemes: List(String),
  end: Anchoring,
) -> Bool {
  case pieces {
    [] ->
      case end {
        Anchored -> graphemes == []
        Floating -> True
      }

    [Piece(atom: atom, repeat: Once), ..rest] ->
      case graphemes {
        [first, ..tail] ->
          atom_matches(atom, first) && match_here(rest, tail, end)
        [] -> False
      }

    [Piece(atom: atom, repeat: ZeroOrOne), ..rest] ->
      match_here(rest, graphemes, end)
      || case graphemes {
        [first, ..tail] ->
          atom_matches(atom, first) && match_here(rest, tail, end)
        [] -> False
      }

    [Piece(atom: atom, repeat: ZeroOrMore), ..rest] ->
      match_star(atom, rest, graphemes, end)

    [Piece(atom: atom, repeat: OneOrMore), ..rest] ->
      case graphemes {
        [first, ..tail] ->
          atom_matches(atom, first) && match_star(atom, rest, tail, end)
        [] -> False
      }
  }
}

// Greedy repetition with backtracking: consume as many characters as the
// atom accepts, then give them back one at a time until the rest matches.
fn match_star(
  atom: Atom,
  rest: List(Piece),
  graphemes: List(String),
  end: Anchoring,
) -> Bool {
  let consumed = case graphemes {
    [first, ..tail] ->
      case atom_matches(atom, first) {
        True -> match_star(atom, rest, tail, end)
        False -> False
      }
    [] -> False
  }
  consumed || match_here(rest, graphemes, end)
}

fn atom_matches(atom: Atom, grapheme: String) -> Bool {
  case atom {
    AnyCharacter -> True
    Literal(expected) -> expected == grapheme
  }
}
