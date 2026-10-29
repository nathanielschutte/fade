"""Run the browser tests, several at a time (scripts/test.sh calls this).

Each file runs in its own process with its own browser: starting one costs
under a second, and it keeps the files independent, so one that fails or
hangs can't take the others with it. Running several at once is what saves
the time.

Two kinds of file can't overlap with others, and say so themselves:
- `RUNS_ALONE = "why"` at the top of the file: it changes something every
  page sees (an announcement, the web app's files). These run first, one at
  a time, with nothing else running.
- Files that import ADMIN share the admin account, which can have only so
  many sessions; they take turns, one after another, in a lane of their own.

    python run.py                    every test_*.py here
    python run.py test_chat.py ...   just these
    E2E_JOBS=1 python run.py         one at a time (default: up to 4 at once)

Settings come from the environment, like the tests themselves (common.py).
Prints each file's output when it finishes (each line stamped with when it
came), then every file's time.
"""
import ast, asyncio, glob, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
JOBS = int(os.environ.get("E2E_JOBS") or min(4, os.cpu_count() or 1))
# Longer than any file takes (the slowest is under a minute on CI), so only a
# stuck one is stopped.
TIMEOUT = int(os.environ.get("E2E_TIMEOUT", "300"))


def describe(path):
    """(runs alone because..., shares the admin account) from the file's source."""
    tree = ast.parse(open(path).read(), path)
    alone, admin = None, False
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "RUNS_ALONE" for t in node.targets):
            alone = ast.literal_eval(node.value)
        if isinstance(node, ast.ImportFrom) and node.module == "common":
            admin = admin or any(a.name == "ADMIN" for a in node.names)
    return alone, admin


async def run_file(name, results):
    start = time.perf_counter()
    proc = await asyncio.create_subprocess_exec(
        sys.executable, name, cwd=HERE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    # Each line stamped with when it came (seconds into the file), since the
    # output is printed only once the file is done.
    lines = []

    async def read():
        async for raw in proc.stdout:
            lines.append(f"{time.perf_counter() - start:6.1f}s  {raw.decode(errors='replace').rstrip()}")
        await proc.wait()

    try:
        await asyncio.wait_for(read(), TIMEOUT)
        ok = proc.returncode == 0
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        lines.append(f"stopped after {TIMEOUT}s")
        ok = False
    secs = time.perf_counter() - start
    results.append((name, secs, ok))
    print(f"==> {name}  {secs:.1f}s{'' if ok else '  FAILED'}", flush=True)
    if lines:
        print("\n".join(lines), flush=True)


async def main(names):
    plain, lane, alone = [], [], []
    for name in names:
        why, admin = describe(os.path.join(HERE, name))
        if why:
            alone.append(name)
        elif admin:
            lane.append(name)
        else:
            plain.append(name)
    results = []
    began = time.perf_counter()

    for name in alone:
        await run_file(name, results)

    # The admin lane is the longest unit, so it starts first; then the largest
    # files (a fair guess at the slowest), so short ones fill in at the end.
    units = ([lane] if lane else []) + [[n] for n in sorted(plain, key=lambda n: -os.path.getsize(os.path.join(HERE, n)))]
    queue = asyncio.Queue()
    for unit in units:
        queue.put_nowait(unit)

    async def worker():
        while not queue.empty():
            for name in queue.get_nowait():
                await run_file(name, results)

    await asyncio.gather(*(worker() for _ in range(max(1, JOBS))))
    wall = time.perf_counter() - began

    print(f"\n==> browser test times ({JOBS} at a time)")
    for name, secs, ok in sorted(results, key=lambda r: -r[1]):
        print(f"{secs:7.1f}s  {name}{'' if ok else '  FAILED'}")
    print(f"{sum(r[1] for r in results):7.1f}s  one after another")
    print(f"{wall:7.1f}s  taken")
    failed = [name for name, _, ok in results if not ok]
    if failed:
        print("failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    names = [os.path.basename(a) for a in sys.argv[1:]] or sorted(
        os.path.basename(p) for p in glob.glob(os.path.join(HERE, "test_*.py")))
    sys.exit(asyncio.run(main(names)))
