"""Unopened pics survive a server restart (F9). Run by scripts/test.sh in two
phases around a restart:

    restart_test.py before   # send pics, note them in $NAPSACK_RESTART_STATE
    (server restarts)
    restart_test.py after    # they still open, once; a pic whose file was lost is expired

`before` also deletes one pic's file, standing in for a pic that only an older
release held (in memory) or that the disk lost. Plain HTTP, no browser.
"""
import base64, json, os, sys, uuid

import requests

BASE = os.environ.get("NAPSACK_URL", "http://127.0.0.1:8099") + "/api"
INVITE = os.environ.get("NAPSACK_INVITE", "")
STATE = os.environ["NAPSACK_RESTART_STATE"]
PIC_DIR = os.path.join(os.path.dirname(os.environ["NAPSACK_DB"]), "pics", "direct")
AUTH_KEY = "A" * 43 + "="


def call(method, path, token=None, **kw):
    headers = kw.pop("headers", {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return requests.request(method, BASE + path, headers=headers, timeout=10, **kw)


def ok(r, code=200):
    assert r.status_code == code, (r.request.method, r.url, r.status_code, r.text[:200])
    return r


def register(name):
    b64 = lambda n: base64.b64encode(os.urandom(n)).decode()
    body = {"username": name, "auth_key": AUTH_KEY, "public_key": b64(91), "wrapped_private_key": b64(166)}
    if INVITE:
        body["invite_code"] = INVITE
    r = ok(call("POST", "/auth/register", json=body)).json()
    return r["user"], r["token"]


def before():
    tag = uuid.uuid4().hex[:6]
    a, a_tok = register(f"rs_a_{tag}")
    b, b_tok = register(f"rs_b_{tag}")
    ok(call("POST", "/friends/requests", a_tok, json={"username": b["username"]}))
    ok(call("POST", f"/friends/requests/{a['id']}/accept", b_tok))
    kept, lost = os.urandom(90_000), os.urandom(500)
    pics = [ok(call("POST", f"/chats/{b['id']}/snaps?format=2", a_tok, data=data)).json() for data in (kept, lost)]
    os.remove(os.path.join(PIC_DIR, f"{pics[1]['id']}.bin"))
    with open(STATE, "w") as f:
        json.dump({"a_id": a["id"], "b_tok": b_tok, "kept": pics[0]["id"], "lost": pics[1]["id"], "bytes": kept.hex()}, f)
    print("sent two pics; removed one's file")


def after():
    s = json.load(open(STATE))
    r = ok(call("GET", f"/snaps/{s['kept']}", s["b_tok"]))
    assert r.content == bytes.fromhex(s["bytes"]), "pic changed across the restart"
    # Fetching doesn't open it; the app confirms once it's on screen.
    ok(call("POST", f"/snaps/{s['kept']}/opened", s["b_tok"]))
    ok(call("GET", f"/snaps/{s['kept']}", s["b_tok"]), 410)
    assert not os.path.exists(os.path.join(PIC_DIR, f"{s['kept']}.bin")), "opened pic's file is gone"
    ok(call("GET", f"/snaps/{s['lost']}", s["b_tok"]), 410)
    states = {m["id"]: m["snap_state"] for m in ok(call("GET", f"/chats/{s['a_id']}/messages", s["b_tok"])).json()}
    assert states == {s["kept"]: "opened", s["lost"]: "expired"}, states
    print("unopened pic survived the restart and opened once; the lost one is expired")


{"before": before, "after": after}[sys.argv[1]]()
