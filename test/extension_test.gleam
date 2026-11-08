//// Checks that extension.txt has been filled in, for Problem 12. It only counts
//// characters, so it's worth no points: your extension earns them.

import gleam/int
import gleam/string

const stub = "Describe your extension(s) here before implementing them."

const min_characters = 400

@external(javascript, "./extension_ffi.mjs", "read_description")
fn read_description() -> String

pub fn description_test() -> Nil {
  let description =
    read_description() |> string.replace(stub, "") |> string.trim
  let length = string.length(description)
  case length >= min_characters {
    True -> Nil
    False ->
      panic as {
        "extension.txt has "
        <> int.to_string(length)
        <> " characters of description, but Problem 12 asks for at least "
        <> int.to_string(min_characters)
        <> ". Describe your extension(s) there before implementing them."
      }
  }
}
