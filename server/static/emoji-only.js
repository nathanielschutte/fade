// Texts of only emoji show large, without the bubble (X53): one to four
// emoji, with spaces between them or not. More than four, or anything else in
// the text, and it's an ordinary text. The same rule as the iPhone's
// (`BubbleView.emojiOnly`, ChatScreen.swift).
//
// Each emoji is held to the reactions' rule, `isReaction` from /crypto.js,
// passed in so this file needs nothing else (and Node can test it:
// shared/crypto/emoji-only.test.js). A character that's usually a plain
// symbol (©, ™, an arrow, a bare ❤ without U+FE0F) only counts in its emoji
// form: alone, a single code point has to be one drawn as an emoji by default.

export const EMOJI_ONLY_MAX = 4;

const graphemes = typeof Intl !== "undefined" && Intl.Segmenter
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;

/** How many emoji `text` is, when it's only 1 to EMOJI_ONLY_MAX of them; otherwise 0. */
export function emojiOnly(text, isReaction) {
  if (typeof text !== "string" || !graphemes) return 0;
  let n = 0;
  for (const { segment } of graphemes.segment(text)) {
    if (/^\s+$/u.test(segment)) continue;
    if (!isReaction(segment)) return 0;
    if ([...segment].length === 1 && !/\p{Emoji_Presentation}/u.test(segment)) return 0;
    if (++n > EMOJI_ONLY_MAX) return 0;
  }
  return n;
}
