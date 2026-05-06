import { onCleanup, onMount, createEffect } from "solid-js";
import type { GraphSlice } from "../lib/graph";
import { nodeKey } from "../lib/graph";

// Edge kind → CSS variable (or hex). Falls back to muted gray if a
// future kind shows up without a matching token.
export const KIND_COLOR: Record<string, string> = {
  mentions: "var(--color-accent)",
  references: "var(--color-text-muted)",
  about: "#a78bfa",
  attended: "#f59e0b",
  attached: "#10b981",
  derived_from: "#ec4899",
  replied_to: "#38bdf8",
  child_of: "#6366f1",
  alias_of: "var(--color-warn)",
};

export type CanvasHover = {
  label: string;
  kind: string;
  source_kind: string | null;
  // Screen-space pixel position of the node centre, used by parent UIs
  // that want to render an HTML tooltip over the canvas.
  screenX: number;
  screenY: number;
};

type SimNode = {
  key: string;
  label: string;
  kind: string;
  source_kind: string | null;
  x: number;
  y: number;
  vx: number;
  vy: number;
  fixed: boolean;
  degree: number;
};

type SimEdge = {
  from: string;
  to: string;
  kind: string;
};

export type GraphCanvasProps = {
  slice: GraphSlice;
  // The "anchor" — pinned at the centre, never simulated. Optional;
  // when null the simulation runs free.
  focusKey?: string | null;
  // The currently selected node — drives focus-mode dimming. Click on
  // empty canvas clears it (parent owns the signal).
  selectedKey?: string | null;
  onNodeClick: (label: string, key: string) => void;
  onSelectionChange?: (key: string | null) => void;
  onHover?: (h: CanvasHover | null) => void;
  // Subset of edge kinds to render. When undefined, every kind shows.
  visibleEdgeKinds?: ReadonlySet<string>;
  width: number;
  height: number;
  // When true, every node's label draws regardless of focus state.
  // Mini-graph leaves this off; full-page page leaves it on.
  labelAll?: boolean;
  // Imperative camera handle exposed to the parent for "fit to view"
  // and "reset" buttons. Called once on mount.
  onCameraReady?: (camera: GraphCamera) => void;
};

export type GraphCamera = {
  fitToView: () => void;
  resetView: () => void;
};

// Sim tuning constants. Tuned for ≤500 nodes.
const ITERATIONS_BUDGET = 260;
const MIN_NODE_R = 5;
const MAX_NODE_R = 13;

export default function GraphCanvas(props: GraphCanvasProps) {
  let canvas: HTMLCanvasElement | undefined;
  let frame = 0;
  let dpr = 1;
  let nodes: SimNode[] = [];
  let edges: SimEdge[] = [];
  let dragKey: string | null = null;
  let dragOffset = { x: 0, y: 0 };
  let dragStart: { sx: number; sy: number } | null = null;
  // Movement gate: a mousedown only "promotes" to a drag once the
  // pointer has moved past this threshold (px²). Below it, mouseup
  // fires the click handler instead — without this every node tap
  // counts as a drag-and-pin and click never reaches the parent.
  const DRAG_THRESHOLD_SQ = 16;
  let dragMoved = false;
  let hoverKey: string | null = null;
  let iterations = 0;

  // Camera. `cam.x/cam.y` are world coords currently centred on the
  // canvas; `cam.scale` is pixels per world unit (1 = identity).
  const cam = { x: 0, y: 0, scale: 1 };
  // Track whether the user has explicitly panned/zoomed. If they
  // haven't, slice changes auto-fit; once they have, we leave the
  // camera alone so layout doesn't snap under the cursor.
  let userMovedCamera = false;
  // Pan drag state — distinct from node drag (dragKey).
  let panAnchor: { x: number; y: number; camX: number; camY: number } | null =
    null;

  function rebuild() {
    const seen = new Map<string, SimNode>();
    const degree = new Map<string, number>();

    for (const n of props.slice.nodes) {
      const key = nodeKey(n.id);
      // Drop a fresh node anywhere on a circle around the origin; we
      // re-centre on the canvas mid-point at draw time via the camera.
      const angle = Math.random() * Math.PI * 2;
      const r = 80 + Math.random() * 60;
      seen.set(key, {
        key,
        label: n.label,
        kind: n.kind,
        source_kind: n.source_kind,
        x: Math.cos(angle) * r,
        y: Math.sin(angle) * r,
        vx: 0,
        vy: 0,
        fixed: false,
        degree: 0,
      });
    }

    edges = [];
    for (const e of props.slice.edges) {
      const from = nodeKey(e.from_node);
      const to = nodeKey(e.to_node);
      if (seen.has(from) && seen.has(to) && from !== to) {
        edges.push({ from, to, kind: e.kind });
        degree.set(from, (degree.get(from) ?? 0) + 1);
        degree.set(to, (degree.get(to) ?? 0) + 1);
      }
    }
    for (const n of seen.values()) {
      n.degree = degree.get(n.key) ?? 0;
    }
    nodes = Array.from(seen.values());

    if (props.focusKey) {
      const f = seen.get(props.focusKey);
      if (f) {
        f.x = 0;
        f.y = 0;
        f.fixed = true;
      }
    }
    iterations = 0;
    if (!userMovedCamera) {
      // Reset to identity so the auto-fit on next frame centres
      // cleanly. fitToView triggers in the post-settle hook below.
      cam.x = 0;
      cam.y = 0;
      cam.scale = 1;
    }
  }

  function step() {
    if (nodes.length === 0) return;
    const k_repel = nodes.length > 80 ? 1100 : 1500;
    const k_spring = 0.024;
    const k_gravity = 0.0035;
    const damping = 0.86;
    const ideal_edge = nodes.length > 80 ? 70 : 120;

    // Pairwise repulsion. O(n²) — fine for the budget we ship.
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      if (a.fixed) continue;
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j];
        let dx = a.x - b.x;
        let dy = a.y - b.y;
        let d2 = dx * dx + dy * dy;
        if (d2 < 0.01) {
          dx = (Math.random() - 0.5) * 4;
          dy = (Math.random() - 0.5) * 4;
          d2 = dx * dx + dy * dy;
        }
        const f = k_repel / d2;
        const d = Math.sqrt(d2);
        const fx = (dx / d) * f;
        const fy = (dy / d) * f;
        a.vx += fx;
        a.vy += fy;
        if (!b.fixed) {
          b.vx -= fx;
          b.vy -= fy;
        }
      }
    }

    const byKey = new Map<string, SimNode>();
    for (const n of nodes) byKey.set(n.key, n);
    for (const e of edges) {
      const a = byKey.get(e.from);
      const b = byKey.get(e.to);
      if (!a || !b) continue;
      const dx = b.x - a.x;
      const dy = b.y - a.y;
      const d = Math.sqrt(dx * dx + dy * dy) || 1;
      const f = (d - ideal_edge) * k_spring;
      const fx = (dx / d) * f;
      const fy = (dy / d) * f;
      if (!a.fixed) {
        a.vx += fx;
        a.vy += fy;
      }
      if (!b.fixed) {
        b.vx -= fx;
        b.vy -= fy;
      }
    }

    for (const n of nodes) {
      if (n.fixed) {
        n.vx = 0;
        n.vy = 0;
        continue;
      }
      // Pull toward world origin (camera then re-centres on canvas).
      n.vx += (0 - n.x) * k_gravity;
      n.vy += (0 - n.y) * k_gravity;
      n.vx *= damping;
      n.vy *= damping;
      n.x += n.vx;
      n.y += n.vy;
    }
    iterations++;

    // Auto-fit once the layout has roughly settled, but only if the
    // user hasn't taken control of the camera.
    if (iterations === 60 && !userMovedCamera) fitToView();
    if (iterations === 200 && !userMovedCamera) fitToView();
  }

  function nodeRadius(n: SimNode): number {
    // Degree-driven sizing on a log scale so a single hub doesn't
    // dwarf the rest. Focused node always gets the max radius.
    if (n.key === props.focusKey) return MAX_NODE_R;
    const t = Math.log2(1 + n.degree) / Math.log2(1 + 16);
    return MIN_NODE_R + Math.min(1, t) * (MAX_NODE_R - MIN_NODE_R - 2);
  }

  function neighbourSet(): Set<string> {
    const target = props.selectedKey ?? props.focusKey ?? null;
    if (!target) return new Set();
    const out = new Set<string>([target]);
    for (const e of edges) {
      if (e.from === target) out.add(e.to);
      if (e.to === target) out.add(e.from);
    }
    return out;
  }

  // Per-kind base fill so the eye can scan note clusters vs. email
  // clusters at a glance. Selection / hover / focus override these.
  const KIND_FILL: Record<string, string> = {
    note: "var(--color-text-muted)",
    email_thread: "oklch(0.72 0.12 230)", // mail blue, matches tcard--mail
    event: "oklch(0.74 0.13 145)",
    file_ref: "oklch(0.72 0.11 300)",
    project: "var(--color-warn)",
    chat: "var(--color-text-dim)",
    agent: "var(--color-good)",
  };

  function nodeFill(n: SimNode, dimmed: boolean): string {
    if (n.key === props.focusKey) return "var(--color-accent)";
    if (n.key === props.selectedKey) return "var(--color-accent)";
    if (n.key === hoverKey) return "var(--color-text)";
    const base = KIND_FILL[n.kind] ?? "var(--color-text-muted)";
    return dimmed ? "var(--color-text-subtle)" : base;
  }

  function worldToScreen(wx: number, wy: number, w: number, h: number) {
    return {
      x: w / 2 + (wx - cam.x) * cam.scale,
      y: h / 2 + (wy - cam.y) * cam.scale,
    };
  }

  function screenToWorld(sx: number, sy: number, w: number, h: number) {
    return {
      x: (sx - w / 2) / cam.scale + cam.x,
      y: (sy - h / 2) / cam.scale + cam.y,
    };
  }

  function fitToView() {
    if (!nodes.length) return;
    let minX = Infinity,
      minY = Infinity,
      maxX = -Infinity,
      maxY = -Infinity;
    for (const n of nodes) {
      if (n.x < minX) minX = n.x;
      if (n.x > maxX) maxX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.y > maxY) maxY = n.y;
    }
    const w = props.width;
    const h = props.height;
    const dx = maxX - minX || 1;
    const dy = maxY - minY || 1;
    const margin = 40;
    const sx = (w - margin * 2) / dx;
    const sy = (h - margin * 2) / dy;
    cam.scale = Math.min(2, Math.max(0.25, Math.min(sx, sy)));
    cam.x = (minX + maxX) / 2;
    cam.y = (minY + maxY) / 2;
  }

  function resetView() {
    userMovedCamera = false;
    fitToView();
  }

  function draw() {
    const c = canvas;
    if (!c) return;
    const ctx = c.getContext("2d");
    if (!ctx) return;
    const w = props.width;
    const h = props.height;
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.save();
    // DPR scaling — every world pixel maps to dpr device pixels.
    ctx.scale(dpr, dpr);
    // Camera transform — translate to canvas centre, then apply scale,
    // then translate so cam.x/cam.y is at the origin.
    ctx.translate(w / 2, h / 2);
    ctx.scale(cam.scale, cam.scale);
    ctx.translate(-cam.x, -cam.y);

    const byKey = new Map<string, SimNode>();
    for (const n of nodes) byKey.set(n.key, n);

    const nb = neighbourSet();
    const focusing = nb.size > 0;
    const visibleKinds = props.visibleEdgeKinds;

    // Edges first.
    for (const e of edges) {
      if (visibleKinds && !visibleKinds.has(e.kind)) continue;
      const a = byKey.get(e.from);
      const b = byKey.get(e.to);
      if (!a || !b) continue;
      const inFocus = !focusing || (nb.has(a.key) && nb.has(b.key));
      ctx.strokeStyle = KIND_COLOR[e.kind] ?? "var(--color-border-strong)";
      ctx.globalAlpha = inFocus ? 0.65 : 0.12;
      ctx.lineWidth = inFocus ? 1.1 / cam.scale : 0.8 / cam.scale;
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    // Nodes.
    for (const n of nodes) {
      const dimmed = focusing && !nb.has(n.key);
      const r = nodeRadius(n);
      ctx.globalAlpha = dimmed ? 0.35 : 1;
      ctx.fillStyle = nodeFill(n, dimmed);
      ctx.beginPath();
      ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      ctx.fill();
      // Highlight ring for focus / selection / hover.
      if (
        n.key === props.focusKey ||
        n.key === props.selectedKey ||
        n.key === hoverKey
      ) {
        ctx.strokeStyle = "var(--color-accent)";
        ctx.lineWidth = 2 / cam.scale;
        ctx.globalAlpha = 0.8;
        ctx.beginPath();
        ctx.arc(n.x, n.y, r + 3 / cam.scale, 0, Math.PI * 2);
        ctx.stroke();
      }
    }

    // Labels — tagged after nodes so they paint on top. Scale text
    // inversely with zoom so it stays a stable 11px on screen.
    const labelPx = 11.5;
    ctx.font = `${labelPx / cam.scale}px var(--font-sans, system-ui, sans-serif)`;
    ctx.textBaseline = "middle";
    for (const n of nodes) {
      const dimmed = focusing && !nb.has(n.key);
      const showLabel =
        props.labelAll ||
        nb.has(n.key) ||
        n.key === hoverKey ||
        n.key === props.selectedKey;
      if (!showLabel) continue;
      ctx.globalAlpha = dimmed ? 0.4 : 1;
      ctx.fillStyle = "var(--color-text)";
      const r = nodeRadius(n);
      const label = n.label.length > 32 ? `${n.label.slice(0, 31)}…` : n.label;
      ctx.fillText(label, n.x + r + 4 / cam.scale, n.y);
    }

    ctx.restore();
  }

  function tick() {
    if (iterations < ITERATIONS_BUDGET) {
      step();
      step();
    }
    draw();
    frame = requestAnimationFrame(tick);
  }

  function nodeAt(worldX: number, worldY: number): SimNode | null {
    // Walk in reverse so the node painted on top wins hit tests.
    for (let i = nodes.length - 1; i >= 0; i--) {
      const n = nodes[i];
      const dx = n.x - worldX;
      const dy = n.y - worldY;
      // Slightly larger pad than the visual radius so small nodes
      // don't feel like pixel-hunting.
      const r = nodeRadius(n) + 5 / cam.scale;
      if (dx * dx + dy * dy <= r * r) return n;
    }
    return null;
  }

  function pointFromEvent(e: MouseEvent): { sx: number; sy: number } {
    if (!canvas) return { sx: 0, sy: 0 };
    const rect = canvas.getBoundingClientRect();
    return {
      sx: e.clientX - rect.left,
      sy: e.clientY - rect.top,
    };
  }

  function onMouseDown(e: MouseEvent) {
    const { sx, sy } = pointFromEvent(e);
    const w = props.width;
    const h = props.height;
    const wp = screenToWorld(sx, sy, w, h);
    const n = nodeAt(wp.x, wp.y);
    if (n) {
      // Provisionally claim the node. The mousemove handler
      // promotes this to a real drag once the pointer crosses the
      // threshold; mouseup with no promotion is a click.
      dragKey = n.key;
      dragOffset = { x: n.x - wp.x, y: n.y - wp.y };
      dragStart = { sx, sy };
      dragMoved = false;
      return;
    }
    // Empty canvas → start panning.
    panAnchor = { x: sx, y: sy, camX: cam.x, camY: cam.y };
    if (canvas) canvas.style.cursor = "grabbing";
  }

  function onMouseMove(e: MouseEvent) {
    const { sx, sy } = pointFromEvent(e);
    const w = props.width;
    const h = props.height;
    if (panAnchor) {
      const dx = (sx - panAnchor.x) / cam.scale;
      const dy = (sy - panAnchor.y) / cam.scale;
      cam.x = panAnchor.camX - dx;
      cam.y = panAnchor.camY - dy;
      userMovedCamera = true;
      return;
    }
    if (dragKey && dragStart) {
      // Threshold-promote into a drag — once we cross the gate, pin
      // the node and start steering it. Below the gate we keep
      // hovering so the click path stays open on mouseup.
      if (!dragMoved) {
        const ddx = sx - dragStart.sx;
        const ddy = sy - dragStart.sy;
        if (ddx * ddx + ddy * ddy > DRAG_THRESHOLD_SQ) {
          dragMoved = true;
          const n = nodes.find((nn) => nn.key === dragKey);
          if (n) {
            n.fixed = true;
            iterations = Math.min(iterations, ITERATIONS_BUDGET - 80);
          }
        }
      }
      if (dragMoved) {
        const wp = screenToWorld(sx, sy, w, h);
        const n = nodes.find((nn) => nn.key === dragKey);
        if (n) {
          n.x = wp.x + dragOffset.x;
          n.y = wp.y + dragOffset.y;
          n.vx = 0;
          n.vy = 0;
        }
        return;
      }
    }
    const wp = screenToWorld(sx, sy, w, h);
    const n = nodeAt(wp.x, wp.y);
    const newHover = n?.key ?? null;
    if (newHover !== hoverKey) {
      hoverKey = newHover;
      if (canvas) canvas.style.cursor = hoverKey ? "pointer" : "default";
      if (props.onHover) {
        if (n) {
          const screen = worldToScreen(n.x, n.y, w, h);
          props.onHover({
            label: n.label,
            kind: n.kind,
            source_kind: n.source_kind,
            screenX: screen.x,
            screenY: screen.y,
          });
        } else {
          props.onHover(null);
        }
      }
    }
  }

  function onMouseUp(e: MouseEvent) {
    if (panAnchor) {
      panAnchor = null;
      if (canvas) canvas.style.cursor = "default";
      return;
    }
    const wasDragKey = dragKey;
    const moved = dragMoved;
    dragKey = null;
    dragStart = null;
    dragMoved = false;
    if (wasDragKey && !moved) {
      // Click on a node — fire selection + open. The selection lets
      // the parent show a detail card; the node-click hands the
      // label up so the caller (e.g. App.openNote) can route to
      // the note tab.
      const n = nodes.find((nn) => nn.key === wasDragKey);
      if (n) {
        props.onSelectionChange?.(n.key);
        props.onNodeClick(n.label, n.key);
      }
      return;
    }
    if (wasDragKey && moved) {
      // Real drag — release the pin so the node settles back into
      // the simulation (unless it's the focused anchor node).
      const n = nodes.find((nn) => nn.key === wasDragKey);
      if (n && n.key !== props.focusKey) n.fixed = false;
      return;
    }
    // Mouse-up over empty canvas without a pan or drag → clear
    // selection so the user can dismiss the detail card by clicking
    // off a node.
    const { sx, sy } = pointFromEvent(e);
    const wp = screenToWorld(sx, sy, props.width, props.height);
    if (!nodeAt(wp.x, wp.y)) {
      props.onSelectionChange?.(null);
    }
  }

  function onWheel(e: WheelEvent) {
    e.preventDefault();
    if (!canvas) return;
    const { sx, sy } = pointFromEvent(e);
    const w = props.width;
    const h = props.height;
    // Zoom toward the cursor so the world point under the pointer
    // stays put across the zoom step.
    const before = screenToWorld(sx, sy, w, h);
    const factor = Math.exp(-e.deltaY * 0.0015);
    cam.scale = Math.max(0.15, Math.min(4, cam.scale * factor));
    const after = screenToWorld(sx, sy, w, h);
    cam.x += before.x - after.x;
    cam.y += before.y - after.y;
    userMovedCamera = true;
  }

  function applyDpi() {
    if (!canvas) return;
    dpr = Math.max(1, window.devicePixelRatio || 1);
    canvas.width = Math.floor(props.width * dpr);
    canvas.height = Math.floor(props.height * dpr);
    canvas.style.width = `${props.width}px`;
    canvas.style.height = `${props.height}px`;
  }

  onMount(() => {
    applyDpi();
    rebuild();
    if (canvas) {
      canvas.addEventListener("wheel", onWheel, { passive: false });
    }
    if (props.onCameraReady) {
      props.onCameraReady({ fitToView, resetView });
    }
    frame = requestAnimationFrame(tick);
  });

  createEffect(() => {
    void props.width;
    void props.height;
    applyDpi();
    if (iterations > ITERATIONS_BUDGET - 60) {
      iterations = ITERATIONS_BUDGET - 60;
    }
  });

  createEffect(() => {
    void props.slice;
    void props.focusKey;
    rebuild();
  });

  onCleanup(() => {
    cancelAnimationFrame(frame);
    if (canvas) canvas.removeEventListener("wheel", onWheel);
  });

  return (
    <canvas
      ref={(el) => (canvas = el)}
      onMouseDown={onMouseDown}
      onMouseMove={onMouseMove}
      onMouseUp={onMouseUp}
      onMouseLeave={() => {
        hoverKey = null;
        dragKey = null;
        panAnchor = null;
        if (canvas) canvas.style.cursor = "default";
        props.onHover?.(null);
      }}
    />
  );
}
