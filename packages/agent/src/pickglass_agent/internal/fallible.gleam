//// The one `Result` combinator the agent needs.
////
//// The agent may not import `gleam/result`, so `try` is written here. It is
//// what lets a chain of checks read top to bottom with `use`, the shape the
//// house style asks for, instead of nesting a `case` per step.

/// Continue with the value inside an `Ok`, or stop at the first `Error`.
///
/// ## Examples
///
/// ```gleam
/// use n <- fallible.then(Ok(1))
/// Ok(n + 1)
/// // -> Ok(2)
/// ```
pub fn then(result: Result(a, e), next: fn(a) -> Result(b, e)) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> Error(reason)
  }
}

/// Replace the error of a result.
///
/// ## Examples
///
/// ```gleam
/// fallible.replace_error(Error(Nil), "bad")
/// // -> Error("bad")
/// ```
pub fn replace_error(result: Result(a, e), with reason: f) -> Result(a, f) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(reason)
  }
}
