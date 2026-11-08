//// Gleam-callable wrappers around grading/*/autograder.mjs, so `gleam test`
//// (and `gleam test -- q13`/`q14`) run them alongside the other tests. See
//// autograders_ffi.mjs for how.
////
//// These checks use the network, so they are grader.untimed_check entries in
//// animator_test.gleam.

import app

@external(javascript, "./autograders_ffi.mjs", "run_deployment_autograder")
fn run_deployment_autograder(url: String) -> Nil

pub fn deployment_autograder_test() -> Nil {
  run_deployment_autograder(app.public_url)
}

@external(javascript, "./autograders_ffi.mjs", "run_video_autograder")
fn run_video_autograder(url: String) -> Nil

pub fn video_autograder_test() -> Nil {
  run_video_autograder(app.video_url)
}
