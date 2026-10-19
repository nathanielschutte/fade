"""End-to-end API smoke test. Run against a fresh server:
    FADE_INVITE_CODE=letmein FADE_DATABASE_URL=sqlite:///tmp/fade-test.db cargo run
    python3 scripts/smoke_test.py http://127.0.0.1:8080 letmein

Encryption happens in the browser (static/crypto.js), so this test sends
correctly shaped opaque payloads and checks the server stores and returns
them byte-for-byte without needing to understand them.
"""
import asyncio, base64, json, os, sys, uuid
import requests, websockets

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
INVITE = sys.argv[2] if len(sys.argv) > 2 else None

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

async def main():
    tag = uuid.uuid4().hex[:6]
    if INVITE:
        ok(register(f"x{tag}", invite_code="nope"), 400)
    ok(register(f"y{tag}", public_key="not base64!"), 400)
    ok(register(f"z{tag}", auth_key="short"), 400)

    ra = ok(register(f"alex_{tag}")).json()
    rb = ok(register(f"sam_{tag}")).json()
    a, b, b_tok = ra["user"], rb["user"], rb["token"]
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
    # Not friends yet: messaging is refused.
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
    m = ok(call("POST", f"/chats/{b['id']}/messages", a_tok, json={"ciphertext": ct})).json()
    assert m["ciphertext"] == ct and "body" not in m
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
    msgs = ok(call("GET", f"/chats/{a['id']}/messages", b_tok)).json()
    assert msgs[-1]["snap_state"] == "opened"

    # Oversize snap (default cap is 512 KB)
    ok(call("POST", f"/chats/{b['id']}/snaps", a_tok, data=os.urandom(600 * 1024)), 413)

    await asyncio.sleep(0.3)
    kinds_b = [e["type"] for e in b_events]
    kinds_a = [e["type"] for e in a_events]
    assert "friends_changed" in kinds_b and kinds_b.count("message") == 2, kinds_b
    assert "message_updated" in kinds_a and "read" in kinds_a, kinds_a

    # Unfriend: chat is closed off again.
    ok(call("DELETE", f"/friends/{a['id']}", b_tok))
    ok(call("GET", f"/chats/{b['id']}/messages", a_tok), 404)

    ok(call("POST", "/auth/logout", a_tok))
    ok(call("GET", "/me", a_tok), 401)
    for t in tasks: t.cancel()
    print("all checks passed")
    print("  events to sam: ", kinds_b)
    print("  events to alex:", kinds_a)

asyncio.run(main())
