"""Generates tests/vectors/media4.json from the shared crypto (shared/crypto/crypto.js).

Videos (plan X28): a format 4 video from alice (7) to bob (3), sealed with
their pair key, and a format 5 video to a group with both of them, sealed with
the format 3 group scheme as kind "video". Both carry the media envelope
(header length, a JSON header with the type and caption, the bytes). Keys are
format1.json's. Run once; the output is pinned, so this refuses to overwrite
the file. Every client must open these exactly, and
tests/vectors/check_media4.py opens them with an independent implementation.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_media4.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "media4.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const alice = await crypto.subtle.importKey('pkcs8', e2e.fromB64(v1.alice.pkcs8), ECDH, false, ['deriveBits']);
  const [a, b] = [v1.alice.id, v1.bob.id];
  // A stand-in for an MP4: its first box, then a few bytes.
  const media = new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 1, 2, 3, 4, 5, 6, 7, 8]);
  const type = 'video/mp4';
  const pair = await e2e.pairKey(alice, v1.bob.spki, a, b);
  const direct = await e2e.encryptVideo(pair, media, type, 'the lake \\u{1F30A}', a, b);
  const wrapKeys = new Map([
    [a, await e2e.groupWrapKey(alice, v1.alice.spki, a, a)],
    [b, await e2e.groupWrapKey(alice, v1.bob.spki, a, b)],
  ]);
  const group = await e2e.encryptGroupVideo(media, 'video/webm;codecs=vp8,opus', '', { groupId: 5, senderId: a, wrapKeys });
  return {
    about: 'napsack videos: format 4 (direct) and 5 (group). Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    direct: {
      format: 4, from: a, to: b, type, caption: 'the lake \\u{1F30A}', media: e2e.toB64(media),
      plaintext: e2e.toB64(e2e.packMedia(media, type, 'the lake \\u{1F30A}')), ciphertext: e2e.toB64(direct),
    },
    group: {
      format: 5, group_id: 5, sender: a, type: 'video/webm;codecs=vp8,opus', caption: '', media: e2e.toB64(media),
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
