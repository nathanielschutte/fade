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
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", a_tok), 410)          # once each
    r = ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", c_tok))           # cal rejoined before it was sent
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
    print("  people: names, private nicknames, pictures; friends only")


# Listed in FADE_ADMINS by scripts/test.sh. A fixed key, so a rerun can sign back in.
SMOKE_ADMIN, SMOKE_ADMIN_KEY = "smoke_admin", base64.b64encode(b"smoke admin key, not a secret..").decode()


def admin_token():
    r = register(SMOKE_ADMIN, auth_key=SMOKE_ADMIN_KEY)
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
    prober = {"X-Forwarded-For": f"203.0.113.{int(tag, 16) % 200 + 1}"}
    bystander = {"X-Forwarded-For": f"198.51.100.{int(tag, 16) % 200 + 1}"}
    assert requests.get(BASE + "/api/config", headers=prober).status_code == 200
    for path in ("/.env", "/wp-login.php", "/.git/config"):
        assert requests.get(BASE + path, headers=prober).status_code == 404, path
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
    print("  guard: robots, scanners refused, probers banned, 4 sessions per person")


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
    if DB:
        stored = [h for (h,) in sqlite3.connect(DB).execute("SELECT token_hash FROM invites WHERE created_by = ?", (a["id"],))]
        assert stored and all(token not in h and used_up not in h for h in stored), "only hashes are stored"
    print("  invites: sign up without the code, friends at once, 10 uses, turned off, hashed")


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
    assert cfg["api_version"] == 1 and cfg["message_formats"] == [1, 2] and cfg["snap_ttl_hours"] == 720, cfg
    assert cfg["server_version"] and cfg["build"], cfg
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
    ok(call("GET", f"/snaps/{snap['id']}", b_tok), 410)          # second view: gone

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

    # Signing out revokes the session; it doesn't come back.
    ok(call("POST", "/auth/logout", a_tok))
    ok(call("GET", "/me", a_tok), 401)
    ok(call("POST", "/auth/logout", a_tok))                                    # twice is harmless
    ok(call("GET", "/me", a_tok), 401)

    check_account(tag)
    await check_live(tag)
    check_invites(tag)
    check_guard(tag)
    check_rate_limits(tag)
    check_sensitive_paths()
    check_nothing_sensitive_served()
    for t in tasks: t.cancel()
    print("all checks passed")
    print("  events to sam: ", kinds_b)
    print("  events to alex:", kinds_a)

asyncio.run(main())
