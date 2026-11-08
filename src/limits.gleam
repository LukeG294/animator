//// The interpreter's limits, which keep user code from hanging or crashing the app.
//// evaluator.run wraps each evaluation in guarded. Anything that does work during an
//// evaluation calls charge for it, which ends the evaluation if that work is too much.
//// A recursion that is too deep ends it by overflowing the JavaScript stack.

import errors.{type EvalError, RecursionLimit, StepLimit}

/// The most paths a finished drawing may contain.
pub const path_limit = 100_000

/// Add units of work (steps) to the evaluation's step count. eval and apply charge 1
/// each, and a built-in whose work is proportional to a list's length charges that
/// length up front, so no single operation (such as list.append copying its first
/// argument or `==` walking a nested structure) can run past the limit. Past the
/// limit, this ends the evaluation, and guarded returns a StepLimit error.
@external(javascript, "./limits_ffi.mjs", "charge")
pub fn charge(steps: Int) -> Nil

@external(javascript, "./limits_ffi.mjs", "guarded")
fn do_guarded(
  evaluate: fn() -> Result(a, EvalError),
  step_error: Result(a, EvalError),
  recursion_error: Result(a, EvalError),
) -> Result(a, EvalError)

/// Run a whole evaluation with a fresh step count and return its result, or an error
/// if it did too much work (StepLimit) or overflowed the stack (RecursionLimit).
pub fn guarded(evaluate: fn() -> Result(a, EvalError)) -> Result(a, EvalError) {
  do_guarded(evaluate, Error(StepLimit), Error(RecursionLimit))
}
