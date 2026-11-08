// Runs grading/*/autograder.mjs as ordinary (synchronous, from Gleam's point
// of view) test checks: gleam test -- q13 shells out to each script and
// throws if it exits non-zero, which grader.gleam's rescue() (a plain
// try/catch, not Promise-aware) can catch correctly.

import { execFileSync } from "node:child_process";
import path from "node:path";

// `gleam test` runs with cwd = the Gleam project directory, regardless of how
// deep under build/ this compiled file actually sits -- import.meta.url would
// point there, not at the source tree, so we don't use it for path resolution.
const PROJECT_ROOT = process.cwd();

// `gleam test -- --verbose` turns on the progress traces below, and passes
// --verbose on to each autograder so it prints its own.
const VERBOSE = process.argv.includes("--verbose");
const VERBOSE_ARGS = VERBOSE ? ["--verbose"] : [];

// A genuine hang never produces a traceback on its own (nothing has thrown
// yet), so with --verbose, print progress as we go instead: if it does
// stall, whatever printed last tells you which step it's stuck in.
function trace(msg) {
  if (!VERBOSE) return;
  console.error(`[autograders ${new Date().toISOString()}] ${msg}`);
}


// Runs one autograder, keeping its report (grading/report.mjs) quiet unless
// it fails. A failure is thrown shaped like a Gleam `panic`, carrying the
// report as its message, so both gleeunit and grader.gleam print the report
// as the test's failure instead of "Command failed: node ...".
function runScript(relativeScriptPath, args) {
  try {
    const report = execFileSync(
      process.execPath,
      [path.join(PROJECT_ROOT, relativeScriptPath), ...args, ...VERBOSE_ARGS],
      { cwd: PROJECT_ROOT, stdio: ["ignore", "pipe", "inherit"], encoding: "utf8" },
    );
    if (VERBOSE) process.stdout.write(report);
  } catch (e) {
    const report = (e.stdout ?? "").trim();
    const error = new Error(
      report !== ""
        ? report
        : `${relativeScriptPath} crashed before reporting any results (its error is printed above)`,
    );
    error.gleam_error = "panic";
    error.file = relativeScriptPath;
    error.line = 1;
    throw error;
  } finally {
    trace(`${relativeScriptPath} finished`);
  }
}


// This one checks the address that the student deployed to.
export function run_deployment_autograder(url) {
  runScript("grading/deployment/autograder.mjs", [url]);
}

// This one checks the student's video link, so it doesn't need a browser or the app.
export function run_video_autograder(url) {
  runScript("grading/video/autograder.mjs", [url]);
}
