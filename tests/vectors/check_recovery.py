"""Recomputes the recovery key vectors with Python's standard library, as a
second, independent implementation of what docs/how-napsack-works.md
describes: Crockford base32 display, then HKDF-SHA256 (empty salt) with info
napsack/v1/recovery/auth. (The wrapping is AES-GCM, checked by every client
in shared/crypto/vector-checks.js.)
"""
import base64, hashlib, hmac, json, os

v = json.load(open(os.path.join(os.path.dirname(__file__), "recovery.json"), encoding="utf-8"))
B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

key = bytes.fromhex(v["key_bytes_hex"])
assert len(key) == 20
n = int.from_bytes(key, "big")
shown = "".join(B32[(n >> (155 - 5 * i)) & 31] for i in range(32))
assert "-".join(shown[i:i + 4] for i in range(0, 32, 4)) == v["recovery_key"], (shown, v["recovery_key"])


def hkdf_sha256(key_material, info, length=32, salt=b"\0" * 32):
    prk = hmac.new(salt, key_material, hashlib.sha256).digest()
    out, block, i = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        out, i = out + block, i + 1
    return out[:length]


auth = base64.b64encode(hkdf_sha256(key, b"napsack/v1/recovery/auth")).decode()
assert auth == v["recovery_auth_key"], (auth, v["recovery_auth_key"])
print("recovery vectors match an independent implementation")
