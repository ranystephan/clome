import {
  createSignal,
  createEffect,
  createMemo,
  onCleanup,
  onMount,
  Show,
  For,
} from "solid-js";
import { listen } from "@tauri-apps/api/event";
import { Maximize, Minimize, X, RotateCcw } from "lucide-solid";
import GraphCanvas, {
  KIND_COLOR,
  type CanvasHover,
  type GraphCamera,
} from "./GraphCanvas";
import {
  loadGraphView,
  loadNeighbors,
  searchGraph,
  EDGE_KINDS,
  nodeKey,
  type EdgeKind,
  type GraphSlice,
  type NodeRow,
} from "../lib/graph";

type CommonProps = {
  workspaceId: unknown;
  // Click routing is kind-aware: notes open the inspector, email
  // threads route to the mail tab, etc. Centralizing it here lets
  // the canvas stay dumb (just hands up the hit) while the parent
  // owns the navigation logic.
  onNodeClick: (node: NodeRow) => void;
};

// ─── Full-page graph tab ─────────────────────────────────────────

export default function GraphView(props: CommonProps) {
  const [slice, setSlice] = createSignal<GraphSlice>({ nodes: [], edges: [] });
  const [query, setQuery] = createSignal("");
  const [loading, setLoading] = createSignal(false);
  const [err, setErr] = createSignal<string | null>(null);
  const [size, setSize] = createSignal({ w: 800, h: 600 });
  const [hover, setHover] = createSignal<CanvasHover | null>(null);
  const [selectedKey, setSelectedKey] = createSignal<string | null>(null);
  const [activeKinds, setActiveKinds] = createSignal<Set<EdgeKind>>(
    new Set(EDGE_KINDS),
  );
  let host: HTMLDivElement | undefined;
  let resizeObs: ResizeObserver | null = null;
  let unlistenVault: (() => void) | null = null;
  let searchSeq = 0;
  let cameraRef: GraphCamera | null = null;

  async function refresh() {
    setLoading(true);
    setErr(null);
    try {
      const next = await loadGraphView(props.workspaceId, 500);
      setSlice(next);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }

  async function runSearch(q: string) {
    const seq = ++searchSeq;
    setLoading(true);
    setErr(null);
    try {
      const next = q.trim()
        ? await searchGraph(props.workspaceId, q, 50)
        : await loadGraphView(props.workspaceId, 500);
      if (seq !== searchSeq) return;
      setSlice(next);
    } catch (e) {
      if (seq !== searchSeq) return;
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      if (seq === searchSeq) setLoading(false);
    }
  }

  onMount(async () => {
    if (host) {
      const update = () => {
        if (!host) return;
        const r = host.getBoundingClientRect();
        setSize({ w: Math.max(320, r.width), h: Math.max(240, r.height) });
      };
      update();
      resizeObs = new ResizeObserver(update);
      resizeObs.observe(host);
    }
    await refresh();
    unlistenVault = await listen("vault:updated", () => {
      void runSearch(query());
    });

    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey && e.key === "0") {
        e.preventDefault();
        cameraRef?.resetView();
      } else if (e.key === "Escape") {
        if (selectedKey()) setSelectedKey(null);
        else if (query()) {
          setQuery("");
          void runSearch("");
        }
      }
    };
    window.addEventListener("keydown", onKey);
    onCleanup(() => window.removeEventListener("keydown", onKey));
  });

  onCleanup(() => {
    resizeObs?.disconnect();
    if (unlistenVault) unlistenVault();
  });

  createEffect(() => {
    void props.workspaceId;
    void refresh();
  });

  // Stats by source kind so the legend can show how many of each lives
  // in the current slice. Useful at scale; today everything is "manual"
  // until Slice B–E ship more node kinds.
  const stats = createMemo(() => {
    const out = { nodes: 0, edges: 0, sources: new Map<string, number>() };
    for (const n of slice().nodes) {
      out.nodes++;
      const k = n.source_kind ?? n.kind;
      out.sources.set(k, (out.sources.get(k) ?? 0) + 1);
    }
    for (const e of slice().edges) {
      if (activeKinds().has(e.kind as EdgeKind)) out.edges++;
    }
    return out;
  });

  // Edge-kind set memo passed to the canvas — only kinds actually
  // present in the slice matter for the legend, but we still respect
  // the user's `activeKinds` filter when sending to canvas.
  const visibleKinds = createMemo(() => activeKinds());

  // Edge kinds present in the current slice — drives the chip row.
  // Filters that have zero edges hide automatically so the legend
  // doesn't get noisy at tiny vault sizes.
  const presentKinds = createMemo(() => {
    const counts = new Map<EdgeKind, number>();
    for (const e of slice().edges) {
      counts.set(
        e.kind as EdgeKind,
        (counts.get(e.kind as EdgeKind) ?? 0) + 1,
      );
    }
    return counts;
  });

  // Resolve the selection back to a node row (for the side panel).
  const selectedNode = createMemo(() => {
    const k = selectedKey();
    if (!k) return null;
    return slice().nodes.find((n) => nodeKey(n.id) === k) ?? null;
  });

  function toggleKind(k: EdgeKind) {
    setActiveKinds((prev) => {
      const next = new Set(prev);
      if (next.has(k)) next.delete(k);
      else next.add(k);
      // At least one kind must be active or the canvas blanks.
      if (next.size === 0) return prev;
      return next;
    });
  }

  return (
    <div class="flex h-full w-full flex-col bg-bg">
      <header class="flex flex-wrap items-center gap-3 border-b border-border px-6 py-4">
        <div class="min-w-0 flex-1">
          <h2 class="text-[15px] font-semibold text-text">Knowledge graph</h2>
          <p class="text-[11px] text-text-dim">
            {stats().nodes} {stats().nodes === 1 ? "node" : "nodes"} ·{" "}
            {stats().edges} {stats().edges === 1 ? "edge" : "edges"}
            <Show when={loading()}>
              <span class="ml-2 text-text-subtle">refreshing…</span>
            </Show>
          </p>
        </div>
        <input
          type="search"
          placeholder="Search graph…"
          value={query()}
          onInput={(e) => setQuery(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              void runSearch(query());
            }
          }}
          class="input-pill w-72 px-3 py-1.5 text-[12.5px]"
        />
        <div class="flex items-center gap-1">
          <button
            type="button"
            class="control-icon flex size-8"
            title="Fit to view (⌘0)"
            onClick={() => cameraRef?.resetView()}
          >
            <Maximize size={14} strokeWidth={2} />
          </button>
        </div>
      </header>

      {/* Edge-kind legend / filter chips */}
      <Show when={presentKinds().size > 0}>
        <div class="flex flex-wrap items-center gap-1.5 border-b border-border px-6 py-2.5">
          <span class="mr-1 text-[10px] uppercase tracking-wide text-text-subtle">
            edges
          </span>
          <For each={EDGE_KINDS}>
            {(k) => (
              <Show when={presentKinds().has(k)}>
                <button
                  type="button"
                  onClick={() => toggleKind(k)}
                  class="flex items-center gap-1.5 rounded-full border border-border px-2 py-0.5 text-[10.5px] transition-colors"
                  classList={{
                    "bg-bg-elev text-text": activeKinds().has(k),
                    "text-text-subtle hover:text-text-dim": !activeKinds().has(k),
                  }}
                >
                  <span
                    class="inline-block size-2 rounded-full"
                    style={{ background: KIND_COLOR[k] }}
                  />
                  {k}
                  <span class="font-mono tabular-nums text-text-subtle">
                    {presentKinds().get(k)}
                  </span>
                </button>
              </Show>
            )}
          </For>
        </div>
      </Show>

      <div class="relative flex-1 overflow-hidden">
        <Show when={err()}>
          <p class="absolute left-6 top-6 text-[12px] text-danger">{err()}</p>
        </Show>
        <div ref={(el) => (host = el)} class="absolute inset-0">
          <Show
            when={slice().nodes.length > 0}
            fallback={
              <div class="flex h-full items-center justify-center">
                <p class="empty-state text-center text-[13px]">
                  <Show
                    when={query().trim()}
                    fallback={<>your vault has no notes yet — start writing.</>}
                  >
                    no matches for "{query()}".
                  </Show>
                </p>
              </div>
            }
          >
            <GraphCanvas
              slice={slice()}
              width={size().w}
              height={size().h}
              selectedKey={selectedKey()}
              onSelectionChange={setSelectedKey}
              onNodeClick={(_label, key) => {
                const n = slice().nodes.find((nn) => nodeKey(nn.id) === key);
                if (n) props.onNodeClick(n);
              }}
              onHover={setHover}
              onCameraReady={(cam) => (cameraRef = cam)}
              visibleEdgeKinds={visibleKinds() as ReadonlySet<string>}
              labelAll
            />
          </Show>
        </div>

        {/* Hover tooltip — pinned in screen coords just above the node. */}
        <Show when={hover() && !selectedNode()}>
          {(h) => (
            <div
              class="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-full rounded-md border border-border bg-bg-panel px-2 py-1 text-[10.5px] text-text shadow-md"
              style={{
                left: `${h().screenX}px`,
                top: `${h().screenY - 12}px`,
              }}
            >
              <div class="font-medium">{h().label}</div>
              <div class="text-text-subtle">
                {h().source_kind ?? h().kind}
              </div>
            </div>
          )}
        </Show>

        {/* Selected node detail card — bottom-left overlay, lets the
            user focus on one node and read its 1-hop context without
            losing the canvas. Click "Open" to deep-dive into the note. */}
        <Show when={selectedNode()}>
          {(n) => (
            <aside class="absolute bottom-4 left-4 z-10 w-72 max-w-[40vw] rounded-lg border border-border bg-bg-panel p-3 shadow-xl">
              <div class="mb-2 flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <div class="truncate text-[13px] font-semibold text-text">
                    {n().label}
                  </div>
                  <div class="text-[10.5px] text-text-subtle">
                    {n().source_kind ?? n().kind}
                  </div>
                </div>
                <button
                  type="button"
                  class="control-icon flex size-6 shrink-0"
                  onClick={() => setSelectedKey(null)}
                  title="Clear selection"
                >
                  <X size={12} strokeWidth={2} />
                </button>
              </div>
              <Show when={n().updated_at}>
                <div class="mb-2 text-[10.5px] text-text-dim">
                  edited {new Date(n().updated_at!).toLocaleString()}
                </div>
              </Show>
              <button
                type="button"
                onClick={() => props.onNodeClick(n())}
                class="btn-soft btn-soft--sm btn-soft--primary w-full"
              >
                <Show
                  when={n().kind === "email_thread"}
                  fallback={<>Open note</>}
                >
                  Open in Mail
                </Show>
              </button>
            </aside>
          )}
        </Show>

        {/* Help strip — bottom right, single line, low contrast. */}
        <div class="pointer-events-none absolute bottom-3 right-4 z-0 text-[10px] text-text-subtle">
          drag · scroll to zoom · click node · ⌘0 fit
        </div>
      </div>
    </div>
  );
}

// ─── Inspector mini-graph ────────────────────────────────────────

type MiniProps = CommonProps & {
  focusTitle: string;
  // When set, clicking the maximize button hands the focused title to
  // the parent so it can swap to the full-page graph tab.
  onOpenFullView?: (title: string) => void;
};

// Re-exported for the App.tsx wiring — keeping the type alongside the
// kind-aware click signature lets callers route by node.kind without
// reaching into the shared graph lib.
export type { NodeRow } from "../lib/graph";

export function MiniGraph(props: MiniProps) {
  const [slice, setSlice] = createSignal<GraphSlice>({ nodes: [], edges: [] });
  const [size, setSize] = createSignal({ w: 280, h: 200 });
  const [selectedKey, setSelectedKey] = createSignal<string | null>(null);
  let host: HTMLDivElement | undefined;
  let resizeObs: ResizeObserver | null = null;
  let unlistenVault: (() => void) | null = null;
  let lastTitle: string | null = null;
  let cameraRef: GraphCamera | null = null;

  async function refresh(title: string) {
    if (!title) return;
    const next = await loadNeighbors(props.workspaceId, title, 40);
    setSlice(next ?? { nodes: [], edges: [] });
  }

  const focusKey = createMemo(() => {
    const t = props.focusTitle;
    const match = slice().nodes.find((n) => n.label === t);
    return match ? nodeKey(match.id) : null;
  });

  onMount(async () => {
    if (host) {
      const update = () => {
        if (!host) return;
        const r = host.getBoundingClientRect();
        setSize({
          w: Math.max(220, r.width),
          h: Math.max(180, r.height),
        });
      };
      update();
      resizeObs = new ResizeObserver(update);
      resizeObs.observe(host);
    }
    unlistenVault = await listen("vault:updated", () => {
      if (lastTitle) void refresh(lastTitle);
    });
  });

  createEffect(() => {
    const t = props.focusTitle;
    lastTitle = t;
    setSelectedKey(null);
    void refresh(t);
  });

  onCleanup(() => {
    resizeObs?.disconnect();
    if (unlistenVault) unlistenVault();
  });

  return (
    <div class="relative">
      <div class="mb-2 flex items-center justify-between">
        <span class="section-label">Graph · 1-hop</span>
        <div class="flex items-center gap-0.5">
          <button
            type="button"
            class="control-icon flex size-6"
            title="Fit"
            onClick={() => cameraRef?.resetView()}
          >
            <Minimize size={11} strokeWidth={2.2} />
          </button>
          <Show when={props.onOpenFullView}>
            <button
              type="button"
              class="control-icon flex size-6"
              title="Open in graph view"
              onClick={() => props.onOpenFullView!(props.focusTitle)}
            >
              <Maximize size={11} strokeWidth={2.2} />
            </button>
          </Show>
        </div>
      </div>
      <div
        ref={(el) => (host = el)}
        class="relative w-full overflow-hidden rounded-md border border-border bg-bg-panel"
        style={{ height: "200px" }}
      >
        <Show
          when={slice().nodes.length > 1}
          fallback={
            <div class="flex h-full items-center justify-center">
              <p class="empty-state text-center text-[11px] leading-snug">
                no links yet — write{" "}
                <code class="text-text-muted">[[wikilinks]]</code> in this note
                to grow the graph.
              </p>
            </div>
          }
        >
          <GraphCanvas
            slice={slice()}
            focusKey={focusKey()}
            selectedKey={selectedKey()}
            onSelectionChange={setSelectedKey}
            width={size().w}
            height={size().h}
            onNodeClick={(_label, key) => {
              const n = slice().nodes.find((nn) => nodeKey(nn.id) === key);
              if (n) props.onNodeClick(n);
            }}
            onCameraReady={(cam) => (cameraRef = cam)}
          />
          <button
            type="button"
            class="absolute bottom-1.5 right-1.5 control-icon size-6"
            title="Reset view"
            onClick={() => cameraRef?.resetView()}
          >
            <RotateCcw size={10} strokeWidth={2.2} />
          </button>
        </Show>
      </div>
    </div>
  );
}
