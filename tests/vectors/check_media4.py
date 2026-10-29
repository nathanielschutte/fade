"""Opens the pinned video vectors (tests/vectors/media4.json) with an
independent implementation (Python's `cryptography`, not crypto.js):

- format 4, a direct video: the pair key (ECDH P-256, HKDF-SHA-256 with salt
  napsack/v1/pair/<lo>/<hi> and info napsack/v1/messages), AES-256-GCM with
  associated data napsack/v4/snap/<from>/<to>;
- format 5, a group video: the format 3 scheme (as check_group3.py) with the
  content kind "video".

Both open to the media envelope: header length (2 bytes, big-endian), a JSON
header {"type", "c"}, then the video. Opening either as anything else fails.
"""
import base64, hashlib, json, os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

HERE = os.path.dirname(__file__)
v1 = json.load(open(os.path.join(HERE, "format1.json"), encoding="utf-8"))
v = json.load(open(os.path.join(HERE, "media4.json"), encoding="utf-8"))
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
    header = json.loads(body[2:2 + n].decode())
    return header, body[2 + n:]


def fails(fn):
    try:
        fn()
    except InvalidTag:
        return True
    return False


# Format 4: bob opens alice's video with their pair key.
d = v["direct"]
pair = derive(private("bob"), bob_id, public("alice"), alice_id, b"napsack/v1/messages")
body = gcm_open(pair, b64(d["ciphertext"]), f"napsack/v4/snap/{d['from']}/{d['to']}")
assert body == b64(d["plaintext"])
header, media = envelope(body)
assert header == {"type": d["type"], "c": d["caption"]} and media == b64(d["media"]), header
assert fails(lambda: gcm_open(pair, b64(d["ciphertext"]), f"napsack/v2/snap/{d['from']}/{d['to']}")), "opened as a pic"
assert fails(lambda: gcm_open(pair, b64(d["ciphertext"]), f"napsack/v4/snap/{d['to']}/{d['from']}")), "sender swapped"

# Format 5: the group scheme, kind "video".
g = v["group"]
content = b64(g["content"])
digest = enc64(hashlib.sha256(content).digest())
roster = enc64(hashlib.sha256(",".join(str(i) for i in sorted(g["recipients"])).encode()).digest())
for who, my_id in (("bob", bob_id), ("alice", alice_id)):
    wrap_key = derive(private(who), my_id, public("alice"), alice_id, b"napsack/v3/group-keys")
    k = gcm_open(wrap_key, b64(g["wraps"][str(my_id)]),
                 f"napsack/v3/group-key/{g['group_id']}/{g['sender']}/{my_id}/{g['client_id']}/{digest}/{roster}")
    body = gcm_open(k, content, f"napsack/v3/group/{g['group_id']}/{g['sender']}/{g['client_id']}/video")
    header, media = envelope(body)
    assert header == {"type": g["type"], "c": g["caption"]} and media == b64(g["media"]), header
    assert fails(lambda: gcm_open(k, content, f"napsack/v3/group/{g['group_id']}/{g['sender']}/{g['client_id']}/pic")), \
        "a video opened as a pic"
print("video vectors (formats 4 and 5) open with an independent implementation")
