//// A synthetic stack profile shaped like a Loom daemon.
////
//// The preview and the tests need a profile with enough structure to make
//// every view show something: roughly forty functions across the
//// `loom`, `weft`, `gleam` and OTP packages, call paths of different depths,
//// recursion through the actor loop, a few hot leaves and a long tail. The
//// numbers are invented; the shape is chosen so that a keeper holding a large
//// state dominates one path, a provider gateway dominates another, and the
//// candidate profile used by Compare has less keeper work than the base.
////
//// The module lives under `dev/` so it is compiled for the preview and the
//// tests and never ships in the viewer's release.
////
//// ## Flow
////
//// `functions` is the function table; `paths` lists call paths root first
//// with a base and a candidate weight; `build` turns one of the two columns
//// into a `Profile`.

import gleam/dict
import gleam/list
import gleam/option.{Some}
import pickglass_core/profile.{type Function, type Profile, type Sample}
import pickglass_core/unit

/// One entry of the function table: short name, module, function, arity and
/// the source file the module compiles from.
type Entry {
  Entry(short: String, module: String, name: String, arity: Int, file: String)
}

fn table() -> List(Entry) {
  [
    Entry("init", "proc_lib", "init_p", 5, "proc_lib.erl"),
    Entry("loop", "gleam@otp@actor", "loop", 2, "src/gleam/otp/actor.gleam"),
    Entry(
      "recv",
      "gleam@erlang@process",
      "receive_forever",
      1,
      "src/gleam/erlang/process.gleam",
    ),
    Entry("a_handle", "weft@actor", "handle", 3, "src/weft/actor.gleam"),
    Entry("a_send", "weft@actor", "send", 2, "src/weft/actor.gleam"),
    Entry(
      "sm_step",
      "weft@state_machine",
      "step",
      3,
      "src/weft/state_machine.gleam",
    ),
    Entry(
      "k_handle",
      "loom@runtime@keeper",
      "handle",
      2,
      "src/loom/runtime/keeper.gleam",
    ),
    Entry(
      "k_snap",
      "loom@runtime@keeper",
      "snapshot",
      1,
      "src/loom/runtime/keeper.gleam",
    ),
    Entry(
      "k_persist",
      "loom@runtime@keeper",
      "persist",
      2,
      "src/loom/runtime/keeper.gleam",
    ),
    Entry(
      "k_hold",
      "loom@runtime@keeper",
      "hold",
      2,
      "src/loom/runtime/keeper.gleam",
    ),
    Entry(
      "k_restart",
      "loom@runtime@keeper",
      "restart",
      1,
      "src/loom/runtime/keeper.gleam",
    ),
    Entry(
      "s_step",
      "loom@runtime@strand",
      "step",
      4,
      "src/loom/runtime/strand.gleam",
    ),
    Entry(
      "s_run",
      "loom@runtime@strand",
      "run",
      2,
      "src/loom/runtime/strand.gleam",
    ),
    Entry(
      "s_dispatch",
      "loom@runtime@strand",
      "dispatch",
      3,
      "src/loom/runtime/strand.gleam",
    ),
    Entry(
      "s_effect",
      "loom@runtime@strand",
      "apply_effect",
      2,
      "src/loom/runtime/strand.gleam",
    ),
    Entry(
      "g_run",
      "loom@provider@gateway",
      "run",
      2,
      "src/loom/provider/gateway.gleam",
    ),
    Entry(
      "g_request",
      "loom@provider@gateway",
      "request",
      3,
      "src/loom/provider/gateway.gleam",
    ),
    Entry(
      "g_stream",
      "loom@provider@gateway",
      "stream",
      2,
      "src/loom/provider/gateway.gleam",
    ),
    Entry(
      "g_chunk",
      "loom@provider@gateway",
      "decode_chunk",
      1,
      "src/loom/provider/gateway.gleam",
    ),
    Entry(
      "c_append",
      "loom@store@conversation",
      "append",
      3,
      "src/loom/store/conversation.gleam",
    ),
    Entry(
      "c_read",
      "loom@store@conversation",
      "read",
      2,
      "src/loom/store/conversation.gleam",
    ),
    Entry(
      "c_fold",
      "loom@store@conversation",
      "fold",
      3,
      "src/loom/store/conversation.gleam",
    ),
    Entry(
      "b_call",
      "loom@tools@broker",
      "call",
      3,
      "src/loom/tools/broker.gleam",
    ),
    Entry(
      "b_check",
      "loom@tools@broker",
      "check",
      2,
      "src/loom/tools/broker.gleam",
    ),
    Entry("l_map", "gleam@list", "map", 2, "src/gleam/list.gleam"),
    Entry("l_fold", "gleam@list", "fold", 3, "src/gleam/list.gleam"),
    Entry("l_filter", "gleam@list", "filter", 2, "src/gleam/list.gleam"),
    Entry("l_reverse", "gleam@list", "reverse", 1, "src/gleam/list.gleam"),
    Entry("d_insert", "gleam@dict", "insert", 3, "src/gleam/dict.gleam"),
    Entry("d_get", "gleam@dict", "get", 2, "src/gleam/dict.gleam"),
    Entry("d_fold", "gleam@dict", "fold", 3, "src/gleam/dict.gleam"),
    Entry("j_decode", "gleam@json", "decode", 2, "src/gleam/json.gleam"),
    Entry("j_string", "gleam@json", "to_string", 1, "src/gleam/json.gleam"),
    Entry("st_concat", "gleam@string", "concat", 1, "src/gleam/string.gleam"),
    Entry("st_split", "gleam@string", "split", 2, "src/gleam/string.gleam"),
    Entry(
      "ba_str",
      "gleam@bit_array",
      "to_string",
      1,
      "src/gleam/bit_array.gleam",
    ),
    Entry("db_exec", "esqlite3", "exec", 2, "esqlite3.erl"),
    Entry("tls", "ssl_gen_statem", "handle_info", 4, "ssl_gen_statem.erl"),
    Entry("lg", "logger_h_common", "log", 2, "logger_h_common.erl"),
    Entry(
      "m_fmt",
      "loom@telemetry@metrics",
      "format",
      2,
      "src/loom/telemetry/metrics.gleam",
    ),
    Entry(
      "m_emit",
      "loom@telemetry@metrics",
      "emit",
      3,
      "src/loom/telemetry/metrics.gleam",
    ),
  ]
}

/// The function table with ids assigned in table order.
pub fn functions() -> List(Function) {
  table()
  |> list.index_map(fn(entry, id) {
    profile.Function(
      id:,
      module: entry.module,
      name: entry.name,
      arity: entry.arity,
      file: Some(entry.file),
      line: Some(10 + id * 7),
      precision: profile.FunctionLevel,
    )
  })
}

/// A call path, root first, with the weight in the base capture and in the
/// candidate capture.
type Path {
  Path(frames: List(String), base: Int, candidate: Int)
}

fn paths() -> List(Path) {
  let root = ["init", "loop"]

  [
    Path(list.append(root, ["recv"]), 1400, 1380),
    Path(list.append(root, ["a_handle", "k_handle"]), 640, 90),
    Path(list.append(root, ["a_handle", "k_handle", "k_snap"]), 1150, 60),
    Path(
      list.append(root, ["a_handle", "k_handle", "k_snap", "d_fold"]),
      820,
      40,
    ),
    Path(
      list.append(root, ["a_handle", "k_handle", "k_snap", "d_fold", "l_fold"]),
      540,
      25,
    ),
    Path(
      list.append(root, ["a_handle", "k_handle", "k_persist", "j_string"]),
      410,
      70,
    ),
    Path(
      list.append(root, [
        "a_handle",
        "k_handle",
        "k_persist",
        "j_string",
        "st_concat",
      ]),
      180,
      35,
    ),
    Path(
      list.append(root, ["a_handle", "k_handle", "k_persist", "db_exec"]),
      320,
      300,
    ),
    Path(
      list.append(root, ["a_handle", "k_handle", "k_hold", "d_insert"]),
      150,
      140,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "s_dispatch", "s_effect"]),
      520,
      510,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "s_dispatch", "b_call", "b_check"]),
      260,
      255,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "s_dispatch", "b_call", "l_map"]),
      140,
      150,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "s_run", "g_run", "g_request"]),
      610,
      640,
    ),
    Path(
      list.append(root, [
        "sm_step",
        "s_step",
        "s_run",
        "g_run",
        "g_request",
        "tls",
      ]),
      880,
      900,
    ),
    Path(
      list.append(root, [
        "sm_step",
        "s_step",
        "s_run",
        "g_run",
        "g_stream",
        "g_chunk",
      ]),
      730,
      745,
    ),
    Path(
      list.append(root, [
        "sm_step",
        "s_step",
        "s_run",
        "g_run",
        "g_stream",
        "g_chunk",
        "j_decode",
      ]),
      560,
      570,
    ),
    Path(
      list.append(root, [
        "sm_step",
        "s_step",
        "s_run",
        "g_run",
        "g_stream",
        "g_chunk",
        "j_decode",
        "ba_str",
      ]),
      190,
      195,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "c_append", "db_exec"]),
      340,
      330,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "c_read", "c_fold", "l_fold"]),
      280,
      275,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "c_read", "c_fold", "d_get"]),
      120,
      118,
    ),
    Path(
      list.append(root, ["sm_step", "s_step", "c_read", "c_fold", "l_reverse"]),
      60,
      62,
    ),
    Path(list.append(root, ["a_handle", "a_send"]), 90, 92),
    Path(
      list.append(root, ["a_handle", "m_emit", "m_fmt", "st_concat"]),
      140,
      138,
    ),
    Path(list.append(root, ["a_handle", "m_emit", "m_fmt", "l_filter"]), 45, 44),
    Path(list.append(root, ["a_handle", "lg"]), 70, 72),
    Path(list.append(root, ["a_handle", "k_handle", "k_restart"]), 25, 20),
    Path(
      list.append(root, ["sm_step", "s_step", "s_dispatch", "st_split"]),
      38,
      39,
    ),
  ]
}

/// Which of the two weight columns to build from.
pub type Capture {
  /// The baseline capture.
  Base

  /// The candidate capture, with less keeper work.
  Candidate
}

/// Build the profile of one capture.
pub fn build(which: Capture) -> Result(Profile, profile.BuildError) {
  let ids =
    table()
    |> list.index_map(fn(entry, id) { #(entry.short, id) })
    |> dict.from_list

  let samples =
    list.filter_map(paths(), fn(path) {
      let weight = case which {
        Base -> path.base
        Candidate -> path.candidate
      }

      case list.try_map(path.frames, fn(short) { dict.get(ids, short) }) {
        Ok(frames) -> Ok(leaf_first(frames, weight))
        Error(Nil) -> Error(Nil)
      }
    })

  profile.new(
    profile.SampledStacks(method: "current_stacktrace", rate: 50),
    [profile.ValueType(name: "samples", unit: unit.Count)],
    functions(),
    samples,
  )
}

fn leaf_first(frames: List(Int), weight: Int) -> Sample {
  profile.Sample(frames: list.reverse(frames), values: [weight], labels: [
    #("owner", "session s-12"),
  ])
}
