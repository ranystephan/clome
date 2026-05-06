-- mail.db schema. Every statement is idempotent so this script is
-- safe to re-run on every boot (the migration mechanism is "just do
-- it again"). When the shape needs to change non-trivially, branch on
-- `SELECT value FROM meta WHERE key='schema_version'` in db.rs.

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- ── Accounts ─────────────────────────────────────────────────────
-- The authoritative account row lives in SurrealDB (`email_account`
-- table) so it shares migrations + workspace scoping with the rest of
-- the vault. mail.db keeps a thin mirror keyed by the same id so the
-- mail tables can use proper foreign keys without crossing DBs.
CREATE TABLE IF NOT EXISTS account_state (
    account_id    TEXT PRIMARY KEY,
    email         TEXT NOT NULL,
    last_sync_at  TEXT,
    status        TEXT NOT NULL DEFAULT 'idle' -- idle | syncing | error
);

-- ── Folders ──────────────────────────────────────────────────────
-- One row per IMAP mailbox. `role` is the SPECIAL-USE flag we resolved
-- (inbox/sent/drafts/trash/archive/junk) or NULL for user folders.
-- `uidvalidity` + `highestmodseq` drive CONDSTORE/QRESYNC fast resync.
CREATE TABLE IF NOT EXISTS folder (
    account_id      TEXT NOT NULL REFERENCES account_state(account_id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    role            TEXT,
    uidvalidity     INTEGER,
    highestmodseq   INTEGER,
    unread_count    INTEGER NOT NULL DEFAULT 0,
    total_count     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, name)
);
CREATE INDEX IF NOT EXISTS folder_role ON folder(account_id, role);

-- ── Messages ─────────────────────────────────────────────────────
-- Composite key (account, folder, uid) is the IMAP-natural identity.
-- `thread_id` is computed by JWZ (mail::threading) and stable across
-- folder moves. `eml_path` is relative to MailDb.root() so backup +
-- migration don't need path rewrites.
CREATE TABLE IF NOT EXISTS message (
    account_id              TEXT NOT NULL,
    folder                  TEXT NOT NULL,
    uid                     INTEGER NOT NULL,
    message_id              TEXT,
    thread_id               TEXT,
    in_reply_to             TEXT,
    refs_json               TEXT,
    from_addr               TEXT,
    from_name               TEXT,
    to_json                 TEXT,
    cc_json                 TEXT,
    bcc_json                TEXT,
    subject                 TEXT,
    snippet                 TEXT,
    date_received           INTEGER,
    date_sent               INTEGER,
    flags_json              TEXT,
    size                    INTEGER,
    has_attachments         INTEGER NOT NULL DEFAULT 0,
    eml_path                TEXT,
    eml_sha256              TEXT,
    body_text_extracted     TEXT,
    body_html_extracted     TEXT,
    PRIMARY KEY (account_id, folder, uid),
    FOREIGN KEY (account_id, folder) REFERENCES folder(account_id, name) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS message_account_folder_date
    ON message(account_id, folder, date_received DESC);
CREATE INDEX IF NOT EXISTS message_thread
    ON message(thread_id, date_received DESC);
CREATE INDEX IF NOT EXISTS message_message_id
    ON message(message_id);

-- ── Attachments ──────────────────────────────────────────────────
-- (account, folder, uid) of the parent message + a content-id per
-- part. `blob_path` is filled once `downloaded = 1` (lazy default per
-- the v1 plan; user can flip a Settings toggle for auto-download).
CREATE TABLE IF NOT EXISTS attachment (
    account_id      TEXT NOT NULL,
    folder          TEXT NOT NULL,
    uid             INTEGER NOT NULL,
    content_id      TEXT NOT NULL,
    filename        TEXT,
    mime            TEXT,
    size            INTEGER,
    blob_path       TEXT,
    downloaded      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, folder, uid, content_id),
    FOREIGN KEY (account_id, folder, uid)
        REFERENCES message(account_id, folder, uid) ON DELETE CASCADE
);

-- ── Threads ──────────────────────────────────────────────────────
-- Per-thread cached aggregates so the list view doesn't recompute
-- counts on every render. Updated by triggers on `message`.
CREATE TABLE IF NOT EXISTS thread (
    thread_id        TEXT PRIMARY KEY,
    root_message_id  TEXT,
    last_date        INTEGER,
    message_count    INTEGER NOT NULL DEFAULT 0,
    unread_count     INTEGER NOT NULL DEFAULT 0,
    has_flagged      INTEGER NOT NULL DEFAULT 0
);

-- ── Drafts ───────────────────────────────────────────────────────
-- Markdown source body + serialised recipients. `imap_uid_after_append`
-- captures the UID returned by IMAP UIDPLUS APPEND so we can update the
-- same draft instead of duplicating on each auto-save.
CREATE TABLE IF NOT EXISTS draft (
    id                       TEXT PRIMARY KEY,
    account_id               TEXT NOT NULL REFERENCES account_state(account_id) ON DELETE CASCADE,
    in_reply_to_thread       TEXT,
    subject                  TEXT,
    to_json                  TEXT,
    cc_json                  TEXT,
    bcc_json                 TEXT,
    body_md                  TEXT,
    attachments_json         TEXT,
    last_saved_at            INTEGER NOT NULL,
    imap_uid_after_append    INTEGER
);

-- ── Outbox ───────────────────────────────────────────────────────
-- Persistent send queue. State machine:
--   queued -> sending -> sent
--   queued -> cancelled  (user clicked undo within window)
--   sending -> failed    (after retry budget exhausted)
CREATE TABLE IF NOT EXISTS outbox (
    id              TEXT PRIMARY KEY,
    account_id      TEXT NOT NULL REFERENCES account_state(account_id) ON DELETE CASCADE,
    draft_id_ref    TEXT,
    send_at         INTEGER NOT NULL,
    undo_until      INTEGER NOT NULL,
    state           TEXT NOT NULL DEFAULT 'queued',
    attempt_count   INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    message_id      TEXT,
    eml_path        TEXT
);
CREATE INDEX IF NOT EXISTS outbox_state_send_at
    ON outbox(state, send_at);

-- ── Snooze ───────────────────────────────────────────────────────
-- Local-only (IMAP has no snooze concept). On wake we re-link the
-- message into its original folder visually; the underlying IMAP UID
-- never moved.
CREATE TABLE IF NOT EXISTS snooze (
    account_id        TEXT NOT NULL,
    folder            TEXT NOT NULL,
    uid               INTEGER NOT NULL,
    wake_at           INTEGER NOT NULL,
    original_folder   TEXT NOT NULL,
    PRIMARY KEY (account_id, folder, uid)
);
CREATE INDEX IF NOT EXISTS snooze_wake_at ON snooze(wake_at);

-- ── Remote-image allowlist ───────────────────────────────────────
-- Per-(account, sender) opt-in for remote image loading. Default deny
-- means tracking pixels can't fire without an explicit user grant.
CREATE TABLE IF NOT EXISTS remote_image_allow (
    account_id     TEXT NOT NULL,
    sender_email   TEXT NOT NULL,
    allowed_at     INTEGER NOT NULL,
    PRIMARY KEY (account_id, sender_email)
);

-- ── Full-text search ─────────────────────────────────────────────
-- FTS5 over the indexed columns of `message`. Tokenizer = porter
-- (English stemming) composed with unicode61 + remove_diacritics for
-- fuzzy international matches. We use the implicit rowid alignment:
-- `message` has an auto-assigned rowid (composite PK doesn't
-- suppress it), and search hits join back via that rowid.
CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
    subject,
    from_addr,
    body_text,
    attachment_text,
    tokenize='porter unicode61 remove_diacritics 2'
);

-- Triggers keep `search_index` aligned with `message`. Each row in
-- the FTS table reuses the parent message's rowid so query hits
-- join cleanly: SELECT m.* FROM message m JOIN search_index s ON
-- m.rowid = s.rowid WHERE search_index MATCH ?.
CREATE TRIGGER IF NOT EXISTS message_ai AFTER INSERT ON message BEGIN
    INSERT INTO search_index(rowid, subject, from_addr, body_text, attachment_text)
    VALUES (
        NEW.rowid,
        COALESCE(NEW.subject, ''),
        COALESCE(NEW.from_addr, ''),
        COALESCE(NEW.body_text_extracted, ''),
        ''  -- attachment text extraction lands in Phase 3.5
    );
END;

CREATE TRIGGER IF NOT EXISTS message_ad AFTER DELETE ON message BEGIN
    DELETE FROM search_index WHERE rowid = OLD.rowid;
END;

CREATE TRIGGER IF NOT EXISTS message_au AFTER UPDATE ON message BEGIN
    DELETE FROM search_index WHERE rowid = OLD.rowid;
    INSERT INTO search_index(rowid, subject, from_addr, body_text, attachment_text)
    VALUES (
        NEW.rowid,
        COALESCE(NEW.subject, ''),
        COALESCE(NEW.from_addr, ''),
        COALESCE(NEW.body_text_extracted, ''),
        ''
    );
END;
