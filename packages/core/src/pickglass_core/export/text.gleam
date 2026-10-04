//// A profile as text a terminal can show: the heaviest functions, then an
//// indented call tree.
////
//// This is the one export that is written to be read rather than loaded by
//// another tool, so it does not try to be complete. The function table lists
//// the functions with the most samples of their own (`flat`), beside the
//// samples of every stack they appear in (`cum`). The tree merges the
//// profile's stacks from the root down, orders each node's children by
//// samples, and leaves out a branch holding less than a small share of the
//// whole, so what remains is the paths where the samples are. Both are cut
//// by `Config`, and the tree says how many lines it left out.
////
//// Percentages are a share of the column's total, in tenths of a percent,
//// computed with integer arithmetic. A column whose total is zero has
//// nothing to divide by, and the text says so instead of printing zeros.
////
//// A column of counts is written as samples. A column of nanoseconds, such as
//// the exclusive time of a call tree, is written as a time and named by the
//// column, because calling traced time "samples" would be wrong.
////
//// ## Flow
////
//// `export` joins `functions` and `tree`. `functions` takes its rows from
//// `analysis/top`. `tree` builds a trie from `profile.merged_stacks`
//// (`insert`), then `render`s it depth first.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/order
import gleam/result
import gleam/string
import pickglass_core/analysis/top
import pickglass_core/export.{type Export, type ExportError, Export}
import pickglass_core/profile.{type Column, type Profile}
import pickglass_core/unit.{type Unit}

/// How much of the profile the text shows.
pub type Config {
  Config(
    /// How many functions the table lists.
    functions: Int,
    /// The most lines the tree prints.
    lines: Int,
    /// A branch holding fewer tenths of a percent of the total than this is
    /// left out.
    min_tenths: Int,
  )
}

/// Fifteen functions, sixty tree lines, branches of at least a half percent.
pub const default_config = Config(functions: 15, lines: 60, min_tenths: 5)

/// Write the function table and the call tree of one column.
///
/// ## Examples
///
/// ```gleam
/// text.export(profile, column, text.default_config)
/// // -> Ok(Export("top functions ...\n\ncall tree ...\n", losses))
/// ```
pub fn export(
  profile: Profile,
  column: Column,
  config: Config,
) -> Result(Export, ExportError) {
  use shape <- result.map(tree(profile, column, config))

  Export(
    body: functions(profile, column, config.functions) <> "\n" <> shape,
    losses: losses(),
  )
}

/// What this text leaves out.
pub fn losses() -> List(String) {
  [
    "Branches below the share threshold and functions past the table's cut.",
    "Every value type but the one written.",
    "Units, coverage and provenance: the caller prints them beside the text.",
    "Source locations of functions.",
  ]
}

// ------------------------------------------------------------- functions

/// The functions with the most samples of their own, with the share of the
/// total each accounts for on its own (`flat`) and with its callees (`cum`).
///
/// ## Examples
///
/// ```gleam
/// text.functions(profile, column, 15)
/// // -> "top 15 functions by samples of their own (3096 samples in all)\n..."
/// ```
pub fn functions(profile: Profile, column: Column, limit: Int) -> String {
  let total = profile.total(profile, column)
  let index = profile.column_index(column)
  let words = words_of(profile, column)

  // A time such as `145.46 us` is wider than a count, so its columns are.
  let width = case words.unit {
    unit.Count -> 9
    _ -> 11
  }

  // A table with no base cannot fail; the error arm is the type's, not a
  // reachable case.
  let rows = case top.table(profile, None, top.Sort(column, top.ByFlat)) {
    Ok(table) -> table.rows
    Error(top.IncompatibleBase) -> []
  }

  let shown =
    rows
    |> list.take(limit)
    |> list.map(fn(row) {
      let totals = at(row.totals, index)

      pad_start(share(totals.flat, total), 7)
      <> pad_start(value_text(words.unit, totals.flat), width)
      <> pad_start(share(totals.cum, total), 8)
      <> pad_start(value_text(words.unit, totals.cum), width)
      <> "  "
      <> row.name
    })

  string.join(
    [
      "top "
        <> int.to_string(list.length(shown))
        <> " functions by "
        <> words.own
        <> " of their own ("
        <> value_text(words.unit, total)
        <> case words.unit {
        unit.Count -> " samples in all)"
        _ -> " in all)"
      },
      pad_start("flat", 7)
        <> pad_start("", width)
        <> pad_start("cum", 8)
        <> pad_start("", width)
        <> "  function",
      ..shown
    ],
    "\n",
  )
  <> "\n"
}

fn at(totals: List(top.Totals), index: Int) -> top.Totals {
  case list.drop(totals, index) {
    [found, ..] -> found
    [] -> top.Totals(flat: 0, cum: 0)
  }
}

// ------------------------------------------------------------------ tree

// One node of the merged call tree: the samples of every stack through it,
// and its children by function name.
type Node {
  Node(count: Int, children: Dict(String, Node))
}

/// The call tree: stacks merged from the root, each node's children ordered
/// by samples, a branch under the threshold left out.
///
/// ## Examples
///
/// ```gleam
/// text.tree(profile, column, text.default_config)
/// // -> Ok("call tree\n 100.0%  main/0\n ...")
/// ```
pub fn tree(
  profile: Profile,
  column: Column,
  config: Config,
) -> Result(String, ExportError) {
  use _ <- result.try(case profile.shape(profile.source(profile)) {
    profile.CallStacks -> Ok(Nil)
    profile.FunctionTotals ->
      Error(export.NoCallStacks(profile.source(profile)))
  })

  let total = profile.total(profile, column)

  let root =
    profile.merged_stacks(profile, column)
    |> list.filter(fn(stack) { stack.1 > 0 })
    |> list.fold(Node(count: 0, children: dict.new()), fn(node, stack) {
      let path =
        stack.0 |> list.reverse |> list.map(profile.name_of(profile, _))

      insert(node, path, stack.1)
    })

  let words = words_of(profile, column)
  let heading =
    "call tree (share of "
    <> value_text(words.unit, total)
    <> case words.unit {
      unit.Count -> " samples)"
      _ -> ", " <> words.own <> ")"
    }

  case total > 0 {
    False -> Ok(heading <> "\n  no samples\n")
    True -> {
      let lines = render(root.children, total, config, 0)
      let kept = list.take(lines, config.lines)
      let omitted = list.length(lines) - list.length(kept)
      let tail = case omitted {
        0 -> []
        n -> ["  ... " <> int.to_string(n) <> " more lines left out"]
      }

      Ok(string.join([heading, ..list.append(kept, tail)], "\n") <> "\n")
    }
  }
}

// Add one stack, root first, to the trie. Every node on the path gains the
// stack's samples, so a node's count is the cumulative value of its prefix.
fn insert(node: Node, path: List(String), value: Int) -> Node {
  case path {
    [] -> node
    [name, ..rest] -> {
      let child = case dict.get(node.children, name) {
        Ok(found) -> found
        Error(Nil) -> Node(count: 0, children: dict.new())
      }
      let grown = insert(Node(..child, count: child.count + value), rest, value)

      Node(..node, children: dict.insert(node.children, name, grown))
    }
  }
}

// Depth first, heaviest child first. A child under the threshold is left out
// with everything beneath it, since its descendants are lighter still.
fn render(
  children: Dict(String, Node),
  total: Int,
  config: Config,
  depth: Int,
) -> List(String) {
  children
  |> dict.to_list
  |> list.sort(fn(a, b) {
    order.break_tie(
      int.compare({ b.1 }.count, { a.1 }.count),
      string.compare(a.0, b.0),
    )
  })
  |> list.filter(fn(entry) { entry.1.count * 1000 / total >= config.min_tenths })
  |> list.flat_map(fn(entry) {
    let #(name, node) = entry
    let line =
      pad_start(share(node.count, total), 7)
      <> "  "
      <> string.repeat("  ", depth)
      <> name

    [line, ..render(node.children, total, config, depth + 1)]
  })
}

// ----------------------------------------------------------------- words

// What a column's values are, for the headings: its unit, and the phrase for
// "of their own" values (samples, or the column's name).
type Words {
  Words(unit: Unit, own: String)
}

fn words_of(profile: Profile, column: Column) -> Words {
  case profile.column_type(profile, column) {
    Ok(profile.ValueType(name:, unit: unit.Count)) ->
      case name {
        "samples" -> Words(unit: unit.Count, own: "samples")
        _ -> Words(unit: unit.Count, own: name)
      }
    Ok(profile.ValueType(name:, unit: other)) -> Words(unit: other, own: name)
    Error(Nil) -> Words(unit: unit.Count, own: "samples")
  }
}

// A value in its unit. Counts are plain integers. Times are written in the
// largest unit that keeps at least one whole digit, with integer arithmetic.
fn value_text(u: Unit, value: Int) -> String {
  case u {
    unit.Nanoseconds -> time_text(value)
    unit.Count | unit.Bytes | unit.Reductions | unit.Ratio(_) ->
      int.to_string(value)
  }
}

fn time_text(ns: Int) -> String {
  case ns {
    _ if ns >= 1_000_000_000 -> scaled(ns, 1_000_000_000, " s")
    _ if ns >= 1_000_000 -> scaled(ns, 1_000_000, " ms")
    _ if ns >= 1000 -> scaled(ns, 1000, " us")
    _ -> int.to_string(ns) <> " ns"
  }
}

// Two decimals of a unit, by integer arithmetic.
fn scaled(value: Int, per: Int, suffix: String) -> String {
  let hundredths = value * 100 / per
  let fraction = hundredths % 100

  int.to_string(hundredths / 100)
  <> "."
  <> string.pad_start(int.to_string(fraction), 2, "0")
  <> suffix
}

// ---------------------------------------------------------------- shares

// A share of a total as a percentage with one decimal. A zero total has no
// share, and the cell says so.
fn share(part: Int, total: Int) -> String {
  case total > 0 {
    False -> "n/a"
    True -> {
      let tenths = part * 1000 / total

      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> "%"
    }
  }
}

fn pad_start(text: String, width: Int) -> String {
  string.pad_start(text, width, " ")
}
