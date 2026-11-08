//// The draw-function code pane: the CodeMirror FFI glue and the side-by-side
//// panel view. app wires the editor's messages through the generic msg-typed
//// helpers here, so this module never depends back on app.

import gleam/list
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// ── CodeMirror FFI ──────────────────────────────────────────────────────────

@external(javascript, "./editor_ffi.mjs", "mountEditor")
fn do_mount(text: String, on_change: fn(String) -> Nil) -> Nil

/// Mount a CodeMirror editor showing text, routing every edit through on_change.
/// Mounting tears down any previous editor itself, so re-mounting just calls this
/// again — there is no separate unmount.
/// Mounting an editor doesn't change the animation. To animate the text in a
/// new editor, the caller has to update the animation too.
pub fn mount(text: String, on_change: fn(String) -> msg) -> Effect(msg) {
  effect.from(fn(dispatch) { do_mount(text, fn(t) { dispatch(on_change(t)) }) })
}

// ── View ──────────────────────────────────────────────────────────────────────

/// The code panel that sits beside the drawing: the live editor and a reference
/// of the built-in inputs and functions. The latest code that runs is rendered
/// continuously, so there is no explicit apply step.
pub fn view_panel(on_collapse: msg, toolbar: Element(msg)) -> Element(msg) {
  html.div([attr.class("code-panel")], [
    html.div([attr.class("code-header")], [
      html.span([attr.class("code-title")], [html.text("draw code")]),
      html.button(
        [
          attr.class("icon-btn"),
          attr.attribute("title", "Hide code"),
          event.on_click(on_collapse),
        ],
        [html.text("⟨")],
      ),
    ]),
    toolbar,
    // The editor fills this wrapper.
    html.div([attr.class("code-editor-wrap")], [
      // CodeMirror mounts into this node (see mount). It is rendered as
      // unsafe_raw_html with constant empty content so Lustre never
      // re-patches it and the editor DOM survives re-renders.
      element.unsafe_raw_html(
        "",
        "div",
        [attr.id("code-editor"), attr.class("code-editor")],
        "",
      ),
    ]),
    view_reference_panel(),
  ])
}

// ── Built-in reference ──────────────────────────────────────────────────────

// One entry in the reference panel: a signature (monospace) and a plain-English
// description.
type RefEntry {
  RefEntry(signature: String, description: String)
}

fn inputs() -> List(RefEntry) {
  [
    RefEntry("shape_slider: Int", "the shape slider value, in [0, 100]"),
  ]
}

fn functions() -> List(RefEntry) {
  [
    RefEntry("random(min: Int, max: Int) -> Int", "a random int in [min, max)"),
    RefEntry("abs(n: Int) -> Int", "the absolute value of `n`"),
    RefEntry(
      "Point(x: Int, y: Int)",
      "a point on the canvas: (0, 0) is the center, x and y run from -500 to 500, and y grows downward",
    ),
    RefEntry("Line(start: Point, end: Point)", "a straight-line shape"),
    RefEntry(
      "Path(shape, start: Int, end: Int, thickness: Int)",
      "draws a shape between times `start` and `end`, in 1/10 s (end <= start draws it instantly)",
    ),
  ]
}

// The gleam/list functions the language supports, under their real names. A
// fn(...) below is any function: a fn(x) { ... } written on the spot, a
// helper's name, or a capture like add(1, _).
fn list_functions() -> List(RefEntry) {
  [
    RefEntry(
      "list.map(list, fn(a) -> b) -> List(b)",
      "each element through `fn`",
    ),
    RefEntry(
      "list.filter(list, fn(a) -> Bool) -> List(a)",
      "only the elements `fn` says True to",
    ),
    RefEntry("list.append(list, list) -> List(a)", "one list after the other"),
    RefEntry("list.length(list) -> Int", "the number of elements"),
    RefEntry(
      "list.flatten(List(List(a))) -> List(a)",
      "the inner lists, end to end",
    ),
  ]
}

// A collapsible panel of the inputs and built-ins available to draw, with
// their types/signatures. Uses native <details>/<summary> so it needs no model
// state, and starts collapsed to leave more room for the editor.
fn view_reference_panel() -> Element(msg) {
  html.details([attr.class("reference")], [
    html.summary([attr.class("reference-summary")], [
      html.text("Built-ins"),
    ]),
    html.div([attr.class("reference-body")], [
      ref_group("Inputs", inputs()),
      ref_group("Functions", functions()),
      ref_group("Lists", list_functions()),
    ]),
  ])
}

fn ref_group(title: String, entries: List(RefEntry)) -> Element(msg) {
  html.div([attr.class("reference-group")], [
    html.div([attr.class("reference-group-title")], [html.text(title)]),
    html.div(
      [attr.class("reference-rows")],
      list.map(entries, fn(e) {
        html.div([attr.class("reference-row")], [
          html.code([attr.class("reference-sig")], [
            html.text(e.signature),
          ]),
          html.span([attr.class("reference-desc")], [
            html.text(e.description),
          ]),
        ])
      }),
    ),
  ])
}
