import { invoke } from "@tauri-apps/api/core";

// Mirrors src-tauri/src/graph.rs::EDGE_KINDS. Adding a kind requires
// both the Rust enum and the SurrealDB ASSERT — UI just renders.
export const EDGE_KINDS = [
  "mentions",
  "references",
  "about",
  "attended",
  "attached",
  "derived_from",
  "replied_to",
  "child_of",
  "alias_of",
] as const;

export type EdgeKind = (typeof EDGE_KINDS)[number];

export type EdgeRow = {
  from_node: unknown;
  to_node: unknown;
  kind: EdgeKind;
  context: string | null;
  created_by: string;
  created_at: string;
};

export type NodeRow = {
  id: unknown;
  kind: string;
  label: string;
  source_kind: string | null;
  updated_at: string | null;
};

export type GraphSlice = {
  nodes: NodeRow[];
  edges: EdgeRow[];
};

export function nodeKey(id: unknown): string {
  // SurrealDB Thing values come over IPC either as a structured
  // {tb, id} object or as a stringified "tb:id". We collapse to a
  // stable key so the canvas can use it as a map id without
  // worrying about the wire shape drifting.
  if (typeof id === "string") return id;
  if (id && typeof id === "object") {
    const obj = id as { tb?: string; id?: unknown };
    if (obj.tb && obj.id !== undefined) {
      const inner =
        typeof obj.id === "string" ? obj.id : JSON.stringify(obj.id);
      return `${obj.tb}:${inner}`;
    }
  }
  return JSON.stringify(id);
}

export async function loadGraphView(
  workspaceId: unknown,
  limit = 500,
): Promise<GraphSlice> {
  return invoke<GraphSlice>("graph_view_query", {
    workspaceId,
    limit,
  });
}

export async function loadNeighbors(
  workspaceId: unknown,
  title: string,
  limit = 40,
): Promise<GraphSlice | null> {
  return invoke<GraphSlice | null>("graph_neighbors_for_note", {
    workspaceId,
    title,
    limit,
  });
}

export async function searchGraph(
  workspaceId: unknown,
  query: string,
  limit = 20,
): Promise<GraphSlice> {
  return invoke<GraphSlice>("graph_search", {
    workspaceId,
    query,
    limit,
  });
}

export async function relate(
  workspaceId: unknown,
  fromTitle: string,
  toTitle: string,
  kind: EdgeKind = "references",
  context?: string,
): Promise<void> {
  await invoke<void>("graph_relate", {
    workspaceId,
    fromTitle,
    toTitle,
    kind,
    context: context ?? null,
  });
}

export async function unrelate(
  workspaceId: unknown,
  fromTitle: string,
  toTitle: string,
  kind?: EdgeKind,
): Promise<void> {
  await invoke<void>("graph_unrelate", {
    workspaceId,
    fromTitle,
    toTitle,
    kind: kind ?? null,
  });
}

export const GRAPH_ENABLED_KEY = "clome.graph.enabled";
