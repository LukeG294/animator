//// The errors of the draw language: everything that can go wrong while
//// evaluating user-submitted code, and the message shown for each.
//// evaluator.gleam, builtins.gleam, and limits.gleam all produce these;
//// the app catches them at the boundary (try_draw's callers), so user code
//// can never crash the app.

import gleam/int

pub type EvalError {
  // A name that isn't bound.
  UnboundVariable(name: String)
  // A built-in received arguments of the wrong type.
  TypeError(message: String)
  // A case whose patterns did not cover this value.
  NoMatchingCase
  // Recursion overflowed the stack.
  RecursionLimit
  // Evaluation exceeded the limit on the amount of processing.
  StepLimit
  // The finished drawing had more paths than the animator will render.
  PathLimit
  // The program has no function by this name that takes num_args arguments.
  MissingFunction(name: String, num_args: Int)
  // The finished drawing is not a well formed list of paths.
  BadDrawing(message: String)
  // Only used during development to mark parts that aren't implemented yet.
  NotImplemented(expr: String)
  // An error in an expression on this source line (see at_line).
  OnLine(error: EvalError, line: Int)
}

/// The error located on line. An error passes through the line marker of each
/// expression it is inside, and the first is closest to the problem, so it is the
/// one that counts.
pub fn at_line(error: EvalError, line: Int) -> EvalError {
  case error {
    OnLine(..) -> error
    _ -> OnLine(error, line)
  }
}

/// A human-readable description of an evaluation error, to show the user: what
/// went wrong and, if it's known, where, e.g. `unknown variable: pt on line 4`.
pub fn error_message(error: EvalError) -> String {
  case error {
    UnboundVariable(name) -> "unknown variable: " <> name
    TypeError(message) -> "type error: " <> message
    NoMatchingCase -> "no case pattern matched the value"
    MissingFunction(name, num_args) ->
      "no function "
      <> name
      <> " that takes "
      <> int.to_string(num_args)
      <> " argument(s)"
    BadDrawing(message) -> "bad drawing: " <> message
    RecursionLimit -> "recursion too deep (missing base case?)"
    StepLimit -> "too many steps (drawing too complex, or infinite loop?)"
    PathLimit -> "too many paths in the drawing"
    NotImplemented(expr) -> "not yet implemented: " <> expr
    OnLine(error, line) -> error_message(error) <> on_line(line)
  }
}

/// " on line 4": where an error is, as every message that has a line ends. The
/// parser ends its own errors this way too.
pub fn on_line(line: Int) -> String {
  " on line " <> int.to_string(line)
}
