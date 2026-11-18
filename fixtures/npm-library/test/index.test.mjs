// The fixture library's unit test, run by the unit stage through the
// package's `test` script. Plain JavaScript, so the type check (which reads
// src/ only) needs no Node type definitions; Node strips the types from the
// TypeScript it imports.
import assert from "node:assert/strict";
import { test } from "node:test";

import { greeting } from "../src/index.ts";

test("greeting names who it greets", () => {
  assert.equal(greeting("fixture"), "Hello, fixture.");
});
