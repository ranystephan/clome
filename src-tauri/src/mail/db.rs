//! `mail.db` — SQLite + FTS5 index for the native mail client.
//!
//! The DB is the *index*; raw RFC 822 bytes live on disk in
//! `mail::store`. Splitting these means the index stays tight (FTS5
//! over snippets and headers, not multi-MB bodies) and backups can be
//! taken with a simple file copy plus rsync of the maildir tree.
//!
//! All access goes through `tokio::task::spawn_blocking` since
//! `rusqlite` is sync. We hand out a handle (`MailDb`) to the rest of
//! the crate; the Connection itself is wrapped in a `Mutex` so multiple
//! commands can serialize through it without each opening its own
//! connection — same pattern Apple Mail uses (a single writer, many
//! short transactions).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::{params, Connection, OpenFlags};
use tokio::sync::Mutex;

/// Idempotent post-schema migrations. Each block detects the
/// pre-migration state and applies only what's missing, so a
/// developer can ship a new column without forcing a DB wipe.
fn apply_online_migrations(conn: &Connection) -> Result<(), rusqlite::Error> {
    // Phase 4 outbox: needs the OutgoingMessage payload alongside
    // each row so the supervisor can drive sends without re-reading
    // user state.
    if !column_exists(conn, "outbox", "outgoing_json")? {
        conn.execute("ALTER TABLE outbox ADD COLUMN outgoing_json TEXT", [])?;
    }
    Ok(())
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, rusqlite::Error> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        rusqlite::params![table, column],
        |r| r.get(0),
    )?;
    Ok(count > 0)
}

/// Schema version baked into `meta.schema_version`. Bump when
/// migrations land. v1 covers everything in the Phase 1 plan.
const SCHEMA_VERSION: i64 = 1;

const SCHEMA: &str = include_str!("schema.sql");

#[derive(Clone)]
pub struct MailDb {
    inner: Arc<Mutex<Connection>>,
    root: PathBuf,
}

impl MailDb {
    /// Resolves to `<app_data_dir>/mail/mail.db`. Caller is the Tauri
    /// `setup()` block, which already knows `app_data_dir`. The same
    /// `mail/` directory is the maildir root for `mail::store`.
    pub async fn open(app_data_dir: &Path) -> Result<Self, String> {
        let root = app_data_dir.join("mail");
        let db_path = root.join("mail.db");
        let root_for_blocking = root.clone();
        let db_for_blocking = db_path.clone();
        let conn = tokio::task::spawn_blocking(move || -> Result<Connection, String> {
            std::fs::create_dir_all(&root_for_blocking)
                .map_err(|e| format!("create {}: {e}", root_for_blocking.display()))?;
            let conn = Connection::open_with_flags(
                &db_for_blocking,
                OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
            )
            .map_err(|e| format!("open {}: {e}", db_for_blocking.display()))?;
            // WAL = concurrent reads while a write transaction holds.
            // synchronous=NORMAL trades a tiny crash window for ~3x
            // write throughput on macOS APFS — same trade-off Apple
            // Mail and Mimestream make.
            conn.pragma_update(None, "journal_mode", "WAL")
                .map_err(|e| format!("set WAL: {e}"))?;
            conn.pragma_update(None, "synchronous", "NORMAL")
                .map_err(|e| format!("set synchronous: {e}"))?;
            conn.pragma_update(None, "foreign_keys", "ON")
                .map_err(|e| format!("set foreign_keys: {e}"))?;
            // The schema is one big idempotent script (CREATE TABLE IF
            // NOT EXISTS, CREATE INDEX IF NOT EXISTS, …). Re-running
            // on every boot is intentional — keeps the DB self-healing
            // if an earlier boot crashed mid-migration.
            conn.execute_batch(SCHEMA)
                .map_err(|e| format!("apply schema: {e}"))?;
            // Online migrations: any column added after the original
            // schema lands here, gated by `pragma_table_info` so we
            // don't double-add. Reaches existing DBs (CREATE TABLE IF
            // NOT EXISTS skips already-present tables and so doesn't
            // pick up new columns on its own).
            apply_online_migrations(&conn)
                .map_err(|e| format!("apply migrations: {e}"))?;
            // Stamp the schema version. Future migrations branch on it.
            conn.execute(
                "INSERT INTO meta(key, value) VALUES('schema_version', ?1) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![SCHEMA_VERSION.to_string()],
            )
            .map_err(|e| format!("stamp schema_version: {e}"))?;
            Ok(conn)
        })
        .await
        .map_err(|e| format!("mail.db open spawn: {e}"))??;
        Ok(Self {
            inner: Arc::new(Mutex::new(conn)),
            root,
        })
    }

    /// Maildir root: `<app_data_dir>/mail/`. `mail::store` resolves
    /// per-account / per-folder paths under this.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Sync-callable variant of `with_conn` for the outbox supervisor
    /// (it runs on a `spawn_blocking` thread already and would
    /// otherwise need to nest one).
    pub fn with_conn_blocking<F, T>(&self, f: F) -> Result<T, String>
    where
        F: FnOnce(&mut Connection) -> Result<T, rusqlite::Error>,
    {
        let mut guard = self.inner.blocking_lock();
        f(&mut guard).map_err(|e| format!("mail.db: {e}"))
    }

    /// Run a closure with the blocking connection. Caller is
    /// responsible for keeping work short — the Mutex is shared across
    /// all callers in the process.
    pub async fn with_conn<F, T>(&self, f: F) -> Result<T, String>
    where
        F: FnOnce(&mut Connection) -> Result<T, rusqlite::Error> + Send + 'static,
        T: Send + 'static,
    {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || -> Result<T, String> {
            // .blocking_lock() is fine here: we're already on a
            // blocking thread spawned by Tokio.
            let mut guard = inner.blocking_lock();
            f(&mut guard).map_err(|e| format!("mail.db: {e}"))
        })
        .await
        .map_err(|e| format!("mail.db spawn: {e}"))?
    }
}
