// What counts as a reaction (X49): isReaction in crypto.js, the same rule as
// the server's `text::is_one_emoji`. The cases are the Rust tests'
// (`one_emoji_is_a_reaction`, `anything_else_is_not_a_reaction` in
// server/src/text.rs); a case added there is added here too.
//
//   node --test "shared/**/*.test.js"

import { test } from "node:test";
import assert from "node:assert/strict";

import { isReaction, REACTIONS } from "./crypto.js";
import { EMOJI_GROUPS } from "../../server/static/emoji.js";

test("one emoji is a reaction", () => {
  for (const ok of [
    "❤️",
    "😂",
    "👍",
    "👍🏽",
    "🇳🇿",
    "1️⃣",
    "#⃣",
    "©️",
    "☀",
    "🫠",
    "👨‍👩‍👧‍👦",
    "🧑🏿‍🚀",
    "🏳️‍🌈",
    "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
  ]) {
    assert.ok(isReaction(ok), JSON.stringify(ok));
  }
});

test("anything else is not a reaction", () => {
  for (const bad of [
    "",
    "a",
    "1",
    "ok",
    "😂😂",
    "😂 ",
    " 😂",
    "😂a",
    "🇳",
    "🇳🇿🇳🇿",
    "1⃣2",
    "️",
    "‍😂",
    "😂‍",
    "😂‍‍😂",
    "🏽",
    "‮😂",
    "😂‮",
    "​",
    "\0",
    "🏴\u{E0067}\u{E0062}",
    "<b>",
    "👍🏽🏽",
    "👨‍👩‍👧‍👦‍👨‍👩‍👧‍👦",
  ]) {
    assert.ok(!isReaction(bad), JSON.stringify(bad));
  }
  for (const notText of [null, undefined, 1, ["😂"], { emoji: "😂" }]) assert.ok(!isReaction(notText));
});

test("every emoji the picker offers is a reaction", () => {
  const all = EMOJI_GROUPS.flatMap(([, list]) => list.split("|").map((entry) => entry.slice(0, entry.indexOf(" "))));
  assert.ok(all.length > 1500, `only ${all.length}`);
  assert.equal(new Set(all).size, all.length, "an emoji is listed twice");
  assert.deepEqual(all.filter((e) => !isReaction(e)), []);
  assert.deepEqual(REACTIONS.filter((e) => !isReaction(e)), []);
  assert.deepEqual(REACTIONS.filter((e) => !all.includes(e)), []);
});
