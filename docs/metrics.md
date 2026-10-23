# Metrics: how they're collected, and how the page is drawn

Status: **built (0.26.0, S3 cost 0.26.3).** The admin panel's **Metrics** tab (`/admin#metrics`) answers three questions: is the infrastructure all right right now, how has it behaved over the last hour to few days, and what does it cost. This document explains where every number comes from and how the page turns those numbers into what you see, so you can trust it, or tell when not to.

The pieces: `server/src/metrics.rs` (collecting, storing, judging, the endpoint), `server/src/aws.rs` (the AWS reads), and the metrics section of `server/static/admin.js` (drawing). No Prometheus, Grafana, agent, or CloudWatch agent: the server measures itself and the machine it runs on.

## The short version

```
every 10 s   /proc, statvfs, request timings ──► one reading ──► last hour, in memory (360 readings)
                                                      │
every minute       6 readings ──► min / avg / max ────┴──► metrics.db (a ring: 3 days × 1,440 minutes per host)
every 5 min        CloudWatch ──► CPU credits (memory only)
every 6 h          CloudWatch ──► S3 bucket sizes (memory only)
every 12 h         Cost Explorer ──► the bill for App=fade (cached in metrics.db)

GET /api/admin/metrics?hours=1|24|72 ──► status per host, series, credits, estimate, bill ──► charts
```

## Where each number comes from

Every 10 seconds the sampler takes one **reading**. Figures that are rates (CPU, disk and network activity, requests) compare counters with the previous reading, so they describe those 10 seconds exactly, not an instant. The first reading after a start only primes the counters, which is why the first data shows up about 20 seconds after the server starts.

| Figure (API name) | Source | How it's worked out |
|---|---|---|
| Machine CPU (`cpu`) | `/proc/stat`, the `cpu` line | Share of all CPU time in the window that wasn't idle or waiting on disk: `(total − idle − iowait) / total`. Covers every vCPU, so 100% means the whole machine is busy. |
| Steal (`steal`), I/O wait (`iowait`) | `/proc/stat` | Their share of the same total. Steal is time AWS gave to someone else; on a t4g it rises when CPU credits run out. |
| Memory (`mem`, `mem_used`) | `/proc/meminfo` | `MemTotal − MemAvailable`. "Available" counts cache the kernel can drop, so this is memory really in use, not the scarier "free" figure. |
| Swap (`swap_used`) | `/proc/meminfo` | `SwapTotal − SwapFree` (the server has none today; it would show if added). |
| Load (`load1`) | `/proc/loadavg` | The 1-minute load average, as the kernel reports it. |
| Disk space (`disk_system`, `disk_data`, and `_used` in bytes) | `statvfs` on `/` and on the data volume | `total − available`. Space the file system reserves for root counts as used, because the app can't use it. If `/` and the data folder are the same volume (development), there's only `disk_data`. |
| Disk activity (`reads_`, `writes_`, `read_bytes_`, `write_bytes_` + volume) | `/proc/diskstats` | Completed reads and writes (and sectors × 512 bytes) per second, for the device holding each volume. The device is found from the volume's device number, so no device names are hard-coded. |
| Network (`net_in`, `net_out`) | `/proc/net/dev` | Bytes per second across every interface except loopback. |
| Server CPU (`app_cpu`) | `/proc/self/stat` | The server's user + system CPU time in the window, as a share of the **whole machine** (divided by vCPUs), so it's directly comparable with machine CPU. |
| Server memory (`app_mem`), threads, open files | `/proc/self/status`, `/proc/self/fd` | Resident memory (RSS), thread count, open file descriptors. |
| Requests, errors (`requests`, `errors`) | The request logger | Every request is counted, including ones the guard refuses (they're load too), except development live reload. Shown per minute: `count × 60 / seconds in the window`. Errors are 5xx responses. |
| Response time (`p50`, `p95`, `p99`) | The request logger | The time from a request reaching the server (behind Caddy) to its response being ready, in microseconds, shown in ms. TLS, Caddy, and the network aren't included. Percentiles are exact (nearest rank over every request) up to 20,000 requests per window; beyond that, a uniform random sample of 20,000. |
| Live connections (`sockets`, `online`) | The socket hub | Open app connections, and how many people they belong to. |
| Database size (`db_bytes`) | The file system | `fade.db` plus its write-ahead log. |

Facts that don't change between readings are taken once at start: vCPUs, total memory, the server's memory cap (its cgroup's `memory.max`, which is systemd's `MemoryMax=400M`), each volume's size, and, on EC2, the instance's id, type, zone, region and account (from instance metadata, IMDSv2).

## How it's kept

**The last hour** stays in memory as the raw 10-second readings (360 of them).

**Each minute** becomes one point: for every figure, the **min, average, and max** of that minute's six readings. Keeping min and max means a 10-second spike survives as the minute's max instead of vanishing into an average. Response-time percentiles are the exception: they're computed again from all of the minute's requests, because averaging six p95s isn't a p95.

Minutes go to **`metrics.db`**, next to the database on the data volume, so history survives deploys and restarts. It's not the app's database and holds no user data. Its `minutes` table is a ring: a minute's slot is `minute mod (retention hours × 60)`, written with an upsert, so the file holds at most one row per minute of the window per host (about 6 MB for three days) and never grows. Nothing is deleted; old minutes are overwritten. `hosts` keeps each machine's facts; `cache` keeps the last bill.

**Retention** is `FADE_METRICS_RETENTION_HOURS` (72 by default, up to 31 days), read at start. Reads always filter by time, so changing it never shows stale minutes.

If `metrics.db` can't be opened, the tab still works with the last hour only, and the server logs a warning.

## What comes from AWS

On EC2 the server also reads a few things AWS knows and the machine doesn't. Calls are signed in `aws.rs` (Signature Version 4, checked in a unit test against AWS's published example) with the instance role's temporary credentials. Every address is fixed in the code, and the role's permissions are read-only (`ReadCpuCredits`, `ReadCosts` in `infra/main.tf`).

| What | From | How often | Cost |
|---|---|---|---|
| CPU credit balance and surplus credits charged | CloudWatch `AWS/EC2` (`CPUCreditBalance`, `CPUSurplusCreditsCharged`), 5-minute points over the whole retention window | Every 5 minutes; kept in memory only (CloudWatch keeps 15 days) | Free (inside the API free tier) |
| Each bucket's size per storage class | CloudWatch `AWS/S3` `BucketSizeBytes` for the backups and artifacts buckets, Standard and Glacier Instant Retrieval | Every 6 hours (S3 publishes once a day) | Free |
| The bill | Cost Explorer `GetCostAndUsage`: everything tagged `App=fade`, by service, per month, from the start of last month to today | Every 12 hours, cached in `metrics.db` so a restart doesn't call again | $0.01 a call, about $0.60 a month |

A read that fails (say, a missing permission) is shown on the page in red and logged once as a warning; a repeat is logged quietly, and a recovery is logged ("... works again"). A failed bill is retried after an hour, bucket sizes too.

## From readings to the API

`GET /api/admin/metrics?hours=` (admins only; [API.md](API.md)) returns one entry per host with these parts:

- **Series.** For the last hour, the 10-second readings, each as `[x, x, x]`. For longer ranges, the stored minutes inside the range, plus the newest reading standing in for the minute in progress. If that's more than 720 points, consecutive points are merged into buckets: the min of their mins, the mean of their averages, the max of their maxes, labeled with the first point's time. 24 hours (1,440 minutes) becomes 720 two-minute points; three days, 720 six-minute points.
- **Status** from the last 10 minutes (the 10-second readings for this machine; stored minutes for any other). A host with nothing for 15 minutes is left out.
- **Credits, estimate, bill**, as below.

## How the page is drawn

### Status ("How it's doing")

Each host gets **All good**, **Worth watching**, or **In the red**: the worst of these checks, with a sentence for each one that isn't fine (red ones first). Status always carries its icon and label, never color alone.

| Check | Uses | Watch at | Red at |
|---|---|---|---|
| Memory | average `mem`, last 10 min | 80% | 90% |
| Each disk | newest `disk_*` | 80% | 90% |
| Server memory | average `app_mem` against its cap | 75% of 400 MB | 90% |
| Steal | average `steal` | 10% | 25% |
| CPU credits (burstable, when CloudWatch answers) | newest balance against a full bank (144 on a t4g.nano: vCPUs × baseline × 60 × 24) | under a third | under a tenth |
| Paid-for CPU | surplus credits charged, last 24 h | any | |
| CPU (only without credit data) | average `cpu` | 70% | 90% |
| Response time | average `p95` | 500 ms | 2 s |
| Server errors | 5xx in the last 10 minutes | 1 | 10 |

Why credits and not CPU %: a t4g may use its baseline (5% of each vCPU on a nano) for free and banks credits when below it. Running above the baseline is fine while credits last; once they're gone, the server is held to its baseline (standard mode, which napsack's server uses: requests slow down and steal rises) or CPU over the baseline is billed (unlimited mode, where the "Extra CPU" cost line counts it). So 30% CPU can be all good, and the credit balance is what says when it isn't.

### Charts

Each chart is **one measure**, never two scales on one chart:

| Chart | Lines | Reference lines (dashed) |
|---|---|---|
| CPU | machine `cpu`, server `app_cpu` | the free baseline (5% on a t4g.nano) |
| CPU credits (AWS only) | balance | a full bank |
| Memory | `mem` | 80% |
| Server memory | `app_mem` | its 400 MB cap |
| Disk space | `disk_*` per volume | 80% |
| Disk activity | reads + writes per second, per volume | |
| Network | `net_in`, `net_out` | |
| Requests | `requests` per minute | |
| Response time | `p50`, `p95` | |
| Live connections | `sockets` | |

How a chart is built from the series:

- **Only points inside the range** are used, for the lines, the scale, the legend, and the table. CPU credits arrive for the whole window whatever the range, so this matters there.
- **The line is each point's average; the faint band around it is that point's min to max.** For the last hour each point is one reading, so there's no band. For longer ranges the band is where a spike shows: a CPU line at 3% with a band reaching 40% means a short burst inside that minute or bucket.
- **Gaps stay gaps.** Where two points are more than three times the usual spacing apart (the server was down, or before metrics existed), the line breaks rather than drawing a straight bridge across time with no readings.
- **Scales start at zero.** Percentages run 0 to 100%. Everything else runs from 0 to a round number (1, 2, 2.5 or 5 × 10ⁿ) just above the highest max or reference line in view.
- **Time** runs from `now − hours` to now, with labels at the start, middle and end; at a day or more they name the weekday.
- **Two lines get a legend** with each line's newest value; one line shows its newest value by the title. Colors are fixed per position (blue first, orange second), validated for color-blind separation and contrast on the dark background.
- **Hover** finds the point nearest the pointer and shows each line's average, with the min–max range when there is one.
- **The table** ("Show as table") lists every line: *now* is the newest point's average, *average* the mean of the points' averages over the range, *peak* the highest max.

It refreshes every 10 seconds on the 1-hour view and every minute otherwise, only while the tab is on screen. A range picked while another is loading loads right after, and an answer for a range no longer picked is dropped.

### Cost

**Estimate**, "a month at today's rate", from us-east-1 on-demand prices (October 2026, 730 hours a month):

| Line | How |
|---|---|
| Server | the instance type's hourly price × 730 (t4g.nano: $0.0042/h → $3.07) |
| Disks | each volume's size rounded up to a whole GB × $0.08 (gp3); the file system reports slightly less than the volume, hence the rounding |
| Public address | $0.005/h × 730 = $3.65 |
| Storage (S3) | each bucket's bytes per class × $0.023/GB (Standard) or $0.004/GB (Glacier Instant Retrieval, where backups move after 30 days) |
| Extra CPU | surplus credits charged in the last 24 h × 30 × $0.04/60 per credit (t4g; one credit is one vCPU-minute) |

Not in the estimate: EBS snapshots (a few cents), S3 requests (fractions of a cent), and data transfer (the first 100 GB a month are free). The **next size up** shows its price and free CPU baseline, to compare when a status turns red.

**Billed** is AWS's own number from Cost Explorer for everything tagged `App=fade`: this month so far and last month, with every service of a cent or more. AWS marks the current month as estimated until it closes. Billing data starts the day the `App` cost tag was turned on in AWS Billing; tags don't apply to costs from before unless AWS backfills them (an option on the cost allocation tags page).

## More than one machine

Every stored minute and host record carries its host (the EC2 instance id), the endpoint returns one entry per host, and the page shows a machine picker when there's more than one. What isn't built yet is the way in for another machine's readings: the plan is the same sampler running as a small `fade-server agent` mode that posts to the main server ([plan.md](plan.md), I4).

## Accuracy, in brief

- Rates are exact over each 10-second window: counter differences divided by the measured elapsed time, not the nominal 10 seconds.
- Minute min/avg/max come from all six readings; spikes shorter than 10 seconds are averaged within their reading.
- Percentiles are exact per window and per minute (up to 20,000 requests per window), never averaged.
- "Average" over a long range is the mean of minute averages, so every minute counts equally.
- Response times are the server's own; what a person waits also includes the network and TLS.
- The estimate is a rate, not a bill; the billed figure is the truth, a day behind.

## Tests

- `metrics.rs` unit tests: parsing each `/proc` file (including a command name with spaces and parentheses), CPU and percentile math, the latency sample staying bounded and fair, minutes keeping spikes, downsampling keeping peaks, the ring never exceeding its slots, every status rule, the estimate (including S3), and AWS failures warning once each.
- `aws.rs` unit tests: SigV4 against AWS's example, query encoding, date conversions, CloudWatch XML, error codes, bucket names.
- `tests/smoke_test.py` `check_metrics`: admins only, real readings of the test machine, ranges clamped.
- `tests/e2e/test_metrics.py`: the status, every chart drawn, hover, all three ranges, nothing drawn outside a chart's plot area, a quick second range click winning, and the phone layout.
