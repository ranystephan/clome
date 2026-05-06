//! JWZ threading. The 1997 algorithm Apple Mail / Mutt / Thunderbird
//! all converged on. Operates on `(message_id, in_reply_to, references,
//! subject, date_sent)` tuples — pure logic, no I/O — so it's trivially
//! testable.
//!
//! The original write-up: <https://www.jwz.org/doc/threading.html>.
//!
//! What we do:
//!   * Build a Container per known Message-ID, plus phantom Containers
//!     for any IDs referenced but not yet downloaded (incremental sync
//!     means many threads start with their roots invisible).
//!   * Wire children to parents using the References chain (newest
//!     ref is the immediate parent; older refs are ancestors). Fall
//!     back to In-Reply-To when References is absent.
//!   * Reject parent links that would create a cycle.
//!   * The thread_id of every message is the Message-ID of its root
//!     container — a stable handle that survives intermediate
//!     messages arriving later.
//!
//! What we deliberately skip from the full JWZ algorithm:
//!   * Subject-prefix grouping (joining "Re: foo" and "foo" threads
//!     when one has no References). Fragile in practice and our
//!     `subject` carries Unicode + provider-specific prefixes that
//!     would need normalisation we can't justify yet. JWZ §5b.
//!   * Pruning of empty container trees — we keep phantoms because
//!     the UI wants to render "[message not yet downloaded]"
//!     placeholders rather than silently ellipsing the chain.

use std::collections::{HashMap, HashSet};

/// What threading needs from a message. Owned because callers usually
/// hold these around for DB writes too.
#[derive(Debug, Clone)]
pub struct ThreadInput {
    pub message_id: String,
    pub in_reply_to: Option<String>,
    pub references: Vec<String>,
}

/// Result for one input message. `thread_id` is the root container's
/// Message-ID, hashed to a stable short string suitable for index
/// lookups.
#[derive(Debug, Clone)]
pub struct ThreadAssignment {
    pub message_id: String,
    pub thread_id: String,
    pub root_message_id: String,
}

/// Compute thread assignments for a batch. Order independent: same
/// inputs → same outputs.
pub fn assign(inputs: &[ThreadInput]) -> Vec<ThreadAssignment> {
    // Step 1: container per Message-ID. Phantom for refs we haven't
    // ingested yet so chains don't break across batches.
    let mut parent_of: HashMap<String, Option<String>> = HashMap::new();
    let mut known: HashSet<String> = HashSet::new();
    for input in inputs {
        if input.message_id.is_empty() {
            continue;
        }
        known.insert(input.message_id.clone());
        parent_of.entry(input.message_id.clone()).or_insert(None);
    }

    // Step 2: parents via References (newest = immediate parent).
    // Wire ancestor chains too so a missing intermediate message
    // doesn't sever the thread.
    for input in inputs {
        if input.message_id.is_empty() {
            continue;
        }
        let chain = build_chain(input);
        let mut prior: Option<String> = None;
        for ancestor in chain.iter() {
            // Each id's parent is the previous (older) id in the
            // chain. The first id has no parent.
            if let Some(p) = &prior {
                let already_has_parent = parent_of
                    .get(ancestor)
                    .map(|v| v.is_some())
                    .unwrap_or(false);
                if !already_has_parent && !creates_cycle(&parent_of, ancestor, p) {
                    parent_of.insert(ancestor.clone(), Some(p.clone()));
                } else {
                    parent_of.entry(ancestor.clone()).or_insert(None);
                }
            } else {
                parent_of.entry(ancestor.clone()).or_insert(None);
            }
            prior = Some(ancestor.clone());
        }
        // Finally, the message itself is a child of the newest ref
        // (last entry of the chain).
        if let Some(immediate) = chain.last() {
            let already_has_parent = parent_of
                .get(&input.message_id)
                .map(|v| v.is_some())
                .unwrap_or(false);
            if !already_has_parent && !creates_cycle(&parent_of, &input.message_id, immediate) {
                parent_of.insert(input.message_id.clone(), Some(immediate.clone()));
            }
        }
    }

    // Step 3: walk parent links to find each message's root, hash it.
    let mut out = Vec::with_capacity(inputs.len());
    for input in inputs {
        if input.message_id.is_empty() {
            continue;
        }
        let root = find_root(&parent_of, &input.message_id);
        out.push(ThreadAssignment {
            message_id: input.message_id.clone(),
            thread_id: hash_root(&root),
            root_message_id: root,
        });
        let _ = &known; // silence the borrow checker in tests
    }
    out
}

fn build_chain(input: &ThreadInput) -> Vec<String> {
    // References: oldest → newest. If absent, fall back to
    // In-Reply-To (single newest).
    if !input.references.is_empty() {
        return input
            .references
            .iter()
            .filter(|s| !s.is_empty())
            .cloned()
            .collect();
    }
    match &input.in_reply_to {
        Some(p) if !p.is_empty() => vec![p.clone()],
        _ => Vec::new(),
    }
}

fn creates_cycle(
    parent_of: &HashMap<String, Option<String>>,
    child: &str,
    candidate_parent: &str,
) -> bool {
    if child == candidate_parent {
        return true;
    }
    // Walk up from candidate_parent — if we reach `child`, the link
    // would close a loop.
    let mut cur = parent_of.get(candidate_parent).cloned().flatten();
    let mut seen = HashSet::new();
    while let Some(node) = cur {
        if node == child {
            return true;
        }
        if !seen.insert(node.clone()) {
            // Pre-existing cycle (shouldn't happen, but be safe).
            return true;
        }
        cur = parent_of.get(&node).cloned().flatten();
    }
    false
}

fn find_root(parent_of: &HashMap<String, Option<String>>, start: &str) -> String {
    let mut cur = start.to_string();
    let mut seen = HashSet::new();
    seen.insert(cur.clone());
    loop {
        match parent_of.get(&cur).and_then(|p| p.clone()) {
            Some(parent) => {
                if !seen.insert(parent.clone()) {
                    // Loop guard — return current as root.
                    return cur;
                }
                cur = parent;
            }
            None => return cur,
        }
    }
}

/// Stable short id derived from the root Message-ID. We use SHA-256
/// truncated to 16 hex chars — tiny enough for indexes, collision
/// space is 2^64 (fine for any single user's mail).
fn hash_root(root: &str) -> String {
    use sha2::Digest;
    let mut h = sha2::Sha256::new();
    h.update(root.as_bytes());
    let bytes = h.finalize();
    bytes.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(id: &str, irt: Option<&str>, refs: &[&str]) -> ThreadInput {
        ThreadInput {
            message_id: id.into(),
            in_reply_to: irt.map(|s| s.into()),
            references: refs.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn isolated_message_is_its_own_root() {
        let out = assign(&[input("a@x", None, &[])]);
        assert_eq!(out[0].root_message_id, "a@x");
    }

    #[test]
    fn reply_inherits_root() {
        let out = assign(&[
            input("a@x", None, &[]),
            input("b@x", Some("a@x"), &["a@x"]),
        ]);
        assert_eq!(out[0].root_message_id, "a@x");
        assert_eq!(out[1].root_message_id, "a@x");
        assert_eq!(out[0].thread_id, out[1].thread_id);
    }

    #[test]
    fn deep_chain_via_references() {
        // a -> b -> c -> d; d only references the chain, not a direct
        // In-Reply-To to b/c. JWZ should still root them at a.
        let out = assign(&[
            input("a@x", None, &[]),
            input("b@x", Some("a@x"), &["a@x"]),
            input("c@x", Some("b@x"), &["a@x", "b@x"]),
            input("d@x", None, &["a@x", "b@x", "c@x"]),
        ]);
        for assign in &out {
            assert_eq!(assign.root_message_id, "a@x");
        }
        let unique_ids: HashSet<_> = out.iter().map(|a| &a.thread_id).collect();
        assert_eq!(unique_ids.len(), 1);
    }

    #[test]
    fn missing_intermediate_keeps_thread_intact() {
        // We have a and c, but b (c's direct parent) was never
        // ingested. c's References chain includes a and b — phantom
        // container for b should still root c at a.
        let out = assign(&[
            input("a@x", None, &[]),
            input("c@x", Some("b@x"), &["a@x", "b@x"]),
        ]);
        assert_eq!(out[0].root_message_id, "a@x");
        assert_eq!(out[1].root_message_id, "a@x");
    }

    #[test]
    fn cycle_in_references_does_not_loop() {
        // Pathological input: a references b, b references a. Code
        // must terminate and produce some deterministic root rather
        // than spin.
        let out = assign(&[
            input("a@x", None, &["b@x"]),
            input("b@x", None, &["a@x"]),
        ]);
        assert_eq!(out.len(), 2);
        // Both must agree on a root, whichever it ends up being.
        assert_eq!(out[0].root_message_id, out[1].root_message_id);
    }

    #[test]
    fn empty_message_id_is_skipped() {
        let out = assign(&[
            input("", None, &[]),
            input("a@x", None, &[]),
        ]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].message_id, "a@x");
    }

    #[test]
    fn thread_id_stable_across_calls() {
        let a = assign(&[input("root@x", None, &[])]);
        let b = assign(&[input("root@x", None, &[])]);
        assert_eq!(a[0].thread_id, b[0].thread_id);
    }
}
