//// The static files the host serves: Lustre's client runtime and the web
//// package's stylesheet.
////
//// The list is closed. Both files are read once at start from the `priv`
//// directories of their applications, which `code:priv_dir` finds in a
//// release and in a development build alike, and a request names one of the
//// two fixed file names or gets a 404. No path from a request ever reaches
//// the file system. A file that cannot be read is a start-up error, so a
//// release missing its stylesheet fails at once and not on the first page.
////
//// This is also the hook for the web package's assets: the stylesheet is
//// `pickglass_web`'s `priv/pickglass.css`, and a future file is one more
//// entry in `manifest`.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import pickglass/internal/ffi_dist
import simplifile

/// One file in memory, with the type it is served as.
pub type Asset {
  Asset(content_type: String, bytes: BitArray)
}

/// The loaded files, by the name a request uses.
pub type Assets {
  Assets(files: Dict(String, Asset))
}

/// The file a page's `<script>` loads for the Lustre client runtime.
pub const runtime_name = "lustre-server-component.min.mjs"

/// The stylesheet the page links.
pub const stylesheet_name = "pickglass.css"

// Name, owning application, path under its `priv`, content type.
const manifest = [
  #(
    runtime_name,
    "lustre",
    "static/lustre-server-component.min.mjs",
    "text/javascript",
  ),
  #(stylesheet_name, "pickglass_web", "pickglass.css", "text/css"),
]

/// Read every file in the manifest. `Error` names the first one that could
/// not be found or read.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(assets) = assets.load()
/// ```
pub fn load() -> Result(Assets, String) {
  manifest
  |> list.try_map(fn(entry) {
    let #(name, application, path, content_type) = entry

    use priv <- result.try(
      ffi_dist.priv_directory(application)
      |> result.map_error(fn(_) {
        "cannot find the priv directory of " <> application
      }),
    )
    use bytes <- result.try(
      simplifile.read_bits(priv <> "/" <> path)
      |> result.map_error(fn(error) {
        "cannot read "
        <> priv
        <> "/"
        <> path
        <> ": "
        <> simplifile.describe_error(error)
      }),
    )

    Ok(#(name, Asset(content_type:, bytes:)))
  })
  |> result.map(fn(files) { Assets(files: dict.from_list(files)) })
}

/// A file by the name a request used.
pub fn get(assets: Assets, name: String) -> Result(Asset, Nil) {
  dict.get(assets.files, name)
}
