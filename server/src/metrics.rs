//! Metrics for the admin panel's Metrics tab: how the machine and the server
//! are doing over the last few days (`FADE_METRICS_RETENTION_HOURS`, 72 by
//! default), whether anything is in the red, and what it costs.
//!
//! Every 10 seconds the sampler reads the machine (CPU, memory, disks,
//! network) and this process from /proc, plus the request counters the
//! request logger feeds. The last hour stays in memory at that resolution.
//! Each minute is stored as min/avg/max per figure, so a short spike isn't
//! averaged away, in `metrics.db`: next to the main database but separate
//! from it, holding no user data. It's a fixed ring of slots, one per minute
//! of the retention window per host, that overwrites itself, so it never
//! grows and nothing is ever deleted. Rows carry the host, so readings from
//! more machines can share the store later.
//!
//! On EC2 it also reads the instance's CPU credits from CloudWatch every five
//! minutes (free: basic metrics, inside the API free tier), and the app's
//! bill from Cost Explorer twice a day ($0.01 a call; the answer is kept in
//! metrics.db so restarts don't call again).

use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

use axum::{
    extract::{Query, State},
    Json,
};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::SqlitePool;

use crate::{auth::AuthUser, aws::Aws, db::now, error::AppResult, SharedState};

pub const INTERVAL: Duration = Duration::from_secs(10);
/// Points per chart line, at most: longer ranges are merged into buckets.
const MAX_POINTS: usize = 720;
/// Latencies kept per window for exact percentiles; beyond this, a uniform sample.
const LATENCY_CAP: usize = 20_000;
const CREDITS_EVERY: Duration = Duration::from_secs(5 * 60);
const BILLING_EVERY_SECS: i64 = 12 * 3600;

/// One reading, or one bucket of readings: figure -> [min, avg, max], over
/// the `s` seconds starting at `t`. (A 10-second reading covers the 10
/// seconds before it was taken; a stored minute, that minute.) Charts draw
/// each point at the middle of what it covers.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub t: i64,
    pub s: i64,
    pub v: BTreeMap<String, [f64; 3]>,
}

/// What doesn't change between readings: the machine's size and identity.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct HostInfo {
    pub host: String,
    pub instance: Option<crate::aws::Instance>,
    pub vcpus: u32,
    pub mem_total: u64,
    /// The server's memory cap (systemd MemoryMax), if it has one.
    pub app_mem_limit: Option<u64>,
    /// Volume name ("system", "data") -> size in bytes.
    pub disks: BTreeMap<String, u64>,
}

#[derive(Default)]
struct Requests {
    count: u64,
    errors: u64,
    latencies_us: Vec<u32>,
    seen: u64,
}

/// Keeps a uniform sample of at most LATENCY_CAP latencies (reservoir sampling).
fn keep_latency(list: &mut Vec<u32>, seen: &mut u64, us: u32) {
    *seen += 1;
    if list.len() < LATENCY_CAP {
        list.push(us);
    } else {
        let i = rand::thread_rng().gen_range(0..*seen);
        if (i as usize) < LATENCY_CAP {
            list[i as usize] = us;
        }
    }
}

/// Nearest-rank percentile of sorted values.
fn percentile(sorted: &[u32], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil().max(1.0) as usize;
    Some(f64::from(sorted[rank.min(sorted.len()) - 1]))
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Credits {
    /// (time, balance, surplus credits charged in that period)
    pub points: Vec<(i64, f64, f64)>,
    pub updated_at: i64,
}

pub struct Metrics {
    pub retention_hours: i64,
    store: Option<SqlitePool>,
    requests: Mutex<Requests>,
    live: Mutex<VecDeque<Point>>,
    info: Mutex<HostInfo>,
    aws: OnceLock<Option<Aws>>,
    credits: Mutex<Option<Credits>>,
    /// What's failing when reading AWS (e.g. "reading the bill ..." -> "AccessDenied"), for the page.
    aws_problems: Mutex<BTreeMap<String, String>>,
    /// What the app's S3 buckets hold, from CloudWatch (once a day there).
    s3: Mutex<Option<Vec<S3Stored>>>,
}

/// One bucket's bytes in one storage class.
#[derive(Clone, Debug, Serialize)]
pub struct S3Stored {
    pub bucket: String,
    pub class: &'static str,
    pub bytes: f64,
}

impl Metrics {
    /// The AWS client, once the sampler has found it (None off EC2).
    pub fn aws(&self) -> Option<&Aws> {
        self.aws.get().and_then(Option::as_ref)
    }

    /// Opens (or creates) the metrics store. If it can't, metrics still work,
    /// just without history across restarts.
    pub async fn open(path: &std::path::Path, retention_hours: i64) -> Self {
        let store = match open_store(path).await {
            Ok(pool) => Some(pool),
            Err(e) => {
                tracing::warn!(error = %e, "metrics store unavailable; keeping the last hour in memory only");
                None
            }
        };
        Self {
            retention_hours: retention_hours.clamp(1, 24 * 31),
            store,
            requests: Mutex::default(),
            live: Mutex::default(),
            info: Mutex::default(),
            aws: OnceLock::new(),
            credits: Mutex::default(),
            aws_problems: Mutex::default(),
            s3: Mutex::default(),
        }
    }

    fn slots(&self) -> i64 {
        self.retention_hours * 60
    }

    /// Called by the request logger for every request.
    pub fn record(&self, status: u16, elapsed: Duration) {
        let us = elapsed.as_micros().min(u128::from(u32::MAX)) as u32;
        let mut r = self.requests.lock().unwrap();
        r.count += 1;
        if status >= 500 {
            r.errors += 1;
        }
        let Requests {
            latencies_us, seen, ..
        } = &mut *r;
        keep_latency(latencies_us, seen, us);
    }

    fn host(&self) -> String {
        self.info.lock().unwrap().host.clone()
    }
}

async fn open_store(path: &std::path::Path) -> anyhow::Result<SqlitePool> {
    use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal);
    let pool = SqlitePoolOptions::new()
        .max_connections(2)
        .connect_with(options)
        .await?;
    // Not the app's database, so no migrations: just these tables.
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS minutes (
            host TEXT NOT NULL, slot INTEGER NOT NULL, minute INTEGER NOT NULL, data TEXT NOT NULL,
            PRIMARY KEY (host, slot))",
    )
    .execute(&pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS hosts (host TEXT PRIMARY KEY, info TEXT NOT NULL, updated_at INTEGER NOT NULL)",
    )
    .execute(&pool)
    .await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, at INTEGER NOT NULL)",
    )
    .execute(&pool)
    .await?;
    Ok(pool)
}

// ---------- reading the machine ----------

#[derive(Clone, Copy, Default)]
struct CpuTimes {
    total: u64,
    idle: u64,
    iowait: u64,
    steal: u64,
}

/// The aggregate "cpu" line of /proc/stat.
fn parse_cpu(stat: &str) -> Option<CpuTimes> {
    let line = stat.lines().find(|l| l.starts_with("cpu "))?;
    let f: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    let at = |i: usize| f.get(i).copied().unwrap_or(0);
    // user nice system idle iowait irq softirq steal (guest time is already in user).
    Some(CpuTimes {
        total: (0..8).map(at).sum(),
        idle: at(3),
        iowait: at(4),
        steal: at(7),
    })
}

/// utime + stime from /proc/self/stat, in clock ticks.
fn parse_proc_ticks(stat: &str) -> Option<u64> {
    // The command name (field 2) can hold spaces, so count from after its ")".
    let rest = &stat[stat.rfind(')')? + 1..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    Some(f.get(11)?.parse::<u64>().ok()? + f.get(12)?.parse::<u64>().ok()?)
}

/// (bytes received, bytes sent) across every interface but loopback.
fn parse_net(dev: &str) -> Option<(u64, u64)> {
    let mut total = (0, 0);
    let mut any = false;
    for line in dev.lines().skip(2) {
        let (name, rest) = line.split_once(':')?;
        if name.trim() == "lo" {
            continue;
        }
        let f: Vec<u64> = rest
            .split_whitespace()
            .filter_map(|x| x.parse().ok())
            .collect();
        if f.len() >= 9 {
            total.0 += f[0];
            total.1 += f[8];
            any = true;
        }
    }
    any.then_some(total)
}

/// (reads, writes, sectors read, sectors written) for a device from /proc/diskstats.
fn parse_diskstats(stats: &str, major: u64, minor: u64) -> Option<[u64; 4]> {
    stats.lines().find_map(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        let num = |i: usize| f.get(i).and_then(|x| x.parse::<u64>().ok());
        (num(0)? == major && num(1)? == minor)
            .then(|| Some([num(3)?, num(7)?, num(5)?, num(9)?]))?
    })
}

fn meminfo(text: &str, key: &str) -> Option<u64> {
    text.lines()
        .find(|l| l.starts_with(key))?
        .split_whitespace()
        .nth(1)?
        .parse::<u64>()
        .ok()
        .map(|kb| kb * 1024)
}

fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

/// A volume's device number as (major, minor), from the file system holding `path`.
#[cfg(unix)]
fn device_of(path: &std::path::Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let dev = std::fs::metadata(path).ok()?.dev();
    // glibc's encoding of dev_t.
    let major = ((dev >> 8) & 0xfff) | ((dev >> 32) & !0xfff);
    let minor = (dev & 0xff) | ((dev >> 12) & !0xff);
    Some((major, minor))
}

#[cfg(not(unix))]
fn device_of(_: &std::path::Path) -> Option<(u64, u64)> {
    None
}

/// The server's memory cap from its cgroup (systemd's MemoryMax), if any.
fn cgroup_memory_limit() -> Option<u64> {
    let group = read("/proc/self/cgroup");
    let path = group.lines().find_map(|l| l.strip_prefix("0::"))?;
    read(&format!("/sys/fs/cgroup{path}/memory.max"))
        .trim()
        .parse()
        .ok()
}

fn clock_ticks() -> f64 {
    #[cfg(unix)]
    {
        // SAFETY: sysconf has no preconditions.
        let t = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if t > 0 {
            return t as f64;
        }
    }
    100.0
}

fn cpu_count() -> u32 {
    std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(1)
}

/// Counters from the previous reading, for rates.
#[derive(Default)]
struct Previous {
    at: Option<Instant>,
    cpu: Option<CpuTimes>,
    proc_ticks: Option<u64>,
    net: Option<(u64, u64)>,
    disks: HashMap<String, [u64; 4]>,
}

struct Volume {
    name: String,
    path: std::path::PathBuf,
    device: Option<(u64, u64)>,
}

/// The system disk and the data disk; just one if they're the same volume.
fn volumes(data_dir: &std::path::Path) -> Vec<Volume> {
    let data = Volume {
        name: "data".into(),
        path: data_dir.to_path_buf(),
        device: device_of(data_dir),
    };
    let root = std::path::Path::new("/");
    let system = Volume {
        name: "system".into(),
        path: root.to_path_buf(),
        device: device_of(root),
    };
    if system.device.is_some() && system.device != data.device {
        vec![system, data]
    } else {
        vec![data]
    }
}

/// Takes one reading. Rates (CPU %, per second) compare with `prev`, which
/// is updated; the first call only primes it, so it returns None.
fn sample(
    prev: &mut Previous,
    vols: &[Volume],
    requests: Requests,
    extra: &[(&str, f64)],
    ticks_per_sec: f64,
    vcpus: u32,
) -> Option<BTreeMap<String, f64>> {
    let at = Instant::now();
    let secs = prev.at.map(|p| at.duration_since(p).as_secs_f64());
    let mut v = BTreeMap::new();
    let mut put = |k: &str, x: f64| {
        if x.is_finite() {
            v.insert(k.to_owned(), x);
        }
    };

    let cpu = parse_cpu(&read("/proc/stat"));
    if let (Some(now), Some(before)) = (cpu, prev.cpu) {
        let total = now.total.saturating_sub(before.total) as f64;
        if total > 0.0 {
            let idle = (now.idle + now.iowait).saturating_sub(before.idle + before.iowait) as f64;
            put("cpu", 100.0 * (total - idle) / total);
            put(
                "iowait",
                100.0 * now.iowait.saturating_sub(before.iowait) as f64 / total,
            );
            put(
                "steal",
                100.0 * now.steal.saturating_sub(before.steal) as f64 / total,
            );
        }
    }

    let mem = read("/proc/meminfo");
    if let (Some(total), Some(avail)) = (meminfo(&mem, "MemTotal:"), meminfo(&mem, "MemAvailable:"))
    {
        let used = total.saturating_sub(avail);
        put("mem", 100.0 * used as f64 / total.max(1) as f64);
        put("mem_used", used as f64);
    }
    if let (Some(total), Some(free)) = (meminfo(&mem, "SwapTotal:"), meminfo(&mem, "SwapFree:")) {
        put("swap_used", total.saturating_sub(free) as f64);
    }
    if let Some(load) = read("/proc/loadavg")
        .split_whitespace()
        .next()
        .and_then(|l| l.parse().ok())
    {
        put("load1", load);
    }

    let diskstats = read("/proc/diskstats");
    for vol in vols {
        if let Some((total, free)) = crate::sysinfo::disk_space(&vol.path) {
            let used = total.saturating_sub(free);
            put(
                &format!("disk_{}", vol.name),
                100.0 * used as f64 / total.max(1) as f64,
            );
            put(&format!("disk_{}_used", vol.name), used as f64);
        }
        let now = vol
            .device
            .and_then(|(ma, mi)| parse_diskstats(&diskstats, ma, mi));
        if let (Some(now), Some(before), Some(s)) = (now, prev.disks.get(&vol.name), secs) {
            let rate = |i: usize, scale: f64| now[i].saturating_sub(before[i]) as f64 * scale / s;
            put(&format!("reads_{}", vol.name), rate(0, 1.0));
            put(&format!("writes_{}", vol.name), rate(1, 1.0));
            put(&format!("read_bytes_{}", vol.name), rate(2, 512.0));
            put(&format!("write_bytes_{}", vol.name), rate(3, 512.0));
        }
        if let Some(now) = now {
            prev.disks.insert(vol.name.clone(), now);
        }
    }

    let net = parse_net(&read("/proc/net/dev"));
    if let (Some(now), Some(before), Some(s)) = (net, prev.net, secs) {
        put("net_in", now.0.saturating_sub(before.0) as f64 / s);
        put("net_out", now.1.saturating_sub(before.1) as f64 / s);
    }

    let ticks = parse_proc_ticks(&read("/proc/self/stat"));
    if let (Some(now), Some(before), Some(s)) = (ticks, prev.proc_ticks, secs) {
        // As a share of the whole machine, like "cpu".
        let used = now.saturating_sub(before) as f64 / ticks_per_sec;
        put("app_cpu", 100.0 * used / s / f64::from(vcpus.max(1)));
    }
    let status = read("/proc/self/status");
    if let Some(rss) = meminfo(&status, "VmRSS:") {
        put("app_mem", rss as f64);
    }
    if let Some(threads) = status
        .lines()
        .find_map(|l| l.strip_prefix("Threads:"))
        .and_then(|t| t.trim().parse().ok())
    {
        put("app_threads", threads);
    }
    if let Ok(fds) = std::fs::read_dir("/proc/self/fd") {
        put("app_files", fds.count() as f64);
    }

    if let Some(s) = secs {
        put("requests", requests.count as f64 * 60.0 / s);
        put("errors", requests.errors as f64 * 60.0 / s);
    }
    let mut lat = requests.latencies_us;
    lat.sort_unstable();
    for (k, p) in [("p50", 50.0), ("p95", 95.0), ("p99", 99.0)] {
        if let Some(us) = percentile(&lat, p) {
            put(k, us / 1000.0);
        }
    }
    for (k, x) in extra {
        put(k, *x);
    }

    let primed = prev.at.is_some();
    prev.at = Some(at);
    prev.cpu = cpu;
    prev.proc_ticks = ticks;
    prev.net = net;
    primed.then_some(v)
}

/// Collects a minute of readings into one min/avg/max point.
#[derive(Default)]
struct Minute {
    minute: i64,
    sums: BTreeMap<String, (f64, f64, f64, u32)>,
    latencies_us: Vec<u32>,
    seen: u64,
}

impl Minute {
    fn add(&mut self, v: &BTreeMap<String, f64>) {
        for (k, &x) in v {
            // Percentiles are worked out from the whole minute's requests instead.
            if matches!(k.as_str(), "p50" | "p95" | "p99") {
                continue;
            }
            let e =
                self.sums
                    .entry(k.clone())
                    .or_insert((f64::INFINITY, 0.0, f64::NEG_INFINITY, 0));
            e.0 = e.0.min(x);
            e.1 += x;
            e.2 = e.2.max(x);
            e.3 += 1;
        }
    }

    fn finish(&mut self) -> Option<Point> {
        if self.sums.is_empty() {
            return None;
        }
        let mut v: BTreeMap<String, [f64; 3]> = std::mem::take(&mut self.sums)
            .into_iter()
            .map(|(k, (min, sum, max, n))| (k, [min, sum / f64::from(n), max]))
            .collect();
        self.latencies_us.sort_unstable();
        for (k, p) in [("p50", 50.0), ("p95", 95.0), ("p99", 99.0)] {
            if let Some(us) = percentile(&self.latencies_us, p) {
                let ms = us / 1000.0;
                v.insert(k.into(), [ms, ms, ms]);
            }
        }
        self.latencies_us.clear();
        self.seen = 0;
        Some(Point {
            t: self.minute * 60,
            s: 60,
            v,
        })
    }
}

// ---------- the sampler ----------

pub fn spawn(state: SharedState) {
    tokio::spawn(async move {
        let aws = Aws::detect().await;
        let info = host_info(&state, aws.as_ref().map(|a| a.instance.clone()));
        tracing::info!(host = %info.host, on_aws = aws.is_some(), retention_hours = state.metrics.retention_hours, "metrics started");
        *state.metrics.info.lock().unwrap() = info.clone();
        let _ = state.metrics.aws.set(aws);
        if let Some(store) = &state.metrics.store {
            let saved = sqlx::query(
                "INSERT INTO hosts (host, info, updated_at) VALUES (?, ?, ?)
                 ON CONFLICT(host) DO UPDATE SET info = excluded.info, updated_at = excluded.updated_at",
            )
            .bind(&info.host)
            .bind(serde_json::to_string(&info).unwrap_or_default())
            .bind(now())
            .execute(store)
            .await;
            if let Err(e) = saved {
                tracing::warn!(error = %e, "saving host info failed");
            }
        }
        tokio::spawn(aws_loop(state.clone()));

        let vols = volumes(&state.config.pic_dir);
        let (ticks, vcpus) = (clock_ticks(), info.vcpus);
        let mut prev = Previous::default();
        let mut minute = Minute::default();
        let mut tick = tokio::time::interval(INTERVAL);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            let requests = std::mem::take(&mut *state.metrics.requests.lock().unwrap());
            for &us in &requests.latencies_us {
                keep_latency(&mut minute.latencies_us, &mut minute.seen, us);
            }
            let (online, sockets) = state.hub.online();
            let db_bytes = db_file_bytes(&state.config.database_url);
            let extra = [
                ("online", online as f64),
                ("sockets", sockets as f64),
                ("db_bytes", db_bytes as f64),
            ];
            let Some(v) = sample(&mut prev, &vols, requests, &extra, ticks, vcpus) else {
                continue;
            };
            let t = now();
            if minute.minute != t / 60 {
                if let Some(point) = minute.finish() {
                    state.metrics.save_minute(&point).await;
                }
                minute.minute = t / 60;
            }
            minute.add(&v);
            let mut live = state.metrics.live.lock().unwrap();
            let span = INTERVAL.as_secs() as i64;
            live.push_back(Point {
                t: t - span,
                s: span,
                v: v.into_iter().map(|(k, x)| (k, [x, x, x])).collect(),
            });
            while live.len() > 360 {
                live.pop_front();
            }
        }
    });
}

fn host_info(state: &SharedState, instance: Option<crate::aws::Instance>) -> HostInfo {
    let host = match &instance {
        Some(i) if !i.id.is_empty() => i.id.clone(),
        _ => {
            let name = read("/proc/sys/kernel/hostname").trim().to_owned();
            if name.is_empty() {
                "local".into()
            } else {
                name
            }
        }
    };
    HostInfo {
        host,
        instance,
        vcpus: cpu_count(),
        mem_total: meminfo(&read("/proc/meminfo"), "MemTotal:").unwrap_or(0),
        app_mem_limit: cgroup_memory_limit(),
        disks: volumes(&state.config.pic_dir)
            .into_iter()
            .filter_map(|v| Some((v.name, crate::sysinfo::disk_space(&v.path)?.0)))
            .collect(),
    }
}

fn db_file_bytes(database_url: &str) -> u64 {
    let path = database_url
        .trim_start_matches("sqlite://")
        .trim_start_matches("sqlite:")
        .split('?')
        .next()
        .unwrap_or("");
    ["", "-wal"]
        .iter()
        .filter_map(|s| std::fs::metadata(format!("{path}{s}")).ok())
        .map(|m| m.len())
        .sum()
}

impl Metrics {
    async fn save_minute(&self, point: &Point) {
        let Some(store) = &self.store else { return };
        let minute = point.t / 60;
        let saved = sqlx::query(
            "INSERT INTO minutes (host, slot, minute, data) VALUES (?, ?, ?, ?)
             ON CONFLICT(host, slot) DO UPDATE SET minute = excluded.minute, data = excluded.data",
        )
        .bind(self.host())
        .bind(minute.rem_euclid(self.slots()))
        .bind(minute)
        .bind(serde_json::to_string(&point.v).unwrap_or_default())
        .execute(store)
        .await;
        if let Err(e) = saved {
            tracing::warn!(error = %e, "saving a metrics minute failed");
        }
    }

    /// Stored minutes since `since`, per host, oldest first.
    async fn minutes(&self, since: i64) -> AppResult<BTreeMap<String, Vec<Point>>> {
        let mut out: BTreeMap<String, Vec<Point>> = BTreeMap::new();
        let Some(store) = &self.store else {
            return Ok(out);
        };
        let rows: Vec<(String, i64, String)> = sqlx::query_as(
            "SELECT host, minute, data FROM minutes WHERE minute >= ? ORDER BY minute",
        )
        .bind(since / 60)
        .fetch_all(store)
        .await?;
        for (host, minute, data) in rows {
            if let Ok(v) = serde_json::from_str(&data) {
                out.entry(host).or_default().push(Point {
                    t: minute * 60,
                    s: 60,
                    v,
                });
            }
        }
        Ok(out)
    }

    async fn cached(&self, key: &str) -> Option<(Value, i64)> {
        let row: (String, i64) = sqlx::query_as("SELECT value, at FROM cache WHERE key = ?")
            .bind(key)
            .fetch_optional(self.store.as_ref()?)
            .await
            .ok()??;
        Some((serde_json::from_str(&row.0).ok()?, row.1))
    }

    async fn cache(&self, key: &str, value: &Value) {
        let Some(store) = &self.store else { return };
        let _ = sqlx::query(
            "INSERT INTO cache (key, value, at) VALUES (?, ?, ?)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, at = excluded.at",
        )
        .bind(key)
        .bind(value.to_string())
        .bind(now())
        .execute(store)
        .await;
    }
}

/// CPU credits every five minutes, the bill twice a day (only on EC2).
async fn aws_loop(state: SharedState) {
    let m = &state.metrics;
    let Some(Some(aws)) = m.aws.get() else { return };
    let mut tick = tokio::time::interval(CREDITS_EVERY);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // After a failed bill, try again in an hour (each call costs $0.01).
    let mut billing_retry_at = 0;
    // Bucket sizes change once a day; check every six hours (an hour after a failure).
    let mut s3_next = 0;
    loop {
        tick.tick().await;
        // Only burstable instances (t2/t3/t4g) have credits.
        if aws.instance.instance_type.starts_with('t') {
            let end = now();
            let start = end - m.retention_hours * 3600;
            let balance = aws
                .ec2_metric("CPUCreditBalance", "Average", start, end)
                .await;
            let charged = aws
                .ec2_metric("CPUSurplusCreditsCharged", "Sum", start, end)
                .await;
            match (balance, charged) {
                (Ok(balance), Ok(charged)) => {
                    let charged: HashMap<i64, f64> = charged.into_iter().collect();
                    let points: Vec<(i64, f64, f64)> = balance
                        .into_iter()
                        .map(|(t, b)| (t, b, charged.get(&t).copied().unwrap_or(0.0)))
                        .collect();
                    m.aws_worked(CREDITS_READ);
                    let mut credits = m.credits.lock().unwrap();
                    if credits.is_none() {
                        tracing::info!(points = points.len(), "CPU credits read from CloudWatch");
                    }
                    *credits = Some(Credits {
                        points,
                        updated_at: end,
                    });
                }
                (Err(e), _) | (_, Err(e)) => {
                    m.aws_failed(CREDITS_READ, &e);
                }
            }
        }
        if now() >= s3_next {
            match s3_usage(aws).await {
                Ok(stored) => {
                    m.aws_worked(S3_READ);
                    *m.s3.lock().unwrap() = Some(stored);
                    s3_next = now() + 6 * 3600;
                }
                Err(e) => {
                    m.aws_failed(S3_READ, &e);
                    s3_next = now() + 3600;
                }
            }
        }
        // The bill is production's (App=fade). A non-production copy
        // (staging) doesn't read it: its role has no Cost Explorer access,
        // by design (infra/staging/main.tf).
        let production = state.config.environment.is_none();
        let fresh = m
            .cached("billing")
            .await
            .is_some_and(|(_, at)| now() - at < BILLING_EVERY_SECS);
        if production && !fresh && now() >= billing_retry_at {
            let t = now();
            match aws
                .costs(
                    "fade",
                    &crate::aws::previous_month_start(t),
                    &crate::aws::ymd(t + 86_400),
                )
                .await
            {
                Ok(months) => {
                    m.cache("billing", &json!({ "months": months, "fetched_at": t }))
                        .await;
                    m.aws_worked(BILLING_READ);
                    tracing::info!("billing fetched from Cost Explorer");
                }
                Err(e) => {
                    billing_retry_at = t + 3600;
                    m.aws_failed(BILLING_READ, &e);
                }
            }
        }
    }
}

const CREDITS_READ: &str = "reading CPU credits from CloudWatch";
const BILLING_READ: &str = "reading the bill from Cost Explorer";
const S3_READ: &str = "reading bucket sizes from CloudWatch";

/// Every app bucket's size in each storage class it uses (backups move to
/// Glacier Instant Retrieval after 30 days; infra/backups.tf).
async fn s3_usage(aws: &Aws) -> anyhow::Result<Vec<S3Stored>> {
    let mut stored = Vec::new();
    for bucket in aws.instance.s3_buckets() {
        for (class, _) in S3_CLASSES {
            if let Some(bytes) = aws.bucket_bytes(&bucket, class).await? {
                stored.push(S3Stored {
                    bucket: bucket.clone(),
                    class,
                    bytes,
                });
            }
        }
    }
    Ok(stored)
}

impl Metrics {
    /// Notes a failed AWS read for the page. Logged as a warning the first
    /// time (or when the error changes), then quietly while it repeats.
    /// Each read is tracked on its own. Returns whether it warned.
    fn aws_failed(&self, what: &str, e: &anyhow::Error) -> bool {
        let text = e.to_string();
        let before = self
            .aws_problems
            .lock()
            .unwrap()
            .insert(what.to_owned(), text.clone());
        let repeat = before.as_deref() == Some(text.as_str());
        if repeat {
            tracing::debug!(error = %e, "{what} failed again");
        } else {
            tracing::warn!(error = %e, "{what} failed");
        }
        !repeat
    }

    /// A read worked: clear its problem, and say so if it had been failing.
    fn aws_worked(&self, what: &str) {
        if self.aws_problems.lock().unwrap().remove(what).is_some() {
            tracing::info!("{what} works again");
        }
    }
}

// ---------- reading it back ----------

/// One point covering several: from the first's start to the last's end;
/// min of mins, max of maxes, and the average weighted by the time each
/// covers (so a 10-second reading counts a sixth of a minute).
fn merge(points: &[Point]) -> Point {
    let mut acc: BTreeMap<String, (f64, f64, f64, f64)> = BTreeMap::new();
    for p in points {
        for (k, [lo, avg, hi]) in &p.v {
            let e = acc
                .entry(k.clone())
                .or_insert((f64::INFINITY, 0.0, f64::NEG_INFINITY, 0.0));
            e.0 = e.0.min(*lo);
            e.1 += avg * p.s as f64;
            e.2 = e.2.max(*hi);
            e.3 += p.s as f64;
        }
    }
    let (first, last) = (&points[0], &points[points.len() - 1]);
    Point {
        t: first.t,
        s: last.t + last.s - first.t,
        v: acc
            .into_iter()
            .map(|(k, (lo, sum, hi, secs))| (k, [lo, sum / secs.max(1.0), hi]))
            .collect(),
    }
}

/// Merges consecutive points so there are at most `max`.
fn downsample(points: &[Point], max: usize) -> Vec<Point> {
    if points.len() <= max {
        return points.to_vec();
    }
    let per = points.len().div_ceil(max);
    points.chunks(per).map(merge).collect()
}

/// A host's series for the range starting at `since`: stored minutes, and
/// for this server its live 10-second readings where the minutes end.
///
/// For the last hour, the readings are shown as they are. They only go back
/// to the last restart, so before that the stored minutes fill in (a deploy
/// used to leave the hour mostly empty). For longer ranges, the readings
/// since the last stored minute become one point for the minute in progress.
fn series(minutes: &[Point], live: &[Point], since: i64, hours: i64) -> Vec<Point> {
    let stored: Vec<Point> = minutes
        .iter()
        .filter(|p| p.t + p.s > since)
        .cloned()
        .collect();
    if hours == 1 {
        let live: Vec<&Point> = live.iter().filter(|p| p.t + p.s > since).collect();
        let live_from = live.first().map_or(i64::MAX, |p| p.t);
        let mut out: Vec<Point> = stored
            .into_iter()
            .filter(|p| p.t + p.s <= live_from)
            .collect();
        out.extend(live.into_iter().cloned());
        return out;
    }
    let stored_to = stored.last().map_or(i64::MIN, |p| p.t + p.s);
    let recent: Vec<Point> = live
        .iter()
        .filter(|p| p.t >= stored_to && p.t + p.s > since)
        .cloned()
        .collect();
    let mut out = stored;
    if !recent.is_empty() {
        out.push(merge(&recent));
    }
    downsample(&out, MAX_POINTS)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    Watch,
    Red,
}

/// Is this host all right? Looks at the last ten minutes of readings.
/// Returns the worst level and a plain reason for anything that isn't OK.
fn assess(recent: &[Point], info: &HostInfo, credits: Option<&Credits>) -> (Level, Vec<String>) {
    fn flag(
        reasons: &mut Vec<(Level, String)>,
        x: Option<f64>,
        watch: f64,
        red: f64,
        text: &dyn Fn(f64) -> String,
    ) {
        match x {
            Some(x) if x >= red => reasons.push((Level::Red, text(x))),
            Some(x) if x >= watch => reasons.push((Level::Watch, text(x))),
            _ => {}
        }
    }
    let mut reasons: Vec<(Level, String)> = Vec::new();
    let r = &mut reasons;
    let avg = |k: &str| -> Option<f64> {
        let xs: Vec<f64> = recent.iter().filter_map(|p| Some(p.v.get(k)?[1])).collect();
        (!xs.is_empty()).then(|| xs.iter().sum::<f64>() / xs.len() as f64)
    };
    let latest = |k: &str| recent.iter().rev().find_map(|p| Some(p.v.get(k)?[1]));

    flag(r, avg("mem"), 80.0, 90.0, &|x| {
        format!("Memory {x:.0}% used")
    });
    for name in info.disks.keys() {
        flag(r, latest(&format!("disk_{name}")), 80.0, 90.0, &|x| {
            format!("The {name} disk is {x:.0}% full")
        });
    }
    if let (Some(limit), Some(rss)) = (info.app_mem_limit, avg("app_mem")) {
        flag(r, Some(100.0 * rss / limit as f64), 75.0, 90.0, &|x| {
            format!("The server is using {x:.0}% of its memory limit")
        });
    }
    flag(r, avg("steal"), 10.0, 25.0, &|x| {
        format!("AWS is holding back {x:.0}% of the CPU (out of credits or a busy host)")
    });
    match credits.and_then(|c| c.points.last()) {
        // Burstable: what matters is the credit balance, not CPU %.
        Some(&(at, balance, _)) => {
            // A low balance alone is a warning, not an alarm: a new or
            // replaced instance starts near zero and builds up while idle.
            // It's red only when it's nearly out and the CPU is held at the
            // baseline, which is when people feel it.
            let full = credit_max(info);
            let baseline = size_of(info).map_or(5.0, |s| s.baseline_pct);
            let hour_ago = credits
                .and_then(|c| c.points.iter().rev().find(|p| p.0 <= at - 3600))
                .map(|p| p.1);
            let rising = hour_ago.is_some_and(|before| balance > before + 1.0);
            if balance < full / 10.0 && avg("cpu").is_some_and(|cpu| cpu >= baseline * 0.9) {
                r.push((
                    Level::Red,
                    format!("Out of CPU credits ({balance:.0} left): the CPU is held to its {baseline:.0}% baseline, so the server is slow"),
                ));
            } else if balance < full / 3.0 {
                r.push((
                    Level::Watch,
                    if rising {
                        format!("CPU credits are building up ({balance:.0} of {full:.0}), as after a restart")
                    } else {
                        format!("CPU credits are low ({balance:.0} left); at zero the server slows to its baseline (or, in unlimited mode, pays for extra CPU)")
                    },
                ));
            }
            let day_ago = now() - 86_400;
            let charged: f64 = credits
                .map(|c| {
                    c.points
                        .iter()
                        .filter(|p| p.0 >= day_ago)
                        .map(|p| p.2)
                        .sum()
                })
                .unwrap_or(0.0);
            if charged > 0.0 {
                r.push((
                    Level::Watch,
                    format!("Paid for {charged:.0} extra CPU credits in the last day"),
                ));
            }
        }
        None => flag(r, avg("cpu"), 70.0, 90.0, &|x| format!("CPU {x:.0}% busy")),
    }
    flag(r, avg("p95"), 500.0, 2000.0, &|x| {
        format!("Slow responses: 95% take under {x:.0} ms")
    });
    // "errors" is a per-minute rate; times the minutes each point covers.
    let errors: f64 = recent
        .iter()
        .filter_map(|p| Some(p.v.get("errors")?[1] * p.s as f64 / 60.0))
        .sum();
    flag(r, Some(errors), 1.0, 10.0, &|x| {
        format!("{x:.0} server errors in the last 10 minutes")
    });

    reasons.sort_by_key(|r| std::cmp::Reverse(r.0));
    let level = reasons.first().map_or(Level::Ok, |r| r.0);
    (level, reasons.into_iter().map(|r| r.1).collect())
}

// ---------- cost ----------

/// On-demand prices in us-east-1 (USD), checked October 2026.
const HOURS_PER_MONTH: f64 = 730.0;
const GP3_PER_GB_MONTH: f64 = 0.08;
/// S3 storage classes the app uses, as CloudWatch names them, and their price per GB-month.
const S3_CLASSES: [(&str, f64); 2] = [
    ("StandardStorage", 0.023),
    ("GlacierInstantRetrievalStorage", 0.004),
];
const PUBLIC_IPV4_PER_HOUR: f64 = 0.005;
/// Burstable instances in unlimited mode pay this per vCPU-hour of surplus
/// credits (one credit is one vCPU-minute). t4g: $0.04; t2/t3: $0.05.
fn surplus_per_credit(instance_type: &str) -> f64 {
    if instance_type.starts_with("t4g") {
        0.04 / 60.0
    } else {
        0.05 / 60.0
    }
}

/// An instance size: price per hour, and for burstable ones the CPU it may
/// use for free (baseline, % of each vCPU) and its vCPUs. It earns
/// vcpus x baseline x 60 credits an hour and banks at most a day's worth.
struct Size {
    name: &'static str,
    per_hour: f64,
    baseline_pct: f64,
    vcpus: f64,
}

const SIZES: &[Size] = &[
    Size {
        name: "t4g.nano",
        per_hour: 0.0042,
        baseline_pct: 5.0,
        vcpus: 2.0,
    },
    Size {
        name: "t4g.micro",
        per_hour: 0.0084,
        baseline_pct: 10.0,
        vcpus: 2.0,
    },
    Size {
        name: "t4g.small",
        per_hour: 0.0168,
        baseline_pct: 20.0,
        vcpus: 2.0,
    },
    Size {
        name: "t4g.medium",
        per_hour: 0.0336,
        baseline_pct: 20.0,
        vcpus: 2.0,
    },
    Size {
        name: "t4g.large",
        per_hour: 0.0672,
        baseline_pct: 30.0,
        vcpus: 2.0,
    },
    Size {
        name: "t4g.xlarge",
        per_hour: 0.1344,
        baseline_pct: 40.0,
        vcpus: 4.0,
    },
];

fn size_of(info: &HostInfo) -> Option<&'static Size> {
    let kind = info.instance.as_ref()?.instance_type.as_str();
    SIZES.iter().find(|s| s.name == kind)
}

/// The most credits this size can bank (144 for a t4g.nano).
fn credit_max(info: &HostInfo) -> f64 {
    size_of(info).map_or(144.0, |s| s.vcpus * s.baseline_pct / 100.0 * 60.0 * 24.0)
}

/// A month at today's rate: the instance, its disks, its public address, what
/// the S3 buckets hold (backups and releases), and any extra CPU paid for in
/// the last day. EBS snapshots are a few cents more; the billed figure has
/// everything.
fn estimate(info: &HostInfo, credits: Option<&Credits>, s3: Option<&[S3Stored]>) -> Value {
    let Some(kind) = info.instance.as_ref().map(|i| i.instance_type.as_str()) else {
        return Value::Null;
    };
    let size = size_of(info);
    let price = size.map(|s| s.per_hour);
    let next = SIZES
        .iter()
        .position(|s| s.name == kind)
        .and_then(|i| SIZES.get(i + 1));
    // A file system reports a little less than its volume; volumes come in whole GiB.
    let disk_gb: f64 = info
        .disks
        .values()
        .map(|b| (*b as f64 / 1024f64.powi(3)).ceil())
        .sum();
    let day_ago = now() - 86_400;
    let charged_day: f64 = credits
        .map(|c| {
            c.points
                .iter()
                .filter(|p| p.0 >= day_ago)
                .map(|p| p.2)
                .sum()
        })
        .unwrap_or(0.0);
    let gib = 1024f64.powi(3);
    let s3_lines: Vec<Value> = s3
        .unwrap_or_default()
        .iter()
        .map(|st| {
            let per_gb = S3_CLASSES.iter().find(|c| c.0 == st.class).map_or(0.0, |c| c.1);
            json!({ "bucket": st.bucket, "class": st.class, "gb": st.bytes / gib, "usd": st.bytes / gib * per_gb })
        })
        .collect();
    let s3_usd = s3.map(|_| {
        s3_lines
            .iter()
            .filter_map(|l| l["usd"].as_f64())
            .sum::<f64>()
    });
    let lines = [
        ("Server", price.map(|p| p * HOURS_PER_MONTH)),
        ("Disks", Some(disk_gb * GP3_PER_GB_MONTH)),
        (
            "Public address",
            Some(PUBLIC_IPV4_PER_HOUR * HOURS_PER_MONTH),
        ),
        ("Storage (S3)", s3_usd),
        (
            "Extra CPU",
            Some(charged_day * 30.0 * surplus_per_credit(kind)),
        ),
    ];
    json!({
        "instance_type": kind,
        "lines": lines.iter().map(|(name, usd)| json!({ "name": name, "usd": usd })).collect::<Vec<_>>(),
        "total": lines.iter().map(|l| l.1.unwrap_or(0.0)).sum::<f64>(),
        "disk_gb": disk_gb,
        "s3": s3.map(|_| s3_lines),
        "next": next.map(|n| json!({
            "instance_type": n.name,
            "usd": n.per_hour * HOURS_PER_MONTH,
            "cpu_baseline_pct": n.baseline_pct,
        })),
        "cpu_baseline_pct": size.map(|s| s.baseline_pct),
        "credit_max": size.map(|_| credit_max(info)),
    })
}

// ---------- the endpoint ----------

#[derive(Deserialize)]
pub struct RangeQuery {
    /// Hours to show: 1 (10-second readings) up to the retention window.
    hours: Option<i64>,
}

/// `GET /api/admin/metrics?hours=24`
pub async fn get(
    State(state): State<SharedState>,
    AuthUser(me): AuthUser,
    Query(q): Query<RangeQuery>,
) -> AppResult<Json<Value>> {
    // PowerUsers and Admins; cost (estimate, bill, AWS problems) is Admins' only.
    let role = crate::roles::require(&state, &me, crate::roles::Role::Power).await?;
    let admin = role == crate::roles::Role::Admin;
    let m = &state.metrics;
    let hours = q.hours.unwrap_or(24).clamp(1, m.retention_hours);
    let t = now();
    let since = t - hours * 3600;
    let local = m.info.lock().unwrap().clone();
    let live: Vec<Point> = m.live.lock().unwrap().iter().cloned().collect();
    let credits = m.credits.lock().unwrap().clone();
    let s3 = m.s3.lock().unwrap().clone();

    let mut stored = m.minutes(since.min(t - 15 * 60)).await?;
    let mut infos: BTreeMap<String, HostInfo> = BTreeMap::new();
    if let Some(store) = &m.store {
        let rows: Vec<(String, String)> = sqlx::query_as("SELECT host, info FROM hosts")
            .fetch_all(store)
            .await?;
        for (host, info) in rows {
            if let Ok(info) = serde_json::from_str(&info) {
                infos.insert(host, info);
            }
        }
    }
    if !local.host.is_empty() {
        infos.insert(local.host.clone(), local.clone());
        stored.entry(local.host.clone()).or_default();
    }

    let mut hosts = Vec::new();
    for (host, minutes) in &stored {
        let is_local = *host == local.host;
        let info = infos.get(host).cloned().unwrap_or_default();
        let ten_min_ago = t - 10 * 60;
        let recent: Vec<Point> = if is_local {
            live.iter()
                .filter(|p| p.t >= ten_min_ago)
                .cloned()
                .collect()
        } else {
            minutes
                .iter()
                .filter(|p| p.t >= ten_min_ago)
                .cloned()
                .collect()
        };
        // Quiet for 15 minutes: a machine that's gone, not one to show.
        if recent.is_empty() && !is_local {
            continue;
        }
        let host_credits = if is_local { credits.as_ref() } else { None };
        let (level, reasons) = assess(&recent, &info, host_credits);
        let series = series(minutes, if is_local { &live } else { &[] }, since, hours);
        hosts.push(json!({
            "host": host,
            "info": info,
            "status": level,
            "reasons": reasons,
            "latest": recent.last().map(|p| &p.v),
            "series": series,
            "credits": host_credits,
            "estimate": if admin { estimate(&info, host_credits, if is_local { s3.as_deref() } else { None }) } else { Value::Null },
        }));
    }

    let billing = if admin {
        m.cached("billing").await.map(|(v, _)| v)
    } else {
        None
    };
    Ok(Json(json!({
        "generated_at": t,
        "hours": hours,
        "retention_hours": m.retention_hours,
        "interval_secs": if hours == 1 { INTERVAL.as_secs() } else { 60 },
        "on_aws": matches!(m.aws.get(), Some(Some(_))),
        "aws_problems": if admin { json!(m.aws_problems.lock().unwrap().clone()) } else { json!({}) },
        "cost_visible": admin,
        // Only production reads the bill (see aws_loop).
        "billing_read": state.config.environment.is_none(),
        "hosts": hosts,
        "billing": billing,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_proc_files() {
        let stat = "cpu  100 5 50 800 20 3 2 10 7 0\ncpu0 1 2 3 4 5 6 7 8 9 0\n";
        let c = parse_cpu(stat).unwrap();
        assert_eq!((c.total, c.idle, c.iowait, c.steal), (990, 800, 20, 10));

        // The command name can contain spaces and parentheses.
        let pstat = "4242 (fade (srv) x) S 1 4242 4242 0 -1 4194560 1200 0 0 0 731 268 0 0 20 0 9 0 5 1000 300";
        assert_eq!(parse_proc_ticks(pstat), Some(731 + 268));

        let dev = "Inter-|   Receive  ...\n face |bytes packets ...\n    lo: 999 9 0 0 0 0 0 0 999 9 0 0 0 0 0 0\n  ens5: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n  eth1: 5 1 0 0 0 0 0 0 7 1 0 0 0 0 0 0\n";
        assert_eq!(parse_net(dev), Some((1005, 2007)));

        let disks = " 259       0 nvme0n1 500 0 4000 10 900 0 7200 50 0 60 60\n 259       1 nvme0n1p1 400 0 3000 9 800 0 6400 40 0 50 49\n";
        assert_eq!(parse_diskstats(disks, 259, 1), Some([400, 800, 3000, 6400]));
        assert_eq!(parse_diskstats(disks, 8, 0), None);

        let mem = "MemTotal:  421888 kB\nMemAvailable:  215040 kB\n";
        assert_eq!(meminfo(mem, "MemTotal:"), Some(421_888 * 1024));
    }

    #[test]
    fn percentiles_are_nearest_rank() {
        let xs: Vec<u32> = (1..=100).collect();
        assert_eq!(percentile(&xs, 50.0), Some(50.0));
        assert_eq!(percentile(&xs, 95.0), Some(95.0));
        assert_eq!(percentile(&xs, 99.0), Some(99.0));
        assert_eq!(percentile(&[7], 99.0), Some(7.0));
        assert_eq!(percentile(&[], 50.0), None);
    }

    #[test]
    fn latency_sample_stays_bounded() {
        let (mut list, mut seen) = (Vec::new(), 0);
        for i in 0..(LATENCY_CAP as u32 * 3) {
            keep_latency(&mut list, &mut seen, i);
        }
        assert_eq!(list.len(), LATENCY_CAP);
        assert_eq!(seen, LATENCY_CAP as u64 * 3);
        // A uniform sample of 0..60k has a median near 30k.
        list.sort_unstable();
        let median = percentile(&list, 50.0).unwrap();
        assert!((median - 30_000.0).abs() < 2_000.0, "{median}");
    }

    #[test]
    fn a_minute_keeps_its_extremes() {
        let mut m = Minute {
            minute: 100,
            ..Default::default()
        };
        for cpu in [10.0, 90.0, 20.0, 20.0, 10.0, 30.0] {
            m.add(&BTreeMap::from([("cpu".to_owned(), cpu)]));
        }
        for us in [1_000, 2_000, 3_000, 40_000] {
            keep_latency(&mut m.latencies_us, &mut m.seen, us);
        }
        let p = m.finish().unwrap();
        assert_eq!(p.t, 6000);
        assert_eq!(p.v["cpu"], [10.0, 30.0, 90.0]); // the 90% spike survives
        assert_eq!(p.v["p50"], [2.0, 2.0, 2.0]);
        assert_eq!(p.v["p99"], [40.0, 40.0, 40.0]);
        assert!(m.finish().is_none(), "nothing left once finished");
    }

    /// A 10-second reading starting at `t`.
    fn point(t: i64, pairs: &[(&str, f64)]) -> Point {
        Point {
            t,
            s: 10,
            v: pairs
                .iter()
                .map(|(k, x)| (k.to_string(), [*x, *x, *x]))
                .collect(),
        }
    }

    fn minute(m: i64, cpu: f64) -> Point {
        Point {
            t: m * 60,
            s: 60,
            v: BTreeMap::from([("cpu".to_owned(), [cpu, cpu, cpu])]),
        }
    }

    #[test]
    fn the_last_hour_fills_in_from_before_a_restart() {
        let now_min = 100_000;
        let since = (now_min - 60) * 60;
        // Stored minutes for the whole hour; the server restarted 10 minutes ago,
        // so its 10-second readings only cover the last 10 minutes.
        let minutes: Vec<Point> = (now_min - 60..now_min).map(|m| minute(m, 5.0)).collect();
        let restart = (now_min - 10) * 60;
        let live: Vec<Point> = (0..60)
            .map(|i| point(restart + i * 10, &[("cpu", 9.0)]))
            .collect();
        let s = series(&minutes, &live, since, 1);
        assert_eq!(
            s.first().unwrap().t,
            since,
            "the hour starts at its start, not at the restart"
        );
        let stored = s.iter().filter(|p| p.s == 60).count();
        assert_eq!(
            stored, 50,
            "minutes before the readings, none overlapping them"
        );
        assert!(s.iter().filter(|p| p.s == 60).all(|p| p.t + 60 <= restart));
        assert_eq!(s.len(), 50 + 60);
        assert!(
            s.windows(2).all(|w| w[0].t + w[0].s <= w[1].t),
            "in order, no overlaps"
        );
        // Without a restart, the readings cover the hour on their own.
        let full: Vec<Point> = (0..360)
            .map(|i| point(since + i * 10, &[("cpu", 1.0)]))
            .collect();
        assert!(series(&minutes, &full, since, 1).iter().all(|p| p.s == 10));
    }

    #[test]
    fn longer_ranges_add_the_minute_in_progress_weighted() {
        let minutes: Vec<Point> = (0..10).map(|m| minute(m, 10.0)).collect();
        // 30 seconds into minute 10: three readings, at 40, 40, and 100.
        let live = [
            point(600, &[("cpu", 40.0)]),
            point(610, &[("cpu", 40.0)]),
            point(620, &[("cpu", 100.0)]),
        ];
        let s = series(&minutes, &live, 0, 24);
        assert_eq!(s.len(), 11);
        let last = s.last().unwrap();
        assert_eq!((last.t, last.s), (600, 30));
        assert_eq!(last.v["cpu"], [40.0, 60.0, 100.0]);
        // Readings already inside a stored minute aren't counted twice.
        let s = series(&minutes, &[point(590, &[("cpu", 99.0)])], 0, 24);
        assert_eq!(s.len(), 10);
    }

    #[test]
    fn merging_weights_by_time_covered() {
        // A minute at 10% and a 10-second reading at 70%: (10×60 + 70×10) / 70.
        let m = merge(&[minute(0, 10.0), point(60, &[("cpu", 70.0)])]);
        assert_eq!((m.t, m.s), (0, 70));
        assert!((m.v["cpu"][1] - 1300.0 / 70.0).abs() < 1e-9);
        assert_eq!((m.v["cpu"][0], m.v["cpu"][2]), (10.0, 70.0));
    }

    #[test]
    fn downsampling_keeps_peaks() {
        let points: Vec<Point> = (0..1000)
            .map(|i| point(i * 60, &[("cpu", if i == 500 { 99.0 } else { 5.0 })]))
            .collect();
        let small = downsample(&points, 100);
        assert_eq!(small.len(), 100);
        assert!(
            small.iter().any(|p| p.v["cpu"][2] == 99.0),
            "the spike is still the max"
        );
        assert_eq!(small[0].t, 0);
        assert_eq!(downsample(&points[..10], 100).len(), 10);
    }

    #[test]
    fn assessing_a_host() {
        let info = HostInfo {
            host: "i-1".into(),
            app_mem_limit: Some(400 * 1024 * 1024),
            disks: BTreeMap::from([("data".to_owned(), 1 << 30)]),
            ..Default::default()
        };
        let calm: Vec<Point> = (0..60)
            .map(|i| {
                point(
                    i * 10,
                    &[
                        ("mem", 40.0),
                        ("cpu", 3.0),
                        ("disk_data", 20.0),
                        ("app_mem", 30e6),
                        ("p95", 4.0),
                        ("errors", 0.0),
                    ],
                )
            })
            .collect();
        assert_eq!(assess(&calm, &info, None), (Level::Ok, vec![]));

        let full: Vec<Point> = (0..60)
            .map(|i| point(i * 10, &[("mem", 85.0), ("disk_data", 95.0)]))
            .collect();
        let (level, reasons) = assess(&full, &info, None);
        assert_eq!(level, Level::Red);
        assert_eq!(reasons[0], "The data disk is 95% full"); // red reasons first
        assert!(reasons.contains(&"Memory 85% used".to_owned()));

        // One 500 per minute over ten minutes of 10-second readings: 10 errors.
        let erroring: Vec<Point> = (0..60).map(|i| point(i * 10, &[("errors", 1.0)])).collect();
        assert_eq!(
            assess(&erroring, &info, None).1,
            vec!["10 server errors in the last 10 minutes"]
        );

        // Burstable: credits decide, not CPU %.
        let busy: Vec<Point> = (0..60).map(|i| point(i * 10, &[("cpu", 95.0)])).collect();
        assert_eq!(assess(&busy, &info, None).0, Level::Red);
        let plenty = Credits {
            points: vec![(now(), 140.0, 0.0)],
            updated_at: now(),
        };
        assert_eq!(assess(&busy, &info, Some(&plenty)).0, Level::Ok);
        let low = Credits {
            points: vec![(now(), 30.0, 0.0)],
            updated_at: now(),
        };
        assert_eq!(assess(&busy, &info, Some(&low)).0, Level::Watch);
        // Nearly out but idle (just booted): a warning that says it's filling.
        let filling = Credits {
            points: vec![(now() - 3600, 2.0, 0.0), (now(), 10.0, 0.0)],
            updated_at: now(),
        };
        assert_eq!(
            assess(&calm, &info, Some(&filling)),
            (
                Level::Watch,
                vec!["CPU credits are building up (10 of 144), as after a restart".to_owned()]
            )
        );
        // Nearly out and held at the baseline: that's slow for people, so red.
        let at_baseline: Vec<Point> = (0..60).map(|i| point(i * 10, &[("cpu", 5.0)])).collect();
        let (level, reasons) = assess(&at_baseline, &info, Some(&filling));
        assert_eq!(level, Level::Red);
        assert!(reasons[0].starts_with("Out of CPU credits"), "{reasons:?}");
        let paying = Credits {
            points: vec![(now() - 600, 0.0, 12.0), (now(), 0.0, 3.0)],
            updated_at: now(),
        };
        let (level, reasons) = assess(&calm, &info, Some(&paying));
        assert_eq!(level, Level::Watch);
        assert!(
            reasons.contains(&"Paid for 15 extra CPU credits in the last day".to_owned()),
            "{reasons:?}"
        );
    }

    #[test]
    fn estimating_the_bill() {
        let info = HostInfo {
            instance: Some(crate::aws::Instance {
                instance_type: "t4g.nano".into(),
                ..Default::default()
            }),
            // What the file systems report on the 8 GB and 1 GB volumes.
            disks: BTreeMap::from([
                ("system".to_owned(), 8_574_143_488),
                ("data".to_owned(), 1_020_702_720),
            ]),
            ..Default::default()
        };
        let e = estimate(&info, None, None);
        assert_eq!(e["disk_gb"], 9.0);
        assert!(e["s3"].is_null(), "unknown until CloudWatch answers");
        let total = e["total"].as_f64().unwrap();
        // 3.066 server + 0.72 disks + 3.65 address
        assert!((total - 7.436).abs() < 0.001, "{total}");
        assert_eq!(e["next"]["instance_type"], "t4g.micro");
        assert_eq!(e["cpu_baseline_pct"], 5.0);
        assert_eq!(e["credit_max"], 144.0);
        let paying = Credits {
            points: vec![(now(), 0.0, 60.0)],
            updated_at: now(),
        };
        let line = |e: &Value, name: &str| {
            e["lines"]
                .as_array()
                .unwrap()
                .iter()
                .find(|l| l["name"] == name)
                .unwrap()["usd"]
                .as_f64()
        };
        let extra = line(&estimate(&info, Some(&paying), None), "Extra CPU").unwrap();
        assert!(
            (extra - 1.2).abs() < 1e-9,
            "60 credits a day for 30 days at $0.04/60: {extra}"
        );
        assert!(
            estimate(&HostInfo::default(), None, None).is_null(),
            "no estimate off AWS"
        );

        // S3: 2 GiB in Standard and 10 GiB of older backups in Glacier IR.
        let gib = 1024f64.powi(3);
        let stored = [
            S3Stored {
                bucket: "fade-backups-1-us-east-1".into(),
                class: "StandardStorage",
                bytes: 2.0 * gib,
            },
            S3Stored {
                bucket: "fade-backups-1-us-east-1".into(),
                class: "GlacierInstantRetrievalStorage",
                bytes: 10.0 * gib,
            },
        ];
        let e = estimate(&info, None, Some(&stored));
        let s3 = line(&e, "Storage (S3)").unwrap();
        assert!((s3 - (2.0 * 0.023 + 10.0 * 0.004)).abs() < 1e-9, "{s3}");
        assert!((e["total"].as_f64().unwrap() - (7.436 + s3)).abs() < 0.001);
        assert_eq!(e["s3"][1]["gb"], 10.0);
        assert_eq!(
            line(&estimate(&info, None, Some(&[])), "Storage (S3)"),
            Some(0.0),
            "empty buckets cost nothing"
        );
    }

    #[tokio::test]
    async fn aws_failures_warn_once_each() {
        let m = Metrics::open(std::path::Path::new("/nonexistent/dir/metrics.db"), 1).await;
        let denied = anyhow::anyhow!("AccessDenied");
        assert!(m.aws_failed(CREDITS_READ, &denied));
        assert!(m.aws_failed(BILLING_READ, &denied));
        // The other read failing in between doesn't make this one new again.
        assert!(!m.aws_failed(CREDITS_READ, &denied));
        assert!(!m.aws_failed(BILLING_READ, &denied));
        assert!(
            m.aws_failed(CREDITS_READ, &anyhow::anyhow!("Throttling")),
            "a new error warns"
        );
        m.aws_worked(CREDITS_READ);
        assert_eq!(
            m.aws_problems.lock().unwrap().keys().collect::<Vec<_>>(),
            vec![BILLING_READ]
        );
        assert!(
            m.aws_failed(CREDITS_READ, &denied),
            "failing after working warns again"
        );
    }

    #[tokio::test]
    async fn the_store_is_a_fixed_ring() {
        let dir = std::env::temp_dir().join(format!("fade-metrics-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        let m = Metrics::open(&dir.join("metrics.db"), 1).await;
        m.info.lock().unwrap().host = "i-test".into();
        let start = now() / 60 * 60 - 3 * 3600;
        // Three hours of minutes into a one-hour ring.
        for i in 0..180 {
            m.save_minute(&point(start + i * 60, &[("cpu", i as f64)]))
                .await;
        }
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM minutes")
            .fetch_one(m.store.as_ref().unwrap())
            .await
            .unwrap();
        assert_eq!(
            rows, 60,
            "never more than one slot per minute of the window"
        );
        let got = m.minutes(start + 120 * 60).await.unwrap();
        let points = &got["i-test"];
        assert_eq!(points.len(), 60);
        assert_eq!(points[0].v["cpu"][1], 120.0);
        assert_eq!(points[59].v["cpu"][1], 179.0);
        // Older minutes were overwritten, not kept.
        assert!(m.minutes(start).await.unwrap()["i-test"].len() == 60);

        m.cache("billing", &json!({ "months": [] })).await;
        m.cache("billing", &json!({ "months": [1] })).await;
        assert_eq!(
            m.cached("billing").await.unwrap().0,
            json!({ "months": [1] })
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn samples_this_machine() {
        let dir = std::env::temp_dir();
        let vols = volumes(&dir);
        let mut prev = Previous::default();
        assert!(
            sample(&mut prev, &vols, Requests::default(), &[], 100.0, 1).is_none(),
            "the first reading only primes"
        );
        std::thread::sleep(Duration::from_millis(50));
        let reqs = Requests {
            count: 3,
            errors: 1,
            latencies_us: vec![1500, 2500, 9000],
            seen: 3,
        };
        let v = sample(
            &mut prev,
            &vols,
            reqs,
            &[("sockets", 2.0)],
            clock_ticks(),
            cpu_count(),
        )
        .unwrap();
        if cfg!(target_os = "linux") {
            for k in [
                "cpu",
                "mem",
                "mem_used",
                "app_mem",
                "app_threads",
                "app_files",
                "disk_data",
            ] {
                assert!(v.contains_key(k), "missing {k}: {v:?}");
            }
            assert!((0.0..=100.0).contains(&v["cpu"]));
        }
        assert_eq!(v["p50"], 2.5);
        assert_eq!(v["p99"], 9.0);
        assert_eq!(v["sockets"], 2.0);
        assert!(v["requests"] > 0.0 && v["errors"] > 0.0);
    }
}
