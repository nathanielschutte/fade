use std::{str::FromStr, time::Duration};

use serde::Serialize;
use sqlx::{
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
    FromRow, SqlitePool,
};

pub async fn connect(url: &str) -> anyhow::Result<SqlitePool> {
    let opts = SqliteConnectOptions::from_str(url)?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(5));
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(opts)
        .await?;
    // A rolled-back binary must start against a database a newer release already
    // migrated, so don't fail on migrations this build doesn't know. That's only
    // safe because migrations are additive (docs/RELEASING.md).
    let mut migrator = sqlx::migrate!("./migrations");
    migrator.set_ignore_missing(true);
    migrator.run(&pool).await?;
    Ok(pool)
}

/// `pics` next to the SQLite file in a `sqlite://path?opts` URL.
pub fn default_pic_dir(database_url: &str) -> std::path::PathBuf {
    let path = database_url
        .trim_start_matches("sqlite://")
        .trim_start_matches("sqlite:")
        .split('?')
        .next()
        .unwrap_or("");
    std::path::Path::new(path)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(std::path::Path::new("."))
        .join("pics")
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct UserPublic {
    pub id: i64,
    pub username: String,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct Message {
    pub id: i64,
    pub sender_id: i64,
    pub recipient_id: i64,
    /// "text" or "snap"
    pub kind: String,
    /// Texts only: base64 of IV || AES-GCM ciphertext. Only the two friends can decrypt it.
    pub ciphertext: Option<String>,
    /// Encryption scheme of `ciphertext` (or of the snap bytes). See version::MESSAGE_FORMATS.
    pub format: i64,
    /// For snaps: "pending", "opened", or "expired"
    pub snap_state: Option<String>,
    pub created_at: i64,
    pub read_at: Option<i64>,
}

pub const MESSAGE_COLS: &str =
    "id, sender_id, recipient_id, kind, ciphertext, format, snap_state, created_at, read_at";

pub async fn get_message(db: &SqlitePool, id: i64) -> sqlx::Result<Option<Message>> {
    sqlx::query_as::<_, Message>(&format!("SELECT {MESSAGE_COLS} FROM messages WHERE id = ?"))
        .bind(id)
        .fetch_optional(db)
        .await
}

/// Standard base64 with padding, non-empty and at most `max_len` characters.
/// The server can't check what's inside encrypted fields, only their shape.
pub fn is_base64(s: &str, max_len: usize) -> bool {
    !s.is_empty()
        && s.len() <= max_len
        && s.len().is_multiple_of(4)
        && s.trim_end_matches('=').len() + 2 >= s.len()
        && s.trim_end_matches('=')
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
}

/// Friendships are stored once with the lower id first.
pub fn pair(a: i64, b: i64) -> (i64, i64) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

pub async fn are_friends(db: &SqlitePool, a: i64, b: i64) -> sqlx::Result<bool> {
    let (lo, hi) = pair(a, b);
    let row: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM friendships WHERE user_lo = ? AND user_hi = ? AND ended_at IS NULL",
    )
    .bind(lo)
    .bind(hi)
    .fetch_optional(db)
    .await?;
    Ok(row.is_some())
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A fresh, fully migrated database in a temp file. The pool has several
    /// connections, so an in-memory database (one per connection) won't do.
    pub async fn temp_db() -> SqlitePool {
        let path = std::env::temp_dir().join(format!(
            "fade-test-{}-{}.db",
            std::process::id(),
            rand::random::<u64>()
        ));
        connect(&format!("sqlite://{}", path.display()))
            .await
            .unwrap()
    }

    /// The never-delete rule, enforced: no migration may drop, delete, rename,
    /// or overwrite anything. 0002 is the one exception, from before real users.
    /// A genuinely needed backfill (`UPDATE ... WHERE col IS NULL`) gets a
    /// reviewed exception here, never a silent one.
    #[test]
    fn migrations_never_destroy_data() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
        let mut checked = 0;
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if name == "0002_e2e.sql" {
                continue;
            }
            let sql: String = std::fs::read_to_string(&path)
                .unwrap()
                .lines()
                .filter(|l| !l.trim_start().starts_with("--"))
                .collect::<Vec<_>>()
                .join(" ")
                .to_uppercase();
            let words: Vec<&str> = sql
                .split(|c: char| c.is_whitespace() || c == ';' || c == '(')
                .filter(|w| !w.is_empty())
                .collect();
            for pair in words.windows(2) {
                let banned = matches!(
                    (pair[0], pair[1]),
                    ("DROP", "TABLE" | "COLUMN")
                        | ("DELETE", "FROM")
                        | ("REPLACE", "INTO")
                        | ("RENAME", _)
                        | ("TRUNCATE", _)
                ) || (pair[0] == "UPDATE" && pair[1] != "CASCADE");
                assert!(!banned, "{name} contains `{} {}`", pair[0], pair[1]);
            }
            checked += 1;
        }
        assert!(checked >= 3);
    }

    #[tokio::test]
    async fn migrations_apply_cleanly_and_are_rerunnable() {
        let db = temp_db().await;
        let versions: Vec<i64> =
            sqlx::query_scalar("SELECT version FROM _sqlx_migrations ORDER BY version")
                .fetch_all(&db)
                .await
                .unwrap();
        assert_eq!(versions.first(), Some(&1));
        assert_eq!(versions.len() as i64, *versions.last().unwrap());
        // Running them again is a no-op, as on every server start.
        let mut m = sqlx::migrate!("./migrations");
        m.set_ignore_missing(true);
        m.run(&db).await.unwrap();
    }

    /// `sqlx::migrate!` copies migrations into the binary at compile time, and
    /// cargo doesn't notice a new or deleted file. This fails if the copy is
    /// stale; `touch src/db.rs` and rebuild. (deploy.sh does that before
    /// every release build.)
    #[test]
    fn embedded_migrations_match_the_files() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
        let mut on_disk: Vec<i64> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| {
                let name = e.unwrap().file_name().to_string_lossy().to_string();
                name.strip_suffix(".sql")?.split('_').next()?.parse().ok()
            })
            .collect();
        on_disk.sort();
        let embedded: Vec<i64> = sqlx::migrate!("./migrations")
            .iter()
            .map(|m| m.version)
            .collect();
        assert_eq!(
            embedded, on_disk,
            "stale embedded migrations: touch src/db.rs and rebuild"
        );
    }

    /// Rule 1 for application code: rows are marked (ended_at, resolved_at,
    /// revoked_at), never deleted. Fails if any server code deletes rows.
    #[test]
    fn code_never_deletes_rows() {
        let needle = ["DELETE", "FROM"].join(" ");
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let src = std::fs::read_to_string(&path).unwrap().to_uppercase();
            for (n, line) in src.lines().enumerate() {
                assert!(
                    !line.contains(&needle),
                    "{}:{} deletes rows; mark them instead (CLAUDE.md, Rule 1)",
                    path.display(),
                    n + 1
                );
            }
        }
    }

    #[test]
    fn pic_dir_sits_next_to_the_database() {
        let p = |u| default_pic_dir(u).to_string_lossy().replace('\\', "/");
        assert_eq!(
            p("sqlite:///var/lib/fade/db/fade.db"),
            "/var/lib/fade/db/pics"
        );
        assert_eq!(p("sqlite://fade.db"), "./pics");
        assert_eq!(p("sqlite:///tmp/x/t.db?mode=rwc"), "/tmp/x/pics");
    }

    /// SQL injection can't happen when every value is a bound `?` parameter.
    /// The only SQL built with `format!` may splice in UPPERCASE constants
    /// (column lists, shared SELECTs), never a variable or positional argument.
    #[test]
    fn sql_only_interpolates_constants() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut checked = 0;
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let src = std::fs::read_to_string(&path).unwrap();
            let mut rest = src.as_str();
            while let Some(at) = rest.find("(&format!(") {
                let before = &rest[..at];
                rest = &rest[at + "(&format!(".len()..];
                if !before.trim_end().ends_with('>')
                    && !before.ends_with("query_as")
                    && !before.ends_with("query_scalar")
                    && !before.ends_with("query")
                {
                    continue; // not a query
                }
                let lit = rest.trim_start();
                assert!(
                    lit.starts_with('"'),
                    "{}: query format! must start with a string literal",
                    path.display()
                );
                let end = lit[1..].find('"').expect("closing quote") + 1;
                let template = &lit[1..end];
                let after = lit[end + 1..].trim_start();
                assert!(
                    after.starts_with(')'),
                    "{}: query format! has extra arguments: {}",
                    path.display(),
                    &after[..after.len().min(60)]
                );
                let mut t = template;
                while let Some(open) = t.find('{') {
                    let close = t[open..].find('}').expect("closing brace") + open;
                    let name = &t[open + 1..close];
                    assert!(
                        !name.is_empty() && name.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'),
                        "{}: query splices in `{{{name}}}`; only UPPERCASE constants are allowed, values must be bound",
                        path.display()
                    );
                    t = &t[close + 1..];
                }
                checked += 1;
            }
        }
        assert!(
            checked >= 8,
            "found only {checked} format!-built queries; did the pattern change?"
        );
    }

    #[test]
    fn pairs_are_ordered() {
        assert_eq!(pair(5, 2), (2, 5));
        assert_eq!(pair(2, 5), (2, 5));
    }

    #[test]
    fn base64_shape() {
        assert!(is_base64("AAAA", 10));
        assert!(is_base64("AAE=", 10));
        assert!(is_base64("AA==", 10));
        assert!(is_base64("ab+/", 10));
        assert!(!is_base64("", 10));
        assert!(!is_base64("AAA", 10)); // not a multiple of 4
        assert!(!is_base64("A===", 10)); // too much padding
        assert!(!is_base64("AA-_", 10)); // URL-safe alphabet isn't accepted
        assert!(!is_base64("AAAAAAAA", 4)); // over the cap
        assert!(!is_base64("<scr", 10));
    }
}
