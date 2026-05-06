//! Per-account IMAP IDLE supervisor.
//!
//! One tokio task per account. Connects, SELECTs INBOX, runs `IDLE`
//! with a short keepalive. When IDLE returns (server push OR keepalive
//! timer), the supervisor closes the IDLE session and calls
//! `mail::sync::sync_folder(INBOX, Newer)` which opens its own
//! connection, fetches the delta, and emits `mail:sync_status` events
//! that the UI already listens to.
//!
//! Why two sessions instead of reusing the IDLE one for the fetch:
//!   * `sync_folder` already does the full LIST / SELECT / FETCH /
//!     persist dance and is the canonical sync path. Reusing it
//!     keeps the moving parts to one.
//!   * Opening a second TCP connection per IDLE cycle costs a few
//!     hundred ms on a warm OS — negligible vs. the 5-minute IDLE
//!     window between cycles.
//!
//! Token refresh and reconnect are handled by `sync::sync_folder` and
//! the IDLE connect path going through `oauth::ensure_fresh_access`,
//! so a long-lived supervisor stays valid as access tokens roll over.

use std::time::Duration;

use surrealdb::engine::local::Db;
use surrealdb::Surreal;
use tauri::{AppHandle, Emitter};

use crate::mail::db::MailDb;
use crate::mail::imap;
use crate::mail::oauth;
use crate::mail::sync::{self, SyncMode};
use crate::mail::types::{Account, ServerConfig, TlsMode};

/// IMAP RFC says servers may close idle sessions at 30 min — we keep
/// well below that. Five minutes also bounds how long a stale token
/// can hide before the next sync surfaces it.
const IDLE_KEEPALIVE: Duration = Duration::from_secs(290);

/// Backoff after a session fails. We don't escalate aggressively
/// because most failures are transient (Wi-Fi flap, server restart);
/// 30 s is enough to avoid hammering after an outage.
const ERROR_BACKOFF: Duration = Duration::from_secs(30);

/// Spawn one supervisor per account currently registered. Called once
/// at boot. Account additions during runtime are handled by
/// `spawn_for_account` (called from `mail_oauth_complete`).
pub async fn spawn_for_existing_accounts(
    mail_db: MailDb,
    surreal: Surreal<Db>,
    app: AppHandle,
) {
    let accounts = match crate::db::list_email_accounts(&surreal).await {
        Ok(a) => a,
        Err(e) => {
            eprintln!("[mail::idle] list_email_accounts: {e}");
            return;
        }
    };
    for account in accounts {
        spawn_for_account(mail_db.clone(), surreal.clone(), app.clone(), account.id).await;
    }
}

pub async fn spawn_for_account(
    mail_db: MailDb,
    surreal: Surreal<Db>,
    app: AppHandle,
    account_id: String,
) {
    tauri::async_runtime::spawn(run_supervisor(mail_db, surreal, app, account_id));
}

async fn run_supervisor(
    mail_db: MailDb,
    surreal: Surreal<Db>,
    app: AppHandle,
    account_id: String,
) {
    eprintln!("[mail::idle] starting supervisor for {account_id}");
    loop {
        match one_cycle(&mail_db, &surreal, &app, &account_id).await {
            Ok(()) => {
                // Cycle ended cleanly — IDLE woke us, sync ran. Loop
                // immediately to re-enter IDLE.
            }
            Err(e) => {
                // Most likely: account removed, network down, server
                // refused the session. Surface the error to the UI so
                // the user sees something is wrong, then back off
                // before retrying.
                eprintln!("[mail::idle] {account_id} cycle error: {e}");
                let _ = app.emit(
                    "mail:sync_status",
                    serde_json::json!({
                        "accountId": &account_id,
                        "status": "error",
                        "error": format!("IDLE: {e}"),
                        "ts": chrono::Utc::now().timestamp(),
                    }),
                );
                tokio::time::sleep(ERROR_BACKOFF).await;
            }
        }
    }
}

async fn one_cycle(
    mail_db: &MailDb,
    surreal: &Surreal<Db>,
    app: &AppHandle,
    account_id: &str,
) -> Result<(), String> {
    let (account, kref) = resolve_account(surreal, account_id).await?;

    // Catch up first. Cheap when nothing's new; gets us aligned with
    // what's already on the server before we start blocking on IDLE.
    if let Ok(summary) = sync::sync_folder(
        mail_db,
        &account,
        &kref,
        None, // INBOX via SPECIAL-USE
        SyncMode::Newer { initial: 100 },
    )
    .await
    {
        let _ = sync::upsert_thread_shadows(
            mail_db,
            surreal,
            account_id,
            &summary.touched_thread_ids,
        )
        .await;
    }
    emit_idle_event(app, account_id, "ready");

    // Open a fresh session just for IDLE — `sync_folder` already
    // closed its own.
    let access = oauth::ensure_fresh_access(&account.email, &kref).await?;
    let server = ServerConfig {
        host: account.imap_host.clone(),
        port: account.imap_port,
        security: TlsMode::Tls,
        username: account.email.clone(),
    };
    let (session, caps) =
        imap::connect_xoauth2(server, account.email.clone(), access).await?;
    if !caps.idle {
        // Server doesn't advertise IDLE — we still got a session; just
        // log out and let the periodic poll cover this account.
        imap::logout(session).await;
        return Err("server does not advertise IDLE — falling back to polling".into());
    }
    let (session, _info) =
        imap::select(session, "INBOX".to_string(), true).await?;

    emit_idle_event(app, account_id, "idling");
    let session = imap::idle_wait(session, IDLE_KEEPALIVE).await?;
    imap::logout(session).await;

    // IDLE woke up. Could be new mail OR keepalive — either way,
    // we run a sync to pull anything new. Sync emits its own events
    // (mail:sync_status idle / error) which the sidebar already
    // listens to for "Synced N min ago" timestamps.
    if let Ok(summary) = sync::sync_folder(
        mail_db,
        &account,
        &kref,
        None,
        SyncMode::Newer { initial: 100 },
    )
    .await
    {
        let _ = sync::upsert_thread_shadows(
            mail_db,
            surreal,
            account_id,
            &summary.touched_thread_ids,
        )
        .await;
    }
    Ok(())
}

fn emit_idle_event(app: &AppHandle, account_id: &str, phase: &str) {
    let _ = app.emit(
        "mail:idle_phase",
        serde_json::json!({ "accountId": account_id, "phase": phase }),
    );
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
