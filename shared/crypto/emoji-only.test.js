// Texts of only emoji, shown large without the bubble (X53): the web's
// emojiOnly (server/static/emoji-only.js), held to the reactions' rule. The
// cases are the iPhone's (ios/NapsackTests/EmojiOnlyTests.swift); a case
// added there is added here too.
//
//   node --test "shared/**/*.test.js"

import { test } from "node:test";
import assert from "node:assert/strict";

import { isReaction } from "./crypto.js";
import { emojiOnly } from "../../server/static/emoji-only.js";

const count = (text) => emojiOnly(text, isReaction);

test("one to four emoji are shown large", () => {
  assert.equal(count("😂"), 1);
  assert.equal(count("❤️"), 1);
  assert.equal(count("👍🏽👍🏽"), 2);
  assert.equal(count("🇳🇿 🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"), 2); // flags, spaced
  assert.equal(count("👨‍👩‍👧‍👦1️⃣🦊"), 3); // a family is one, a keycap is one
  assert.equal(count(" 🎉🎉🎉🎉\n"), 4);
  assert.equal(count("©️"), 1); // a symbol in its emoji form
});

test("anything else is an ordinary text", () => {
  for (const text of ["🎉🎉🎉🎉🎉", "ok 👍", "👍!", "", "   ", "1", "©", "™", "↔", "❤", "☀", "a", "👍 👍 👍 👍 👍"]) {
    assert.equal(count(text), 0, JSON.stringify(text));
  }
  assert.equal(count(null), 0);
});
