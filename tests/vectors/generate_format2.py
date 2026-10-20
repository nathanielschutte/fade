"""Generates tests/vectors/format2.json from the web client's crypto.js.

Format 2 is a pic with a caption sealed inside (docs/how-napsack-works.md).
It reuses the format 1 keys (alice, bob) from format1.json. Run once; the
output is pinned, so this refuses to overwrite the file. Every client must
reproduce these values exactly.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_format2.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "format2.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const alice = await crypto.subtle.importKey('pkcs8', e2e.fromB64(v1.alice.pkcs8), ECDH, false, ['deriveBits']);
  const key = await e2e.pairKey(alice, v1.bob.spki, v1.alice.id, v1.bob.id);
  const photo = Uint8Array.from({ length: 64 }, (_, i) => (i * 53 + 7) % 256);
  const pic = async (caption) => ({
    from: v1.alice.id, to: v1.bob.id, caption,
    photo_b64: e2e.toB64(photo),
    plaintext_b64: e2e.toB64(e2e.packPic(photo, caption)),
    ciphertext_b64: e2e.toB64(await e2e.encryptPic(key, photo, caption, v1.alice.id, v1.bob.id)),
  });
  return {
    about: 'napsack message format 2 test vectors (pic + caption). Keys are format1.json. Generated once from server/static/crypto.js; never regenerate.',
    pic: await pic('sunset at the lake \\u{1F305}'),
    pic_no_caption: await pic(''),
  };
}"""


async def main():
    if os.path.exists(OUT):
        sys.exit(f"{OUT} exists. Format 2 vectors are pinned; don't regenerate them.")
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
