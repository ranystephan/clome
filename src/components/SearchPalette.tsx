import {
  createSignal,
  createEffect,
  Show,
  For,
  onCleanup,
} from "solid-js";
import { invoke } from "@tauri-apps/api/core";
import { Search as SearchIcon, FileText, MessageSquare } from "lucide-solid";
import { SourceDot } from "./SourceBadge";

type NoteHit = {
  title: string;
  source_kind: string;
  snippet: string;
  title_hit: boolean;
  semantic_only?: boolean;
};
type MessageHit = {
  message_id: unknown;
  chat_id: unknown;
  chat_title: string | null;
  role: string;
  snippet: string;
  created_at: string;
};
type SearchResults = {
  notes: NoteHit[];
  messages: MessageHit[];
};

type FlatItem =
  | { kind: "note"; index: number; hit: NoteHit }
  | { kind: "message"; index: number; hit: MessageHit };

type Props = {
  open: boolean;
  workspaceId: unknown | null;
  onClose: () => void;
  onPickNote: (title: string) => void;
  onPickMessage: (hit: MessageHit) => void;
};

const DEBOUNCE_MS = 140;

export default function SearchPalette(props: Props) {
  const [query, setQuery] = createSignal("");
  const [results, setResults] = createSignal<SearchResults>({
    notes: [],
    messages: [],
  });
  const [loading, setLoading] = createSignal(false);
  const [selected, setSelected] = createSignal(0);
  let inputEl!: HTMLInputElement;
  let searchSeq = 0;
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;

  const flat = (): FlatItem[] => {
    const r = results();
    const out: FlatItem[] = [];
    r.notes.forEach((h, i) => out.push({ kind: "note", index: i, hit: h }));
    r.messages.forEach((h, i) =>
      out.push({ kind: "message", index: i, hit: h }),
    );
    return out;
  };

  function clearTimer() {
    if (debounceTimer !== null) {
      clearTimeout(debounceTimer);
      debounceTimer = null;
    }
  }

  async function runSearch(q: string) {
    if (props.workspaceId === null) return;
    const seq = ++searchSeq;
    if (q.trim().length === 0) {
      setResults({ notes: [], messages: [] });
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      const res = await invoke<SearchResults>("search", {
        workspaceId: props.workspaceId,
        query: q,
        limit: 25,
      });
      if (seq !== searchSeq) return;
      setResults(res);
    } catch (e) {
      console.error("search failed:", e);
      if (seq === searchSeq) setResults({ notes: [], messages: [] });
    } finally {
      if (seq === searchSeq) setLoading(false);
    }
  }

  // Debounce query → search
  createEffect(() => {
    const q = query();
    clearTimer();
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      void runSearch(q);
    }, DEBOUNCE_MS);
  });

  // Reset selection when results change
  createEffect(() => {
    flat();
    setSelected(0);
  });

  // On open: focus, reset
  createEffect(() => {
    if (props.open) {
      setQuery("");
      setResults({ notes: [], messages: [] });
      setSelected(0);
      queueMicrotask(() => inputEl?.focus());
    }
  });

  function pick(item: FlatItem) {
    if (item.kind === "note") {
      props.onPickNote(item.hit.title);
    } else {
      props.onPickMessage(item.hit);
    }
    props.onClose();
  }

  function onKeyDown(e: KeyboardEvent) {
    if (!props.open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      props.onClose();
      return;
    }
    const items = flat();
    if (items.length === 0) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelected((s) => (s + 1) % items.length);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelected((s) => (s - 1 + items.length) % items.length);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const it = items[selected()];
      if (it) pick(it);
    }
  }

  createEffect(() => {
    if (props.open) {
      window.addEventListener("keydown", onKeyDown);
      onCleanup(() => window.removeEventListener("keydown", onKeyDown));
    }
  });

  onCleanup(clearTimer);

  return (
    <Show when={props.open}>
      <div
        class="modal-scrim items-start justify-center z-[110]"
        style={{ "padding-top": "10vh" }}
        onClick={(e) => {
          if (e.target === e.currentTarget) props.onClose();
        }}
      >
        <div class="modal-card flex max-h-[70vh] w-[40rem] max-w-[90vw] flex-col overflow-hidden">
          {/* Input */}
          <div class="flex items-center gap-3 border-b border-border px-4 py-3">
            <SearchIcon size={15} strokeWidth={2} class="shrink-0 text-text-dim" />
            <input
              ref={inputEl}
              value={query()}
              onInput={(e) => setQuery(e.currentTarget.value)}
              placeholder="search notes + messages…"
              class="flex-1 bg-transparent text-[15px] outline-none placeholder:text-text-subtle"
            />
            <Show when={loading()}>
              <span class="font-mono text-[10px] text-text-subtle">…</span>
            </Show>
            <kbd class="kbd-chip">
              esc
            </kbd>
          </div>

          {/* Results */}
          <div class="flex-1 overflow-y-auto">
            <Show
              when={query().trim().length > 0 && flat().length === 0 && !loading()}
            >
              <p class="empty-state px-4 py-6">
                no matches
              </p>
            </Show>

            <Show when={results().notes.length > 0}>
              <div class="section-label px-3 pt-2 pb-1">
                Notes
              </div>
              <For each={results().notes}>
                {(hit, i) => {
                  const isSel = () => selected() === i();
                  return (
                    <button
                      type="button"
                      onMouseEnter={() => setSelected(i())}
                      onMouseDown={(e) => {
                        e.preventDefault();
                        pick({ kind: "note", index: i(), hit });
                      }}
                      class="list-row flex w-full items-start gap-3 px-4 py-2 text-left"
                      classList={{
                        "list-row--active": isSel(),
                      }}
                    >
                      <span class="mt-0.5">
                        <SourceDot kind={hit.source_kind} />
                      </span>
                      <span class="min-w-0 flex-1">
                        <span class="flex items-center gap-1.5">
                          <span class="block truncate text-[13.5px] font-medium text-text">
                            {hit.title}
                          </span>
                          <Show when={hit.semantic_only}>
                            <span class="shrink-0 rounded-full border border-accent/30 bg-accent/10 px-1.5 py-px text-[9.5px] font-medium uppercase tracking-wider text-accent">
                              semantic
                            </span>
                          </Show>
                        </span>
                        <Show when={hit.snippet}>
                          <span class="mt-0.5 block truncate text-[11.5px] text-text-dim">
                            {hit.snippet}
                          </span>
                        </Show>
                      </span>
                      <FileText
                        size={11}
                        strokeWidth={2}
                        class="mt-1 shrink-0 text-text-subtle"
                      />
                    </button>
                  );
                }}
              </For>
            </Show>

            <Show when={results().messages.length > 0}>
              <div class="border-t border-border/60" />
              <div class="section-label px-3 pt-2 pb-1">
                Messages
              </div>
              <For each={results().messages}>
                {(hit, i) => {
                  const flatIdx = () => results().notes.length + i();
                  const isSel = () => selected() === flatIdx();
                  return (
                    <button
                      type="button"
                      onMouseEnter={() => setSelected(flatIdx())}
                      onMouseDown={(e) => {
                        e.preventDefault();
                        pick({ kind: "message", index: i(), hit });
                      }}
                      class="list-row flex w-full items-start gap-3 px-4 py-2 text-left"
                      classList={{
                        "list-row--active": isSel(),
                      }}
                    >
                      <MessageSquare
                        size={12}
                        strokeWidth={2}
                        class="mt-1 shrink-0 text-text-subtle"
                      />
                      <span class="min-w-0 flex-1">
                        <span class="block text-[11px] font-mono uppercase tracking-wide text-text-subtle">
                          {hit.role}
                          <Show when={hit.chat_title}>
                            {" · "}
                            <span class="text-text-dim">{hit.chat_title}</span>
                          </Show>
                        </span>
                        <span class="mt-0.5 block truncate text-[12.5px] text-text-muted">
                          {hit.snippet}
                        </span>
                      </span>
                    </button>
                  );
                }}
              </For>
            </Show>

            <Show when={query().trim().length === 0}>
              <p class="empty-state px-4 py-6">
                type to search this workspace
              </p>
            </Show>
          </div>

          {/* Footer */}
          <div class="flex items-center justify-between border-t border-border px-4 py-2 font-mono text-[10px] text-text-subtle">
            <span>
              ↑↓ nav · ↩ open · esc close
            </span>
            <span class="tabular-nums">
              {results().notes.length + results().messages.length} hits
            </span>
          </div>
        </div>
      </div>
    </Show>
  );
}
