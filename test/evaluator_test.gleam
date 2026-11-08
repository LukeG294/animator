//// Tests for the draw-function interpreter (evaluator.gleam).
////
//// These verify the building blocks the README documents — list literals,
//// shape_slider, field access, arithmetic/comparison, case with list patterns, and
//// helper recursion — by writing real draw source, parsing it with parser (the same
//// path the app uses), and running it. They also check that malformed drawings
//// surface an EvalError rather than panicking, since draw code is user-submitted.
////
//// They compare the Values that evaluation produces, and don't use the drawing types
//// in shape.gleam, drawing.gleam, or the Path constructor, because an extension may
//// change those: Gradescope compiles this file against a student's extended code. The
//// tests of those parts are in drawing_test.gleam, which students don't get.

import builtins
import errors.{
  type EvalError, OnLine, RecursionLimit, StepLimit, TypeError, UnboundVariable,
}
import evaluator.{
  type Value, Builtin, Global, Local, VBool, VData, VFunc, VInt, VList,
}
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import gleeunit
import limits
import mutable_dict
import parser

pub fn main() -> Nil {
  gleeunit.main()
}

// Wrap a body in the draw signature, parse it, and run it at shape_slider.
// The wrapping puts the draw signature on line 1, so the first body line is
// source line 2 — what the line in an error refers to.
fn run(shape_slider: Int, body: String) -> Result(Value, EvalError) {
  let assert Ok(program) =
    parser.parse_program(
      "fn draw(shape_slider: Int) -> List(Path) {\n" <> body <> "\n}",
      builtins.global_frame(),
    )
  evaluator.run("draw", [VInt(shape_slider)], program)
}

// A list literal's elements can be any expressions, in order.
pub fn list_literal_test() {
  assert value("[]") == Ok(VList([]))
  assert value("[1, 2 + 3, True]") == Ok(VList([VInt(1), VInt(5), VBool(True)]))
  assert value("[Point(1, 2), [3]]")
    == Ok(VList([point(1, 2), VList([VInt(3)])]))
}

// The shape slider value shape_slider flows into draw.
pub fn shape_slider_is_bound_test() {
  assert run(1, "let r = 100 + shape_slider * 100\nr") == Ok(VInt(200))
}

// .x/.y read a Point's coordinates; arithmetic and let combine them.
pub fn field_access_test() {
  assert value("let a = Point(3, 4)\nPoint(a.x + 1, a.y * 2)")
    == Ok(point(4, 8))
}

// Field access reads every record type, not just Point: a field whose value is
// itself a record (.start, .end) chains.
pub fn field_access_nested_test() {
  assert value(
      "let l = Line(Point(3, 4), Point(5, 6))
       let far = l.end
       Point(far.x, l.start.y)",
    )
    == Ok(point(5, 4))
}

// The parser accepts any name that some type declares, so reading a field off
// the wrong type is caught at evaluation, where the tag is known.
pub fn field_access_wrong_type_test() {
  // .x is a Point field, but a Line has no x.
  let assert Error(OnLine(TypeError(_), _)) =
    value("Line(Point(0, 0), Point(1, 1)).x")
  // No record type has a .z field.
  let assert Error(OnLine(TypeError(_), _)) = value("Point(1, 2).z")
  // A non-record has no fields at all.
  let assert Error(OnLine(TypeError(_), _)) = value("shape_slider.x")
}

// case on a Bool (from a comparison) picks between two values.
pub fn case_on_comparison_test() {
  let body =
    "case shape_slider > 0 {
      True -> 1
      False -> 2
    }"
  assert run(5, body) == Ok(VInt(1))
  assert run(-5, body) == Ok(VInt(2))
}

// A case evaluates its subject and then only the body of the arm that matches. A
// value that no arm matches is an error.
pub fn case_test() {
  assert run(0, "case True {\nTrue -> []\nFalse -> nope\n}") == Ok(VList([]))
  let assert Error(OnLine(UnboundVariable("nope"), _)) =
    run(0, "case nope {\n_ -> []\n}")
  let assert Error(OnLine(errors.NoMatchingCase, _)) =
    run(0, "case 1 {\n[] -> []\n}")
}

// An integer pattern matches only that integer.
pub fn case_int_pattern_test() {
  let body =
    "case shape_slider {
      0 -> 10
      -1 -> 20
      n -> n
    }"
  assert value(body) == Ok(VInt(7))
  assert value(string_replace_slider(body, "0")) == Ok(VInt(10))
  assert value(string_replace_slider(body, "-1")) == Ok(VInt(20))
  let assert Error(OnLine(errors.NoMatchingCase, _)) =
    value("case 1 {\n0 -> 10\n}")
  let assert Error(OnLine(errors.NoMatchingCase, _)) =
    value("case True {\n1 -> 10\n}")
}

fn string_replace_slider(body: String, subject: String) -> String {
  string.replace(body, "shape_slider", subject)
}

// && and || only evaluate their right side if it's needed.
pub fn short_circuit_test() {
  assert trace("tick(1, False) && tick(2, True)") == #(Ok(VBool(False)), [1])
  assert trace("tick(1, True) && tick(2, False)") == #(Ok(VBool(False)), [1, 2])
  assert trace("tick(1, True) && tick(2, True)") == #(Ok(VBool(True)), [1, 2])
  assert trace("tick(1, True) || tick(2, False)") == #(Ok(VBool(True)), [1])
  assert trace("tick(1, False) || tick(2, True)") == #(Ok(VBool(True)), [1, 2])
  assert trace("tick(1, False) || tick(2, False)")
    == #(Ok(VBool(False)), [1, 2])
  assert value("False && nope") == Ok(VBool(False))
  assert value("True || nope") == Ok(VBool(True))
  // && binds tighter than ||, and comparisons bind tighter than both.
  assert value("1 == 2 || 3 == 3 && 4 != 4") == Ok(VBool(False))
  assert value("True || False && False") == Ok(VBool(True))
}

pub fn boolean_operator_type_errors_test() {
  let assert Error(OnLine(TypeError("&& expects two Bools"), _)) =
    value("1 && True")
  let assert Error(OnLine(TypeError("&& expects two Bools"), _)) =
    value("True && 1")
  let assert Error(OnLine(TypeError("|| expects two Bools"), _)) =
    value("1 || True")
  let assert Error(OnLine(TypeError("|| expects two Bools"), _)) =
    value("False || 1")
}

// [a, b, ..rest] puts a and b in front of the elements of rest, in order.
pub fn list_prepend_test() {
  assert value("[1, ..[2, 3]]") == ints([1, 2, 3])
  assert value("[1, 2, ..[3]]") == ints([1, 2, 3])
  // Prepending to an empty list, and to a list that is itself prepended to.
  assert value("[1, ..[]]") == ints([1])
  assert value("[1, ..[2, ..[3]]]") == ints([1, 2, 3])
}

// A recursive helper builds a list, exercising helpers, recursion, and list-literal
// cons via the .. spread.
pub fn helper_recursion_test() {
  assert run(
      0,
      "many(3)
     }

     fn many(n: Int) -> List(Int) {
       case n > 0 {
         True -> [n, ..many(n - 1)]
         False -> []
       }",
    )
    == ints([3, 2, 1])
}

// A recursion too deep for the JavaScript stack is an error, not a crash.
pub fn non_tail_recursion_limit_test() {
  let assert Error(RecursionLimit) =
    run(
      0,
      "let x = build(100000)
       []
     }

     fn build(n: Int) -> List(Int) {
       case n > 0 {
         True -> [n, ..build(n - 1)]
         False -> []
       }",
    )
}

// A step is charged per list node a built-in copies, not just per expression
// evaluated, so a helper that doubles a list on each call — enormous work
// from few calls — spends the budget as fast as it builds. (Doubling a
// 1-element list 40 times would allocate 2^40 cells and OOM the tab; the
// charges inside list.append trip the budget around 2^18.)
pub fn runaway_append_step_limit_test() {
  let assert Error(StepLimit) =
    run(
      0,
      "dbl([1], 40)
     }

     fn dbl(xs: List(Int), n: Int) -> List(Int) {
       case n <= 0 {
         True -> xs
         False -> dbl(list.append(xs, xs), n - 1)
       }",
    )
}

// list.flatten can dwarf its inputs (many sublists, possibly shared), so it
// charges for its whole result before building it. Building each half stays
// within the budget; flattening their concatenation is charged — and trips —
// without the huge list ever being materialized.
pub fn runaway_flatten_step_limit_test() {
  let assert Error(StepLimit) =
    run(
      0,
      "let x = dbl([1], 17)
       list.flatten([x, x])
     }

     fn dbl(xs: List(Int), n: Int) -> List(Int) {
       case n <= 0 {
         True -> xs
         False -> dbl(list.append(xs, xs), n - 1)
       }",
    )
}

// No chain of a branching recursion is deep, so the stack isn't what stops it. The
// step count sees the 2^40 calls it adds up to.
pub fn branching_recursion_step_limit_test() {
  let assert Error(StepLimit) =
    run(
      0,
      "fork(0)
     }

     fn fork(n: Int) -> List(Int) {
       case n >= 40 {
         True -> []
         False -> list.append(fork(n + 1), fork(n + 1))
       }",
    )
}

// A value nested too deeply to build or compare is an error, not a crash.
pub fn deep_equality_recursion_limit_test() {
  let assert Error(RecursionLimit) =
    run(
      0,
      "let deep = build(100000, [])
       case deep == deep {
         True -> []
         False -> []
       }
     }

     fn build(n: Int, acc: List(Int)) -> List(Int) {
       case n <= 0 {
         True -> acc
         False -> build(n - 1, [acc])
       }",
    )
}

// An unbound variable is reported, not thrown — with the line it sits on
// (the body is line 2 of the wrapped source).
pub fn unbound_variable_test() {
  let assert Error(OnLine(UnboundVariable("nope"), 2)) = run(0, "nope")
}

// A name is found in the current frame (a parameter) or in a parent frame (a
// built-in).
pub fn bound_variable_test() {
  assert run(3, "shape_slider") == Ok(VInt(3))
  let assert Ok(VFunc(_)) = run(0, "abs")
}

// A call evaluates its function and then its operands, so an error in either is
// the result of the call, and only then applies the function to the arguments.
// Calling a value that isn't a function is an error that apply reports.
pub fn call_test() {
  let assert Error(OnLine(UnboundVariable("nope"), 2)) = run(0, "nope(1)")
  let assert Error(OnLine(UnboundVariable("nope"), 2)) = run(0, "abs(nope)")
  let assert Error(OnLine(TypeError(_), 2)) = run(0, "1(2)")
}

// A built-in that charges more work than the whole step allowance ends the
// evaluation with StepLimit.
pub fn builtin_step_limit_test() {
  let hungry =
    VFunc(
      Builtin("hungry", 1, fn(_args) {
        limits.charge(1_000_000)
        Ok(VInt(0))
      }),
    )
  let assert Error(StepLimit) =
    limits.guarded(fn() { evaluator.apply(hungry, [VInt(0)]) })
}

// ── Where an error happened ─────────────────────────────────────────────────

// An error is reported on its line (via the parser's At markers): nope sits on line
// 3 of the wrapped source, not line 2.
pub fn error_line_test() {
  let assert Error(OnLine(UnboundVariable("nope"), 3)) =
    run(0, "let a = 1\nPoint(nope, nope)")
}

// The line follows evaluation into a helper: missing sits on line 6 of the
// wrapped source, inside bad, not on the line of the call to bad.
pub fn error_line_in_helper_test() {
  let assert Error(OnLine(UnboundVariable("missing"), 6)) =
    run(0, "bad(1)\n}\n\nfn bad(n: Int) -> Int {\n  n + missing")
}

// The line also follows evaluation into a function value applied by a
// built-in (here the whole body is one line, line 2).
pub fn error_line_in_lambda_test() {
  let assert Error(OnLine(UnboundVariable("missing"), 2)) =
    run(0, "list.map([1], fn(m) { m + missing })")
}

// error_message includes the line for the errors that have one.
pub fn error_message_line_test() {
  let assert Error(e) = run(0, "list.map([1], fn(m) { m + missing })")
  assert errors.error_message(e) == "unknown variable: missing on line 2"
  assert errors.error_message(RecursionLimit)
    == "recursion too deep (missing base case?)"
}

// ── Function values and list.* ──────────────────────────────────────────────

// An anonymous function passed to list.map.
pub fn lambda_map_test() {
  assert value("list.map([1, 2, 3], fn(n) { n * 2 })") == ints([2, 4, 6])
}

// A fn closes over the locals in scope where it was written — k here is not
// in scope inside list.map, only where the fn was built.
pub fn closure_captures_locals_test() {
  assert value("let k = 10\nlist.map([1, 2], fn(n) { n + k })")
    == ints([11, 12])
}

// A fn also closes over shape_slider.
pub fn closure_captures_slider_test() {
  assert run(7, "list.map([1], fn(n) { n * shape_slider })") == ints([7])
}

// A named helper used as a value, rather than called.
pub fn named_function_as_value_test() {
  assert value_with(
      "list.map([1, 2], double)",
      "fn double(n: Int) -> Int { n * 2 }",
    )
    == ints([2, 4])
}

// A built-in used as a value: abs passed to list.map.
pub fn builtin_as_value_test() {
  assert value("list.map([-1, -2], abs)") == ints([1, 2])
}

// The capture shorthand f(1, _) is sugar for fn(x) { f(1, x) }.
pub fn function_capture_test() {
  assert value_with(
      "list.map([1, 2], add(10, _))",
      "fn add(a: Int, b: Int) -> Int { a + b }",
    )
    == ints([11, 12])
}

// A function value can be bound with let and then called by that name.
pub fn function_in_let_test() {
  assert value("let f = fn(n) { n * 2 }\nf(4)") == Ok(VInt(8))
}

// A discarded parameter is un-referenceable, exactly as in Gleam.
pub fn discarded_lambda_param_test() {
  assert value("list.map([1, 2], fn(_n) { 5 })") == ints([5, 5])
  let assert Error(OnLine(UnboundVariable("n"), _)) =
    value("list.map([1, 2], fn(_n) { n })")
}

// The list.* built-ins keep gleam/list's argument order and semantics.
pub fn list_builtins_test() {
  assert value("list.filter([1, 2, 3], fn(n) { n > 1 })") == ints([2, 3])
  assert value("list.append([1], [2, 3])") == ints([1, 2, 3])
}

// != is the opposite of ==, for any two values.
pub fn not_equal_test() {
  assert value("1 != 2") == Ok(VBool(True))
  assert value("1 != 1") == Ok(VBool(False))
  assert value("[1, 2] != [1, 2]") == Ok(VBool(False))
  assert value("Point(1, 2) != Point(1, 3)") == Ok(VBool(True))
  assert value("1 != True") == Ok(VBool(True))
}

pub fn list_length_test() {
  assert value("list.length([])") == Ok(VInt(0))
  assert value("list.length([1, 2, 3])") == Ok(VInt(3))
  let assert Error(OnLine(TypeError("list.length expects a list"), _)) =
    value("list.length(1)")
}

// A list.* function outside the supported subset is simply an unbound name
// (a call's target is just a variable), and says so rather than misbehaving.
pub fn unsupported_list_function_test() {
  let assert Error(OnLine(UnboundVariable("list.sort"), _)) =
    value("list.sort([2, 1], compare)")
  let assert Error(OnLine(UnboundVariable("list.first"), _)) =
    value("list.first([1])")
}

// An error inside the function passed to a list.* built-in surfaces as that
// error, rather than being swallowed or crashing the app.
pub fn error_inside_list_function_test() {
  let assert Error(OnLine(UnboundVariable("nope"), _)) =
    value("list.map([1], fn(n) { n + nope })")
  let assert Error(RecursionLimit) =
    value_with(
      "list.map([1], fn(n) { loop(n) })",
      "fn loop(n: Int) -> Int { loop(n + 1) }",
    )
}

// Misusing a list.* built-in is a type error, not a crash.
pub fn list_builtin_type_errors_test() {
  let assert Error(OnLine(TypeError(_), _)) = value("list.map(5, fn(n) { n })")
  let assert Error(OnLine(TypeError(_), _)) = value("list.map([1], 5)")
  // A predicate that doesn't return a Bool.
  let assert Error(OnLine(TypeError(_), _)) =
    value("list.filter([1], fn(n) { n })")
  // A function value applied to the wrong number of arguments.
  let assert Error(OnLine(TypeError(_), _)) =
    value("list.map([1], fn(a, b) { a + b })")
}

// A call's target can be any expression: here adder(10) returns a function
// that is called immediately, f(x)(y)-style.
pub fn curried_call_test() {
  assert value_with("adder(10)(20)", "fn adder(a: Int) { fn(b) { a + b } }")
    == Ok(VInt(30))
}

// Calling a value that is not a function is an error, not a crash. (The same
// goes for a shadowed built-in: the local wins, as in Gleam.)
pub fn call_non_function_test() {
  let assert Error(OnLine(TypeError(_), _)) = value("let f = 5\nf(2)")
  let assert Error(OnLine(TypeError(_), _)) = value("let abs = 5\nabs(2)")
}

// ── Evaluating each expression exactly once ─────────────────────────────────

// Run a draw body at shape_slider 7 in a global frame that also binds tick, and
// return draw's value along with the labels of the ticks in the order they ran.
// tick(label, value) records label and returns value, so wrapping an expression
// in a tick reveals whether it was evaluated, how many times, and when.
fn trace(body: String) -> #(Result(Value, EvalError), List(Int)) {
  trace_with(body, "")
}

// As trace, for a body that needs helper functions of its own.
fn trace_with(
  body: String,
  helpers: String,
) -> #(Result(Value, EvalError), List(Int)) {
  let log = mutable_dict.new()
  let labels = fn() { result.unwrap(mutable_dict.get(log, "labels"), []) }
  let global = builtins.global_frame()
  mutable_dict.insert(
    global,
    "tick",
    VFunc(
      Builtin("tick", 2, fn(args) {
        let assert [VInt(label), value] = args
        mutable_dict.insert(log, "labels", [label, ..labels()])
        Ok(value)
      }),
    ),
  )
  let assert Ok(program) =
    parser.parse_program(
      "fn draw(shape_slider: Int) -> List(Path) {\n"
        <> body
        <> "\n}\n\n"
        <> helpers,
      global,
    )
  let value = evaluator.run("draw", [VInt(7)], program)
  #(value, list.reverse(labels()))
}

// Just the value of a draw body, for a test of what its names refer to.
fn value(body: String) -> Result(Value, EvalError) {
  trace(body).0
}

// As value, for a body that needs helper functions of its own.
fn value_with(body: String, helpers: String) -> Result(Value, EvalError) {
  trace_with(body, helpers).0
}

fn point(x: Int, y: Int) -> Value {
  VData("Point", [VInt(x), VInt(y)])
}

fn ints(xs: List(Int)) -> Result(Value, EvalError) {
  Ok(VList(list.map(xs, VInt)))
}

// A call evaluates its function, then its operands from left to right, once each,
// and then applies the function once to the arguments in the same order.
pub fn call_evaluates_once_in_order_test() {
  assert trace("tick(1, 5)") == #(Ok(VInt(5)), [1])
  assert trace("tick(1, abs)(tick(2, -3))") == #(Ok(VInt(3)), [1, 2])
  assert trace("tick(1, Point)(tick(2, 10), tick(3, 20))")
    == #(Ok(point(10, 20)), [1, 2, 3])
  assert value("10 - 3") == Ok(VInt(7))
}

// An error in a call's function or in any of its operands is the result of the
// whole call. If there is more than one, it is the one that comes first.
pub fn call_reports_first_error_test() {
  let assert Error(OnLine(UnboundVariable("nope"), _)) = value("nope(1)")
  let assert Error(OnLine(UnboundVariable("nope"), _)) = value("Point(1, nope)")
  let assert Error(OnLine(UnboundVariable("nope"), _)) = value("Point(nope, 1)")
  let assert Error(OnLine(UnboundVariable("first"), _)) = value("first(second)")
  let assert Error(OnLine(UnboundVariable("first"), _)) =
    value("Point(first, second)")
}

// Each part of a list literal and the record of a field access are evaluated once.
pub fn list_and_field_evaluate_once_test() {
  assert trace("[tick(1, 1), tick(2, 2), ..tick(3, [4])]")
    == #(Ok(VList([VInt(1), VInt(2), VInt(4)])), [1, 2, 3])
  assert trace("tick(1, Point(5, 6)).y") == #(Ok(VInt(6)), [1])
}

// A pipe becomes a call, whose piped value is evaluated once like any operand.
pub fn pipe_evaluates_once_test() {
  assert trace("tick(1, -3) |> abs") == #(Ok(VInt(3)), [1])
  assert trace("tick(1, 3) |> Point(tick(2, 4))") == #(Ok(point(3, 4)), [1, 2])
}

// A let evaluates its value once, before its body and even if the body never uses
// the name, and then evaluates its body once.
pub fn let_evaluates_once_test() {
  assert trace("let x = tick(1, 5)\nx + x") == #(Ok(VInt(10)), [1])
  assert trace("let x = tick(1, 5)\n0") == #(Ok(VInt(0)), [1])
  assert trace("let x = 1\ntick(x, x)") == #(Ok(VInt(1)), [1])
  assert trace("let a = tick(1, 1)\nlet b = tick(2, 2)\nb - a")
    == #(Ok(VInt(1)), [1, 2])
}

// A case evaluates its subject once, no matter how many arms it tries.
pub fn case_evaluates_subject_once_test() {
  assert trace("case tick(1, []) {\n[_] -> 1\n[_, _] -> 2\n[] -> 3\n}")
    == #(Ok(VInt(3)), [1])
}

// A case evaluates the body of only the first arm that matches, and only once.
pub fn case_evaluates_matching_arm_once_test() {
  let arms = " {\nTrue -> tick(1, 1)\nFalse -> tick(2, 2)\n_ -> tick(3, 3)\n}"
  assert trace("case True" <> arms) == #(Ok(VInt(1)), [1])
  assert trace("case False" <> arms) == #(Ok(VInt(2)), [2])
  assert trace("case 0" <> arms) == #(Ok(VInt(3)), [3])
  let #(result, ticks) = trace("case 1 {\n[] -> tick(1, 1)\n}")
  let assert Error(OnLine(errors.NoMatchingCase, _)) = result
  assert ticks == []
}

// A variable pattern matches any value and binds its name to that value.
pub fn variable_pattern_test() {
  assert value("case 5 {\nx -> x + 1\n}") == Ok(VInt(6))
  assert value("case [1, 2] {\nx -> x\n}") == Ok(VList([VInt(1), VInt(2)]))
  assert value("case True {\nFalse -> 0\nx -> 1\n}") == Ok(VInt(1))
}

// A list pattern without a rest matches a list of the same length whose elements all
// match, and binds the names of all of its elements.
pub fn list_pattern_test() {
  assert value("case [1, 2] {\n[a] -> a\n[a, b] -> a * 10 + b\n_ -> 0\n}")
    == Ok(VInt(12))
  assert value("case [[], 1] {\n[first, _] -> first\n}") == Ok(VList([]))
  assert value("case [1, 2, 3] {\n[a, b] -> a + b\n_ -> 0\n}") == Ok(VInt(0))
  assert value("case [1, 2] {\n[True, b] -> b\n_ -> 0\n}") == Ok(VInt(0))
  assert value("case [1, 2] {\n[a, True] -> a\n_ -> 0\n}") == Ok(VInt(0))
  assert value("case [[1, 2], 3] {\n[[a, b], c] -> a * 100 + b * 10 + c\n}")
    == Ok(VInt(123))
}

// A list pattern's ..rest binds a list of the values after the ones its elements
// matched, which may be none of them.
pub fn list_pattern_rest_test() {
  assert value("case [1, 2, 3] {\n[a, ..rest] -> [a * 10, ..rest]\n}")
    == Ok(VList([VInt(10), VInt(2), VInt(3)]))
  assert value("case [1] {\n[a, ..rest] -> rest\n}") == Ok(VList([]))
  assert value("case [] {\n[a, ..rest] -> 1\n_ -> 0\n}") == Ok(VInt(0))
  assert value(
      "case [True, 2, 3] {\n[False, ..rest] -> 0\n[True, b, ..rest] -> b\n}",
    )
    == Ok(VInt(2))
}

// A call evaluates its argument once, however often the parameter is used, and
// its body once. Naming a function without calling it evaluates nothing.
pub fn user_function_evaluates_once_test() {
  let boom = "fn boom() -> Int { tick(1, 1) }"
  assert trace_with("double(tick(1, 3))", "fn double(n: Int) -> Int { n + n }")
    == #(Ok(VInt(6)), [1])
  assert trace_with("boom()", boom) == #(Ok(VInt(1)), [1])
  assert trace_with("tick(2, boom)()", boom) == #(Ok(VInt(1)), [2, 1])
  assert trace_with("boom() + boom()", boom) == #(Ok(VInt(2)), [1, 1])
  assert trace_with("let f = boom\n0", boom) == #(Ok(VInt(0)), [])
}

// An anonymous function's body is evaluated on each call and never before one.
pub fn lambda_body_evaluates_per_call_test() {
  assert trace("let f = fn(n) { tick(1, n) }\n0") == #(Ok(VInt(0)), [])
  assert value("let f = fn(n) { nope }\n0") == Ok(VInt(0))
  assert trace("let f = fn(n) { tick(n, n) }\nf(1) + f(2)")
    == #(Ok(VInt(3)), [1, 2])
  assert trace("fn(n) { tick(1, n) }(2)") == #(Ok(VInt(2)), [1])
}

// A built-in applies its function once per element, in order.
pub fn list_builtins_apply_once_per_element_test() {
  assert trace("list.map([1, 2, 3], fn(n) { tick(n, n) })")
    == #(Ok(VList([VInt(1), VInt(2), VInt(3)])), [1, 2, 3])
  assert trace("list.filter([1, 2], fn(n) { tick(n, n > 1) })")
    == #(Ok(VList([VInt(2)])), [1, 2])
}

// The sugar for anonymous functions evaluates just what the function it stands for
// would: a capture's other arguments on each call, and a use's body on each call.
pub fn sugar_evaluates_per_call_test() {
  assert trace("let f = Point(tick(1, 0), _)\n0") == #(Ok(VInt(0)), [])
  assert trace("let f = Point(tick(1, 0), _)\nf(5)") == #(Ok(point(0, 5)), [1])
  assert trace_with(
      "use x <- twice\ntick(x, x)",
      "fn twice(k: fn(Int) -> Int) -> Int { k(1) + k(2) }",
    )
    == #(Ok(VInt(3)), [1, 2])
}

// ── What each name refers to ────────────────────────────────────────────────

// A name refers to its nearest binding: the current frame, then each parent in
// turn, and last of all the global frame.
pub fn lookup_finds_nearest_binding_test() {
  let global = mutable_dict.new()
  mutable_dict.insert(global, "x", VInt(0))
  mutable_dict.insert(global, "y", VInt(0))
  mutable_dict.insert(global, "z", VInt(0))
  let outer =
    Local(dict.from_list([#("x", VInt(2)), #("y", VInt(2))]), Global(global))
  let inner = Local(dict.from_list([#("x", VInt(1))]), outer)
  assert evaluator.lookup(inner, "x") == Ok(VInt(1))
  assert evaluator.lookup(inner, "y") == Ok(VInt(2))
  assert evaluator.lookup(inner, "z") == Ok(VInt(0))
  assert evaluator.lookup(outer, "x") == Ok(VInt(2))
}

// A name is only found in the frames an environment can reach: never in a frame
// whose parent is this one, and never at all if no frame binds it.
pub fn lookup_unbound_name_test() {
  let outer = Local(dict.new(), Global(mutable_dict.new()))
  let inner = Local(dict.from_list([#("x", VInt(1))]), outer)
  assert evaluator.lookup(outer, "x") == Error(UnboundVariable("x"))
  assert evaluator.lookup(inner, "w") == Error(UnboundVariable("w"))
}

// A let adds to the frame without losing what it already binds.
pub fn let_keeps_earlier_bindings_test() {
  assert value("let a = 1\nlet b = 2\nshape_slider * 100 + a * 10 + b")
    == Ok(VInt(712))
}

// A later let of the same name replaces the earlier one, whose value is still the
// one its own value expression sees. Inside a block, it lasts only to the block's end.
pub fn let_rebinding_test() {
  assert value("let x = 1\nlet x = x + 1\nx") == Ok(VInt(2))
  assert value("let x = 1\nlet y = {\nlet x = 2\nx\n}\nx * 10 + y")
    == Ok(VInt(12))
}

// A let's name is in scope only after it, and only to the end of its block.
pub fn let_scope_test() {
  let assert Error(OnLine(UnboundVariable("x"), _)) = value("let x = x\n0")
  let assert Error(OnLine(UnboundVariable("b"), _)) =
    value("let a = b\nlet b = 1\na")
  let assert Error(OnLine(UnboundVariable("b"), _)) =
    value("let a = {\nlet b = 1\nb\n}\nb")
}

// An arm's body can use everything around the case as well as its pattern's names.
pub fn case_keeps_outer_bindings_test() {
  assert value(
      "let a = 1\ncase [2, 3] {\n[b, ..rest] -> shape_slider * 100 + a * 10 + b\n}",
    )
    == Ok(VInt(712))
}

// A pattern's name hides an outer one in that arm, and nowhere else.
pub fn case_pattern_shadowing_test() {
  assert value("let x = 1\nlet y = case 2 {\nx -> x\n}\nx * 10 + y")
    == Ok(VInt(12))
}

// A pattern's names are in scope only in that arm's body: not after the case, and
// not in another arm, even if part of the first arm's pattern matched.
pub fn case_scope_test() {
  let assert Error(OnLine(UnboundVariable("b"), _)) =
    value("let y = case [1] {\n[b] -> b\n}\nb")
  let assert Error(OnLine(UnboundVariable("a"), _)) =
    value("case [1] {\n[a, True] -> a\n[_] -> a\n}")
  let assert Error(OnLine(UnboundVariable("z"), _)) =
    value("let y = case True {\n_ -> {\nlet z = 1\nz\n}\n}\nz")
}

// A function's arguments bind to its parameters in order, however many there are.
pub fn parameters_bind_in_order_test() {
  assert value_with("five()", "fn five() -> Int { 5 }") == Ok(VInt(5))
  assert value_with(
      "digits(1, 2, 3)",
      "fn digits(a: Int, b: Int, c: Int) -> Int { a * 100 + b * 10 + c }",
    )
    == Ok(VInt(123))
}

// Each call has its own frame, so a recursive call doesn't change the n of the call
// waiting for it, and a later call doesn't see the arguments of an earlier one.
pub fn each_call_has_its_own_frame_test() {
  assert value_with(
      "sum(4)",
      "fn sum(n: Int) -> Int {
         case n > 0 {
           True -> {
             let rest = sum(n - 1)
             rest + n
           }
           False -> 0
         }
       }",
    )
    == Ok(VInt(10))
  assert value_with(
      "let a = same(1)\nlet b = same(2)\na * 10 + b",
      "fn same(n: Int) -> Int { n }",
    )
    == Ok(VInt(12))
}

// Binding a name in a call's frame doesn't change the caller's binding of that name.
pub fn call_keeps_caller_bindings_test() {
  assert value_with(
      "let x = 1\nlet y = bind_x(2) + let_x()\nx * 100 + y",
      "fn bind_x(x: Int) -> Int { x }
       fn let_x() -> Int {
         let x = 3
         x
       }",
    )
    == Ok(VInt(105))
}

// A top-level function's frame has the global frame as its parent, wherever it is
// called from, so the caller's names aren't in scope in its body.
pub fn function_cannot_see_caller_test() {
  let assert Error(OnLine(UnboundVariable("secret"), _)) =
    value_with("let secret = 1\npeek()", "fn peek() -> Int { secret }")
  let assert Error(OnLine(UnboundVariable("shape_slider"), _)) =
    value_with("peek()", "fn peek() -> Int { shape_slider }")
  // Not even through a function in between, whose caller is draw.
  let assert Error(OnLine(UnboundVariable("secret"), _)) =
    value_with(
      "let secret = 1\nmiddle()",
      "fn middle() -> Int { peek() }
       fn peek() -> Int { secret }",
    )
  // The caller's local also doesn't hide a global name in the function's body.
  assert value_with(
      "let double = 5\ntwo_doubled()",
      "fn two_doubled() -> Int { double(2) }
       fn double(n: Int) -> Int { n * 2 }",
    )
    == Ok(VInt(4))
}

// A function's parameters and lets are out of scope once it returns, both in the
// caller and in the next function it calls.
pub fn function_names_do_not_outlive_call_test() {
  let helpers =
    "fn helper(param: Int) -> Int {
       let local = param
       local
     }
     fn peek_param() -> Int { param }
     fn peek_local() -> Int { local }"
  let assert Error(OnLine(UnboundVariable("param"), _)) =
    value_with("let a = helper(1)\nparam", helpers)
  let assert Error(OnLine(UnboundVariable("local"), _)) =
    value_with("let a = helper(1)\nlocal", helpers)
  let assert Error(OnLine(UnboundVariable("param"), _)) =
    value_with("let a = helper(1)\npeek_param()", helpers)
  let assert Error(OnLine(UnboundVariable("local"), _)) =
    value_with("let a = helper(1)\npeek_local()", helpers)
}

// A parameter hides a global name of the same name in that function's body.
pub fn parameter_hides_global_test() {
  assert value_with("show(3)", "fn show(abs: Int) -> Int { abs }")
    == Ok(VInt(3))
  assert value_with(
      "call(3, abs)",
      "fn call(n: Int, helper: fn(Int) -> Int) -> Int { helper(n) }
       fn helper(n: Int) -> Int { n + 100 }",
    )
    == Ok(VInt(3))
}

// A function's body finds top-level functions in the global frame when it is called,
// so they can call each other no matter which is defined first.
pub fn mutual_recursion_test() {
  assert value_with(
      "even(5)",
      "fn even(n: Int) -> Bool {
         case n == 0 {
           True -> True
           False -> odd(n - 1)
         }
       }
       fn odd(n: Int) -> Bool {
         case n == 0 {
           True -> False
           False -> even(n - 1)
         }
       }",
    )
    == Ok(VBool(False))
}

// A function's free names refer to bindings where it was defined, even if the frame
// that calls it binds the same name.
pub fn closure_uses_defining_frame_test() {
  assert value_with(
      "let x = 1\ncall(fn() { x })",
      "fn call(f: fn() -> Int) -> Int {
         let x = 2
         f()
       }",
    )
    == Ok(VInt(1))
  assert value_with(
      "let x = 1\ncall(2, fn() { x })",
      "fn call(x: Int, f: fn() -> Int) -> Int { f() }",
    )
    == Ok(VInt(1))
}

// The names of the frame that calls a function aren't in scope in its body.
pub fn closure_cannot_see_caller_test() {
  let assert Error(OnLine(UnboundVariable("hidden"), _)) =
    value_with(
      "call(fn() { hidden })",
      "fn call(f: fn() -> Int) -> Int {
         let hidden = 1
         f()
       }",
    )
  let assert Error(OnLine(UnboundVariable("hidden"), _)) =
    value_with(
      "call(1, fn() { hidden })",
      "fn call(hidden: Int, f: fn() -> Int) -> Int { f() }",
    )
}

// A function sees the bindings in scope at its definition. A later let isn't one of
// them, whether it rebinds a name or adds a new one, and neither is its own let.
pub fn closure_sees_only_earlier_bindings_test() {
  assert value("let k = 1\nlet f = fn() { k }\nlet k = 2\nf() * 10 + k")
    == Ok(VInt(12))
  let assert Error(OnLine(UnboundVariable("later"), _)) =
    value("let f = fn() { later }\nlet later = 1\nf()")
  let assert Error(OnLine(UnboundVariable("f"), _)) =
    value("let f = fn(n) { f(n) }\nf(1)")
}

// A function outlives the call that created it, and each one keeps its own frame.
pub fn closures_are_independent_test() {
  assert value_with(
      "let a = adder(1)\nlet b = adder(10)\na(100) + b(200) + a(1000)",
      "fn adder(k: Int) -> fn(Int) -> Int { fn(n) { n + k } }",
    )
    == Ok(VInt(1312))
}

// A function can use the names of every frame it is nested in, not just the nearest.
pub fn closure_sees_every_enclosing_frame_test() {
  assert value(
      "let f = fn(a) { fn(b) { fn(c) { shape_slider * 1000 + a * 100 + b * 10 + c } } }
       f(1)(2)(3)",
    )
    == Ok(VInt(7123))
  assert value("let f = case [5] {\n[x] -> fn(y) { x + y }\n}\nf(1)")
    == Ok(VInt(6))
}

// A function's parameter hides an outer name in its body, and a let in its body binds
// only in that call's frame, so neither changes the name around the function.
pub fn lambda_shadowing_test() {
  assert value("let x = 1\nlet f = fn(x) { x + 1 }\nf(5) * 10 + x")
    == Ok(VInt(61))
  assert value("let x = 1\nlet f = fn() {\nlet x = 2\nx\n}\nf() * 10 + x")
    == Ok(VInt(21))
}

// Each call of a recursive anonymous function has its own frame as well.
pub fn lambda_recursion_has_own_frames_test() {
  assert value(
      "let sum = fn(self, n) {
         case n > 0 {
           True -> {
             let rest = self(self, n - 1)
             rest + n
           }
           False -> 0
         }
       }
       sum(sum, 4)",
    )
    == Ok(VInt(10))
}

// A function's parameters and lets are out of scope after it returns, and a pattern's
// names are out of scope after the arm that made a function from them.
pub fn lambda_names_do_not_outlive_call_test() {
  let assert Error(OnLine(UnboundVariable("inner"), _)) =
    value("let f = fn(inner) { inner }\nlet a = f(1)\ninner")
  let assert Error(OnLine(UnboundVariable("z"), _)) =
    value("let f = fn() {\nlet z = 1\nz\n}\nlet a = f()\nz")
  let assert Error(OnLine(UnboundVariable("x"), _)) =
    value("let f = case [5] {\n[x] -> fn(y) { x + y }\n}\nlet a = f(1)\nx")
}

// A use's parameter is in scope for the rest of its block and no further, while the
// rest of the block can use the names around it.
pub fn use_scope_test() {
  let call = "fn call(k: fn(Int) -> Int) -> Int { k(1) }"
  assert value_with("let a = 10\nuse x <- call\na + x", call) == Ok(VInt(11))
  let assert Error(OnLine(UnboundVariable("x"), _)) =
    value_with("let y = {\nuse x <- call\nx\n}\nx", call)
}

// A capture's other arguments use the names where it was written.
pub fn capture_scope_test() {
  assert value_with(
      "let x = 5\ncall(Point(x, _))",
      "fn call(f: fn(Int) -> Point) -> Point {
         let x = 6
         f(1)
       }",
    )
    == Ok(point(5, 1))
}

// An anonymous function is named lambda in the errors it causes.
pub fn lambda_name_in_errors_test() {
  let assert Error(OnLine(
    TypeError("lambda takes 1 argument(s) but was given 2"),
    _,
  )) = value("let f = fn(a) { a }\nf(1, 2)")
}

// As in Gleam, list.name reads a field of a local variable named list if name is a
// record field, and otherwise it is still the built-in. Out of scope, list is unbound.
pub fn list_as_a_local_name_test() {
  assert value("let list = Point(1, 2)\nlist.x") == Ok(VInt(1))
  assert value("fn(list) { list.y }(Point(1, 2))") == Ok(VInt(2))
  assert value("case Point(1, 2) {\nlist -> list.x\n}") == Ok(VInt(1))
  assert value("let list = [1, -2]\nlist.map(list, abs)")
    == Ok(VList([VInt(1), VInt(2)]))
  assert value("let list = Point(-1, 2)\nlist.map([list.x], abs)")
    == Ok(VList([VInt(1)]))
  let assert Error(OnLine(UnboundVariable("list"), _)) = value("list.x")
  let assert Error(OnLine(UnboundVariable("list"), _)) =
    value("let a = {\nlet list = Point(1, 2)\nlist.x\n}\nlist.x")
}
