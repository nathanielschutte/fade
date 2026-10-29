"""End-to-end API smoke test. scripts/test.sh runs it against a fresh server,
or point it at one yourself:
    python3 tests/smoke_test.py http://127.0.0.1:8080 letmein

Encryption happens in the client (shared/crypto/crypto.js), so this test sends
correctly shaped opaque payloads and checks the server stores and returns
them byte-for-byte without needing to understand them.
"""
import asyncio, base64, json, os, sqlite3, struct, sys, time, urllib.parse, uuid, zlib
import requests, websockets

BASE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("NAPSACK_URL", "http://127.0.0.1:8080")
# The test server's database, when local: some checks look at what was stored.
DB = os.environ.get("NAPSACK_DB") or None
# NAPSACK_REMOTE=1: testing a deployed server (staging; docs/operations/staging.md), not a
# local one. Skips what needs the local machine: the push receiver.
REMOTE = os.environ.get("NAPSACK_REMOTE") == "1"
INVITE = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("NAPSACK_INVITE")

b64 = lambda raw: base64.b64encode(raw).decode()
AUTH_KEY = b64(os.urandom(32))
SNAP = os.urandom(150 * 1024)  # an encrypted snap is just bytes to the server

SEEN = []  # every API response, for the secret-field sweep at the end

def call(method, path, token=None, **kw):
    h = kw.pop("headers", {})
    if token: h["Authorization"] = f"Bearer {token}"
    r = requests.request(method, BASE + "/api" + path, headers=h, **kw)
    SEEN.append((method, path, r))
    return r

# Secrets the server holds that must never appear in any response.
NEVER_SERVED = ("auth_hash", "token_hash", "password_hash", "password")
# Allowed only in the response to signing up or in.
ONLY_FROM_AUTH = ("token", "wrapped_private_key")

def keys_in(value):
    if isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from keys_in(v)
    elif isinstance(value, list):
        for v in value:
            yield from keys_in(v)

def check_nothing_sensitive_served():
    """Nothing secret in any JSON response, and protective headers on every one."""
    for method, path, r in SEEN:
        for header, want in (("X-Content-Type-Options", "nosniff"), ("X-Frame-Options", "DENY"),
                             ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store"),
                             ("X-Robots-Tag", "noindex, nofollow, noarchive")):
            assert r.headers.get(header) == want, (method, path, header, r.headers.get(header))
        if "json" not in r.headers.get("Content-Type", ""):
            continue
        keys = set(keys_in(r.json()))
        assert not keys & set(NEVER_SERVED), (method, path, keys & set(NEVER_SERVED))
        if not path.startswith("/auth/"):
            assert not keys & set(ONLY_FROM_AUTH), (method, path, keys & set(ONLY_FROM_AUTH))
    print(f"  {len(SEEN)} API responses: no secret fields, protective headers on all")

def check_sensitive_paths():
    """Only the embedded client is served: no files, source, config, or database."""
    probes = ["/.env", "/.git/config", "/.git/HEAD", "/fade.db", "/server/fade.db", "/Cargo.toml",
              "/server/Cargo.toml", "/src/main.rs", "/static/app.js", "/../Cargo.toml", "/..%2fCargo.toml",
              "/%2e%2e/%2e%2e/etc/passwd", "/etc/passwd", "/var/lib/fade/db/fade.db", "/run/fade/env",
              "/admin/../Cargo.toml", "/api/../../Cargo.toml", "/terraform.tfstate", "/infra/terraform.tfvars",
              "/backup", "/debug", "/metrics", "/server-status", "/wp-login.php", "/api/admin"]
    markers = ("[package]", "SQLite format", "FADE_", "invite_code", "root:", "BEGIN", "terraform", "fn main")
    for path in probes:
        r = requests.get(BASE + path, allow_redirects=False)
        assert r.status_code in (400, 404), (path, r.status_code)
        assert not any(m in r.text for m in markers), (path, r.text[:200])
        assert r.headers.get("X-Frame-Options") == "DENY", path
    icon = requests.get(BASE + "/favicon.svg")
    assert icon.status_code == 200 and icon.headers["Content-Type"] == "image/svg+xml" and icon.text.startswith("<svg")
    ico = requests.get(BASE + "/favicon.ico", allow_redirects=False)
    assert ico.status_code == 308 and ico.headers["Location"] == "/favicon.svg"
    page = requests.get(BASE + "/")
    assert 'rel="icon" href="/favicon.svg"' in page.text
    assert "default-src 'self'" in page.headers["Content-Security-Policy"]
    assert page.headers["Cross-Origin-Opener-Policy"] == "same-origin"
    print(f"  {len(probes)} sensitive-path probes: all 404, nothing leaked")

def png(w, h, claim=None):
    """A real PNG, built by hand (no imaging library needed). `claim` lies about the size."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    cw, ch = claim or (w, h)
    rows = b"".join(b"\0" + b"".join(bytes([(x * 7) % 256, (y * 5) % 256, 90]) for x in range(w)) for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", cw, ch, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def contains(blob, needle):
    return blob.find(needle) != -1


def befriend(asker_tok, asked, asked_tok, asker_id):
    ok(call("POST", "/friends/requests", asker_tok, json={"username": asked["username"]}))
    ok(call("POST", f"/friends/requests/{asker_id}/accept", asked_tok))

def check_groups(tag, a, a_tok, b, b_tok):
    """Groups: membership rules, history from joining, owner handover. Not E2E in v1."""
    rc = ok(register(f"cal_{tag}")).json(); c, c_tok = rc["user"], rc["token"]
    rd = ok(register(f"dee_{tag}")).json(); d, d_tok = rd["user"], rd["token"]
    befriend(c_tok, a, a_tok, c["id"])                       # ana-cal friends; ben-cal are not

    ok(call("POST", "/groups", a_tok, json={"name": "x", "member_ids": [b["id"], d["id"]]}), 400)  # dee isn't ana's friend
    ok(call("POST", "/groups", a_tok, json={"name": "   ", "member_ids": []}), 400)
    g = ok(call("POST", "/groups", a_tok, json={"name": "  road   trip ", "member_ids": [b["id"], c["id"]]})).json()
    gid = g["id"]
    assert g["name"] == "road trip" and g["role"] == "owner" and g["encrypted"] is False
    assert sorted(m["id"] for m in g["members"]) == sorted([a["id"], b["id"], c["id"]])
    assert [m["role"] for m in g["members"]][0] == "owner"

    ok(call("GET", f"/groups/{gid}", d_tok), 404)              # outsiders see nothing
    ok(call("GET", f"/groups/{gid}/messages", d_tok), 404)
    ok(call("POST", f"/groups/{gid}/messages", d_tok, json={"text": "hi"}), 404)
    ok(call("POST", f"/groups/{gid}/messages", b_tok, json={"text": "  "}), 400)
    ok(call("POST", f"/groups/{gid}/messages", b_tok, json={"text": "x" * 2001}), 400)
    m = ok(call("POST", f"/groups/{gid}/messages", b_tok, json={"text": " who's driving? "})).json()
    assert m["body"] == "who's driving?" and m["sender_name"] == b["username"] and m["format"] == 0

    msgs = ok(call("GET", f"/groups/{gid}/messages", c_tok)).json()
    assert [x["kind"] for x in msgs] == ["event", "text"] and json.loads(msgs[0]["body"])["type"] == "created"
    mine = [x for x in ok(call("GET", "/groups", c_tok)).json() if x["id"] == gid][0]
    assert mine["unread"] == 1 and mine["member_count"] == 3 and mine["last_message"]["id"] == m["id"]
    ok(call("POST", f"/groups/{gid}/read", c_tok))
    assert [x for x in ok(call("GET", "/groups", c_tok)).json() if x["id"] == gid][0]["unread"] == 0

    # "Seen by": members see how far each member has read; outsiders see nothing.
    reads = {r["user_id"]: r for r in ok(call("GET", f"/groups/{gid}/reads", b_tok)).json()}
    assert set(reads) == {a["id"], b["id"], c["id"]}, reads
    assert reads[c["id"]]["last_read_id"] == m["id"] and reads[c["id"]]["username"] == c["username"]
    assert reads[a["id"]]["last_read_id"] < m["id"]
    ok(call("GET", f"/groups/{gid}/reads", d_tok), 404)
    ok(call("GET", f"/groups/{gid}/reads"), 401)

    # Only the owner removes others; removed members lose access; nothing is deleted.
    ok(call("DELETE", f"/groups/{gid}/members/{c['id']}", b_tok), 400)
    ok(call("DELETE", f"/groups/{gid}/members/{c['id']}", a_tok))
    ok(call("GET", f"/groups/{gid}/messages", c_tok), 404)
    assert all(x["id"] != gid for x in ok(call("GET", "/groups", c_tok)).json())
    ok(call("POST", f"/groups/{gid}/members", b_tok, json={"user_id": c["id"]}), 400)  # ben isn't cal's friend
    ok(call("POST", f"/groups/{gid}/members", a_tok, json={"user_id": b["id"]}), 409)  # already in
    ok(call("POST", f"/groups/{gid}/members", a_tok, json={"user_id": c["id"]}))
    back = ok(call("GET", f"/groups/{gid}/messages", c_tok)).json()
    assert all(x["id"] > m["id"] for x in back), "a rejoined member sees history from rejoining"
    assert json.loads(back[0]["body"]) ["type"] == "added"

    # Group pics: images only, view-once per member, not the sender, gone once everyone's seen it.
    # Hostile uploads: script hidden after a real image (a polyglot), and fakes.
    jpeg = png(300, 200) + b"<script>alert(1)</script><html>Exif\0GPSLatitude"
    ok(call("POST", f"/groups/{gid}/pics", b_tok, data=b"<svg onload=x>" + b" " * 100), 400)
    ok(call("POST", f"/groups/{gid}/pics", b_tok, data=b"\xff\xd8\xff\xe0" + os.urandom(4000)), 400)  # JPEG magic, garbage inside
    ok(call("POST", f"/groups/{gid}/pics", b_tok, data=png(1, 1, claim=(100_000, 100_000))), 400)    # decompression bomb
    ok(call("POST", f"/groups/{gid}/pics", d_tok, data=jpeg), 404)
    ok(call("POST", f"/groups/{gid}/pics", b_tok, data=jpeg, params={"caption": "a\u202eb"}), 400)
    ok(call("POST", f"/groups/{gid}/pics", b_tok, data=jpeg, params={"caption": "x" * 201}), 400)
    pm = ok(call("POST", f"/groups/{gid}/pics", b_tok, data=jpeg, headers={"Content-Type": "image/jpeg"},
                 params={"caption": " sunset 🌅 <b>hi</b> "})).json()
    assert "sunset" not in json.dumps(pm), "the caption stays hidden until the pic is opened"
    pic = pm["pic"]
    assert pm["pic_id"] == pic["id"] and pic["viewers"] == [] and pic["discard_reason"] is None and pm["body"] == ""
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", b_tok), 400)          # sender can't open it
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", d_tok), 404)          # outsider
    r = ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", a_tok))
    assert urllib.parse.unquote(r.headers["X-Napsack-Caption"]) == "sunset 🌅 <b>hi</b>"
    assert r.content.startswith(b"\xff\xd8\xff") and r.headers["Content-Type"] == "image/jpeg" and r.headers["Cache-Control"] == "no-store"
    assert not any(contains(r.content, n) for n in (b"<script", b"<html", b"Exif", b"GPS")), "hidden payload survived"
    assert "sandbox" in r.headers["Content-Security-Policy"] and r.headers["X-Content-Type-Options"] == "nosniff"
    # Fetching doesn't open it (a dropped connection could lose it); confirming does.
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", a_tok))               # again, until confirmed
    ok(call("POST", f"/groups/{gid}/pics/{pic['id']}/opened", d_tok), 404)  # outsider
    ok(call("POST", f"/groups/{gid}/pics/{pic['id']}/opened", b_tok), 404)  # the sender
    ok(call("POST", f"/groups/{gid}/pics/{pic['id']}/opened", a_tok))
    ok(call("POST", f"/groups/{gid}/pics/{pic['id']}/opened", a_tok))       # a retry is fine
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", a_tok), 410)          # once each
    r = ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", c_tok))           # cal rejoined before it was sent
    ok(call("POST", f"/groups/{gid}/pics/{pic['id']}/opened", c_tok))
    after_pic = [x for x in ok(call("GET", f"/groups/{gid}/messages", b_tok)).json() if x["id"] == pm["id"]][0]
    assert sorted(after_pic["pic"]["viewers"]) == sorted([a["id"], c["id"]]) and after_pic["pic"]["discard_reason"] == "opened"

    # Group pictures: any member, images only, members only, every one kept.
    ok(call("POST", f"/groups/{gid}/avatar", b_tok, data=b"<svg>" + b" " * 200), 400)
    ok(call("POST", f"/groups/{gid}/avatar", b_tok, data=b"\xff\xd8\xff" + b"x" * 200_000), 413)
    ok(call("POST", f"/groups/{gid}/avatar", b_tok, data=png(1, 1, claim=(100_000, 100_000))), 400)
    av = ok(call("POST", f"/groups/{gid}/avatar", b_tok, data=png(64, 64) + b"<script>x</script>")).json()["avatar_id"]
    assert ok(call("GET", f"/groups/{gid}", a_tok)).json()["avatar_id"] == av
    avr = ok(call("GET", f"/groups/{gid}/avatar/{av}", c_tok))
    assert avr.content.startswith(b"\xff\xd8\xff") and not contains(avr.content, b"<script")
    ok(call("GET", f"/groups/{gid}/avatar/{av}", d_tok), 404)
    assert json.loads(ok(call("GET", f"/groups/{gid}/messages", a_tok)).json()[-1]["body"])["type"] == "picture"

    for bad in ["evil\u202egpj.exe", "zero\u200bwidth", "nul\u0000", "esc\u001b[31m", "two\nlines"]:
        ok(call("PATCH", f"/groups/{gid}", b_tok, json={"name": bad}), 400)
    ok(call("POST", f"/groups/{gid}/messages", b_tok, json={"text": "a\u202eb"}), 400)
    ok(call("POST", f"/groups/{gid}/messages", b_tok, json={"text": "bell\u0007"}), 400)
    # Injection payloads are just text: stored and returned literally, nothing breaks.
    for payload in ["'; DROP TABLE users; --", "\" OR 1=1 --", "x'); DELETE FROM group_messages; --",
                    "<img src=x onerror=alert(1)>", "{{7*7}} ${7*7} %s %n", "line\nbreak\ttab"]:
        sent = ok(call("POST", f"/groups/{gid}/messages", b_tok, json={"text": payload})).json()
        assert sent["body"] == payload.strip(), (sent["body"], payload)
        assert ok(call("GET", f"/groups/{gid}/messages", a_tok)).json()[-1]["body"] == payload.strip()
    weird = ok(call("PATCH", f"/groups/{gid}", b_tok, json={"name": "'; DROP TABLE groups; --"})).json()
    assert weird["name"] == "'; DROP TABLE groups; --"
    assert len(ok(call("GET", f"/groups/{gid}/messages", a_tok)).json()) > 5, "messages survived"

    renamed = ok(call("PATCH", f"/groups/{gid}", b_tok, json={"name": "Road trip 2026"})).json()
    assert renamed["name"] == "Road trip 2026"

    # The owner leaves; the longest-standing member takes over.
    ok(call("DELETE", f"/groups/{gid}/members/{a['id']}", a_tok))
    after = ok(call("GET", f"/groups/{gid}", b_tok)).json()
    assert {x["id"]: x["role"] for x in after["members"]} == {b["id"]: "owner", c["id"]: "member"}, after["members"]
    events = [json.loads(x["body"])["type"] for x in ok(call("GET", f"/groups/{gid}/messages", b_tok)).json() if x["kind"] == "event"]
    assert events[-3:] == ["renamed", "left", "owner"], events  # after "picture"
    assert "renamed" in events[-5:-3]  # the injection-looking name was just a name
    ok(call("GET", f"/groups/{gid}", a_tok), 404)
    print("  groups: membership rules, history from joining, owner handover")

def check_people(tag, a, a_tok, b, b_tok):
    """Display names, private nicknames, profile pictures: friends only, all kept."""
    rs = ok(register(f"stranger_{tag}")).json(); s, s_tok = rs["user"], rs["token"]
    friend_view = lambda tok, who: [c for c in ok(call("GET", "/friends", tok)).json() if c["id"] == who["id"]][0]

    assert ok(call("GET", "/me", a_tok)).json()["display_name"] is None
    for bad in ["x" * 31, "evil‮gpj", "two\nlines", "nul\u0000", "zero​width"]:
        ok(call("PUT", "/me/name", a_tok, json={"name": bad}), 400)
    ok(call("PUT", "/me/name", a_tok, json={"name": "  Alex   the Great "}))
    assert ok(call("GET", "/me", a_tok)).json()["display_name"] == "Alex the Great"
    assert friend_view(b_tok, a)["display_name"] == "Alex the Great"
    assert ok(call("GET", f"/users/{a['id']}/profile", b_tok)).json()["display_name"] == "Alex the Great"
    ok(call("PUT", "/me/name", a_tok, json={"name": "'; DROP TABLE users; --"}))       # just a name
    assert friend_view(b_tok, a)["display_name"] == "'; DROP TABLE users; --"
    ok(call("PUT", "/me/name", a_tok, json={"name": "Alex the Great"}))

    # Strangers see none of it: no profile, no picture, and requests show only usernames.
    ok(call("GET", f"/users/{a['id']}/profile", s_tok), 404)
    ok(call("POST", "/friends/requests", s_tok, json={"username": a["username"]}))
    assert "Alex the Great" not in json.dumps(ok(call("GET", "/friends/requests", s_tok)).json())
    ok(call("DELETE", f"/friends/requests/{s['id']}", a_tok))

    # A nickname is seen only by whoever set it.
    ok(call("PUT", f"/friends/{a['id']}/nickname", b_tok, json={"name": "Captain Nickname"}))
    assert friend_view(b_tok, a)["nickname"] == "Captain Nickname"
    assert ok(call("GET", f"/users/{a['id']}/profile", b_tok)).json()["nickname"] == "Captain Nickname"
    for tok in (a_tok, s_tok):
        assert "Captain" not in json.dumps(ok(call("GET", "/friends", tok)).json())
    assert "Captain" not in json.dumps(ok(call("GET", f"/users/{b['id']}/profile", a_tok)).json())
    assert "Captain" not in json.dumps(ok(call("GET", "/me", a_tok)).json())
    ok(call("PUT", f"/friends/{a['id']}/nickname", s_tok, json={"name": "x"}), 404)  # not friends
    ok(call("PUT", f"/friends/{a['id']}/nickname", b_tok, json={"name": "‮oops"}), 400)
    ok(call("PUT", f"/friends/{a['id']}/nickname", b_tok, json={"name": "  "}))      # clears
    assert friend_view(b_tok, a)["nickname"] is None

    # Profile pictures: rebuilt like every image the server sees; friends only.
    ok(call("POST", "/me/avatar", a_tok, data=b"<svg onload=x>" + b" " * 100), 400)
    ok(call("POST", "/me/avatar", a_tok, data=png(1, 1, claim=(100_000, 100_000))), 400)
    ok(call("POST", "/me/avatar", a_tok, data=b"\xff\xd8\xff" + b"x" * 200_000), 413)
    av = ok(call("POST", "/me/avatar", a_tok, data=png(80, 80) + b"<script>alert(1)</script>")).json()["avatar_id"]
    assert ok(call("GET", "/me", a_tok)).json()["avatar_id"] == av and friend_view(b_tok, a)["avatar_id"] == av
    r = ok(call("GET", f"/users/{a['id']}/avatar/{av}", b_tok))
    assert r.content.startswith(b"\xff\xd8\xff") and not contains(r.content, b"<script")
    assert "sandbox" in r.headers["Content-Security-Policy"] and r.headers["Content-Type"] == "image/jpeg"
    ok(call("GET", f"/users/{a['id']}/avatar/{av}", a_tok))
    ok(call("GET", f"/users/{a['id']}/avatar/{av}", s_tok), 404)
    av2 = ok(call("POST", "/me/avatar", a_tok, data=png(64, 64))).json()["avatar_id"]
    ok(call("GET", f"/users/{a['id']}/avatar/{av}", b_tok), 404)                    # replaced: not served
    ok(call("DELETE", "/me/avatar", a_tok))
    assert ok(call("GET", "/me", a_tok)).json()["avatar_id"] is None and friend_view(b_tok, a)["avatar_id"] is None
    ok(call("GET", f"/users/{a['id']}/avatar/{av2}", b_tok), 404)

    # Birthdays: real dates only, the year optional, friends see it, clearing keeps history.
    for bad in [{"month": 13, "day": 1}, {"month": 2, "day": 30}, {"month": 2, "day": 29, "year": 2023},
                {"month": 4, "day": 31}, {"month": 5, "day": 5, "year": 1800}, {"month": 5, "day": 5, "year": 3000},
                {"month": 5}]:
        ok(call("PUT", "/me/birthday", a_tok, json=bad), 400)
    ok(call("PUT", "/me/birthday", json={"month": 3, "day": 3}), 401)
    ok(call("PUT", "/me/birthday", a_tok, json={"month": 2, "day": 29}))              # no year: fine
    ok(call("PUT", "/me/birthday", a_tok, json={"month": 3, "day": 9, "year": 1994}))
    assert ok(call("GET", f"/users/{a['id']}/profile", a_tok)).json()["birthday"] == {"month": 3, "day": 9, "year": 1994}
    assert ok(call("GET", f"/users/{a['id']}/profile", b_tok)).json()["birthday"] == {"month": 3, "day": 9, "year": 1994}
    assert friend_view(b_tok, a)["birthday"] == "03-09"
    ok(call("GET", f"/users/{a['id']}/profile", s_tok), 404)                           # strangers see nothing
    ok(call("PUT", "/me/birthday", a_tok, json={}))
    assert ok(call("GET", f"/users/{a['id']}/profile", b_tok)).json()["birthday"] is None
    assert friend_view(b_tok, a)["birthday"] is None
    if DB:
        n = sqlite3.connect(DB).execute("SELECT COUNT(*) FROM user_birthdays WHERE user_id = ?", (a["id"],)).fetchone()[0]
        assert n == 3, n
    print("  people: names, private nicknames, pictures, birthdays; friends only")


# Listed in FADE_ADMINS by scripts/test.sh. A fixed key, so a rerun can sign back in.
SMOKE_ADMIN, SMOKE_ADMIN_KEY = "smoke_admin", base64.b64encode(b"smoke admin key, not a secret..").decode()


def real_public_key():
    """A real P-256 public key (SPKI, base64), for an account Team Napsack writes to."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    key = ec.generate_private_key(ec.SECP256R1()).public_key()
    return b64(key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))


def admin_token():
    # A real public key, so Team Napsack can write to this admin (check_team).
    r = register(SMOKE_ADMIN, auth_key=SMOKE_ADMIN_KEY, public_key=real_public_key())
    if r.status_code == 409:
        r = call("POST", "/auth/login", json={"username": SMOKE_ADMIN, "auth_key": SMOKE_ADMIN_KEY})
    return ok(r).json()["token"]


def check_account(tag):
    """Change password, recovery keys, admin reset codes, signing out elsewhere (account.rs).
    The server only ever sees derived keys, so random ones stand in here."""
    k1, k2, k3, k4, k5 = (b64(os.urandom(32)) for _ in range(5))
    r = ok(register(f"acct_{tag}", auth_key=k1)).json()
    u, tok = r["user"], r["token"]
    name = u["username"]
    login = lambda key: call("POST", "/auth/login", json={"username": name, "auth_key": key})
    assert u["has_recovery_key"] is False and u["key_reset_at"] is None
    tok2 = ok(login(k1)).json()["token"]                                      # a second device

    # Unlock (for re-wrapping) needs a session and the password.
    ok(call("POST", "/auth/unlock", json={"auth_key": k1}), 401)
    ok(call("POST", "/auth/unlock", tok, json={"auth_key": k2}), 400)
    assert ok(call("POST", "/auth/unlock", tok, json={"auth_key": k1})).json() == {"wrapped_private_key": r["wrapped_private_key"]}

    # A recovery key needs the password too, so a stolen session can't plant one.
    rk, rw = b64(os.urandom(32)), b64(os.urandom(180))
    ok(call("PUT", "/me/recovery", tok, json={"auth_key": k2, "recovery_auth_key": rk, "recovery_wrapped_key": rw}), 400)
    ok(call("PUT", "/me/recovery", tok, json={"auth_key": k1, "recovery_auth_key": rk, "recovery_wrapped_key": "not base64!"}), 400)
    ok(call("PUT", "/me/recovery", tok, json={"auth_key": k1, "recovery_auth_key": rk, "recovery_wrapped_key": rw}))
    assert ok(call("GET", "/me", tok)).json()["has_recovery_key"] is True
    sec = ok(call("GET", "/me/security", tok)).json()
    assert sec["recovery_set_at"] and sec["active_sessions"] == 2 and sec["key_reset_at"] is None, sec

    # Changing the password ends the other sessions, keeps this one.
    w3 = b64(os.urandom(180))
    ok(call("POST", "/me/password", tok, json={"auth_key": k2, "new_auth_key": k3, "new_wrapped_private_key": w3}), 400)
    assert ok(call("POST", "/me/password", tok, json={"auth_key": k1, "new_auth_key": k3, "new_wrapped_private_key": w3})).json()["sessions_ended"] == 1
    ok(call("GET", "/me", tok2), 401)
    ok(call("GET", "/me", tok))
    ok(login(k1), 400)
    assert ok(login(k3)).json()["wrapped_private_key"] == w3

    # Recovery: the wrong key gets nothing; the right one, the recovery copy; then a new password.
    ok(call("POST", "/auth/recover/start", json={"username": name, "recovery_auth_key": b64(os.urandom(32))}), 400)
    ok(call("POST", "/auth/recover/start", json={"username": f"nobody_{tag}", "recovery_auth_key": rk}), 400)
    assert ok(call("POST", "/auth/recover/start", json={"username": name.upper(), "recovery_auth_key": rk})).json() == {"recovery_wrapped_key": rw}
    w4 = b64(os.urandom(180))
    rec = ok(call("POST", "/auth/recover/finish", json={"username": name, "recovery_auth_key": rk, "new_auth_key": k4, "new_wrapped_private_key": w4})).json()
    assert rec["public_key"] == r["public_key"] and rec["wrapped_private_key"] == w4, "same key, new password"
    assert rec["user"]["has_recovery_key"] is True
    ok(call("GET", "/me", tok), 401)                                          # every old session ended
    tok = rec["token"]
    ok(login(k3), 400)

    # Sign out everywhere else.
    other = ok(login(k4)).json()["token"]
    assert ok(call("POST", "/me/sessions/end-others", tok)).json()["sessions_ended"] == 1
    ok(call("GET", "/me", other), 401)
    ok(call("GET", "/me", tok))

    # Admin reset code: admins only, the newest code only, once; a new key pair that friends see.
    rf = ok(register(f"acctfriend_{tag}")).json()
    befriend(tok, rf["user"], rf["token"], u["id"])
    adm = admin_token()
    ok(call("POST", f"/admin/users/{u['id']}/reset-code", tok), 404)       # not an admin
    ok(call("POST", "/admin/users/999999/reset-code", adm), 404)
    first = ok(call("POST", f"/admin/users/{u['id']}/reset-code", adm)).json()
    issued = ok(call("POST", f"/admin/users/{u['id']}/reset-code", adm)).json()   # replaces the first
    assert issued["username"] == name and len(issued["code"]) == 19 and issued["expires_at"] > time.time() + 23 * 3600
    new_pub, w5 = b64(os.urandom(91)), b64(os.urandom(180))
    body = {"username": name, "new_auth_key": k5, "public_key": new_pub, "wrapped_private_key": w5}
    ok(call("POST", "/auth/reset", json={**body, "code": first["code"]}), 400)
    res = ok(call("POST", "/auth/reset", json={**body, "code": issued["code"].lower().replace("-", " ")})).json()
    assert res["public_key"] == new_pub and res["user"]["key_reset_at"] and res["user"]["has_recovery_key"] is False
    ok(call("POST", "/auth/reset", json={**body, "code": issued["code"]}), 400)   # used
    ok(call("GET", "/me", tok), 401)
    ok(login(k5))
    seen = [c for c in ok(call("GET", "/friends", rf["token"])).json() if c["id"] == u["id"]][0]
    assert seen["public_key"] == new_pub and seen["key_reset_at"] == res["user"]["key_reset_at"]
    ok(call("POST", "/auth/recover/start", json={"username": name, "recovery_auth_key": rk}), 400)  # went with the old key
    if DB:
        reasons = [x for (x,) in sqlite3.connect(DB).execute(
            "SELECT reason FROM credential_history WHERE user_id = ? ORDER BY id", (u["id"],))]
        assert reasons == ["recovery_key_set", "password_changed", "recovered", "admin_reset"], reasons
        codes = sqlite3.connect(DB).execute("SELECT code_hash FROM reset_codes WHERE user_id = ?", (u["id"],)).fetchall()
        assert len(codes) == 2 and all(issued["code"] not in h for (h,) in codes), "codes are stored hashed"
    print("  account: password change, recovery key, reset codes, sign out elsewhere; history kept")


async def socket(tok):
    ws = await websockets.connect(BASE.replace("http", "ws") + "/api/ws")
    await ws.send(json.dumps({"type": "auth", "token": tok}))
    assert json.loads(await ws.recv())["type"] == "ready"
    return ws


async def next_event(ws, kind, timeout=3.0):
    end = time.time() + timeout
    while True:
        left = end - time.time()
        if left <= 0:
            raise AssertionError(f"no {kind} event")
        ev = json.loads(await asyncio.wait_for(ws.recv(), left))
        if ev["type"] == kind:
            return ev


async def no_event(ws, kind, wait=0.8):
    try:
        await next_event(ws, kind, wait)
    except (AssertionError, asyncio.TimeoutError):
        return
    raise AssertionError(f"unexpected {kind} event")


async def check_live(tag):
    """Typing and "active now" (presence.rs), push notifications (push.rs),
    reactions and replies (reactions.rs, groups.rs)."""
    from push_receiver import Receiver, check_vapid
    ra, rb, rc = (ok(register(f"{n}_{tag}")).json() for n in ("liva", "livb", "livc"))
    (a, a_tok), (b, b_tok), (c, c_tok) = ((r["user"], r["token"]) for r in (ra, rb, rc))
    befriend(a_tok, b, b_tok, a["id"])
    friend_of = lambda tok, who: [x for x in ok(call("GET", "/friends", tok)).json() if x["id"] == who["id"]][0]

    # Presence: ben comes online, ana hears it and sees "active now"; strangers hear nothing.
    assert ok(call("GET", "/me", a_tok)).json()["share_activity"] is True
    wa, wc = await socket(a_tok), await socket(c_tok)
    wb = await socket(b_tok)
    ev = await next_event(wa, "presence")
    assert ev["user_id"] == b["id"] and ev["active"] is True
    await no_event(wc, "presence")
    assert friend_of(a_tok, b)["active_now"] is True

    # Typing reaches the friend only; a stranger's "typing" goes nowhere.
    await wb.send(json.dumps({"type": "typing", "to": a["id"]}))
    ev = await next_event(wa, "typing")
    assert ev == {"type": "typing", "from": b["id"], "group_id": None}, ev
    await wc.send(json.dumps({"type": "typing", "to": a["id"]}))
    await no_event(wa, "typing")
    await wb.send("not json at all")                                         # ignored, socket stays up

    # Hiding activity is mutual: ben hides, so nobody sees his, and he sees nobody's.
    ok(call("PUT", "/me/settings", b_tok, json={"share_activity": False}))
    assert friend_of(a_tok, b)["active_now"] is None and friend_of(a_tok, b)["last_seen_at"] is None
    assert friend_of(b_tok, a)["active_now"] is None
    await asyncio.sleep(2)                                                    # past the typing throttle
    await wb.send(json.dumps({"type": "typing", "to": a["id"]}))
    await no_event(wa, "typing")
    ok(call("PUT", "/me/settings", b_tok, json={"share_activity": True}))

    # Push: only known push services (a local test receiver here), well-formed keys.
    rx = Receiver()
    phone = rx.browser(f"ben-phone-{tag}")
    sub = phone.subscription()
    for bad in ("https://evil.example/push", "http://169.254.169.254/latest", "https://fcm.googleapis.com.evil.io/x"):
        ok(call("POST", "/push/subscriptions", b_tok, json={**sub, "endpoint": bad}), 400)
    ok(call("POST", "/push/subscriptions", b_tok, json={**sub, "keys": {"p256dh": "AAAA", "auth": sub["keys"]["auth"]}}), 400)
    ok(call("POST", "/push/subscriptions", json=sub), 401)
    ok(call("POST", "/push/subscriptions", b_tok, json=sub))
    ok(call("POST", "/push/subscriptions", b_tok, json=sub))                  # the app sends it on every launch
    if DB:
        rows = sqlite3.connect(DB).execute(
            "SELECT COUNT(*) FROM push_subscriptions WHERE endpoint = ?", (phone.endpoint,)).fetchone()[0]
        assert rows == 1, f"an unchanged subscription made {rows} rows"
    vapid = ok(call("GET", "/config")).json()["vapid_public_key"]

    # While napsack is on ben's screen, no push: the app shows it.
    await wb.send(json.dumps({"type": "visibility", "visible": True}))
    await asyncio.sleep(0.2)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2}))
    await asyncio.sleep(1.0)
    assert rx.count(phone.endpoint.rsplit("/", 1)[-1]) == 0, "pushed while on screen"

    # In the background, a push arrives: encrypted to ben's browser, signed, and saying who, not what.
    await wb.send(json.dumps({"type": "visibility", "visible": False}))
    await asyncio.sleep(0.2)
    ok(call("PUT", "/me/name", a_tok, json={"name": "Ana Live"}))
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2}))
    name, headers, body = rx.wait_for(phone.endpoint.rsplit("/", 1)[-1])[0]
    assert headers["content-encoding"] == "aes128gcm" and headers["ttl"] == "86400"
    # The topic collapses notes per chat without telling the push service who sent them.
    assert headers["topic"] == phone.topic(f"dm-{a['id']}") and len(headers["topic"]) == 24, headers["topic"]
    assert headers["urgency"] == "high"
    assert check_vapid(headers["authorization"], rx.origin) == vapid
    note = phone.decrypt(body)
    assert note == {"title": "Ana Live", "body": "New message", "tag": f"dm-{a['id']}", "url": f"/#chat={a['id']}"}, note
    assert b"New message" not in body, "the payload is encrypted"

    # Pics, friend requests, and acceptances notify too.
    ok(call("POST", f"/chats/{b['id']}/snaps?format=2", a_tok, data=os.urandom(500)))
    assert phone.decrypt(rx.wait_for(name, 2)[1][2])["body"] == "Sent you a pic"
    ok(call("POST", "/friends/requests", c_tok, json={"username": b["username"]}))
    req_note = phone.decrypt(rx.wait_for(name, 3)[2][2])
    assert req_note == {"title": "napsack", "body": f"{c['username']} wants to be friends", "tag": "requests", "url": "/#friends"}, req_note

    # A muted chat stays quiet; unmuted, it notifies again.
    ok(call("PUT", f"/chats/{a['id']}/mute", b_tok, json={"on": True}))
    quiet = rx.count(name)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2}))
    await asyncio.sleep(1.0)
    assert rx.count(name) == quiet, "a muted chat doesn't notify"
    ok(call("PUT", f"/chats/{a['id']}/mute", b_tok, json={"on": False}))
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2}))
    rx.wait_for(name, quiet + 1)

    # Signing out ends that browser's notifications.
    ok(call("POST", "/auth/logout", b_tok))
    b_tok = ok(call("POST", "/auth/login", json={"username": b["username"], "auth_key": AUTH_KEY})).json()["token"]
    before = rx.count(name)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2}))
    await asyncio.sleep(1.0)
    assert rx.count(name) == before, "no push after signing out"

    # A push service saying "gone" ends the subscription.
    laptop = rx.browser(f"ben-laptop-{tag}")
    ok(call("POST", "/push/subscriptions", b_tok, json=laptop.subscription()))
    rx.status[laptop.endpoint.rsplit("/", 1)[-1]] = 410
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2}))
    rx.wait_for(laptop.endpoint.rsplit("/", 1)[-1])
    await asyncio.sleep(0.5)
    if DB:
        reasons = dict(sqlite3.connect(DB).execute(
            "SELECT endpoint, end_reason FROM push_subscriptions WHERE user_id = ?", (b["id"],)).fetchall())
        assert reasons == {phone.endpoint: "signed_out", laptop.endpoint: "gone"}, reasons

    # Reactions: encrypted, one per person, the newest wins, and taking one back keeps the rows.
    m = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 2})).json()
    url = f"/chats/{a['id']}/messages/{m['id']}/reaction"
    ok(call("PUT", url, b_tok, json={"ciphertext": "not base64!"}), 400)
    ok(call("PUT", url, b_tok, json={"ciphertext": b64(os.urandom(40)), "format": 3}), 400)
    ok(call("PUT", f"/chats/{c['id']}/messages/{m['id']}/reaction", b_tok, json={"ciphertext": b64(os.urandom(40))}), 404)  # not friends
    first, second = b64(os.urandom(40)), b64(os.urandom(40))
    ok(call("PUT", url, b_tok, json={"ciphertext": first}))
    got = ok(call("PUT", url, b_tok, json={"ciphertext": second})).json()
    assert [r["ciphertext"] for r in got["reactions"]] == [second] and got["reactions"][0]["sender_id"] == b["id"]
    listed = [x for x in ok(call("GET", f"/chats/{b['id']}/messages", a_tok)).json() if x["id"] == m["id"]][0]
    assert listed["reactions"] == got["reactions"]
    assert ok(call("PUT", url, b_tok, json={"ciphertext": None})).json()["reactions"] == []
    ok(call("PUT", f"/chats/{a['id']}/messages/999999/reaction", b_tok, json={"ciphertext": first}), 404)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(60)), "format": 3}), 400)

    # Groups: plain reactions from the fixed set, replies within the group.
    g = ok(call("POST", "/groups", a_tok, json={"name": f"live {tag}", "member_ids": [b["id"]]})).json()
    other = ok(call("POST", "/groups", a_tok, json={"name": f"other {tag}", "member_ids": []})).json()
    gm = ok(call("POST", f"/groups/{g['id']}/messages", a_tok, json={"text": "first"})).json()
    om = ok(call("POST", f"/groups/{other['id']}/messages", a_tok, json={"text": "elsewhere"})).json()
    ok(call("POST", f"/groups/{g['id']}/messages", b_tok, json={"text": "re", "reply_to": om["id"]}), 400)
    reply = ok(call("POST", f"/groups/{g['id']}/messages", b_tok, json={"text": "reply", "reply_to": gm["id"]})).json()
    assert reply["reply_to"] == gm["id"]
    gurl = f"/groups/{g['id']}/messages/{gm['id']}/reaction"
    ok(call("PUT", gurl, b_tok, json={"emoji": "💩"}), 400)
    ok(call("PUT", gurl, c_tok, json={"emoji": "👍"}), 404)                   # not a member
    events = ok(call("GET", f"/groups/{g['id']}/messages", b_tok)).json()
    ok(call("PUT", f"/groups/{g['id']}/messages/{events[0]['id']}/reaction", b_tok, json={"emoji": "👍"}), 400)  # an event
    reacted = ok(call("PUT", gurl, b_tok, json={"emoji": "😂"})).json()
    assert [(r["user_id"], r["emoji"]) for r in reacted["reactions"]] == [(b["id"], "😂")]
    assert ok(call("PUT", gurl, b_tok, json={"emoji": None})).json()["reactions"] == []

    for ws in (wa, wb, wc):
        await ws.close()
    rx.server.shutdown()
    print("  live: presence, typing, push (encrypted, signed, who-not-what), reactions, replies")


def check_group_e2e(tag, a, a_tok, b, b_tok):
    """End-to-end encrypted group messages (format 3, docs/implementation/group-encryption.md):
    the server checks the member list and the keys' shapes, stores the sealed
    content once, and hands each member only their own key. The crypto itself
    is checked by the vectors and the browser tests."""
    out_tok = ok(register(f"grpout_{tag}")).json()["token"]
    g = ok(call("POST", "/groups", a_tok, json={"name": f"sealed {tag}", "member_ids": [b["id"]]})).json()
    gid, members = g["id"], sorted([a["id"], b["id"]])
    detail = ok(call("GET", f"/groups/{gid}", b_tok)).json()
    assert all(m["public_key"] for m in detail["members"]), "members come with their public keys"

    def sealed(recipients=members, **over):
        body = {"format": 3, "content": b64(os.urandom(80)), "client_id": b64(os.urandom(16)),
                "recipients": recipients, "wraps": {str(i): b64(os.urandom(60)) for i in recipients}}
        body.update(over)
        return body

    ok(call("POST", f"/groups/{gid}/messages", out_tok, json=sealed()), 404)                    # not a member
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed([a["id"]])), 409)            # stale member list
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed(wraps={str(a["id"]): b64(os.urandom(60))})), 400)
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed(wraps={str(i): b64(os.urandom(59)) for i in members})), 400)
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed(content="")), 400)
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed(client_id=b64(os.urandom(8)))), 400)
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed(format=7)), 400)

    first = sealed()
    m = ok(call("POST", f"/groups/{gid}/messages", a_tok, json=first)).json()
    assert m["format"] == 3 and m["body"] == "" and m["content"] == first["content"], m
    assert m["key"] == first["wraps"][str(a["id"])] and m["recipients"] == members and m["sender_public_key"]
    again = ok(call("POST", f"/groups/{gid}/messages", a_tok, json=first)).json()              # a resend
    assert again["id"] == m["id"], "a resent message comes back as the one stored, not a copy"
    ok(call("POST", f"/groups/{gid}/messages", b_tok, json=sealed()))

    seen = ok(call("GET", f"/groups/{gid}/messages", b_tok)).json()
    mine = [x for x in seen if x["id"] == m["id"]][0]
    assert mine["key"] == first["wraps"][str(b["id"])] and mine["content"] == first["content"]
    assert first["wraps"][str(a["id"])] not in json.dumps(seen), "nobody gets another member's key"
    started = [x for x in seen if x["kind"] == "event" and json.loads(x["body"])["type"] == "encrypted"]
    assert len(started) == 1 and started[0]["id"] < m["id"], "one 'encrypted from now on' event, first"
    last = [x for x in ok(call("GET", "/groups", b_tok)).json() if x["id"] == gid][0]["last_message"]
    assert last["format"] == 3 and last["key"] and last["content"]

    # Pics: sealed bytes, view-once, served exactly as sent.
    photo = os.urandom(700)
    keys = {"client_id": b64(os.urandom(16)), "recipients": members,
            "wraps": {str(i): b64(os.urandom(60)) for i in members}}
    ok(call("POST", f"/groups/{gid}/pics?format=3", a_tok, data=photo), 400)                  # no keys
    pm = ok(call("POST", f"/groups/{gid}/pics?format=3", a_tok, data=photo,
                 headers={"X-Napsack-Keys": json.dumps(keys)})).json()
    assert pm["format"] == 3 and pm["pic"] and pm["key"] == keys["wraps"][str(a["id"])]
    r = ok(call("GET", f"/groups/{gid}/pics/{pm['pic']['id']}", b_tok))
    assert r.content == photo and r.headers["content-type"] == "application/octet-stream"
    ok(call("POST", f"/groups/{gid}/pics/{pm['pic']['id']}/opened", b_tok))
    ok(call("GET", f"/groups/{gid}/pics/{pm['pic']['id']}", b_tok), 410)                     # view once

    # Videos (format 5): the same scheme and keys, a larger cap; not a text format.
    ok(call("POST", f"/groups/{gid}/messages", a_tok, json=sealed(format=5)), 400)
    clip = os.urandom(600 * 1024)

    def video_keys():
        return {"client_id": b64(os.urandom(16)), "recipients": members,
                "wraps": {str(i): b64(os.urandom(60)) for i in members}}
    ok(call("POST", f"/groups/{gid}/pics?format=3", a_tok, data=clip,
            headers={"X-Napsack-Keys": json.dumps(video_keys())}), 413)                       # too big for a pic
    vkeys = video_keys()
    vm = ok(call("POST", f"/groups/{gid}/pics?format=5", a_tok, data=clip,
                 headers={"X-Napsack-Keys": json.dumps(vkeys)})).json()
    assert vm["format"] == 5 and vm["pic"] and vm["key"] == vkeys["wraps"][str(a["id"])] and vm["sender_public_key"]
    theirs = [x for x in ok(call("GET", f"/groups/{gid}/messages", b_tok)).json() if x["id"] == vm["id"]][0]
    assert theirs["key"] == vkeys["wraps"][str(b["id"])] and vkeys["wraps"][str(a["id"])] not in json.dumps(theirs)
    assert ok(call("GET", f"/groups/{gid}/pics/{vm['pic']['id']}", b_tok)).content == clip

    ok(call("POST", f"/groups/{gid}/messages", a_tok, json={"text": "an old client"}))         # format 0 still works
    if DB:
        db = sqlite3.connect(DB)
        assert db.execute("SELECT COUNT(*) FROM group_message_keys WHERE message_id = ?", (m["id"],)).fetchone()[0] == 2
        assert db.execute("SELECT body FROM group_messages WHERE id = ?", (m["id"],)).fetchone()[0] == first["content"]
    print("  groups, encrypted: exact member lists, own keys only, replays refused, sealed pics and videos")


def check_streaks(tag, a, a_tok, b, b_tok):
    """Streaks: days in a row both friends sent each other a pic, in the
    viewer's time zone. The test database gets backdated pics directly (the
    API only ever stamps "now")."""
    view = lambda tok, who, tz=0: [c for c in ok(call("GET", f"/friends?tz={tz}", tok)).json() if c["id"] == who["id"]][0]
    assert view(a_tok, b)["streak"] == 0 and view(a_tok, b)["streak_expiring"] is False
    ok(call("GET", "/friends?tz=999999", a_tok))                          # clamped to a real zone
    if not DB:
        return
    today = int(time.time()) // 86400
    db = sqlite3.connect(DB)
    for d in (today - 2, today - 1, today):
        for frm, to, sec in ((a["id"], b["id"], 60), (b["id"], a["id"], 61)):
            db.execute("INSERT INTO messages (sender_id, recipient_id, kind, created_at, snap_state, format) VALUES (?, ?, 'snap', ?, 'opened', 2)",
                       (frm, to, d * 86400 + sec))
    db.commit()
    assert view(a_tok, b)["streak"] == 3 and view(b_tok, a)["streak"] == 3
    friend = ok(call("GET", f"/users/{b['id']}/profile?tz=0", a_tok)).json()
    assert friend["streak"]["current"] == 3 and friend["streak"]["longest"] == 3 and friend["streak"]["expiring"] is False
    assert ok(call("GET", f"/users/{a['id']}/profile?tz=0", a_tok)).json()["longest_streak"] >= 3
    print("  streaks: both ways, every day, counted in the viewer's day")


def check_marks(tag, a, a_tok, b, b_tok):
    """Favorites and hidden chats: only for friends and members, private to
    whoever sets them, and nothing is ever deleted."""
    rs = ok(register(f"loner_{tag}")).json(); s = rs["user"]
    view = lambda tok, who: [c for c in ok(call("GET", "/friends", tok)).json() if c["id"] == who["id"]][0]
    group_view = lambda tok, gid: [g for g in ok(call("GET", "/groups", tok)).json() if g["id"] == gid][0]

    ok(call("PUT", f"/chats/{s['id']}/favorite", a_tok, json={"on": True}), 404)   # not a friend
    ok(call("PUT", f"/chats/{s['id']}/hidden", a_tok, json={"on": True}), 404)
    ok(call("PUT", f"/chats/{b['id']}/favorite", json={"on": True}), 401)
    assert view(a_tok, b)["favorite"] is False and view(a_tok, b)["hidden"] is False

    # Favorites: mine alone; the friend sees no difference.
    ok(call("PUT", f"/chats/{b['id']}/favorite", a_tok, json={"on": True}))
    ok(call("PUT", f"/chats/{b['id']}/favorite", a_tok, json={"on": True}))      # again: no change
    assert view(a_tok, b)["favorite"] is True and view(b_tok, a)["favorite"] is False
    ok(call("PUT", f"/chats/{b['id']}/favorite", a_tok, json={"on": False}))
    assert view(a_tok, b)["favorite"] is False

    g = ok(call("POST", "/groups", a_tok, json={"name": f"marks {tag}", "member_ids": [b["id"]]})).json()
    ok(call("PUT", f"/groups/{g['id']}/favorite", rs["token"], json={"on": True}), 404)  # not a member
    ok(call("PUT", f"/groups/{g['id']}/favorite", b_tok, json={"on": True}))
    assert group_view(b_tok, g["id"])["favorite"] is True and group_view(a_tok, g["id"])["favorite"] is False

    # Hiding: off my list until a new message (from either side) brings it back.
    ok(call("PUT", f"/chats/{b['id']}/hidden", a_tok, json={"on": True}))
    assert view(a_tok, b)["hidden"] is True and view(b_tok, a)["hidden"] is False
    ok(call("POST", f"/chats/{a['id']}/messages", b_tok, json={"ciphertext": b64(os.urandom(48)), "format": 2}))
    assert view(a_tok, b)["hidden"] is False, "a new message shows the chat again"
    ok(call("PUT", f"/chats/{b['id']}/hidden", a_tok, json={"on": True}))
    assert view(a_tok, b)["hidden"] is True
    assert len(ok(call("GET", f"/chats/{b['id']}/messages", a_tok)).json()) > 0, "hiding keeps the messages"
    ok(call("PUT", f"/chats/{b['id']}/hidden", a_tok, json={"on": False}))
    assert view(a_tok, b)["hidden"] is False
    if DB:
        rows = sqlite3.connect(DB).execute("SELECT COUNT(*) FROM chat_marks WHERE user_id = ?", (a["id"],)).fetchone()[0]
        assert rows == 5, f"every change is a new row, none deleted: {rows}"

    # Muting: for a while or until turned off; only for friends and members; private.
    ok(call("PUT", f"/chats/{s['id']}/mute", a_tok, json={"on": True}), 404)
    for bad in (0, -1, 24 * 366):
        ok(call("PUT", f"/chats/{b['id']}/mute", a_tok, json={"on": True, "hours": bad}), 400)
    r = ok(call("PUT", f"/chats/{b['id']}/mute", a_tok, json={"on": True, "hours": 8})).json()
    assert r["muted"] and abs(r["muted_until"] - (time.time() + 8 * 3600)) < 60, r
    mine = view(a_tok, b)
    assert mine["muted"] is True and mine["muted_until"] == r["muted_until"] and view(b_tok, a)["muted"] is False
    ok(call("PUT", f"/chats/{b['id']}/mute", a_tok, json={"on": True}))
    assert view(a_tok, b)["muted"] is True and view(a_tok, b)["muted_until"] is None, "until turned off"
    ok(call("PUT", f"/chats/{b['id']}/mute", a_tok, json={"on": False}))
    assert view(a_tok, b)["muted"] is False
    ok(call("PUT", f"/groups/{g['id']}/mute", b_tok, json={"on": True, "hours": 168}))
    assert group_view(b_tok, g["id"])["muted"] is True and group_view(a_tok, g["id"])["muted"] is False


async def check_resend(tag):
    """A send retried after a dropped connection (same client_id) returns the
    stored message instead of storing it twice. And the socket answers the
    app's heartbeat."""
    ra, rb = ok(register(f"rs_a_{tag}")).json(), ok(register(f"rs_b_{tag}")).json()
    a, a_tok, b, b_tok = ra["user"], ra["token"], rb["user"], rb["token"]
    ok(call("POST", "/friends/requests", a_tok, json={"username": b["username"]}))
    ok(call("POST", f"/friends/requests/{a['id']}/accept", b_tok))

    cid = b64(os.urandom(16))
    body = {"ciphertext": b64(os.urandom(48)), "format": 2, "client_id": cid}
    first = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json=body)).json()
    again = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json=body)).json()
    assert again["id"] == first["id"] and first["client_id"] == cid
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={**body, "client_id": "<bad id>"}), 400)
    other = ok(call("POST", f"/chats/{a['id']}/messages", b_tok, json=body)).json()        # someone else's id space
    assert other["id"] != first["id"]

    pid = b64(os.urandom(16)).replace("+", "-").replace("/", "_")
    url = f"/chats/{b['id']}/snaps?format=2&client_id={urllib.parse.quote(pid)}"
    p1 = ok(call("POST", url, a_tok, data=SNAP, headers={"Content-Type": "application/octet-stream"})).json()
    p2 = ok(call("POST", url, a_tok, data=SNAP, headers={"Content-Type": "application/octet-stream"})).json()
    assert p1["id"] == p2["id"], "a retried pic upload isn't stored twice"
    if DB:
        n = sqlite3.connect(DB).execute("SELECT COUNT(*) FROM messages WHERE sender_id = ?", (a["id"],)).fetchone()[0]
        assert n == 2, n

    ws = await socket(a_tok)
    await ws.send(json.dumps({"type": "ping"}))
    assert (await next_event(ws, "pong"))["type"] == "pong"
    await ws.close()
    print("  resends: texts, pics, and group messages stored once; the socket answers pings")



def check_health():
    """/api/health, for the outside monitor (docs/implementation/health-monitor.md): public,
    says whether the database and disk are fine, and nothing private."""
    r = ok(call("GET", "/health"))
    h = r.json()
    assert set(h) == {"ok", "checks", "version", "build", "time", "uptime_secs"}, h
    assert h["ok"] is True and h["checks"] == {"database": "ok", "disk": "ok"}, h
    assert h["build"] and abs(h["time"] - time.time()) < 60
    assert "no-store" in r.headers["Cache-Control"]
    print("  health: public, database and disk OK, nothing private")

def check_roles(tag):
    """Roles (docs/implementation/roles.md): what a User, a PowerUser, and an Admin can reach.
    PowerUsers see how the app is doing, never more private data: no users
    table, no cost, no logs, no reset codes, and on the graph everyone they
    aren't friends with is anonymous (no username, no id, anywhere)."""
    r = {n: ok(register(f"ro_{n}_{tag}")).json() for n in ("user", "power", "friend", "stranger", "pal")}
    tok = {n: r[n]["token"] for n in r}
    uid = {n: r[n]["user"]["id"] for n in r}
    name = {n: r[n]["user"]["username"] for n in r}
    befriend(tok["power"], r["friend"]["user"], tok["friend"], uid["power"])
    befriend(tok["power"], r["pal"]["user"], tok["pal"], uid["power"])
    befriend(tok["friend"], r["stranger"]["user"], tok["stranger"], uid["friend"])
    adm = admin_token()

    assert ok(call("GET", "/me", tok["user"])).json()["role"] == "user"
    assert ok(call("GET", "/me", adm)).json()["role"] == "admin"

    # A User: none of it exists.
    for method, path in (("GET", "/admin/stats"), ("GET", "/admin/metrics"), ("GET", "/admin/graph"), ("GET", "/admin/roles"),
                         ("GET", "/admin/logs"), ("POST", f"/admin/roles/{uid['friend']}"), ("DELETE", f"/admin/roles/{uid['friend']}"),
                         ("POST", "/admin/roles/reload"), ("POST", f"/admin/users/{uid['friend']}/reset-code"),
                         ("GET", "/admin/incidents"), ("POST", "/admin/incidents/20261023T171000Z/resolve"),
                         ("GET", "/admin/users"), ("GET", f"/admin/users/{uid['friend']}"),
                         ("POST", f"/admin/users/{uid['friend']}/deactivate"), ("POST", f"/admin/users/{uid['friend']}/reactivate"),
                         ("POST", f"/admin/users/{uid['friend']}/sign-out"), ("POST", f"/admin/users/{uid['friend']}/unlock"),
                         ("GET", "/admin/actions"), ("GET", "/admin/announcements"), ("POST", "/admin/announcements"),
                         ("POST", "/admin/announcements/1/withdraw")):
        ok(call(method, path, tok["user"], json={"body": "x", "hours": 1}), 404)

    # An Admin makes someone a PowerUser (once).
    ok(call("POST", f"/admin/roles/{uid['power']}", adm))
    ok(call("POST", f"/admin/roles/{uid['power']}", adm), 409)
    ok(call("POST", f"/admin/roles/{uid['user']}", adm, ), 200)
    ok(call("DELETE", f"/admin/roles/{uid['user']}", adm))                      # and takes it away
    ok(call("DELETE", f"/admin/roles/{uid['user']}", adm), 404)
    ok(call("POST", "/admin/roles/999999", adm), 404)
    assert ok(call("GET", "/me", tok["power"])).json()["role"] == "power"
    P = tok["power"]

    # PowerUser: the overview without the users table; metrics without cost.
    stats = ok(call("GET", "/admin/stats", P)).json()
    assert stats["users"]["list"] is None and stats["users"]["total"] >= 5
    assert name["stranger"] not in json.dumps(stats)
    m = ok(call("GET", "/admin/metrics?hours=1", P)).json()
    assert m["cost_visible"] is False and m["billing"] is None and m["aws_problems"] == {}
    assert all(h["estimate"] is None for h in m["hosts"])
    # No logs, no reset codes, no reloading the admin list, no taking roles away.
    ok(call("GET", "/admin/logs", P), 404)
    ok(call("POST", f"/admin/users/{uid['friend']}/reset-code", P), 404)
    ok(call("POST", "/admin/roles/reload", P), 404)
    # No incidents either (Admins only, X18), and no Users tab or announcements.
    ok(call("GET", "/admin/incidents", P), 404)
    for method, path in (("GET", "/admin/users"), ("GET", f"/admin/users/{uid['stranger']}"),
                         ("POST", f"/admin/users/{uid['stranger']}/deactivate"), ("POST", f"/admin/users/{uid['stranger']}/sign-out"),
                         ("POST", f"/admin/users/{uid['stranger']}/unlock"), ("GET", "/admin/actions"),
                         ("POST", "/admin/announcements")):
        ok(call(method, path, P, json={"body": "x", "hours": 1}), 404)
    ok(call("POST", "/admin/incidents/20261023T171000Z/resolve", P), 404)

    # The graph: friends by name; everyone else anonymous, in every form.
    for query in ("?all=1", f"?users={uid['power']}&depth=2", f"?users={uid['friend']}&depth=2"):
        g = ok(call("GET", f"/admin/graph{query}", P)).json()
        assert g["anonymous"] is True
        text = json.dumps(g)
        assert name["stranger"] not in text and name["user"] not in text, query
        for n in g["graph"]["nodes"]:
            if n.get("user_id") not in (uid["power"], uid["friend"], uid["pal"]):
                assert "user_id" not in n and "username" not in n and n["key"].startswith("a") and n["alias"].startswith("Someone "), n
        assert {p["id"] for p in g["people"]} == {uid["power"], uid["friend"], uid["pal"]}, g["people"]
    g = ok(call("GET", f"/admin/graph?users={uid['friend']}&depth=1", P)).json()
    stranger = next(n for n in g["graph"]["nodes"] if "alias" in n)
    ok(call("GET", f"/admin/graph?users={uid['stranger']}", P), 400)          # not by id
    seeded = ok(call("GET", f"/admin/graph?users={stranger['key']}", P)).json()  # by alias: fine
    assert [n["key"] for n in seeded["graph"]["nodes"] if n["kind"] == "seed"] == [stranger["key"]]
    # An Admin sees real names.
    assert name["stranger"] in json.dumps(ok(call("GET", "/admin/graph?all=1", adm)).json())

    # Roles: a PowerUser sees themselves and their friends, grants to friends only, revokes nothing.
    roles = ok(call("GET", "/admin/roles", P)).json()
    assert roles["role"] == "power"
    assert {p["id"] for p in roles["people"]} == {uid["power"], uid["friend"], uid["pal"]}
    assert all(p["granted_by"] is None for p in roles["people"])
    ok(call("POST", f"/admin/roles/{uid['stranger']}", P), 404)
    ok(call("POST", f"/admin/roles/{uid['power']}", P), 400)                     # not yourself
    ok(call("POST", f"/admin/roles/{uid['friend']}", P))
    ok(call("DELETE", f"/admin/roles/{uid['friend']}", P), 404)
    assert ok(call("GET", "/me", tok["friend"])).json()["role"] == "power"
    everyone = ok(call("GET", "/admin/roles", adm)).json()
    granted = next(p for p in everyone["people"] if p["id"] == uid["friend"])
    assert granted["role"] == "power" and granted["granted_by"] == name["power"]
    ok(call("DELETE", f"/admin/roles/{uid['friend']}", adm))
    ok(call("DELETE", f"/admin/roles/{uid['power']}", adm))
    ok(call("GET", "/admin/stats", P), 404)                                       # back to User
    ok(call("POST", "/admin/roles/reload", adm), 400)                             # no settings parameter here
    # Incidents: Admins only. Locally there's no monitor; ids are checked before anything else.
    inc = ok(call("GET", "/admin/incidents", adm)).json()
    if not REMOTE:
        assert inc == {"available": False, "incidents": []}, inc
    ok(call("POST", "/admin/incidents/..%2F..%2Fstate/resolve", adm), 400)
    ok(call("POST", "/admin/incidents/not-an-id/resolve", adm), 400)
    if DB:
        n = sqlite3.connect(DB).execute("SELECT COUNT(*) FROM user_roles WHERE user_id IN (?, ?, ?)", (uid["power"], uid["friend"], uid["user"])).fetchone()[0]
        assert n == 3, f"grants are marked ended, never deleted: {n}"
    print("  roles: Users see nothing; PowerUsers no names, cost, logs, or resets; Admins everything")

def check_admin_users(tag):
    """System → Users (admin_users.rs): turning an account off keeps all of it,
    but it can't sign in or be sent to, until it's turned back on; signing out
    everywhere; clearing a sign-in lock; every action recorded. Announcements."""
    adm = admin_token()
    me_admin = ok(call("GET", "/me", adm)).json()
    r = {n: ok(register(f"au_{n}_{tag}")).json() for n in "xy"}
    x, y = r["x"]["user"], r["y"]["user"]
    x_tok, y_tok = r["x"]["token"], r["y"]["token"]
    befriend(y_tok, x, x_tok, y["id"])
    ok(call("POST", f"/chats/{x['id']}/messages", y_tok, json={"ciphertext": b64(os.urandom(48)), "format": 2}))
    invite = ok(call("POST", "/invites", x_tok)).json()

    people = ok(call("GET", "/admin/users", adm)).json()
    row = next(u for u in people["users"] if u["id"] == x["id"])
    assert row["deactivated"] is False and row["role"] == "user" and row["friends"] == 1, row
    assert people["accounts_max"] >= people["active"] >= 3
    d = ok(call("GET", f"/admin/users/{x['id']}", adm)).json()
    assert d["counts"]["friends"] == 1 and d["counts"]["invites_made"] == 1 and len(d["sessions"]) >= 1, d
    assert d["deactivated"] is False and d["sign_in"]["failures"] == 0
    assert not {"auth_hash", "token_hash", "code", "wrapped_private_key"} & set(json.dumps(d).split('"')), "nothing secret"
    ok(call("GET", "/admin/users/999999", adm), 404)

    # Not yourself, not another Admin, and a reason is checked like other text.
    ok(call("POST", f"/admin/users/{me_admin['id']}/deactivate", adm, json={}), 400)
    ok(call("POST", f"/admin/users/{x['id']}/deactivate", adm, json={"reason": "a\u202eb"}), 400)
    ok(call("POST", f"/admin/users/{x['id']}/deactivate", adm, json={"reason": "z" * 201}), 400)

    # Off: signed out, can't sign in (said only after the right password), can't be sent to or found.
    off = ok(call("POST", f"/admin/users/{x['id']}/deactivate", adm, json={"reason": "asked to leave"})).json()
    assert off["deactivated"] is True and off["sessions_ended"] >= 1, off
    ok(call("POST", f"/admin/users/{x['id']}/deactivate", adm, json={}), 409)
    ok(call("GET", "/me", x_tok), 401)
    wrong = call("POST", "/auth/login", json={"username": x["username"], "auth_key": b64(os.urandom(32))})
    assert wrong.status_code == 400 and "turned off" not in wrong.text, wrong.text
    turned = call("POST", "/auth/login", json={"username": x["username"], "auth_key": AUTH_KEY})
    assert turned.status_code == 400 and "turned off" in turned.json()["error"], turned.text
    sent = call("POST", f"/chats/{x['id']}/messages", y_tok, json={"ciphertext": b64(os.urandom(48)), "format": 2})
    assert sent.status_code == 400 and "turned off" in sent.json()["error"], sent.text
    history = ok(call("GET", f"/chats/{x['id']}/messages", y_tok)).json()
    assert len(history) == 1, "the chat stays readable"
    friend = next(c for c in ok(call("GET", "/friends", y_tok)).json() if c["id"] == x["id"])
    assert friend["deactivated"] is True and friend.get("active_now") is None and friend.get("last_seen_at") is None, friend
    ok(call("POST", "/friends/requests", adm, json={"username": x["username"]}), 404)
    ok(call("GET", f"/invites/lookup/{invite['path'].rsplit('/', 1)[-1]}"), 404)
    row = next(u for u in ok(call("GET", "/admin/users", adm)).json()["users"] if u["id"] == x["id"])
    assert row["deactivated"] is True

    # On again: everything as it was.
    ok(call("POST", f"/admin/users/{x['id']}/reactivate", adm))
    ok(call("POST", f"/admin/users/{x['id']}/reactivate", adm), 409)
    x_tok = ok(call("POST", "/auth/login", json={"username": x["username"], "auth_key": AUTH_KEY})).json()["token"]
    ok(call("POST", f"/chats/{x['id']}/messages", y_tok, json={"ciphertext": b64(os.urandom(48)), "format": 2}))
    assert ok(call("GET", f"/chats/{y['id']}/messages", x_tok)).json(), "their history came back with them"

    # Signing out everywhere ends every session.
    ok(call("POST", f"/admin/users/{x['id']}/sign-out", adm))
    ok(call("GET", "/me", x_tok), 401)
    ok(call("POST", f"/admin/users/{me_admin['id']}/sign-out", adm), 400)

    # A sign-in lock: wrong passwords counted, then cleared.
    for _ in range(3):
        ok(call("POST", "/auth/login", json={"username": y["username"], "auth_key": b64(os.urandom(32))}), 400)
    assert ok(call("GET", f"/admin/users/{y['id']}", adm)).json()["sign_in"]["failures"] == 3
    assert ok(call("POST", f"/admin/users/{y['id']}/unlock", adm)).json()["failures_cleared"] == 3
    assert ok(call("GET", f"/admin/users/{y['id']}", adm)).json()["sign_in"]["failures"] == 0

    # Every action recorded, and shown on the account.
    acts = [a["action"] for a in ok(call("GET", f"/admin/users/{x['id']}", adm)).json()["actions"]]
    assert acts[:3] == ["sign_out", "reactivate", "deactivate"], acts
    feed = ok(call("GET", "/admin/actions", adm)).json()["actions"]
    assert any(a["action"] == "unlock" and a["target"] == y["username"] for a in feed), feed[:5]
    if DB:
        db = sqlite3.connect(DB)
        assert db.execute("SELECT COUNT(*) FROM deactivations WHERE user_id = ?", (x["id"],)).fetchone()[0] == 1
        assert db.execute("SELECT COUNT(*) FROM users WHERE id = ?", (x["id"],)).fetchone()[0] == 1, "never deleted"

    # Announcements: one at a time, checked, everyone signed in sees them, withdrawn not deleted.
    ok(call("GET", "/announcement"), 401)
    for bad in ({"body": "", "hours": 24}, {"body": "x" * 281, "hours": 24}, {"body": "two\nlines", "hours": 24},
                {"body": "ok", "hours": 0}, {"body": "ok", "hours": 24 * 15}):
        ok(call("POST", "/admin/announcements", adm, json=bad), 400)
    posted = ok(call("POST", "/admin/announcements", adm, json={"body": f"hello {tag}", "hours": 24})).json()["announcement"]
    seen = ok(call("GET", "/announcement", y_tok)).json()["announcement"]
    assert seen["id"] == posted["id"] and seen["body"] == f"hello {tag}", seen
    second = ok(call("POST", "/admin/announcements", adm, json={"body": f"again {tag}", "hours": 1})).json()["announcement"]
    assert ok(call("GET", "/announcement", y_tok)).json()["announcement"]["id"] == second["id"], "the new one replaces the last"
    ok(call("POST", f"/admin/announcements/{second['id']}/withdraw", adm))
    ok(call("POST", f"/admin/announcements/{second['id']}/withdraw", adm), 404)
    assert ok(call("GET", "/announcement", y_tok)).json()["announcement"] is None
    recent = ok(call("GET", "/admin/announcements", adm)).json()["announcements"]
    assert {a["id"] for a in recent} >= {posted["id"], second["id"]}, "kept"
    print("  admin users: turned off and back on with nothing lost, signed out, unlocked, recorded; announcements")

def check_team(tag):
    """Team Napsack (team.rs, occasions.rs): napsack's own account. It messages
    people without being their friend; its chat is read-only; nobody signs in
    as it, finds it, or acts on it. The schedule is read-only and checked."""
    adm = admin_token()
    me_admin = ok(call("GET", "/me", adm)).json()
    r = ok(register(f"tm_{tag}")).json()
    other = r["token"]

    sched = ok(call("GET", "/admin/occasions", adm)).json()
    team = sched["team_napsack"]
    assert team and sched["problems"] == [], sched
    ids = {o["id"] for o in sched["occasions"]}
    assert {"test-hello", "birthday-wish"} <= ids, ids
    assert all(o["only"] == ["nate"] or o["to"] == 'Users(["nate"])' for o in sched["occasions"]), "tests go to nate only"
    ok(call("GET", "/admin/occasions", other), 404)
    ok(call("POST", "/admin/occasions/test-hello/try", other), 404)
    ok(call("POST", "/admin/occasions/no-such-thing/try", adm), 404)

    if REMOTE:
        # (Staging's smoke_admin is older than real keys in this test: it can't be written to.)
        print("  team napsack: schedule checked; sending skipped remotely")
        return
    # Not there until it has said something.
    assert not [c for c in ok(call("GET", "/friends", adm)).json() if c["id"] == team]
    sent = ok(call("POST", "/admin/occasions/test-hello/try", adm)).json()
    chat = next(c for c in ok(call("GET", "/friends", adm)).json() if c["id"] == team)
    assert chat["system"] is True and chat["display_name"] == "Team Napsack" and chat["public_key"], chat
    assert chat["last_message"]["id"] == sent["message_id"] and chat["last_message"]["format"] == 2
    history = ok(call("GET", f"/chats/{team}/messages", adm)).json()
    assert history[-1]["sender_id"] == team and history[-1]["recipient_id"] == me_admin["id"]
    assert "Team Napsack" not in json.dumps(history), "it's encrypted like any text"
    ok(call("POST", f"/chats/{team}/read", adm))
    ok(call("PUT", f"/chats/{team}/mute", adm, json={"on": True, "hours": 8}))     # you can mute it
    # Read-only, and not a person.
    ok(call("POST", f"/chats/{team}/messages", adm, json={"ciphertext": b64(os.urandom(48)), "format": 2}), 404)
    assert ok(call("GET", f"/chats/{team}/messages", other)).json() == [], "only your own messages from it"
    ok(call("POST", "/friends/requests", other, json={"username": "napsack"}), 404)
    who = ok(call("GET", f"/admin/users/{team}", adm)).json()
    assert who["role"] == "system", who
    ok(call("POST", f"/admin/users/{team}/deactivate", adm, json={}), 400)
    ok(call("POST", f"/admin/users/{team}/reset-code", adm), 400)
    login = call("POST", "/auth/login", json={"username": who["username"], "auth_key": AUTH_KEY})
    assert login.status_code == 400 and "turned off" not in login.text
    if DB:
        db = sqlite3.connect(DB)
        assert db.execute("SELECT COUNT(*) FROM occasion_sends WHERE occasion = 'test-hello'").fetchone()[0] == 0, "a try isn't a send"
    print("  team napsack: messages anyone, read-only, never signs in; schedule checked; try sends to you")

def check_graph(tag):
    """The friend map: your own map only, with an anonymous ? for each person
    a friend knows that you don't; the admin graph for admins only."""
    r = {n: ok(register(f"gr_{n}_{tag}")).json() for n in "abcdef"}
    tok = {n: r[n]["token"] for n in r}
    uid = {n: r[n]["user"]["id"] for n in r}
    # a-b, a-c, b-c (b and c know each other), c-d, d-e, a-f (then ended)
    for x, y in ("ab", "ac", "bc", "cd", "de", "af"):
        befriend(tok[x], r[y]["user"], tok[y], uid[x])
    ok(call("DELETE", f"/friends/{uid['f']}", tok["a"]))

    ok(call("GET", "/graph"), 401)
    g = ok(call("GET", "/graph", tok["a"])).json()
    kinds = {n["key"]: n["kind"] for n in g["nodes"]}
    k = lambda n: f"u{uid[n]}"
    assert kinds == {k("a"): "self", k("b"): "friend", k("c"): "friend", "?1": "unknown"}, kinds
    edges = {frozenset(e) for e in g["edges"]}
    assert edges == {frozenset({k("a"), k("b")}), frozenset({k("a"), k("c")}), frozenset({k("b"), k("c")}), frozenset({k("c"), "?1"})}, edges
    unknown = next(n for n in g["nodes"] if n["kind"] == "unknown")
    assert set(unknown) == {"key", "kind"}, unknown
    text = json.dumps(g)
    for hidden in "def":
        assert f"\"u{uid[hidden]}\"" not in text and r[hidden]["user"]["username"] not in text, hidden
    assert all("username" not in n for n in g["nodes"]), "the app names your friends itself"

    ok(call("GET", "/admin/graph", tok["a"]), 404)
    adm = admin_token()
    one = ok(call("GET", f"/admin/graph?users={uid['a']}&depth=1", adm)).json()
    names = {n["username"] for n in one["graph"]["nodes"]}
    assert names == {r[n]["user"]["username"] for n in "abc"}, names
    assert [n["kind"] for n in one["graph"]["nodes"] if n["user_id"] == uid["a"]] == ["seed"]
    two = ok(call("GET", f"/admin/graph?users={uid['a']}&depth=2", adm)).json()
    assert r["d"]["user"]["username"] in {n["username"] for n in two["graph"]["nodes"]}
    assert r["e"]["user"]["username"] not in {n["username"] for n in two["graph"]["nodes"]}
    everyone = ok(call("GET", "/admin/graph?all=1", adm)).json()
    assert everyone["all"] is True
    assert {uid[n] for n in "abcdef"} <= {n["user_id"] for n in everyone["graph"]["nodes"]}
    assert len(everyone["people"]) >= 6 and all(set(p) == {"id", "username"} for p in everyone["people"])
    ok(call("GET", "/admin/graph?users=1,x", adm), 400)
    ok(call("GET", "/admin/graph?users=" + ",".join(["1"] * 51), adm), 400)

    # Group chats, only when asked for. c's chat has a, b, and d (d is a's "?").
    assert "chat" not in json.dumps(g), "off by default"
    trip = ok(call("POST", "/groups", tok["c"], json={"name": f"trip {tag}", "member_ids": [uid["a"], uid["b"], uid["d"]]})).json()
    side = ok(call("POST", "/groups", tok["c"], json={"name": f"side {tag}", "member_ids": [uid["d"]]})).json()
    mine = ok(call("GET", "/graph?chats=1", tok["a"])).json()
    chats = [n for n in mine["nodes"] if n["kind"] == "chat"]
    assert len(chats) == 1, chats  # not the chat a isn't in
    chat = chats[0]
    assert (chat["name"], chat["group_id"], chat["size"], chat["others"]) == (f"trip {tag}", trip["id"], 4, 1), chat
    lined = {e[0] if e[1] == chat["key"] else e[1] for e in mine["edges"] if chat["key"] in e}
    assert lined == {k("a"), k("b"), k("c")}, lined  # never the ? (d)
    assert f"side {tag}" not in json.dumps(mine)
    # The System graph: chats with two people on it; names only for members (the admin isn't in these).
    sys = ok(call("GET", f"/admin/graph?users={uid['c']}&depth=1&chats=1", adm)).json()
    found = {n["key"]: n for n in sys["graph"]["nodes"] if n["kind"] == "chat"}
    assert f"c{trip['id']}" in found and f"c{side['id']}" in found, found
    assert all("name" not in n and "group_id" not in n for n in found.values()), found
    assert f"trip {tag}" not in json.dumps(sys) and f"side {tag}" not in json.dumps(sys)
    print("  friend map: your own map, anonymous ?s, group chats (never tied to a ?), admin graph for admins only")

async def check_late_joiner(tag):
    """Someone added to a group doesn't get messages from before they joined,
    even as updates. (A reaction or an "opened by" re-sent old messages to
    every current member: pics the newcomer couldn't open, and for older
    plaintext messages, the text itself.)"""
    ra, rb, rc = (ok(register(f"lj_{n}_{tag}")).json() for n in "abc")
    a_tok, b_tok, c_tok = ra["token"], rb["token"], rc["token"]
    befriend(a_tok, rb["user"], b_tok, ra["user"]["id"])
    befriend(a_tok, rc["user"], c_tok, ra["user"]["id"])
    gid = ok(call("POST", "/groups", a_tok, json={"name": f"before {tag}", "member_ids": [rb["user"]["id"]]})).json()["id"]
    old = ok(call("POST", f"/groups/{gid}/messages", a_tok, json={"text": "said before cal joined"})).json()
    ok(call("POST", f"/groups/{gid}/members", a_tok, json={"user_id": rc["user"]["id"]}))
    cal = await socket(c_tok)
    ben = await socket(b_tok)
    ok(call("PUT", f"/groups/{gid}/messages/{old['id']}/reaction", b_tok, json={"emoji": "👍"}))
    assert (await next_event(ben, "group_message"))["message"]["id"] == old["id"]   # ben was there
    while True:  # cal gets nothing about it (the join notice came before)
        try:
            ev = await next_event(cal, "group_message", 1.0)
        except (AssertionError, asyncio.TimeoutError):
            break
        assert ev["message"]["id"] > old["id"], "a message from before cal joined reached cal"
        assert "said before cal joined" not in json.dumps(ev)
    new = ok(call("POST", f"/groups/{gid}/messages", a_tok, json={"text": "after"})).json()
    assert (await next_event(cal, "group_message"))["message"]["id"] == new["id"]   # new ones do
    await cal.close()
    await ben.close()
    print("  groups: newcomers never get messages from before they joined, even as updates")


def check_metrics(not_admin):
    """The admin Metrics tab's data: admins only; real readings of this
    machine within ~20 seconds of starting; ranges clamped to what's kept."""
    ok(call("GET", "/admin/metrics", not_admin), 404)
    ok(call("GET", "/admin/metrics"), 401)
    adm = admin_token()
    data = None
    for _ in range(40):
        data = ok(call("GET", "/admin/metrics?hours=1", adm)).json()
        host = data["hosts"][0] if data["hosts"] else None
        # (A reading taken just after a restart can come before any request.)
        if host and host["latest"] and host["latest"].get("requests", [0, 0, 0])[1] > 0:
            break
        time.sleep(1)
    assert data["retention_hours"] == 72 and data["hours"] == 1 and data["interval_secs"] == 10, data
    assert len(data["hosts"]) == 1, data["hosts"]
    host = data["hosts"][0]
    latest = host["latest"]
    assert latest, "readings arrive within 20 seconds"
    for key in ("cpu", "mem", "app_mem", "requests", "disk_data", "sockets"):
        assert key in latest and len(latest[key]) == 3, (key, latest)
    assert 0 <= latest["cpu"][1] <= 100 and 0 < latest["mem"][1] < 100
    assert latest["requests"][1] > 0, "this test's own requests are counted"
    assert host["status"] in ("ok", "watch", "red") and isinstance(host["reasons"], list)
    assert host["info"]["vcpus"] >= 1 and host["info"]["mem_total"] > 0
    # Each reading overlaps the hour: a minute that ends inside it counts (its start may be before).
    assert host["series"] and all(p["t"] + p["s"] > data["generated_at"] - 3600 for p in host["series"])
    if not REMOTE:  # (a deployed server is on AWS)
        assert data["on_aws"] is False and host["estimate"] is None and host["credits"] is None
    # Only production reads the bill; staging (a named environment) doesn't.
    assert data["billing_read"] is (not REMOTE), data["billing_read"]
    assert ok(call("GET", "/admin/metrics?hours=100000", adm)).json()["hours"] == 72
    assert ok(call("GET", "/admin/metrics?hours=0", adm)).json()["hours"] == 1
    print("  metrics: admins only, live readings of this machine, ranges clamped")

def check_guard(tag):
    """Abuse protection (guard.rs). A forwarded address stands in for real
    traffic through Caddy; local requests skip the per-address rules."""
    r = requests.get(BASE + "/robots.txt")
    assert r.status_code == 200 and r.text == "User-agent: *\nDisallow: /\n"
    assert r.headers["X-Robots-Tag"] == "noindex, nofollow, noarchive"

    # Scanning tools are refused outright, wherever they come from.
    assert requests.get(BASE + "/api/config", headers={"User-Agent": "sqlmap/1.8.4#stable"}).status_code == 403
    assert requests.get(BASE + "/", headers={"User-Agent": "Mozilla/5.0 Nuclei - Open-source project"}).status_code == 403

    # Probing for files napsack never has: three strikes, banned for an hour, that address only.
    # (Not remotely: Caddy sets the real address, and staging exempts the tester's.)
    prober = {"X-Forwarded-For": f"203.0.113.{int(tag, 16) % 200 + 1}"}
    bystander = {"X-Forwarded-For": f"198.51.100.{int(tag, 16) % 200 + 1}"}
    for path in ("/.env", "/wp-login.php", "/.git/config"):
        assert requests.get(BASE + path, headers=prober).status_code == 404, path
    if not REMOTE:
        assert requests.get(BASE + "/api/config", headers=prober).status_code == 403, "banned"
        assert requests.get(BASE + "/", headers=prober).status_code == 403
        assert requests.get(BASE + "/api/config", headers=bystander).status_code == 200, "others unaffected"

    # Sessions per person: a fifth sign-in quietly ends the oldest.
    rs = ok(register(f"sess_{tag}")).json()
    name, tokens = rs["user"]["username"], [rs["token"]]
    for _ in range(4):
        tokens.append(ok(call("POST", "/auth/login", json={"username": name, "auth_key": AUTH_KEY})).json()["token"])
    ok(call("GET", "/me", tokens[0]), 401)
    for t in tokens[1:]:
        ok(call("GET", "/me", t))
    assert ok(call("GET", "/me/security", tokens[-1])).json()["active_sessions"] == 4
    print(f"  guard: robots, scanners refused, {'probers banned (local only)' if REMOTE else 'probers banned'}, 4 sessions per person")


def check_edits(tag):
    """Editing texts (edits.rs, plan X29): only the sender, only texts, for 15
    minutes, at most 20 times; a resend isn't a second edit; every version is
    kept; a group edit is sealed for the members the text went to, and each
    gets only their own key."""
    regs = [ok(register(f"ed{x}_{tag}")).json() for x in "abc"]
    (a, a_tok), (b, b_tok), (c, c_tok) = [(r["user"], r["token"]) for r in regs]
    befriend(a_tok, b, b_tok, a["id"])
    ct = lambda: b64(os.urandom(48))
    text = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct(), "format": 2})).json()
    url = f"/chats/{b['id']}/messages/{text['id']}/edit"
    first = {"ciphertext": ct(), "format": 2, "client_id": b64(os.urandom(12))}
    m = ok(call("PUT", url, a_tok, json=first)).json()
    assert m["edit_ciphertext"] == first["ciphertext"] and m["ciphertext"] == text["ciphertext"] and m["edited_at"], m
    assert ok(call("PUT", url, a_tok, json=first)).json()["edited_at"] == m["edited_at"]          # a resend
    ok(call("PUT", f"/chats/{a['id']}/messages/{text['id']}/edit", b_tok, json={"ciphertext": ct(), "format": 2}), 404)  # not theirs
    ok(call("PUT", url, a_tok, json={"ciphertext": ct(), "format": 1}), 400)
    ok(call("PUT", url, a_tok, json={"ciphertext": "not base64!", "format": 2}), 400)
    history = ok(call("GET", f"/chats/{a['id']}/messages/{text['id']}/edits", b_tok)).json()
    assert [e["ciphertext"] for e in history] == [first["ciphertext"]], history
    ok(call("GET", f"/chats/{b['id']}/messages/{text['id']}/edits", c_tok), 404)                  # not in the chat
    assert ok(call("GET", f"/chats/{a['id']}/messages", b_tok)).json()[-1]["edit_ciphertext"] == first["ciphertext"]
    for _ in range(19):
        ok(call("PUT", url, a_tok, json={"ciphertext": ct(), "format": 2}))
    ok(call("PUT", url, a_tok, json={"ciphertext": ct(), "format": 2}), 400)                      # 20 is the most
    pic = ok(call("POST", f"/chats/{b['id']}/snaps?format=2", a_tok, data=os.urandom(500))).json()
    ok(call("PUT", f"/chats/{b['id']}/messages/{pic['id']}/edit", a_tok, json={"ciphertext": ct(), "format": 2}), 400)
    if DB:
        late = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct(), "format": 2})).json()
        db = sqlite3.connect(DB)
        db.execute("UPDATE messages SET created_at = created_at - 16 * 60 WHERE id = ?", (late["id"],))
        db.commit()
        ok(call("PUT", f"/chats/{b['id']}/messages/{late['id']}/edit", a_tok, json={"ciphertext": ct(), "format": 2}), 400)
        assert db.execute("SELECT COUNT(*) FROM message_edits WHERE message_id = ?", (text["id"],)).fetchone()[0] == 20

    # Groups: sealed for the members the text went to.
    g = ok(call("POST", "/groups", a_tok, json={"name": f"edits {tag}", "member_ids": [b["id"]]})).json()
    members = sorted([a["id"], b["id"]])

    def sealed(**over):
        body = {"format": 3, "content": b64(os.urandom(80)), "client_id": b64(os.urandom(16)),
                "recipients": members, "wraps": {str(i): b64(os.urandom(60)) for i in members}}
        body.update(over)
        return body
    gm = ok(call("POST", f"/groups/{g['id']}/messages", a_tok, json=sealed())).json()
    edit = sealed()
    gurl = f"/groups/{g['id']}/messages/{gm['id']}/edit"
    ok(call("PUT", gurl, b_tok, json=sealed()), 404)                                                # not theirs
    ok(call("PUT", gurl, a_tok, json=sealed(recipients=[a["id"]], wraps={str(a["id"]): b64(os.urandom(60))})), 409)
    mine = ok(call("PUT", gurl, a_tok, json=edit)).json()
    assert mine["edit_content"] == edit["content"] and mine["edit_key"] == edit["wraps"][str(a["id"])], mine
    theirs = [x for x in ok(call("GET", f"/groups/{g['id']}/messages", b_tok)).json() if x["id"] == gm["id"]][0]
    assert theirs["edit_key"] == edit["wraps"][str(b["id"])] and edit["wraps"][str(a["id"])] not in json.dumps(theirs)
    versions = ok(call("GET", f"/groups/{g['id']}/messages/{gm['id']}/edits", b_tok)).json()
    assert [(v["content"], v["key"]) for v in versions] == [(edit["content"], edit["wraps"][str(b["id"])])], versions
    ok(call("GET", f"/groups/{g['id']}/messages/{gm['id']}/edits", c_tok), 404)                     # not a member
    print("  edits: the sender's texts, 15 minutes, 20 at most, every version kept, own keys only")


def check_rename(tag):
    """Changing a username (account.rs, usernames.rs; plan X30): needs the
    password, once a week; the old name stays the person's: nobody can sign
    up with it, signing in with it says it changed, and it still finds them."""
    old, new = f"rna_{tag}", f"rnb_{tag}"
    ra, rb = ok(register(old)).json(), ok(register(f"rnc_{tag}")).json()
    (a, a_tok), (b, b_tok) = (ra["user"], ra["token"]), (rb["user"], rb["token"])
    befriend(a_tok, b, b_tok, a["id"])
    new_key = b64(os.urandom(32))
    body = lambda **over: {"username": new, "auth_key": AUTH_KEY, "new_auth_key": new_key,
                           "new_wrapped_private_key": b64(os.urandom(166)), **over}
    ok(call("POST", "/me/username", None, json=body()), 401)
    ok(call("POST", "/me/username", a_tok, json=body(auth_key=b64(os.urandom(32)))), 400)          # wrong password
    ok(call("POST", "/me/username", a_tok, json=body(username="no spaces")), 400)
    ok(call("POST", "/me/username", a_tok, json=body(username=old.upper())), 400)                  # already theirs
    ok(call("POST", "/me/username", a_tok, json=body(username=b["username"])), 400)                # taken
    assert ok(call("POST", "/me/username", a_tok, json=body())).json() == {"username": new}
    assert ok(call("GET", "/me", a_tok)).json()["username"] == new, "the session stays signed in"
    mine = ok(call("GET", f"/users/{a['id']}/profile", a_tok)).json()
    assert mine["past_usernames"] == [old] and mine["next_rename_at"], mine
    theirs = ok(call("GET", f"/users/{a['id']}/profile", b_tok)).json()
    assert theirs["username"] == new and theirs["past_usernames"] == [old]
    chat = [c for c in ok(call("GET", "/friends", b_tok)).json() if c["id"] == a["id"]][0]
    assert chat["username"] == new and chat["was"] == old and chat["renamed_at"], chat
    # Once a week.
    r = ok(call("POST", "/me/username", a_tok, json=body(username=f"rnd_{tag}", auth_key=new_key)), 400)
    assert "once a week" in r.json()["error"], r.text
    # Signing in: the old name says it changed (and doesn't say the new one); the new one works.
    r = ok(call("POST", "/auth/login", json={"username": old, "auth_key": new_key}), 400)
    assert "changed" in r.json()["error"] and new not in r.text, r.text
    ok(call("POST", "/auth/login", json={"username": new, "auth_key": AUTH_KEY}), 400)              # the old key is gone
    ok(call("POST", "/auth/login", json={"username": new, "auth_key": new_key}))
    # The old name is reserved, and still finds them.
    ok(register(old.upper()), 400)
    rc = ok(register(f"rne_{tag}")).json()
    found = ok(call("POST", "/friends/requests", rc["token"], json={"username": old})).json()
    assert found["user"] == {"id": a["id"], "username": new}, found
    if DB:
        db = sqlite3.connect(DB)
        assert db.execute("SELECT COUNT(*) FROM credential_history WHERE user_id = ?", (a["id"],)).fetchone()[0] == 1
    print("  renames: the password, once a week, old names reserved and still found")


def check_videos(tag):
    """Videos (format 4, plan X28): opaque bytes like a pic, view-once, with
    their own larger cap; a pic's cap stays the same."""
    ra, rb = ok(register(f"vida_{tag}")).json(), ok(register(f"vidb_{tag}")).json()
    (a, a_tok), (b, b_tok) = (ra["user"], ra["token"]), (rb["user"], rb["token"])
    befriend(a_tok, b, b_tok, a["id"])
    config = ok(call("GET", "/config")).json()
    assert config["video_max_seconds"] == 10 and config["video_max_bytes"] >= 2 * 1024 * 1024, config
    ok(call("POST", f"/chats/{b['id']}/snaps?format=2", a_tok, data=os.urandom(600 * 1024)), 413)   # too big for a pic
    clip = os.urandom(600 * 1024)
    video = ok(call("POST", f"/chats/{b['id']}/snaps?format=4", a_tok, data=clip)).json()
    assert video["format"] == 4 and video["snap_state"] == "pending", video
    assert ok(call("GET", f"/snaps/{video['id']}", b_tok)).content == clip
    ok(call("POST", f"/snaps/{video['id']}/opened", b_tok))
    ok(call("GET", f"/snaps/{video['id']}", b_tok), 410)                                          # view once
    ok(call("POST", f"/chats/{b['id']}/snaps?format=4", a_tok, data=os.urandom(config["video_max_bytes"] + 1)), 413)
    ok(call("POST", f"/chats/{b['id']}/snaps?format=5", a_tok, data=clip), 400)                    # a group format
    print("  videos: their own cap, view-once, not a group format")


def check_invites(tag):
    """Invite links (invites.rs): stand in for the invite code, make friends,
    work 10 times, can be turned off; only a hash is stored."""
    ra, rb = ok(register(f"inva_{tag}")).json(), ok(register(f"invb_{tag}")).json()
    (a, a_tok), (b, b_tok) = (ra["user"], ra["token"]), (rb["user"], rb["token"])
    made = ok(call("POST", "/invites", a_tok)).json()
    token = made["path"].rsplit("/", 1)[-1]
    assert made["path"] == f"/i/{token}" and len(token) == 22 and made["max_uses"] == 10
    assert requests.get(BASE + made["path"]).status_code == 200, "the link opens the app"
    assert ok(call("GET", f"/invites/lookup/{token}")).json() == {"inviter": {"id": a["id"], "username": a["username"]}}
    ok(call("GET", "/invites/lookup/not-a-real-token-at-all"), 404)
    ok(call("POST", "/invites", None), 401)

    # A stranger signs up with the link instead of the invite code, and they're friends.
    body = lambda name, **extra: {"username": name, "auth_key": AUTH_KEY, "public_key": b64(os.urandom(91)),
                                  "wrapped_private_key": b64(os.urandom(166)), **extra}
    ok(call("POST", "/auth/register", json=body(f"invc_{tag}", invite_token="x" * 22)), 400)
    rc = ok(call("POST", "/auth/register", json=body(f"invc_{tag}", invite_token=token))).json()
    assert [f["id"] for f in ok(call("GET", "/friends", rc["token"])).json()] == [a["id"]]

    # Someone signed in adds the inviter; their own link and a second accept do nothing more.
    ok(call("POST", "/invites/accept", a_tok, json={"token": token}), 400)
    assert ok(call("POST", "/invites/accept", b_tok, json={"token": token})).json()["already"] is False
    assert ok(call("POST", "/invites/accept", b_tok, json={"token": token})).json()["already"] is True
    mine = ok(call("GET", "/invites", a_tok)).json()[0]
    assert [(j["username"], j["kind"]) for j in mine["joined"]] == [(f"invc_{tag}", "signed_up"), (b["username"], "added")]
    assert mine["live"] is True and "token" not in json.dumps(mine)

    # Ten uses, then it's done.
    used_up = ok(call("POST", "/invites", a_tok)).json()["path"].rsplit("/", 1)[-1]
    for i in range(10):
        ok(call("POST", "/auth/register", json=body(f"inv{i}_{tag}", invite_token=used_up)))
    ok(call("POST", "/auth/register", json=body(f"invx_{tag}", invite_token=used_up)), 400)
    ok(call("GET", f"/invites/lookup/{used_up}"), 404)

    # Turned off: it stops working, for sign-up and for adding.
    ok(call("POST", f"/invites/{made['id']}/revoke", b_tok), 404)                 # not theirs
    ok(call("POST", f"/invites/{made['id']}/revoke", a_tok))
    ok(call("GET", f"/invites/lookup/{token}"), 404)
    ok(call("POST", "/auth/register", json=body(f"invy_{tag}", invite_token=token)), 400)

    # The personal link (X25): the same one every time, past 10 uses, not in the
    # invite list, until it's reset.
    ok(call("GET", "/friend-link", None), 401)
    ok(call("POST", "/friend-link/reset", None), 401)
    personal = ok(call("GET", "/friend-link", a_tok)).json()["path"]
    assert ok(call("GET", "/friend-link", a_tok)).json()["path"] == personal
    assert ok(call("GET", "/friend-link", b_tok)).json()["path"] != personal
    own = personal.rsplit("/", 1)[-1]
    for i in range(11):
        ok(call("POST", "/auth/register", json=body(f"inp{i}_{tag}", invite_token=own)))
    assert ok(call("GET", "/friend-link", a_tok)).json()["uses"] == 11
    assert all(i["max_uses"] == 10 for i in ok(call("GET", "/invites", a_tok)).json()), "personal links aren't listed"
    renewed = ok(call("POST", "/friend-link/reset", a_tok)).json()["path"]
    assert renewed != personal and ok(call("GET", "/friend-link", a_tok)).json()["path"] == renewed
    ok(call("GET", f"/invites/lookup/{own}"), 404)
    ok(call("POST", "/auth/register", json=body(f"inpx_{tag}", invite_token=own)), 400)
    assert ok(call("GET", f"/invites/lookup/{renewed.rsplit('/', 1)[-1]}")).json()["inviter"]["id"] == a["id"]
    if DB:
        stored = [h for (h,) in sqlite3.connect(DB).execute("SELECT token_hash FROM invites WHERE created_by = ?", (a["id"],))]
        assert stored and all(t not in h for h in stored for t in (token, used_up, own)), "only hashes are stored"
    print("  invites: sign up without the code, friends at once, 10 uses, turned off, hashed; personal link until reset")


def check_rate_limits(tag):
    """Failed sign-ins lock a username for a while; one address can't hammer sign-up."""
    name = f"lock_{tag}"
    ok(register(name))
    for _ in range(10):
        ok(call("POST", "/auth/login", json={"username": name, "auth_key": b64(os.urandom(32))}), 400)
    r = call("POST", "/auth/login", json={"username": name, "auth_key": AUTH_KEY})
    assert r.status_code == 429, ("even the right password waits out the lock", r.status_code)
    # Behind Caddy the address comes from X-Forwarded-For; a local test can
    # stand in for a remote one by sending it (production ignores spoofed ones).
    # (Not remotely: Caddy sets the real address, and staging exempts the tester's.)
    if REMOTE:
        print("  rate limits: 10 failed sign-ins lock the account (per-address limit: local only)")
        return
    remote = {"X-Forwarded-For": f"203.0.113.{int(tag[:2], 16) % 250 + 1}"}
    # A different username each time, so only the per-address limit applies.
    codes = [call("POST", "/auth/login", headers=remote, json={"username": f"nobody{i}_{tag}", "auth_key": AUTH_KEY}).status_code
             for i in range(31)]
    assert codes[:30] == [400] * 30 and codes[30] == 429, codes
    print("  rate limits: 10 failed sign-ins lock the account; 30 attempts per address")

def ok(r, code=200):
    assert r.status_code == code, f"{r.request.method} {r.url} -> {r.status_code} {r.text}"
    return r

def register(name, **extra):
    body = {
        "username": name, "auth_key": AUTH_KEY,
        "public_key": b64(os.urandom(91)), "wrapped_private_key": b64(os.urandom(166)),
        **extra,
    }
    if INVITE: body.setdefault("invite_code", INVITE)
    return call("POST", "/auth/register", json=body)

async def ws_events(token, bucket, ready):
    url = BASE.replace("http", "ws") + "/api/ws"
    async with websockets.connect(url) as ws:
        await ws.send(json.dumps({"type": "auth", "token": token}))
        while True:
            ev = json.loads(await ws.recv())
            if ev["type"] == "ready": ready.set(); continue
            bucket.append(ev)

def check_versions(token):
    """/config describes the server; old native clients get 426 everywhere else."""
    cfg = ok(call("GET", "/config")).json()
    assert cfg["api_version"] == 1 and cfg["message_formats"] == [1, 2, 4] and cfg["snap_ttl_hours"] == 720, cfg
    assert cfg["server_version"] and cfg["build"], cfg
    # Which copy this is: null in production (and here, locally); staging names itself.
    assert cfg["environment"] == ("staging" if REMOTE else None), cfg
    assert isinstance(cfg["started_at"], int) and cfg["started_at"] <= time.time() + 5, cfg
    min_ios = cfg["min_client_versions"].get("ios")
    if not min_ios:
        print("  (no minimum iOS version configured; skipping 426 checks)")
        return
    major, minor, patch = (int(x) for x in min_ios.split("."))
    older = f"ios/{major}.{minor}.{patch - 1}" if patch else f"ios/{major}.{max(minor - 1, 0)}.99"
    if (major, minor, patch) == (0, 0, 0):
        return
    r = call("GET", "/me", token, headers={"X-Napsack-Client": older + "+7"})
    assert r.status_code == 426 and "Update to" in r.json()["error"], (r.status_code, r.text)
    ok(call("GET", "/me", token, headers={"X-Napsack-Client": f"ios/{min_ios}+1"}))
    ok(call("GET", "/config", headers={"X-Napsack-Client": older}))   # /config always answers
    ok(call("GET", "/me", token, headers={"X-Napsack-Client": "android/0.0.1"}))  # no minimum set
    ok(call("GET", "/me", token))                                         # web client: no header
    print(f"  version gate: {older} -> 426, ios/{min_ios} ok")

async def main():
    tag = uuid.uuid4().hex[:6]
    if INVITE:
        ok(register(f"x{tag}", invite_code="nope"), 400)
    ok(register(f"y{tag}", public_key="not base64!"), 400)
    ok(register(f"z{tag}", auth_key="short"), 400)

    ra = ok(register(f"alex_{tag}")).json()
    rb = ok(register(f"sam_{tag}")).json()
    a, b, b_tok = ra["user"], rb["user"], rb["token"]
    check_versions(b_tok)
    ok(call("GET", "/admin/logs", b_tok), 404)   # not an admin
    ok(call("GET", "/admin/logs"), 401)
    check_metrics(b_tok)
    # Client diagnostics: accepted signed in or not, size-capped, rate-limited per user.
    entry = {"level": "info", "message": "smoke", "fields": {"status": 1}}
    assert call("POST", "/logs", json={"entries": [entry]}).status_code == 204
    assert call("POST", "/logs", b_tok, json={"entries": [entry]}).status_code == 204
    ok(call("POST", "/logs", b_tok, json={"entries": [entry] * 51}), 400)
    for _ in range(7):
        assert call("POST", "/logs", b_tok, json={"entries": [entry] * 50}).status_code == 204  # over the cap: dropped quietly
    ok(register(f"ALEX_{tag}"), 409)

    # Sign-in uses the derived auth key and hands back the wrapped private key unchanged.
    ok(call("POST", "/auth/login", json={"username": a["username"], "auth_key": b64(os.urandom(32))}), 400)
    la = ok(call("POST", "/auth/login", json={"username": a["username"].upper(), "auth_key": AUTH_KEY})).json()
    a_tok = la["token"]
    assert la["wrapped_private_key"] == ra["wrapped_private_key"] and la["public_key"] == ra["public_key"]
    assert "password" not in json.dumps(la)

    b_events, b_ready = [], asyncio.Event()
    a_events, a_ready = [], asyncio.Event()
    tasks = [asyncio.create_task(ws_events(b_tok, b_events, b_ready)),
             asyncio.create_task(ws_events(a_tok, a_events, a_ready))]
    await asyncio.wait_for(asyncio.gather(b_ready.wait(), a_ready.wait()), 5)

    ct = b64(os.urandom(12 + 16 + 20))
    # Not friends yet: messaging and profiles are refused.
    ok(call("GET", f"/users/{b['id']}/profile", a_tok), 404)
    ok(call("GET", "/users/999999/profile", a_tok), 404)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct}), 404)

    for evil in ["' OR '1'='1", "admin'--", "x\"; DROP TABLE users; --", "%", "_", "nate%", "*"]:
        r = call("POST", "/friends/requests", a_tok, json={"username": evil})
        assert r.status_code in (400, 404), (evil, r.status_code, r.text)
        r = call("POST", "/auth/login", json={"username": evil, "auth_key": "' OR '1'='1"})
        assert r.status_code in (400, 401, 429), (evil, r.status_code)
        assert "token" not in r.text
    for evil in ["bob' --", "a;b", "<script>", "a\u202eb", "nul\u0000"]:
        assert register(evil).status_code == 400, evil
    assert ok(call("POST", "/friends/requests", a_tok, json={"username": b["username"]})).json()["status"] == "requested"
    reqs = ok(call("GET", "/friends/requests", b_tok)).json()
    assert [r["id"] for r in reqs["incoming"]] == [a["id"]]
    ok(call("POST", f"/friends/requests/{a['id']}/accept", b_tok))
    chats_a = ok(call("GET", "/friends", a_tok)).json()
    assert [c["id"] for c in chats_a] == [b["id"]]
    assert chats_a[0]["public_key"] == rb["public_key"], "chat list carries the friend's public key"

    # Texts: ciphertext only, stored and returned untouched.
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"text": "plaintext"}), 422)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": "hello there"}), 400)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(16000))}), 400)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct, "format": 3}), 400)
    m = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct})).json()
    assert m["ciphertext"] == ct and "body" not in m and m["format"] == 1
    chats = ok(call("GET", "/friends", b_tok)).json()
    assert chats[0]["unread"] == 1 and chats[0]["last_message"]["ciphertext"] == ct
    ok(call("POST", f"/chats/{a['id']}/read", b_tok))
    assert ok(call("GET", "/friends", b_tok)).json()[0]["unread"] == 0

    # Snaps: opaque bytes, view-once.
    ok(call("POST", f"/chats/{b['id']}/snaps", a_tok, data=b"tiny"), 400)
    ok(call("POST", f"/chats/{b['id']}/snaps?format=3", a_tok, data=SNAP), 400)
    snap = ok(call("POST", f"/chats/{b['id']}/snaps?format=2", a_tok, data=SNAP,
                   headers={"Content-Type": "application/octet-stream"})).json()
    assert snap["snap_state"] == "pending" and snap["ciphertext"] is None and snap["format"] == 2
    ok(call("GET", f"/snaps/{snap['id']}", a_tok), 404)          # sender can't open it
    r = ok(call("GET", f"/snaps/{snap['id']}", b_tok))
    assert r.content == SNAP and "no-store" in r.headers["Cache-Control"]
    # Fetching doesn't open it: a dropped download can be tried again. The app
    # confirms once it has shown the pic; then it's gone.
    assert ok(call("GET", f"/snaps/{snap['id']}", b_tok)).content == SNAP
    ok(call("POST", f"/snaps/{snap['id']}/opened", a_tok), 404)  # only the recipient
    ok(call("POST", f"/snaps/{snap['id']}/opened", b_tok))
    ok(call("POST", f"/snaps/{snap['id']}/opened", b_tok))       # a retry is fine
    ok(call("GET", f"/snaps/{snap['id']}", b_tok), 410)          # opened: gone

    # Profiles: your own has your counts and friends; a friend's has what you share.
    mine = ok(call("GET", f"/users/{a['id']}/profile", a_tok)).json()
    assert mine["kind"] == "me" and [f["id"] for f in mine["friends"]] == [b["id"]], mine
    assert mine["stats"] == {"texts_sent": 1, "texts_received": 0, "pics_sent": 1, "pics_received": 0, "pics_opened": 1}, mine["stats"]
    theirs = ok(call("GET", f"/users/{a['id']}/profile", b_tok)).json()
    assert theirs["kind"] == "friend" and theirs["username"] == a["username"], theirs
    assert theirs["together"]["texts"] == 1 and theirs["together"]["pics"] == 1 and theirs["friend_count"] == 1
    assert "public_key" not in json.dumps(theirs) and "stats" not in theirs
    msgs = ok(call("GET", f"/chats/{a['id']}/messages", b_tok)).json()
    assert msgs[-1]["snap_state"] == "opened"

    # Oversize snap (default cap is 512 KB)
    ok(call("POST", f"/chats/{b['id']}/snaps", a_tok, data=os.urandom(600 * 1024)), 413)

    await asyncio.sleep(0.3)
    kinds_b = [e["type"] for e in b_events]
    kinds_a = [e["type"] for e in a_events]
    assert "friends_changed" in kinds_b and kinds_b.count("message") == 2, kinds_b
    assert "message_updated" in kinds_a and "read" in kinds_a, kinds_a

    # Paging back through a long history: every message exactly once, oldest first per page.
    sent = [ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(40))})).json()["id"]
            for _ in range(120)]
    seen, before = [], None
    while True:
        q = f"?limit=50" + (f"&before={before}" if before else "")
        page = ok(call("GET", f"/chats/{a['id']}/messages{q}", b_tok)).json()
        ids = [m["id"] for m in page]
        assert ids == sorted(ids), "each page is oldest first"
        seen = ids + seen
        if len(page) < 50:
            break
        before = ids[0]
    assert seen == sorted(seen) and len(seen) == len(set(seen)), "no gaps or repeats"
    assert seen[-120:] == sent and len(seen) == 122, len(seen)   # +1 text, +1 snap from earlier
    # Over the cap of 200 is clamped, not an error; 122 fits under it.
    assert len(ok(call("GET", f"/chats/{a['id']}/messages?limit=500", b_tok)).json()) == 122

    # Unfriend: chat is closed off again.
    ok(call("DELETE", f"/friends/{a['id']}", b_tok))
    ok(call("GET", f"/chats/{b['id']}/messages", a_tok), 404)
    ok(call("GET", f"/users/{b['id']}/profile", a_tok), 404)
    assert ok(call("GET", "/friends", a_tok)).json() == []

    # Nothing was deleted: re-friending brings the whole history back.
    assert ok(call("POST", "/friends/requests", b_tok, json={"username": a["username"]})).json()["status"] == "requested"
    ok(call("DELETE", f"/friends/requests/{b['id']}", a_tok))                 # alex declines
    assert ok(call("GET", "/friends/requests", b_tok)).json()["outgoing"] == []
    assert ok(call("POST", "/friends/requests", b_tok, json={"username": a["username"]})).json()["status"] == "requested"  # asking again works
    ok(call("POST", f"/friends/requests/{b['id']}/accept", a_tok))
    history = ok(call("GET", f"/chats/{b['id']}/messages?limit=200", a_tok)).json()
    assert len(history) == 122, len(history)
    assert [c["id"] for c in ok(call("GET", "/friends", a_tok)).json()] == [b["id"]]

    check_people(tag, a, a_tok, b, b_tok)
    check_groups(tag, a, a_tok, b, b_tok)
    check_marks(tag, a, a_tok, b, b_tok)
    check_group_e2e(tag, a, a_tok, b, b_tok)
    check_streaks(tag, a, a_tok, b, b_tok)

    # Signing out revokes the session; it doesn't come back.
    ok(call("POST", "/auth/logout", a_tok))
    ok(call("GET", "/me", a_tok), 401)
    ok(call("POST", "/auth/logout", a_tok))                                    # twice is harmless
    ok(call("GET", "/me", a_tok), 401)

    check_account(tag)
    if REMOTE:
        print("  live: skipped (needs a local push receiver)")
    else:
        await check_live(tag)
    check_invites(tag)
    check_videos(tag)
    check_edits(tag)
    check_rename(tag)
    await check_resend(tag)
    await check_late_joiner(tag)
    check_graph(tag)
    check_roles(tag)
    check_admin_users(tag)
    check_team(tag)
    check_health()
    check_guard(tag)
    check_rate_limits(tag)
    check_sensitive_paths()
    check_nothing_sensitive_served()
    for t in tasks: t.cancel()
    print("all checks passed")
    print("  events to sam: ", kinds_b)
    print("  events to alex:", kinds_a)

asyncio.run(main())
