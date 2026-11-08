//// Drop: a physics game on top of the animator.
////
//// A ball falls from the top-left of the canvas. The player's draw function adds
//// lines (revealed over time, exactly as the animator reveals them) that the ball
//// bounces and rolls on, and the goal is to guide it into a bucket whose place
//// changes every level. Levels never run out: each is made from its number.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import render.{type RenderPath, RenderPath}
import shape.{type Path, Line, Point}

// ── Constants ─────────────────────────────────────────────────────────────────

/// The ball's radius, in canvas units.
pub const radius = 14.0

// Gravity, in units per second squared.
const gravity = 450.0

// How much of the speed into a surface comes back out.
const restitution = 0.4

// Each step keeps this much of the speed along a surface it touches.
const grip = 0.9985

// The simulation's time step, in seconds.
const dt = 0.008333333

// The longest a run lasts, in steps (12 seconds).
const max_steps = 1440

// The fastest the ball can go; this keeps one step shorter than its radius.
const speed_cap = 850.0

// The ball is stuck when slower than this for this many steps.
const stuck_speed = 25.0

const stuck_steps = 150

// A trajectory point is recorded every this many steps.
const sample_every = 2

/// The time between recorded trajectory points, in tenths of a second.
pub const sample_tenths = 0.16666667

// Past this many lines in the player's drawing, nothing is simulated.
const max_lines = 300

// ── Types ─────────────────────────────────────────────────────────────────────

/// A straight wall: x1, y1, x2, y2.
pub type Segment =
  #(Float, Float, Float, Float)

/// The goal bucket: a floor and a right wall, with a low lip on the left. A ball
/// that touches it from the inside has won.
pub type Goal {
  Goal(left: Float, right: Float, floor: Float)
}

pub type Level {
  Level(
    number: Int,
    // Where the ball starts.
    start: #(Float, Float),
    goal: Goal,
    // Solid walls in the way.
    walls: List(Segment),
    // A solution: the corners of a chain of ramps, used to make the level and to
    // check that it can be won.
    route: List(#(Float, Float)),
  )
}

pub type Outcome {
  Cleared
  Missed(reason: String)
}

/// A finished simulation.
pub type Run {
  Run(
    // The ball's path as x, y, x, y, ... one pair every `sample_tenths`.
    points: List(Float),
    outcome: Outcome,
    // When the run ends, in tenths of a second.
    end_time: Float,
  )
}

// ── Levels ────────────────────────────────────────────────────────────────────

// A repeatable pseudo-random whole number from a level number and a salt.
fn hash(level: Int, salt: Int) -> Int {
  let a = { level * 7919 + salt * 104_729 + 13 } % 65_521
  let b = { a * a + 31 * a + salt * 17 + level } % 65_521
  { b * 48_271 } % 65_521
}

// A repeatable pseudo-random whole number from lo to hi, both included.
fn between(level: Int, salt: Int, lo: Int, hi: Int) -> Int {
  lo + hash(level, salt) % { hi - lo + 1 }
}

// The whole numbers from `from` to `to`, both included.
fn upto(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..upto(from + 1, to)]
  }
}

fn f(n: Int) -> Float {
  int.to_float(n)
}

/// The level with this number (1, 2, 3, ...). Every level can be won: a layout
/// whose solution doesn't clear it in the simulation is replaced by another.
pub fn level(number: Int) -> Level {
  solvable(number, 0)
}

fn solvable(number: Int, variant: Int) -> Level {
  let candidate = generate(number, variant)
  case variant >= 60 || acceptable(candidate) {
    True -> candidate
    False -> solvable(number, variant + 1)
  }
}

// A layout is used if its solution wins, its walls keep clear of the solution and
// the bucket, and (past the first levels) one straight line from the ball to the
// bucket does not win.
fn acceptable(level: Level) -> Bool {
  can_clear(level)
  && walls_clear_of_goal(level)
  && walls_clear_of_route(level)
  && { level.number < 7 || !direct_line_clears(level) }
}

// The solution as paths: its first ramp is a line, and any later ramp a boost
// strip (the only other shape that is a plain segment).
fn route_paths(level: Level) -> List(Path) {
  list.zip(level.route, list.drop(level.route, 1))
  |> list.index_map(fn(pair, i) {
    let #(a, b) = pair
    let thickness = case i {
      0 -> 3.0
      _ -> 5.0
    }
    shape.Path(Line(Point(a.0, a.1), Point(b.0, b.1)), 0.0, 10.0, thickness)
  })
}

// Whether the solution carries the ball into the goal.
fn can_clear(level: Level) -> Bool {
  simulate(level, route_paths(level)).outcome == Cleared
}

// Whether a single straight line from where the solution starts to where it ends
// carries the ball into the goal, which a good level shouldn't allow.
fn direct_line_clears(level: Level) -> Bool {
  case level.route, list.last(level.route) {
    [from, ..], Ok(to) ->
      simulate(level, [
        shape.Path(
          Line(Point(from.0, from.1), Point(to.0, to.1)),
          0.0,
          10.0,
          3.0,
        ),
      ]).outcome
      == Cleared
    _, _ -> False
  }
}

// Whether every wall keeps well away from the solution.
fn walls_clear_of_route(level: Level) -> Bool {
  list.all(level.walls, fn(wall) {
    list.all(wall_samples(wall), fn(p) {
      distance_to_route(p, level.route) >=. 25.0
    })
  })
}

// Points along a wall: its ends and three between.
fn wall_samples(wall: Segment) -> List(#(Float, Float)) {
  list.map([0.0, 0.25, 0.5, 0.75, 1.0], fn(t) {
    #(wall.0 +. { wall.2 -. wall.0 } *. t, wall.1 +. { wall.3 -. wall.1 } *. t)
  })
}

// Whether every wall's ends are well away from the bucket.
fn walls_clear_of_goal(level: Level) -> Bool {
  let goal = level.goal
  list.all(level.walls, fn(wall) {
    let centre = #({ goal.left +. goal.right } /. 2.0, goal.floor)
    distance(wall.0, wall.1, centre.0, centre.1) >=. 90.0
    && distance(wall.2, wall.3, centre.0, centre.1) >=. 90.0
  })
}

// One layout for a level; `variant` picks another when the first can't be won.
fn generate(number: Int, variant: Int) -> Level {
  let b = variant * 4000
  let sx = f(between(number, 1 + b, -400, -360))
  let sy = f(between(number, 2 + b, -380, -350))
  // The bucket gets narrower as levels go on, and moves every level.
  let width = f(int.max(110, 190 - 3 * number))
  let left = f(between(number, 3 + b, -80, 300))
  let floor = f(between(number, 4 + b, 120, 400))
  let goal = Goal(left: left, right: left +. width, floor: floor)
  let route =
    make_route(number, b, #(sx -. 40.0, sy +. 80.0), #(
      left +. 20.0,
      floor -. 70.0,
    ))
  Level(
    number: number,
    start: #(sx, sy),
    goal: goal,
    walls: make_walls(number, b, #(sx, sy), goal, route),
    route: route,
  )
}

fn distance(x1: Float, y1: Float, x2: Float, y2: Float) -> Float {
  let dx = x2 -. x1
  let dy = y2 -. y1
  float.square_root(dx *. dx +. dy *. dy) |> result_or(0.0)
}

fn result_or(r: Result(Float, Nil), default: Float) -> Float {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

// The solution's ramps. The first levels are one straight ramp. After that the way
// bends: it goes steep, then shallow, well off the straight line from the ball to
// the bucket, and that straight line is blocked (see `make_walls`).
fn make_route(
  number: Int,
  b: Int,
  from: #(Float, Float),
  to: #(Float, Float),
) -> List(#(Float, Float)) {
  case number < 7 {
    True -> [from, to]
    False -> {
      // Whole numbers, so that the solution's code draws exactly this route.
      let x = from.0 +. { to.0 -. from.0 } *. 0.3
      let y = from.1 +. { to.1 -. from.1 } *. 0.7
      [
        from,
        #(
          f(float.round(x) + between(number, 20 + b, -40, 40)),
          f(float.round(y) + between(number, 30 + b, -30, 30)),
        ),
        to,
      ]
    }
  }
}

// The red walls, which come in slowly. The first levels have none. From level 4 a
// full-height barrier stands across the level with a wide gap where the solution
// passes; later levels add barriers and the gap narrows. From level 7 the solution
// bends (so no single straight line gets through every gap) and a shelf under the
// ball makes a line start close below it; a few loose walls come in after that.
fn make_walls(
  number: Int,
  b: Int,
  start: #(Float, Float),
  goal: Goal,
  route: List(#(Float, Float)),
) -> List(Segment) {
  let gates = case number {
    n if n < 4 -> 0
    n if n < 7 -> 1
    n if n < 11 -> 2
    n if n < 16 -> 3
    _ -> 4
  }
  case gates, route, list.last(route) {
    0, _, _ -> []
    _, [from, ..], Ok(to) -> {
      let gap = f(int.max(88, 170 - 3 * { number - 3 }))
      let barriers =
        gate_positions(gates)
        |> list.flat_map(fn(fraction) {
          let x =
            float.round(from.0 +. { to.0 -. from.0 } *. fraction)
            |> int.to_float
          let y = route_y(route, x)
          [
            #(x, -2500.0, x, y -. gap /. 2.0),
            #(x, y +. gap /. 2.0, x, 1500.0),
          ]
        })
      let shelf = case number >= 7 {
        True -> [
          #(-520.0, start.1 +. 230.0, start.0 +. 30.0, start.1 +. 230.0),
        ]
        False -> []
      }
      let loose_walls =
        upto(1, int.min({ number - 4 } / 4, 4))
        |> list.filter_map(fn(k) {
          find_wall(number, b, k, 0, start, goal, route)
        })
      list.flatten([shelf, barriers, loose_walls])
    }
    _, _, _ -> []
  }
}

// How far along the way from the ball to the bucket each barrier stands.
fn gate_positions(count: Int) -> List(Float) {
  case count {
    1 -> [0.65]
    2 -> [0.55, 0.9]
    3 -> [0.4, 0.65, 0.9]
    _ -> [0.3, 0.5, 0.7, 0.9]
  }
}

// The height of the solution at a horizontal position.
fn route_y(route: List(#(Float, Float)), x: Float) -> Float {
  case route {
    [a, b, ..rest] ->
      case x <=. b.0 || list.is_empty(rest) {
        True -> a.1 +. { b.1 -. a.1 } *. { x -. a.0 } /. { b.0 -. a.0 }
        False -> route_y([b, ..rest], x)
      }
    [only] -> only.1
    [] -> 0.0
  }
}

fn find_wall(
  number: Int,
  b: Int,
  k: Int,
  attempt: Int,
  start: #(Float, Float),
  goal: Goal,
  route: List(#(Float, Float)),
) -> Result(Segment, Nil) {
  case attempt >= 8 {
    True -> Error(Nil)
    False -> {
      let salt = 100 + k * 10 + attempt + b
      let cx = f(between(number, salt, -250, 350))
      let cy = f(between(number, salt + 500, -200, 350))
      let hx = f(between(number, salt + 1000, -70, 70))
      let hy = f(between(number, salt + 1500, -40, 40))
      let wall = #(cx -. hx, cy -. hy, cx +. hx, cy +. hy)
      let points = [#(wall.0, wall.1), #(cx, cy), #(wall.2, wall.3)]
      let clear_of_route =
        list.all(points, fn(p) { distance_to_route(p, route) >=. 60.0 })
      let clear_of_goal =
        list.all(points, fn(p) {
          distance(p.0, p.1, { goal.left +. goal.right } /. 2.0, goal.floor)
          >=. 130.0
        })
      let clear_of_start =
        list.all(points, fn(p) {
          distance(p.0, p.1, start.0, start.1) >=. 100.0
        })
      case clear_of_route && clear_of_goal && clear_of_start {
        True -> Ok(wall)
        False -> find_wall(number, b, k, attempt + 1, start, goal, route)
      }
    }
  }
}

fn distance_to_route(
  p: #(Float, Float),
  route: List(#(Float, Float)),
) -> Float {
  list.zip(route, list.drop(route, 1))
  |> list.fold(1.0e9, fn(best, pair) {
    let #(a, b) = pair
    float.min(best, distance_to_segment(p.0, p.1, a.0, a.1, b.0, b.1))
  })
}

// How far the point (px, py) is from the segment (x1, y1)-(x2, y2).
fn distance_to_segment(
  px: Float,
  py: Float,
  x1: Float,
  y1: Float,
  x2: Float,
  y2: Float,
) -> Float {
  let #(qx, qy) = closest_point(px, py, x1, y1, x2, y2)
  distance(px, py, qx, qy)
}

fn closest_point(
  px: Float,
  py: Float,
  x1: Float,
  y1: Float,
  x2: Float,
  y2: Float,
) -> #(Float, Float) {
  let dx = x2 -. x1
  let dy = y2 -. y1
  let length_squared = dx *. dx +. dy *. dy
  case length_squared <=. 0.000001 {
    True -> #(x1, y1)
    False -> {
      let t = { { px -. x1 } *. dx +. { py -. y1 } *. dy } /. length_squared
      let t = float.min(1.0, float.max(0.0, t))
      #(x1 +. dx *. t, y1 +. dy *. t)
    }
  }
}

// The walls of the goal bucket.
fn bucket(goal: Goal) -> List(Segment) {
  [
    #(goal.left, goal.floor -. 40.0, goal.left, goal.floor),
    #(goal.left, goal.floor, goal.right, goal.floor),
    #(goal.right, goal.floor -. 120.0, goal.right, goal.floor),
  ]
}

fn fixed_segments(level: Level) -> List(Segment) {
  list.append(level.walls, bucket(level.goal))
}

/// A level's walls and goal, as paths that are there from the start.
pub fn level_paths(level: Level) -> List(RenderPath) {
  let wall = fn(segment: Segment, color: String, width: Float) {
    RenderPath(
      points: [Point(segment.0, segment.1), Point(segment.2, segment.3)],
      thickness: width,
      color: color,
      start: 0.0,
      end: 0.0,
    )
  }
  // The obstacles are muted so that they don't take over; the goal stands out.
  list.append(
    list.map(level.walls, wall(_, "rgba(232, 128, 112, 0.55)", 3.5)),
    list.map(bucket(level.goal), wall(_, "#5be0a0", 6.0)),
  )
}

/// Code that wins the level: a line along each ramp of its solution.
pub fn reference_solution(level: Level) -> String {
  let lines =
    list.zip(level.route, list.drop(level.route, 1))
    |> list.index_map(fn(pair, i) {
      let #(a, b) = pair
      // The first ramp is a line, any later one a boost strip.
      "    "
      <> case i {
        0 -> "line("
        _ -> "boost("
      }
      <> int.to_string(float.round(a.0))
      <> ", "
      <> int.to_string(float.round(a.1))
      <> ", "
      <> int.to_string(float.round(b.0))
      <> ", "
      <> int.to_string(float.round(b.1))
      <> ", 0),\n"
    })
  "fn draw(shape_slider: Int) -> List(Path) {\n  list.flatten([\n"
  <> list.fold(lines, "", fn(acc, line) { acc <> line })
  <> "  ])\n}\n"
}

// ── The player's drawing ──────────────────────────────────────────────────────

// What kind of thing a line is. Thickness 3 is an ordinary line, 4 a bounce pad,
// 5 a boost strip and 6 a brake pad (see `collide`), 7 a magnet and 8 a lift. The
// shape functions give each kind its own stroke thickness, and the physics reads it back from there, so shapes need nothing but
// the language's own Line and Path.
const kind_wall = 3

const kind_magnet = 7

const kind_lift = 8

// A line that appears between two times, in tenths of a second.
type Drawn {
  Drawn(
    x1: Float,
    y1: Float,
    x2: Float,
    y2: Float,
    start: Float,
    end: Float,
    kind: Int,
  )
}

// Something the ball can touch: x1, y1, x2, y2 and its kind.
type Surface =
  #(Float, Float, Float, Float, Int)

fn drawn_lines(paths: List(Path)) -> List(Drawn) {
  list.map(paths, fn(path) {
    case path.shape {
      Line(a, b) ->
        Drawn(
          a.x,
          a.y,
          b.x,
          b.y,
          path.start,
          path.end,
          int.max(kind_wall, float.round(path.thickness)),
        )
    }
  })
}

/// The colour and stroke width a path is drawn with, which depend on its kind.
pub fn styled(path: Path) -> RenderPath {
  let kind = int.max(kind_wall, float.round(path.thickness))
  let #(color, width) = case kind {
    4 -> #("#ff7ad9", 5.0)
    5 -> #("#ffd166", 4.0)
    6 -> #("#b08968", 6.0)
    7 -> #("#c792ea", 2.5)
    8 -> #("#6fe3f0", 2.0)
    _ -> #("#89ddff", path.thickness)
  }
  RenderPath(..render.render_path(path, color), thickness: width)
}

// The part of a line that exists at this time, if any, as something to bump into.
// A line grows from its start point to its end point between its start and end
// times, the same way the animation draws it. Magnets and lifts are not solid.
fn revealed(line: Drawn, time: Float) -> List(Surface) {
  case time <. line.start || line.kind >= kind_magnet {
    True -> []
    False -> {
      let duration = line.end -. line.start
      let u = case duration <=. 0.0 {
        True -> 1.0
        False -> float.min(1.0, { time -. line.start } /. duration)
      }
      case u <=. 0.0 {
        True -> []
        False -> [
          #(
            line.x1,
            line.y1,
            line.x1 +. { line.x2 -. line.x1 } *. u,
            line.y1 +. { line.y2 -. line.y1 } *. u,
            line.kind,
          ),
        ]
      }
    }
  }
}

/// The player's lines as the ball meets them. A line can't pass through a red wall: it
/// stops where it reaches one, both in the simulation and as it is drawn.
pub fn clip(level: Level, paths: List(Path)) -> List(Path) {
  let walls = fixed_segments(level)
  list.map(paths, fn(path) {
    case path.shape {
      Line(a, b) ->
        // Magnets and lifts are only markers, so they aren't cut short.
        case float.round(path.thickness) >= kind_magnet {
          True -> path
          False -> {
            let reach = first_hit(a.x, a.y, b.x, b.y, walls)
            case reach >=. 1.0 {
              True -> path
              False -> {
                let t = float.max(0.0, reach -. 0.02)
                shape.Path(
                  Line(
                    a,
                    Point(
                      a.x +. { b.x -. a.x } *. t,
                      a.y +. { b.y -. a.y } *. t,
                    ),
                  ),
                  path.start,
                  path.end,
                  path.thickness,
                )
              }
            }
          }
        }
    }
  })
}

// How far along the line from (ax, ay) to (bx, by), from 0 to 1, it first meets one
// of the walls; 1 if it meets none.
fn first_hit(
  ax: Float,
  ay: Float,
  bx: Float,
  by: Float,
  walls: List(Segment),
) -> Float {
  list.fold(walls, 1.0, fn(best, wall) {
    let #(cx, cy, dx, dy) = wall
    let rx = bx -. ax
    let ry = by -. ay
    let sx = dx -. cx
    let sy = dy -. cy
    let cross = rx *. sy -. ry *. sx
    case float.absolute_value(cross) <. 0.000001 {
      True -> best
      False -> {
        let t = { { cx -. ax } *. sy -. { cy -. ay } *. sx } /. cross
        let u = { { cx -. ax } *. ry -. { cy -. ay } *. rx } /. cross
        case t >=. 0.0 && t <=. 1.0 && u >=. 0.0 && u <=. 1.0 {
          True -> float.min(best, t)
          False -> best
        }
      }
    }
  })
}

// ── Fields: things that pull on the ball without being touched ────────────────

type Field {
  // A magnet: its centre, how hard it pulls, and when it appears.
  Pull(x: Float, y: Float, strength: Float, from: Float)
  // A lift: the box it fills, and when it appears.
  Rise(left: Float, top: Float, right: Float, bottom: Float, from: Float)
}

// How far a magnet reaches, and how hard a lift pushes up (units per second squared).
const magnet_reach = 260.0

const lift_force = 1100.0

// How hard a boost strip pushes the ball along it.
const boost_force = 520.0

fn fields(drawn: List(Drawn)) -> List(Field) {
  let of_kind = fn(kind) { list.filter(drawn, fn(line) { line.kind == kind }) }
  let ends = fn(lines: List(Drawn)) {
    list.flat_map(lines, fn(line) { [#(line.x1, line.y1), #(line.x2, line.y2)] })
  }
  let first_start = fn(lines: List(Drawn)) {
    list.fold(lines, 1.0e9, fn(best, line) { float.min(best, line.start) })
  }
  let magnets = of_kind(kind_magnet)
  let lifts = of_kind(kind_lift)
  let pull = case magnets {
    [] -> []
    [first, ..] -> {
      let points = ends(magnets)
      let n = f(list.length(points))
      let cx = list.fold(points, 0.0, fn(sum, p) { sum +. p.0 }) /. n
      let cy = list.fold(points, 0.0, fn(sum, p) { sum +. p.1 }) /. n
      // A bigger marker pulls harder.
      let half = distance(first.x1, first.y1, first.x2, first.y2) /. 2.0
      [Pull(cx, cy, 14.0 *. half, first_start(magnets))]
    }
  }
  let rise = case lifts {
    [] -> []
    _ -> {
      let points = ends(lifts)
      let xs = list.map(points, fn(p) { p.0 })
      let ys = list.map(points, fn(p) { p.1 })
      [
        Rise(
          list.fold(xs, 1.0e9, float.min) -. 20.0,
          list.fold(ys, 1.0e9, float.min),
          list.fold(xs, -1.0e9, float.max) +. 20.0,
          list.fold(ys, -1.0e9, float.max),
          first_start(lifts),
        ),
      ]
    }
  }
  list.append(pull, rise)
}

// The ball's velocity after the fields that are there at this time have pulled on it.
fn pulled(
  fields: List(Field),
  time: Float,
  x: Float,
  y: Float,
  vx: Float,
  vy: Float,
) -> #(Float, Float) {
  list.fold(fields, #(vx, vy), fn(v, field) {
    case field {
      Pull(cx, cy, strength, from) -> {
        let d = distance(x, y, cx, cy)
        case time >=. from && d <. magnet_reach && d >. 1.0 {
          True -> {
            let pull = strength *. { 1.0 -. d /. magnet_reach } *. dt
            #(v.0 +. { cx -. x } /. d *. pull, v.1 +. { cy -. y } /. d *. pull)
          }
          False -> v
        }
      }
      Rise(left, top, right, bottom, from) ->
        case
          time >=. from && x >. left && x <. right && y >. top && y <. bottom
        {
          True -> #(v.0, v.1 -. lift_force *. dt)
          False -> v
        }
    }
  })
}

// ── The simulation ────────────────────────────────────────────────────────────

// The level's own walls and bucket, as surfaces.
fn fixed_surfaces(level: Level) -> List(Surface) {
  fixed_segments(level)
  |> list.map(fn(segment) {
    #(segment.0, segment.1, segment.2, segment.3, kind_wall)
  })
}

/// Drop the ball and see what it does: bounce and roll on the level's walls and
/// on the player's lines (as far as they have grown), pulled by any magnet or
/// lift, until it reaches the goal, falls off, gets stuck, or time runs out.
pub fn simulate(level: Level, paths: List(Path)) -> Run {
  case list.length(paths) > max_lines {
    True -> Run([level.start.0, level.start.1], Missed("Too many lines"), 0.0)
    False -> {
      // A line stops at any red wall it reaches (again, if it was already cut).
      let drawn = drawn_lines(clip(level, paths))
      step(
        level,
        fixed_surfaces(level),
        drawn,
        fields(drawn),
        0,
        level.start.0,
        level.start.1,
        0.0,
        0.0,
        [level.start.1, level.start.0],
        0,
      )
    }
  }
}

fn step(
  level: Level,
  fixed: List(Surface),
  drawn: List(Drawn),
  fields: List(Field),
  i: Int,
  x: Float,
  y: Float,
  vx: Float,
  vy: Float,
  recorded: List(Float),
  slow: Int,
) -> Run {
  let time = f(i) *. dt *. 10.0
  // Fall (and be pulled by magnets and lifts), then move.
  let #(vx, vy) = pulled(fields, time, x, y, vx, vy +. gravity *. dt)
  let #(vx, vy) = cap_speed(vx, vy)
  let x = x +. vx *. dt
  let y = y +. vy *. dt
  // Bounce off everything that exists now (twice, to settle corners).
  let surfaces =
    list.fold(drawn, fixed, fn(acc, line) {
      list.append(revealed(line, time), acc)
    })
  let #(x, y, vx, vy) = collide(x, y, vx, vy, surfaces)
  let #(x, y, vx, vy) = collide(x, y, vx, vy, surfaces)
  let recorded = case i % sample_every == 0 {
    True -> [y, x, ..recorded]
    False -> recorded
  }
  let slow = case
    float.absolute_value(vx) +. float.absolute_value(vy) <. stuck_speed
  {
    True -> slow + 1
    False -> 0
  }
  case touches_goal(level.goal, x, y) {
    True -> finish(recorded, Cleared)
    False ->
      case y >. 560.0 || x <. -560.0 || x >. 560.0 {
        True -> finish(recorded, Missed("Fell"))
        False ->
          case slow > stuck_steps {
            True -> finish(recorded, Missed("Stuck"))
            False ->
              case i >= max_steps {
                True -> finish(recorded, Missed("Time"))
                False ->
                  step(
                    level,
                    fixed,
                    drawn,
                    fields,
                    i + 1,
                    x,
                    y,
                    vx,
                    vy,
                    recorded,
                    slow,
                  )
              }
          }
      }
  }
}

// Whether the ball is touching the bucket from the inside: between its sides, above
// its floor, and against the floor or a wall. Being above its open top isn't enough.
fn touches_goal(goal: Goal, x: Float, y: Float) -> Bool {
  x >. goal.left
  && x <. goal.right
  && y <. goal.floor
  && list.any(bucket(goal), fn(segment) {
    let #(x1, y1, x2, y2) = segment
    distance_to_segment(x, y, x1, y1, x2, y2) <=. radius +. 2.0
  })
}

fn cap_speed(vx: Float, vy: Float) -> #(Float, Float) {
  let speed = distance(0.0, 0.0, vx, vy)
  case speed >. speed_cap {
    True -> #(vx *. speed_cap /. speed, vy *. speed_cap /. speed)
    False -> #(vx, vy)
  }
}

// How much of its speed into a surface the ball keeps going out. A bounce pad gives
// back all it took, a brake pad nothing, and a slow touch is only a rest.
fn bounciness(kind: Int, into: Float) -> Float {
  case kind {
    4 ->
      case into >. -20.0 {
        True -> 0.0
        False -> 1.0
      }
    6 -> 0.0
    _ ->
      case into >. -60.0 {
        True -> 0.0
        False -> restitution
      }
  }
}

// Push the ball out of every surface it overlaps and reflect its velocity. Boost
// strips also push it along them, and brake pads slow it.
fn collide(
  x: Float,
  y: Float,
  vx: Float,
  vy: Float,
  surfaces: List(Surface),
) -> #(Float, Float, Float, Float) {
  case surfaces {
    [] -> #(x, y, vx, vy)
    [surface, ..rest] -> {
      let #(x1, y1, x2, y2, kind) = surface
      let #(qx, qy) = closest_point(x, y, x1, y1, x2, y2)
      let dx = x -. qx
      let dy = y -. qy
      let d = distance(x, y, qx, qy)
      case d >=. radius {
        True -> collide(x, y, vx, vy, rest)
        False -> {
          // The surface's normal, pointing at the ball. If the ball's centre is
          // exactly on the segment, use the segment's own normal, upward.
          let #(nx, ny) = case d <. 0.0001 {
            True -> segment_normal(x1, y1, x2, y2)
            False -> #(dx /. d, dy /. d)
          }
          let x = qx +. nx *. radius
          let y = qy +. ny *. radius
          let into = vx *. nx +. vy *. ny
          let #(vx, vy) = case into <. 0.0 {
            False -> #(vx, vy)
            True -> {
              let bounce = bounciness(kind, into)
              #(
                { vx -. { 1.0 +. bounce } *. into *. nx } *. grip,
                { vy -. { 1.0 +. bounce } *. into *. ny } *. grip,
              )
            }
          }
          let #(vx, vy) = case kind {
            5 -> {
              // Along the strip, from its first end to its second.
              let length = distance(x1, y1, x2, y2)
              case length >. 0.0001 {
                True -> #(
                  vx +. { x2 -. x1 } /. length *. boost_force *. dt,
                  vy +. { y2 -. y1 } /. length *. boost_force *. dt,
                )
                False -> #(vx, vy)
              }
            }
            6 -> #(vx *. 0.93, vy *. 0.93)
            _ -> #(vx, vy)
          }
          collide(x, y, vx, vy, rest)
        }
      }
    }
  }
}

fn segment_normal(
  x1: Float,
  y1: Float,
  x2: Float,
  y2: Float,
) -> #(Float, Float) {
  let dx = x2 -. x1
  let dy = y2 -. y1
  let length = distance(0.0, 0.0, dx, dy)
  case length <. 0.0001 {
    True -> #(0.0, -1.0)
    False -> {
      // Perpendicular to the segment, choosing the one that points up.
      let nx = dy /. length
      let ny = 0.0 -. dx /. length
      case ny >. 0.0 {
        True -> #(0.0 -. nx, 0.0 -. ny)
        False -> #(nx, ny)
      }
    }
  }
}

fn finish(recorded: List(Float), outcome: Outcome) -> Run {
  let points = list.reverse(recorded)
  let count = list.length(points) / 2
  Run(
    points: points,
    outcome: outcome,
    end_time: f(int.max(count - 1, 0)) *. sample_tenths,
  )
}

// ── Drawing the run ───────────────────────────────────────────────────────────

/// The ball's trail: a faint line along its path that grows with the animation, so
/// its tip is where the ball is.
pub fn trail(run: Run) -> RenderPath {
  RenderPath(
    points: pairs(run.points),
    thickness: 3.0,
    color: "rgba(255, 255, 255, 0.28)",
    start: 0.0,
    end: run.end_time,
  )
}

fn pairs(flat: List(Float)) -> List(shape.Point) {
  case flat {
    [x, y, ..rest] -> [Point(x, y), ..pairs(rest)]
    _ -> []
  }
}

// ── The ball and the toolbox (game_ffi.mjs) ───────────────────────────────────

/// Show the ball. Until `dropped`, it waits at the start. Once dropped it moves
/// along `points` (x, y, x, y, ...; one pair every `interval` tenths of a second),
/// following the animation's clock, and calls `on_end` once the clock reaches
/// `end_time`. Replaces any earlier ball.
@external(javascript, "./game_ffi.mjs", "armBall")
pub fn arm_ball(
  points: List(Float),
  interval: Float,
  end_time: Float,
  on_end: fn() -> Nil,
  dropped: Bool,
) -> Nil

/// Remove the ball.
@external(javascript, "./game_ffi.mjs", "disarmBall")
pub fn disarm_ball() -> Nil

/// Add a line of code to the end of the shape list in the code editor.
@external(javascript, "./game_ffi.mjs", "addSnippet")
pub fn add_snippet(snippet: String) -> Nil

/// Let shapes on the canvas be picked up and moved: the three functions are called
/// with the canvas position (x, y, in canvas units) as the pointer goes down and
/// moves. When it comes up, `on_end` says whether it was over the trash can.
@external(javascript, "./game_ffi.mjs", "installDrag")
pub fn install_drag(
  on_start: fn(Float, Float) -> Nil,
  on_move: fn(Float, Float) -> Nil,
  on_end: fn(Bool) -> Nil,
) -> Nil

/// Delete a line of the code editor (counting from 1).
@external(javascript, "./game_ffi.mjs", "deleteLine")
pub fn delete_line(line: Int) -> Nil

/// Replace a line of the code editor (counting from 1).
@external(javascript, "./game_ffi.mjs", "replaceLine")
pub fn replace_line(line: Int, text: String) -> Nil

/// Show or hide small labels in the code editor that say what each number in a
/// shape's call does.
@external(javascript, "./game_ffi.mjs", "setHints")
pub fn set_hints(on: Bool) -> Nil

/// Let the bar between the code column and the level be dragged to resize the column.
@external(javascript, "./game_ffi.mjs", "installResizer")
pub fn install_resizer() -> Nil

/// Clear everything saved in the browser and reload the page.
@external(javascript, "./game_ffi.mjs", "clearData")
pub fn clear_data() -> Nil

/// Let toolbox tiles be dragged into the code editor, or onto the level, where
/// `on_drop` is called with the tile's code and the canvas position (x, y).
@external(javascript, "./game_ffi.mjs", "installToolbox")
pub fn install_toolbox(on_drop: fn(String, Float, Float) -> Nil) -> Nil

// ── The player's code ─────────────────────────────────────────────────────────

/// The code a level starts with: one shape per line inside the list.
pub const template =
  "fn draw(shape_slider: Int) -> List(Path) {
  list.flatten([
  ])
}
"

/// A shape the player can drag into their code.
pub type Tile {
  Tile(name: String, snippet: String)
}

/// The tiles for a level. The line starts under the ball and heads down the first
/// stretch of the way to the goal, so it needs lengthening or moving to win.
pub fn tiles(level: Level) -> List(Tile) {
  let line = case level.route {
    [a, b, ..] ->
      "line("
      <> int.to_string(float.round(a.0))
      <> ", "
      <> int.to_string(float.round(a.1))
      <> ", "
      <> int.to_string(float.round({ a.0 +. b.0 } /. 2.0))
      <> ", "
      <> int.to_string(float.round({ a.1 +. b.1 } /. 2.0))
      <> ", 0)"
    _ -> "line(-420, -300, -150, -120, 0)"
  }
  [
    Tile("Line", line),
    Tile("Slide", "slide(-300, -100, 200, 0)"),
    Tile("Funnel", "funnel(-50, -50, 200, 0)"),
    Tile("Backstop", "backstop(350, 200, 160, 0)"),
    Tile("Kicker", "kicker(-100, 100, 160, 0)"),
    Tile("Chute", "chute(100, -100, 200, 0)"),
    Tile("Bowl", "bowl(150, 250, 200, 0)"),
    Tile("Arc", "arc(-200, -100, 100, 0)"),
    Tile("Stairs", "stairs(-300, -200, 70, 0)"),
    Tile("Zigzag", "zigzag(-250, 150, 240, 0)"),
    // These change how the ball moves.
    Tile("Bounce", "bounce(-200, 120, 140, 0, 0)"),
    Tile("Boost", "boost(-100, -100, 100, 0, 0)"),
    Tile("Brake", "brake(150, 250, 140, 0)"),
    Tile("Magnet", "magnet(0, 200, 40, 0)"),
    Tile("Lift", "lift(-200, 300, 200, 0)"),
  ]
}

// ── Dragging shapes on the canvas ─────────────────────────────────────────────

/// A shape in the player's code: its line (counting from 1), indent, function name
/// and arguments as written.
pub type Call {
  Call(line: Int, indent: String, name: String, args: List(String))
}

/// A shape being dragged: its code, the numbers that place it (as first written),
/// and where on the canvas the drag began.
pub type Grab {
  Grab(call: Call, origin: List(Int), x: Float, y: Float)
}

// How close (in canvas units) a click has to be to a shape to pick it up.
const reach = 30.0

/// The names of the shapes in the toolbox, as they are written in code. A level
/// may use each of them at most once.
pub const shape_names = [
  "line", "slide", "funnel", "backstop", "kicker", "chute", "bowl", "arc",
  "stairs", "zigzag", "bounce", "boost", "brake", "magnet", "lift",
]

// The lines inside the shape list, with their line numbers (from 1). Error if the
// code has no shape list.
fn list_lines(source: String) -> Result(List(#(Int, String)), Nil) {
  let numbered =
    string.split(source, "\n")
    |> list.index_map(fn(text, i) { #(i + 1, text) })
  use open <- result.try(
    list.find(numbered, fn(l) {
      string.ends_with(string.trim(l.1), "list.flatten([")
    }),
  )
  Ok(
    numbered
    |> list.drop(open.0)
    |> list.take_while(fn(l) { string.trim(l.1) != "])" }),
  )
}

/// The shapes in the player's code, one per line of the shape list.
pub fn shape_calls(source: String) -> List(Call) {
  case list_lines(source) {
    Error(_) -> []
    Ok(lines) -> list.filter_map(lines, fn(l) { parse_call(l.0, l.1) })
  }
}

/// The shapes the code uses, by name.
pub fn used_shapes(source: String) -> List(String) {
  list.map(shape_calls(source), fn(call) { call.name })
}

/// Whether the code may be run in the game: its shape list holds only toolbox
/// shapes, one per line, and no shape more than once. If not, a title and a few
/// words saying what to change.
pub fn check_shapes(source: String) -> Result(Nil, #(String, String)) {
  case list_lines(source) {
    Error(_) ->
      Error(#("Keep the shape list", "shapes go inside list.flatten([ ])"))
    Ok(lines) -> {
      let code =
        lines
        |> list.map(fn(l) { string.trim(l.1) })
        |> list.filter(fn(text) {
          text != "" && !string.starts_with(text, "//")
        })
      let names =
        list.filter_map(code, fn(text) {
          use call <- result.try(parse_call(0, text))
          case list.contains(shape_names, call.name) {
            True -> Ok(call.name)
            False -> Error(Nil)
          }
        })
      case list.length(names) == list.length(code) {
        False -> Error(#("Toolbox shapes only", "one shape per line"))
        True ->
          case
            list.find(shape_names, fn(name) {
              list.length(list.filter(names, fn(n) { n == name })) > 1
            })
          {
            Ok(_) ->
              Error(#(
                "Max one per shape",
                "Remove duplicates of the same shape",
              ))
            Error(_) -> Ok(Nil)
          }
      }
    }
  }
}

// Whether every ( has its ) and none comes first.
fn balanced(text: String) -> Bool {
  let depth =
    list.fold(string.to_graphemes(text), Ok(0), fn(depth, g) {
      case depth, g {
        Ok(d), "(" -> Ok(d + 1)
        Ok(d), ")" ->
          case d > 0 {
            True -> Ok(d - 1)
            False -> Error(Nil)
          }
        other, _ -> other
      }
    })
  depth == Ok(0)
}

fn parse_call(line: Int, text: String) -> Result(Call, Nil) {
  let trimmed = string.trim(text)
  let indent =
    string.slice(
      text,
      0,
      string.length(text) - string.length(string.trim_start(text)),
    )
  let body = case string.ends_with(trimmed, ",") {
    True -> string.drop_end(trimmed, 1)
    False -> trimmed
  }
  case string.split_once(body, "(") {
    Ok(#(name, rest)) ->
      case string.ends_with(rest, ")") {
        True ->
          case balanced(string.drop_end(rest, 1)) {
            True ->
              Ok(Call(
                line,
                indent,
                string.trim(name),
                split_args(string.drop_end(rest, 1)),
              ))
            False -> Error(Nil)
          }
        False -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

// Split on the commas that aren't inside brackets.
fn split_args(inner: String) -> List(String) {
  let #(parts, current, _) =
    list.fold(string.to_graphemes(inner), #([], "", 0), fn(acc, g) {
      let #(parts, current, depth) = acc
      case g {
        "(" -> #(parts, current <> g, depth + 1)
        ")" -> #(parts, current <> g, depth - 1)
        "," if depth == 0 -> #([current, ..parts], "", depth)
        _ -> #(parts, current <> g, depth)
      }
    })
  list.reverse([current, ..parts]) |> list.map(string.trim)
}

// How many of a shape's first arguments say where it is: a line has two points,
// every other shape one.
fn position_count(name: String) -> Int {
  case name {
    "line" | "boost" -> 4
    _ -> 2
  }
}

// The numbers that place a shape, if they are written as plain numbers.
fn placement(call: Call) -> Result(List(Int), Nil) {
  call.args
  |> list.take(position_count(call.name))
  |> list.try_map(int.parse)
}

/// The shape closest to a point on the canvas, if the point is near enough to pick
/// it up. `run` draws code and gives its paths.
pub fn hit_test(
  source: String,
  x: Float,
  y: Float,
  run: fn(String) -> Result(List(Path), String),
) -> Result(Grab, Nil) {
  shape_calls(source)
  |> list.filter_map(fn(call) {
    use origin <- result.try(placement(call))
    use paths <- result.try(run(single_call(call)) |> result.replace_error(Nil))
    // A line is picked up by its stroke. Any other shape can also be picked up
    // from inside, though a stroke close by wins.
    let outline = distance_to_paths(paths, x, y)
    let distance = case call.name != "line" && inside_bounds(paths, x, y) {
      True -> float.min(outline, reach /. 2.0 +. 1.0)
      False -> outline
    }
    Ok(#(distance, Grab(call, origin, x, y)))
  })
  |> list.filter(fn(candidate) { candidate.0 <. reach })
  |> list.sort(fn(a, b) { float.compare(a.0, b.0) })
  |> list.first
  |> result.map(fn(candidate) { candidate.1 })
}

// Code that draws just this shape.
fn single_call(call: Call) -> String {
  "fn draw(shape_slider: Int) -> List(Path) {\n  list.flatten([\n    "
  <> call.name
  <> "("
  <> string.join(call.args, ", ")
  <> "),\n  ])\n}\n"
}

// Whether a point is inside the box around the paths.
fn inside_bounds(paths: List(Path), x: Float, y: Float) -> Bool {
  case bounds(paths) {
    Ok(#(left, top, right, bottom)) ->
      x >=. left && x <=. right && y >=. top && y <=. bottom
    Error(_) -> False
  }
}

// The box around the paths: left, top, right, bottom.
fn bounds(paths: List(Path)) -> Result(#(Float, Float, Float, Float), Nil) {
  let points =
    list.flat_map(paths, fn(path) {
      case path.shape {
        Line(a, b) -> [a, b]
      }
    })
  let xs = list.map(points, fn(p) { p.x })
  let ys = list.map(points, fn(p) { p.y })
  case xs, ys {
    [], _ | _, [] -> Error(Nil)
    _, _ ->
      Ok(#(
        list.fold(xs, 1.0e9, float.min),
        list.fold(ys, 1.0e9, float.min),
        list.fold(xs, -1.0e9, float.max),
        list.fold(ys, -1.0e9, float.max),
      ))
  }
}

fn distance_to_paths(paths: List(Path), x: Float, y: Float) -> Float {
  list.fold(paths, 1.0e9, fn(best, path) {
    case path.shape {
      Line(a, b) ->
        float.min(best, distance_to_segment(x, y, a.x, a.y, b.x, b.y))
    }
  })
}

/// The shape's line of code after dragging from where it was picked up to (x, y).
pub fn moved_line(grab: Grab, x: Float, y: Float) -> String {
  grab.call.indent <> moved_call(grab, x, y) <> ","
}

// The shape's call after moving it, as it is written without the indent or comma.
fn moved_call(grab: Grab, x: Float, y: Float) -> String {
  let dx = float.round(x -. grab.x)
  let dy = float.round(y -. grab.y)
  let moved =
    list.index_map(grab.origin, fn(value, i) {
      int.to_string(case i % 2 == 0 {
        True -> value + dx
        False -> value + dy
      })
    })
  let rest = list.drop(grab.call.args, list.length(grab.origin))
  grab.call.name <> "(" <> string.join(list.append(moved, rest), ", ") <> ")"
}

/// A toolbox snippet moved so that the shape it draws is centred on (x, y). `run`
/// draws code and gives its paths. If that can't be worked out, the snippet as is.
pub fn place(
  snippet: String,
  x: Float,
  y: Float,
  run: fn(String) -> Result(List(Path), String),
) -> String {
  let placed = {
    use call <- result.try(parse_call(0, snippet))
    use origin <- result.try(placement(call))
    use paths <- result.try(run(single_call(call)) |> result.replace_error(Nil))
    use #(left, top, right, bottom) <- result.try(bounds(paths))
    let centre =
      Grab(call, origin, { left +. right } /. 2.0, { top +. bottom } /. 2.0)
    Ok(moved_call(centre, x, y))
  }
  result.unwrap(placed, snippet)
}

/// The functions the tiles call. They are added after the player's code, so line
/// numbers in error messages are the player's own. Every one gives a list of
/// paths, `t` is when it starts to draw (tenths of a second), and the integer
/// numbers below are cosines and sines times 1000, because the language has no
/// trigonometry.
pub const prelude =
  "fn kseg(a: Point, b: Point, t: Int, d: Int, k: Int) -> Path {
  Path(Line(a, b), t, t + d, k)
}

fn seg(a: Point, b: Point, t: Int, d: Int) -> Path {
  kseg(a, b, t, d, 3)
}

fn bounce(x: Int, y: Int, w: Int, tilt: Int, t: Int) -> List(Path) {
  [kseg(Point(x - w / 2, y - tilt / 2), Point(x + w / 2, y + tilt / 2), t, 6, 4)]
}

fn boost(x1: Int, y1: Int, x2: Int, y2: Int, t: Int) -> List(Path) {
  [kseg(Point(x1, y1), Point(x2, y2), t, 10, 5)]
}

fn brake(x: Int, y: Int, w: Int, t: Int) -> List(Path) {
  [kseg(Point(x - w / 2, y), Point(x + w / 2, y), t, 6, 6)]
}

fn magnet(x: Int, y: Int, s: Int, t: Int) -> List(Path) {
  [
    kseg(Point(x - s, y), Point(x + s, y), t, 4, 7),
    kseg(Point(x, y - s), Point(x, y + s), t + 3, 4, 7),
  ]
}

fn lift(x: Int, y: Int, h: Int, t: Int) -> List(Path) {
  [
    kseg(Point(x - 30, y), Point(x - 30, y - h), t, 6, 8),
    kseg(Point(x, y), Point(x, y - h), t + 2, 6, 8),
    kseg(Point(x + 30, y), Point(x + 30, y - h), t + 4, 6, 8),
  ]
}

fn line(x1: Int, y1: Int, x2: Int, y2: Int, t: Int) -> List(Path) {
  [seg(Point(x1, y1), Point(x2, y2), t, 10)]
}

fn zigzag(x: Int, y: Int, w: Int, t: Int) -> List(Path) {
  let q = w / 4
  let h = w / 6
  [
    seg(Point(x, y), Point(x + q, y + h), t, 3),
    seg(Point(x + q, y + h), Point(x + 2 * q, y), t + 3, 3),
    seg(Point(x + 2 * q, y), Point(x + 3 * q, y + h), t + 6, 3),
    seg(Point(x + 3 * q, y + h), Point(x + w, y), t + 9, 3),
  ]
}

fn bowl(cx: Int, cy: Int, w: Int, t: Int) -> List(Path) {
  let h = w / 2
  let q = w / 4
  [
    seg(Point(cx - h, cy - q), Point(cx - q, cy), t, 4),
    seg(Point(cx - q, cy), Point(cx + q, cy), t + 4, 4),
    seg(Point(cx + q, cy), Point(cx + h, cy - q), t + 8, 4),
  ]
}

fn stairs(x: Int, y: Int, s: Int, t: Int) -> List(Path) {
  [
    seg(Point(x, y), Point(x + s, y), t, 3),
    seg(Point(x + s, y), Point(x + s, y + s), t + 3, 3),
    seg(Point(x + s, y + s), Point(x + 2 * s, y + s), t + 6, 3),
    seg(Point(x + 2 * s, y + s), Point(x + 2 * s, y + 2 * s), t + 9, 3),
    seg(Point(x + 2 * s, y + 2 * s), Point(x + 3 * s, y + 2 * s), t + 12, 3),
  ]
}

fn on_circle(cx: Int, cy: Int, r: Int, c: Int, s: Int) -> Point {
  Point(cx + r * c / 1000, cy + r * s / 1000)
}

fn arc(cx: Int, cy: Int, r: Int, t: Int) -> List(Path) {
  [
    seg(on_circle(cx, cy, r, 1000, 0), on_circle(cx, cy, r, 866, 500), t, 2),
    seg(on_circle(cx, cy, r, 866, 500), on_circle(cx, cy, r, 500, 866), t + 1, 2),
    seg(on_circle(cx, cy, r, 500, 866), on_circle(cx, cy, r, 0, 1000), t + 2, 2),
    seg(on_circle(cx, cy, r, 0, 1000), on_circle(cx, cy, r, -500, 866), t + 3, 2),
    seg(on_circle(cx, cy, r, -500, 866), on_circle(cx, cy, r, -866, 500), t + 4, 2),
    seg(on_circle(cx, cy, r, -866, 500), on_circle(cx, cy, r, -1000, 0), t + 5, 2),
  ]
}

fn slide(x: Int, y: Int, s: Int, t: Int) -> List(Path) {
  [
    seg(Point(x, y), Point(x + s * 134 / 1000, y + s / 2), t, 3),
    seg(Point(x + s * 134 / 1000, y + s / 2), Point(x + s / 2, y + s * 866 / 1000), t + 2, 3),
    seg(Point(x + s / 2, y + s * 866 / 1000), Point(x + s, y + s), t + 4, 3),
  ]
}

fn funnel(cx: Int, cy: Int, w: Int, t: Int) -> List(Path) {
  [
    seg(Point(cx - w / 2, cy - w / 3), Point(cx - w / 8, cy + w / 3), t, 5),
    seg(Point(cx + w / 2, cy - w / 3), Point(cx + w / 8, cy + w / 3), t + 2, 5),
  ]
}

fn backstop(x: Int, y: Int, h: Int, t: Int) -> List(Path) {
  [seg(Point(x, y - h / 2), Point(x, y + h / 2), t, 6)]
}

fn kicker(x: Int, y: Int, w: Int, t: Int) -> List(Path) {
  [seg(Point(x - w / 2, y), Point(x + w / 2, y - w / 3), t, 5)]
}

fn chute(x: Int, y: Int, h: Int, t: Int) -> List(Path) {
  [
    seg(Point(x - 26, y), Point(x - 26, y + h), t, 5),
    seg(Point(x + 26, y), Point(x + 26, y + h), t + 2, 5),
  ]
}
"
