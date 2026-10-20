"""Generates tests/vectors/texts2.json from the shared crypto (shared/crypto/crypto.js).

Format 2 texts (a JSON envelope, with replies) and reactions, using the format
1 keys (alice, bob) from format1.json. Run once; the output is pinned, so this
refuses to overwrite the file. Every client must reproduce these values exactly.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_texts2.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "texts2.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const alice = await crypto.subtle.importKey('pkcs8', e2e.fromB64(v1.alice.pkcs8), ECDH, false, ['deriveBits']);
  const key = await e2e.pairKey(alice, v1.bob.spki, v1.alice.id, v1.bob.id);
  const text = async (t, replyTo) => ({
    from: v1.alice.id, to: v1.bob.id, text: t, reply_to: replyTo,
    plaintext: e2e.packText(t, replyTo),
    ciphertext: await e2e.encryptText2(key, t, replyTo, v1.alice.id, v1.bob.id),
  });
  return {
    about: 'napsack format 2 texts (JSON envelope, replies) and reactions. Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    texts: [
      await text('see you at 8 \\u{1F33F}', null),
      await text('yes! "quotes", back\\\\slash, and a\\nnew line', 41),
    ],
    reaction: {
      from: v1.alice.id, to: v1.bob.id, message_id: 41, emoji: e2e.REACTIONS[0],
      ciphertext: await e2e.encryptReaction(key, e2e.REACTIONS[0], v1.alice.id, v1.bob.id, 41),
    },
  };
}"""


async def main():
    if os.path.exists(OUT):
        sys.exit(f"{OUT} exists. These vectors are pinned; don't regenerate them.")
    v1 = json.load(open(os.path.join(HERE, "format1.json"), encoding="utf-8"))
    async with async_playwright() as pw:
        browser = await launch(pw)
        page = await browser.new_page()
        await page.goto(BASE)
        vectors = await page.evaluate(GENERATE, v1)
        await browser.close()
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(vectors, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {OUT}")


asyncio.run(main())
