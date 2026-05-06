//! Per-account, per-folder sync.
//!
//! `sync_folder` is the unit of work — connect, list, SELECT, fetch a
//! slice of UIDs, parse + thread + persist. Two modes drive the slice:
//!
//!   * `SyncMode::Newer` — first ever sync OR catch-up after offline.
//!     `Newer { initial: 100 }` fetches the last 100 if the local DB
//!     has nothing for this folder; otherwise fetches strictly above
//!     `MAX(local uid)` capped at `INCREMENTAL_FETCH_CAP`.
//!   * `SyncMode::Older { count }` — pagination. Fetches UIDs strictly
//!     below `MIN(local uid)`, up to `count`. Drives the "Load older"
//!     button in the message list.
//!
//! Future shape (Phase 3.5+): the supervisor wraps this with IDLE so
//! `Newer` runs on push without an explicit invocation. The shape of
//! the sync function stays the same.

use rusqlite::params;

use crate::mail::db::MailDb;
use crate::mail::imap;
use crate::mail::oauth;
use crate::mail::parse::{self, ParsedMessage};
use crate::mail::store;
use crate::mail::threading::{self, ThreadInput};
use crate::mail::types::{Account, ServerConfig, TlsMode};
use surrealdb::engine::local::Db;
use surrealdb::Surreal;
use chrono::TimeZone;

/// Recent-slice size for the very first sync of a folder.
const INITIAL_FETCH_COUNT: u32 = 100;

/// Cap on a single incremental fetch — protects us from a server
/// returning thousands of UIDs after a long offline gap. Anything
/// beyond gets fetched on the next tick.
const INCREMENTAL_FETCH_CAP: usize = 500;

/// Cap on a single "load older" page so a stale mailbox can't lock the
/// UI by streaming a full year of mail in one go. The user can hit the
/// button repeatedly to walk further back.
const OLDER_PAGE_CAP: usize = 200;

#[derive(Debug, Clone, Copy)]
pub enum SyncMode {
    /// Catch-up at the new end of the mailbox. Initial sync = `initial`
    /// most-recent UIDs. Subsequent syncs = anything `> MAX(local uid)`.
    Newer { initial: u32 },
    /// Pagination at the old end. Fetch up to `count` UIDs strictly
    /// below `MIN(local uid)`.
    Older { count: usize },
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncSummary {
    pub account_id: String,
    pub folder: String,
    pub uidvalidity: u32,
    pub fetched: usize,
    pub stored: usize,
    /// Thread ids whose membership changed during this sync. Drives
    /// the SurrealDB shadow-row upsert so the graph layer sees fresh
    /// aggregates (subject / count / last_date) without rescanning
    /// the whole `message` table. Empty when nothing was stored.
    #[serde(default)]
    pub touched_thread_ids: Vec<String>,
}

/// Sync the INBOX. Convenience wrapper used by the periodic sync loop;
/// resolves the inbox folder name from SPECIAL-USE and falls back to
/// the literal string `"INBOX"`.
pub async fn initial_inbox_sync(
    db: &MailDb,
    account: &Account,
    keychain_ref: &str,
) -> Result<SyncSummary, String> {
    sync_folder(db, account, keychain_ref, None, SyncMode::Newer { initial: INITIAL_FETCH_COUNT })
        .await
}

/// Sync an arbitrary folder by name. `folder` = `None` resolves to
/// the inbox; otherwise the literal folder name is used (this is the
/// IMAP server name as returned by LIST, e.g. `[Gmail]/Sent Mail` for
/// Gmail's Sent folder).
pub async fn sync_folder(
    db: &MailDb,
    account: &Account,
    keychain_ref: &str,
    folder: Option<&str>,
    mode: SyncMode,
) -> Result<SyncSummary, String> {
    // Refresh the OAuth access token if it's expired or about to be.
    // Persists the new bundle to Keychain so subsequent calls reuse it.
    let access = oauth::ensure_fresh_access(&account.email, keychain_ref).await?;

    let server = ServerConfig {
        host: account.imap_host.clone(),
        port: account.imap_port,
        security: TlsMode::Tls,
        username: account.email.clone(),
    };

    let (session, _caps) = imap::connect_xoauth2(server, account.email.clone(), access).await?;

    // account_state row precedes any folder/message inserts (FKs).
    let account_id = account.id.clone();
    let email = account.email.clone();
    db.with_conn(move |conn| {
        conn.execute(
            "INSERT INTO account_state(account_id, email, status) VALUES (?1, ?2, 'syncing') \
             ON CONFLICT(account_id) DO UPDATE SET email = excluded.email, status = 'syncing'",
            params![account_id, email],
        )?;
        Ok(())
    })
    .await?;

    // Always re-LIST so a server-side rename / new folder is visible
    // by the time we try to SELECT it. Cheap on Gmail (~one round-trip).
    let (session, folders) = imap::list_folders(session).await?;
    let target = match folder {
        Some(name) => folders
            .iter()
            .find(|f| f.name == name)
            .cloned()
            .ok_or_else(|| format!("folder not found on server: {name}"))?,
        None => folders
            .iter()
            .find(|f| f.role.as_deref() == Some("inbox"))
            .cloned()
            .or_else(|| {
                folders
                    .iter()
                    .find(|f| f.name.eq_ignore_ascii_case("INBOX"))
                    .cloned()
            })
            .ok_or_else(|| "no INBOX folder on server".to_string())?,
    };

    // Persist all folder rows up-front. Idempotent UPSERT keeps the
    // role tag fresh when a server reorganizes its SPECIAL-USE flags.
    // Also reconciles the local set against the server's current list:
    // anything we have locally that's no longer in LIST is dropped
    // (e.g. `[Gmail]` from older sync rounds before the \Noselect
    // filter landed, or a folder the user deleted server-side). The
    // cleanup is gated by `folders.len() > 1` so a transient single-
    // result LIST can't wipe the tree by accident.
    let account_id = account.id.clone();
    let folders_for_db = folders.clone();
    db.with_conn(move |conn| {
        let tx = conn.transaction()?;
        for f in &folders_for_db {
            tx.execute(
                "INSERT INTO folder(account_id, name, role, unread_count, total_count) \
                 VALUES (?1, ?2, ?3, 0, 0) \
                 ON CONFLICT(account_id, name) DO UPDATE SET role = excluded.role",
                params![account_id, f.name, f.role],
            )?;
        }
        if folders_for_db.len() > 1 {
            // Build an `IN (?, ?, …)` placeholder list. We'd reach for
            // `rarray` if rusqlite shipped it as default; manual
            // building keeps us off optional features.
            let placeholders: Vec<String> = (0..folders_for_db.len())
                .map(|i| format!("?{}", i + 2))
                .collect();
            let sql = format!(
                "DELETE FROM folder WHERE account_id = ?1 AND name NOT IN ({})",
                placeholders.join(", ")
            );
            let mut params_vec: Vec<rusqlite::types::Value> =
                vec![rusqlite::types::Value::Text(account_id.clone())];
            for f in &folders_for_db {
                params_vec.push(rusqlite::types::Value::Text(f.name.clone()));
            }
            tx.execute(&sql, rusqlite::params_from_iter(params_vec.iter()))?;
        }
        tx.commit()?;
        Ok(())
    })
    .await?;

    let (session, select_info) = imap::select(session, target.name.clone(), true).await?;

    // Persist UIDVALIDITY + total_count so subsequent syncs can detect
    // server-side rebuilds.
    let account_id = account.id.clone();
    let folder_name = target.name.clone();
    let uv = select_info.uidvalidity;
    let exists = select_info.exists;
    db.with_conn(move |conn| {
        conn.execute(
            "UPDATE folder SET uidvalidity = ?1, total_count = ?2 \
             WHERE account_id = ?3 AND name = ?4",
            params![uv, exists, account_id, folder_name],
        )?;
        Ok(())
    })
    .await?;

    // Decide which UIDs to fetch.
    let account_id = account.id.clone();
    let folder_name = target.name.clone();
    let bounds: (Option<i64>, Option<i64>) = db
        .with_conn(move |conn| {
            conn.query_row(
                "SELECT MIN(uid), MAX(uid) FROM message \
                 WHERE account_id = ?1 AND folder = ?2",
                rusqlite::params![account_id, folder_name],
                |r| Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, Option<i64>>(1)?)),
            )
        })
        .await
        .unwrap_or((None, None));
    let prior_min = bounds.0.map(|v| v as u32);
    let prior_max = bounds.1.map(|v| v as u32);

    let (session, all_uids) = imap::uid_search_all(session).await?;
    let to_fetch: Vec<u32> = match mode {
        SyncMode::Newer { initial } => match prior_max {
            Some(prev) => all_uids
                .iter()
                .copied()
                .filter(|u| *u > prev)
                .rev()
                .take(INCREMENTAL_FETCH_CAP)
                .collect(),
            None => all_uids
                .iter()
                .rev()
                .take(initial as usize)
                .copied()
                .collect(),
        },
        SyncMode::Older { count } => {
            let cap = count.min(OLDER_PAGE_CAP);
            match prior_min {
                Some(prev) => all_uids
                    .iter()
                    .copied()
                    .filter(|u| *u < prev)
                    .rev()
                    .take(cap)
                    .collect(),
                // Older with nothing local = same as initial newer.
                None => all_uids.iter().rev().take(cap).copied().collect(),
            }
        }
    };

    let uid_range = if to_fetch.is_empty() {
        imap::logout(session).await;
        return Ok(SyncSummary {
            account_id: account.id.clone(),
            folder: target.name,
            uidvalidity: select_info.uidvalidity,
            fetched: 0,
            stored: 0,
            touched_thread_ids: Vec::new(),
        });
    } else {
        let mut s: Vec<String> = to_fetch.iter().map(|u| u.to_string()).collect();
        s.sort();
        s.join(",")
    };

    let (session, fetched) = imap::uid_fetch_full(session, uid_range).await?;

    // Flag refresh pass: pull (UID, FLAGS) for the messages we have
    // *locally* so changes made elsewhere (Gmail web marking read,
    // Apple Mail starring, iPhone Mail archiving) propagate back.
    //
    // Earlier this used the server's latest UIDs which mis-fired on
    // dense inboxes — server's "newest 500" isn't necessarily what's
    // in our local DB. Asking the server about UIDs we already have
    // is unambiguous and IMAP-cheap (single round-trip, no body bytes).
    let just_fetched: std::collections::HashSet<u32> =
        fetched.iter().map(|f| f.uid).collect();
    let account_id_for_local = account.id.clone();
    let folder_name_for_local = target.name.clone();
    let local_uids: Vec<u32> = db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT uid FROM message \
                 WHERE account_id = ?1 AND folder = ?2 \
                 ORDER BY uid DESC LIMIT 2000",
            )?;
            let rows = stmt.query_map(
                rusqlite::params![account_id_for_local, folder_name_for_local],
                |r| r.get::<_, i64>(0),
            )?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r? as u32);
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();
    let to_refresh: Vec<u32> = local_uids
        .into_iter()
        .filter(|u| !just_fetched.contains(u))
        .collect();
    let session = if to_refresh.is_empty() {
        session
    } else {
        let mut s: Vec<String> = to_refresh.iter().map(|u| u.to_string()).collect();
        s.sort();
        let range = s.join(",");
        let (session, flags_pairs) = imap::uid_fetch_flags(session, range).await?;
        // Apply the flag updates in a single transaction.
        let account_id = account.id.clone();
        let folder_name = target.name.clone();
        let pair_count = flags_pairs.len();
        db.with_conn(move |conn| {
            let tx = conn.transaction()?;
            for (uid, flags) in &flags_pairs {
                let json = serde_json::to_string(flags).unwrap_or_else(|_| "[]".into());
                tx.execute(
                    "UPDATE message SET flags_json = ?1 \
                     WHERE account_id = ?2 AND folder = ?3 AND uid = ?4",
                    rusqlite::params![json, account_id, folder_name, *uid as i64],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
        .await?;
        eprintln!(
            "[mail::sync] flag refresh: {} uids in {}/{}",
            pair_count, account.id, target.name
        );
        session
    };

    imap::logout(session).await;

    let (stored, touched_thread_ids) =
        persist_messages(db, account, &target.name, fetched).await?;

    let account_id = account.id.clone();
    let now = chrono::Utc::now().timestamp();
    db.with_conn(move |conn| {
        conn.execute(
            "UPDATE account_state SET status = 'idle', last_sync_at = ?1 WHERE account_id = ?2",
            params![now, account_id],
        )?;
        Ok(())
    })
    .await?;

    Ok(SyncSummary {
        account_id: account.id.clone(),
        folder: target.name,
        uidvalidity: select_info.uidvalidity,
        fetched: stored,
        stored,
        touched_thread_ids,
    })
}

/// Lean flag-only refresh. Single connection, SELECT folder,
/// UID FETCH (UID FLAGS) for our local UIDs, update flags_json. No
/// LIST, no UID SEARCH ALL, no body fetch.
///
/// Use this from the periodic poll to keep read/star/answered state
/// in sync with what other clients (Gmail web, Apple Mail, iPhone
/// Mail) are doing — without paying the cost or fragility of the
/// full `sync_folder` path. Survives transient Gmail drops on the
/// heavyweight LIST step.
pub async fn refresh_flags_only(
    db: &MailDb,
    account: &Account,
    keychain_ref: &str,
    folder: &str,
) -> Result<usize, String> {
    let access = oauth::ensure_fresh_access(&account.email, keychain_ref).await?;
    let server = ServerConfig {
        host: account.imap_host.clone(),
        port: account.imap_port,
        security: TlsMode::Tls,
        username: account.email.clone(),
    };
    let (session, _caps) =
        imap::connect_xoauth2(server, account.email.clone(), access).await?;
    let (session, _info) = imap::select(session, folder.to_string(), true).await?;

    // Pull local UIDs we care about. Cap at 5000 — covers any
    // recent-history window the user might revisit on Gmail web.
    let account_id = account.id.clone();
    let folder_owned = folder.to_string();
    let local_uids: Vec<u32> = db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT uid FROM message \
                 WHERE account_id = ?1 AND folder = ?2 \
                 ORDER BY uid DESC LIMIT 5000",
            )?;
            let rows = stmt.query_map(
                rusqlite::params![account_id, folder_owned],
                |r| r.get::<_, i64>(0),
            )?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r? as u32);
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();

    if local_uids.is_empty() {
        imap::logout(session).await;
        return Ok(0);
    }

    let mut s: Vec<String> = local_uids.iter().map(|u| u.to_string()).collect();
    s.sort();
    let range = s.join(",");
    let (session, flags_pairs) = imap::uid_fetch_flags(session, range).await?;
    imap::logout(session).await;

    let pair_count = flags_pairs.len();
    let account_id = account.id.clone();
    let folder_owned = folder.to_string();
    db.with_conn(move |conn| {
        let tx = conn.transaction()?;
        for (uid, flags) in &flags_pairs {
            let json = serde_json::to_string(flags).unwrap_or_else(|_| "[]".into());
            tx.execute(
                "UPDATE message SET flags_json = ?1 \
                 WHERE account_id = ?2 AND folder = ?3 AND uid = ?4",
                rusqlite::params![json, account_id, folder_owned, *uid as i64],
            )?;
        }
        tx.commit()?;
        Ok(())
    })
    .await?;

    eprintln!(
        "[mail::sync] flag refresh (lean): {} uids updated in {}/{}",
        pair_count, account.id, folder
    );
    Ok(pair_count)
}

/// Pull aggregate values per thread from mail.db and upsert
/// SurrealDB `email_thread` shadow rows so the polymorphic graph
/// layer can reference threads as first-class nodes. Idempotent —
/// re-runs simply refresh subject/last_date/count.
///
/// Workspace assignment: pinned to the default workspace for now.
/// Email accounts aren't workspace-scoped yet (per spec the multi-
/// workspace UI is deferred), so the shadow row gets the same
/// implicit binding the seeded vault uses.
pub async fn upsert_thread_shadows(
    mail_db: &MailDb,
    surreal: &Surreal<Db>,
    account_id: &str,
    thread_ids: &[String],
) -> Result<usize, String> {
    if thread_ids.is_empty() {
        return Ok(0);
    }

    // One workspace lookup per sync — cheap, and avoids capturing the
    // SurrealDB handle in the rusqlite blocking closure.
    let workspaces = crate::db::list_workspaces(surreal)
        .await
        .map_err(|e| format!("list_workspaces: {e}"))?;
    let ws = workspaces
        .first()
        .ok_or_else(|| "no workspace to bind email threads to".to_string())?
        .id
        .clone();

    // Pull per-thread aggregates from mail.db. We grab the latest
    // message's metadata (subject is often the empty/default on the
    // root, but the freshest reply is the closest to what the user
    // sees in their inbox row), plus the count and the recency stamp.
    let acc_owned = account_id.to_string();
    let tids_owned: Vec<String> = thread_ids.to_vec();
    let aggregates: Vec<crate::db::EmailThreadAggregate> = mail_db
        .with_conn(move |conn| {
            // SQLite doesn't support binding an array directly, but
            // each thread_id is at most a few hundred bytes and
            // counts are bounded by a single sync batch (≤500), so
            // an in-memory loop with a prepared statement is fine.
            let mut stmt = conn.prepare(
                "SELECT subject, from_addr, from_name, date_received, \
                        (SELECT COUNT(*) FROM message m2 \
                         WHERE m2.account_id = ?1 AND m2.thread_id = ?2) AS cnt \
                 FROM message \
                 WHERE account_id = ?1 AND thread_id = ?2 \
                 ORDER BY date_received DESC LIMIT 1",
            )?;
            let mut out: Vec<crate::db::EmailThreadAggregate> = Vec::new();
            for tid in &tids_owned {
                let row = stmt.query_row(rusqlite::params![&acc_owned, tid], |r| {
                    let subject: Option<String> = r.get(0)?;
                    let from_addr: Option<String> = r.get(1)?;
                    let from_name: Option<String> = r.get(2)?;
                    let date_received: i64 = r.get(3)?;
                    let count: i64 = r.get(4)?;
                    Ok((subject, from_addr, from_name, date_received, count))
                });
                let (subject, from_addr, from_name, date_received, count) = match row {
                    Ok(v) => v,
                    Err(rusqlite::Error::QueryReturnedNoRows) => continue,
                    Err(e) => return Err(e),
                };
                let last = chrono::Utc
                    .timestamp_opt(date_received, 0)
                    .single()
                    .unwrap_or_else(chrono::Utc::now);
                out.push(crate::db::EmailThreadAggregate {
                    thread_id: tid.clone(),
                    account_id: acc_owned.clone(),
                    subject: subject.unwrap_or_default(),
                    from_addr,
                    from_name,
                    last_date: last,
                    message_count: count,
                });
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("aggregate threads: {e}"))?;

    let mut written = 0usize;
    for agg in aggregates {
        if let Err(e) = crate::db::upsert_email_thread(surreal, &ws, &agg).await {
            eprintln!(
                "[mail::sync] upsert email_thread shadow {} failed: {e}",
                agg.thread_id
            );
            continue;
        }
        written += 1;
    }
    eprintln!(
        "[mail::sync] thread shadows: account={} requested={} written={}",
        account_id,
        thread_ids.len(),
        written
    );
    Ok(written)
}

/// One-shot backfill: walks every distinct thread_id already in
/// mail.db for this account and upserts the SurrealDB shadow row.
/// Idempotent — safe to run on every boot. Necessary because
/// `persist_messages` only emits touched ids for the slice it just
/// fetched; users who synced before the shadow layer existed (or
/// who haven't received new mail since the upgrade) would otherwise
/// see an empty `email_thread` table forever.
pub async fn backfill_thread_shadows(
    mail_db: &MailDb,
    surreal: &Surreal<Db>,
    account_id: &str,
) -> Result<usize, String> {
    let acc_owned = account_id.to_string();
    let thread_ids: Vec<String> = mail_db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT DISTINCT thread_id FROM message \
                 WHERE account_id = ?1 AND thread_id IS NOT NULL",
            )?;
            let rows = stmt.query_map(rusqlite::params![&acc_owned], |r| {
                r.get::<_, String>(0)
            })?;
            let mut out = Vec::new();
            for r in rows {
                if let Ok(s) = r {
                    out.push(s);
                }
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("collect thread ids: {e}"))?;

    eprintln!(
        "[mail::sync] backfill: account={} {} thread(s) to mirror",
        account_id,
        thread_ids.len()
    );
    upsert_thread_shadows(mail_db, surreal, account_id, &thread_ids).await
}

async fn persist_messages(
    db: &MailDb,
    account: &Account,
    folder_name: &str,
    fetched: Vec<imap::FetchedMessage>,
) -> Result<(usize, Vec<String>), String> {
    let mut parsed_with_meta: Vec<(u32, Vec<u8>, Option<i64>, ParsedMessage, Vec<String>)> =
        Vec::with_capacity(fetched.len());
    for f in fetched {
        let parsed = match parse::parse(&f.raw) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[mail::sync] parse uid={} skipped: {e}", f.uid);
                continue;
            }
        };
        parsed_with_meta.push((f.uid, f.raw, f.internal_date, parsed, f.flags));
    }

    let inputs: Vec<ThreadInput> = parsed_with_meta
        .iter()
        .filter_map(|(_, _, _, p, _)| {
            p.message_id.clone().map(|id| ThreadInput {
                message_id: id,
                in_reply_to: p.in_reply_to.clone(),
                references: p.references.clone(),
            })
        })
        .collect();
    let assignments = threading::assign(&inputs);
    let thread_by_msg: std::collections::HashMap<&str, &str> = assignments
        .iter()
        .map(|a| (a.message_id.as_str(), a.thread_id.as_str()))
        .collect();

    let mut stored = 0usize;
    let mut touched_threads: std::collections::HashSet<String> =
        std::collections::HashSet::new();
    for (uid, raw, internal_date, parsed, flags) in parsed_with_meta {
        let path = store::eml_path(db.root(), &account.id, folder_name, uid);
        let sha = store::sha256_hex(&raw);
        if let Err(e) = store::write_atomic(&path, &raw).await {
            eprintln!("[mail::sync] write eml uid={uid}: {e}");
            continue;
        }

        let thread_id = parsed
            .message_id
            .as_deref()
            .and_then(|m| thread_by_msg.get(m))
            .map(|s| s.to_string());
        // Cloned for the post-insert touched-set update; the original
        // moves into the `params!` closure below.
        let thread_id_for_set = thread_id.clone();

        let date_received = parsed
            .date_sent
            .or(internal_date)
            .unwrap_or_else(|| chrono::Utc::now().timestamp());
        let to_json = serde_json::to_string(&parsed.to).unwrap_or_else(|_| "[]".into());
        let cc_json = serde_json::to_string(&parsed.cc).unwrap_or_else(|_| "[]".into());
        let bcc_json = serde_json::to_string(&parsed.bcc).unwrap_or_else(|_| "[]".into());
        let refs_json =
            serde_json::to_string(&parsed.references).unwrap_or_else(|_| "[]".into());
        let flags_json =
            serde_json::to_string(&flags).unwrap_or_else(|_| "[]".into());
        let has_att = if parsed.attachments.is_empty() { 0i64 } else { 1i64 };
        let size = raw.len() as i64;
        let eml_rel = path
            .strip_prefix(db.root())
            .unwrap_or(&path)
            .to_string_lossy()
            .into_owned();

        let account_id = account.id.clone();
        let folder_owned = folder_name.to_string();
        let message_id = parsed.message_id.clone();
        let in_reply_to = parsed.in_reply_to.clone();
        let from_addr = parsed.from_addr.clone();
        let from_name = parsed.from_name.clone();
        let subject = parsed.subject.clone();
        let snippet = parsed.snippet.clone();
        let body_text = parsed.body_text.clone();
        let body_html = parsed.body_html.clone();
        let date_sent = parsed.date_sent;
        let result = db
            .with_conn(move |conn| {
                conn.execute(
                    "INSERT INTO message ( \
                        account_id, folder, uid, message_id, thread_id, in_reply_to, refs_json, \
                        from_addr, from_name, to_json, cc_json, bcc_json, \
                        subject, snippet, date_received, date_sent, \
                        flags_json, size, has_attachments, eml_path, eml_sha256, \
                        body_text_extracted, body_html_extracted \
                     ) VALUES ( \
                        ?1, ?2, ?3, ?4, ?5, ?6, ?7, \
                        ?8, ?9, ?10, ?11, ?12, \
                        ?13, ?14, ?15, ?16, \
                        ?17, ?18, ?19, ?20, ?21, \
                        ?22, ?23 \
                     ) ON CONFLICT(account_id, folder, uid) DO UPDATE SET \
                        flags_json = excluded.flags_json, \
                        snippet = excluded.snippet",
                    params![
                        account_id,
                        folder_owned,
                        uid,
                        message_id,
                        thread_id,
                        in_reply_to,
                        refs_json,
                        from_addr,
                        from_name,
                        to_json,
                        cc_json,
                        bcc_json,
                        subject,
                        snippet,
                        date_received,
                        date_sent,
                        flags_json,
                        size,
                        has_att,
                        eml_rel,
                        sha,
                        body_text,
                        body_html,
                    ],
                )?;
                Ok(())
            })
            .await;
        if let Err(e) = result {
            eprintln!("[mail::sync] index uid={uid}: {e}");
            continue;
        }
        if let Some(tid) = thread_id_for_set {
            touched_threads.insert(tid);
        }
        stored += 1;
    }

    Ok((stored, touched_threads.into_iter().collect()))
}

