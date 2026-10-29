"""Opens the pinned edit vectors (tests/vectors/edits2.json) with an
independent implementation (Python's `cryptography`, not crypto.js):

- a direct edit: the pair key, AES-256-GCM with associated data
  napsack/v2/edit/<from>/<to>/<message id>;
- a group edit: the format 3 scheme (as check_group3.py) with the content
  kind "edit/<message id>".

Both open to the format 2 text envelope {"t": "..."}, and neither opens as
an edit of a different message or as a plain text.
"""
import base64, hashlib, json, os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

HERE = os.path.dirname(__file__)
v1 = json.load(open(os.path.join(HERE, "format1.json"), encoding="utf-8"))
v = json.load(open(os.path.join(HERE, "edits2.json"), encoding="utf-8"))
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


def fails(fn):
    try:
        fn()
    except InvalidTag:
        return True
    return False


# Direct: bob opens alice's edit of message 42.
d = v["direct"]
pair = derive(private("bob"), bob_id, public("alice"), alice_id, b"napsack/v1/messages")
sealed = b64(d["ciphertext"])
body = gcm_open(pair, sealed, f"napsack/v2/edit/{d['from']}/{d['to']}/{d['message_id']}")
assert body.decode() == d["plaintext"] and json.loads(body) == {"t": d["text"]}, body
assert fails(lambda: gcm_open(pair, sealed, f"napsack/v2/edit/{d['from']}/{d['to']}/{d['message_id'] + 1}")), "moved"
assert fails(lambda: gcm_open(pair, sealed, f"napsack/v2/text/{d['from']}/{d['to']}")), "opened as a text"

# Group: the format 3 scheme, kind edit/<message id>.
g = v["group"]
content = b64(g["content"])
digest = enc64(hashlib.sha256(content).digest())
roster = enc64(hashlib.sha256(",".join(str(i) for i in sorted(g["recipients"])).encode()).digest())
wrap_key = derive(private("bob"), bob_id, public("alice"), alice_id, b"napsack/v3/group-keys")
k = gcm_open(wrap_key, b64(g["wraps"][str(bob_id)]),
             f"napsack/v3/group-key/{g['group_id']}/{g['sender']}/{bob_id}/{g['client_id']}/{digest}/{roster}")
aad = f"napsack/v3/group/{g['group_id']}/{g['sender']}/{g['client_id']}"
assert json.loads(gcm_open(k, content, f"{aad}/edit/{g['message_id']}")) == {"t": g["text"]}
assert fails(lambda: gcm_open(k, content, f"{aad}/edit/{g['message_id'] + 1}")), "moved"
assert fails(lambda: gcm_open(k, content, f"{aad}/text")), "opened as a text"
print("edit vectors open with an independent implementation")
