"""Generates tests/vectors/passkey1.json from the web client's crypto (shared/crypto/crypto.js).

Passkeys (docs/design/passkeys.md): the PRF input every napsack passkey is
asked for, a fixed PRF secret standing in for what a passkey answers, and
Alice's private key (format1.json) wrapped by the key derived from it. Run
once; the output is pinned, so this refuses to overwrite the file. Every
client must open it exactly.

    NAPSACK_URL=http://127.0.0.1:8099 python3 tests/vectors/generate_passkey1.py
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "e2e"))
from common import BASE, launch  # noqa: E402

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "passkey1.json")

GENERATE = """async (v1) => {
  const e2e = await import('/crypto.js');
  const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  const secret = Uint8Array.from({ length: 32 }, (_, i) => (i * 37 + 11) % 256);
  const pw = await e2e.deriveFromPassword(v1.password.username, v1.password.password);
  const passkeyKey = await e2e.deriveFromPasskey(secret);
  return {
    about: 'napsack passkey test vectors. Keys are format1.json. Generated once from shared/crypto/crypto.js; never regenerate.',
    prf_input_hex: hex(await e2e.passkeyPrfInput()),
    prf_secret_hex: hex(secret),
    passkey_wrapped_key: await e2e.wrapForPasskey(pw.wrapKey, v1.password.wrapped_private_key, passkeyKey),
  };
}"""


async def main():
    if os.path.exists(OUT):
        sys.exit(f"{OUT} exists. Passkey vectors are pinned; don't regenerate them.")
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
