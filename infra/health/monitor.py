"""The health monitor (docs/health-monitor.md): every 5 minutes, is napsack's
server healthy? If not, gather evidence, try to fix it (one step per run,
gently first), write the incident down in S3, and notify an SNS topic.

Settings (environment):
  HEALTH_URL   https://<domain>/api/health
  APP_TAG      the App tag of the server to watch (e.g. "fade")
  BUCKET       where state and incidents live (health/...)
  TOPIC_ARN    the SNS topic for notifications
  ACT          "false" to watch and report only
"""
import json
import os
import time
import urllib.error
import urllib.request

FAILURES_TO_ACT = 2          # in a row, 5 minutes apart, before doing anything
CLOCK_SLACK_SECS = 300       # the server's clock must be this close to ours
PROBE_TIMEOUT_SECS = 10
STATE_KEY = "health/state.json"
STEPS = {1: "restart the app", 2: "reboot", 3: "stop and start", 4: "replace (needs a human)"}


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def probe(url, now, fetch):
    """What the health endpoint says, and whether that's healthy."""
    started = time.monotonic()
    try:
        status, body = fetch(url, PROBE_TIMEOUT_SECS)
    except Exception as e:  # unreachable, TLS, timeout
        return {"healthy": False, "reachable": False, "error": f"{type(e).__name__}: {e}"[:300]}
    result = {"reachable": True, "status": status, "ms": round((time.monotonic() - started) * 1000)}
    try:
        data = json.loads(body)
    except ValueError:
        return {**result, "healthy": False, "error": "the answer isn't JSON", "body": body[:300]}
    result["checks"] = data.get("checks")
    result["build"] = data.get("build")
    problems = []
    if status != 200:
        problems.append(f"status {status}")
    if data.get("ok") is not True:
        problems.append("ok is not true")
    if not data.get("build"):
        problems.append("no build")
    t = data.get("time")
    if not isinstance(t, (int, float)) or abs(t - now) > CLOCK_SLACK_SECS:
        problems.append(f"clock off: {t} vs {int(now)}")
    if problems:
        return {**result, "healthy": False, "error": "; ".join(problems)}
    return {**result, "healthy": True}


def next_step(state, instance):
    """Which step to try now: escalating each run, with shortcuts for what the evidence says."""
    last = state.get("last_step", 0)
    if instance is None:
        return 4  # no server to work on
    if instance["state"] in ("pending", "stopping"):
        return 0  # on its way somewhere: give it until the next run
    if instance["state"] == "stopped":
        return 3  # (start it)
    if instance.get("system_status") == "impaired":
        return max(3, last + 1)  # AWS hardware: only a move helps
    step = last + 1
    if step == 1 and not (instance.get("instance_status") == "ok" and instance.get("ssm") == "Online"):
        step = 2  # can't reach the app's machine to restart it
    return min(step, 4)


class Monitor:
    def __init__(self, env, aws, fetch, clock=time.time):
        self.env, self.aws, self.fetch, self.clock = env, aws, fetch, clock
        self.act = env.get("ACT", "true").lower() != "false"

    def run(self):
        now = self.clock()
        state = self.aws.get_json(STATE_KEY) or {"failures": 0, "incident": None, "last_step": 0}
        result = probe(self.env["HEALTH_URL"], now, self.fetch)
        if result["healthy"]:
            if state.get("incident"):
                incident = self.aws.get_json(f"health/incidents/{state['incident']}.json") or {"id": state["incident"], "timeline": []}
                incident.update(status="recovered", closed_at=iso(now))
                incident["timeline"].append({"at": iso(now), "probe": result, "note": "healthy again"})
                self.aws.put_json(f"health/incidents/{incident['id']}.json", incident)
                fixed_by = STEPS.get(state.get("last_step"), "nothing (it recovered on its own)")
                self.aws.notify(f"napsack recovered ({incident['id']})",
                                f"Healthy again at {iso(now)} after {state.get('last_step', 0)} step(s); last tried: {fixed_by}.")
            self.aws.put_json(STATE_KEY, {"failures": 0, "incident": None, "last_step": 0, "last_ok": iso(now)})
            return {"healthy": True, "probe": result}

        state["failures"] = state.get("failures", 0) + 1
        instance = self.aws.describe_instance()
        entry = {"at": iso(now), "probe": result, "instance": instance}
        if state["failures"] < FAILURES_TO_ACT:
            entry["note"] = f"failure {state['failures']} of {FAILURES_TO_ACT} before acting"
            state["pending"] = entry
            self.aws.put_json(STATE_KEY, state)
            return {"healthy": False, "acted": False, "probe": result}

        if instance:
            entry["console_tail"] = self.aws.console_tail(instance["id"])
        if not state.get("incident"):
            state["incident"] = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now))
            incident = {"id": state["incident"], "opened_at": iso(now), "status": "open",
                        "timeline": [state.pop("pending")] if state.get("pending") else []}
            self.aws.notify(f"napsack is unhealthy ({incident['id']})",
                            json.dumps({"probe": result, "instance": instance}, indent=2)[:3000])
        else:
            incident = self.aws.get_json(f"health/incidents/{state['incident']}.json") or {"id": state["incident"], "timeline": []}

        step = next_step(state, instance)
        if step == 0:
            entry["note"] = f"the server is {instance['state']}; waiting for the next run"
            incident["timeline"].append(entry)
            self.aws.put_json(f"health/incidents/{incident['id']}.json", incident)
            self.aws.put_json(STATE_KEY, state)
            return {"healthy": False, "acted": False, "probe": result}
        action = {"step": step, "name": STEPS[step]}
        if not self.act:
            action["result"] = "not taken (ACT=false)"
        elif step == 4:
            action["result"] = "needs a human"
            incident["status"] = "needs_human"
            self.aws.notify(f"napsack needs a human ({incident['id']})",
                            "Restart, reboot, and stop/start didn't help. Replace the server: "
                            "terraform -chdir=infra apply -replace=aws_instance.app, following CLAUDE.md's Rule 1 checklist "
                            "(snapshot the data volume first, check row counts after).")
        else:
            try:
                action["result"] = self.aws.do(step, instance)
            except Exception as e:
                action["result"] = f"failed: {type(e).__name__}: {e}"[:300]
            self.aws.notify(f"napsack: tried to {STEPS[step]} ({incident['id']})", json.dumps(action))
        entry["action"] = action
        incident["timeline"].append(entry)
        state["last_step"] = step if self.act else state.get("last_step", 0)
        self.aws.put_json(f"health/incidents/{incident['id']}.json", incident)
        self.aws.put_json(STATE_KEY, state)
        return {"healthy": False, "acted": self.act, "step": step, "probe": result}


# ---------- AWS (the real thing; tests use a fake) ----------

class Aws:
    def __init__(self, env):
        import boto3  # in the Lambda runtime
        self.env = env
        self.ec2 = boto3.client("ec2")
        self.ssm = boto3.client("ssm")
        self.s3 = boto3.client("s3")
        self.sns = boto3.client("sns")

    def get_json(self, key):
        try:
            return json.loads(self.s3.get_object(Bucket=self.env["BUCKET"], Key=key)["Body"].read())
        except self.s3.exceptions.NoSuchKey:
            return None

    def put_json(self, key, value):
        self.s3.put_object(Bucket=self.env["BUCKET"], Key=key, Body=json.dumps(value, indent=2).encode(),
                           ContentType="application/json")

    def notify(self, subject, message):
        self.sns.publish(TopicArn=self.env["TOPIC_ARN"], Subject=subject[:100], Message=message)

    def describe_instance(self):
        res = self.ec2.describe_instances(Filters=[
            {"Name": "tag:App", "Values": [self.env["APP_TAG"]]},
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
        ])
        found = [i for r in res["Reservations"] for i in r["Instances"]]
        if not found:
            return None
        i = found[0]
        out = {"id": i["InstanceId"], "state": i["State"]["Name"], "type": i["InstanceType"]}
        st = self.ec2.describe_instance_status(InstanceIds=[i["InstanceId"]], IncludeAllInstances=True)["InstanceStatuses"]
        if st:
            out["system_status"] = st[0]["SystemStatus"]["Status"]
            out["instance_status"] = st[0]["InstanceStatus"]["Status"]
        info = self.ssm.describe_instance_information(Filters=[{"Key": "InstanceIds", "Values": [i["InstanceId"]]}])["InstanceInformationList"]
        out["ssm"] = info[0]["PingStatus"] if info else "unknown"
        return out

    def console_tail(self, instance_id):
        try:
            # (boto3 decodes the console output already.)
            return (self.ec2.get_console_output(InstanceId=instance_id, Latest=True).get("Output") or "")[-2000:]
        except Exception as e:
            return f"(console unavailable: {type(e).__name__})"

    def do(self, step, instance):
        iid = instance["id"]
        if step == 1:
            cmd = self.ssm.send_command(InstanceIds=[iid], DocumentName="AWS-RunShellScript",
                                        Parameters={"commands": ["systemctl restart caddy fade", "sleep 3", "systemctl is-active caddy fade"]})
            return f"restart sent (command {cmd['Command']['CommandId']})"
        if step == 2:
            self.ec2.reboot_instances(InstanceIds=[iid])
            return "reboot requested"
        if step == 3:
            # Two runs: stop now; the next run finds it stopped and starts it
            # (no waiting here, so runs never overlap).
            if instance["state"] == "stopped":
                self.ec2.start_instances(InstanceIds=[iid])
                return "started (on new hardware)"
            self.ec2.stop_instances(InstanceIds=[iid])
            return "stop requested; the next run starts it"
        raise ValueError(f"no step {step}")


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "napsack-health-monitor"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, res.read(64 * 1024).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:  # a status, but not 2xx: still an answer
        return e.code, e.read(64 * 1024).decode("utf-8", "replace")


def handler(event, context):
    env = dict(os.environ)
    result = Monitor(env, Aws(env), fetch).run()
    print(json.dumps(result))
    return result
