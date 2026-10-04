//// A raw HTTP and WebSocket client over `gen_tcp`, for the host tests.
////
//// The host is tested through a real listener on loopback, with requests
//// written byte by byte, because the cases that matter (a missing cookie, a
//// wrong `Origin`, a frame with an extra key) are exactly what a browser
//// never sends. Frames are masked with the zero key, which is a valid mask
//// that leaves the payload unchanged.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "gleam_stdlib", "identity")
fn dyn(value: a) -> Dynamic

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  host: Dynamic,
  port: Int,
  options: Dynamic,
  timeout: Int,
) -> Dynamic

@external(erlang, "gen_tcp", "send")
fn tcp_send(socket: Dynamic, data: BitArray) -> Dynamic

@external(erlang, "gen_tcp", "recv")
fn tcp_recv(socket: Dynamic, length: Int, timeout: Int) -> Dynamic

@external(erlang, "gen_tcp", "close")
fn tcp_close(socket: Dynamic) -> Dynamic

/// An open connection.
pub type Conn {
  Conn(socket: Dynamic, pending: BitArray)
}

/// What an HTTP exchange returned.
pub type Reply {
  Reply(status: Int, headers: String, body: String)
}

pub fn connect(port: Int) -> Conn {
  let options =
    dyn([
      dyn(atom.create("binary")),
      dyn(#(atom.create("active"), False)),
    ])
  let assert Ok(socket) =
    decode.run(
      tcp_connect(dyn(#(127, 0, 0, 1)), port, options, 2000),
      decode.field(1, decode.dynamic, decode.success),
    )

  Conn(socket:, pending: <<>>)
}

fn receive(conn: Conn, wait_ms: Int) -> Result(BitArray, Nil) {
  decode.run(
    tcp_recv(conn.socket, 0, wait_ms),
    decode.field(1, decode.bit_array, decode.success),
  )
  |> result.replace_error(Nil)
}

fn read_until_closed(conn: Conn, so_far: BitArray) -> BitArray {
  case receive(conn, 1500) {
    Ok(chunk) -> read_until_closed(conn, bit_array.append(so_far, chunk))
    Error(Nil) -> so_far
  }
}

/// Send one `GET` and read the whole reply. `headers` are extra lines.
pub fn get(port: Int, path: String, headers: List(#(String, String))) -> Reply {
  let conn = connect(port)
  let lines =
    list.append(
      [#("Host", "127.0.0.1:" <> int.to_string(port)), #("Connection", "close")],
      headers,
    )
  let text =
    "GET "
    <> path
    <> " HTTP/1.1\r\n"
    <> string.join(
      list.map(lines, fn(pair) { pair.0 <> ": " <> pair.1 }),
      "\r\n",
    )
    <> "\r\n\r\n"
  let _ = tcp_send(conn.socket, bit_array.from_string(text))
  let raw = read_until_closed(conn, <<>>)
  let _ = tcp_close(conn.socket)

  parse_reply(result.unwrap(bit_array.to_string(raw), ""))
}

fn parse_reply(text: String) -> Reply {
  let #(head, body) = case string.split_once(text, "\r\n\r\n") {
    Ok(pair) -> pair
    Error(Nil) -> #(text, "")
  }
  let status = case string.split(head, " ") {
    [_, code, ..] -> result.unwrap(int.parse(code), 0)
    _ -> 0
  }

  Reply(status:, headers: head, body:)
}

/// The value of a response header, or an empty string.
pub fn header(reply: Reply, name: String) -> String {
  reply.headers
  |> string.split("\r\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, ": ") {
      Ok(#(key, value)) ->
        case string.lowercase(key) == string.lowercase(name) {
          True -> Ok(value)
          False -> Error(Nil)
        }
      Error(Nil) -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

/// Attempt a WebSocket upgrade. On `101` the connection is returned for
/// frames; otherwise the refusal.
pub fn upgrade(
  port: Int,
  path: String,
  headers: List(#(String, String)),
) -> Result(Conn, Reply) {
  let conn = connect(port)
  let lines =
    list.append(
      [
        #("Host", "127.0.0.1:" <> int.to_string(port)),
        #("Connection", "Upgrade"),
        #("Upgrade", "websocket"),
        #("Sec-WebSocket-Version", "13"),
        #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
      ],
      headers,
    )
  let text =
    "GET "
    <> path
    <> " HTTP/1.1\r\n"
    <> string.join(
      list.map(lines, fn(pair) { pair.0 <> ": " <> pair.1 }),
      "\r\n",
    )
    <> "\r\n\r\n"
  let _ = tcp_send(conn.socket, bit_array.from_string(text))

  case read_head(conn, <<>>) {
    Error(Nil) -> Error(Reply(0, "", ""))
    Ok(raw) -> {
      let reply = parse_reply(result.unwrap(bit_array.to_string(raw), ""))

      case reply.status {
        101 -> Ok(Conn(..conn, pending: leftover(raw)))
        _ -> {
          let _ = tcp_close(conn.socket)

          Error(reply)
        }
      }
    }
  }
}

// Read until the blank line that ends the response head has arrived. A
// receive returns whatever the socket holds, and a server that writes the
// status line and the headers in separate sends can have the first segment
// reach the client alone, so one receive is not the head. Parsing it as if it
// were gave a status of zero and a refused upgrade that the server had never
// refused. The wait applies to each receive, so a server that is slow to
// answer is still told apart from one that answered in pieces.
fn read_head(conn: Conn, so_far: BitArray) -> Result(BitArray, Nil) {
  case split_head(so_far, 0) {
    Ok(_) -> Ok(so_far)
    Error(Nil) ->
      case receive(conn, 2000) {
        Ok(chunk) -> read_head(conn, bit_array.append(so_far, chunk))
        Error(Nil) ->
          case so_far {
            <<>> -> Error(Nil)
            _ -> Ok(so_far)
          }
      }
  }
}

// Bytes after the blank line that ends the response head: the first frame
// can arrive in the same segment as the handshake.
fn leftover(raw: BitArray) -> BitArray {
  case split_head(raw, 0) {
    Ok(offset) ->
      bit_array.slice(raw, offset, bit_array.byte_size(raw) - offset)
      |> result.unwrap(<<>>)
    Error(Nil) -> <<>>
  }
}

fn split_head(raw: BitArray, offset: Int) -> Result(Int, Nil) {
  case bit_array.slice(raw, offset, 4) {
    Ok(<<"\r\n\r\n":utf8>>) -> Ok(offset + 4)
    Ok(_) -> split_head(raw, offset + 1)
    Error(Nil) -> Error(Nil)
  }
}

/// Send a text frame, masked with the zero key.
pub fn send_text(conn: Conn, text: String) -> Nil {
  let payload = bit_array.from_string(text)
  let size = bit_array.byte_size(payload)
  let length = case size < 126 {
    True -> <<{ 128 + size }:8>>
    False -> <<254:8, size:16>>
  }
  let frame = <<129:8, length:bits, 0:32, payload:bits>>
  let _ = tcp_send(conn.socket, frame)

  Nil
}

/// Read one server text frame, or `Error` when none arrives in time or the
/// connection closed. The connection is returned with what is left over.
pub fn read_text(conn: Conn, wait_ms: Int) -> #(Result(String, Nil), Conn) {
  case frame_of(conn.pending) {
    Ok(#(text, rest)) -> #(Ok(text), Conn(..conn, pending: rest))
    Error(False) -> #(Error(Nil), conn)
    Error(True) ->
      case receive(conn, wait_ms) {
        Error(Nil) -> #(Error(Nil), conn)
        Ok(more) ->
          read_text(
            Conn(..conn, pending: bit_array.append(conn.pending, more)),
            wait_ms,
          )
      }
  }
}

// `Error(True)` means more bytes are needed; `Error(False)` means the frame
// is not a text frame.
fn frame_of(buffer: BitArray) -> Result(#(String, BitArray), Bool) {
  case buffer {
    <<_:4, 1:4, 0:1, 126:7, size:16, rest:bytes>> -> take(rest, size)
    <<_:4, 1:4, 0:1, 127:7, size:64, rest:bytes>> -> take(rest, size)
    <<_:4, 1:4, 0:1, size:7, rest:bytes>> if size < 126 -> take(rest, size)
    <<_:4, 8:4, _:bytes>> -> Error(False)
    _ -> Error(True)
  }
}

fn take(rest: BitArray, size: Int) -> Result(#(String, BitArray), Bool) {
  case bit_array.byte_size(rest) >= size {
    False -> Error(True)
    True -> {
      use payload <- result.try(
        bit_array.slice(rest, 0, size) |> result.replace_error(True),
      )
      use text <- result.try(
        bit_array.to_string(payload) |> result.replace_error(False),
      )
      let remainder =
        bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
        |> result.unwrap(<<>>)

      Ok(#(text, remainder))
    }
  }
}

pub fn close(conn: Conn) -> Nil {
  let _ = tcp_close(conn.socket)

  Nil
}
