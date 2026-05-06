use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use surrealdb::engine::local::{Db, SurrealKv};
use surrealdb::sql::Thing;
use surrealdb::Surreal;

const SCHEMA: &str = r#"
-- Drop the Day-4 auto-extracted entity table. Vault model uses notes now (§7).
REMOVE TABLE IF EXISTS entity;

DEFINE TABLE IF NOT EXISTS workspace SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS name ON workspace TYPE string;
DEFINE FIELD IF NOT EXISTS created_at ON workspace TYPE datetime DEFAULT time::now();

DEFINE TABLE IF NOT EXISTS agent SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS name ON agent TYPE string;
DEFINE FIELD IF NOT EXISTS system_prompt ON agent TYPE string;
DEFINE FIELD IF NOT EXISTS model ON agent TYPE string;
DEFINE FIELD IF NOT EXISTS workspace ON agent TYPE record<workspace>;
DEFINE FIELD IF NOT EXISTS capabilities ON agent TYPE array<string> DEFAULT [];

DEFINE TABLE IF NOT EXISTS chat SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS title ON chat TYPE string;
DEFINE FIELD IF NOT EXISTS workspace ON chat TYPE record<workspace>;
DEFINE FIELD IF NOT EXISTS created_at ON chat TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS agent ON chat TYPE option<record<agent>>;
-- Group chats: chat can have N agents. Replies routed via @-mention
-- in the composer; first bound agent is the implicit default for
-- non-mentioned messages (preserves single-agent UX when N=1).
DEFINE FIELD IF NOT EXISTS agents ON chat TYPE array<record<agent>> DEFAULT [];
-- Idempotent migration backfilling existing rows. DEFAULT [] only
-- applies on INSERT, so chats created before this field exist as
-- `agents == NONE`. Step 1 normalizes NONE → []; step 2 then safely
-- calls array::len on the result. Re-runs on every boot are no-ops.
UPDATE chat SET agents = [] WHERE agents == NONE;
UPDATE chat SET agents = [agent] WHERE agent != NONE AND array::len(agents) == 0;

DEFINE TABLE IF NOT EXISTS message SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS chat ON message TYPE record<chat>;
DEFINE FIELD IF NOT EXISTS role ON message TYPE string;
DEFINE FIELD IF NOT EXISTS content ON message TYPE string;
DEFINE FIELD IF NOT EXISTS created_at ON message TYPE datetime DEFAULT time::now();
-- Per-tool-call results captured during the agent turn ({index, action,
-- headers, result}). FLEXIBLE so nested `result` shape (mail list, event
-- list, file read, etc.) round-trips without an inner schema. Without
-- this definition SurrealDB silently drops the column on SCHEMAFULL
-- tables — which is what made rich tool cards (calendar, email, etc.)
-- vanish from chat the moment the bubble re-hydrated from disk.
DEFINE FIELD IF NOT EXISTS tool_results ON message FLEXIBLE TYPE option<array>;

-- Folders are flat single-membership groupings of notes within a
-- workspace. Names are unique per workspace. Deleting a folder
-- unassigns its notes (sets `note.folder` back to NONE) — never
-- destroys content.
DEFINE TABLE IF NOT EXISTS folder SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS name ON folder TYPE string;
DEFINE FIELD IF NOT EXISTS workspace ON folder TYPE record<workspace>;
DEFINE FIELD IF NOT EXISTS color ON folder TYPE option<string>;
DEFINE FIELD IF NOT EXISTS created_at ON folder TYPE datetime DEFAULT time::now();
DEFINE INDEX IF NOT EXISTS folder_unique_name ON folder FIELDS name, workspace UNIQUE;

DEFINE TABLE IF NOT EXISTS note SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS title ON note TYPE string;
DEFINE FIELD IF NOT EXISTS body ON note TYPE string DEFAULT '';
DEFINE FIELD IF NOT EXISTS source_kind ON note TYPE string DEFAULT 'manual';
DEFINE FIELD IF NOT EXISTS source_url ON note TYPE option<string>;
DEFINE FIELD IF NOT EXISTS source_meta ON note TYPE option<object>;
DEFINE FIELD IF NOT EXISTS workspace ON note TYPE record<workspace>;
-- Optional folder membership. NONE = unfiled (top-level / "Notes").
DEFINE FIELD IF NOT EXISTS folder ON note TYPE option<record<folder>>;
DEFINE FIELD IF NOT EXISTS last_edited_by ON note TYPE string DEFAULT 'user';
DEFINE FIELD IF NOT EXISTS created_at ON note TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS updated_at ON note TYPE datetime DEFAULT time::now();
-- Semantic half of the hybrid @-mention oracle. Populated by the
-- embedder background task whenever title/body changes; nullable so
-- newly-written notes don't block on the embed (BM25 still works
-- immediately, cosine kicks in once the embedding lands).
DEFINE FIELD IF NOT EXISTS embedding ON note TYPE option<array<float>>;
DEFINE FIELD IF NOT EXISTS embedded_at ON note TYPE option<datetime>;
DEFINE INDEX IF NOT EXISTS note_unique_title ON note FIELDS title, workspace UNIQUE;
-- HNSW vector index. 384 dims = bge-small-en-v1.5. Cosine matches
-- the cosine-similarity score we expose to the hybrid scorer.
DEFINE INDEX IF NOT EXISTS note_embedding_hnsw ON note FIELDS embedding HNSW DIMENSION 384 DIST COSINE TYPE F32 EFC 150 M 24;

-- Polymorphic edge table. Replaces the note-only `link` table; the
-- migration runner (`migrate_link_to_edge`) copies any pre-existing
-- `link` rows here on first boot and removes the old table. `from_node`
-- and `to_node` are unrestricted records so a single edge layer
-- connects any node kind to any other (notes, future email_thread /
-- event / project / etc.). `kind` is constrained to a small enum;
-- adding a new edge kind is a deliberate schema change.
DEFINE TABLE IF NOT EXISTS edge SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS from_node ON edge TYPE record;
DEFINE FIELD IF NOT EXISTS to_node ON edge TYPE record;
DEFINE FIELD IF NOT EXISTS kind ON edge TYPE string ASSERT $value IN [
    "mentions","references","about","attended","attached",
    "derived_from","replied_to","child_of","alias_of"
];
DEFINE FIELD IF NOT EXISTS context ON edge TYPE option<string>;
DEFINE FIELD IF NOT EXISTS workspace ON edge TYPE option<record<workspace>>;
DEFINE FIELD IF NOT EXISTS created_by ON edge TYPE string DEFAULT 'user';
DEFINE FIELD IF NOT EXISTS created_at ON edge TYPE datetime DEFAULT time::now();
DEFINE INDEX IF NOT EXISTS edge_no_dup ON edge FIELDS from_node, to_node, kind UNIQUE;
DEFINE INDEX IF NOT EXISTS edge_from ON edge FIELDS from_node;
DEFINE INDEX IF NOT EXISTS edge_to ON edge FIELDS to_node;

-- Cursor / status rows for graph background tasks (link migration,
-- wikilink rescan). One row per key.
DEFINE TABLE IF NOT EXISTS graph_meta SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS key ON graph_meta TYPE string;
DEFINE FIELD IF NOT EXISTS value ON graph_meta TYPE string;
DEFINE INDEX IF NOT EXISTS graph_meta_unique ON graph_meta FIELDS key UNIQUE;

-- Audit log for graph mutations (mirrors note_edit). Every relate /
-- unrelate / merge appends a row so the user can review what an agent
-- changed and roll it back.
DEFINE TABLE IF NOT EXISTS graph_edit SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS by ON graph_edit TYPE string;
DEFINE FIELD IF NOT EXISTS ts ON graph_edit TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS action ON graph_edit TYPE string;
DEFINE FIELD IF NOT EXISTS payload ON graph_edit TYPE string;

DEFINE TABLE IF NOT EXISTS note_edit SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS note ON note_edit TYPE record<note>;
DEFINE FIELD IF NOT EXISTS by ON note_edit TYPE string;
DEFINE FIELD IF NOT EXISTS ts ON note_edit TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS diff ON note_edit TYPE string;

-- ── Full-text search (BM25) ──────────────────────────────────────
DEFINE ANALYZER IF NOT EXISTS clome_text TOKENIZERS class FILTERS lowercase, ascii;
DEFINE INDEX IF NOT EXISTS note_title_search ON note FIELDS title SEARCH ANALYZER clome_text BM25;
DEFINE INDEX IF NOT EXISTS note_body_search ON note FIELDS body SEARCH ANALYZER clome_text BM25;
DEFINE INDEX IF NOT EXISTS message_content_search ON message FIELDS content SEARCH ANALYZER clome_text BM25;

-- ── Email threads (graph shadow of mail.db) ─────────────────────
-- Each row mirrors a JWZ-clustered conversation tracked in mail.db.
-- We don't duplicate message bodies — those stay in mail.db / on disk.
-- This shadow exists so the polymorphic edge layer can reference
-- threads as first-class graph nodes alongside notes, and so the
-- agent's `graph_search` can hit email content via subject/sender/body
-- via the same hybrid retrieval path notes use.
--
-- `touched_at` gates lazy embedding: a thread becomes a candidate for
-- the background embed loop only after the user has opened or replied
-- to it (or it's been [[wikilinked]] in the future). Cold mail stays
-- on BM25 only and never bloats HNSW.
DEFINE TABLE IF NOT EXISTS email_thread SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS thread_id ON email_thread TYPE string;
DEFINE FIELD IF NOT EXISTS account_id ON email_thread TYPE string;
DEFINE FIELD IF NOT EXISTS subject ON email_thread TYPE string DEFAULT '';
DEFINE FIELD IF NOT EXISTS from_addr ON email_thread TYPE option<string>;
DEFINE FIELD IF NOT EXISTS from_name ON email_thread TYPE option<string>;
DEFINE FIELD IF NOT EXISTS last_date ON email_thread TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS message_count ON email_thread TYPE int DEFAULT 0;
DEFINE FIELD IF NOT EXISTS workspace ON email_thread TYPE record<workspace>;
DEFINE FIELD IF NOT EXISTS embedding ON email_thread TYPE option<array<float>>;
DEFINE FIELD IF NOT EXISTS embedded_at ON email_thread TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS touched_at ON email_thread TYPE option<datetime>;
-- `promoted_at != NONE` is the "this thread lives in the graph" gate.
-- Mail sync always upserts shadow rows for cheap lookup, but the
-- canvas, agent search, and edges treat unpromoted threads as
-- invisible. The user (or agent) explicitly promotes via the
-- promote_email_thread path; `graph::relate` auto-promotes when an
-- edge is created with an email_thread endpoint.
DEFINE FIELD IF NOT EXISTS promoted_at ON email_thread TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS created_at ON email_thread TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS updated_at ON email_thread TYPE datetime DEFAULT time::now();
DEFINE INDEX IF NOT EXISTS email_thread_unique ON email_thread FIELDS thread_id, account_id UNIQUE;
DEFINE INDEX IF NOT EXISTS email_thread_subject_search ON email_thread FIELDS subject SEARCH ANALYZER clome_text BM25;
DEFINE INDEX IF NOT EXISTS email_thread_embedding_hnsw ON email_thread FIELDS embedding HNSW DIMENSION 384 DIST COSINE TYPE F32 EFC 150 M 24;

-- ── Email accounts (mail client, Phase 1) ────────────────────────
-- The authoritative account row. Tokens are NOT stored here — only the
-- opaque `keychain_ref` pointing at a kSecClassGenericPassword item
-- under service "com.clome.app.mail". Unique on email so `Add account`
-- can't silently double-add the same address.
DEFINE TABLE IF NOT EXISTS email_account SCHEMAFULL;
DEFINE FIELD IF NOT EXISTS email ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS display_name ON email_account TYPE option<string>;
DEFINE FIELD IF NOT EXISTS provider ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS imap_host ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS imap_port ON email_account TYPE int;
DEFINE FIELD IF NOT EXISTS imap_security ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS smtp_host ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS smtp_port ON email_account TYPE int;
DEFINE FIELD IF NOT EXISTS smtp_security ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS keychain_ref ON email_account TYPE string;
DEFINE FIELD IF NOT EXISTS has_refresh_token ON email_account TYPE bool DEFAULT false;
DEFINE FIELD IF NOT EXISTS signature ON email_account TYPE option<string>;
DEFINE FIELD IF NOT EXISTS notify_enabled ON email_account TYPE bool DEFAULT true;
DEFINE FIELD IF NOT EXISTS attachment_auto_dl_max_mb ON email_account TYPE int DEFAULT 0;
DEFINE FIELD IF NOT EXISTS created_at ON email_account TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS last_sync_at ON email_account TYPE option<datetime>;
DEFINE INDEX IF NOT EXISTS email_account_email_unique ON email_account FIELDS email UNIQUE;
"#;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Note {
    pub id: Thing,
    pub title: String,
    pub body: String,
    pub source_kind: String,
    pub source_url: Option<String>,
    pub last_edited_by: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    /// Optional folder membership. NONE in the DB → None here. UI groups
    /// notes whose `folder` is None under "Unfiled".
    #[serde(default)]
    pub folder: Option<Thing>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Folder {
    pub id: Thing,
    pub name: String,
    pub color: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct EmailThread {
    pub id: Thing,
    pub thread_id: String,
    pub account_id: String,
    pub subject: String,
    pub from_addr: Option<String>,
    pub from_name: Option<String>,
    pub last_date: DateTime<Utc>,
    pub message_count: i64,
    #[serde(default)]
    pub touched_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub promoted_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
}

/// Aggregate values used to upsert an email_thread shadow row. The
/// caller (mail sync hook) computes these from the message table in
/// mail.db and hands them to `upsert_email_thread`.
#[derive(Clone, Debug)]
pub struct EmailThreadAggregate {
    pub thread_id: String,
    pub account_id: String,
    pub subject: String,
    pub from_addr: Option<String>,
    pub from_name: Option<String>,
    pub last_date: DateTime<Utc>,
    pub message_count: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Workspace {
    pub id: Thing,
    pub name: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Agent {
    pub id: Thing,
    pub name: String,
    pub system_prompt: String,
    pub model: String,
    #[serde(default, deserialize_with = "null_or_seq_to_vec")]
    pub capabilities: Vec<String>,
}

/// Serde helper: SurrealDB rows written before the `capabilities` field
/// existed (or rows where the column is NULL for any reason) deserialize
/// the field as a JSON null. `#[serde(default)]` alone doesn't catch
/// that — null is a present-but-null value, not a missing field. This
/// turns null → empty vec.
fn null_or_seq_to_vec<'de, D, T>(de: D) -> Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Option::<Vec<T>>::deserialize(de).map(|opt| opt.unwrap_or_default())
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Chat {
    pub id: Thing,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub agent: Option<Thing>,
    // Group-chat support: list of bound agents. Migration in SCHEMA
    // backfills this from `agent` on first boot. Default empty preserves
    // serde when an old DB row predates the field.
    #[serde(default)]
    pub agents: Vec<Thing>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Message {
    pub id: Thing,
    pub role: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub tool_results: Option<Vec<serde_json::Value>>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct NoteRef {
    pub title: String,
    pub source_kind: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct MessageRef {
    pub role: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct NoteEdit {
    pub by: String,
    pub ts: DateTime<Utc>,
    pub diff: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct InspectorData {
    pub note: Note,
    pub backlinks_notes: Vec<NoteRef>,
    pub backlinks_messages: Vec<MessageRef>,
    pub edits: Vec<NoteEdit>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct NoteSearchHit {
    pub title: String,
    pub source_kind: String,
    pub snippet: String,
    pub title_hit: bool,
    /// True when the hit only came from cosine similarity, not BM25.
    /// Lets the UI badge "semantic match" so the user understands why
    /// a note appears even though their query string isn't in it.
    #[serde(default)]
    pub semantic_only: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct MessageSearchHit {
    pub message_id: Thing,
    pub chat_id: Thing,
    pub chat_title: Option<String>,
    pub role: String,
    pub snippet: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize, Clone, Debug)]
pub struct SearchResults {
    pub notes: Vec<NoteSearchHit>,
    pub messages: Vec<MessageSearchHit>,
}

pub async fn open(data_dir: PathBuf) -> Result<Surreal<Db>, surrealdb::Error> {
    std::fs::create_dir_all(&data_dir).ok();
    let path = data_dir.join("clome.db");
    let db = Surreal::new::<SurrealKv>(path.to_string_lossy().to_string()).await?;
    db.use_ns("clome").use_db("default").await?;
    db.query(SCHEMA).await?.check()?;
    seed_defaults(&db).await?;
    migrate_link_to_edge(&db).await?;
    Ok(db)
}

/// One-shot migration: copy any pre-existing `link` rows into the new
/// polymorphic `edge` table (kind = "references"), then remove the
/// `link` table itself. Idempotent — the marker row in `graph_meta`
/// makes subsequent boots no-ops; the table-removal step is also safe
/// when `link` is already gone.
async fn migrate_link_to_edge(db: &Surreal<Db>) -> Result<(), surrealdb::Error> {
    // `value` is a reserved Surreal keyword, so we project the id and
    // ignore the field — existence of the row is the marker.
    let done: Option<Thing> = db
        .query("SELECT VALUE id FROM graph_meta WHERE key = 'link_migration' LIMIT 1")
        .await?
        .take(0)?;
    if done.is_some() {
        return Ok(());
    }

    // Copy rows. INSERT skips on duplicate (edge_no_dup unique index)
    // so a partial prior run is recoverable. We pull rows via SELECT
    // first instead of an INSERT … SELECT so we can survive the case
    // where `link` has already been removed (table missing).
    #[derive(Deserialize)]
    struct LinkRow {
        from_note: Thing,
        to_note: Thing,
        context: Option<String>,
    }
    let rows: Vec<LinkRow> = db
        .query("SELECT from_note, to_note, context FROM link")
        .await
        .ok()
        .and_then(|mut r| r.take::<Vec<LinkRow>>(0).ok())
        .unwrap_or_default();
    for row in rows {
        let _ = db
            .query(
                "CREATE edge SET \
                    from_node = $from, \
                    to_node = $to, \
                    kind = 'references', \
                    context = $ctx, \
                    created_by = 'migration'",
            )
            .bind(("from", row.from_note))
            .bind(("to", row.to_note))
            .bind(("ctx", row.context))
            .await;
    }

    // Drop the old table and mark migration done in one pass.
    db.query(
        "REMOVE TABLE IF EXISTS link; \
         CREATE graph_meta SET key = 'link_migration', value = 'done';",
    )
    .await?
    .check()?;
    Ok(())
}

#[derive(Deserialize)]
struct IdOnly {
    #[allow(dead_code)]
    id: Thing,
}

async fn seed_defaults(db: &Surreal<Db>) -> Result<(), surrealdb::Error> {
    let existing: Option<IdOnly> = db
        .query("SELECT id FROM workspace:default")
        .await?
        .take(0)?;
    if existing.is_none() {
        db.query(
            r#"
        CREATE workspace:default SET name = 'default';
        CREATE chat:main SET title = 'main', workspace = workspace:default;
        CREATE agent:generalist SET
            name = 'Generalist',
            system_prompt = 'You are Clome generalist agent. Concise. No filler.',
            model = 'mlx-community/gemma-3-4b-it-4bit',
            capabilities = ['email.read', 'calendar.read', 'reminders.read', 'filesystem.read'],
            workspace = workspace:default;
        CREATE agent:calendar SET
            name = 'Calendar',
            system_prompt = 'You manage the user calendar. Read events, suggest slots.',
            model = 'mlx-community/gemma-3-4b-it-4bit',
            capabilities = ['calendar.read', 'calendar.write', 'reminders.read', 'reminders.write'],
            workspace = workspace:default;
        CREATE agent:email SET
            name = 'Email',
            system_prompt = 'You manage email. Read threads, draft replies.',
            model = 'mlx-community/gemma-3-4b-it-4bit',
            capabilities = ['email.read'],
            workspace = workspace:default;
        "#,
        )
        .await?
        .check()?;
    }
    ensure_seed_agent_capabilities(db).await?;
    Ok(())
}

async fn ensure_seed_agent_capabilities(db: &Surreal<Db>) -> Result<(), surrealdb::Error> {
    // Add any missing capabilities to the named seed agent. Idempotent;
    // never strips a capability the user added on top.
    async fn ensure(
        db: &Surreal<Db>,
        agent_thing: &str,
        wanted: &[&str],
    ) -> Result<(), surrealdb::Error> {
        let row: Option<Agent> = db
            .query(format!(
                "SELECT id, name, system_prompt, model, capabilities FROM {agent_thing}"
            ))
            .await?
            .take(0)?;
        let Some(agent) = row else {
            return Ok(());
        };
        let mut caps = agent.capabilities.clone();
        let mut changed = false;
        for cap in wanted {
            if !caps.iter().any(|c| c == cap) {
                caps.push((*cap).to_string());
                changed = true;
            }
        }
        if changed {
            db.query(format!("UPDATE {agent_thing} SET capabilities = $caps"))
                .bind(("caps", caps))
                .await?
                .check()?;
        }
        Ok(())
    }

    // Generalist is the catch-all chat agent — give it every read
    // capability so the user doesn't hit "I don't have access to X"
    // for ordinary questions ("what emails today?", "any meetings?").
    // The user can prune via Manage agents if they want a stricter
    // surface; we never strip below this baseline.
    ensure(
        db,
        "agent:generalist",
        &["email.read", "calendar.read", "reminders.read", "filesystem.read"],
    )
    .await?;
    ensure(db, "agent:email", &["email.read"]).await?;
    ensure(
        db,
        "agent:calendar",
        &["calendar.read", "calendar.write", "reminders.read", "reminders.write"],
    )
    .await?;
    Ok(())
}

pub async fn save_message(
    db: &Surreal<Db>,
    chat_id: &Thing,
    role: &str,
    content: &str,
) -> Result<(), surrealdb::Error> {
    save_message_with_tool_results(db, chat_id, role, content, None).await
}

pub async fn save_message_with_tool_results(
    db: &Surreal<Db>,
    chat_id: &Thing,
    role: &str,
    content: &str,
    tool_results: Option<Vec<serde_json::Value>>,
) -> Result<(), surrealdb::Error> {
    db.query(
        "CREATE message SET chat = $chat, role = $role, content = $content, tool_results = $tool_results",
    )
        .bind(("chat", chat_id.clone()))
        .bind(("role", role.to_string()))
        .bind(("content", content.to_string()))
        .bind(("tool_results", tool_results))
        .await?
        .check()?;

    // Wikilink mentions in chat content become edges from the chat
    // record to each referenced note. Resolve the chat's workspace
    // first; if the chat is somehow orphaned we skip silently rather
    // than failing the message save.
    #[derive(Deserialize)]
    struct WsOnly {
        workspace: Thing,
    }
    let row: Option<WsOnly> = db
        .query("SELECT workspace FROM $chat LIMIT 1")
        .bind(("chat", chat_id.clone()))
        .await?
        .take(0)?;
    if let Some(WsOnly { workspace }) = row {
        let by = format!("chat:{role}");
        let _ = sync_wikilinks_for_chat_message(db, &workspace, chat_id, content, &by).await;
    }
    Ok(())
}

pub async fn list_chats(
    db: &Surreal<Db>,
    workspace_id: &Thing,
) -> Result<Vec<Chat>, surrealdb::Error> {
    let chats: Vec<Chat> = db
        .query(
            "SELECT id, title, created_at, agent, agents FROM chat \
             WHERE workspace = $ws ORDER BY created_at ASC LIMIT 200",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    Ok(chats)
}

pub async fn create_chat(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
) -> Result<Option<Chat>, surrealdb::Error> {
    let created: Vec<Chat> = db
        .query("CREATE chat SET title = $title, workspace = $ws")
        .bind(("ws", workspace_id.clone()))
        .bind(("title", title.to_string()))
        .await?
        .take(0)?;
    Ok(created.into_iter().next())
}

pub async fn rename_chat(
    db: &Surreal<Db>,
    id: &Thing,
    title: &str,
) -> Result<(), surrealdb::Error> {
    db.query("UPDATE $id SET title = $title")
        .bind(("id", id.clone()))
        .bind(("title", title.to_string()))
        .await?
        .check()?;
    Ok(())
}

pub async fn delete_chat(db: &Surreal<Db>, id: &Thing) -> Result<(), surrealdb::Error> {
    db.query("DELETE message WHERE chat = $id; DELETE $id;")
        .bind(("id", id.clone()))
        .await?
        .check()?;
    Ok(())
}

pub async fn list_messages(
    db: &Surreal<Db>,
    chat_id: &Thing,
) -> Result<Vec<Message>, surrealdb::Error> {
    let msgs: Vec<Message> = db
        .query(
            "SELECT id, role, content, created_at, tool_results FROM message \
             WHERE chat = $chat ORDER BY created_at ASC LIMIT 2000",
        )
        .bind(("chat", chat_id.clone()))
        .await?
        .take(0)?;
    Ok(msgs)
}

pub async fn list_notes(
    db: &Surreal<Db>,
    workspace_id: &Thing,
) -> Result<Vec<Note>, surrealdb::Error> {
    // Spec §11 Tier 1 success criterion: @-mention autocomplete must
    // return relevant notes <100ms over 1000+ notes. Sidebar + mention
    // oracle both consume this list. The previous 200-row cap silently
    // truncated both at note 201.
    //
    // 5000 fits comfortably in IPC/memory (~2.5 MB JSON at 500-byte
    // bodies) and covers any single-user vault for the foreseeable
    // future. If we ever cross this, the right fix is a dedicated
    // server-side title-only search command for the mention oracle —
    // not a higher cap here.
    let notes: Vec<Note> = db
        .query(
            "SELECT * FROM note WHERE workspace = $ws \
             ORDER BY updated_at DESC LIMIT 5000",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    Ok(notes)
}

/// Idempotent: if a note with the same title exists in `workspace_id`,
/// return it. Otherwise create + log a `note_edit`.
pub async fn create_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
    body: &str,
    source_kind: &str,
    last_edited_by: &str,
) -> Result<Option<Note>, surrealdb::Error> {
    let existing: Option<Note> = db
        .query("SELECT * FROM note WHERE title = $title AND workspace = $ws LIMIT 1")
        .bind(("ws", workspace_id.clone()))
        .bind(("title", title.to_string()))
        .await?
        .take(0)?;
    if let Some(note) = existing {
        return Ok(Some(note));
    }

    let created: Vec<Note> = db
        .query(
            "CREATE note SET \
                title = $title, \
                body = $body, \
                source_kind = $source_kind, \
                workspace = $ws, \
                last_edited_by = $by, \
                updated_at = time::now()",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("title", title.to_string()))
        .bind(("body", body.to_string()))
        .bind(("source_kind", source_kind.to_string()))
        .bind(("by", last_edited_by.to_string()))
        .await?
        .take(0)?;

    let note = created.into_iter().next();
    if let Some(n) = &note {
        let _ = db
            .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
            .bind(("note", n.id.clone()))
            .bind(("by", last_edited_by.to_string()))
            .bind(("diff", format!("created with title \"{}\"", title)))
            .await;
        if !body.is_empty() {
            let _ = sync_wikilinks_for_note(
                db,
                workspace_id,
                title,
                &n.id,
                body,
                last_edited_by,
            )
            .await;
        }
    }
    Ok(note)
}

pub async fn get_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
) -> Result<Option<Note>, surrealdb::Error> {
    let note: Option<Note> = db
        .query("SELECT * FROM note WHERE title = $title AND workspace = $ws LIMIT 1")
        .bind(("ws", workspace_id.clone()))
        .bind(("title", title.to_string()))
        .await?
        .take(0)?;
    Ok(note)
}

pub async fn update_note_body(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
    body: &str,
    last_edited_by: &str,
) -> Result<Option<Note>, surrealdb::Error> {
    let Some(existing) = get_note(db, workspace_id, title).await? else {
        return Ok(None);
    };
    let old_len = existing.body.chars().count();
    let new_len = body.chars().count();

    let updated: Vec<Note> = db
        .query(
            "UPDATE $id SET body = $body, last_edited_by = $by, updated_at = time::now()",
        )
        .bind(("id", existing.id.clone()))
        .bind(("body", body.to_string()))
        .bind(("by", last_edited_by.to_string()))
        .await?
        .take(0)?;

    let diff = format!("body edited by {by} ({old} → {new} chars)",
        by = last_edited_by, old = old_len, new = new_len);
    let _ = db
        .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
        .bind(("note", existing.id.clone()))
        .bind(("by", last_edited_by.to_string()))
        .bind(("diff", diff))
        .await;
    let _ = sync_wikilinks_for_note(
        db,
        workspace_id,
        title,
        &existing.id,
        body,
        last_edited_by,
    )
    .await;

    Ok(updated.into_iter().next())
}

pub async fn inspect_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
) -> Result<Option<InspectorData>, surrealdb::Error> {
    let Some(note) = get_note(db, workspace_id, title).await? else {
        return Ok(None);
    };
    let needle = format!("[[{}]]", title);

    let backlinks_notes: Vec<NoteRef> = db
        .query(
            "SELECT title, source_kind, updated_at FROM note \
             WHERE workspace = $ws \
               AND title != $self_title \
               AND string::contains(body, $needle) \
             ORDER BY updated_at DESC LIMIT 30",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("self_title", title.to_string()))
        .bind(("needle", needle.clone()))
        .await?
        .take(0)?;

    // Backlinks across messages: scope to chats in this workspace via the
    // chat record link.
    let backlinks_messages: Vec<MessageRef> = db
        .query(
            "SELECT role, content, created_at FROM message \
             WHERE chat.workspace = $ws \
               AND string::contains(content, $needle) \
             ORDER BY created_at DESC LIMIT 30",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("needle", needle))
        .await?
        .take(0)?;

    let edits: Vec<NoteEdit> = db
        .query(
            "SELECT by, ts, diff FROM note_edit WHERE note = $note ORDER BY ts DESC LIMIT 30",
        )
        .bind(("note", note.id.clone()))
        .await?
        .take(0)?;

    Ok(Some(InspectorData {
        note,
        backlinks_notes,
        backlinks_messages,
        edits,
    }))
}

pub fn extract_wikilink_titles(text: &str) -> Vec<String> {
    let mut titles = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find("[[") {
        let after = &rest[start + 2..];
        let Some(end) = after.find("]]") else { break };
        let inner = after[..end].trim();
        if !inner.is_empty() && !inner.contains('[') && !inner.contains(']') {
            titles.push(inner.to_string());
        }
        rest = &after[end + 2..];
    }
    titles.sort();
    titles.dedup();
    titles
}

/// Idempotent stub-creation for wikilink targets that don't exist yet.
/// Skips the full `create_note` path on purpose — those auto-created
/// stubs always have empty bodies, so there's no further wikilink
/// sync to do, and avoiding the recursion keeps the type system happy
/// (mutual `async fn` recursion would need explicit boxing otherwise).
pub async fn ensure_notes_exist(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    titles: &[String],
    by: &str,
) -> Result<(), surrealdb::Error> {
    for title in titles {
        let existing: Option<Thing> = db
            .query("SELECT VALUE id FROM note WHERE title = $title AND workspace = $ws LIMIT 1")
            .bind(("ws", workspace_id.clone()))
            .bind(("title", title.clone()))
            .await?
            .take(0)?;
        if existing.is_some() {
            continue;
        }
        let created: Vec<Note> = db
            .query(
                "CREATE note SET \
                    title = $title, \
                    body = '', \
                    source_kind = 'manual', \
                    workspace = $ws, \
                    last_edited_by = $by",
            )
            .bind(("ws", workspace_id.clone()))
            .bind(("title", title.clone()))
            .bind(("by", by.to_string()))
            .await?
            .take(0)?;
        if let Some(n) = created.first() {
            let _ = db
                .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
                .bind(("note", n.id.clone()))
                .bind(("by", by.to_string()))
                .bind(("diff", format!("auto-created by wikilink \"[[{title}]]\"")))
                .await;
        }
    }
    Ok(())
}

pub async fn append_to_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
    content: &str,
    by: &str,
) -> Result<Option<Note>, surrealdb::Error> {
    let Some(existing) = get_note(db, workspace_id, title).await? else {
        return Ok(None);
    };
    let new_body = if existing.body.trim().is_empty() {
        content.to_string()
    } else {
        format!("{}\n\n{}", existing.body, content)
    };
    let appended_chars = content.chars().count();

    let updated: Vec<Note> = db
        .query(
            "UPDATE $id SET body = $body, last_edited_by = $by, updated_at = time::now()",
        )
        .bind(("id", existing.id.clone()))
        .bind(("body", new_body))
        .bind(("by", by.to_string()))
        .await?
        .take(0)?;

    let _ = db
        .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
        .bind(("note", existing.id.clone()))
        .bind(("by", by.to_string()))
        .bind(("diff", format!("appended {appended_chars} chars by {by}")))
        .await;
    if let Some(updated_note) = updated.first() {
        let _ = sync_wikilinks_for_note(
            db,
            workspace_id,
            title,
            &existing.id,
            &updated_note.body,
            by,
        )
        .await;
    }

    Ok(updated.into_iter().next())
}

pub async fn rename_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    old_title: &str,
    new_title: &str,
    by: &str,
) -> Result<Option<Note>, surrealdb::Error> {
    let Some(existing) = get_note(db, workspace_id, old_title).await? else {
        return Ok(None);
    };
    // Update the row itself.
    let updated: Vec<Note> = db
        .query(
            "UPDATE $id SET title = $new, last_edited_by = $by, updated_at = time::now()",
        )
        .bind(("id", existing.id.clone()))
        .bind(("new", new_title.to_string()))
        .bind(("by", by.to_string()))
        .await?
        .take(0)?;

    // Rewrite [[old]] → [[new]] in every other note's body and every chat
    // message in this workspace so wikilinks keep resolving after the rename.
    let old_link = format!("[[{}]]", old_title);
    let new_link = format!("[[{}]]", new_title);
    let _ = db
        .query(
            "UPDATE note SET body = string::replace(body, $old, $new) \
             WHERE workspace = $ws AND string::contains(body, $old)",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("old", old_link.clone()))
        .bind(("new", new_link.clone()))
        .await;
    let _ = db
        .query(
            "UPDATE message SET content = string::replace(content, $old, $new) \
             WHERE chat.workspace = $ws AND string::contains(content, $old)",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("old", old_link))
        .bind(("new", new_link))
        .await;

    // Audit row.
    let diff = format!("renamed from \"{}\" to \"{}\"", old_title, new_title);
    let _ = db
        .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
        .bind(("note", existing.id))
        .bind(("by", by.to_string()))
        .bind(("diff", diff))
        .await;

    Ok(updated.into_iter().next())
}

pub async fn delete_note_by_title(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
) -> Result<bool, surrealdb::Error> {
    let Some(note) = get_note(db, workspace_id, title).await? else {
        return Ok(false);
    };
    db.query(
        "DELETE note_edit WHERE note = $id; \
         DELETE edge WHERE from_node = $id OR to_node = $id; \
         DELETE $id;",
    )
    .bind(("id", note.id))
    .await?
    .check()?;
    Ok(true)
}

/// Title-keyed convenience over `graph::relate` — agents use note
/// titles, not record ids, so this resolves both endpoints and writes
/// the edge through the polymorphic graph layer. Auto-creates either
/// endpoint if missing (matches the @-mention "create on click" rule).
pub async fn relate_notes(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    from_title: &str,
    to_title: &str,
    kind: &str,
    context: Option<&str>,
    by: &str,
) -> Result<(), surrealdb::Error> {
    let from = match get_note(db, workspace_id, from_title).await? {
        Some(n) => n,
        None => match create_note(db, workspace_id, from_title, "", "manual", by).await? {
            Some(n) => n,
            None => return Ok(()),
        },
    };
    let to = match get_note(db, workspace_id, to_title).await? {
        Some(n) => n,
        None => match create_note(db, workspace_id, to_title, "", "manual", by).await? {
            Some(n) => n,
            None => return Ok(()),
        },
    };

    crate::graph::relate(db, Some(workspace_id), &from.id, &to.id, kind, context, by).await?;

    let diff = match kind {
        "mentions" => format!("mentions → [[{to_title}]]"),
        other => format!("{other} → [[{to_title}]]"),
    };
    let _ = db
        .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
        .bind(("note", from.id))
        .bind(("by", by.to_string()))
        .bind(("diff", diff))
        .await;
    Ok(())
}

/// Surgical edit: replace `old_string` with `new_string` in the note's
/// body. Returns `Err(EditNoteError::NotFound)` if the note doesn't
/// exist, `EditNoteError::NoMatch` if `old_string` isn't in the body,
/// or `EditNoteError::Ambiguous(n)` if it appears more than once and
/// `replace_all = false`. The wikilink-sync hook fires through the
/// shared `update_note_body` path, so edges stay consistent with the
/// new body without the caller having to think about it.
pub async fn edit_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
    old_string: &str,
    new_string: &str,
    replace_all: bool,
    by: &str,
) -> Result<Note, EditNoteError> {
    let note = match get_note(db, workspace_id, title).await {
        Ok(Some(n)) => n,
        Ok(None) => return Err(EditNoteError::NotFound),
        Err(e) => return Err(EditNoteError::Db(e)),
    };

    if old_string.is_empty() {
        return Err(EditNoteError::EmptyOld);
    }

    let count = note.body.matches(old_string).count();
    if count == 0 {
        return Err(EditNoteError::NoMatch);
    }
    if count > 1 && !replace_all {
        return Err(EditNoteError::Ambiguous(count));
    }

    let new_body = if replace_all {
        note.body.replace(old_string, new_string)
    } else {
        note.body.replacen(old_string, new_string, 1)
    };

    match update_note_body(db, workspace_id, title, &new_body, by).await {
        Ok(Some(updated)) => Ok(updated),
        Ok(None) => Err(EditNoteError::NotFound),
        Err(e) => Err(EditNoteError::Db(e)),
    }
}

#[derive(Debug)]
pub enum EditNoteError {
    NotFound,
    NoMatch,
    EmptyOld,
    Ambiguous(usize),
    Db(surrealdb::Error),
}

impl std::fmt::Display for EditNoteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EditNoteError::NotFound => write!(f, "note not found"),
            EditNoteError::NoMatch => {
                write!(f, "old_string not found in note body")
            }
            EditNoteError::EmptyOld => {
                write!(f, "old_string cannot be empty")
            }
            EditNoteError::Ambiguous(n) => write!(
                f,
                "old_string appears {n} times — add surrounding context to make it unique, or set replace_all"
            ),
            EditNoteError::Db(e) => write!(f, "db error: {e}"),
        }
    }
}

/// Walk every `[[wikilink]]` in `body`, ensure the target notes exist,
/// and bring the outbound `mentions` edges from `note_id` in line with
/// the body. Old mentions to titles no longer in the body are removed
/// — the body is the source of truth, the edges are derived state.
pub async fn sync_wikilinks_for_note(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    self_title: &str,
    note_id: &Thing,
    body: &str,
    by: &str,
) -> Result<(), surrealdb::Error> {
    let mut titles = extract_wikilink_titles(body);
    titles.retain(|t| t != self_title);
    let _ = ensure_notes_exist(db, workspace_id, &titles, by).await;

    let mut target_ids: Vec<Thing> = Vec::new();
    for t in &titles {
        if let Some(n) = get_note(db, workspace_id, t).await? {
            target_ids.push(n.id);
        }
    }
    crate::graph::replace_mention_edges(db, Some(workspace_id), note_id, &target_ids, by).await?;
    Ok(())
}

/// Append-only wikilink sync for a chat message. Adds `mentions` edges
/// from the chat node to every newly-referenced note; never removes
/// existing chat→note edges (chats are append-only, so historical
/// mentions stay valid even after the message scrolls away).
pub async fn sync_wikilinks_for_chat_message(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    chat_id: &Thing,
    body: &str,
    by: &str,
) -> Result<(), surrealdb::Error> {
    let titles = extract_wikilink_titles(body);
    if titles.is_empty() {
        return Ok(());
    }
    let _ = ensure_notes_exist(db, workspace_id, &titles, by).await;
    for t in &titles {
        if let Some(n) = get_note(db, workspace_id, t).await? {
            let _ = crate::graph::relate(
                db,
                Some(workspace_id),
                chat_id,
                &n.id,
                "mentions",
                None,
                by,
            )
            .await;
        }
    }
    Ok(())
}

/// One-shot rescan: walks every note, replays `sync_wikilinks_for_note`
/// to backfill `mentions` edges that were never recorded (e.g. notes
/// edited before the polymorphic edge layer existed). Idempotent —
/// `replace_mention_edges` is a diff, not an insert.
pub async fn rescan_wikilink_edges(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    by: &str,
) -> Result<usize, surrealdb::Error> {
    #[derive(Deserialize)]
    struct Row {
        id: Thing,
        title: String,
        body: String,
    }
    let rows: Vec<Row> = db
        .query("SELECT id, title, body FROM note WHERE workspace = $ws")
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    let n = rows.len();
    for row in rows {
        let _ =
            sync_wikilinks_for_note(db, workspace_id, &row.title, &row.id, &row.body, by).await;
    }
    Ok(n)
}

// ── Folder CRUD ──────────────────────────────────────────────────

pub async fn list_folders(
    db: &Surreal<Db>,
    workspace_id: &Thing,
) -> Result<Vec<Folder>, surrealdb::Error> {
    let folders: Vec<Folder> = db
        .query(
            "SELECT id, name, color, created_at FROM folder \
             WHERE workspace = $ws ORDER BY name ASC LIMIT 500",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    Ok(folders)
}

pub async fn create_folder(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    name: &str,
    color: Option<&str>,
) -> Result<Option<Folder>, surrealdb::Error> {
    // Idempotent on (name, workspace) — saves callers the round-trip.
    let existing: Option<Folder> = db
        .query(
            "SELECT id, name, color, created_at FROM folder \
             WHERE name = $name AND workspace = $ws LIMIT 1",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("name", name.to_string()))
        .await?
        .take(0)?;
    if existing.is_some() {
        return Ok(existing);
    }

    let created: Vec<Folder> = db
        .query(
            "CREATE folder SET name = $name, color = $color, workspace = $ws",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("name", name.to_string()))
        .bind(("color", color.map(|s| s.to_string())))
        .await?
        .take(0)?;
    Ok(created.into_iter().next())
}

pub async fn rename_folder(
    db: &Surreal<Db>,
    folder_id: &Thing,
    name: &str,
) -> Result<(), surrealdb::Error> {
    db.query("UPDATE $id SET name = $name")
        .bind(("id", folder_id.clone()))
        .bind(("name", name.to_string()))
        .await?
        .check()?;
    Ok(())
}

/// Delete the folder row and unassign every note that pointed to it.
/// Notes themselves are never destroyed by folder deletion.
pub async fn delete_folder(
    db: &Surreal<Db>,
    folder_id: &Thing,
) -> Result<(), surrealdb::Error> {
    db.query(
        "UPDATE note SET folder = NONE WHERE folder = $id; \
         DELETE $id;",
    )
    .bind(("id", folder_id.clone()))
    .await?
    .check()?;
    Ok(())
}

/// Move a note to a folder, or unassign it when `folder_id` is None.
/// Returns the updated note row so the caller can refresh its cache.
pub async fn set_note_folder(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    title: &str,
    folder_id: Option<&Thing>,
    by: &str,
) -> Result<Option<Note>, surrealdb::Error> {
    let Some(note) = get_note(db, workspace_id, title).await? else {
        return Ok(None);
    };
    let updated: Vec<Note> = db
        .query(
            "UPDATE $id SET folder = $folder, last_edited_by = $by, \
                            updated_at = time::now()",
        )
        .bind(("id", note.id.clone()))
        .bind(("folder", folder_id.cloned()))
        .bind(("by", by.to_string()))
        .await?
        .take(0)?;

    // Audit row — folder moves are part of the note's history so the
    // user can trace where a note has lived.
    let diff = match folder_id {
        Some(_) => "moved to folder".to_string(),
        None => "unassigned from folder".to_string(),
    };
    let _ = db
        .query("CREATE note_edit SET note = $note, by = $by, diff = $diff")
        .bind(("note", note.id))
        .bind(("by", by.to_string()))
        .bind(("diff", diff))
        .await;

    Ok(updated.into_iter().next())
}

// ── Email thread shadow (graph node) ─────────────────────────────

/// Upsert a single email_thread shadow row from a mail.db aggregate.
/// Idempotent on (thread_id, account_id). Bumps `updated_at`,
/// preserves embedding state, and never touches `touched_at` (that
/// flag is owned by the user-interaction path, not by sync).
pub async fn upsert_email_thread(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    agg: &EmailThreadAggregate,
) -> Result<(), surrealdb::Error> {
    let existing: Option<Thing> = db
        .query(
            "SELECT VALUE id FROM email_thread \
             WHERE thread_id = $tid AND account_id = $acc LIMIT 1",
        )
        .bind(("tid", agg.thread_id.clone()))
        .bind(("acc", agg.account_id.clone()))
        .await?
        .take(0)?;

    // SurrealDB v2 won't coerce a serde-stringified RFC-3339 into its
    // native `datetime` type — bind a `sql::Datetime` wrapper so the
    // CBOR layer carries the proper tag.
    let last_date = surrealdb::sql::Datetime::from(agg.last_date);

    if let Some(id) = existing {
        db.query(
            "UPDATE $id SET \
                subject = $subject, \
                from_addr = $from_addr, \
                from_name = $from_name, \
                last_date = $last_date, \
                message_count = $count, \
                updated_at = time::now()",
        )
        .bind(("id", id))
        .bind(("subject", agg.subject.clone()))
        .bind(("from_addr", agg.from_addr.clone()))
        .bind(("from_name", agg.from_name.clone()))
        .bind(("last_date", last_date))
        .bind(("count", agg.message_count))
        .await?
        .check()?;
    } else {
        db.query(
            "CREATE email_thread SET \
                thread_id = $tid, \
                account_id = $acc, \
                subject = $subject, \
                from_addr = $from_addr, \
                from_name = $from_name, \
                last_date = $last_date, \
                message_count = $count, \
                workspace = $ws",
        )
        .bind(("tid", agg.thread_id.clone()))
        .bind(("acc", agg.account_id.clone()))
        .bind(("subject", agg.subject.clone()))
        .bind(("from_addr", agg.from_addr.clone()))
        .bind(("from_name", agg.from_name.clone()))
        .bind(("last_date", last_date))
        .bind(("count", agg.message_count))
        .bind(("ws", workspace_id.clone()))
        .await?
        .check()?;
    }
    Ok(())
}

/// Bump `touched_at` to now. Called from the user-interaction path
/// (read thread, reply, [[wikilink]]) so future heuristics can
/// surface "warm" threads — but on its own, touched_at no longer
/// makes a thread visible in the graph. See `promote_email_thread`
/// for that.
pub async fn mark_email_thread_touched(
    db: &Surreal<Db>,
    thread_id: &str,
    account_id: &str,
) -> Result<(), surrealdb::Error> {
    db.query(
        "UPDATE email_thread SET touched_at = time::now() \
         WHERE thread_id = $tid AND account_id = $acc",
    )
    .bind(("tid", thread_id.to_string()))
    .bind(("acc", account_id.to_string()))
    .await?
    .check()?;
    Ok(())
}

/// Outcome of a promote_email_thread call. Distinguishes "did the
/// shadow row even exist" from "was it already promoted" — the
/// agent treats the first case as a programming error (it
/// hallucinated a thread_id) and the second as a benign no-op.
#[derive(Debug)]
pub enum PromoteOutcome {
    NotFound,
    Promoted,
    AlreadyPromoted,
}

/// Promote a thread into the graph. After this, the thread shows up
/// in `graph_view_query`, `graph_search`, and is eligible for the
/// background embed loop.
pub async fn promote_email_thread(
    db: &Surreal<Db>,
    thread_id: &str,
    account_id: &str,
) -> Result<PromoteOutcome, surrealdb::Error> {
    // Look the row up first so we can disambiguate "doesn't exist"
    // from "exists but already promoted". A bare UPDATE WHERE collapses
    // those into the same empty-result-set, and the agent path needs
    // to know the difference to fail loudly on hallucinated ids.
    #[derive(Deserialize)]
    struct Row {
        id: Thing,
        promoted_at: Option<DateTime<Utc>>,
    }
    let existing: Option<Row> = db
        .query(
            "SELECT id, promoted_at FROM email_thread \
             WHERE thread_id = $tid AND account_id = $acc LIMIT 1",
        )
        .bind(("tid", thread_id.to_string()))
        .bind(("acc", account_id.to_string()))
        .await?
        .take(0)?;
    let Some(row) = existing else {
        return Ok(PromoteOutcome::NotFound);
    };
    if row.promoted_at.is_some() {
        return Ok(PromoteOutcome::AlreadyPromoted);
    }
    db.query("UPDATE $id SET promoted_at = time::now()")
        .bind(("id", row.id))
        .await?
        .check()?;
    Ok(PromoteOutcome::Promoted)
}

/// Promote by SurrealDB record id (used when we already hold a
/// `Thing` — e.g. inside `graph::relate` when an edge endpoint is
/// an email_thread). Idempotent.
pub async fn promote_email_thread_by_id(
    db: &Surreal<Db>,
    id: &Thing,
) -> Result<(), surrealdb::Error> {
    db.query("UPDATE $id SET promoted_at = time::now() WHERE promoted_at == NONE")
        .bind(("id", id.clone()))
        .await?
        .check()?;
    Ok(())
}

pub async fn unpromote_email_thread(
    db: &Surreal<Db>,
    thread_id: &str,
    account_id: &str,
) -> Result<(), surrealdb::Error> {
    // Drop the promotion AND every edge touching this thread —
    // edges to an invisible node are dangling references in the
    // canvas and meaningless to graph_search.
    db.query(
        "LET $t = (SELECT VALUE id FROM email_thread \
                   WHERE thread_id = $tid AND account_id = $acc LIMIT 1)[0]; \
         IF $t IS NOT NONE { \
            UPDATE $t SET promoted_at = NONE; \
            DELETE edge WHERE from_node = $t OR to_node = $t; \
         };",
    )
    .bind(("tid", thread_id.to_string()))
    .bind(("acc", account_id.to_string()))
    .await?
    .check()?;
    Ok(())
}

pub async fn list_email_threads(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    limit: usize,
    promoted_only: bool,
) -> Result<Vec<EmailThread>, surrealdb::Error> {
    let limit = limit.clamp(1, 5000) as i64;
    let where_clause = if promoted_only {
        "WHERE workspace = $ws AND promoted_at != NONE"
    } else {
        "WHERE workspace = $ws"
    };
    let sql = format!(
        "SELECT id, thread_id, account_id, subject, from_addr, from_name, \
                last_date, message_count, touched_at, promoted_at, updated_at \
         FROM email_thread {where_clause} \
         ORDER BY last_date DESC LIMIT {limit}"
    );
    let rows: Vec<EmailThread> = db
        .query(sql)
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    Ok(rows)
}

// ── Workspace CRUD ───────────────────────────────────────────────

pub async fn list_workspaces(db: &Surreal<Db>) -> Result<Vec<Workspace>, surrealdb::Error> {
    let ws: Vec<Workspace> = db
        .query("SELECT id, name, created_at FROM workspace ORDER BY created_at ASC LIMIT 200")
        .await?
        .take(0)?;
    Ok(ws)
}

pub async fn create_workspace(
    db: &Surreal<Db>,
    name: &str,
) -> Result<Option<Workspace>, surrealdb::Error> {
    let created: Vec<Workspace> = db
        .query("CREATE workspace SET name = $name")
        .bind(("name", name.to_string()))
        .await?
        .take(0)?;
    Ok(created.into_iter().next())
}

pub async fn rename_workspace(
    db: &Surreal<Db>,
    id: &Thing,
    name: &str,
) -> Result<(), surrealdb::Error> {
    db.query("UPDATE $id SET name = $name")
        .bind(("id", id.clone()))
        .bind(("name", name.to_string()))
        .await?
        .check()?;
    Ok(())
}

// ── Search ───────────────────────────────────────────────────────

#[derive(Deserialize)]
struct NoteRowForSearch {
    id: Thing,
    title: String,
    body: String,
    source_kind: String,
}

#[derive(Deserialize)]
struct NoteRowForVector {
    id: Thing,
    title: String,
    body: String,
    source_kind: String,
}

#[derive(Deserialize)]
struct MsgRowForSearch {
    id: Thing,
    chat_id: Thing,
    chat_title: Option<String>,
    role: String,
    content: String,
    created_at: DateTime<Utc>,
}

pub async fn search(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    query: &str,
    limit: usize,
) -> Result<SearchResults, surrealdb::Error> {
    let q = query.trim();
    if q.is_empty() {
        return Ok(SearchResults {
            notes: vec![],
            messages: vec![],
        });
    }
    let lq = q.to_lowercase();

    // Lexical lane. Keep the matching in Rust instead of relying on
    // Surreal string operators / BM25 index state; this must work for
    // exact titles, note bodies, and chat text even on old local DBs.
    let note_candidates: Vec<NoteRowForSearch> = db
        .query(
            "SELECT id, title, body, source_kind FROM note \
             WHERE workspace = $ws",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    let mut bm25_rows: Vec<NoteRowForSearch> = note_candidates
        .into_iter()
        .filter(|n| {
            n.title.to_lowercase().contains(&lq) || n.body.to_lowercase().contains(&lq)
        })
        .collect();
    bm25_rows.sort_by_key(|n| {
        if n.title.to_lowercase().contains(&lq) {
            0
        } else {
            1
        }
    });
    bm25_rows.truncate(limit);
    eprintln!(
        "[search] ws={workspace_id} lq={lq:?} lexical_note_hits={}",
        bm25_rows.len()
    );

    let bm25_ids: std::collections::HashSet<Thing> =
        bm25_rows.iter().map(|n| n.id.clone()).collect();

    let mut notes: Vec<NoteSearchHit> = bm25_rows
        .into_iter()
        .map(|n| {
            let title_hit = n.title.to_lowercase().contains(&lq);
            let snippet = make_snippet(&n.body, &lq);
            NoteSearchHit {
                title: n.title,
                source_kind: n.source_kind,
                snippet,
                title_hit,
                semantic_only: false,
            }
        })
        .collect();

    // Semantic lane — fills in fuzzy / synonym matches BM25 misses.
    // Embedding may fail (model still downloading, ONNX init error);
    // skip silently in that case so search keeps working on BM25 alone.
    let needed = limit.saturating_sub(notes.len());
    if needed > 0 {
        // Non-blocking — returns None while the model is still
        // downloading on a fresh install. BM25 results show instantly
        // either way; semantic kicks in once the background warmup
        // (kicked off in `run_reembed_loop`) lands.
        if let Some(qvec) = crate::embed::embed_one_if_ready(q.to_string()).await {
            // HNSW knn operator <|K,COSINE|> — K must be a literal int,
            // not a bind parameter (parsed at query-build time). We
            // clamp + format inline; bounded by `limit` upstream so
            // there's no injection surface.
            let k = (needed * 2).max(8).min(64);
            let knn_sql = format!(
                "SELECT id, title, body, source_kind FROM note \
                 WHERE workspace = $ws \
                   AND embedding != NONE \
                   AND embedding <|{k},COSINE|> $qv \
                 LIMIT {k}"
            );
            let vec_rows: Vec<NoteRowForVector> = db
                .query(&knn_sql)
                .bind(("ws", workspace_id.clone()))
                .bind(("qv", qvec))
                .await
                .ok()
                .and_then(|mut r| r.take::<Vec<NoteRowForVector>>(0).ok())
                .unwrap_or_default();

            for row in vec_rows.into_iter().take(needed) {
                if bm25_ids.contains(&row.id) {
                    continue;
                }
                let snippet = if row.body.is_empty() {
                    String::new()
                } else {
                    let len = row.body.len().min(140);
                    let mut end = len;
                    while end < row.body.len() && !row.body.is_char_boundary(end) {
                        end += 1;
                    }
                    let suffix = if end < row.body.len() { "…" } else { "" };
                    format!("{}{suffix}", &row.body[..end])
                };
                notes.push(NoteSearchHit {
                    title: row.title,
                    source_kind: row.source_kind,
                    snippet,
                    title_hit: false,
                    semantic_only: true,
                });
            }
        }
    }

    let msg_candidates: Vec<MsgRowForSearch> = db
        .query(
            "SELECT id, role, content, created_at, \
                    chat AS chat_id, chat.title AS chat_title \
             FROM message \
             WHERE chat.workspace = $ws \
             ORDER BY created_at DESC",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;

    let messages: Vec<MessageSearchHit> = msg_candidates
        .into_iter()
        .filter(|m| m.content.to_lowercase().contains(&lq))
        .take(limit)
        .map(|m| MessageSearchHit {
            message_id: m.id,
            chat_id: m.chat_id,
            chat_title: m.chat_title,
            role: m.role,
            snippet: make_snippet(&m.content, &lq),
            created_at: m.created_at,
        })
        .collect();

    Ok(SearchResults { notes, messages })
}

fn make_snippet(text: &str, lower_query: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let text_lower = text.to_lowercase();
    let span = 70;
    match text_lower.find(lower_query) {
        Some(byte_idx) => {
            // Walk back to a char boundary.
            let mut start = byte_idx.saturating_sub(span);
            while start > 0 && !text.is_char_boundary(start) {
                start -= 1;
            }
            let mut end = (byte_idx + lower_query.len() + span).min(text.len());
            while end < text.len() && !text.is_char_boundary(end) {
                end += 1;
            }
            let prefix = if start > 0 { "…" } else { "" };
            let suffix = if end < text.len() { "…" } else { "" };
            format!("{prefix}{}{suffix}", &text[start..end])
        }
        None => text.chars().take(140).collect(),
    }
}

/// Delete a workspace and cascade everything it owns: notes (+ note_edits +
/// links), chats (+ messages), agents. Returns false if this is the last
/// workspace remaining (always keep at least one).
pub async fn delete_workspace(
    db: &Surreal<Db>,
    id: &Thing,
) -> Result<bool, surrealdb::Error> {
    let count: Option<i64> = db
        .query("(SELECT VALUE count() FROM workspace GROUP ALL)[0]")
        .await?
        .take(0)?;
    if count.unwrap_or(0) <= 1 {
        return Ok(false);
    }
    db.query(
        "DELETE note_edit WHERE note.workspace = $ws; \
         DELETE edge WHERE workspace = $ws; \
         DELETE note WHERE workspace = $ws; \
         DELETE message WHERE chat.workspace = $ws; \
         DELETE chat WHERE workspace = $ws; \
         DELETE agent WHERE workspace = $ws; \
         DELETE $ws;",
    )
    .bind(("ws", id.clone()))
    .await?
    .check()?;
    Ok(true)
}

// ── Agent CRUD ───────────────────────────────────────────────────

pub async fn list_agents(
    db: &Surreal<Db>,
    workspace_id: &Thing,
) -> Result<Vec<Agent>, surrealdb::Error> {
    let agents: Vec<Agent> = db
        .query(
            "SELECT id, name, system_prompt, model, capabilities FROM agent \
             WHERE workspace = $ws ORDER BY name ASC LIMIT 200",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    Ok(agents)
}

pub async fn create_agent(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    name: &str,
    system_prompt: &str,
    model: &str,
    capabilities: &[String],
) -> Result<Option<Agent>, surrealdb::Error> {
    let created: Vec<Agent> = db
        .query(
            "CREATE agent SET \
                name = $name, \
                system_prompt = $sp, \
                model = $model, \
                capabilities = $caps, \
                workspace = $ws",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("name", name.to_string()))
        .bind(("sp", system_prompt.to_string()))
        .bind(("model", model.to_string()))
        .bind(("caps", capabilities.to_vec()))
        .await?
        .take(0)?;
    Ok(created.into_iter().next())
}

pub async fn update_agent(
    db: &Surreal<Db>,
    id: &Thing,
    name: &str,
    system_prompt: &str,
    model: &str,
    capabilities: &[String],
) -> Result<Option<Agent>, surrealdb::Error> {
    let updated: Vec<Agent> = db
        .query(
            "UPDATE $id SET name = $name, system_prompt = $sp, model = $model, capabilities = $caps",
        )
        .bind(("id", id.clone()))
        .bind(("name", name.to_string()))
        .bind(("sp", system_prompt.to_string()))
        .bind(("model", model.to_string()))
        .bind(("caps", capabilities.to_vec()))
        .await?
        .take(0)?;
    Ok(updated.into_iter().next())
}

pub async fn delete_agent(
    db: &Surreal<Db>,
    id: &Thing,
) -> Result<(), surrealdb::Error> {
    // Unbind chats first so chat.agent doesn't dangle.
    db.query("UPDATE chat SET agent = NONE WHERE agent = $id; DELETE $id;")
        .bind(("id", id.clone()))
        .await?
        .check()?;
    Ok(())
}

pub async fn get_agent(
    db: &Surreal<Db>,
    id: &Thing,
) -> Result<Option<Agent>, surrealdb::Error> {
    let a: Option<Agent> = db
        .query("SELECT id, name, system_prompt, model, capabilities FROM agent WHERE id = $id LIMIT 1")
        .bind(("id", id.clone()))
        .await?
        .take(0)?;
    Ok(a)
}

pub async fn set_chat_agent(
    db: &Surreal<Db>,
    chat_id: &Thing,
    agent_id: Option<&Thing>,
) -> Result<(), surrealdb::Error> {
    match agent_id {
        Some(a) => db
            .query("UPDATE $chat SET agent = $agent")
            .bind(("chat", chat_id.clone()))
            .bind(("agent", a.clone()))
            .await?
            .check()?,
        None => db
            .query("UPDATE $chat SET agent = NONE")
            .bind(("chat", chat_id.clone()))
            .await?
            .check()?,
    };
    Ok(())
}

/// Replace the chat's bound agent list. Used by the multi-select agent
/// picker. Also writes the legacy single `agent` field with the first
/// element so old code paths (e.g. `get_chat_agent`) keep working.
pub async fn set_chat_agents(
    db: &Surreal<Db>,
    chat_id: &Thing,
    agent_ids: &[Thing],
) -> Result<(), surrealdb::Error> {
    let first = agent_ids.first().cloned();
    db.query("UPDATE $chat SET agents = $agents, agent = $first")
        .bind(("chat", chat_id.clone()))
        .bind(("agents", agent_ids.to_vec()))
        .bind(("first", first))
        .await?
        .check()?;
    Ok(())
}

/// Fetch the full agent records bound to a chat (multi-agent group
/// chat support). Returns empty when nothing is bound.
pub async fn get_chat_agents(
    db: &Surreal<Db>,
    chat_id: &Thing,
) -> Result<Vec<Agent>, surrealdb::Error> {
    #[derive(Deserialize)]
    struct ChatAgentsRef {
        #[serde(default)]
        agents: Vec<Thing>,
    }
    let row: Option<ChatAgentsRef> = db
        .query("SELECT agents FROM $chat LIMIT 1")
        .bind(("chat", chat_id.clone()))
        .await?
        .take(0)?;
    let ids = row.map(|r| r.agents).unwrap_or_default();
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let agents: Vec<Agent> = db
        .query(
            "SELECT id, name, system_prompt, model, capabilities FROM agent WHERE id IN $ids",
        )
        .bind(("ids", ids))
        .await?
        .take(0)?;
    Ok(agents)
}

pub async fn get_chat_agent(
    db: &Surreal<Db>,
    chat_id: &Thing,
) -> Result<Option<Agent>, surrealdb::Error> {
    #[derive(Deserialize)]
    struct ChatAgentRef {
        agent: Option<Thing>,
    }
    let row: Option<ChatAgentRef> = db
        .query("SELECT agent FROM $chat LIMIT 1")
        .bind(("chat", chat_id.clone()))
        .await?
        .take(0)?;
    let Some(agent_id) = row.and_then(|r| r.agent) else {
        return Ok(None);
    };
    get_agent(db, &agent_id).await
}

// ── Email accounts (mail client, Phase 1) ─────────────────────────

/// Wire-shape row matching SurrealDB's `email_account` table. Kept
/// private so the rest of the codebase always goes through
/// `mail::types::Account`; this struct exists only to deserialize.
#[derive(Deserialize)]
struct EmailAccountRow {
    id: Thing,
    email: String,
    display_name: Option<String>,
    provider: String,
    imap_host: String,
    imap_port: i64,
    smtp_host: String,
    smtp_port: i64,
    signature: Option<String>,
    notify_enabled: bool,
    attachment_auto_dl_max_mb: i64,
    created_at: DateTime<Utc>,
    last_sync_at: Option<DateTime<Utc>>,
}

fn to_account(row: EmailAccountRow) -> crate::mail::types::Account {
    use crate::mail::types::ProviderKind;
    let provider = match row.provider.as_str() {
        "gmail" => ProviderKind::Gmail,
        "outlook" => ProviderKind::Outlook,
        "icloud" => ProviderKind::ICloud,
        "fastmail" => ProviderKind::Fastmail,
        "yahoo" => ProviderKind::Yahoo,
        _ => ProviderKind::Imap,
    };
    crate::mail::types::Account {
        id: row.id.to_string(),
        email: row.email,
        display_name: row.display_name,
        provider,
        imap_host: row.imap_host,
        imap_port: row.imap_port as u16,
        smtp_host: row.smtp_host,
        smtp_port: row.smtp_port as u16,
        signature: row.signature,
        notify_enabled: row.notify_enabled,
        attachment_auto_dl_max_mb: row.attachment_auto_dl_max_mb as u32,
        created_at: row.created_at.to_rfc3339(),
        last_sync_at: row.last_sync_at.map(|t| t.to_rfc3339()),
    }
}

pub async fn create_email_account(
    db: &Surreal<Db>,
    autoconfig: &crate::mail::types::AutoconfigResult,
    keychain_ref: &str,
    has_refresh_token: bool,
) -> Result<crate::mail::types::Account, surrealdb::Error> {
    use crate::mail::types::TlsMode;
    let imap_security = match autoconfig.imap.security {
        TlsMode::Tls => "tls",
        TlsMode::Starttls => "starttls",
    };
    let smtp_security = match autoconfig.smtp.security {
        TlsMode::Tls => "tls",
        TlsMode::Starttls => "starttls",
    };
    // Idempotent on email: re-running OAuth for an existing address
    // rotates the keychain_ref instead of inserting a duplicate (the
    // unique index on `email` would otherwise reject CREATE).
    #[derive(Deserialize)]
    struct ExistingId {
        id: Thing,
    }
    let existing: Option<ExistingId> = db
        .query("SELECT id FROM email_account WHERE email = $email LIMIT 1")
        .bind(("email", autoconfig.email.clone()))
        .await?
        .take(0)?;

    let row: Option<EmailAccountRow> = if let Some(prior) = existing {
        db.query(
            "UPDATE $id SET \
                keychain_ref = $kref, has_refresh_token = $has_rt, \
                provider = $provider, \
                imap_host = $imap_host, imap_port = $imap_port, imap_security = $imap_security, \
                smtp_host = $smtp_host, smtp_port = $smtp_port, smtp_security = $smtp_security \
             RETURN AFTER",
        )
        .bind(("id", prior.id))
        .bind(("provider", autoconfig.provider.as_str().to_string()))
        .bind(("imap_host", autoconfig.imap.host.clone()))
        .bind(("imap_port", autoconfig.imap.port as i64))
        .bind(("imap_security", imap_security.to_string()))
        .bind(("smtp_host", autoconfig.smtp.host.clone()))
        .bind(("smtp_port", autoconfig.smtp.port as i64))
        .bind(("smtp_security", smtp_security.to_string()))
        .bind(("kref", keychain_ref.to_string()))
        .bind(("has_rt", has_refresh_token))
        .await?
        .take(0)?
    } else {
        let created: Vec<EmailAccountRow> = db
            .query(
                "CREATE email_account SET \
                    email = $email, provider = $provider, \
                    imap_host = $imap_host, imap_port = $imap_port, imap_security = $imap_security, \
                    smtp_host = $smtp_host, smtp_port = $smtp_port, smtp_security = $smtp_security, \
                    keychain_ref = $kref, has_refresh_token = $has_rt",
            )
            .bind(("email", autoconfig.email.clone()))
            .bind(("provider", autoconfig.provider.as_str().to_string()))
            .bind(("imap_host", autoconfig.imap.host.clone()))
            .bind(("imap_port", autoconfig.imap.port as i64))
            .bind(("imap_security", imap_security.to_string()))
            .bind(("smtp_host", autoconfig.smtp.host.clone()))
            .bind(("smtp_port", autoconfig.smtp.port as i64))
            .bind(("smtp_security", smtp_security.to_string()))
            .bind(("kref", keychain_ref.to_string()))
            .bind(("has_rt", has_refresh_token))
            .await?
            .take(0)?;
        created.into_iter().next()
    };

    let row = row.ok_or_else(|| {
        surrealdb::Error::Db(surrealdb::error::Db::Thrown(
            "email_account write returned no row".into(),
        ))
    })?;
    Ok(to_account(row))
}

pub async fn list_email_accounts(
    db: &Surreal<Db>,
) -> Result<Vec<crate::mail::types::Account>, surrealdb::Error> {
    let rows: Vec<EmailAccountRow> = db
        .query(
            "SELECT id, email, display_name, provider, \
                    imap_host, imap_port, smtp_host, smtp_port, \
                    signature, notify_enabled, attachment_auto_dl_max_mb, \
                    created_at, last_sync_at \
             FROM email_account ORDER BY created_at ASC",
        )
        .await?
        .take(0)?;
    Ok(rows.into_iter().map(to_account).collect())
}

/// Returns the deleted row's `keychain_ref` so the caller can drop the
/// matching Keychain entry. `None` means there was no row to delete.
pub async fn delete_email_account(
    db: &Surreal<Db>,
    account_id: &str,
) -> Result<Option<String>, surrealdb::Error> {
    let id: Thing = account_id.parse().map_err(|_| {
        surrealdb::Error::Db(surrealdb::error::Db::Thrown(format!(
            "invalid email_account id {account_id:?}"
        )))
    })?;
    #[derive(Deserialize)]
    struct KrefRow {
        keychain_ref: String,
    }
    let prior: Option<KrefRow> = db
        .query("SELECT keychain_ref FROM $id")
        .bind(("id", id.clone()))
        .await?
        .take(0)?;
    db.query("DELETE $id").bind(("id", id)).await?.check()?;
    Ok(prior.map(|r| r.keychain_ref))
}
