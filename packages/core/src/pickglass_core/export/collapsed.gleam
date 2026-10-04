//// Collapsed stacks, the input of Brendan Gregg's flamegraph.pl.
////
//// One line per distinct stack: the frames from the root to the leaf joined
//// by `;`, a space, and the stack's value. Almost every flame graph tool
//// reads it, which makes it the export of last resort. It is also the
//// poorest: it holds one value type and no units.
////
//// Lines are sorted so equal profiles give equal files. A `;` or a newline
//// inside a function name would break the format, so each becomes a
//// comma or a space. Stacks with a zero or negative total are left out,
//// since the format has no representation for them.
////
//// ## Flow
////
//// `export` merges stacks, renders each as a `line` (cleaning each frame
//// name with `clean`), sorts the lines and joins them.

import gleam/int
import gleam/list
import gleam/string
import pickglass_core/export.{type Export, type ExportError, Export}
import pickglass_core/profile.{type Column, type Profile}

/// Write one column of a profile as collapsed stacks.
///
/// ## Examples
///
/// ```gleam
/// collapsed.export(p, column)
/// // -> Ok(Export("a:main/0;b:run/1 5\n", losses))
/// ```
pub fn export(profile: Profile, column: Column) -> Result(Export, ExportError) {
  case profile.shape(profile.source(profile)) {
    profile.FunctionTotals ->
      Error(export.NoCallStacks(profile.source(profile)))
    profile.CallStacks -> {
      let lines =
        profile.merged_stacks(profile, column)
        |> list.filter(fn(stack) { stack.1 > 0 })
        |> list.map(fn(stack) { line(profile, stack.0, stack.1) })
        |> list.sort(string.compare)
      let body = case lines {
        [] -> ""
        _ -> string.join(lines, "\n") <> "\n"
      }
      Ok(Export(body: body, losses: losses()))
    }
  }
}

fn line(profile: Profile, frames: List(Int), value: Int) -> String {
  let names =
    frames
    |> list.reverse
    |> list.map(fn(id) { clean(profile.name_of(profile, id)) })
  string.join(names, ";") <> " " <> int.to_string(value)
}

fn clean(name: String) -> String {
  name
  |> string.replace(";", ",")
  |> string.replace("\n", " ")
}

/// What this format leaves out.
pub fn losses() -> List(String) {
  [
    "Units: values are bare numbers.",
    "Every value type but the one exported.",
    "Coverage and truncation: whether the profile is complete.",
    "Owner labels: which session or strand a sample belongs to.",
    "Provenance: when, where and how the profile was taken.",
    "Stacks whose total is zero or negative.",
  ]
}
