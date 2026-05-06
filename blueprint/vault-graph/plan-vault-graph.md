# Vault Graph — Obsidian-style notes + cross-domain knowledge graph

> i want the markdown notes part of the app to behave like Obsidian does. with links, references, cross references, and even a knowledge graph. ther reason for this is that I want the agents to have access to it, and by that we could expand the knowledge graph through the agent, and emails would also be integrated in the knowledge graph, with appropriate references. my calendar, my notes, my terminals even, my projects. everything would be in a big knowledge graph that is built smartly, properly, so that my agents will have appropriate knowledge if they need it.
>
> * Notes vault stays primary; emails, calendar events, files, terminal sessions, projects become first-class node kinds (own payload tables) — not wrapped notes
> * One polymorphic `edge` table (`from: record<any>`, `to: record<any>`, `kind`, `context`) replaces the note-only `link` table; existing rows migrate
> * Every node kind carries title + body + embedding → uniform hybrid retrieval across kinds (BM25 + HNSW + 1-hop), Karpathy-style
> * Wikilinks `[[Title]]` parsed at save-time; missing targets auto-create empty notes; ambiguity → title-disambiguation only when needed
> * Graph view = optional, settings-toggle, off by default. Full-page force-directed + 1-2 hop mini-graph in inspector. Cheap render (canvas/WebGL, recency+degree pruning)
> * Edge enum: `mentions`, `references`, `about`, `attended`, `attached`, `derived_from`, `replied_to`, `child_of` + free-text `context`
> * Agent tools: `graph.search`, `graph.neighbors`, `graph.path`, `graph.relate`, `graph.unlink`, `graph.merge`. Audited via `graph_edit` log. No raw SurQL exposed
> * Identity resolution: embedding-similarity suggestions + one-click user confirm + agent `graph.merge` via suggestion API. Reversible
> * Projects: new `project` table; membership via `child_of` edges from notes/emails/events
> * Terminal sessions: schema slot now (`terminal_session`), populated via on-demand `Cmd+Shift+K` capture only until terminal embed ships (Tier 3)
> * Emails: all threads are node rows (SurrealDB shadow of mail.db `thread`); embedding + HNSW indexing lazy on first touch (read / reply / `[[mention]]`); embed scope = subject + first 1000 chars
> * Scale budget: ≤50k nodes / ≤200k edges; graph view prunes to 1-2 hop + top-N by recency × degree
> * v1 phasing: vertical slices — notes-graph end-to-end first, then email, then events/files/projects/terminals
> * `@`-mention oracle expands to all node kinds with a kind-filter UI
> * Backfill: one-shot `link → edge` migration on first boot + async background note-body rescan for missing wikilink edges
> * Chats and agents promoted to graph nodes; messages stay non-nodes (edges flow from `chat` → target, not `message` → target)

---

## Overview

- **Replace the note-only `link` table with a polymorphic `edge` table** (`from: record<any>`, `to: record<any>`, `kind` enum, `context`, `created_at`, `created_by`). One edge layer connects every node kind. Existing `link` rows migrate to `edge` with `kind = "references"`.
- **Promote non-note artifacts to first-class graph nodes** with their own SurrealDB tables: `email_thread` (shadow of mail.db), `event`, `file_ref`, `terminal_session`, `project`. Plus `chat` and `agent` already exist as records — they join the graph as nodes too. Every node kind carries an optional `embedding` + `embedded_at` for unified HNSW retrieval.
- **Auto-resolve `[[wikilinks]]` at save-time**: parse note bodies and chat messages on write, upsert `edge { kind: "mentions" }` rows, auto-create empty target notes if missing (Obsidian "create on click"). Replaces today's manual `LinkNotes` agent tool as the default link source.
- **Optional graph view** (off by default, settings toggle): full-page force-directed canvas for exploration + 1-2 hop mini-graph in the existing inspector pane. Both prune to ≤500 visible nodes via recency × degree. Render budget < 16ms/frame at 500 nodes.
- **Agent graph surface**: typed tool API (`graph.search`, `graph.neighbors`, `graph.path`, `graph.relate`, `graph.unlink`, `graph.merge`) with hybrid BM25 + HNSW + 1-hop retrieval. Every write logs a `graph_edit` row. Raw SurQL stays Rust-internal — agents never see it.

## Expected behavior

### Notes (Phase A)

- Typing `[[Foo]]` in a note body and saving creates an `edge { from: this_note, to: note(Foo), kind: "mentions" }` row. If `Foo` doesn't exist, an empty note is created with `source_kind = "manual"` and `last_edited_by = "user"` (or `"agent:<name>"` when typed by an agent).
- Renaming a note retitles its row, rewrites all `[[OldTitle]]` strings in note bodies + message bodies (already does today), and updates `edge` rows automatically because they reference by record id, not title.
- Deleting a note cascades all `edge` rows where `from = note` or `to = note` (replaces today's `link` cascade).
- The inspector pane backlinks list now shows backlinks from all node kinds, grouped by kind: notes / emails / events / files / chats. Each item links to its native viewer (note → inspector, email → mail thread, event → calendar pane).
- The `@`-mention autocomplete in chat and the search palette gains a kind-filter chip row (All · Notes · Emails · Events · Files · Projects · Chats). Selecting `@some-event` inserts `[[some-event]]` and persists an edge from the chat to the event on send.

### Cross-domain (Phases B–E)

- Opening or replying to an email thread for the first time triggers a lazy embed of `subject + body[:1000]` and inserts the thread into the graph. Cold threads stay in mail.db only and are reachable via BM25 search but not in the graph view's hot path.
- Calendar events (already pulled via EventKit on demand) become persistent `event` nodes the first time they're referenced or attended. Their body is `description + location + attendees` summary.
- Files referenced via `read_file` or `list_dir` agent tools auto-create `file_ref` nodes (path + last_seen + sha256). Attachments downloaded from email auto-create `file_ref` linked to the parent thread by `attached`.
- Terminal sessions captured via `Cmd+Shift+K` create `terminal_session` nodes (cwd + recent commands + transcript snippet). No automatic per-session recording in v1.
- Projects are user-created groupings: a sidebar entry creates a `project` node; dragging notes/emails/events onto it inserts `child_of` edges. Agents can suggest project membership via `graph.relate`.

### Identity resolution

- The inspector pane on a note shows a "Possibly the same as" panel listing the top-3 cosine-similar nodes (any kind) above 0.85 threshold. One-click "merge" promotes the chosen node into the canonical and rewrites all incoming edges to the surviving node. The dropped node becomes an alias row (recoverable from `graph_edit` log).
- Agents call `graph.merge(a, b)` only after first calling `graph.suggest_alias(a)` and getting `b` back — guard against silent merges. Every merge is reversible from the audit log (Settings → Vault → Recent merges → Undo).

### Graph view

- Off by default. Settings → Vault → "Enable graph view" toggle exposes a new tab next to chat/notes (full page) and a mini-graph block at the bottom of the inspector pane.
- Full page: force-directed canvas (WebGL via existing dependencies, fallback canvas2D). Filter chips by kind. Search box does a `graph.search` and re-centers on the result. Click node → opens it in its native viewer; double-click → re-centers.
- Mini-graph in inspector: shows the current node + its 1-hop neighborhood (or 2-hop if < 25 nodes total). Hover edge → shows `kind` + `context` snippet. Click neighbor → navigates inspector to that node.
- Both views prune to top 500 nodes by `score = log(recency_days + 1) × degree`. A "node count: 423/12k (filtered)" caption is always visible.

### Agent surface

- Existing `LinkNotes` tool stays for backwards compatibility but is documented as a special case of `graph.relate(from, to, "references")`.
- New tool prompts surfaced when agent has the `graph.read` capability (read-only: `search`, `neighbors`, `path`, `suggest_alias`) or `graph.write` (adds `relate`, `unlink`, `merge`). Default agents (Generalist, Calendar, Email) get `graph.read`; user opts in to `graph.write` per agent.
- Agent search results render as inline cards (one per hit) with kind icon, title, snippet, and a `[[mention]]` chip the user can click to insert into the message draft.

### Migration & boot behavior

- First boot after upgrade runs an idempotent migration:
  1. Adds new tables (`edge`, `graph_edit`, `event`, `file_ref`, `terminal_session`, `project`, `email_thread`).
  2. Copies all `link` rows into `edge` with `kind = "references"` (in a single SurQL transaction).
  3. Drops `link` table.
- After migration, a background task rescans every `note.body` once, parsing `[[wikilinks]]` and inserting any missing `mentions` edges. Idempotent — re-runs on every boot are no-ops. Progress shown in a toast (e.g. "Indexing vault: 412 / 5230 notes…"); cancellable; resumable via a `graph_meta` cursor row.
- Existing `note_unique_title` index keeps notes globally unique per workspace. New unique index `edge_no_dup` on `(from, to, kind)` prevents duplicate edges of the same kind.

## Changes

### Schema (SurrealDB — `clome.db`)

- Replace `link` table with polymorphic `edge { from: record<any>, to: record<any>, kind: string, context: option<string>, weight: option<float>, workspace, created_at, created_by }`.
- Add `kind` constraint via SurrealDB ASSERT to one of: `mentions`, `references`, `about`, `attended`, `attached`, `derived_from`, `replied_to`, `child_of`, `alias_of`.
- Add `graph_edit { edge_or_node, by, ts, action, payload }` audit table mirroring `note_edit`.
- Add `graph_meta { key, value }` for backfill cursors and one-shot migration markers.
- New node tables: `event`, `file_ref`, `terminal_session`, `project`, `email_thread`. Each has `title`, `body`, `embedding`, `embedded_at`, `workspace`, `source_meta`, timestamps.
- Add `embedding` + `embedded_at` to `chat` and `agent` (already exist as records, missing the embed fields).
- New unique indexes: `edge_no_dup` on `(from, to, kind)`, `project_unique_name` on `(name, workspace)`.
- New HNSW index per node kind: `event_embedding_hnsw`, `file_ref_embedding_hnsw`, `terminal_session_embedding_hnsw`, `project_embedding_hnsw`, `email_thread_embedding_hnsw`, `chat_embedding_hnsw`, `agent_embedding_hnsw`. All 384-dim, COSINE, EFC 150, M 24 (matches existing note index).
- New BM25 search indexes for title + body on each new node kind.
- Drop `entity` table (already removed in current schema; keep the REMOVE statement).

### Schema (SQLite — `mail.db`)

- No changes. `mail.db` remains content authority for messages and attachments. The new `email_thread` row in SurrealDB is a thin shadow keyed by `thread_id` (same shape as today's `email_account` shadow).

### Rust core (`src-tauri/src/`)

- Rename `db::link_notes` → `db::create_edge` and accept polymorphic `Thing` for both endpoints. Keep a thin `link_notes` shim calling the new function for the existing agent tool surface.
- New `db::edge` module: `create_edge`, `delete_edge`, `list_edges_for(node, kinds?, depth?)`, `shortest_path(a, b)`, `find_aliases(node, threshold)`. All take and return SurrealDB `Thing`s.
- Extend `db::extract_wikilink_titles` to also resolve to `Thing`s and emit `mentions` edges in `db::update_note_body` and `db::save_message`.
- New `db::node_kinds` module: `create_event`, `create_file_ref`, `create_terminal_session`, `create_project` and their getter / lister counterparts. `email_thread` upsert hooks into the existing mail sync path.
- New `db::merge_nodes(a, b)`: rewrites all `edge.from = a` to `b` and `edge.to = a` to `b` in a transaction; marks `a` as `alias_of` `b`; logs to `graph_edit`.
- New `embed::embed_node(thing)` dispatcher: routes by record-kind to the right field-extraction strategy (note → title+body, email_thread → subject+body[:1000], event → title+notes+location, etc.). Existing 384-dim model stays.
- New `tools.rs` variants: `GraphSearch`, `GraphNeighbors`, `GraphPath`, `GraphRelate`, `GraphUnlink`, `GraphMerge`, `GraphSuggestAlias`. Each maps to a `db::edge` or `db::node_kinds` function. Wire into existing `ToolCall::action_name` / capability gating (`graph.read` / `graph.write`).
- New tauri commands in `lib.rs`: `graph_search`, `graph_neighbors`, `graph_path`, `graph_view_query` (the bulk-load query the graph view UI uses), `graph_merge_nodes`, `graph_undo_merge`, `graph_settings_set_enabled`. Existing `inspect_note` extended to return mini-graph data.
- New migration runner `db::migrate_link_to_edge`: idempotent, runs after `SCHEMA` is applied. Sets `graph_meta:link_migration` to `"done"` on success.
- New background task `embed::rescan_wikilinks_loop`: walks notes ordered by `updated_at DESC`, parses bodies, upserts `mentions` edges via `db::create_edge`. Persists cursor in `graph_meta:wikilink_rescan_cursor`. Cancellable via `tokio_util::sync::CancellationToken` shared with existing embed worker.
- Mail sync (`mail/sync.rs`): on thread upsert, also upsert the SurrealDB `email_thread` shadow row. On thread first-touch (read / reply), enqueue an embed job.

### Frontend (`src/`)

- New `src/lib/graph.ts`: typed wrappers for the new tauri commands. `searchGraph`, `getNeighbors`, `getPath`, `relate`, `unlink`, `merge`, `suggestAlias`.
- Extend `src/lib/wikilinks.ts`: add `resolveWikilinks(text, workspace)` that calls a tauri command to resolve titles to `Thing`s + kinds (so the renderer can colour-code by kind: blue for note, purple for event, green for project, etc.).
- New `src/components/GraphView.tsx`: full-page force-directed view. Uses canvas2D (no new dep) for v1; can swap to a WebGL lib later if 500+ nodes lag. Includes filter chips, search box, hover tooltip, click-to-open.
- New `src/components/MiniGraph.tsx`: 1-2 hop graph block embedded in `InspectorPane.tsx`. Fixed height (~160px). Click → navigates inspector.
- Extend `src/components/InspectorPane.tsx`: add "Possibly the same as" alias-suggestion section above existing backlinks. Group backlinks by kind.
- Extend `src/components/MentionDropdown.tsx`: add a row of kind-filter chips at the top. Default "All". Persist last selection per session.
- Extend `src/components/SearchPalette.tsx`: same kind-filter chips. Search hits show kind icon.
- Extend `src/components/MarkdownContent.tsx`: render `[[wikilink]]` chips coloured by resolved kind.
- New `src/components/Settings/VaultGraphSettings.tsx`: toggle for graph view enable, alias-suggestion threshold slider, "Recent merges" undo list.
- App shell (`src/App.tsx`): add a new "Graph" tab type to `WorkspaceTab` union, gated by the settings toggle.

### Agent capabilities (`caps.rs` + agent registry)

- New capabilities: `graph.read`, `graph.write`. Default agents (Generalist, Calendar, Email) get `graph.read` on first boot. User toggles `graph.write` per agent in Agent settings.
- Existing `link_notes` tool keeps requiring no specific capability (back-compat) but is internally re-routed through `graph.write` once the user accepts the upgrade prompt on first launch.

### Settings & migration UX

- First post-upgrade launch: small modal explains the migration, shows the rescan progress, offers "Run later" (defers to next boot). No destructive action — the user can dismiss.
- Settings → Vault → toggle for graph view, alias threshold, list of recent merges with one-click undo.
- Audit log viewer in Settings (read-only): table of `graph_edit` rows filterable by `by` (user / agent name) and kind. Each row has an "Undo" action where reversible.

### Phasing (vertical slices)

- **Slice A — Notes graph end-to-end**: schema migration, `link → edge`, wikilink auto-resolution, inspector backlinks grouping, mini-graph in inspector, full-page graph view (notes only), `graph.search` / `graph.neighbors` / `graph.relate` agent tools, settings toggle. Notes feel Obsidian-like in isolation.
- **Slice B — Email integration**: `email_thread` shadow rows, lazy embed on first touch, mail sync hook, thread nodes appear in graph view + `@`-mention oracle + inspector backlinks. `replied_to` edges.
- **Slice C — Calendar + files**: `event` and `file_ref` node kinds + ingest hooks from existing EventKit / `read_file` tool calls. `attended` and `attached` edges.
- **Slice D — Projects + alias resolution**: `project` table, drag-to-add UX, `child_of` edges, `graph.suggest_alias` + `graph.merge` tools, inspector "Possibly the same as" panel, recent-merges undo.
- **Slice E — Terminal session capture**: `terminal_session` node kind populated via `Cmd+Shift+K` from terminal context. Schema only — no per-session recording until Tier 3.

Each slice ships independently and is usable on its own. No half-finished states between slices.
