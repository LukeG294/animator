#!/usr/bin/env node
// Autograder for Problem 13 (Deploy Your App).
//
// Fetches the address in `public_url` (src/app.gleam) and checks that it serves this
// project: the page and the scripts it loads have the required controls. It doesn't
// run the app, and it can't tell whose version it is.
//
// Usage: node autograder.mjs <url> [--verbose]
//   --verbose prints progress traces to stderr as it goes.

import { finish } from "../report.mjs";

const VERBOSE = process.argv.includes("--verbose");
const URL_ARG = process.argv.slice(2).find((a) => !a.startsWith("--")) ?? "";

const BANNER = "Problem 13 (Deploy Your App)";
const EXAMPLE_APP = "animator.cs61a.org";
const LOCAL_HOSTS = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"];
const TIMEOUT_MS = 30000;
const REQUIRED = [
  ["the drawing menu", "drawing-select"],
  ["the speed slider", "speed-slider"],
  ["the canvas", "animation-canvas"],
];
// A script that a page loads: <script src="..."> or import ... from "...".
const SCRIPT = /(?:\bsrc\s*=\s*|\bfrom\s+)["']([^"']+\.m?js)["']/g;

function trace(msg) {
  if (!VERBOSE) return;
  console.error(`[deployment autograder ${new Date().toISOString()}] ${msg}`);
}

// Why this address can't be a public deployment of the student's app, or null.
function addressProblem(address) {
  if (address === "") {
    return 'public_url in src/app.gleam is empty. Set it to your app\'s public address, such as\n"https://your-username.github.io/animator/".';
  }
  let parsed;
  try {
    parsed = new URL(address);
  } catch {
    return `public_url in src/app.gleam is ${JSON.stringify(address)}, which isn't a complete web address.\nIt should start with https://.`;
  }
  if (parsed.hostname === EXAMPLE_APP) {
    return `public_url is the course's example app. It should be the address of your own deployed app.`;
  }
  if (LOCAL_HOSTS.includes(parsed.hostname)) {
    return `public_url is ${JSON.stringify(address)}, which is only on your own computer. It should be a public address.`;
  }
  if (parsed.protocol !== "https:") {
    return `public_url is ${JSON.stringify(address)}. It should start with https://.`;
  }
  return null;
}

async function get(url) {
  trace(`fetching ${url}`);
  return fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) }).catch((e) => e);
}

// The text of each script that the page loads, leaving out any it can't load.
async function scripts(page, base) {
  const texts = [];
  for (const [, src] of page.matchAll(SCRIPT)) {
    const response = await get(new URL(src, base));
    if (!(response instanceof Error) && response.ok) texts.push(await response.text());
  }
  return texts;
}

async function main() {
  const problem = addressProblem(URL_ARG);
  if (problem !== null) {
    finish(BANNER, [{ name: "public_url is a public address", pass: false, detail: problem }]);
  }

  const response = await get(URL_ARG);
  if (response instanceof Error || !response.ok) {
    const saw = response instanceof Error ? response.message : `status ${response.status}`;
    finish(BANNER, [{
      name: "the address can be reached",
      pass: false,
      detail:
        `Opening ${URL_ARG} gave ${saw}.\n` +
        "If you just set up GitHub Pages, it can take up to 10 minutes to appear. Check the address on\n" +
        "the Pages page of your repository's settings, and that index.html is at the top of the repository.",
    }]);
  }

  const page = await response.text();
  const code = [page, ...(await scripts(page, response.url))].join("\n");
  const missing = REQUIRED.filter(([, id]) => !code.includes(id)).map(([what]) => what);
  finish(BANNER, [{
    name: "the address serves the app's controls",
    pass: missing.length === 0,
    detail:
      `${URL_ARG} loaded, but it doesn't have ${missing.join(", ")}.\n` +
      "Run `gleam dev publish` and upload all of the files in public/ again.",
  }]);
}

main().catch((e) => {
  console.error("autograder crashed:", e);
  process.exit(2);
});
