//// The pages of the application and where they live.
////
//// Navigation between pages is a plain link, not a message. A link to a page
//// asks the host to serve the page's route, and the host starts a component
//// for it, so no handler is attached and nothing in a page can be steered
//// to another page by a forged event. The `Page` type is closed, and
//// `href` is the only function that turns one into an address, so an
//// address is never built from text a browser sent.
////
//// `Links` says how addresses are written: `Routes` for the viewer, which
//// serves each page under a path, and `Files` for the static preview, where
//// each page is its own file.
////
//// ## Reading order
////
//// `nav_pages` is the order of the navigation bar; `title` and `href` give a
//// page's label and address; `process_href` addresses one process's detail
//// page by key.

import pickglass_web/key.{type Key}

/// A page of the application.
pub type Page {
  /// Memory layers, schedulers and OS roles.
  Overview

  /// Memory grouped by owner.
  Owners

  /// The process table.
  Processes

  /// One process.
  ProcessDetail

  /// Memory categories and allocators.
  Memory

  /// The supervision tree.
  Supervision

  /// Probes: plan, active and history.
  Probes

  /// A profile: flame, icicle, graph, top, peek and source.
  Profile

  /// Counters and spans over time.
  Timeline

  /// Two captures side by side.
  Compare

  /// The decision log.
  Audit
}

/// How addresses are written.
pub type Links {
  /// Paths under the viewer's root, for the live host.
  Routes

  /// One file per page, for the static preview.
  Files
}

/// The pages in navigation order. The process detail page is reached from a
/// row and has no entry.
pub const nav_pages: List(Page) = [
  Overview,
  Owners,
  Processes,
  Memory,
  Supervision,
  Probes,
  Profile,
  Timeline,
  Compare,
  Audit,
]

/// The label of a page.
pub fn title(page: Page) -> String {
  case page {
    Overview -> "Overview"
    Owners -> "Owners"
    Processes -> "Processes"
    ProcessDetail -> "Process"
    Memory -> "Memory"
    Supervision -> "Supervision"
    Probes -> "Probes"
    Profile -> "Profile"
    Timeline -> "Timeline"
    Compare -> "Compare"
    Audit -> "Audit"
  }
}

fn slug(page: Page) -> String {
  case page {
    Overview -> "overview"
    Owners -> "owners"
    Processes -> "processes"
    ProcessDetail -> "process-detail"
    Memory -> "memory"
    Supervision -> "supervision"
    Probes -> "probes"
    Profile -> "profile"
    Timeline -> "timeline"
    Compare -> "compare"
    Audit -> "audit"
  }
}

/// The address of a page.
///
/// ## Examples
///
/// ```gleam
/// page.href(Routes, Owners)
/// // -> "/owners"
///
/// page.href(Files, Owners)
/// // -> "owners.html"
/// ```
pub fn href(links: Links, page: Page) -> String {
  case links {
    Routes -> "/" <> slug(page)
    Files -> slug(page) <> ".html"
  }
}

/// The address of one process's detail page. The key is the viewer's, whose
/// alphabet is safe in a path.
pub fn process_href(links: Links, process: Key) -> String {
  case links {
    Routes -> "/process/" <> key.to_string(process)
    Files -> "process-detail.html"
  }
}
