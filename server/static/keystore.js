// Where the web app keeps its unlocked key and pinned friend keys: IndexedDB.
// The unwrapped private key is a non-extractable CryptoKey, so page script can
// use it but never read it out, and a reload doesn't need the password.
// Signing out deletes all of it, pins included (Nate, 2026-11-06), and the
// database itself (app.js, forgetEverything). (The iOS app uses the Keychain instead.)
export const DB_NAME = "napsack";
const STORE = "keys";

// Set once signing out has emptied it: nothing is kept again before the page reloads.
let forgotten = false;

function idb() {
  if (forgotten) return Promise.reject(new Error("signed out"));
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => {
      const db = req.result;
      db.onversionchange = () => db.close(); // another tab deleting it (signing out) isn't kept waiting
      resolve(db);
    };
    req.onerror = () => reject(req.error);
  });
}

async function idbDo(mode, fn) {
  const db = await idb();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const req = fn(tx.objectStore(STORE));
      tx.oncomplete = () => resolve(req?.result);
      tx.onerror = () => reject(tx.error);
    });
  } finally {
    db.close();
  }
}

export const saveLocal = (key, value) => idbDo("readwrite", (s) => s.put(value, key));
export const loadLocal = (key) => idbDo("readonly", (s) => s.get(key));
export const deleteLocal = (key) => idbDo("readwrite", (s) => s.delete(key));

/** Everything kept, gone: signing in, so nothing an earlier account left is used. */
export const clear = () => idbDo("readwrite", (s) => s.clear());

/** Only the keys `keep` says yes to stay (another account's pins, left by an older napsack, go). */
export async function keepOnly(keep) {
  const keys = await idbDo("readonly", (s) => s.getAllKeys());
  const gone = keys.filter((k) => !keep(String(k)));
  if (gone.length) await idbDo("readwrite", (s) => { for (const k of gone) s.delete(k); });
}

/** Signing out: everything, and nothing kept after, until the page reloads.
 * The connection is closed again at once, so the database can be deleted. */
export async function forget() {
  try {
    await clear();
  } finally {
    forgotten = true;
  }
}
