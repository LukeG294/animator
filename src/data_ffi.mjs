// The browser features behind data.gleam.

import { Result$Ok, Result$Error } from "./gleam.mjs";

// localStorage can throw: when the browser blocks it for this site, or (on a
// write) when the site is out of space.
export function storageGet(key) {
  try {
    const value = globalThis.localStorage.getItem(key);
    return value === null ? Result$Error(undefined) : Result$Ok(value);
  } catch {
    return Result$Error(undefined);
  }
}

export function storageSet(key, value) {
  try {
    globalThis.localStorage.setItem(key, value);
  } catch (error) {
    console.error(`Couldn't save: ${error.message}`);
  }
}

// Ask the user to name a new drawing; "" (empty string) means they cancelled.
export function promptDrawingName() {
  const name = window.prompt("Name for the new drawing:");
  return name === null ? "" : name;
}
