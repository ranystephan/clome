import { createSignal, createEffect, Show, For, onCleanup, onMount } from "solid-js";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { X, Plus, Trash2, Sparkles, Square, Pencil } from "lucide-solid";

type AgentId = unknown;

type Agent = {
  id: AgentId;
  name: string;
  system_prompt: string;
  model: string;
  capabilities: string[];
};

type CapabilityInfo = {
  key: string;
  label: string;
  description: string;
};

type Draft = {
  id: AgentId | null; // null = new
  name: string;
  system_prompt: string;
  model: string;
  capabilities: string[];
};

type Props = {
  open: boolean;
  workspaceId: unknown | null;
  agents: Agent[];
  onClose: () => void;
};

const DEFAULT_MODEL = "mlx-community/Qwen2.5-7B-Instruct-4bit";

type ArchitectStatus = "idle" | "running" | "error";

let promptGenSeq = 1_000_000; // separate id space from chat turns

export default function AgentsModal(props: Props) {
  const [draft, setDraft] = createSignal<Draft | null>(null);
  const [saving, setSaving] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [allCaps, setAllCaps] = createSignal<CapabilityInfo[]>([]);
  const [pendingDeleteKey, setPendingDeleteKey] = createSignal<string | null>(null);
  // Architect (meta-prompt writer)
  const [architectOpen, setArchitectOpen] = createSignal(false);
  const [architectDesc, setArchitectDesc] = createSignal("");
  const [architectStatus, setArchitectStatus] = createSignal<ArchitectStatus>("idle");
  const [architectErr, setArchitectErr] = createSignal<string | null>(null);
  let architectTurnId = 0;
  const promptGenUnlisteners: UnlistenFn[] = [];

  onMount(async () => {
    try {
      setAllCaps(await invoke<CapabilityInfo[]>("list_capabilities"));
    } catch (e) {
      console.error("list_capabilities failed:", e);
    }
    // Architect streaming events.
    promptGenUnlisteners.push(
      await listen<{ turnId: number; token: string }>("prompt_gen:token", (e) => {
        if (e.payload.turnId !== architectTurnId) return;
        const d = draft();
        if (!d) return;
        setDraft({ ...d, system_prompt: d.system_prompt + e.payload.token });
      }),
    );
    promptGenUnlisteners.push(
      await listen<{ turnId: number }>("prompt_gen:done", (e) => {
        if (e.payload.turnId !== architectTurnId) return;
        setArchitectStatus("idle");
      }),
    );
    promptGenUnlisteners.push(
      await listen<{ turnId: number; message: string }>("prompt_gen:error", (e) => {
        if (e.payload.turnId !== architectTurnId) return;
        setArchitectStatus("error");
        setArchitectErr(e.payload.message);
      }),
    );
  });

  onCleanup(() => promptGenUnlisteners.forEach((u) => u()));

  createEffect(() => {
    if (props.open) {
      setDraft(null);
      setError(null);
      setPendingDeleteKey(null);
      setArchitectOpen(false);
      setArchitectDesc("");
      setArchitectStatus("idle");
      setArchitectErr(null);
    }
  });

  function startNew() {
    setDraft({
      id: null,
      name: "",
      system_prompt: "",
      model: DEFAULT_MODEL,
      capabilities: [],
    });
    setError(null);
  }

  function startEdit(a: Agent) {
    setDraft({
      id: a.id,
      name: a.name,
      system_prompt: a.system_prompt,
      model: a.model,
      capabilities: [...a.capabilities],
    });
    setError(null);
  }

  async function runArchitect() {
    const d = draft();
    if (!d) return;
    const desc = architectDesc().trim();
    if (!desc) return;
    architectTurnId = ++promptGenSeq;
    setArchitectErr(null);
    setArchitectStatus("running");
    // Clear textarea so generated text streams into a clean field.
    setDraft({ ...d, system_prompt: "" });
    try {
      await invoke("generate_agent_prompt", {
        turnId: architectTurnId,
        description: desc,
        model: d.model.trim() || null,
      });
    } catch (e) {
      setArchitectStatus("error");
      setArchitectErr(String(e));
    }
  }

  function cancelArchitect() {
    // Bumping the listener key drops in-flight tokens silently.
    architectTurnId = -1;
    setArchitectStatus("idle");
  }

  function toggleCap(key: string) {
    const d = draft();
    if (!d) return;
    const has = d.capabilities.includes(key);
    setDraft({
      ...d,
      capabilities: has
        ? d.capabilities.filter((c) => c !== key)
        : [...d.capabilities, key],
    });
  }

  async function save() {
    const d = draft();
    if (!d) return;
    if (!d.name.trim()) {
      setError("name is required");
      return;
    }
    if (props.workspaceId === null && d.id === null) {
      setError("no active workspace");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      if (d.id === null) {
        await invoke("create_agent", {
          workspaceId: props.workspaceId,
          name: d.name.trim(),
          systemPrompt: d.system_prompt,
          model: d.model.trim() || DEFAULT_MODEL,
          capabilities: d.capabilities,
        });
      } else {
        await invoke("update_agent", {
          agentId: d.id,
          name: d.name.trim(),
          systemPrompt: d.system_prompt,
          model: d.model.trim() || DEFAULT_MODEL,
          capabilities: d.capabilities,
        });
      }
      setDraft(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }

  async function deleteAgent(a: Agent) {
    const key = JSON.stringify(a.id);
    if (pendingDeleteKey() !== key) {
      // First click — arm. Auto-disarm after 4s.
      setPendingDeleteKey(key);
      setTimeout(() => {
        if (pendingDeleteKey() === key) setPendingDeleteKey(null);
      }, 4000);
      return;
    }
    setPendingDeleteKey(null);
    try {
      await invoke("delete_agent", { agentId: a.id });
    } catch (e) {
      console.error("delete_agent failed:", e);
    }
  }

  function onKeyDown(e: KeyboardEvent) {
    if (!props.open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      if (draft() !== null) setDraft(null);
      else props.onClose();
    } else if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      if (draft()) {
        e.preventDefault();
        void save();
      }
    }
  }

  createEffect(() => {
    if (props.open) {
      window.addEventListener("keydown", onKeyDown);
      onCleanup(() => window.removeEventListener("keydown", onKeyDown));
    }
  });

  return (
    <Show when={props.open}>
      <div
        class="modal-scrim items-start justify-center"
        style={{ "padding-top": "8vh" }}
        onClick={(e) => {
          if (e.target === e.currentTarget) props.onClose();
        }}
      >
        <div class="modal-card flex max-h-[80vh] w-[42rem] max-w-[92vw] flex-col overflow-hidden">
          <header class="flex items-center justify-between border-b border-border px-5 py-3">
            <h2 class="text-[14px] font-semibold tracking-wide text-text">
              Agents
            </h2>
            <button
              type="button"
              class="control-icon p-1"
              onClick={props.onClose}
              title="Close (Esc)"
            >
              <X size={15} strokeWidth={2} />
            </button>
          </header>

          <div class="flex-1 overflow-y-auto">
            <Show
              when={draft() !== null}
              fallback={
                <div class="px-3 py-2">
                  <Show when={props.agents.length === 0}>
                    <p class="empty-state px-3 py-6">
                      no agents yet — click + to make one.
                    </p>
                  </Show>
                  <For each={props.agents}>
                    {(a) => (
                      <div
                        role="button"
                        tabindex={0}
                        onClick={() => startEdit(a)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter" || e.key === " ") {
                            e.preventDefault();
                            startEdit(a);
                          }
                        }}
                        class="list-row group flex w-full cursor-pointer items-start gap-3 px-3 py-2.5 text-left"
                        title="Click to edit"
                      >
                        <div class="min-w-0 flex-1">
                          <span class="flex items-center gap-2">
                            <span class="truncate text-[14px] font-medium text-text">
                              {a.name}
                            </span>
                            <Show when={a.capabilities.length > 0}>
                              <span class="font-mono text-[10px] text-text-subtle">
                                {a.capabilities.length} cap{a.capabilities.length === 1 ? "" : "s"}
                              </span>
                            </Show>
                          </span>
                          <p class="mt-0.5 line-clamp-2 text-[12px] text-text-dim">
                            {a.system_prompt || "no prompt"}
                          </p>
                          <p class="mt-1 font-mono text-[10px] text-text-subtle">
                            {a.model}
                          </p>
                        </div>
                        <div class="flex shrink-0 items-center gap-0.5">
                          <span
                            class="control-icon flex size-7 opacity-0 group-hover:opacity-100"
                            title="Edit"
                          >
                            <Pencil size={12} strokeWidth={2} />
                          </span>
                          <button
                            type="button"
                            onClick={(e) => {
                              e.stopPropagation();
                              void deleteAgent(a);
                            }}
                            title={
                              pendingDeleteKey() === JSON.stringify(a.id)
                                ? "Click again to confirm"
                                : "Delete"
                            }
                            class="control-icon flex size-7 transition-all"
                            classList={{
                              "opacity-0 group-hover:opacity-100 text-text-subtle hover:bg-danger/10 hover:text-danger":
                                pendingDeleteKey() !== JSON.stringify(a.id),
                              "opacity-100 bg-danger/15 text-danger":
                                pendingDeleteKey() === JSON.stringify(a.id),
                            }}
                          >
                            <Trash2 size={13} strokeWidth={2} />
                          </button>
                        </div>
                      </div>
                    )}
                  </For>
                </div>
              }
            >
              <div class="px-5 py-4">
                <label class="section-label block">
                  Name
                </label>
                <input
                  value={draft()!.name}
                  onInput={(e) =>
                    setDraft({ ...draft()!, name: e.currentTarget.value })
                  }
                  placeholder="Calendar, Research, Code, …"
                  class="input-pill mt-1.5 w-full px-3 py-2 text-[14px]"
                />
                <div class="mt-4 flex items-baseline justify-between">
                  <label class="section-label block">
                    System prompt
                  </label>
                  <button
                    type="button"
                    onClick={() => setArchitectOpen((v) => !v)}
                    class="control-ghost flex items-center gap-1 px-2 py-0.5 text-[11px] hover:text-accent"
                    title="Have an AI write this prompt for you"
                  >
                    <Sparkles size={11} strokeWidth={2} />
                    AI assist
                  </button>
                </div>

                <Show when={architectOpen()}>
                  <div class="surface-inset mt-2 rounded-xl p-3">
                    <p class="text-[11px] text-text-dim">
                      Describe what the agent should do. Architect rewrites
                      the prompt below.
                    </p>
                    <input
                      value={architectDesc()}
                      onInput={(e) => setArchitectDesc(e.currentTarget.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && !e.shiftKey) {
                          e.preventDefault();
                          if (architectStatus() !== "running") void runArchitect();
                        }
                      }}
                      placeholder='e.g. "research assistant for ML papers"'
                      class="input-pill mt-2 w-full px-2.5 py-1.5 text-[12.5px]"
                      disabled={architectStatus() === "running"}
                    />
                    <div class="mt-2 flex items-center justify-between gap-2">
                      <span class="text-[10.5px] text-text-subtle">
                        <Show
                          when={architectStatus() === "running"}
                          fallback={<>↩ generates · overwrites the prompt below</>}
                        >
                          streaming…
                        </Show>
                      </span>
                      <div class="flex gap-1.5">
                        <Show when={architectStatus() === "running"}>
                          <button
                            type="button"
                            onClick={cancelArchitect}
                            class="control-ghost flex items-center gap-1 px-2 py-0.5 text-[11px]"
                          >
                            <Square size={9} strokeWidth={2} />
                            stop
                          </button>
                        </Show>
                        <button
                          type="button"
                          onClick={runArchitect}
                          class="btn-soft btn-soft--sm flex items-center gap-1 px-2.5 py-0.5 text-[11px] font-medium disabled:opacity-50"
                          disabled={
                            architectStatus() === "running" ||
                            !architectDesc().trim()
                          }
                        >
                          <Sparkles size={10} strokeWidth={2} />
                          {architectStatus() === "running" ? "writing…" : "generate"}
                        </button>
                      </div>
                    </div>
                    <Show when={architectErr()}>
                      <p class="mt-2 text-[11px] text-danger">{architectErr()}</p>
                    </Show>
                  </div>
                </Show>

                <textarea
                  value={draft()!.system_prompt}
                  onInput={(e) =>
                    setDraft({
                      ...draft()!,
                      system_prompt: e.currentTarget.value,
                    })
                  }
                  rows={8}
                  placeholder="Specialty + tone. e.g. 'You manage the user calendar. Read events, suggest slots.'"
                  class="input-pill mt-1.5 w-full resize-y px-3 py-2 font-mono text-[12.5px]"
                />
                <label class="section-label mt-4 block">
                  Model
                </label>
                <input
                  value={draft()!.model}
                  onInput={(e) =>
                    setDraft({ ...draft()!, model: e.currentTarget.value })
                  }
                  placeholder="mlx-community/Qwen2.5-7B-Instruct-4bit"
                  class="input-pill mt-1.5 w-full px-3 py-2 font-mono text-[12px]"
                />

                <label class="section-label mt-4 block">
                  Capabilities
                </label>
                <p class="mt-1 text-[11px] text-text-subtle">
                  Vault tools (notes, wikilinks) are always on. Below are extra surfaces this agent can touch.
                </p>
                <div class="mt-2 space-y-1">
                  <For each={allCaps()}>
                    {(cap) => {
                      const checked = () => draft()!.capabilities.includes(cap.key);
                      return (
                        <label class="list-row flex cursor-pointer items-start gap-3 px-2 py-1.5">
                          <input
                            type="checkbox"
                            class="mt-0.5 size-3.5 shrink-0 cursor-pointer accent-accent"
                            checked={checked()}
                            onChange={() => toggleCap(cap.key)}
                          />
                          <span class="min-w-0 flex-1">
                            <span class="block text-[13px] text-text">
                              {cap.label}
                              <span class="ml-2 font-mono text-[10px] text-text-subtle">
                                {cap.key}
                              </span>
                            </span>
                            <span class="mt-0.5 block text-[11.5px] text-text-dim">
                              {cap.description}
                            </span>
                          </span>
                        </label>
                      );
                    }}
                  </For>
                </div>

                <Show when={error()}>
                  <p class="mt-3 text-[12px] text-danger">{error()}</p>
                </Show>
              </div>
            </Show>
          </div>

          <footer class="flex items-center justify-between border-t border-border px-5 py-3">
            <Show
              when={draft() !== null}
              fallback={
                <button
                  type="button"
                  onClick={startNew}
                  class="control-ghost flex items-center gap-1.5 px-2 py-1 text-[12px]"
                >
                  <Plus size={13} strokeWidth={2} />
                  new agent
                </button>
              }
            >
              <span class="text-text-subtle">
                <span class="kbd-chip">⌘↩</span>{" "}
                <span class="kbd-chip">esc</span>
              </span>
            </Show>
            <Show when={draft() !== null}>
              <div class="flex gap-2">
                <button
                  type="button"
                  onClick={() => setDraft(null)}
                  class="btn-soft btn-soft--sm btn-soft--ghost"
                  disabled={saving()}
                >
                  back
                </button>
                <button
                  type="button"
                  onClick={save}
                  class="btn-soft btn-soft--sm btn-soft--primary"
                  disabled={saving() || !draft()!.name.trim()}
                >
                  {saving() ? "saving…" : "save"}
                </button>
              </div>
            </Show>
          </footer>
        </div>
      </div>
    </Show>
  );
}
