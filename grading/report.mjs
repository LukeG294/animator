// Prints an autograder's results for a student to read, then exits: 0 if
// every check passed, 1 if any failed.
//
// `banner` names the problem the checks belong to ("Problem 13 (Deploy Your App)").
// Each result is {name, pass, detail}; detail is only printed for a failure,
// where it should say what the check expected and what it saw instead.
// pageErrors are uncaught exceptions the app threw in the browser, which
// often explain a failure better than the failed check itself can.
//
// gleam test captures this output and shows it as the test's failure message
// (see test/autograders_ffi.mjs), so it is plain text, not JSON.
export function finish(banner, results, pageErrors = []) {
  const passed = results.filter((r) => r.pass).length;
  const total = results.length;
  const lines = [`${banner}: ${passed} of ${total} check${total === 1 ? "" : "s"} passed`];
  for (const r of results) {
    lines.push(`  ${r.pass ? "pass" : "FAIL"}  ${r.name}`);
    if (!r.pass) lines.push(...indent(r.detail, 8));
  }
  if (pageErrors.length > 0) {
    lines.push("  The app threw errors in the browser while being checked:");
    for (const e of pageErrors) lines.push(...indent(e, 8));
  }
  console.log(lines.join("\n"));
  process.exit(passed === results.length ? 0 : 1);
}

function indent(text, spaces) {
  return String(text)
    .split("\n")
    .map((line) => " ".repeat(spaces) + line);
}
