//// Function names as a chart label.
////
//// A profile names a function `module:function/arity`, and in a real Loom
//// trace the module is the same long prefix on nearly every box
//// (`runtime@strand_runtime:`). A label cut to the width of its box then
//// shows only that prefix, and every box reads the same. pprof and
//// speedscope label a box with the most specific part of the name that
//// fits, and this module does the same: the whole name when it fits, then
//// `function/arity`, then the function cut to the room there is.
////
//// The full name is never replaced. The hover title and the selection
//// details carry it, and the callers here use the short form for the label
//// alone.
////
//// A closure is named by the compiler, not by its author. Gleam and Erlang
//// write one as `-drive_loop/2-anonymous-0-/2` or `-drive_loop/2-fun-0-/2`,
//// which is the enclosing function, its arity, a kind, a counter and the
//// closure's own arity. `readable` turns that into `drive_loop/2 fun#0`, so
//// a reader sees which function the closure lives in and which one it is.
//// Any other name that starts with a dash is left as it is, because
//// guessing at a compiler's naming would turn a name into a different name.
////
//// ## Reading order
////
//// `split` separates the module from the function; `readable` rewrites a
//// closure's name; `fit` chooses the label for a width; `short` is the
//// form `fit` falls back to.

import gleam/string
import pickglass_web/chart/svg_util

/// A function name taken apart.
pub type Parts {
  Parts(
    /// The module, or an empty string when the name has none.
    module: String,
    /// The function with its arity, written for a reader: a closure is
    /// `drive_loop/2 fun#0`.
    function: String,
  )
}

/// Split `module:function/arity` at its first colon and write the function
/// part for a reader.
///
/// ## Examples
///
/// ```gleam
/// names.split("runtime@strand_runtime:drive_loop/2")
/// // -> Parts("runtime@strand_runtime", "drive_loop/2")
///
/// names.split("runtime@strand_runtime:-drive_loop/2-anonymous-0-/2")
/// // -> Parts("runtime@strand_runtime", "drive_loop/2 fun#0")
///
/// names.split("init")
/// // -> Parts("", "init")
/// ```
pub fn split(name: String) -> Parts {
  case string.split_once(name, ":") {
    Ok(#(module, function)) -> Parts(module, readable(function))
    Error(Nil) -> Parts("", readable(name))
  }
}

/// Rewrite the compiler's name for a closure as the function it lives in
/// and its counter. Any other name is returned unchanged.
///
/// ## Examples
///
/// ```gleam
/// names.readable("-drive_loop/2-anonymous-0-/2")
/// // -> "drive_loop/2 fun#0"
///
/// names.readable("-handle/1-fun-3-/1")
/// // -> "handle/1 fun#3"
///
/// names.readable("drive_loop/2")
/// // -> "drive_loop/2"
/// ```
pub fn readable(function: String) -> String {
  case string.starts_with(function, "-") {
    False -> function
    True ->
      case string.split(string.drop_start(function, 1), "-") {
        [enclosing, "anonymous", counter, _arity] ->
          enclosing <> " fun#" <> counter
        [enclosing, "fun", counter, _arity] -> enclosing <> " fun#" <> counter
        _ -> function
      }
  }
}

/// The name without its module, written for a reader.
///
/// ## Examples
///
/// ```gleam
/// names.short("runtime@strand_runtime:drive_loop/2")
/// // -> "drive_loop/2"
/// ```
pub fn short(name: String) -> String {
  split(name).function
}

/// The label for a box `width` units wide, in a monospace face whose glyphs
/// are `glyph` units wide: the whole name when it fits, otherwise
/// `function/arity` when that fits, otherwise the function cut to the room
/// with an ellipsis. A box too narrow for three characters has no label.
///
/// ## Examples
///
/// ```gleam
/// names.fit("runtime@strand_runtime:drive_loop/2", 400, 7)
/// // -> "runtime@strand_runtime:drive_loop/2"
///
/// names.fit("runtime@strand_runtime:drive_loop/2", 120, 7)
/// // -> "drive_loop/2"
///
/// names.fit("runtime@strand_runtime:drive_loop/2", 70, 7)
/// // -> "drive_…"
/// ```
pub fn fit(name: String, width: Int, glyph: Int) -> String {
  let Parts(module:, function:) = split(name)

  let whole = case module {
    "" -> function
    _ -> module <> ":" <> function
  }

  let room = { width - 8 } / glyph

  case string.length(whole) <= room {
    True -> whole
    False -> svg_util.fit(function, width, glyph)
  }
}
