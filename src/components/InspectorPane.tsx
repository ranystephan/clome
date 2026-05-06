import { createSignal, createEffect, For, Show, onCleanup } from "solid-js";
import { invoke } from "@tauri-apps/api/core";
import {
  X,
  Pencil,
  Eye,
  ExternalLink,
  Maximize2,
  Minimize2,
  ChevronDown,
  ChevronRight,
  Trash2,
} from "lucide-solid";
import MarkdownContent from "./MarkdownContent";
import NoteEditor from "./NoteEditor";
import { SourceChip, SourceDot } from "./SourceBadge";
import { MiniGraph } from "./GraphView";
import type { NodeRow } from "../lib/graph";

type Note = {
  title: string;
  body: string;
  source_kind: string;
  source_url: string | null;
  last_edited_by: string;
  created_at: string;
  updated_at: string;
};

type NoteRef = { title: string; source_kind: string };
type MessageRef = { role: string; content: string; created_at: string };
type NoteEdit = { by: string; ts: string; diff: string };

type InspectorData = {
  note: Note;
  backlinks_notes: NoteRef[];
  backlinks_messages: MessageRef[];
  edits: NoteEdit[];
};

type Props = {
  title: string | null;
  mode: "side" | "page";
  workspaceId: unknown | null;
  // Pixel width applied in side mode. Page mode ignores this and goes
  // flex-1. Owner controls the value (drag/persistence) and gives us
  // the start handler to wire to the resize grip.
  width: number;
  // Settings flag controlling whether the mini-graph block renders.
  // Off by default; on when the user enables Graph view in settings.
  showMiniGraph: boolean;
  // Optional jumper to the full-page graph tab. When provided, the
  // mini-graph shows a "maximize" button that hands the current note
  // up so the parent can switch tabs / focus.
  onOpenGraph?: () => void;
  // Kind-aware router. The mini-graph can surface email_thread
  // nodes once Slice B's shadow rows exist; routing those to the
  // mail tab vs. notes to the inspector lives in App.tsx.
  onOpenGraphNode?: (node: NodeRow) => void;
  onResizeStart: (e: MouseEvent) => void;
  onClose: () => void;
  onToggleMode: () => void;
  onWikilinkClick: (title: string) => void;
  onDelete: (title: string) => void;
  onRename: (oldTitle: string, newTitle: string) => Promise<void> | void;
};

type SaveStatus = "idle" | "saving" | "saved" | "error";
const SAVE_DEBOUNCE_MS = 600;

function fmtTs(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

function snippetAround(text: string, needle: string, span = 60): string {
  const idx = text.indexOf(needle);
  if (idx < 0) return text.slice(0, span * 2);
  const start = Math.max(0, idx - span);
  const end = Math.min(text.length, idx + needle.length + span);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < text.length ? "…" : "";
  return prefix + text.slice(start, end) + suffix;
}

function SectionHeader(props: { children: any }) {
  return (
    <h3 class="section-label mb-2">
      {props.children}
    </h3>
  );
}

function CollapsibleHeader(props: {
  expanded: boolean;
  onToggle: () => void;
  label: string;
  count?: number;
}) {
  return (
    <button
      type="button"
      onClick={props.onToggle}
      class="control-ghost -ml-1 mb-2 flex items-center gap-1 px-1 py-0.5"
    >
      <Show
        when={props.expanded}
        fallback={<ChevronRight size={11} strokeWidth={2.5} />}
      >
        <ChevronDown size={11} strokeWidth={2.5} />
      </Show>
      <span>{props.label}</span>
      <Show when={props.count != null}>
        <span class="font-mono text-[10px] tabular-nums text-text-subtle/80">
          {props.count}
        </span>
      </Show>
    </button>
  );
}

export default function InspectorPane(props: Props) {
  const [data, setData] = createSignal<InspectorData | null>(null);
  const [loading, setLoading] = createSignal(false);
  const [editing, setEditing] = createSignal(false);
  const [draft, setDraft] = createSignal("");
  const [saveStatus, setSaveStatus] = createSignal<SaveStatus>("idle");
  // Bumped each time the user actively switches notes — used as a remount key
  // so NoteEditor reinitializes its internal CodeMirror buffer.
  const [editorKey, setEditorKey] = createSignal(0);
  // Collapsible sections — start collapsed for the secondary panels so the
  // inspector opens focused on body. Reset per inspected note.
  const [openLinks, setOpenLinks] = createSignal(false);
  const [openMentions, setOpenMentions] = createSignal(false);
  const [openHistory, setOpenHistory] = createSignal(false);
  // Title rename state
  const [editingTitle, setEditingTitle] = createSignal(false);
  const [titleDraft, setTitleDraft] = createSignal("");

  function startTitleEdit() {
    if (props.title === null) return;
    setTitleDraft(props.title);
    setEditingTitle(true);
  }
  async function commitTitleEdit() {
    const t = props.title;
    if (t === null) {
      setEditingTitle(false);
      return;
    }
    const next = titleDraft().trim();
    setEditingTitle(false);
    if (!next || next === t) return;
    await props.onRename(t, next);
  }

  let saveTimer: ReturnType<typeof setTimeout> | null = null;
  let lastSavedBody = "";
  let saveSeq = 0;

  function clearSaveTimer() {
    if (saveTimer !== null) {
      clearTimeout(saveTimer);
      saveTimer = null;
    }
  }

  createEffect(async () => {
    const t = props.title;
    const ws = props.workspaceId;
    clearSaveTimer();
    if (t === null || ws === null) {
      setData(null);
      setEditing(false);
      setDraft("");
      lastSavedBody = "";
      setSaveStatus("idle");
      return;
    }
    setLoading(true);
    try {
      const res = await invoke<InspectorData | null>("inspect_note", {
        workspaceId: ws,
        title: t,
      });
      setData(res);
      const body = res?.note.body ?? "";
      setDraft(body);
      lastSavedBody = body;
      setEditing(false);
      setSaveStatus("idle");
      setEditorKey((k) => k + 1);
      setOpenLinks(false);
      setOpenMentions(false);
      setOpenHistory(false);
      setEditingTitle(false);
    } catch (e) {
      console.error("inspect_note failed:", e);
      setData(null);
    } finally {
      setLoading(false);
    }
  });

  onCleanup(clearSaveTimer);

  async function flushSave() {
    const t = props.title;
    const ws = props.workspaceId;
    if (t === null || ws === null) return;
    const body = draft();
    if (body === lastSavedBody) {
      setSaveStatus("saved");
      return;
    }
    const seq = ++saveSeq;
    setSaveStatus("saving");
    try {
      await invoke("update_note_body", { workspaceId: ws, title: t, body });
      // Avoid clobbering newer typing with a stale refetch result.
      if (seq !== saveSeq) return;
      const res = await invoke<InspectorData | null>("inspect_note", {
        workspaceId: ws,
        title: t,
      });
      if (seq !== saveSeq) return;
      setData(res);
      lastSavedBody = body;
      setSaveStatus("saved");
    } catch (e) {
      console.error("auto-save failed:", e);
      setSaveStatus("error");
    }
  }

  function handleEdit(text: string) {
    setDraft(text);
    if (text === lastSavedBody) {
      setSaveStatus("saved");
      return;
    }
    setSaveStatus("saving");
    clearSaveTimer();
    saveTimer = setTimeout(() => {
      saveTimer = null;
      void flushSave();
    }, SAVE_DEBOUNCE_MS);
  }

  function toggleEditing() {
    if (editing()) {
      // leaving edit mode — flush any pending save immediately
      clearSaveTimer();
      void flushSave();
      setEditing(false);
    } else {
      setEditing(true);
    }
  }

  async function createGhost() {
    const t = props.title;
    const ws = props.workspaceId;
    if (t === null || ws === null) return;
    try {
      await invoke("create_note", { workspaceId: ws, title: t, sourceKind: "manual" });
      const res = await invoke<InspectorData | null>("inspect_note", {
        workspaceId: ws,
        title: t,
      });
      setData(res);
      const body = res?.note.body ?? "";
      setDraft(body);
      lastSavedBody = body;
      setEditorKey((k) => k + 1);
    } catch (e) {
      console.error("create_note failed:", e);
    }
  }

  const isPage = () => props.mode === "page";

  // Word count + estimated read time (220 wpm — average adult reading
  // pace for screen text). Reads from `draft` so it updates live while
  // the user types in the editor.
  const wordCount = () => {
    const body = draft() || data()?.note.body || "";
    if (!body.trim()) return 0;
    return body.trim().split(/\s+/).length;
  };
  const readMin = () => Math.max(1, Math.ceil(wordCount() / 220));

  function statusLabel(): string {
    switch (saveStatus()) {
      case "saving":
        return "saving…";
      case "saved":
        return "saved";
      case "error":
        return "save failed";
      default:
        return "";
    }
  }

  return (
    <Show when={props.title !== null}>
      <aside
        class="inspector-pane relative flex flex-col bg-bg"
        classList={{
          // Side rail: fixed width, never shrinks below.
          "shrink-0 border-l border-border": !isPage(),
          // Page tab: fill the column AND allow flex children below
          // (the body scroller) to shrink under the parent — without
          // `min-h-0` the inner `overflow-y-auto` div hugs content
          // and never scrolls.
          "flex-1 min-h-0 min-w-0": isPage(),
        }}
        style={!isPage() ? { width: `${props.width}px` } : undefined}
      >
        {/* Resize grip on the LEFT edge — only in side mode. 6px hit
            area, 1px visible line that brightens on hover/active. Mirror
            of the sidebar's right-edge handle in App.tsx. */}
        <Show when={!isPage()}>
          <div
            onMouseDown={props.onResizeStart}
            class="group/inspresize absolute -left-[3px] top-0 z-20 h-full w-[6px] cursor-col-resize select-none"
          >
            <div class="absolute inset-y-0 left-[2px] w-px bg-accent/0 transition-colors group-hover/inspresize:bg-accent/50" />
          </div>
        </Show>
        <header
          class="flex items-start justify-between gap-3"
          classList={{
            "border-b border-border px-6 py-5": !isPage(),
            "px-16 pb-2 pt-10": isPage(),
          }}
        >
          <div
            class="min-w-0 flex-1"
            classList={{
              "max-w-[760px]": isPage(),
            }}
          >
            <Show
              when={editingTitle()}
              fallback={
                <h2
                  class="control-ghost -mx-1 truncate px-1 font-semibold text-text cursor-text"
                  classList={{
                    "text-[15px]": !isPage(),
                    "text-[30px] leading-tight tracking-tight": isPage(),
                  }}
                  onDblClick={startTitleEdit}
                  title="Double-click to rename"
                >
                  {props.title}
                </h2>
              }
            >
              <input
                value={titleDraft()}
                onInput={(e) => setTitleDraft(e.currentTarget.value)}
                onBlur={commitTitleEdit}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    void commitTitleEdit();
                  } else if (e.key === "Escape") {
                    e.preventDefault();
                    setEditingTitle(false);
                  }
                }}
                ref={(el) => queueMicrotask(() => el?.focus())}
                class="input-pill -mx-1 w-full px-1 font-semibold text-text"
                classList={{
                  "text-[15px]": !isPage(),
                  "text-[30px] leading-tight": isPage(),
                }}
              />
            </Show>
            <Show when={data()}>
              <div
                class="flex flex-wrap items-center gap-x-2.5 gap-y-1"
                classList={{
                  "mt-1.5": !isPage(),
                  "mt-3": isPage(),
                }}
              >
                <SourceChip kind={data()!.note.source_kind} />
                <span class="text-[11px] text-text-dim">
                  edited {fmtTs(data()!.note.updated_at)} by {data()!.note.last_edited_by}
                </span>
                <Show when={isPage() && wordCount() > 0}>
                  <span class="text-text-subtle">·</span>
                  <span class="text-[11px] tabular-nums text-text-dim">
                    {wordCount().toLocaleString()} words · {readMin()} min
                  </span>
                </Show>
                <Show when={isPage() && statusLabel()}>
                  <span class="text-text-subtle">·</span>
                  <span
                    class="text-[11px] tabular-nums"
                    classList={{
                      "text-text-subtle":
                        saveStatus() === "saved" || saveStatus() === "saving",
                      "text-danger": saveStatus() === "error",
                    }}
                  >
                    {statusLabel()}
                  </span>
                </Show>
              </div>
            </Show>
          </div>
          <div class="flex items-center gap-0.5">
            <Show when={data()}>
              <button
                type="button"
                class="control-icon p-1.5"
                onClick={toggleEditing}
                title={editing() ? "View rendered" : "Edit"}
              >
                <Show when={editing()} fallback={<Pencil size={14} strokeWidth={2} />}>
                  <Eye size={14} strokeWidth={2} />
                </Show>
              </button>
              <button
                type="button"
                class="control-icon p-1.5 hover:text-danger"
                onClick={() => {
                  const t = props.title;
                  if (t !== null) props.onDelete(t);
                }}
                title="Delete note"
              >
                <Trash2 size={14} strokeWidth={2} />
              </button>
            </Show>
            <button
              type="button"
              class="control-icon p-1.5"
              onClick={props.onToggleMode}
              title={isPage() ? "Show as side panel" : "Open as page"}
            >
              <Show when={isPage()} fallback={<Maximize2 size={14} strokeWidth={2} />}>
                <Minimize2 size={14} strokeWidth={2} />
              </Show>
            </button>
            <button
              type="button"
              class="control-icon p-1.5"
              onClick={props.onClose}
              title="Close"
            >
              <X size={15} strokeWidth={2} />
            </button>
          </div>
        </header>

        <div class="flex-1 min-h-0 overflow-y-auto">
          <Show when={loading()}>
            <p class="empty-state px-6 py-6 text-left">loading…</p>
          </Show>

          <Show when={!loading() && data() === null}>
            <div
              classList={{
                "px-6 py-6": !isPage(),
                "mx-auto max-w-[760px] px-16 py-12": isPage(),
              }}
            >
              <p
                class="empty-state text-left"
                classList={{
                  "text-[14px]": isPage(),
                }}
              >
                this note doesn't exist yet.
              </p>
              <button
                type="button"
                onClick={createGhost}
                class="btn-soft btn-soft--sm btn-soft--primary mt-3"
              >
                create note
              </button>
            </div>
          </Show>

          <Show when={!loading() && data()}>
            {/* body */}
            <section
              classList={{
                "border-b border-border px-6 py-5": !isPage(),
                "mx-auto w-full max-w-[760px] px-16 pb-10 pt-6": isPage(),
              }}
            >
              <Show when={!isPage()}>
                <div class="mb-2 flex items-center justify-between">
                  <SectionHeader>Body</SectionHeader>
                  <div class="flex items-center gap-2">
                    <Show when={wordCount() > 0}>
                      <span class="text-[10px] tabular-nums text-text-subtle">
                        {wordCount().toLocaleString()} words · {readMin()} min
                      </span>
                    </Show>
                    <Show when={statusLabel()}>
                      <span
                        class="text-[10px] tabular-nums"
                        classList={{
                          "text-text-subtle":
                            saveStatus() === "saved" ||
                            saveStatus() === "saving",
                          "text-danger": saveStatus() === "error",
                        }}
                      >
                        {statusLabel()}
                      </span>
                    </Show>
                  </div>
                </div>
              </Show>
              <div
                classList={{
                  "note-page-body": isPage(),
                }}
              >
                <Show
                  when={editing()}
                  fallback={
                    <Show
                      when={(draft() || data()!.note.body).trim().length > 0}
                      fallback={
                        <p
                          class="empty-state text-left italic"
                          classList={{
                            "text-[14px]": isPage(),
                          }}
                        >
                          empty. click the pencil icon to add content.
                        </p>
                      }
                    >
                      <MarkdownContent
                        text={draft() || data()!.note.body}
                        onWikilinkClick={props.onWikilinkClick}
                      />
                    </Show>
                  }
                >
                  {/* Remount key forces a fresh editor when the inspected note
                      changes, so we never accidentally bind one note's CM
                      state to another's title. */}
                  <Show when={editorKey() >= 0} keyed>
                    <div data-editor-key={editorKey()}>
                      <NoteEditor
                        initialValue={draft()}
                        onChange={handleEdit}
                        autofocus
                        onEscape={() => toggleEditing()}
                      />
                    </div>
                  </Show>
                </Show>
              </div>
            </section>

            {/* source */}
            <Show when={data()!.note.source_url}>
              <section
                classList={{
                  "border-b border-border px-6 py-5": !isPage(),
                  "mx-auto w-full max-w-[760px] border-t border-border/60 px-16 py-5": isPage(),
                }}
              >
                <SectionHeader>Source</SectionHeader>
                <a
                  href={data()!.note.source_url!}
                  target="_blank"
                  rel="noopener"
                  class="flex items-center gap-1.5 truncate text-[12px] text-accent hover:underline"
                >
                  <ExternalLink size={11} strokeWidth={2} />
                  <span class="truncate">{data()!.note.source_url}</span>
                </a>
              </section>
            </Show>

            {/* connections band — page mode renders graph + backlinks
                + history in the writing column with soft dividers, so
                the eye lands on body first and explores below. Side
                mode keeps the original tight stack. */}
            <Show
              when={
                isPage() &&
                (data()!.backlinks_notes.length > 0 ||
                  data()!.backlinks_messages.length > 0 ||
                  data()!.edits.length > 0 ||
                  (props.showMiniGraph && props.workspaceId !== null))
              }
            >
              <div class="mx-auto w-full max-w-[760px] border-t border-border/60 px-16 py-8">
                <div class="grid gap-8 md:grid-cols-2">
                  <Show
                    when={
                      props.showMiniGraph &&
                      props.workspaceId !== null &&
                      props.title !== null
                    }
                  >
                    <div class="md:col-span-2">
                      <MiniGraph
                        workspaceId={props.workspaceId}
                        focusTitle={props.title!}
                        onNodeClick={(node) => {
                          if (props.onOpenGraphNode) {
                            props.onOpenGraphNode(node);
                          } else if (node.kind === "note") {
                            props.onWikilinkClick(node.label);
                          }
                        }}
                        onOpenFullView={
                          props.onOpenGraph
                            ? () => props.onOpenGraph!()
                            : undefined
                        }
                      />
                    </div>
                  </Show>

                  <Show when={data()!.backlinks_notes.length > 0}>
                    <div>
                      <SectionHeader>
                        Linked from notes · {data()!.backlinks_notes.length}
                      </SectionHeader>
                      <ul class="-mx-1.5 mt-1.5 space-y-0.5">
                        <For each={data()!.backlinks_notes}>
                          {(n) => (
                            <li>
                              <button
                                type="button"
                                onClick={() => props.onWikilinkClick(n.title)}
                                class="list-row flex w-full items-center gap-2.5 px-1.5 py-1 text-left"
                              >
                                <SourceDot kind={n.source_kind} />
                                <span class="truncate text-[13px] text-text">
                                  {n.title}
                                </span>
                              </button>
                            </li>
                          )}
                        </For>
                      </ul>
                    </div>
                  </Show>

                  <Show when={data()!.backlinks_messages.length > 0}>
                    <div>
                      <SectionHeader>
                        Mentioned in chat · {data()!.backlinks_messages.length}
                      </SectionHeader>
                      <ul class="mt-1.5 space-y-2">
                        <For each={data()!.backlinks_messages.slice(0, 6)}>
                          {(m) => (
                            <li class="surface-raised rounded-lg px-2.5 py-2">
                              <div class="flex items-center gap-1.5 text-[10px] uppercase tracking-wide text-text-dim">
                                <span class="font-medium">{m.role}</span>
                                <span class="text-text-subtle">·</span>
                                <span class="normal-case tracking-normal">
                                  {fmtTs(m.created_at)}
                                </span>
                              </div>
                              <p class="mt-1 line-clamp-2 text-[12px] text-text">
                                {snippetAround(
                                  m.content,
                                  `[[${props.title}]]`,
                                  50,
                                )}
                              </p>
                            </li>
                          )}
                        </For>
                      </ul>
                    </div>
                  </Show>

                  <Show when={data()!.edits.length > 0}>
                    <div class="md:col-span-2">
                      <CollapsibleHeader
                        expanded={openHistory()}
                        onToggle={() => setOpenHistory((v) => !v)}
                        label="History"
                        count={data()!.edits.length}
                      />
                      <Show when={openHistory()}>
                        <ul class="mt-1 space-y-1">
                          <For each={data()!.edits.slice(0, 10)}>
                            {(e) => (
                              <li class="flex flex-wrap items-baseline gap-x-1.5 text-[11px] text-text-dim">
                                <span class="tabular-nums text-text-subtle">
                                  {fmtTs(e.ts)}
                                </span>
                                <span class="text-text-subtle">·</span>
                                <span class="text-text-muted">{e.by}</span>
                                <span class="text-text-subtle">·</span>
                                <span>{e.diff}</span>
                              </li>
                            )}
                          </For>
                        </ul>
                      </Show>
                    </div>
                  </Show>
                </div>
              </div>
            </Show>

            {/* Side-mode: original tight stack of secondary panels. */}
            <Show when={!isPage()}>
              <Show when={data()!.backlinks_notes.length > 0}>
                <section class="border-b border-border px-6 py-4">
                  <CollapsibleHeader
                    expanded={openLinks()}
                    onToggle={() => setOpenLinks((v) => !v)}
                    label="Linked from notes"
                    count={data()!.backlinks_notes.length}
                  />
                  <Show when={openLinks()}>
                    <ul class="-mx-1.5 mt-1 space-y-0.5">
                      <For each={data()!.backlinks_notes}>
                        {(n) => (
                          <li>
                            <button
                              type="button"
                              onClick={() => props.onWikilinkClick(n.title)}
                              class="list-row flex w-full items-center gap-2.5 px-1.5 py-1 text-left"
                            >
                              <SourceDot kind={n.source_kind} />
                              <span class="truncate text-[13px] text-text">
                                {n.title}
                              </span>
                            </button>
                          </li>
                        )}
                      </For>
                    </ul>
                  </Show>
                </section>
              </Show>

              <Show when={data()!.backlinks_messages.length > 0}>
                <section class="border-b border-border px-6 py-4">
                  <CollapsibleHeader
                    expanded={openMentions()}
                    onToggle={() => setOpenMentions((v) => !v)}
                    label="Mentioned in chat"
                    count={data()!.backlinks_messages.length}
                  />
                  <Show when={openMentions()}>
                    <ul class="space-y-2">
                      <For each={data()!.backlinks_messages.slice(0, 8)}>
                        {(m) => (
                          <li class="surface-raised rounded-lg px-2.5 py-2">
                            <div class="flex items-center gap-1.5 text-[10px] uppercase tracking-wide text-text-dim">
                              <span class="font-medium">{m.role}</span>
                              <span class="text-text-subtle">·</span>
                              <span class="normal-case tracking-normal">
                                {fmtTs(m.created_at)}
                              </span>
                            </div>
                            <p class="mt-1 line-clamp-2 text-[12px] text-text">
                              {snippetAround(
                                m.content,
                                `[[${props.title}]]`,
                                50,
                              )}
                            </p>
                          </li>
                        )}
                      </For>
                    </ul>
                  </Show>
                </section>
              </Show>

              <Show
                when={
                  props.showMiniGraph &&
                  props.workspaceId !== null &&
                  props.title !== null
                }
              >
                <section class="border-b border-border px-6 py-4">
                  <MiniGraph
                    workspaceId={props.workspaceId}
                    focusTitle={props.title!}
                    onNodeClick={(node) => {
                      if (props.onOpenGraphNode) {
                        props.onOpenGraphNode(node);
                      } else if (node.kind === "note") {
                        props.onWikilinkClick(node.label);
                      }
                    }}
                    onOpenFullView={
                      props.onOpenGraph ? () => props.onOpenGraph!() : undefined
                    }
                  />
                </section>
              </Show>

              <Show when={data()!.edits.length > 0}>
                <section class="px-6 py-4">
                  <CollapsibleHeader
                    expanded={openHistory()}
                    onToggle={() => setOpenHistory((v) => !v)}
                    label="History"
                    count={data()!.edits.length}
                  />
                  <Show when={openHistory()}>
                    <ul class="space-y-1">
                      <For each={data()!.edits.slice(0, 10)}>
                        {(e) => (
                          <li class="flex flex-wrap items-baseline gap-x-1.5 text-[11px] text-text-dim">
                            <span class="tabular-nums text-text-subtle">
                              {fmtTs(e.ts)}
                            </span>
                            <span class="text-text-subtle">·</span>
                            <span class="text-text-muted">{e.by}</span>
                            <span class="text-text-subtle">·</span>
                            <span>{e.diff}</span>
                          </li>
                        )}
                      </For>
                    </ul>
                  </Show>
                </section>
              </Show>
            </Show>
          </Show>
        </div>
      </aside>
    </Show>
  );
}
