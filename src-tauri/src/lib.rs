mod caps;
pub mod db;
mod embed;
mod ghostty_native;
pub mod graph;
mod mail;
mod mlx;
mod tools;

use db::{Agent, Chat, Folder, InspectorData, Message, Note, SearchResults, Workspace};
use graph::GraphSlice;
use mlx::{stream_chat_cancelable, stream_chat_to, ChatMessage, DoneEvent, ErrorEvent, TokenEvent};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use sysinfo::{ProcessesToUpdate, System};
use surrealdb::engine::local::Db;
use surrealdb::sql::Thing;
use surrealdb::Surreal;
use tauri::{AppHandle, Emitter, Manager};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Default)]
struct ChatCancels(Arc<Mutex<HashMap<u64, CancellationToken>>>);

struct ResourceUsageState {
    system: Mutex<System>,
}

impl Default for ResourceUsageState {
    fn default() -> Self {
        let mut system = System::new();
        system.refresh_processes(ProcessesToUpdate::All, true);
        Self {
            system: Mutex::new(system),
        }
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct AppResourceUsage {
    app_cpu_percent: f32,
    app_memory_bytes: u64,
    model_cpu_percent: f32,
    model_memory_bytes: u64,
    model_process_count: usize,
    total_cpu_percent: f32,
    total_memory_bytes: u64,
    sampled_at_ms: i64,
}

#[derive(Default)]
struct ProcessResourceUsage {
    cpu_percent: f32,
    memory_bytes: u64,
}

fn usage_for_process(process: Option<&sysinfo::Process>) -> ProcessResourceUsage {
    process
        .map(|p| ProcessResourceUsage {
            cpu_percent: p.cpu_usage(),
            memory_bytes: p.memory(),
        })
        .unwrap_or_default()
}

fn is_detected_model_server(process: &sysinfo::Process) -> bool {
    let name = process.name().to_string_lossy().to_ascii_lowercase();
    let command = process
        .cmd()
        .iter()
        .map(|part| part.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();
    let haystack = format!("{name} {command}");

    haystack.contains("mlx_lm.server")
        || haystack.contains("mlx-lm.server")
        || haystack.contains("mlx_lm server")
}

#[tauri::command]
fn app_resource_usage(
    state: tauri::State<'_, ResourceUsageState>,
) -> Result<AppResourceUsage, String> {
    let mut system = state
        .system
        .lock()
        .map_err(|_| "resource usage sampler lock poisoned".to_string())?;
    system.refresh_processes(ProcessesToUpdate::All, true);

    let current_pid = sysinfo::Pid::from_u32(std::process::id());
    let app_usage = usage_for_process(system.process(current_pid));

    let mut model_cpu_percent = 0.0;
    let mut model_memory_bytes = 0;
    let mut model_process_count = 0;
    for (pid, process) in system.processes() {
        if *pid == current_pid || !is_detected_model_server(process) {
            continue;
        }
        model_cpu_percent += process.cpu_usage();
        model_memory_bytes += process.memory();
        model_process_count += 1;
    }

    Ok(AppResourceUsage {
        app_cpu_percent: app_usage.cpu_percent,
        app_memory_bytes: app_usage.memory_bytes,
        model_cpu_percent,
        model_memory_bytes,
        model_process_count,
        total_cpu_percent: app_usage.cpu_percent + model_cpu_percent,
        total_memory_bytes: app_usage.memory_bytes + model_memory_bytes,
        sampled_at_ms: chrono::Utc::now().timestamp_millis(),
    })
}

#[tauri::command]
async fn chat_stream(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    cancels: tauri::State<'_, ChatCancels>,
    workspace_id: Thing,
    chat_id: Thing,
    turn_id: u64,
    model: String,
    messages: Vec<ChatMessage>,
    // Group-chat: composer-side @-mention parsing picks one agent and
    // passes it here. When Some, this agent supplies the system prompt
    // / model / capabilities for THIS turn only — the chat's bound
    // list is unaffected. When None, fall back to the chat's first
    // bound agent (preserves single-agent behavior).
    agent_override: Option<Thing>,
    // Optional per-turn compute fallback. The agent persona and
    // capabilities still come from `agent_override`; this only changes
    // which local model serves the turn.
    model_override: Option<String>,
) -> Result<(), String> {
    let latest_user_content = messages
        .iter()
        .rev()
        .find(|m| m.role == "user")
        .map(|m| m.content.clone())
        .unwrap_or_default();
    if !latest_user_content.is_empty() {
        let _ = db::save_message(&db, &chat_id, "user", &latest_user_content).await;
    }

    if let Some(social_reply) = lightweight_social_reply(&latest_user_content) {
        let _ = app.emit(
            "chat:token",
            TokenEvent {
                turn_id,
                token: social_reply.into(),
            },
        );
        let _ = db::save_message(&db, &chat_id, "agent", social_reply).await;
        let _ = app.emit("chat:done", DoneEvent { turn_id });
        return Ok(());
    }

    // Per-turn agent resolution: the latest typed @-mention is the
    // source of truth. The frontend normally sends the same override,
    // but if it sent a stale room-lead id we correct it here before
    // falling back to the explicit override and then the chat's first
    // bound agent.
    let mentioned_agent_override =
        resolve_mentioned_agent_id(&db, &chat_id, &latest_user_content).await;
    let resolved_agent_override = mentioned_agent_override.or(agent_override);
    let bound_agent = match &resolved_agent_override {
        Some(id) => db::get_agent(&db, id).await.ok().flatten(),
        None => db::get_chat_agent(&db, &chat_id).await.ok().flatten(),
    };
    eprintln!(
        "[chat_stream] bound_agent: {:?}",
        bound_agent.as_ref().map(|a| (a.name.clone(), a.capabilities.clone()))
    );
    let mut enriched = messages;
    let mut effective_model = model;
    if let Some(agent) = &bound_agent {
        effective_model = agent.model.clone();
        // Replace (or insert) the leading system message with the
        // agent's persona prompt.
        let persona = format!(
            "You are {} — {}. Reply concisely.",
            agent.name, agent.system_prompt
        );
        if let Some(first) = enriched.first_mut() {
            if first.role == "system" {
                first.content = persona;
            } else {
                enriched.insert(
                    0,
                    ChatMessage {
                        role: "system".into(),
                        content: persona,
            ..Default::default()
        },
                );
            }
        } else {
            enriched.push(ChatMessage {
                role: "system".into(),
                content: persona,
            ..Default::default()
        });
        }
    }
    if let Some(override_model) = model_override
        .as_ref()
        .map(|m| m.trim())
        .filter(|m| !m.is_empty())
    {
        effective_model = override_model.to_string();
    }

    let use_full_harness = latest_user_needs_full_harness(&latest_user_content);
    let read_titles = if use_full_harness {
        inject_vault_context_for_text(
            &db,
            &workspace_id,
            &mut enriched,
            &latest_user_content,
        )
        .await
    } else {
        Vec::new()
    };
    let agent_caps: Vec<String> = bound_agent
        .as_ref()
        .map(|a| a.capabilities.clone())
        .unwrap_or_default();
    let agent_activity_name = bound_agent
        .as_ref()
        .map(|a| a.name.clone())
        .unwrap_or_else(|| "Clome".to_string());
    if use_full_harness {
        // Tool surface is now defined via the OpenAI `tools` parameter —
        // mlx_lm's chat template injects Qwen's native `<tools>` block
        // automatically. No more hand-written 3-5KB fenced-format docs
        // dumped into the system prompt. We still inject behavioral
        // guidance per capability (e.g. "never invent thread_ids") and
        // the current time for date math.
        inject_tool_behavior_docs(&mut enriched, &agent_caps);
        inject_current_time(&mut enriched);
    }
    // No latest_user_guard. With tool/assistant-tool_calls turns, the
    // chat template marks tool data as data — the model no longer
    // pattern-mimics prior assistant prose, so the heavy "TURN FOCUS"
    // band-aid that compounded with weak attention is no longer needed.

    if !read_titles.is_empty() {
        let _ = app.emit(
            "agent:activity",
            serde_json::json!({
                "ts": chrono::Utc::now().to_rfc3339(),
                "kind": "vault_read",
                "agent": &agent_activity_name,
                "count": read_titles.len(),
                "titles": read_titles,
            }),
        );
    }

    let app_clone = app.clone();
    let db_clone: Surreal<Db> = (*db).clone();
    let chat_id_clone = chat_id.clone();
    let ws_clone = workspace_id.clone();
    let caps_clone = agent_caps.clone();
    let agent_activity_name_clone = agent_activity_name.clone();
    let actor = format!("agent:{agent_activity_name}");
    let cancel_token = CancellationToken::new();
    let cancel_registry = cancels.0.clone();
    {
        let mut map = cancel_registry
            .lock()
            .map_err(|_| "cancel registry poisoned".to_string())?;
        if let Some(existing) = map.insert(turn_id, cancel_token.clone()) {
            existing.cancel();
        }
    }

    tauri::async_runtime::spawn(async move {
        const MAX_ITERS: usize = 4;
        let mut iter_messages = enriched;
        let mut combined = String::new();
        let mut any_writes = false;
        let tools_enabled = use_full_harness;
        // Build OpenAI-shape tool schemas for THIS turn (vault tools +
        // capability-gated tools the bound agent has). mlx_lm.server
        // pipes these into Qwen's chat template, which formats the
        // model's native `<tools>...</tools>` system block. The model
        // emits structured `tool_calls` deltas — no more text-fence
        // parser, no fabrication, no pattern-mimic on follow-up turns.
        let tool_schemas = if tools_enabled {
            Some(tools::tool_schemas(&caps_clone))
        } else {
            None
        };
        // 0-based index across the entire turn — used to pair each
        // tool chip the model emitted with its result event so the
        // frontend can replace the chip with a rich inline card.
        let mut tool_index: usize = 0;
        let mut tool_results_for_save: Vec<serde_json::Value> = Vec::new();

        for iter in 0..MAX_ITERS {
            // Normalize before every stream call. Most local chat
            // templates (gemma, llama, qwen, mistral) assert strict
            // user/assistant alternation after an optional leading
            // system, and even one duplicate role kills the request
            // with a 404 / template error. The normalizer keeps tool
            // role messages in place — they're the canonical way to
            // feed function results back under Qwen's template.
            normalize_role_alternation(&mut iter_messages);
            eprintln!("[agent_loop] iter {iter} starting (msgs={})", iter_messages.len());
            let stream_res = stream_chat_cancelable(
                app_clone.clone(),
                turn_id,
                effective_model.clone(),
                iter_messages.clone(),
                tool_schemas.clone(),
                cancel_token.clone(),
            )
            .await;
            let result = match stream_res {
                Ok(r) => r,
                Err(message) => {
                    eprintln!("[agent_loop] iter {iter} stream ERR: {message}");
                    let _ = app_clone.emit("chat:error", ErrorEvent { turn_id, message });
                    if let Ok(mut map) = cancel_registry.lock() {
                        map.remove(&turn_id);
                    }
                    return;
                }
            };
            eprintln!(
                "[agent_loop] iter {iter} done — {} content chars, {} tool_calls, finish={:?}",
                result.content.len(),
                result.tool_calls.len(),
                result.finish_reason,
            );
            combined.push_str(&result.content);
            if cancel_token.is_cancelled() {
                break;
            }

            // No tool calls → final assistant turn, we're done.
            if result.tool_calls.is_empty() {
                break;
            }

            // Push the assistant's tool-call turn into iter_messages so
            // the next iter's chat template renders it as Qwen's native
            // `<tool_call>` block. The OpenAI shape (id + function +
            // arguments) round-trips through mlx_lm's template.
            iter_messages.push(ChatMessage::assistant_tool_calls(result.tool_calls.clone()));

            // Dispatch each call. Read results push as `tool` role
            // messages for the next iter; writes are fire-and-forget
            // but we still emit a `tool` message with a "{ok:true}"
            // ack so the model knows the action completed.
            let mut any_dispatch = false;
            for tc in result.tool_calls {
                if cancel_token.is_cancelled() {
                    break;
                }
                let fn_name = tc.function.name.clone();
                let fn_args = tc.function.arguments.clone();
                let parsed = tools::from_function_call(&fn_name, &fn_args);
                let call = match parsed {
                    Some(c) => c,
                    None => {
                        eprintln!("[agent_loop] unknown tool call: {fn_name} args={fn_args}");
                        // Tell the model the call was rejected so it
                        // doesn't loop on the same bad invocation.
                        iter_messages.push(ChatMessage::tool(
                            tc.id,
                            fn_name,
                            "{\"error\":\"unknown_tool_or_bad_arguments\"}",
                        ));
                        continue;
                    }
                };
                any_dispatch = true;
                let action = call.action_name().to_string();
                let target = call.target().to_string();
                let secondary = call.secondary().map(|s| s.to_string());
                let _ = app_clone.emit(
                    "agent:activity",
                    serde_json::json!({
                        "ts": chrono::Utc::now().to_rfc3339(),
                        "kind": "tool_call",
                        "agent": &agent_activity_name_clone,
                        "action": action,
                        "target": target,
                        "secondary": secondary,
                    }),
                );
                if !call.is_read() {
                    any_writes = true;
                }
                let headers_snapshot = call.headers_snapshot();

                // For frontend chip/card rendering: synthesize a
                // `clome-tool` fence corresponding to this call and
                // emit it as a chat:token BEFORE running the tool.
                // The fence preprocessor in markdown.ts turns it into a
                // chip; chat:tool_start then pulses that chip; on
                // chat:tool_result the toolResults post-processor swaps
                // the chip with a rich card. Native tool calling means
                // the model itself emits no fence text — we generate
                // one for display only.
                let synth_fence = synthesize_tool_fence(&action, &headers_snapshot);
                if !synth_fence.is_empty() {
                    let _ = app_clone.emit(
                        "chat:token",
                        TokenEvent { turn_id, token: synth_fence.clone() },
                    );
                    combined.push_str(&synth_fence);
                }
                let _ = app_clone.emit(
                    "chat:tool_start",
                    serde_json::json!({
                        "turnId": turn_id,
                        "action": action,
                        "target": target,
                        "secondary": secondary,
                    }),
                );

                let exec_result = tools::execute(
                    &app_clone,
                    &db_clone,
                    &ws_clone,
                    call,
                    &actor,
                    &caps_clone,
                )
                .await;

                let result_json: serde_json::Value = match &exec_result {
                    Some(s) => serde_json::from_str(s)
                        .unwrap_or(serde_json::Value::String(s.clone())),
                    None => serde_json::Value::Null,
                };
                let tool_result_payload = serde_json::json!({
                    "index": tool_index,
                    "action": action,
                    "headers": headers_snapshot,
                    "result": result_json,
                });
                let _ = app_clone.emit(
                    "chat:tool_result",
                    serde_json::json!({
                        "turnId": turn_id,
                        "index": tool_result_payload["index"],
                        "action": tool_result_payload["action"],
                        "headers": tool_result_payload["headers"],
                        "result": tool_result_payload["result"],
                    }),
                );
                tool_results_for_save.push(tool_result_payload);
                tool_index += 1;

                let _ = app_clone.emit(
                    "chat:tool_end",
                    serde_json::json!({
                        "turnId": turn_id,
                        "action": action,
                    }),
                );

                // Feed the result back as a `tool` role message. For
                // writes we send a tiny ack so the model can write its
                // confirmation reply on the next iter.
                let tool_content = match exec_result {
                    Some(s) => s,
                    None => "{\"ok\":true}".into(),
                };
                iter_messages.push(ChatMessage::tool(tc.id, fn_name, tool_content));
            }

            if !any_dispatch {
                // Every tool call was rejected — bail to avoid a loop.
                break;
            }
            if cancel_token.is_cancelled() {
                break;
            }
            if iter + 1 >= MAX_ITERS {
                // Hit iteration cap. Add a final-prose nudge so the
                // assistant wraps up rather than emitting another
                // tool call we'd never run.
                iter_messages.push(ChatMessage {
                    role: "user".into(),
                    content: "Iteration budget exhausted. Reply now in plain prose using the tool results so far.".into(),
                    ..Default::default()
                });
            }
        }

        if !combined.is_empty() {
            let saved_tool_results = if tool_results_for_save.is_empty() {
                None
            } else {
                Some(tool_results_for_save)
            };
            let _ = db::save_message_with_tool_results(
                &db_clone,
                &chat_id_clone,
                "agent",
                &combined,
                saved_tool_results,
            )
            .await;
            let titles = db::extract_wikilink_titles(&combined);
            if !titles.is_empty() {
                let _ = db::ensure_notes_exist(&db_clone, &ws_clone, &titles, &actor).await;
            }
            if any_writes || !titles.is_empty() {
                let _ = app_clone.emit("vault:updated", ());
            }
        }
        if let Ok(mut map) = cancel_registry.lock() {
            map.remove(&turn_id);
        }
        let _ = app_clone.emit("chat:done", DoneEvent { turn_id });
    });
    Ok(())
}

#[tauri::command]
async fn mlx_model_status(model: String) -> Result<mlx::ModelStatus, String> {
    mlx::model_status(model).await
}

#[tauri::command]
fn chat_cancel(cancels: tauri::State<'_, ChatCancels>, turn_id: u64) -> Result<bool, String> {
    let token = {
        let mut map = cancels
            .0
            .lock()
            .map_err(|_| "cancel registry poisoned".to_string())?;
        map.remove(&turn_id)
    };
    if let Some(token) = token {
        token.cancel();
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Build a `clome-tool` fence text from a structured tool call so the
/// frontend chip preprocessor (which reads fences from message text)
/// renders a chip for each native tool call. The fence is for DISPLAY
/// ONLY — the actual call already went through OpenAI tools protocol.
/// A2 will refactor MessageContent to render chips/cards from the
/// `toolResults` array directly and this synthesis can go away.
fn synthesize_tool_fence(action: &str, headers: &serde_json::Value) -> String {
    let mut out = String::from("\n\n````clome-tool\naction: ");
    out.push_str(action);
    out.push('\n');
    if let Some(obj) = headers.as_object() {
        for (k, v) in obj {
            if v.is_null() {
                continue;
            }
            // Render scalar values flat. Skip arrays/objects — they
            // don't fit the YAML-ish header shape and the chip only
            // needs the action + a few scalar headers anyway.
            let scalar = match v {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Number(n) => n.to_string(),
                serde_json::Value::Bool(b) => b.to_string(),
                _ => continue,
            };
            if scalar.is_empty() {
                continue;
            }
            out.push_str(k);
            out.push_str(": ");
            out.push_str(&scalar);
            out.push('\n');
        }
    }
    out.push_str("````\n\n");
    out
}

/// Slim per-capability behavioral docs. The TOOL DEFINITIONS go via the
/// OpenAI `tools` parameter (mlx_lm injects Qwen's native `<tools>`
/// system block). This function only adds non-format guidance the model
/// still needs: identifier conventions, render rules for tool results,
/// caps-not-granted scoreboard. No fence syntax, no example blocks —
/// those caused the fabricate/repeat failures and the chat template
/// makes them unnecessary.
fn inject_tool_behavior_docs(messages: &mut Vec<ChatMessage>, agent_caps: &[String]) {
    let docs = caps::behavior_docs_for(agent_caps);
    if docs.is_empty() {
        return;
    }
    if let Some(first) = messages.first_mut() {
        if first.role == "system" {
            if !first.content.is_empty() {
                first.content.push_str("\n\n---\n\n");
            }
            first.content.push_str(&docs);
            return;
        }
    }
    messages.insert(
        0,
        ChatMessage {
            role: "system".into(),
            content: docs,
            ..Default::default()
        },
    );
}

/// Defensively coerce `messages` into a shape every common local chat
/// template will accept: at most one leading `system`, then strict
/// `user` / `assistant` alternation. Same-role neighbours are merged
/// (their content concatenated with a blank line); a stray
/// `assistant` ahead of the first `user` is dropped.
///
/// Most failures we've seen with the MLX server are jinja `assert`s
/// raising "Conversation roles must alternate user/assistant/...".
/// They fire when the frontend store carries an empty errored agent
/// row, when an iter-N+1 tool-result block is appended after we've
/// already pushed a same-role message, or when chat history loaded
/// from disk had two `user` rows in a row from a prior crashed turn.
/// One central pass handles all of those.
fn normalize_role_alternation(messages: &mut Vec<ChatMessage>) {
    if messages.is_empty() {
        return;
    }
    let mut out: Vec<ChatMessage> = Vec::with_capacity(messages.len());
    // Keep up to one leading system message.
    let mut idx = 0;
    if messages[0].role == "system" {
        out.push(messages[0].clone());
        idx = 1;
        // Skip any extra system messages that landed back-to-back —
        // merge their content into the leading one.
        while idx < messages.len() && messages[idx].role == "system" {
            let extra = messages[idx].content.clone();
            if let Some(first) = out.first_mut() {
                if !extra.is_empty() {
                    if !first.content.is_empty() {
                        first.content.push_str("\n\n");
                    }
                    first.content.push_str(&extra);
                }
            }
            idx += 1;
        }
    }

    // Drop any leading assistant — gemma + friends require the first
    // post-system message to be user.
    while idx < messages.len() && messages[idx].role == "assistant" {
        idx += 1;
    }

    // Walk the rest, merging consecutive same-role user/assistant rows.
    // `tool` role messages pass through unchanged — Qwen's chat template
    // wires them into `<tool_response>` blocks tied to the preceding
    // assistant tool-call. They MUST stay distinct (one tool message
    // per tool call) and must NOT merge with neighbors. Likewise, an
    // assistant message carrying tool_calls is a structural turn — we
    // keep it as-is rather than trying to merge content strings.
    while idx < messages.len() {
        let cur = messages[idx].clone();
        if cur.role == "tool" || cur.tool_calls.is_some() {
            out.push(cur);
            idx += 1;
            continue;
        }
        let role = match cur.role.as_str() {
            "user" | "assistant" => cur.role.clone(),
            _ => "user".to_string(),
        };
        if let Some(last) = out.last_mut() {
            // Don't merge into an assistant-with-tool_calls or a tool
            // message — those are structural and merging would corrupt
            // the call/response pairing.
            let mergeable = last.role == role && last.tool_calls.is_none() && last.role != "tool";
            if mergeable {
                if !cur.content.is_empty() {
                    if !last.content.is_empty() {
                        last.content.push_str("\n\n");
                    }
                    last.content.push_str(&cur.content);
                }
                idx += 1;
                continue;
            }
        }
        out.push(ChatMessage {
            role,
            content: cur.content,
            ..Default::default()
        });
        idx += 1;
    }

    *messages = out;
}

fn lightweight_social_reply(text: &str) -> Option<&'static str> {
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.len() > 80 {
        return None;
    }
    let normalized = trimmed
        .trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace())
        .to_ascii_lowercase();
    match normalized.as_str() {
        "hi"
        | "hello"
        | "hey"
        | "yo"
        | "sup"
        | "gm"
        | "gn"
        | "good morning"
        | "good afternoon"
        | "good evening"
        | "hey there"
        | "hi there" => Some("Hi - I'm here. What's up?"),
        "how are you"
        | "how are you doing"
        | "how are you doing today"
        | "how's it going"
        | "hows it going"
        | "how is it going"
        | "how are things"
        | "what's up"
        | "whats up"
        | "what is up" => Some("I'm good - here with you. What's on your mind?"),
        "thanks" | "thank you" | "thx" => Some("Of course."),
        "ok" | "okay" | "cool" | "nice" | "got it" => Some("Got it."),
        _ => None,
    }
}

async fn resolve_mentioned_agent_id(
    db: &Surreal<Db>,
    chat_id: &Thing,
    text: &str,
) -> Option<Thing> {
    let targets = agent_mention_targets(text);
    if targets.is_empty() {
        return None;
    }
    let bound = db::get_chat_agents(db, chat_id).await.ok()?;
    for target in targets {
        if let Some(agent) = bound.iter().find(|agent| {
            normalize_agent_mention(&agent.name) == target
                || normalize_agent_mention(&agent_mention_slug(&agent.name)) == target
        }) {
            return Some(agent.id.clone());
        }
    }
    None
}

fn agent_mention_targets(text: &str) -> Vec<String> {
    let mut targets = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '@' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < chars.len()
            && (chars[j].is_ascii_alphanumeric() || chars[j] == '_' || chars[j] == '-')
        {
            j += 1;
        }
        if j > i + 1 {
            let raw: String = chars[i + 1..j].iter().collect();
            targets.push(normalize_agent_mention(&raw));
        }
        i = j.max(i + 1);
    }
    targets
}

fn normalize_agent_mention(value: &str) -> String {
    value
        .chars()
        .filter_map(|c| {
            if c.is_whitespace() || c == '_' || c == '-' {
                None
            } else {
                Some(c.to_ascii_lowercase())
            }
        })
        .collect()
}

fn agent_mention_slug(name: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for c in name.trim().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash && !out.is_empty() {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

fn latest_user_needs_full_harness(text: &str) -> bool {
    let normalized = text.to_ascii_lowercase();
    if normalized.contains("[[") {
        return true;
    }
    const KEYWORDS: &[&str] = &[
        "add ",
        "append",
        "calendar",
        "create ",
        "delete",
        "directory",
        "edit",
        "email",
        "event",
        "file",
        "find",
        "folder",
        "graph",
        "inbox",
        "list",
        "mail",
        "meeting",
        "note",
        "open ",
        "read ",
        "remember",
        "remind",
        "reminder",
        "rename",
        "save",
        "schedule",
        "search",
        "show me",
        "time",
        "today",
        "tomorrow",
        "vault",
        "yesterday",
    ];
    KEYWORDS.iter().any(|needle| normalized.contains(needle))
}

fn inject_latest_user_guard(messages: &mut Vec<ChatMessage>, latest_user: &str) {
    let latest = latest_user.trim();
    if latest.is_empty() {
        return;
    }
    let clipped = if latest.chars().count() > 4000 {
        let head: String = latest.chars().take(4000).collect();
        format!("{head}...[truncated]")
    } else {
        latest.to_string()
    };
    let block = format!(
        "TURN FOCUS:\n\
         The latest user message is the only instruction for this turn:\n\
         <latest_user_message>\n{clipped}\n</latest_user_message>\n\
         Use older chat history only as background. Do not continue an older task, search topic, \
         email query, or graph query unless the latest user message explicitly asks you to continue it. \
         Never repeat, re-list, or paraphrase a previous reply. If the new question asks about \
         emails, events, reminders, files, or graph data, you MUST issue a fresh clome-tool call — \
         the previous turn's data is stale and the user is asking a different question. \
         If the latest message is only a greeting or social check-in, answer conversationally without tools."
    );
    // Insert as a SEPARATE leading system message rather than appending
    // to the persona/tool-docs block. Appended at the tail of a 3-5 KB
    // system blob, weak local models lose attention to it. Placed first,
    // it is the very first thing the model reads, before persona, tool
    // docs, and time. The chat template will still concatenate adjacent
    // system messages, but the ORDER is what matters for attention.
    messages.insert(
        0,
        ChatMessage {
            role: "system".into(),
            content: block,
            ..Default::default()
        },
    );
}

/// Render tool results into a model-friendly text block. The default
/// path used to dump raw JSON, which works for tiny shapes but loses
/// fidelity quickly: at 30+ email rows, small models start
/// hallucinating subjects / senders / dates because the JSON noise
/// drowns out the actual content. For known list-shaped actions we
/// emit a tight markdown-ish list with explicit `id: …` lines so the
/// model can copy thread ids verbatim into `[[email:…]]` references.
/// Unknown actions fall back to JSON so we never lose information.
fn format_tool_result_for_model(action: &str, _target: &str, json: &str) -> String {
    match action {
        "list_events" => match serde_json::from_str::<Vec<serde_json::Value>>(json) {
            Ok(rows) if !rows.is_empty() => format_event_rows(action, &rows),
            Ok(_) => format!("### {action}\n_no events_\n"),
            Err(_) => format!("### {action}\n```json\n{json}\n```\n"),
        },
        "list_mail" | "search_mail" => {
            match serde_json::from_str::<Vec<serde_json::Value>>(json) {
                Ok(rows) if !rows.is_empty() => format_mail_rows(action, &rows),
                Ok(_) => format!("### {action}\n_no results_\n"),
                Err(_) => format!("### {action}\n```json\n{json}\n```\n"),
            }
        }
        "graph_search" | "graph_neighbors" => {
            // GraphSlice = { nodes: [...], edges: [...] }
            match serde_json::from_str::<serde_json::Value>(json) {
                Ok(v) => format_graph_slice(action, &v),
                Err(_) => format!("### {action}\n```json\n{json}\n```\n"),
            }
        }
        _ => format!("### {action}\n```json\n{json}\n```\n"),
    }
}

fn format_event_rows(action: &str, rows: &[serde_json::Value]) -> String {
    let mut out = format!("### {action} — {} event(s)\n\n", rows.len());
    for r in rows {
        let title = r
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("(untitled)");
        let start = r.get("start").and_then(|v| v.as_str()).unwrap_or("");
        let end = r.get("end").and_then(|v| v.as_str()).unwrap_or("");
        let location = r.get("location").and_then(|v| v.as_str()).unwrap_or("");
        let calendar = r.get("calendar").and_then(|v| v.as_str()).unwrap_or("");

        out.push_str(&format!("- **{title}**"));
        if !start.is_empty() || !end.is_empty() {
            out.push_str(&format!(" — {start}"));
            if !end.is_empty() {
                out.push_str(&format!(" to {end}"));
            }
        }
        if !location.is_empty() {
            out.push_str(&format!(" — location: {location}"));
        }
        if !calendar.is_empty() {
            out.push_str(&format!(" — calendar: {calendar}"));
        }
        out.push('\n');
    }
    out
}

fn format_mail_rows(action: &str, rows: &[serde_json::Value]) -> String {
    let mut out = format!("### {action} — {} thread(s)\n\n", rows.len());
    for r in rows {
        let subject = r
            .get("subject")
            .and_then(|v| v.as_str())
            .unwrap_or("(no subject)");
        let from_name = r.get("from_name").and_then(|v| v.as_str()).unwrap_or("");
        let from_addr = r.get("from_addr").and_then(|v| v.as_str()).unwrap_or("");
        let from = if !from_name.is_empty() && !from_addr.is_empty() {
            format!("{from_name} <{from_addr}>")
        } else if !from_name.is_empty() {
            from_name.to_string()
        } else {
            from_addr.to_string()
        };
        let thread_id = r.get("thread_id").and_then(|v| v.as_str()).unwrap_or("");
        let account_id = r.get("account_id").and_then(|v| v.as_str()).unwrap_or("");
        let date_unix = r.get("date_received").and_then(|v| v.as_i64()).unwrap_or(0);
        let date_str = if date_unix > 0 {
            chrono::DateTime::<chrono::Utc>::from_timestamp(date_unix, 0)
                .map(|dt| {
                    dt.with_timezone(&chrono::Local)
                        .format("%Y-%m-%d %H:%M")
                        .to_string()
                })
                .unwrap_or_default()
        } else {
            String::new()
        };
        let unread = r
            .get("unread")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let snippet = r
            .get("snippet")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .replace('\n', " ");
        let snippet_short = if snippet.len() > 200 {
            format!("{}…", &snippet[..200])
        } else {
            snippet
        };

        out.push_str(&format!(
            "- **{subject}** — from {from}{}{}\n  id: `{thread_id}` · account: `{account_id}`\n",
            if !date_str.is_empty() { format!(" — {date_str}") } else { String::new() },
            if unread { " · UNREAD" } else { "" },
        ));
        if !snippet_short.is_empty() {
            out.push_str(&format!("  snippet: {snippet_short}\n"));
        }
    }
    out
}

fn format_graph_slice(action: &str, v: &serde_json::Value) -> String {
    let nodes = v.get("nodes").and_then(|n| n.as_array());
    let edges = v.get("edges").and_then(|e| e.as_array());
    let n_count = nodes.map(|a| a.len()).unwrap_or(0);
    let e_count = edges.map(|a| a.len()).unwrap_or(0);
    let mut out = format!("### {action} — {n_count} node(s), {e_count} edge(s)\n\n");
    if let Some(nodes) = nodes {
        for n in nodes {
            let label = n.get("label").and_then(|x| x.as_str()).unwrap_or("");
            let kind = n.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            let src = n.get("source_kind").and_then(|x| x.as_str()).unwrap_or("");
            out.push_str(&format!(
                "- [[{label}]] · kind: {kind}{}\n",
                if !src.is_empty() { format!(" · source: {src}") } else { String::new() },
            ));
        }
    }
    out
}

fn inject_current_time(messages: &mut Vec<ChatMessage>) {
    let now = chrono::Local::now();
    let offset = now.format("%:z").to_string(); // e.g. "-07:00"
    let tz_name = iana_time_zone::get_timezone().unwrap_or_else(|_| "local".to_string());
    let line = format!(
        "\n\nCURRENT TIME: {iso} ({pretty}).\n\
         USER TIMEZONE: {tz} (UTC offset {offset}).\n\
         \n\
         RULES for tool date headers (`from`, `to`, `due`, `start`, `end`):\n\
         - Always interpret bare clock times the user mentions (\"noon\", \"3pm\", \"tomorrow morning\") in the USER's timezone above, NOT UTC.\n\
         - Emit either:\n\
           (a) a NAIVE ISO datetime with NO trailing Z and NO offset, e.g. `2026-05-03T12:00:00` — the system treats this as the user's local time, OR\n\
           (b) an ISO datetime with the user's offset baked in, e.g. `2026-05-03T12:00:00{offset}`.\n\
         - DO NOT append a trailing `Z`. `Z` means UTC and is almost always wrong for user-facing scheduling — \"noon\" with a `Z` would land at 5am local on the West Coast.\n\
         - Never write `now`, `tomorrow`, `next week`, `+7d`. Compute the real ISO datetime.",
        iso = now.to_rfc3339(),
        pretty = now.format("%A, %B %-d %Y, %-I:%M %p"),
        tz = tz_name,
        offset = offset,
    );
    if let Some(first) = messages.first_mut() {
        if first.role == "system" {
            first.content.push_str(&line);
            return;
        }
    }
    messages.insert(
        0,
        ChatMessage {
            role: "system".into(),
            content: line.trim_start().to_string(),
            ..Default::default()
        },
    );
}

fn inject_tool_docs(messages: &mut Vec<ChatMessage>, agent_caps: &[String]) {
    let docs = tools::tool_docs_for(agent_caps);
    if let Some(first) = messages.first_mut() {
        if first.role == "system" {
            first.content = format!("{}\n\n---\n\n{}", first.content, docs);
            return;
        }
    }
    messages.insert(
        0,
        ChatMessage {
            role: "system".into(),
            content: docs,
            ..Default::default()
        },
    );
}

/// Look up [[wikilinked]] notes from the latest user message and inline their
/// bodies into the system prompt, so the model treats explicit mentions as
/// real context instead of opaque tokens. Returns the titles actually fetched
/// (for the activity timeline).
async fn inject_vault_context_for_text(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    messages: &mut Vec<ChatMessage>,
    text: &str,
) -> Vec<String> {
    let mut titles: Vec<String> = db::extract_wikilink_titles(text);
    titles.sort();
    titles.dedup();

    if titles.is_empty() {
        return titles;
    }

    let mut sections: Vec<String> = Vec::new();
    for title in &titles {
        let note = match db::get_note(db, workspace_id, title).await {
            Ok(Some(n)) => n,
            _ => continue,
        };

        // Pull a 1-hop graph snapshot per mentioned note so the agent
        // sees not just the body but the surrounding context — which
        // other notes link to it, which it links out to, and any
        // typed edges. This is what makes the chat feel like the user's
        // private encyclopedia rather than a stateless LLM.
        let slice = graph::neighbors(db, &note.id, None, 25).await.ok();
        let mut linked: Vec<String> = Vec::new();
        if let Some(s) = slice {
            for n in s.nodes.iter() {
                if n.kind == "note" && n.label != *title {
                    linked.push(format!("[[{}]]", n.label));
                }
            }
        }
        linked.sort();
        linked.dedup();

        let body_trimmed = note.body.trim();
        let mut section = if body_trimmed.is_empty() {
            format!(
                "## [[{title}]]\n_(note exists but has no body yet — the user hasn't written about it)_"
            )
        } else {
            format!("## [[{title}]]\n{body_trimmed}")
        };
        if !linked.is_empty() {
            section.push_str(&format!(
                "\n\n_neighbors:_ {}",
                linked.join(", ")
            ));
        }
        sections.push(section);
    }

    if sections.is_empty() {
        return titles;
    }

    let block = format!(
        "The user's vault contains these notes referenced in the conversation via [[wikilink]] syntax. Treat them as ground truth context. When you reference a note, use its [[wikilink]] form so the user can click through.\n\n{}",
        sections.join("\n\n")
    );

    if let Some(first) = messages.first_mut() {
        if first.role == "system" {
            first.content = format!("{}\n\n---\n\n{}", first.content, block);
            return titles;
        }
    }
    messages.insert(
        0,
        ChatMessage {
            role: "system".into(),
            content: block,
            ..Default::default()
        },
    );
    titles
}

#[tauri::command]
async fn list_notes(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
) -> Result<Vec<Note>, String> {
    db::list_notes(&db, &workspace_id).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_note(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: String,
    body: Option<String>,
    source_kind: Option<String>,
) -> Result<Option<Note>, String> {
    let title = title.trim();
    if title.is_empty() {
        return Err("title cannot be empty".into());
    }
    let body_text = body.unwrap_or_default();
    let note = db::create_note(
        &db,
        &workspace_id,
        title,
        &body_text,
        source_kind.as_deref().unwrap_or("manual"),
        "user",
    )
    .await
    .map_err(|e| e.to_string())?;
    let mut titles = db::extract_wikilink_titles(&body_text);
    titles.retain(|t| t != title);
    if !titles.is_empty() {
        let _ = db::ensure_notes_exist(&db, &workspace_id, &titles, "user").await;
    }
    let _ = app.emit("vault:updated", ());
    Ok(note)
}

#[tauri::command]
async fn inspect_note(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: String,
) -> Result<Option<InspectorData>, String> {
    db::inspect_note(&db, &workspace_id, &title)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn update_note_body(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: String,
    body: String,
) -> Result<Option<Note>, String> {
    let note = db::update_note_body(&db, &workspace_id, &title, &body, "user")
        .await
        .map_err(|e| e.to_string())?;
    let titles = db::extract_wikilink_titles(&body);
    if !titles.is_empty() {
        let _ = db::ensure_notes_exist(&db, &workspace_id, &titles, "user").await;
    }
    let _ = app.emit("vault:updated", ());
    Ok(note)
}

#[tauri::command]
async fn rename_note(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    old_title: String,
    new_title: String,
) -> Result<Option<Note>, String> {
    let new_trimmed = new_title.trim();
    if new_trimmed.is_empty() {
        return Err("title cannot be empty".into());
    }
    if new_trimmed == old_title {
        return db::get_note(&db, &workspace_id, &old_title)
            .await
            .map_err(|e| e.to_string());
    }
    if db::get_note(&db, &workspace_id, new_trimmed)
        .await
        .map_err(|e| e.to_string())?
        .is_some()
    {
        return Err("a note with that title already exists".into());
    }
    let result = db::rename_note(&db, &workspace_id, &old_title, new_trimmed, "user")
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(result)
}

#[tauri::command]
async fn delete_note(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: String,
) -> Result<bool, String> {
    let removed = db::delete_note_by_title(&db, &workspace_id, &title)
        .await
        .map_err(|e| e.to_string())?;
    if removed {
        let _ = app.emit("vault:updated", ());
    }
    Ok(removed)
}

#[tauri::command]
async fn list_chats(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
) -> Result<Vec<Chat>, String> {
    db::list_chats(&db, &workspace_id).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_chat(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: Option<String>,
) -> Result<Option<Chat>, String> {
    let chat = db::create_chat(&db, &workspace_id, title.as_deref().unwrap_or("New chat"))
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("chats:updated", ());
    Ok(chat)
}

#[tauri::command]
async fn list_workspaces(db: tauri::State<'_, Surreal<Db>>) -> Result<Vec<Workspace>, String> {
    db::list_workspaces(&db).await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_workspace(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    name: String,
) -> Result<Option<Workspace>, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("name cannot be empty".into());
    }
    let ws = db::create_workspace(&db, trimmed)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("workspaces:updated", ());
    Ok(ws)
}

#[tauri::command]
async fn rename_workspace(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    name: String,
) -> Result<(), String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("name cannot be empty".into());
    }
    db::rename_workspace(&db, &workspace_id, trimmed)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("workspaces:updated", ());
    Ok(())
}

#[tauri::command]
async fn list_agents(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
) -> Result<Vec<Agent>, String> {
    db::list_agents(&db, &workspace_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_agent(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    name: String,
    system_prompt: String,
    model: String,
    capabilities: Option<Vec<String>>,
) -> Result<Option<Agent>, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("name cannot be empty".into());
    }
    let caps = capabilities.unwrap_or_default();
    eprintln!("[create_agent] name={trimmed:?} caps={caps:?}");
    let agent = db::create_agent(&db, &workspace_id, trimmed, &system_prompt, &model, &caps)
        .await
        .map_err(|e| e.to_string())?;
    eprintln!("[create_agent] persisted: {:?}", agent.as_ref().map(|a| &a.capabilities));
    let _ = app.emit("agents:updated", ());
    Ok(agent)
}

#[tauri::command]
async fn update_agent(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    agent_id: Thing,
    name: String,
    system_prompt: String,
    model: String,
    capabilities: Option<Vec<String>>,
) -> Result<Option<Agent>, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("name cannot be empty".into());
    }
    let caps = capabilities.unwrap_or_default();
    eprintln!("[update_agent] id={agent_id} name={trimmed:?} caps={caps:?}");
    let agent = db::update_agent(&db, &agent_id, trimmed, &system_prompt, &model, &caps)
        .await
        .map_err(|e| e.to_string())?;
    eprintln!("[update_agent] persisted: {:?}", agent.as_ref().map(|a| &a.capabilities));
    let _ = app.emit("agents:updated", ());
    Ok(agent)
}

#[derive(serde::Serialize, Clone, Debug)]
struct CapabilityInfo {
    key: &'static str,
    label: &'static str,
    description: &'static str,
}

/// Hardcoded meta-prompt used by the Architect agent when generating
/// system prompts for other agents. Lives as code (not a DB row) so
/// the user can't accidentally delete it; their own agent edits stay
/// theirs.
const ARCHITECT_SYSTEM: &str = r#"You are Prompt Architect. Your single job is to write the SYSTEM PROMPT for another AI agent that the user is configuring. The user will give you a one-line description of what the new agent should do.

Output rules — non-negotiable:
- Output ONLY the system prompt. No preamble like "Here's the prompt:" or "Sure!", no postamble explanation, no markdown code fences around it.
- Start with a clear role line: "You are <Name> — <one-sentence purpose>."
- Then 4–8 lines of specific behaviors, constraints, or style rules. Bulleted or short paragraphs, your call.
- Total length: 80–250 words. Tight, not verbose.
- Negative constraints when relevant ("Never invent citations.", "Refuse to give legal advice.").
- Match tone to domain: technical agents = direct + precise; creative = warmer; coaching = supportive but firm.
- Do NOT include placeholder text like {{name}} or [USER]. Concrete only.
- Do NOT mention being an LLM, training data, or being from any company. Speak as the new agent itself, in second person to itself ("You are…", "You should…").
- If the user's description references vault tools (notes, wikilinks) or capabilities (calendar, reminders, web), assume those work via separate mechanisms and don't re-document them — just hint at the agent's intended use of them.
- If the description is vague, infer reasonable specifics rather than asking back. The user can edit afterward.

Examples (input → output):

INPUT: an agent that helps me code in Rust
OUTPUT:
You are RustCoder — a Rust pair programmer focused on idiomatic, performant code.

When the user asks about Rust:
- Prefer ownership patterns over reference counting unless thread-safety demands Arc.
- Reach for the standard library before adding crates; mention ecosystem crates by name when warranted (tokio, serde, anyhow, thiserror, axum).
- Show short complete examples that compile, with the right `use` statements.
- Flag unsafe blocks explicitly and explain why they're sound.
- When a trade-off exists, name it ("Box vs Arc here costs ~2ns per deref but…").
- No filler. If the answer is one line, give one line.

INPUT: agent that helps me prep for academic talks
OUTPUT:
You are TalkCoach — a coach for academic talk prep, pitched at a ~25 minute conference slot.

Help the user:
- Structure: motivating problem → key idea → result → why it matters. Push back if the structure is buried.
- Trim slides ruthlessly: every slide must earn its existence with one main point.
- Anticipate hostile questions and rehearse 1–2 sentence answers, not full essays.
- Spot jargon the audience won't share and flag it.

Never write the talk for the user wholesale; their voice matters. Suggest specific edits and the reason behind each.

Now wait for the user's description of the new agent."#;

#[tauri::command]
async fn generate_agent_prompt(
    app: AppHandle,
    turn_id: u64,
    description: String,
    model: Option<String>,
) -> Result<(), String> {
    let trimmed = description.trim();
    if trimmed.is_empty() {
        return Err("description cannot be empty".into());
    }
    let model = model
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| "mlx-community/Qwen2.5-7B-Instruct-4bit".to_string());

    let messages = vec![
        ChatMessage {
            role: "system".into(),
            content: ARCHITECT_SYSTEM.to_string(),
            ..Default::default()
        },
        ChatMessage {
            role: "user".into(),
            content: trimmed.to_string(),
            ..Default::default()
        },
    ];

    let app_clone = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(message) =
            stream_chat_to(app_clone.clone(), "prompt_gen", turn_id, model, messages).await
        {
            let _ = app_clone.emit(
                "prompt_gen:error",
                ErrorEvent { turn_id, message },
            );
        }
    });
    Ok(())
}

#[tauri::command]
fn list_capabilities() -> Vec<CapabilityInfo> {
    caps::ALL
        .iter()
        .map(|c| CapabilityInfo {
            key: c.key,
            label: c.label,
            description: c.description,
        })
        .collect()
}

#[tauri::command]
async fn delete_agent(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    agent_id: Thing,
) -> Result<(), String> {
    db::delete_agent(&db, &agent_id)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("agents:updated", ());
    let _ = app.emit("chats:updated", ());
    Ok(())
}

#[tauri::command]
async fn set_chat_agent(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    chat_id: Thing,
    agent_id: Option<Thing>,
) -> Result<(), String> {
    db::set_chat_agent(&db, &chat_id, agent_id.as_ref())
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("chats:updated", ());
    Ok(())
}

#[tauri::command]
async fn set_chat_agents(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    chat_id: Thing,
    agent_ids: Vec<Thing>,
) -> Result<(), String> {
    db::set_chat_agents(&db, &chat_id, &agent_ids)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("chats:updated", ());
    Ok(())
}

#[tauri::command]
async fn list_chat_agents(
    db: tauri::State<'_, Surreal<Db>>,
    chat_id: Thing,
) -> Result<Vec<db::Agent>, String> {
    db::get_chat_agents(&db, &chat_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn search(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    query: String,
    limit: Option<usize>,
) -> Result<SearchResults, String> {
    db::search(&db, &workspace_id, &query, limit.unwrap_or(20))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn graph_view_query(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    limit: Option<usize>,
) -> Result<GraphSlice, String> {
    graph::view_query(&db, &workspace_id, limit.unwrap_or(500))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn graph_neighbors_for_note(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: String,
    limit: Option<usize>,
) -> Result<Option<GraphSlice>, String> {
    let Some(note) = db::get_note(&db, &workspace_id, &title)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    graph::neighbors(&db, &note.id, None, limit.unwrap_or(40))
        .await
        .map(Some)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn list_folders(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
) -> Result<Vec<Folder>, String> {
    db::list_folders(&db, &workspace_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn create_folder(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    name: String,
    color: Option<String>,
) -> Result<Option<Folder>, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("folder name cannot be empty".into());
    }
    let folder = db::create_folder(&db, &workspace_id, trimmed, color.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(folder)
}

#[tauri::command]
async fn rename_folder(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    folder_id: Thing,
    name: String,
) -> Result<(), String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("folder name cannot be empty".into());
    }
    db::rename_folder(&db, &folder_id, trimmed)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(())
}

#[tauri::command]
async fn delete_folder(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    folder_id: Thing,
) -> Result<(), String> {
    db::delete_folder(&db, &folder_id)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(())
}

#[tauri::command]
async fn set_note_folder(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    title: String,
    folder_id: Option<Thing>,
) -> Result<Option<Note>, String> {
    let note = db::set_note_folder(&db, &workspace_id, &title, folder_id.as_ref(), "user")
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(note)
}

#[tauri::command]
async fn promote_email_thread(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    thread_id: String,
    account_id: String,
) -> Result<bool, String> {
    match db::promote_email_thread(&db, &thread_id, &account_id)
        .await
        .map_err(|e| e.to_string())?
    {
        db::PromoteOutcome::NotFound => Err(
            "thread not found — nothing to promote (the shadow row \
             should land on next mail sync if the thread exists)"
                .into(),
        ),
        db::PromoteOutcome::Promoted => {
            let _ = app.emit("vault:updated", ());
            Ok(true)
        }
        db::PromoteOutcome::AlreadyPromoted => Ok(false),
    }
}

#[tauri::command]
async fn unpromote_email_thread(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    thread_id: String,
    account_id: String,
) -> Result<(), String> {
    db::unpromote_email_thread(&db, &thread_id, &account_id)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(())
}

#[tauri::command]
async fn graph_search(
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    query: String,
    limit: Option<usize>,
) -> Result<GraphSlice, String> {
    graph::search_with_expansion(&db, &workspace_id, &query, limit.unwrap_or(20))
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn graph_relate(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    from_title: String,
    to_title: String,
    kind: Option<String>,
    context: Option<String>,
) -> Result<(), String> {
    let kind = kind.unwrap_or_else(|| "references".into());
    db::relate_notes(
        &db,
        &workspace_id,
        &from_title,
        &to_title,
        &kind,
        context.as_deref(),
        "user",
    )
    .await
    .map_err(|e| e.to_string())?;
    let _ = app.emit("vault:updated", ());
    Ok(())
}

#[tauri::command]
async fn graph_unrelate(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
    from_title: String,
    to_title: String,
    kind: Option<String>,
) -> Result<(), String> {
    let from = db::get_note(&db, &workspace_id, &from_title)
        .await
        .map_err(|e| e.to_string())?;
    let to = db::get_note(&db, &workspace_id, &to_title)
        .await
        .map_err(|e| e.to_string())?;
    if let (Some(f), Some(t)) = (from, to) {
        graph::unrelate(&db, &f.id, &t.id, kind.as_deref(), "user")
            .await
            .map_err(|e| e.to_string())?;
        let _ = app.emit("vault:updated", ());
    }
    Ok(())
}

#[tauri::command]
async fn delete_workspace(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    workspace_id: Thing,
) -> Result<bool, String> {
    let removed = db::delete_workspace(&db, &workspace_id)
        .await
        .map_err(|e| e.to_string())?;
    if removed {
        let _ = app.emit("workspaces:updated", ());
    }
    Ok(removed)
}

#[tauri::command]
async fn rename_chat(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    chat_id: Thing,
    title: String,
) -> Result<(), String> {
    db::rename_chat(&db, &chat_id, &title)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("chats:updated", ());
    Ok(())
}

#[tauri::command]
async fn delete_chat(
    app: AppHandle,
    db: tauri::State<'_, Surreal<Db>>,
    chat_id: Thing,
) -> Result<(), String> {
    db::delete_chat(&db, &chat_id)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit("chats:updated", ());
    Ok(())
}

#[tauri::command]
async fn list_messages(
    db: tauri::State<'_, Surreal<Db>>,
    chat_id: Thing,
) -> Result<Vec<Message>, String> {
    db::list_messages(&db, &chat_id)
        .await
        .map_err(|e| e.to_string())
}

// ── Legacy Mail.app reader ───────────────────────────────────────
// Read-only viewer of ~/Library/Mail/V*/MailData/Envelope Index +
// .emlx files. Stays alive through Phase 6 so the existing
// `MailView.tsx` keeps working while the native client lands; Phase 7
// deletes it (and the `walkdir` / `mailparse` deps) as part of cutover.
//
// Wrapped in spawn_blocking — rusqlite + walkdir + std::fs are sync
// and we don't want to pin the tauri command thread on disk I/O for
// large mailboxes.

#[tauri::command]
async fn mail_list_mailboxes() -> Result<Vec<mail::Mailbox>, String> {
    tokio::task::spawn_blocking(mail::legacy_list_mailboxes)
        .await
        .map_err(|e| format!("mail_list_mailboxes spawn: {e}"))?
}

#[tauri::command]
async fn mail_list_messages(
    mailbox_id: i64,
    limit: Option<i64>,
) -> Result<Vec<mail::MailMessage>, String> {
    let lim = limit.unwrap_or(200).clamp(1, 5000);
    tokio::task::spawn_blocking(move || mail::legacy_list_messages(mailbox_id, lim))
        .await
        .map_err(|e| format!("mail_list_messages spawn: {e}"))?
}

#[tauri::command]
async fn mail_get_body(message_id: i64) -> Result<mail::MailBody, String> {
    tokio::task::spawn_blocking(move || mail::legacy_get_body(message_id))
        .await
        .map_err(|e| format!("mail_get_body spawn: {e}"))?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

    let capture_shortcut = Shortcut::new(
        Some(Modifiers::SUPER | Modifiers::SHIFT),
        Code::KeyK,
    );

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if shortcut == &capture_shortcut && event.state() == ShortcutState::Pressed {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.unminimize();
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                        let _ = app.emit("capture:open", ());
                    }
                })
                .build(),
        )
        .setup(move |app| {
            let handle = app.handle().clone();
            let data_dir = handle
                .path()
                .app_data_dir()
                .expect("app_data_dir resolves on macOS");
            let db = tauri::async_runtime::block_on(db::open(data_dir))
                .expect("surrealdb opens at app data dir");
            // Background reembed loop. Surreal handle is internally
            // Arc-shared, so cloning is cheap; spawn picks up updates
            // independently of the user-facing query handle.
            let embed_db = std::sync::Arc::new(db.clone());
            tauri::async_runtime::spawn(embed::run_reembed_loop(embed_db));
            // One-shot wikilink rescan. Walks every note, replays the
            // body parser, brings missing `mentions` edges in line with
            // current bodies. Idempotent; the marker row in graph_meta
            // makes subsequent boots no-ops.
            let rescan_db: Surreal<Db> = db.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = graph::run_wikilink_rescan(&rescan_db).await {
                    eprintln!("[graph] wikilink rescan failed: {e}");
                }
            });
            handle.manage(db);
            handle.manage(ChatCancels::default());
            handle.manage(ResourceUsageState::default());
            handle.manage(ghostty_native::TerminalNativeState::default());
            ghostty_native::install_terminal_event_emitter(handle.clone());

            // Native mail client — open mail.db (Phase 1 substrate)
            // and stash the in-flight OAuth registry. Both are
            // tauri::State so commands pull them via injection.
            let mail_data_dir = handle
                .path()
                .app_data_dir()
                .expect("app_data_dir resolves on macOS");
            let mail_db = tauri::async_runtime::block_on(mail::db::MailDb::open(&mail_data_dir))
                .expect("mail.db opens at app data dir");
            // Spawn the outbox supervisor (drains queued sends after
            // their undo windows expire, retries with exponential
            // backoff). Handle clones are cheap — Surreal<Db> is
            // Arc-wrapped internally; MailDb wraps an Arc<Mutex<…>>.
            let outbox_db = mail_db.clone();
            let outbox_surreal: Surreal<Db> = (*handle.state::<Surreal<Db>>()).clone();
            let outbox_app = handle.clone();
            tauri::async_runtime::spawn(mail::outbox::run_supervisor(
                outbox_db,
                outbox_surreal,
                outbox_app,
            ));
            // Spawn IMAP IDLE supervisors for every existing account.
            // Each supervisor maintains a persistent IDLE session on
            // INBOX and triggers an incremental sync on push. The
            // periodic 30s poll is the safety net.
            let idle_db = mail_db.clone();
            let idle_surreal: Surreal<Db> = (*handle.state::<Surreal<Db>>()).clone();
            let idle_app = handle.clone();
            tauri::async_runtime::spawn(async move {
                mail::idle::spawn_for_existing_accounts(idle_db, idle_surreal, idle_app).await;
            });

            // One-shot: backfill SurrealDB email_thread shadows for
            // every account whose mail.db is already populated. Necessary
            // because the sync hook only reports threads from the slice
            // it just fetched, so users who synced before the shadow
            // layer existed (or who have no new mail) would otherwise
            // see no email nodes in the graph.
            let backfill_mail_db = mail_db.clone();
            let backfill_surreal: Surreal<Db> = (*handle.state::<Surreal<Db>>()).clone();
            tauri::async_runtime::spawn(async move {
                let accounts = match db::list_email_accounts(&backfill_surreal).await {
                    Ok(a) => a,
                    Err(e) => {
                        eprintln!("[mail::sync] backfill list_email_accounts: {e}");
                        return;
                    }
                };
                for acc in accounts {
                    if let Err(e) = mail::sync::backfill_thread_shadows(
                        &backfill_mail_db,
                        &backfill_surreal,
                        &acc.id,
                    )
                    .await
                    {
                        eprintln!("[mail::sync] backfill {}: {e}", acc.id);
                    }
                }
            });
            handle.manage(mail_db);
            handle.manage(mail::commands::OAuthPending::default());

            app.global_shortcut().register(capture_shortcut)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            chat_stream,
            chat_cancel,
            app_resource_usage,
            list_notes,
            create_note,
            inspect_note,
            update_note_body,
            rename_note,
            delete_note,
            list_chats,
            create_chat,
            rename_chat,
            delete_chat,
            list_messages,
            mail_list_mailboxes,
            mail_list_messages,
            mail_get_body,
            // Native mail client.
            mail::commands::mail_autoconfig,
            mail::commands::mail_oauth_start,
            mail::commands::mail_oauth_complete,
            mail::commands::mail_account_list,
            mail::commands::mail_account_remove,
            mail::commands::mail_sync_inbox,
            mail::commands::mail_sync_folder,
            mail::commands::mail_refresh_flags,
            mail::commands::mail_load_older,
            mail::commands::mail_folder_list,
            mail::commands::mail_message_list,
            mail::commands::mail_thread_get,
            mail::commands::mail_message_get,
            mail::commands::mail_remote_images_allow,
            mail::commands::mail_debug_flags,
            mail::commands::mail_search,
            mail::commands::mail_unified_inbox,
            mail::commands::mail_send,
            mail::commands::mail_outbox_undo,
            mail::commands::mail_outbox_pending,
            mail::commands::mail_message_set_flag,
            mail::commands::mail_message_move,
            mail::commands::mail_message_archive,
            mail::commands::mail_message_delete,
            list_workspaces,
            create_workspace,
            rename_workspace,
            delete_workspace,
            search,
            graph_view_query,
            graph_neighbors_for_note,
            graph_search,
            graph_relate,
            graph_unrelate,
            promote_email_thread,
            unpromote_email_thread,
            list_folders,
            create_folder,
            rename_folder,
            delete_folder,
            set_note_folder,
            list_agents,
            create_agent,
            update_agent,
            delete_agent,
            set_chat_agent,
            set_chat_agents,
            list_chat_agents,
            list_capabilities,
            mlx_model_status,
            generate_agent_prompt,
            ghostty_native::terminal_native_show,
            ghostty_native::terminal_native_hide,
            ghostty_native::terminal_native_close,
            ghostty_native::terminal_native_hide_all,
            ghostty_native::terminal_native_reset_generation,
            ghostty_native::terminal_native_set_overlay_clip,
            ghostty_native::terminal_native_install_app_shortcuts,
            ghostty_native::terminal_native_prewarm,
            ghostty_native::window_set_traffic_lights_hidden,
            ghostty_native::terminal_native_snapshot,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::{agent_mention_slug, agent_mention_targets, normalize_agent_mention};

    #[test]
    fn mention_targets_match_frontend_slug_rules() {
        assert_eq!(agent_mention_targets("@calendar today"), vec!["calendar"]);
        assert_eq!(
            agent_mention_targets("@email-agent check sent mail"),
            vec!["emailagent"]
        );
        assert_eq!(
            normalize_agent_mention(&agent_mention_slug("Email Agent")),
            "emailagent"
        );
    }
}
