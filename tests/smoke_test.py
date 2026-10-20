"""End-to-end API smoke test. scripts/test.sh runs it against a fresh server,
or point it at one yourself:
    python3 tests/smoke_test.py http://127.0.0.1:8080 letmein

Encryption happens in the browser (static/crypto.js), so this test sends
correctly shaped opaque payloads and checks the server stores and returns
them byte-for-byte without needing to understand them.
"""
import asyncio, base64, json, os, sys, uuid
import requests, websockets

BASE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("NAPSACK_URL", "http://127.0.0.1:8080")
INVITE = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("NAPSACK_INVITE")

b64 = lambda raw: base64.b64encode(raw).decode()
AUTH_KEY = b64(os.urandom(32))
SNAP = os.urandom(150 * 1024)  # an encrypted snap is just bytes to the server

def call(method, path, token=None, **kw):
    h = kw.pop("headers", {})
    if token: h["Authorization"] = f"Bearer {token}"
    return requests.request(method, BASE + "/api" + path, headers=h, **kw)

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

    ok(call("POST", "/auth/logout", a_tok))
    ok(call("GET", "/me", a_tok), 401)
    for t in tasks: t.cancel()
    print("all checks passed")
    print("  events to sam: ", kinds_b)
    print("  events to alex:", kinds_a)

asyncio.run(main())
