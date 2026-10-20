"""End-to-end API smoke test. scripts/test.sh runs it against a fresh server,
or point it at one yourself:
    python3 tests/smoke_test.py http://127.0.0.1:8080 letmein

Encryption happens in the browser (static/crypto.js), so this test sends
correctly shaped opaque payloads and checks the server stores and returns
them byte-for-byte without needing to understand them.
"""
import asyncio, base64, json, os, struct, sys, uuid, zlib
import requests, websockets

BASE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("NAPSACK_URL", "http://127.0.0.1:8080")
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
                             ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store")):
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
    pm = ok(call("POST", f"/groups/{gid}/pics", b_tok, data=jpeg, headers={"Content-Type": "image/jpeg"})).json()
    pic = pm["pic"]
    assert pm["pic_id"] == pic["id"] and pic["viewers"] == [] and pic["discard_reason"] is None and pm["body"] == ""
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", b_tok), 400)          # sender can't open it
    ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", d_tok), 404)          # outsider
    r = ok(call("GET", f"/groups/{gid}/pics/{pic['id']}", a_tok))
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
    assert cfg["api_version"] == 1 and cfg["message_formats"] == [1], cfg
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
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": b64(os.urandom(9000))}), 400)
    ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct, "format": 2}), 400)
    m = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct})).json()
    assert m["ciphertext"] == ct and "body" not in m and m["format"] == 1
    chats = ok(call("GET", "/friends", b_tok)).json()
    assert chats[0]["unread"] == 1 and chats[0]["last_message"]["ciphertext"] == ct
    ok(call("POST", f"/chats/{a['id']}/read", b_tok))
    assert ok(call("GET", "/friends", b_tok)).json()[0]["unread"] == 0

    # Snaps: opaque bytes, view-once.
    ok(call("POST", f"/chats/{b['id']}/snaps", a_tok, data=b"tiny"), 400)
    snap = ok(call("POST", f"/chats/{b['id']}/snaps", a_tok, data=SNAP,
                   headers={"Content-Type": "application/octet-stream"})).json()
    assert snap["snap_state"] == "pending" and snap["ciphertext"] is None
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

    check_groups(tag, a, a_tok, b, b_tok)

    # Signing out revokes the session; it doesn't come back.
    ok(call("POST", "/auth/logout", a_tok))
    ok(call("GET", "/me", a_tok), 401)
    ok(call("POST", "/auth/logout", a_tok))                                    # twice is harmless
    ok(call("GET", "/me", a_tok), 401)

    check_rate_limits(tag)
    check_sensitive_paths()
    check_nothing_sensitive_served()
    for t in tasks: t.cancel()
    print("all checks passed")
    print("  events to sam: ", kinds_b)
    print("  events to alex:", kinds_a)

asyncio.run(main())
