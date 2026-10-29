// The server's answers, kept on this device so napsack opens at once and
// keeps working on a slow connection (plan X31): the chat list, groups, the
// newest page of each chat, and who you are. What's kept is exactly what the
// server sent, so messages stay encrypted here and are decrypted only when
// shown (callers store a copy taken before decrypting). Pics are never kept:
// they're view-once. Signing out deletes all of it.
//
// A database of its own, apart from the keys (keystore.js). Everything here
// is optional: if the browser won't store it (a private window, a full
// disk), napsack loads from the server as before.
const DB_NAME = "napsack-cache";
const STORE = "responses";

let opening = null;
function idb() {
  opening ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  }).catch((err) => {
    opening = null;
    throw err;
  });
  return opening;
}

async function run(mode, fn) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const req = fn(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(req?.result);
    tx.onerror = () => reject(tx.error);
  });
}

/** What was kept under `key`, or undefined. Never throws. */
export async function get(key) {
  try {
    return (await run("readonly", (s) => s.get(key)))?.value;
  } catch {
    return undefined;
  }
}

/** Keeps `value` (a server answer, as sent) under `key`. Never throws. */
export async function put(key, value) {
  try {
    await run("readwrite", (s) => s.put({ value, at: Date.now() }, key));
  } catch {
    // Not kept this time; the next load from the server tries again.
  }
}

/** Everything kept, for signing out. */
export async function clear() {
  try {
    await run("readwrite", (s) => s.clear());
  } catch {
    // Nothing was kept, or the browser forgot it already.
  }
}

/** Every key and value kept (for tests and diagnostics). */
export async function all() {
  try {
    const [keys, values] = await Promise.all([run("readonly", (s) => s.getAllKeys()), run("readonly", (s) => s.getAll())]);
    return keys.map((k, i) => [k, values[i]]);
  } catch {
    return [];
  }
}
