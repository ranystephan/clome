import { createEffect, ErrorBoundary } from "solid-js";
import {
  renderMarkdown,
  decodeCodeFromAttr,
  extractToolResultsFromMarkdown,
} from "../lib/markdown";
import { buildCardHtml, type ToolResult } from "../lib/toolCards";

export type TypedRefClick = {
  kind: string;
  key: string;
};

type Props = {
  text: string;
  /** When true, the most recent tool chip in this message gets a
   * pulsing border to indicate the sidecar is currently running. The
   * effect targets the LAST .tool-chip child after each render. */
  toolRunning?: boolean;
  /** Tool results in emission order. We post-process the rendered DOM
   * and swap each .tool-chip[i] with a rich card built from
   * toolResults[i] when one is available. */
  toolResults?: ToolResult[];
  onWikilinkClick: (title: string) => void;
  /** Kind-aware reference click. Fires for `[[email:THREAD_ID|Subject]]`
   * and similar typed wikilinks; if absent, typed refs degrade to
   * onWikilinkClick(label) so older callers keep working. */
  onTypedRefClick?: (ref: TypedRefClick) => void;
};

export default function MarkdownContent(props: Props) {
  let container!: HTMLDivElement;

  // Re-render on text/toolRunning/toolResults changes. We set
  // innerHTML imperatively (rather than via Solid's `innerHTML` prop)
  // so we can post-process the resulting DOM:
  //   1. swap each chip with a rich card if its result is available
  //   2. flag the still-running chip with a pulsing border
  // Solid's `innerHTML` prop runs before our effect can grab the
  // fresh ref, so doing both manually keeps them in lockstep.
  createEffect(() => {
    let html: string;
    try {
      html = renderMarkdown(props.text);
    } catch (e) {
      console.error("MarkdownContent render failed:", e);
      html = `<pre style="white-space:pre-wrap">${escapeHtml(props.text)}</pre>`;
    }
    container.innerHTML = html;

    // Walk chips in document order. Each chip[i] corresponds to
    // toolResults[i] from the backend (same emission order). Replace
    // with a richer card when we have one; otherwise leave the chip
    // (still useful as a "running" placeholder).
    const chips = Array.from(container.querySelectorAll<HTMLElement>(".tool-chip"));
    const inferredResults = extractToolResultsFromMarkdown(props.text);
    const results = props.toolResults?.length ? props.toolResults : inferredResults;
    chips.forEach((chip, i) => {
      const r = results[i];
      if (!r) return;
      const cardHtml = buildCardHtml(r);
      if (!cardHtml) return;
      const tmpl = document.createElement("template");
      tmpl.innerHTML = cardHtml.trim();
      const card = tmpl.content.firstElementChild;
      if (card) chip.replaceWith(card);
    });

    // After swapping, the "running" chip is whichever .tool-chip is
    // still left at the end (the most recent one we don't yet have
    // a result for). Pulse it so the user sees we're not stuck.
    if (props.toolRunning) {
      const remaining = container.querySelectorAll(".tool-chip");
      const last = remaining[remaining.length - 1];
      if (last) last.classList.add("tool-chip--running");
    }
  });

  function handleClick(e: MouseEvent) {
    const target = e.target as HTMLElement | null;
    if (!target) return;

    // Typed reference wins over the legacy bare-title form so the
    // selector order doesn't matter for the renderer.
    const typedBtn = target.closest("[data-wikilink-kind]") as HTMLElement | null;
    if (typedBtn) {
      const kind = typedBtn.getAttribute("data-wikilink-kind");
      const key = typedBtn.getAttribute("data-wikilink-key");
      if (kind && key) {
        if (props.onTypedRefClick) {
          props.onTypedRefClick({ kind, key });
        } else {
          // Fallback: route the visible label as if it were a note.
          props.onWikilinkClick(typedBtn.textContent ?? key);
        }
      }
      return;
    }

    const wikilinkBtn = target.closest("[data-wikilink]") as HTMLElement | null;
    if (wikilinkBtn) {
      const title = wikilinkBtn.getAttribute("data-wikilink");
      if (title) props.onWikilinkClick(title);
      return;
    }

    const copyBtn = target.closest("[data-code-b64]") as HTMLElement | null;
    if (copyBtn) {
      const b64 = copyBtn.getAttribute("data-code-b64");
      const code = b64 ? decodeCodeFromAttr(b64) : "";
      if (code) {
        navigator.clipboard.writeText(code).then(() => {
          const original = copyBtn.textContent;
          copyBtn.textContent = "copied";
          setTimeout(() => {
            copyBtn.textContent = original ?? "copy";
          }, 1400);
        });
      }
      return;
    }
  }

  return (
    <ErrorBoundary
      fallback={(err) => (
        <div class="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-[13px] text-danger">
          <div class="font-medium">Render error</div>
          <pre class="mt-1 whitespace-pre-wrap text-[11px] opacity-75">
            {String(err)}
          </pre>
          <pre class="mt-2 whitespace-pre-wrap text-[12px] text-text">
            {props.text}
          </pre>
        </div>
      )}
    >
      <div ref={container} class="md-content" onClick={handleClick} />
    </ErrorBoundary>
  );
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
