"""Generates tests/vectors/format1.json from the web client's crypto.js.

Run once; the output is pinned. Format 1 must never change, because existing
messages depend on it, so this refuses to overwrite the file. Every client
(web today, iOS next) must reproduce these values exactly.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_format1.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "format1.json")

GENERATE = """async () => {
  const e2e = await import('/crypto.js');
  const s = crypto.subtle;
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const b64 = e2e.toB64;
  const user = { username: 'Alice', password: 'correct horse battery staple' };
  const { authKey, wrapKey } = await e2e.deriveFromPassword(user.username, user.password);

  const pairOf = async () => {
    const p = await s.generateKey(ECDH, true, ['deriveBits']);
    return { pkcs8: b64(await s.exportKey('pkcs8', p.privateKey)), spki: b64(await s.exportKey('spki', p.publicKey)), key: p.privateKey };
  };
  const alice = await pairOf(), bob = await pairOf();
  const aliceId = 7, bobId = 3;
  const wrapped = b64(await e2e.seal(wrapKey, e2e.fromB64(alice.pkcs8), 'napsack/v1/identity'));
  const key = await e2e.pairKey(alice.key, bob.spki, aliceId, bobId);
  const text = 'see you at 8 \\u{1F33F}';
  const snap = Uint8Array.from({ length: 64 }, (_, i) => (i * 37 + 11) % 256);
  return {
    about: 'napsack message format 1 test vectors. Generated once from server/static/crypto.js; never regenerate.',
    password: { ...user, auth_key: authKey, wrapped_private_key: wrapped },
    alice: { id: aliceId, pkcs8: alice.pkcs8, spki: alice.spki },
    bob: { id: bobId, pkcs8: bob.pkcs8, spki: bob.spki },
    text: { from: aliceId, to: bobId, plaintext: text, ciphertext: await e2e.encryptText(key, text, aliceId, bobId) },
    snap: { from: aliceId, to: bobId, plaintext_b64: b64(snap), ciphertext_b64: b64(await e2e.encryptSnap(key, snap, aliceId, bobId)) },
    safety_code: await e2e.safetyCode(alice.spki, bob.spki),
  };
}"""


async def main():
    if os.path.exists(OUT):
        sys.exit(f"{OUT} exists. Format 1 vectors are pinned; don't regenerate them.")
    async with async_playwright() as pw:
        browser = await launch(pw)
        page = await browser.new_page()
        await page.goto(BASE)
        vectors = await page.evaluate(GENERATE)
        await browser.close()
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(vectors, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {OUT}")


asyncio.run(main())
