//! Per-agent capabilities — opt-in tool surfaces gated on the bound
//! agent's `capabilities` array. Only tools whose key the agent has
//! are documented in the system prompt and accepted at execution time.
//!
//! Calendar/Reminders run through a Swift `clome-eventkit` sidecar
//! bundled via Tauri's `externalBin`. Earlier we used JXA via
//! `osascript`, but that routes through the AppleEvents TCC bucket,
//! which never granted reliably for our signed dev binary — the
//! Automation prompt either didn't fire or its grant was invalidated
//! by the post-build re-sign. EventKit uses NSCalendarsUsageDescription
//! / NSRemindersUsageDescription instead, which the parent .app's
//! Info.plist already declares (via scripts/inject-tcc.sh).

use serde_json::json;
use std::path::{Path, PathBuf};
use tauri::AppHandle;
use tauri_plugin_shell::ShellExt;

#[derive(Debug, Clone, Copy)]
pub struct CapabilityDef {
    pub key: &'static str,
    pub label: &'static str,
    pub description: &'static str,
    pub tool_docs: &'static str,
}

pub const ALL: &[CapabilityDef] = &[
    CapabilityDef {
        key: "calendar.read",
        label: "Calendar — read",
        description: "List events from Calendar.app in a date range.",
        tool_docs: r#"
- `list_events`
  Headers: `from` (optional ISO datetime; defaults to now),
  `to` (optional ISO datetime; defaults to now+7d)
  Returns JSON array of {title, start, end, location, calendar}."#,
    },
    CapabilityDef {
        key: "calendar.write",
        label: "Calendar — write",
        description: "Create / delete events in Calendar.app.",
        tool_docs: r#"
- `create_event`
  Headers: `title`, `start` (ISO datetime), `end` (ISO datetime),
  `calendar` (optional name; defaults to user's default), `location` (optional)
  Body: optional event notes (markdown).
- `delete_event`
  Headers: EITHER `id` (the stable id from a previous list_events
  result), OR `title` + `on` (ISO date — the day the event lives on).
  Use `id` when available — `title` + `on` is fuzzy fallback for
  events you haven't listed yet. Use this to fix a mistakenly-created
  event: emit `delete_event` with the wrong id, then `create_event`
  with the corrected time."#,
    },
    CapabilityDef {
        key: "reminders.read",
        label: "Reminders — read",
        description: "List reminders from Reminders.app.",
        tool_docs: r#"
- `list_reminders`
  Headers: `include_completed` (optional, default false)
  Returns JSON array of {title, due, list, completed}."#,
    },
    CapabilityDef {
        key: "reminders.write",
        label: "Reminders — write",
        description: "Create new reminders in Reminders.app.",
        tool_docs: r#"
- `create_reminder`
  Headers: `title`, `due` (optional ISO datetime), `list` (optional list name)
  Body: optional reminder notes (markdown)."#,
    },
    CapabilityDef {
        key: "email.read",
        label: "Email — read",
        description: "Search the user's mail and promote relevant threads into the knowledge graph.",
        tool_docs: r#"
- `list_mail`
  Headers: `hours_back` (integer, optional; default 24, max 720),
           `limit` (integer, optional; default 30, max 100),
           `direction` (optional; one of `received`, `sent`, `any`;
                        default `received`)
  Returns JSON array of {thread_id, account_id, subject, from_addr, from_name, snippet, date_received, unread}.
  **This is the right tool for time-based queries** — "what came in
  today" → hours_back=24 (default direction "received"), "what did
  I send this week" → hours_back=168, direction=sent. Returns
  thread heads (latest message per thread) so a chatty conversation
  doesn't crowd everything else out. NEVER call `search_mail` with
  query="today" / "this week" / "yesterday" — those are not content
  terms in any user's inbox; they would return random hits or none.
  Use the CURRENT TIME the system gave you to pick `hours_back`.

  Direction guidance:
  - "what emails did I get / receive" → direction=received (default; can omit)
  - "what emails did I send" → direction=sent
  - "all my email activity" → direction=any

- `search_mail`
  Headers: `query` (free text — content / sender / subject keywords),
           `limit` (optional integer; default 15, max 50),
           `direction` (optional; one of `received`, `sent`, `any`;
                        default `any` — search defaults to wider scope
                        than list because users often don't remember
                        if they sent or received the email they're
                        looking for).
  Returns the same JSON shape as `list_mail`. Hits the user's local
  mail.db full-text index across every account. Use for content-based
  queries: "emails about Acme", "anything from Sarah", etc. Do NOT
  use for purely temporal queries — see `list_mail`.
- `promote_email_thread`
  Headers: `thread_id` (from a search_mail result), `account_id` (optional — auto-resolved if a message exists for that thread)
  Adds the thread to the knowledge graph so it's queryable via
  `graph_search` and visible in the graph view. Idempotent — repeated
  calls are no-ops. Use this when a conversation references emails
  the user wants the agent to retain context on (interview threads,
  project conversations, ongoing deals). Do NOT promote
  marketing / newsletter / shipping-receipt threads — keep the graph
  high-signal.

  **Referencing emails in your prose.** When you mention a specific
  email thread in your reply, format the reference as a typed wikilink
  so the user can click through to the message:
      `[[email:THREAD_ID|Subject line]]`
  The `THREAD_ID` is the value from `search_mail`'s `thread_id` field.
  The display label after `|` is what the user reads — usually the
  subject. Example:
      "Latest update is in [[email:abc123|Q3 review with Acme]]."
  Bare wikilinks like `[[Q3 review]]` route to notes and won't open
  the email — always use the typed form for email references.

  **NEVER invent thread_ids.** A thread_id is an opaque identifier
  the system computes from message headers (looks like a hex hash,
  not a slug). It MUST come from a `list_mail` or `search_mail`
  result you have actually run THIS turn. If you
  don't have a real thread_id, do NOT call `promote_email_thread` and
  do NOT emit `[[email:...]]` references — instead, run the right
  read tool first. The system will reject any thread_id it can't find
  in mail.db with a clear error; if you see that error, the fix is to
  search first, not to retry with a different made-up id. Do NOT use
  placeholders like `<thread_id>` or `[Booking Name]` in the label
  either — quote the actual subject the read tool returned.

  **Always render search/list results as clickable refs.** When
  `list_mail` or `search_mail` returns N entries and the user
  asked about emails, list ALL of them in your reply as a bulleted
  list, each one a `[[email:THREAD_ID|Subject]]` link followed by
  the sender and (if useful) a one-clause snippet. Do NOT collapse
  multiple unrelated emails into a single sentence ("you got
  several emails from X about…") — that hides the thread_ids and
  the user can't click through. One bullet per thread."#,
    },
    CapabilityDef {
        key: "filesystem.read",
        label: "Filesystem — read",
        description: "Read files and list folders under allowed local roots.",
        tool_docs: r#"
- `list_dir`
  Headers: `path`, `limit` (optional integer; default 80, max 200)
  Returns JSON object {path, entries:[{name, path, kind, size}]}.
- `read_file`
  Headers: `path`
  Returns JSON object {path, bytes, truncated, content}. Text files are capped at 512 KiB.
  Paths must be under an allowed root. Defaults: current app working
  directory, ~/Desktop, ~/Documents, ~/Downloads. Override with
  CLOME_FS_ROOTS as a colon-separated root list."#,
    },
];

/// Maps an action name to the capability key required to execute it.
/// Vault tools (create_note etc.) return None — they're always allowed.
pub fn cap_for_action(action: &str) -> Option<&'static str> {
    match action {
        "create_event" => Some("calendar.write"),
        "delete_event" => Some("calendar.write"),
        "list_events" => Some("calendar.read"),
        "create_reminder" => Some("reminders.write"),
        "list_reminders" => Some("reminders.read"),
        "search_mail" => Some("email.read"),
        "list_mail" => Some("email.read"),
        "read_thread" => Some("email.read"),
        "promote_email_thread" => Some("email.read"),
        "list_dir" => Some("filesystem.read"),
        "read_file" => Some("filesystem.read"),
        _ => None,
    }
}

/// Concat of tool_docs for the capabilities the bound agent has.
/// Empty string if none.
pub fn tool_docs_for(capabilities: &[String]) -> String {
    let mut out = String::new();
    for cap in ALL {
        if cap.tool_docs.is_empty() {
            continue;
        }
        if capabilities.iter().any(|c| c == cap.key) {
            out.push_str(cap.tool_docs);
            out.push('\n');
        }
    }
    out
}

/// Slim behavioral guidance for native tool calling. Tool DEFINITIONS
/// (signatures, parameters, types) come from `tools::tool_schemas` →
/// OpenAI `tools` → Qwen's chat template. This function only emits
/// non-format guidance the model still needs:
///   * which capabilities are NOT granted (so it doesn't hallucinate),
///   * how to reference results in prose (typed wikilinks),
///   * domain rules ("never invent thread_ids", ISO date format).
/// No fence syntax, no `````clome-tool` examples — those caused the
/// fabricate / pattern-mimic failures and the chat template makes them
/// unnecessary.
pub fn behavior_docs_for(agent_caps: &[String]) -> String {
    let mut out = String::new();

    // Capability scoreboard — explicit list of granted vs not-granted
    // so the model doesn't invent calendar/email data when the cap
    // isn't there.
    let mut granted: Vec<&str> = Vec::new();
    let mut missing: Vec<&str> = Vec::new();
    for cap in ALL {
        if agent_caps.iter().any(|c| c == cap.key) {
            granted.push(cap.label);
        } else {
            missing.push(cap.label);
        }
    }
    out.push_str("## Tool guidance\n\n");
    if !granted.is_empty() {
        out.push_str("Granted capabilities: ");
        out.push_str(&granted.join(", "));
        out.push('\n');
    }
    if !missing.is_empty() {
        out.push_str("Not granted (do NOT call these tools or fabricate their data): ");
        out.push_str(&missing.join(", "));
        out.push('\n');
    }
    out.push_str("Vault tools (graph_search, graph_neighbors, create_note, append_to_note, edit_note, replace_note_body, delete_note, relate) are always available.\n\n");

    // Cross-cutting rules.
    out.push_str(
        "Rules:\n\
         - Use `graph_search` BEFORE answering any question that names a topic, person, project, or specific entity in the user's vault.\n\
         - Reference notes in your reply with `[[Note Title]]` so the user can click through.\n\
         - Reference email threads with the typed wikilink `[[email:THREAD_ID|Subject]]` — `THREAD_ID` is the verbatim value from `list_mail` / `search_mail` results, never invented or abbreviated.\n\
         - Date headers (start, end, due, from, to) MUST be ISO 8601 in the user's timezone. Naive `YYYY-MM-DDTHH:MM:SS` or with the user's offset. Never append `Z` (UTC) for user-facing times.\n\
         - When a list-shaped tool returns N entries and the user asked about that data, render ALL of them as a bulleted list — one bullet per item. Do not collapse multiple items into one sentence.\n\
         - Do the minimum the user asked. One request = one tool action unless the user explicitly enumerates multiple.\n",
    );

    out
}

// ── EventKit sidecar invocation ──────────────────────────────────

/// Run the `clome-eventkit` sidecar with one subcommand and a JSON
/// payload. Returns stdout on exit-0, or `Err(message)` on non-zero
/// exit / spawn failure. The sidecar always emits valid JSON (either
/// the result or `{"error": "..."}`) so callers can blindly forward
/// stdout into the model's tool-results block.
async fn run_sidecar(
    app: &AppHandle,
    subcommand: &str,
    payload: serde_json::Value,
) -> Result<String, String> {
    let shell = app.shell();
    let cmd = shell
        .sidecar("clome-eventkit")
        .map_err(|e| format!("sidecar not bundled: {e}"))?;

    let payload_str = payload.to_string();
    let output = cmd
        .args([subcommand, &payload_str])
        .output()
        .await
        .map_err(|e| format!("spawn clome-eventkit: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if !output.status.success() {
        // Sidecar's own error JSON (already on stdout) is what we want
        // to surface to the model; stderr is debug noise. Fall back to
        // stderr only if stdout is empty.
        if !stdout.is_empty() {
            return Err(stdout);
        }
        return Err(format!(
            "clome-eventkit {subcommand} failed: {}",
            if stderr.is_empty() { "no output" } else { &stderr }
        ));
    }
    Ok(stdout)
}

pub async fn eventkit_create_event(
    app: &AppHandle,
    title: &str,
    start: &str,
    end: &str,
    calendar: Option<&str>,
    location: Option<&str>,
    notes: &str,
) -> Result<String, String> {
    let mut payload = json!({
        "title": title,
        "start": start,
        "end": end,
        "notes": notes,
    });
    if let Some(c) = calendar {
        payload["calendar"] = json!(c);
    }
    if let Some(l) = location {
        payload["location"] = json!(l);
    }
    run_sidecar(app, "create-event", payload).await
}

pub async fn eventkit_delete_event(
    app: &AppHandle,
    id: Option<&str>,
    title: Option<&str>,
    on: Option<&str>,
) -> Result<String, String> {
    let mut payload = json!({});
    if let Some(i) = id {
        payload["id"] = json!(i);
    }
    if let Some(t) = title {
        payload["title"] = json!(t);
    }
    if let Some(o) = on {
        payload["on"] = json!(o);
    }
    run_sidecar(app, "delete-event", payload).await
}

pub async fn eventkit_list_events(
    app: &AppHandle,
    from: Option<&str>,
    to: Option<&str>,
) -> Result<String, String> {
    let mut payload = json!({});
    if let Some(f) = from {
        payload["from"] = json!(f);
    }
    if let Some(t) = to {
        payload["to"] = json!(t);
    }
    run_sidecar(app, "list-events", payload).await
}

pub async fn eventkit_list_reminders(
    app: &AppHandle,
    include_completed: bool,
) -> Result<String, String> {
    let payload = json!({ "include_completed": include_completed });
    run_sidecar(app, "list-reminders", payload).await
}

pub async fn eventkit_create_reminder(
    app: &AppHandle,
    title: &str,
    due: Option<&str>,
    list: Option<&str>,
    notes: &str,
) -> Result<String, String> {
    let mut payload = json!({
        "title": title,
        "notes": notes,
    });
    if let Some(d) = due {
        payload["due"] = json!(d);
    }
    if let Some(l) = list {
        payload["list"] = json!(l);
    }
    run_sidecar(app, "create-reminder", payload).await
}

// Mail.app AppleScript bridge removed — agent reads only from Clome's
// own mail.db now (see `list_mail` / `search_mail` in tools.rs).

// Mail bridges into macOS Mail.app (`mail_list_recent`, `mail_read_thread`)
// were removed: the agent is supposed to operate exclusively on Clome's
// own mail.db (via `list_mail` / `search_mail`). Reaching into the
// system Mail.app leaked accounts/threads the user never connected to
// Clome. The legacy AppleScript reader stays only for the in-app mail
// viewer (`mail::legacy::*`), not the agent surface.

// ── Filesystem read bridge ──────────────────────────────────────

const MAX_READ_BYTES: usize = 512 * 1024;

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn expand_path(path: &str) -> Result<PathBuf, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("path cannot be empty".into());
    }
    if trimmed == "~" {
        return home_dir().ok_or_else(|| "HOME is not set".to_string());
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        let home = home_dir().ok_or_else(|| "HOME is not set".to_string())?;
        return Ok(home.join(rest));
    }
    let p = PathBuf::from(trimmed);
    if p.is_absolute() {
        Ok(p)
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(p))
            .map_err(|e| format!("current_dir: {e}"))
    }
}

fn default_allowed_roots() -> Vec<PathBuf> {
    if let Ok(raw) = std::env::var("CLOME_FS_ROOTS") {
        let roots: Vec<PathBuf> = raw
            .split(':')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .filter_map(|s| expand_path(s).ok())
            .filter_map(|p| p.canonicalize().ok())
            .collect();
        if !roots.is_empty() {
            return roots;
        }
    }

    let mut roots = Vec::new();
    if let Ok(cwd) = std::env::current_dir().and_then(|p| p.canonicalize()) {
        roots.push(cwd);
    }
    if let Some(home) = home_dir() {
        for child in ["Desktop", "Documents", "Downloads"] {
            let p = home.join(child);
            if let Ok(canon) = p.canonicalize() {
                roots.push(canon);
            }
        }
    }
    roots
}

fn canonical_allowed(path: &str) -> Result<PathBuf, String> {
    let expanded = expand_path(path)?;
    let canon = expanded
        .canonicalize()
        .map_err(|e| format!("resolve {}: {e}", expanded.display()))?;
    let allowed = default_allowed_roots();
    if allowed.iter().any(|root| is_under(&canon, root)) {
        Ok(canon)
    } else {
        let roots = allowed
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        Err(format!(
            "{} is outside allowed roots ({})",
            canon.display(),
            roots
        ))
    }
}

fn is_under(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

fn metadata_size(meta: &std::fs::Metadata) -> serde_json::Value {
    if meta.is_file() {
        json!(meta.len())
    } else {
        serde_json::Value::Null
    }
}

pub async fn fs_list_dir(path: &str, limit: usize) -> Result<String, String> {
    let path = canonical_allowed(path)?;
    let limit = limit.clamp(1, 200);
    if !path.is_dir() {
        return Err(format!("{} is not a directory", path.display()));
    }
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(&path).map_err(|e| format!("read_dir: {e}"))? {
        let entry = entry.map_err(|e| format!("dir entry: {e}"))?;
        let meta = entry.metadata().map_err(|e| format!("metadata: {e}"))?;
        let kind = if meta.is_dir() {
            "dir"
        } else if meta.is_file() {
            "file"
        } else {
            "other"
        };
        entries.push(json!({
            "name": entry.file_name().to_string_lossy(),
            "path": entry.path().display().to_string(),
            "kind": kind,
            "size": metadata_size(&meta),
        }));
    }
    entries.sort_by(|a, b| {
        let ak = a["kind"].as_str().unwrap_or("");
        let bk = b["kind"].as_str().unwrap_or("");
        let an = a["name"].as_str().unwrap_or("");
        let bn = b["name"].as_str().unwrap_or("");
        (ak != "dir", an).cmp(&(bk != "dir", bn))
    });
    entries.truncate(limit);
    Ok(json!({
        "path": path.display().to_string(),
        "entries": entries,
    })
    .to_string())
}

pub async fn fs_read_file(path: &str) -> Result<String, String> {
    let path = canonical_allowed(path)?;
    if !path.is_file() {
        return Err(format!("{} is not a file", path.display()));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("read_file: {e}"))?;
    let truncated = bytes.len() > MAX_READ_BYTES;
    let slice = if truncated {
        &bytes[..MAX_READ_BYTES]
    } else {
        &bytes[..]
    };
    let content = String::from_utf8_lossy(slice).to_string();
    Ok(json!({
        "path": path.display().to_string(),
        "bytes": bytes.len(),
        "truncated": truncated,
        "content": content,
    })
    .to_string())
}
