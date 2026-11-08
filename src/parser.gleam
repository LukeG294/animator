//// Glance-based parser for the draw-function subset of Gleam.
//// Takes a source string, parses it with glance, and adds its functions to an
//// evaluator.GlobalFrame

import errors
import evaluator.{
  type Expr, type GlobalFrame, type Pattern, Global, UserFn, VFunc,
}
import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mutable_dict

/// Parse a source string by adding its top-level functions to global, a
/// global frame that binds the built-ins (see builtins.global_frame).
/// A function replaces any built-in of the same name, and its env is the
/// global frame itself, which is what lets functions call themselves and each
/// other. A parse error is a message that ends with the line it is on.
pub fn parse_program(
  source: String,
  global: GlobalFrame,
) -> Result(GlobalFrame, String) {
  let at = line_finder(source)
  case glance.module(source) {
    // Input runs out after the last thing written, which is where a missing
    // closing brace or paren belongs.
    Error(glance.UnexpectedEndOfInput) -> {
      let end = string.byte_size(string.trim_end(source))
      fail("Unexpected end of input", glance.Span(end, end), at)
    }
    Error(glance.UnexpectedToken(_, position)) ->
      fail(
        "Syntax error",
        glance.Span(position.byte_offset, position.byte_offset),
        at,
      )
    Ok(module) -> {
      // In source order, so that the error reported is the first one written
      // (and a duplicate function is the second definition, not the first).
      let defs =
        list.sort(module.functions, fn(a, b) {
          int.compare(a.definition.location.start, b.definition.location.start)
        })
      use fns <- result.try(list.try_map(defs, convert_function(_, global, at)))
      use Nil <- result.try(unique(
        list.map(defs, fn(def) {
          #(def.definition.name, def.definition.location)
        }),
        "Duplicate function name: ",
        at,
      ))
      list.each(fns, fn(f) { mutable_dict.insert(global, f.0, f.1) })
      Ok(global)
    }
  }
}

// ── Source lines ──────────────────────────────────────────────────────────────

// A lookup from a glance source span to the 1-based line it starts on.
type Liner =
  fn(glance.Span) -> Int

// Glance records where each expression sits in the source as a byte-offset
// Span. The evaluator wants line numbers — what an error message can say —
// so the parser wraps each statement and case arm in At(line, _) using this
// lookup.
fn line_finder(source: String) -> Liner {
  // The byte offset at which each line starts: line 1 at offset 0, and each
  // later line one byte past the newline that ends the line before it.
  let #(starts, _) =
    list.fold(string.split(source, "\n"), #([], 0), fn(acc, line) {
      let #(starts, offset) = acc
      #([offset, ..starts], offset + string.byte_size(line) + 1)
    })
  // A span's line is the number of lines that start at or before it.
  fn(span: glance.Span) {
    list.count(starts, fn(start) { start <= span.start })
  }
}

/// A parse error for the source at span, e.g. `Syntax error on line 4`. Every
/// error the parser reports is made here, so each one says where it is.
fn fail(message: String, span: glance.Span, at: Liner) -> Result(a, String) {
  Error(message <> errors.on_line(at(span)))
}

/// Where a statement starts. Expression statements carry no location of
/// their own; the expression's location is where they start.
fn statement_location(stmt: glance.Statement) -> glance.Span {
  case stmt {
    glance.Use(location, _, _) -> location
    glance.Assignment(location, _, _, _, _) -> location
    glance.Assert(location, _, _) -> location
    glance.Expression(expr) -> expr.location
  }
}

/// Convert a top-level function into a named UserFn in the global frame.
fn convert_function(
  def: glance.Definition(glance.Function),
  global: GlobalFrame,
  at: Liner,
) -> Result(#(String, evaluator.Value), String) {
  let glance.Definition(_, func) = def
  let params = list.map(func.parameters, fn(p) { binding_name(p.name) })
  use Nil <- result.try(unique(
    located(params, func.location),
    "Duplicate parameter name: ",
    at,
  ))
  use body <- result.try(convert_statements(func.body, func.location, at))
  Ok(#(func.name, VFunc(UserFn(func.name, params, body, Global(global)))))
}

/// An error naming the first name that appears more than once in `names`,
/// after `message`, on the line of its second appearance. Each name comes
/// with the location of what binds it. A frame binds each name at most once,
/// so a function's parameters, the variables of one pattern, and the
/// top-level functions must each have distinct names (as Gleam requires).
/// Discarded names, which start with _, can repeat, since they can never be
/// referenced.
fn unique(
  names: List(#(String, glance.Span)),
  message: String,
  at: Liner,
) -> Result(Nil, String) {
  let named = list.filter(names, fn(name) { !string.starts_with(name.0, "_") })
  case named {
    [] -> Ok(Nil)
    [#(first, _), ..rest] ->
      case list.key_find(rest, first) {
        Ok(location) -> fail(message <> first, location, at)
        Error(Nil) -> unique(rest, message, at)
      }
  }
}

/// Names that are all bound at location, for unique.
fn located(
  names: List(String),
  location: glance.Span,
) -> List(#(String, glance.Span)) {
  list.map(names, fn(name) { #(name, location) })
}

/// The name a function parameter binds. A discarded parameter (_foo) keeps
/// its underscore so it can never be referenced (matching Gleam).
fn binding_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(n) -> n
    glance.Discarded(n) -> "_" <> n
  }
}

/// The name bound by a pattern that is only a name: a variable x or a
/// discarded _x, which (like a parameter) keeps its underscore. let, use,
/// and the ..rest of a list pattern only support these patterns.
fn pattern_name(
  pattern: glance.Pattern,
  context: String,
  at: Liner,
) -> Result(String, String) {
  case pattern {
    glance.PatternVariable(_, name) -> Ok(name)
    glance.PatternDiscard(_, name) -> Ok("_" <> name)
    _ -> fail("Unsupported pattern in " <> context, pattern.location, at)
  }
}

/// Convert the statements of a block (or a function body) into one Expr, each
/// statement wrapped in At with the line it starts on. Each let binds over
/// the rest of the block, and the last statement is the block's value. A use
/// statement wraps the rest of the block too: use x <- f(a) is sugar for
/// f(a, fn(x) { rest }), so it is desugared here and the interpreter never has
/// to know about it. The block (or function) is at location, which is where
/// an empty one is reported.
fn convert_statements(
  statements: List(glance.Statement),
  location: glance.Span,
  at: Liner,
) -> Result(Expr, String) {
  case list.reverse(statements) {
    [] -> fail("Empty block", location, at)
    [last, ..rest_rev] -> {
      use final_expr <- result.try(case last {
        glance.Expression(expr) -> {
          use e <- result.map(convert_expr(expr, at))
          evaluator.At(at(expr.location), e)
        }
        glance.Use(location, _, _) ->
          fail(
            "A use binding must be followed by more of the block",
            location,
            at,
          )
        _ ->
          fail(
            "A block must end with an expression",
            statement_location(last),
            at,
          )
      })
      // Folding in reverse means body already holds everything after each
      // statement.
      list.try_fold(rest_rev, final_expr, fn(body, stmt) {
        case stmt {
          glance.Assignment(location, glance.Let, pattern, _, value) -> {
            use name <- result.try(pattern_name(pattern, "let binding", at))
            use v <- result.try(convert_expr(value, at))
            Ok(evaluator.Let(name, evaluator.At(at(location), v), body))
          }
          glance.Use(location, patterns, func) -> {
            use params <- result.try(
              list.try_map(patterns, fn(p) {
                pattern_name(p.pattern, "use binding", at)
              }),
            )
            use Nil <- result.try(unique(
              located(params, location),
              "Duplicate parameter name: ",
              at,
            ))
            let callback = evaluator.Lambda(params, body)
            use call <- result.try(convert_call(func, [], [callback], at))
            Ok(evaluator.At(at(location), call))
          }
          _ ->
            fail(
              "Only let, use, and expressions are allowed in a block",
              statement_location(stmt),
              at,
            )
        }
      })
    }
  }
}

// ── Expression conversion ───────────────────────────────────────────────────────

/// The conversion of one expression: one case per supported glance form.
fn convert_expr(expr: glance.Expression, at: Liner) -> Result(Expr, String) {
  case expr {
    glance.Variable(_, "True") -> Ok(evaluator.LiteralBool(True))
    glance.Variable(_, "False") -> Ok(evaluator.LiteralBool(False))
    glance.Variable(_, name) -> Ok(evaluator.Var(name))
    glance.Int(location, s) -> {
      case int.parse(s) {
        Ok(n) -> Ok(evaluator.LiteralInt(n))
        Error(_) -> fail("Invalid integer literal: " <> s, location, at)
      }
    }
    glance.Float(location, _) ->
      fail(
        "Only whole numbers are allowed (this language has no decimals)",
        location,
        at,
      )
    glance.Call(_, _, _) -> convert_call(expr, [], [], at)
    glance.Fn(location, params, _, body) -> {
      let names = list.map(params, fn(p) { binding_name(p.name) })
      use Nil <- result.try(unique(
        located(names, location),
        "Duplicate parameter name: ",
        at,
      ))
      use b <- result.try(convert_statements(body, location, at))
      Ok(evaluator.Lambda(names, b))
    }
    // The capture shorthand f(1, _) is sugar for fn(x) { f(1, x) }, so it is
    // desugared here and the interpreter never has to know about it.
    glance.FnCapture(_, _, func, before, after) ->
      convert_capture(func, before, after, at)
    // The pipe x |> f(a) is sugar for f(x, a), so it is desugared here and
    // the interpreter never has to know about it.
    glance.BinaryOperator(_, glance.Pipe, left, right) -> {
      use l <- result.try(convert_expr(left, at))
      convert_call(right, [l], [], at)
    }
    glance.BinaryOperator(_, glance.And, left, right) ->
      convert_short_circuit("&&", False, left, right, at)
    glance.BinaryOperator(_, glance.Or, left, right) ->
      convert_short_circuit("||", True, left, right, at)
    glance.BinaryOperator(location, op, left, right) ->
      convert_binop(op, left, right, location, at)
    glance.Case(_, [subject], clauses) -> {
      use s <- result.try(convert_expr(subject, at))
      use arms <- result.try(convert_clauses(clauses, at))
      Ok(evaluator.Case(s, arms))
    }
    glance.Case(location, _, _) ->
      fail("Multi-subject case is not supported", location, at)
    glance.Block(location, stmts) -> convert_statements(stmts, location, at)
    glance.List(_, elems, rest) -> convert_list(elems, rest, at)
    // list.something names a gleam/list built-in, unless it names a record field
    // of a variable called list. As in Gleam, a local variable called list doesn't
    // hide the built-ins, so list.map(list, f) still works.
    glance.FieldAccess(_, glance.Variable(_, "list"), label) ->
      case is_record_field(label) {
        True -> Ok(evaluator.FieldAccess(evaluator.Var("list"), label))
        False -> Ok(evaluator.Var("list." <> label))
      }
    glance.FieldAccess(_, container, label) -> {
      use c <- result.try(convert_expr(container, at))
      Ok(evaluator.FieldAccess(c, label))
    }
    _ -> fail("Expression type not supported", expr.location, at)
  }
}

/// Whether some record type has a field called label.
fn is_record_field(label: String) -> Bool {
  list.any(evaluator.constructors, fn(entry) { list.contains(entry.1, label) })
}

/// Convert a list literal [a, b, ..rest] into a LiteralList.
fn convert_list(
  elems: List(glance.Expression),
  rest: Option(glance.Expression),
  at: Liner,
) -> Result(Expr, String) {
  use converted <- result.try(list.try_map(elems, convert_expr(_, at)))
  case rest {
    None -> Ok(evaluator.LiteralList(converted, None))
    Some(r) -> {
      use r <- result.try(convert_expr(r, at))
      Ok(evaluator.LiteralList(converted, Some(r)))
    }
  }
}

/// Convert a call, with extra operands added before and after the call's own:
/// a pipe x |> f(a) adds x first, and a use adds its callback last. Any func
/// that is not a call — a bare name like x |> helper, a capture like
/// x |> f(a, _), or any expression that evaluates to a function — is called
/// with only the extra operands.
fn convert_call(
  func: glance.Expression,
  before: List(Expr),
  after: List(Expr),
  at: Liner,
) -> Result(Expr, String) {
  case func {
    glance.Call(_, callee, args) -> {
      use c <- result.try(convert_expr(callee, at))
      use ordered <- result.try(order_record_args(
        callee,
        list.length(before),
        args,
        at,
      ))
      use converted_args <- result.try(convert_call_args(ordered, at))
      Ok(evaluator.Call(c, list.flatten([before, converted_args, after])))
    }
    _ -> {
      use c <- result.try(convert_expr(func, at))
      Ok(evaluator.Call(c, list.append(before, after)))
    }
  }
}

/// The arguments of a call with any labels removed, if the callee is a record
/// constructor: Point(y: 1, x: 0) becomes Point(0, 1), with the labelled arguments
/// in the order of the record's fields. This needs no change to the evaluator.
/// The arguments of any other call are returned as they are. The first
/// num_before fields are taken by the operands that a pipe adds.
fn order_record_args(
  callee: glance.Expression,
  num_before: Int,
  args: List(glance.Field(glance.Expression)),
  at: Liner,
) -> Result(List(glance.Field(glance.Expression)), String) {
  let fields = case callee {
    glance.Variable(_, name) -> list.key_find(evaluator.constructors, name)
    _ -> Error(Nil)
  }
  case fields {
    Error(Nil) -> Ok(args)
    Ok(fields) -> {
      let #(positional, rest) =
        list.split_while(args, fn(arg) {
          case arg {
            glance.UnlabelledField(_) -> True
            _ -> False
          }
        })
      use labelled <- result.try(list.try_map(rest, labelled_arg(_, at)))
      use Nil <- result.try(unique(
        list.map(labelled, fn(arg) { #(arg.0, arg.1) }),
        "Duplicate label: ",
        at,
      ))
      let open_fields = list.drop(fields, num_before + list.length(positional))
      use Nil <- result.try(
        list.try_each(labelled, fn(arg) {
          case list.contains(open_fields, arg.0) {
            True -> Ok(Nil)
            False -> fail("Unexpected label: " <> arg.0, arg.1, at)
          }
        }),
      )
      let ordered =
        list.filter_map(open_fields, fn(field) {
          list.find(labelled, fn(arg) { arg.0 == field })
          |> result.map(fn(arg) { glance.UnlabelledField(arg.2) })
        })
      Ok(list.append(positional, ordered))
    }
  }
}

/// The label, location, and value of an argument after the first labelled one.
fn labelled_arg(
  field: glance.Field(glance.Expression),
  at: Liner,
) -> Result(#(String, glance.Span, glance.Expression), String) {
  case field {
    glance.LabelledField(label, location, item) -> Ok(#(label, location, item))
    glance.ShorthandField(label, location) ->
      Ok(#(label, location, glance.Variable(location, label)))
    glance.UnlabelledField(item) ->
      fail(
        "An unlabelled argument cannot follow a labelled one",
        item.location,
        at,
      )
  }
}

// The name the capture's placeholder parameter binds. It is not a legal Gleam
// identifier, so it can never collide with (or shadow) a user's variable.
const capture_param = "capture#"

/// Desugar a capture f(1, _) into fn(capture#) { f(1, capture#) }.
fn convert_capture(
  func: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
  at: Liner,
) -> Result(Expr, String) {
  use callee <- result.try(convert_expr(func, at))
  use bs <- result.try(convert_call_args(before, at))
  use as_ <- result.try(convert_call_args(after, at))
  let args = list.flatten([bs, [evaluator.Var(capture_param)], as_])
  Ok(evaluator.Lambda([capture_param], evaluator.Call(callee, args)))
}

// The name that a short-circuit operator binds its left value to. Like
// capture_param, it is not a legal Gleam identifier.
const left_value = "left#"

/// Desugar a && b into case a { False -> False  left# -> left# && b }, and a || b
/// likewise with True, so that b is only evaluated if it's needed. The built-in
/// operator reports a value that isn't a Bool on either side.
fn convert_short_circuit(
  op_name: String,
  stops_at: Bool,
  left: glance.Expression,
  right: glance.Expression,
  at: Liner,
) -> Result(Expr, String) {
  use l <- result.try(convert_expr(left, at))
  use r <- result.try(convert_expr(right, at))
  let call =
    evaluator.Call(evaluator.Var(op_name), [evaluator.Var(left_value), r])
  Ok(
    evaluator.Case(l, [
      #(evaluator.PBool(stops_at), evaluator.LiteralBool(stops_at)),
      #(evaluator.PVar(left_value), call),
    ]),
  )
}

fn convert_binop(
  op: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
  location: glance.Span,
  at: Liner,
) -> Result(Expr, String) {
  case binop_name(op) {
    Some(op_name) -> {
      use l <- result.try(convert_expr(left, at))
      use r <- result.try(convert_expr(right, at))
      Ok(evaluator.Call(evaluator.Var(op_name), [l, r]))
    }
    None -> fail("Unsupported operator", location, at)
  }
}

/// Convert Glance call arguments (List(Field(Expression))) to List(Expr).
fn convert_call_args(
  args: List(glance.Field(glance.Expression)),
  at: Liner,
) -> Result(List(Expr), String) {
  list.try_map(args, fn(field) {
    case field {
      glance.UnlabelledField(item) -> convert_expr(item, at)
      glance.LabelledField(_, location, _)
      | glance.ShorthandField(_, location) ->
        fail(
          "Labelled arguments are only supported in a call to a record constructor",
          location,
          at,
        )
    }
  })
}

// ── Operator conversion ─────────────────────────────────────────────────────────

fn binop_name(op: glance.BinaryOperator) -> Option(String) {
  case op {
    glance.AddInt -> Some("+")
    glance.SubInt -> Some("-")
    glance.MultInt -> Some("*")
    glance.DivInt -> Some("/")
    glance.RemainderInt -> Some("%")
    glance.LtInt -> Some("<")
    glance.GtInt -> Some(">")
    glance.LtEqInt -> Some("<=")
    glance.GtEqInt -> Some(">=")
    glance.Eq -> Some("==")
    glance.NotEq -> Some("!=")
    _ -> None
  }
}

// ── Clause / arm conversion ────────────────────────────────────────────────────

/// Convert case clauses into arms, each body wrapped in At with its line.
fn convert_clauses(
  clauses: List(glance.Clause),
  at: Liner,
) -> Result(List(evaluator.Arm), String) {
  list.try_map(clauses, fn(clause) {
    case clause.patterns, clause.guard {
      [[pat]], None -> {
        use p <- result.try(convert_pattern(pat, at))
        use Nil <- result.try(unique(
          located(pattern_names(p), pat.location),
          "Duplicate variable name in pattern: ",
          at,
        ))
        use body <- result.try(convert_expr(clause.body, at))
        Ok(#(p, evaluator.At(at(clause.body.location), body)))
      }
      [[_]], Some(guard) -> fail("Guards are not supported", guard.location, at)
      _, _ ->
        fail(
          "Multi-pattern clauses are not supported",
          clause.body.location,
          at,
        )
    }
  })
}

// ── Pattern conversion ──────────────────────────────────────────────────────────

fn convert_pattern(pat: glance.Pattern, at: Liner) -> Result(Pattern, String) {
  case pat {
    glance.PatternVariant(_, None, "True", [], False) ->
      Ok(evaluator.PBool(True))
    glance.PatternVariant(_, None, "False", [], False) ->
      Ok(evaluator.PBool(False))
    glance.PatternInt(location, s) ->
      case int.parse(s) {
        Ok(n) -> Ok(evaluator.PInt(n))
        Error(_) -> fail("Invalid integer literal: " <> s, location, at)
      }
    glance.PatternDiscard(_, _) -> Ok(evaluator.PWildcard)
    glance.PatternVariable(_, name) -> Ok(evaluator.PVar(name))
    glance.PatternList(_, elems, rest) -> {
      use converted_elems <- result.try(
        list.try_map(elems, convert_pattern(_, at)),
      )
      use rest <- result.try(case rest {
        None -> Ok(None)
        Some(r) -> result.map(pattern_name(r, "list pattern", at), Some)
      })
      Ok(evaluator.PList(converted_elems, rest))
    }
    _ -> fail("Pattern type not supported", pat.location, at)
  }
}

/// The names a pattern binds, in order.
fn pattern_names(pattern: Pattern) -> List(String) {
  case pattern {
    evaluator.PVar(name) -> [name]
    evaluator.PList(elems, rest) ->
      list.append(list.flat_map(elems, pattern_names), case rest {
        Some(name) -> [name]
        None -> []
      })
    _ -> []
  }
}
