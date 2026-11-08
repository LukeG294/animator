// Reads extension.txt for extension_test.gleam. `gleam test` runs with cwd = the
// Gleam project directory, so the path is relative to that.

import { existsSync, readFileSync } from "node:fs";

const DESCRIPTION = "extension.txt";

export function read_description() {
  return existsSync(DESCRIPTION) ? readFileSync(DESCRIPTION, "utf8") : "";
}

