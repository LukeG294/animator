//// `gleam dev` serves the app at http://localhost:8000 (or `gleam dev 8001` for
//// another port) and rebuilds it whenever a source file changes. `gleam dev
//// publish` instead puts the files to deploy in public/. The work is in
//// animator_dev_ffi.mjs.

const default_port = 8000

@external(javascript, "./animator_dev_ffi.mjs", "start")
fn start(default_port: Int) -> Nil

pub fn main() -> Nil {
  start(default_port)
}
