//// What every export carries: the text, and what it leaves out.
////
//// An export is a lossy projection of a capture. A collapsed-stacks file
//// has no units; a speedscope file has no coverage; a Chrome trace has no
//// stacks. A file that silently drops what the viewer showed lets a reader
//// mistake the file for the whole, so each export returns, with its text,
//// the list of what it did not carry, written for people. The viewer shows
//// the list in its export dialog and writes it beside the file as
//// `<name>.loss.txt`.
////
//// This module holds the shared types. The formats live in
//// `export/collapsed`, `export/speedscope` and `export/chrome_trace`.
////
//// A format function returns `Ok` of an `Export` or an `ExportError`. The
//// caller writes the body, and `loss_text` is the content of the sidecar.

import gleam/list
import gleam/string
import pickglass_core/profile.{type Source}

/// A finished export.
pub type Export {
  Export(
    /// The file content.
    body: String,
    /// One sentence per thing the format cannot carry, for this export.
    losses: List(String),
  )
}

/// Why an export could not be produced.
pub type ExportError {
  /// The profile's source has no calling context, and the format needs
  /// stacks.
  NoCallStacks(source: Source)
}

/// The sidecar text for a loss list: one line per loss.
///
/// ## Examples
///
/// ```gleam
/// export.loss_text(["units"])
/// // -> "This export does not carry:\n- units\n"
/// ```
pub fn loss_text(losses: List(String)) -> String {
  let lines = list.map(losses, fn(loss) { "- " <> loss })
  string.join(["This export does not carry:", ..lines], "\n") <> "\n"
}
