"""Generates tests/vectors/group3.json from the shared crypto (shared/crypto/crypto.js).

Format 3 group messages (docs/implementation/group-encryption.md): a text with a reply and a
pic with a caption, sent by alice (7) to a group with bob (3), each sealed once
and its key wrapped for both members. Keys are format1.json's. Run once; the
output is pinned, so this refuses to overwrite the file. Every client must
open these exactly, and tests/vectors/check_group3.py opens them with an
independent implementation.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_group3.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "group3.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const alice = await crypto.subtle.importKey('pkcs8', e2e.fromB64(v1.alice.pkcs8), ECDH, false, ['deriveBits']);
  const [a, b] = [v1.alice.id, v1.bob.id];
  const wrapKeys = new Map([
    [a, await e2e.groupWrapKey(alice, v1.alice.spki, a, a)],
    [b, await e2e.groupWrapKey(alice, v1.bob.spki, a, b)],
  ]);
  const opts = { groupId: 5, senderId: a, wrapKeys };
  const text = await e2e.encryptGroupText('road trip? \\u{1F697}', 99, opts);
  const photo = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5, 6, 7, 8, 0xff, 0xd9]);
  const pic = await e2e.encryptGroupPic(photo, 'the dock \\u{1F332}', opts);
  const out = (m) => ({ client_id: m.clientId, recipients: m.recipients, content: e2e.toB64(m.content), wraps: m.wraps });
  return {
    about: 'napsack format 3 group messages (docs/group-encryption.md). Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    group_id: 5,
    sender: a,
    text: { text: 'road trip? \\u{1F697}', reply_to: 99, plaintext: e2e.packText('road trip? \\u{1F697}', 99), ...out(text) },
    pic: { caption: 'the dock \\u{1F332}', photo: e2e.toB64(photo), ...out(pic) },
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
