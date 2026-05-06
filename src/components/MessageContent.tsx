import MarkdownContent, { type TypedRefClick } from "./MarkdownContent";
import type { ToolResult } from "../lib/toolCards";

type Props = {
  text: string;
  markdown?: boolean;
  /** Highlight the most recent tool chip with a running pulse. Set while
   * we're between a model-emitted tool block and the model's next turn,
   * driven by chat:tool_start / chat:tool_end events. */
  toolRunning?: boolean;
  /** Per-tool-call results streamed from the backend. MarkdownContent
   * swaps each chip with a rich card based on its position. */
  toolResults?: ToolResult[];
  onWikilinkClick: (title: string) => void;
  onTypedRefClick?: (ref: TypedRefClick) => void;
};

/**
 * Single rendering path: markdown-it plus our clome-tool chip
 * preprocessor. We used to swap to a plain-text streamer mid-stream,
 * but that hid the tool chip until the message finished, and joined the
 * close fence to the next iter's prose so neither rendered correctly.
 * Markdown rendering on every token is cheap enough at typical agent
 * message sizes; the preprocessor degrades gracefully to raw text when
 * a fence isn't closed yet.
 */
export default function MessageContent(props: Props) {
  // `markdown` is kept around for callers that want plain-text (user
  // bubbles); when false we fall back to a minimal pass-through that
  // still renders [[wikilinks]] as buttons.
  if (props.markdown === false) {
    return (
      <PlainText text={props.text} onWikilinkClick={props.onWikilinkClick} />
    );
  }
  return (
    <MarkdownContent
      text={props.text}
      toolRunning={props.toolRunning}
      toolResults={props.toolResults}
      onWikilinkClick={props.onWikilinkClick}
      onTypedRefClick={props.onTypedRefClick}
    />
  );
}

function PlainText(props: {
  text: string;
  onWikilinkClick: (title: string) => void;
}) {
  // Cheap parser inline so we don't need wikilinks.ts here.
  const parts: { kind: "text" | "link"; value: string }[] = [];
  const re = /\[\[([^\[\]\n]+)\]\]/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(props.text)) !== null) {
    if (m.index > last) parts.push({ kind: "text", value: props.text.slice(last, m.index) });
    parts.push({ kind: "link", value: m[1].trim() });
    last = m.index + m[0].length;
  }
  if (last < props.text.length) parts.push({ kind: "text", value: props.text.slice(last) });
  return (
    <span>
      {parts.map((p) =>
        p.kind === "text" ? (
          <span>{p.value}</span>
        ) : (
          <button
            type="button"
            class="wikilink-chip"
            onClick={() => props.onWikilinkClick(p.value)}
          >
            {p.value}
          </button>
        ),
      )}
    </span>
  );
}
