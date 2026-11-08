//// A grader for Gleam assignments: it groups a project's tests by question, so
//// that the tests for one question can be run and scored on their own. This is
//// the Gleam counterpart of pytest-grader, which does the same for the Python
//// assignments.
////
//// gleeunit finds and runs every test in `test/` and has no way to select a
//// subset, so the grouping lives in the project's test entry module
//// (`test/<package>_test.gleam`), which declares the questions and hands them
//// to main:
////
////     import grader.{check, question}
////     import roll_test
////
////     pub fn main() -> Nil {
////       grader.main([
////         question("q1", 2, [
////           check("roll_dice_test", roll_test.roll_dice_test),
////           check("sow_sad_test", roll_test.sow_sad_test),
////         ]),
////         question("q2", 2, [..]),
////       ])
////     }
////
//// What a student can then run, from the Gleam project directory:
////
////     gleam test              every test in test/, with gleeunit (as usual)
////     gleam test -- q1        the tests for one question, and nothing else
////     gleam test -- q1 q3     the tests for several questions
////     gleam test -- roll_dice_test   one test, named as its check names it
////     gleam test -- all       every question's tests, grouped by question
////     gleam test -- score     every question, with the points it earns
////
//// Any of these also takes `--verbose`, which is left for the tests themselves
//// to read, e.g. to print progress traces.
////
//// A question earns its points only when all of its tests pass. Points are
//// optional: give a question 0 points and the score leaves points out.
////
//// A question's tests are named here, rather than discovered, because Gleam has
//// no reflection: a test is a function, and naming it is what puts it in a
//// group. A test may belong to no question — plain `gleam test` still runs it —
//// which is where tests that check something no single question owns belong.
////
//// This file is installed into a project's `test/` directory from
//// `lib/gleam/grader.gleam` in the assignments repo, and a Gleam client build
//// re-copies it, so edit it there and not in the copy.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleeunit

// ── Declaring an assignment's questions ──────────────────────────────────────

pub opaque type Question {
  Question(name: String, points: Int, checks: List(Check))
}

pub opaque type Check {
  Check(name: String, run: fn() -> Nil, timed: Bool)
}

/// One question: the name a student names it by (`gleam test -- q1`), what all
/// of its tests passing is worth, and those tests.
pub fn question(name: String, points: Int, checks: List(Check)) -> Question {
  Question(name, points, checks)
}

/// One test of a question: the name to report it under, and the test function
/// itself. Its result is discarded, since a test function ends in whatever its
/// last assertion produced and that differs from test to test.
pub fn check(name: String, run: fn() -> a) -> Check {
  Check(name, discard_result(run), True)
}

/// A test with no timeout, for one that is slow by design, such as one that
/// drives a real browser.
pub fn untimed_check(name: String, run: fn() -> a) -> Check {
  Check(name, discard_result(run), False)
}

fn discard_result(run: fn() -> a) -> fn() -> Nil {
  fn() {
    let _ = run()
    Nil
  }
}

// ── Running them ─────────────────────────────────────────────────────────────

/// The test entry point, which dispatches on what follows `gleam test --`.
/// With nothing after it, gleeunit runs the whole suite, exactly as it would
/// without this module.
pub fn main(questions: List(Question)) -> Nil {
  case list.filter(args(), fn(arg) { arg != "--verbose" }) {
    [] -> gleeunit.main()
    selectors ->
      case supervise() {
        True -> Nil
        False -> select(questions, selectors)
      }
  }
}

fn select(questions: List(Question), selectors: List(String)) -> Nil {
  case selectors {
    ["score"] | ["--score"] -> score(questions)
    ["all"] | ["--all"] -> run(questions, names(questions))
    _ -> run(questions, selectors)
  }
}

// Run a check. The supervisor never times out a check running under the empty
// name, which is how an untimed check runs.
fn attempt(check: Check) -> Result(Nil, Dynamic) {
  case check.timed {
    True -> rescue(check.name, check.run)
    False -> rescue("", check.run)
  }
}

// Run the selected questions, reporting every test, and exit non-zero if any
// failed so this can gate a build as well as inform a student.
fn run(questions: List(Question), selectors: List(String)) -> Nil {
  let failed =
    list.fold(selectors, 0, fn(failed, selector) {
      case list.find(questions, fn(q) { q.name == selector }) {
        Ok(question) -> failed + report(question)
        Error(Nil) ->
          case single(questions, selector) {
            Ok(question) -> failed + report(question)
            Error(Nil) -> {
              unknown(questions, selector)
              failed
            }
          }
      }
    })
  case failed {
    0 -> Nil
    n -> {
      io.println("\n" <> int.to_string(n) <> " test(s) failed")
      exit(1)
    }
  }
}

// One question's tests, one line each, answering how many failed.
fn report(question: Question) -> Int {
  io.println("\n" <> question.name <> ":")
  let failed =
    list.fold(question.checks, 0, fn(failed, check) {
      case attempt(check) {
        Ok(Nil) -> {
          io.println("  pass  " <> check.name)
          failed
        }
        Error(error) -> {
          io.println("  FAIL  " <> check.name)
          io.println(indent(describe(error)))
          failed + 1
        }
      }
    })
  let total = list.length(question.checks)
  io.println("  " <> counted(total - failed, total, "test") <> " passed")
  failed
}

// Every question's score, without the detail of which test failed: a summary to
// read between problems, where `gleam test -- q2` is how to look closer.
fn score(questions: List(Question)) -> Nil {
  let width =
    list.fold(names(questions), 5, fn(width, name) {
      int.max(width, string.length(name))
    })
  let graded = list.fold(questions, 0, fn(sum, q) { sum + q.points }) > 0
  let totals =
    list.fold(questions, #(0, 0, 0, 0), fn(totals, question) {
      let passed =
        list.count(question.checks, fn(check) { attempt(check) == Ok(Nil) })
      let total = list.length(question.checks)
      let earned = case passed == total {
        True -> question.points
        False -> 0
      }
      io.println(line(
        question.name,
        width,
        passed,
        total,
        earned,
        question.points,
        graded,
      ))
      #(
        totals.0 + passed,
        totals.1 + total,
        totals.2 + earned,
        totals.3 + question.points,
      )
    })
  io.println("")
  io.println(line(
    "total",
    width,
    totals.0,
    totals.1,
    totals.2,
    totals.3,
    graded,
  ))
  case totals.0 == totals.1 {
    True -> Nil
    False -> exit(1)
  }
}

// One line of the score: the tests a question passed, and the points it earned
// if the assignment gives its questions any.
fn line(
  name: String,
  width: Int,
  passed: Int,
  total: Int,
  earned: Int,
  points: Int,
  graded: Bool,
) -> String {
  let tests = counted(passed, total, "test")
  case graded {
    False -> pad(name, width) <> tests
    True ->
      pad(name, width) <> pad(tests, 20) <> counted(earned, points, "point")
  }
}

fn counted(n: Int, of: Int, unit: String) -> String {
  let plural = case of {
    1 -> unit
    _ -> unit <> "s"
  }
  int.to_string(n) <> " of " <> int.to_string(of) <> " " <> plural
}

fn pad(text: String, width: Int) -> String {
  string.pad_end(text <> "  ", to: width + 2, with: " ")
}

fn names(questions: List(Question)) -> List(String) {
  list.map(questions, fn(question) { question.name })
}

// The question a test named selector belongs to, holding only that test.
fn single(
  questions: List(Question),
  selector: String,
) -> Result(Question, Nil) {
  list.find_map(questions, fn(question) {
    list.find(question.checks, fn(check) { check.name == selector })
    |> result.map(fn(check) { Question(..question, checks: [check]) })
  })
}

fn unknown(questions: List(Question), selector: String) -> Nil {
  io.println(
    "no question or test named "
    <> selector
    <> "; this assignment has "
    <> string.join(names(questions), ", "),
  )
  exit(1)
}

// ── Reporting a failure ──────────────────────────────────────────────────────

// What a failed test panicked with: the assertion's message, where it was
// raised, and — for a failed pattern match — the value that did not match,
// which is usually the whole story. For a failed `assert a == b`, it also
// shows both sides: tests put the code under test on the left, so the right is
// what was expected and the left is what the code actually produced. The left
// side's source comes first, since the call it makes shows the test's input.
fn describe(error: Dynamic) -> String {
  let message =
    result.unwrap(field(error, "message", decode.string), "test failed")
  let where = case
    field(error, "module", decode.string),
    field(error, "line", decode.int)
  {
    Ok(module), Ok(line) -> " (" <> module <> ":" <> int.to_string(line) <> ")"
    _, _ -> ""
  }
  let value = case field(error, "value", decode.dynamic) {
    Ok(value) -> "\nvalue: " <> string.inspect(value)
    Error(Nil) -> ""
  }
  let sides = case
    field(error, "left", decode.at(["value"], decode.dynamic)),
    field(error, "right", decode.at(["value"], decode.dynamic))
  {
    Ok(left), Ok(right) ->
      code(error)
      <> "\nexpected: "
      <> string.inspect(right)
      <> "\nactual:   "
      <> string.inspect(left)
    _, _ -> ""
  }
  message <> where <> value <> sides <> hint(message)
}

// Advice for a panic that a student can fix without understanding the runtime's
// wording for it.
fn hint(message: String) -> String {
  case string.starts_with(message, "`todo` expression evaluated") {
    True -> "\nhint: Replace the `todo` at this line with your implementation."
    False -> ""
  }
}

// The source of a failed assertion's left side, as a line of its report, or
// nothing when the test file cannot be read.
fn code(error: Dynamic) -> String {
  let snippet = {
    use file <- result.try(field(error, "file", decode.string))
    use start <- result.try(field(
      error,
      "left",
      decode.at(["start"], decode.int),
    ))
    use end <- result.try(field(error, "left", decode.at(["end"], decode.int)))
    source(file, start, end)
  }
  case snippet {
    Ok(snippet) -> "\ncode:     " <> snippet
    Error(Nil) -> ""
  }
}

// One field of the raised object, if it has one of that type.
fn field(
  error: Dynamic,
  name: String,
  decoder: decode.Decoder(a),
) -> Result(a, Nil) {
  decode.run(error, decode.at([name], decoder))
  |> result.replace_error(Nil)
}

// A failure message, every line of it indented under the test it belongs to.
fn indent(message: String) -> String {
  message
  |> string.split("\n")
  |> list.map(fn(line) { "        " <> line })
  |> string.join("\n")
}

// ── FFI ──────────────────────────────────────────────────────────────────────

@external(javascript, "./grader_ffi.mjs", "args")
fn args() -> List(String)

// Run the test function called name, catching the panic a failed assertion
// raises. The Error holds the raised object, which describe reads. A test that
// runs for too long is reported as failed by name, and ends the whole run,
// unless its name is empty.
@external(javascript, "./grader_ffi.mjs", "rescue")
fn rescue(name: String, run: fn() -> Nil) -> Result(Nil, Dynamic)

// Start running this program again on a thread that a test cannot block, so
// that a test which runs for too long can be stopped. True on the thread that
// only supervises, which must leave the tests to the other one.
@external(javascript, "./grader_ffi.mjs", "supervise")
fn supervise() -> Bool

// The text of file from byte start up to byte end.
@external(javascript, "./grader_ffi.mjs", "source")
fn source(file: String, start: Int, end: Int) -> Result(String, Nil)

@external(javascript, "./grader_ffi.mjs", "exit")
fn exit(code: Int) -> Nil
