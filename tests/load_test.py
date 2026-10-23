"""Load test (docs/staging.md): how many people and how much traffic napsack
handles. Staging only, never production.

    python tests/load_test.py --stages 50,100,200 --rate 6 --duration 60

Each test account holds a live socket, as an open app does, and sends texts
to its friends at --rate texts a minute. Per stage it reports:
- send: how long POST /chats/{id}/messages takes;
- delivery: from sending to arrival on the friend's socket (what people feel);
- errors, dropped sockets, and /api/health's response time under load.

Accounts are registered once, a few at a time (each costs a password hash on
the server), and reused from tests/.loadtest-<host>.json on later runs. The
texts are random bytes: the server only ever sees ciphertext anyway.

Settings: NAPSACK_URL and NAPSACK_INVITE (scripts/load-staging.sh sets them).
The machine running it should be in staging's exempt_addresses.
"""
import argparse, asyncio, base64, json, os, random, sys, time, uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

import requests
import websockets

BASE = os.environ.get("NAPSACK_URL", "").rstrip("/")
INVITE = os.environ.get("NAPSACK_INVITE", "")
b64 = lambda raw: base64.b64encode(raw).decode()
POOL = ThreadPoolExecutor(max_workers=64)
local = __import__("threading").local()


def session():
    if not hasattr(local, "s"):
        local.s = requests.Session()
    return local.s


def call(method, path, token=None, **kw):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    return session().request(method, f"{BASE}/api{path}", headers=headers, timeout=30, **kw)


def register(name):
    auth_key = b64(os.urandom(32))
    body = {"username": name, "auth_key": auth_key, "public_key": b64(os.urandom(91)),
            "wrapped_private_key": b64(os.urandom(166)), "invite_code": INVITE}
    r = call("POST", "/auth/register", json=body)
    r.raise_for_status()
    j = r.json()
    return {"id": j["user"]["id"], "username": name, "token": j["token"]}


def befriend(a, b):
    r = call("POST", "/friends/requests", a["token"], json={"username": b["username"]})
    if r.status_code not in (200, 409):
        r.raise_for_status()
    r = call("POST", f"/friends/requests/{a['id']}/accept", b["token"])
    if r.status_code not in (200, 404, 409):  # already friends: fine
        r.raise_for_status()


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, round(p / 100 * len(xs)) - 1))]


def friends_of(i, n, k):
    """A ring: each account is friends with the k after it and the k before it."""
    return sorted({(i + d) % n for d in range(-k, k + 1) if d and n > 1})


def prepare(total, k):
    host = urlparse(BASE).hostname
    path = os.path.join(os.path.dirname(__file__), f".loadtest-{host}.json")
    users = json.load(open(path)) if os.path.exists(path) else []
    if len(users) < total:
        tag = uuid.uuid4().hex[:5]
        print(f"registering {total - len(users)} accounts (a few at a time)...")
        with ThreadPoolExecutor(max_workers=4) as ex:
            new = list(ex.map(register, [f"load_{tag}_{i}" for i in range(len(users), total)]))
        users += new
        json.dump(users, open(path, "w"))
        print("making friends...")
        with ThreadPoolExecutor(max_workers=8) as ex:
            list(ex.map(lambda ij: befriend(users[ij[0]], users[ij[1]]),
                        [(i, j) for i in range(total) for j in friends_of(i, total, k) if j > i]))
    return users[:total]


async def run_stage(users, sockets, n, k, rate, duration, results):
    """n accounts, each sending `rate` texts a minute for `duration` seconds."""
    sent, delivered, send_ms, errors = {}, [], [], []
    health_ms = []
    loop = asyncio.get_running_loop()

    async def listen(i):
        ws = sockets[i]
        try:
            async for raw in ws:
                ev = json.loads(raw)
                if ev.get("type") == "message":
                    m = ev["message"]
                    cid = m.get("client_id")
                    if m.get("recipient_id") == users[i]["id"] and cid in sent:
                        delivered.append((time.perf_counter() - sent[cid]) * 1000)
        except websockets.ConnectionClosed:
            errors.append(f"socket {i} closed")

    def send(i, j):
        cid = uuid.uuid4().hex
        sent[cid] = time.perf_counter()
        t = time.perf_counter()
        try:
            r = call("POST", f"/chats/{users[j]['id']}/messages", users[i]["token"],
                     json={"ciphertext": b64(os.urandom(64)), "format": 2, "client_id": cid})
            send_ms.append((time.perf_counter() - t) * 1000)
            if r.status_code != 200:
                errors.append(f"send {r.status_code}")
        except Exception as e:
            errors.append(f"send {type(e).__name__}")

    async def sender(i):
        await asyncio.sleep(random.random() * 60 / rate)  # spread the starts
        end = time.monotonic() + duration
        while time.monotonic() < end:
            j = random.choice([x for x in friends_of(i, len(users), k) if x < n] or [None])
            if j is not None:
                await loop.run_in_executor(POOL, send, i, j)
            await asyncio.sleep(random.expovariate(rate / 60))

    async def health():
        end = time.monotonic() + duration
        while time.monotonic() < end:
            t = time.perf_counter()
            try:
                await loop.run_in_executor(POOL, lambda: session().get(f"{BASE}/api/health", timeout=10).raise_for_status())
                health_ms.append((time.perf_counter() - t) * 1000)
            except Exception as e:
                errors.append(f"health {type(e).__name__}")
            await asyncio.sleep(5)

    listeners = [asyncio.create_task(listen(i)) for i in range(n)]
    await asyncio.gather(*(sender(i) for i in range(n)), health())
    await asyncio.sleep(3)  # stragglers
    for t in listeners:
        t.cancel()
    row = {
        "accounts": n, "sockets": n, "texts": len(send_ms),
        "texts_per_sec": round(len(send_ms) / duration, 1),
        "send_p50_ms": pct(send_ms, 50), "send_p95_ms": pct(send_ms, 95), "send_max_ms": max(send_ms, default=None),
        "delivered": len(delivered), "delivery_p50_ms": pct(delivered, 50), "delivery_p95_ms": pct(delivered, 95),
        "health_p95_ms": pct(health_ms, 95), "errors": len(errors),
        "error_kinds": dict(sorted({e: errors.count(e) for e in set(errors)}.items())),
    }
    results.append(row)
    fmt = lambda x: "-" if x is None else f"{x:.0f}"
    print(f"{n:>6} accounts | {row['texts_per_sec']:>5} texts/s | send p50 {fmt(row['send_p50_ms'])} p95 {fmt(row['send_p95_ms'])} ms"
          f" | delivery p50 {fmt(row['delivery_p50_ms'])} p95 {fmt(row['delivery_p95_ms'])} ms ({row['delivered']}/{row['texts']})"
          f" | health p95 {fmt(row['health_p95_ms'])} ms | errors {row['errors']} {row['error_kinds'] or ''}")


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stages", default="25,50,100", help="accounts online at each stage, comma-separated")
    ap.add_argument("--friends", type=int, default=3, help="friends on each side in the ring")
    ap.add_argument("--rate", type=float, default=6, help="texts a minute per account")
    ap.add_argument("--duration", type=int, default=60, help="seconds per stage")
    args = ap.parse_args()
    if not BASE or "staging" not in BASE:
        sys.exit("refusing: NAPSACK_URL must be staging (load tests never run against production)")
    stages = [int(s) for s in args.stages.split(",")]
    users = prepare(max(stages), args.friends)
    sockets, results = [], []
    print(f"{BASE}: {args.rate} texts a minute per account, {args.duration}s per stage")
    for n in stages:
        while len(sockets) < n:
            ws = await websockets.connect(BASE.replace("https", "wss").replace("http", "ws") + "/api/ws", max_size=2**20)
            await ws.send(json.dumps({"type": "auth", "token": users[len(sockets)]["token"]}))
            sockets.append(ws)
        for ws in sockets:  # drain the "ready" and catch-up events
            try:
                while True:
                    await asyncio.wait_for(ws.recv(), 0.05)
            except (asyncio.TimeoutError, websockets.ConnectionClosed):
                pass
        await run_stage(users, sockets, n, args.friends, args.rate, args.duration, results)
    for ws in sockets:
        await ws.close()
    out = os.path.join(os.path.dirname(__file__), f".loadtest-{urlparse(BASE).hostname}-results.json")
    json.dump({"at": time.time(), "args": vars(args), "stages": results}, open(out, "w"), indent=2)
    print(f"results: {out}")


if __name__ == "__main__":
    asyncio.run(main())
