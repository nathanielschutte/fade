"""Opens the pinned format 3 group vectors with an independent implementation
of docs/group-encryption.md (Python's `cryptography`, not crypto.js): ECDH
P-256, HKDF-SHA-256 with the documented salt and info, AES-256-GCM with the
documented associated data. Both members' wraps must open to the same key,
the content must open to the documented envelopes, and changing any piece of
the associated data must fail.
"""
import base64, hashlib, json, os

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.exceptions import InvalidTag

HERE = os.path.dirname(__file__)
v1 = json.load(open(os.path.join(HERE, "format1.json"), encoding="utf-8"))
v = json.load(open(os.path.join(HERE, "group3.json"), encoding="utf-8"))
b64 = lambda s: base64.b64decode(s)
enc64 = lambda b: base64.b64encode(b).decode()


def private(who):
    return serialization.load_der_private_key(b64(v1[who]["pkcs8"]), password=None)


def public(who):
    return serialization.load_der_public_key(b64(v1[who]["spki"]))


def wrap_key(mine, my_id, theirs, their_id):
    shared = mine.exchange(ec.ECDH(), theirs)
    lo, hi = sorted([my_id, their_id])
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=f"napsack/v1/pair/{lo}/{hi}".encode(),
                info=b"napsack/v3/group-keys").derive(shared)


def gcm_open(key, sealed, aad):
    return AESGCM(key).decrypt(sealed[:12], sealed[12:], aad.encode())


def roster(ids):
    return enc64(hashlib.sha256(",".join(str(i) for i in sorted(ids)).encode()).digest())


def open_as(member, member_id, m, kind, group=v["group_id"], sender=v["sender"]):
    content = b64(m["content"])
    digest = enc64(hashlib.sha256(content).digest())
    kw = wrap_key(private(member), member_id, public("alice"), v1["alice"]["id"])
    aad = f"napsack/v3/group-key/{group}/{sender}/{member_id}/{m['client_id']}/{digest}/{roster(m['recipients'])}"
    k = gcm_open(kw, b64(m["wraps"][str(member_id)]), aad)
    assert len(k) == 32
    return k, gcm_open(k, content, f"napsack/v3/group/{group}/{sender}/{m['client_id']}/{kind}")


alice_id, bob_id = v1["alice"]["id"], v1["bob"]["id"]
assert v["sender"] == alice_id
for m in (v["text"], v["pic"]):
    assert sorted(m["recipients"]) == sorted([alice_id, bob_id]) and set(m["wraps"]) == {str(alice_id), str(bob_id)}
    assert len(b64(m["client_id"])) == 16
    assert all(len(b64(w)) == 12 + 32 + 16 for w in m["wraps"].values())

# Bob reads the text; alice (her other devices) reads it with her own wrap.
k_bob, body = open_as("bob", bob_id, v["text"], "text")
k_alice, body_alice = open_as("alice", alice_id, v["text"], "text")
assert k_bob == k_alice and body == body_alice
expected = json.dumps({"t": v["text"]["text"], "re": v["text"]["reply_to"]}, separators=(",", ":"), ensure_ascii=False)
assert body.decode() == expected == v["text"]["plaintext"], body

# The pic: caption length (2 bytes) || caption || photo, as format 2 pics.
_, pic = open_as("bob", bob_id, v["pic"], "pic")
n = int.from_bytes(pic[:2], "big")
assert pic[2:2 + n].decode() == v["pic"]["caption"] and pic[2 + n:] == b64(v["pic"]["photo"])

# Anything moved or changed fails: another group, sender, kind, or member list.
for bad in (dict(group=6), dict(sender=bob_id)):
    try:
        open_as("bob", bob_id, v["text"], "text", **bad)
        raise SystemExit(f"opened with {bad}")
    except InvalidTag:
        pass
try:
    open_as("bob", bob_id, v["text"], "pic")
    raise SystemExit("a text opened as a pic")
except InvalidTag:
    pass
try:
    open_as("bob", bob_id, {**v["text"], "recipients": [bob_id, alice_id, 11]}, "text")
    raise SystemExit("opened with a different member list")
except InvalidTag:
    pass
print("format 3 group vectors open with an independent implementation")
