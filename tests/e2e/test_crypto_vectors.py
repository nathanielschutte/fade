"""Unit tests for the web client's crypto.js, run in a real browser.

Checks the pinned format 1 vectors (tests/vectors/format1.json) byte for byte,
plus the properties the design relies on: tampering and misattribution fail,
both friends derive the same key, and IVs are fresh. A failure here means a
change would make existing messages unreadable. Don't "fix" it by editing the
vectors. Settings come from the environment; see common.py."""
import asyncio, json, os
from playwright.async_api import async_playwright

from common import BASE, launch

VECTORS = os.path.join(os.path.dirname(__file__), "..", "vectors", "format1.json")

CHECKS = """async (v) => {
  const e2e = await import('/crypto.js');
  const s = crypto.subtle;
  const ECDH = { name: 'ECDH', namedCurve: 'P-256' };
  const priv = (p) => s.importKey('pkcs8', e2e.fromB64(p.pkcs8), ECDH, false, ['deriveBits']);
  const fails = async (f) => { try { await f(); return false; } catch { return true; } };
  const results = {};
  const check = (name, ok) => { results[name] = Boolean(ok); };

  // Password -> keys
  const d = await e2e.deriveFromPassword(v.password.username, v.password.password);
  check('auth key matches vector', d.authKey === v.password.auth_key);
  const lower = await e2e.deriveFromPassword(v.password.username.toLowerCase(), v.password.password);
  check('username is case-insensitive', lower.authKey === v.password.auth_key);
  const wrong = await e2e.deriveFromPassword(v.password.username, v.password.password + '!');
  check('different password, different auth key', wrong.authKey !== v.password.auth_key);

  // Wrapped identity
  const unwrapped = await e2e.unwrapIdentity(d.wrapKey, v.password.wrapped_private_key);
  const k1 = await e2e.pairKey(unwrapped, v.bob.spki, v.alice.id, v.bob.id);
  const t1 = await e2e.decryptText(k1, v.text.ciphertext, v.text.from, v.text.to);
  check('unwrapped key decrypts vector text', t1 === v.text.plaintext);
  check('wrong password cannot unwrap', await fails(() => e2e.unwrapIdentity(wrong.wrapKey, v.password.wrapped_private_key)));

  // Both sides derive the same chat key
  const alice = await priv(v.alice), bob = await priv(v.bob);
  const kb = await e2e.pairKey(bob, v.alice.spki, v.bob.id, v.alice.id);
  check('recipient decrypts vector text', await e2e.decryptText(kb, v.text.ciphertext, v.text.from, v.text.to) === v.text.plaintext);
  const snap = await e2e.decryptSnap(kb, e2e.fromB64(v.snap.ciphertext_b64), v.snap.from, v.snap.to);
  check('recipient decrypts vector snap', e2e.toB64(snap) === v.snap.plaintext_b64);
  const ka = await e2e.pairKey(alice, v.bob.spki, v.alice.id, v.bob.id);
  const fresh = await e2e.encryptText(ka, 'round trip', v.alice.id, v.bob.id);
  check('fresh message round-trips', await e2e.decryptText(kb, fresh, v.alice.id, v.bob.id) === 'round trip');
  check('IVs are fresh', fresh !== await e2e.encryptText(ka, 'round trip', v.alice.id, v.bob.id));

  // Associated data binds sender, recipient, and kind
  check('swapped sender fails', await fails(() => e2e.decryptText(kb, v.text.ciphertext, v.text.to, v.text.from)));
  check('text cannot be read as a snap', await fails(() => e2e.decryptSnap(kb, e2e.fromB64(v.text.ciphertext), v.text.from, v.text.to)));
  const tampered = e2e.fromB64(v.text.ciphertext); tampered[20] ^= 1;
  check('tampering fails', await fails(() => e2e.decryptText(kb, e2e.toB64(tampered), v.text.from, v.text.to)));
  const outsider = (await s.generateKey(ECDH, false, ['deriveBits'])).privateKey;
  const ko = await e2e.pairKey(outsider, v.alice.spki, 99, v.alice.id);
  check('a third key cannot decrypt', await fails(() => e2e.decryptText(ko, v.text.ciphertext, v.text.from, v.text.to)));

  // Safety code
  check('safety code matches vector', await e2e.safetyCode(v.alice.spki, v.bob.spki) === v.safety_code);
  check('safety code is symmetric', await e2e.safetyCode(v.bob.spki, v.alice.spki) === v.safety_code);
  check('format is 1', e2e.FORMAT === 1);
  return results;
}"""


async def main():
    with open(VECTORS, encoding="utf-8") as f:
        vectors = json.load(f)
    async with async_playwright() as pw:
        browser = await launch(pw)
        page = await browser.new_page()
        await page.goto(BASE)
        results = await page.evaluate(CHECKS, vectors)
        await browser.close()
    for name, ok in results.items():
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    assert all(results.values()), [n for n, ok in results.items() if not ok]
    print(f"CRYPTO VECTORS PASSED ({len(results)} checks)")


asyncio.run(main())
