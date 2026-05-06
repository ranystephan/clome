//! Polymorphic graph layer over the vault.
//!
//! Edges live in a single `edge` table connecting any record to any
//! other record by a typed `kind`. Today the only node kind is `note`,
//! but the layer is shape-ready for future kinds (email_thread, event,
//! project, terminal_session, file_ref) without further schema churn.
//!
//! Every wikilink in a note body or chat message becomes a `mentions`
//! edge at save time, replacing today's manual `link_notes` flow as
//! the default link source. Explicit user / agent relations land as
//! whatever `kind` the caller chose — `references` for back-compat with
//! the old `link` table, plus the rest of the enum (`about`, `attended`,
//! `attached`, `derived_from`, `replied_to`, `child_of`, `alias_of`).
//!
//! Audit: every mutation appends a `graph_edit` row so the user can
//! see what an agent changed and (eventually) undo it.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use surrealdb::engine::local::Db;
use surrealdb::sql::Thing;
use surrealdb::Surreal;

/// The closed enum of edge kinds. Matches the SurrealDB schema ASSERT.
/// New variants require both a Rust constant and a schema bump.
pub const EDGE_KINDS: &[&str] = &[
    "mentions",
    "references",
    "about",
    "attended",
    "attached",
    "derived_from",
    "replied_to",
    "child_of",
    "alias_of",
];

pub fn is_valid_kind(kind: &str) -> bool {
    EDGE_KINDS.contains(&kind)
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct EdgeRow {
    pub from_node: Thing,
    pub to_node: Thing,
    pub kind: String,
    pub context: Option<String>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

/// Result row for `view_query` and `neighbors`. The `kind` is the
/// node-record table name (`note`, `chat`, …) — UI uses it to colour
/// nodes and pick the right viewer when the user clicks one.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct NodeRow {
    pub id: Thing,
    pub kind: String,
    pub label: String,
    pub source_kind: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Serialize, Clone, Debug)]
pub struct GraphSlice {
    pub nodes: Vec<NodeRow>,
    pub edges: Vec<EdgeRow>,
}

/// Idempotent edge insert. The unique index `edge_no_dup` enforces
/// (from, to, kind) at the DB level; if a matching row already exists
/// we update its context (last write wins) so the agent / user can
/// refine the snippet without producing a duplicate.
pub async fn relate(
    db: &Surreal<Db>,
    workspace_id: Option<&Thing>,
    from: &Thing,
    to: &Thing,
    kind: &str,
    context: Option<&str>,
    by: &str,
) -> Result<(), surrealdb::Error> {
    if !is_valid_kind(kind) {
        return Err(surrealdb::Error::Db(surrealdb::error::Db::Thrown(format!(
            "edge kind {kind:?} is not in the allowed set"
        ))));
    }
    if from == to {
        return Ok(());
    }

    // Upsert via SELECT-then-CREATE-or-UPDATE. SurQL has no UPSERT
    // statement on a (multi-field) unique key, but the unique index
    // would reject a duplicate CREATE — so we look first.
    let existing: Option<Thing> = db
        .query(
            "SELECT VALUE id FROM edge \
             WHERE from_node = $from AND to_node = $to AND kind = $kind \
             LIMIT 1",
        )
        .bind(("from", from.clone()))
        .bind(("to", to.clone()))
        .bind(("kind", kind.to_string()))
        .await?
        .take(0)?;

    let action: &str;
    if let Some(id) = existing {
        if context.is_some() {
            db.query("UPDATE $id SET context = $ctx")
                .bind(("id", id))
                .bind(("ctx", context.map(|s| s.to_string())))
                .await?
                .check()?;
        }
        action = "relate_existing";
    } else {
        db.query(
            "CREATE edge SET \
                from_node = $from, \
                to_node = $to, \
                kind = $kind, \
                context = $ctx, \
                workspace = $ws, \
                created_by = $by",
        )
        .bind(("from", from.clone()))
        .bind(("to", to.clone()))
        .bind(("kind", kind.to_string()))
        .bind(("ctx", context.map(|s| s.to_string())))
        .bind(("ws", workspace_id.cloned()))
        .bind(("by", by.to_string()))
        .await?
        .check()?;
        action = "relate";
    }

    // Auto-promote any email_thread endpoint. An edge into a hidden
    // node is meaningless — if the user/agent is bothering to relate
    // to a thread, they want it visible in the graph.
    if from.tb == "email_thread" {
        let _ = crate::db::promote_email_thread_by_id(db, from).await;
    }
    if to.tb == "email_thread" {
        let _ = crate::db::promote_email_thread_by_id(db, to).await;
    }

    let payload = serde_json::json!({
        "from": from.to_string(),
        "to": to.to_string(),
        "kind": kind,
    });
    let _ = db
        .query("CREATE graph_edit SET by = $by, action = $a, payload = $p")
        .bind(("by", by.to_string()))
        .bind(("a", action.to_string()))
        .bind(("p", payload.to_string()))
        .await;
    Ok(())
}

pub async fn unrelate(
    db: &Surreal<Db>,
    from: &Thing,
    to: &Thing,
    kind: Option<&str>,
    by: &str,
) -> Result<(), surrealdb::Error> {
    if let Some(k) = kind {
        db.query("DELETE edge WHERE from_node = $f AND to_node = $t AND kind = $k")
            .bind(("f", from.clone()))
            .bind(("t", to.clone()))
            .bind(("k", k.to_string()))
            .await?
            .check()?;
    } else {
        db.query("DELETE edge WHERE from_node = $f AND to_node = $t")
            .bind(("f", from.clone()))
            .bind(("t", to.clone()))
            .await?
            .check()?;
    }
    let payload = serde_json::json!({
        "from": from.to_string(),
        "to": to.to_string(),
        "kind": kind,
    });
    let _ = db
        .query("CREATE graph_edit SET by = $by, action = 'unrelate', payload = $p")
        .bind(("by", by.to_string()))
        .bind(("p", payload.to_string()))
        .await;
    Ok(())
}

/// Replace the full set of `mentions` edges flowing out of `from_node`
/// with exactly `targets`. Adds new ones, drops stale ones, leaves
/// everything else (other kinds, edges from other nodes) alone.
///
/// This is the workhorse called from every note-body / message save —
/// the body is the source of truth, edges are derived state.
pub async fn replace_mention_edges(
    db: &Surreal<Db>,
    workspace_id: Option<&Thing>,
    from_node: &Thing,
    targets: &[Thing],
    by: &str,
) -> Result<(), surrealdb::Error> {
    let new_set: HashSet<Thing> = targets.iter().filter(|t| *t != from_node).cloned().collect();

    let existing: Vec<Thing> = db
        .query(
            "SELECT VALUE to_node FROM edge \
             WHERE from_node = $from AND kind = 'mentions'",
        )
        .bind(("from", from_node.clone()))
        .await?
        .take(0)?;
    let existing_set: HashSet<Thing> = existing.into_iter().collect();

    for stale in existing_set.difference(&new_set) {
        let _ = unrelate(db, from_node, stale, Some("mentions"), by).await;
    }
    for fresh in new_set.difference(&existing_set) {
        let _ = relate(db, workspace_id, from_node, fresh, "mentions", None, by).await;
    }
    Ok(())
}

/// 1-hop neighborhood for a node. Returns both directions (incoming +
/// outgoing) so the inspector mini-graph can show backlinks alongside
/// outbound mentions.
pub async fn neighbors(
    db: &Surreal<Db>,
    node: &Thing,
    kind_filter: Option<&[String]>,
    limit: usize,
) -> Result<GraphSlice, surrealdb::Error> {
    let limit = limit.clamp(1, 500);
    let kind_clause = if kind_filter.is_some() {
        " AND kind IN $kinds"
    } else {
        ""
    };
    let sql = format!(
        "SELECT from_node, to_node, kind, context, created_by, created_at FROM edge \
         WHERE (from_node = $node OR to_node = $node){kind_clause} \
         ORDER BY created_at DESC LIMIT {limit}"
    );
    let mut q = db.query(sql).bind(("node", node.clone()));
    if let Some(kinds) = kind_filter {
        q = q.bind(("kinds", kinds.to_vec()));
    }
    let edges: Vec<EdgeRow> = q.await?.take(0)?;

    let mut node_ids: HashSet<Thing> = HashSet::new();
    node_ids.insert(node.clone());
    for e in &edges {
        node_ids.insert(e.from_node.clone());
        node_ids.insert(e.to_node.clone());
    }
    let nodes = hydrate_nodes(db, &node_ids).await?;
    Ok(GraphSlice { nodes, edges })
}

/// Bulk slice for the full-page graph view. Top-N by recency × degree
/// keeps the canvas at <= ~500 visible nodes (per scale budget §plan).
pub async fn view_query(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    limit_nodes: usize,
) -> Result<GraphSlice, surrealdb::Error> {
    let limit_nodes = limit_nodes.clamp(50, 2000);

    // Notes — primary node kind.
    #[derive(Deserialize)]
    struct NoteSeed {
        id: Thing,
        title: String,
        source_kind: String,
        updated_at: DateTime<Utc>,
    }
    let note_rows: Vec<NoteSeed> = db
        .query(
            "SELECT id, title, source_kind, updated_at FROM note \
             WHERE workspace = $ws ORDER BY updated_at DESC LIMIT $lim",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("lim", limit_nodes as i64))
        .await?
        .take(0)?;

    // Email threads — only the ones the user/agent has explicitly
    // promoted into the graph. Mail sync still mirrors every thread
    // for cheap lookup, but the canvas would be useless drowned in
    // hundreds of cold marketing emails. Promotion is the gate.
    #[derive(Deserialize)]
    struct ThreadSeed {
        id: Thing,
        subject: String,
        last_date: DateTime<Utc>,
        from_name: Option<String>,
    }
    let thread_cap = (limit_nodes / 2).max(50) as i64;
    let thread_rows: Vec<ThreadSeed> = db
        .query(
            "SELECT id, subject, last_date, from_name FROM email_thread \
             WHERE workspace = $ws AND promoted_at != NONE \
             ORDER BY last_date DESC LIMIT $lim",
        )
        .bind(("ws", workspace_id.clone()))
        .bind(("lim", thread_cap))
        .await
        .ok()
        .and_then(|mut r| r.take::<Vec<ThreadSeed>>(0).ok())
        .unwrap_or_default();

    let mut node_ids: HashSet<Thing> = note_rows.iter().map(|r| r.id.clone()).collect();
    for t in &thread_rows {
        node_ids.insert(t.id.clone());
    }

    let mut nodes: Vec<NodeRow> = note_rows
        .into_iter()
        .map(|r| NodeRow {
            id: r.id,
            kind: "note".into(),
            label: r.title,
            source_kind: Some(r.source_kind),
            updated_at: Some(r.updated_at),
        })
        .collect();
    for t in thread_rows {
        let label = if t.subject.trim().is_empty() {
            "(no subject)".to_string()
        } else {
            t.subject
        };
        nodes.push(NodeRow {
            id: t.id,
            kind: "email_thread".into(),
            label,
            source_kind: t.from_name,
            updated_at: Some(t.last_date),
        });
    }

    // Pull every edge whose endpoint records belong to this workspace,
    // then filter in Rust to those where BOTH endpoints made it into
    // the seed set (so we never dangle an edge into a node we didn't
    // load). Workspace scoping uses record-traversal (`from_node.workspace`)
    // which works even for legacy edges that don't have the `workspace`
    // column populated — the column came in with the polymorphic edge
    // table, while the migrated `link` rows pre-date it.
    let raw_edges: Vec<EdgeRow> = db
        .query(
            "SELECT from_node, to_node, kind, context, created_by, created_at FROM edge \
             WHERE from_node.workspace = $ws AND to_node.workspace = $ws LIMIT 8000",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    let edges: Vec<EdgeRow> = raw_edges
        .into_iter()
        .filter(|e| node_ids.contains(&e.from_node) && node_ids.contains(&e.to_node))
        .collect();

    eprintln!(
        "[graph] view_query ws={} → {} nodes, {} edges",
        workspace_id,
        nodes.len(),
        edges.len()
    );

    Ok(GraphSlice { nodes, edges })
}

/// Hybrid-retrieval search across graph nodes. Combines the note
/// lexical+HNSW lane (via `db::search`) with a workspace-scoped
/// substring scan over email_thread subjects/senders. Each hit is
/// expanded with its 1-hop neighborhood for context.
pub async fn search_with_expansion(
    db: &Surreal<Db>,
    workspace_id: &Thing,
    query: &str,
    limit: usize,
) -> Result<GraphSlice, surrealdb::Error> {
    let results = crate::db::search(db, workspace_id, query, limit).await?;
    let mut node_ids: HashSet<Thing> = HashSet::new();

    for hit in &results.notes {
        // Search returns titles; resolve to record ids one round trip
        // (workspace-scoped — same query the inspector uses).
        if let Some(note) = crate::db::get_note(db, workspace_id, &hit.title).await? {
            node_ids.insert(note.id);
        }
    }

    // Email threads — substring lane keeps results predictable even
    // before HNSW catches up on cold threads. We pull a generous slice
    // and filter in Rust because Surreal's CONTAINS-style operators
    // get expensive on large tables; the row set is bounded by the
    // workspace and the lane is best-effort anyway.
    let lq = query.trim().to_lowercase();
    if !lq.is_empty() {
        #[derive(Deserialize)]
        struct ThreadHit {
            id: Thing,
            subject: String,
            from_name: Option<String>,
            from_addr: Option<String>,
        }
        let candidates: Vec<ThreadHit> = db
            .query(
                "SELECT id, subject, from_name, from_addr FROM email_thread \
                 WHERE workspace = $ws AND promoted_at != NONE \
                 ORDER BY last_date DESC LIMIT 800",
            )
            .bind(("ws", workspace_id.clone()))
            .await
            .ok()
            .and_then(|mut r| r.take::<Vec<ThreadHit>>(0).ok())
            .unwrap_or_default();
        for c in candidates {
            let s = c.subject.to_lowercase();
            let fn_l = c
                .from_name
                .as_deref()
                .unwrap_or("")
                .to_lowercase();
            let fa_l = c
                .from_addr
                .as_deref()
                .unwrap_or("")
                .to_lowercase();
            if s.contains(&lq) || fn_l.contains(&lq) || fa_l.contains(&lq) {
                node_ids.insert(c.id);
            }
        }
    }

    if node_ids.is_empty() {
        return Ok(GraphSlice {
            nodes: vec![],
            edges: vec![],
        });
    }

    // Workspace-scoped sweep, then filter to edges touching at least
    // one search hit. Same pattern as `view_query` so a SurrealDB
    // `IN` quirk on bound record arrays doesn't silently swallow
    // edges. Workspace traversal works on any node kind that owns
    // a `workspace` field (notes, future email_thread, etc.).
    let raw_edges: Vec<EdgeRow> = db
        .query(
            "SELECT from_node, to_node, kind, context, created_by, created_at FROM edge \
             WHERE from_node.workspace = $ws OR to_node.workspace = $ws LIMIT 4000",
        )
        .bind(("ws", workspace_id.clone()))
        .await?
        .take(0)?;
    let edges: Vec<EdgeRow> = raw_edges
        .into_iter()
        .filter(|e| node_ids.contains(&e.from_node) || node_ids.contains(&e.to_node))
        .collect();

    // Pull every endpoint hydrated, including 1-hop neighbors of the
    // seed hits — that's the "graph" half of the hybrid retrieve.
    let mut all_ids = node_ids.clone();
    for e in &edges {
        all_ids.insert(e.from_node.clone());
        all_ids.insert(e.to_node.clone());
    }
    let nodes = hydrate_nodes(db, &all_ids).await?;

    eprintln!(
        "[graph] search ws={} q={:?} → {} nodes, {} edges",
        workspace_id,
        query,
        nodes.len(),
        edges.len()
    );
    Ok(GraphSlice { nodes, edges })
}

/// One-shot wikilink rescan across every workspace. Marks itself done
/// in `graph_meta:wikilink_rescan` so the work happens once per
/// install. Re-runs after a clean install backfill any pre-existing
/// notes whose bodies contain `[[wikilinks]]` that never produced
/// edges (because they were written before the polymorphic edge layer
/// existed).
pub async fn run_wikilink_rescan(db: &Surreal<Db>) -> Result<(), surrealdb::Error> {
    // `value` is a reserved keyword in SurrealDB SELECT clauses; we
    // pull the id and treat row existence as the done-marker.
    let done: Option<Thing> = db
        .query("SELECT VALUE id FROM graph_meta WHERE key = 'wikilink_rescan' LIMIT 1")
        .await?
        .take(0)?;
    if done.is_some() {
        return Ok(());
    }

    let workspaces = crate::db::list_workspaces(db).await?;
    let mut total = 0usize;
    for ws in workspaces {
        match crate::db::rescan_wikilink_edges(db, &ws.id, "rescan").await {
            Ok(n) => total += n,
            Err(e) => eprintln!("[graph] rescan workspace {} failed: {e}", ws.id),
        }
    }
    eprintln!("[graph] wikilink rescan complete: {total} notes processed");

    db.query("CREATE graph_meta SET key = 'wikilink_rescan', value = 'done'")
        .await?
        .check()?;
    Ok(())
}

/// Resolve a set of record ids into NodeRow summaries. Each kind is
/// hydrated from its dedicated table — the polymorphic edge layer
/// gives us a flat id space, but each table has its own schema, so
/// we partition by `id.tb` first and run one query per kind.
async fn hydrate_nodes(
    db: &Surreal<Db>,
    ids: &HashSet<Thing>,
) -> Result<Vec<NodeRow>, surrealdb::Error> {
    if ids.is_empty() {
        return Ok(vec![]);
    }

    // Partition by table name (Surreal Thing knows its own table).
    let mut by_kind: std::collections::HashMap<String, Vec<Thing>> =
        std::collections::HashMap::new();
    for id in ids {
        by_kind
            .entry(id.tb.clone())
            .or_default()
            .push(id.clone());
    }

    let mut out: Vec<NodeRow> = Vec::new();

    if let Some(note_ids) = by_kind.remove("note") {
        #[derive(Deserialize)]
        struct NoteSummary {
            id: Thing,
            title: String,
            source_kind: String,
            updated_at: DateTime<Utc>,
        }
        let notes: Vec<NoteSummary> = db
            .query(
                "SELECT id, title, source_kind, updated_at FROM note \
                 WHERE id IN $ids",
            )
            .bind(("ids", note_ids))
            .await?
            .take(0)?;
        for n in notes {
            out.push(NodeRow {
                id: n.id,
                kind: "note".into(),
                label: n.title,
                source_kind: Some(n.source_kind),
                updated_at: Some(n.updated_at),
            });
        }
    }

    if let Some(thread_ids) = by_kind.remove("email_thread") {
        #[derive(Deserialize)]
        struct ThreadSummary {
            id: Thing,
            subject: String,
            from_name: Option<String>,
            last_date: DateTime<Utc>,
        }
        let threads: Vec<ThreadSummary> = db
            .query(
                "SELECT id, subject, from_name, last_date FROM email_thread \
                 WHERE id IN $ids",
            )
            .bind(("ids", thread_ids))
            .await?
            .take(0)?;
        for t in threads {
            let label = if t.subject.trim().is_empty() {
                "(no subject)".to_string()
            } else {
                t.subject
            };
            out.push(NodeRow {
                id: t.id,
                kind: "email_thread".into(),
                label,
                source_kind: t.from_name,
                updated_at: Some(t.last_date),
            });
        }
    }

    // Other kinds (event, project, terminal_session) land here as
    // they get added in later slices. Edges into them stay valid
    // even before they're hydratable — the canvas just renders an
    // unlabelled node, which is harmless.

    Ok(out)
}
