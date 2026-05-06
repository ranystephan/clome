import {
  createSignal,
  createMemo,
  createEffect,
  For,
  Show,
  Switch,
  Match,
  onMount,
  onCleanup,
  untrack,
} from "solid-js";
import { createStore, produce } from "solid-js/store";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import {
  PanelLeft,
  PanelLeftClose,
  Plus,
  Search,
  ChevronDown,
  ChevronRight,
  ArrowUp,
  ArrowDown,
  Trash2,
  Pencil,
  X,
  Settings,
  Terminal,
  Copy,
  Check,
  Square,
  SquarePen,
  MessageSquare,
  Hash,
  Zap,
  Columns2,
  Rows2,
  FileText,
  Bot,
  Gauge,
  Route,
  Sparkles,
  Users,
  Eye,
  Wrench,
  Mail,
  Network,
  Folder as FolderIcon,
  FolderOpen,
  FolderPlus,
  ArrowUpDown,
} from "lucide-solid";
// Phase 2 swap: the new native mail client. Legacy MailView (Mail.app
// reader) stays around as `./components/MailView` until the native
// path reaches parity (Phase 7 cutover).
import MailView from "./components/MailApp";
import MentionDropdown, { type MentionItem } from "./components/MentionDropdown";
import MessageContent from "./components/MessageContent";
import InspectorPane from "./components/InspectorPane";
import GraphView from "./components/GraphView";
import CaptureModal from "./components/CaptureModal";
import SearchPalette from "./components/SearchPalette";
import AgentsModal from "./components/AgentsModal";
import NativeTerminalHost from "./components/NativeTerminalHost";
import { SourceDot } from "./components/SourceBadge";
import { extractLinkTitles } from "./lib/wikilinks";
import { sourceLabel } from "./lib/sources";
import hljsDarkUrl from "highlight.js/styles/github-dark.min.css?url";
import hljsLightUrl from "highlight.js/styles/github.min.css?url";
import "./App.css";

const HLJS_LINK_ID = "clome-hljs-theme";

async function swapHljsTheme(resolved: "light" | "dark") {
  const url = resolved === "light" ? hljsLightUrl : hljsDarkUrl;
  let link = document.getElementById(HLJS_LINK_ID) as HTMLLinkElement | null;
  if (!link) {
    link = document.createElement("link");
    link.id = HLJS_LINK_ID;
    link.rel = "stylesheet";
    document.head.appendChild(link);
  }
  if (link.href.endsWith(url)) return;
  link.href = url;
}

type MsgStatus = "streaming" | "done" | "error";
type ToolResult = {
  index: number;
  action: string;
  headers: Record<string, unknown> | null;
  result: unknown;
};
type PromptMessage = { role: "user" | "assistant"; content: string };
type Message = {
  id: number;
  role: "user" | "agent";
  text: string;
  status?: MsgStatus;
  turnPlan?: TurnPlan;
  // SurrealDB message id for hydrated rows. New (streaming) turns have
  // no DB id yet — they get one server-side after stream completes.
  dbId?: unknown;
  // True between chat:tool_start and chat:tool_end — drives the
  // chip "running" pulse and the floating "running …" pill.
  toolRunning?: boolean;
  // Last action name received from chat:tool_start. Shown in the pill
  // (e.g. "running list_events…").
  toolAction?: string;
  // Target of the running tool — note title, search query, thread id,
  // etc. — so the pill can read as "searching graph for 'Acme'"
  // instead of the bare action name.
  toolTarget?: string;
  toolSecondary?: string;
  // Phase machine: which "stage" of the agent loop we're currently
  // in. Drives the live status strip at the top of the bubble so the
  // user sees a real label + timer ("thinking · 8s") instead of an
  // opaque three-dot animation.
  //   - "thinking" : pre-first-token wait OR between iter results
  //                  and the next iter's first token. No streaming.
  //   - "writing"  : tokens currently arriving — bubble fills live.
  //   - "tool"     : a sidecar / tauri tool is executing.
  phase?: "thinking" | "writing" | "tool";
  phaseStartedAt?: number;
  // Per-tool-call results, in emission order. MarkdownContent uses
  // these to swap each .tool-chip in the rendered message with a
  // rich inline card (event list, reminder list, scheduled card etc).
  toolResults?: ToolResult[];
};

type Note = {
  title: string;
  body: string;
  source_kind: string;
  source_url: string | null;
  last_edited_by: string;
  created_at: string;
  updated_at: string;
  // Optional folder membership. null = unfiled (rendered under
  // "Unfiled" in the sidebar). The Rust side carries this back as an
  // opaque Thing; comparison is done via JSON.stringify (same pattern
  // we use for ChatId / WorkspaceId).
  folder?: unknown | null;
};

type Folder = {
  id: unknown;
  name: string;
  color: string | null;
  created_at: string;
};

type NoteSortMode = "recency" | "alphabetical";

// SurrealDB Thing comes back as an opaque JSON object. Frontend treats it
// as a black box and round-trips it back to Rust verbatim.
type ChatId = unknown;
type WorkspaceId = unknown;

type AgentId = unknown;
type Chat = {
  id: ChatId;
  title: string;
  created_at: string;
  agent: AgentId | null;
  // Group chats: list of agents bound to this chat. The legacy `agent`
  // field stays in sync with `agents[0]` server-side; new code reads
  // from `agents`.
  agents?: AgentId[];
};

type Workspace = {
  id: WorkspaceId;
  name: string;
  created_at: string;
};

type TerminalPane = {
  id: string;
  title: string;
  cwd: string | null;
};

type TerminalLayout =
  | { kind: "pane"; paneId: string }
  | {
      kind: "split";
      direction: "row" | "column";
      ratio: number;
      first: TerminalLayout;
      second: TerminalLayout;
    };

type TerminalSession = {
  id: string;
  kind: "terminal";
  title: string;
  cwd: string | null;
  panes: TerminalPane[];
  activePaneId: string;
  layout: TerminalLayout;
};

type WorkspaceTab =
  | { id: string; kind: "chat"; title: string; chatId: ChatId }
  | TerminalSession
  | { id: string; kind: "note"; title: string; noteTitle: string }
  | { id: string; kind: "mail"; title: string }
  | { id: string; kind: "graph"; title: string };

type TerminalMeta = {
  tabId: string;
  title: string | null;
  displayTitle: string;
  cwd: string | null;
  pathLabel: string | null;
  git: { branch: string; dirty: boolean; repoRoot: string } | null;
  running: boolean;
  exitCode: number | null;
  durationMs: number | null;
};

type TerminalWorkspaceState = {
  sessions: TerminalSession[];
  openIds: string[];
  activeId: string | null;
};

type Agent = {
  id: AgentId;
  name: string;
  system_prompt: string;
  model: string;
  capabilities: string[];
};

type StoredMessage = {
  id: ChatId;
  role: string;
  content: string;
  created_at: string;
  tool_results?: ToolResult[] | null;
};

type ComputeMode = "fast" | "balanced" | "deep";

type TurnPlanKind = "single" | "direct" | "lead-synthesis" | "deep-review";

type TurnPlan = {
  kind: TurnPlanKind;
  compute: ComputeMode;
  speakerName: string;
  speakerModel: string;
  effectiveModel: string;
  modelWarning?: string;
  agentOverride: AgentId | null;
  reason: string;
  steps: string[];
  groupSize: number;
};

type MlxModelStatus = {
  server_reachable: boolean;
  available: boolean;
  models: string[];
};

type ModelReadiness =
  | { state: "checking" }
  | { state: "ready" }
  | { state: "missing"; fallbackReady: boolean }
  | { state: "offline" };

type AppResourceUsage = {
  appCpuPercent: number;
  appMemoryBytes: number;
  modelCpuPercent: number;
  modelMemoryBytes: number;
  modelProcessCount: number;
  totalCpuPercent: number;
  totalMemoryBytes: number;
  sampledAtMs: number;
};

type ActivityKind = "tool_call" | "vault_read";
type ActivityItem = {
  ts: string;
  kind: ActivityKind;
  agent: string;
  // tool_call:
  action?: string;
  target?: string;
  secondary?: string | null;
  // vault_read:
  count?: number;
  titles?: string[];
};

const ACTION_VERB: Record<string, string> = {
  create_note: "created",
  append_to_note: "appended to",
  edit_note: "edited",
  replace_note_body: "rewrote",
  delete_note: "deleted",
  relate: "related",
  graph_search: "searched graph for",
  graph_neighbors: "explored graph from",
};
const ACTION_ICON: Record<string, string> = {
  create_note: "✎",
  append_to_note: "+",
  edit_note: "⟲",
  replace_note_body: "✱",
  delete_note: "✗",
  relate: "↗",
  graph_search: "⌕",
  graph_neighbors: "◌",
};

// Present-tense gerunds for the running-tool pill. Kept distinct from
// ACTION_VERB (past tense, used in activity log).
const ACTION_GERUND: Record<string, string> = {
  create_note: "creating note",
  append_to_note: "appending to",
  edit_note: "editing",
  replace_note_body: "rewriting",
  delete_note: "deleting",
  relate: "linking",
  graph_search: "searching the graph for",
  graph_neighbors: "exploring neighbors of",
  search_mail: "searching mail for",
  promote_email_thread: "promoting email thread",
  list_events: "checking the calendar",
  create_event: "scheduling",
  delete_event: "removing event",
  list_reminders: "checking reminders",
  create_reminder: "creating reminder",
  list_recent_mail: "scanning recent mail",
  read_thread: "reading thread",
  list_dir: "listing directory",
  read_file: "reading file",
};

// Format a phase-elapsed duration. Sub-second granularity matters at
// 0–2s (the user wants to see SOMETHING incrementing); past 10s the
// rounded integer is plenty.
function formatPhaseElapsed(ms: number): string {
  if (ms < 1000) return "0s";
  if (ms < 10_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.round(ms / 1000)}s`;
}

function toolStatusLabel(
  action?: string,
  target?: string,
  secondary?: string,
): string {
  if (!action) return "thinking";
  const verb = ACTION_GERUND[action] ?? `running ${action}`;
  // Trim noisy ids — thread_ids and Mail.app message ids are useless
  // to the user. If the target is purely hex / digits / longer than
  // ~40 chars, omit it.
  const looksLikeId = (s: string) =>
    /^[0-9a-f]{8,}$/i.test(s) || /^\d+$/.test(s) || s.length > 40;
  const cleanTarget = target && !looksLikeId(target) ? target : undefined;
  const cleanSecondary =
    secondary && !looksLikeId(secondary) ? secondary : undefined;
  if (cleanTarget && cleanSecondary) {
    return `${verb} "${cleanTarget}" → "${cleanSecondary}"`;
  }
  if (cleanTarget) return `${verb} "${cleanTarget}"`;
  return verb;
}

function relativeTime(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  if (ms < 5_000) return "now";
  if (ms < 60_000) return `${Math.floor(ms / 1000)}s`;
  if (ms < 3_600_000) return `${Math.floor(ms / 60_000)}m`;
  if (ms < 86_400_000) return `${Math.floor(ms / 3_600_000)}h`;
  return `${Math.floor(ms / 86_400_000)}d`;
}

function ActivityRow(props: {
  item: ActivityItem;
  onTitleClick: (title: string) => void;
}) {
  const a = () => props.item;
  return (
    <div class="activity-row flex items-center gap-2 px-2 py-1.5 text-[11.5px] leading-snug">
      <span class="activity-row__icon">
        <Show
          when={a().kind === "vault_read"}
          fallback={<Wrench size={10} strokeWidth={2.2} />}
        >
          <Eye size={10} strokeWidth={2.2} />
        </Show>
      </span>
      <Show
        when={a().kind === "tool_call"}
        fallback={
          <span class="min-w-0 flex-1 truncate text-text-muted">
            read {a().count} {a().count === 1 ? "note" : "notes"}
          </span>
        }
      >
        <span class="min-w-0 flex-1 truncate text-text-muted">
          <span class="text-text-subtle">
            {ACTION_VERB[a().action ?? ""] ?? a().action}
          </span>{" "}
          <button
            type="button"
            class="activity-row__link"
            onClick={(e) => {
              e.stopPropagation();
              if (a().target) props.onTitleClick(a().target!);
            }}
          >
            {a().target}
          </button>
          <Show when={a().secondary}>
            <span class="text-text-subtle"> → </span>
            <button
              type="button"
              class="activity-row__link"
              onClick={(e) => {
                e.stopPropagation();
                if (a().secondary) props.onTitleClick(a().secondary!);
              }}
            >
              {a().secondary}
            </button>
          </Show>
        </span>
      </Show>
      <span class="shrink-0 font-mono text-[10px] tabular-nums text-text-subtle/70">
        {relativeTime(a().ts)}
      </span>
    </div>
  );
}

type NoteRowProps = {
  note: Note;
  folders: Folder[];
  renaming: () => boolean;
  renameDraft: () => string;
  onRenameDraft: (s: string) => void;
  inspectorTitle: () => string | null;
  onOpen: (title: string) => void;
  onStartRename: (title: string) => void;
  onCommitRename: (oldTitle: string) => Promise<void> | void;
  onCancelRename: () => void;
  onDelete: (title: string) => void;
  onMoveToFolder: (title: string, folderId: unknown | null) => void;
};

// Sidebar note row + actions. Lifted out of the App body so the
// folder/Unfiled groups can each `<For>` their own bucket without
// duplicating the row markup. State stays in App via the prop fns.
function NoteRow(props: NoteRowProps) {
  const [moveOpen, setMoveOpen] = createSignal(false);
  // The popover lives in a sibling element rather than inside the
  // trigger button, so click-outside has to watch the whole row's
  // popover-area (trigger + dropdown) — checking only the trigger
  // would close the popover on the very first click that *should*
  // pick a folder.
  let popoverRoot: HTMLDivElement | undefined;

  createEffect(() => {
    if (!moveOpen()) return;
    const onDown = (e: MouseEvent) => {
      if (popoverRoot && !popoverRoot.contains(e.target as Node)) {
        setMoveOpen(false);
      }
    };
    window.addEventListener("mousedown", onDown);
    onCleanup(() => window.removeEventListener("mousedown", onDown));
  });

  return (
    <div
      class="note-row list-row group/note relative flex items-center"
      classList={{
        "note-row--active list-row--active":
          props.inspectorTitle() === props.note.title && !props.renaming(),
        "text-text-muted":
          props.inspectorTitle() !== props.note.title && !props.renaming(),
      }}
    >
      <Show
        when={props.renaming()}
        fallback={
          <button
            type="button"
            onClick={() => props.onOpen(props.note.title)}
            onDblClick={() => props.onStartRename(props.note.title)}
            class="note-row__button flex min-w-0 flex-1 items-center gap-2.5 text-left"
          >
            <span class="note-row__source">
              <SourceDot kind={props.note.source_kind} class="size-1.5" />
            </span>
            <span class="note-row__body">
              <span class="note-row__title">{props.note.title}</span>
              <span class="note-row__meta">
                {sourceLabel(props.note.source_kind)} ·{" "}
                {relativeTime(props.note.updated_at)}
              </span>
            </span>
          </button>
        }
      >
        <div class="note-row__button flex min-w-0 flex-1 items-center gap-2.5">
          <span class="note-row__source">
            <SourceDot kind={props.note.source_kind} class="size-1.5" />
          </span>
          <input
            value={props.renameDraft()}
            onInput={(e) => props.onRenameDraft(e.currentTarget.value)}
            onBlur={() => props.onCommitRename(props.note.title)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                void props.onCommitRename(props.note.title);
              } else if (e.key === "Escape") {
                e.preventDefault();
                props.onCancelRename();
              }
            }}
            ref={(el) => queueMicrotask(() => el?.focus())}
            class="input-pill min-w-0 flex-1 px-1 py-0.5 text-[13px]"
          />
        </div>
      </Show>
      <Show when={!props.renaming()}>
        {/* The action cluster is hover-gated, but we keep it visible
            while the move popover is open — otherwise the trigger
            unmounts the moment the cursor leaves the row to reach the
            menu, killing the popover with it. */}
        <div
          class="note-row__actions mr-1 items-center gap-0.5"
          classList={{
            "flex": moveOpen(),
            "hidden group-hover/note:flex": !moveOpen(),
          }}
        >
          <button
            type="button"
            onMouseDown={(e) => e.stopPropagation()}
            onClick={(e) => {
              e.stopPropagation();
              setMoveOpen((v) => !v);
            }}
            title="Move to folder"
            class="control-icon flex size-5"
            classList={{
              "text-accent": moveOpen(),
            }}
          >
            <FolderIcon size={11} strokeWidth={2} />
          </button>
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              props.onStartRename(props.note.title);
            }}
            title="Rename"
            class="control-icon flex size-5"
          >
            <Pencil size={11} strokeWidth={2} />
          </button>
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              props.onDelete(props.note.title);
            }}
            title="Delete note"
            class="control-icon flex size-5 hover:text-danger"
          >
            <Trash2 size={11} strokeWidth={2} />
          </button>
        </div>
        {/* Move-to-folder popover. Mounted as a sibling of the action
            cluster (not inside it) so it doesn't get torn down when
            the row loses its hover state — which would happen the
            moment the cursor moves down to the menu. The wrapping
            `popoverRoot` covers both trigger and menu so the
            click-outside guard treats them as one region. */}
        <Show when={moveOpen()}>
          <div
            ref={(el) => (popoverRoot = el)}
            class="absolute right-1 top-full z-40 mt-0.5 w-48 rounded-md border border-border bg-bg-elev p-1 shadow-xl"
          >
            <button
              type="button"
              onMouseDown={(e) => e.stopPropagation()}
              onClick={(e) => {
                e.stopPropagation();
                props.onMoveToFolder(props.note.title, null);
                setMoveOpen(false);
              }}
              class="list-row flex w-full items-center gap-2 px-2 py-1 text-left text-[12px]"
              classList={{
                "text-text-subtle": props.note.folder == null,
              }}
            >
              <span class="size-2" />
              Unfiled
              <Show when={props.note.folder == null}>
                <Check size={10} strokeWidth={2.5} class="ml-auto" />
              </Show>
            </button>
            <For each={props.folders}>
              {(f) => {
                const isHere = () =>
                  JSON.stringify(props.note.folder) === JSON.stringify(f.id);
                return (
                  <button
                    type="button"
                    onMouseDown={(e) => e.stopPropagation()}
                    onClick={(e) => {
                      e.stopPropagation();
                      if (!isHere())
                        props.onMoveToFolder(props.note.title, f.id);
                      setMoveOpen(false);
                    }}
                    class="list-row flex w-full items-center gap-2 px-2 py-1 text-left text-[12px]"
                    classList={{
                      "text-accent": isHere(),
                    }}
                  >
                    <FolderIcon size={11} strokeWidth={2} />
                    <span class="truncate">{f.name}</span>
                    <Show when={isHere()}>
                      <Check size={10} strokeWidth={2.5} class="ml-auto" />
                    </Show>
                  </button>
                );
              }}
            </For>
          </div>
        </Show>
      </Show>
    </div>
  );
}

type TerminalMultiplexerProps = {
  session: TerminalSession;
  meta: Record<string, TerminalMeta>;
  active: boolean;
  generation: number;
  onFocusPane: (paneId: string) => void;
  onSplitRight: (paneId: string) => void;
  onSplitDown: (paneId: string) => void;
  onClosePane: (paneId: string) => void;
  // Drag-resize callback. Path = sequence of 0|1 (first|second) from
  // the layout root to the split being resized. Empty path = root split.
  onResizeSplit: (path: number[], ratio: number) => void;
};

type TerminalMultiplexerHostProps = {
  // Captured at mount time. Stable for component lifetime — when active
  // session changes, the parent's keyed Show recreates this host with a
  // new sessionId.
  sessionId: string;
  // Memos passed by reference — host re-derives via these every render
  // so reactivity flows through the host without depending on stale
  // accessors from the parent's Show body.
  terminalSessions: () => TerminalSession[];
  meta: () => Record<string, TerminalMeta>;
  activeWorkspaceTabIdMemo: () => string | null;
  generationMemo: () => number;
  focusTerminalPane: (sessionId: string, paneId: string) => void;
  splitTerminalPane: (sessionId: string, direction: "row" | "column") => void;
  closeTerminalPane: (sessionId: string, paneId: string) => void;
  resizeTerminalSplit: (
    sessionId: string,
    path: number[],
    ratio: number,
  ) => void;
};

function TerminalMultiplexerHost(props: TerminalMultiplexerHostProps) {
  // Last-known cache: between sibling setSignal calls (e.g. the close-
  // workspace-tab sequence flips terminalSessions THEN workspaceTabs),
  // session() can momentarily return null while this host is still
  // mounted (parent's `activeTerminalSessionId` hasn't yet flipped).
  // Without the cache, the prop getter would resolve to null and
  // TerminalMultiplexer's `.layout` deref would throw, crashing
  // mid-write and freezing the app. Cache holds the last good value
  // until the parent's keyed Show unmounts us cleanly.
  let lastSession: TerminalSession | null = null;
  const session = createMemo<TerminalSession | null>(() => {
    const cur = props.terminalSessions().find((s) => s.id === props.sessionId);
    if (cur) lastSession = cur;
    return cur ?? null;
  });
  return (
    <Show when={session()}>
      <TerminalMultiplexer
        session={(session() ?? lastSession) as TerminalSession}
        meta={props.meta()}
        active={
          (props.activeWorkspaceTabIdMemo() ?? "") === props.sessionId
        }
        generation={props.generationMemo()}
        onFocusPane={(paneId) =>
          props.focusTerminalPane(props.sessionId, paneId)
        }
        onSplitRight={(paneId) => {
          props.focusTerminalPane(props.sessionId, paneId);
          props.splitTerminalPane(props.sessionId, "row");
        }}
        onSplitDown={(paneId) => {
          props.focusTerminalPane(props.sessionId, paneId);
          props.splitTerminalPane(props.sessionId, "column");
        }}
        onClosePane={(paneId) => props.closeTerminalPane(props.sessionId, paneId)}
        onResizeSplit={(path, ratio) =>
          props.resizeTerminalSplit(props.sessionId, path, ratio)
        }
      />
    </Show>
  );
}

function TerminalMultiplexer(props: TerminalMultiplexerProps) {
  return (
    <div class="terminal-mux">
      <TerminalLayoutNode
        node={props.session.layout}
        path={[]}
        session={props.session}
        meta={props.meta}
        active={props.active}
        generation={props.generation}
        onFocusPane={props.onFocusPane}
        onSplitRight={props.onSplitRight}
        onSplitDown={props.onSplitDown}
        onClosePane={props.onClosePane}
        onResizeSplit={props.onResizeSplit}
      />
    </div>
  );
}

type TerminalLayoutNodeProps = TerminalMultiplexerProps & {
  node: TerminalLayout;
  // Position of this node in the layout tree from the root.
  // Empty array = root layout. Each step is 0 (first) or 1 (second).
  path: number[];
};

function TerminalLayoutNode(props: TerminalLayoutNodeProps) {
  // SolidJS gotcha #1: top-level `if (props.node.kind === ...)` runs once
  // at mount and the JSX choice freezes. Switch/Match wraps both branches
  // so kind flips re-render.
  // SolidJS gotcha #2: `<Match when={X}>{(x) => <Comp prop={x().y}>}</Match>`
  // leaks the accessor x into child prop getters. When Match flips false,
  // teardown re-evaluates props and calls x() on the stale state → throws
  // "stale value" → corrupts the reactive graph → entire app freezes.
  // Workaround: read props.node directly inside child JSX (no function-
  // children accessor). Cast for type narrowing — runtime safe because
  // Match's `when` already gated.
  return (
    <Switch>
      <Match when={props.node.kind === "split"}>
        <TerminalSplitView
          getNode={() =>
            props.node as Extract<TerminalLayout, { kind: "split" }>
          }
          path={props.path}
          session={props.session}
          meta={props.meta}
          active={props.active}
          generation={props.generation}
          onFocusPane={props.onFocusPane}
          onSplitRight={props.onSplitRight}
          onSplitDown={props.onSplitDown}
          onClosePane={props.onClosePane}
          onResizeSplit={props.onResizeSplit}
        />
      </Match>
      <Match when={props.node.kind === "pane"}>
        <TerminalPaneView
          getPaneId={() =>
            (props.node as Extract<TerminalLayout, { kind: "pane" }>).paneId
          }
          session={props.session}
          meta={props.meta}
          active={props.active}
          generation={props.generation}
          onFocusPane={props.onFocusPane}
          onSplitRight={props.onSplitRight}
          onSplitDown={props.onSplitDown}
          onClosePane={props.onClosePane}
        />
      </Match>
    </Switch>
  );
}

type TerminalSplitViewProps = Omit<TerminalLayoutNodeProps, "node"> & {
  getNode: () => Extract<TerminalLayout, { kind: "split" }>;
};

function TerminalSplitView(props: TerminalSplitViewProps) {
  let containerEl!: HTMLDivElement;
  const [dragging, setDragging] = createSignal(false);

  function startDrag(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    const isRow = props.getNode().direction === "row";
    const rect = containerEl.getBoundingClientRect();
    setDragging(true);

    function onMove(ev: MouseEvent) {
      const offset = isRow ? ev.clientX - rect.left : ev.clientY - rect.top;
      const total = isRow ? rect.width : rect.height;
      if (total <= 0) return;
      const ratio = Math.min(0.9, Math.max(0.1, offset / total));
      props.onResizeSplit(props.path, ratio);
    }
    function onUp() {
      setDragging(false);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    }
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }

  return (
    <div
      ref={containerEl}
      class="terminal-split"
      classList={{
        "terminal-split--row": props.getNode().direction === "row",
        "terminal-split--column": props.getNode().direction === "column",
      }}
    >
      <div
        class="terminal-split__child"
        style={{ flex: `${props.getNode().ratio} 1 0` }}
      >
        <TerminalLayoutNode
          node={props.getNode().first}
          path={[...props.path, 0]}
          session={props.session}
          meta={props.meta}
          active={props.active}
          generation={props.generation}
          onFocusPane={props.onFocusPane}
          onSplitRight={props.onSplitRight}
          onSplitDown={props.onSplitDown}
          onClosePane={props.onClosePane}
          onResizeSplit={props.onResizeSplit}
        />
      </div>
      <div
        class="terminal-split__splitter"
        classList={{ "terminal-split__splitter--dragging": dragging() }}
        onMouseDown={startDrag}
      />
      <div
        class="terminal-split__child"
        style={{ flex: `${1 - props.getNode().ratio} 1 0` }}
      >
        <TerminalLayoutNode
          node={props.getNode().second}
          path={[...props.path, 1]}
          session={props.session}
          meta={props.meta}
          active={props.active}
          generation={props.generation}
          onFocusPane={props.onFocusPane}
          onSplitRight={props.onSplitRight}
          onSplitDown={props.onSplitDown}
          onClosePane={props.onClosePane}
          onResizeSplit={props.onResizeSplit}
        />
      </div>
    </div>
  );
}

type TerminalPaneViewProps = Omit<
  TerminalLayoutNodeProps,
  "node" | "path" | "onResizeSplit"
> & {
  // Function-style prop instead of plain string. Lets parent gate the
  // read on Match's truthiness without leaking Match's accessor across
  // the component boundary (see TerminalLayoutNode comment).
  getPaneId: () => string;
};

function TerminalPaneView(props: TerminalPaneViewProps) {
  const pane = () =>
    props.session.panes.find((item) => item.id === props.getPaneId()) ??
    props.session.panes[0];
  const meta = () => props.meta[pane().id];
  const activePane = () => props.session.activePaneId === pane().id;
  const detail = () => {
    const m = meta();
    const path = m?.pathLabel;
    const branch = m?.git ? `${m.git.branch}${m.git.dirty ? "*" : ""}` : null;
    if (branch && path) return `${branch} • ${path}`;
    return branch ?? path ?? "";
  };

  return (
    <div
      class="terminal-pane"
      classList={{ "terminal-pane--active": activePane() }}
    >
      <div
        class="terminal-pane__bar"
        onMouseDown={() => props.onFocusPane(pane().id)}
      >
        <div class="terminal-pane__identity">
          <span class="terminal-pane__title">
            {meta()?.displayTitle || pane().title}
          </span>
          <Show when={meta()?.running}>
            <span class="terminal-pane__running">
              <Zap size={11} strokeWidth={2.3} />
              Running
            </span>
          </Show>
          <Show when={detail()}>
            <span class="terminal-pane__detail">{detail()}</span>
          </Show>
        </div>
        <div class="terminal-pane__actions">
          <button
            type="button"
            title="Split right"
            onClick={(e) => {
              e.stopPropagation();
              props.onSplitRight(pane().id);
            }}
          >
            <Columns2 size={13} strokeWidth={2.15} />
          </button>
          <button
            type="button"
            title="Split down"
            onClick={(e) => {
              e.stopPropagation();
              props.onSplitDown(pane().id);
            }}
          >
            <Rows2 size={13} strokeWidth={2.15} />
          </button>
          <Show when={props.session.panes.length > 1}>
            <button
              type="button"
              title="Close pane"
              onClick={(e) => {
                e.stopPropagation();
                props.onClosePane(pane().id);
              }}
            >
              <X size={13} strokeWidth={2.25} />
            </button>
          </Show>
        </div>
      </div>
      <NativeTerminalHost
        tabId={pane().id}
        cwd={meta()?.cwd ?? pane().cwd}
        active={props.active}
        focus={props.active && activePane()}
        generation={props.generation}
      />
    </div>
  );
}

type TokenEvent = { turnId: number; token: string };
type DoneEvent = { turnId: number };
type ErrorEvent = { turnId: number; message: string };

type Mention =
  | { active: false }
  | { active: true; atIdx: number; query: string };

function normalizeMentionName(value: string) {
  return value.toLowerCase().replace(/[\s_-]+/g, "");
}

function agentMentionSlug(agent: Agent) {
  return agent.name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function shortModelName(model: string) {
  const last = model.split("/").pop() ?? model;
  return last.replace(/-Instruct/i, "").replace(/-4bit/i, "");
}

function computeModeLabel(mode: ComputeMode) {
  if (mode === "fast") return "Fast";
  if (mode === "deep") return "Deep";
  return "Balanced";
}

function turnPlanLabel(kind: TurnPlanKind) {
  if (kind === "direct") return "Direct reply";
  if (kind === "lead-synthesis") return "Lead synthesis";
  if (kind === "deep-review") return "Deep review";
  return "Single reply";
}

function readinessLabel(readiness: ModelReadiness | undefined) {
  if (!readiness || readiness.state === "checking") return "Checking";
  if (readiness.state === "ready") return "Ready";
  if (readiness.state === "missing") {
    return readiness.fallbackReady ? "Fallback" : "Missing";
  }
  return "Offline";
}

function readinessClass(readiness: ModelReadiness | undefined) {
  if (!readiness || readiness.state === "checking") return "model-status--checking";
  if (readiness.state === "ready") return "model-status--ready";
  if (readiness.state === "missing") {
    return readiness.fallbackReady ? "model-status--fallback" : "model-status--missing";
  }
  return "model-status--offline";
}

function formatUsagePercent(value: number | null | undefined) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "--";
  if (value >= 100) return `${Math.round(value)}%`;
  if (value >= 10) return `${value.toFixed(0)}%`;
  return `${value.toFixed(1)}%`;
}

function formatUsageBytes(bytes: number | null | undefined) {
  if (bytes === null || bytes === undefined || !Number.isFinite(bytes)) return "--";
  const mb = bytes / 1024 / 1024;
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)}G`;
  return `${Math.max(1, Math.round(mb))}M`;
}

function usageTone(
  kind: "cpu" | "memory",
  value: number | null | undefined,
): "muted" | "ok" | "warn" | "danger" {
  if (value === null || value === undefined || !Number.isFinite(value)) return "muted";
  if (kind === "cpu") {
    if (value >= 400) return "danger";
    if (value >= 200) return "warn";
    return "ok";
  }
  if (kind === "memory") {
    const gb = value / 1024 / 1024 / 1024;
    if (gb >= 8) return "danger";
    if (gb >= 4) return "warn";
    return "ok";
  }
  return "ok";
}

function ResourceUsagePill(props: {
  label: string;
  value: string;
  tone: "muted" | "ok" | "warn" | "danger";
}) {
  return (
    <span class={`resource-usage-pill resource-usage-pill--${props.tone}`}>
      <span class="resource-usage-pill__label">{props.label}</span>
      <span class="resource-usage-pill__value">{props.value}</span>
    </span>
  );
}

// Qwen 2.5 7B 4-bit quant. Beats Gemma 3 4B for structured-output
// reliability (esp. clome-tool JSON blocks) at ~2x size. Run via:
//   mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit
const DEFAULT_MODEL = "mlx-community/Qwen2.5-7B-Instruct-4bit";

const SYSTEM_PROMPT =
  "You are Clome, a local AI companion running on the user's Mac. " +
  "Be concise. No filler. Respond in plain text unless code is needed. " +
  "When the user references something using [[wikilink]] syntax, treat it as a named entity in their notes vault.";

const PROMPT_HISTORY_MAX_MESSAGES = 14;
const PROMPT_HISTORY_MAX_CHARS = 14_000;

function stripClomeToolBlocks(text: string): string {
  const lines = text.split(/\r?\n/);
  const kept: string[] = [];
  let inToolBlock = false;
  let fenceTicks = 0;

  for (const line of lines) {
    const open = line.match(/^\s*(`{3,})clome-tool\s*$/);
    if (!inToolBlock && open) {
      inToolBlock = true;
      fenceTicks = open[1].length;
      continue;
    }

    if (inToolBlock) {
      const close = line.match(/^\s*(`{3,})\s*$/);
      if (close && close[1].length >= fenceTicks) {
        inToolBlock = false;
        fenceTicks = 0;
      }
      continue;
    }

    kept.push(line);
  }

  return kept.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

// Cap on plain prior assistant content fed back to the model. Long
// turns are still trimmed for context budget. Tool-derived turns are
// dropped entirely — see comment in buildPromptHistory below.
const PRIOR_AGENT_TEXT_CAP = 400;

function condensePriorAgentText(m: Message): string {
  const stripped = stripClomeToolBlocks(m.text);
  if (stripped.length <= PRIOR_AGENT_TEXT_CAP) return stripped;
  return stripped.slice(0, PRIOR_AGENT_TEXT_CAP).trimEnd();
}

function buildPromptHistory(messages: Message[], latestUserText: string): PromptMessage[] {
  const rows: PromptMessage[] = [];
  for (const m of messages) {
    // Drop prior tool-derived agent turns. With native tool calling,
    // the canonical thing to send back is the assistant's `tool_calls`
    // structure plus the matching `tool` role result. We don't yet
    // persist those (A2 work), so for A1 we send a clean history that
    // doesn't include the model's prior prose summary at all — that
    // prose is exactly what poisoned follow-up turns under the old
    // text-fence harness. The user already saw the rendered cards in
    // the bubble.
    if (m.role === "agent" && m.toolResults && m.toolResults.length > 0) {
      continue;
    }
    const content =
      m.role === "agent" ? condensePriorAgentText(m) : m.text.trim();
    if (!content) continue;
    rows.push({
      role: m.role === "agent" ? "assistant" : "user",
      content,
    });
  }
  rows.push({ role: "user", content: latestUserText });

  const kept: PromptMessage[] = [];
  let chars = 0;
  for (let i = rows.length - 1; i >= 0; i -= 1) {
    const row = rows[i];
    const nextChars = chars + row.content.length;
    if (
      kept.length > 0 &&
      (kept.length >= PROMPT_HISTORY_MAX_MESSAGES ||
        nextChars > PROMPT_HISTORY_MAX_CHARS)
    ) {
      break;
    }
    kept.push(row);
    chars = nextChars;
  }
  return kept.reverse();
}

export default function App() {
  const [messages, setMessages] = createStore<Message[]>([]);
  const liveMessagesByChat = new Map<string, Message[]>();
  const liveTurnChatById = new Map<number, string>();
  const liveTurnMessageIds = new Map<number, number[]>();

  function chatKey(chatId: ChatId): string {
    return JSON.stringify(chatId);
  }

  function cloneMessage(m: Message): Message {
    return {
      ...m,
      toolResults: m.toolResults ? [...m.toolResults] : undefined,
    };
  }

  function nextMessageIdFor(rows: Message[]): number {
    if (rows.length === 0) return 0;
    return Math.max(...rows.map((m) => m.id)) + 1;
  }

  function rememberLiveTurn(
    chatId: ChatId,
    userMessage: Message,
    agentMessage: Message,
  ) {
    const key = chatKey(chatId);
    const rows = liveMessagesByChat.get(key) ?? [];
    liveMessagesByChat.set(key, [
      ...rows,
      cloneMessage(userMessage),
      cloneMessage(agentMessage),
    ]);
    liveTurnChatById.set(agentMessage.id, key);
    liveTurnMessageIds.set(agentMessage.id, [userMessage.id, agentMessage.id]);
  }

  function updateLiveTurn(turnId: number, mut: (m: Message) => void) {
    const key = liveTurnChatById.get(turnId);
    if (!key) return;
    const rows = liveMessagesByChat.get(key);
    if (!rows) return;
    liveMessagesByChat.set(
      key,
      rows.map((row) => {
        if (row.id !== turnId) return row;
        const next = cloneMessage(row);
        mut(next);
        return next;
      }),
    );
  }

  function clearLiveTurn(turnId: number) {
    const key = liveTurnChatById.get(turnId);
    if (!key) return;
    const ids = new Set(liveTurnMessageIds.get(turnId) ?? [turnId]);
    const rows = liveMessagesByChat.get(key)?.filter((row) => !ids.has(row.id)) ?? [];
    if (rows.length > 0) {
      liveMessagesByChat.set(key, rows);
    } else {
      liveMessagesByChat.delete(key);
    }
    liveTurnChatById.delete(turnId);
    liveTurnMessageIds.delete(turnId);
  }

  function mergeLiveMessages(chatId: ChatId, hydrated: Message[]): Message[] {
    const live = liveMessagesByChat.get(chatKey(chatId)) ?? [];
    if (live.length === 0) return hydrated;
    const dbKeys = new Set(
      hydrated
        .map((m) => (m.dbId === undefined ? null : JSON.stringify(m.dbId)))
        .filter((key): key is string => key !== null),
    );
    const stillLive = live.filter(
      (m) => m.dbId === undefined || !dbKeys.has(JSON.stringify(m.dbId)),
    );
    return [...hydrated, ...stillLive.map(cloneMessage)];
  }

  // Live tick at 250ms while ANY agent message is in a streaming
  // phase. Drives the elapsed-time readout in the status strip
  // without each bubble setting up its own interval. Pauses when
  // nothing is streaming so we don't burn CPU at idle.
  const [phaseTick, setPhaseTick] = createSignal(Date.now());
  let phaseTickHandle: number | null = null;
  function ensurePhaseTicker() {
    if (phaseTickHandle != null) return;
    phaseTickHandle = window.setInterval(() => {
      setPhaseTick(Date.now());
      // Stop the ticker once nothing is left in a live phase.
      const stillLive = messages.some(
        (m) => m.role === "agent" && m.status === "streaming" && m.phase,
      );
      if (!stillLive && phaseTickHandle != null) {
        clearInterval(phaseTickHandle);
        phaseTickHandle = null;
      }
    }, 250);
  }
  const [notes, setNotes] = createSignal<Note[]>([]);
  const [folders, setFolders] = createSignal<Folder[]>([]);
  const [collapsedFolderIds, setCollapsedFolderIds] = createSignal<Set<string>>(
    new Set(),
  );
  // Persisted sort + source-kind filter for the sidebar notes list.
  const NOTES_SORT_KEY = "clome:notesSort";
  const NOTES_KIND_FILTER_KEY = "clome:notesKindFilter";
  const [notesSort, setNotesSort] = createSignal<NoteSortMode>(
    (localStorage.getItem(NOTES_SORT_KEY) as NoteSortMode) ?? "recency",
  );
  createEffect(() => localStorage.setItem(NOTES_SORT_KEY, notesSort()));
  const [activeKindFilters, setActiveKindFilters] = createSignal<Set<string>>(
    new Set(
      JSON.parse(localStorage.getItem(NOTES_KIND_FILTER_KEY) ?? "[]") as string[],
    ),
  );
  createEffect(() =>
    localStorage.setItem(
      NOTES_KIND_FILTER_KEY,
      JSON.stringify([...activeKindFilters()]),
    ),
  );
  const [input, setInput] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [activeTurnId, setActiveTurnId] = createSignal<number | null>(null);
  const [mention, setMention] = createSignal<Mention>({ active: false });
  const [mentionSelected, setMentionSelected] = createSignal(0);
  // Semantic backfill for the @-mention oracle. Substring matches are
  // instant + sync (in-memory `notes()`); semantic hits arrive via a
  // debounced backend call. Stored separately so the UI can render
  // substring matches with zero latency, then graft on semantic ones
  // when they land. Per-query sequence guards against out-of-order.
  const [mentionSemanticHits, setMentionSemanticHits] = createSignal<string[]>([]);
  let mentionSemanticSeq = 0;
  let mentionSemanticTimer: number | null = null;
  const [inspectorTitle, setInspectorTitle] = createSignal<string | null>(null);
  // (Removed `inspectorMode` signal — render mode is derived from
  // `activeNoteTab()`. Pinning the inspector as a tab IS the page-mode
  // state now; floating side panel is the default.)
  const [sidebarOpen, setSidebarOpen] = createSignal(true);
  // Peek state: when sidebar is collapsed, hovering the left edge slides
  // an overlay sidebar in. Dismisses on mouse-leave with a short grace
  // period so brief crossings don't flicker. Independent of sidebarOpen
  // — peek is ephemeral, doesn't change content layout.
  const [sidebarPeek, setSidebarPeek] = createSignal(false);
  let peekDismissTimer = 0;
  const cancelPeekDismiss = () => {
    if (peekDismissTimer !== 0) {
      window.clearTimeout(peekDismissTimer);
      peekDismissTimer = 0;
    }
  };
  const openSidebarPeek = () => {
    cancelPeekDismiss();
    if (!sidebarPeek()) setSidebarPeek(true);
  };
  const scheduleSidebarPeekClose = () => {
    cancelPeekDismiss();
    peekDismissTimer = window.setTimeout(() => {
      peekDismissTimer = 0;
      setSidebarPeek(false);
    }, 140);
  };
  const [sidebarFilter, setSidebarFilter] = createSignal("");
  const [sidebarWidth, setSidebarWidth] = createSignal(272);
  // Inspector pane width when shown on the right (side mode). 26rem
  // default matches the previous hardcoded `w-[26rem]`. Persisted so
  // resize survives reload.
  const INSPECTOR_WIDTH_KEY = "clome:inspectorWidth";
  const [inspectorWidth, setInspectorWidth] = createSignal(
    (() => {
      const raw =
        typeof localStorage !== "undefined"
          ? localStorage.getItem(INSPECTOR_WIDTH_KEY)
          : null;
      const n = raw ? parseInt(raw, 10) : NaN;
      // Min floor only — no upper cap. User can drag arbitrarily wide;
      // crossing 90% snaps to a workspace tab (page mode) instead.
      return Number.isFinite(n) ? Math.max(300, n) : 416;
    })(),
  );
  createEffect(() => {
    if (typeof localStorage === "undefined") return;
    localStorage.setItem(INSPECTOR_WIDTH_KEY, String(inspectorWidth()));
  });

  // Hide traffic lights only while the sidebar is in peek-overlay mode
  // (collapsed + peeking). When peek transitions to docked (user clicks
  // the PanelLeft button) or fully dismisses, lights come back.
  createEffect(() => {
    const peekingOverlay = !sidebarOpen() && sidebarPeek();
    void invoke("window_set_traffic_lights_hidden", {
      hidden: peekingOverlay,
    }).catch((e) =>
      console.error("window_set_traffic_lights_hidden failed:", e),
    );
  });

  // Clip Ghostty surfaces around the active HTML overlay. Surfaces stay
  // visible everywhere outside the rect; only the overlay region is
  // excluded so HTML can paint there. Avoids the full-screen black-out
  // that comes from hiding every surface unconditionally.
  //
  // Peek sidebar: send its computed rect (small left strip).
  // Other overlays (palette, modals): full window rect → all surfaces
  //   inside that rect are fully covered → cheap full-hide path in Swift.
  createEffect(() => {
    const peeking = !sidebarOpen() && sidebarPeek();
    const fullScreenOverlay =
      searchOpen() ||
      settingsOpen() ||
      captureOpen() ||
      workspacePickerOpen() ||
      agentPickerOpen() ||
      pendingDelete() !== null ||
      renamingChatId() !== null ||
      renamingNoteTitle() !== null ||
      renamingWorkspaceId() !== null;

    let rect: { x: number; y: number; width: number; height: number } | null =
      null;
    if (fullScreenOverlay) {
      rect = { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight };
    } else if (peeking) {
      // Mirror peek CSS analytically — getBoundingClientRect during the
      // slide-in animation reports mid-transform values, which would
      // briefly mask the wrong region.
      const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      const top = 0.6 * rem;
      const left = 0.55 * rem;
      const maxH = Math.min(560, window.innerHeight - 1.6 * rem);
      rect = {
        x: left,
        y: top,
        width: sidebarWidth(),
        height: maxH,
      };
    }

    void invoke("terminal_native_set_overlay_clip", { rect }).catch((e) =>
      console.error("terminal_native_set_overlay_clip failed:", e),
    );
  });
  const [notesCollapsed, setNotesCollapsed] = createSignal(false);
  const [lastCopiedId, setLastCopiedId] = createSignal<number | null>(null);
  const [captureOpen, setCaptureOpen] = createSignal(false);
  const [settingsOpen, setSettingsOpen] = createSignal(false);
  const [draggingTabId, setDraggingTabId] = createSignal<string | null>(null);
  const [dragOverTabId, setDragOverTabId] = createSignal<string | null>(null);

  // Theme preference. "system" follows OS prefers-color-scheme, otherwise
  // forced. CSS theme tokens live under `:root[data-theme="light"]` —
  // we just toggle the attribute on <html>.
  type ThemePref = "system" | "dark" | "light";
  const THEME_KEY = "clome:theme";
  const [themePref, setThemePref] = createSignal<ThemePref>(
    ((): ThemePref => {
      if (typeof localStorage === "undefined") return "system";
      const v = localStorage.getItem(THEME_KEY);
      return v === "dark" || v === "light" || v === "system" ? v : "system";
    })(),
  );
  createEffect(() => {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem(THEME_KEY, themePref());
    }
  });
  createEffect(() => {
    const pref = themePref();
    const resolved =
      pref === "system"
        ? window.matchMedia("(prefers-color-scheme: light)").matches
          ? "light"
          : "dark"
        : pref;
    document.documentElement.dataset.theme = resolved;
    // Swap highlight.js stylesheet so code blocks match. We inject a
    // <link> tag with a stable id and replace its href on theme change;
    // the previous theme's CSS is replaced atomically to avoid a flash
    // of unstyled code.
    void swapHljsTheme(resolved);
  });

  // ── Settings: default model + default agent + hide activity panel ──
  const DEFAULT_MODEL_KEY = "clome:defaultModel";
  const DEFAULT_AGENT_KEY = "clome:defaultAgentId";
  const ACTIVITY_HIDDEN_KEY = "clome:activityHidden";
  const COMPUTE_MODE_KEY = "clome:computeMode";

  const [defaultModel, setDefaultModel] = createSignal<string>(
    localStorage.getItem(DEFAULT_MODEL_KEY) ?? DEFAULT_MODEL,
  );
  createEffect(() =>
    localStorage.setItem(DEFAULT_MODEL_KEY, defaultModel()),
  );

  const [computeMode, setComputeMode] = createSignal<ComputeMode>(
    ((): ComputeMode => {
      const v = localStorage.getItem(COMPUTE_MODE_KEY);
      return v === "fast" || v === "balanced" || v === "deep"
        ? v
        : "balanced";
    })(),
  );
  createEffect(() =>
    localStorage.setItem(COMPUTE_MODE_KEY, computeMode()),
  );

  // Stored as a JSON-encoded SurrealDB Thing (opaque). Empty string =
  // no default agent (chats start unbound, like the old behavior).
  const [defaultAgentJson, setDefaultAgentJson] = createSignal<string>(
    localStorage.getItem(DEFAULT_AGENT_KEY) ?? "",
  );
  createEffect(() => {
    const v = defaultAgentJson();
    if (v) localStorage.setItem(DEFAULT_AGENT_KEY, v);
    else localStorage.removeItem(DEFAULT_AGENT_KEY);
  });

  const [activityHidden, setActivityHidden] = createSignal(
    localStorage.getItem(ACTIVITY_HIDDEN_KEY) === "1",
  );
  createEffect(() =>
    localStorage.setItem(ACTIVITY_HIDDEN_KEY, activityHidden() ? "1" : "0"),
  );

  // Knowledge graph view — opt-in. When on: a "graph" tab opens via the
  // sidebar entry, and the inspector pane shows a 1-hop mini-graph for
  // the focused note. Off (default) hides both surfaces; the underlying
  // edges are still maintained in the DB so flipping it on later "just
  // works" without a rebuild.
  const GRAPH_ENABLED_KEY = "clome:graphEnabled";
  const [graphEnabled, setGraphEnabled] = createSignal(
    localStorage.getItem(GRAPH_ENABLED_KEY) === "1",
  );
  createEffect(() =>
    localStorage.setItem(GRAPH_ENABLED_KEY, graphEnabled() ? "1" : "0"),
  );
  type PendingDelete =
    | { kind: "note"; title: string }
    | { kind: "chat"; chatId: ChatId; title: string }
    | { kind: "workspace"; workspaceId: WorkspaceId; name: string }
    | { kind: "folder"; folderId: unknown; name: string };
  const [pendingDelete, setPendingDelete] = createSignal<PendingDelete | null>(null);
  const [renamingChatId, setRenamingChatId] = createSignal<ChatId | null>(null);
  const [renamingNoteTitle, setRenamingNoteTitle] = createSignal<string | null>(null);
  const [renamingWorkspaceId, setRenamingWorkspaceId] = createSignal<WorkspaceId | null>(null);
  const [renameDraft, setRenameDraft] = createSignal("");
  const [chats, setChats] = createSignal<Chat[]>([]);
  const [currentChatId, setCurrentChatId] = createSignal<ChatId | null>(null);
  const [chatsCollapsed, setChatsCollapsed] = createSignal(false);
  const [terminalsCollapsed, setTerminalsCollapsed] = createSignal(false);
  const [workspaces, setWorkspaces] = createSignal<Workspace[]>([]);
  const [currentWorkspaceId, setCurrentWorkspaceId] = createSignal<WorkspaceId | null>(null);
  const [workspacePickerOpen, setWorkspacePickerOpen] = createSignal(false);
  const [creatingWorkspace, setCreatingWorkspace] = createSignal(false);
  const [newWorkspaceDraft, setNewWorkspaceDraft] = createSignal("");
  const [activity, setActivity] = createSignal<ActivityItem[]>([]);
  const [activityCollapsed, setActivityCollapsed] = createSignal(false);
  const [searchOpen, setSearchOpen] = createSignal(false);
  const [workspaceTabs, setWorkspaceTabs] = createSignal<WorkspaceTab[]>([]);
  const [activeWorkspaceTabId, setActiveWorkspaceTabId] = createSignal<string | null>(null);
  const [terminalSessions, setTerminalSessions] = createSignal<TerminalSession[]>([]);
  const [terminalMeta, setTerminalMeta] = createSignal<Record<string, TerminalMeta>>({});
  const [terminalStateReady, setTerminalStateReady] = createSignal(false);
  // After a search-pick on a message, switch chat → load → scroll to it.
  const [pendingScrollMsgId, setPendingScrollMsgId] = createSignal<unknown | null>(null);
  const [highlightMsgKey, setHighlightMsgKey] = createSignal<number | null>(null);
  const [agents, setAgents] = createSignal<Agent[]>([]);
  const [agentPickerOpen, setAgentPickerOpen] = createSignal(false);
  const [agentsModalOpen, setAgentsModalOpen] = createSignal(false);
  const [roomAgentQuery, setRoomAgentQuery] = createSignal("");
  const [modelReadiness, setModelReadiness] = createSignal<Record<string, ModelReadiness>>({});
  const [resourceUsage, setResourceUsage] = createSignal<AppResourceUsage | null>(null);
  const [resourceUsageError, setResourceUsageError] = createSignal<string | null>(null);
  const [nativeTerminalGeneration, setNativeTerminalGeneration] = createSignal(0);
  let nativeTerminalGenerationCounter = 0;

  async function refreshResourceUsage() {
    try {
      const usage = await invoke<AppResourceUsage>("app_resource_usage");
      setResourceUsage(usage);
      setResourceUsageError(null);
    } catch (error) {
      setResourceUsageError(error instanceof Error ? error.message : String(error));
    }
  }

  onMount(() => {
    void refreshResourceUsage();
    const handle = window.setInterval(() => void refreshResourceUsage(), 2500);
    onCleanup(() => window.clearInterval(handle));
  });

  const currentChat = createMemo<Chat | null>(() => {
    const id = currentChatId();
    if (id === null) return null;
    return chats().find((c) => JSON.stringify(c.id) === JSON.stringify(id)) ?? null;
  });
  // (Removed `currentChatAgent` single-agent memo — superseded by
  // `currentChatAgents` below for group-chat support. Equivalent
  // single-agent semantics = `currentChatAgents()[0]`.)
  // Group-chat: full list of bound agents resolved against the local
  // agents() cache. Falls back to [agent] for legacy chats whose
  // `agents` field hasn't been backfilled in the JSON yet.
  const currentChatAgents = createMemo<Agent[]>(() => {
    const c = currentChat();
    if (!c) return [];
    const ids =
      c.agents && c.agents.length > 0
        ? c.agents
        : c.agent !== null
          ? [c.agent]
          : [];
    if (ids.length === 0) return [];
    return ids
      .map((id) =>
        agents().find((a) => JSON.stringify(a.id) === JSON.stringify(id)),
      )
      .filter((a): a is Agent => a !== undefined);
  });

  const fallbackModelReady = createMemo(() => {
    const readiness = modelReadiness()[defaultModel()];
    return readiness?.state === "ready";
  });

  function readinessForModel(model: string): ModelReadiness | undefined {
    const readiness = modelReadiness()[model];
    if (
      readiness?.state === "missing" &&
      model !== defaultModel() &&
      fallbackModelReady()
    ) {
      return { state: "missing", fallbackReady: true };
    }
    return readiness;
  }

  const roomModels = createMemo(() => {
    const seen = new Set<string>();
    const out: string[] = [];
    const add = (model: string) => {
      const trimmed = model.trim();
      if (!trimmed || seen.has(trimmed)) return;
      seen.add(trimmed);
      out.push(trimmed);
    };
    add(defaultModel());
    for (const agent of currentChatAgents()) add(agent.model);
    return out;
  });

  const roomAgentResults = createMemo(() => {
    const q = roomAgentQuery().trim().toLowerCase();
    if (!q) return agents();
    return agents().filter((agent) =>
      `${agent.name} ${agent.model}`.toLowerCase().includes(q),
    );
  });

  const resourceUsageTitle = createMemo(() => {
    const usage = resourceUsage();
    const error = resourceUsageError();
    if (error) return `Resource usage unavailable: ${error}`;
    if (!usage) return "Sampling Clome resource usage";
    const modelPart =
      usage.modelProcessCount > 0
        ? `MLX model server: CPU ${formatUsagePercent(usage.modelCpuPercent)}, memory ${formatUsageBytes(usage.modelMemoryBytes)}.`
        : "No MLX model server process detected.";
    return [
      "Clome app plus detected local MLX model server.",
      `App: CPU ${formatUsagePercent(usage.appCpuPercent)}, memory ${formatUsageBytes(usage.appMemoryBytes)}.`,
      modelPart,
    ].join(" ");
  });

  createEffect(() => {
    const models = roomModels();
    if (models.length === 0) return;
    let cancelled = false;
    for (const model of models) {
      setModelReadiness((prev) => ({
        ...prev,
        [model]: prev[model] ?? { state: "checking" },
      }));
      void invoke<MlxModelStatus>("mlx_model_status", { model })
        .then((status) => {
          if (cancelled) return;
          setModelReadiness((prev) => ({
            ...prev,
            [model]: status.available
              ? { state: "ready" }
              : {
                  state: "missing",
                  fallbackReady:
                    model === defaultModel()
                      ? false
                      : prev[defaultModel()]?.state === "ready",
                },
          }));
        })
        .catch(() => {
          if (cancelled) return;
          setModelReadiness((prev) => ({
            ...prev,
            [model]: { state: "offline" },
          }));
        });
    }
    onCleanup(() => {
      cancelled = true;
    });
  });

  const currentWorkspace = createMemo<Workspace | null>(() => {
    const id = currentWorkspaceId();
    if (id === null) return null;
    return (
      workspaces().find((w) => JSON.stringify(w.id) === JSON.stringify(id)) ?? null
    );
  });
  const activeWorkspaceTab = createMemo<WorkspaceTab | null>(() => {
    const id = activeWorkspaceTabId();
    if (id === null) return workspaceTabs()[0] ?? null;
    return workspaceTabs().find((tab) => tab.id === id) ?? workspaceTabs()[0] ?? null;
  });
  const activeTerminalTab = createMemo(() => {
    const tab = activeWorkspaceTab();
    return tab?.kind === "terminal" ? tab : null;
  });
  const activeNoteTab = createMemo(() => {
    const tab = activeWorkspaceTab();
    return tab?.kind === "note" ? tab : null;
  });
  // Page-mode driven by note tab being active. `inspectorMode` signal
  // is no longer authoritative — kept for the toggle button but we
  // ignore it for rendering decisions when a note tab is in play.
  const effectiveInspectorTitle = () => {
    const nt = activeNoteTab();
    if (nt) return nt.noteTitle;
    return inspectorTitle();
  };
  // Stable string-or-null. Used as the `<Show keyed>` key so the
  // multiplexer host re-mounts only when the active session ID actually
  // changes — not on every metadata update that produces a new session
  // object reference. Default Object.is equality on strings is fine.
  const activeTerminalSessionId = createMemo<string | null>(
    () => activeTerminalTab()?.id ?? null,
  );
  const terminalTabIds = createMemo(() => terminalPaneIdsForSessions(terminalSessions()).join("|"));

  function nextNativeTerminalGeneration() {
    nativeTerminalGenerationCounter += 1;
    setNativeTerminalGeneration(nativeTerminalGenerationCounter);
    return nativeTerminalGenerationCounter;
  }

  function hideAllNativeTerminals(generation: number) {
    void invoke("terminal_native_hide_all", { generation }).catch((e) =>
      console.error("terminal_native_hide_all failed:", e),
    );
  }

  const TERMINALS_KEY_PREFIX = "clome:terminalWorkspaceState:";

  function workspaceStorageId(workspaceId: WorkspaceId | null) {
    return workspaceId === null ? null : JSON.stringify(workspaceId);
  }

  function terminalStorageKey(workspaceId: WorkspaceId | null) {
    const id = workspaceStorageId(workspaceId);
    return id === null ? null : `${TERMINALS_KEY_PREFIX}${id}`;
  }

  function makeTerminalPaneId(sessionId: string) {
    return `${sessionId}:pane:${Date.now()}:${Math.random().toString(36).slice(2)}`;
  }

  function clampSplitRatio(value: unknown) {
    return typeof value === "number" && Number.isFinite(value)
      ? Math.min(0.85, Math.max(0.15, value))
      : 0.5;
  }

  function normalizeTerminalPane(value: unknown): TerminalPane | null {
    if (!value || typeof value !== "object") return null;
    const raw = value as Partial<TerminalPane>;
    if (typeof raw.id !== "string" || raw.id.trim().length === 0) return null;
    return {
      id: raw.id,
      title: typeof raw.title === "string" && raw.title.trim() ? raw.title : "terminal",
      cwd: typeof raw.cwd === "string" && raw.cwd.trim() ? raw.cwd : null,
    };
  }

  function normalizeTerminalLayout(
    value: unknown,
    paneIds: Set<string>,
    fallbackPaneId: string,
  ): TerminalLayout {
    if (!value || typeof value !== "object") {
      return { kind: "pane", paneId: fallbackPaneId };
    }
    const raw = value as Partial<TerminalLayout>;
    if (raw.kind === "pane") {
      const paneId = typeof raw.paneId === "string" && paneIds.has(raw.paneId)
        ? raw.paneId
        : fallbackPaneId;
      return { kind: "pane", paneId };
    }
    if (raw.kind === "split") {
      const split = raw as Partial<Extract<TerminalLayout, { kind: "split" }>>;
      const direction = split.direction === "column" ? "column" : "row";
      return {
        kind: "split",
        direction,
        ratio: clampSplitRatio(split.ratio),
        first: normalizeTerminalLayout(split.first, paneIds, fallbackPaneId),
        second: normalizeTerminalLayout(split.second, paneIds, fallbackPaneId),
      };
    }
    return { kind: "pane", paneId: fallbackPaneId };
  }

  function collectLayoutPaneIds(layout: TerminalLayout): string[] {
    if (layout.kind === "pane") return [layout.paneId];
    return [...collectLayoutPaneIds(layout.first), ...collectLayoutPaneIds(layout.second)];
  }

  function activePaneForSession(session: TerminalSession): TerminalPane {
    return (
      session.panes.find((pane) => pane.id === session.activePaneId) ??
      session.panes[0]
    );
  }

  function terminalPaneMeta(session: TerminalSession) {
    return terminalMeta()[activePaneForSession(session).id];
  }

  function terminalPaneIdsForSessions(sessions: TerminalSession[]) {
    return sessions.flatMap((session) => session.panes.map((pane) => pane.id));
  }

  function terminalPresentationFromPane(
    session: TerminalSession,
    metaById: Record<string, TerminalMeta> = terminalMeta(),
  ) {
    const activePane = activePaneForSession(session);
    const meta = metaById[activePane.id];
    return {
      title: meta?.displayTitle || activePane.title || session.title,
      cwd: meta?.cwd ?? activePane.cwd ?? session.cwd,
    };
  }

  function normalizeTerminalSessionPresentation(
    session: TerminalSession,
    metaById: Record<string, TerminalMeta> = terminalMeta(),
  ): TerminalSession {
    const presentation = terminalPresentationFromPane(session, metaById);
    return { ...session, title: presentation.title, cwd: presentation.cwd };
  }

  function normalizeTerminalSession(value: unknown): TerminalSession | null {
    if (!value || typeof value !== "object") return null;
    const raw = value as Partial<TerminalSession> & {
      panes?: unknown;
      layout?: unknown;
      activePaneId?: unknown;
    };
    if (raw.kind !== "terminal" || typeof raw.id !== "string") return null;
    const title = typeof raw.title === "string" && raw.title.trim() ? raw.title : "terminal";
    const cwd = typeof raw.cwd === "string" && raw.cwd.trim() ? raw.cwd : null;
    const panes = Array.isArray(raw.panes)
      ? raw.panes
          .map(normalizeTerminalPane)
          .filter((pane): pane is TerminalPane => pane !== null)
      : [];
    const normalizedPanes = panes.length > 0
      ? panes
      : [{ id: raw.id, title, cwd }];
    const paneIds = new Set(normalizedPanes.map((pane) => pane.id));
    const fallbackPaneId = normalizedPanes[0].id;
    const activePaneId =
      typeof raw.activePaneId === "string" && paneIds.has(raw.activePaneId)
        ? raw.activePaneId
        : fallbackPaneId;
    const layout = normalizeTerminalLayout(raw.layout, paneIds, fallbackPaneId);
    const layoutPaneIds = new Set(collectLayoutPaneIds(layout));
    const layoutSafePanes = normalizedPanes.filter((pane) => layoutPaneIds.has(pane.id));
    const finalPanes = layoutSafePanes.length > 0 ? layoutSafePanes : [normalizedPanes[0]];
    const finalPaneIds = new Set(finalPanes.map((pane) => pane.id));
    const finalActivePaneId = finalPaneIds.has(activePaneId) ? activePaneId : finalPanes[0].id;
    const finalLayout = normalizeTerminalLayout(layout, finalPaneIds, finalPanes[0].id);
    return normalizeTerminalSessionPresentation({
      id: raw.id,
      kind: "terminal",
      title,
      cwd,
      panes: finalPanes,
      activePaneId: finalActivePaneId,
      layout: finalLayout,
    });
  }

  function loadTerminalWorkspaceState(workspaceId: WorkspaceId | null): TerminalWorkspaceState {
    const key = terminalStorageKey(workspaceId);
    if (key === null) return { sessions: [], openIds: [], activeId: null };
    const stored = loadStored<Partial<TerminalWorkspaceState>>(key);
    const sessions = Array.isArray(stored?.sessions)
      ? stored.sessions
          .map(normalizeTerminalSession)
          .filter((tab): tab is TerminalSession => tab !== null)
      : [];
    const sessionIds = new Set(sessions.map((tab) => tab.id));
    const openIds = Array.isArray(stored?.openIds)
      ? stored.openIds.filter((id): id is string => typeof id === "string" && sessionIds.has(id))
      : [];
    const activeId =
      typeof stored?.activeId === "string" && openIds.includes(stored.activeId)
        ? stored.activeId
        : null;
    return { sessions, openIds, activeId };
  }

  // Note tabs persist per workspace as a list of titles. We don't store
  // the tab object — it's deterministic from title (id = `note:<title>`).
  const NOTE_TABS_KEY_PREFIX = "clome:noteTabs:";
  function noteTabsStorageKey(workspaceId: WorkspaceId | null) {
    const id = workspaceStorageId(workspaceId);
    return id === null ? null : `${NOTE_TABS_KEY_PREFIX}${id}`;
  }
  function loadNoteTabTitles(workspaceId: WorkspaceId | null): string[] {
    const key = noteTabsStorageKey(workspaceId);
    if (key === null) return [];
    const stored = loadStored<unknown>(key);
    return Array.isArray(stored)
      ? stored.filter((s): s is string => typeof s === "string")
      : [];
  }

  function restoreTerminalWorkspaceState(workspaceId: WorkspaceId | null) {
    setTerminalStateReady(false);
    const saved = loadTerminalWorkspaceState(workspaceId);
    const noteTitles = loadNoteTabTitles(workspaceId);
    setTerminalSessions(saved.sessions);
    setTerminalMeta({});
    setWorkspaceTabs((tabs) => {
      const chatTabs = tabs.filter((tab) => tab.kind === "chat");
      const openTerminals = saved.openIds
        .map((id) => saved.sessions.find((tab) => tab.id === id))
        .filter((tab): tab is TerminalSession => tab !== undefined);
      const noteTabs: WorkspaceTab[] = noteTitles.map((title) => ({
        id: noteTabId(title),
        kind: "note",
        title,
        noteTitle: title,
      }));
      return [...chatTabs, ...openTerminals, ...noteTabs];
    });
    if (saved.activeId) {
      setActiveWorkspaceTabId(saved.activeId);
    }
    setTerminalStateReady(true);
  }

  function closeNativeTerminalSessions(sessions: TerminalSession[]) {
    for (const tabId of terminalPaneIdsForSessions(sessions)) {
      invoke("terminal_native_close", {
        tabId,
        generation: nativeTerminalGeneration(),
      }).catch((e) => console.error("terminal_native_close failed:", e));
    }
  }

  function hideNativeTerminalSession(session: TerminalSession) {
    for (const pane of session.panes) {
      invoke("terminal_native_hide", {
        tabId: pane.id,
        generation: nativeTerminalGeneration(),
      }).catch((e) =>
        console.error("terminal_native_hide failed:", e),
      );
    }
  }

  createEffect(() => {
    const key = noteTabsStorageKey(currentWorkspaceId());
    if (key === null || !terminalStateReady()) return;
    const titles = workspaceTabs()
      .filter((tab): tab is Extract<WorkspaceTab, { kind: "note" }> => tab.kind === "note")
      .map((tab) => tab.noteTitle);
    localStorage.setItem(key, JSON.stringify(titles));
  });

  createEffect(() => {
    const key = terminalStorageKey(currentWorkspaceId());
    if (key === null || !terminalStateReady()) return;
    const sessions = terminalSessions();
    const sessionIds = new Set(sessions.map((tab) => tab.id));
    const openIds = workspaceTabs()
      .filter((tab) => tab.kind === "terminal" && sessionIds.has(tab.id))
      .map((tab) => tab.id);
    const active = activeWorkspaceTabId();
    const state: TerminalWorkspaceState = {
      sessions,
      openIds,
      activeId: active !== null && openIds.includes(active) ? active : null,
    };
    localStorage.setItem(key, JSON.stringify(state));
  });

  function applyTerminalMeta(meta: TerminalMeta) {
    if (!terminalPaneIdsForSessions(untrack(terminalSessions)).includes(meta.tabId)) return;

    const nextMeta = { ...untrack(terminalMeta), [meta.tabId]: meta };
    setTerminalMeta(nextMeta);
    setTerminalSessions((current) =>
      current.map((session) => {
        if (!session.panes.some((pane) => pane.id === meta.tabId)) return session;
        const panes = session.panes.map((pane) => {
          if (pane.id !== meta.tabId) return pane;
          const title = meta.displayTitle || pane.title;
          const cwd = meta.cwd ?? pane.cwd;
          if (title === pane.title && cwd === pane.cwd) return pane;
          return { ...pane, title, cwd };
        });
        return normalizeTerminalSessionPresentation({ ...session, panes }, nextMeta);
      }),
    );
    setWorkspaceTabs((current) =>
      current.map((tab) => {
        if (tab.kind !== "terminal" || !tab.panes.some((pane) => pane.id === meta.tabId)) {
          return tab;
        }
        const panes = tab.panes.map((pane) => {
          if (pane.id !== meta.tabId) return pane;
          const title = meta.displayTitle || pane.title;
          const cwd = meta.cwd ?? pane.cwd;
          if (title === pane.title && cwd === pane.cwd) return pane;
          return { ...pane, title, cwd };
        });
        return normalizeTerminalSessionPresentation({ ...tab, panes }, nextMeta);
      }),
    );
  }

  createEffect(() => {
    const tab = activeWorkspaceTab();
    const generation = nextNativeTerminalGeneration();
    if (tab?.kind !== "terminal") {
      hideAllNativeTerminals(generation);
    }
  });

  async function refreshTerminalMeta() {
    const paneIds = terminalPaneIdsForSessions(untrack(terminalSessions));
    if (paneIds.length === 0) {
      setTerminalMeta({});
      return;
    }

    const metas = await Promise.all(
      paneIds.map((tabId) =>
        invoke<TerminalMeta>("terminal_native_snapshot", { tabId })
          .catch((e) => {
            console.error("terminal_native_snapshot failed:", e);
            return null;
          }),
      ),
    );

    const next: Record<string, TerminalMeta> = {};
    for (const meta of metas) {
      if (meta) next[meta.tabId] = meta;
    }
    setTerminalMeta(next);

    for (const meta of metas) {
      if (meta) applyTerminalMeta(meta);
    }
  }

  createEffect(() => {
    const ids = terminalTabIds();
    if (!ids) return;
    void refreshTerminalMeta();
    const interval = window.setInterval(() => {
      void refreshTerminalMeta();
    }, 5000);
    onCleanup(() => window.clearInterval(interval));
  });

  // ── Persist current workspace + chat across reloads ────────────
  const WS_KEY = "clome:currentWorkspaceId";
  const CHAT_KEY = "clome:currentChatId";

  function loadStored<T = unknown>(key: string): T | null {
    try {
      const raw = localStorage.getItem(key);
      if (!raw) return null;
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  }

  // Read once at construction so the early refresh* calls see the saved id.
  const initialWs = loadStored<WorkspaceId>(WS_KEY);
  if (initialWs !== null) setCurrentWorkspaceId(initialWs);
  const initialChat = loadStored<ChatId>(CHAT_KEY);
  if (initialChat !== null) setCurrentChatId(initialChat);

  createEffect(() => {
    const ws = currentWorkspaceId();
    if (ws === null) localStorage.removeItem(WS_KEY);
    else localStorage.setItem(WS_KEY, JSON.stringify(ws));
  });
  createEffect(() => {
    const c = currentChatId();
    if (c === null) localStorage.removeItem(CHAT_KEY);
    else localStorage.setItem(CHAT_KEY, JSON.stringify(c));
  });
  createEffect(() => {
    const chatList = chats();
    setWorkspaceTabs((tabs) => {
      const next = tabs
        .map((tab) => {
          if (tab.kind !== "chat") return tab;
          const chat = chatList.find(
            (c) => JSON.stringify(c.id) === JSON.stringify(tab.chatId),
          );
          return chat
            ? { id: tab.id, kind: "chat" as const, title: chat.title, chatId: chat.id }
            : null;
        })
        .filter((tab): tab is WorkspaceTab => tab !== null);
      const active = activeWorkspaceTabId();
      if (active !== null && !next.some((tab) => tab.id === active)) {
        setActiveWorkspaceTabId(next[0]?.id ?? null);
      }
      return next;
    });
  });

  // Scroll-to-message after a search-pick deep-link.
  // Watches messages.length so it fires once hydration completes.
  createEffect(() => {
    const target = pendingScrollMsgId();
    void messages.length;
    if (target === null) return;
    const targetKey = JSON.stringify(target);
    const targetMsg = messages.find(
      (m) => m.dbId !== undefined && JSON.stringify(m.dbId) === targetKey,
    );
    if (!targetMsg) return;
    setPendingScrollMsgId(null);
    setStickToBottom(false);
    setHighlightMsgKey(targetMsg.id);
    queueMicrotask(() => {
      const el = document.querySelector(
        `[data-msg-key='${CSS.escape(targetKey)}']`,
      );
      el?.scrollIntoView({ block: "center", behavior: "smooth" });
    });
    setTimeout(() => {
      if (highlightMsgKey() === targetMsg.id) setHighlightMsgKey(null);
    }, 1800);
  });

  // Sidebar resize via right-edge handle
  let resizeStartX = 0;
  let resizeStartWidth = 0;
  function onResizeStart(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    window.getSelection()?.removeAllRanges();
    resizeStartX = e.clientX;
    resizeStartWidth = sidebarWidth();
    window.addEventListener("mousemove", onResizeMove);
    window.addEventListener("mouseup", onResizeEnd);
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    (document.body.style as any).webkitUserSelect = "none";
  }
  function onResizeMove(e: MouseEvent) {
    const dx = e.clientX - resizeStartX;
    const next = Math.min(420, Math.max(220, resizeStartWidth + dx));
    setSidebarWidth(next);
  }
  function onResizeEnd() {
    window.removeEventListener("mousemove", onResizeMove);
    window.removeEventListener("mouseup", onResizeEnd);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    (document.body.style as any).webkitUserSelect = "";
    window.getSelection()?.removeAllRanges();
  }

  // Inspector resize via left-edge handle. Inspector lives on the right
  // side of the layout — dragging the handle leftward should grow it,
  // so width increases as cursor moves left (dx negative → -dx added).
  let inspectorResizeStartX = 0;
  let inspectorResizeStartWidth = 0;
  function onInspectorResizeStart(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    window.getSelection()?.removeAllRanges();
    inspectorResizeStartX = e.clientX;
    inspectorResizeStartWidth = inspectorWidth();
    window.addEventListener("mousemove", onInspectorResizeMove);
    window.addEventListener("mouseup", onInspectorResizeEnd);
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    (document.body.style as any).webkitUserSelect = "none";
  }
  function onInspectorResizeMove(e: MouseEvent) {
    const dx = e.clientX - inspectorResizeStartX;
    const candidate = inspectorResizeStartWidth - dx;
    const snapAt = window.innerWidth * 0.9;
    if (candidate >= snapAt) {
      const t = inspectorTitle();
      if (t !== null) {
        // Reset to a sane width so when the user un-pins (closes the
        // note tab) the side panel comes back at a reasonable size,
        // not 90%-of-screen sticky.
        setInspectorWidth(416);
        pinNoteAsTab(t);
      }
      onInspectorResizeEnd();
      return;
    }
    setInspectorWidth(Math.max(300, candidate));
  }
  function onInspectorResizeEnd() {
    window.removeEventListener("mousemove", onInspectorResizeMove);
    window.removeEventListener("mouseup", onInspectorResizeEnd);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    (document.body.style as any).webkitUserSelect = "";
    window.getSelection()?.removeAllRanges();
  }

  function openNote(title: string) {
    // Each note gets its own workspace tab. If a tab for this title
    // already exists, just activate it; otherwise pin a fresh one.
    // `pinNoteAsTab` is idempotent (skips append when id present), so
    // calling it directly handles both cases.
    pinNoteAsTab(title);
  }
  function closeInspector() {
    // If the inspector is currently page-mode (note pinned as tab),
    // closing the X also dismisses the tab. Side-mode is just the
    // floating panel — clearing the title is enough.
    const note = untrack(activeNoteTab);
    if (note) closeNoteTabByTitle(note.noteTitle);
    setInspectorTitle(null);
  }
  function toggleInspectorMode() {
    // Page mode === note pinned as workspace tab. Side mode === floating
    // panel on the right. The expand button toggles between the two.
    const note = untrack(activeNoteTab);
    if (note) {
      // Un-pin the tab but keep inspectorTitle set so the side rail
      // shows the same note (tab → side restoration).
      const id = noteTabId(note.noteTitle);
      const tab = untrack(workspaceTabs).find((t) => t.id === id);
      if (tab) closeWorkspaceTab(tab);
      setInspectorTitle(note.noteTitle);
      return;
    }
    const t = inspectorTitle();
    if (t !== null) pinNoteAsTab(t);
  }
  let nextId = 0;
  let inputEl!: HTMLTextAreaElement;
  let chatScrollEl: HTMLElement | undefined;
  const [stickToBottom, setStickToBottom] = createSignal(true);
  const NEAR_BOTTOM_PX = 80;
  const COMPOSER_MAX_PX = 220;

  function isNearBottom(): boolean {
    if (!chatScrollEl) return true;
    const { scrollTop, scrollHeight, clientHeight } = chatScrollEl;
    return scrollHeight - (scrollTop + clientHeight) <= NEAR_BOTTOM_PX;
  }
  function scrollChatToBottom() {
    if (!chatScrollEl) return;
    chatScrollEl.scrollTop = chatScrollEl.scrollHeight;
  }
  function jumpToBottom() {
    setStickToBottom(true);
    scrollChatToBottom();
  }
  function onChatScroll() {
    const near = isNearBottom();
    if (stickToBottom() !== near) setStickToBottom(near);
  }
  function autoResizeComposer() {
    if (!inputEl) return;
    inputEl.style.height = "auto";
    inputEl.style.height = `${Math.min(inputEl.scrollHeight, COMPOSER_MAX_PX)}px`;
  }
  const unlisteners: UnlistenFn[] = [];

  function patch(turnId: number, mut: (m: Message) => void) {
    updateLiveTurn(turnId, mut);
    setMessages((msg) => msg.id === turnId, produce(mut));
  }

  async function refreshNotes() {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      setNotes(await invoke<Note[]>("list_notes", { workspaceId: ws }));
    } catch (e) {
      console.error("list_notes failed:", e);
    }
  }

  async function refreshFolders() {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      setFolders(await invoke<Folder[]>("list_folders", { workspaceId: ws }));
    } catch (e) {
      console.error("list_folders failed:", e);
    }
  }

  async function refreshChats() {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      const list = await invoke<Chat[]>("list_chats", { workspaceId: ws });
      setChats(list);
      const keepTerminalFocus = activeWorkspaceTab()?.kind === "terminal";
      if (currentChatId() === null && list.length > 0) {
        if (!keepTerminalFocus) await switchToChat(list[0]);
      } else {
        // currentChatId may now be stale (e.g. last chat deleted, or
        // workspace just changed).
        const stillExists = list.some(
          (c) => JSON.stringify(c.id) === JSON.stringify(currentChatId()),
        );
        if (!stillExists) {
          if (list.length > 0 && !keepTerminalFocus) {
            await switchToChat(list[0]);
          } else {
            setCurrentChatId(null);
            setMessages(() => []);
          }
        }
      }
    } catch (e) {
      console.error("list_chats failed:", e);
    }
  }

  async function refreshAgents() {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      setAgents(await invoke<Agent[]>("list_agents", { workspaceId: ws }));
    } catch (e) {
      console.error("list_agents failed:", e);
    }
  }

  async function refreshWorkspaces() {
    try {
      const list = await invoke<Workspace[]>("list_workspaces");
      setWorkspaces(list);
      // Default-select first workspace on cold start. Try to keep the
      // current one if it's still there.
      const current = currentWorkspaceId();
      const stillExists =
        current !== null &&
        list.some((w) => JSON.stringify(w.id) === JSON.stringify(current));
      if (!stillExists && list.length > 0) {
        await switchToWorkspace(list[0]);
      }
    } catch (e) {
      console.error("list_workspaces failed:", e);
    }
  }

  async function switchToWorkspace(ws: Workspace) {
    if (JSON.stringify(ws.id) === JSON.stringify(currentWorkspaceId())) {
      setWorkspacePickerOpen(false);
      return;
    }
    setTerminalStateReady(false);
    hideAllNativeTerminals(nextNativeTerminalGeneration());
    setCurrentWorkspaceId(ws.id);
    setCurrentChatId(null);
    setTerminalSessions([]);
    setTerminalMeta({});
    setWorkspaceTabs([]);
    setActiveWorkspaceTabId(null);
    setMessages(() => []);
    setNotes([]);
    setChats([]);
    setAgents([]);
    setInspectorTitle(null);
    setWorkspacePickerOpen(false);
    restoreTerminalWorkspaceState(ws.id);
    await Promise.all([
      refreshNotes(),
      refreshFolders(),
      refreshChats(),
      refreshAgents(),
    ]);
  }

  // (Removed `bindCurrentChatToAgent` single-binder — superseded by
  // `toggleChatAgent` for the multi-select picker. Server still
  // exposes `set_chat_agent` for callers that want single-agent
  // semantics.)

  // Group-chat: toggle a single agent in/out of the current chat's
  // bound agent list. Server-side `set_chat_agents` also keeps the
  // legacy `agent` field synced to `agents[0]`.
  async function toggleChatAgent(agent: Agent) {
    const chatId = currentChatId();
    if (chatId === null) return;
    const current = currentChatAgents();
    const has = current.some(
      (a) => JSON.stringify(a.id) === JSON.stringify(agent.id),
    );
    const nextIds = has
      ? current
          .filter((a) => JSON.stringify(a.id) !== JSON.stringify(agent.id))
          .map((a) => a.id)
      : [...current.map((a) => a.id), agent.id];
    try {
      await invoke("set_chat_agents", { chatId, agentIds: nextIds });
      await refreshChats();
    } catch (e) {
      console.error("set_chat_agents failed:", e);
    }
  }

  // Resolve `@agent-name` (case/space-insensitive) → bound agent. Used
  // by the composer to route the next turn in a multi-agent chat.
  // Returns null if no mention or none of the mentions match a bound
  // agent.
  function resolveAgentMention(text: string, bound: Agent[]): Agent | null {
    if (bound.length === 0) return null;
    const re = /@([\w\-]+)/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      const target = normalizeMentionName(m[1]);
      const hit = bound.find(
        (a) =>
          normalizeMentionName(a.name) === target ||
          normalizeMentionName(agentMentionSlug(a)) === target,
      );
      if (hit) return hit;
    }
    return null;
  }

  function buildTurnPlan(text: string, bound: Agent[]): TurnPlan {
    const compute = computeMode();
    const mentioned = bound.length >= 2 ? resolveAgentMention(text, bound) : null;
    const lead = mentioned ?? bound[0] ?? null;
    const lower = text.toLowerCase();
    const asksForMany =
      /\b(brainstorm|debate|critique|review|compare|tradeoff|plan|strategy|opinions|perspectives|what do you think)\b/.test(
        lower,
      );
    const deepRequested =
      compute === "deep" ||
      /\b(deep|thorough|careful|important|architecture|scheduler|compute|risk)\b/.test(
        lower,
      );

    if (!lead) {
      return {
        kind: "single",
        compute,
        speakerName: "Clome",
        speakerModel: defaultModel(),
        effectiveModel: defaultModel(),
        agentOverride: null,
        reason: "No room members are bound, so the default local chat model answers.",
        steps: [
          "Use the resident chat model",
          "Answer directly",
        ],
        groupSize: 0,
      };
    }

    if (mentioned) {
      return {
        kind: "direct",
        compute,
        speakerName: mentioned.name,
        speakerModel: mentioned.model,
        effectiveModel: mentioned.model,
        agentOverride: mentioned.id,
        reason: `Addressed to ${mentioned.name}; routing this turn directly.`,
        steps: [
          "Use the selected agent persona",
          compute === "deep" ? "Allow a slower specialist pass if available" : "Keep the reply focused",
        ],
        groupSize: bound.length,
      };
    }

    if (bound.length >= 2 && (asksForMany || deepRequested)) {
      return {
        kind: deepRequested ? "deep-review" : "lead-synthesis",
        compute,
        speakerName: lead.name,
        speakerModel: lead.model,
        effectiveModel: lead.model,
        agentOverride: lead.id,
        reason:
          "No agent was addressed, so the room lead answers with the group context in mind.",
        steps: [
          "Route through the room lead",
          asksForMany ? "Frame the answer as a synthesis" : "Check whether a specialist should be invited",
          compute === "fast"
            ? "Stay on the loaded model"
            : compute === "deep"
              ? "Permit specialist-model escalation when the backend scheduler is available"
              : "Prefer one loaded model and short agent passes",
        ],
        groupSize: bound.length,
      };
    }

    return {
      kind: bound.length >= 2 ? "lead-synthesis" : "single",
      compute,
      speakerName: lead.name,
      speakerModel: lead.model,
      effectiveModel: lead.model,
      agentOverride: lead.id,
      reason:
        bound.length >= 2
          ? "No agent was addressed; the room lead takes the turn."
          : "Single-agent chat; routing to the bound agent.",
      steps: [
        "Use one foreground generation",
        "Keep other local models idle",
      ],
      groupSize: bound.length,
    };
  }

  async function checkModelReadiness(model: string): Promise<ModelReadiness> {
    try {
      const status = await invoke<MlxModelStatus>("mlx_model_status", { model });
      const readiness: ModelReadiness = status.available
        ? { state: "ready" }
        : {
            state: "missing",
            fallbackReady:
              model === defaultModel()
                ? false
                : modelReadiness()[defaultModel()]?.state === "ready",
          };
      setModelReadiness((prev) => ({ ...prev, [model]: readiness }));
      return readiness;
    } catch {
      const readiness: ModelReadiness = { state: "offline" };
      setModelReadiness((prev) => ({ ...prev, [model]: readiness }));
      return readiness;
    }
  }

  async function prepareTurnPlan(plan: TurnPlan): Promise<TurnPlan> {
    const primary = await checkModelReadiness(plan.speakerModel);
    if (primary.state === "ready") {
      return { ...plan, effectiveModel: plan.speakerModel };
    }

    const fallback = await checkModelReadiness(defaultModel());
    if (fallback.state === "ready") {
      return {
        ...plan,
        effectiveModel: defaultModel(),
        modelWarning:
          primary.state === "offline"
            ? `MLX is not serving ${shortModelName(plan.speakerModel)}. Using ${shortModelName(defaultModel())} for this turn.`
            : `${shortModelName(plan.speakerModel)} is not loaded. Using ${shortModelName(defaultModel())} for this turn.`,
        steps: [
          ...plan.steps.filter((step) => !step.toLowerCase().includes("specialist-model")),
          "Fallback model selected before streaming",
        ],
      };
    }

    return {
      ...plan,
      modelWarning:
        primary.state === "offline"
          ? "MLX server is offline. Start the local model server and try again."
          : `${shortModelName(plan.speakerModel)} is not available, and the fallback model is not ready.`,
    };
  }

  function startNewWorkspace() {
    setNewWorkspaceDraft("");
    setCreatingWorkspace(true);
  }

  async function commitNewWorkspace() {
    const trimmed = newWorkspaceDraft().trim();
    setCreatingWorkspace(false);
    if (!trimmed) return;
    try {
      const ws = await invoke<Workspace | null>("create_workspace", { name: trimmed });
      if (ws) await switchToWorkspace(ws);
    } catch (e) {
      console.error("create_workspace failed:", e);
    }
  }

  function startRenameWorkspace(ws: Workspace) {
    setRenamingWorkspaceId(ws.id);
    setRenameDraft(ws.name);
  }

  async function commitWorkspaceRename(ws: Workspace) {
    const name = renameDraft().trim();
    setRenamingWorkspaceId(null);
    if (!name || name === ws.name) return;
    try {
      await invoke("rename_workspace", { workspaceId: ws.id, name });
    } catch (e) {
      console.error("rename_workspace failed:", e);
    }
  }

  function deleteWorkspaceWithConfirm(ws: Workspace) {
    if (workspaces().length <= 1) {
      // Silently no-op — the last workspace can't be removed. The
      // confirm modal also has this guard server-side.
      return;
    }
    setPendingDelete({ kind: "workspace", workspaceId: ws.id, name: ws.name });
    setWorkspacePickerOpen(false);
  }

  function chatTabId(chatId: ChatId): string {
    return `chat:${JSON.stringify(chatId)}`;
  }

  function openChatTab(chat: Chat) {
    const id = chatTabId(chat.id);
    setWorkspaceTabs((tabs) => {
      const exists = tabs.some((tab) => tab.id === id);
      if (exists) {
        return tabs.map((tab) =>
          tab.id === id ? { id, kind: "chat", title: chat.title, chatId: chat.id } : tab,
        );
      }
      return [...tabs, { id, kind: "chat", title: chat.title, chatId: chat.id }];
    });
    setActiveWorkspaceTabId(id);
  }

  async function activateWorkspaceTab(tab: WorkspaceTab) {
    setActiveWorkspaceTabId(tab.id);
    if (tab.kind === "chat") {
      setCurrentChatId(tab.chatId);
      await loadMessages(tab.chatId);
    } else if (tab.kind === "note") {
      // Sync inspector to this note so the page-mode renderer reads the
      // right title from `effectiveInspectorTitle`.
      setInspectorTitle(tab.noteTitle);
    }
  }

  // Note pinned as a workspace tab. Page-mode inspector renders into the
  // main column and the chat/terminal pane hides — the note becomes a
  // first-class tab instead of an overlay.
  function noteTabId(noteTitle: string) {
    return `note:${noteTitle}`;
  }
  function pinNoteAsTab(title: string) {
    const id = noteTabId(title);
    setWorkspaceTabs((tabs) => {
      if (tabs.some((t) => t.id === id)) return tabs;
      return [...tabs, { id, kind: "note", title, noteTitle: title }];
    });
    setActiveWorkspaceTabId(id);
    setInspectorTitle(title);
  }
  function closeNoteTabByTitle(noteTitle: string) {
    const id = noteTabId(noteTitle);
    const tab = untrack(workspaceTabs).find((t) => t.id === id);
    if (!tab) return;
    closeWorkspaceTab(tab);
    if (untrack(inspectorTitle) === noteTitle) {
      setInspectorTitle(null);
    }
  }

  function openTerminalTab(tab: TerminalSession) {
    setWorkspaceTabs((tabs) => {
      if (tabs.some((item) => item.id === tab.id)) return tabs;
      return [...tabs, tab];
    });
    setActiveWorkspaceTabId(tab.id);
  }

  // Single-instance mail tab. Re-clicking just refocuses; closing the
  // tab clears it and a fresh open re-mounts MailView.
  const MAIL_TAB_ID = "mail:inbox";
  function openMailTab() {
    setWorkspaceTabs((tabs) => {
      if (tabs.some((t) => t.id === MAIL_TAB_ID)) return tabs;
      return [...tabs, { id: MAIL_TAB_ID, kind: "mail", title: "Mail" }];
    });
    setActiveWorkspaceTabId(MAIL_TAB_ID);
  }

  // Single-instance knowledge graph tab. Mirrors the mail-tab pattern.
  const GRAPH_TAB_ID = "graph:vault";
  function openGraphTab() {
    setWorkspaceTabs((tabs) => {
      if (tabs.some((t) => t.id === GRAPH_TAB_ID)) return tabs;
      return [...tabs, { id: GRAPH_TAB_ID, kind: "graph", title: "Graph" }];
    });
    setActiveWorkspaceTabId(GRAPH_TAB_ID);
  }

  // Click router for graph nodes. Notes route to the inspector path
  // (existing flow); email_threads route to the mail tab. Future
  // kinds slot in here as their viewers ship.
  function routeGraphNodeClick(node: import("./lib/graph").NodeRow) {
    if (node.kind === "email_thread") {
      openMailTab();
      // Threads in the graph layer carry SurrealDB record ids; the
      // mail tab keys off the JWZ thread_id stored on the shadow row.
      // We don't have it directly here — the graph node was hydrated
      // from email_thread, and node.id is the surreal record. The
      // simplest reliable path: emit the surreal id and let MailApp
      // resolve via a lookup. Cheaper for now: leave the mail tab to
      // open at the inbox. Thread focus from the graph view is
      // covered by routeTypedRefClick below.
      return;
    }
    if (node.kind === "note") {
      openNote(node.label);
      return;
    }
    // Unknown kind — fall back to opening as a note (legacy behavior).
    openNote(node.label);
  }

  // Click router for typed inline references emitted by the agent
  // (e.g. `[[email:THREAD_ID|Subject]]` in a chat message). Routes
  // by `kind`; the `key` is whatever the agent emitted between
  // `kind:` and `|` — for emails, the JWZ thread_id.
  function routeTypedRefClick(ref: { kind: string; key: string }) {
    if (ref.kind === "email") {
      openMailTab();
      // MailApp listens for this event and selects the most recent
      // message in the thread. Decoupling via window event keeps
      // this function ignorant of MailApp's internals.
      window.dispatchEvent(
        new CustomEvent("clome:focus_email_thread", {
          detail: { threadId: ref.key },
        }),
      );
      return;
    }
    if (ref.kind === "chat") {
      // Future: hand the chat id to switchToChat. For now, no-op.
      console.warn("chat ref click not wired yet:", ref.key);
      return;
    }
    // event / file / project — slot in here as their viewers ship.
    console.warn("unhandled typed-ref kind:", ref);
  }

  function updateTerminalSession(
    sessionId: string,
    updater: (session: TerminalSession) => TerminalSession,
  ) {
    let updated: TerminalSession | null = null;
    setTerminalSessions((sessions) =>
      sessions.map((session) => {
        if (session.id !== sessionId) return session;
        updated = updater(session);
        return updated;
      }),
    );
    if (!updated) return;
    setWorkspaceTabs((tabs) =>
      tabs.map((tab) =>
        tab.kind === "terminal" && tab.id === sessionId ? updated! : tab,
      ),
    );
  }

  function applySplitRatio(
    layout: TerminalLayout,
    path: number[],
    ratio: number,
  ): TerminalLayout {
    if (path.length === 0) {
      if (layout.kind !== "split") return layout;
      return { ...layout, ratio };
    }
    if (layout.kind !== "split") return layout;
    const [head, ...rest] = path;
    if (head === 0)
      return { ...layout, first: applySplitRatio(layout.first, rest, ratio) };
    if (head === 1)
      return { ...layout, second: applySplitRatio(layout.second, rest, ratio) };
    return layout;
  }

  function updateTerminalSplitRatio(
    sessionId: string,
    path: number[],
    ratio: number,
  ) {
    updateTerminalSession(sessionId, (current) =>
      normalizeTerminalSessionPresentation({
        ...current,
        layout: applySplitRatio(current.layout, path, ratio),
      }),
    );
  }

  function insertTerminalSplit(
    layout: TerminalLayout,
    targetPaneId: string,
    newPaneId: string,
    direction: "row" | "column",
  ): TerminalLayout {
    if (layout.kind === "pane") {
      if (layout.paneId !== targetPaneId) return layout;
      return {
        kind: "split",
        direction,
        ratio: 0.5,
        first: layout,
        second: { kind: "pane", paneId: newPaneId },
      };
    }
    return {
      ...layout,
      first: insertTerminalSplit(layout.first, targetPaneId, newPaneId, direction),
      second: insertTerminalSplit(layout.second, targetPaneId, newPaneId, direction),
    };
  }

  function removeTerminalPaneFromLayout(
    layout: TerminalLayout,
    paneId: string,
  ): TerminalLayout | null {
    if (layout.kind === "pane") {
      return layout.paneId === paneId ? null : layout;
    }
    const first = removeTerminalPaneFromLayout(layout.first, paneId);
    const second = removeTerminalPaneFromLayout(layout.second, paneId);
    if (!first) return second;
    if (!second) return first;
    return { ...layout, first, second };
  }

  function focusTerminalPane(sessionId: string, paneId: string) {
    updateTerminalSession(sessionId, (session) => {
      if (!session.panes.some((pane) => pane.id === paneId)) return session;
      return normalizeTerminalSessionPresentation({
        ...session,
        activePaneId: paneId,
      });
    });
  }

  function splitTerminalPane(sessionId: string, direction: "row" | "column") {
    const session = terminalSessions().find((item) => item.id === sessionId);
    if (!session) return;
    const activePane = activePaneForSession(session);
    const activeMeta = terminalMeta()[activePane.id];
    const pane: TerminalPane = {
      id: makeTerminalPaneId(session.id),
      title: "terminal",
      cwd: activeMeta?.cwd ?? activePane.cwd ?? session.cwd,
    };
    updateTerminalSession(sessionId, (current) =>
      normalizeTerminalSessionPresentation({
        ...current,
        panes: [...current.panes, pane],
        activePaneId: pane.id,
        layout: insertTerminalSplit(
          current.layout,
          activePaneForSession(current).id,
          pane.id,
          direction,
        ),
      }),
    );
  }

  function closeTerminalPane(sessionId: string, paneId: string) {
    const session = terminalSessions().find((item) => item.id === sessionId);
    if (!session || session.panes.length <= 1) return;

    invoke("terminal_native_close", {
      tabId: paneId,
      generation: nativeTerminalGeneration(),
    }).catch((e) =>
      console.error("terminal_native_close failed:", e),
    );
    setTerminalMeta((current) => {
      const { [paneId]: _removed, ...rest } = current;
      return rest;
    });
    updateTerminalSession(sessionId, (current) => {
      const panes = current.panes.filter((pane) => pane.id !== paneId);
      const fallbackPaneId = panes[0]?.id ?? current.activePaneId;
      const layout =
        removeTerminalPaneFromLayout(current.layout, paneId) ??
        { kind: "pane", paneId: fallbackPaneId };
      const activePaneId =
        current.activePaneId === paneId ? fallbackPaneId : current.activePaneId;
      return normalizeTerminalSessionPresentation({
        ...current,
        panes,
        activePaneId,
        layout,
      });
    });
  }

  function newTerminalTab() {
    const count = terminalSessions().length + 1;
    const id = `terminal:${Date.now()}:${Math.random().toString(36).slice(2)}`;
    const pane: TerminalPane = {
      id,
      title: count === 1 ? "terminal" : `terminal ${count}`,
      cwd: null,
    };
    const tab: TerminalSession = {
      id,
      kind: "terminal",
      title: count === 1 ? "terminal" : `terminal ${count}`,
      cwd: null,
      panes: [pane],
      activePaneId: pane.id,
      layout: { kind: "pane", paneId: pane.id },
    };
    setTerminalSessions((tabs) => [...tabs, tab]);
    openTerminalTab(tab);
  }

  function terminalSidebarTitle(tab: TerminalSession) {
    const activePane = activePaneForSession(tab);
    return terminalMeta()[activePane.id]?.displayTitle || activePane.title || tab.title;
  }

  function terminalSidebarDetail(tab: TerminalSession) {
    const meta = terminalPaneMeta(tab);
    const path = meta?.pathLabel;
    const branch = meta?.git
      ? `${meta.git.branch}${meta.git.dirty ? "*" : ""}`
      : null;
    const panes = tab.panes.length > 1 ? `${tab.panes.length} panes` : "";
    const detail = branch && path ? `${branch} • ${path}` : branch ?? path ?? "";
    return [detail, panes].filter(Boolean).join(" • ");
  }

  function applyActiveTabAfterRemoval(removedTabId: string, before: WorkspaceTab[], nextTabs: WorkspaceTab[]) {
    if (activeWorkspaceTabId() !== removedTabId) return;
    const idx = before.findIndex((item) => item.id === removedTabId);
    const next = nextTabs[Math.max(0, Math.min(idx, nextTabs.length - 1))] ?? null;
    setActiveWorkspaceTabId(next?.id ?? null);
    if (next?.kind === "chat") {
      setCurrentChatId(next.chatId);
      void loadMessages(next.chatId);
    } else if (!next) {
      setMessages(() => []);
    }
  }

  function reorderWorkspaceTab(fromId: string, toIndex: number) {
    setWorkspaceTabs((tabs) => {
      const fromIndex = tabs.findIndex((t) => t.id === fromId);
      if (fromIndex < 0 || fromIndex === toIndex) return tabs;
      const next = [...tabs];
      const [moved] = next.splice(fromIndex, 1);
      // After removing fromIndex, every element with original index >
      // fromIndex shifts left by one — adjust insertion point so the
      // moved tab lands AT the target's original visual position.
      const insertAt = fromIndex < toIndex ? toIndex - 1 : toIndex;
      next.splice(insertAt, 0, moved);
      return next;
    });
  }

  function closeWorkspaceTab(tab: WorkspaceTab) {
    if (tab.kind === "terminal") {
      hideNativeTerminalSession(tab);
    }
    const before = workspaceTabs();
    const nextTabs = before.filter((item) => item.id !== tab.id);
    setWorkspaceTabs(nextTabs);
    applyActiveTabAfterRemoval(tab.id, before, nextTabs);
    // Closing a note tab while its inspector was the source of truth →
    // also close the inspector so it doesn't linger as a side panel
    // showing the just-dismissed note.
    if (tab.kind === "note" && untrack(inspectorTitle) === tab.noteTitle) {
      setInspectorTitle(null);
    }
  }

  function deleteTerminalSession(tab: TerminalSession) {
    closeNativeTerminalSessions([tab]);
    setTerminalSessions((sessions) => sessions.filter((item) => item.id !== tab.id));
    setTerminalMeta((current) => {
      const rest = { ...current };
      for (const pane of tab.panes) {
        delete rest[pane.id];
      }
      return rest;
    });
    const before = workspaceTabs();
    const nextTabs = before.filter((item) => item.id !== tab.id);
    setWorkspaceTabs(nextTabs);
    applyActiveTabAfterRemoval(tab.id, before, nextTabs);
  }

  async function loadMessages(chatId: ChatId) {
    try {
      const stored = await invoke<StoredMessage[]>("list_messages", { chatId });
      const hydrated: Message[] = stored.map((m, i) => ({
        id: i,
        role: m.role === "agent" ? "agent" : "user",
        text: m.content,
        status: "done",
        dbId: m.id,
        toolResults: m.tool_results ?? undefined,
      }));
      const merged = mergeLiveMessages(chatId, hydrated);
      setMessages(() => merged);
      nextId = nextMessageIdFor(merged);
      if (
        merged.some(
          (m) => m.role === "agent" && m.status === "streaming" && m.phase,
        )
      ) {
        ensurePhaseTicker();
      }
      setStickToBottom(true);
      queueMicrotask(scrollChatToBottom);
    } catch (e) {
      console.error("list_messages failed:", e);
      const live = mergeLiveMessages(chatId, []);
      setMessages(() => live);
      nextId = nextMessageIdFor(live);
    }
  }

  async function switchToChat(chat: Chat) {
    openChatTab(chat);
    setCurrentChatId(chat.id);
    await loadMessages(chat.id);
  }

  async function newChat() {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      const chat = await invoke<Chat | null>("create_chat", {
        workspaceId: ws,
        title: "New chat",
      });
      if (!chat) return;
      // Honor the user's default-agent setting: bind the new chat to it
      // before switching, so the first message goes through the right
      // system prompt + capabilities.
      const agentJson = defaultAgentJson();
      if (agentJson) {
        try {
          const agentId = JSON.parse(agentJson);
          await invoke("set_chat_agent", { chatId: chat.id, agentId });
          chat.agent = agentId;
        } catch (e) {
          console.error("set default agent failed:", e);
        }
      }
      await switchToChat(chat);
      await refreshChats();
    } catch (e) {
      console.error("create_chat failed:", e);
    }
  }

  function deleteNote(title: string) {
    setPendingDelete({ kind: "note", title });
  }

  function deleteChatWithConfirm(chat: Chat) {
    setPendingDelete({ kind: "chat", chatId: chat.id, title: chat.title });
  }

  async function confirmPendingDelete() {
    const p = pendingDelete();
    if (!p) return;
    setPendingDelete(null);
    const ws = currentWorkspaceId();
    try {
      if (p.kind === "note") {
        if (ws === null) return;
        await invoke("delete_note", { workspaceId: ws, title: p.title });
        if (inspectorTitle() === p.title) setInspectorTitle(null);
        // If this note was pinned as a workspace tab, drop it too —
        // the underlying note is gone, the tab would error on activate.
        closeNoteTabByTitle(p.title);
      } else if (p.kind === "chat") {
        await invoke("delete_chat", { chatId: p.chatId });
      } else if (p.kind === "folder") {
        await invoke("delete_folder", { folderId: p.folderId });
        await Promise.all([refreshFolders(), refreshNotes()]);
      } else {
        const removed = await invoke<boolean>("delete_workspace", {
          workspaceId: p.workspaceId,
        });
        if (!removed) {
          console.warn("delete_workspace refused: last workspace");
          return;
        }
        closeNativeTerminalSessions(loadTerminalWorkspaceState(p.workspaceId).sessions);
        const deletedTerminalKey = terminalStorageKey(p.workspaceId);
        if (deletedTerminalKey) localStorage.removeItem(deletedTerminalKey);
        const deletedNoteTabsKey = noteTabsStorageKey(p.workspaceId);
        if (deletedNoteTabsKey) localStorage.removeItem(deletedNoteTabsKey);
        // If we just nuked the active workspace, clear local state — the
        // workspaces:updated event will trigger refresh + auto-pick a new one.
        if (JSON.stringify(currentWorkspaceId()) === JSON.stringify(p.workspaceId)) {
          setTerminalStateReady(false);
          closeNativeTerminalSessions(terminalSessions());
          setCurrentWorkspaceId(null);
          setCurrentChatId(null);
          setTerminalSessions([]);
          setTerminalMeta({});
          setWorkspaceTabs([]);
          setActiveWorkspaceTabId(null);
          setMessages(() => []);
          setNotes([]);
          setChats([]);
          setInspectorTitle(null);
        }
      }
    } catch (e) {
      console.error("delete failed:", e);
    }
  }

  function startRenameChat(chat: Chat) {
    setRenamingChatId(chat.id);
    setRenameDraft(chat.title);
  }

  async function commitChatRename(chat: Chat) {
    const title = renameDraft().trim();
    setRenamingChatId(null);
    if (!title || title === chat.title) return;
    try {
      await invoke("rename_chat", { chatId: chat.id, title });
    } catch (e) {
      console.error("rename_chat failed:", e);
    }
  }

  function startRenameNote(title: string) {
    setRenamingNoteTitle(title);
    setRenameDraft(title);
  }

  async function commitNoteRename(oldTitle: string) {
    const newTitle = renameDraft().trim();
    setRenamingNoteTitle(null);
    if (!newTitle || newTitle === oldTitle) return;
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      await invoke("rename_note", { workspaceId: ws, oldTitle, newTitle });
      if (inspectorTitle() === oldTitle) setInspectorTitle(newTitle);
      renameNoteTab(oldTitle, newTitle);
    } catch (e) {
      console.error("rename_note failed:", e);
    }
  }

  function renameNoteTab(oldTitle: string, newTitle: string) {
    const oldId = noteTabId(oldTitle);
    const newId = noteTabId(newTitle);
    setWorkspaceTabs((tabs) =>
      tabs.map((t) =>
        t.kind === "note" && t.id === oldId
          ? { id: newId, kind: "note", title: newTitle, noteTitle: newTitle }
          : t,
      ),
    );
    if (untrack(activeWorkspaceTabId) === oldId) {
      setActiveWorkspaceTabId(newId);
    }
  }

  async function deleteChat(chat: Chat) {
    try {
      await invoke("delete_chat", { chatId: chat.id });
      // chats:updated listener will refresh + auto-switch if needed.
    } catch (e) {
      console.error("delete_chat failed:", e);
    }
  }

  // Debounced semantic backfill. Fires on every mention query change
  // but only invokes the backend once per ~140ms keystroke quiet
  // period; cancels in-flight responses via the seq guard.
  createEffect(() => {
    const m = mention();
    if (mentionSemanticTimer !== null) {
      window.clearTimeout(mentionSemanticTimer);
      mentionSemanticTimer = null;
    }
    if (!m.active || m.query.trim().length < 2) {
      setMentionSemanticHits([]);
      return;
    }
    const ws = currentWorkspaceId();
    if (ws === null) return;
    const q = m.query;
    const seq = ++mentionSemanticSeq;
    mentionSemanticTimer = window.setTimeout(() => {
      mentionSemanticTimer = null;
      void invoke<{ notes: { title: string; semantic_only?: boolean }[] }>(
        "search",
        { workspaceId: ws, query: q, limit: 12 },
      )
        .then((res) => {
          if (seq !== mentionSemanticSeq) return;
          // Keep only semantic-only hits — substring lane already
          // covers exact matches and we don't want to duplicate them.
          const titles = res.notes
            .filter((n) => n.semantic_only)
            .map((n) => n.title);
          setMentionSemanticHits(titles);
        })
        .catch((e) => console.error("mention semantic search:", e));
    }, 140);
  });

  const filteredItems = createMemo<MentionItem[]>(() => {
    const m = mention();
    if (!m.active) return [];
    const q = m.query.toLowerCase();
    const agentMatches = currentChatAgents()
      .filter((a) => a.name.toLowerCase().includes(q))
      .slice(0, 4)
      .map((a) => ({
        kind: "agent" as const,
        idKey: JSON.stringify(a.id),
        title: a.name,
        model: shortModelName(a.model),
      }));
    const allNotes = notes();
    const substringMatches = allNotes
      .filter((n) => n.title.toLowerCase().includes(q))
      .slice(0, 8)
      .map((n) => ({
        kind: "note" as const,
        title: n.title,
        source_kind: n.source_kind,
      }));
    const substringTitles = new Set(substringMatches.map((n) => n.title));
    // Append semantic-only hits (debounced backend) that aren't already
    // in the substring set. Cap total notes at 12 so the dropdown
    // doesn't grow unbounded.
    const semanticTitles = mentionSemanticHits();
    const noteByTitle = new Map(allNotes.map((n) => [n.title, n] as const));
    const semanticMatches = semanticTitles
      .filter((t) => !substringTitles.has(t))
      .map((t) => noteByTitle.get(t))
      .filter((n): n is Note => n !== undefined)
      .slice(0, Math.max(0, 12 - substringMatches.length))
      .map((n) => ({
        kind: "note" as const,
        title: n.title,
        source_kind: n.source_kind,
      }));
    return [...agentMatches, ...substringMatches, ...semanticMatches];
  });

  const showCreate = createMemo(() => {
    const m = mention();
    if (!m.active) return false;
    const q = m.query.trim();
    if (q.length === 0) return false;
    return !notes().some(
      (n) => n.title.toLowerCase() === q.toLowerCase(),
    );
  });

  const totalDropdownItems = createMemo(
    () => filteredItems().length + (showCreate() ? 1 : 0),
  );

  const filteredSidebarNotes = createMemo(() => {
    const q = sidebarFilter().trim().toLowerCase();
    const kinds = activeKindFilters();
    let list = notes();
    if (q) {
      list = list.filter(
        (n) =>
          n.title.toLowerCase().includes(q) ||
          n.body.toLowerCase().includes(q),
      );
    }
    if (kinds.size > 0) {
      list = list.filter((n) => kinds.has(n.source_kind));
    }
    if (notesSort() === "alphabetical") {
      list = [...list].sort((a, b) =>
        a.title.toLowerCase().localeCompare(b.title.toLowerCase()),
      );
    }
    // recency = default (already updated_at desc from backend)
    return list;
  });

  // Notes grouped by folder for the sidebar tree. Notes with no folder
  // bucket into `unfiled`. Folder lookup goes by JSON.stringify on the
  // opaque Thing id since SurrealDB Things are object-shaped over IPC.
  const notesByFolder = createMemo(() => {
    const list = filteredSidebarNotes();
    const buckets = new Map<string, Note[]>();
    buckets.set("__unfiled__", []);
    for (const f of folders()) {
      buckets.set(JSON.stringify(f.id), []);
    }
    for (const n of list) {
      const key = n.folder ? JSON.stringify(n.folder) : "__unfiled__";
      const arr = buckets.get(key);
      if (arr) arr.push(n);
      else buckets.set(key, [n]);
    }
    return buckets;
  });

  // Distinct source kinds present in the workspace — drives the kind
  // filter chip row. Recomputes on every notes change so the chip set
  // grows as the vault adds new kinds (chat, capture, web, …).
  const availableKinds = createMemo(() => {
    const out = new Map<string, number>();
    for (const n of notes()) {
      out.set(n.source_kind, (out.get(n.source_kind) ?? 0) + 1);
    }
    return out;
  });

  function toggleKindFilter(kind: string) {
    setActiveKindFilters((prev) => {
      const next = new Set(prev);
      if (next.has(kind)) next.delete(kind);
      else next.add(kind);
      return next;
    });
  }

  function toggleFolderCollapsed(key: string) {
    setCollapsedFolderIds((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  // Inline-create / inline-rename state for folders. We can't rely on
  // window.prompt / confirm — Tauri's WebKit webview no-ops them in
  // most macOS contexts, so the user sees nothing happen. Inline
  // inputs + the existing pendingDelete modal cover the same ground.
  const [creatingFolder, setCreatingFolder] = createSignal(false);
  const [folderDraft, setFolderDraft] = createSignal("");
  const [renamingFolderId, setRenamingFolderId] = createSignal<unknown | null>(
    null,
  );

  function startCreatingFolder() {
    setFolderDraft("");
    setCreatingFolder(true);
    if (notesCollapsed()) setNotesCollapsed(false);
  }

  async function commitCreateFolder() {
    const ws = currentWorkspaceId();
    const name = folderDraft().trim();
    setCreatingFolder(false);
    setFolderDraft("");
    if (ws === null || !name) return;
    try {
      await invoke("create_folder", { workspaceId: ws, name });
      await refreshFolders();
    } catch (e) {
      console.error("create_folder failed:", e);
    }
  }

  function startRenameFolder(folder: Folder) {
    setRenamingFolderId(folder.id);
    setFolderDraft(folder.name);
  }

  async function commitRenameFolder(folder: Folder) {
    const next = folderDraft().trim();
    setRenamingFolderId(null);
    setFolderDraft("");
    if (!next || next === folder.name) return;
    try {
      await invoke("rename_folder", { folderId: folder.id, name: next });
      await refreshFolders();
    } catch (e) {
      console.error("rename_folder failed:", e);
    }
  }

  async function moveNoteToFolder(title: string, folderId: unknown | null) {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    try {
      await invoke("set_note_folder", {
        workspaceId: ws,
        title,
        folderId,
      });
      await refreshNotes();
    } catch (e) {
      console.error("set_note_folder failed:", e);
    }
  }

  function requestDeleteFolder(folder: Folder) {
    setPendingDelete({ kind: "folder", folderId: folder.id, name: folder.name });
  }

  onMount(async () => {
    // Reset native generation epoch FIRST — Rust `latest_generation`
    // persists across webview reloads but the JS counter restarts at 0.
    // Without this, every `terminal_native_show` after a reload trips
    // `is_stale` and returns false, leaving panes stuck on
    // "starting terminal..." until the JS counter naturally catches up
    // through tab interactions (minutes). Surfaces are kept by tabId
    // in the runtime, so reattach after reset is instant.
    void invoke("terminal_native_reset_generation").catch((e) =>
      console.error("terminal_native_reset_generation failed:", e),
    );

    // Pre-warm ghostty (config load, GPU pipeline, font atlas) so the
    // first user-visible terminal attach is instant.
    void invoke("terminal_native_prewarm").catch((e) =>
      console.error("terminal_native_prewarm failed:", e),
    );

    // Install NSEvent local monitor for app-level shortcuts. Without it,
    // a focused ghostty surface eats Cmd+K / Cmd+Shift+K / Cmd+, and the
    // JS keydown handler never fires.
    void invoke("terminal_native_install_app_shortcuts").catch((e) =>
      console.error("terminal_native_install_app_shortcuts failed:", e),
    );

    // Global escape: clear any modal / rename UI state if something gets
    // stuck. Belt-and-suspenders against the kind of "buttons don't work"
    // freeze a transparent / mis-rendered modal can cause.
    const onGlobalKey = (e: KeyboardEvent) => {
      // Cmd+K (or Ctrl+K) → search palette
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k" && !e.shiftKey) {
        e.preventDefault();
        setSearchOpen((v) => !v);
        return;
      }
      if (e.key === "Escape") {
        if (settingsOpen()) {
          setSettingsOpen(false);
        } else if (pendingDelete()) {
          setPendingDelete(null);
        } else if (renamingChatId() !== null) {
          setRenamingChatId(null);
        } else if (renamingNoteTitle() !== null) {
          setRenamingNoteTitle(null);
        } else if (renamingWorkspaceId() !== null) {
          setRenamingWorkspaceId(null);
        } else if (workspacePickerOpen()) {
          setWorkspacePickerOpen(false);
        } else if (sidebarPeek()) {
          cancelPeekDismiss();
          setSidebarPeek(false);
        }
      }
    };
    window.addEventListener("keydown", onGlobalKey);
    onCleanup(() => window.removeEventListener("keydown", onGlobalKey));

    // System theme change → re-resolve when on "system" pref.
    const mql = window.matchMedia("(prefers-color-scheme: light)");
    const onSysTheme = () => {
      if (untrack(themePref) !== "system") return;
      document.documentElement.dataset.theme = mql.matches ? "light" : "dark";
    };
    mql.addEventListener("change", onSysTheme);
    onCleanup(() => mql.removeEventListener("change", onSysTheme));

    unlisteners.push(
      await listen<TerminalMeta>("terminal:metadata", (e) => {
        applyTerminalMeta(e.payload);
      }),
    );
    unlisteners.push(
      await listen<string>("app:shortcut", (e) => {
        // Native NSEvent monitor caught an app shortcut while a ghostty
        // surface was first responder. Route to the same handlers the
        // window keydown listener uses.
        switch (e.payload) {
          case "cmd+k":
            setSearchOpen((v) => !v);
            return;
          case "cmd+shift+k":
            setCaptureOpen((v) => !v);
            return;
          case "cmd+,":
            setSettingsOpen((v) => !v);
            return;
        }
      }),
    );
    unlisteners.push(
      await listen<string>("terminal:focus", (e) => {
        const paneId = e.payload;
        const session = untrack(terminalSessions).find((s) =>
          s.panes.some((p) => p.id === paneId),
        );
        if (!session) return;
        focusTerminalPane(session.id, paneId);
      }),
    );
    unlisteners.push(
      await listen<{ tabId: string; shortcut: string }>(
        "terminal:shortcut",
        (e) => {
          const { tabId: paneId, shortcut } = e.payload;
          const session = untrack(terminalSessions).find((s) =>
            s.panes.some((p) => p.id === paneId),
          );
          if (!session) return;
          switch (shortcut) {
            case "split-right":
              focusTerminalPane(session.id, paneId);
              splitTerminalPane(session.id, "row");
              return;
            case "split-down":
              focusTerminalPane(session.id, paneId);
              splitTerminalPane(session.id, "column");
              return;
            case "close-pane":
              if (session.panes.length > 1) {
                closeTerminalPane(session.id, paneId);
              } else {
                // Last pane → close the whole session like a normal tab.
                const wsTab = untrack(workspaceTabs).find(
                  (t) => t.id === session.id,
                );
                if (wsTab) closeWorkspaceTab(wsTab);
              }
              return;
            case "new-terminal":
              newTerminalTab();
              return;
            case "focus-prev":
            case "focus-next": {
              const ids = session.panes.map((p) => p.id);
              if (ids.length <= 1) return;
              const idx = ids.indexOf(paneId);
              if (idx < 0) return;
              const step = shortcut === "focus-next" ? 1 : -1;
              const nextId = ids[(idx + step + ids.length) % ids.length];
              focusTerminalPane(session.id, nextId);
              // Re-show the new active pane to grab native focus.
              return;
            }
          }
        },
      ),
    );

    await refreshWorkspaces();
    if (currentWorkspaceId() !== null && !terminalStateReady()) {
      restoreTerminalWorkspaceState(currentWorkspaceId());
    }
    await Promise.all([refreshNotes(), refreshFolders()]);
    await refreshChats();
    await refreshAgents();
    unlisteners.push(
      await listen<TokenEvent>("chat:token", (e) => {
        patch(e.payload.turnId, (m) => {
          m.text += e.payload.token;
          // First token of this iteration → flip from "thinking" to
          // "writing". Subsequent tokens leave the phase alone so the
          // strip's elapsed timer keeps counting from when streaming
          // actually started, not from each token.
          if (m.phase !== "writing") {
            m.phase = "writing";
            m.phaseStartedAt = Date.now();
          }
        });
        if (stickToBottom()) queueMicrotask(scrollChatToBottom);
      }),
    );
    unlisteners.push(
      await listen<DoneEvent>("chat:done", (e) => {
        patch(e.payload.turnId, (m) => {
          m.status = "done";
          // Defensive: backend always emits tool_end before done, but
          // make sure the pill never lingers if a request errors out.
          m.toolRunning = false;
          m.toolAction = undefined;
          m.toolTarget = undefined;
          m.toolSecondary = undefined;
          m.phase = undefined;
          m.phaseStartedAt = undefined;
        });
        setBusy(false);
        if (activeTurnId() === e.payload.turnId) setActiveTurnId(null);
        clearLiveTurn(e.payload.turnId);
      }),
    );
    unlisteners.push(
      await listen<ErrorEvent>("chat:error", (e) => {
        patch(e.payload.turnId, (m) => {
          m.text = m.text || `error: ${e.payload.message}`;
          m.status = "error";
          m.toolRunning = false;
          m.toolAction = undefined;
          m.toolTarget = undefined;
          m.toolSecondary = undefined;
          m.phase = undefined;
          m.phaseStartedAt = undefined;
        });
        setBusy(false);
        if (activeTurnId() === e.payload.turnId) setActiveTurnId(null);
      }),
    );
    unlisteners.push(
      await listen<{
        turnId: number;
        action: string;
        target?: string | null;
        secondary?: string | null;
      }>("chat:tool_start", (e) => {
        patch(e.payload.turnId, (m) => {
          m.toolRunning = true;
          m.toolAction = e.payload.action;
          m.toolTarget = e.payload.target ?? undefined;
          m.toolSecondary = e.payload.secondary ?? undefined;
          m.phase = "tool";
          m.phaseStartedAt = Date.now();
        });
      }),
    );
    unlisteners.push(
      await listen<{ turnId: number; action: string }>("chat:tool_end", (e) => {
        patch(e.payload.turnId, (m) => {
          m.toolRunning = false;
          m.toolAction = undefined;
          m.toolTarget = undefined;
          m.toolSecondary = undefined;
          // After a tool finishes we sit in "thinking" again until
          // the next iteration emits its first token (the model
          // reads the result, decides what to write next, then
          // streams). The phase strip thus reads "thinking · 4s"
          // during that quiet stretch instead of going dark.
          m.phase = "thinking";
          m.phaseStartedAt = Date.now();
        });
      }),
    );
    unlisteners.push(
      await listen<ToolResult & { turnId: number }>("chat:tool_result", (e) => {
        patch(e.payload.turnId, (m) => {
          if (!m.toolResults) m.toolResults = [];
          // Backend uses index as the canonical position; assign by
          // index so out-of-order delivery (rare but possible) doesn't
          // misalign chips with cards.
          m.toolResults[e.payload.index] = {
            index: e.payload.index,
            action: e.payload.action,
            headers: e.payload.headers,
            result: e.payload.result,
          };
        });
      }),
    );
    unlisteners.push(
      await listen("vault:updated", () => {
        void refreshNotes();
        void refreshFolders();
      }),
    );
    unlisteners.push(
      await listen("capture:open", () => setCaptureOpen(true)),
    );
    unlisteners.push(
      await listen("chats:updated", () => refreshChats()),
    );
    unlisteners.push(
      await listen("workspaces:updated", () => refreshWorkspaces()),
    );
    unlisteners.push(
      await listen("agents:updated", () => refreshAgents()),
    );
    unlisteners.push(
      await listen<ActivityItem>("agent:activity", (e) => {
        setActivity((arr) => [e.payload, ...arr].slice(0, 50));
      }),
    );
  });

  onCleanup(() => unlisteners.forEach((u) => u()));

  function handleInput(e: InputEvent & { currentTarget: HTMLTextAreaElement }) {
    setInput(e.currentTarget.value);
    detectMention(e.currentTarget);
    autoResizeComposer();
  }

  function detectMention(el: HTMLTextAreaElement) {
    const value = el.value;
    const caret = el.selectionStart ?? value.length;
    const before = value.slice(0, caret);
    const atIdx = before.lastIndexOf("@");
    if (atIdx >= 0) {
      const between = before.slice(atIdx + 1);
      if (!/[\s\[\]]/.test(between)) {
        setMention({ active: true, atIdx, query: between });
        setMentionSelected(0);
        return;
      }
    }
    setMention({ active: false });
  }

  function replaceActiveMention(replacement: string) {
    const m = mention();
    if (!m.active) return null;
    const value = input();
    const before = value.slice(0, m.atIdx);
    const after = value.slice(m.atIdx + 1 + m.query.length);
    const next = `${before}${replacement}${after}`;
    setInput(next);
    setMention({ active: false });
    setMentionSelected(0);
    return { before, caret: before.length + replacement.length };
  }

  function focusComposerAt(caret: number) {
    queueMicrotask(() => {
      if (!inputEl) return;
      inputEl.focus();
      inputEl.setSelectionRange(caret, caret);
      autoResizeComposer();
    });
  }

  function pickMention(item: MentionItem) {
    if (item.kind === "agent") {
      const agent = currentChatAgents().find(
        (a) => JSON.stringify(a.id) === item.idKey,
      );
      const slug = agent ? agentMentionSlug(agent) : item.title;
      const result = replaceActiveMention(`@${slug} `);
      if (result) focusComposerAt(result.caret);
      return;
    }

    const result = replaceActiveMention(`[[${item.title}]]`);
    if (result) focusComposerAt(result.caret);
  }

  function createMentionedNote(title: string) {
    const result = replaceActiveMention(`[[${title}]]`);
    if (result) {
      const ws = currentWorkspaceId();
      if (ws !== null) {
        invoke("create_note", { workspaceId: ws, title, sourceKind: "manual" }).catch(
          (e) => console.error("create_note failed:", e),
        );
      }
      focusComposerAt(result.caret);
    }
  }

  function handleKeyDown(e: KeyboardEvent) {
    const m = mention();

    if (m.active) {
      const total = totalDropdownItems();
      if (total === 0 && e.key !== "Escape") return;

      if (e.key === "ArrowDown") {
        e.preventDefault();
        setMentionSelected((s) => (s + 1) % total);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setMentionSelected((s) => (s - 1 + total) % total);
      } else if (e.key === "Enter") {
        e.preventDefault();
        e.stopPropagation();
        const idx = mentionSelected();
        const items = filteredItems();
        if (idx < items.length) pickMention(items[idx]);
        else if (showCreate()) createMentionedNote(m.query);
      } else if (e.key === "Escape") {
        e.preventDefault();
        setMention({ active: false });
      }
      return;
    }

    // No active mention: Enter alone submits, Shift+Enter inserts newline.
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void send();
    }
  }

  async function send() {
    const text = input().trim();
    if (!text || busy()) return;
    if (mention().active) return;

    setInput("");
    autoResizeComposer();
    setBusy(true);
    setStickToBottom(true);

    const userId = nextId++;
    const agentId = nextId++;
    const chatId = currentChatId();
    const ws = currentWorkspaceId();
    setActiveTurnId(agentId);
    const plan = await prepareTurnPlan(buildTurnPlan(text, currentChatAgents()));
    const history = buildPromptHistory(messages, text);
    const userMessage: Message = { id: userId, role: "user", text, status: "done" };
    const agentMessage: Message = {
      id: agentId,
      role: "agent",
      text: "",
      status: "streaming",
      turnPlan: plan,
      phase: "thinking",
      phaseStartedAt: Date.now(),
    };

    setMessages((m) => [
      ...m,
      userMessage,
      agentMessage,
    ]);
    ensurePhaseTicker();
    if (chatId !== null) rememberLiveTurn(chatId, userMessage, agentMessage);
    queueMicrotask(scrollChatToBottom);

    if (ws !== null) {
      for (const title of extractLinkTitles(text)) {
        invoke("create_note", { workspaceId: ws, title, sourceKind: "manual" }).catch(
          (e) => console.error("create_note failed:", e),
        );
      }
    }

    if (chatId === null || ws === null) {
      patch(agentId, (m) => {
        m.text =
          ws === null
            ? "no active workspace"
            : "no active chat — create one first";
        m.status = "error";
      });
      setBusy(false);
      setActiveTurnId(null);
      return;
    }

    const selectedReadiness = readinessForModel(plan.effectiveModel);
    if (selectedReadiness?.state !== "ready") {
      patch(agentId, (m) => {
        m.text = plan.modelWarning ?? "local model is not ready";
        m.status = "error";
      });
      setBusy(false);
      setActiveTurnId(null);
      return;
    }

    try {
      await invoke("chat_stream", {
        workspaceId: ws,
        chatId,
        turnId: agentId,
        model: defaultModel(),
        modelOverride:
          plan.effectiveModel !== plan.speakerModel ? plan.effectiveModel : null,
        messages: [
          {
            role: "system",
            content:
              SYSTEM_PROMPT +
              " " +
              `Room turn plan: ${turnPlanLabel(plan.kind)}. ` +
              `Compute mode: ${computeModeLabel(plan.compute)}. ` +
              `Speaker: ${plan.speakerName}. ` +
              `Effective model: ${plan.effectiveModel}. ` +
              `Reason: ${plan.reason}`,
          },
          ...history,
        ],
        agentOverride: plan.agentOverride,
      });
    } catch (e) {
      patch(agentId, (m) => {
        m.text = `invoke failed: ${e}`;
        m.status = "error";
      });
      setBusy(false);
      setActiveTurnId(null);
    }
  }

  async function cancelStream() {
    const turnId = activeTurnId();
    if (turnId === null) return;
    try {
      await invoke("chat_cancel", { turnId });
    } catch (e) {
      console.error("chat_cancel failed:", e);
    }
  }

  function copyMessage(id: number, text: string) {
    navigator.clipboard.writeText(text).then(
      () => {
        setLastCopiedId(id);
        setTimeout(() => {
          if (lastCopiedId() === id) setLastCopiedId(null);
        }, 1400);
      },
      (e) => console.error("clipboard write failed:", e),
    );
  }

  async function createBlankNote() {
    const ws = currentWorkspaceId();
    if (ws === null) return;
    const stamp = new Date()
      .toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      })
      .replace(",", "");
    const title = `Untitled ${stamp}`;
    try {
      await invoke("create_note", { workspaceId: ws, title, sourceKind: "manual" });
      openNote(title);
    } catch (e) {
      console.error("create_note failed:", e);
    }
  }

  return (
    <main class="app-shell flex h-screen overflow-hidden bg-bg">
      {/* Hover trigger: thin invisible strip on the left edge that opens
          a peek sidebar when the user nudges the cursor against it. Only
          rendered while sidebar is collapsed. */}
      <Show when={!sidebarOpen()}>
        <div
          class="sidebar-peek-trigger"
          onMouseEnter={openSidebarPeek}
        />
      </Show>
      {/* Sidebar — Slack/Notion pattern: dense, sectioned, collapsible, resizable */}
      <Show when={sidebarOpen() || sidebarPeek()}>
        <aside
          class="app-sidebar relative flex shrink-0 flex-col bg-bg-panel"
          classList={{ "app-sidebar--peek": !sidebarOpen() && sidebarPeek() }}
          style={{ width: `${sidebarWidth()}px` }}
          onMouseEnter={() => {
            if (!sidebarOpen()) cancelPeekDismiss();
          }}
          onMouseLeave={() => {
            if (!sidebarOpen()) scheduleSidebarPeekClose();
          }}
        >
          {/* Traffic-light spacer — invisible but draggable */}
          <div
            data-tauri-drag-region
            class="h-[36px] shrink-0 select-none"
          />

          {/* Workspace row: text-only name + chevron + compose + close.
              Mirrors Slack: workspace switcher | edit (compose) icon */}
          <header
            data-tauri-drag-region
            class="sidebar-header shrink-0 select-none px-3 pb-3"
          >
            <div class="relative flex items-center gap-0.5">
              <button
                type="button"
                onClick={() => setWorkspacePickerOpen((v) => !v)}
                class="workspace-switcher group flex h-9 min-w-0 flex-1 items-center gap-2 px-2"
                title="Switch workspace"
              >
                <span class="workspace-switcher__mark">
                  {(currentWorkspace()?.name ?? "C").slice(0, 1).toUpperCase()}
                </span>
                <span class="min-w-0 flex-1 text-left">
                  <span class="block truncate text-[13.5px] font-semibold text-text">
                    {currentWorkspace()?.name ?? "—"}
                  </span>
                  <span class="block truncate text-[10.5px] text-text-subtle">
                    Local workspace
                  </span>
                </span>
                <ChevronDown
                  size={13}
                  strokeWidth={2.5}
                  class="shrink-0 text-text-dim transition-colors group-hover:text-text"
                />
              </button>
              <Show when={workspacePickerOpen()}>
                <div
                  class="surface-raised absolute left-0 top-full z-50 mt-1 w-56 overflow-hidden rounded-xl"
                  onClick={(e) => e.stopPropagation()}
                >
                  <For each={workspaces()}>
                    {(w) => {
                      const isActive = () =>
                        JSON.stringify(w.id) === JSON.stringify(currentWorkspaceId());
                      const isRenaming = () =>
                        JSON.stringify(w.id) === JSON.stringify(renamingWorkspaceId());
                      return (
                        <Show
                          when={!isRenaming()}
                          fallback={
                            <div class="flex items-center gap-2 px-3 py-1.5">
                              <input
                                ref={(el) =>
                                  queueMicrotask(() => {
                                    el?.focus();
                                    el?.select();
                                  })
                                }
                                value={renameDraft()}
                                onInput={(e) => setRenameDraft(e.currentTarget.value)}
                                onKeyDown={(e) => {
                                  if (e.key === "Enter") {
                                    e.preventDefault();
                                    void commitWorkspaceRename(w);
                                  } else if (e.key === "Escape") {
                                    e.preventDefault();
                                    setRenamingWorkspaceId(null);
                                  }
                                }}
                                onBlur={() => void commitWorkspaceRename(w)}
                                class="input-pill w-full px-2 py-1 text-[13px]"
                              />
                            </div>
                          }
                        >
                          <div
                            class="list-row group/wsrow flex w-full items-center gap-2 px-3 py-2 text-[13px]"
                            classList={{
                              "list-row--active font-semibold": isActive(),
                              "text-text-muted": !isActive(),
                            }}
                          >
                            <button
                              type="button"
                              onClick={() => switchToWorkspace(w)}
                              class="flex min-w-0 flex-1 items-center justify-between gap-2 text-left"
                            >
                              <span class="truncate">{w.name}</span>
                              <Show when={isActive()}>
                                <span class="font-mono text-[10px] text-accent">●</span>
                              </Show>
                            </button>
                            <button
                              type="button"
                              onClick={(e) => {
                                e.stopPropagation();
                                startRenameWorkspace(w);
                              }}
                              title="Rename workspace"
                              class="control-icon flex size-5 opacity-0 group-hover/wsrow:opacity-100"
                            >
                              <Pencil size={11} strokeWidth={2} />
                            </button>
                            <button
                              type="button"
                              onClick={(e) => {
                                e.stopPropagation();
                                deleteWorkspaceWithConfirm(w);
                              }}
                              title="Delete workspace"
                              class="control-icon flex size-5 opacity-0 hover:text-danger group-hover/wsrow:opacity-100"
                            >
                              <Trash2 size={11} strokeWidth={2} />
                            </button>
                          </div>
                        </Show>
                      );
                    }}
                  </For>
                  <div class="border-t border-border" />
                  <Show
                    when={creatingWorkspace()}
                    fallback={
                      <button
                        type="button"
                        onClick={startNewWorkspace}
                        class="list-row flex w-full items-center gap-2 px-3 py-2 text-left text-[13px]"
                      >
                        <Plus size={12} strokeWidth={2.25} />
                        <span>new workspace</span>
                      </button>
                    }
                  >
                    <div class="flex items-center gap-2 px-2 py-1.5">
                      <Plus size={12} strokeWidth={2.25} class="shrink-0 text-text-dim" />
                      <input
                        ref={(el) =>
                          queueMicrotask(() => {
                            el?.focus();
                          })
                        }
                        value={newWorkspaceDraft()}
                        onInput={(e) =>
                          setNewWorkspaceDraft(e.currentTarget.value)
                        }
                        onKeyDown={(e) => {
                          if (e.key === "Enter") {
                            e.preventDefault();
                            void commitNewWorkspace();
                          } else if (e.key === "Escape") {
                            e.preventDefault();
                            setCreatingWorkspace(false);
                          }
                        }}
                        onBlur={() => void commitNewWorkspace()}
                        placeholder="workspace name…"
                        class="input-pill w-full px-2 py-1 text-[13px]"
                      />
                    </div>
                  </Show>
                </div>
              </Show>
              <button
                type="button"
                onClick={openMailTab}
                title="Open Mail"
                class="control-icon flex size-8 shrink-0"
              >
                <Mail size={14} strokeWidth={1.75} />
              </button>
              <Show when={graphEnabled()}>
                <button
                  type="button"
                  onClick={openGraphTab}
                  title="Open knowledge graph"
                  class="control-icon flex size-8 shrink-0"
                >
                  <Network size={14} strokeWidth={1.75} />
                </button>
              </Show>
              <button
                type="button"
                onClick={createBlankNote}
                title="New note"
                class="control-icon flex size-8 shrink-0"
              >
                <SquarePen size={14} strokeWidth={1.75} />
              </button>
              <button
                type="button"
                onClick={() => setSidebarOpen(false)}
                title="Hide vault"
                class="control-icon flex size-8 shrink-0"
              >
                <PanelLeftClose size={14} strokeWidth={1.75} />
              </button>
            </div>
          </header>

          {/* Search */}
          <div class="shrink-0 px-3 pb-3">
            <div class="input-pill text-[13px]">
              <Search
                size={13}
                strokeWidth={2}
                class="shrink-0 text-text-subtle"
              />
              <input
                type="text"
                value={sidebarFilter()}
                onInput={(e) => setSidebarFilter(e.currentTarget.value)}
                placeholder="Search vault…"
              />
            </div>
          </div>

          {/* Chats section — collapsible list of chat threads */}
          <div class="group/section flex shrink-0 items-center pl-2 pr-2 pt-1 pb-0.5">
            <button
              type="button"
              onClick={() => setChatsCollapsed((c) => !c)}
              class="control-ghost flex flex-1 items-center gap-1 px-1 py-0.5"
            >
              <Show
                when={!chatsCollapsed()}
                fallback={<ChevronRight size={11} strokeWidth={2.5} />}
              >
                <ChevronDown size={11} strokeWidth={2.5} />
              </Show>
              <span class="section-label">
                Chats
              </span>
              <Show when={chats().length > 0}>
                <span class="text-[10.5px] font-medium tabular-nums text-text-subtle/70">
                  {chats().length}
                </span>
              </Show>
            </button>
            <button
              type="button"
              onClick={newChat}
              title="New chat"
              class="control-icon flex size-5 opacity-0 group-hover/section:opacity-100"
            >
              <Plus size={12} strokeWidth={2.25} />
            </button>
          </div>

          <Show when={!chatsCollapsed()}>
            <div class="shrink-0 px-2 pb-1">
              <Show when={chats().length === 0}>
                <p class="empty-state px-3 py-2 text-left">no chats</p>
              </Show>
              <For each={chats()}>
                {(chat) => {
                  const active = () => {
                    const tab = activeWorkspaceTab();
                    return (
                      tab?.kind === "chat" &&
                      JSON.stringify(chat.id) === JSON.stringify(tab.chatId)
                    );
                  };
                  const renaming = () =>
                    JSON.stringify(renamingChatId()) ===
                    JSON.stringify(chat.id);
                  return (
                    <div
                      class="list-row group/chat relative flex items-center"
                      classList={{
                        "list-row--active font-semibold":
                          active() && !renaming(),
                        "text-text-muted":
                          !active() && !renaming(),
                      }}
                    >
                      <Show
                        when={renaming()}
                        fallback={
                          <button
                            type="button"
                            onClick={() => switchToChat(chat)}
                            onDblClick={() => startRenameChat(chat)}
                            class="flex min-w-0 flex-1 items-center gap-2.5 px-2.5 py-1 text-left"
                          >
                            <MessageSquare size={13} strokeWidth={2} class="shrink-0" />
                            <span class="truncate text-[13.5px]">{chat.title}</span>
                          </button>
                        }
                      >
                        <div class="flex min-w-0 flex-1 items-center gap-2.5 px-2.5 py-1">
                          <MessageSquare size={13} strokeWidth={2} class="shrink-0" />
                          <input
                            value={renameDraft()}
                            onInput={(e) => setRenameDraft(e.currentTarget.value)}
                            onBlur={() => commitChatRename(chat)}
                            onKeyDown={(e) => {
                              if (e.key === "Enter") {
                                e.preventDefault();
                                void commitChatRename(chat);
                              } else if (e.key === "Escape") {
                                e.preventDefault();
                                setRenamingChatId(null);
                              }
                            }}
                            ref={(el) => queueMicrotask(() => el?.focus())}
                            class="input-pill min-w-0 flex-1 px-1 py-0.5 text-[13.5px]"
                          />
                        </div>
                      </Show>
                      <Show when={!renaming()}>
                        <div class="absolute right-1 hidden items-center gap-0.5 group-hover/chat:flex">
                          <button
                            type="button"
                            onClick={(e) => {
                              e.stopPropagation();
                              startRenameChat(chat);
                            }}
                            title="Rename"
                            class="control-icon flex size-5"
                          >
                            <Pencil size={11} strokeWidth={2} />
                          </button>
                          <button
                            type="button"
                            onClick={(e) => {
                              e.stopPropagation();
                              deleteChatWithConfirm(chat);
                            }}
                            title="Delete chat"
                            class="control-icon flex size-5 hover:text-danger"
                          >
                            <Trash2 size={11} strokeWidth={2} />
                          </button>
                        </div>
                      </Show>
                    </div>
                  );
                }}
              </For>
            </div>
          </Show>

          <div class="group/section flex shrink-0 items-center pl-2 pr-2 pt-2 pb-0.5">
            <button
              type="button"
              onClick={() => setTerminalsCollapsed((c) => !c)}
              class="control-ghost flex flex-1 items-center gap-1 px-1 py-0.5"
            >
              <Show
                when={!terminalsCollapsed()}
                fallback={<ChevronRight size={11} strokeWidth={2.5} />}
              >
                <ChevronDown size={11} strokeWidth={2.5} />
              </Show>
              <span class="section-label">
                Terminals
              </span>
              <Show when={terminalSessions().length > 0}>
                <span class="text-[10.5px] font-medium tabular-nums text-text-subtle/70">
                  {terminalSessions().length}
                </span>
              </Show>
            </button>
            <button
              type="button"
              onClick={newTerminalTab}
              title="New terminal"
              class="control-icon flex size-5 opacity-0 group-hover/section:opacity-100"
            >
              <Plus size={12} strokeWidth={2.25} />
            </button>
          </div>

          <Show when={!terminalsCollapsed()}>
            <div class="shrink-0 px-2 pb-1">
              <Show when={terminalSessions().length === 0}>
                <p class="empty-state px-3 py-2 text-left">no terminals</p>
              </Show>
              <For each={terminalSessions()}>
                {(tab) => {
                  const active = () => activeWorkspaceTab()?.id === tab.id;
                  const meta = () => terminalPaneMeta(tab);
                  const detail = () => terminalSidebarDetail(tab);
                  return (
                    <div
                      class="list-row group/terminal relative flex items-stretch"
                      classList={{
                        "list-row--active": active(),
                        "text-text-muted": !active(),
                      }}
                    >
                      <button
                        type="button"
                        onClick={() => openTerminalTab(tab)}
                        class="flex min-w-0 flex-1 flex-col items-start gap-0.5 px-2.5 py-1.5 pr-7 text-left"
                      >
                        <span class="flex min-w-0 max-w-full items-center gap-2">
                          <Terminal size={13} strokeWidth={2} class="shrink-0" />
                          <span class="truncate text-[13.5px] font-semibold leading-tight">
                            {terminalSidebarTitle(tab)}
                          </span>
                        </span>
                        <Show when={meta()?.running}>
                          <span
                            class="flex items-center gap-1.5 text-[12px] font-medium leading-tight"
                            classList={{
                              "text-text-muted": active(),
                              "text-accent": !active(),
                            }}
                          >
                            <Zap size={12} strokeWidth={2.2} />
                            <span>Running</span>
                          </span>
                        </Show>
                        <Show when={detail()}>
                          <span
                            class="max-w-full truncate font-mono text-[11.5px] leading-tight"
                            classList={{
                              "text-text-dim": active(),
                              "text-text-dim": !active(),
                            }}
                          >
                            {detail()}
                          </span>
                        </Show>
                      </button>
                      <div class="absolute right-1 top-1 hidden items-center gap-0.5 group-hover/terminal:flex">
                        <button
                          type="button"
                          onClick={() => deleteTerminalSession(tab)}
                          title="Delete terminal"
                          class="control-icon flex size-5 hover:text-danger"
                          classList={{
                            "text-text-dim": active(),
                          }}
                        >
                          <Trash2 size={11} strokeWidth={2} />
                        </button>
                      </div>
                    </div>
                  );
                }}
              </For>
            </div>
          </Show>

          {/* Notes section header — collapsible */}
          <div class="group/section notes-section-head flex shrink-0 items-center pl-2 pr-2 pt-3 pb-0.5">
            <button
              type="button"
              onClick={() => setNotesCollapsed((c) => !c)}
              class="control-ghost flex flex-1 items-center gap-1 px-1 py-0.5"
            >
              <Show
                when={!notesCollapsed()}
                fallback={
                  <ChevronRight size={11} strokeWidth={2.5} />
                }
              >
                <ChevronDown size={11} strokeWidth={2.5} />
              </Show>
              <span class="section-label">
                Notes
              </span>
              <Show when={notes().length > 0}>
                <span class="text-[10.5px] font-medium tabular-nums text-text-subtle/70">
                  {notes().length}
                </span>
              </Show>
            </button>
            <button
              type="button"
              onClick={() =>
                setNotesSort((m) =>
                  m === "recency" ? "alphabetical" : "recency",
                )
              }
              title={
                notesSort() === "recency"
                  ? "Sorted by recency · click for A-Z"
                  : "Sorted A-Z · click for recency"
              }
              class="control-icon flex size-5 opacity-0 group-hover/section:opacity-100"
            >
              <ArrowUpDown size={11} strokeWidth={2.25} />
            </button>
            <button
              type="button"
              onClick={startCreatingFolder}
              title="New folder"
              class="control-icon flex size-5 opacity-0 group-hover/section:opacity-100"
            >
              <FolderPlus size={12} strokeWidth={2.25} />
            </button>
            <button
              type="button"
              onClick={createBlankNote}
              title="New note"
              class="control-icon flex size-5 opacity-0 group-hover/section:opacity-100"
            >
              <Plus size={12} strokeWidth={2.25} />
            </button>
          </div>

          {/* Source-kind filter chips. Only render when the vault has
              more than one kind so it doesn't add visual noise to a
              fresh "manual"-only vault. */}
          <Show when={!notesCollapsed() && availableKinds().size > 1}>
            <div class="flex flex-wrap gap-1 px-3 pb-1.5">
              <For each={[...availableKinds().entries()].sort()}>
                {([kind, count]) => (
                  <button
                    type="button"
                    onClick={() => toggleKindFilter(kind)}
                    class="flex items-center gap-1 rounded-full border border-border px-1.5 py-0.5 text-[10px] transition-colors"
                    classList={{
                      "bg-bg-elev text-text": activeKindFilters().has(kind),
                      "text-text-subtle hover:text-text-dim":
                        !activeKindFilters().has(kind),
                    }}
                  >
                    <SourceDot kind={kind} class="size-1.5" />
                    <span>{sourceLabel(kind)}</span>
                    <span class="font-mono tabular-nums text-text-subtle">
                      {count}
                    </span>
                  </button>
                )}
              </For>
            </div>
          </Show>

          {/* Inline new-folder input. Shown above the list so the user
              sees what they're typing in context. Tauri's WebKit no-ops
              window.prompt() so we render an actual input. */}
          <Show when={!notesCollapsed() && creatingFolder()}>
            <div class="px-3 pb-1.5">
              <div class="surface-inset flex items-center gap-1.5 rounded-md px-2 py-1">
                <FolderPlus size={11} strokeWidth={2} class="text-text-subtle" />
                <input
                  value={folderDraft()}
                  onInput={(e) => setFolderDraft(e.currentTarget.value)}
                  onBlur={() => void commitCreateFolder()}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      void commitCreateFolder();
                    } else if (e.key === "Escape") {
                      e.preventDefault();
                      setCreatingFolder(false);
                      setFolderDraft("");
                    }
                  }}
                  placeholder="folder name…"
                  ref={(el) => queueMicrotask(() => el?.focus())}
                  class="input-pill min-w-0 flex-1 px-1 py-0.5 text-[12.5px]"
                />
              </div>
            </div>
          </Show>

          {/* Note list — folders + unfiled */}
          <div class="notes-list flex-1 overflow-y-auto px-2 pb-2">
            <Show when={!notesCollapsed()}>
              <Show when={notes().length === 0}>
                <div class="notes-empty-state">
                  <div class="notes-empty-state__glyph">
                    <FileText size={15} strokeWidth={2} />
                  </div>
                  <p class="text-[12.5px] text-text-muted">No notes yet</p>
                  <p class="mt-1 text-[11.5px] text-text-subtle">
                    Capture an idea or mention a note from chat.
                  </p>
                </div>
              </Show>
              <Show
                when={
                  notes().length > 0 && filteredSidebarNotes().length === 0
                }
              >
                <div class="notes-empty-state notes-empty-state--compact">
                  <Search size={14} strokeWidth={2} />
                  <p>No matching notes</p>
                </div>
              </Show>

              {/* Folder groups, alphabetical. Folder header opens/collapses
                  the group; right-side icons rename or delete. */}
              <For each={folders()}>
                {(f) => {
                  const key = JSON.stringify(f.id);
                  const collapsed = () => collapsedFolderIds().has(key);
                  const items = () => notesByFolder().get(key) ?? [];
                  const renaming = () =>
                    JSON.stringify(renamingFolderId()) === key;
                  return (
                    <div class="folder-group mt-1.5">
                      <div class="group/folder flex items-center px-1 py-0.5">
                        <Show
                          when={renaming()}
                          fallback={
                            <button
                              type="button"
                              onClick={() => toggleFolderCollapsed(key)}
                              onDblClick={() => startRenameFolder(f)}
                              class="control-ghost flex flex-1 items-center gap-1.5 px-1 py-0.5 text-left"
                            >
                              <Show
                                when={!collapsed()}
                                fallback={<ChevronRight size={10} strokeWidth={2.5} />}
                              >
                                <ChevronDown size={10} strokeWidth={2.5} />
                              </Show>
                              <Show
                                when={!collapsed() && items().length > 0}
                                fallback={<FolderIcon size={11} strokeWidth={2} />}
                              >
                                <FolderOpen size={11} strokeWidth={2} />
                              </Show>
                              <span class="truncate text-[12px] text-text-muted">
                                {f.name}
                              </span>
                              <Show when={items().length > 0}>
                                <span class="font-mono text-[10px] tabular-nums text-text-subtle">
                                  {items().length}
                                </span>
                              </Show>
                            </button>
                          }
                        >
                          <div class="flex flex-1 items-center gap-1.5 px-1 py-0.5">
                            <FolderIcon size={11} strokeWidth={2} class="text-text-subtle" />
                            <input
                              value={folderDraft()}
                              onInput={(e) => setFolderDraft(e.currentTarget.value)}
                              onBlur={() => void commitRenameFolder(f)}
                              onKeyDown={(e) => {
                                if (e.key === "Enter") {
                                  e.preventDefault();
                                  void commitRenameFolder(f);
                                } else if (e.key === "Escape") {
                                  e.preventDefault();
                                  setRenamingFolderId(null);
                                  setFolderDraft("");
                                }
                              }}
                              ref={(el) => queueMicrotask(() => el?.focus())}
                              class="input-pill min-w-0 flex-1 px-1 py-0.5 text-[12px]"
                            />
                          </div>
                        </Show>
                        <Show when={!renaming()}>
                          <div class="folder-actions hidden items-center gap-0.5 group-hover/folder:flex">
                            <button
                              type="button"
                              onClick={() => startRenameFolder(f)}
                              title="Rename folder"
                              class="control-icon flex size-5"
                            >
                              <Pencil size={10} strokeWidth={2} />
                            </button>
                            <button
                              type="button"
                              onClick={() => requestDeleteFolder(f)}
                              title="Delete folder (notes stay)"
                              class="control-icon flex size-5 hover:text-danger"
                            >
                              <Trash2 size={10} strokeWidth={2} />
                            </button>
                          </div>
                        </Show>
                      </div>
                      <Show when={!collapsed()}>
                        <div class="ml-3">
                          <For each={items()}>
                            {(n) => (
                              <NoteRow
                                note={n}
                                folders={folders()}
                                renaming={() => renamingNoteTitle() === n.title}
                                renameDraft={renameDraft}
                                onRenameDraft={setRenameDraft}
                                inspectorTitle={inspectorTitle}
                                onOpen={openNote}
                                onStartRename={startRenameNote}
                                onCommitRename={commitNoteRename}
                                onCancelRename={() => setRenamingNoteTitle(null)}
                                onDelete={deleteNote}
                                onMoveToFolder={moveNoteToFolder}
                              />
                            )}
                          </For>
                        </div>
                      </Show>
                    </div>
                  );
                }}
              </For>

              {/* Unfiled bucket — always present so the user can park
                  notes outside a folder. Hidden if both folders exist
                  AND there are zero unfiled notes (avoids an empty stub). */}
              <Show
                when={
                  (notesByFolder().get("__unfiled__")?.length ?? 0) > 0 ||
                  folders().length === 0
                }
              >
                <div class="folder-group mt-1.5">
                  <Show when={folders().length > 0}>
                    <div class="px-1 py-0.5">
                      <span class="section-label opacity-70">Unfiled</span>
                    </div>
                  </Show>
                  <div class={folders().length > 0 ? "ml-3" : ""}>
                    <For each={notesByFolder().get("__unfiled__") ?? []}>
                      {(n) => (
                        <NoteRow
                          note={n}
                          folders={folders()}
                          renaming={() => renamingNoteTitle() === n.title}
                          renameDraft={renameDraft}
                          onRenameDraft={setRenameDraft}
                          inspectorTitle={inspectorTitle}
                          onOpen={openNote}
                          onStartRename={startRenameNote}
                          onCommitRename={commitNoteRename}
                          onCancelRename={() => setRenamingNoteTitle(null)}
                          onDelete={deleteNote}
                          onMoveToFolder={moveNoteToFolder}
                        />
                      )}
                    </For>
                  </div>
                </div>
              </Show>
            </Show>
          </div>

          {/* Activity section — agent reads + tool calls live. Hidden
              entirely when the user disables it in Settings. */}
          <Show when={!activityHidden()}>
          <div class="shrink-0 border-t border-border/60">
            <div class="group/section flex items-center px-2 pt-1 pb-0.5">
              <button
                type="button"
                onClick={() => setActivityCollapsed((c) => !c)}
                class="control-ghost flex flex-1 items-center gap-1 px-1 py-0.5"
              >
                <Show
                  when={!activityCollapsed()}
                  fallback={<ChevronRight size={11} strokeWidth={2.5} />}
                >
                  <ChevronDown size={11} strokeWidth={2.5} />
                </Show>
                <span class="section-label">
                  Activity
                </span>
                <Show when={activity().length > 0}>
                  <span class="text-[10.5px] font-medium tabular-nums text-text-subtle/70">
                    {activity().length}
                  </span>
                </Show>
              </button>
              <Show when={activity().length > 0}>
                <button
                  type="button"
                  onClick={() => setActivity([])}
                  title="Clear"
                  class="control-icon flex size-5 opacity-0 group-hover/section:opacity-100"
                >
                  <X size={11} strokeWidth={2} />
                </button>
              </Show>
            </div>
            <Show when={!activityCollapsed()}>
              <div class="max-h-48 overflow-y-auto px-2 pb-1">
                <Show when={activity().length === 0}>
                  <p class="empty-state px-2 py-3 text-left text-[11.5px]">
                    no activity yet — agent reads + tool calls show here.
                  </p>
                </Show>
                <For each={activity()}>
                  {(a) => <ActivityRow item={a} onTitleClick={openNote} />}
                </For>
              </div>
            </Show>
          </div>
          </Show>

          {/* Footer status strip — Discord-style anchor */}
          <div class="app-sidebar-footer p-2.5">
            <div class="sidebar-status-card flex items-center gap-2">
            <div class="surface-raised flex size-8 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold text-text">
              R
            </div>
            <div class="min-w-0 flex-1">
              <div class="truncate text-[12.5px] font-medium text-text">
                Rany
              </div>
              <div
                class="resource-usage-strip"
                title={resourceUsageTitle()}
                aria-label={resourceUsageTitle()}
              >
                <ResourceUsagePill
                  label="CPU"
                  value={formatUsagePercent(resourceUsage()?.totalCpuPercent)}
                  tone={usageTone("cpu", resourceUsage()?.totalCpuPercent)}
                />
                <ResourceUsagePill
                  label="MEM"
                  value={formatUsageBytes(resourceUsage()?.totalMemoryBytes)}
                  tone={usageTone("memory", resourceUsage()?.totalMemoryBytes)}
                />
              </div>
            </div>
            <button
              type="button"
              title="Settings"
              onClick={() => setSettingsOpen(true)}
              class="control-icon flex size-8 shrink-0"
            >
              <Settings size={13} strokeWidth={2} />
            </button>
            </div>
          </div>

          {/* Resize handle — drag right edge to set width.
              6px hit area, visible 1px line on hover/active. */}
          <div
            onMouseDown={onResizeStart}
            class="group/resize absolute -right-[3px] top-0 z-20 h-full w-[6px] cursor-col-resize select-none"
          >
            <div class="absolute inset-y-0 right-[2px] w-px bg-accent/0 transition-colors group-hover/resize:bg-accent/50" />
          </div>
        </aside>
      </Show>

      {/* Main column — hosts terminal, mail, chat, and (when a note tab
          is active) a page-mode inspector. Always rendered so the topbar
          tab strip stays visible regardless of which kind of tab is on. */}
      <div class="relative flex min-w-0 flex-1 flex-col">
        <header
          data-tauri-drag-region
          class="workspace-tabs app-topbar"
          classList={{ "workspace-tabs--no-sidebar": !sidebarOpen() }}
        >
          <Show when={!sidebarOpen()}>
            <button
              type="button"
              onClick={() => setSidebarOpen(true)}
              title="Show vault"
              class="workspace-tabs__icon"
            >
              <PanelLeft size={14} strokeWidth={2} />
            </button>
          </Show>
          <Show
            when={workspaceTabs().length > 0}
            fallback={<div class="topbar-empty-space" />}
          >
            <div class="workspace-tabs__list topbar-tab-rail">
              <For each={workspaceTabs()}>
                {(tab, idx) => {
                  const active = () => activeWorkspaceTab()?.id === tab.id;
                  const isDragOver = () => dragOverTabId() === tab.id;
                  return (
                    <div
                      class="workspace-tab"
                      classList={{
                        "workspace-tab--active": active(),
                        "workspace-tab--dragover": isDragOver(),
                      }}
                      title={tab.title}
                      draggable={true}
                      onDragStart={(e) => {
                        setDraggingTabId(tab.id);
                        // Required for the drag to actually fire on Safari/
                        // WebKit. Payload is the tab id we're moving.
                        e.dataTransfer?.setData("text/plain", tab.id);
                        e.dataTransfer!.effectAllowed = "move";
                      }}
                      onDragOver={(e) => {
                        // preventDefault is what tells the browser this
                        // element is a valid drop target.
                        e.preventDefault();
                        e.dataTransfer!.dropEffect = "move";
                        if (draggingTabId() && draggingTabId() !== tab.id) {
                          setDragOverTabId(tab.id);
                        }
                      }}
                      onDragLeave={() => {
                        if (dragOverTabId() === tab.id) setDragOverTabId(null);
                      }}
                      onDrop={(e) => {
                        e.preventDefault();
                        const fromId = draggingTabId();
                        setDraggingTabId(null);
                        setDragOverTabId(null);
                        if (!fromId || fromId === tab.id) return;
                        reorderWorkspaceTab(fromId, idx());
                      }}
                      onDragEnd={() => {
                        setDraggingTabId(null);
                        setDragOverTabId(null);
                      }}
                    >
                      <button
                        type="button"
                        class="workspace-tab__button"
                        onClick={() => void activateWorkspaceTab(tab)}
                      >
                        <Switch fallback={<MessageSquare size={13} strokeWidth={2} />}>
                          <Match when={tab.kind === "terminal"}>
                            <Terminal size={13} strokeWidth={2} />
                          </Match>
                          <Match when={tab.kind === "note"}>
                            <FileText size={13} strokeWidth={2} />
                          </Match>
                          <Match when={tab.kind === "mail"}>
                            <Mail size={13} strokeWidth={2} />
                          </Match>
                        </Switch>
                        <span class="workspace-tab__title">{tab.title}</span>
                      </button>
                      <button
                        type="button"
                        class="workspace-tab__close"
                        title={tab.kind === "terminal" ? "Remove from top bar" : "Close tab"}
                        onClick={() => closeWorkspaceTab(tab)}
                      >
                        <X size={11} strokeWidth={2.3} />
                      </button>
                    </div>
                  );
                }}
              </For>
            </div>
          </Show>

          <Show when={activeWorkspaceTab()?.kind === "chat" && currentChatId()}>
            <div class="relative">
              <button
                type="button"
                onClick={() =>
                  setAgentPickerOpen((v) => {
                    if (v) setRoomAgentQuery("");
                    return !v;
                  })
                }
                class="room-button topbar-room-button flex items-center gap-1.5 px-2.5 py-1 text-[11.5px] text-text-muted"
                title="Room controls"
              >
                <Users size={12} strokeWidth={2.2} class="text-text-dim" />
                <span class="font-medium">
                  {currentChatAgents().length === 0
                    ? "Room"
                    : currentChatAgents().length === 1
                      ? currentChatAgents()[0].name
                      : `${currentChatAgents().length} agents`}
                </span>
                <ChevronDown size={11} strokeWidth={2.5} class="opacity-60" />
              </button>
              <Show when={agentPickerOpen()}>
                <div class="room-menu absolute right-0 top-full z-50 mt-1 w-[22rem] overflow-hidden">
                  <div class="room-menu__header">
                    <div class="min-w-0">
                      <div class="room-menu__title">Room</div>
                      <div class="room-menu__subtitle">
                        {currentChatAgents().length === 0
                          ? "Default local chat"
                          : `${currentChatAgents().length} member${currentChatAgents().length === 1 ? "" : "s"} · ${computeModeLabel(computeMode())}`}
                      </div>
                    </div>
                    <div class="room-mode-pill">
                      <Route size={11} strokeWidth={2.2} />
                      Auto
                    </div>
                  </div>

                  <Show when={currentChatAgents().length > 0}>
                    <div class="room-selected">
                      <For each={currentChatAgents()}>
                        {(agent) => (
                          <button
                            type="button"
                            class="room-selected-pill"
                            title={`Remove ${agent.name}`}
                            onClick={() => void toggleChatAgent(agent)}
                          >
                            <span class="truncate">{agent.name}</span>
                            <X size={10} strokeWidth={2.4} />
                          </button>
                        )}
                      </For>
                    </div>
                  </Show>

                  <Show
                    when={agents().length > 0}
                    fallback={
                      <p class="px-3 py-3 text-[12px] text-text-subtle">
                        No agents yet. Create one in "Manage agents."
                      </p>
                    }
                  >
                    <div class="room-search">
                      <Search size={12} strokeWidth={2.2} />
                      <input
                        type="text"
                        value={roomAgentQuery()}
                        onInput={(e) => setRoomAgentQuery(e.currentTarget.value)}
                        placeholder="Find agents"
                      />
                      <Show when={roomAgentQuery().trim().length > 0}>
                        <button
                          type="button"
                          title="Clear search"
                          onClick={() => setRoomAgentQuery("")}
                        >
                          <X size={11} strokeWidth={2.4} />
                        </button>
                      </Show>
                    </div>

                    <div class="room-agent-list">
                      <For each={roomAgentResults()}>
                        {(a) => {
                          const bound = () =>
                            currentChatAgents().some(
                              (b) =>
                                JSON.stringify(b.id) === JSON.stringify(a.id),
                            );
                          const ready = () => readinessForModel(a.model);
                          return (
                            <button
                              type="button"
                              onClick={() => void toggleChatAgent(a)}
                              class="room-agent-row"
                              classList={{ "room-agent-row--selected": bound() }}
                            >
                              <span class="room-agent-row__check">
                                <Show when={bound()}>
                                  <Check size={12} strokeWidth={2.5} />
                                </Show>
                              </span>
                              <span class="room-agent-row__body">
                                <span class="room-agent-row__name">{a.name}</span>
                                <span class="room-agent-row__model">{shortModelName(a.model)}</span>
                              </span>
                              <span
                                class={`model-status-dot ${readinessClass(ready())}`}
                                title={`${shortModelName(a.model)}: ${readinessLabel(ready())}`}
                              />
                            </button>
                          );
                        }}
                      </For>
                      <Show when={roomAgentResults().length === 0}>
                        <div class="px-3 py-5 text-center text-[12px] text-text-subtle">
                          No matching agents
                        </div>
                      </Show>
                    </div>
                  </Show>

                  <div class="room-compute">
                    <div class="room-compute__top">
                      <span>Compute</span>
                      <span class="room-compute__fallback">
                        <span
                          class={`model-status-dot ${readinessClass(readinessForModel(defaultModel()))}`}
                          title={`Fallback: ${readinessLabel(readinessForModel(defaultModel()))}`}
                        />
                        {shortModelName(defaultModel())}
                      </span>
                    </div>
                    <div class="grid grid-cols-3 gap-1">
                      {(["fast", "balanced", "deep"] as ComputeMode[]).map((mode) => (
                        <button
                          type="button"
                          onClick={() => setComputeMode(mode)}
                          class="room-compute-button"
                          classList={{ "room-compute-button--active": computeMode() === mode }}
                        >
                          {computeModeLabel(mode)}
                        </button>
                      ))}
                    </div>
                    <p class="mt-2 text-[10.5px] leading-snug text-text-subtle">
                      {computeMode() === "fast"
                        ? "One foreground model call."
                        : computeMode() === "deep"
                          ? "Use slower specialist passes when available."
                          : "Default: one loaded model, short passes."}
                    </p>
                  </div>

                  <button
                    type="button"
                    onClick={() => {
                      setAgentPickerOpen(false);
                      setAgentsModalOpen(true);
                    }}
                    class="room-manage-button"
                  >
                    <Settings size={11} strokeWidth={2} />
                    <span>Manage agents</span>
                  </button>
                </div>
              </Show>
            </div>
          </Show>
        </header>

        {/*
          Mounting strategy chosen specifically to avoid SolidJS stale-
          accessor crashes:

          - `<Show keyed>` re-creates children only when the keyed value's
            reference changes. We key on `activeTerminalSessionId()` (a
            stable string memo), NOT on the session object — so panes /
            metadata updates DON'T thrash the multiplexer.
          - The keyed function gets the session ID as a captured VALUE
            (not an accessor). No "stale value" leak.
          - The host component looks up the live session by id from a
            local memo, so its prop is always read against the current
            store, not a frozen snapshot.

          Earlier patterns crashed because `<Show when={X}>{(x) => ...}`
          and `(activeTerminalTab() as T).id` re-evaluated their
          getters during the unmount transition, when X had already
          flipped null. The error propagated out of `setWorkspaceTabs`
          and corrupted the reactive graph → app freeze.
        */}
        <Show when={activeTerminalSessionId()} keyed>
          {(sessionId) => (
            <TerminalMultiplexerHost
              sessionId={sessionId}
              terminalSessions={terminalSessions}
              meta={terminalMeta}
              activeWorkspaceTabIdMemo={activeWorkspaceTabId}
              generationMemo={nativeTerminalGeneration}
              focusTerminalPane={focusTerminalPane}
              splitTerminalPane={splitTerminalPane}
              closeTerminalPane={closeTerminalPane}
              resizeTerminalSplit={updateTerminalSplitRatio}
            />
          )}
        </Show>

        <Show when={activeWorkspaceTab()?.kind === "mail"}>
          <MailView />
        </Show>

        <Show when={activeWorkspaceTab()?.kind === "graph"}>
          <GraphView
            workspaceId={currentWorkspaceId()}
            onNodeClick={routeGraphNodeClick}
          />
        </Show>

        <Show when={activeWorkspaceTab()?.kind === "note"}>
          <InspectorPane
            title={effectiveInspectorTitle()}
            mode="page"
            width={inspectorWidth()}
            onResizeStart={onInspectorResizeStart}
            onClose={closeInspector}
            onToggleMode={toggleInspectorMode}
            onWikilinkClick={openNote}
            onDelete={deleteNote}
            onRename={async (oldTitle, newTitle) => {
              const ws = currentWorkspaceId();
              if (ws === null) return;
              try {
                await invoke("rename_note", { workspaceId: ws, oldTitle, newTitle });
                if (inspectorTitle() === oldTitle) setInspectorTitle(newTitle);
                renameNoteTab(oldTitle, newTitle);
              } catch (e) {
                console.error("rename_note failed:", e);
              }
            }}
            workspaceId={currentWorkspaceId()}
            showMiniGraph={graphEnabled()}
            onOpenGraph={openGraphTab}
            onOpenGraphNode={routeGraphNodeClick}
          />
        </Show>

        <section
          ref={chatScrollEl}
          onScroll={onChatScroll}
          class="chat-scroll flex-1 overflow-y-auto px-8 pb-6"
          classList={{
            hidden:
              activeWorkspaceTab()?.kind === "terminal" ||
              activeWorkspaceTab()?.kind === "mail" ||
              activeWorkspaceTab()?.kind === "note" ||
              activeWorkspaceTab()?.kind === "graph",
          }}
        >
          <div class="chat-column mx-auto flex max-w-[42rem] flex-col gap-4">
            <Show when={messages.length === 0}>
              <div class="empty-state py-24">
                <p class="text-[15px] text-text">
                  start a conversation
                </p>
                <p class="mt-1.5 text-[13px] text-text-dim">
                  local model only — no cloud calls. type{" "}
                  <span class="rounded bg-bg-elev px-1.5 py-0.5 text-text-muted">
                    @
                  </span>{" "}
                  for agents or notes.
                </p>
              </div>
            </Show>
            <For each={messages}>
              {(m) => (
                <div
                  class="group flex min-w-0 flex-col transition-colors duration-700"
                  data-msg-key={m.dbId ? JSON.stringify(m.dbId) : undefined}
                  classList={{
                    "items-end max-w-[78%] self-end": m.role === "user",
                    "items-start self-stretch w-full": m.role === "agent",
                    "ring-2 ring-accent/60 rounded-2xl": highlightMsgKey() === m.id,
                  }}
                >
                  <div
                    class="chat-message min-w-0 max-w-full rounded-2xl px-4 py-3 text-[15px] leading-relaxed"
                    classList={{
                      "chat-message--user whitespace-pre-wrap": m.role === "user",
                      "chat-message--agent text-text w-full": m.role === "agent",
                      "text-danger": m.status === "error",
                    }}
                  >
                    <Show when={m.role === "agent" && m.turnPlan}>
                      {(plan) => (
                        <div class="turn-plan-card">
                          <div class="turn-plan-card__head">
                            <div class="turn-plan-card__identity">
                              <span class="turn-plan-card__avatar">
                                <Bot size={13} strokeWidth={2.3} />
                              </span>
                              <div class="min-w-0">
                                <div class="turn-plan-card__title">
                                  {plan().speakerName}
                                </div>
                                <div class="turn-plan-card__sub">
                                  {turnPlanLabel(plan().kind)} · {shortModelName(plan().effectiveModel)}
                                </div>
                              </div>
                            </div>
                            <div class="turn-plan-card__compute">
                              <Gauge size={11} strokeWidth={2.2} />
                              {computeModeLabel(plan().compute)}
                            </div>
                          </div>
                          <div class="turn-plan-card__reason">{plan().reason}</div>
                          <Show when={plan().modelWarning}>
                            <div class="turn-plan-card__warning">
                              {plan().modelWarning}
                            </div>
                          </Show>
                          <div class="turn-plan-card__steps">
                            <For each={plan().steps}>
                              {(step) => (
                                <span class="turn-plan-card__step">
                                  <Sparkles size={10} strokeWidth={2.3} />
                                  {step}
                                </span>
                              )}
                            </For>
                          </div>
                        </div>
                      )}
                    </Show>
                    <MessageContent
                      text={m.text}
                      markdown={m.role === "agent"}
                      toolRunning={
                        m.role === "agent" && (m.toolRunning ?? false)
                      }
                      toolResults={m.toolResults}
                      onWikilinkClick={(title) => openNote(title)}
                      onTypedRefClick={routeTypedRefClick}
                    />
                    {/* Phase strip — single unified status line. Reads
                        as "thinking · 4.2s" / "writing · 142 chars · 9s"
                        / "searching the graph for 'Acme' · 0.8s" while
                        the turn is in flight. Replaces the earlier
                        opaque three-dot placeholder so the user has a
                        concrete signal that work is happening, plus
                        which phase the agent is in. */}
                    <Show
                      when={
                        m.role === "agent" &&
                        m.status === "streaming" &&
                        m.phase
                      }
                    >
                      <div
                        class="phase-strip"
                        classList={{
                          "phase-strip--writing": m.phase === "writing",
                          "phase-strip--tool": m.phase === "tool",
                          "phase-strip--thinking": m.phase === "thinking",
                        }}
                      >
                        <span class="phase-strip__pulse" aria-hidden="true">
                          <span /><span /><span />
                        </span>
                        <span class="phase-strip__label">
                          {m.phase === "tool"
                            ? toolStatusLabel(
                                m.toolAction,
                                m.toolTarget,
                                m.toolSecondary,
                              )
                            : m.phase === "writing"
                              ? "writing"
                              : "thinking"}
                        </span>
                        <span class="phase-strip__sep">·</span>
                        <Show when={m.phase === "writing"}>
                          <span class="phase-strip__detail">
                            {m.text.length.toLocaleString()} chars
                          </span>
                          <span class="phase-strip__sep">·</span>
                        </Show>
                        <span class="phase-strip__elapsed">
                          {formatPhaseElapsed(
                            phaseTick() - (m.phaseStartedAt ?? phaseTick()),
                          )}
                        </span>
                      </div>
                    </Show>
                  </div>
                  <Show
                    when={
                      m.role === "agent" &&
                      m.status === "done" &&
                      m.text.length > 0
                    }
                  >
                    <div class="mt-1 ml-1 flex items-center opacity-0 transition-opacity group-hover:opacity-100">
                      <button
                        type="button"
                        onClick={() => copyMessage(m.id, m.text)}
                        title="Copy message"
                      class="control-ghost flex items-center gap-1 px-1.5 py-1 text-[11px]"
                      >
                        <Show
                          when={lastCopiedId() === m.id}
                          fallback={
                            <>
                              <Copy size={11} strokeWidth={2} />
                              copy
                            </>
                          }
                        >
                          <Check size={11} strokeWidth={2.5} />
                          copied
                        </Show>
                      </button>
                    </div>
                  </Show>
                </div>
              )}
            </For>
          </div>
        </section>

        <footer
          class="chat-footer relative px-8 pb-6 pt-2"
          classList={{
            hidden:
              activeWorkspaceTab()?.kind === "terminal" ||
              activeWorkspaceTab()?.kind === "mail" ||
              activeWorkspaceTab()?.kind === "note" ||
              activeWorkspaceTab()?.kind === "graph",
          }}
        >
          <Show when={!stickToBottom() && messages.length > 0}>
            <button
              type="button"
              onClick={jumpToBottom}
              title="Scroll to latest"
              class="fab-soft absolute -top-2 left-1/2 z-10 size-9 -translate-x-1/2 -translate-y-full"
            >
              <ArrowDown size={15} strokeWidth={2.25} />
            </button>
          </Show>
          <form
            class="chat-composer-form mx-auto flex max-w-[42rem] items-end gap-2.5"
            onSubmit={(e) => {
              e.preventDefault();
              send();
            }}
          >
            <div class="relative flex-1">
              <Show when={mention().active}>
                <MentionDropdown
                  query={(mention() as { query: string }).query}
                  items={filteredItems()}
                  showCreate={showCreate()}
                  selectedIndex={mentionSelected()}
                  onPick={pickMention}
                  onCreateNote={createMentionedNote}
                  onHover={setMentionSelected}
                />
              </Show>
              <div class="composer-pill">
                <textarea
                  ref={inputEl}
                  value={input()}
                  onInput={handleInput}
                  onKeyDown={handleKeyDown}
                  onClick={(e) => detectMention(e.currentTarget)}
                  onBlur={() =>
                    setTimeout(() => setMention({ active: false }), 150)
                  }
                  placeholder={
                    busy()
                      ? "thinking…"
                      : "message the room — @ for agents or notes"
                  }
                  disabled={busy()}
                  rows={1}
                  class="block w-full resize-none bg-transparent text-[15px] leading-6 text-text outline-none placeholder:text-text-dim disabled:opacity-60"
                  style={{ "max-height": `${COMPOSER_MAX_PX}px` }}
                />
              </div>
            </div>
            <Show
              when={busy()}
              fallback={
                <button
                  type="submit"
                  disabled={input().trim().length === 0 || mention().active}
                  title="Send"
                  class="soft-send-button flex size-11 shrink-0 items-center justify-center"
                >
                  <ArrowUp size={18} strokeWidth={2.5} />
                </button>
              }
            >
              <button
                type="button"
                onClick={cancelStream}
                title="Cancel response"
                class="soft-send-button soft-send-button--secondary flex size-11 shrink-0 items-center justify-center"
              >
                <Square size={15} strokeWidth={2.5} />
              </button>
            </Show>
          </form>
        </footer>
      </div>

      {/* Side-mode inspector (right rail). Page-mode lives inside the
          main column above so the topbar tab strip stays visible. Hide
          the rail whenever the title corresponds to an existing note
          tab — that note already has a tab, no need to mirror it. */}
      <Show
        when={
          inspectorTitle() !== null &&
          !workspaceTabs().some(
            (t) => t.kind === "note" && t.noteTitle === inspectorTitle(),
          )
        }
      >
        <InspectorPane
          title={effectiveInspectorTitle()}
          mode="side"
          width={inspectorWidth()}
          onResizeStart={onInspectorResizeStart}
          onClose={closeInspector}
          onToggleMode={toggleInspectorMode}
          onWikilinkClick={openNote}
          onDelete={deleteNote}
          onRename={async (oldTitle, newTitle) => {
            const ws = currentWorkspaceId();
            if (ws === null) return;
            try {
              await invoke("rename_note", { workspaceId: ws, oldTitle, newTitle });
              if (inspectorTitle() === oldTitle) setInspectorTitle(newTitle);
              renameNoteTab(oldTitle, newTitle);
            } catch (e) {
              console.error("rename_note failed:", e);
            }
          }}
          workspaceId={currentWorkspaceId()}
          showMiniGraph={graphEnabled()}
          onOpenGraph={openGraphTab}
        />
      </Show>

      <Show when={pendingDelete()}>
        <div
          class="modal-scrim items-center justify-center"
          tabindex={-1}
          onClick={() => setPendingDelete(null)}
          onKeyDown={(e) => {
            if (e.key === "Escape") setPendingDelete(null);
            if (e.key === "Enter") void confirmPendingDelete();
          }}
        >
          <div
            class="modal-card w-[28rem] max-w-[90vw] p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 class="text-[15px] font-semibold text-text">
              {(() => {
                const p = pendingDelete()!;
                const label =
                  p.kind === "workspace" || p.kind === "folder"
                    ? p.name
                    : p.title;
                return `Delete ${p.kind} "${label}"?`;
              })()}
            </h2>
            <p class="mt-2 text-[13px] leading-relaxed text-text-muted">
              {pendingDelete()!.kind === "note"
                ? "Removes the body, backlinks, and edit history. Cannot be undone."
                : pendingDelete()!.kind === "chat"
                  ? "Removes all messages in this chat. Cannot be undone."
                  : pendingDelete()!.kind === "folder"
                    ? "Notes inside become unfiled — none are deleted."
                    : "Removes ALL notes, chats, messages, and agents in this workspace. Cannot be undone."}
            </p>
            <div class="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setPendingDelete(null)}
                class="btn-soft btn-soft--sm btn-soft--ghost"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={confirmPendingDelete}
                class="btn-soft btn-soft--sm btn-soft--danger"
                autofocus
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </Show>

      <CaptureModal
        open={captureOpen()}
        workspaceId={currentWorkspaceId()}
        onClose={() => setCaptureOpen(false)}
        onSaved={(title) => {
          refreshNotes();
          openNote(title);
        }}
      />

      {/* Settings modal. Backdrop click and Escape both close.
          Sections: theme, default model, default agent, panels. */}
      <Show when={settingsOpen()}>
        <div
          class="modal-scrim items-center justify-center"
          onClick={() => setSettingsOpen(false)}
        >
          <div
            class="modal-card max-h-[80vh] w-[460px] max-w-[92vw] overflow-y-auto p-5"
            onClick={(e) => e.stopPropagation()}
          >
            <div class="mb-5 flex items-center justify-between">
              <h2 class="text-[15px] font-semibold text-text">Settings</h2>
              <button
                type="button"
                onClick={() => setSettingsOpen(false)}
                class="control-icon flex size-7"
                title="Close"
              >
                <X size={14} strokeWidth={2} />
              </button>
            </div>

            <div class="space-y-5">
              <section>
                <label class="section-label">
                  Theme
                </label>
                <div class="surface-inset mt-2 flex gap-1 rounded-lg p-0.5">
                  <For each={["system", "dark", "light"] as const}>
                    {(opt) => (
                      <button
                        type="button"
                        onClick={() => setThemePref(opt)}
                        class="flex-1 rounded-md px-3 py-1.5 text-[12.5px] capitalize transition-colors"
                        classList={{
                          "surface-raised text-text font-medium":
                            themePref() === opt,
                          "text-text-dim hover:text-text":
                            themePref() !== opt,
                        }}
                      >
                        {opt}
                      </button>
                    )}
                  </For>
                </div>
                <p class="mt-2 text-[11px] text-text-subtle">
                  System follows your macOS appearance.
                </p>
              </section>

              <section>
                <label
                  for="settings-default-model"
                  class="section-label"
                >
                  Default Model
                </label>
                <input
                  id="settings-default-model"
                  type="text"
                  value={defaultModel()}
                  onInput={(e) => setDefaultModel(e.currentTarget.value)}
                  spellcheck={false}
                  class="input-pill mt-2 w-full px-3 py-1.5 font-mono text-[12px]"
                />
                <p class="mt-2 text-[11px] text-text-subtle">
                  MLX model identifier passed to <code class="text-text-muted">chat_stream</code>.
                  Default: <code class="text-text-muted">{DEFAULT_MODEL}</code>.
                </p>
              </section>

              <section>
                <label
                  for="settings-default-agent"
                  class="section-label"
                >
                  Default Agent for New Chats
                </label>
                <select
                  id="settings-default-agent"
                  value={defaultAgentJson()}
                  onChange={(e) => setDefaultAgentJson(e.currentTarget.value)}
                  class="surface-inset mt-2 w-full rounded-lg px-3 py-1.5 text-[12.5px] text-text outline-none"
                >
                  <option value="">none (unbound)</option>
                  <For each={agents()}>
                    {(a) => (
                      <option value={JSON.stringify(a.id)}>{a.name}</option>
                    )}
                  </For>
                </select>
                <p class="mt-2 text-[11px] text-text-subtle">
                  New chats are bound to this agent automatically. You can
                  still change per-chat from the chat header.
                </p>
              </section>

              <section>
                <label class="section-label">
                  Panels
                </label>
                <label class="surface-inset mt-2 flex cursor-pointer items-center justify-between rounded-lg px-3 py-2">
                  <div>
                    <div class="text-[12.5px] text-text">
                      Hide activity timeline
                    </div>
                    <div class="text-[11px] text-text-subtle">
                      Removes the agent-action log section from the sidebar.
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={activityHidden()}
                    onChange={(e) => setActivityHidden(e.currentTarget.checked)}
                    class="size-4 cursor-pointer accent-accent"
                  />
                </label>
                <label class="surface-inset mt-2 flex cursor-pointer items-center justify-between rounded-lg px-3 py-2">
                  <div>
                    <div class="text-[12.5px] text-text">
                      Knowledge graph view
                    </div>
                    <div class="text-[11px] text-text-subtle">
                      Adds a Graph tab and a 1-hop mini-graph to the inspector.
                      Edges are always tracked behind the scenes — toggling
                      this only changes whether the visual surfaces appear.
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={graphEnabled()}
                    onChange={(e) => setGraphEnabled(e.currentTarget.checked)}
                    class="size-4 cursor-pointer accent-accent"
                  />
                </label>
              </section>
            </div>
          </div>
        </div>
      </Show>

      <AgentsModal
        open={agentsModalOpen()}
        workspaceId={currentWorkspaceId()}
        agents={agents()}
        onClose={() => setAgentsModalOpen(false)}
      />

      <SearchPalette
        open={searchOpen()}
        workspaceId={currentWorkspaceId()}
        onClose={() => setSearchOpen(false)}
        onPickNote={(title) => openNote(title)}
        onPickMessage={(hit) => {
          // Switch to the message's chat if we already have it cached
          // (workspace-scoped search guarantees it's local), then queue a
          // scroll-to-message that fires once loadMessages hydrates.
          setPendingScrollMsgId(hit.message_id);
          const chat = chats().find(
            (c) => JSON.stringify(c.id) === JSON.stringify(hit.chat_id),
          );
          if (chat) void switchToChat(chat);
        }}
      />
    </main>
  );
}
