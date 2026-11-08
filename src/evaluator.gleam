//// The interpreter, which evaluates the program that the parser produces.

import errors.{type EvalError, MissingFunction, TypeError}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import limits
import mutable_dict.{type MutableDict}

// ── Types ─────────────────────────────────────────────────────────────────────

/// The value of an expression evaluated in an environment.
pub type Value {
  VBool(Bool)
  VInt(Int)
  VList(List(Value))
  // A record (e.g., a Point or Line). The tag indicates its type.
  VData(tag: String, fields: List(Value))
  VFunc(Callable)
}

/// A record type has a constructor name and a list of field names.
pub type Constructor =
  #(String, List(String))

/// Rather than supporting new types, this interpreter uses a fixed set.
pub const constructors: List(Constructor) = [
  #("Point", ["x", "y"]),
  #("Line", ["start", "end"]),
  #("Path", ["shape", "start", "end", "thickness"]),
]

/// The name-to-value bindings of a local frame (an immutable Gleam Dict).
pub type Bindings =
  Dict(String, Value)

/// The global frame is a mutable dictionary from names to values. It is mutable
/// so that it can contain cycles: each top-level function in the global frame
/// has the global frame as its env.
pub type GlobalFrame =
  MutableDict(String, Value)

/// An environment is a sequence of frames that includes a Local frame for each
/// call to a user-defined function and a Global frame at the end.
pub type Env {
  Local(bindings: Bindings, parent: Env)
  Global(bindings: GlobalFrame)
}

/// A function value. A Builtin's run function implements its behavior, while a
/// UserFn has a body Expr that is evaluated in a new frame whose parent is env.
pub type Callable {
  Builtin(
    name: String,
    num_args: Int,
    run: fn(List(Value)) -> Result(Value, EvalError),
  )
  UserFn(name: String, params: List(String), body: Expr, env: Env)
}

/// An Expr evaluates to a value when evaluated in an Env.
pub type Expr {
  Var(String)
  LiteralBool(Bool)
  LiteralInt(Int)
  // [a, b, ..rest] where the optional rest must evaluate to a list.
  LiteralList(elems: List(Expr), rest: Option(Expr))
  // f(x, y) where the fn_expr must evaluate to a function.
  Call(fn_expr: Expr, operands: List(Expr))
  // An anonymous function: fn(x, y) { ... }.
  Lambda(params: List(String), body: Expr)
  // A case expression: case subject { pattern -> expr }
  Case(subject: Expr, arms: List(Arm))
  // let name = value followed by body, the expression on the next line.
  Let(name: String, value: Expr, body: Expr)
  // Accessing a field value by name: p.x, line.start, etc.
  FieldAccess(record: Expr, field: String)
  // A source-line marker the parser adds around each let and each case arm so
  // that error messages can include the line where an expression appeared.
  At(line: Int, expr: Expr)
}

/// An arm of a case expression: a Pattern and the Expr evaluated if it matches.
pub type Arm =
  #(Pattern, Expr)

/// A pattern in a case expression.
pub type Pattern {
  PBool(Bool)
  PInt(Int)
  PWildcard
  PVar(String)
  PList(elems: List(Pattern), rest: Option(String))
}

// ── Evaluation ────────────────────────────────────────────────────────────────

/// Evaluate an expression in an environment.
fn eval(expr: Expr, env: Env) -> Result(Value, EvalError) {
  limits.charge(1)
  case expr {
    Var(name) -> lookup(env, name)
    LiteralBool(b) -> Ok(VBool(b))
    LiteralInt(n) -> Ok(VInt(n))
    LiteralList(elems, rest) -> eval_list(elems, rest, env)
    Call(fn_expr, operands) ->
      case eval(fn_expr, env) {
        Ok(a) ->
          case list.try_map(operands, fn(x) { eval(x, env) }) {
            Ok(b) -> apply(a, b)
            Error(i) -> Error(i)
          }
        Error(i) -> Error(i)
      }

    // Evaluate the expression v exactly once, then extend env to include
    // the name bound to its value; finally, evaluate the body of the let.
    Let(name, v, body) ->
      case eval(v, env) {
        Error(e) -> Error(e)
        // YOUR CODE HERE (replace the code below)
        Ok(value) -> eval(body, extend(env, [#(name, value)]))
      }
    Case(subject, arms) ->
      // YOUR CODE HERE (replace the code below)
      case eval(subject, env) {
        Error(i) -> Error(i)
        Ok(i) ->
          case find_arm(i, arms) {
            Ok(#(bindings, body)) -> eval(body, extend(env, bindings))
            Error(Nil) -> Error(errors.NoMatchingCase)
          }
      }
    Lambda(params, body) ->
      // YOUR CODE HERE (replace the code below)
      Ok(VFunc(UserFn("lambda", params, body, env)))
    FieldAccess(record, field) ->
      case eval(record, env) {
        Error(e) -> Error(e)
        Ok(v) -> get_field(v, field)
      }
    // An error from this expression is on this line.
    At(line, expr) -> result.map_error(eval(expr, env), errors.at_line(_, line))
  }
}

/// Evaluate a list literal [a, b, ..rest].
fn eval_list(
  elems: List(Expr),
  rest: Option(Expr),
  env: Env,
) -> Result(Value, EvalError) {
  case list.try_map(elems, fn(e) { eval(e, env) }), rest {
    Error(e), _ -> Error(e)
    // YOUR CODE HERE (replace the code below)
    Ok(head), None -> Ok(VList(head))
    Ok(head), Some(r) ->
      case eval(r, env) {
        // YOUR CODE HERE (replace the code below)
        Ok(VList(tail)) -> Ok(VList(list.append(head, tail)))
        Ok(other) ->
          Error(TypeError("`..` expects a list, got " <> describe(other)))
        Error(e) -> Error(e)
      }
  }
}

/// Apply a function value to already-evaluated arguments. Every application costs
/// one step, even of a built-in.
pub fn apply(f: Value, args: List(Value)) -> Result(Value, EvalError) {
  limits.charge(1)
  case f {
    VFunc(callable) -> {
      let wanted = num_params(callable)
      case list.length(args) == wanted {
        False -> Error(wrong_num_args(callable.name, wanted, list.length(args)))
        True ->
          case callable {
            Builtin(_, _, run) -> run(args)
            UserFn(_, params, body, parent) ->
              // YOUR CODE HERE (replace the code below)
              eval(body, Local(dict.from_list(list.zip(params, args)), parent))
          }
      }
    }
    _ -> Error(TypeError("calling a value that is not a function"))
  }
}

/// How many arguments a function takes.
fn num_params(callable: Callable) -> Int {
  case callable {
    Builtin(_, num_args, _) -> num_args
    UserFn(_, params, _, _) -> list.length(params)
  }
}

/// The value of a record's field, found by its position in constructors.
fn get_field(v: Value, field: String) -> Result(Value, EvalError) {
  case v {
    VData(tag, values) -> {
      let names = result.unwrap(list.key_find(constructors, tag), [])
      case list.key_find(list.zip(names, values), field) {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error(TypeError("a " <> tag <> " has no ." <> field))
      }
    }
    _ ->
      Error(TypeError("." <> field <> " expects a record, got " <> describe(v)))
  }
}

/// The value bound to name in env. A name is looked up exactly as in an
/// environment diagram: check the current frame's bindings, then its
/// parent's, and so on out to the Global frame. A name that no frame binds
/// is an errors.UnboundVariable(name) error.
pub fn lookup(env: Env, name: String) -> Result(Value, EvalError) {
  case env {
    Local(bindings, parent) ->
      case dict.get(bindings, name) {
        Ok(i) -> Ok(i)
        Error(_) -> lookup(parent, name)
      }
    Global(bindings) ->
      case mutable_dict.get(bindings, name) {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error(errors.UnboundVariable(name))
      }
  }
}

// ── Pattern matching ──────────────────────────────────────────────────────────

/// The bindings and body of the first arm whose pattern matches value, or
/// Error(Nil) if no pattern matches.
pub fn find_arm(
  value: Value,
  arms: List(Arm),
) -> Result(#(List(#(String, Value)), Expr), Nil) {
  case arms {
    [] -> Error(Nil)
    [#(pattern, body), ..rest] ->
      case match_pattern(pattern, value) {
        Ok(bindings) -> Ok(#(bindings, body))
        Error(Nil) -> find_arm(value, rest)
      }
  }
}

/// The names that pattern binds if it matches value, or Error(Nil) if it doesn't.
fn match_pattern(
  pattern: Pattern,
  value: Value,
) -> Result(List(#(String, Value)), Nil) {
  case pattern, value {
    PBool(b1), VBool(b2) if b1 == b2 -> Ok([])
    PInt(n1), VInt(n2) if n1 == n2 -> Ok([])
    PWildcard, _ -> Ok([])
    PVar(v1), v2 -> Ok([#(v1, v2)])
    PList(elems, rest), VList(vs) -> match_list(elems, rest, vs)
    _, _ -> Error(Nil)
  }
}

/// The names that the list pattern [elems, ..rest] binds if it matches the values
/// vs, or Error(Nil) if it doesn't.
fn match_list(
  elems: List(Pattern),
  rest: Option(String),
  vs: List(Value),
) -> Result(List(#(String, Value)), Nil) {
  case elems, rest, vs {
    [], None, [] -> Ok([])
    // YOUR CODE HERE (replace the code below)
    [], Some(x), _ -> {
      let _ = x
      Ok([#(x, VList(vs))])
    }
    [p, ..ps], rest, [v, ..vs] -> {
      case match_pattern(p, v), match_list(ps, rest, vs) {
        Ok(a), Ok(b) -> Ok(list.append(a, b))
        _, _ -> Error(Nil)
      }
    }
    _, _, _ -> Error(Nil)
  }
}

// ── Running a program ─────────────────────────────────────────────────────────

/// Call the function named function in the global frame on args.
pub fn run(
  function: String,
  args: List(Value),
  global: GlobalFrame,
) -> Result(Value, EvalError) {
  use <- limits.guarded
  // The function's body is evaluated here rather than through apply, so that
  // a program runs even before apply can call user-defined functions.
  case mutable_dict.get(global, function) {
    Ok(VFunc(UserFn(_, params, body, env))) ->
      case list.length(params) == list.length(args) {
        True -> eval(body, Local(dict.from_list(list.zip(params, args)), env))
        False -> Error(MissingFunction(function, list.length(args)))
      }
    _ -> Error(MissingFunction(function, list.length(args)))
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// The environment with the `new` bindings added to the current frame, each
/// replacing any earlier binding of the same name in that frame. A let and a
/// case arm bind this way.
pub fn extend(env: Env, new: List(#(String, Value))) -> Env {
  case env {
    Local(existing, parent) ->
      Local(dict.merge(existing, dict.from_list(new)), parent)
    // Global is never extended
    Global(_) -> env
  }
}

/// Construct a TypeError when a function is called on  wrong # of arguments.
fn wrong_num_args(function_name: String, wanted: Int, got: Int) -> EvalError {
  TypeError(
    function_name
    <> " takes "
    <> int.to_string(wanted)
    <> " argument(s) but was given "
    <> int.to_string(got),
  )
}

/// A short description for error messages that omits list or record contents.
fn describe(v: Value) -> String {
  case v {
    VList(_) -> "a list"
    VData(tag, _) -> "a " <> tag <> " record"
    VFunc(f) -> "the function " <> f.name
    _ -> string.inspect(v)
  }
}
