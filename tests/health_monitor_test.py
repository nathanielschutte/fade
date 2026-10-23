"""The health monitor's decisions (infra/health/monitor.py; docs/implementation/health-monitor.md),
with AWS and the network faked. Run by scripts/test.sh: python3 tests/health_monitor_test.py"""
import json, os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "infra", "health"))
import monitor  # noqa: E402

NOW = 1_792_750_000
HEALTHY = (200, json.dumps({"ok": True, "checks": {"database": "ok", "disk": "ok"}, "build": "abc", "time": NOW}))


class FakeAws:
    def __init__(self, instance=None):
        self.store, self.notes, self.done = {}, [], []
        self.instance = instance if instance is not None else {"id": "i-1", "state": "running", "system_status": "ok", "instance_status": "ok", "ssm": "Online"}

    def get_json(self, key):
        return json.loads(self.store[key]) if key in self.store else None

    def put_json(self, key, value):
        self.store[key] = json.dumps(value)

    def notify(self, subject, message):
        self.notes.append(subject)

    def describe_instance(self):
        return self.instance

    def console_tail(self, iid):
        return "kernel: ..."

    def do(self, step, instance):
        self.done.append(step)
        return f"did {step}"


def run(aws, answer, act="true", clock=NOW):
    def fetch(url, timeout):
        if isinstance(answer, Exception):
            raise answer
        return answer
    env = {"HEALTH_URL": "https://napsack.test/api/health", "ACT": act}
    return monitor.Monitor(env, aws, fetch, clock=lambda: clock).run()


class Tests(unittest.TestCase):
    def test_healthy(self):
        aws = FakeAws()
        self.assertTrue(run(aws, HEALTHY)["healthy"])
        self.assertEqual(aws.get_json(monitor.STATE_KEY)["failures"], 0)
        self.assertEqual(aws.notes, [])

    def test_answers_that_arent_healthy(self):
        bad = [
            (503, json.dumps({"ok": False, "checks": {"database": "slow"}, "build": "abc", "time": NOW})),
            (200, "<html>gateway</html>"),
            (200, json.dumps({"ok": True, "build": "", "time": NOW})),
            (200, json.dumps({"ok": True, "build": "abc", "time": NOW - 3600})),  # a stale cache
        ]
        for answer in bad:
            self.assertFalse(monitor.probe("u", NOW, lambda u, t: answer)["healthy"], answer)
        down = monitor.probe("u", NOW, lambda u, t: (_ for _ in ()).throw(TimeoutError("timed out")))
        self.assertEqual((down["healthy"], down["reachable"]), (False, False))

    def test_one_failure_waits_two_act_and_steps_escalate(self):
        aws = FakeAws()
        r = run(aws, TimeoutError("down"))
        self.assertFalse(r["acted"])
        self.assertEqual(aws.done, [])
        self.assertEqual(aws.notes, [])
        run(aws, TimeoutError("down"), clock=NOW + 300)
        self.assertEqual(aws.done, [1], "restart the app first")
        self.assertTrue(aws.notes[0].startswith("napsack is unhealthy"))
        run(aws, TimeoutError("down"), clock=NOW + 600)
        run(aws, TimeoutError("down"), clock=NOW + 900)
        self.assertEqual(aws.done, [1, 2, 3])
        run(aws, TimeoutError("down"), clock=NOW + 1200)
        self.assertEqual(aws.done, [1, 2, 3], "step 4 isn't automatic yet")
        self.assertTrue(any(n.startswith("napsack needs a human") for n in aws.notes))
        state = aws.get_json(monitor.STATE_KEY)
        incident = aws.get_json(f"health/incidents/{state['incident']}.json")
        self.assertEqual(incident["status"], "needs_human")
        self.assertEqual([e["action"]["step"] for e in incident["timeline"] if "action" in e], [1, 2, 3, 4])
        self.assertIn("console_tail", incident["timeline"][-1])
        self.assertIn("note", incident["timeline"][0], "the first failure is in the record too")

        # Healthy again: the incident closes, and says so.
        r = run(aws, (200, json.dumps({"ok": True, "build": "abc", "time": NOW + 1500})), clock=NOW + 1500)
        self.assertTrue(r["healthy"])
        incident = aws.get_json(f"health/incidents/{state['incident']}.json")
        self.assertEqual(incident["status"], "recovered")
        self.assertTrue(aws.notes[-1].startswith("napsack recovered"))
        self.assertIsNone(aws.get_json(monitor.STATE_KEY)["incident"])

    def test_shortcuts(self):
        # AWS hardware failing: straight to stop and start.
        aws = FakeAws({"id": "i-1", "state": "running", "system_status": "impaired", "instance_status": "impaired", "ssm": "ConnectionLost"})
        run(aws, TimeoutError("down"))
        run(aws, TimeoutError("down"), clock=NOW + 300)
        self.assertEqual(aws.done, [3])
        # Wedged (no SSM): skip the restart, reboot.
        aws = FakeAws({"id": "i-1", "state": "running", "system_status": "ok", "instance_status": "impaired", "ssm": "ConnectionLost"})
        run(aws, TimeoutError("down"))
        run(aws, TimeoutError("down"), clock=NOW + 300)
        self.assertEqual(aws.done, [2])
        # Stopped: start it.
        aws = FakeAws({"id": "i-1", "state": "stopped"})
        run(aws, TimeoutError("down"))
        run(aws, TimeoutError("down"), clock=NOW + 300)
        self.assertEqual(aws.done, [3])

    def test_waits_while_the_server_is_on_its_way(self):
        aws = FakeAws({"id": "i-1", "state": "stopping"})
        run(aws, TimeoutError("down"))
        r = run(aws, TimeoutError("down"), clock=NOW + 300)
        self.assertFalse(r["acted"])
        self.assertEqual(aws.done, [])
        state = aws.get_json(monitor.STATE_KEY)
        incident = aws.get_json(f"health/incidents/{state['incident']}.json")
        self.assertIn("waiting for the next run", incident["timeline"][-1]["note"])

    def test_watch_only(self):
        aws = FakeAws()
        run(aws, TimeoutError("down"), act="false")
        r = run(aws, TimeoutError("down"), act="false", clock=NOW + 300)
        self.assertFalse(r["acted"])
        self.assertEqual(aws.done, [])
        state = aws.get_json(monitor.STATE_KEY)
        incident = aws.get_json(f"health/incidents/{state['incident']}.json")
        self.assertEqual(incident["timeline"][-1]["action"]["result"], "not taken (ACT=false)")

    def test_a_blip_is_forgotten(self):
        aws = FakeAws()
        run(aws, TimeoutError("down"))
        run(aws, HEALTHY, clock=NOW + 300)
        run(aws, TimeoutError("down"), clock=NOW + 600)
        self.assertEqual(aws.done, [], "two failures must be in a row")


if __name__ == "__main__":
    unittest.main(verbosity=1)
