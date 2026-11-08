// The code editor (CodeMirror 6).
//
// The draw-function editor is a real CodeMirror 6 instance rather than a plain
// <textarea>, giving us automatic indentation, matching-bracket highlighting,
// bracket auto-closing, and Gleam syntax highlighting. Lustre renders only an
// empty `unsafe_raw_html` mount node (#code-editor) and never re-patches it
// (its inner_html stays ""), so the CodeMirror DOM we inject survives re-renders.
// A re-render can still replace the node, such as when an element is added before
// it or the panel leaves the view and returns, so reattachEditor moves the editor
// into the new one.
//
// CodeMirror is loaded lazily from a CDN the first time the editor opens, so the
// pane is blank for a moment on first load (and the editor needs the network).

let cmView = null; // the live EditorView, or null when no editor is mounted
let cmOnChange = null; // Gleam callback: receives the document text on every edit
let cmModulePromise = null; // cached import of the CodeMirror bundle
let cmObserver = null; // watches the page for a replaced mount node (see reattachEditor)

// Lezer highlight-tag → token-name mapping for our hand-written Gleam tokenizer.
// (The grammar itself is small enough that a StreamLanguage tokenizer is simpler
// than pulling in a full Lezer grammar; the heavy lifting — highlighting,
// indentation, bracket matching — is all CodeMirror's.)
function defineGleam(StreamLanguage) {
  const keywords = new Set([
    "fn", "case", "let", "const", "import", "use", "type", "pub", "as", "if",
    "todo", "panic", "assert",
  ]);
  return StreamLanguage.define({
    token(stream) {
      if (stream.eatSpace()) return null;
      if (stream.match(/^\/\/.*/)) return "comment";
      if (stream.match(/^"(?:[^"\\]|\\.)*"?/)) return "string";
      if (stream.match(/^[0-9]+\.[0-9]+/) || stream.match(/^[0-9]+/)) return "number";
      if (stream.match(/^(True|False|Nil|Ok|Error)\b/)) return "atom";
      const word = stream.match(/^[A-Za-z_][A-Za-z0-9_]*/);
      if (word) {
        if (keywords.has(word[0])) return "keyword";
        if (/^[A-Z]/.test(word[0])) return "typeName"; // Point, Path, ...
        return "variableName";
      }
      if (stream.match(/^(\+\.|-\.|\*\.|\/\.|<=\.|>=\.|<\.|>\.|==|!=|->|<-|\|>|=)/))
        return "operator";
      stream.next();
      return null;
    },
    languageData: { commentTokens: { line: "//" } },
  });
}

function loadCodeMirror() {
  if (cmModulePromise) return cmModulePromise;
  const V = "6";
  cmModulePromise = Promise.all([
    import(`https://esm.sh/@codemirror/view@${V}`),
    import(`https://esm.sh/@codemirror/state@${V}`),
    import(`https://esm.sh/@codemirror/commands@${V}`),
    import(`https://esm.sh/@codemirror/language@${V}`),
    import(`https://esm.sh/@codemirror/autocomplete@${V}`),
    import(`https://esm.sh/@lezer/highlight@1`),
  ]).then(([view, state, commands, language, autocomplete, highlight]) => {
    const { tags: t } = highlight;
    const theme = view.EditorView.theme(
      {
        "&": { color: "#d4c5a0", backgroundColor: "#0d0d1a", height: "100%" },
        ".cm-content": {
          fontFamily: "monospace",
          fontSize: "13px",
          padding: "16px 0",
        },
        ".cm-gutters": {
          backgroundColor: "#0d0d1a",
          color: "#3a3a5e",
          border: "none",
        },
        // Translucent, so a selection on the cursor's line shows through it.
        ".cm-activeLine": { backgroundColor: "rgba(130, 140, 220, 0.08)" },
        ".cm-activeLineGutter": { backgroundColor: "rgba(130, 140, 220, 0.08)" },
        ".cm-selectionBackground": { background: "#2c3a72" },
        "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground": {
          background: "#3c58b0",
        },
        "&.cm-focused .cm-matchingBracket": {
          backgroundColor: "#2a4a3a",
          color: "#fff",
        },
        ".cm-scroller": { overflow: "auto" },
        "&.cm-focused": { outline: "1px solid #6a6aaa" },
      },
      { dark: true },
    );
    const highlightStyle = language.HighlightStyle.define([
      { tag: t.keyword, color: "#c792ea" },
      { tag: t.comment, color: "#6a7a6a", fontStyle: "italic" },
      { tag: t.string, color: "#c3e88d" },
      { tag: t.number, color: "#f78c6c" },
      { tag: [t.atom, t.bool], color: "#82aaff" },
      { tag: t.typeName, color: "#ffcb6b" },
      { tag: t.variableName, color: "#d4c5a0" },
      { tag: t.operator, color: "#89ddff" },
    ]);
    const gleam = defineGleam(language.StreamLanguage);

    function create(parent, doc, onChange) {
      const updateListener = view.EditorView.updateListener.of((u) => {
        if (u.docChanged) onChange(u.state.doc.toString());
      });
      const startState = state.EditorState.create({
        doc,
        extensions: [
          view.lineNumbers(),
          view.highlightActiveLine(),
          view.highlightActiveLineGutter(),
          commands.history(),
          view.drawSelection(),
          language.indentOnInput(),
          language.indentUnit.of("  "),
          language.bracketMatching(),
          autocomplete.closeBrackets(),
          language.syntaxHighlighting(highlightStyle),
          gleam,
          view.keymap.of([
            ...autocomplete.closeBracketsKeymap,
            ...commands.defaultKeymap,
            ...commands.historyKeymap,
            commands.indentWithTab,
          ]),
          theme,
          view.EditorView.lineWrapping,
          updateListener,
        ],
      });
      return new view.EditorView({ state: startState, parent });
    }

    return { create };
  });
  return cmModulePromise;
}

// Resolve once an element with `id` exists, polling on animation frames, or with
// null after `maxFrames` tries (so a closed editor doesn't wait forever).
function waitForElement(id, maxFrames) {
  return new Promise((resolve) => {
    let tries = 0;
    const check = () => {
      const el = document.getElementById(id);
      if (el) return resolve(el);
      if (tries++ >= maxFrames) return resolve(null);
      requestAnimationFrame(check);
    };
    check();
  });
}

// If a re-render removed the live editor along with its mount node, move it into the
// new node, keeping its text and undo history. Removing a focused element leaves the
// focus on the page's body, so give it back to the editor from there.
function reattachEditor() {
  if (!cmView || cmView.dom.isConnected) return;
  const el = document.getElementById("code-editor");
  if (!el) return; // the panel is out of the view for now
  el.replaceChildren(cmView.dom);
  cmView.requestMeasure();
  if (document.activeElement === document.body) cmView.focus();
}

// Counts calls to mountEditor, so that a mount that finishes after a later one
// (the first load can be slow) gives way to it instead of replacing its text.
let mountGeneration = 0;

export function mountEditor(initialText, onChange) {
  const generation = ++mountGeneration;
  // Tear down any editor from a previous drawing first, so mounting is
  // self-contained: switching drawings just calls this again.
  if (cmView) {
    cmView.destroy();
    cmView = null;
  }
  cmOnChange = onChange;
  if (!cmObserver) {
    cmObserver = new MutationObserver(reattachEditor);
    cmObserver.observe(document.body, { childList: true, subtree: true });
  }
  // The mount effect can run before Lustre has committed the #code-editor
  // node to the DOM, so wait for it to appear before loading CodeMirror.
  waitForElement("code-editor", 120).then((mount) => {
    if (!mount || generation !== mountGeneration) return; // closed, or superseded
    loadCodeMirror()
      .then((CM) => {
        if (generation !== mountGeneration) return; // a later mount took over
        const el = document.getElementById("code-editor");
        if (!el) return; // editor was closed before CodeMirror finished loading
        el.innerHTML = "";
        cmView = CM.create(el, initialText, (t) => {
          if (cmOnChange) cmOnChange(t);
        });
      })
      .catch((e) => console.error("CodeMirror failed to load:", e));
  });
}
