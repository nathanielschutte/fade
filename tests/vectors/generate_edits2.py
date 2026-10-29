"""Generates tests/vectors/edits2.json from the shared crypto (shared/crypto/crypto.js).

Edits to texts (plan X29): alice (7) edits her direct text 42 to bob (3), and
her group text 77 in group 5 (with bob), each a format 2 text envelope sealed
with associated data that names the message it edits. Keys are
format1.json's. Run once; the output is pinned, so this refuses to overwrite
the file. Every client must open these exactly, and
tests/vectors/check_edits2.py opens them with an independent implementation.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_edits2.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "edits2.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const alice = await crypto.subtle.importKey('pkcs8', e2e.fromB64(v1.alice.pkcs8), ECDH, false, ['deriveBits']);
  const [a, b] = [v1.alice.id, v1.bob.id];
  const pair = await e2e.pairKey(alice, v1.bob.spki, a, b);
  const text = 'see you at 7, not 6 \\u{1F642}';
  const direct = await e2e.encryptEdit(pair, text, a, b, 42);
  const wrapKeys = new Map([
    [a, await e2e.groupWrapKey(alice, v1.alice.spki, a, a)],
    [b, await e2e.groupWrapKey(alice, v1.bob.spki, a, b)],
  ]);
  const group = await e2e.encryptGroupEdit('the dock, not the lake', 77, { groupId: 5, senderId: a, wrapKeys });
  return {
    about: 'napsack edits to texts (plan X29). Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    direct: { from: a, to: b, message_id: 42, text, plaintext: e2e.packText(text), ciphertext: direct },
    group: {
      group_id: 5, sender: a, message_id: 77, text: 'the dock, not the lake',
      client_id: group.clientId, recipients: group.recipients, content: e2e.toB64(group.content), wraps: group.wraps,
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
