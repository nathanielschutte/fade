# Health monitor (design)

Status: **built (0.29.0).** Requested by Nate on 2026-10-23 (I6 in [plan.md](plan.md)). napsack runs on one server; this notices from outside when it's unwell, tries to fix it, gently first, and writes down what happened.

## The pieces

```
EventBridge schedule (every 5 minutes)
        │
        ▼
Lambda "fade-health" (Python, outside the VPC)
  1. GET https://<domain>/api/health      ── healthy? reset, done (and close any open incident)
  2. Unhealthy: gather evidence            ── EC2 status checks, instance state, SSM agent, console log tail
  3. Act, one step per run, escalating     ── restart app → reboot → stop/start → (replace: a human, for now)
  4. Record                                 ── S3: health/incidents/<started>.json (evidence + actions + outcome)
  5. Notify                                 ── SNS topic "fade-health" (subscriptions decided later)
        │
        ▼
state between runs: S3 health/state.json (failures in a row, open incident, last step)
```

## The health endpoint

`GET /api/health`, public, no sign-in, nothing private:

```json
{ "ok": true, "checks": { "database": "ok", "disk": "ok" },
  "version": "0.29.0", "build": "abc1234", "time": 1792750000, "uptime_secs": 3600 }
```

- **database:** a `SELECT 1` that must answer within 2 seconds. **disk:** the data disk has room for writes.
- Answers **200** when everything is OK and **503** otherwise, naming which check failed.
- What the monitor verifies: the status code, `ok: true`, a build present, and `time` within 5 minutes of its own clock. A stale cache or a wrong server would fail the last two.

## What counts as unhealthy, and when it acts

- **Unhealthy:** any of these: no answer within 10 seconds (unreachable, a TLS error, a timeout), a non-200 response, `ok: false`, a bad body, or a clock off by more than 5 minutes.
- **Two in a row before acting.** One failure is noted but not acted on. A deploy restarts the server for a second or two, and a blip shouldn't trigger a reboot. Two failures 5 minutes apart open an **incident**.
- **One step per run while it stays unhealthy,** each given 5 minutes to work before the next:

| Step | When | What | Cost of trying |
|---|---|---|---|
| 1. Restart the app | The instance is running, its EC2 status checks pass, and its SSM agent is online | `systemctl restart caddy fade` via SSM Run Command | Seconds |
| 2. Reboot | The instance is running | `ec2:RebootInstances` | A minute or two |
| 3. Stop and start | Always possible | Stop, wait, start: the instance moves to new hardware, keeping its disks and Elastic IP | A few minutes |
| 4. Replace | Still unhealthy after 3 | **Stubbed for now:** an urgent notification with what to run (`terraform apply -replace=aws_instance.app`, with the Rule 1 checklist) | – |

- **Shortcuts:**
  - If AWS's **system** status check is failing (AWS hardware), steps 1 and 2 can't help, so it goes straight to 3.
  - If the instance is **stopped**, it starts it.
  - If the SSM agent is offline (the machine is wedged), it skips step 1.
- **Recovery** is the first healthy answer after an incident. It closes the incident, records how long it lasted and which step fixed it, and notifies.
- **A kill switch:** with `ACT=false` the monitor only watches and reports.

### Why not an Auto Scaling group (yet)

An Auto Scaling group of one would make step 4 automatic: terminate the server and the group launches a fresh one. But the data volume lives in one zone and must be attached by the new server's boot script, and the Elastic IP must be reassociated by it, rather than by Terraform as now. That's the "group of one" in [horizontal-scaling.md](horizontal-scaling.md#cheaper-alternatives), and a change to the boot script that Rule 1 says must be tested against a volume that already has data. Steps 1–3, plus EC2's own automatic recovery (on by default for this instance type), cover the likely failures. Step 4 waits for a human until that's built.

## Incident records

`s3://<artifacts bucket>/health/incidents/<started>.json`, rewritten on every run until the incident closes:

```json
{ "id": "20261023T171000Z", "opened_at": "...", "closed_at": "...", "status": "open|recovered|needs_human",
  "timeline": [
    { "at": "...", "probe": { "reachable": false, "error": "timeout after 10s" },
      "instance": { "state": "running", "system_status": "ok", "instance_status": "impaired", "ssm": "ConnectionLost" },
      "console_tail": "...last 2 KB of the serial console...",
      "action": { "step": 2, "name": "reboot", "result": "requested" } } ] }
```

`health/state.json` holds the failures in a row, the open incident's id, and the last step taken.

## Notifications

SNS topic **fade-health**. Messages: incident opened (with the evidence), each action, recovered, and "needs a human". The topic has no subscriptions yet. Adding an email or a phone later is one command, and no code changes.

## Cost

| | Free tier | Our use |
|---|---|---|
| Lambda | 1M requests and 400,000 GB-seconds a month, always | ~8,700 runs of about 1 second at 128 MB |
| EventBridge scheduled rule | Free | |
| SNS | 1,000 email / 1M mobile push a month | A handful |
| S3 | | A few KB per incident: cents at most |
| CloudWatch Logs (the Lambda's) | 5 GB ingestion free | 14-day retention, tiny |

So about **$0**.

## Permissions (Lambda role)

- **Read:** `ec2:DescribeInstances`, `ec2:DescribeInstanceStatus`, `ec2:GetConsoleOutput`, `ssm:DescribeInstanceInformation`, `ssm:GetCommandInvocation`.
- **Act, only on instances tagged `App=fade`:** `ec2:RebootInstances`, `ec2:StopInstances`, `ec2:StartInstances`, and `ssm:SendCommand` (the `AWS-RunShellScript` document).
- **Record:** `s3:GetObject` and `s3:PutObject` on `health/*` in the artifacts bucket.
- **Notify:** `sns:Publish` on the topic.

No delete permissions of any kind.

## Tests

- `tests/health_monitor_test.py`, run by `scripts/test.sh`: the monitor's decisions with AWS and the network faked. Healthy; one failure (no action); two (step 1); escalation; system check failing (straight to stop/start); stopped instance (start); recovery closing the incident; `ACT=false`; and a body that answers but is wrong.
- **Smoke test:** `/api/health` is public, has every field, and leaks nothing.
- **Production, after deploy:** one manual invocation, reading its log and `health/state.json`. No incident is faked against production.
