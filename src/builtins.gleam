//// The built-in functions of the draw mini-language: random, the type
//// constructors, universal equality, the integer operators/comparisons, the
//// boolean operators, and a curated subset of gleam/list.
////
//// global_frame() produces a global frame that binds the built-ins, to which
//// parser.parse_program adds a program's functions. The split runs one direction —
//// this module builds on the evaluator's Values and calls its apply, while
//// the evaluator knows nothing about which built-ins exist — so the interpreter
//// itself can be read in evaluator.gleam alone.

import errors.{type EvalError, TypeError}
import evaluator.{
  type Bindings, type GlobalFrame, type Value, Builtin, VBool, VData, VFunc,
  VInt, VList, apply,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import limits
import mutable_dict

/// A new global frame that binds the built-ins, ready for
/// parser.parse_program to add a program's functions.
pub fn global_frame() -> GlobalFrame {
  let frame = mutable_dict.new()
  let bind = fn(name, value) { mutable_dict.insert(frame, name, value) }
  dict.each(builtins(), bind)
  frame
}

// The built-in bindings of the global frame, shared by every draw function.
fn builtins() -> Bindings {
  dict.from_list([
    builtin("random", 2, builtin_random),
    builtin("abs", 1, builtin_abs),
    builtin("==", 2, builtin_eq),
    builtin("!=", 2, builtin_not_eq),
    // The parser only calls these once it has evaluated the left side to decide
    // that the right side is needed (see parser.convert_short_circuit).
    bool_op("&&", fn(x, y) { x && y }),
    bool_op("||", fn(x, y) { x || y }),
    int_op("+", fn(x, y) { x + y }),
    int_op("-", fn(x, y) { x - y }),
    int_op("*", fn(x, y) { x * y }),
    // Gleam's integer division truncates toward zero and yields 0 when
    // dividing by zero, so arithmetic can never crash the interpreter.
    int_op("/", fn(x, y) { x / y }),
    // Likewise, % is the remainder of that division, taking the sign of x,
    // and yields 0 when dividing by zero.
    int_op("%", fn(x, y) { x % y }),
    int_cmp("<", fn(x, y) { x < y }),
    int_cmp(">", fn(x, y) { x > y }),
    int_cmp("<=", fn(x, y) { x <= y }),
    int_cmp(">=", fn(x, y) { x >= y }),
    ..list.append(constructors(), list_builtins())
  ])
}

// Every record type's constructor, taking one argument per field. The field
// names come from the evaluator's constructors table, which also tells
// field access how to read them back. A constructor accepts any values, so it
// never errors.
fn constructors() -> List(#(String, Value)) {
  list.map(evaluator.constructors, fn(entry: evaluator.Constructor) {
    let #(tag, fields) = entry
    builtin(tag, list.length(fields), fn(args) { Ok(VData(tag, args)) })
  })
}

// An entry in the global environment: a named built-in function value.
fn builtin(
  name: String,
  num_args: Int,
  run: fn(List(Value)) -> Result(Value, EvalError),
) -> #(String, Value) {
  #(name, VFunc(Builtin(name, num_args, run)))
}

// ── gleam/list built-ins ────────────────────────────────────────────────────
//
// A curated subset of gleam/list, under its real names (list.map) and with
// gleam/list's own argument order and semantics, so what a user learns here
// is just Gleam. Much of the rest of gleam/list names types this language
// does not have (tuples, Result, Order, Dict).
//
// Every entry has the same shape — builtin(name, num_args, run) — and every run
// function pattern-matches its arguments, answering expects(name, "…") to anything
// of the wrong type. An argument that should be a function is simply handed to
// apply, which reports a non-function itself.

fn list_builtins() -> List(#(String, Value)) {
  [
    builtin("list.map", 2, fn(args) {
      case args {
        [VList(xs), f] ->
          result.map(list.try_map(xs, fn(x) { apply(f, [x]) }), VList)
        _ -> expects("list.map", "a list and a function")
      }
    }),
    builtin("list.filter", 2, fn(args) {
      case args {
        [VList(xs), keep] -> {
          use kept <- result.map(
            list.try_fold(xs, [], fn(acc, x) {
              case apply(keep, [x]) {
                Ok(VBool(True)) -> Ok([x, ..acc])
                Ok(VBool(False)) -> Ok(acc)
                Ok(_) ->
                  Error(TypeError(
                    "list.filter's function must return True or False",
                  ))
                Error(e) -> Error(e)
              }
            }),
          )
          VList(list.reverse(kept))
        }
        _ -> expects("list.filter", "a list and a function")
      }
    }),
    builtin("list.append", 2, fn(args) {
      case args {
        // Appending copies xs, one new cell per element (ys is shared), so
        // charge that many steps. Counting the copy is what keeps repeated
        // appends honest: doubling a list over and over soon asks a single
        // append for more cells than the whole allowance, so it trips
        // StepLimit instead of hanging or exhausting memory.
        [VList(xs), VList(ys)] -> {
          limits.charge(list.length(xs))
          Ok(VList(list.append(xs, ys)))
        }
        _ -> expects("list.append", "two lists")
      }
    }),
    builtin("list.length", 1, fn(args) {
      case args {
        // Counting walks the whole list, so charge that many steps.
        [VList(xs)] -> {
          let length = list.length(xs)
          limits.charge(length)
          Ok(VInt(length))
        }
        _ -> expects("list.length", "a list")
      }
    }),
    builtin("list.flatten", 1, fn(args) {
      case args {
        [VList(xss)] -> {
          use lists <- result.try(
            list.try_map(xss, fn(xs) {
              case xs {
                VList(elements) -> Ok(elements)
                _ -> expects("list.flatten", "a list")
              }
            }),
          )
          // The concatenation can dwarf every input (many sublists, possibly
          // shared), so charge for walking every sublist and copying every
          // element before building it — a huge result trips StepLimit
          // without ever being materialized.
          let total = list.fold(lists, 0, fn(n, l) { n + list.length(l) })
          limits.charge(list.length(lists) + total)
          Ok(VList(list.flatten(lists)))
        }
        _ -> expects("list.flatten", "a list of lists")
      }
    }),
  ]
}

// The type error a built-in reports for arguments of the wrong shape.
fn expects(name: String, what: String) -> Result(a, EvalError) {
  Error(TypeError(name <> " expects " <> what))
}

// ── The rest of the built-ins ─────────────────────────────────────────────────

fn int_op(name: String, op: fn(Int, Int) -> Int) -> #(String, Value) {
  builtin(name, 2, fn(args) {
    case args {
      [VInt(x), VInt(y)] -> Ok(VInt(op(x, y)))
      _ -> expects(name, "two ints")
    }
  })
}

fn int_cmp(name: String, op: fn(Int, Int) -> Bool) -> #(String, Value) {
  builtin(name, 2, fn(args) {
    case args {
      [VInt(x), VInt(y)] -> Ok(VBool(op(x, y)))
      _ -> expects(name, "two ints")
    }
  })
}

fn bool_op(name: String, op: fn(Bool, Bool) -> Bool) -> #(String, Value) {
  builtin(name, 2, fn(args) {
    case args {
      [VBool(x), VBool(y)] -> Ok(VBool(op(x, y)))
      _ -> expects(name, "two Bools")
    }
  })
}

// A random integer in [min, max). If max <= min the range is empty, so we
// just return min rather than crash.
fn builtin_random(args: List(Value)) -> Result(Value, EvalError) {
  case args {
    [VInt(min), VInt(max)] ->
      case max <= min {
        True -> Ok(VInt(min))
        False ->
          Ok(VInt(
            min + float.truncate(float.random() *. int.to_float(max - min)),
          ))
      }
    _ -> expects("random", "two ints")
  }
}

// Absolute value of an integer.
fn builtin_abs(args: List(Value)) -> Result(Value, EvalError) {
  case args {
    [VInt(n)] -> Ok(VInt(int.absolute_value(n)))
    _ -> expects("abs", "one int")
  }
}

// Universal equality: any two values of the same shape. Integers compare
// exactly (no round-off to absorb), so equality is always reliable.
fn builtin_eq(args: List(Value)) -> Result(Value, EvalError) {
  case args {
    [a, b] -> result.map(value_equal(a, b), VBool)
    _ -> expects("==", "two values")
  }
}

// The opposite of ==, for any two values.
fn builtin_not_eq(args: List(Value)) -> Result(Value, EvalError) {
  case args {
    [a, b] -> result.map(value_equal(a, b), fn(equal) { VBool(!equal) })
    _ -> expects("!=", "two values")
  }
}

// Comparison walks both structures, so each pair of nodes visited costs a step.
// Shared substructure makes a value's walk far larger than any list's length:
// nesting a pair of references k times deep yields 2^k leaves from k cheap builds,
// so without this charge one == could hang the page.
fn value_equal(a: Value, b: Value) -> Result(Bool, EvalError) {
  limits.charge(1)
  case a, b {
    VInt(x), VInt(y) -> Ok(x == y)
    VBool(x), VBool(y) -> Ok(x == y)
    VList(xs), VList(ys) -> value_equal_lists(xs, ys)
    VData(t1, xs), VData(t2, ys) ->
      case t1 == t2 {
        True -> value_equal_lists(xs, ys)
        False -> Ok(False)
      }
    _, _ -> Ok(False)
  }
}

fn value_equal_lists(
  xs: List(Value),
  ys: List(Value),
) -> Result(Bool, EvalError) {
  case xs, ys {
    [], [] -> Ok(True)
    [x, ..rx], [y, ..ry] ->
      case value_equal(x, y) {
        Ok(True) -> value_equal_lists(rx, ry)
        other -> other
      }
    _, _ -> Ok(False)
  }
}
