// Migrations are embedded at compile time by `sqlx::migrate!`. Without this,
// cargo can miss an added or removed migration file and ship a stale set.
fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
