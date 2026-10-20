"""Checks the pinned format 2 text vectors against the documented envelope,
independently of crypto.js: compact JSON, "t" then "re" (only when replying),
UTF-8 without escaping non-ASCII. Ciphertext length is IV (12) + plaintext +
GCM tag (16). (Decryption is checked by every client in vector-checks.js.)
"""
import base64, json, os

v = json.load(open(os.path.join(os.path.dirname(__file__), "texts2.json"), encoding="utf-8"))

for t in v["texts"]:
    body = {"t": t["text"]}
    if t["reply_to"] is not None:
        body["re"] = t["reply_to"]
    expected = json.dumps(body, separators=(",", ":"), ensure_ascii=False)
    assert t["plaintext"] == expected, (t["plaintext"], expected)
    assert len(base64.b64decode(t["ciphertext"])) == 12 + len(expected.encode()) + 16, t["text"]

r = v["reaction"]
assert len(base64.b64decode(r["ciphertext"])) == 12 + len(r["emoji"].encode()) + 16
print("format 2 text vectors match the documented envelope")
