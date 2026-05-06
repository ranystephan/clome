//! Mail.app reader. Drives the in-app mail viewer without an IMAP
//! client of our own — Mail.app already manages every account the
//! user has configured. We read its `Envelope Index` sqlite (metadata
//! + snippets) and the per-message .emlx files for full bodies.
//!
//! Read-only. Actions (delete / reply / mark-read) go through
//! AppleScript in a later phase so Mail.app stays the source of truth
//! and IMAP sync stays consistent.
//!
//! Path layout (macOS Sonoma+):
//!   ~/Library/Mail/V10/MailData/Envelope Index             — sqlite
//!   ~/Library/Mail/V10/<account-uuid>/<mailbox>.mbox/...   — emlx
//!
//! `V10` is the current Mail.app schema version. Older OSes (V9, V8)
//! shared the same schema names; we resolve the highest-numbered V*
//! directory and use that.

use mailparse::{parse_mail, MailHeaderMap, ParsedMail};
use rusqlite::{params, Connection, OpenFlags};
use serde::Serialize;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Mailbox {
    pub id: i64,
    pub url: String,
    pub display_name: String,
    pub unread_count: i64,
    pub total_count: i64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct MailMessage {
    pub id: i64,
    pub subject: String,
    pub sender: String,
    pub snippet: String,
    pub date_received: i64, // unix seconds
    pub mailbox_id: i64,
    pub read: bool,
    pub flagged: bool,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct MailBody {
    pub id: i64,
    pub subject: String,
    pub from: String,
    pub to: String,
    pub cc: Option<String>,
    pub date: String,
    /// HTML body if present, else plain text wrapped in <pre>. Always
    /// safe to drop into an iframe with srcdoc.
    pub html: String,
    pub plain: String,
}

fn mail_root() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME unset".to_string())?;
    let mail_dir = home.join("Library").join("Mail");
    if !mail_dir.exists() {
        return Err(format!(
            "Mail.app data dir not found at {} — open Mail.app once to create it",
            mail_dir.display()
        ));
    }
    // Pick the highest VN/ — schema versions advance with macOS.
    let best = std::fs::read_dir(&mail_dir)
        .map_err(|e| format!("read {}: {e}", mail_dir.display()))?
        .filter_map(|r| r.ok())
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            if let Some(n) = name.strip_prefix('V') {
                n.parse::<u32>().ok().map(|v| (v, e.path()))
            } else {
                None
            }
        })
        .max_by_key(|(v, _)| *v)
        .map(|(_, p)| p)
        .ok_or_else(|| "no V* mail data dir found".to_string())?;
    Ok(best)
}

fn open_envelope_index() -> Result<Connection, String> {
    let path = mail_root()?.join("MailData").join("Envelope Index");
    if !path.exists() {
        return Err(format!("envelope index not found: {}", path.display()));
    }
    // Read-only + URI form so SQLite doesn't try to create the WAL.
    // immutable=1 keeps us off Mail.app's locks.
    let uri = format!("file:{}?mode=ro&immutable=1", path.display());
    Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|e| format!("open envelope index: {e}"))
}

fn humanize_mailbox_url(url: &str) -> String {
    // Examples:
    //   imap://user%40gmail.com@imap.gmail.com:993/INBOX
    //   imap://user@imap.fastmail.com/Sent
    //   local://Local/INBOX
    //   exchange://...
    if let Some(slash) = url.rfind('/') {
        let tail = &url[slash + 1..];
        if !tail.is_empty() {
            return urldecode(tail);
        }
    }
    url.to_string()
}

fn urldecode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
            if let Ok(b) = u8::from_str_radix(hex, 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn list_mailboxes() -> Result<Vec<Mailbox>, String> {
    let conn = open_envelope_index()?;
    // mailboxes.url is the canonical identifier; total_count and
    // unread_count cached on the row.
    let mut stmt = conn
        .prepare(
            "SELECT ROWID, url, IFNULL(unread_count, 0), IFNULL(total_count, 0) \
             FROM mailboxes \
             WHERE url IS NOT NULL \
             ORDER BY url ASC",
        )
        .map_err(|e| format!("prepare list_mailboxes: {e}"))?;
    let rows = stmt
        .query_map([], |row| {
            let id: i64 = row.get(0)?;
            let url: String = row.get(1)?;
            let unread: i64 = row.get(2)?;
            let total: i64 = row.get(3)?;
            Ok(Mailbox {
                id,
                display_name: humanize_mailbox_url(&url),
                url,
                unread_count: unread,
                total_count: total,
            })
        })
        .map_err(|e| format!("query list_mailboxes: {e}"))?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| format!("row: {e}"))?);
    }
    Ok(out)
}

pub fn list_messages(mailbox_id: i64, limit: i64) -> Result<Vec<MailMessage>, String> {
    let conn = open_envelope_index()?;
    // Mail.app schema: subject + sender are normalized into separate
    // tables. Messages table stores `subject` and `sender` as foreign
    // keys (ROWID into the respective tables). `read` is a bit flag in
    // the `flags` column. snippet is right on messages.
    //
    // `flags` bit layout (verified against Mail.app on Sonoma):
    //   0x01 = read, 0x10 = flagged.
    let sql = "
        SELECT m.ROWID,
               IFNULL(s.subject, ''),
               IFNULL(a.address, '') || \
                 CASE WHEN a.comment IS NOT NULL AND a.comment != '' \
                      THEN ' (' || a.comment || ')' ELSE '' END,
               IFNULL(m.snippet, ''),
               IFNULL(m.date_received, 0),
               m.mailbox,
               IFNULL(m.read, 0),
               IFNULL(m.flagged, 0)
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        WHERE m.mailbox = ?
        ORDER BY m.date_received DESC
        LIMIT ?
    ";
    let mut stmt = conn
        .prepare(sql)
        .map_err(|e| format!("prepare list_messages: {e}"))?;
    let rows = stmt
        .query_map(params![mailbox_id, limit], |row| {
            Ok(MailMessage {
                id: row.get(0)?,
                subject: row.get(1)?,
                sender: row.get(2)?,
                snippet: row.get(3)?,
                date_received: row.get(4)?,
                mailbox_id: row.get(5)?,
                read: row.get::<_, i64>(6)? != 0,
                flagged: row.get::<_, i64>(7)? != 0,
            })
        })
        .map_err(|e| format!("query list_messages: {e}"))?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| format!("row: {e}"))?);
    }
    Ok(out)
}

/// Locates the .emlx file for a given message ROWID. Mail.app stores
/// each message at <account>/<mailbox>.mbox/Messages/<ROWID>.emlx
/// (with intermediate fragmenting for >9999 IDs). We walk the V*
/// directory and match on the filename.
fn find_emlx(message_id: i64) -> Result<PathBuf, String> {
    let root = mail_root()?;
    let needle = format!("{message_id}.emlx");
    let needle_partial = format!("{message_id}.partial.emlx");
    for entry in WalkDir::new(&root)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
    {
        if let Some(name) = entry.file_name().to_str() {
            if name == needle || name == needle_partial {
                return Ok(entry.into_path());
            }
        }
    }
    Err(format!("emlx for {message_id} not found"))
}

/// .emlx format: first line is an ASCII byte count, then `byte_count`
/// bytes of RFC822, then a trailing XML plist with flags. We only
/// need the RFC822 portion.
fn read_emlx_rfc822(path: &Path) -> Result<Vec<u8>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let nl = bytes
        .iter()
        .position(|b| *b == b'\n')
        .ok_or_else(|| "emlx has no header".to_string())?;
    let count: usize = std::str::from_utf8(&bytes[..nl])
        .map_err(|e| format!("emlx header utf8: {e}"))?
        .trim()
        .parse()
        .map_err(|e| format!("emlx count parse: {e}"))?;
    let body_start = nl + 1;
    let body_end = (body_start + count).min(bytes.len());
    Ok(bytes[body_start..body_end].to_vec())
}

fn extract_bodies(parsed: &ParsedMail) -> (String, String) {
    let mut html = String::new();
    let mut plain = String::new();
    walk_parts(parsed, &mut html, &mut plain);
    (html, plain)
}

fn walk_parts(part: &ParsedMail, html: &mut String, plain: &mut String) {
    let ctype = part.ctype.mimetype.to_ascii_lowercase();
    if ctype.starts_with("multipart/") {
        for sub in &part.subparts {
            walk_parts(sub, html, plain);
        }
        return;
    }
    let body = part.get_body().unwrap_or_default();
    if ctype == "text/html" && html.is_empty() {
        *html = body;
    } else if ctype == "text/plain" && plain.is_empty() {
        *plain = body;
    }
}

pub fn get_body(message_id: i64) -> Result<MailBody, String> {
    let path = find_emlx(message_id)?;
    let raw = read_emlx_rfc822(&path)?;
    let parsed = parse_mail(&raw).map_err(|e| format!("parse mail: {e}"))?;
    let headers = &parsed.headers;
    let subject = headers.get_first_value("Subject").unwrap_or_default();
    let from = headers.get_first_value("From").unwrap_or_default();
    let to = headers.get_first_value("To").unwrap_or_default();
    let cc = headers.get_first_value("Cc");
    let date = headers.get_first_value("Date").unwrap_or_default();
    let (html, plain) = extract_bodies(&parsed);
    let html = if html.is_empty() {
        // Fallback: wrap plain-text in <pre> so the iframe has
        // something to render. Escape HTML to avoid accidental injection
        // when an email body legitimately contains `<` etc.
        format!(
            "<pre style=\"white-space:pre-wrap;font-family:inherit\">{}</pre>",
            html_escape(&plain)
        )
    } else {
        html
    };
    Ok(MailBody {
        id: message_id,
        subject,
        from,
        to,
        cc,
        date,
        html,
        plain,
    })
}

fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}
