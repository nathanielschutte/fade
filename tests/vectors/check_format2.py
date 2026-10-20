"""Checks the pinned format 2 vectors against the documented envelope layout,
independently of crypto.js: caption length (2 bytes, big-endian), the caption
in UTF-8, then the photo. (The AES-GCM layer is the same as format 1 with
associated data napsack/v2/snap/<from>/<to>; the browser test decrypts it.)
"""
import base64, json, os

v = json.load(open(os.path.join(os.path.dirname(__file__), "format2.json"), encoding="utf-8"))

for name in ("pic", "pic_no_caption"):
    p = v[name]
    caption = p["caption"].encode("utf-8")
    photo = base64.b64decode(p["photo_b64"])
    expected = len(caption).to_bytes(2, "big") + caption + photo
    assert base64.b64decode(p["plaintext_b64"]) == expected, name
    # IV (12) + envelope + GCM tag (16)
    assert len(base64.b64decode(p["ciphertext_b64"])) == 12 + len(expected) + 16, name

print("format 2 vectors match the documented envelope")
