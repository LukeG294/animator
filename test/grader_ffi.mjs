// The things grader.gleam needs and Gleam cannot express: the command-line
// arguments, running a test function without letting its panic (or its never
// finishing) end the whole run silently, and the process exit code.
//
// Installed into a project's test/ directory from lib/gleam/grader_ffi.mjs in
// the assignments repo; edit it there and not in the copy.

import { readFileSync, writeSync } from "node:fs";
import { Worker, isMainThread, workerData } from "node:worker_threads";
import { Result$Ok, Result$Error, toList } from "./gleam.mjs";

// How long one test may run before the supervisor fails it and ends the run.
const TIMEOUT_MS = 2_000;

export function args() {
  return toList(globalThis.Deno ? Deno.args : process.argv.slice(2));
}

// Run f, turning the panic a failed `assert` or `let assert` raises into an
// Error holding the raised object. Gleam reads the details out of it (see
// describe in grader.gleam), so nothing is formatted here.
export function rescue(name, f) {
  watch(name);
  try {
    f();
    return Result$Ok(undefined);
  } catch (error) {
    return Result$Error(error);
  } finally {
    watch("");
  }
}

// A test runs synchronously on its thread, so nothing on that thread can
// interrupt one that never finishes. So the questions run on a worker thread,
// which re-runs this program's entry script, while the main thread supervises:
// they share a buffer holding a counter that changes whenever a test starts or
// ends, and the running test's name (empty between tests). When the counter
// stays put for TIMEOUT_MS while a test is running, the supervisor reports that
// test as failed and ends the run. The process exits with the worker's code.
//
// Returns whether this thread is the supervisor, which must not run any tests.
export function supervise() {
  if (globalThis.Deno) return false;
  if (!isMainThread) {
    // A worker's console.log is relayed through its event loop, which a test
    // that never finishes blocks, losing the lines printed before it.
    console.log = (...values) => writeSync(1, values.join(" ") + "\n");
    return false;
  }
  const shared = new SharedArrayBuffer(8 + 256);
  const state = new Int32Array(shared, 0, 2);
  const worker = new Worker(process.argv[1], {
    argv: process.argv.slice(2),
    workerData: { shared },
  });
  let seen = -1;
  let since = Date.now();
  const timer = setInterval(() => {
    const count = Atomics.load(state, 0);
    const length = Atomics.load(state, 1);
    if (count !== seen || length === 0) {
      seen = count;
      since = Date.now();
    } else if (Date.now() - since >= TIMEOUT_MS) {
      const name = Buffer.from(new Uint8Array(shared, 8, length)).toString();
      console.log(`  FAIL  ${name}`);
      console.log(
        `        timed out after ${TIMEOUT_MS / 1000} seconds; ending the test run`,
      );
      clearInterval(timer);
      worker.terminate();
    }
  }, 100);
  worker.on("error", (error) => console.error(error));
  worker.on("exit", (code) => {
    clearInterval(timer);
    process.exitCode = code;
  });
  return true;
}

function watch(name) {
  const shared = workerData?.shared;
  if (!shared) return;
  const state = new Int32Array(shared, 0, 2);
  const bytes = new TextEncoder().encode(name).slice(0, 256);
  new Uint8Array(shared, 8).set(bytes);
  Atomics.store(state, 1, bytes.length);
  Atomics.add(state, 0, 1);
}

// The source text between two byte offsets of a file, which is how a failed
// assertion locates its expressions. The file path is relative to the project
// directory, found from this module's compiled location
// (<project>/build/dev/javascript/<package>/) so it can be run from anywhere.
export function source(file, start, end) {
  try {
    const url = new URL(`../../../../${file}`, import.meta.url);
    const bytes = readFileSync(url).subarray(start, end);
    return Result$Ok(new TextDecoder().decode(bytes));
  } catch {
    return Result$Error(undefined);
  }
}

export function exit(code) {
  if (globalThis.Deno) {
    Deno.exit(code);
  } else {
    process.exit(code);
  }
}
