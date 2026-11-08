//// The library of saved drawings. A drawing is a name and the source of its draw
//// function.

// ── localStorage (data_ffi.mjs) ───────────────────────────────────────────────

/// The string stored in localStorage under key, or an Error if there isn't one.
@external(javascript, "./data_ffi.mjs", "storageGet")
pub fn storage_get(key: String) -> Result(String, Nil)

/// Store value in localStorage under key, replacing anything already there. If that
/// isn't possible, this logs the reason to the browser console.
@external(javascript, "./data_ffi.mjs", "storageSet")
pub fn storage_set(key: String, value: String) -> Nil

// ── The new-drawing prompt (data_ffi.mjs) ─────────────────────────────────────

/// Prompt the user to name a new drawing; "" (empty string) means they
/// cancelled or left it blank.
@external(javascript, "./data_ffi.mjs", "promptDrawingName")
pub fn prompt_drawing_name() -> String

// ── The saved library ─────────────────────────────────────────────────────────

import examples
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list

// All saved data lives in localStorage under this single key, as JSON.
const storage_key = "animator"

/// Every drawing, as #(name, source) in menu order, and the name of the one that
/// is open, plus the state of the game.
pub type Library {
  Library(drawings: List(#(String, String)), selected: String, game: GameState)
}

/// Progress in the game: the level being played, the highest level reached, the
/// code written for the current level ("" until the player writes some), and
/// whether the player has been shown how to play.
pub type GameState {
  GameState(level: Int, highest: Int, code: String, intro_seen: Bool)
}

/// The game state of a new player.
pub const new_game = GameState(level: 1, highest: 1, code: "", intro_seen: False)

/// The library saved in localStorage. If nothing usable is stored, it is the
/// examples, with the first one open. A remembered drawing that no longer
/// exists is replaced by the first drawing.
pub fn load() -> Library {
  let stored = case storage_get(storage_key) {
    Ok(text) -> json.parse(text, library_decoder())
    Error(_) -> Error(json.UnexpectedEndOfInput)
  }
  case stored {
    Ok(Library(drawings: [first, ..], selected: selected, ..) as library) ->
      case list.key_find(library.drawings, selected) {
        Ok(_) -> library
        Error(_) -> Library(..library, selected: first.0)
      }
    _ -> examples_library()
  }
}

fn examples_library() -> Library {
  case examples.all {
    [first, ..] -> Library(examples.all, first.0, new_game)
    [] -> Library([], "", new_game)
  }
}

/// Store the whole library in localStorage.
pub fn save(library: Library) -> Nil {
  let drawing = fn(d: #(String, String)) {
    json.object([#("name", json.string(d.0)), #("source", json.string(d.1))])
  }
  json.object([
    #("drawings", json.array(library.drawings, drawing)),
    #("selected", json.string(library.selected)),
    #(
      "game",
      json.object([
        #("level", json.int(library.game.level)),
        #("highest", json.int(library.game.highest)),
        #("code", json.string(library.game.code)),
        #("intro_seen", json.bool(library.game.intro_seen)),
      ]),
    ),
  ])
  |> json.to_string
  |> storage_set(storage_key, _)
}

fn library_decoder() -> decode.Decoder(Library) {
  let drawing = {
    use name <- decode.field("name", decode.string)
    use source <- decode.field("source", decode.string)
    decode.success(#(name, source))
  }
  use drawings <- decode.field("drawings", decode.list(drawing))
  use selected <- decode.field("selected", decode.string)
  // Libraries saved before the game existed have no game state.
  let game = {
    use level <- decode.field("level", decode.int)
    use highest <- decode.field("highest", decode.int)
    use code <- decode.field("code", decode.string)
    // Saves from before the how-to-play dialog existed count as having seen it.
    use intro_seen <- decode.optional_field("intro_seen", True, decode.bool)
    decode.success(GameState(level, highest, code, intro_seen))
  }
  use game <- decode.optional_field("game", new_game, game)
  decode.success(Library(drawings, selected, game))
}

/// The source of the drawing called name, if there is one.
pub fn find(library: Library, name: String) -> Result(String, Nil) {
  list.key_find(library.drawings, name)
}

/// Add a drawing, or replace the source of the one with that name (keeping its
/// place in the menu).
pub fn put(library: Library, name: String, source: String) -> Library {
  case find(library, name) {
    Ok(_) ->
      Library(
        ..library,
        drawings: list.map(library.drawings, fn(d) {
          case d.0 == name {
            True -> #(name, source)
            False -> d
          }
        }),
      )
    Error(_) ->
      Library(
        ..library,
        drawings: list.append(library.drawings, [#(name, source)]),
      )
  }
}

/// name, or name with " 2", " 3", ... added if a drawing already has it.
pub fn unique_name(library: Library, name: String) -> String {
  unique_name_from(library, name, name, 2)
}

fn unique_name_from(
  library: Library,
  candidate: String,
  base: String,
  n: Int,
) -> String {
  case find(library, candidate) {
    Error(_) -> candidate
    Ok(_) ->
      unique_name_from(library, base <> " " <> int.to_string(n), base, n + 1)
  }
}

/// The library without the drawing called name. If that was the open one, the
/// first remaining drawing becomes the open one.
pub fn remove(library: Library, name: String) -> Library {
  let drawings = list.filter(library.drawings, fn(d) { d.0 != name })
  case drawings {
    [first, ..] if library.selected == name ->
      Library(..library, drawings: drawings, selected: first.0)
    _ -> Library(..library, drawings: drawings)
  }
}
