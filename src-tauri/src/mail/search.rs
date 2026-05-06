//! Mail full-text search over `mail.db` FTS5. The user's query string
//! is parsed into a small DSL of structured filters + free-text terms
//! before being lowered into FTS5 `MATCH` + SQL `WHERE`.
//!
//! Supported operators (Gmail/Apple-Mail-class — keep them familiar):
//!
//!   * `from:<addr-or-name>`    — substring match on `from_addr`
//!   * `to:<addr-or-name>`      — substring match across `to_json`
//!   * `subject:<term>`         — FTS5 column-restricted match
//!   * `in:<folder-or-role>`    — exact match on folder name OR role
//!   * `has:attachment`         — `has_attachments = 1`
//!   * `is:unread`              — flag heuristic
//!   * `is:flagged`             — flag heuristic
//!   * free text                — MATCH across all FTS columns
//!
//! Quotes group terms (`subject:"weekly review"`). Phase 5 polish
//! adds `before:` / `after:` date filters; for now the query DSL
//! ships with the operators most users reach for first.

use rusqlite::{params_from_iter, types::Value, Connection};

use crate::mail::commands::MessageHeader;

#[derive(Debug, Default, Clone)]
pub(crate) struct Query {
    from: Option<String>,
    to: Option<String>,
    in_folder: Option<String>,
    has_attachment: bool,
    is_unread: bool,
    is_flagged: bool,
    /// Terms that target the `subject` FTS column.
    subject_terms: Vec<String>,
    /// Terms that hit any FTS column.
    free_terms: Vec<String>,
}

pub(crate) fn parse(q: &str) -> Query {
    let mut out = Query::default();
    for token in tokenize(q) {
        if let Some(rest) = token.strip_prefix("from:") {
            out.from = Some(rest.to_string());
        } else if let Some(rest) = token.strip_prefix("to:") {
            out.to = Some(rest.to_string());
        } else if let Some(rest) = token.strip_prefix("in:") {
            out.in_folder = Some(rest.to_string());
        } else if let Some(rest) = token.strip_prefix("subject:") {
            out.subject_terms.push(rest.to_string());
        } else if token.eq_ignore_ascii_case("has:attachment")
            || token.eq_ignore_ascii_case("has:attachments")
        {
            out.has_attachment = true;
        } else if token.eq_ignore_ascii_case("is:unread") {
            out.is_unread = true;
        } else if token.eq_ignore_ascii_case("is:flagged") {
            out.is_flagged = true;
        } else {
            out.free_terms.push(token);
        }
    }
    out
}

/// Splits on whitespace but respects double-quoted spans so multi-word
/// FTS phrases like `subject:"weekly review"` survive intact.
fn tokenize(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut in_quote = false;
    for ch in s.chars() {
        match ch {
            '"' => in_quote = !in_quote,
            c if c.is_whitespace() && !in_quote => {
                if !buf.is_empty() {
                    out.push(std::mem::take(&mut buf));
                }
            }
            c => buf.push(c),
        }
    }
    if !buf.is_empty() {
        out.push(buf);
    }
    out
}

/// Direction of the listing. `Received` keeps inbox-role folders
/// only (the default for "what came in?"), `Sent` keeps sent-role,
/// `Any` keeps everything. Resolved against the per-account
/// `folder.role` column so it works regardless of provider naming.
#[derive(Clone, Copy, Debug)]
pub enum Direction {
    Received,
    Sent,
    Any,
}

impl Direction {
    pub fn parse(s: Option<&str>) -> Self {
        match s.map(str::to_ascii_lowercase).as_deref() {
            Some("sent") => Direction::Sent,
            Some("any") | Some("all") | Some("both") => Direction::Any,
            _ => Direction::Received,
        }
    }
    fn role_filter_sql(self) -> Option<&'static str> {
        match self {
            Direction::Received => Some(
                " AND EXISTS (SELECT 1 FROM folder f \
                  WHERE f.account_id = m.account_id \
                    AND f.name = m.folder AND f.role = 'inbox')",
            ),
            Direction::Sent => Some(
                " AND EXISTS (SELECT 1 FROM folder f \
                  WHERE f.account_id = m.account_id \
                    AND f.name = m.folder AND f.role = 'sent')",
            ),
            Direction::Any => None,
        }
    }
}

/// Time-window listing — bypasses FTS entirely. Returns the most
/// recent thread heads in the last `hours_back` hours across (a)
/// every account if `account_id` is None, or (b) the named account.
/// "Thread heads" = the latest message per thread (in the chosen
/// direction's folder set), so the user doesn't see five rows for
/// a single back-and-forth.
pub fn list_recent(
    conn: &Connection,
    account_id: Option<&str>,
    hours_back: i64,
    limit: i64,
    direction: Direction,
) -> Result<Vec<MessageHeader>, rusqlite::Error> {
    let cutoff_unix =
        chrono::Utc::now().timestamp() - hours_back.clamp(1, 30 * 24) * 3600;
    let limit = limit.clamp(1, 200);

    // Group by thread so a chatty conversation doesn't dominate the
    // result. We pick the row with the latest date_received per
    // thread via a correlated subquery — fine at workspace scale,
    // mail.db tops out at ~mid-five-figure rows for typical users.
    // The role filter on m (the OUTER row) is sufficient — a thread
    // can technically have copies in inbox AND sent (e.g. self-CC),
    // and we want one chip per (thread, direction).
    let mut sql = String::from(
        "SELECT m.account_id, m.folder, m.uid, m.message_id, m.thread_id, \
                m.from_addr, m.from_name, m.subject, m.snippet, m.date_received, \
                m.has_attachments, m.flags_json, fr.role \
         FROM message m \
         LEFT JOIN folder fr ON fr.account_id = m.account_id AND fr.name = m.folder \
         WHERE m.date_received >= ? \
           AND m.date_received = ( \
                SELECT MAX(m2.date_received) FROM message m2 \
                WHERE m2.account_id = m.account_id \
                  AND m2.thread_id = m.thread_id \
           )",
    );
    let mut params: Vec<Value> = vec![Value::Integer(cutoff_unix)];
    if let Some(acc) = account_id {
        sql.push_str(" AND m.account_id = ?");
        params.push(Value::Text(acc.to_string()));
    }
    if let Some(role_clause) = direction.role_filter_sql() {
        sql.push_str(role_clause);
    }
    sql.push_str(" ORDER BY m.date_received DESC LIMIT ?");
    params.push(Value::Integer(limit));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params.iter()), |row| {
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
            direction: row.get::<_, Option<String>>(12)?,
        })
    })?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

pub fn search(
    conn: &Connection,
    account_id: Option<&str>,
    raw_query: &str,
    limit: i64,
    offset: i64,
    direction: Direction,
) -> Result<Vec<MessageHeader>, rusqlite::Error> {
    let q = parse(raw_query);

    // Compose FTS5 MATCH expression. Subject-targeted terms become
    // `subject:term`; free terms are bare. Empty MATCH means "no FTS
    // constraint" — the SQL skips the FTS join entirely.
    let mut match_terms: Vec<String> = Vec::new();
    for term in &q.subject_terms {
        match_terms.push(format!("subject:{}", fts_quote(term)));
    }
    for term in &q.free_terms {
        match_terms.push(fts_quote(term));
    }
    let match_expr: Option<String> = if match_terms.is_empty() {
        None
    } else {
        Some(match_terms.join(" "))
    };

    let mut sql = String::from(
        "SELECT m.account_id, m.folder, m.uid, m.message_id, m.thread_id, \
                m.from_addr, m.from_name, m.subject, m.snippet, m.date_received, \
                m.has_attachments, m.flags_json, fr.role \
         FROM message m \
         LEFT JOIN folder fr ON fr.account_id = m.account_id AND fr.name = m.folder ",
    );
    let mut params: Vec<Value> = Vec::new();
    let mut where_clauses: Vec<String> = Vec::new();

    if let Some(expr) = &match_expr {
        sql.push_str(" JOIN search_index s ON m.rowid = s.rowid ");
        where_clauses.push("search_index MATCH ?".into());
        params.push(Value::Text(expr.clone()));
    }
    if let Some(account) = account_id {
        where_clauses.push("m.account_id = ?".into());
        params.push(Value::Text(account.to_string()));
    }
    if let Some(from) = &q.from {
        // Substring match — FTS5 can't be relied on for "find any
        // address containing the substring" because email addresses
        // include `@` and `.` which the porter tokenizer chops up.
        where_clauses.push("(LOWER(m.from_addr) LIKE ? OR LOWER(m.from_name) LIKE ?)".into());
        let pat = format!("%{}%", from.to_lowercase());
        params.push(Value::Text(pat.clone()));
        params.push(Value::Text(pat));
    }
    if let Some(to) = &q.to {
        where_clauses.push("LOWER(m.to_json) LIKE ?".into());
        params.push(Value::Text(format!("%{}%", to.to_lowercase())));
    }
    if let Some(folder) = &q.in_folder {
        // Match either the literal folder name or its SPECIAL-USE
        // role tag — `in:inbox` works regardless of what the server
        // calls the folder in this account.
        where_clauses.push(
            "(m.folder = ? OR EXISTS (SELECT 1 FROM folder f \
             WHERE f.account_id = m.account_id AND f.name = m.folder AND f.role = ?))"
                .into(),
        );
        params.push(Value::Text(folder.clone()));
        params.push(Value::Text(folder.clone()));
    }
    if q.has_attachment {
        where_clauses.push("m.has_attachments = 1".into());
    }
    if q.is_unread {
        // The flags_json substring approach mirrors the message_list
        // command — keeps the heuristic in one place.
        where_clauses.push("m.flags_json NOT LIKE '%Seen%'".into());
    }
    if q.is_flagged {
        where_clauses.push("m.flags_json LIKE '%Flagged%'".into());
    }

    if !where_clauses.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&where_clauses.join(" AND "));
    }
    // Direction filter applies AFTER the existing WHERE clauses.
    // Wrap the role lookup in a leading-AND prefix so it stitches
    // onto either branch (with or without prior clauses).
    if let Some(role_clause) = direction.role_filter_sql() {
        if where_clauses.is_empty() {
            sql.push_str(" WHERE 1=1");
        }
        sql.push_str(role_clause);
    }
    if match_expr.is_some() {
        // FTS5 rank ascending = most relevant first; sort on date
        // within the same relevance bucket so brand-new mail still
        // wins ties.
        sql.push_str(" ORDER BY rank ASC, m.date_received DESC ");
    } else {
        sql.push_str(" ORDER BY m.date_received DESC ");
    }
    sql.push_str(" LIMIT ? OFFSET ?");
    params.push(Value::Integer(limit));
    params.push(Value::Integer(offset));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params.iter()), |row| {
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
            direction: row.get::<_, Option<String>>(12)?,
        })
    })?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// All messages in one thread, ordered chronologically. Returns the
/// folder.role per row so the agent can spot the sent/received chain
/// (answer "did X reply to my email"). Includes `body_text_extracted`
/// truncated to a sane size — full body lookup hits .eml on disk and
/// isn't worth the latency for the agent's typical use case (skim a
/// thread to check if there's a reply).
pub struct ThreadMessage {
    pub account_id: String,
    pub folder: String,
    pub uid: u32,
    pub message_id: Option<String>,
    pub from_addr: Option<String>,
    pub from_name: Option<String>,
    pub subject: Option<String>,
    pub date_received: i64,
    pub direction: Option<String>,
    pub snippet: Option<String>,
    pub body_text: Option<String>,
}

pub fn thread_messages(
    conn: &Connection,
    thread_id: &str,
    account_id: Option<&str>,
    body_chars: usize,
) -> Result<Vec<ThreadMessage>, rusqlite::Error> {
    let mut sql = String::from(
        "SELECT m.account_id, m.folder, m.uid, m.message_id, \
                m.from_addr, m.from_name, m.subject, m.date_received, \
                fr.role, m.snippet, m.body_text_extracted \
         FROM message m \
         LEFT JOIN folder fr ON fr.account_id = m.account_id AND fr.name = m.folder \
         WHERE m.thread_id = ?",
    );
    let mut params: Vec<Value> = vec![Value::Text(thread_id.to_string())];
    if let Some(acc) = account_id {
        sql.push_str(" AND m.account_id = ?");
        params.push(Value::Text(acc.to_string()));
    }
    sql.push_str(" ORDER BY m.date_received ASC LIMIT 50");
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params.iter()), |row| {
        let body_full: Option<String> = row.get(10)?;
        let body_text = body_full.map(|b| {
            if b.chars().count() <= body_chars {
                b
            } else {
                let truncated: String = b.chars().take(body_chars).collect();
                format!("{truncated}…[truncated]")
            }
        });
        Ok(ThreadMessage {
            account_id: row.get(0)?,
            folder: row.get(1)?,
            uid: row.get::<_, i64>(2)? as u32,
            message_id: row.get(3)?,
            from_addr: row.get(4)?,
            from_name: row.get(5)?,
            subject: row.get(6)?,
            date_received: row.get(7)?,
            direction: row.get::<_, Option<String>>(8)?,
            snippet: row.get(9)?,
            body_text,
        })
    })?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r?);
    }
    Ok(out)
}

/// FTS5 needs operators escaped — quote the term so it can never be
/// parsed as `AND`/`OR`/`NOT`/parens. Double quotes inside become
/// pairs of double quotes per FTS5 lexical rules.
fn fts_quote(term: &str) -> String {
    if term.is_empty() {
        return "\"\"".into();
    }
    let escaped = term.replace('"', "\"\"");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_compound_query() {
        let q = parse("from:foo@bar subject:\"weekly review\" has:attachment is:unread tps reports");
        assert_eq!(q.from.as_deref(), Some("foo@bar"));
        assert_eq!(q.subject_terms, vec!["weekly review".to_string()]);
        assert!(q.has_attachment);
        assert!(q.is_unread);
        assert_eq!(q.free_terms, vec!["tps".to_string(), "reports".to_string()]);
    }

    #[test]
    fn pure_free_text() {
        let q = parse("invoice quarterly");
        assert!(q.from.is_none());
        assert_eq!(q.free_terms, vec!["invoice".to_string(), "quarterly".to_string()]);
    }

    #[test]
    fn fts_quote_escapes_inner_quotes() {
        assert_eq!(fts_quote(r#"a"b"#), r#""a""b""#);
    }
}
