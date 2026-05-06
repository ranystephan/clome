import { createSignal, createEffect, Show, onCleanup } from "solid-js";
import { invoke } from "@tauri-apps/api/core";
import { X } from "lucide-solid";

type Props = {
  open: boolean;
  workspaceId: unknown | null;
  onClose: () => void;
  onSaved: (title: string) => void;
};

const SOURCE_KINDS = [
  "capture",
  "manual",
  "web",
  "paper",
  "book",
  "class",
  "email",
] as const;

function generatedCaptureTitle(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `capture-${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

export default function CaptureModal(props: Props) {
  const [title, setTitle] = createSignal("");
  const [body, setBody] = createSignal("");
  const [sourceKind, setSourceKind] = createSignal<string>("capture");
  const [saving, setSaving] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  let titleEl!: HTMLInputElement;

  createEffect(() => {
    if (props.open) {
      setTitle("");
      setBody("");
      setSourceKind("capture");
      setError(null);
      queueMicrotask(() => titleEl?.focus());
    }
  });

  function onKeyDown(e: KeyboardEvent) {
    if (!props.open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      props.onClose();
    } else if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      void save();
    }
  }

  createEffect(() => {
    if (props.open) {
      window.addEventListener("keydown", onKeyDown);
      onCleanup(() => window.removeEventListener("keydown", onKeyDown));
    }
  });

  async function save() {
    const t = title().trim() || generatedCaptureTitle();
    if (!body().trim() && !title().trim()) {
      setError("capture needs text or a title");
      titleEl?.focus();
      return;
    }
    if (props.workspaceId === null) {
      setError("no active workspace");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await invoke("create_note", {
        workspaceId: props.workspaceId,
        title: t,
        body: body(),
        sourceKind: sourceKind(),
      });
      props.onSaved(t);
      props.onClose();
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Show when={props.open}>
      <div
        class="modal-scrim items-start justify-center"
        style={{ "padding-top": "10vh" }}
        onClick={(e) => {
          if (e.target === e.currentTarget) props.onClose();
        }}
      >
        <div class="modal-card w-[36rem] max-w-[90vw]">
          <header class="flex items-center justify-between border-b border-border px-5 py-3">
            <h2 class="text-[13px] font-semibold tracking-wide text-text">
              Capture to vault
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
          <div class="px-5 py-4">
            <label class="section-label block">
              Title
            </label>
            <input
              ref={titleEl}
              value={title()}
              onInput={(e) => setTitle(e.currentTarget.value)}
              placeholder="e.g. stephen-boyd, paper title, idea name…"
              class="input-pill mt-1.5 w-full px-3 py-2 text-[14px]"
            />
            <label class="section-label mt-4 block">
              Body
            </label>
            <textarea
              value={body()}
              onInput={(e) => setBody(e.currentTarget.value)}
              placeholder="paste / type / drop. markdown supported. [[wikilinks]] auto-create."
              rows={10}
              class="input-pill mt-1.5 w-full resize-y px-3 py-2 font-mono text-[13px]"
            />
            <div class="mt-4 flex items-center gap-3">
              <label class="section-label">
                Source
              </label>
              <select
                value={sourceKind()}
                onChange={(e) => setSourceKind(e.currentTarget.value)}
                class="surface-inset rounded-lg px-2 py-1 text-[12px] outline-none"
              >
                {SOURCE_KINDS.map((k) => (
                  <option value={k}>{k}</option>
                ))}
              </select>
              <Show when={error()}>
                <span class="text-[12px] text-danger">{error()}</span>
              </Show>
            </div>
          </div>
          <footer class="flex items-center justify-between border-t border-border px-5 py-3">
            <span class="text-text-dim">
              <span class="kbd-chip">⌘↩</span>{" "}
              <span class="kbd-chip">esc</span>
            </span>
            <div class="flex gap-2">
              <button
                type="button"
                class="btn-soft btn-soft--sm btn-soft--ghost"
                onClick={props.onClose}
                disabled={saving()}
              >
                cancel
              </button>
              <button
                type="button"
                class="btn-soft btn-soft--sm btn-soft--primary"
                onClick={save}
                disabled={saving() || (title().trim().length === 0 && body().trim().length === 0)}
              >
                {saving() ? "saving…" : "save"}
              </button>
            </div>
          </footer>
        </div>
      </div>
    </Show>
  );
}
