//! Tauri command handlers for the Phase 1 onboarding surface.
//!
//! - `mail_autoconfig(email)` — resolve provider from email address.
//! - `mail_oauth_start(autoconfig)` — open browser to OAuth URL,
//!    return handoff state. The auth flow continues asynchronously
//!    via the loopback listener spawned inside `mail::oauth::begin`.
//! - `mail_oauth_complete(handoff)` — block on the loopback receiver,
//!    exchange the code, persist tokens to Keychain, write the
//!    SurrealDB account row, return the resulting `Account`.
//! - `mail_account_list()` — read accounts from SurrealDB.
//! - `mail_account_remove(id)` — delete account row + Keychain entry.
//!
//! The browser is opened via `tauri-plugin-opener` so we don't add a
//! new dep just for the URL hand-off.

use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use surrealdb::engine::local::Db;
use surrealdb::Surreal;
use tauri::{AppHandle, Emitter};
use tauri_plugin_opener::OpenerExt;
use tokio::sync::Mutex;

use crate::mail::autoconfig;
use crate::mail::keychain;
use crate::mail::oauth::{self, PendingAuth};
use crate::mail::types::{Account, AutoconfigResult, ProviderKind};

/// Phase-1-only state: we stash the in-flight OAuth handoff while the
/// browser is open. Keyed by the CSRF state token (unique per attempt).
/// `mail_oauth_complete(state)` looks up by state, drives the flow to
/// completion, then drops the entry.
#[derive(Default, Clone)]
pub struct OAuthPending(pub Arc<Mutex<HashMap<String, PendingAuth>>>);

#[tauri::command]
pub async fn mail_autoconfig(email: String) -> Result<AutoconfigResult, String> {
    autoconfig::resolve(&email)
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthStartResult {
    pub state: String,
    pub auth_url: String,
    pub redirect_uri: String,
}

#[tauri::command]
pub async fn mail_oauth_start(
    app: AppHandle,
    pending: tauri::State<'_, OAuthPending>,
    autoconfig: AutoconfigResult,
) -> Result<OAuthStartResult, String> {
    let endpoints = autoconfig
        .oauth
        .clone()
        .ok_or_else(|| "this provider does not support OAuth — use app-specific password".to_string())?;
    let pa = oauth::begin(endpoints).await?;
    let state = pa.csrf.secret().clone();
    let result = OAuthStartResult {
        state: state.clone(),
        auth_url: pa.auth_url.clone(),
        redirect_uri: pa.redirect_uri.clone(),
    };
    pending.0.lock().await.insert(state, pa);

    // Open the system browser. tauri-plugin-opener returns immediately
    // — the loopback listener inside `oauth::begin` handles the
    // redirect. If the open call fails (no default browser?), surface
    // the URL so the user can paste it manually.
    if let Err(e) = app.opener().open_url(&result.auth_url, None::<&str>) {
        eprintln!("[mail_oauth_start] opener failed: {e} — user must open URL manually");
    }
    Ok(result)
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthCompleteArgs {
    pub state: String,
    pub autoconfig: AutoconfigResult,
}

#[tauri::command]
pub async fn mail_oauth_complete(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    pending: tauri::State<'_, OAuthPending>,
    args: OAuthCompleteArgs,
) -> Result<Account, String> {
    let pa = pending
        .0
        .lock()
        .await
        .remove(&args.state)
        .ok_or_else(|| "no pending OAuth flow for this state — start over".to_string())?;
    let provider_tag = args.autoconfig.provider.as_str().to_string();
    let bundle = oauth::finish(pa, &provider_tag).await?;

    // Persist tokens *before* writing the SurrealDB row so a crash
    // between the two leaves an orphaned Keychain item rather than an
    // account row pointing at nothing.
    let kref = keychain::new_ref();
    keychain::store(&kref, &bundle).await?;

    let account = crate::db::create_email_account(
        &db,
        &args.autoconfig,
        &kref,
        bundle.refresh_token.is_some(),
    )
    .await
    .map_err(|e| {
        // Best-effort cleanup if SurrealDB write fails after Keychain
        // write succeeded. Logging only — we don't want to mask the
        // SurrealDB error with a Keychain delete error.
        let kref = kref.clone();
        tauri::async_runtime::spawn(async move {
            let _ = keychain::delete(&kref).await;
        });
        format!("create_email_account: {e}")
    })?;

    // Hot-spawn an IDLE supervisor for this brand-new account so it
    // gets push notifications without an app restart. The supervisor
    // is `loop`-driven — it will catch up on first iteration via the
    // initial sync, then enter IDLE.
    let mail_db_for_idle: crate::mail::db::MailDb = (*mail_db).clone();
    let surreal_for_idle: surrealdb::Surreal<surrealdb::engine::local::Db> = (*db).clone();
    let app_for_idle = app.clone();
    let id_for_idle = account.id.clone();
    tauri::async_runtime::spawn(async move {
        crate::mail::idle::spawn_for_account(
            mail_db_for_idle,
            surreal_for_idle,
            app_for_idle,
            id_for_idle,
        )
        .await;
    });

    Ok(account)
}

#[tauri::command]
pub async fn mail_account_list(
    db: tauri::State<'_, Surreal<Db>>,
) -> Result<Vec<Account>, String> {
    crate::db::list_email_accounts(&db)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn mail_account_remove(
    db: tauri::State<'_, Surreal<Db>>,
    account_id: String,
) -> Result<(), String> {
    let kref = crate::db::delete_email_account(&db, &account_id)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(kref) = kref {
        // Drop the Keychain item too. If it's already gone (manual
        // cleanup, prior crash) treat as success.
        if let Err(e) = keychain::delete(&kref).await {
            eprintln!("[mail_account_remove] keychain delete: {e}");
        }
    }
    Ok(())
}

/// Helper used by `lib.rs::run` to populate `Account` shapes when the
/// frontend wants the *current* provider tag without re-resolving.
/// Phase 2 wires this into a richer status surface; today it's just a
/// utility re-export.
pub fn provider_for(account: &Account) -> ProviderKind {
    account.provider
}

// ── Phase 2: read path ──────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub name: String,
    pub role: Option<String>,
    pub uidvalidity: Option<u32>,
    pub unread_count: i64,
    pub total_count: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct MessageHeader {
    pub account_id: String,
    pub folder: String,
    pub uid: u32,
    pub message_id: Option<String>,
    pub thread_id: Option<String>,
    pub from_addr: Option<String>,
    pub from_name: Option<String>,
    pub subject: Option<String>,
    pub snippet: Option<String>,
    pub date_received: i64,
    pub has_attachments: bool,
    /// Stable "is unread" / "is flagged" flags extracted from
    /// `flags_json`. Phase 2 keeps it boolean — Phase 4 surfaces the
    /// full IMAP flag set (`\Seen`, `\Flagged`, custom labels).
    pub unread: bool,
    pub flagged: bool,
    /// Folder role at the time of the query: `"inbox"` for received
    /// mail, `"sent"` for outgoing, `None` for drafts/archives/etc.
    /// Lets agent reasoning answer "did X reply" by spotting an inbox
    /// row in the same thread as a sent row.
    #[serde(default)]
    pub direction: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct MessageDetail {
    pub header: MessageHeader,
    pub to: Vec<crate::mail::parse::EmailAddr>,
    pub cc: Vec<crate::mail::parse::EmailAddr>,
    pub html: String,
    pub plain_fallback: Option<String>,
    pub had_remote_images: bool,
    pub remote_images_allowed: bool,
    pub attachments: Vec<AttachmentInfo>,
    pub has_calendar_invite: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentInfo {
    pub content_id: String,
    pub filename: Option<String>,
    pub mime: String,
    pub size: usize,
    pub is_inline: bool,
}

/// Resolve account + keychain_ref from a SurrealDB account id, common
/// preamble for every sync / write command.
async fn account_and_kref(
    db: &Surreal<Db>,
    account_id: &str,
) -> Result<(Account, String), String> {
    let accounts = crate::db::list_email_accounts(db)
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
    let kref_row: Option<KrefRow> = db
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

/// Emit "syncing" before, "idle" or "error" after. Errors are emitted
/// as events (not just returned) so the sidebar status indicator
/// shows them even when the call site forgot to render the rejected
/// promise.
fn emit_sync_event(app: &AppHandle, payload: serde_json::Value) {
    let _ = app.emit("mail:sync_status", payload);
}

#[tauri::command]
pub async fn mail_sync_inbox(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
) -> Result<crate::mail::sync::SyncSummary, String> {
    let (account, kref) = account_and_kref(&db, &account_id).await?;
    emit_sync_event(
        &app,
        serde_json::json!({ "accountId": account_id, "status": "syncing" }),
    );
    match crate::mail::sync::initial_inbox_sync(&mail_db, &account, &kref).await {
        Ok(summary) => {
            // Mirror touched threads into the SurrealDB graph layer so
            // graph_search / graph_view_query find them. Failure here
            // is non-fatal — the mail UI still works without shadows.
            let _ = crate::mail::sync::upsert_thread_shadows(
                &mail_db,
                &db,
                &account_id,
                &summary.touched_thread_ids,
            )
            .await;
            emit_sync_event(
                &app,
                serde_json::json!({
                    "accountId": account_id,
                    "status": "idle",
                    "fetched": summary.fetched,
                    "stored": summary.stored,
                    "ts": chrono::Utc::now().timestamp(),
                }),
            );
            Ok(summary)
        }
        Err(e) => {
            emit_sync_event(
                &app,
                serde_json::json!({
                    "accountId": account_id,
                    "status": "error",
                    "error": &e,
                    "ts": chrono::Utc::now().timestamp(),
                }),
            );
            Err(e)
        }
    }
}

#[tauri::command]
pub async fn mail_sync_folder(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
) -> Result<crate::mail::sync::SyncSummary, String> {
    let (account, kref) = account_and_kref(&db, &account_id).await?;
    emit_sync_event(
        &app,
        serde_json::json!({
            "accountId": account_id,
            "folder": folder,
            "status": "syncing",
        }),
    );
    match crate::mail::sync::sync_folder(
        &mail_db,
        &account,
        &kref,
        Some(&folder),
        crate::mail::sync::SyncMode::Newer { initial: 100 },
    )
    .await
    {
        Ok(summary) => {
            let _ = crate::mail::sync::upsert_thread_shadows(
                &mail_db,
                &db,
                &account_id,
                &summary.touched_thread_ids,
            )
            .await;
            emit_sync_event(
                &app,
                serde_json::json!({
                    "accountId": account_id,
                    "folder": folder,
                    "status": "idle",
                    "fetched": summary.fetched,
                    "stored": summary.stored,
                    "ts": chrono::Utc::now().timestamp(),
                }),
            );
            Ok(summary)
        }
        Err(e) => {
            emit_sync_event(
                &app,
                serde_json::json!({
                    "accountId": account_id,
                    "folder": folder,
                    "status": "error",
                    "error": &e,
                    "ts": chrono::Utc::now().timestamp(),
                }),
            );
            Err(e)
        }
    }
}

/// Lean flag-only sync — keeps unread / starred / answered state
/// aligned with whatever you (or Apple Mail / Outlook / Gmail web)
/// did externally. Decoupled from the heavyweight `mail_sync_inbox`
/// so it keeps working even when Gmail drops the LIST mid-flight.
#[tauri::command]
pub async fn mail_refresh_flags(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: Option<String>,
) -> Result<usize, String> {
    let (account, kref) = account_and_kref(&db, &account_id).await?;
    let folder = folder.unwrap_or_else(|| "INBOX".into());
    match crate::mail::sync::refresh_flags_only(&mail_db, &account, &kref, &folder).await {
        Ok(n) => {
            // Tell the UI to re-read flags so the sidebar dots /
            // unread bold / star icons reflect what we just wrote.
            let _ = app.emit(
                "mail:flags_refreshed",
                serde_json::json!({
                    "accountId": account_id,
                    "folder": folder,
                    "updated": n,
                }),
            );
            Ok(n)
        }
        Err(e) => Err(e),
    }
}

#[tauri::command]
pub async fn mail_load_older(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    count: Option<usize>,
) -> Result<crate::mail::sync::SyncSummary, String> {
    let count = count.unwrap_or(100).min(200);
    let (account, kref) = account_and_kref(&db, &account_id).await?;
    let _ = app.emit(
        "mail:sync_status",
        serde_json::json!({ "accountId": account_id, "folder": folder, "status": "syncing" }),
    );
    let summary = crate::mail::sync::sync_folder(
        &mail_db,
        &account,
        &kref,
        Some(&folder),
        crate::mail::sync::SyncMode::Older { count },
    )
    .await?;
    let _ = crate::mail::sync::upsert_thread_shadows(
        &mail_db,
        &db,
        &account_id,
        &summary.touched_thread_ids,
    )
    .await;
    let _ = app.emit(
        "mail:sync_status",
        serde_json::json!({
            "accountId": account_id,
            "folder": folder,
            "status": "idle",
            "fetched": summary.fetched,
            "stored": summary.stored,
        }),
    );
    Ok(summary)
}

#[tauri::command]
pub async fn mail_folder_list(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
) -> Result<Vec<Folder>, String> {
    mail_db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT name, role, uidvalidity, unread_count, total_count \
                 FROM folder WHERE account_id = ?1 \
                 ORDER BY \
                    CASE role \
                        WHEN 'inbox' THEN 0 \
                        WHEN 'sent' THEN 1 \
                        WHEN 'drafts' THEN 2 \
                        WHEN 'archive' THEN 3 \
                        WHEN 'trash' THEN 4 \
                        WHEN 'junk' THEN 5 \
                        ELSE 99 END, \
                    name ASC",
            )?;
            let rows = stmt.query_map(rusqlite::params![account_id], |row| {
                Ok(Folder {
                    name: row.get(0)?,
                    role: row.get(1)?,
                    uidvalidity: row.get::<_, Option<i64>>(2)?.map(|v| v as u32),
                    unread_count: row.get(3)?,
                    total_count: row.get(4)?,
                })
            })?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
        .await
}

#[tauri::command]
pub async fn mail_message_list(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    limit: Option<i64>,
    offset: Option<i64>,
) -> Result<Vec<MessageHeader>, String> {
    let limit = limit.unwrap_or(200).clamp(1, 1000);
    let offset = offset.unwrap_or(0).max(0);
    mail_db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT account_id, folder, uid, message_id, thread_id, \
                        from_addr, from_name, subject, snippet, date_received, \
                        has_attachments, flags_json \
                 FROM message \
                 WHERE account_id = ?1 AND folder = ?2 \
                 ORDER BY date_received DESC \
                 LIMIT ?3 OFFSET ?4",
            )?;
            let rows = stmt.query_map(
                rusqlite::params![account_id, folder, limit, offset],
                |row| {
                    let flags_json: String = row.get(11)?;
                    let unread = !flags_json.contains("\\Seen") && !flags_json.contains("Seen");
                    let flagged = flags_json.contains("\\Flagged") || flags_json.contains("Flagged");
                    Ok(MessageHeader {
                        account_id: row.get(0)?,
                        folder: row.get(1)?,
                        uid: row.get::<_, i64>(2)? as u32,
                        message_id: row.get(3)?,
                        thread_id: row.get(4)?,
                        from_addr: row.get(5)?,
                        from_name: row.get(6)?,
                        subject: row.get(7)?,
                        snippet: row.get(8)?,
                        date_received: row.get(9)?,
                        has_attachments: row.get::<_, i64>(10)? != 0,
                        unread,
                        flagged,
                        direction: None,
                    })
                },
            )?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
        .await
}

#[tauri::command]
pub async fn mail_thread_get(
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    thread_id: String,
) -> Result<Vec<MessageHeader>, String> {
    let thread_id_for_query = thread_id.clone();
    let headers: Vec<MessageHeader> = mail_db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT account_id, folder, uid, message_id, thread_id, \
                        from_addr, from_name, subject, snippet, date_received, \
                        has_attachments, flags_json \
                 FROM message \
                 WHERE thread_id = ?1 \
                 ORDER BY date_received ASC",
            )?;
            let rows = stmt.query_map(rusqlite::params![thread_id_for_query], |row| {
                let flags_json: String = row.get(11)?;
                let unread = !flags_json.contains("\\Seen") && !flags_json.contains("Seen");
                let flagged = flags_json.contains("\\Flagged") || flags_json.contains("Flagged");
                Ok(MessageHeader {
                    account_id: row.get(0)?,
                    folder: row.get(1)?,
                    uid: row.get::<_, i64>(2)? as u32,
                    message_id: row.get(3)?,
                    thread_id: row.get(4)?,
                    from_addr: row.get(5)?,
                    from_name: row.get(6)?,
                    subject: row.get(7)?,
                    snippet: row.get(8)?,
                    date_received: row.get(9)?,
                    has_attachments: row.get::<_, i64>(10)? != 0,
                    unread,
                    flagged,
                    direction: None,
                })
            })?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
        .await?;

    // Touch the SurrealDB shadow as a low-signal "user looked at
    // this" marker. Visibility in the graph requires explicit
    // promotion (see `promote_email_thread`), so this stamp is
    // only used by future heuristics.
    if let Some(first) = headers.first() {
        let _ = crate::db::mark_email_thread_touched(&db, &thread_id, &first.account_id).await;
    }
    Ok(headers)
}

#[tauri::command]
pub async fn mail_message_get(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    uid: u32,
    allow_remote_images_once: Option<bool>,
) -> Result<MessageDetail, String> {
    // Pull header row + eml_path from the index.
    #[derive(Clone)]
    struct Row {
        eml_rel: String,
        eml_sha256: Option<String>,
        message_id: Option<String>,
        thread_id: Option<String>,
        from_addr: Option<String>,
        from_name: Option<String>,
        subject: Option<String>,
        snippet: Option<String>,
        date_received: i64,
        has_attachments: bool,
        flags_json: String,
    }
    let account_id_for_db = account_id.clone();
    let folder_for_db = folder.clone();
    let row: Row = mail_db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT eml_path, eml_sha256, message_id, thread_id, \
                        from_addr, from_name, subject, snippet, date_received, \
                        has_attachments, flags_json \
                 FROM message \
                 WHERE account_id = ?1 AND folder = ?2 AND uid = ?3",
            )?;
            stmt.query_row(
                rusqlite::params![account_id_for_db, folder_for_db, uid],
                |r| {
                    Ok(Row {
                        eml_rel: r.get(0)?,
                        eml_sha256: r.get(1)?,
                        message_id: r.get(2)?,
                        thread_id: r.get(3)?,
                        from_addr: r.get(4)?,
                        from_name: r.get(5)?,
                        subject: r.get(6)?,
                        snippet: r.get(7)?,
                        date_received: r.get(8)?,
                        has_attachments: r.get::<_, i64>(9)? != 0,
                        flags_json: r.get(10)?,
                    })
                },
            )
        })
        .await?;

    let path = mail_db.root().join(&row.eml_rel);
    let raw = crate::mail::store::read_verified(&path, row.eml_sha256.as_deref()).await?;
    let parsed = crate::mail::parse::parse(&raw)?;

    // Sender allowlist lookup.
    let sender = row.from_addr.clone().unwrap_or_default();
    let account_id_for_db = account_id.clone();
    let allow_remote = mail_db
        .with_conn(move |conn| {
            if sender.is_empty() {
                return Ok::<bool, rusqlite::Error>(false);
            }
            let count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM remote_image_allow \
                 WHERE account_id = ?1 AND sender_email = ?2",
                rusqlite::params![account_id_for_db, sender],
                |r| r.get(0),
            )?;
            Ok(count > 0)
        })
        .await
        .unwrap_or(false);

    let html_input = parsed.body_html.clone().unwrap_or_else(|| {
        // Plain-only message: wrap as <pre> so the iframe still has
        // safe HTML to render. The sanitiser pass below preserves it.
        format!(
            "<pre style=\"white-space:pre-wrap;font-family:inherit\">{}</pre>",
            html_escape(parsed.body_text.as_deref().unwrap_or(""))
        )
    });
    let effective_allow_remote = allow_remote || allow_remote_images_once.unwrap_or(false);
    let opts = crate::mail::sanitize::SanitizeOptions {
        allow_remote_images: effective_allow_remote,
        strip_tracking_pixels: false,
    };
    let sanitised = crate::mail::sanitize::sanitize(&html_input, &opts);

    let attachments = parsed
        .attachments
        .iter()
        .map(|a| AttachmentInfo {
            content_id: a.content_id.clone(),
            filename: a.filename.clone(),
            mime: a.mime.clone(),
            size: a.size,
            is_inline: a.is_inline,
        })
        .collect();

    let unread = !row.flags_json.contains("\\Seen") && !row.flags_json.contains("Seen");
    let flagged =
        row.flags_json.contains("\\Flagged") || row.flags_json.contains("Flagged");

    Ok(MessageDetail {
        header: MessageHeader {
            account_id,
            folder,
            uid,
            message_id: row.message_id,
            thread_id: row.thread_id,
            from_addr: row.from_addr,
            from_name: row.from_name,
            subject: row.subject,
            snippet: row.snippet,
            date_received: row.date_received,
            has_attachments: row.has_attachments,
            unread,
            flagged,
            direction: None,
        },
        to: parsed.to,
        cc: parsed.cc,
        html: sanitised.html,
        plain_fallback: parsed.body_text,
        had_remote_images: sanitised.had_remote_images,
        remote_images_allowed: effective_allow_remote,
        attachments,
        has_calendar_invite: parsed.has_calendar_invite,
    })
}

#[tauri::command]
pub async fn mail_search(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: Option<String>,
    query: String,
    limit: Option<i64>,
    offset: Option<i64>,
    direction: Option<String>,
) -> Result<Vec<MessageHeader>, String> {
    let limit = limit.unwrap_or(100).clamp(1, 500);
    let offset = offset.unwrap_or(0).max(0);
    let dir = crate::mail::search::Direction::parse(direction.as_deref());
    mail_db
        .with_conn(move |conn| {
            crate::mail::search::search(
                conn,
                account_id.as_deref(),
                &query,
                limit,
                offset,
                dir,
            )
        })
        .await
}

#[tauri::command]
pub async fn mail_unified_inbox(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> Result<Vec<MessageHeader>, String> {
    let limit = limit.unwrap_or(200).clamp(1, 1000);
    let offset = offset.unwrap_or(0).max(0);
    mail_db
        .with_conn(move |conn| {
            // Join `message` against `folder` so we can constrain on the
            // SPECIAL-USE role rather than the (server-specific) folder
            // name. "Inbox" lives at different paths across providers.
            let mut stmt = conn.prepare(
                "SELECT m.account_id, m.folder, m.uid, m.message_id, m.thread_id, \
                        m.from_addr, m.from_name, m.subject, m.snippet, m.date_received, \
                        m.has_attachments, m.flags_json \
                 FROM message m \
                 JOIN folder f ON f.account_id = m.account_id AND f.name = m.folder \
                 WHERE f.role = 'inbox' \
                 ORDER BY m.date_received DESC \
                 LIMIT ?1 OFFSET ?2",
            )?;
            let rows = stmt.query_map(rusqlite::params![limit, offset], |row| {
                let flags_json: String = row.get(11)?;
                let unread = !flags_json.contains("Seen");
                let flagged = flags_json.contains("Flagged");
                Ok(MessageHeader {
                    account_id: row.get(0)?,
                    folder: row.get(1)?,
                    uid: row.get::<_, i64>(2)? as u32,
                    message_id: row.get(3)?,
                    thread_id: row.get(4)?,
                    from_addr: row.get(5)?,
                    from_name: row.get(6)?,
                    subject: row.get(7)?,
                    snippet: row.get(8)?,
                    date_received: row.get(9)?,
                    has_attachments: row.get::<_, i64>(10)? != 0,
                    unread,
                    flagged,
                    direction: None,
                })
            })?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
        .await
}

// ── Phase 4: write path ─────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ComposeArgs {
    pub account_id: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_md: String,
    pub in_reply_to: Option<String>,
    pub references: Option<Vec<String>>,
}

/// Enqueue a message for send. The actual SMTP fire happens after the
/// undo window (default 10s) expires, driven by the outbox supervisor.
///
/// Returns the outbox row so the frontend can show the "Sending in
/// Ns…" toast and surface UNDO until the window passes.
#[tauri::command]
pub async fn mail_send(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    args: ComposeArgs,
) -> Result<crate::mail::outbox::OutboxItem, String> {
    let (account, _kref) = account_and_kref(&db, &args.account_id).await?;
    let item = crate::mail::outbox::enqueue(
        &mail_db,
        &account,
        crate::mail::outbox::EnqueueArgs {
            account_id: args.account_id.clone(),
            to: args.to,
            cc: args.cc,
            bcc: args.bcc,
            subject: args.subject,
            body_md: args.body_md,
            in_reply_to: args.in_reply_to,
            references: args.references,
            undo_window_secs: None,
            send_at: None,
        },
    )
    .await?;
    let _ = app.emit(
        "mail:outbox_update",
        serde_json::json!({
            "id": item.id,
            "state": "queued",
            "undoUntil": item.undo_until,
            "subject": item.subject,
        }),
    );
    Ok(item)
}

#[tauri::command]
pub async fn mail_outbox_undo(
    app: AppHandle,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    outbox_id: String,
) -> Result<bool, String> {
    let id_for_event = outbox_id.clone();
    let cancelled = crate::mail::outbox::cancel(&mail_db, &outbox_id).await?;
    if cancelled {
        let _ = app.emit(
            "mail:outbox_update",
            serde_json::json!({ "id": id_for_event, "state": "cancelled" }),
        );
    }
    Ok(cancelled)
}

#[tauri::command]
pub async fn mail_outbox_pending(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: Option<String>,
) -> Result<Vec<crate::mail::outbox::OutboxItem>, String> {
    crate::mail::outbox::list_pending(&mail_db, account_id.as_deref()).await
}

/// Connect, SELECT (read-write), run a closure with the session, then
/// log out. Used by the flag / move / delete commands so each one is
/// independently atomic at the IMAP level.
async fn with_session<F, Fut, T>(
    db: &Surreal<Db>,
    account_id: &str,
    folder: &str,
    body: F,
) -> Result<T, String>
where
    F: FnOnce(crate::mail::imap::ImapSession) -> Fut,
    Fut: std::future::Future<Output = Result<(crate::mail::imap::ImapSession, T), String>>,
{
    let (account, kref) = account_and_kref(db, account_id).await?;
    let bundle = crate::mail::keychain::load(&kref).await?;
    if bundle.access_token.is_empty() {
        return Err("OAuth bundle has empty access_token — re-authenticate".into());
    }
    let server = crate::mail::types::ServerConfig {
        host: account.imap_host.clone(),
        port: account.imap_port,
        security: crate::mail::types::TlsMode::Tls,
        username: account.email.clone(),
    };
    let (session, _caps) =
        crate::mail::imap::connect_xoauth2(server, account.email.clone(), bundle.access_token)
            .await?;
    let (session, _info) =
        crate::mail::imap::select(session, folder.to_string(), false).await?;
    let result = body(session).await;
    match result {
        Ok((session, value)) => {
            crate::mail::imap::logout(session).await;
            Ok(value)
        }
        Err(e) => Err(e),
    }
}

#[tauri::command]
pub async fn mail_message_set_flag(
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    uid: u32,
    flag: String,
    set: bool,
) -> Result<(), String> {
    let flag_for_imap = flag.clone();
    with_session(&db, &account_id, &folder, move |session| async move {
        let op = if set {
            crate::mail::imap::FlagOp::Add
        } else {
            crate::mail::imap::FlagOp::Remove
        };
        let session =
            crate::mail::imap::uid_store_flags(session, uid, vec![flag_for_imap.clone()], op)
                .await?;
        Ok((session, ()))
    })
    .await?;

    // Reflect locally — flags_json is a JSON array of opaque tokens
    // produced by `format!("{:?}", flag)` in fetch. Toggle the
    // friendly name so subsequent list reads see the new state without
    // a round-trip resync.
    let flag_for_db = flag.clone();
    let account_id_for_db = account_id.clone();
    let folder_for_db = folder.clone();
    mail_db
        .with_conn(move |conn| {
            let row: (String,) = conn.query_row(
                "SELECT flags_json FROM message \
                 WHERE account_id = ?1 AND folder = ?2 AND uid = ?3",
                rusqlite::params![account_id_for_db, folder_for_db, uid],
                |r| Ok((r.get(0)?,)),
            )?;
            let mut flags: Vec<String> =
                serde_json::from_str(&row.0).unwrap_or_default();
            // Strip any prior trace of this flag, then add iff set.
            flags.retain(|f| !f.contains(&flag_for_db));
            if set {
                flags.push(flag_for_db.clone());
            }
            let new_json = serde_json::to_string(&flags).unwrap_or_else(|_| "[]".into());
            conn.execute(
                "UPDATE message SET flags_json = ?1 \
                 WHERE account_id = ?2 AND folder = ?3 AND uid = ?4",
                rusqlite::params![new_json, account_id_for_db, folder_for_db, uid],
            )?;
            Ok(())
        })
        .await?;

    Ok(())
}

#[tauri::command]
pub async fn mail_message_move(
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    uid: u32,
    target_folder: String,
) -> Result<(), String> {
    let target_for_imap = target_folder.clone();
    with_session(&db, &account_id, &folder, move |session| async move {
        let session = crate::mail::imap::uid_move(session, uid, target_for_imap).await?;
        Ok((session, ()))
    })
    .await?;

    delete_local_message(&mail_db, account_id.clone(), folder.clone(), uid).await?;
    Ok(())
}

async fn delete_local_message(
    mail_db: &crate::mail::db::MailDb,
    account_id: String,
    folder: String,
    uid: u32,
) -> Result<(), String> {
    mail_db
        .with_conn(move |conn| {
            conn.execute(
                "DELETE FROM message \
                 WHERE account_id = ?1 AND folder = ?2 AND uid = ?3",
                rusqlite::params![account_id, folder, uid],
            )?;
            Ok(())
        })
        .await
}

#[tauri::command]
pub async fn mail_message_archive(
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    uid: u32,
) -> Result<(), String> {
    let target = resolve_folder_by_role(&mail_db, &account_id, "archive").await?;
    mail_message_move(db, mail_db, account_id, folder, uid, target).await
}

#[tauri::command]
pub async fn mail_message_delete(
    db: tauri::State<'_, Surreal<Db>>,
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
    uid: u32,
) -> Result<(), String> {
    // Soft delete = move to Trash. Aligns with what the web UI does
    // for Gmail / Outlook / Fastmail. Permanent expunge happens when
    // the user empties Trash (Phase 5).
    delete_local_message(&mail_db, account_id.clone(), folder.clone(), uid).await?;
    let target = match resolve_folder_by_role(&mail_db, &account_id, "trash").await {
        Ok(target) => target,
        Err(e) => {
            eprintln!("[Mail] local delete complete; remote Trash lookup failed: {e}");
            return Ok(());
        }
    };
    if let Err(e) = mail_message_move(db, mail_db, account_id, folder, uid, target).await {
        eprintln!("[Mail] local delete complete; remote delete failed: {e}");
    }
    Ok(())
}

async fn resolve_folder_by_role(
    mail_db: &tauri::State<'_, crate::mail::db::MailDb>,
    account_id: &str,
    role: &str,
) -> Result<String, String> {
    let account_id_db = account_id.to_string();
    let role_db = role.to_string();
    let name: Option<String> = mail_db
        .with_conn(move |conn| {
            if let Some(name) = conn
                .query_row(
                "SELECT name FROM folder WHERE account_id = ?1 AND role = ?2 LIMIT 1",
                rusqlite::params![account_id_db, role_db],
                |r| r.get::<_, String>(0),
                )
                .map(Some)
                .or_else(|e| match e {
                    rusqlite::Error::QueryReturnedNoRows => Ok(None),
                    other => Err(other),
                })?
            {
                return Ok(Some(name));
            }

            let candidates: &[&str] = match role_db.as_str() {
                "trash" => &["trash", "bin", "deleted", "deleted items", "deleted messages"],
                "archive" => &["archive", "all mail"],
                "sent" => &["sent", "sent mail"],
                "drafts" => &["drafts"],
                _ => &[],
            };
            let mut stmt = conn.prepare(
                "SELECT name FROM folder WHERE account_id = ?1 ORDER BY name COLLATE NOCASE",
            )?;
            let rows = stmt.query_map(rusqlite::params![account_id_db], |r| {
                r.get::<_, String>(0)
            })?;
            for row in rows {
                let name = row?;
                let lower = name.to_ascii_lowercase();
                let mut normalized = lower.as_str();
                if let Some(close) = normalized.find("]/") {
                    normalized = &normalized[close + 2..];
                }
                let leaf = normalized.rsplit('/').next().unwrap_or(normalized);
                if candidates
                    .iter()
                    .any(|candidate| normalized == *candidate || leaf == *candidate)
                {
                    return Ok(Some(name));
                }
            }
            Ok(None)
        })
        .await?;
    name.ok_or_else(|| format!("no folder with role '{role}' for this account"))
}

/// Diagnostic: returns raw flags_json + computed unread bool for the
/// most recent 20 messages in a folder. Lets us see whether the
/// problem is "flags not stored" vs "flags not interpreted".
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct DebugFlagRow {
    pub uid: u32,
    pub subject: Option<String>,
    pub flags_json: String,
    pub unread_computed: bool,
}

#[tauri::command]
pub async fn mail_debug_flags(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    folder: String,
) -> Result<Vec<DebugFlagRow>, String> {
    mail_db
        .with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT uid, subject, flags_json FROM message \
                 WHERE account_id = ?1 AND folder = ?2 \
                 ORDER BY date_received DESC LIMIT 20",
            )?;
            let rows = stmt.query_map(rusqlite::params![account_id, folder], |row| {
                let uid: i64 = row.get(0)?;
                let subject: Option<String> = row.get(1)?;
                let flags_json: String = row.get(2)?;
                let unread =
                    !flags_json.contains("Seen") && !flags_json.contains("\\Seen");
                Ok(DebugFlagRow {
                    uid: uid as u32,
                    subject,
                    flags_json,
                    unread_computed: unread,
                })
            })?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r?);
            }
            Ok(out)
        })
        .await
}

#[tauri::command]
pub async fn mail_remote_images_allow(
    mail_db: tauri::State<'_, crate::mail::db::MailDb>,
    account_id: String,
    sender_email: String,
) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp();
    mail_db
        .with_conn(move |conn| {
            conn.execute(
                "INSERT INTO remote_image_allow(account_id, sender_email, allowed_at) \
                 VALUES(?1, ?2, ?3) \
                 ON CONFLICT(account_id, sender_email) DO UPDATE SET allowed_at = excluded.allowed_at",
                rusqlite::params![account_id, sender_email, now],
            )?;
            Ok(())
        })
        .await
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
