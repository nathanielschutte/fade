// Where the web app keeps its unlocked key and pinned friend keys: IndexedDB.
// The unwrapped private key is a non-extractable CryptoKey, so page script can
// use it but never read it out, and a reload doesn't need the password.
// Signing out deletes it. (The iOS app uses the Keychain instead.)
const DB_NAME = "napsack";
const STORE = "keys";

function idb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
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
