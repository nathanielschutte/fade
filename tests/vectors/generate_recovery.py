"""Generates tests/vectors/recovery.json from the web client's crypto (shared/crypto/crypto.js).

Recovery keys (docs/how-napsack-works.md): a fixed 20-byte key, its display
form, the auth key derived from it, and Alice's private key (format1.json)
wrapped by it. Run once; the output is pinned, so this refuses to overwrite
the file. Every client must reproduce these values exactly.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_recovery.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "recovery.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const bytes = Uint8Array.from({ length: 20 }, (_, i) => (i * 29 + 3) % 256);
  const recoveryKey = e2e.formatRecoveryKey(bytes);
  const rec = await e2e.deriveFromRecoveryKey(recoveryKey);
  const pw = await e2e.deriveFromPassword(v1.password.username, v1.password.password);
  return {
    about: 'napsack recovery key test vectors. Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    key_bytes_hex: Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(''),
    recovery_key: recoveryKey,
    recovery_auth_key: rec.authKey,
    recovery_wrapped_key: await e2e.wrapForRecovery(pw.wrapKey, v1.password.wrapped_private_key, rec.wrapKey),
  };
}"""


async def main():
    if os.path.exists(OUT):
        sys.exit(f"{OUT} exists. Recovery vectors are pinned; don't regenerate them.")
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
