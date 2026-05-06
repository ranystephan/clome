//! Persistent send queue. Implements the "send with N-second undo
//! window" UX pattern from §6.6 of `ui-ux-plan.md` plus scheduled
//! send (future `send_at`) and bounded exponential-backoff retry on
//! transient SMTP errors.
//!
//! State machine:
//!
//! ```text
//!   queued ──(undo within window)──> cancelled
//!     │
//!     │ (now >= max(send_at, undo_until))
//!     ▼
//!   sending ──(SMTP success)──> sent
//!     │
//!     │ (transient error, attempt < MAX_ATTEMPTS)
//!     ▼
//!   queued (with backoff send_at)
//!     │
//!     │ (attempt >= MAX_ATTEMPTS)
//!     ▼
//!   failed
//! ```

use std::time::Duration;

use rusqlite::params;
use serde::{Deserialize, Serialize};
use surrealdb::engine::local::Db;
use surrealdb::Surreal;
use tauri::{AppHandle, Emitter};

use crate::mail::db::MailDb;
use crate::mail::smtp;
use crate::mail::types::Account;

/// Default delay between user clicking "Send" and the actual SMTP
/// hand-off. Matches Gmail's "Undo Send" default. Configurable per
/// account in Settings (Phase 5).
pub const DEFAULT_UNDO_WINDOW_SECS: i64 = 10;

/// Cap on retries before marking a send as `failed`. Five attempts
/// with the backoff schedule below covers ~30 minutes total — enough
/// for a typical transient outage; beyond that the user should be
/// told.
const MAX_ATTEMPTS: i64 = 5;

/// Exponential-ish backoff in seconds: 1, 5, 30, 300, 1800.
fn backoff_secs(attempt: i64) -> i64 {
    match attempt {
        1 => 1,
        2 => 5,
        3 => 30,
        4 => 300,
        _ => 1800,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboxItem {
    pub id: String,
    pub account_id: String,
    pub send_at: i64,
    pub undo_until: i64,
    pub state: String,
    pub attempt_count: i64,
    pub last_error: Option<String>,
    pub message_id: Option<String>,
    /// Subject pulled from the JSON payload so the toast can show it.
    pub subject: String,
    /// Comma-joined recipient addresses for the toast preview.
    pub to_preview: String,
}

/// Wire payload from the composer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnqueueArgs {
    pub account_id: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_md: String,
    pub in_reply_to: Option<String>,
    pub references: Option<Vec<String>>,
    /// Override default undo window. `None` → DEFAULT_UNDO_WINDOW_SECS.
    pub undo_window_secs: Option<i64>,
    /// `None` → send when undo window expires. `Some(t)` → schedule
    /// for unix-second `t` (must be > now + undo_window).
    pub send_at: Option<i64>,
}

pub async fn enqueue(
    db: &MailDb,
    account: &Account,
    args: EnqueueArgs,
) -> Result<OutboxItem, String> {
    let undo = args.undo_window_secs.unwrap_or(DEFAULT_UNDO_WINDOW_SECS).max(0);
    let now = chrono::Utc::now().timestamp();
    let undo_until = now + undo;
    let send_at = args.send_at.unwrap_or(undo_until).max(undo_until);
    let id = format!("ob-{}", uuid::Uuid::new_v4());
    let payload = OutgoingPayload {
        from_addr: account.email.clone(),
        from_name: account.display_name.clone(),
        to: args.to.clone(),
        cc: args.cc.clone(),
        bcc: args.bcc.clone(),
        subject: args.subject.clone(),
        body_md: args.body_md.clone(),
        in_reply_to: args.in_reply_to.clone(),
        references: args.references.unwrap_or_default(),
    };
    let outgoing_json =
        serde_json::to_string(&payload).map_err(|e| format!("outbox serialize: {e}"))?;

    let id_for_db = id.clone();
    let account_id = args.account_id.clone();
    db.with_conn(move |conn| {
        conn.execute(
            "INSERT INTO outbox(id, account_id, send_at, undo_until, state, \
                                 attempt_count, outgoing_json) \
             VALUES (?1, ?2, ?3, ?4, 'queued', 0, ?5)",
            params![id_for_db, account_id, send_at, undo_until, outgoing_json],
        )?;
        Ok(())
    })
    .await?;

    let to_preview = args.to.join(", ");
    Ok(OutboxItem {
        id,
        account_id: args.account_id,
        send_at,
        undo_until,
        state: "queued".into(),
        attempt_count: 0,
        last_error: None,
        message_id: None,
        subject: args.subject,
        to_preview,
    })
}

pub async fn cancel(db: &MailDb, outbox_id: &str) -> Result<bool, String> {
    let id = outbox_id.to_string();
    let changed = db
        .with_conn(move |conn| {
            // Only cancel if still queued — once we've handed to SMTP
            // we can't take it back.
            conn.execute(
                "UPDATE outbox SET state = 'cancelled' \
                 WHERE id = ?1 AND state = 'queued'",
                params![id],
            )
        })
        .await?;
    Ok(changed > 0)
}

pub async fn list_pending(
    db: &MailDb,
    account_id: Option<&str>,
) -> Result<Vec<OutboxItem>, String> {
    let account_id = account_id.map(|s| s.to_string());
    db.with_conn(move |conn| {
        let mut stmt = conn.prepare(
            "SELECT id, account_id, send_at, undo_until, state, \
                    attempt_count, last_error, message_id, outgoing_json \
             FROM outbox \
             WHERE state IN ('queued', 'sending', 'failed') \
               AND (?1 IS NULL OR account_id = ?1) \
             ORDER BY send_at ASC",
        )?;
        let rows = stmt.query_map(params![account_id], parse_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    })
    .await
}

/// One pass of the supervisor. Runs every `tick` from the spawned
/// loop. Picks up due rows, drives them through `mail::smtp::send`,
/// updates state.
pub async fn run_once(
    db: &MailDb,
    surreal: &Surreal<Db>,
    app: &AppHandle,
) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp();

    // Snapshot due rows. We hold the mutex only briefly, then release
    // it so SMTP I/O doesn't block other DB readers.
    let due: Vec<(String, String, String)> = db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT id, account_id, outgoing_json FROM outbox \
                 WHERE state = 'queued' \
                   AND send_at <= ?1 \
                   AND undo_until <= ?1 \
                 ORDER BY send_at ASC \
                 LIMIT 8",
            )?;
            let rows = stmt.query_map(params![now], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                ))
            })?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
        .await?;

    for (id, account_id, outgoing_json) in due {
        // Mark sending so a second tick doesn't double-fire.
        let id_for_db = id.clone();
        let claimed = db
            .with_conn(move |conn| {
                conn.execute(
                    "UPDATE outbox SET state = 'sending' \
                     WHERE id = ?1 AND state = 'queued'",
                    params![id_for_db],
                )
            })
            .await
            .unwrap_or(0);
        if claimed == 0 {
            continue; // Another tick raced past us.
        }
        let _ = app.emit(
            "mail:outbox_update",
            serde_json::json!({ "id": &id, "state": "sending" }),
        );

        let payload: OutgoingPayload = match serde_json::from_str(&outgoing_json) {
            Ok(p) => p,
            Err(e) => {
                mark_failed(db, &id, &format!("payload deserialize: {e}")).await;
                continue;
            }
        };
        let (account, kref) = match resolve_account(surreal, &account_id).await {
            Ok(pair) => pair,
            Err(e) => {
                mark_failed(db, &id, &format!("account lookup: {e}")).await;
                continue;
            }
        };

        let outgoing = smtp::OutgoingMessage {
            from_addr: payload.from_addr,
            from_name: payload.from_name,
            to: payload.to,
            cc: payload.cc,
            bcc: payload.bcc,
            subject: payload.subject,
            body_md: payload.body_md,
            in_reply_to: payload.in_reply_to,
            references: payload.references,
        };
        match smtp::send(&account, &kref, outgoing).await {
            Ok(outcome) => {
                let id_for_db = id.clone();
                let mid = outcome.message_id.clone();
                let _ = db
                    .with_conn(move |conn| {
                        conn.execute(
                            "UPDATE outbox SET state = 'sent', message_id = ?2 WHERE id = ?1",
                            params![id_for_db, mid],
                        )
                    })
                    .await;
                let _ = app.emit(
                    "mail:outbox_update",
                    serde_json::json!({
                        "id": &id,
                        "state": "sent",
                        "messageId": outcome.message_id,
                    }),
                );
            }
            Err(e) => {
                // Schedule retry or finalise as failed.
                let id_for_db = id.clone();
                let err = e.clone();
                let next_attempt: i64 = db
                    .with_conn(move |conn| {
                        let attempts: i64 = conn.query_row(
                            "SELECT attempt_count FROM outbox WHERE id = ?1",
                            params![id_for_db],
                            |r| r.get(0),
                        )?;
                        Ok(attempts + 1)
                    })
                    .await
                    .unwrap_or(MAX_ATTEMPTS + 1);

                if next_attempt >= MAX_ATTEMPTS {
                    mark_failed(db, &id, &err).await;
                } else {
                    let retry_at = now + backoff_secs(next_attempt);
                    let id_for_db = id.clone();
                    let err_for_db = err.clone();
                    let _ = db
                        .with_conn(move |conn| {
                            conn.execute(
                                "UPDATE outbox SET state = 'queued', \
                                                 attempt_count = ?2, \
                                                 last_error = ?3, \
                                                 send_at = ?4 \
                                 WHERE id = ?1",
                                params![id_for_db, next_attempt, err_for_db, retry_at],
                            )
                        })
                        .await;
                    let _ = app.emit(
                        "mail:outbox_update",
                        serde_json::json!({
                            "id": &id,
                            "state": "queued",
                            "attempt": next_attempt,
                            "lastError": err,
                            "retryAt": retry_at,
                        }),
                    );
                }
            }
        }
    }
    Ok(())
}

async fn mark_failed(db: &MailDb, id: &str, err: &str) {
    let id_for_db = id.to_string();
    let err_for_db = err.to_string();
    let _ = db
        .with_conn(move |conn| {
            conn.execute(
                "UPDATE outbox SET state = 'failed', last_error = ?2 WHERE id = ?1",
                params![id_for_db, err_for_db],
            )
        })
        .await;
}

/// Drive the supervisor loop. Runs forever; cancelled when the app
/// exits and tokio drops the task.
pub async fn run_supervisor(db: MailDb, surreal: Surreal<Db>, app: AppHandle) {
    loop {
        if let Err(e) = run_once(&db, &surreal, &app).await {
            eprintln!("[mail::outbox] supervisor tick: {e}");
        }
        tokio::time::sleep(Duration::from_millis(1000)).await;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OutgoingPayload {
    from_addr: String,
    from_name: Option<String>,
    to: Vec<String>,
    cc: Vec<String>,
    bcc: Vec<String>,
    subject: String,
    body_md: String,
    in_reply_to: Option<String>,
    references: Vec<String>,
}

fn parse_row(row: &rusqlite::Row<'_>) -> Result<OutboxItem, rusqlite::Error> {
    let outgoing_json: Option<String> = row.get(8)?;
    let (subject, to_preview) = match outgoing_json
        .as_deref()
        .map(serde_json::from_str::<OutgoingPayload>)
    {
        Some(Ok(p)) => (p.subject, p.to.join(", ")),
        _ => (String::new(), String::new()),
    };
    Ok(OutboxItem {
        id: row.get(0)?,
        account_id: row.get(1)?,
        send_at: row.get(2)?,
        undo_until: row.get(3)?,
        state: row.get(4)?,
        attempt_count: row.get(5)?,
        last_error: row.get(6)?,
        message_id: row.get(7)?,
        subject,
        to_preview,
    })
}

async fn resolve_account(
    surreal: &Surreal<Db>,
    account_id: &str,
) -> Result<(Account, String), String> {
    let accounts = crate::db::list_email_accounts(surreal)
        .await
        .map_err(|e| e.to_string())?;
    let account = accounts
        .into_iter()
        .find(|a| a.id == account_id)
        .ok_or_else(|| format!("account not found: {account_id}"))?;
    #[derive(serde::Deserialize)]
    struct KrefRow {
        keychain_ref: String,
    }
    let id: surrealdb::sql::Thing = account_id
        .parse()
        .map_err(|_| format!("invalid account id {account_id}"))?;
    let kref_row: Option<KrefRow> = surreal
        .query("SELECT keychain_ref FROM $id")
        .bind(("id", id))
        .await
        .map_err(|e| e.to_string())?
        .take(0)
        .map_err(|e| e.to_string())?;
    let kref = kref_row
        .map(|r| r.keychain_ref)
        .ok_or_else(|| format!("no keychain_ref for {account_id}"))?;
    Ok((account, kref))
}
