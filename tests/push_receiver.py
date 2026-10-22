"""A stand-in push service for the tests (the server's FADE_PUSH_ALLOW_LOCAL
lets it send to http://127.0.0.1). It records every push, checks the VAPID
signature, and decrypts the payload with the browser's key, so the tests check
RFC 8291 and RFC 8292 independently of the Rust code (server/src/push.rs).
"""
import base64, http.server, json, os, threading, time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def hkdf(salt, ikm, info, length):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


class Browser:
    """One browser's push subscription: its own key pair and auth secret."""

    def __init__(self, receiver, name):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.public = self.key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        self.auth = os.urandom(16)
        self.endpoint = f"{receiver.origin}/push/{name}"

    def subscription(self):
        """What PushSubscription.toJSON() gives a page."""
        return {"endpoint": self.endpoint, "keys": {"p256dh": b64url(self.public), "auth": b64url(self.auth)}}

    def topic(self, tag):
        """The Topic header the server should send for `tag` (push.rs, topic):
        keyed with this browser's auth secret, 24 base64url characters."""
        return b64url(hkdf(self.auth, tag.encode(), b"napsack push topic", 18))

    def decrypt(self, body):
        """RFC 8291 (aes128gcm), one record."""
        salt, rs, idlen = body[:16], int.from_bytes(body[16:20], "big"), body[20]
        as_public = body[21:21 + idlen]
        assert rs == 4096 and idlen == 65, (rs, idlen)
        shared = self.key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_public))
        ikm = hkdf(self.auth, shared, b"WebPush: info\0" + self.public + as_public, 32)
        cek = hkdf(salt, ikm, b"Content-Encoding: aes128gcm\0", 16)
        nonce = hkdf(salt, ikm, b"Content-Encoding: nonce\0", 12)
        plain = AESGCM(cek).decrypt(nonce, body[21 + idlen:], None)
        assert plain.endswith(b"\x02"), "single, final record"
        return json.loads(plain[:-1])


def check_vapid(header, origin):
    """`vapid t=<JWT>, k=<key>`: an ES256 JWT for this push service, signed by k."""
    assert header.startswith("vapid t="), header
    token, key = header[len("vapid t="):].split(", k=")
    head, claims, sig = token.split(".")
    assert json.loads(unb64url(head)) == {"typ": "JWT", "alg": "ES256"}
    c = json.loads(unb64url(claims))
    assert c["aud"] == origin and c["exp"] > time.time() and c["sub"].startswith(("https://", "mailto:")), c
    raw = unb64url(sig)
    pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), unb64url(key))
    pub.verify(encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")),
               f"{head}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))
    return key


class Receiver:
    """Listens on 127.0.0.1; `status` per path name lets a test play "gone" (410)."""

    def __init__(self):
        self.received = []  # (name, headers with lowercase names, body)
        self.status = {}
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                name = self.path.rsplit("/", 1)[-1]
                # Header names are case-insensitive; keep them lowercase.
                outer.received.append((name, {k.lower(): v for k, v in self.headers.items()}, body))
                self.send_response(outer.status.get(name, 201))
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.origin = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def browser(self, name):
        return Browser(self, name)

    def wait_for(self, name, count=1, timeout=10.0):
        """The first `count` pushes to `name`, waiting for them to arrive."""
        end = time.time() + timeout
        while time.time() < end:
            got = [r for r in self.received if r[0] == name]
            if len(got) >= count:
                return got
            time.sleep(0.05)
        raise AssertionError(f"no push for {name} within {timeout}s")

    def count(self, name):
        return len([r for r in self.received if r[0] == name])
