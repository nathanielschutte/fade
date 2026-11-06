// The server's answers, kept on this device so napsack opens at once and
// keeps working on a slow connection (plan X31): the chat list, groups, the
// newest page of each chat, and who you are. What's kept is exactly what the
// server sent, so messages stay encrypted here and are decrypted only when
// shown (callers store a copy taken before decrypting). Pics are never kept:
// they're view-once. Signing out deletes all of it, and the database itself
// (app.js, forgetEverything); signing in starts it empty.
//
// A database of its own, apart from the keys (keystore.js). Everything here
// is optional: if the browser won't store it (a private window, a full
// disk), napsack loads from the server as before.
export const DB_NAME = "napsack-cache";
const STORE = "responses";

let opening = null;
// Set once signing out has emptied it (or another tab is deleting it): nothing
// is kept again before the page reloads.
let forgotten = false;
function idb() {
  if (forgotten) return Promise.reject(new Error("signed out"));
  opening ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    // Waiting behind a deletion another tab holds up (one of an older napsack,
    // as this one signs out): napsack goes on without what was kept.
    let gaveUp = false;
    const late = setTimeout(() => {
      gaveUp = true;
      reject(new Error("the kept answers are busy"));
    }, 2000);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => {
      clearTimeout(late);
      const db = req.result;
      if (gaveUp) {
        db.close();
        return;
      }
      // Another tab signing out deletes it: let go at once, so the deletion
      // isn't kept waiting, and keep nothing more (this tab reloads too, app.js).
      db.onversionchange = () => {
        forgotten = true;
        db.close();
      };
      resolve(db);
    };
    req.onerror = () => {
      clearTimeout(late);
      reject(req.error);
    };
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

/** Everything kept, gone: signing in, so nothing an earlier account left is used. */
export async function clear() {
  try {
    await run("readwrite", (s) => s.clear());
  } catch {
    // Nothing was kept, or the browser forgot it already.
  }
}

/** Only the keys `keep` says yes to stay (another account's, left by a tab
 * that never signed out). Never throws. */
export async function keepOnly(keep) {
  try {
    const keys = await run("readonly", (s) => s.getAllKeys());
    const gone = keys.filter((k) => !keep(String(k)));
    if (gone.length) await run("readwrite", (s) => { for (const k of gone) s.delete(k); });
  } catch {
    // Nothing was kept, or the browser forgot it already.
  }
}

/** Signing out: everything, then the connection closes, so the database can
 * be deleted, and nothing is kept again until the page reloads. */
export async function forget() {
  await clear();
  forgotten = true;
  try {
    (await opening)?.close();
  } catch {
    // It never opened.
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
