//! IMAP client over the sync `imap` crate (2.x line) + `native-tls`,
//! wrapped in `tokio::task::spawn_blocking`. Phase 2 covers connect
//! (implicit TLS, port 993), XOAUTH2 SASL, LIST, SELECT, and UID
//! FETCH for headers + bodies. STARTTLS, IDLE, CONDSTORE/QRESYNC,
//! MOVE, and APPEND arrive in Phase 3 / 4.
//!
//! Why sync + native-tls: `imap` 2.x is stable and well-tested; the
//! alpha 3.x line has been moving for years and the rustls path
//! drifted enough between alphas to be a maintenance hazard.
//! native-tls on macOS goes through Security.framework, which we
//! already depend on for the Keychain — so no new system surface.

use std::net::TcpStream;

use imap::types::{Capabilities, Mailbox as ServerMailbox, Name, NameAttribute};
use imap::{Authenticator, Session};
use native_tls::TlsConnector;

use crate::mail::types::{ServerConfig, TlsMode};

/// Authenticated IMAP session over implicit-TLS via native-tls.
pub type ImapSession = Session<native_tls::TlsStream<TcpStream>>;

#[derive(Debug, Clone, Default)]
pub struct ServerCaps {
    pub idle: bool,
    pub condstore: bool,
    pub qresync: bool,
    pub move_ext: bool,
    pub uidplus: bool,
    pub special_use: bool,
    pub compress_deflate: bool,
}

impl ServerCaps {
    fn from_caps(caps: &Capabilities) -> Self {
        let mut out = ServerCaps::default();
        for c in caps.iter() {
            // imap_proto::Capability impls Display via its own
            // Debug-ish formatting; the canonical form ("Atom("IDLE")")
            // is awkward, so we stringify and pattern-match on a
            // normalised view.
            let raw = format!("{c:?}");
            // Atom("IDLE") -> "IDLE"; AuthMethod("XOAUTH2") -> AUTH=XOAUTH2 ?
            // We mostly care about the boolean atoms, which appear as
            // Atom("…"). Strip the wrapper and compare upper-case.
            let inside = raw
                .strip_prefix("Atom(")
                .and_then(|s| s.strip_suffix(')'))
                .map(|s| s.trim_matches('"'))
                .unwrap_or(raw.as_str());
            let upper = inside.to_ascii_uppercase();
            match upper.as_str() {
                "IDLE" => out.idle = true,
                "CONDSTORE" => out.condstore = true,
                "QRESYNC" => out.qresync = true,
                "MOVE" => out.move_ext = true,
                "UIDPLUS" => out.uidplus = true,
                "SPECIAL-USE" => out.special_use = true,
                s if s == "COMPRESS=DEFLATE" => out.compress_deflate = true,
                _ => {}
            }
        }
        out
    }
}

#[derive(Debug, Clone)]
pub struct FolderInfo {
    pub name: String,
    pub role: Option<String>,
    pub delimiter: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SelectInfo {
    pub uidvalidity: u32,
    pub uidnext: Option<u32>,
    pub exists: u32,
    pub recent: u32,
    pub highestmodseq: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct FetchedMessage {
    pub uid: u32,
    pub flags: Vec<String>,
    pub internal_date: Option<i64>,
    pub raw: Vec<u8>,
}

pub async fn connect_xoauth2(
    server: ServerConfig,
    email: String,
    oauth_access_token: String,
) -> Result<(ImapSession, ServerCaps), String> {
    if !matches!(server.security, TlsMode::Tls) {
        return Err(format!(
            "STARTTLS not yet supported (server: {}); pin to port 993 / 465 for Phase 2",
            server.host
        ));
    }
    tokio::task::spawn_blocking(move || -> Result<(ImapSession, ServerCaps), String> {
        let tls = TlsConnector::builder()
            .build()
            .map_err(|e| format!("imap tls init: {e}"))?;
        let client = imap::connect((server.host.as_str(), server.port), &server.host, &tls)
            .map_err(|e| format!("imap connect {}:{}: {e}", server.host, server.port))?;
        let auth = XOAuth2Auth {
            user: email,
            token: oauth_access_token,
        };
        let mut session = client.authenticate("XOAUTH2", &auth).map_err(|(e, _)| {
            format!("imap XOAUTH2 auth: {e}")
        })?;
        let caps_handle = session
            .capabilities()
            .map_err(|e| format!("imap CAPABILITY: {e}"))?;
        let caps = ServerCaps::from_caps(&caps_handle);
        drop(caps_handle);
        Ok((session, caps))
    })
    .await
    .map_err(|e| format!("imap connect spawn: {e}"))?
}

struct XOAuth2Auth {
    user: String,
    token: String,
}

impl Authenticator for XOAuth2Auth {
    type Response = String;
    fn process(&self, _challenge: &[u8]) -> Self::Response {
        // RFC-flavoured XOAUTH2 SASL payload. We return the *raw*
        // string — the `imap` crate base64-encodes it before putting
        // it on the wire. Encoding it ourselves would double-encode
        // and Gmail responds with "Invalid SASL argument".
        format!("user={}\x01auth=Bearer {}\x01\x01", self.user, self.token)
    }
}

pub async fn list_folders(
    mut session: ImapSession,
) -> Result<(ImapSession, Vec<FolderInfo>), String> {
    tokio::task::spawn_blocking(move || -> Result<(ImapSession, Vec<FolderInfo>), String> {
        let names = session
            .list(Some(""), Some("*"))
            .map_err(|e| format!("imap LIST: {e}"))?;
        let mut out = Vec::with_capacity(names.len());
        for name in names.iter() {
            // Skip \Noselect parents (Gmail's `[Gmail]`, IMAP
            // hierarchy roots in general). They aren't selectable
            // mailboxes — trying to SELECT one yields
            // `[NONEXISTENT] Unknown Mailbox`. Children remain in
            // the list and carry their own SPECIAL-USE roles.
            if name.attributes().iter().any(|a| matches!(a, NameAttribute::NoSelect)) {
                continue;
            }
            out.push(FolderInfo {
                name: name.name().to_string(),
                role: role_for(name).map(str::to_string),
                delimiter: name.delimiter().map(|c| c.to_string()),
            });
        }
        drop(names);
        Ok((session, out))
    })
    .await
    .map_err(|e| format!("imap list spawn: {e}"))?
}

fn role_for(name: &Name) -> Option<&'static str> {
    for attr in name.attributes() {
        if let NameAttribute::Custom(s) = attr {
            match s.as_ref() {
                "\\Inbox" => return Some("inbox"),
                "\\Sent" => return Some("sent"),
                "\\Drafts" => return Some("drafts"),
                "\\Trash" => return Some("trash"),
                "\\Junk" => return Some("junk"),
                "\\Archive" | "\\All" => return Some("archive"),
                "\\Flagged" | "\\Important" => return Some("flagged"),
                _ => continue,
            }
        }
    }
    let lower = name.name().to_ascii_lowercase();
    if lower.ends_with("inbox") {
        Some("inbox")
    } else if lower.ends_with("sent")
        || lower.ends_with("sent mail")
        || lower.ends_with("sent messages")
        || lower.ends_with("sent items")
    {
        Some("sent")
    } else if lower.ends_with("drafts") {
        Some("drafts")
    } else if lower.ends_with("trash")
        || lower.ends_with("deleted messages")
        || lower.ends_with("deleted items")
    {
        Some("trash")
    } else if lower.ends_with("junk") || lower.ends_with("spam") {
        Some("junk")
    } else if lower.ends_with("archive") || lower.ends_with("all mail") {
        Some("archive")
    } else {
        None
    }
}

pub async fn select(
    mut session: ImapSession,
    folder: String,
    read_only: bool,
) -> Result<(ImapSession, SelectInfo), String> {
    tokio::task::spawn_blocking(move || -> Result<(ImapSession, SelectInfo), String> {
        let mb: ServerMailbox = if read_only {
            session
                .examine(&folder)
                .map_err(|e| format!("imap EXAMINE {folder}: {e}"))?
        } else {
            session
                .select(&folder)
                .map_err(|e| format!("imap SELECT {folder}: {e}"))?
        };
        let info = SelectInfo {
            uidvalidity: mb.uid_validity.unwrap_or(0),
            uidnext: mb.uid_next,
            exists: mb.exists,
            recent: mb.recent,
            highestmodseq: None,
        };
        Ok((session, info))
    })
    .await
    .map_err(|e| format!("imap select spawn: {e}"))?
}

pub async fn uid_fetch_full(
    mut session: ImapSession,
    uid_range: String,
) -> Result<(ImapSession, Vec<FetchedMessage>), String> {
    tokio::task::spawn_blocking(move || -> Result<(ImapSession, Vec<FetchedMessage>), String> {
        let fetched = session
            .uid_fetch(&uid_range, "(UID FLAGS INTERNALDATE BODY.PEEK[])")
            .map_err(|e| format!("imap UID FETCH: {e}"))?;
        let mut out = Vec::with_capacity(fetched.len());
        for f in fetched.iter() {
            let Some(uid) = f.uid else { continue };
            let flags: Vec<String> = f.flags().iter().map(|fl| format!("{fl:?}")).collect();
            let internal_date = f.internal_date().map(|d| d.timestamp());
            let raw = f.body().map(|b| b.to_vec()).unwrap_or_default();
            out.push(FetchedMessage {
                uid,
                flags,
                internal_date,
                raw,
            });
        }
        drop(fetched);
        Ok((session, out))
    })
    .await
    .map_err(|e| format!("imap fetch spawn: {e}"))?
}

/// Fetch FLAGS only for a UID range. Used to keep local read /
/// flagged / answered state aligned with server-side changes that
/// happen outside Clome (Gmail web, mobile apps, other clients).
/// Cheap — one IMAP round-trip with no body bytes — so we run it
/// every sync against the most recent UIDs.
pub async fn uid_fetch_flags(
    mut session: ImapSession,
    uid_range: String,
) -> Result<(ImapSession, Vec<(u32, Vec<String>)>), String> {
    tokio::task::spawn_blocking(
        move || -> Result<(ImapSession, Vec<(u32, Vec<String>)>), String> {
            let fetched = session
                .uid_fetch(&uid_range, "(UID FLAGS)")
                .map_err(|e| format!("imap UID FETCH FLAGS: {e}"))?;
            let mut out = Vec::with_capacity(fetched.len());
            for f in fetched.iter() {
                let Some(uid) = f.uid else { continue };
                let flags: Vec<String> =
                    f.flags().iter().map(|fl| format!("{fl:?}")).collect();
                out.push((uid, flags));
            }
            drop(fetched);
            Ok((session, out))
        },
    )
    .await
    .map_err(|e| format!("imap fetch flags spawn: {e}"))?
}

pub async fn uid_search_all(mut session: ImapSession) -> Result<(ImapSession, Vec<u32>), String> {
    tokio::task::spawn_blocking(move || -> Result<(ImapSession, Vec<u32>), String> {
        let mut uids: Vec<u32> = session
            .uid_search("ALL")
            .map_err(|e| format!("imap UID SEARCH: {e}"))?
            .into_iter()
            .collect();
        uids.sort_unstable();
        Ok((session, uids))
    })
    .await
    .map_err(|e| format!("imap search spawn: {e}"))?
}

pub async fn logout(session: ImapSession) {
    tokio::task::spawn_blocking(move || {
        let mut s = session;
        let _ = s.logout();
    })
    .await
    .ok();
}

/// Enter IDLE on the currently-selected mailbox. Blocks the thread
/// (sync `imap` 2.4 IDLE) up to `keepalive`, then returns the session
/// for the caller to either re-enter IDLE or do regular IMAP work.
///
/// Reasons it returns:
///   * server pushed a new `EXISTS` / `EXPUNGE` notification (data!)
///   * keepalive timer fired (caller can use this for shutdown checks)
///   * connection error (returned as Err)
///
/// We don't expose *which* of those happened; the caller handles all
/// three the same way (close the IDLE, do an incremental fetch, then
/// optionally re-enter).
pub async fn idle_wait(
    session: ImapSession,
    keepalive: std::time::Duration,
) -> Result<ImapSession, String> {
    tokio::task::spawn_blocking(move || -> Result<ImapSession, String> {
        let mut session = session;
        {
            // The Idle handle borrows `session` mutably and sends
            // `DONE` on drop. We use a block scope so the borrow
            // ends right after `wait_keepalive` returns; the session
            // is then usable again (and we hand it back to the caller).
            let mut idle = session
                .idle()
                .map_err(|e| format!("imap IDLE start: {e}"))?;
            idle.set_keepalive(keepalive);
            idle.wait_keepalive()
                .map_err(|e| format!("imap IDLE wait: {e}"))?;
        }
        Ok(session)
    })
    .await
    .map_err(|e| format!("imap IDLE spawn: {e}"))?
}

/// `UID STORE <uid> +FLAGS (...)` or `-FLAGS` / `FLAGS`.
/// `flags` are RFC 3501 system flag tokens like `\Seen`, `\Flagged`,
/// `\Deleted`, `\Answered`. Server-side keywords work too.
#[derive(Debug, Clone, Copy)]
pub enum FlagOp {
    Add,
    Remove,
    Replace,
}

pub async fn uid_store_flags(
    mut session: ImapSession,
    uid: u32,
    flags: Vec<String>,
    op: FlagOp,
) -> Result<ImapSession, String> {
    tokio::task::spawn_blocking(move || -> Result<ImapSession, String> {
        let op_str = match op {
            FlagOp::Add => "+FLAGS",
            FlagOp::Remove => "-FLAGS",
            FlagOp::Replace => "FLAGS",
        };
        let body = format!("({})", flags.join(" "));
        let _ = session
            .uid_store(uid.to_string(), format!("{op_str} {body}"))
            .map_err(|e| format!("imap UID STORE: {e}"))?;
        Ok(session)
    })
    .await
    .map_err(|e| format!("imap store spawn: {e}"))?
}

/// `UID MOVE <uid> <target>` if MOVE is available, else manual
/// `COPY` + `STORE \Deleted` + `EXPUNGE`. `imap` 2.4 maps MOVE through
/// `Session::uid_mv`.
pub async fn uid_move(
    mut session: ImapSession,
    uid: u32,
    target_folder: String,
) -> Result<ImapSession, String> {
    tokio::task::spawn_blocking(move || -> Result<ImapSession, String> {
        if let Err(move_err) = session.uid_mv(uid.to_string(), &target_folder) {
            session
                .uid_copy(uid.to_string(), &target_folder)
                .map_err(|copy_err| {
                    format!("imap UID MOVE: {move_err}; fallback UID COPY: {copy_err}")
                })?;
            session
                .uid_store(uid.to_string(), "+FLAGS (\\Deleted)")
                .map_err(|store_err| {
                    format!("imap UID MOVE: {move_err}; fallback UID STORE deleted: {store_err}")
                })?;
            if let Err(uid_expunge_err) = session.uid_expunge(uid.to_string()) {
                session.expunge().map_err(|expunge_err| {
                    format!(
                        "imap UID MOVE: {move_err}; fallback UID EXPUNGE: {uid_expunge_err}; EXPUNGE: {expunge_err}"
                    )
                })?;
            }
        }
        Ok(session)
    })
    .await
    .map_err(|e| format!("imap move spawn: {e}"))?
}
