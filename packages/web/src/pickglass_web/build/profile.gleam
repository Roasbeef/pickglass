//// Building the profile page's model from a profile and a filter chain.
////
//// The profile page draws six views of one profile after a chain of filter
//// steps. Every number on it comes from core's analyses, so this module
//// only sequences them: it applies the chain (`transform.apply`), then asks
//// for the flame layout, the call graph, its layered placement, the Peek of
//// each node and the Top table. Where the profile's source has no calling
//// context (counters, allocation counts) core refuses the flame and the
//// graph; this module turns that refusal into `NoStacks`, so the page says
//// why instead of drawing an empty picture, and the Top table is still
//// built, because function totals need no stacks.
////
//// The module is pure and lives in `src` so the viewer can build the page
//// from a profile it measured; the preview's fixture builds its profile the
//// same way by hand.
////
//// ## Flow
////
//// - `build` applies the chain and computes every view's data.
//// - `Failure` says which step failed and why, so a caller can drop the
////   step that broke the chain.

import gleam/list
import gleam/option.{None}
import gleam/result
import pickglass_core/analysis/graph
import pickglass_core/analysis/peek
import pickglass_core/analysis/top
import pickglass_core/analysis/transform
import pickglass_core/layout/dag
import pickglass_core/layout/flame
import pickglass_core/profile.{type Column, type Profile}
import pickglass_web/model

/// Why the model could not be built.
pub type Failure {
  /// A step's pattern did not compile.
  ChainRefused(transform.ChainError)

  /// The Top table could not be built for the chosen column.
  TopRefused(top.TopError)

  /// The call graph could not be built although the source has stacks.
  GraphRefused(graph.BuildError)
}

/// Build the page's model of `base` after `chain`, drawn from `column`.
///
/// ## Examples
///
/// ```gleam
/// profile_page.build(header, base, column, [transform.Focus("loom@")], [])
/// ```
pub fn build(
  header: model.ProfileHeader,
  base: Profile,
  column: Column,
  chain: List(transform.Step),
  exports: List(model.ExportNote),
) -> Result(model.ProfileModel, Failure) {
  use applied <- result.try(
    transform.apply(base, chain, column) |> result.map_error(ChainRefused),
  )
  use table <- result.try(
    top.table(applied.profile, None, top.Sort(column:, key: top.ByFlat))
    |> result.map_error(TopRefused),
  )
  use stacks <- result.try(stacks_of(applied, column))

  Ok(model.ProfileModel(
    header: model.ProfileHeader(
      ..header,
      source: profile.source(applied.profile),
    ),
    profile: applied.profile,
    column:,
    chain: applied.reports,
    stacks:,
    top: table,
    exports:,
  ))
}

// A source with no calling context has no flame and no graph; core says so
// with `NoCallStacks` and that is the only refusal turned into a value.
fn stacks_of(
  applied: transform.Applied,
  column: Column,
) -> Result(model.Stacks, Failure) {
  case flame.layout(applied.profile, column, flame.default_config) {
    Error(flame.NoCallStacks(source:)) -> Ok(model.NoStacks(source:))
    Ok(layout) -> {
      use call_graph <- result.map(
        graph.build(
          applied.profile,
          column,
          graph.with_display(graph.default_config, applied.display),
        )
        |> result.map_error(GraphRefused),
      )

      let name_of = fn(id) { profile.name_of(applied.profile, id) }

      model.HasStacks(
        layout:,
        graph: call_graph,
        dag: dag.layout(call_graph, name_of, dag.default_config),
        peeks: list.filter_map(call_graph.nodes, fn(node) {
          peek.at(call_graph, node.function)
        }),
      )
    }
  }
}
