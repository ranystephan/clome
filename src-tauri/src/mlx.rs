use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter};
use tokio_util::sync::CancellationToken;

const MLX_BASE_URL: &str = "http://localhost:8080/v1";

/// OpenAI-shape chat message. `content` is always present (empty string
/// for tool-call assistant turns — mlx_lm accepts this). Optional fields
/// kick in for tool flows: `tool_calls` on assistant when the model
/// invokes a function; `tool_call_id` + `name` on `role: "tool"` rows
/// carrying the function result. `skip_serializing_if = "Option::is_none"`
/// keeps wire format clean for plain user/system rows.
#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct ChatMessage {
    pub role: String,
    #[serde(default)]
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub tool_calls: Option<Vec<ToolCallStruct>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub name: Option<String>,
}

impl ChatMessage {
    pub fn assistant_tool_calls(tool_calls: Vec<ToolCallStruct>) -> Self {
        Self {
            role: "assistant".into(),
            content: String::new(),
            tool_calls: Some(tool_calls),
            ..Default::default()
        }
    }
    pub fn tool(tool_call_id: impl Into<String>, name: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: "tool".into(),
            content: content.into(),
            tool_call_id: Some(tool_call_id.into()),
            name: Some(name.into()),
            ..Default::default()
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ToolCallStruct {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String, // always "function"
    pub function: ToolCallFunction,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ToolCallFunction {
    pub name: String,
    /// JSON-encoded arguments string (per OpenAI spec).
    pub arguments: String,
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: &'a [ChatMessage],
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    tools: Option<&'a [Value]>,
}

/// Final result of a streamed chat completion. With native tool calling,
/// a single completion can produce both prose content (rare alongside
/// tool_calls but possible) and structured tool calls. `finish_reason`
/// distinguishes the cases: "tool_calls" → caller should dispatch and
/// loop; "stop" → assistant turn complete.
#[derive(Clone, Debug, Default)]
pub struct StreamResult {
    pub content: String,
    pub tool_calls: Vec<ToolCallStruct>,
    pub finish_reason: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct ModelStatus {
    pub server_reachable: bool,
    pub available: bool,
    pub models: Vec<String>,
}

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<ModelInfo>,
}

#[derive(Deserialize)]
struct ModelInfo {
    id: String,
}

pub async fn model_status(model: String) -> Result<ModelStatus, String> {
    let client = reqwest::Client::new();
    let resp = client
        .get(format!("{}/models", MLX_BASE_URL))
        .send()
        .await
        .map_err(|e| format!("connect: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("mlx server {status}: {text}"));
    }

    let parsed = resp
        .json::<ModelsResponse>()
        .await
        .map_err(|e| format!("models json: {e}"))?;
    let models: Vec<String> = parsed.data.into_iter().map(|m| m.id).collect();
    let wanted = model.trim();
    let available = models.iter().any(|m| m == wanted);

    Ok(ModelStatus {
        server_reachable: true,
        available,
        models,
    })
}

#[derive(Deserialize)]
struct StreamChunk {
    choices: Vec<StreamChoice>,
}

#[derive(Deserialize)]
struct StreamChoice {
    delta: Delta,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize)]
struct Delta {
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    tool_calls: Option<Vec<DeltaToolCall>>,
}

/// Delta tool call. mlx_lm.server emits the call as a single complete
/// JSON object (not token-by-token), so we don't need to accumulate
/// `function.arguments` across deltas — each delta carries the full
/// arguments string. `index` lets the caller distinguish parallel calls
/// if the model emits more than one.
#[derive(Deserialize)]
struct DeltaToolCall {
    #[serde(default)]
    id: Option<String>,
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    function: Option<DeltaToolFunction>,
    #[serde(default)]
    index: Option<usize>,
}

#[derive(Deserialize)]
struct DeltaToolFunction {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    arguments: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct TokenEvent {
    #[serde(rename = "turnId")]
    pub turn_id: u64,
    pub token: String,
}

#[derive(Serialize, Clone)]
pub struct DoneEvent {
    #[serde(rename = "turnId")]
    pub turn_id: u64,
}

#[derive(Serialize, Clone)]
pub struct ErrorEvent {
    #[serde(rename = "turnId")]
    pub turn_id: u64,
    pub message: String,
}

pub async fn stream_chat_cancelable(
    app: AppHandle,
    turn_id: u64,
    model: String,
    messages: Vec<ChatMessage>,
    tools: Option<Vec<Value>>,
    cancel: CancellationToken,
) -> Result<StreamResult, String> {
    stream_chat_to_cancelable(app, "chat", turn_id, model, messages, tools, Some(cancel), false).await
}

/// Same as stream_chat but emits events under the `event_ns` namespace
/// (e.g. "chat" → chat:token / chat:done / chat:error, "prompt_gen" →
/// prompt_gen:token / prompt_gen:done / prompt_gen:error). Lets the
/// agent loop and the prompt-architect generator share one streaming
/// implementation without colliding on event names. Tools-less variant
/// for callers that don't dispatch tools (e.g. prompt architect).
pub async fn stream_chat_to(
    app: AppHandle,
    event_ns: &str,
    turn_id: u64,
    model: String,
    messages: Vec<ChatMessage>,
) -> Result<String, String> {
    let res = stream_chat_to_cancelable(app, event_ns, turn_id, model, messages, None, None, true).await?;
    Ok(res.content)
}

async fn stream_chat_to_cancelable(
    app: AppHandle,
    event_ns: &str,
    turn_id: u64,
    model: String,
    messages: Vec<ChatMessage>,
    tools: Option<Vec<Value>>,
    cancel: Option<CancellationToken>,
    emit_done: bool,
) -> Result<StreamResult, String> {
    let client = reqwest::Client::new();
    let body = ChatRequest {
        model: &model,
        messages: &messages,
        stream: true,
        tools: tools.as_deref(),
    };

    let token_ev = format!("{event_ns}:token");
    let done_ev = format!("{event_ns}:done");

    let req = client
        .post(format!("{}/chat/completions", MLX_BASE_URL))
        .json(&body)
        .send();

    let resp = match &cancel {
        Some(token) => {
            tokio::select! {
                _ = token.cancelled() => {
                    if emit_done {
                        let _ = app.emit(&done_ev, DoneEvent { turn_id });
                    }
                    return Ok(StreamResult::default());
                }
                resp = req => resp.map_err(|e| format!("connect: {e}"))?,
            }
        }
        None => req.await.map_err(|e| format!("connect: {e}"))?,
    };

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("mlx server {status}: {text}"));
    }

    let mut stream = resp.bytes_stream();
    let mut buf = String::new();
    let mut result = StreamResult::default();
    // Per-index tool-call accumulators. mlx_lm.server today emits each
    // call as one complete chunk, but the OpenAI streaming spec allows
    // splitting `arguments` across deltas — accumulating handles both.
    let mut tool_acc: Vec<(Option<String>, String, String)> = Vec::new();

    loop {
        let next = match &cancel {
            Some(token) => {
                tokio::select! {
                    _ = token.cancelled() => {
                        if emit_done {
                            let _ = app.emit(&done_ev, DoneEvent { turn_id });
                        }
                        return Ok(result);
                    }
                    chunk = stream.next() => chunk,
                }
            }
            None => stream.next().await,
        };
        let Some(chunk) = next else { break };
        let chunk = chunk.map_err(|e| format!("stream: {e}"))?;
        buf.push_str(&String::from_utf8_lossy(&chunk));

        loop {
            let Some(idx) = buf.find('\n') else { break };
            let line = buf[..idx].trim().to_string();
            buf.drain(..=idx);

            if line.is_empty() || !line.starts_with("data: ") {
                continue;
            }
            let data = &line[6..];
            if data == "[DONE]" {
                if emit_done {
                    let _ = app.emit(&done_ev, DoneEvent { turn_id });
                }
                result.tool_calls = build_tool_calls(tool_acc);
                return Ok(result);
            }
            let Ok(parsed) = serde_json::from_str::<StreamChunk>(data) else {
                continue;
            };
            let Some(choice) = parsed.choices.into_iter().next() else {
                continue;
            };
            if let Some(reason) = choice.finish_reason {
                result.finish_reason = reason;
            }
            if let Some(token) = choice.delta.content {
                if !token.is_empty() {
                    result.content.push_str(&token);
                    let _ = app.emit(
                        &token_ev,
                        TokenEvent {
                            turn_id,
                            token,
                        },
                    );
                }
            }
            if let Some(calls) = choice.delta.tool_calls {
                for call in calls {
                    let i = call.index.unwrap_or(0);
                    while tool_acc.len() <= i {
                        tool_acc.push((None, String::new(), String::new()));
                    }
                    if let Some(id) = call.id {
                        tool_acc[i].0 = Some(id);
                    }
                    if let Some(f) = call.function {
                        if let Some(n) = f.name {
                            if !n.is_empty() {
                                tool_acc[i].1 = n;
                            }
                        }
                        if let Some(a) = f.arguments {
                            tool_acc[i].2.push_str(&a);
                        }
                    }
                }
            }
        }
    }

    result.tool_calls = build_tool_calls(tool_acc);
    if emit_done {
        let _ = app.emit(&done_ev, DoneEvent { turn_id });
    }
    Ok(result)
}

fn build_tool_calls(acc: Vec<(Option<String>, String, String)>) -> Vec<ToolCallStruct> {
    acc.into_iter()
        .filter(|(_, name, _)| !name.is_empty())
        .enumerate()
        .map(|(i, (id, name, args))| ToolCallStruct {
            id: id.unwrap_or_else(|| format!("call_{i}")),
            kind: "function".into(),
            function: ToolCallFunction {
                name,
                arguments: if args.is_empty() { "{}".into() } else { args },
            },
        })
        .collect()
}
