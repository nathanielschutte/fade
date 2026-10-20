// The shared crypto against the pinned vectors, in Node (no browser, no phone).
// The same checks (vector-checks.js) run on the iPhone from the app's spike
// screen, and the browser runs its own copy (tests/e2e/test_crypto_vectors.py).
// If any of them disagree, the change is wrong: never "fix" it by editing the
// vectors.
//
//   node --test "shared/**/*.test.js"

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as e2e from "./crypto.js";
import { runVectorChecks } from "./vector-checks.js";

const load = (name) => JSON.parse(readFileSync(new URL(`../../tests/vectors/${name}`, import.meta.url), "utf8"));

test("every vector check passes", async () => {
  const results = await runVectorChecks(e2e, {
    format1: load("format1.json"),
    format2: load("format2.json"),
    recovery: load("recovery.json"),
  });
  for (const r of results) console.log(`${r.ok ? "ok  " : "FAIL"} ${r.name} (${r.ms} ms)${r.error ? `: ${r.error}` : ""}`);
  assert.ok(results.length >= 20, `only ${results.length} checks ran`);
  assert.deepEqual(results.filter((r) => !r.ok).map((r) => r.name), []);
});
