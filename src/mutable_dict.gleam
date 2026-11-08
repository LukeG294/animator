//// A mutable dictionary: a JavaScript Map, which Gleam updates in place
//// rather than copying. The evaluator's global frame is one.
////
//// Keys are compared as a Map compares them: strings and numbers by value,
//// but records and lists by reference.

pub type MutableDict(k, v)

/// A new, empty dictionary.
@external(javascript, "./mutable_dict_ffi.mjs", "newDict")
pub fn new() -> MutableDict(k, v)

/// The value for key, or Error(Nil) if the dictionary has none.
@external(javascript, "./mutable_dict_ffi.mjs", "get")
pub fn get(dict: MutableDict(k, v), key: k) -> Result(v, Nil)

/// Bind key to value, replacing any value it had.
@external(javascript, "./mutable_dict_ffi.mjs", "insert")
pub fn insert(dict: MutableDict(k, v), key: k, value: v) -> Nil
