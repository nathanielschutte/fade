"""Opens the pinned photo vectors (tests/vectors/media6.json) with an
independent implementation (Python's `cryptography`, not crypto.js):

- format 6, a direct photo: the pair key (ECDH P-256, HKDF-SHA-256 with salt
  napsack/v1/pair/<lo>/<hi> and info napsack/v1/messages), AES-256-GCM with
  associated data napsack/v6/snap/<from>/<to>;
- format 7, a group photo: the format 3 scheme (as check_group3.py) with the
  content kind "image".

Both open to the media envelope: header length (2 bytes, big-endian), a JSON
header {"type": "image/jpeg", "c", and "y" where the caption sits, if
placed}, then the JPEG. Neither opens as a video or a format 2 pic.
"""
import base64, hashlib, json, os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

HERE = os.path.dirname(__file__)
v1 = json.load(open(os.path.join(HERE, "format1.json"), encoding="utf-8"))
v = json.load(open(os.path.join(HERE, "media6.json"), encoding="utf-8"))
b64 = base64.b64decode
enc64 = lambda b: base64.b64encode(b).decode()
alice_id, bob_id = v1["alice"]["id"], v1["bob"]["id"]


def private(who):
    return serialization.load_der_private_key(b64(v1[who]["pkcs8"]), password=None)


def public(who):
    return serialization.load_der_public_key(b64(v1[who]["spki"]))


def derive(mine, my_id, theirs, their_id, info):
    lo, hi = sorted([my_id, their_id])
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=f"napsack/v1/pair/{lo}/{hi}".encode(),
                info=info).derive(mine.exchange(ec.ECDH(), theirs))


def gcm_open(key, sealed, aad):
    return AESGCM(key).decrypt(sealed[:12], sealed[12:], aad.encode())


def envelope(body):
    n = int.from_bytes(body[:2], "big")
    return json.loads(body[2:2 + n].decode()), body[2 + n:]


def fails(fn):
    try:
        fn()
    except InvalidTag:
        return True
    return False


# Format 6: bob opens alice's photo, its caption placed a quarter of the way down.
d = v["direct"]
pair = derive(private("bob"), bob_id, public("alice"), alice_id, b"napsack/v1/messages")
sealed = b64(d["ciphertext"])
body = gcm_open(pair, sealed, f"napsack/v6/snap/{d['from']}/{d['to']}")
assert body == b64(d["plaintext"])
header, media = envelope(body)
assert header == {"type": "image/jpeg", "c": d["caption"], "y": d["y"]} and media == b64(d["media"]), header
for other in ("v4", "v2"):  # not a video, not a format 2 pic
    assert fails(lambda: gcm_open(pair, sealed, f"napsack/{other}/snap/{d['from']}/{d['to']}")), other

# Format 7: the group scheme, kind "image"; no place given, so no "y".
g = v["group"]
content = b64(g["content"])
digest = enc64(hashlib.sha256(content).digest())
roster = enc64(hashlib.sha256(",".join(str(i) for i in sorted(g["recipients"])).encode()).digest())
wrap_key = derive(private("bob"), bob_id, public("alice"), alice_id, b"napsack/v3/group-keys")
k = gcm_open(wrap_key, b64(g["wraps"][str(bob_id)]),
             f"napsack/v3/group-key/{g['group_id']}/{g['sender']}/{bob_id}/{g['client_id']}/{digest}/{roster}")
aad = f"napsack/v3/group/{g['group_id']}/{g['sender']}/{g['client_id']}"
header, media = envelope(gcm_open(k, content, f"{aad}/image"))
assert header == {"type": "image/jpeg", "c": g["caption"]} and media == b64(g["media"]), header
for other in ("video", "pic"):
    assert fails(lambda: gcm_open(k, content, f"{aad}/{other}")), other
print("photo vectors (formats 6 and 7) open with an independent implementation")
