// The browser side of the game: the ball drawn over the animation, a watcher that
// says when its run has finished, and dragging shapes from the toolbox into the
// code editor.

import { getClock } from "./canvas.mjs";

// ── CodeMirror (the same copies editor_ffi.mjs loads) ─────────────────────────

let loaded = null;
function modules() {
  if (!loaded) {
    loaded = Promise.all([
      import("https://esm.sh/@codemirror/view@6"),
      import("https://esm.sh/@codemirror/state@6"),
    ]).then(([view, state]) => ({ view, state }));
  }
  return loaded;
}

// The editor's current view, if it has been created.
async function currentView() {
  const { view: { EditorView } } = await modules();
  const dom = document.querySelector(".cm-editor");
  return dom ? EditorView.findFromDOM(dom) : null;
}

// ── The ball ──────────────────────────────────────────────────────────────────

// { pts: Float64Array [x0, y0, x1, y1, ...], interval, endTime, onEnd, dropped, fired }
let ball = null;
let looping = false;

// Show a ball. Until `dropped`, it waits at the start. After that it follows
// `pointList` (one point every `interval` tenths of a second) as the animation's
// clock advances, and `onEnd` is called once, when the clock reaches `endTime`.
// Replaces any earlier ball.
export function armBall(pointList, interval, endTime, onEnd, dropped) {
  const flat = [];
  for (const v of pointList) flat.push(v);
  ball = { pts: Float64Array.from(flat), interval, endTime, onEnd, dropped, fired: false };
  if (!looping) {
    looping = true;
    requestAnimationFrame(frame);
  }
}

export function disarmBall() {
  ball = null;
  const canvas = document.getElementById("ball-canvas");
  if (canvas) canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
}

function frame() {
  requestAnimationFrame(frame);
  const canvas = document.getElementById("ball-canvas");
  if (!canvas || !ball) return;
  // Match the backing store to the element's size, like canvas.mjs does.
  const dpr = window.devicePixelRatio || 1;
  const w = Math.round(canvas.clientWidth * dpr);
  const h = Math.round(canvas.clientHeight * dpr);
  if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
    canvas.width = w;
    canvas.height = h;
  }
  // Waiting to be dropped, the ball sits at the start (time 0).
  const clock = ball.dropped ? getClock() : 0;
  if (ball.dropped && !ball.fired && clock >= ball.endTime) {
    ball.fired = true;
    ball.onEnd();
  }
  const count = ball.pts.length / 2;
  if (count === 0) return;
  // Where the ball is now: between the two recorded points around the clock.
  const index = Math.min(Math.max(clock / ball.interval, 0), count - 1);
  const i = Math.floor(index);
  const j = Math.min(i + 1, count - 1);
  const f = index - i;
  const x = ball.pts[2 * i] + (ball.pts[2 * j] - ball.pts[2 * i]) * f;
  const y = ball.pts[2 * i + 1] + (ball.pts[2 * j + 1] - ball.pts[2 * i + 1]) * f;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(canvas.width / 1000, 0, 0, canvas.height / 1000, canvas.width / 2, canvas.height / 2);
  ctx.beginPath();
  ctx.arc(x, y, 14, 0, Math.PI * 2);
  ctx.fillStyle = "#ffd166";
  ctx.shadowColor = "rgba(255, 209, 102, 0.8)";
  ctx.shadowBlur = 18;
  ctx.fill();
}

// ── Dragging shapes into the editor ───────────────────────────────────────────

const SNIPPET = "application/x-animator-snippet";
let installed = false;

// Let any element with a data-snippet attribute be dragged into the code editor,
// where dropping it adds its code as a new line in the shape list, or onto the
// level, where `onDrop(snippet, x, y)` is called with the canvas position (in
// canvas units, a 1000-wide world centred on the origin, y down).
export function installToolbox(onDrop) {
  if (installed) return;
  installed = true;
  document.addEventListener("dragstart", (e) => {
    const tile = e.target.closest ? e.target.closest("[data-snippet]") : null;
    if (!tile) return;
    e.dataTransfer.setData(SNIPPET, tile.dataset.snippet);
    e.dataTransfer.setData("text/plain", tile.dataset.snippet);
    e.dataTransfer.effectAllowed = "copy";
  });
  document.addEventListener(
    "dragover",
    (e) => {
      const stage = snippetStage(e);
      document.querySelectorAll(".stage.drop-target").forEach((s) => {
        if (s !== stage) s.classList.remove("drop-target");
      });
      if (stage) stage.classList.add("drop-target");
      if (stage || isSnippetOverEditor(e)) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
      }
    },
    true,
  );
  document.addEventListener("dragleave", (e) => {
    if (!e.relatedTarget) {
      document.querySelectorAll(".stage.drop-target").forEach((s) => s.classList.remove("drop-target"));
    }
  });
  document.addEventListener(
    "drop",
    (e) => {
      document.querySelectorAll(".stage.drop-target").forEach((s) => s.classList.remove("drop-target"));
      const stage = snippetStage(e);
      if (stage) {
        e.preventDefault();
        e.stopPropagation();
        const rect = stage.getBoundingClientRect();
        onDrop(
          e.dataTransfer.getData(SNIPPET),
          ((e.clientX - rect.left) / rect.width) * 1000 - 500,
          ((e.clientY - rect.top) / rect.height) * 1000 - 500,
        );
        return;
      }
      if (!isSnippetOverEditor(e)) return;
      // Handle the drop ourselves, so CodeMirror doesn't also insert the text.
      e.preventDefault();
      e.stopPropagation();
      insertSnippet(e.dataTransfer.getData(SNIPPET), e.clientX, e.clientY);
    },
    true,
  );
}

function hasSnippet(e) {
  return e.dataTransfer && Array.from(e.dataTransfer.types).includes(SNIPPET);
}

// The game's canvas, if a toolbox tile is being dragged over it.
function snippetStage(e) {
  if (!hasSnippet(e) || !e.target.closest) return null;
  const stage = e.target.closest(".stage");
  return stage && stage.dataset.game === "true" ? stage : null;
}

function isSnippetOverEditor(e) {
  return hasSnippet(e) && e.target.closest && e.target.closest(".cm-editor");
}

// Add the snippet as its own line in the shape list, at the line it was dropped on
// (kept inside the list). If the code isn't in the expected shape, insert it where
// it was dropped.
async function insertSnippet(snippet, x, y) {
  const { view: { EditorView } } = await modules();
  const dom = document.querySelector(".cm-editor");
  const view = dom ? EditorView.findFromDOM(dom) : null;
  if (!view || !snippet) return;
  const doc = view.state.doc;
  // A shape can only be used once: if the code already has one, add nothing.
  const name = snippet.split("(")[0].trim();
  for (let n = 1; n <= doc.lines; n++) {
    if (new RegExp("^\\s*" + name + "\\(").test(doc.line(n).text)) return;
  }
  // Without coordinates (a click), the snippet goes at the end of the list.
  const pos =
    x === undefined ? doc.length : (view.posAtCoords({ x, y }) ?? doc.length);
  let open = -1;
  let close = -1;
  for (let n = 1; n <= doc.lines; n++) {
    const text = doc.line(n).text.trim();
    if (open < 0 && text.endsWith("list.flatten([")) open = n;
    else if (open > 0 && text === "])") {
      close = n;
      break;
    }
  }
  if (open > 0 && close > 0) {
    const line =
      x === undefined
        ? close
        : Math.min(Math.max(doc.lineAt(pos).number, open + 1), close);
    const at = doc.line(line).from;
    view.dispatch({ changes: { from: at, insert: "    " + snippet + ",\n" } });
  } else {
    view.dispatch({ changes: { from: pos, insert: snippet } });
  }
  view.focus();
}

// Add the snippet as the last line of the shape list in the editor.
export function addSnippet(snippet) {
  insertSnippet(snippet);
}

// ── Moving shapes on the canvas ───────────────────────────────────────────────

let dragInstalled = false;

// Report the pointer going down on the game's canvas, moving, and coming up, in
// canvas units (a 1000-wide world centred on the origin, y down). When it comes up,
// `onEnd` is told whether it was over the trash can.
export function installDrag(onStart, onMove, onEnd) {
  if (dragInstalled) return;
  dragInstalled = true;
  let stage = null;
  const world = (e) => {
    // Kept inside the canvas, so a shape can't be carried out of reach.
    const rect = stage.getBoundingClientRect();
    const clamp = (v) => Math.min(500, Math.max(-500, v));
    return [
      clamp(((e.clientX - rect.left) / rect.width) * 1000 - 500),
      clamp(((e.clientY - rect.top) / rect.height) * 1000 - 500),
    ];
  };
  // The trash can doesn't catch the pointer (so it never hides a shape), so find out
  // from its box whether the pointer is over it.
  const overTrash = (e) => {
    const trash = document.querySelector(".trash-zone");
    if (!trash) return false;
    const r = trash.getBoundingClientRect();
    return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
  };
  document.addEventListener("pointerdown", (e) => {
    const target = e.target.closest ? e.target.closest(".stage") : null;
    if (!target || target.dataset.game !== "true" || e.button !== 0) return;
    stage = target;
    stage.classList.add("dragging");
    e.preventDefault();
    const [x, y] = world(e);
    onStart(x, y);
  });
  document.addEventListener("pointermove", (e) => {
    if (!stage) return;
    // Light the trash can up while the shape is over it.
    const trash = document.querySelector(".trash-zone");
    if (trash) trash.classList.toggle("over", overTrash(e));
    const [x, y] = world(e);
    onMove(x, y);
  });
  const finish = (e, cancelled) => {
    if (!stage) return;
    stage.classList.remove("dragging");
    stage = null;
    const trash = document.querySelector(".trash-zone");
    if (trash) trash.classList.remove("over");
    onEnd(!cancelled && overTrash(e));
  };
  document.addEventListener("pointerup", (e) => finish(e, false));
  document.addEventListener("pointercancel", (e) => finish(e, true));
}

// Delete line number `line` (from 1) of the editor, including its line break.
export async function deleteLine(line) {
  const view = await currentView();
  if (!view || line < 1 || line > view.state.doc.lines) return;
  const doc = view.state.doc;
  const { from, to } = doc.line(line);
  // The break after the line, or, for the last line, the one before it.
  const start = to < doc.length ? from : Math.max(from - 1, 0);
  const end = to < doc.length ? to + 1 : to;
  view.dispatch({ changes: { from: start, to: end } });
}

// Replace line number `line` (from 1) of the editor with `text`.
export async function replaceLine(line, text) {
  const view = await currentView();
  if (!view || line < 1 || line > view.state.doc.lines) return;
  const { from, to } = view.state.doc.line(line);
  view.dispatch({ changes: { from, to, insert: text } });
}

// ── Hints for the numbers in a shape's call ───────────────────────────────────

// What each number means, for each shape the toolbox adds.
const LABELS = {
  line: ["x1", "y1", "x2", "y2", "start"],
  slide: ["x", "y", "size", "start"],
  funnel: ["x", "y", "width", "start"],
  backstop: ["x", "y", "height", "start"],
  kicker: ["x", "y", "width", "start"],
  chute: ["x", "y", "height", "start"],
  bowl: ["x", "y", "width", "start"],
  arc: ["x", "y", "radius", "start"],
  stairs: ["x", "y", "step", "start"],
  zigzag: ["x", "y", "width", "start"],
  bounce: ["x", "y", "width", "tilt", "start"],
  boost: ["x1", "y1", "x2", "y2", "start"],
  brake: ["x", "y", "width", "start"],
  magnet: ["x", "y", "size", "start"],
  lift: ["x", "y", "height", "start"],
};

let hintsOn = false;
let hintsLooping = false;
const hinted = new WeakSet();

// While hints are on, every editor that appears gets small labels in front of each
// number of a shape's call. They are only decorations: the text is not changed.
export function setHints(on) {
  hintsOn = on;
  if (on && !hintsLooping) {
    hintsLooping = true;
    addHintsLoop();
  }
}

async function addHintsLoop() {
  const { view: viewModule, state } = await modules();
  const extension = hintExtension(viewModule, state);
  const tick = () => {
    requestAnimationFrame(tick);
    if (!hintsOn) return;
    const dom = document.querySelector(".cm-editor");
    const view = dom ? viewModule.EditorView.findFromDOM(dom) : null;
    if (view && !hinted.has(view)) {
      hinted.add(view);
      view.dispatch({ effects: state.StateEffect.appendConfig.of(extension) });
    }
  };
  tick();
}

function hintExtension({ Decoration, ViewPlugin, WidgetType, EditorView }) {
  class Hint extends WidgetType {
    constructor(label) {
      super();
      this.label = label;
    }
    eq(other) {
      return other.label === this.label;
    }
    toDOM() {
      const span = document.createElement("span");
      span.className = "cm-arg-hint";
      span.textContent = this.label;
      span.setAttribute("aria-hidden", "true");
      return span;
    }
    // Let the editor handle clicks and drags that start on a label, so the text
    // can be selected and edited as if the labels weren't there.
    ignoreEvent() {
      return false;
    }
  }
  // A label in front of each argument of each shape call.
  function build(view) {
    const marks = [];
    const doc = view.state.doc;
    for (let n = 1; n <= doc.lines; n++) {
      const line = doc.line(n);
      const match = /^\s*([a-z_]+)\(/.exec(line.text);
      const labels = match ? LABELS[match[1]] : null;
      if (!labels) continue;
      let depth = 0;
      let index = 0;
      let atStart = true;
      for (let i = match[0].length; i < line.text.length; i++) {
        const ch = line.text[i];
        if (atStart && ch !== " ") {
          if (index < labels.length) {
            marks.push(Decoration.widget({ widget: new Hint(labels[index]), side: -1 }).range(line.from + i));
          }
          atStart = false;
        }
        if (ch === "(") depth++;
        else if (ch === ")") {
          if (depth === 0) break;
          depth--;
        } else if (ch === "," && depth === 0) {
          index++;
          atStart = true;
        }
      }
    }
    return Decoration.set(marks, true);
  }
  const plugin = ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = build(view);
      }
      update(update) {
        if (update.docChanged) this.decorations = build(update.view);
      }
    },
    { decorations: (value) => value.decorations },
  );
  const theme = EditorView.baseTheme({
    ".cm-arg-hint": {
      color: "#7d8bbd",
      fontSize: "10px",
      fontFamily: "system-ui, sans-serif",
      marginRight: "4px",
      userSelect: "none",
      pointerEvents: "none",
    },
    ".cm-selectionMatch": { background: "#3a4a8a66" },
  });
  return [plugin, theme];
}

// ── The width of the code column ──────────────────────────────────────────────

const WIDTH_KEY = "animator.codeWidth";
const MIN_CODE_WIDTH = 340;
let resizerInstalled = false;

// Let the bar between the code column and the level (.col-resizer) be dragged to
// change how wide the code column is. The width is kept for next time.
export function installResizer() {
  if (resizerInstalled) return;
  resizerInstalled = true;
  const root = document.documentElement;
  try {
    const saved = localStorage.getItem(WIDTH_KEY);
    if (saved) root.style.setProperty("--code-width", saved + "px");
  } catch {
    // Storage blocked: the column just starts at its usual width.
  }
  let handle = null;
  document.addEventListener("pointerdown", (e) => {
    const target = e.target.closest ? e.target.closest(".col-resizer") : null;
    if (!target || e.button !== 0) return;
    handle = target;
    handle.classList.add("dragging");
    document.body.style.userSelect = "none";
    e.preventDefault();
  });
  document.addEventListener("pointermove", (e) => {
    if (!handle) return;
    const app = document.querySelector(".app");
    if (!app) return;
    const width = e.clientX - app.getBoundingClientRect().left;
    // Never so narrow that the toolbox's last column is cut off.
    const clamped = Math.min(Math.max(width, MIN_CODE_WIDTH), window.innerWidth * 0.7);
    root.style.setProperty("--code-width", clamped + "px");
  });
  const finish = () => {
    if (!handle) return;
    handle.classList.remove("dragging");
    handle = null;
    document.body.style.userSelect = "";
    const column = document.querySelector(".code-col");
    if (!column) return;
    try {
      localStorage.setItem(WIDTH_KEY, String(Math.round(column.getBoundingClientRect().width)));
    } catch {
      // Storage blocked or full: the width just isn't kept.
    }
  };
  document.addEventListener("pointerup", finish);
  document.addEventListener("pointercancel", finish);
}

// ── Starting over ─────────────────────────────────────────────────────────────

// Forget everything that was saved and reload, as if the page had never been used.
export function clearData() {
  try {
    localStorage.clear();
  } catch {
    // Nothing could be saved there anyway.
  }
  location.reload();
}
