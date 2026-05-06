use std::collections::HashMap;
use surrealdb::engine::local::Db;
use surrealdb::sql::Thing;
use surrealdb::Surreal;
use tauri::AppHandle;

use crate::caps;
use crate::db;

#[derive(Debug)]
pub enum ToolCall {
    CreateNote {
        title: String,
        body: String,
        source_kind: Option<String>,
    },
    AppendToNote {
        title: String,
        content: String,
    },
    ReplaceNoteBody {
        title: String,
        body: String,
    },
    EditNote {
        title: String,
        old_string: String,
        new_string: String,
        replace_all: bool,
    },
    DeleteNote {
        title: String,
    },
    Relate {
        from: String,
        to: String,
        kind: String,
        context: Option<String>,
    },
    GraphSearch {
        query: String,
        limit: usize,
    },
    GraphNeighbors {
        title: String,
        limit: usize,
    },
    SearchMail {
        query: String,
        limit: usize,
        direction: Option<String>,
    },
    ListMail {
        hours_back: i64,
        limit: usize,
        direction: Option<String>,
    },
    ReadMailThread {
        thread_id: String,
        account_id: Option<String>,
    },
    PromoteEmailThread {
        thread_id: String,
        account_id: Option<String>,
    },
    CreateEvent {
        title: String,
        start: String,
        end: String,
        calendar: Option<String>,
        location: Option<String>,
        notes: String,
    },
    DeleteEvent {
        id: Option<String>,
        title: Option<String>,
        on: Option<String>,
    },
    CreateReminder {
        title: String,
        due: Option<String>,
        list: Option<String>,
        notes: String,
    },
    ListEvents {
        from: Option<String>,
        to: Option<String>,
    },
    ListReminders {
        include_completed: bool,
    },
    ListDir {
        path: String,
        limit: usize,
    },
    ReadFile {
        path: String,
    },
}

impl ToolCall {
    pub fn action_name(&self) -> &'static str {
        match self {
            ToolCall::CreateNote { .. } => "create_note",
            ToolCall::AppendToNote { .. } => "append_to_note",
            ToolCall::ReplaceNoteBody { .. } => "replace_note_body",
            ToolCall::EditNote { .. } => "edit_note",
            ToolCall::DeleteNote { .. } => "delete_note",
            ToolCall::Relate { .. } => "relate",
            ToolCall::GraphSearch { .. } => "graph_search",
            ToolCall::GraphNeighbors { .. } => "graph_neighbors",
            ToolCall::SearchMail { .. } => "search_mail",
            ToolCall::ListMail { .. } => "list_mail",
            ToolCall::ReadMailThread { .. } => "read_thread",
            ToolCall::PromoteEmailThread { .. } => "promote_email_thread",
            ToolCall::CreateEvent { .. } => "create_event",
            ToolCall::DeleteEvent { .. } => "delete_event",
            ToolCall::CreateReminder { .. } => "create_reminder",
            ToolCall::ListEvents { .. } => "list_events",
            ToolCall::ListReminders { .. } => "list_reminders",
            ToolCall::ListDir { .. } => "list_dir",
            ToolCall::ReadFile { .. } => "read_file",
        }
    }
    pub fn target(&self) -> &str {
        match self {
            ToolCall::CreateNote { title, .. }
            | ToolCall::AppendToNote { title, .. }
            | ToolCall::ReplaceNoteBody { title, .. }
            | ToolCall::EditNote { title, .. }
            | ToolCall::DeleteNote { title } => title.as_str(),
            ToolCall::Relate { from, .. } => from.as_str(),
            ToolCall::GraphSearch { query, .. } => query.as_str(),
            ToolCall::GraphNeighbors { title, .. } => title.as_str(),
            ToolCall::SearchMail { query, .. } => query.as_str(),
            ToolCall::ListMail { .. } => "mail",
            ToolCall::ReadMailThread { thread_id, .. } => thread_id.as_str(),
            ToolCall::PromoteEmailThread { thread_id, .. } => thread_id.as_str(),
            ToolCall::CreateEvent { title, .. } => title.as_str(),
            ToolCall::DeleteEvent { id, title, .. } => id
                .as_deref()
                .or(title.as_deref())
                .unwrap_or("event"),
            ToolCall::CreateReminder { title, .. } => title.as_str(),
            ToolCall::ListEvents { .. } => "events",
            ToolCall::ListReminders { .. } => "reminders",
            ToolCall::ListDir { path, .. } => path.as_str(),
            ToolCall::ReadFile { path } => path.as_str(),
        }
    }
    pub fn secondary(&self) -> Option<&str> {
        match self {
            ToolCall::Relate { to, .. } => Some(to.as_str()),
            _ => None,
        }
    }
    pub fn is_read(&self) -> bool {
        matches!(self, ToolCall::ListEvents { .. } | ToolCall::ListReminders { .. })
            || matches!(self, ToolCall::ListDir { .. } | ToolCall::ReadFile { .. })
            || matches!(self, ToolCall::GraphSearch { .. } | ToolCall::GraphNeighbors { .. })
            || matches!(self, ToolCall::SearchMail { .. } | ToolCall::ListMail { .. } | ToolCall::ReadMailThread { .. })
    }

    /// Serialize the call's user-visible headers into a JSON object so
    /// the frontend can render rich cards even for write actions
    /// (which don't return any payload of their own). The body is
    /// intentionally excluded — agents tend to write a lot of
    /// freeform notes there and we don't want them in card chrome.
    pub fn headers_snapshot(&self) -> serde_json::Value {
        use serde_json::json;
        match self {
            ToolCall::CreateNote { title, source_kind, .. } => json!({
                "title": title,
                "source_kind": source_kind,
            }),
            ToolCall::AppendToNote { title, .. } => json!({ "title": title }),
            ToolCall::ReplaceNoteBody { title, .. } => json!({ "title": title }),
            ToolCall::DeleteNote { title } => json!({ "title": title }),
            ToolCall::EditNote {
                title,
                replace_all,
                ..
            } => json!({
                "title": title,
                "replace_all": replace_all,
            }),
            ToolCall::Relate {
                from,
                to,
                kind,
                context,
            } => json!({
                "from": from,
                "to": to,
                "kind": kind,
                "context": context,
            }),
            ToolCall::GraphSearch { query, limit } => json!({
                "query": query,
                "limit": limit,
            }),
            ToolCall::GraphNeighbors { title, limit } => json!({
                "title": title,
                "limit": limit,
            }),
            ToolCall::SearchMail {
                query,
                limit,
                direction,
            } => json!({
                "query": query,
                "limit": limit,
                "direction": direction,
            }),
            ToolCall::ListMail {
                hours_back,
                limit,
                direction,
            } => json!({
                "hours_back": hours_back,
                "limit": limit,
                "direction": direction,
            }),
            ToolCall::ReadMailThread { thread_id, account_id } => json!({
                "thread_id": thread_id,
                "account_id": account_id,
            }),
            ToolCall::PromoteEmailThread {
                thread_id,
                account_id,
            } => json!({
                "thread_id": thread_id,
                "account_id": account_id,
            }),
            ToolCall::CreateEvent { title, start, end, calendar, location, .. } => json!({
                "title": title,
                "start": start,
                "end": end,
                "calendar": calendar,
                "location": location,
            }),
            ToolCall::DeleteEvent { id, title, on } => json!({
                "id": id,
                "title": title,
                "on": on,
            }),
            ToolCall::CreateReminder { title, due, list, .. } => json!({
                "title": title,
                "due": due,
                "list": list,
            }),
            ToolCall::ListEvents { from, to } => json!({
                "from": from,
                "to": to,
            }),
            ToolCall::ListReminders { include_completed } => json!({
                "include_completed": include_completed,
            }),
            ToolCall::ListDir { path, limit } => json!({ "path": path, "limit": limit }),
            ToolCall::ReadFile { path } => json!({ "path": path }),
        }
    }
}

const TOOL_LABEL: &str = "clome-tool";

/// Parse every fenced clome-tool block in `text`. Block format is a
/// YAML-ish header (one `key: value` per line) optionally followed by a
/// `---` separator and a free-form body. The body can contain any
/// markdown — including triple-backtick code blocks — because we
/// terminate on the OUTER fence's matching close (3+ backticks alone on
/// a line, count >= opener). Use 4 backticks if the body has fenced code.
pub fn parse_tool_calls(text: &str) -> Vec<ToolCall> {
    extract_tool_blocks(text)
        .iter()
        .filter_map(|block| parse_block(block))
        .collect()
}

fn parse_block(block: &str) -> Option<ToolCall> {
    let mut headers: HashMap<String, String> = HashMap::new();
    let mut body_lines: Vec<&str> = Vec::new();
    let mut in_body = false;
    for line in block.lines() {
        if !in_body && line.trim() == "---" {
            in_body = true;
            continue;
        }
        if in_body {
            body_lines.push(line);
        } else {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Some(idx) = trimmed.find(':') {
                let key = trimmed[..idx].trim().to_string();
                let val = trimmed[idx + 1..].trim().to_string();
                headers.insert(key, val);
            }
        }
    }
    let body = body_lines.join("\n").trim_end().to_string();
    let action = headers.get("action").map(String::as_str)?;
    match action {
        "create_note" => Some(ToolCall::CreateNote {
            title: headers.get("title").cloned()?,
            body,
            source_kind: headers.get("source_kind").cloned(),
        }),
        "append_to_note" => Some(ToolCall::AppendToNote {
            title: headers.get("title").cloned()?,
            content: body,
        }),
        "replace_note_body" => Some(ToolCall::ReplaceNoteBody {
            title: headers.get("title").cloned()?,
            body,
        }),
        "edit_note" => {
            // The body carries two text blocks separated by a single
            // line containing exactly `<<<NEW>>>`. Everything before
            // that line is `old_string`, everything after is
            // `new_string`. Multi-line is fine — the literal headers
            // `old_string:` / `new_string:` would force single-line
            // values via the YAML-ish header parser, so the body is
            // the right home for verbatim text.
            const MARKER: &str = "<<<NEW>>>";
            let title = headers.get("title").cloned()?;
            let replace_all = headers
                .get("replace_all")
                .map(|v| matches!(v.to_lowercase().as_str(), "true" | "yes" | "1"))
                .unwrap_or(false);
            // The temporary `format!` would otherwise drop while
            // `splitn` still holds a reference to it. Bind it.
            let pat = format!("\n{MARKER}\n");
            let mut split = body.splitn(2, &pat);
            let old_string = split.next().unwrap_or("").to_string();
            let new_string = split.next().map(|s| s.to_string());
            // Tolerate a marker at the very start (empty old) by
            // catching the leading `<<<NEW>>>\n` form too.
            let (old_string, new_string) = match new_string {
                Some(n) => (old_string, n),
                None => {
                    // Try splitting on just `<<<NEW>>>` on its own
                    // line at any position (handles trailing
                    // newline differences).
                    let body_str = body.as_str();
                    if let Some(idx) = find_line(body_str, MARKER) {
                        let (head, tail) = body_str.split_at(idx);
                        // Strip the marker line itself.
                        let tail = tail
                            .strip_prefix(MARKER)
                            .unwrap_or(tail)
                            .trim_start_matches('\n');
                        (
                            head.trim_end_matches('\n').to_string(),
                            tail.to_string(),
                        )
                    } else {
                        // Missing marker — abort so the agent sees a
                        // clear "no marker" error instead of an
                        // accidentally-empty replacement.
                        return None;
                    }
                }
            };
            Some(ToolCall::EditNote {
                title,
                old_string,
                new_string,
                replace_all,
            })
        }
        "delete_note" => Some(ToolCall::DeleteNote {
            title: headers.get("title").cloned()?,
        }),
        "relate" => {
            let kind = headers
                .get("kind")
                .map(|s| s.to_lowercase())
                .filter(|k| crate::graph::is_valid_kind(k))
                .unwrap_or_else(|| "references".into());
            Some(ToolCall::Relate {
                from: headers.get("from").cloned()?,
                to: headers.get("to").cloned()?,
                kind,
                context: headers.get("context").cloned(),
            })
        }
        "graph_search" => Some(ToolCall::GraphSearch {
            query: headers.get("query").cloned()?,
            limit: headers
                .get("limit")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(10)
                .clamp(1, 50),
        }),
        "graph_neighbors" => Some(ToolCall::GraphNeighbors {
            title: headers.get("title").cloned()?,
            limit: headers
                .get("limit")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(20)
                .clamp(1, 100),
        }),
        "search_mail" => Some(ToolCall::SearchMail {
            query: headers.get("query").cloned()?,
            limit: headers
                .get("limit")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(15)
                .clamp(1, 50),
            direction: headers.get("direction").cloned(),
        }),
        "list_mail" => Some(ToolCall::ListMail {
            hours_back: headers
                .get("hours_back")
                .and_then(|v| v.parse::<i64>().ok())
                .unwrap_or(24)
                .clamp(1, 30 * 24),
            limit: headers
                .get("limit")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(30)
                .clamp(1, 100),
            direction: headers.get("direction").cloned(),
        }),
        "promote_email_thread" => Some(ToolCall::PromoteEmailThread {
            thread_id: headers.get("thread_id").cloned()?,
            account_id: headers.get("account_id").cloned(),
        }),
        "create_event" => Some(ToolCall::CreateEvent {
            title: headers.get("title").cloned()?,
            start: headers.get("start").cloned()?,
            end: headers.get("end").cloned()?,
            calendar: headers.get("calendar").cloned(),
            location: headers.get("location").cloned(),
            notes: body,
        }),
        "delete_event" => {
            let id = headers.get("id").cloned();
            let title = headers.get("title").cloned();
            // Need at least one of id / title — otherwise the sidecar
            // has nothing to match against and will error anyway.
            if id.is_none() && title.is_none() {
                return None;
            }
            Some(ToolCall::DeleteEvent {
                id,
                title,
                on: headers.get("on").cloned(),
            })
        }
        "create_reminder" => Some(ToolCall::CreateReminder {
            title: headers.get("title").cloned()?,
            due: headers.get("due").cloned(),
            list: headers.get("list").cloned(),
            notes: body,
        }),
        "list_events" => Some(ToolCall::ListEvents {
            from: headers.get("from").cloned(),
            to: headers.get("to").cloned(),
        }),
        "list_reminders" => Some(ToolCall::ListReminders {
            include_completed: headers
                .get("include_completed")
                .map(|v| matches!(v.to_lowercase().as_str(), "true" | "yes" | "1"))
                .unwrap_or(false),
        }),
        "list_dir" => Some(ToolCall::ListDir {
            path: headers.get("path").cloned()?,
            limit: headers
                .get("limit")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(80)
                .clamp(1, 200),
        }),
        "read_file" => Some(ToolCall::ReadFile {
            path: headers.get("path").cloned()?,
        }),
        _ => None,
    }
}

/// Parse a structured OpenAI function call into a ToolCall. The
/// `arguments` string is the JSON object the model emitted in the
/// `tool_calls` delta. This is the native tool-calling path; the older
/// `parse_block` (free-text fences) is kept only for legacy DB rows.
pub fn from_function_call(name: &str, arguments: &str) -> Option<ToolCall> {
    let v: serde_json::Value =
        serde_json::from_str(arguments.trim()).unwrap_or_else(|_| serde_json::json!({}));
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    let req_s = |k: &str| s(k);
    let usize_or = |k: &str, default: usize, max: usize| -> usize {
        let raw = v
            .get(k)
            .and_then(|x| x.as_u64().map(|n| n as usize).or_else(|| x.as_str().and_then(|t| t.parse().ok())))
            .unwrap_or(default);
        raw.clamp(1, max)
    };
    let i64_or = |k: &str, default: i64, max: i64| -> i64 {
        let raw = v
            .get(k)
            .and_then(|x| x.as_i64().or_else(|| x.as_str().and_then(|t| t.parse().ok())))
            .unwrap_or(default);
        raw.clamp(1, max)
    };
    let bool_or = |k: &str, default: bool| -> bool {
        v.get(k)
            .and_then(|x| {
                x.as_bool()
                    .or_else(|| x.as_str().map(|t| matches!(t.to_lowercase().as_str(), "true" | "yes" | "1")))
            })
            .unwrap_or(default)
    };

    match name {
        "create_note" => Some(ToolCall::CreateNote {
            title: req_s("title")?,
            body: s("body").unwrap_or_default(),
            source_kind: s("source_kind"),
        }),
        "append_to_note" => Some(ToolCall::AppendToNote {
            title: req_s("title")?,
            content: s("content").unwrap_or_default(),
        }),
        "replace_note_body" => Some(ToolCall::ReplaceNoteBody {
            title: req_s("title")?,
            body: s("body").unwrap_or_default(),
        }),
        "edit_note" => Some(ToolCall::EditNote {
            title: req_s("title")?,
            old_string: s("old_string").unwrap_or_default(),
            new_string: s("new_string").unwrap_or_default(),
            replace_all: bool_or("replace_all", false),
        }),
        "delete_note" => Some(ToolCall::DeleteNote {
            title: req_s("title")?,
        }),
        "relate" => Some(ToolCall::Relate {
            from: req_s("from")?,
            to: req_s("to")?,
            kind: s("kind")
                .map(|k| k.to_lowercase())
                .filter(|k| crate::graph::is_valid_kind(k))
                .unwrap_or_else(|| "references".into()),
            context: s("context"),
        }),
        "graph_search" => Some(ToolCall::GraphSearch {
            query: req_s("query")?,
            limit: usize_or("limit", 10, 50),
        }),
        "graph_neighbors" => Some(ToolCall::GraphNeighbors {
            title: req_s("title")?,
            limit: usize_or("limit", 20, 100),
        }),
        "search_mail" => Some(ToolCall::SearchMail {
            query: req_s("query")?,
            limit: usize_or("limit", 15, 50),
            direction: s("direction"),
        }),
        "list_mail" => Some(ToolCall::ListMail {
            hours_back: i64_or("hours_back", 24, 30 * 24),
            limit: usize_or("limit", 30, 100),
            direction: s("direction"),
        }),
        "read_thread" => Some(ToolCall::ReadMailThread {
            thread_id: req_s("thread_id")?,
            account_id: s("account_id"),
        }),
        "promote_email_thread" => Some(ToolCall::PromoteEmailThread {
            thread_id: req_s("thread_id")?,
            account_id: s("account_id"),
        }),
        "create_event" => Some(ToolCall::CreateEvent {
            title: req_s("title")?,
            start: req_s("start")?,
            end: req_s("end")?,
            calendar: s("calendar"),
            location: s("location"),
            notes: s("notes").unwrap_or_default(),
        }),
        "delete_event" => {
            let id = s("id");
            let title = s("title");
            if id.is_none() && title.is_none() {
                return None;
            }
            Some(ToolCall::DeleteEvent {
                id,
                title,
                on: s("on"),
            })
        }
        "create_reminder" => Some(ToolCall::CreateReminder {
            title: req_s("title")?,
            due: s("due"),
            list: s("list"),
            notes: s("notes").unwrap_or_default(),
        }),
        "list_events" => Some(ToolCall::ListEvents {
            from: s("from"),
            to: s("to"),
        }),
        "list_reminders" => Some(ToolCall::ListReminders {
            include_completed: bool_or("include_completed", false),
        }),
        "list_dir" => Some(ToolCall::ListDir {
            path: req_s("path")?,
            limit: usize_or("limit", 80, 200),
        }),
        "read_file" => Some(ToolCall::ReadFile {
            path: req_s("path")?,
        }),
        _ => None,
    }
}

/// Build OpenAI-shape JSON-schema tool definitions for the bound agent.
/// Vault tools (notes/graph/relate) are always included; capability-
/// gated tools are added only if the agent has the corresponding cap.
/// mlx_lm.server passes this list through to Qwen's chat template,
/// which formats them into the model's native `<tools>` system block.
pub fn tool_schemas(agent_caps: &[String]) -> Vec<serde_json::Value> {
    use serde_json::json;

    fn func(name: &str, description: &str, properties: serde_json::Value, required: &[&str]) -> serde_json::Value {
        json!({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": {
                    "type": "object",
                    "properties": properties,
                    "required": required,
                },
            },
        })
    }

    let mut out = vec![
        // ── Vault (always available) ─────────────────────────────────
        func(
            "graph_search",
            "Hybrid (BM25 + vector + 1-hop) search over the user's notes vault. Use BEFORE answering any question that names a topic, person, project, or specific entity — the user's vault is a private knowledge graph and answering from training data when their notes have the answer is a failure mode.",
            json!({
                "query": {"type": "string", "description": "Free-text query — what the user is asking about"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
            }),
            &["query"],
        ),
        func(
            "graph_neighbors",
            "Pull the 1-hop neighborhood of a specific note (when the user already named it via [[Title]]). Targeted form of graph_search.",
            json!({
                "title": {"type": "string", "description": "Exact note title"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20},
            }),
            &["title"],
        ),
        func(
            "create_note",
            "Create a new note in the user's vault. Idempotent on title — re-creating returns the existing note.",
            json!({
                "title": {"type": "string"},
                "body": {"type": "string", "description": "Markdown content. Can be empty."},
                "source_kind": {"type": "string", "description": "Optional provenance label (e.g. 'manual', 'capture')"},
            }),
            &["title"],
        ),
        func(
            "append_to_note",
            "Append content to an existing note. Use for additive edits.",
            json!({
                "title": {"type": "string"},
                "content": {"type": "string", "description": "Markdown to append. Will be separated by a blank line from the existing body."},
            }),
            &["title", "content"],
        ),
        func(
            "edit_note",
            "Find-and-replace inside an existing note. Use for targeted single edits — prefer this over replace_note_body when the change is narrow. `old_string` must match byte-for-byte; if a single-occurrence match is ambiguous include enough surrounding context to disambiguate.",
            json!({
                "title": {"type": "string"},
                "old_string": {"type": "string", "description": "Exact text to find. Multi-line OK."},
                "new_string": {"type": "string", "description": "Replacement text."},
                "replace_all": {"type": "boolean", "default": false},
            }),
            &["title", "old_string", "new_string"],
        ),
        func(
            "replace_note_body",
            "Full overwrite of a note's body. Last resort — only when the rewrite is so pervasive that find-and-replace would need many edit_note calls.",
            json!({
                "title": {"type": "string"},
                "body": {"type": "string"},
            }),
            &["title", "body"],
        ),
        func(
            "delete_note",
            "Delete a note from the vault.",
            json!({"title": {"type": "string"}}),
            &["title"],
        ),
        func(
            "relate",
            "Create a typed edge between two notes. Use only when the wikilink form doesn't fit (non-default kind or you want a context snippet). Allowed kinds: mentions, references (default), about, attended, attached, derived_from, replied_to, child_of, alias_of.",
            json!({
                "from": {"type": "string", "description": "Source note title"},
                "to": {"type": "string", "description": "Target note title"},
                "kind": {"type": "string", "default": "references"},
                "context": {"type": "string"},
            }),
            &["from", "to"],
        ),
    ];

    let has = |k: &str| agent_caps.iter().any(|c| c == k);

    if has("calendar.read") {
        out.push(func(
            "list_events",
            "List calendar events in a date range. Date headers MUST be ISO 8601 in the user's timezone — naive `YYYY-MM-DDTHH:MM:SS` or with offset. Never use `Z` (UTC) for user-facing times.",
            json!({
                "from": {"type": "string", "description": "ISO 8601 lower bound"},
                "to": {"type": "string", "description": "ISO 8601 upper bound"},
            }),
            &[],
        ));
    }
    if has("calendar.write") {
        out.push(func(
            "create_event",
            "Add an event to the user's calendar.",
            json!({
                "title": {"type": "string"},
                "start": {"type": "string", "description": "ISO 8601 start in user's timezone"},
                "end": {"type": "string", "description": "ISO 8601 end in user's timezone"},
                "calendar": {"type": "string"},
                "location": {"type": "string"},
                "notes": {"type": "string"},
            }),
            &["title", "start", "end"],
        ));
        out.push(func(
            "delete_event",
            "Remove an event. Provide `id` (preferred) OR `title` + `on`.",
            json!({
                "id": {"type": "string"},
                "title": {"type": "string"},
                "on": {"type": "string", "description": "ISO 8601 date the event falls on"},
            }),
            &[],
        ));
    }
    if has("reminders.read") {
        out.push(func(
            "list_reminders",
            "List the user's reminders.",
            json!({
                "include_completed": {"type": "boolean", "default": false},
            }),
            &[],
        ));
    }
    if has("reminders.write") {
        out.push(func(
            "create_reminder",
            "Add a reminder.",
            json!({
                "title": {"type": "string"},
                "due": {"type": "string", "description": "ISO 8601 due time"},
                "list": {"type": "string"},
                "notes": {"type": "string"},
            }),
            &["title"],
        ));
    }
    if has("email.read") {
        // Order matters — list local Qwen-class models tend to pick the
        // first matching tool. search_mail is the workhorse for any
        // user question that names a person, topic, or keyword (which
        // is most agent mail questions), so it goes first.
        out.push(func(
            "search_mail",
            "PRIMARY mail tool. Full-text search across the user's mail.db (subject, body, from, to). Use whenever the user names a person, sender, topic, organization, or any content keyword — `emails from Sarah`, `anything about Acme`, `reimbursement from Princeton`, `Stripe receipt`, `did X reply`. Returns thread heads with `thread_id`, `account_id`, `from_addr`, `subject`, `snippet`, `date_received`, and `direction` (`inbox` = received, `sent` = outgoing).",
            json!({
                "query": {"type": "string", "description": "Content / sender / subject keywords. Plain words; supports `from:foo`, `subject:bar`, `is:unread`, `has:attachment`."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 15},
                "direction": {"type": "string", "enum": ["received", "sent", "any"], "default": "any", "description": "Default `any` — searches both inbox and sent so 'did X reply about Y' finds both sides of the thread."},
            }),
            &["query"],
        ));
        out.push(func(
            "read_thread",
            "Read every message in one email thread, oldest to newest. Returns each message's `from_addr`, `subject`, `date_received`, `direction` (`inbox`/`sent`), `snippet`, and a truncated `body_text`. Use this AFTER `search_mail` returned a thread the user is asking about, to determine whether the other party replied, what they said, or to summarize the conversation. `thread_id` MUST come from a search_mail/list_mail result this turn — never invent it.",
            json!({
                "thread_id": {"type": "string"},
                "account_id": {"type": "string", "description": "Optional — auto-resolved from thread_id if omitted."},
            }),
            &["thread_id"],
        ));
        out.push(func(
            "list_mail",
            "Time-windowed listing — for purely TEMPORAL queries with NO content filter ('what came in today', 'mail from this week'). DO NOT call this when the user names a person, topic, or keyword — use `search_mail` for that. Returns thread heads with the same fields as search_mail (including `direction`).",
            json!({
                "hours_back": {"type": "integer", "minimum": 1, "maximum": 720, "default": 24},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 30},
                "direction": {"type": "string", "enum": ["received", "sent", "any"], "default": "received"},
            }),
            &[],
        ));
        out.push(func(
            "promote_email_thread",
            "Add an email thread to the knowledge graph so it's queryable via graph_search. Idempotent. thread_id MUST come from a search_mail or list_mail result run THIS turn — never invent it.",
            json!({
                "thread_id": {"type": "string"},
                "account_id": {"type": "string"},
            }),
            &["thread_id"],
        ));
    }
    if has("filesystem.read") {
        out.push(func(
            "list_dir",
            "List directory entries under an allowed root.",
            json!({
                "path": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 80},
            }),
            &["path"],
        ));
        out.push(func(
            "read_file",
            "Read a text file (max 512 KiB).",
            json!({"path": {"type": "string"}}),
            &["path"],
        ));
    }

    out
}

/// Find the byte index of a line whose trimmed content equals `needle`.
/// Used by the edit_note parser to locate the `<<<NEW>>>` separator
/// line robustly (i.e. tolerating a missing trailing newline).
fn find_line(haystack: &str, needle: &str) -> Option<usize> {
    let mut start = 0usize;
    for line in haystack.split_inclusive('\n') {
        let trimmed = line.trim_end_matches(['\n', '\r']).trim();
        if trimmed == needle {
            return Some(start);
        }
        start += line.len();
    }
    None
}

/// Extract the inner content of every ```clome-tool ... ``` block. The
/// closing fence count must match the opener count (>=3). Body content
/// can contain ANY characters including inner triple-backtick fences.
pub fn extract_tool_blocks(text: &str) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let at_line_start = i == 0 || chars[i - 1] == '\n';
        if !at_line_start {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < chars.len() && (chars[j] == ' ' || chars[j] == '\t') {
            j += 1;
        }
        let tick_start = j;
        while j < chars.len() && chars[j] == '`' {
            j += 1;
        }
        let tick_count = j - tick_start;
        if tick_count < 3 {
            i += 1;
            continue;
        }
        let label: Vec<char> = TOOL_LABEL.chars().collect();
        if j + label.len() > chars.len() || chars[j..j + label.len()] != label[..] {
            i += 1;
            continue;
        }
        // rest of opener line must be whitespace
        let mut k = j + label.len();
        let mut clean_open = true;
        while k < chars.len() && chars[k] != '\n' {
            if chars[k] != ' ' && chars[k] != '\t' {
                clean_open = false;
                break;
            }
            k += 1;
        }
        if !clean_open {
            i += 1;
            continue;
        }
        let content_start = if k < chars.len() { k + 1 } else { k };
        // search for closing fence: line of >=tick_count backticks, only whitespace after
        let mut p = content_start;
        let mut content_end: Option<usize> = None;
        let mut after_close: Option<usize> = None;
        let mut line_start = p;
        while p <= chars.len() {
            if p == chars.len() || chars[p] == '\n' {
                // examine [line_start..p)
                let mut q = line_start;
                while q < p && (chars[q] == ' ' || chars[q] == '\t') {
                    q += 1;
                }
                let cnt_start = q;
                while q < p && chars[q] == '`' {
                    q += 1;
                }
                let cnt = q - cnt_start;
                if cnt >= tick_count {
                    let mut clean = true;
                    let mut r = q;
                    while r < p {
                        if chars[r] != ' ' && chars[r] != '\t' {
                            clean = false;
                            break;
                        }
                        r += 1;
                    }
                    if clean {
                        content_end = Some(line_start);
                        after_close = Some(if p < chars.len() { p + 1 } else { p });
                        break;
                    }
                }
                p += 1;
                line_start = p;
            } else {
                p += 1;
            }
        }
        if let (Some(end), Some(after)) = (content_end, after_close) {
            let content: String = chars[content_start..end].iter().collect();
            // Strip trailing newline before the close fence (cosmetic)
            blocks.push(content.trim_end_matches('\n').to_string());
            i = after;
        } else {
            // No matching close fence found. Weak local models
            // sometimes emit a 4-backtick opener and then close with
            // only 3 backticks (or forget to close at all, especially
            // after fabricating a fake JSON body inside the block).
            // We're parsing the FULL post-stream text, so an unclosed
            // opener at this point is final — treat end-of-text as an
            // implicit close so the headers still produce a valid
            // ToolCall instead of silently dropping the call.
            let content: String = chars[content_start..].iter().collect();
            blocks.push(content.trim_end_matches('\n').to_string());
            break;
        }
    }
    blocks
}

/// Execute a tool call. Returns Some(json_string) for READ tools whose
/// result needs to feed back to the model in a follow-up turn. Returns
/// None for fire-and-forget WRITE tools.
pub async fn execute(
    app: &AppHandle,
    db: &Surreal<Db>,
    workspace_id: &Thing,
    call: ToolCall,
    by: &str,
    agent_caps: &[String],
) -> Option<String> {
    // Capability gate. Vault tools (cap_for_action returns None) always pass.
    let action = call.action_name();
    if let Some(required) = caps::cap_for_action(action) {
        if !agent_caps.iter().any(|c| c == required) {
            eprintln!(
                "[tools] denied: action {action} requires capability {required} (agent has {:?})",
                agent_caps
            );
            // Always emit a structured denial result so the frontend
            // can render a clear "denied" card — both for reads
            // (which feed back to the model) and writes (which
            // otherwise fail silently). The card uses this shape:
            //   { denied: true, capability: "calendar.read", action: "list_events" }
            return Some(format!(
                "{{\"denied\": true, \"capability\": \"{required}\", \"action\": \"{action}\"}}"
            ));
        }
    }

    match call {
        ToolCall::CreateNote {
            title,
            body,
            source_kind,
        } => {
            let _ = db::create_note(
                db,
                workspace_id,
                &title,
                &body,
                source_kind.as_deref().unwrap_or("chat"),
                by,
            )
            .await;
            None
        }
        ToolCall::AppendToNote { title, content } => {
            let _ = db::append_to_note(db, workspace_id, &title, &content, by).await;
            None
        }
        ToolCall::ReplaceNoteBody { title, body } => {
            let _ = db::update_note_body(db, workspace_id, &title, &body, by).await;
            None
        }
        ToolCall::EditNote {
            title,
            old_string,
            new_string,
            replace_all,
        } => {
            // Echo a structured result back so the model (and the
            // tool-card renderer) can show "edited" vs "no match" vs
            // "ambiguous". Vault writes normally fire-and-forget, but
            // edit_note is interesting precisely because it can fail
            // for a recoverable reason — agents need that signal to
            // try again with more context.
            match db::edit_note(
                db,
                workspace_id,
                &title,
                &old_string,
                &new_string,
                replace_all,
                by,
            )
            .await
            {
                Ok(_) => Some(format!(
                    "{{\"ok\": true, \"title\": \"{}\", \"replace_all\": {replace_all}}}",
                    title.replace('"', "\\\"")
                )),
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::DeleteNote { title } => {
            let _ = db::delete_note_by_title(db, workspace_id, &title).await;
            None
        }
        ToolCall::Relate {
            from,
            to,
            kind,
            context,
        } => {
            let _ = db::relate_notes(
                db,
                workspace_id,
                &from,
                &to,
                &kind,
                context.as_deref(),
                by,
            )
            .await;
            None
        }
        ToolCall::GraphSearch { query, limit } => {
            match crate::graph::search_with_expansion(db, workspace_id, &query, limit).await {
                Ok(slice) => Some(serde_json::to_string(&slice).unwrap_or_else(|_| "{}".into())),
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::SearchMail {
            query,
            limit,
            direction,
        } => {
            // Hits mail.db FTS via the same path the user-facing
            // `mail_search` tauri command uses. Returns thread-grouped
            // headers — agent then picks the relevant thread_ids and
            // emits `promote_email_thread` to bring them into the graph.
            use tauri::Manager;
            let mail_state = app.state::<crate::mail::db::MailDb>();
            let q = query.clone();
            let lim = limit as i64;
            let dir = crate::mail::search::Direction::parse(direction.as_deref());
            let res = mail_state
                .with_conn(move |conn| {
                    crate::mail::search::search(conn, None, &q, lim, 0, dir)
                })
                .await;
            match res {
                Ok(headers) => {
                    // Trim payload — agents only need enough to pick a
                    // thread. Keep thread_id, account_id, subject, from,
                    // snippet, date_received.
                    let trimmed: Vec<serde_json::Value> = headers
                        .iter()
                        .map(|h| {
                            serde_json::json!({
                                "thread_id": h.thread_id,
                                "account_id": h.account_id,
                                "subject": h.subject,
                                "from_addr": h.from_addr,
                                "from_name": h.from_name,
                                "snippet": h.snippet,
                                "date_received": h.date_received,
                                "direction": h.direction,
                                "unread": h.unread,
                            })
                        })
                        .collect();
                    Some(serde_json::Value::Array(trimmed).to_string())
                }
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::ListMail {
            hours_back,
            limit,
            direction,
        } => {
            // Pure date-window listing — no FTS. The agent uses this
            // for "what came in today / this week" queries; the
            // search_mail tool stays for content matching. Returns
            // thread heads (latest message per thread) so a chatty
            // conversation doesn't dominate the result. `direction`
            // pins the listing to received (inbox), sent, or both.
            use tauri::Manager;
            let mail_state = app.state::<crate::mail::db::MailDb>();
            let lim = limit as i64;
            let dir = crate::mail::search::Direction::parse(direction.as_deref());
            let res = mail_state
                .with_conn(move |conn| {
                    crate::mail::search::list_recent(conn, None, hours_back, lim, dir)
                })
                .await;
            match res {
                Ok(headers) => {
                    let trimmed: Vec<serde_json::Value> = headers
                        .iter()
                        .map(|h| {
                            serde_json::json!({
                                "thread_id": h.thread_id,
                                "account_id": h.account_id,
                                "subject": h.subject,
                                "from_addr": h.from_addr,
                                "from_name": h.from_name,
                                "snippet": h.snippet,
                                "date_received": h.date_received,
                                "direction": h.direction,
                                "unread": h.unread,
                            })
                        })
                        .collect();
                    Some(serde_json::Value::Array(trimmed).to_string())
                }
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::ReadMailThread { thread_id, account_id } => {
            use tauri::Manager;
            let mail_state = app.state::<crate::mail::db::MailDb>();
            let tid = thread_id.clone();
            let acc = account_id.clone();
            let res = mail_state
                .with_conn(move |conn| {
                    crate::mail::search::thread_messages(conn, &tid, acc.as_deref(), 2000)
                })
                .await;
            match res {
                Ok(msgs) if msgs.is_empty() => {
                    Some("{\"error\":\"thread not found in mail.db — verify the thread_id from a recent search_mail/list_mail result\"}".into())
                }
                Ok(msgs) => {
                    let trimmed: Vec<serde_json::Value> = msgs
                        .iter()
                        .map(|m| {
                            serde_json::json!({
                                "message_id": m.message_id,
                                "from_addr": m.from_addr,
                                "from_name": m.from_name,
                                "subject": m.subject,
                                "date_received": m.date_received,
                                "direction": m.direction,
                                "snippet": m.snippet,
                                "body_text": m.body_text,
                            })
                        })
                        .collect();
                    Some(serde_json::Value::Array(trimmed).to_string())
                }
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::PromoteEmailThread {
            thread_id,
            account_id,
        } => {
            // ALWAYS verify the thread exists in mail.db. Without this
            // the agent could hallucinate a plausible-looking
            // thread_id (e.g. "rany-stephan-booking-cancellation")
            // and we'd accept it. Looking it up here forces the
            // agent to use real ids returned by `search_mail`.
            use tauri::Manager;
            let mail_state = app.state::<crate::mail::db::MailDb>();
            let tid_owned = thread_id.clone();
            let want_account = account_id.clone();
            // MailDb::with_conn already projects the rusqlite error
            // into a String — match that here so the type checker
            // doesn't have to chase the inner type through with_conn.
            let mail_lookup: Result<Vec<String>, String> = mail_state
                .with_conn(move |conn| {
                    let mut stmt = conn.prepare(
                        "SELECT DISTINCT account_id FROM message \
                         WHERE thread_id = ?1",
                    )?;
                    let rows = stmt.query_map(rusqlite::params![&tid_owned], |r| {
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
                .await;

            let accounts_for_thread = match mail_lookup {
                Ok(v) => v,
                Err(e) => {
                    return Some(format!(
                        "{{\"error\": \"mail.db lookup failed: {}\"}}",
                        e.replace('"', "\\\"")
                    ))
                }
            };
            if accounts_for_thread.is_empty() {
                return Some(format!(
                    "{{\"error\": \"thread_id \\\"{}\\\" doesn't exist — \
                     run `search_mail` first and copy the thread_id from a \
                     real result. Do NOT invent thread_ids.\"}}",
                    thread_id.replace('"', "\\\"")
                ));
            }
            // If the agent passed an explicit account_id, it must
            // match. Otherwise pick the first (mail accounts are
            // workspace-global today; threads don't span accounts).
            let acc = match want_account {
                Some(a) if accounts_for_thread.iter().any(|x| x == &a) => a,
                Some(a) => {
                    return Some(format!(
                        "{{\"error\": \"thread \\\"{}\\\" exists but not under account \\\"{}\\\" \
                         — known accounts: {}\"}}",
                        thread_id.replace('"', "\\\""),
                        a.replace('"', "\\\""),
                        accounts_for_thread.join(", ")
                    ))
                }
                None => accounts_for_thread.into_iter().next().unwrap(),
            };

            match crate::db::promote_email_thread(db, &thread_id, &acc).await {
                Ok(crate::db::PromoteOutcome::Promoted) => Some(format!(
                    "{{\"ok\": true, \"thread_id\": \"{}\", \"already_promoted\": false}}",
                    thread_id.replace('"', "\\\"")
                )),
                Ok(crate::db::PromoteOutcome::AlreadyPromoted) => Some(format!(
                    "{{\"ok\": true, \"thread_id\": \"{}\", \"already_promoted\": true}}",
                    thread_id.replace('"', "\\\"")
                )),
                Ok(crate::db::PromoteOutcome::NotFound) => Some(format!(
                    "{{\"error\": \"shadow row missing — sync mail and retry. thread_id=\\\"{}\\\" account=\\\"{}\\\"\"}}",
                    thread_id.replace('"', "\\\""),
                    acc.replace('"', "\\\"")
                )),
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::GraphNeighbors { title, limit } => {
            // Title-keyed entry point for agents — resolve to a record id
            // first, then return the 1-hop slice. Missing titles surface
            // as an empty result, not an error.
            let result = match db::get_note(db, workspace_id, &title).await {
                Ok(Some(note)) => crate::graph::neighbors(db, &note.id, None, limit)
                    .await
                    .map(Some),
                Ok(None) => Ok(None),
                Err(e) => Err(e),
            };
            match result {
                Ok(Some(slice)) => {
                    Some(serde_json::to_string(&slice).unwrap_or_else(|_| "{}".into()))
                }
                Ok(None) => Some(format!(
                    "{{\"error\": \"no node with title \\\"{}\\\"\"}}",
                    title.replace('"', "\\\"")
                )),
                Err(e) => Some(format!(
                    "{{\"error\": \"{}\"}}",
                    e.to_string().replace('"', "\\\"")
                )),
            }
        }
        ToolCall::CreateEvent {
            title,
            start,
            end,
            calendar,
            location,
            notes,
        } => {
            let res = caps::eventkit_create_event(
                app,
                &title,
                &start,
                &end,
                calendar.as_deref(),
                location.as_deref(),
                &notes,
            )
            .await;
            if let Err(e) = res {
                eprintln!("[tools] create_event failed: {e}");
            }
            None
        }
        ToolCall::DeleteEvent { id, title, on } => {
            let res = caps::eventkit_delete_event(
                app,
                id.as_deref(),
                title.as_deref(),
                on.as_deref(),
            )
            .await;
            if let Err(e) = res {
                eprintln!("[tools] delete_event failed: {e}");
            }
            None
        }
        ToolCall::CreateReminder {
            title,
            due,
            list,
            notes,
        } => {
            let res =
                caps::eventkit_create_reminder(app, &title, due.as_deref(), list.as_deref(), &notes)
                    .await;
            if let Err(e) = res {
                eprintln!("[tools] create_reminder failed: {e}");
            }
            None
        }
        ToolCall::ListEvents { from, to } => {
            let res = caps::eventkit_list_events(app, from.as_deref(), to.as_deref()).await;
            match res {
                Ok(json) => {
                    eprintln!(
                        "[tools] list_events → {} chars: {}",
                        json.len(),
                        &json[..json.len().min(400)]
                    );
                    Some(json)
                }
                Err(e) => {
                    eprintln!("[tools] list_events ERR: {e}");
                    Some(format!("{{\"error\": \"{}\"}}", e.replace('"', "\\\"")))
                }
            }
        }
        ToolCall::ListReminders { include_completed } => {
            let res = caps::eventkit_list_reminders(app, include_completed).await;
            match res {
                Ok(json) => {
                    eprintln!(
                        "[tools] list_reminders → {} chars: {}",
                        json.len(),
                        &json[..json.len().min(400)]
                    );
                    Some(json)
                }
                Err(e) => {
                    eprintln!("[tools] list_reminders ERR: {e}");
                    Some(format!("{{\"error\": \"{}\"}}", e.replace('"', "\\\"")))
                }
            }
        }
        ToolCall::ListDir { path, limit } => {
            let res = caps::fs_list_dir(&path, limit).await;
            match res {
                Ok(json) => {
                    eprintln!(
                        "[tools] list_dir → {} chars: {}",
                        json.len(),
                        &json[..json.len().min(400)]
                    );
                    Some(json)
                }
                Err(e) => {
                    eprintln!("[tools] list_dir ERR: {e}");
                    Some(format!("{{\"error\": \"{}\"}}", e.replace('"', "\\\"")))
                }
            }
        }
        ToolCall::ReadFile { path } => {
            let res = caps::fs_read_file(&path).await;
            match res {
                Ok(json) => {
                    eprintln!(
                        "[tools] read_file → {} chars: {}",
                        json.len(),
                        &json[..json.len().min(400)]
                    );
                    Some(json)
                }
                Err(e) => {
                    eprintln!("[tools] read_file ERR: {e}");
                    Some(format!("{{\"error\": \"{}\"}}", e.replace('"', "\\\"")))
                }
            }
        }
    }
}

pub fn tool_docs() -> &'static str {
    r#"## VAULT TOOLS

You can write to the user's notes vault by emitting fenced clome-tool
blocks. Use **four backticks** for the wrapper so any inner
triple-backtick code block doesn't close the outer fence.

Format — YAML-ish header, optional body separated by `---`:

````clome-tool
action: <action_name>
title: <note title>
[other_field: value]
---
<optional free-form body / content — any markdown, code, math>
````

Header rules:
- One `key: value` per line. Values are plain text — no quoting, no
  escaping. The `:` is the first one on the line; everything after it
  (trimmed) is the value.
- Header keys are single-line. For multi-line content use the body
  section below `---`.

Body rules:
- Everything after a line containing only `---` is the body, until the
  closing fence.
- The body is verbatim — paste any markdown including ```python or
  ```rust fences, LaTeX math, anything.
- Omit the `---` line entirely if the action has no body.

Actions and required fields:
- `graph_search`     : query, [limit]   (READ — hybrid: BM25 + vector + 1-hop expansion)
- `graph_neighbors`  : title, [limit]   (READ — 1-hop neighborhood of one note)
- `create_note`      : title, [source_kind], [body]
- `append_to_note`   : title, body  (the body is what gets appended)
- `edit_note`        : title, [replace_all]; body = old <<<NEW>>> new
- `replace_note_body`: title, body  (full overwrite — last resort)
- `delete_note`      : title
- `relate`           : from, to, [kind], [context]

**Use `graph_search` BEFORE answering** any question that names a topic,
person, project, paper, or specific entity. The user's vault is a
knowledge graph grown from their own notes, chats, and captures —
answering from generic training data when their notes contain the
answer is a failure mode. Workflow:
  1. User asks about a topic →
  2. Emit `graph_search` with the topic as the query, STOP and wait →
  3. System feeds back matching nodes + 1-hop edges →
  4. Synthesize an answer that **cites the matching notes with `[[wikilink]]`**
     so the user can click through.
Skip `graph_search` only for: pure conversational chit-chat, math, or
the user explicitly asking about something with no plausible vault
hit (e.g. "what's the weather").

`graph_neighbors` is the targeted form — when the user already named
a specific note (`[[Some Title]]`), pull its neighborhood directly
instead of re-searching by string.

`relate` connects two notes via a typed edge. Allowed `kind` values:
`mentions`, `references` (default), `about`, `attended`, `attached`,
`derived_from`, `replied_to`, `child_of`, `alias_of`. The system also
auto-creates `mentions` edges from any `[[wikilink]]` in a saved note
or chat message — only emit `relate` when the wikilink form doesn't
fit (e.g. you want a non-default `kind` or a snippet of context).

Examples:

````clome-tool
action: create_note
title: Stephen Boyd
---
Stanford EE professor. Co-author of *Convex Optimization*.
````

````clome-tool
action: append_to_note
title: convex-optimization
---
Here is a cvxpy example:

```python
import cvxpy as cp
x = cp.Variable()
prob = cp.Problem(cp.Minimize((x - 2)**2), [x >= 0])
prob.solve()
```

This minimizes (x-2)² subject to x ≥ 0.
````

````clome-tool
action: edit_note
title: convex-optimization
---
Authored by [[Stephen Boyd]] and Lieven Vandenberghe.
<<<NEW>>>
Authored by [[Stephen Boyd]] and Lieven Vandenberghe (2004 textbook, free PDF online).
````

````clome-tool
action: relate
from: stephen-boyd
to: convex-optimization
kind: about
context: textbook author
````

````clome-tool
action: graph_search
query: convex optimization courses
limit: 10
````

````clome-tool
action: graph_neighbors
title: convex-optimization
limit: 20
````

Rules:
- Only emit when the user asks to save / record / fix / delete.
- If the user wants to "redo" or "fix" a note, prefer
  `replace_note_body` over delete + create.
- Multiple blocks per reply are fine.
- Reference notes in your prose with `[[wikilink]]` syntax.
- Tool blocks execute exactly once after your reply finishes.

## ABSOLUTE RULES — read carefully

1. **READ tools** (`graph_search`, `graph_neighbors`, `list_events`,
   `list_reminders`, `list_mail`, `search_mail`, `list_dir`,
   `read_file`): emit the tool block and STOP. End your response with
   the closing fence — same backtick count as the opener (four). Do
   NOT write prose after. Do NOT include a `---` separator for read
   tools (the body is unused). Do NOT write a fake ```json result
   inside the block — that is a hallucination. The system runs the
   tool and feeds you the real data in your next turn — only THEN do
   you answer using the actual data.

   ❌ WRONG (fabricated body, parser may drop the call entirely):
   ````clome-tool
   action: list_mail
   hours_back: 24
   ---
   ```json
   [{"thread_id": "thread123", "subject": "Meeting", ...}]
   ```
   ````

   ✅ RIGHT (header only, then close):
   ````clome-tool
   action: list_mail
   hours_back: 24
   ````

2. **WRITE tools** (`create_event`, `delete_event`, `create_reminder`,
   `create_note`, `append_to_note`, `edit_note`, `replace_note_body`,
   `delete_note`, `relate`): emit the tool block, then write a SHORT
   one-sentence confirmation in plain prose so the user knows what
   you did and why. Do NOT fabricate tool output (fake ids, fake JSON).

   **Editing strategy** — when modifying an existing note, prefer in
   order: `edit_note` (one specific change) → `append_to_note`
   (additive) → `replace_note_body` (only if the rewrite is so
   pervasive that find-and-replace would need many `edit_note` calls).
   `edit_note`'s `old_string` must match the body byte-for-byte; if a
   single-occurrence match is ambiguous, include enough surrounding
   text to disambiguate. If the tool reports "no match" or
   "ambiguous", read the note back via `graph_neighbors` (or rely on
   the body the system already injected) and try again with better
   context — do NOT fall back to `replace_note_body` to mask a failed
   edit.

3. **Do the minimum the user asked.** One user request → one tool
   action unless the user explicitly enumerates multiple things.
   - "add gym today around noon" = ONE create_event. Not gym + lunch
     + prep + warmup.
   - Context the user provides ("I should eat lunch", "tomorrow is
     push day", "I have a meeting at 3") is BACKGROUND for choosing
     a good time, not a list of additional events to schedule.
   - When in doubt about scope, do less. The user can always ask for
     more. Recovering from extra events requires `delete_event` and
     wastes their attention.

4. **Date headers** (`from`, `to`, `due`, `start`, `end`) MUST be
   ISO 8601 in the USER's timezone. Two acceptable forms:
   - Naive (no suffix), interpreted as user-local:
     `2026-05-01T15:00:00`
   - With the user's offset:
     `2026-05-01T15:00:00-07:00`
   NEVER append `Z` (UTC) to user-facing times. "Noon" written as
   `12:00:00Z` is 5am on the US west coast — wrong every time.
   Do NOT write `now`, `tomorrow`, `next week`, `+7d`. Compute the
   actual ISO datetime yourself based on the CURRENT TIME and USER
   TIMEZONE the system gave you above."#
}

/// Build full tool docs for the bound agent: vault docs (always),
/// then a capabilities scoreboard (granted vs not-granted), then any
/// capability-specific docs the agent has been granted.
///
/// The scoreboard is what stops the model fabricating: without it,
/// an agent without `calendar.read` happily invents a calendar list
/// because it knows what one looks like from training data. With the
/// explicit "NOT GRANTED" list, refusal is the cheaper path.
pub fn tool_docs_for(agent_caps: &[String]) -> String {
    let mut out = tool_docs().to_string();

    let mut granted: Vec<String> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    for cap in caps::ALL {
        let entry = format!("`{}` — {}", cap.key, cap.description);
        if agent_caps.iter().any(|c| c == cap.key) {
            granted.push(entry);
        } else {
            missing.push(entry);
        }
    }

    out.push_str("\n\n## YOUR CAPABILITIES\n");
    if granted.is_empty() {
        out.push_str("\nGRANTED: (none beyond vault tools)\n");
    } else {
        out.push_str("\nGRANTED:\n");
        for g in &granted {
            out.push_str(&format!("- {g}\n"));
        }
    }
    if missing.is_empty() {
        out.push_str("\nNOT GRANTED: (none — every capability is available)\n");
    } else {
        out.push_str("\nNOT GRANTED — you cannot use these:\n");
        for m in &missing {
            out.push_str(&format!("- {m}\n"));
        }
    }
    out.push_str(
        "\n**Hard rule.** If the user asks for something that requires a NOT GRANTED capability:\n\
         - Do NOT emit a tool block for it.\n\
         - Do NOT fabricate the data — never invent calendar events, reminders, or any other tool output.\n\
         - Reply in one sentence: \"I don't have access to <capability>. Add the capability to my agent settings (or ask the <suitable> agent) and try again.\"\n",
    );
    out.push_str(
        "\n**Grounding rule.** If the user asks for data covered by a GRANTED capability, \
         you MUST use the matching read tool before answering. For example, calendar \
         questions require `list_events`; email questions require `list_mail` or \
         `search_mail`; reminder questions require `list_reminders`. Never answer \
         these from memory, never invent example rows, and never render raw JSON as \
         the final answer.\n",
    );

    let extras = caps::tool_docs_for(agent_caps);
    if !extras.trim().is_empty() {
        out.push_str("\n## EXTRA TOOLS (granted by capabilities)\n");
        out.push_str(&extras);
    }
    out
}
