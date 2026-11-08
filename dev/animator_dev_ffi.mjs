// The development server behind `gleam dev`: it serves this project's files and
// compiles src/ whenever it changes. `gleam dev publish` instead puts the files
// to deploy in public/. Run by Node, which `gleam dev` starts.

import { execFile, execSync } from "node:child_process";
import {
  copyFileSync,
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  watch,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import path from "node:path";

const MIME_TYPES = {
  ".html": "text/html",
  ".css": "text/css",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".map": "application/json",
  ".ico": "image/x-icon",
};

// Compile. After a compile error, the page keeps running the last working build,
// and the error appears in this terminal.
function rebuild() {
  execFile("gleam", ["build"], (error, stdout, stderr) => {
    if (error) {
      console.error(stdout + stderr);
    } else {
      console.log("Rebuilt the app. Refresh the page to see the changes.");
    }
  });
}

// Saving a file can raise several events, so act once they stop.
function debounced(f) {
  let timer = null;
  return () => {
    clearTimeout(timer);
    timer = setTimeout(f, 100);
  };
}

function handleRequest(request, response) {
  const url = new URL(request.url, "http://localhost").pathname;
  const file = path.join(".", path.normalize(url === "/" ? "index.html" : url));
  if (!existsSync(file) || !statSync(file).isFile()) {
    response.writeHead(404).end();
    return;
  }
  response.setHeader("Content-Type", MIME_TYPES[path.extname(file)] ?? "text/plain");
  response.setHeader("Cache-Control", "no-store");
  createReadStream(file).pipe(response);
}

// The compiled app is about 100 modules, so bundle it into one file. `gleam dev`
// has already compiled it.
function publish() {
  const built = "./build/dev/javascript/animator/app.mjs";
  mkdirSync("public", { recursive: true });
  execSync(
    `npx -y esbuild@0.25.5 ${built} --bundle --minify --format=esm --log-level=error --outfile=public/app.mjs`,
    { stdio: "inherit" },
  );
  const page = readFileSync("index.html", "utf8");
  if (!page.includes(built)) {
    console.error(`index.html no longer imports ${built}, so update it in public/index.html.`);
  }
  writeFileSync("public/index.html", page.replace(built, "./app.mjs"));
  copyFileSync("animator.css", "public/animator.css");
  console.log("Wrote index.html, animator.css, and app.mjs to the public folder.");
}

export function start(defaultPort) {
  if (process.argv.at(-1) === "publish") {
    publish();
  } else {
    serve(defaultPort);
  }
}

function serve(defaultPort) {
  const port = Number(process.argv.at(-1)) || defaultPort;
  watch("src", { recursive: true }, debounced(rebuild));
  const server = createServer(handleRequest);
  server.on("error", (error) => {
    if (error.code !== "EADDRINUSE") throw error;
    console.error(`Port ${port} is in use. Choose another: gleam dev ${port + 1}`);
    process.exit(1);
  });
  server.listen(port, "127.0.0.1", () => {
    console.log(`Serving the app at http://localhost:${port} (Ctrl-C to stop)`);
  });
}
