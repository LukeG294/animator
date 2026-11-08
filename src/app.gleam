//// Animator -- an application for program-generated drawings.

import builtins
import data.{type Library}
import drawing
import editor
import errors
import examples
import game
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/element/svg
import lustre/event
import parser
import render
import shape.{type Path}

/// Your app's public address, once you've deployed it in Problem 13, such as
/// "https://your-username.github.io/animator/".
pub const public_url = "https://lukeg294.github.io/animator/"

/// Set to True if you would like your app's URL included in the course gallery.
pub const include_app_in_gallery = True

/// A link to your video from Problem 14, which anyone with the link can watch.
pub const video_url =
  "https://drive.google.com/file/d/1DzXwbMS3RNbPrJNaNe-wjAntr2lcOKPA/view"

/// Set to True if you would like your video included in the course gallery.
pub const include_video_in_gallery = True

const path_color = "#89ddff"

// The value the game passes to draw. The game has no shape slider.
const game_slider = 10

const default_code =
  "fn draw(shape_slider: Int) -> List(Path) {\n  [Path(Line(Point(0, 0), Point(100, 100)), 0, 10, 2)]\n}\n"

// ── Model ──────────────────────────────────────────────────────────────────────

pub type Model {
  Model(
    // The code in the editor.
    source: String,
    // Whether the code editor is shown.
    code_open: Bool,
    // The latest evaluation error, if any, shown in a dialog.
    error: Option(String),
    // The value passed to the draw function.
    shape_slider: Int,
    // Animation speed as a multiple of normal (negative plays backward).
    speed: Float,
    // Whether the animation is playing (False means paused).
    playing: Bool,
    // The saved drawings and which one is open.
    library: Library,
    // Changes when the drawing menu has to be rebuilt (see view_library).
    select_version: Int,
    // Whether the trash button has been clicked once and awaits confirmation.
    confirm_delete: Bool,
    // Whether the game is being played (otherwise the drawing library is shown).
    game_on: Bool,
    // The level being played.
    level: game.Level,
    // How the ball's last run ended, and the line length the drawing uses.
    outcome: Option(game.Outcome),
    // What is wrong with the shapes, if anything: a title and a few words.
    problem: Option(#(String, String)),
    // The speed set outside the game, put back when the game is left.
    free_speed: Float,
    // Whether the how-to-play dialog is showing.
    show_intro: Bool,
    // Whether Clear data has been clicked once and awaits confirmation.
    confirm_clear: Bool,
    // The shape being moved with the pointer, if any.
    grab: Option(game.Grab),
    // Whether the ball has been dropped (it waits at the start until it is).
    dropped: Bool,
    // Whether the run has reached its end, so the result is shown.
    result_shown: Bool,
  )
}

pub type Msg {
  // The editor's text changed.
  SetCode(String)
  // The page has loaded with a drawing open.
  Loaded

  // Layout controls
  ToggleCode
  DismissError

  // Animation controls
  SetShape(Int)
  SetSpeed(Float)
  Play
  Pause
  Reset

  // Drawing menu: a drawing's name, or "" for "+ New drawing".
  SelectDrawing(String)
  // The trash button: the first click asks to confirm, the second deletes.
  DeleteDrawing

  // The game: start it, leave it, the ball's run reached its end, next level.
  PlayGame
  ExitGame
  RunEnded
  NextLevel
  // The Drop ball button, and a toolbox tile being clicked.
  DropBall
  AddTile(String)
  // A tile dropped onto the level at a position.
  DropTile(String, Float, Float)
  // A shape on the canvas picked up, moved, and put down.
  DragStart(Float, Float)
  DragMove(Float, Float)
  // The shape was put down, over the trash can (True) or not.
  DragEnd(Bool)

  // Clear data: the first click asks "Are you sure?", the second wipes everything.
  ClearData
  DisarmClear

  // The how-to-play dialog is dismissed.
  CloseIntro
}

// ── Init ───────────────────────────────────────────────────────────────────────

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  // Reopen what was saved, with the same drawing open as before.
  let library = data.load()
  let source = result.unwrap(data.find(library, library.selected), "")
  #(
    Model(
      source: source,
      code_open: True,
      error: None,
      shape_slider: 10,
      speed: 1.0,
      playing: True,
      library: library,
      select_version: 0,
      confirm_delete: False,
      game_on: False,
      level: game.level(library.game.level),
      outcome: None,
      problem: None,
      show_intro: False,
      confirm_clear: False,
      free_speed: 1.0,
      grab: None,
      dropped: False,
      result_shown: False,
    ),
    // Effects that happen automatically at the start go here.
    effect.batch([
      editor.mount(source, SetCode),
      effect.from(fn(_) { game.install_resizer() }),
      effect.from(fn(dispatch) { dispatch(Loaded) }),
    ]),
  )
}

// Open the saved drawing called name: show its code in the editor, run it from the
// start, and remember it as the open one. If it can't run, its code and the error
// show, and the canvas is left empty.
fn open_drawing(model: Model, name: String) -> #(Model, Effect(Msg)) {
  let source = result.unwrap(data.find(model.library, name), "")
  let library = data.Library(..model.library, selected: name)
  let #(model, run) =
    evaluate(
      Model(..model, library: library, source: source, confirm_delete: False),
      True,
      True,
    )
  #(
    model,
    effect.batch([run, editor.mount(source, SetCode), save(model.library)]),
  )
}

// Whether name is one of the built-in examples, which can't be deleted.
fn is_example(name: String) -> Bool {
  list.key_find(examples.all, name) |> result.is_ok
}

fn save(library: Library) -> Effect(Msg) {
  effect.from(fn(_) { data.save(library) })
}

// Parse and evaluate a draw function at the given shape-slider value, returning
// the rendered paths on success, or a human-readable message on failure.
fn run_source(shape_slider: Int, source: String) -> Result(List(Path), String) {
  case parser.parse_program(source, builtins.global_frame()) {
    Error(msg) -> Error(msg)
    Ok(program) ->
      drawing.try_draw(shape_slider, program)
      // Convert Error(EvalError) to Error(String) with a useful error message.
      |> result.map_error(errors.error_message)
  }
}

// ── Update ─────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ToggleCode -> #(Model(..model, code_open: !model.code_open), effect.none())

    DismissError -> #(Model(..model, error: None), effect.none())

    Loaded -> evaluate(model, True, True)

    // After each keystroke in the editor, save the drawing, evaluate it, and
    // restart the animation. In the game, the code belongs to the level.
    SetCode(text) -> {
      let library = case model.game_on {
        True ->
          data.Library(
            ..model.library,
            game: data.GameState(..model.library.game, code: text),
          )
        False -> data.put(model.library, model.library.selected, text)
      }
      let #(model, run) =
        evaluate(Model(..model, library: library, source: text), True, False)
      #(model, effect.batch([run, save(model.library)]))
    }

    SelectDrawing("") ->
      case data.prompt_drawing_name() {
        // Cancelled: put the menu back on the open drawing.
        "" -> #(
          Model(..model, select_version: model.select_version + 1),
          effect.none(),
        )
        name -> {
          let name = data.unique_name(model.library, name)
          let library = data.put(model.library, name, default_code)
          open_drawing(Model(..model, library: library), name)
        }
      }

    SelectDrawing(name) ->
      case data.find(model.library, name) {
        Ok(_) -> open_drawing(model, name)
        Error(_) -> #(model, effect.none())
      }

    DeleteDrawing ->
      case model.confirm_delete, is_example(model.library.selected) {
        _, True -> #(model, effect.none())
        False, False -> #(Model(..model, confirm_delete: True), effect.none())
        True, False -> {
          let library = data.remove(model.library, model.library.selected)
          let first = case library.drawings {
            [#(name, _), ..] -> name
            [] -> ""
          }
          open_drawing(Model(..model, library: library), first)
        }
      }

    PlayGame -> {
      let code = case model.library.game.code {
        "" -> game.template
        code -> code
      }
      let #(model, run) =
        evaluate(
          Model(
            ..model,
            game_on: True,
            // A player with no game save is shown how to play.
            show_intro: !model.library.game.intro_seen,
            // The game always runs at normal speed, and puts the speed back after.
            free_speed: model.speed,
            speed: 1.0,
            playing: True,
            source: code,
            error: None,
            outcome: None,
            result_shown: False,
          ),
          True,
          True,
        )
      #(
        model,
        effect.batch([
          run,
          editor.mount(code, SetCode),
          effect.from(fn(dispatch) {
            render.set_speed(1.0)
            game.install_toolbox(fn(snippet, x, y) {
              dispatch(DropTile(snippet, x, y))
            })
            game.install_drag(
              fn(x, y) { dispatch(DragStart(x, y)) },
              fn(x, y) { dispatch(DragMove(x, y)) },
              fn(over_trash) { dispatch(DragEnd(over_trash)) },
            )
            game.set_hints(True)
          }),
        ]),
      )
    }

    ExitGame -> {
      game.disarm_ball()
      game.set_hints(False)
      let #(model, open) =
        open_drawing(
          Model(
            ..model,
            game_on: False,
            show_intro: False,
            speed: model.free_speed,
            grab: None,
            outcome: None,
            result_shown: False,
            error: None,
          ),
          model.library.selected,
        )
      #(
        model,
        effect.batch([
          open,
          effect.from(fn(_) {
            case model.playing {
              True -> render.set_speed(model.speed)
              False -> Nil
            }
          }),
        ]),
      )
    }

    RunEnded -> #(Model(..model, result_shown: True), effect.none())

    NextLevel -> {
      let state = model.library.game
      let level = state.level + 1
      let library =
        data.Library(
          ..model.library,
          game: data.GameState(
            level: level,
            highest: int.max(state.highest, level),
            code: "",
            intro_seen: state.intro_seen,
          ),
        )
      let #(model, run) =
        evaluate(
          Model(
            ..model,
            library: library,
            level: game.level(level),
            source: game.template,
            error: None,
            result_shown: False,
          ),
          True,
          True,
        )
      #(
        model,
        effect.batch([run, editor.mount(game.template, SetCode), save(library)]),
      )
    }

    // Re-run the draw function with the new slider value, keeping the clock.
    SetShape(n) ->
      evaluate(Model(..model, shape_slider: n), model.game_on, False)

    SetSpeed(rate) -> #(
      Model(..model, speed: rate),
      effect.from(fn(_) {
        case model.playing {
          True -> render.set_speed(rate)
          False -> Nil
        }
      }),
    )

    Play -> #(
      Model(..model, playing: True),
      effect.from(fn(_) { render.set_speed(model.speed) }),
    )

    Pause -> #(
      Model(..model, playing: False),
      effect.from(fn(_) { render.set_speed(0.0) }),
    )

    // Back to the start, playing at the chosen speed.
    Reset ->
      case model.game_on {
        // In the game, back to the start: the ball waits to be dropped again.
        True -> {
          let #(model, run) =
            evaluate_game(Model(..model, playing: True), False, False)
          #(
            model,
            effect.batch([
              run,
              effect.from(fn(_) { render.set_speed(model.speed) }),
            ]),
          )
        }
        False -> #(
          Model(..model, playing: True),
          effect.from(fn(_) {
            render.reset_clock()
            render.set_speed(model.speed)
          }),
        )
      }

    DropBall ->
      case model.game_on && option.is_none(model.problem) {
        True -> evaluate_game(model, False, True)
        False -> #(model, effect.none())
      }

    // A shape can only be used once, so a tile for one that's in use does nothing.
    AddTile(snippet) ->
      case shape_in_use(model.source, snippet) {
        True -> #(model, effect.none())
        False -> #(model, effect.from(fn(_) { game.add_snippet(snippet) }))
      }

    // Add the shape centred where it was dropped, kept inside the level.
    DropTile(snippet, x, y) -> {
      let draw_code = fn(code) {
        run_source(game_slider, code <> "\n" <> game.prelude)
      }
      let inside = fn(v) { float.min(430.0, float.max(-430.0, v)) }
      #(
        model,
        effect.from(fn(_) {
          game.add_snippet(game.place(snippet, inside(x), inside(y), draw_code))
        }),
      )
    }

    // Pick up the shape under the pointer, if there is one.
    DragStart(x, y) ->
      case model.game_on {
        False -> #(model, effect.none())
        True -> {
          let draw_code = fn(code) {
            run_source(game_slider, code <> "\n" <> game.prelude)
          }
          #(
            Model(
              ..model,
              grab: game.hit_test(model.source, x, y, draw_code)
                |> option.from_result,
            ),
            effect.none(),
          )
        }
      }

    // Move it: its numbers are rewritten in the editor, which redraws everything.
    DragMove(x, y) ->
      case model.grab {
        None -> #(model, effect.none())
        Some(grab) -> #(
          model,
          effect.from(fn(_) {
            game.replace_line(grab.call.line, game.moved_line(grab, x, y))
          }),
        )
      }

    ClearData ->
      case model.confirm_clear {
        True -> #(model, effect.from(fn(_) { game.clear_data() }))
        False -> #(Model(..model, confirm_clear: True), effect.none())
      }

    DisarmClear -> #(Model(..model, confirm_clear: False), effect.none())

    // Once the dialog has been read, that is remembered, so it only shows once.
    CloseIntro -> {
      let library =
        data.Library(
          ..model.library,
          game: data.GameState(..model.library.game, intro_seen: True),
        )
      #(Model(..model, show_intro: False, library: library), save(library))
    }

    // Put down over the trash can, a shape's line of code is deleted.
    DragEnd(over_trash) -> #(
      Model(..model, grab: None),
      case model.grab, over_trash {
        Some(grab), True ->
          effect.from(fn(_) { game.delete_line(grab.call.line) })
        _, _ -> effect.none()
      },
    )
  }
}

// Evaluate the model's source at its shape slider value. On success, hand the
// paths to the canvas (restarting the clock if `restart`). On failure, show the
// error, and either keep the last drawing (while editing) or, if `clear_on_error`,
// empty the canvas (when a drawing is opened).
fn evaluate(
  model: Model,
  restart: Bool,
  clear_on_error: Bool,
) -> #(Model, Effect(Msg)) {
  case model.game_on {
    True -> evaluate_game(model, clear_on_error, False)
    False ->
      case run_source(model.shape_slider, model.source) {
        Ok(paths) -> #(
          Model(..model, error: None),
          effect.from(fn(_) {
            paths
            |> list.map(render.render_path(_, path_color))
            |> render.set_drawing
            case restart {
              True -> render.reset_clock()
              False -> Nil
            }
          }),
        )
        Error(msg) -> #(Model(..model, error: Some(msg)), case clear_on_error {
          True ->
            effect.from(fn(_) {
              render.set_drawing([])
              render.reset_clock()
            })
          False -> effect.none()
        })
      }
  }
}

// Evaluate the player's code in the game: lay out the level and the player's lines,
// start the animation over, and show the ball at the start. It stays there until
// `drop`, which also draws the ball's trail and lets it fall.
// The game's shape functions are added after the player's code.
fn evaluate_game(
  model: Model,
  clear_on_error: Bool,
  drop: Bool,
) -> #(Model, Effect(Msg)) {
  let level = model.level
  let problem = case game.check_shapes(model.source) {
    Ok(_) -> None
    Error(found) -> Some(found)
  }
  case run_source(game_slider, model.source <> "\n" <> game.prelude) {
    Ok(paths) -> {
      // Red walls cut short any line that reaches them.
      let paths = game.clip(level, paths)
      let run = game.simulate(level, paths)
      #(
        Model(
          ..model,
          error: None,
          problem: problem,
          outcome: Some(run.outcome),
          dropped: drop,
          result_shown: False,
        ),
        effect.from(fn(dispatch) {
          list.flatten([
            game.level_paths(level),
            case drop {
              True -> [game.trail(run)]
              False -> []
            },
            list.map(paths, game.styled),
          ])
          |> render.set_drawing
          // Moving a shape keeps the animation where it is, so it shows at once.
          case drop || option.is_none(model.grab) {
            True -> render.reset_clock()
            False -> Nil
          }
          game.arm_ball(
            run.points,
            game.sample_tenths,
            run.end_time,
            fn() { dispatch(RunEnded) },
            drop,
          )
        }),
      )
    }
    Error(msg) -> #(
      Model(
        ..model,
        error: Some(msg),
        problem: problem,
        dropped: False,
        result_shown: False,
      ),
      case clear_on_error {
        True ->
          effect.from(fn(_) {
            render.set_drawing([])
            render.reset_clock()
            game.disarm_ball()
          })
        False -> effect.none()
      },
    )
  }
}

// ── View ──────────────────────────────────────────────────────────────────
//
// Two side-by-side panes: the code editor on the left and its rendered output on
// the right. The code column can be hidden to expand the right pane.

pub fn view(model: Model) -> Element(Msg) {
  let app_class = case model.code_open, model.game_on {
    True, False -> "app"
    False, False -> "app code-hidden"
    True, True -> "app game"
    False, True -> "app game code-hidden"
  }
  // The code column still exists even when hidden (CSS collapses it) so the
  // mounted CodeMirror editor keeps its state across show/hide.
  html.div([attr.class("shell")], [
    view_top_bar(model),
    html.div([attr.class(app_class)], [
      html.div([attr.class("code-col")], [
        editor.view_panel(ToggleCode, case model.game_on {
          True -> view_toolbox(model)
          False -> view_library(model)
        }),
      ]),
      // Drag this bar to change how wide the code column is.
      html.div(
        [
          attr.class("col-resizer"),
          attr.attribute("title", "Drag to resize"),
          attr.attribute("data-test-id", "col-resizer"),
        ],
        [],
      ),
      view_anim(model),
    ]),
    view_intro(model),
  ])
}

// How to play, shown the first time the game is opened.
fn view_intro(model: Model) -> Element(Msg) {
  case model.show_intro {
    False -> element.none()
    True ->
      html.div([attr.class("intro-backdrop")], [
        html.div(
          [
            attr.class("intro-dialog"),
            attr.attribute("role", "dialog"),
            attr.attribute("aria-modal", "true"),
            attr.attribute("aria-label", "How to play"),
            attr.attribute("data-test-id", "intro-dialog"),
          ],
          [
            html.h2([], [html.text("How to play")]),
            html.p([attr.class("intro-goal")], [
              html.text("Your goal: get the ball into the green bucket."),
            ]),
            html.ol([], [
              html.li([], [
                html.text(
                  "Add shapes from the toolbox. Click one, or drag it onto the level.",
                ),
              ]),
              html.li([], [
                html.text(
                  "Shapes act as ramps and bumpers. Drag them to move them, and use each shape once.",
                ),
              ]),
              html.li([], [
                html.text(
                  "Press Drop ball to release the ball. If it misses, adjust your shapes and try again.",
                ),
              ]),
              html.li([], [
                html.text(
                  "The red walls are solid, so build your path around them.",
                ),
              ]),
            ]),
            html.button(
              [
                attr.class("intro-btn"),
                attr.attribute("data-test-id", "intro-got-it"),
                event.on_click(CloseIntro),
              ],
              [html.text("Got it")],
            ),
          ],
        ),
      ])
  }
}

// The bar across the top: the way into the game and, in it, the way out.
fn view_top_bar(model: Model) -> Element(Msg) {
  html.div([attr.class("top-bar")], [
    html.span([attr.class("brand")], [html.text("Animator")]),
    case model.game_on {
      False ->
        html.button(
          [
            attr.class("play-game"),
            attr.attribute("data-test-id", "play-game"),
            event.on_click(PlayGame),
          ],
          [html.text("▶  Play Game")],
        )
      True ->
        html.div([attr.class("game-status")], [
          html.span([attr.attribute("data-test-id", "game-level")], [
            html.text("Level " <> int.to_string(model.library.game.level)),
          ]),
          html.span([attr.class("best")], [
            html.text("Best " <> int.to_string(model.library.game.highest)),
          ]),
          html.button(
            [
              attr.class(case model.confirm_clear {
                True -> "clear-data armed"
                False -> "clear-data"
              }),
              attr.attribute("data-test-id", "clear-data"),
              event.on_click(ClearData),
              event.on_blur(DisarmClear),
            ],
            [
              html.text(case model.confirm_clear {
                True -> "Are you sure?"
                False -> "Clear data"
              }),
            ],
          ),
          html.button(
            [
              attr.class("exit-game"),
              attr.attribute("data-test-id", "exit-game"),
              event.on_click(ExitGame),
            ],
            [html.text("Exit")],
          ),
        ])
    },
  ])
}

fn view_anim(model: Model) -> Element(Msg) {
  html.div([attr.class("canvas-area")], [
    view_reveal_code(model),
    html.div(
      [
        attr.class("stage"),
        attr.attribute("data-game", case model.game_on {
          True -> "true"
          False -> "false"
        }),
      ],
      [
        html.canvas([attr.id("animation-canvas"), attr.class("canvas")]),
        // The ball, drawn over the animation while the game is on.
        case model.game_on {
          True ->
            html.canvas([attr.id("ball-canvas"), attr.class("ball-canvas")])
          False -> element.none()
        },
        // On the canvas itself, so it can always be reached.
        view_trash_zone(model),
      ],
    ),
    view_error(model),
    view_banner(model),
    view_controls(model),
  ])
}

// Whether the shape a snippet draws is already in the code.
fn shape_in_use(source: String, snippet: String) -> Bool {
  case string.split_once(snippet, "(") {
    Ok(#(name, _)) -> list.contains(game.used_shapes(source), name)
    Error(_) -> False
  }
}

// The trash can in the corner of the level: put a shape down on it to delete it.
fn view_trash_zone(model: Model) -> Element(Msg) {
  case model.game_on {
    False -> element.none()
    True ->
      html.div(
        [
          attr.class(case model.grab {
            Some(_) -> "trash-zone active"
            None -> "trash-zone"
          }),
          attr.attribute("data-test-id", "game-trash"),
          attr.attribute("title", "Drag a shape here to delete it"),
        ],
        [
          svg.svg(
            [
              attr.attribute("viewBox", "0 0 24 24"),
              attr.attribute("width", "26"),
              attr.attribute("height", "26"),
              attr.attribute("fill", "currentColor"),
              attr.attribute("aria-hidden", "true"),
            ],
            [
              svg.path([
                attr.attribute(
                  "d",
                  "M9 3h6l1 2h4v2H4V5h4l1-2zM6 9h12l-1 11H7L6 9zm4 2v7h1.5v-7H10zm2.5 0v7H14v-7h-1.5z",
                ),
              ]),
            ],
          ),
          html.span([attr.class("trash-label")], [html.text("Drop to delete")]),
        ],
      )
  }
}

// The shapes to drag into the code, and how much line is left to draw with.
fn view_toolbox(model: Model) -> Element(Msg) {
  html.div([attr.class("toolbox")], [
    html.p([attr.class("toolbox-note")], [
      html.text("Click or drag a shape onto the level or editor"),
    ]),
    html.div([attr.class("toolbox-grid")], {
      list.map(game.tiles(model.level), fn(tile) {
        let used = shape_in_use(model.source, tile.snippet)
        html.div(
          [
            attr.class(case used {
              True -> "tile used"
              False -> "tile"
            }),
            attr.attribute("draggable", case used {
              True -> "false"
              False -> "true"
            }),
            attr.attribute("data-snippet", tile.snippet),
            attr.attribute("data-test-id", "tile-" <> tile.name),
            attr.attribute("title", case used {
              True -> "Already in the level"
              False -> tile.snippet
            }),
            event.on_click(AddTile(tile.snippet)),
          ],
          [html.text(tile.name)],
        )
      })
    }),
  ])
}

// An alert that stops the ball being dropped, with a few words on what to change.
fn notice(title: String, hint: String) -> Element(Msg) {
  html.div([attr.class("banner missed")], [
    html.strong([], [html.text(title)]),
    html.span([attr.class("banner-sub")], [html.text(hint)]),
  ])
}

// What the player needs to know now: what is wrong with their shapes, the
// Drop ball button once they're ready, or how the run went once it has played out.
fn view_banner(model: Model) -> Element(Msg) {
  case model.game_on, model.problem, model.result_shown, model.outcome {
    False, _, _, _ -> element.none()
    True, Some(#(title, hint)), _, _ -> notice(title, hint)
    True, None, True, Some(game.Cleared) ->
      html.div([attr.class("banner cleared")], [
        html.strong([], [html.text("Cleared!")]),
        html.button(
          [
            attr.class("banner-btn"),
            attr.attribute("data-test-id", "next-level"),
            event.on_click(NextLevel),
          ],
          [html.text("Next level")],
        ),
      ])
    True, None, True, Some(game.Missed(reason)) ->
      html.div([attr.class("banner missed")], [
        html.strong([], [html.text(reason)]),
        html.button(
          [
            attr.class("banner-btn"),
            attr.attribute("data-test-id", "try-again"),
            event.on_click(Reset),
          ],
          [html.text("Try again")],
        ),
      ])
    True, None, _, _ ->
      case model.dropped || model.result_shown {
        True -> element.none()
        False ->
          html.button(
            [
              attr.class("drop-ball"),
              attr.attribute("data-test-id", "drop-ball"),
              event.on_click(DropBall),
            ],
            [html.text("Drop ball")],
          )
      }
  }
}

// The drawing picker above the code: every saved drawing, then "+ New drawing".
// Cancelling the new-drawing prompt bumps select_version, which gives the select
// a new key so it is rebuilt showing the open drawing again.
fn view_library(model: Model) -> Element(Msg) {
  let option = fn(name: String, value: String) {
    html.option(
      [attr.value(value), attr.selected(name == model.library.selected)],
      name,
    )
  }
  keyed.div([attr.class("library")], [
    #(
      int.to_string(model.select_version),
      html.select(
        [
          attr.class("library-select"),
          attr.attribute("data-test-id", "drawing-select"),
          event.on_change(SelectDrawing),
        ],
        list.append(
          list.map(model.library.drawings, fn(d) { option(d.0, d.0) }),
          [html.option([attr.value("")], "+ New drawing")],
        ),
      ),
    ),
    ..case is_example(model.library.selected) {
      True -> []
      False -> [#("trash", view_trash(model.confirm_delete))]
    }
  ])
}

// The trash button, shown for drawings that aren't examples. The first click arms
// it (it turns red); the second deletes the drawing.
fn view_trash(armed: Bool) -> Element(Msg) {
  html.button(
    [
      attr.class(case armed {
        True -> "icon-btn trash armed"
        False -> "icon-btn trash"
      }),
      attr.attribute("data-test-id", "delete-drawing"),
      attr.attribute("title", case armed {
        True -> "Click again to delete this drawing"
        False -> "Delete this drawing"
      }),
      attr.attribute("aria-label", "Delete this drawing"),
      event.on_click(DeleteDrawing),
    ],
    [
      case armed {
        True -> html.text("Delete?")
        False ->
          icon([
            svg.path([
              attr.attribute(
                "d",
                "M9 3h6l1 2h4v2H4V5h4l1-2zM6 9h12l-1 11H7L6 9zm4 2v7h1.5v-7H10zm2.5 0v7H14v-7h-1.5z",
              ),
            ]),
          ])
      },
    ],
  )
}

// A 24x24 icon drawn in the current text colour.
fn icon(shapes: List(Element(Msg))) -> Element(Msg) {
  svg.svg(
    [
      attr.attribute("viewBox", "0 0 24 24"),
      attr.attribute("width", "16"),
      attr.attribute("height", "16"),
      attr.attribute("fill", "currentColor"),
      attr.attribute("aria-hidden", "true"),
    ],
    shapes,
  )
}

fn view_controls(model: Model) -> Element(Msg) {
  let buttons =
    html.div([attr.class("control-buttons")], [
      case model.playing {
        True -> control_button("Pause", Pause, pause_icon())
        False -> control_button("Play", Play, play_icon())
      },
      control_button("Reset", Reset, reset_icon()),
    ])
  let shape_slider =
    slider(
      "Shape",
      "shape-slider",
      "0",
      "100",
      "1",
      int.to_string(model.shape_slider),
      fn(v) {
        case int.parse(v) {
          Ok(n) -> SetShape(n)
          Error(_) -> SetShape(model.shape_slider)
        }
      },
    )
  let speed_slider =
    slider(
      "Speed",
      "speed-slider",
      "-3",
      "3",
      "0.1",
      float.to_string(model.speed),
      fn(v) {
        case float.parse(v), int.parse(v) {
          Ok(f), _ -> SetSpeed(f)
          _, Ok(n) -> SetSpeed(int.to_float(n))
          _, _ -> SetSpeed(model.speed)
        }
      },
    )
  html.div([attr.class("controls")], case model.game_on {
    // The game runs at its own speed and doesn't use the shape slider.
    True -> [buttons]
    False -> [buttons, shape_slider, speed_slider]
  })
}

// An icon-only button; label is its tooltip and screen-reader name.
fn control_button(
  label: String,
  msg: Msg,
  symbol: Element(Msg),
) -> Element(Msg) {
  html.button(
    [
      attr.class("ctl-btn"),
      attr.attribute("title", label),
      attr.attribute("aria-label", label),
      event.on_click(msg),
    ],
    [symbol],
  )
}

fn play_icon() -> Element(Msg) {
  icon([svg.path([attr.attribute("d", "M8 5v14l11-7z")])])
}

fn pause_icon() -> Element(Msg) {
  icon([svg.path([attr.attribute("d", "M6 5h4v14H6zM14 5h4v14h-4z")])])
}

fn reset_icon() -> Element(Msg) {
  icon([
    svg.path([
      attr.attribute("d", "M12 5V1L7 6l5 5V7a5 5 0 1 1-5 5H5a7 7 0 1 0 7-7z"),
    ]),
  ])
}

fn slider(
  label: String,
  test_id: String,
  min: String,
  max: String,
  step: String,
  value: String,
  on_change: fn(String) -> Msg,
) -> Element(Msg) {
  html.label([attr.class("slider")], [
    html.span([], [html.text(label)]),
    html.input([
      attr.type_("range"),
      attr.attribute("data-test-id", test_id),
      attr.min(min),
      attr.max(max),
      attr.step(step),
      attr.value(value),
      event.on_input(on_change),
    ]),
    html.output([], [html.text(value)]),
  ])
}

// A small dialog over the animation area describing the current error.
fn view_error(model: Model) -> Element(Msg) {
  case model.error {
    None -> element.none()
    Some(msg) ->
      html.div(
        [
          attr.class("error-dialog"),
          attr.attribute("role", "alert"),
        ],
        [
          html.div([attr.class("error-body")], [
            html.strong([], [html.text("Something went wrong")]),
            html.p([], [html.text(msg)]),
          ]),
          html.button(
            [
              attr.class("error-close"),
              attr.attribute("title", "Dismiss"),
              event.on_click(DismissError),
            ],
            [html.text("×")],
          ),
        ],
      )
  }
}

// The button that brings the code column back, overlaid on the top-left of the
// right pane. Nothing is rendered while the column is already showing (its own
// header holds the button that hides it).
fn view_reveal_code(model: Model) -> Element(Msg) {
  case model.code_open {
    True -> element.none()
    False ->
      html.button(
        [
          attr.class("icon-btn reveal-code"),
          attr.attribute("title", "Show code"),
          event.on_click(ToggleCode),
        ],
        [html.text("⟩")],
      )
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
