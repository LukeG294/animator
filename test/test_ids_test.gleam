//// Checks that the app has the elements that Gradescope's tests look for, so that
//// a submission can be scored. They check nothing about how those elements behave:
//// the tests that earn points for Problems 9 to 11 run only on Gradescope.
////
//// lustre/dev/simulate renders the app without a browser and never runs its
//// Effects. These tests only need app to have public init, update, and view
//// functions, so they don't depend on how the Model or Msg types are designed.

import app
import lustre/dev/query
import lustre/dev/simulate

fn assert_rendered(selector: query.Selector, message: String) -> Nil {
  let sim =
    simulate.start(simulate.application(app.init, app.update, app.view), Nil)
  case
    query.find(
      in: simulate.view(sim),
      matching: query.element(matching: selector),
    )
  {
    Ok(_) -> Nil
    Error(Nil) -> panic as message
  }
}

// Problem 9

pub fn canvas_id_test() {
  assert_rendered(
    query.and(query.tag("canvas"), query.id("animation-canvas")),
    "When the app opens, there is no <canvas id=\"animation-canvas\"> element. Add one to the view, using attr.id(\"animation-canvas\").",
  )
}

pub fn code_editor_id_test() {
  assert_rendered(
    query.id("code-editor"),
    "When the app opens, no element has the id \"code-editor\", which editor.view_panel provides. Keep it in the view.",
  )
}

// Problem 10

pub fn shape_slider_id_test() {
  assert_rendered(
    query.test_id("shape-slider"),
    "When the app opens, no element has data-test-id=\"shape-slider\". Tag the slider that sets shape_slider with attr.attribute(\"data-test-id\", \"shape-slider\"), and keep it in the view.",
  )
}

pub fn speed_slider_id_test() {
  assert_rendered(
    query.test_id("speed-slider"),
    "When the app opens, no element has data-test-id=\"speed-slider\". Tag the speed slider with attr.attribute(\"data-test-id\", \"speed-slider\"), and keep it in the view.",
  )
}

// Problem 11

pub fn drawing_select_id_test() {
  assert_rendered(
    query.and(query.tag("select"), query.test_id("drawing-select")),
    "When the app opens, there is no <select> with data-test-id=\"drawing-select\". Tag the drop-down menu with attr.attribute(\"data-test-id\", \"drawing-select\").",
  )
}
