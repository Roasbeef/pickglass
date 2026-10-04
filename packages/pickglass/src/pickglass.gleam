//// Pickglass: a runtime inspector and performance and trace viewer for the
//// BEAM, written in Gleam.
////
//// With no arguments the program prints its banner, which is what `make
//// release-smoke` compares against the version in `gleam.toml`: that
//// comparison proves the artifact that booted is the artifact that was
//// built. With `attach` it joins a profiled node, pushes the agent, prints
//// what the agent reports and detaches; `pickglass/cli` owns that.
////
//// The release launcher boots the bundled runtime and runs
//// `pickglass@@main:run(pickglass)`, which calls `main` below.

import argv
import gleam/io
import gleam/option.{Some}
import pickglass/cli
import pickglass/internal/ffi_os
import pickglass/once
import pickglass/serve

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

/// Run the command line. With no arguments, print the banner and return;
/// the release launcher halts the emulator once it does. With arguments, run
/// the command and end the VM with its exit status.
///
/// ## Examples
///
/// ```gleam
/// pickglass.main()
/// // prints "pickglass 0.1.0"
/// ```
pub fn main() -> Nil {
  case cli.parse(argv.load().arguments) {
    Ok(cli.ShowBanner) -> io.println(banner())
    Ok(cli.ShowHelp) -> io.println(cli.usage)
    Ok(cli.Attach(cli.AttachOptions(once: Some(out), ..) as options)) ->
      ffi_os.halt(
        once.run(once.Request(
          state_dir: options.state_dir,
          pid: options.pid,
          agent_ebin: options.agent_ebin,
          out:,
          version:,
        )),
      )
    Ok(cli.Attach(options)) -> ffi_os.halt(cli.run_attach(options))
    Ok(cli.Open(options)) -> ffi_os.halt(serve.run_open(options, version))
    Ok(cli.View(options)) -> ffi_os.halt(serve.run_view(options))
    Error(message) -> {
      io.println_error("pickglass: " <> message)
      io.println_error(cli.usage)
      ffi_os.halt(2)
    }
  }
}
