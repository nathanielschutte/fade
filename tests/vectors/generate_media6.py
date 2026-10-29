"""Generates tests/vectors/media6.json from the shared crypto (shared/crypto/crypto.js).

Photos in the media envelope (plan X33): a format 6 photo from alice (7) to
bob (3) with its caption placed a quarter of the way down (`y`), and a format
7 photo to a group with both, with no place given. Keys are format1.json's.
Run once; the output is pinned, so this refuses to overwrite the file. Every
client must open these exactly, and tests/vectors/check_media6.py opens them
with an independent implementation.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_media6.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "media6.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const alice = await crypto.subtle.importKey('pkcs8', e2e.fromB64(v1.alice.pkcs8), ECDH, false, ['deriveBits']);
  const [a, b] = [v1.alice.id, v1.bob.id];
  // A stand-in for a JPEG: its start and end markers around a few bytes.
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 6, 7, 8, 0xff, 0xd9]);
  const pair = await e2e.pairKey(alice, v1.bob.spki, a, b);
  const direct = await e2e.encryptImage(pair, jpeg, 'up here \\u{1F446}', a, b, 0.25);
  const wrapKeys = new Map([
    [a, await e2e.groupWrapKey(alice, v1.alice.spki, a, a)],
    [b, await e2e.groupWrapKey(alice, v1.bob.spki, a, b)],
  ]);
  const group = await e2e.encryptGroupImage(jpeg, 'no place given', { groupId: 5, senderId: a, wrapKeys });
  return {
    about: 'napsack photos in the media envelope: format 6 (direct) and 7 (group), with the caption place y. Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    direct: {
      format: 6, from: a, to: b, type: 'image/jpeg', caption: 'up here \\u{1F446}', y: 0.25, media: e2e.toB64(jpeg),
      plaintext: e2e.toB64(e2e.packMedia(jpeg, 'image/jpeg', 'up here \\u{1F446}', 0.25)), ciphertext: e2e.toB64(direct),
    },
    group: {
      format: 7, group_id: 5, sender: a, type: 'image/jpeg', caption: 'no place given', y: null, media: e2e.toB64(jpeg),
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
