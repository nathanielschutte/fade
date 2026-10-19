"""Recomputes the format 1 password derivation with Python's standard library
and checks it against the pinned vectors. This is a second, independent
implementation of what docs/how-napsack-works.md describes, so it catches the
case where crypto.js and its own vectors agree with each other but not with
the documented design. No browser needed.
"""
import base64, hashlib, hmac, json, os

v = json.load(open(os.path.join(os.path.dirname(__file__), "format1.json"), encoding="utf-8"))
pw = v["password"]


def hkdf_sha256(key_material, info, length=32, salt=b"\0" * 32):
    prk = hmac.new(salt, key_material, hashlib.sha256).digest()
    out, block, i = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([i]), hashlib.sha256).digest()
        out, i = out + block, i + 1
    return out[:length]


salt = f"napsack/v1/user/{pw['username'].strip().lower()}".encode()
master = hashlib.pbkdf2_hmac("sha256", pw["password"].encode(), salt, 600_000, 32)
auth_key = base64.b64encode(hkdf_sha256(master, b"napsack/v1/auth")).decode()
assert auth_key == pw["auth_key"], (auth_key, pw["auth_key"])

# Safety code: SHA-256 over the sorted public keys, six 16-bit groups mod 100000.
a, b = sorted([v["alice"]["spki"], v["bob"]["spki"]])
digest = hashlib.sha256(f"napsack/v1/safety/{a}/{b}".encode()).digest()
code = " ".join(f"{((digest[i] << 8) | digest[i + 1]) % 100000:05d}" for i in range(0, 12, 2))
assert code == v["safety_code"], (code, v["safety_code"])

print("format 1 vectors match an independent implementation")
