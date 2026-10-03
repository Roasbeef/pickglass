//// Pickglass: a runtime inspector and performance and trace viewer for the
//// BEAM, written in Gleam.
////
//// This module is a placeholder. The product design is not settled, so the
//// package holds only what the build, the release and the smoke test need:
//// a version, a one-line banner, and a `main` the self-contained release
//// launcher calls. The launcher boots the bundled runtime, runs
//// `pickglass@@main:run(pickglass)`, and the banner printed here is what
//// `make release-smoke` compares against the version in `gleam.toml`. That
//// comparison is the reason `version` exists at all today: it proves the
//// artifact that booted is the artifact that was built.
////
//// The workspace will grow a pure core, an impure collector host and a
//// Lustre web package beside this one. Until then there is nothing for them
//// to depend on, so nothing is exported for them.

import gleam/io

/// The package version, kept equal to the `version` in `gleam.toml`.
/// `make release-smoke` fails when the two drift, so a release can never
/// report a version it was not built from.
///
/// ## Examples
///
/// ```gleam
/// pickglass.version
/// // -> "0.1.0"
/// ```
pub const version = "0.1.0"

/// The line the release launcher prints: the program name and its version,
/// in the shape `pickglass <version>`.
///
/// ## Examples
///
/// ```gleam
/// pickglass.banner()
/// // -> "pickglass 0.1.0"
/// ```
pub fn banner() -> String {
  "pickglass " <> version
}

/// Print the banner and return. The release launcher evaluates this through
/// the generated `pickglass@@main` entry module, which halts the emulator
/// once it returns.
///
/// ## Examples
///
/// ```gleam
/// pickglass.main()
/// // prints "pickglass 0.1.0"
/// ```
pub fn main() -> Nil {
  io.println(banner())
}
