# Native Mail Client (Tauri / Rust)

> Source prompt:
>
> I want to build a mail client/app inside of clome where i will be able to have all the features of a mail app like outlook, gmail, or the apple mail app. i should be able to login with oauth to any email i have. since we are building in rust as well, it should be as native, super snappy, super quick, super clear. later on we will make it so the agents in clome can read write and interact with the mails as well. we need to focus on security, performance, speed,...
>
> * Native Rust mail client (Tauri); aim: fast, clear, reliable; "any email" coverage.
> * Login: OAuth via XOAUTH2 over IMAP+SMTP — single transport for Gmail / Outlook / iCloud / Fastmail / custom. Provider APIs (Gmail, Graph) deferred as future optimization.
> * Replace existing `mail.rs` + `MailView.tsx` Mail.app reader fully (no coexistence).
> * Storage: dedicated `mail.db` (SQLite + FTS5) for metadata/index; raw RFC 822 messages and attachments as `.eml` files on disk under `Application Support/com.clome.app/mail/{account}/{folder}/{uid}.eml` (Maildir-inspired).
> * Threading: JWZ algorithm over `Message-ID` / `In-Reply-To` / `References` (Apple Mail / Mutt class).
> * Onboarding: type email → Mozilla ISPDB + DNS SRV (RFC 6186) + Microsoft autodiscover → OAuth → done. Manual override available.
> * Sync: in-process tokio tasks per account. Modern IMAP stack required when offered (CONDSTORE, QRESYNC, IDLE, MOVE, COMPRESS=DEFLATE, LIST-EXTENDED + SPECIAL-USE, UIDPLUS); baseline IMAP fallback when not.
> * Full offline mirror: headers + bodies cached locally; attachments lazy-download by default, cap configurable in Settings.
> * Full-text search: SQLite FTS5 over body + headers + extracted attachment text, porter + trigram tokenizer.
> * Multi-account from day 1: unified inbox + per-account views, account switcher in sidebar.
> * Write scope at v1: send / reply / forward, drafts (synced to IMAP `Drafts` folder, auto-save every 30s), flag / star / archive / delete, move / label, scheduled send, undo send (default 10s, configurable), snooze.
> * Outbox: persistent table in `mail.db`, exponential backoff retry on transient SMTP errors, status surfaced in UI ("Sending in 8s, undo").
> * HTML rendering: iframe `sandbox` (no scripts/forms/popups), block remote images until per-sender allowlist, strip tracking pixels via known-tracker list, link-rewriter shows real URL on hover.
> * Attachments: lazy-download default; in-app preview for image / text / PDF; QuickLook via Swift sidecar later. All thresholds in Settings.
> * Notifications: macOS `UNUserNotificationCenter` via Swift sidecar — banner per new mail, dock badge = total unread, per-account toggle, respect Focus / Do Not Disturb.
> * UI: resizable 3-pane ↔ 2-pane via Cmd+\\. Conversation rendering: Gmail-style stack (older messages collapsed, expand-on-click).
> * Encryption at rest: rely on FileVault. No app-level crypto in v1.
> * Tokens: macOS Keychain via `security-framework`. DB stores `keychain_ref` strings only; raw access / refresh tokens never touch disk in plaintext.
> * First-sync strategy: all folders, headers-only for last 90 days, expand backward in background. Bodies fetched on click + prefetch top-of-list.
> * Composer format: markdown source rendered to HTML on send; `multipart/alternative` carries plaintext alongside HTML.
> * Calendar invites (`.ics`): inline RSVP card on receive — Accept/Decline/Tentative writes via existing EventKit sidecar (`calendar.write` cap), response sent via SMTP.
> * Account migration: read accounts list from macOS Internet Accounts via Swift sidecar to pre-populate "Add account"; fresh OAuth always required (Apple does not share tokens).
> * Identities: single identity per account in v1 (one signature per account); aliases / multiple identities deferred.
> * Agent integration v1: read-only — `email.read` cap re-pointed to new IMAP store, new `search_email` tool action, schema agent-readable from day one. Write actions (`email.write`: send / draft / flag / archive) land in v1.1.

---

## Overview

- Replace the existing read-only Mail.app bridge (`src-tauri/src/mail.rs` + `src/components/MailView.tsx`) with a self-contained, OAuth-authenticated IMAP+SMTP client written entirely in Rust on the Tauri side, with a Solid UI on the frontend.
- One transport for "any email": **XOAUTH2 over IMAP+SMTP**. Modern IMAP extensions (CONDSTORE/QRESYNC/IDLE/MOVE/COMPRESS=DEFLATE/UIDPLUS/SPECIAL-USE) negotiated at login; baseline IMAP4rev1 supported as fallback. Provider-specific APIs (Gmail, Microsoft Graph) deferred until measured to be necessary.
- Storage split for performance and durability: SQLite `mail.db` (with FTS5) is the *index*; immutable RFC 822 `.eml` files on disk are the *truth*. This mirrors what Apple Mail and Notmuch do, scales to multi-GB mailboxes, and keeps backups & debugging simple.
- Tokens never touch the database. macOS Keychain (`security-framework`) holds OAuth access + refresh tokens; SQLite stores only opaque key references. No app-level disk encryption — rely on FileVault.
- Threading uses the **JWZ algorithm** over `Message-ID` / `In-Reply-To` / `References`, with conversations rendered Gmail-style (older messages collapsed, latest expanded).
- Sync runs in-process via tokio: one `IDLE` connection + one fetch connection per account, shared work via a sync supervisor.
- Onboarding aims at zero-friction: user types an email address; Mozilla ISPDB, DNS SRV (RFC 6186) and Microsoft autodiscover discover the servers; OAuth completes; first-sync streams headers in <5s.
- Agent integration is **designed-for, not shipped-with** at v1: schema and tool surfaces are agent-readable from day one, but the only live capability at v1 launch is `email.read` re-pointed at the new store. Write capabilities (`email.write`) ship in v1.1 once the human-facing surfaces are polished.
- Aligns with the project's "no fallbacks, single impl per behavior" rule (CLAUDE.md): one transport (XOAUTH2 + IMAP), one storage layout, one composer.

---

## Expected behavior

### Onboarding & accounts

- "Add account" modal: user types `name@example.com`. App detects existing accounts in macOS Internet Accounts and offers them as quick-pick chips above the manual field.
- App resolves IMAP/SMTP servers + OAuth endpoints via Mozilla ISPDB → DNS SRV → Microsoft autodiscover, in that order. If discovery fails, manual server entry fields appear.
- OAuth flow opens system browser (`tauri-plugin-shell` `open()` on the auth URL), captures redirect to `http://127.0.0.1:<random-port>/callback`, exchanges code for tokens, stores tokens in Keychain, persists account row in SurrealDB (no secrets), kicks off first-sync.
- Multiple accounts supported from v1. Account switcher in left sidebar. Unified inbox view aggregates all accounts' Inbox folders, sorted by date.

### Reading mail

- Sidebar: accounts list, each with detected special folders (Inbox, Sent, Drafts, Trash, Archive, Junk via `SPECIAL-USE`) plus user folders. Unified Inbox at top.
- Message list: virtualized, sortable by date / sender / subject / size / flagged. Conversation collapse toggle (per-thread).
- Reading pane: Gmail-style conversation stack — latest message expanded, older collapsed with one-line summary; click to expand. Reply / Reply-All / Forward / Snooze / Archive / Delete actions on each message.
- HTML body rendered inside an iframe with `sandbox="allow-same-origin"` (no `allow-scripts`, no `allow-forms`, no `allow-popups`). Remote images blocked by default; per-sender "Always load images from this sender" allowlist; tracking pixels stripped pre-render via known-tracker URL list.
- Plain-text fallback shown when HTML absent or sanitization removes everything material.
- Links rewritten so hover shows real target URL (mitigates display-text spoofing); click opens via `tauri-plugin-opener`.
- Attachments: shown as chips. Click → if cached, open via in-app preview (image / text / PDF) or system handler; if not cached, fetch on demand and stream progress.
- Search: Cmd+F focuses search box; FTS5 query supports `from:`, `to:`, `subject:`, `has:attachment`, `in:folder`, `is:unread`, `is:flagged`, plus free text.
- Cmd+\\ toggles 3-pane ↔ 2-pane. Layout state persisted per workspace.

### Composing & sending

- Composer is a markdown editor (CodeMirror 6, sharing the same setup as `NoteEditor`). Live preview pane on right.
- On send: markdown rendered to HTML; outgoing message constructed as `multipart/alternative` with both `text/plain` (markdown source) and `text/html` (rendered) parts. Attachments added as `multipart/mixed`. CID inline images supported.
- Send button enqueues into outbox with default 10s undo window. UI shows "Sending in 8s, undo" banner; click "Undo" cancels before SMTP fires. After window elapses, SMTP send begins.
- "Schedule send" picker writes future `send_at` timestamp. Outbox supervisor wakes at that time.
- Drafts auto-save every 30s to local `mail.db` and synced to IMAP `Drafts` folder via `APPEND`.
- Failed sends: exponential backoff (1s, 5s, 30s, 5m, 30m). After max retries, surfaced as banner + outbox state = `failed`; user can retry or discard.

### Mailbox management

- Flag / star / mark-read / mark-unread / archive / move / label / delete: emit IMAP `STORE` / `MOVE` / `EXPUNGE` immediately; reflect locally optimistically; reconcile on next CONDSTORE pull.
- Snooze: removes message from current view, schedules wake-up time. On wake, message returns to Inbox with banner "Returned from snooze". Stored locally only (no IMAP sync — IMAP has no snooze concept).
- Calendar invites (`text/calendar` parts): rendered inline as RSVP card. Accept / Decline / Tentative buttons call existing EventKit sidecar (`create_event` / `delete_event` via `calendar.write` cap), then SMTP-send the iTIP `REPLY` back to the organizer.

### Sync & freshness

- IMAP `IDLE` keeps Inbox fresh in real time. Other folders polled on switch + every 5 min when app focused.
- CONDSTORE / QRESYNC: incremental sync via `MODSEQ` and `VANISHED` responses. No full-mailbox rescans except after `UIDVALIDITY` change.
- COMPRESS=DEFLATE negotiated when available — reduces bandwidth on slow networks.
- Sync state persists across app restart: per-folder `(uidvalidity, highestmodseq, last_uid)`. Resume from last point on relaunch.
- IDLE pauses gracefully on system sleep; resumes on wake. App-closed = no sync (no daemon in v1).

### Notifications

- New unread Inbox messages → macOS notification banner (sender + subject) via Swift sidecar `clome-notify` calling `UNUserNotificationCenter`.
- Dock badge shows total unread across all accounts' Inboxes.
- Per-account toggle for banners + sound. Default sound = system "Mail" sound. Respect macOS Focus / Do Not Disturb.
- Click notification: focuses app, navigates to the message.

### Vault & agent integration

- Existing `note.source_kind = "email"` repurposed: notes can be created from a thread via "Save thread to vault" action. Note `source_meta` stores `{ account_id, folder, thread_id, message_uids }`.
- Wikilinks `[[Note Title]]` typed inside the composer remain plain text in the outgoing email body (no leakage of vault state to recipients).
- `email.read` capability re-points to the new IMAP store. Backwards-compatible tool action signatures (`list_recent_mail`, `read_thread`) preserved; new `search_email(query, folder?, sender?, since?)` action added.
- `email.write` capability declared but **not bound to any agent at v1 ship**. Tool docs included so agents can discover the surface; execution is gated and returns `{denied: true, reason: "email.write capability not granted"}`. Lights up in v1.1.
- Vault auto-link: when a thread is saved, JWZ thread ID becomes a stable handle so future messages in the same thread back-link to the existing note automatically.

---

## Implementation plan

### Rust dependencies (`src-tauri/Cargo.toml`)

Additions (with brief justification):

| Crate | Purpose |
|-------|---------|
| `async-imap` | Async IMAP4rev1 client w/ IDLE; tokio-native. |
| `async-native-tls` | TLS for IMAP / SMTP (matches `async-imap`). |
| `lettre` | SMTP client + MIME builder. Async via `tokio1` feature. |
| `mail-parser` | Modern, fast, zero-copy MIME parser (replaces `mailparse` for new code; keep `mailparse` only until legacy reader is removed). |
| `mail-builder` | RFC 822 / MIME message construction for send + draft `APPEND`. |
| `oauth2` | OAuth 2.0 client (auth code + refresh). |
| `security-framework` | macOS Keychain bindings. |
| `webbrowser` | Open OAuth auth URL in default browser (alt: existing `tauri-plugin-opener`). |
| `ammonia` | HTML sanitizer (whitelist tags/attrs, strip script/style). |
| `pulldown-cmark` | Markdown → HTML renderer for composer. |
| `idna` | Punycode for IDN domains in addresses. |
| `quoted_printable`, `base64`, `encoding_rs` | MIME content transfer / charset. |
| `uuid` | Stable IDs for outbox + drafts. |
| `tokio-rusqlite` (or keep sync `rusqlite` w/ `spawn_blocking`) | Async SQLite for `mail.db`. |
| `notify-rust` *(optional)* | Cross-platform fallback if Swift sidecar unavailable. |

Removed once parity reached:
- `mailparse` (replaced by `mail-parser`)
- `walkdir` (no `.emlx` traversal anymore)

### Rust module layout (new)

All under `src-tauri/src/mail/`:

| File | Role |
|------|------|
| `mod.rs` | Module root; re-exports public types + Tauri commands. |
| `db.rs` | Open / migrate `mail.db`. Schema, indices, FTS5 setup. CRUD for accounts, folders, messages, threads, attachments, drafts, outbox, snoozes, allowlists. |
| `store.rs` | Filesystem store for `.eml` files + attachment blobs. Path resolution, atomic write (write-to-tmp-then-rename), checksum verify on read, GC pass for orphans. |
| `keychain.rs` | macOS Keychain wrapper. `store_token(account_id, token) → keychain_ref`, `load_token(keychain_ref) → token`, `delete_token(keychain_ref)`. Uses `kSecClassGenericPassword` with `kSecAttrService = "com.clome.app.mail"`. |
| `oauth.rs` | OAuth 2.0 flows. Per-provider config (auth URL, token URL, scopes). Authorization code flow via local loopback redirect (`http://127.0.0.1:<port>/callback`). PKCE on. Refresh handling. |
| `autoconfig.rs` | Mozilla ISPDB lookup (`https://autoconfig.thunderbird.net/v1.1/<domain>`), DNS SRV (`_imaps._tcp`, `_submission._tcp`), Microsoft autodiscover (`https://autodiscover-s.outlook.com/autodiscover/autodiscover.xml`). Returns server config or error. |
| `imap.rs` | IMAP client wrapper around `async-imap`. Connection pool (1 IDLE + 1 fetch per account). Capability negotiation. SELECT/EXAMINE, FETCH, STORE, MOVE, EXPUNGE, APPEND, IDLE, SEARCH, UID SEARCH, CONDSTORE/QRESYNC. |
| `smtp.rs` | SMTP send via `lettre`. XOAUTH2 SASL. STARTTLS / implicit TLS. |
| `sync.rs` | Per-account `SyncSupervisor` (tokio task). Coordinates IDLE + fetch connections. Selective sync per folder (priority: Inbox > Sent/Drafts > others). Resume from `(uidvalidity, highestmodseq)`. Backoff on connection drop. |
| `parse.rs` | RFC 822 / MIME parsing via `mail-parser`. Extracts headers, body parts, attachments, inline images, calendar parts. Charset normalization to UTF-8. |
| `threading.rs` | JWZ algorithm. Builds `(thread_id, parent_message_id)` from `Message-ID` / `In-Reply-To` / `References`. Stable thread IDs via root-message-id hash. |
| `search.rs` | FTS5 query layer. Translates user query (`from:`, `subject:`, `is:unread`, etc.) to FTS5 MATCH expressions + WHERE clauses. Returns ranked results. |
| `sanitize.rs` | HTML sanitization via `ammonia`. Tag/attribute whitelist. `cid:` rewrite to local file URLs. Remote `<img>`/`<link>`/`<style url(...)>` blocked-and-tagged for the iframe to enforce. Tracking pixel stripper (URL pattern list, e.g. `*google-analytics*`, `*track.*`, `*pixel.*`). Link rewriter inserts `data-href` for hover preview. |
| `outbox.rs` | Persistent send queue. `enqueue(message, send_at, undo_window)`. Background task wakes at earliest `send_at`, transitions `queued → sending → sent | failed`. Exponential backoff on transient errors. |
| `snooze.rs` | Snooze table + wake-up scheduler. Wake-up task runs every minute, restores due messages to Inbox view. |
| `notify.rs` | Notification bridge to Swift sidecar `clome-notify` (new `externalBin`). Sends `{title, body, account_id, message_uid}`. Sidecar calls `UNUserNotificationCenter`. |
| `internet_accounts.rs` | Swift sidecar bridge. Reads macOS Internet Accounts via `Accounts.framework` (private but stable for read), returns `[{provider, email, type}]` for onboarding pre-population. |
| `calendar_invite.rs` | iTIP / iCalendar `.ics` parser. Detects METHOD (REQUEST/REPLY/CANCEL). Builds RSVP iTIP REPLY. Calls existing EventKit sidecar (already wired in `caps.rs`) for write-through. |
| `commands.rs` | Tauri command handlers. Thin wrappers around the modules above. |

### Modifications to existing files

#### `src-tauri/src/lib.rs`
- Register all `mail::commands::*` in `invoke_handler!`.
- Spawn one `SyncSupervisor` per account on app `setup()` after the DB opens.
- On window-close: pause IDLE; on window-focus: resume.
- Bridge `mail:new_message`, `mail:sync_status`, `mail:outbox_update` events to frontend.

#### `src-tauri/src/caps.rs`
- Update `email.read` `tool_docs` to describe new actions: `list_recent_mail` (multi-account aware), `read_thread`, `search_email`.
- Add new capability `email.write` with `tool_docs` for `send_email`, `create_draft`, `mark_read`, `mark_unread`, `flag_message`, `archive_message`, `delete_message`, `move_message`. Capability declared but unbound at v1.
- Update `cap_for_action()` map for all new tool actions.

#### `src-tauri/src/tools.rs`
- Add executors for new email actions, dispatching to `mail::commands::*` (read path) and stub-returning-denied for write actions until v1.1.

#### `src-tauri/src/db.rs` (SurrealDB)
- New table `email_account` — non-secret account metadata only:
  - `id`, `email`, `display_name`, `provider` (gmail|outlook|icloud|fastmail|imap), `imap_host`, `imap_port`, `smtp_host`, `smtp_port`, `keychain_ref`, `signature` (markdown), `notify_enabled`, `attachment_auto_dl_max_mb`, `created_at`, `last_sync_at`.
- New mapping table `mail_note_link` — `{ thread_id, account_id, note_id, created_at }` for vault auto-link.
- Migration: drop `mail` references; idempotent re-apply.

### `mail.db` schema (SQLite)

Path: `~/Library/Application Support/com.clome.app/mail/mail.db`.

Tables:

```
account_state(account_id, last_sync_at, status)
folder(account_id, name, role, uidvalidity, highestmodseq, unread_count, total_count, PRIMARY KEY (account_id, name))
message(account_id, folder, uid, message_id, thread_id, in_reply_to, refs_json,
        from_addr, from_name, to_json, cc_json, bcc_json,
        subject, snippet, date_received, date_sent,
        flags_json, size, has_attachments,
        eml_path, eml_sha256,
        body_text_extracted, body_html_extracted,
        PRIMARY KEY (account_id, folder, uid))
attachment(account_id, message_uid_ref, content_id, filename, mime, size, blob_path, downloaded, PRIMARY KEY (account_id, message_uid_ref, content_id))
thread(thread_id, root_message_id, last_date, message_count, unread_count, has_flagged, PRIMARY KEY (thread_id))
draft(id, account_id, in_reply_to_thread, subject, to_json, cc_json, bcc_json, body_md, attachments_json, last_saved_at, imap_uid_after_append)
outbox(id, account_id, draft_id_ref, send_at, undo_until, state, attempt_count, last_error, message_id, eml_path)
snooze(message_uid_ref, account_id, folder, wake_at, original_folder)
remote_image_allow(account_id, sender_email, allowed_at)
search_index — FTS5 virtual table over (subject, from_addr, body_text_extracted, attachment_text)
```

FTS5 config: external content table linked to `message`, porter tokenizer + `unicode61` + `trigram` for partial match. Triggers keep FTS in sync on insert/update/delete.

Indices: `(account_id, folder, date_received DESC)`, `(thread_id, date_received DESC)`, `(account_id, flags_json)` (filtered for unread), `(message_id)` for threading lookups.

### Frontend (`src/`)

#### New components (`src/components/Mail/`)

| File | Role |
|------|------|
| `MailApp.tsx` | Mail surface root. Wires sidebar / list / reading / composer panes. Owns layout state (3-pane vs 2-pane) and selected (account, folder, thread, message). |
| `MailSidebar.tsx` | Unified Inbox at top. Account list with collapsible folders. Unread count badges. Drag-to-reorder accounts. |
| `MessageList.tsx` | Virtualized list. Sort & filter controls. Multi-select for bulk actions. |
| `ThreadReader.tsx` | Gmail-style conversation stack. Manages collapsed/expanded message states. |
| `MessageView.tsx` | Single message render: headers, body (via `HtmlSandbox`), attachments, action toolbar. |
| `HtmlSandbox.tsx` | Sandboxed iframe wrapper. Receives sanitized HTML + remote-image policy. Handles "Load remote images" prompt. |
| `Composer.tsx` | Markdown editor (CodeMirror) + live preview. To/Cc/Bcc/Subject fields with autocomplete from address book (extracted from sent/received). Attachment chip area. Send / Schedule / Discard buttons. |
| `AccountAddModal.tsx` | Onboarding flow: email entry → autoconfig progress → OAuth browser hand-off → success → first-sync indicator. Internet-Accounts pre-fill chips. |
| `MailSettings.tsx` | Per-account: signature, notify on/off, attachment auto-DL cap, undo-send window. Per-app: layout default, theme. |
| `RsvpCard.tsx` | Inline calendar invite renderer. Accept / Decline / Tentative buttons. |
| `OutboxBanner.tsx` | "Sending in Ns, undo" + scheduled-send pills + failed-send banner. |

#### Modifications

- `src/App.tsx`: register Mail surface as a top-level route alongside existing Chat / Notes / Terminal. Cmd-key shortcut for Mail (TBD — propose Cmd+1/2/3 for surfaces).
- `src/lib/`: new `mailQuery.ts` (FTS5 query DSL helpers), `mimeAddr.ts` (RFC 5322 address parsing/formatting), `htmlPreflight.ts` (parses sanitized HTML into renderable DOM with image-block markers).
- `src/types.ts`: add `MailAccount`, `Folder`, `Message`, `Thread`, `Attachment`, `Draft`, `OutboxItem`, `SnoozeEntry`, plus event payloads.

#### Removed

- `src/components/MailView.tsx` (after Phase 2 parity, before Phase 7 ships).

### Tauri commands (full list)

Discovery / accounts:
- `mail_autoconfig(email) -> AutoconfigResult`
- `mail_oauth_start(provider, email) -> { auth_url, state }`
- `mail_oauth_complete(state, code) -> AccountId` *(internal, called by loopback handler)*
- `mail_internet_accounts_list() -> Vec<DetectedAccount>`
- `mail_account_list() -> Vec<Account>`
- `mail_account_remove(account_id) -> ()`
- `mail_account_update_settings(account_id, settings) -> ()`

Read:
- `mail_folder_list(account_id) -> Vec<Folder>`
- `mail_message_list(account_id, folder, limit, offset, sort) -> Vec<MessageHeader>`
- `mail_unified_inbox(limit, offset) -> Vec<MessageHeader>`
- `mail_thread_get(thread_id) -> Thread`
- `mail_message_get(account_id, folder, uid) -> MessageDetail`
- `mail_attachment_download(account_id, folder, uid, content_id) -> AttachmentBlobPath`
- `mail_search(query, scope) -> Vec<MessageHeader>`

Write:
- `mail_compose_create(account_id, in_reply_to_thread?) -> DraftId`
- `mail_draft_save(draft_id, fields) -> ()`
- `mail_outbox_enqueue(draft_id, send_at?, undo_window_secs?) -> OutboxId`
- `mail_outbox_undo(outbox_id) -> ()`
- `mail_outbox_status(account_id?) -> Vec<OutboxItem>`
- `mail_message_flag(account_id, folder, uid, flags) -> ()`
- `mail_message_move(account_id, folder, uid, target_folder) -> ()`
- `mail_message_delete(account_id, folder, uid) -> ()`
- `mail_message_archive(account_id, folder, uid) -> ()`
- `mail_message_snooze(account_id, folder, uid, wake_at) -> ()`
- `mail_remote_images_allow(account_id, sender_email) -> ()`

Vault / agent integration:
- `mail_save_thread_to_vault(thread_id, workspace_id) -> NoteId`
- `mail_thread_for_note(note_id) -> Option<Thread>`

Calendar:
- `mail_invite_rsvp(account_id, folder, uid, response: Accepted|Declined|Tentative) -> ()`

Events emitted to frontend:
- `mail:new_message { account_id, folder, uid, header }`
- `mail:sync_status { account_id, status, folder?, progress? }`
- `mail:outbox_update { outbox_id, state }`
- `mail:auth_required { account_id }` *(refresh failed)*

---

## Implementation phases

Each phase ends with a working app — incomplete in scope but not in quality. Daily-dogfood-able from Phase 2 onward.

### Phase 1 — Foundations (substrate, no UI)

- New crates added to `Cargo.toml`. Workspace builds.
- `mail::keychain` lands with round-trip test.
- `mail::db` opens `mail.db` at correct path; migrations apply idempotently; FTS5 virtual table + triggers wired.
- `mail::store` writes/reads `.eml` atomically; verifies SHA-256 on read.
- `mail::autoconfig` resolves Gmail and Outlook from email-only input.
- `mail::oauth` completes Gmail authorization-code flow with PKCE end-to-end via local loopback. Tokens stored in Keychain, account row written to SurrealDB.
- New SurrealDB table `email_account` migrated.
- Tauri commands: `mail_autoconfig`, `mail_oauth_start`, `mail_internet_accounts_list`, `mail_account_list`. No frontend UI — invoked via dev console for now.
- Existing `mail.rs` + `MailView.tsx` untouched. App fully functional.

**Exit criterion:** can complete Gmail OAuth from devtools and see an `email_account` row + a Keychain item.

### Phase 2 — Read path (parity with existing reader)

- `mail::imap` connects via XOAUTH2 (using token from Keychain) to one account, lists folders, fetches headers + bodies, stores `.eml` to disk, indexes into `mail.db`.
- `mail::parse` extracts headers, body parts, attachments — UTF-8 normalized.
- `mail::threading` JWZ algorithm produces stable `thread_id`s.
- `mail::sanitize` strips scripts, blocks remote images by default.
- New `MailApp.tsx` + `MailSidebar.tsx` + `MessageList.tsx` + `ThreadReader.tsx` + `MessageView.tsx` + `HtmlSandbox.tsx`. One account, Inbox only. Read-only.
- Reaches feature parity with the legacy `MailView.tsx` for one Gmail account.

**Exit criterion:** can read Gmail Inbox with threading, sanitized HTML, and click-to-load remote images. Daily dogfood begins.

### Phase 3 — Sync, push, multi-account, search

- `mail::sync` `SyncSupervisor` per account: persistent IDLE on Inbox, fetch connection on demand, CONDSTORE/QRESYNC fast resync, COMPRESS=DEFLATE, SPECIAL-USE folder detection, baseline-IMAP fallback.
- All folders synced (headers-only for last 90 days as initial-sync default; bodies on click + prefetch).
- Multi-account: add a second account from devtools, sidebar lists both. Unified Inbox view.
- `mail::search` FTS5 queries (`from:`, `to:`, `subject:`, `has:attachment`, `in:`, `is:unread`, free text).
- `mail:new_message` events fire on IDLE notifications; UI updates without manual refresh.
- `AccountAddModal.tsx` with autoconfig + Internet-Accounts pre-population.
- `MailSettings.tsx` (read-only of current settings; full-edit comes in Phase 5).

**Exit criterion:** two real accounts (Gmail + iCloud) sync in real time with QRESYNC; FTS5 search returns results in <50ms over 50k messages.

### Phase 4 — Write path

- `mail::smtp` sends via XOAUTH2.
- `mail::outbox` persistent queue with undo-send (default 10s) + scheduled send + exponential backoff retry.
- `Composer.tsx` markdown editor with live preview, To/Cc/Bcc autocomplete, attachment chips. `multipart/alternative` (text + HTML) on send.
- Drafts: auto-save every 30s; appended to IMAP `Drafts` folder via UIDPLUS-aware `APPEND`.
- Reply / Reply-All / Forward actions wire from `MessageView.tsx` into composer.
- Mailbox actions: flag / star / mark-read / move / delete / archive — IMAP `STORE`/`MOVE`/`EXPUNGE` with optimistic UI.
- `mail::snooze` snooze + wake-up.

**Exit criterion:** full send + receive cycle including undo-send and scheduled send; flag/move/archive/delete reflect on Gmail web within seconds.

### Phase 5 — Polish

- `mail::notify` Swift sidecar (`clome-notify` external bin) — banner notifications + dock badge. Per-account toggle and Focus respect.
- Attachments: lazy-download with cap; in-app preview for image / text / PDF; system-handler open for other types.
- HTML rendering polish: tracking-pixel stripper (vendored URL list), link-rewriter hover preview, per-sender remote-image allowlist UX.
- `MailSettings.tsx` full edit: per-account signature, undo-send window, attachment auto-DL cap, notify toggles.
- Layout polish: 3-pane ↔ 2-pane via Cmd+\\, conversation collapse memory.
- Calendar invite RSVP: `RsvpCard.tsx` + `mail::calendar_invite` calling existing EventKit sidecar.

**Exit criterion:** ship-quality UX. Polish gate (CLAUDE.md) passed by manual review.

### Phase 6 — Agent integration v1

- `caps.rs` updated: `email.read` re-pointed at new IMAP store. Tool actions `list_recent_mail`, `read_thread` route to `mail::commands` instead of `mail.rs`.
- New tool action `search_email(query, folder?, sender?, since?)` lands.
- `mail_save_thread_to_vault` wired. `note.source_kind = "email"` workflow uses new `thread_id` as source meta.
- `email.write` capability declared with full tool docs but execution returns `{denied: true, reason: ...}` (gate enforced in `tools.rs`). Visible to agents for discovery; not bound at v1.

**Exit criterion:** Email agent can list and read mail across multiple accounts; "Save thread to vault" action works end-to-end.

### Phase 7 — Migration & cleanup

- macOS Internet Accounts pre-population integrated into onboarding modal (works since Phase 3, polished here).
- Decommission `src-tauri/src/mail.rs` + `src/components/MailView.tsx`. Remove `walkdir`, `mailparse` deps once nothing references them.
- Update README / CLAUDE.md notes describing the new mail surface, paths, and Keychain service name.

**Exit criterion:** no references to legacy `mail.rs` remain. App boots clean. v1 ship-ready.

---

## Testing strategy

### Unit tests

- **JWZ threading** (`threading.rs`): canonical fixture set (Apple Mail thread bug, broken `References`, missing `In-Reply-To`, deep nesting >50, cyclic references, multipart digests).
- **MIME parsing** (`parse.rs`): RFC 2045/2046/2047 fixtures — quoted-printable, base64, multipart/alternative + multipart/related (CID images), multipart/mixed (attachments), `=?utf-8?B?…?=` Q-encoding, charset auto-detection (Shift-JIS, EUC-KR, ISO-8859-1), broken/lenient bodies (real-world Gmail/Exchange quirks).
- **HTML sanitizer** (`sanitize.rs`): script tags stripped, event handlers (`onclick`, `onload`) stripped, `javascript:` URLs blocked, `data:` images allowed but tracked, `cid:` rewrites correctly resolve to local file URLs, tracking-pixel URLs detected and removed, link-rewriter inserts hover-target attribute.
- **FTS5 query DSL** (`search.rs`): `from:` + `is:unread` + free text composes correctly; quoted phrases preserved; trigram fallback for partial matches.
- **Autoconfig** (`autoconfig.rs`): mocked ISPDB responses for Gmail / Outlook / iCloud / Fastmail / unknown domains; SRV record fallback; autodiscover XML parse.
- **OAuth state machine** (`oauth.rs`): PKCE verifier round-trip, state token validation, refresh on 401.
- **JWZ thread ID stability**: same conversation across two clients produces same thread ID.
- **Outbox state machine** (`outbox.rs`): undo before window expires; window expires → send; failed → retry with backoff; max retries → `failed`.
- **Snooze** (`snooze.rs`): wake-up at exact time; clock-skew tolerance ±60s; restore to original folder.
- **Address parsing** (`mimeAddr.ts`): groups, comments, quoted local-parts, IDN domains.
- **Markdown → HTML** (composer): preserves links, escapes HTML in code blocks, generates valid `multipart/alternative`.

### Integration tests

- **Live IMAP/SMTP per provider** (gated by env vars; opt-in for CI):
  - Gmail (XOAUTH2)
  - Outlook.com (XOAUTH2)
  - iCloud (XOAUTH2 if available; app-specific password fallback)
  - Fastmail (XOAUTH2)
  - Self-hosted Dovecot (baseline IMAP, no XOAUTH2)
- **OAuth round-trip**: complete authorization-code flow on Gmail + Outlook, store refresh token, force expiry, refresh succeeds.
- **CONDSTORE/QRESYNC**: server reports `MODSEQ`; missed updates fetched on reconnect; `VANISHED` responses delete locally.
- **`UIDVALIDITY` change**: mailbox renamed server-side → local rebuild triggered; no data lost (full re-fetch).
- **IDLE reconnect**: kill connection mid-IDLE → resume within 30s; backoff escalates if server unreachable.
- **Send + undo**: enqueue → undo within window → no SMTP attempt; verify outbox state transition `queued → cancelled`.
- **Send + retry**: simulate transient SMTP 421 → backoff → eventual success.
- **Scheduled send**: `send_at` set to T+10s → SMTP fires within ±2s; restart app between enqueue and send → schedule survives.
- **Drafts**: auto-save creates IMAP `Drafts` entry; subsequent saves update via UID; send removes draft.
- **Multi-account unified inbox**: messages from two accounts interleave by date; per-account filter toggle works.
- **Search**: 50k-message corpus → FTS5 query (`from:foo subject:invoice`) returns in <50ms on M-series.
- **Calendar invite**: receive iTIP REQUEST → Accept → EventKit shows event + iTIP REPLY arrives at organizer's inbox.

### Edge cases

- Two messages with identical `Message-ID` (forwarded threads) — JWZ collision handling.
- Empty body, whitespace-only body, body with only attachments.
- 50MB+ message (Gmail max). Streaming fetch + `.eml` write must not exhaust memory.
- Attachment with same filename across messages — disk path collision avoided via `(uid, content_id)`.
- Server returns flags Clome doesn't model (`$Junk`, `$Forwarded`) — preserved opaquely on round-trip.
- IMAP server with no `\Sent` SPECIAL-USE flag — fallback name detection (`Sent`, `Sent Items`, `Sent Messages`).
- iCloud quirks: case-sensitive folder names; absent CONDSTORE on some accounts.
- Gmail `[Gmail]/All Mail` virtual folder — exclude from unified inbox to avoid double-counting.
- Refresh token revoked server-side → `mail:auth_required` event surfaces; user re-OAuths; pending IDLE/syncs paused.
- Message with malformed UTF-8 bytes — replace with U+FFFD, do not panic.
- HTML email with inline `<style>` containing `@import url(...)` — stripped (counts as remote-content).
- Calendar invite without organizer email — render disabled RSVP.

### Manual / dogfood

- Daily use from Phase 2 onward — own Gmail (Stanford account) as primary test account.
- Send / receive between two accounts to verify threading + flags reflect bidirectionally.
- Verify Focus-mode respect: enable macOS Focus → notifications suppressed → unread badge still updates.
- Compare scroll smoothness vs Apple Mail / Mimestream on 10k-message Inbox (qualitative).

---

## Open questions

1. **Composer format** — `2b` (markdown source) chosen as default to match Clome's note ecosystem and avoid adding a rich-text editor dependency. But: most non-tech recipients reply in HTML rich text; threads inherit prior HTML formatting. Should v1 ship a **rich-text WYSIWYG composer** instead, with markdown as an optional power-user mode? Final call deferred — flagged for re-decision before Phase 4 starts.
2. **Yahoo Mail XOAUTH2** rejected non-trusted clients in 2024. Path forward: (a) live without Yahoo at v1; (b) require Yahoo users to use app-specific password; (c) apply for OAuth partner status. Likely (a) + (b).
3. **iCloud OAuth** — Apple does not publish a standard OAuth endpoint for iCloud Mail; XOAUTH2 support is inconsistent. Likely require **app-specific password** generated in Apple ID settings for iCloud accounts. Confirm feasibility before Phase 1 ends.
4. **Outlook.com via IMAP** is supported but lacks Categories / Focused Inbox. Acceptable for v1, but power users may notice. Provider-API (Graph) layer remains a Tier-2 option.
5. **Attachment text extraction for FTS** — should Phase 3 include PDF / docx / xlsx text extraction (via `pdf-extract` / `docx-rs`) so attachments are searchable? Adds 5-10MB binary size and CPU cost. Recommend: defer to v1.1 polish; index filename + MIME at v1.
6. **Push when app closed** — Tauri in-process sync stops at app quit. Acceptable since most users keep mail open; macOS notifications won't fire when closed. Future option: ship a launchd daemon. Out of v1 scope.
7. **Encrypted email (S/MIME / OpenPGP)** — v1 ignores. Tier-3 or never. Decision deferred.
8. **Mail.app .emlx archive import** — should v1 give users a one-click "import existing Mail.app history into new store" flow so first-launch shows their full archive offline before IMAP catches up? Useful onboarding sweetener; non-trivial parser since `.emlx` headers + flags differ. Recommend: add as opt-in checkbox in onboarding modal in Phase 7 *only if simple*; otherwise drop.
9. **Server-side filter / rule visibility** — many users have Gmail filters / Outlook rules. v1 won't show or edit them. Acceptable for now; revisit in v1.x.
10. **Conversation collapse state sync** — local-only at v1 (no IMAP equivalent). If user has multiple devices (later), state would diverge. Not a v1 concern.
11. **Per-thread mute / VIP sender list** — propose for v1.1 polish; not in core v1.
12. **Aliases / multiple identities per account** — `5c` chose to defer. Confirm before Phase 4 lands; could be small enough to slip in.
13. **Notification sidecar (`clome-notify`) build & sign** — adds a second external bin to the Tauri bundle. Confirm `tauri.conf.json` `externalBin` array can carry both `clome-eventkit` and `clome-notify` cleanly, with TCC `NSUserNotificationsUsageDescription` injected (similar to `scripts/inject-tcc.sh`).
14. **Removal of `mailparse`** — depends on legacy `mail.rs` going first. Phase 7 sequencing needs care: don't remove `mailparse` until both `mail.rs` and `MailView.tsx` are deleted.
15. **Address book** — autocomplete in composer needs a contacts source. v1 builds a local index from sent + received headers. Future: tap macOS Contacts via Swift sidecar — not in v1.
