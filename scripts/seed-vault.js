// Seed the vault with cross-linked test notes for Slice A graph testing.
//
// Usage:
//   1. Start the app:  bun run tauri dev
//   2. Open devtools (Cmd+Opt+I) on the Clome window
//   3. Paste this whole file into the Console and hit Enter
//   4. Settings → "Knowledge graph view" toggle on
//   5. Click the Network icon in the sidebar to see the graph tab.
//
// Re-runs are safe: existing notes get their bodies overwritten, edges
// follow because the wikilink-sync hook re-derives them from the body.

(async () => {
  const { invoke } = window.__TAURI__.core;

  const workspaces = await invoke("list_workspaces");
  if (!workspaces.length) throw new Error("no workspaces — open the app at least once");
  const ws = workspaces[0].id;
  console.log("[seed] workspace:", ws);

  // Title → markdown body. Bodies cross-link via [[wikilinks]] so the
  // graph layer auto-creates the mentions edges on save.
  const notes = {
    "Convex Optimization": `# Convex Optimization

A core toolkit for problems where the local optimum is also global.
Authored by [[Stephen Boyd]] and Lieven Vandenberghe. Reference text
across [[Stanford EE]] and modern ML.

Key formulations:
- Linear programming, QP, SOCP, SDP
- Lagrangian duality, KKT conditions
- [[Sparse Recovery]] via [[LASSO]] / [[Ridge Regression]]

Tooling: [[CVXPY]] for prototyping, MOSEK / Gurobi for production.`,

    "Stephen Boyd": `# Stephen Boyd

Stanford EE professor. Co-author of *[[Convex Optimization]]* (2004).
Known for the [[Stanford EE]] courses EE364a / EE364b and the [[CVXPY]]
modeling tool. His work spans [[Sparse Recovery]] and convex relaxations
in control.`,

    "Stanford EE": `# Stanford EE

The Department of Electrical Engineering at Stanford. Notable faculty:
- [[Stephen Boyd]] — convex optimization, control
- [[Andrej Karpathy]] (alumnus, briefly affiliated) — deep learning

Adjacent to CS where [[Neural Networks]] and [[Backpropagation]]
research overlap heavily with EE signal-processing work.`,

    "CVXPY": `# CVXPY

Python embedded language for [[Convex Optimization]]. Built by Steven
Diamond and [[Stephen Boyd]]'s group at [[Stanford EE]]. Lets you
write problems close to mathematical notation; the parser checks
disciplined-convex rules.

\`\`\`python
import cvxpy as cp
x = cp.Variable(10)
prob = cp.Problem(cp.Minimize(cp.norm(x - b, 1)),
                  [cp.norm(x, "inf") <= 1])
prob.solve()
\`\`\`

Used heavily for [[LASSO]] / [[Sparse Recovery]] research.`,

    "LASSO": `# LASSO

Least Absolute Shrinkage and Selection Operator. ℓ1-regularized
regression — drives coefficients to exactly zero, doing implicit
feature selection. Sister technique: [[Ridge Regression]] (ℓ2).

Both fall under the [[Convex Optimization]] umbrella; [[CVXPY]] is the
fastest way to prototype variants. The connection to [[Sparse Recovery]]
and [[Compressive Sensing]] is via the same ℓ1 minimization.`,

    "Ridge Regression": `# Ridge Regression

ℓ2-regularized linear regression. Closed-form solution unlike [[LASSO]],
but no implicit sparsity. Standard tool in stats and the natural
counterweight to [[LASSO]] when explaining the bias-variance trade-off.

Lives in the same [[Convex Optimization]] family.`,

    "Sparse Recovery": `# Sparse Recovery

Recovering a sparse signal x from underdetermined measurements y = Ax.
Cornerstone result: ℓ1 minimization (a [[LASSO]]-like program) recovers
x exactly under restricted-isometry-property assumptions on A.

Foundation for [[Compressive Sensing]]. Heavy use of [[Convex Optimization]]
machinery from [[Stephen Boyd]]'s group.`,

    "Compressive Sensing": `# Compressive Sensing

Sample-below-Nyquist scheme: measure y = Ax with A random, recover x
by [[Sparse Recovery]] when x is sparse in some basis.

Origins: Candès, Romberg, Tao (2006) and Donoho (2006). Strongly
connected to [[LASSO]]; differs in the assumptions placed on A.`,

    "Linear Algebra": `# Linear Algebra

Foundation everything else stands on. [[Stanford EE]] teaches it as
EE263 (Boyd's intro). Critical for [[Convex Optimization]],
[[Neural Networks]], [[Sparse Recovery]] — basically every quantitative
field.

Trefethen & Bau is the canonical numerical text.`,

    "Andrej Karpathy": `# Andrej Karpathy

Computer scientist; [[Stanford EE]] PhD. Former director of AI at
Tesla. Known for the CS231n course (taught with Fei-Fei Li) on
[[Neural Networks]] for vision, the "bitter lesson" perspective on
scaling, and the recent push toward simple, hackable from-scratch
implementations like nanoGPT.

Relevant to [[Backpropagation]] pedagogy: his "Yes you should
understand backprop" essay is required reading.`,

    "Neural Networks": `# Neural Networks

Parametric function approximators trained by gradient descent via
[[Backpropagation]]. Modern wave: transformers, scaling laws,
self-supervised pre-training.

[[Andrej Karpathy]]'s lectures and [[Stanford EE]]'s CS231n are the
standard pedagogical entry points. Underlying math leans on
[[Linear Algebra]] + a tiny bit of [[Convex Optimization]] (most NN
losses are non-convex though, hence the practical empiricism).`,

    "Backpropagation": `# Backpropagation

Reverse-mode automatic differentiation applied to [[Neural Networks]].
Linnainmaa 1970, Werbos 1974, popularized by Rumelhart-Hinton-Williams
1986.

[[Andrej Karpathy]]'s "Yes you should understand backprop" essay walks
through the leaky abstractions. Implementing it by hand (micrograd) is
the standard exercise for grokking the autograd machinery underneath
PyTorch / JAX.`,
  };

  let n = 0;
  for (const [title, body] of Object.entries(notes)) {
    // create_note is idempotent on title — re-running just gets back
    // the existing note. We then overwrite the body via update_note_body
    // so the wikilink-sync hook fires and refreshes the edge set.
    await invoke("create_note", {
      workspaceId: ws,
      title,
      sourceKind: "manual",
    });
    await invoke("update_note_body", {
      workspaceId: ws,
      title,
      body,
    });
    n++;
    console.log(`[seed] ${n}/${Object.keys(notes).length}  ${title}`);
  }
  console.log(`[seed] done — ${n} notes written. Edges auto-derived from [[wikilinks]].`);
})();
