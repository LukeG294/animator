#!/usr/bin/env node
// Autograder for Problem 14 (Record Your Extension).
//
// Opens the link in `video_url` (src/app.gleam) without signing in, and checks
// that Google Drive shows the file to anyone who has the link. It can't tell
// what's in the file.
//
// Usage: node autograder.mjs <url> [--verbose]
//   --verbose prints progress traces to stderr as it goes.

import { finish } from "../report.mjs";

const VERBOSE = process.argv.includes("--verbose");
const URL_ARG = process.argv.slice(2).find((a) => !a.startsWith("--")) ?? "";

const BANNER = "Problem 14 (Record Your Extension)";
const DRIVE_HOST = "drive.google.com";
const TIMEOUT_MS = 30000;
const SHARE_STEPS =
  "In Google Drive, open Share for your video and, under General access, choose Anyone with the link.";

function trace(msg) {
  if (!VERBOSE) return;
  console.error(`[video autograder ${new Date().toISOString()}] ${msg}`);
}

// Why this can't be a link to a video on Google Drive, or null.
function linkProblem(link) {
  if (link === "") {
    return 'video_url in src/app.gleam is empty. Set it to your video\'s link, such as\n"https://drive.google.com/file/d/your-file-id/view".';
  }
  let parsed;
  try {
    parsed = new URL(link);
  } catch {
    return `video_url in src/app.gleam is ${JSON.stringify(link)}, which isn't a complete web address.\nIt should start with https://.`;
  }
  if (parsed.hostname !== DRIVE_HOST) {
    return `video_url is ${JSON.stringify(link)}. It should be a link to your video on ${DRIVE_HOST}.`;
  }
  return null;
}

// Why someone with this link and no Google account can't open it, or null.
function accessProblem(response) {
  const signIn =
    response.status === 401 ||
    response.status === 403 ||
    new URL(response.url).hostname !== DRIVE_HOST;
  if (signIn) {
    return `Opening ${URL_ARG} asks for a sign-in, so your video isn't shared.\n${SHARE_STEPS}`;
  }
  if (response.status === 404) {
    return `Google Drive has no file at ${URL_ARG}.\nCopy the link again from Share in Google Drive.`;
  }
  if (!response.ok) {
    return `Opening ${URL_ARG} gave status ${response.status}. Try again in a few minutes.`;
  }
  return null;
}

async function main() {
  const problem = linkProblem(URL_ARG);
  if (problem !== null) {
    finish(BANNER, [{ name: "video_url is a Google Drive link", pass: false, detail: problem }]);
  }

  trace(`opening ${URL_ARG}`);
  const response = await fetch(URL_ARG, { signal: AbortSignal.timeout(TIMEOUT_MS) }).catch((e) => e);
  trace(`finished at ${response.url} with status ${response.status}`);
  if (response instanceof Error) {
    finish(BANNER, [{
      name: "the link can be reached",
      pass: false,
      detail: `Opening ${URL_ARG} gave ${response.message}. Check your connection and try again.`,
    }]);
  }
  const access = accessProblem(response);
  finish(BANNER, [{
    name: "anyone with the link can open it",
    pass: access === null,
    detail: access,
  }]);
}

main().catch((e) => {
  console.error("autograder crashed:", e);
  process.exit(2);
});
