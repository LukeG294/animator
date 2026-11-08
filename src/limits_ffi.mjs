// The interpreter's limits. Counting steps uses mutation, and both limits end an
// evaluation by unwinding the JavaScript stack, so this is written in JavaScript.

// The most steps a whole evaluation may spend, across every branch. Sized so that
// even a program that spends them all on the interpreter's slowest operations
// finishes in well under a tenth of a second.
const STEP_LIMIT = 250000;

const OUT_OF_STEPS = {};

let steps = 0;

export function charge(cost) {
  steps += Math.max(cost, 0);
  if (steps > STEP_LIMIT) throw OUT_OF_STEPS;
}

export function guarded(evaluate, stepError, recursionError) {
  steps = 0;
  try {
    return evaluate();
  } catch (error) {
    if (error === OUT_OF_STEPS) return stepError;
    // A stack overflow is a RangeError in Chrome and Safari, and an InternalError
    // in Firefox.
    if (error instanceof RangeError || error?.name === "InternalError") {
      return recursionError;
    }
    throw error;
  }
}
