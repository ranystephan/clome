//! One-shot vault seeder for graph testing.
//!
//! Run with `cargo run --bin seed_vault` while the Clome app is
//! NOT running (SurrealKV holds an exclusive file lock). Writes a
//! cluster of cross-linked notes into the default workspace; the
//! `update_note_body` path triggers wikilink-sync, which auto-creates
//! mentioned targets and upserts `mentions` edges.
//!
//! Idempotent — re-running just overwrites the bodies and re-derives
//! the edges from the new bodies. Targeted at testing only; not
//! shipped with the production app.

use std::path::PathBuf;

const NOTES: &[(&str, &str)] = &[
    (
        "Convex Optimization",
        "# Convex Optimization\n\n\
         A core toolkit for problems where the local optimum is also global. \
         Authored by [[Stephen Boyd]] and Lieven Vandenberghe. Reference text \
         across [[Stanford EE]] and modern ML.\n\n\
         Key formulations:\n\
         - Linear programming, QP, SOCP, SDP\n\
         - Lagrangian duality, KKT conditions\n\
         - [[Sparse Recovery]] via [[LASSO]] / [[Ridge Regression]]\n\n\
         Tooling: [[CVXPY]] for prototyping, MOSEK / Gurobi for production.",
    ),
    (
        "Stephen Boyd",
        "# Stephen Boyd\n\n\
         Stanford EE professor. Co-author of *[[Convex Optimization]]* (2004). \
         Known for the [[Stanford EE]] courses EE364a / EE364b and the [[CVXPY]] \
         modeling tool. His work spans [[Sparse Recovery]] and convex relaxations \
         in control.",
    ),
    (
        "Stanford EE",
        "# Stanford EE\n\n\
         The Department of Electrical Engineering at Stanford. Notable faculty:\n\
         - [[Stephen Boyd]] — convex optimization, control\n\
         - [[Andrej Karpathy]] (alumnus, briefly affiliated) — deep learning\n\n\
         Adjacent to CS where [[Neural Networks]] and [[Backpropagation]] \
         research overlap heavily with EE signal-processing work.",
    ),
    (
        "CVXPY",
        "# CVXPY\n\n\
         Python embedded language for [[Convex Optimization]]. Built by Steven \
         Diamond and [[Stephen Boyd]]'s group at [[Stanford EE]]. Lets you \
         write problems close to mathematical notation; the parser checks \
         disciplined-convex rules.\n\n\
         Used heavily for [[LASSO]] / [[Sparse Recovery]] research.",
    ),
    (
        "LASSO",
        "# LASSO\n\n\
         Least Absolute Shrinkage and Selection Operator. ℓ1-regularized \
         regression — drives coefficients to exactly zero, doing implicit \
         feature selection. Sister technique: [[Ridge Regression]] (ℓ2).\n\n\
         Both fall under the [[Convex Optimization]] umbrella; [[CVXPY]] is the \
         fastest way to prototype variants. The connection to [[Sparse Recovery]] \
         and [[Compressive Sensing]] is via the same ℓ1 minimization.",
    ),
    (
        "Ridge Regression",
        "# Ridge Regression\n\n\
         ℓ2-regularized linear regression. Closed-form solution unlike [[LASSO]], \
         but no implicit sparsity. Standard tool in stats and the natural \
         counterweight to [[LASSO]] when explaining the bias-variance trade-off.\n\n\
         Lives in the same [[Convex Optimization]] family.",
    ),
    (
        "Sparse Recovery",
        "# Sparse Recovery\n\n\
         Recovering a sparse signal x from underdetermined measurements y = Ax. \
         Cornerstone result: ℓ1 minimization (a [[LASSO]]-like program) recovers \
         x exactly under restricted-isometry-property assumptions on A.\n\n\
         Foundation for [[Compressive Sensing]]. Heavy use of [[Convex Optimization]] \
         machinery from [[Stephen Boyd]]'s group.",
    ),
    (
        "Compressive Sensing",
        "# Compressive Sensing\n\n\
         Sample-below-Nyquist scheme: measure y = Ax with A random, recover x \
         by [[Sparse Recovery]] when x is sparse in some basis.\n\n\
         Origins: Candès, Romberg, Tao (2006) and Donoho (2006). Strongly \
         connected to [[LASSO]]; differs in the assumptions placed on A.",
    ),
    (
        "Linear Algebra",
        "# Linear Algebra\n\n\
         Foundation everything else stands on. [[Stanford EE]] teaches it as \
         EE263 (Boyd's intro). Critical for [[Convex Optimization]], \
         [[Neural Networks]], [[Sparse Recovery]] — basically every quantitative \
         field.\n\n\
         Trefethen & Bau is the canonical numerical text.",
    ),
    (
        "Andrej Karpathy",
        "# Andrej Karpathy\n\n\
         Computer scientist; [[Stanford EE]] PhD. Former director of AI at \
         Tesla. Known for the CS231n course (taught with Fei-Fei Li) on \
         [[Neural Networks]] for vision, the \"bitter lesson\" perspective on \
         scaling, and the recent push toward simple, hackable from-scratch \
         implementations like nanoGPT.\n\n\
         Relevant to [[Backpropagation]] pedagogy: his \"Yes you should \
         understand backprop\" essay is required reading.",
    ),
    (
        "Neural Networks",
        "# Neural Networks\n\n\
         Parametric function approximators trained by gradient descent via \
         [[Backpropagation]]. Modern wave: transformers, scaling laws, \
         self-supervised pre-training.\n\n\
         [[Andrej Karpathy]]'s lectures and [[Stanford EE]]'s CS231n are the \
         standard pedagogical entry points. Underlying math leans on \
         [[Linear Algebra]] + a tiny bit of [[Convex Optimization]] (most NN \
         losses are non-convex though, hence the practical empiricism).",
    ),
    (
        "Backpropagation",
        "# Backpropagation\n\n\
         Reverse-mode automatic differentiation applied to [[Neural Networks]]. \
         Linnainmaa 1970, Werbos 1974, popularized by Rumelhart-Hinton-Williams \
         1986.\n\n\
         [[Andrej Karpathy]]'s \"Yes you should understand backprop\" essay walks \
         through the leaky abstractions. Implementing it by hand (micrograd) is \
         the standard exercise for grokking the autograd machinery underneath \
         PyTorch / JAX.",
    ),
];

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Mirror the path the running app uses (see lib.rs setup).
    let home = std::env::var("HOME")?;
    let data_dir =
        PathBuf::from(home).join("Library/Application Support/com.clome.app");
    println!("[seed] data_dir = {}", data_dir.display());

    let db = clome_lib::db::open(data_dir).await?;
    let workspaces = clome_lib::db::list_workspaces(&db).await?;
    let ws = workspaces
        .first()
        .ok_or("no workspaces — open the app at least once first")?;
    println!("[seed] workspace = {} ({})", ws.name, ws.id);

    for (i, (title, body)) in NOTES.iter().enumerate() {
        // create_note is idempotent on (title, workspace); when the
        // note already exists it returns the existing record, so we
        // unconditionally follow up with update_note_body to refresh
        // the body and trigger wikilink-edge sync.
        clome_lib::db::create_note(&db, &ws.id, title, "", "manual", "user").await?;
        clome_lib::db::update_note_body(&db, &ws.id, title, body, "user").await?;
        println!("[seed] {:2}/{}  {}", i + 1, NOTES.len(), title);
    }

    println!(
        "[seed] done — {} notes written, edges auto-derived from [[wikilinks]].",
        NOTES.len()
    );
    Ok(())
}
