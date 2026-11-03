"""Opens the pinned passkey vectors (tests/vectors/passkey1.json) with an
independent implementation (Python's `cryptography`, not crypto.js), as
docs/design/passkeys.md describes: the PRF input is SHA-256 of
napsack/v1/passkey/prf; the wrap key is HKDF-SHA-256 of the passkey's PRF
secret (empty salt, info napsack/v1/passkey/wrap); the copy is AES-256-GCM
(12-byte IV first) with associated data napsack/v1/passkey, and opens to
Alice's PKCS#8 private key (format1.json). It doesn't open as the password's
copy or with another secret.
"""
import base64, hashlib, json, os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

HERE = os.path.dirname(__file__)
v1 = json.load(open(os.path.join(HERE, "format1.json"), encoding="utf-8"))
v = json.load(open(os.path.join(HERE, "passkey1.json"), encoding="utf-8"))

assert hashlib.sha256(b"napsack/v1/passkey/prf").hexdigest() == v["prf_input_hex"], "PRF input"


def wrap_key(secret):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"napsack/v1/passkey/wrap").derive(secret)


sealed = base64.b64decode(v["passkey_wrapped_key"])
key = wrap_key(bytes.fromhex(v["prf_secret_hex"]))
opened = AESGCM(key).decrypt(sealed[:12], sealed[12:], b"napsack/v1/passkey")
assert opened == base64.b64decode(v1["alice"]["pkcs8"]), "opens to Alice's private key"
for wrong_key, aad in ((key, b"napsack/v1/identity"), (wrap_key(bytes(32)), b"napsack/v1/passkey")):
    try:
        AESGCM(wrong_key).decrypt(sealed[:12], sealed[12:], aad)
        raise AssertionError("opened with the wrong key or associated data")
    except InvalidTag:
        pass
print("passkey vectors match an independent implementation")
