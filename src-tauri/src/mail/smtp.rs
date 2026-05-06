//! SMTP send over `lettre` + native-tls. XOAUTH2 SASL using the
//! OAuth access token from `mail::keychain`.
//!
//! Phase 4 ships a single one-shot send call. The persistent outbox
//! (with undo-send window + scheduled delay + retry) lives on top of
//! this — it's a state machine that just calls `send()` when its timer
//! fires.
//!
//! Body shape: callers pass markdown source; we render to HTML via
//! pulldown-cmark and emit `multipart/alternative` carrying both. This
//! is what most modern recipients expect (HTML for visual clients,
//! plain for terminal / accessibility / spam-filter heuristics).

use lettre::message::header::ContentType;
use lettre::message::{Mailbox, Mailboxes, MultiPart, SinglePart};
use lettre::transport::smtp::authentication::{Credentials, Mechanism};
use lettre::transport::smtp::client::{Tls, TlsParameters};
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};
use pulldown_cmark::{Options, Parser};

use crate::mail::oauth;
use crate::mail::types::Account;

#[derive(Debug, Clone)]
pub struct OutgoingMessage {
    pub from_addr: String,
    pub from_name: Option<String>,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_md: String,
    /// Used when this message is a reply: surfaces as `In-Reply-To`
    /// + `References` so the receiving client threads it correctly.
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SendOutcome {
    pub message_id: String,
}

pub async fn send(
    account: &Account,
    keychain_ref: &str,
    msg: OutgoingMessage,
) -> Result<SendOutcome, String> {
    // Refresh the access token if needed; persists the new bundle to
    // Keychain so the next sync / send doesn't have to refresh again.
    let access_token = oauth::ensure_fresh_access(&account.email, keychain_ref).await?;

    let from = parse_mailbox(&msg.from_addr, msg.from_name.as_deref())?;
    let to_box = parse_mailbox_list(&msg.to)?;
    let cc_box = parse_mailbox_list(&msg.cc)?;
    let bcc_box = parse_mailbox_list(&msg.bcc)?;

    let html = render_markdown(&msg.body_md);
    let plain = msg.body_md.clone();

    let mut builder = Message::builder()
        .from(from.clone())
        .subject(&msg.subject);
    if let Some(boxes) = to_box {
        builder = builder.mailbox(lettre::message::header::To::from(boxes));
    }
    if let Some(boxes) = cc_box {
        builder = builder.mailbox(lettre::message::header::Cc::from(boxes));
    }
    if let Some(boxes) = bcc_box {
        builder = builder.mailbox(lettre::message::header::Bcc::from(boxes));
    }
    if let Some(parent) = &msg.in_reply_to {
        builder = builder.in_reply_to(format!("<{parent}>"));
    }
    if !msg.references.is_empty() {
        let joined: String = msg
            .references
            .iter()
            .map(|r| format!("<{r}>"))
            .collect::<Vec<_>>()
            .join(" ");
        builder = builder.references(joined);
    }

    let body_part = MultiPart::alternative()
        .singlepart(
            SinglePart::builder()
                .header(ContentType::TEXT_PLAIN)
                .body(plain),
        )
        .singlepart(
            SinglePart::builder()
                .header(ContentType::TEXT_HTML)
                .body(html),
        );

    let email = builder
        .multipart(body_part)
        .map_err(|e| format!("smtp build: {e}"))?;
    let message_id = email
        .headers()
        .get_raw("Message-ID")
        .map(|s| s.to_string())
        .unwrap_or_default()
        .trim_matches(|c| c == '<' || c == '>')
        .to_string();

    let creds = Credentials::new(account.email.clone(), access_token);
    let transport = build_transport(account, creds)?;

    transport
        .send(email)
        .await
        .map_err(|e| format!("smtp send: {e}"))?;

    Ok(SendOutcome { message_id })
}

fn build_transport(
    account: &Account,
    creds: Credentials,
) -> Result<AsyncSmtpTransport<Tokio1Executor>, String> {
    // Implicit TLS (port 465) vs STARTTLS (587). The autoconfig layer
    // already resolved this; `smtp_security` was persisted at account
    // creation.
    //
    // We can't read smtp_security straight off `Account` (the
    // structure was minimised). Conventional ports decide: 465 = TLS
    // wrapper, 587 = STARTTLS, anything else falls back to STARTTLS
    // because cleartext SMTP is not a thing we support.
    let tls = TlsParameters::new(account.smtp_host.clone())
        .map_err(|e| format!("smtp tls params: {e}"))?;
    let builder = if account.smtp_port == 465 {
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&account.smtp_host)
            .port(account.smtp_port)
            .tls(Tls::Wrapper(tls))
    } else {
        AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&account.smtp_host)
            .map_err(|e| format!("smtp starttls relay: {e}"))?
            .port(account.smtp_port)
            .tls(Tls::Required(tls))
    };
    Ok(builder
        .credentials(creds)
        .authentication(vec![Mechanism::Xoauth2])
        .build())
}

fn parse_mailbox(addr: &str, name: Option<&str>) -> Result<Mailbox, String> {
    let parsed: Mailbox = match name {
        Some(n) if !n.trim().is_empty() => format!("{n} <{addr}>")
            .parse()
            .map_err(|e| format!("parse from {addr}: {e}"))?,
        _ => addr
            .parse()
            .map_err(|e| format!("parse from {addr}: {e}"))?,
    };
    Ok(parsed)
}

fn parse_mailbox_list(addrs: &[String]) -> Result<Option<Mailboxes>, String> {
    if addrs.is_empty() {
        return Ok(None);
    }
    let mut boxes = Mailboxes::new();
    for a in addrs {
        let mb: Mailbox = a
            .parse()
            .map_err(|e| format!("parse address {a}: {e}"))?;
        boxes.push(mb);
    }
    Ok(Some(boxes))
}

fn render_markdown(src: &str) -> String {
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    opts.insert(Options::ENABLE_TABLES);
    opts.insert(Options::ENABLE_TASKLISTS);
    let parser = Parser::new_ext(src, opts);
    let mut out = String::with_capacity(src.len() + 64);
    pulldown_cmark::html::push_html(&mut out, parser);
    // Wrap in a minimal HTML shell so recipients without a stripped-
    // body renderer (rare but exists) still get a sane document.
    format!(
        "<!doctype html><html><body style=\"font-family:-apple-system,sans-serif;font-size:14px\">{out}</body></html>"
    )
}
