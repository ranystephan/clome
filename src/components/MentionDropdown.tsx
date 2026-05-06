import { For, Show } from "solid-js";
import { Bot, FileText, Plus } from "lucide-solid";
import { SourceDot } from "./SourceBadge";

export type MentionItem =
  | { kind: "agent"; idKey: string; title: string; model: string }
  | { kind: "note"; title: string; source_kind: string };

type Props = {
  query: string;
  items: MentionItem[];
  showCreate: boolean;
  selectedIndex: number;
  onPick: (item: MentionItem) => void;
  onCreateNote: (title: string) => void;
  onHover: (index: number) => void;
};

export default function MentionDropdown(props: Props) {
  const agentItems = () => props.items.filter((item) => item.kind === "agent");
  const noteItems = () => props.items.filter((item) => item.kind === "note");
  const noteOffset = () => agentItems().length;
  const createIndex = () => props.items.length;

  return (
    <div class="mention-menu absolute bottom-full left-0 z-50 mb-2 w-[21.5rem] overflow-hidden">
      <Show when={agentItems().length > 0}>
        <div class="mention-menu__section">
          <Bot size={11} strokeWidth={2.2} />
          <span>Agents</span>
        </div>
      </Show>
      <For each={agentItems()}>
        {(item, i) => (
          <button
            type="button"
            class="mention-menu__row"
            classList={{
              "bg-bg-hover": i() === props.selectedIndex,
              "hover:bg-bg-hover": i() !== props.selectedIndex,
            }}
            onMouseEnter={() => props.onHover(i())}
            onMouseDown={(e) => {
              e.preventDefault();
              props.onPick(item);
            }}
          >
            <span class="mention-menu__agent-dot" />
            <span class="min-w-0 flex-1 truncate text-text">{item.title}</span>
            <span class="mention-menu__meta truncate">{item.model}</span>
          </button>
        )}
      </For>
      <Show when={noteItems().length > 0}>
        <div class="mention-menu__section" classList={{ "border-t border-border": agentItems().length > 0 }}>
          <FileText size={11} strokeWidth={2.2} />
          <span>Notes</span>
        </div>
      </Show>
      <For each={noteItems()}>
        {(item, i) => {
          const idx = () => noteOffset() + i();
          return (
            <button
              type="button"
              class="mention-menu__row"
              classList={{
                "bg-bg-hover": idx() === props.selectedIndex,
                "hover:bg-bg-hover": idx() !== props.selectedIndex,
              }}
              onMouseEnter={() => props.onHover(idx())}
              onMouseDown={(e) => {
                e.preventDefault();
                props.onPick(item);
              }}
            >
              <SourceDot kind={item.source_kind} />
              <span class="min-w-0 flex-1 truncate text-text">{item.title}</span>
              <span class="mention-menu__meta">note</span>
            </button>
          );
        }}
      </For>
      <Show when={props.showCreate}>
        <Show when={props.items.length > 0}>
          <div class="border-t border-border" />
        </Show>
        <button
          type="button"
          class="mention-menu__row"
          classList={{
            "bg-bg-hover": props.selectedIndex === createIndex(),
            "hover:bg-bg-hover": props.selectedIndex !== createIndex(),
          }}
          onMouseEnter={() => props.onHover(createIndex())}
          onMouseDown={(e) => {
            e.preventDefault();
            props.onCreateNote(props.query);
          }}
        >
          <Plus size={13} strokeWidth={2} class="text-text-dim shrink-0" />
          <span class="text-text-dim">create</span>
          <span class="truncate text-text">"{props.query}"</span>
        </button>
      </Show>
      <Show when={props.items.length === 0 && !props.showCreate}>
        <p class="px-3 py-2.5 text-[12px] text-text-dim">
          type to find an agent or note
        </p>
      </Show>
    </div>
  );
}
