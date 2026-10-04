//// Finding and reading the agent's compiled modules.
////
//// The viewer pushes the agent into the target as bytes, so it needs the
//// agent's `.beam` files at run time. A release carries them in the
//// viewer's `priv/agent` directory. In development they are the build
//// output of `packages/agent`. `pickglass_agent@@main.beam` is the
//// compiler's entry module for running the agent as a program; it imports
//// the standard library and is never pushed.

import gleam/list
import gleam/result
import gleam/string
import pickglass/internal/ffi_dist
import simplifile

/// One module to push: its name and compiled bytes.
pub type Beam {
  Beam(module: String, file_name: String, bytes: BitArray)
}

/// Where the beams are looked for when no directory is named: the
/// viewer's `priv/agent` first, then the development build output relative
/// to the working directory.
fn default_directories() -> List(String) {
  let from_priv = case ffi_dist.priv_directory("pickglass") {
    Ok(priv) -> [priv <> "/agent"]
    Error(Nil) -> []
  }

  list.append(from_priv, [
    "../agent/build/dev/erlang/pickglass_agent/ebin",
    "packages/agent/build/dev/erlang/pickglass_agent/ebin",
  ])
}

/// Read every agent module from a directory, or from the first default
/// directory that exists.
///
/// ## Examples
///
/// ```gleam
/// agent_beams.load(None)
/// // -> Ok([Beam("pickglass_agent@server", ...), ...])
/// ```
pub fn load(directory: Result(String, Nil)) -> Result(List(Beam), String) {
  let candidates = case directory {
    Ok(named) -> [named]
    Error(Nil) -> default_directories()
  }

  case
    list.find(candidates, fn(path) { simplifile.is_directory(path) == Ok(True) })
  {
    Error(Nil) ->
      Error(
        "no agent beams found; build packages/agent or pass --agent-ebin DIR",
      )
    Ok(found) -> read_all(found)
  }
}

fn read_all(directory: String) -> Result(List(Beam), String) {
  use entries <- result.try(
    simplifile.read_directory(directory)
    |> result.replace_error("cannot read " <> directory),
  )

  let files =
    list.filter(entries, fn(entry) {
      string.ends_with(entry, ".beam")
      && !string.ends_with(entry, "@@main.beam")
      && string.starts_with(entry, "pickglass_agent@")
    })

  case files {
    [] -> Error("no pickglass_agent@ beams in " <> directory)
    _ -> list.try_map(files, fn(file) { read_beam(directory, file) })
  }
}

fn read_beam(directory: String, file: String) -> Result(Beam, String) {
  let path = directory <> "/" <> file

  use bytes <- result.try(
    simplifile.read_bits(path) |> result.replace_error("cannot read " <> path),
  )

  Ok(Beam(module: string.drop_end(file, 5), file_name: path, bytes:))
}
