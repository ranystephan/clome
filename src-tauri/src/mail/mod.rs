//! Native mail client. Replaces the legacy Mail.app reader (still
//! reachable as `mail::legacy::*` through Phase 6) with a self-contained
//! IMAP+SMTP client authenticated via OAuth (XOAUTH2 SASL).
//!
//! Design contract — see `clome/blueprint/mail-client/plan-mail-client.md`:
//!   * `mail.db`     — SQLite + FTS5 index, owned by `mail::db`.
//!   * `.eml` files  — immutable on-disk truth, owned by `mail::store`.
//!   * Tokens        — macOS Keychain, owned by `mail::keychain`. The
//!                     SurrealDB `email_account` row stores only an
//!                     opaque `keychain_ref` string.
//!
//! Phase 1 lands the substrate (db / store / keychain / oauth /
//! autoconfig + onboarding commands) without UI. Read path arrives in
//! Phase 2; write path Phase 4.

pub mod autoconfig;
pub mod commands;
pub mod db;
pub mod idle;
pub mod imap;
pub mod keychain;
pub mod legacy;
pub mod oauth;
pub mod outbox;
pub mod parse;
pub mod sanitize;
pub mod search;
pub mod smtp;
pub mod store;
pub mod sync;
pub mod threading;
pub mod types;

// ── Legacy compatibility shim ───────────────────────────────────────
// The existing `MailView.tsx` in the frontend calls `mail_list_*` /
// `mail_get_body`, which `lib.rs` resolves via `mail::Mailbox` etc.
// Keeping these re-exports means we don't churn lib.rs while the new
// substrate lands. Phase 7 deletes both the re-exports and `legacy.rs`.
pub use legacy::{
    get_body as legacy_get_body, list_mailboxes as legacy_list_mailboxes,
    list_messages as legacy_list_messages, MailBody, MailMessage, Mailbox,
};
