// Every client runs these against the pinned vectors (tests/vectors/): Node in
// CI (vectors.test.js) and the iOS app's spike screen on a real iPhone. The
// browser runs the same checks in tests/e2e/test_crypto_vectors.py. A failure
// means that client would disagree with the others about bytes on the wire.

/**
 * @typedef {{ name: string, ok: boolean, ms: number, error?: string }} CheckResult
 */

/**
 * @param {typeof import("./crypto.js")} e2e
 * @param {{ format1: any, format2: any, recovery: any, texts2: any, group3?: any, media4?: any, edits2?: any }} vectors the files in tests/vectors/
 * @param {(r: CheckResult) => void} [onResult] called as each check finishes
 * @returns {Promise<CheckResult[]>}
 */
export async function runVectorChecks(e2e, vectors, onResult = () => {}) {
  const { format1: v, format2: v2, recovery: vr, texts2: vt, group3: vg, media4: vm, edits2: ve } = vectors;
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

  // Format 2 texts (replies) and reactions
  for (const [i, t] of vt.texts.entries()) {
    await check(`format 2 text ${i + 1} decrypts like the vector`, async () => {
      const got = await e2e.decryptAnyText(ctx.kb, t.ciphertext, 2, t.from, t.to);
      return got.text === t.text && got.replyTo === t.reply_to && e2e.packText(t.text, t.reply_to) === t.plaintext;
    });
  }
  await check("format 1 texts still read, with no reply", async () => {
    const got = await e2e.decryptAnyText(ctx.kb, v.text.ciphertext, 1, v.text.from, v.text.to);
    return got.text === v.text.plaintext && got.replyTo === null;
  });
  await check("a format 2 text can't be read as format 1", () =>
    fails(() => e2e.decryptAnyText(ctx.kb, vt.texts[0].ciphertext, 1, vt.texts[0].from, vt.texts[0].to)));
  await check("unknown envelope fields are ignored", () => {
    const got = e2e.unpackText('{"t":"later","re":7,"future":true}');
    return got.text === "later" && got.replyTo === 7;
  });
  await check("malformed envelopes are refused", () =>
    ['{"x":1}', "not json", '{"t":5}'].every((j) => { try { e2e.unpackText(j); return false; } catch { return true; } }));
  const r = vt.reaction;
  await check("reaction decrypts like the vector", async () =>
    (await e2e.decryptReaction(ctx.kb, r.ciphertext, r.from, r.to, r.message_id)) === r.emoji);
  await check("a reaction can't move to another message", () =>
    fails(() => e2e.decryptReaction(ctx.kb, r.ciphertext, r.from, r.to, r.message_id + 1)));
  await check("a reaction round-trips", async () => {
    const ct = await e2e.encryptReaction(ctx.ka, e2e.REACTIONS[1], v.alice.id, v.bob.id, 42);
    return (await e2e.decryptReaction(ctx.kb, ct, v.alice.id, v.bob.id, 42)) === e2e.REACTIONS[1];
  });

  // Format 3 group messages (docs/implementation/group-encryption.md)
  if (vg) {
    const opts = (m, myId, wrapKey) => ({
      groupId: vg.group_id, senderId: vg.sender, myId, clientId: m.client_id, recipients: m.recipients, wrapKey });
    await check("group wrap keys for bob and alice", async () => {
      ctx.gb = await e2e.groupWrapKey(await priv(v.bob), v.alice.spki, v.bob.id, v.alice.id);
      ctx.ga = await e2e.groupWrapKey(await priv(v.alice), v.alice.spki, v.alice.id, v.alice.id);
      return true;
    });
    await check("group text decrypts like the vector", async () => {
      const t = vg.text;
      const got = await e2e.decryptGroupText(e2e.fromB64(t.content), t.wraps[v.bob.id], opts(t, v.bob.id, ctx.gb));
      return got.text === t.text && got.replyTo === t.reply_to && e2e.packText(t.text, t.reply_to) === t.plaintext;
    });
    await check("the sender's own devices read it too", async () => {
      const t = vg.text;
      return (await e2e.decryptGroupText(e2e.fromB64(t.content), t.wraps[v.alice.id], opts(t, v.alice.id, ctx.ga))).text === t.text;
    });
    await check("group pic decrypts like the vector, caption and all", async () => {
      const p = vg.pic;
      const got = await e2e.decryptGroupPic(e2e.fromB64(p.content), p.wraps[v.bob.id], opts(p, v.bob.id, ctx.gb));
      return got.caption === p.caption && e2e.toB64(got.photo) === p.photo;
    });
    await check("one member's wrap doesn't open for another", () =>
      fails(() => e2e.decryptGroupText(e2e.fromB64(vg.text.content), vg.text.wraps[v.alice.id], opts(vg.text, v.bob.id, ctx.gb))));
    await check("a group message can't move to another group", () =>
      fails(() => e2e.decryptGroupText(e2e.fromB64(vg.text.content), vg.text.wraps[v.bob.id],
        { ...opts(vg.text, v.bob.id, ctx.gb), groupId: vg.group_id + 1 })));
    await check("or claim a different member list", () =>
      fails(() => e2e.decryptGroupText(e2e.fromB64(vg.text.content), vg.text.wraps[v.bob.id],
        { ...opts(vg.text, v.bob.id, ctx.gb), recipients: [...vg.text.recipients, 11] })));
    await check("a group text can't be read as a pic", () =>
      fails(() => e2e.decryptGroupPic(e2e.fromB64(vg.text.content), vg.text.wraps[v.bob.id], opts(vg.text, v.bob.id, ctx.gb))));
    await check("changed content fails", () => {
      const c = e2e.fromB64(vg.text.content);
      c[c.length - 1] ^= 1;
      return fails(() => e2e.decryptGroupText(c, vg.text.wraps[v.bob.id], opts(vg.text, v.bob.id, ctx.gb)));
    });
    await check("a new group message round-trips", async () => {
      const wrapKeys = new Map([
        [v.alice.id, await e2e.groupWrapKey(await priv(v.alice), v.alice.spki, v.alice.id, v.alice.id)],
        [v.bob.id, await e2e.groupWrapKey(await priv(v.alice), v.bob.spki, v.alice.id, v.bob.id)],
      ]);
      const m = await e2e.encryptGroupText("new", null, { groupId: 9, senderId: v.alice.id, wrapKeys });
      const got = await e2e.decryptGroupText(m.content, m.wraps[v.bob.id], {
        groupId: 9, senderId: v.alice.id, myId: v.bob.id, clientId: m.clientId, recipients: m.recipients, wrapKey: ctx.gb });
      return got.text === "new" && e2e.GROUP_FORMAT === 3 && Object.keys(m.wraps).length === 2;
    });
  }

  // Videos: format 4 (direct) and 5 (group), the media envelope
  if (vm) {
    const d = vm.direct, g = vm.group;
    await check("a format 4 video decrypts like the vector, caption and all", async () => {
      const got = await e2e.decryptVideo(ctx.kb, e2e.fromB64(d.ciphertext), d.from, d.to);
      return got.type === d.type && got.caption === d.caption && e2e.toB64(got.media) === d.media
        && e2e.toB64(e2e.packMedia(e2e.fromB64(d.media), d.type, d.caption)) === d.plaintext;
    });
    await check("a video can't be read as a pic", () =>
      fails(() => e2e.decryptPic(ctx.kb, e2e.fromB64(d.ciphertext), 2, d.from, d.to)));
    await check("a format 5 group video decrypts like the vector", async () => {
      const wrapKey = await e2e.groupWrapKey(await priv(v.bob), v.alice.spki, v.bob.id, v.alice.id);
      const got = await e2e.decryptGroupVideo(e2e.fromB64(g.content), g.wraps[v.bob.id], {
        groupId: g.group_id, senderId: g.sender, myId: v.bob.id, clientId: g.client_id, recipients: g.recipients, wrapKey });
      return got.type === g.type && got.caption === g.caption && e2e.toB64(got.media) === g.media;
    });
    await check("a group video can't be read as a group pic", async () => {
      const wrapKey = await e2e.groupWrapKey(await priv(v.bob), v.alice.spki, v.bob.id, v.alice.id);
      return fails(() => e2e.decryptGroupPic(e2e.fromB64(g.content), g.wraps[v.bob.id], {
        groupId: g.group_id, senderId: g.sender, myId: v.bob.id, clientId: g.client_id, recipients: g.recipients, wrapKey }));
    });
    await check("only video types travel in the envelope", async () => {
      const header = new TextEncoder().encode(JSON.stringify({ type: "text/html", c: "" }));
      const forged = new Uint8Array([0, header.length, ...header, 1, 2, 3]);
      return (await fails(() => e2e.packMedia(new Uint8Array([1]), "text/html", "")))
        && (await fails(() => e2e.unpackMedia(forged)));
    });
    await check("a video round-trips", async () => {
      const sealed = await e2e.encryptVideo(ctx.kb, new Uint8Array([9, 8, 7]), "video/mp4", "hi", v.alice.id, v.bob.id);
      const got = await e2e.decryptVideo(ctx.kb, sealed, v.alice.id, v.bob.id);
      return got.caption === "hi" && got.media.join() === "9,8,7" && e2e.VIDEO_FORMAT === 4 && e2e.GROUP_VIDEO_FORMAT === 5;
    });
  }

  // Edits to texts: bound to the message they edit
  if (ve) {
    const d = ve.direct, g = ve.group;
    await check("a direct edit decrypts like the vector", async () =>
      (await e2e.decryptEdit(ctx.kb, d.ciphertext, d.from, d.to, d.message_id)) === d.text
        && e2e.packText(d.text) === d.plaintext);
    await check("an edit can't be moved to another message", () =>
      fails(() => e2e.decryptEdit(ctx.kb, d.ciphertext, d.from, d.to, d.message_id + 1)));
    await check("an edit can't be read as a text", () =>
      fails(() => e2e.decryptAnyText(ctx.kb, d.ciphertext, 2, d.from, d.to)));
    await check("a group edit decrypts like the vector", async () => {
      const wrapKey = await e2e.groupWrapKey(await priv(v.bob), v.alice.spki, v.bob.id, v.alice.id);
      const opts = { groupId: g.group_id, senderId: g.sender, myId: v.bob.id, clientId: g.client_id, recipients: g.recipients, wrapKey };
      return (await e2e.decryptGroupEdit(e2e.fromB64(g.content), g.wraps[v.bob.id], g.message_id, opts)) === g.text
        && (await fails(() => e2e.decryptGroupEdit(e2e.fromB64(g.content), g.wraps[v.bob.id], g.message_id + 1, opts)));
    });
  }

  // Recovery keys and changing the password
  await check("recovery key displays like the vector", () => {
    const bytes = Uint8Array.from(vr.key_bytes_hex.match(/../g), (h) => parseInt(h, 16));
    return e2e.formatRecoveryKey(bytes) === vr.recovery_key;
  });
  await check("recovery key reads back despite typos", () => {
    const sloppy = vr.recovery_key.toLowerCase().replace(/-/g, " ").replace(/0/g, "o").replace(/1/g, "l");
    return e2e.toB64(e2e.parseRecoveryKey(sloppy)) === e2e.toB64(e2e.parseRecoveryKey(vr.recovery_key));
  });
  await check("recovery key derives the vector's auth key", async () => {
    ctx.rec = await e2e.deriveFromRecoveryKey(vr.recovery_key);
    return ctx.rec.authKey === vr.recovery_auth_key;
  });
  await check("recovery key unlocks the vector's private key", async () => {
    const next = await e2e.deriveFromPassword(v.password.username, "a brand new password");
    const got = await e2e.recoverIdentity(ctx.rec.wrapKey, vr.recovery_wrapped_key, next.wrapKey);
    const k = await e2e.pairKey(got.privateKey, v.bob.spki, v.alice.id, v.bob.id);
    const again = await e2e.unwrapIdentity(next.wrapKey, got.wrappedPrivateKey);
    const k2 = await e2e.pairKey(again, v.bob.spki, v.alice.id, v.bob.id);
    return (await e2e.decryptText(k, v.text.ciphertext, v.text.from, v.text.to)) === v.text.plaintext
      && (await e2e.decryptText(k2, v.text.ciphertext, v.text.from, v.text.to)) === v.text.plaintext;
  });
  await check("a recovery copy round-trips", async () => {
    const copy = await e2e.wrapForRecovery(ctx.d.wrapKey, v.password.wrapped_private_key, ctx.rec.wrapKey);
    const got = await e2e.recoverIdentity(ctx.rec.wrapKey, copy, ctx.d.wrapKey);
    const k = await e2e.pairKey(got.privateKey, v.bob.spki, v.alice.id, v.bob.id);
    return (await e2e.decryptText(k, v.text.ciphertext, v.text.from, v.text.to)) === v.text.plaintext;
  });
  await check("the password-wrapped key can't pass as a recovery copy", () =>
    fails(() => e2e.recoverIdentity(ctx.rec.wrapKey, v.password.wrapped_private_key, ctx.d.wrapKey)));
  await check("a wrong recovery key can't unlock", async () => {
    const wrong = await e2e.deriveFromRecoveryKey(e2e.newRecoveryKey());
    return fails(() => e2e.recoverIdentity(wrong.wrapKey, vr.recovery_wrapped_key, ctx.d.wrapKey));
  });
  await check("malformed recovery keys are refused", () =>
    ["", "ABCD-EFGH", "U".repeat(32), vr.recovery_key + "0"].every((t) => { try { e2e.parseRecoveryKey(t); return false; } catch { return true; } }));
  await check("changing the password keeps the same key", async () => {
    const next = await e2e.deriveFromPassword(v.password.username, "another new password");
    const rewrapped = await e2e.rewrapIdentity(ctx.d.wrapKey, v.password.wrapped_private_key, next.wrapKey);
    const k = await e2e.pairKey(await e2e.unwrapIdentity(next.wrapKey, rewrapped), v.bob.spki, v.alice.id, v.bob.id);
    return (await e2e.decryptText(k, v.text.ciphertext, v.text.from, v.text.to)) === v.text.plaintext
      && (await fails(() => e2e.unwrapIdentity(ctx.d.wrapKey, rewrapped)));
  });

  // Safety code and formats
  await check("safety code matches the vector", async () => (await e2e.safetyCode(v.alice.spki, v.bob.spki)) === v.safety_code);
  await check("safety code is symmetric", async () => (await e2e.safetyCode(v.bob.spki, v.alice.spki)) === v.safety_code);
  await check("new texts and pics are format 2", () => e2e.TEXT_FORMAT === 2 && e2e.SNAP_FORMAT === 2);
  return results;
}
