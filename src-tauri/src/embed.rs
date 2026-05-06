//! Local text embedding via fastembed (ONNX bge-small-en-v1.5, 384 dim).
//!
//! Runs in-process — no external server. First call downloads the model
//! (~33 MB) into the user's cache dir; subsequent boots load from disk.
//! ONNX inference is sync + CPU-bound, so all calls go through
//! `spawn_blocking` to avoid pinning the tokio runtime.
//!
//! Background reembed task: walks notes whose `embedding` is null or
//! whose `embedded_at < updated_at`, batches them through the model,
//! writes results back. Keeps the vault index eventually-consistent
//! without blocking writes on the user-visible path.

use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use std::sync::Arc;
use std::time::Duration;
use surrealdb::engine::local::Db;
use surrealdb::sql::Thing;
use surrealdb::Surreal;
use tokio::sync::OnceCell;

#[allow(dead_code)]
pub const EMBED_DIM: usize = 384;

/// Singleton — ONNX session is expensive to create (~500ms cold).
static EMBEDDER: OnceCell<Arc<TextEmbedding>> = OnceCell::const_new();

async fn embedder() -> Result<Arc<TextEmbedding>, String> {
    EMBEDDER
        .get_or_try_init(|| async {
            tokio::task::spawn_blocking(|| {
                let opts = InitOptions::new(EmbeddingModel::BGESmallENV15)
                    .with_show_download_progress(true);
                TextEmbedding::try_new(opts)
                    .map(Arc::new)
                    .map_err(|e| format!("embedder init: {e}"))
            })
            .await
            .map_err(|e| format!("embedder spawn: {e}"))?
        })
        .await
        .cloned()
}

/// Embeds a batch of strings. Returns one 384-dim vector per input.
pub async fn embed_batch(texts: Vec<String>) -> Result<Vec<Vec<f32>>, String> {
    if texts.is_empty() {
        return Ok(vec![]);
    }
    let model = embedder().await?;
    tokio::task::spawn_blocking(move || {
        model
            .embed(texts, None)
            .map_err(|e| format!("embed: {e}"))
    })
    .await
    .map_err(|e| format!("embed spawn: {e}"))?
}

/// Non-blocking variant for the user-facing search path. Returns None
/// if the embedder isn't ready yet (model still downloading or init in
/// progress) so search can fall back to BM25 instantly instead of
/// hanging the Cmd+K palette behind a 30s+ first-run download.
pub async fn embed_one_if_ready(text: String) -> Option<Vec<f32>> {
    let model = EMBEDDER.get()?.clone();
    let result = tokio::task::spawn_blocking(move || model.embed(vec![text], None))
        .await
        .ok()?
        .ok()?;
    result.into_iter().next()
}

#[allow(dead_code)]
pub async fn embed_one(text: String) -> Result<Vec<f32>, String> {
    let mut out = embed_batch(vec![text]).await?;
    out.pop().ok_or_else(|| "empty embedding result".to_string())
}

/// Combines title + body into the document the embedder sees. Title
/// gets repeated to weight it higher in the resulting vector.
pub fn document_for_embedding(title: &str, body: &str) -> String {
    let trimmed_body = if body.len() > 4_000 {
        // bge-small handles 512 tokens (~2k chars). Truncating at 4k
        // chars is a safe over-approximation that still captures the
        // start of long notes — the model truncates internally anyway.
        &body[..4_000]
    } else {
        body
    };
    format!("{title}\n{title}\n{trimmed_body}")
}

#[derive(serde::Deserialize)]
struct PendingNote {
    id: Thing,
    title: String,
    body: String,
}

/// Background task: embeds notes (and touched email_thread shadows)
/// that are missing or stale. Polls every few seconds — the queue
/// stays small in practice (one new/edited note every minute or two
/// during normal use).
pub async fn run_reembed_loop(db: Arc<Surreal<Db>>) {
    // Warm the model up front so the first user write doesn't pay the
    // cold-start cost. If the download fails we just keep retrying;
    // BM25 search still works without embeddings.
    if let Err(e) = embedder().await {
        eprintln!("[embed] warmup failed (will retry): {e}");
    }

    loop {
        let n_notes = match step(&db).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("[embed] note step error: {e}");
                0
            }
        };
        let n_threads = match step_email_threads(&db).await {
            Ok(n) => n,
            Err(e) => {
                eprintln!("[embed] thread step error: {e}");
                0
            }
        };
        if n_notes + n_threads > 0 {
            // Burned through a batch — loop immediately to drain.
            continue;
        }
        tokio::time::sleep(Duration::from_secs(4)).await;
    }
}

/// Lazy-embed step for email_thread shadows. Only picks up rows the
/// user/agent has explicitly *promoted* into the graph — cold inbox
/// shadows stay out of the HNSW index entirely. Embedding input is
/// `subject + from + body[:1000]` of the latest message, sourced
/// from mail.db. mail.db lookups happen in a separate loop body to
/// avoid holding the SurrealDB query across the rusqlite blocking call.
async fn step_email_threads(db: &Surreal<Db>) -> Result<usize, String> {
    #[derive(serde::Deserialize)]
    struct PendingThread {
        id: surrealdb::sql::Thing,
        thread_id: String,
        account_id: String,
        #[allow(dead_code)]
        subject: String,
    }
    let pending: Vec<PendingThread> = db
        .query(
            "SELECT id, thread_id, account_id, subject FROM email_thread \
             WHERE promoted_at != NONE \
               AND (embedding == NONE \
                    OR embedded_at == NONE \
                    OR embedded_at < promoted_at) \
             LIMIT 8",
        )
        .await
        .map_err(|e| format!("query pending threads: {e}"))?
        .take(0)
        .map_err(|e| format!("take pending threads: {e}"))?;

    if pending.is_empty() {
        return Ok(0);
    }

    // Build the embed-input strings by reading the latest message
    // body for each thread out of mail.db. We don't hold a MailDb
    // handle here — every Tauri command opens one cheaply via the
    // shared sqlite connection pool — but we DO want a single
    // connection per batch for amortized prepare-cost, which is what
    // crate::mail::db::MailDb::open already does.
    let app_data = match dirs_app_data() {
        Some(p) => p,
        None => return Err("could not resolve app data dir".into()),
    };
    let mail_db = crate::mail::db::MailDb::open(&app_data)
        .await
        .map_err(|e| format!("open mail.db: {e}"))?;

    // Pre-collect the latest body per thread.
    let needed: Vec<(surrealdb::sql::Thing, String, String)> = pending
        .iter()
        .map(|p| (p.id.clone(), p.account_id.clone(), p.thread_id.clone()))
        .collect();
    let body_strings: Vec<(surrealdb::sql::Thing, String)> = mail_db
        .with_conn(move |conn| {
            let mut out: Vec<(surrealdb::sql::Thing, String)> = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT subject, from_name, from_addr, body_text_extracted \
                 FROM message \
                 WHERE account_id = ?1 AND thread_id = ?2 \
                 ORDER BY date_received DESC LIMIT 1",
            )?;
            for (id, acc, tid) in needed {
                let row = stmt.query_row(rusqlite::params![&acc, &tid], |r| {
                    let subject: Option<String> = r.get(0)?;
                    let from_name: Option<String> = r.get(1)?;
                    let from_addr: Option<String> = r.get(2)?;
                    let body: Option<String> = r.get(3)?;
                    Ok((subject, from_name, from_addr, body))
                });
                let (subject, from_name, from_addr, body) = match row {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let body = body.unwrap_or_default();
                let body_trim = if body.len() > 1000 { &body[..1000] } else { &body };
                let from = from_name.or(from_addr).unwrap_or_default();
                let composed = format!(
                    "{}\n{}\n{}",
                    subject.unwrap_or_default(),
                    from,
                    body_trim,
                );
                out.push((id, composed));
            }
            Ok(out)
        })
        .await
        .map_err(|e| format!("read message bodies: {e}"))?;

    if body_strings.is_empty() {
        return Ok(0);
    }

    let docs: Vec<String> = body_strings.iter().map(|(_, s)| s.clone()).collect();
    let vectors = embed_batch(docs).await?;

    let mut written = 0usize;
    for ((id, _), vec) in body_strings.into_iter().zip(vectors.into_iter()) {
        if let Err(e) = db
            .query("UPDATE $id SET embedding = $v, embedded_at = time::now()")
            .bind(("id", id.clone()))
            .bind(("v", vec))
            .await
        {
            eprintln!("[embed] update email_thread {id} failed: {e}");
            continue;
        }
        written += 1;
    }

    Ok(written)
}

fn dirs_app_data() -> Option<std::path::PathBuf> {
    // Mirrors lib.rs::run setup — Tauri's `app_data_dir` resolves to
    // ~/Library/Application Support/com.clome.app on macOS. We
    // don't have an AppHandle here, so we reconstruct the path
    // directly. The schema migration runs at boot from the proper
    // tauri path, so this is read-only territory here.
    let home = std::env::var_os("HOME")?;
    let mut p = std::path::PathBuf::from(home);
    p.push("Library/Application Support/com.clome.app");
    Some(p)
}

async fn step(db: &Surreal<Db>) -> Result<usize, String> {
    // Pick up to 16 notes whose embedding is missing or stale (body has
    // been edited since the last embed). Batched embedding is much
    // cheaper than one-at-a-time for the ONNX model.
    let pending: Vec<PendingNote> = db
        .query(
            "SELECT id, title, body FROM note \
             WHERE embedding == NONE \
                OR embedded_at == NONE \
                OR embedded_at < updated_at \
             LIMIT 16",
        )
        .await
        .map_err(|e| format!("query pending: {e}"))?
        .take(0)
        .map_err(|e| format!("take pending: {e}"))?;

    if pending.is_empty() {
        return Ok(0);
    }

    let docs: Vec<String> = pending
        .iter()
        .map(|n| document_for_embedding(&n.title, &n.body))
        .collect();
    let vectors = embed_batch(docs).await?;

    for (note, vec) in pending.iter().zip(vectors.into_iter()) {
        // UPDATE merges only the listed fields; keeps other state intact.
        if let Err(e) = db
            .query("UPDATE $id SET embedding = $v, embedded_at = time::now()")
            .bind(("id", note.id.clone()))
            .bind(("v", vec))
            .await
        {
            eprintln!("[embed] update {} failed: {}", note.id, e);
        }
    }

    Ok(pending.len())
}
