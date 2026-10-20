//! Memory, load, and disk figures for the admin panel, read from /proc and
//! statvfs. Linux only; elsewhere the fields are null.

use serde_json::{json, Value};

fn meminfo_kb(text: &str, key: &str) -> Option<u64> {
    text.lines()
        .find(|l| l.starts_with(key))?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()
}

#[cfg(unix)]
fn disk(path: &std::path::Path) -> Option<(u64, u64)> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let c = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `s` is a properly sized out-parameter.
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 {
        return None;
    }
    let block = s.f_frsize as u64;
    Some((s.f_blocks as u64 * block, s.f_bavail as u64 * block))
}

#[cfg(not(unix))]
fn disk(_: &std::path::Path) -> Option<(u64, u64)> {
    None
}

/// `data_dir` is any folder on the data volume (the pics folder works).
pub fn snapshot(data_dir: &std::path::Path) -> Value {
    let mem = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let load: Option<f64> = std::fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|l| l.split_whitespace().next()?.parse().ok());
    let (disk_total, disk_free) = disk(data_dir).unzip();
    json!({
        "mem_total_bytes": meminfo_kb(&mem, "MemTotal:").map(|k| k * 1024),
        "mem_available_bytes": meminfo_kb(&mem, "MemAvailable:").map(|k| k * 1024),
        "app_rss_bytes": meminfo_kb(&status, "VmRSS:").map(|k| k * 1024),
        "load_1m": load,
        "disk_total_bytes": disk_total,
        "disk_free_bytes": disk_free,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_proc_lines() {
        let text = "MemTotal:         421888 kB\nMemAvailable:     215040 kB\n";
        assert_eq!(meminfo_kb(text, "MemTotal:"), Some(421_888));
        assert_eq!(meminfo_kb(text, "MemAvailable:"), Some(215_040));
        assert_eq!(meminfo_kb(text, "Missing:"), None);
        let snap = snapshot(std::path::Path::new("."));
        assert!(snap.get("disk_free_bytes").is_some());
    }
}
