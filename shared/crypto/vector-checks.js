// Every client runs these against the pinned vectors (tests/vectors/): Node in
// CI (vectors.test.js) and the iOS app's spike screen on a real iPhone. The
// browser runs the same checks in tests/e2e/test_crypto_vectors.py. A failure
// means that client would disagree with the others about bytes on the wire.

/**
 * @typedef {{ name: string, ok: boolean, ms: number, error?: string }} CheckResult
 */

/**
 * @param {typeof import("./crypto.js")} e2e
 * @param {any} v  tests/vectors/format1.json
 * @param {any} v2 tests/vectors/format2.json
 * @param {(r: CheckResult) => void} [onResult] called as each check finishes
 * @returns {Promise<CheckResult[]>}
 */
export async function runVectorChecks(e2e, v, v2, onResult = () => {}) {
  const s = globalThis.crypto.subtle;
  const ECDH = { name: "ECDH", namedCurve: "P-256" };
  const priv = (p) => s.importKey("pkcs8", e2e.fromB64(p.pkcs8), ECDH, false, ["deriveBits"]);
  const fails = async (f) => { try { await f(); return false; } catch { return true; } };
  const results = [];
  const ctx = {};

  async function check(name, fn) {
    const start = Date.now();
    let ok = false, error;
    try {
      ok = Boolean(await fn());
    } catch (err) {
      error = String(err?.message ?? err);
    }
    const r = { name, ok, ms: Date.now() - start, ...(error ? { error } : {}) };
    results.push(r);
    onResult(r);
  }

  // The platform has what crypto.js needs.
  await check("crypto.subtle is available", () => typeof s?.importKey === "function");
  await check("TextEncoder and TextDecoder work", () =>
    new TextDecoder().decode(new TextEncoder().encode("napsack \u{1F33F}")) === "napsack \u{1F33F}");
  await check("base64 round-trips", () => e2e.toB64(e2e.fromB64("AAEC/w==")) === "AAEC/w==");

  // Password -> keys (the slow one: 600,000 rounds of PBKDF2)
  await check("password derives the vector's auth key", async () => {
    ctx.d = await e2e.deriveFromPassword(v.password.username, v.password.password);
    return ctx.d.authKey === v.password.auth_key;
  });
  await check("username is case-insensitive", async () =>
    (await e2e.deriveFromPassword(v.password.username.toLowerCase(), v.password.password)).authKey === v.password.auth_key);
  await check("unwrapped key decrypts the vector text", async () => {
    const unwrapped = await e2e.unwrapIdentity(ctx.d.wrapKey, v.password.wrapped_private_key);
    const k = await e2e.pairKey(unwrapped, v.bob.spki, v.alice.id, v.bob.id);
    return (await e2e.decryptText(k, v.text.ciphertext, v.text.from, v.text.to)) === v.text.plaintext;
  });
  await check("a wrong password can't unwrap", async () => {
    const wrong = await e2e.deriveFromPassword(v.password.username, "wrong password");
    return fails(() => e2e.unwrapIdentity(wrong.wrapKey, v.password.wrapped_private_key));
  });

  // Both sides derive the same chat key (ECDH + HKDF)
  await check("both friends derive the chat key", async () => {
    ctx.ka = await e2e.pairKey(await priv(v.alice), v.bob.spki, v.alice.id, v.bob.id);
    ctx.kb = await e2e.pairKey(await priv(v.bob), v.alice.spki, v.bob.id, v.alice.id);
    return true;
  });
  await check("recipient decrypts the vector text", async () =>
    (await e2e.decryptText(ctx.kb, v.text.ciphertext, v.text.from, v.text.to)) === v.text.plaintext);
  await check("recipient decrypts the vector pic (format 1)", async () =>
    e2e.toB64(await e2e.decryptSnap(ctx.kb, e2e.fromB64(v.snap.ciphertext_b64), v.snap.from, v.snap.to)) === v.snap.plaintext_b64);
  await check("a fresh text round-trips with a fresh IV", async () => {
    const a = await e2e.encryptText(ctx.ka, "round trip", v.alice.id, v.bob.id);
    const b = await e2e.encryptText(ctx.ka, "round trip", v.alice.id, v.bob.id);
    return a !== b && (await e2e.decryptText(ctx.kb, a, v.alice.id, v.bob.id)) === "round trip";
  });

  // Associated data binds sender, recipient, and kind
  await check("swapped sender fails", () => fails(() => e2e.decryptText(ctx.kb, v.text.ciphertext, v.text.to, v.text.from)));
  await check("a text can't be read as a pic", () =>
    fails(() => e2e.decryptSnap(ctx.kb, e2e.fromB64(v.text.ciphertext), v.text.from, v.text.to)));
  await check("tampering fails", () => {
    const t = e2e.fromB64(v.text.ciphertext);
    t[20] ^= 1;
    return fails(() => e2e.decryptText(ctx.kb, e2e.toB64(t), v.text.from, v.text.to));
  });

  // Format 2: pics with captions
  for (const name of ["pic", "pic_no_caption"]) {
    const p = v2[name];
    await check(`recipient decrypts format 2 ${name}`, async () => {
      const got = await e2e.decryptPic(ctx.kb, e2e.fromB64(p.ciphertext_b64), 2, p.from, p.to);
      return got.caption === p.caption && e2e.toB64(got.photo) === p.photo_b64;
    });
    await check(`packs ${name} like the vector`, () =>
      e2e.toB64(e2e.packPic(e2e.fromB64(p.photo_b64), p.caption)) === p.plaintext_b64);
  }
  await check("format 2 can't be read as format 1", () =>
    fails(() => e2e.decryptPic(ctx.kb, e2e.fromB64(v2.pic.ciphertext_b64), 1, v2.pic.from, v2.pic.to)));
  await check("a captioned pic round-trips", async () => {
    const sealed = await e2e.encryptPic(ctx.ka, new Uint8Array([1, 2, 3]), "hi \u{1F44B}", v.alice.id, v.bob.id);
    const back = await e2e.decryptPic(ctx.kb, sealed, 2, v.alice.id, v.bob.id);
    return back.caption === "hi \u{1F44B}" && Array.from(back.photo).join() === "1,2,3";
  });

  // A new account's keys, the way sign-up makes them
  await check("a new identity wraps and unwraps", async () => {
    const id = await e2e.createIdentity(ctx.d.wrapKey);
    const back = await e2e.unwrapIdentity(ctx.d.wrapKey, id.wrappedPrivateKey);
    const k1 = await e2e.pairKey(back, v.bob.spki, 1, v.bob.id);
    const k2 = await e2e.pairKey(await priv(v.bob), id.publicKey, v.bob.id, 1);
    return (await e2e.decryptText(k2, await e2e.encryptText(k1, "new", 1, v.bob.id), 1, v.bob.id)) === "new";
  });

  // Safety code and formats
  await check("safety code matches the vector", async () => (await e2e.safetyCode(v.alice.spki, v.bob.spki)) === v.safety_code);
  await check("safety code is symmetric", async () => (await e2e.safetyCode(v.bob.spki, v.alice.spki)) === v.safety_code);
  await check("texts are format 1, pics format 2", () => e2e.TEXT_FORMAT === 1 && e2e.SNAP_FORMAT === 2);
  return results;
}
