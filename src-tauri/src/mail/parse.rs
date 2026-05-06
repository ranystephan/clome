//! Inbound MIME parser. Wraps `mail-parser` (zero-copy, charset-aware)
//! and produces a flat `ParsedMessage` shaped for the rest of the
//! pipeline — threading, FTS indexing, sanitisation, UI.
//!
//! Charsets: mail-parser already does the heavy lifting (UTF-8
//! conversion via `encoding_rs`), so callers always see `String` /
//! `&str` regardless of what came down the wire.

use mail_parser::{Address, HeaderValue, MessageParser, MimeHeaders, PartType};

/// Snippet length we precompute and store in `message.snippet` so the
/// list view doesn't have to re-extract from the body on every render.
const SNIPPET_CHARS: usize = 200;

/// Result of parsing one RFC 822 message. Owned (`String`s) so it can
/// cross thread + DB boundaries without lifetime contortions.
#[derive(Debug, Clone)]
pub struct ParsedMessage {
    pub message_id: Option<String>,
    pub in_reply_to: Option<String>,
    /// Full `References:` chain in document order. Newest reference
    /// is last (RFC 2822 §3.6.4).
    pub references: Vec<String>,
    pub subject: Option<String>,
    pub from_addr: Option<String>,
    pub from_name: Option<String>,
    pub to: Vec<EmailAddr>,
    pub cc: Vec<EmailAddr>,
    pub bcc: Vec<EmailAddr>,
    /// Unix seconds, from the `Date:` header. Falls back to
    /// `INTERNALDATE` (the IMAP server timestamp) at the call site
    /// when this is `None`.
    pub date_sent: Option<i64>,
    pub body_text: Option<String>,
    pub body_html: Option<String>,
    pub snippet: String,
    pub attachments: Vec<ParsedAttachment>,
    /// Whether the message contains a `text/calendar` part. Lit by
    /// the inline RSVP card in Phase 5; tracked here so it doesn't
    /// require re-parsing the .eml later.
    pub has_calendar_invite: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmailAddr {
    pub addr: String,
    pub name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ParsedAttachment {
    /// Content-ID with surrounding `<>` stripped, or a synthesised
    /// stable id (e.g. `att-{index}`) when the part has no Content-ID.
    /// Same value flows into `mail::store::attachment_path`.
    pub content_id: String,
    pub filename: Option<String>,
    pub mime: String,
    pub size: usize,
    /// True for inline parts that rendered HTML references via `cid:`.
    /// The renderer rewrites those to local file URLs at display time.
    pub is_inline: bool,
    /// Raw bytes. Phase 2 keeps these in memory — Phase 4 lazy
    /// download path will replace this with on-demand fetch.
    pub bytes: Vec<u8>,
}

pub fn parse(raw: &[u8]) -> Result<ParsedMessage, String> {
    let msg = MessageParser::default()
        .parse(raw)
        .ok_or_else(|| "MIME parser rejected the message".to_string())?;

    let message_id = msg.message_id().map(|s| s.to_string());
    let in_reply_to = single_id(msg.in_reply_to());
    let references = id_list(msg.references());

    let subject = msg.subject().map(|s| s.to_string());
    let (from_addr, from_name) = match msg.from() {
        Some(a) => first_addr_split(a),
        None => (None, None),
    };
    let to = msg.to().map(addr_list).unwrap_or_default();
    let cc = msg.cc().map(addr_list).unwrap_or_default();
    let bcc = msg.bcc().map(addr_list).unwrap_or_default();
    let date_sent = msg.date().map(|d| d.to_timestamp());

    let body_text = msg.body_text(0).map(|s| s.into_owned());
    let body_html = msg.body_html(0).map(|s| s.into_owned());
    let snippet = build_snippet(body_text.as_deref(), body_html.as_deref());

    let mut attachments = Vec::new();
    let mut has_calendar_invite = false;
    for (idx, part) in msg.parts.iter().enumerate() {
        let mime = part_mime(part);
        if mime.eq_ignore_ascii_case("text/calendar") {
            has_calendar_invite = true;
        }
        // Skip the multipart wrappers and the body parts already
        // surfaced via body_text / body_html.
        if !is_attachment_part(part) {
            continue;
        }
        let bytes = match &part.body {
            PartType::Binary(b) | PartType::InlineBinary(b) => b.to_vec(),
            PartType::Text(t) | PartType::Html(t) => t.as_bytes().to_vec(),
            _ => continue,
        };
        let content_id = part
            .content_id()
            .map(strip_angles)
            .unwrap_or_else(|| format!("att-{idx}"));
        attachments.push(ParsedAttachment {
            content_id,
            filename: part.attachment_name().map(|s| s.to_string()),
            mime,
            size: bytes.len(),
            is_inline: matches!(part.body, PartType::InlineBinary(_)),
            bytes,
        });
    }

    Ok(ParsedMessage {
        message_id,
        in_reply_to,
        references,
        subject,
        from_addr,
        from_name,
        to,
        cc,
        bcc,
        date_sent,
        body_text,
        body_html,
        snippet,
        attachments,
        has_calendar_invite,
    })
}

fn part_mime(part: &mail_parser::MessagePart<'_>) -> String {
    let ct = part.content_type();
    let main = ct
        .map(|c| c.ctype())
        .unwrap_or("application")
        .to_ascii_lowercase();
    let sub = ct
        .and_then(|c| c.subtype())
        .unwrap_or("octet-stream")
        .to_ascii_lowercase();
    format!("{main}/{sub}")
}

fn is_attachment_part(part: &mail_parser::MessagePart<'_>) -> bool {
    match part.body {
        PartType::Binary(_) | PartType::InlineBinary(_) => true,
        PartType::Text(_) | PartType::Html(_) => part.attachment_name().is_some(),
        _ => false,
    }
}

fn first_addr_split(addr: &Address<'_>) -> (Option<String>, Option<String>) {
    let first = match addr {
        Address::List(list) => list.first(),
        Address::Group(groups) => groups
            .first()
            .and_then(|g| g.addresses.first()),
    };
    match first {
        Some(a) => (
            a.address().map(|s| s.to_string()),
            a.name().map(|s| s.to_string()),
        ),
        None => (None, None),
    }
}

fn addr_list(addr: &Address<'_>) -> Vec<EmailAddr> {
    let mut out = Vec::new();
    match addr {
        Address::List(list) => {
            for a in list.iter() {
                if let Some(addr) = a.address() {
                    out.push(EmailAddr {
                        addr: addr.to_string(),
                        name: a.name().map(|s| s.to_string()),
                    });
                }
            }
        }
        Address::Group(groups) => {
            for g in groups.iter() {
                for a in g.addresses.iter() {
                    if let Some(addr) = a.address() {
                        out.push(EmailAddr {
                            addr: addr.to_string(),
                            name: a.name().map(|s| s.to_string()),
                        });
                    }
                }
            }
        }
    }
    out
}

fn single_id(hv: &HeaderValue<'_>) -> Option<String> {
    match hv {
        HeaderValue::Text(s) => Some(strip_angles(s)),
        HeaderValue::TextList(list) => list.first().map(|s| strip_angles(s)),
        _ => None,
    }
}

fn id_list(hv: &HeaderValue<'_>) -> Vec<String> {
    match hv {
        HeaderValue::Text(s) => split_id_chain(s),
        HeaderValue::TextList(list) => list.iter().flat_map(|s| split_id_chain(s)).collect(),
        _ => Vec::new(),
    }
}

/// `References:` may be one big space-separated string OR multiple
/// folded lines that mail-parser concatenates. Either way, the canonical
/// form is whitespace-separated `<id>` tokens.
fn split_id_chain(s: &str) -> Vec<String> {
    s.split_ascii_whitespace()
        .filter(|t| !t.is_empty())
        .map(strip_angles)
        .filter(|t| !t.is_empty())
        .collect()
}

fn strip_angles(s: &str) -> String {
    let s = s.trim();
    let s = s.strip_prefix('<').unwrap_or(s);
    let s = s.strip_suffix('>').unwrap_or(s);
    s.to_string()
}

/// Snippet = first 200 visible chars from text/plain (preferred) or
/// text/html stripped of tags. Single-line, collapsed whitespace.
fn build_snippet(text: Option<&str>, html: Option<&str>) -> String {
    let raw: String = match (text, html) {
        (Some(t), _) if !t.trim().is_empty() => t.to_string(),
        (_, Some(h)) if !h.trim().is_empty() => strip_html_tags(h),
        _ => String::new(),
    };
    let mut out = String::with_capacity(SNIPPET_CHARS);
    let mut last_space = false;
    for c in raw.chars() {
        if c.is_whitespace() {
            if last_space {
                continue;
            }
            out.push(' ');
            last_space = true;
        } else {
            out.push(c);
            last_space = false;
        }
        if out.chars().count() >= SNIPPET_CHARS {
            break;
        }
    }
    out.trim().to_string()
}

/// Cheap tag stripper for the snippet path only — never used for
/// rendering. The actual sanitiser (`mail::sanitize`) does proper
/// HTML→DOM walking via `ammonia`.
fn strip_html_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}
