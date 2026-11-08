// A mutable dictionary (see mutable_dict.gleam): a JavaScript Map. Updating
// it in place is what lets the global frame contain functions whose env is
// the frame itself, so it is written in JavaScript.

import { Ok, Error } from "./gleam.mjs";

export function newDict() {
  return new Map();
}

export function get(dict, key) {
  return dict.has(key) ? new Ok(dict.get(key)) : new Error(undefined);
}

export function insert(dict, key, value) {
  dict.set(key, value);
}
