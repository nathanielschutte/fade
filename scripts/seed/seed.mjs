#!/usr/bin/env node
// Fills an empty napsack with a few friends and their chats (story.mjs),
// through the API, encrypted exactly as the web app does it: the same
// crypto.js, the same message formats, so the web and iOS apps read it like
// anything a person sent. Run by scripts/reset-staging.sh after it empties
// staging, and by tests/e2e/test_seed.py against the test server. Never
// production: it refuses any server but this machine's and staging's.
//
//   NAPSACK_URL=http://127.0.0.1:8080 NAPSACK_INVITE=letmein node scripts/seed/seed.mjs
//   node scripts/seed/seed.mjs --url http://127.0.0.1:8080 --tag x7   (usernames end in _x7)
//
// Everyone's password is the test password: NAPSACK_PASSWORD, or for this
// machine's server the public one (LOCAL_PASSWORD in tests/e2e/common.py).
// The accounts must not exist yet (it stops at the first that does), except
// the admin's, which it signs in to if a test already made it.

import { readFileSync } from "node:fs";
import * as e2e from "../../shared/crypto/crypto.js";
import { PEOPLE, FRIENDS, PENDING, NICKNAMES, CHATS, GROUPS } from "./story.mjs";
import * as pictures from "./pictures.mjs";

const args = process.argv.slice(2);
const arg = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const BASE = (arg("--url") || process.env.NAPSACK_URL || "http://127.0.0.1:8080").replace(/\/+$/, "");
const INVITE = process.env.NAPSACK_INVITE || "";
const TAG = arg("--tag");
// The tests' password: NAPSACK_PASSWORD (staging's own, which reset-staging.sh
// sets), or else a local server's public one from common.py.
const LOCAL_PASSWORD = readFileSync(new URL("../../tests/e2e/common.py", import.meta.url), "utf8")
  .match(/^LOCAL_PASSWORD = "(.+)"$/m)?.[1];
if (!LOCAL_PASSWORD) throw new Error("no LOCAL_PASSWORD in tests/e2e/common.py");
const PASSWORD = process.env.NAPSACK_PASSWORD || LOCAL_PASSWORD;

const counts = { people: 0, friendships: 0, texts: 0, reactions: 0, edits: 0, groups: 0, group_messages: 0, group_reactions: 0, pics: 0 };

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function api(path, { token, method = "GET", json, body, headers = {} } = {}) {
  const h = { "User-Agent": "napsack-seed", ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  if (json !== undefined) {
    h["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  }
  const res = await fetch(`${BASE}/api${path}`, { method, headers: h, body });
  const text = await res.text();
  if (!res.ok) {
    let why = text;
    try { why = JSON.parse(text).error ?? text; } catch {}
    throw new ApiError(res.status, `${method} ${path}: ${res.status} ${why}`);
  }
  return text ? JSON.parse(text) : null;
}

/** This machine's test server, or staging. Never production, never anything else. */
async function checkServer() {
  const url = new URL(BASE);
  const local = ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  const staging = url.protocol === "https:" && url.hostname.startsWith("staging.");
  // By its address before sending it anything, then by what it says it is.
  if (!local && !staging) {
    console.error(`refusing: ${BASE} is neither this machine nor staging`);
    process.exit(1);
  }
  if (!local && PASSWORD === LOCAL_PASSWORD) {
    console.error(`refusing: ${BASE} isn't this machine, and the password is the public one. Set NAPSACK_PASSWORD.`);
    process.exit(1);
  }
  const config = await api("/config");
  if (staging && config.environment !== "staging") {
    console.error(`refusing: ${BASE} doesn't say it's staging`);
    process.exit(1);
  }
  if (config.invite_required && !INVITE && !TAG) console.warn("no NAPSACK_INVITE: sign-ups will be refused");
  return config;
}

const clientId = () => e2e.toB64(crypto.getRandomValues(new Uint8Array(16))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const username = (key) => (TAG ? `${PEOPLE[key].username}_${TAG}` : PEOPLE[key].username);

/** Signs up as the web app does: keys from the password, a key pair, a recovery key. */
async function signUp(key, config, { orSignIn = false } = {}) {
  const name = username(key);
  const { authKey, wrapKey } = await e2e.deriveFromPassword(name, PASSWORD);
  const identity = await e2e.createIdentity(wrapKey);
  let res, privateKey = identity.privateKey;
  try {
    res = await api("/auth/register", { method: "POST", json: {
      username: name, auth_key: authKey,
      invite_code: config.invite_required ? INVITE : undefined,
      public_key: identity.publicKey, wrapped_private_key: identity.wrappedPrivateKey,
    } });
    // The web app sets a recovery key at sign-up. Nobody keeps this one: the
    // password is known, and it keeps the "save a recovery key" nudge away.
    const recovery = await e2e.deriveFromRecoveryKey(e2e.newRecoveryKey());
    await api("/me/recovery", { token: res.token, method: "PUT", json: {
      auth_key: authKey, recovery_auth_key: recovery.authKey,
      recovery_wrapped_key: await e2e.wrapForRecovery(wrapKey, res.wrapped_private_key, recovery.wrapKey),
    } });
    counts.people++;
  } catch (err) {
    if (err.status !== 409) throw err;
    if (!orSignIn) {
      console.error(`${name} already exists on ${BASE}: it already has the seed (or part of it). `
        + "Start from an empty database (scripts/reset-staging.sh for staging).");
      process.exit(1);
    }
    res = await api("/auth/login", { method: "POST", json: { username: name, auth_key: authKey } }).catch((e) => {
      throw new Error(`${name} exists but doesn't take the test password (${e.message})`);
    });
    privateKey = await e2e.unwrapIdentity(wrapKey, res.wrapped_private_key);
  }
  return { key, username: name, id: res.user.id, token: res.token, privateKey, publicKey: res.public_key };
}

const pairKeys = new Map();
/** The key two friends share, from the sender's side (it's the same from either). */
function pairKey(from, to) {
  const k = [from.id, to.id].sort().join(":");
  if (!pairKeys.has(k)) pairKeys.set(k, e2e.pairKey(from.privateKey, to.publicKey, from.id, to.id));
  return pairKeys.get(k);
}

async function sendText(from, to, text, replyTo) {
  const ciphertext = await e2e.encryptText2(await pairKey(from, to), text, replyTo, from.id, to.id);
  counts.texts++;
  return api(`/chats/${to.id}/messages`, { token: from.token, method: "POST",
    json: { ciphertext, format: e2e.TEXT_FORMAT, client_id: clientId() } });
}

async function react(who, other, messageId, emoji) {
  const ciphertext = await e2e.encryptReaction(await pairKey(who, other), emoji, who.id, other.id, messageId);
  await api(`/chats/${other.id}/messages/${messageId}/reaction`, { token: who.token, method: "PUT", json: { ciphertext, format: 2 } });
  counts.reactions++;
}

async function edit(from, to, messageId, text) {
  const ciphertext = await e2e.encryptEdit(await pairKey(from, to), text, from.id, to.id, messageId);
  await api(`/chats/${to.id}/messages/${messageId}/edit`, { token: from.token, method: "PUT",
    json: { ciphertext, format: 2, client_id: clientId() } });
  counts.edits++;
}

async function sendPic(from, to, photo, caption, y) {
  const sealed = await e2e.encryptImage(await pairKey(from, to), photo, caption, from.id, to.id, y);
  await api(`/chats/${to.id}/snaps?format=${e2e.IMAGE_FORMAT}&client_id=${clientId()}`, { token: from.token, method: "POST",
    body: sealed, headers: { "Content-Type": "application/octet-stream" } });
  counts.pics++;
}

/** A direct chat: its texts in order, the reactions and edits along the way. */
async function seedChat(chat, people) {
  const a = people[chat.a], b = people[chat.b];
  const sent = [];
  // Both have read everything but the last two lines.
  const readAt = chat.lines.length - 2;
  for (const [i, [who, text, extra = {}]] of chat.lines.entries()) {
    if (i === readAt) {
      await api(`/chats/${b.id}/read`, { token: a.token, method: "POST" });
      await api(`/chats/${a.id}/read`, { token: b.token, method: "POST" });
    }
    const [from, to] = who === "a" ? [a, b] : [b, a];
    const m = await sendText(from, to, text, extra.re ? sent[i - extra.re].id : null);
    sent.push(m);
    if (extra.edit) await edit(from, to, m.id, extra.edit);
    if (extra.react) await react(to, from, m.id, extra.react);
  }
  if (chat.pic) {
    const [from, to] = chat.pic.from === "a" ? [a, b] : [b, a];
    await sendPic(from, to, pictures.sunset(720, 960), chat.pic.caption, chat.pic.y);
  }
}

/** Seals something for every member, as the web app's sealFor does. */
async function sealFor(group, from, seal) {
  const wrapKeys = new Map();
  for (const m of group.members) wrapKeys.set(m.id, await e2e.groupWrapKey(from.privateKey, m.public_key, from.id, m.id));
  return seal({ groupId: group.id, senderId: from.id, wrapKeys });
}

async function seedGroup(spec, people) {
  const owner = people[spec.owner];
  const created = await api("/groups", { token: owner.token, method: "POST",
    json: { name: spec.name, member_ids: spec.members.map((k) => people[k].id) } });
  const group = await api(`/groups/${created.id}`, { token: owner.token });
  counts.groups++;
  const picture = pictures[spec.picture](512, 512);
  await api(`/groups/${group.id}/avatar`, { token: owner.token, method: "POST", body: picture, headers: { "Content-Type": "image/jpeg" } });

  const everyone = [spec.owner, ...spec.members];
  const sent = [];
  const readAt = spec.lines.length - 3;
  for (const [i, [who, text, extra = {}]] of spec.lines.entries()) {
    if (i === readAt) {
      for (const k of everyone) await api(`/groups/${group.id}/read`, { token: people[k].token, method: "POST" });
    }
    const from = people[who];
    const replyTo = extra.re ? sent[i - extra.re].id : null;
    const s = await sealFor(group, from, (opts) => e2e.encryptGroupText(text, replyTo, opts));
    const m = await api(`/groups/${group.id}/messages`, { token: from.token, method: "POST", json: {
      format: e2e.GROUP_FORMAT, content: e2e.toB64(s.content), client_id: s.clientId, recipients: s.recipients, wraps: s.wraps,
    } });
    counts.group_messages++;
    sent.push(m);
    for (const [k, emoji] of Object.entries(extra.react || {})) {
      await api(`/groups/${group.id}/messages/${m.id}/reaction`, { token: people[k].token, method: "PUT", json: { emoji } });
      counts.group_reactions++;
    }
  }
  if (spec.pic) {
    const from = people[spec.pic.from];
    const s = await sealFor(group, from, (opts) => e2e.encryptGroupImage(pictures.mountains(720, 960), spec.pic.caption, opts, spec.pic.y));
    await api(`/groups/${group.id}/pics?format=${e2e.GROUP_IMAGE_FORMAT}`, { token: from.token, method: "POST", body: s.content, headers: {
      "Content-Type": "application/octet-stream",
      "X-Napsack-Keys": JSON.stringify({ client_id: s.clientId, recipients: s.recipients, wraps: s.wraps }),
    } });
    counts.pics++;
  }
}

async function main() {
  const started = Date.now();
  const config = await checkServer();
  console.log(`seeding ${BASE} (${config.environment ?? "local"}, build ${config.build})`);

  // Everyone but the admin first: if the seed is already there, nothing is written.
  const people = {};
  for (const key of Object.keys(PEOPLE).filter((k) => k !== "admin")) people[key] = await signUp(key, config);
  people.admin = await signUp("admin", config, { orSignIn: true });

  for (const [key, p] of Object.entries(PEOPLE)) {
    if (!p.name) continue;
    const token = people[key].token;
    await api("/me/name", { token, method: "PUT", json: { name: p.name } });
    await api("/me/avatar", { token, method: "POST", body: pictures.avatar(p.hue), headers: { "Content-Type": "image/jpeg" } });
    if (p.birthday) await api("/me/birthday", { token, method: "PUT", json: p.birthday });
  }

  for (const [asker, asked] of [...FRIENDS, PENDING]) {
    await api("/friends/requests", { token: people[asker].token, method: "POST", json: { username: people[asked].username } });
    if (asker === PENDING[0] && asked === PENDING[1]) continue;
    await api(`/friends/requests/${people[asker].id}/accept`, { token: people[asked].token, method: "POST" });
    counts.friendships++;
  }
  for (const [who, friend, name] of NICKNAMES) {
    await api(`/friends/${people[friend].id}/nickname`, { token: people[who].token, method: "PUT", json: { name } });
  }

  for (const chat of CHATS) await seedChat(chat, people);
  for (const group of GROUPS) await seedGroup(group, people);

  // Signed out again, so the seed leaves no session behind.
  for (const p of Object.values(people)) await api("/auth/logout", { token: p.token, method: "POST" });

  const secs = ((Date.now() - started) / 1000).toFixed(1);
  console.log(`done in ${secs}s: ${Object.entries(counts).map(([k, v]) => `${v} ${k.replace("_", " ")}`).join(", ")}`);
  console.log(`  pending request: ${people[PENDING[0]].username} -> ${people[PENDING[1]].username}`);
  console.log(`  sign in as any of: ${Object.values(people).map((p) => p.username).join(", ")}`);
  console.log(PASSWORD === LOCAL_PASSWORD
    ? `  password: ${PASSWORD} (the test password, tests/e2e/common.py)`
    : "  password: NAPSACK_PASSWORD (staging's test password, from its tfvars)");
}

main().catch((err) => {
  console.error(`seed failed: ${err.message}`);
  process.exit(1);
});
