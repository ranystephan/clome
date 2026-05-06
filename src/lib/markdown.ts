import MarkdownIt from "markdown-it";
import katexLib from "katex";
import * as hljsModule from "highlight.js/lib/common";
import * as DOMPurifyModule from "dompurify";

// CJS-via-ESM interop: vite sometimes hands back { default: x } instead of x.
function unwrap<T>(mod: any): T {
  return mod && mod.default ? mod.default : mod;
}

const hljs: any = unwrap(hljsModule);
const DOMPurify: any = unwrap(DOMPurifyModule);
const katex: any = unwrap(katexLib);

const md: MarkdownIt = new MarkdownIt({
  // html is on so things like <sup>/<sub>/<br> from agent or note bodies
  // render. DOMPurify below scrubs anything dangerous before it hits the DOM.
  html: true,
  linkify: true,
  breaks: false,
  typographer: false,
});

function escapeAttr(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// ── Math (KaTeX) ─────────────────────────────────────────────────
//
// We do this ourselves instead of relying on markdown-it-katex because
// LLMs (Qwen, GPT-4) emit math with several different delimiter styles
// — `$…$`, `$$…$$`, `\(…\)`, `\[…\]` — and the upstream plugin only
// recognizes the dollar variants and is brittle around whitespace.

function renderMath(latex: string, displayMode: boolean): string {
  try {
    return katex.renderToString(latex, {
      throwOnError: false,
      displayMode,
      strict: "ignore",
      output: "html",
    });
  } catch (e) {
    return `<span class="katex-error" title="${escapeAttr(String(e))}">${escapeAttr(latex)}</span>`;
  }
}

// Block math at start of a line: `$$ … $$` or `\[ … \]`. Multi-line OK.
md.block.ruler.before(
  "paragraph",
  "math_block",
  (state, startLine, endLine, silent) => {
    const start = state.bMarks[startLine] + state.tShift[startLine];
    const max = state.eMarks[startLine];
    const line = state.src.slice(start, max);

    let openLen = 0;
    let closeMarker = "";
    if (line.startsWith("$$")) {
      openLen = 2;
      closeMarker = "$$";
    } else if (line.startsWith("\\[")) {
      openLen = 2;
      closeMarker = "\\]";
    } else {
      return false;
    }

    const restOfFirst = line.slice(openLen);
    const sameLineCloseIdx = restOfFirst.indexOf(closeMarker);
    if (sameLineCloseIdx !== -1) {
      // open + close on the same line
      if (silent) return true;
      const inner = restOfFirst.slice(0, sameLineCloseIdx).trim();
      const token = state.push("math_block", "math", 0);
      token.block = true;
      token.content = inner;
      token.markup = closeMarker;
      state.line = startLine + 1;
      return true;
    }

    // multi-line: scan forward for closing marker
    let collected = restOfFirst;
    let endLineIdx = -1;
    for (let i = startLine + 1; i < endLine; i++) {
      const lstart = state.bMarks[i] + state.tShift[i];
      const lmax = state.eMarks[i];
      const lline = state.src.slice(lstart, lmax);
      const idx = lline.indexOf(closeMarker);
      if (idx !== -1) {
        collected += "\n" + lline.slice(0, idx);
        endLineIdx = i;
        break;
      }
      collected += "\n" + lline;
    }
    if (endLineIdx === -1) return false;

    if (silent) return true;
    const token = state.push("math_block", "math", 0);
    token.block = true;
    token.content = collected.trim();
    token.markup = closeMarker;
    state.line = endLineIdx + 1;
    return true;
  },
);

md.renderer.rules.math_block = (tokens, idx) =>
  `<div class="math-block">${renderMath(tokens[idx].content, true)}</div>`;

// Inline math: `\( … \)`, `\[ … \]` (mid-text), `$…$`, `$$…$$`.
// MUST run before "escape" — markdown-it's escape rule eats `\(` `\[`
// (backslash + ASCII punct) and rewrites them to literal `(` `[`.
md.inline.ruler.before("escape", "math_inline", (state, silent) => {
  const start = state.pos;
  const src = state.src;

  let openLen = 0;
  let closeMarker = "";
  let display = false;

  if (src.startsWith("\\(", start)) {
    openLen = 2;
    closeMarker = "\\)";
    display = false;
  } else if (src.startsWith("\\[", start)) {
    openLen = 2;
    closeMarker = "\\]";
    display = true;
  } else if (src.startsWith("$$", start)) {
    openLen = 2;
    closeMarker = "$$";
    display = true;
  } else if (src.charCodeAt(start) === 0x24 /* $ */) {
    // single $ — guard against currency by requiring a non-digit after the
    // closing $. Also bail if next char is whitespace (looks more like prose).
    openLen = 1;
    closeMarker = "$";
    display = false;
  } else {
    return false;
  }

  // find closing marker (allow newlines inside display math).
  // Check the closeMarker BEFORE the escape-pair skip — otherwise `\)` and
  // `\]` get swallowed as escape pairs and we never find the close.
  let i = start + openLen;
  let found = -1;
  while (i < src.length) {
    if (src.startsWith(closeMarker, i)) {
      found = i;
      break;
    }
    if (src[i] === "\\" && i + 1 < src.length) {
      // skip an escaped pair like `\\` or `\$` inside the math body
      i += 2;
      continue;
    }
    if (!display && src[i] === "\n") {
      // single $…$ stays on one line
      break;
    }
    i++;
  }
  if (found === -1) return false;

  const inner = src.slice(start + openLen, found);
  if (inner.trim().length === 0) return false;

  // currency guard for $…$ only
  if (openLen === 1 && closeMarker === "$") {
    const afterCode = src.charCodeAt(found + 1);
    if (afterCode >= 0x30 && afterCode <= 0x39) return false;
  }

  if (!silent) {
    const token = state.push("math_inline", "math", 0);
    token.content = inner;
    token.markup = closeMarker;
    (token as any).meta = { display };
  }
  state.pos = found + closeMarker.length;
  return true;
});

md.renderer.rules.math_inline = (tokens, idx) => {
  const token = tokens[idx] as any;
  const display = !!token.meta?.display;
  return renderMath(token.content, display);
};

// ── [[wikilink]] inline rule ─────────────────────────────────────
//
// Two flavors:
//   * `[[Note Title]]`                     — note wikilink (legacy)
//   * `[[kind:KEY|Display Label]]`         — typed reference. Today
//     `kind` is one of: `email`, `event`, `file`, `project`, `chat`.
//     Display label is what the user sees; KEY is the opaque id the
//     click handler routes on (e.g. an email thread_id).
md.inline.ruler.before("emphasis", "wikilink", (state, silent) => {
  const start = state.pos;
  const src = state.src;
  if (src.charCodeAt(start) !== 0x5b /* [ */) return false;
  if (src.charCodeAt(start + 1) !== 0x5b /* [ */) return false;

  const closeIdx = src.indexOf("]]", start + 2);
  if (closeIdx === -1) return false;

  // Only `]]` terminates, and a literal newline aborts (so a stray
  // `[[` doesn't slurp the whole rest of the document). Raw `[` and
  // single `]` inside the label are fine — agents like to write
  // things like `[[email:X|Subject - [Project Name]]]` and the
  // user shouldn't be punished with a literal-text fallback because
  // of model formatting noise.
  const inner = src.slice(start + 2, closeIdx);
  if (inner.length === 0 || /\n/.test(inner)) return false;

  if (!silent) {
    const token = state.push("wikilink", "", 0);
    token.content = inner.trim();
  }
  state.pos = closeIdx + 2;
  return true;
});

const TYPED_KIND_RE = /^([a-z_]+):([^|]+?)(?:\|(.+))?$/;
const RECOGNIZED_KINDS = new Set([
  "email",
  "event",
  "file",
  "project",
  "chat",
]);

md.renderer.rules.wikilink = (tokens, idx) => {
  const raw = tokens[idx].content;
  const m = raw.match(TYPED_KIND_RE);
  if (m && RECOGNIZED_KINDS.has(m[1])) {
    const kind = m[1];
    const key = m[2].trim();
    const label = (m[3] ?? key).trim();
    return `<button type="button" class="wikilink-chip wikilink-chip--${escapeAttr(kind)}" data-wikilink-kind="${escapeAttr(kind)}" data-wikilink-key="${escapeAttr(key)}">${escapeAttr(label)}</button>`;
  }
  // Legacy note form: bare title.
  return `<button type="button" class="wikilink-chip" data-wikilink="${escapeAttr(raw)}">${escapeAttr(raw)}</button>`;
};

// ── clome-tool fenced block → tool-call chip ─────────────────────

/**
 * Models emit two flavors of broken JSON inside tool blocks, both
 * rejected by strict JSON.parse:
 *   1. Raw newlines / tabs inside string literals.
 *   2. LaTeX-style backslashes inside string literals (`\[`, `\lambda`,
 *      `\quad`) — invalid JSON escapes.
 * Walk the input, normalize both inside string literals, then retry.
 */
type ToolHeader = Record<string, string>;

function parseToolBlock(block: string): ToolHeader | null {
  const headers: ToolHeader = {};
  const lines = block.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "---") break; // body section starts; chip only needs header
    if (trimmed === "") continue;
    const idx = trimmed.indexOf(":");
    if (idx <= 0) continue;
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    if (key) headers[key] = value;
  }
  return headers.action ? headers : null;
}

function toolBlockBody(block: string): string {
  const lines = block.split("\n");
  const sep = lines.findIndex((line) => line.trim() === "---");
  return sep >= 0 ? lines.slice(sep + 1).join("\n").trim() : "";
}

function parseToolBlockJsonBody(block: string): unknown {
  const body = toolBlockBody(block);
  if (!body) return null;
  const fenced =
    body.match(/^\s*`{3,}\s*json\s*\n([\s\S]*?)\n\s*`{3,}\s*$/i) ??
    body.match(/`{3,}\s*json\s*\n([\s\S]*?)\n\s*`{3,}/i);
  const raw = (fenced ? fenced[1] : body).trim();
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function renderToolChip(block: string): string {
  const h = parseToolBlock(block);
  if (!h) {
    return `<span class="tool-chip tool-chip--unparsed"><span class="tool-chip__icon">?</span><span class="tool-chip__verb">tool call</span></span>`;
  }
  const action = h.action;
  const wikilink = (title: string) =>
    `<button type="button" class="wikilink-chip" data-wikilink="${escapeAttr(title)}">${escapeAttr(title)}</button>`;

  let icon = "✎";
  let verb = action;
  let body = "";
  if (action === "create_note" && h.title) {
    icon = "✎";
    verb = "created";
    body = wikilink(h.title);
  } else if (action === "append_to_note" && h.title) {
    icon = "+";
    verb = "appended to";
    body = wikilink(h.title);
  } else if (action === "replace_note_body" && h.title) {
    icon = "↻";
    verb = "rewrote";
    body = wikilink(h.title);
  } else if (action === "delete_note" && h.title) {
    icon = "✕";
    verb = "deleted";
    body = wikilink(h.title);
  } else if (action === "link_notes" && h.from && h.to) {
    icon = "↗";
    verb = "linked";
    body = `${wikilink(h.from)} <span class="tool-chip__arrow">→</span> ${wikilink(h.to)}`;
  } else if (action === "create_event" && h.title) {
    icon = "📅";
    verb = "scheduled";
    body = `<span class="tool-chip__target">${escapeAttr(h.title)}</span>`;
    if (h.start) body += ` <span class="tool-chip__arrow">at</span> <span class="tool-chip__meta">${escapeAttr(h.start)}</span>`;
  } else if (action === "delete_event") {
    icon = "🗑";
    verb = "deleted event";
    const label = h.title || h.id || "";
    body = label
      ? `<span class="tool-chip__target">${escapeAttr(label)}</span>`
      : "";
    if (h.on) body += ` <span class="tool-chip__arrow">on</span> <span class="tool-chip__meta">${escapeAttr(h.on)}</span>`;
  } else if (action === "list_events") {
    icon = "📅";
    verb = "read calendar";
    const range = h.from || h.to ? `<span class="tool-chip__meta">${escapeAttr(h.from || "now")}${h.to ? " → " + escapeAttr(h.to) : ""}</span>` : "";
    body = range;
  } else if (action === "create_reminder" && h.title) {
    icon = "✓";
    verb = "added reminder";
    body = `<span class="tool-chip__target">${escapeAttr(h.title)}</span>`;
    if (h.due) body += ` <span class="tool-chip__arrow">due</span> <span class="tool-chip__meta">${escapeAttr(h.due)}</span>`;
  } else if (action === "list_reminders") {
    icon = "✓";
    verb = "read reminders";
    body = "";
  } else if (action === "edit_note" && h.title) {
    icon = "⟲";
    verb = "edited";
    body = wikilink(h.title);
  } else if (action === "relate" && h.from && h.to) {
    icon = "↗";
    verb = h.kind ? `related (${h.kind})` : "related";
    body = `${wikilink(h.from)} <span class="tool-chip__arrow">→</span> ${wikilink(h.to)}`;
  } else if (action === "graph_search" && h.query) {
    icon = "⌕";
    verb = "searched graph for";
    body = `<span class="tool-chip__target">"${escapeAttr(h.query)}"</span>`;
  } else if (action === "graph_neighbors" && h.title) {
    icon = "◌";
    verb = "explored graph from";
    body = wikilink(h.title);
  } else if (action === "list_mail") {
    icon = "📬";
    const hours = h.hours_back ? Number.parseInt(h.hours_back, 10) : 24;
    const range = !Number.isFinite(hours)
      ? "recent"
      : hours <= 24
        ? "last 24h"
        : hours <= 72
          ? `last ${Math.round(hours / 24)}d`
          : `last ${Math.round(hours / 24)}d`;
    const dir = h.direction ?? "received";
    verb = dir === "sent" ? "listed sent mail" : dir === "any" ? "listed mail" : "listed received mail";
    body = `<span class="tool-chip__meta">${escapeAttr(range)}</span>`;
  } else if (action === "search_mail" && h.query !== undefined) {
    icon = "✉";
    const dir = h.direction ?? "any";
    verb = dir === "sent" ? "searched sent mail for" : dir === "received" ? "searched received mail for" : "searched mail for";
    body = h.query
      ? `<span class="tool-chip__target">"${escapeAttr(h.query)}"</span>`
      : "";
  } else if (action === "list_recent_mail") {
    icon = "📥";
    verb = "read recent mail";
    body = h.limit ? `<span class="tool-chip__meta">${escapeAttr(h.limit)}</span>` : "";
  } else if (action === "read_thread" && (h.thread_id || h.id)) {
    icon = "📨";
    verb = "read thread";
    body = `<span class="tool-chip__meta">${escapeAttr(h.thread_id || h.id)}</span>`;
  } else if (action === "promote_email_thread" && h.thread_id) {
    icon = "★";
    verb = "promoted email thread";
    body = `<span class="tool-chip__meta">${escapeAttr(h.thread_id)}</span>`;
  } else if (action === "list_dir" && h.path) {
    icon = "📂";
    verb = "listed folder";
    body = `<span class="tool-chip__target">${escapeAttr(h.path)}</span>`;
  } else if (action === "read_file" && h.path) {
    icon = "📄";
    verb = "read file";
    body = `<span class="tool-chip__target">${escapeAttr(h.path)}</span>`;
  } else {
    // Generic fallback — better an unstyled chip than the raw
    // ```clome-tool``` code block falling through to markdown-it. We
    // use the first non-`action` header we can find (often the most
    // identifying one — title, query, path) as the body label.
    icon = "⚙";
    verb = action.replace(/_/g, " ");
    const summaryKey = ["title", "query", "path", "id", "thread_id", "from"].find(
      (k) => typeof h[k] === "string" && h[k].length > 0,
    );
    body = summaryKey
      ? `<span class="tool-chip__meta">${escapeAttr(h[summaryKey])}</span>`
      : "";
  }
  // data-tool-action lets the rich-card post-processor find chips
  // robustly (and lets us style by action without re-parsing).
  return `<span class="tool-chip" data-tool-action="${escapeAttr(action)}"><span class="tool-chip__icon">${icon}</span><span class="tool-chip__verb">${escapeAttr(verb)}</span>${body}</span>`;
}

// ── Pre-process: pull ```clome-tool blocks out before markdown-it ─
// Tool block format is YAML-ish header + optional body (separated by
// `---`), wrapped in a ```clome-tool fence. We scan source ourselves
// and swap the entire region with chip HTML directly, BEFORE markdown-it
// parses. Closing fence count must match opener (>=3); body can contain
// any inner triple-backtick code without breaking the outer.
function preprocessToolBlocks(text: string): string {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const opener = matchToolOpener(text, i);
    if (!opener) {
      out += text[i];
      i++;
      continue;
    }
    const close = findMatchingClose(
      text,
      opener.payloadStart,
      opener.tickCount,
    );
    if (!close) {
      out += text[i];
      i++;
      continue;
    }
    const blockContent = text.slice(opener.payloadStart, close.contentEnd);
    const chipHtml = renderToolChip(blockContent);
    if (!chipHtml) {
      out += text[i];
      i++;
      continue;
    }
    out += "\n" + chipHtml + "\n";
    i = close.afterClose;
    if (text[i] === "\n") i++;
  }
  return out;
}

function findMatchingClose(
  text: string,
  contentStart: number,
  tickCount: number,
): { contentEnd: number; afterClose: number } | null {
  let i = contentStart;
  let lineStart = i;
  let fallback: { contentEnd: number; afterClose: number } | null = null;
  while (i <= text.length) {
    if (i === text.length || text[i] === "\n") {
      // examine [lineStart..i)
      let j = lineStart;
      while (j < i && (text[j] === " " || text[j] === "\t")) j++;
      const tickStart = j;
      while (j < i && text[j] === "`") j++;
      const cnt = j - tickStart;
      if (cnt >= tickCount) {
        let clean = true;
        let k = j;
        while (k < i) {
          if (text[k] !== " " && text[k] !== "\t") {
            clean = false;
            break;
          }
          k++;
        }
        if (clean) {
          const found = {
            contentEnd: lineStart,
            afterClose: i < text.length ? i + 1 : i,
          };
          if (cnt >= tickCount) return found;
          if (cnt >= 3) fallback = found;
        }
      }
      i++;
      lineStart = i;
    } else {
      i++;
    }
  }
  // Weak local models sometimes use a 4-backtick opener and then close
  // with only 3 backticks (or forget to close entirely after fabricating
  // a fake JSON body). Prefer the 3-tick fallback if we found one;
  // otherwise treat end-of-text as an implicit close so the chip still
  // renders and the call goes through instead of leaving the bubble
  // empty / showing raw fence text.
  if (fallback) return fallback;
  return { contentEnd: text.length, afterClose: text.length };
}

function matchToolOpener(
  text: string,
  i: number,
): { payloadStart: number; tickCount: number } | null {
  if (i > 0 && text[i - 1] !== "\n") return null;
  let j = i;
  while (j < text.length && (text[j] === " " || text[j] === "\t")) j++;
  const tickStart = j;
  while (j < text.length && text[j] === "`") j++;
  const tickCount = j - tickStart;
  if (tickCount < 3) return null;
  const label = "clome-tool";
  if (text.substr(j, label.length) !== label) return null;
  let lineEnd = j + label.length;
  while (lineEnd < text.length && text[lineEnd] !== "\n") {
    if (text[lineEnd] !== " " && text[lineEnd] !== "\t") return null;
    lineEnd++;
  }
  return { payloadStart: lineEnd + 1, tickCount };
}

export function extractToolResultsFromMarkdown(text: string): {
  index: number;
  action: string;
  headers: Record<string, unknown> | null;
  result: unknown;
}[] {
  const results: {
    index: number;
    action: string;
    headers: Record<string, unknown> | null;
    result: unknown;
  }[] = [];
  let i = 0;
  while (i < text.length) {
    const opener = matchToolOpener(text, i);
    if (!opener) {
      i++;
      continue;
    }
    const close = findMatchingClose(text, opener.payloadStart, opener.tickCount);
    if (!close) {
      i++;
      continue;
    }
    const blockContent = text.slice(opener.payloadStart, close.contentEnd);
    const headers = parseToolBlock(blockContent);
    if (headers?.action) {
      results.push({
        index: results.length,
        action: headers.action,
        headers,
        result: parseToolBlockJsonBody(blockContent),
      });
    }
    i = close.afterClose;
    if (text[i] === "\n") i++;
  }
  return results;
}

// ── Fenced code blocks: header with language + copy button ───────
md.renderer.rules.fence = (tokens, idx) => {
  const token = tokens[idx];
  const info = (token.info || "").trim();
  const lang = info.split(/\s+/)[0] || "";
  const raw = token.content.replace(/\n$/, "");

  if (lang === "clome-tool") {
    // Defensive: pre-processor below should normally have already
    // stripped these, but keep the legacy path for blocks where the
    // opener happens to land cleanly inside markdown-it's parser.
    const chip = renderToolChip(raw);
    if (chip) return chip;
  }

  // ```math fenced block → KaTeX display render. Convention used by
  // GitHub, Pandoc, and most markdown editors. Lets users write LaTeX
  // without picking the right `$$` / `\[ \]` delimiter style.
  if (lang === "math" || lang === "latex" || lang === "tex") {
    return `<div class="math-block">${renderMath(raw, true)}</div>`;
  }

  let highlighted = "";
  if (lang && hljs.getLanguage(lang)) {
    try {
      highlighted = hljs.highlight(raw, {
        language: lang,
        ignoreIllegals: true,
      }).value;
    } catch {
      highlighted = "";
    }
  }
  if (!highlighted) {
    try {
      highlighted = hljs.highlightAuto(raw).value;
    } catch {
      highlighted = md.utils.escapeHtml(raw);
    }
  }

  const encoded = btoa(unescape(encodeURIComponent(raw)));
  return `<div class="code-block">
    <div class="code-block__header">
      <span class="code-block__lang">${escapeAttr(lang || "text")}</span>
      <button type="button" class="code-block__copy" data-code-b64="${encoded}">copy</button>
    </div>
    <pre><code class="hljs language-${escapeAttr(lang)}">${highlighted}</code></pre>
  </div>`;
};

// ── DOMPurify config: allow our buttons + data attrs + KaTeX ─────
const SANITIZE_CONFIG: any = {
  ADD_TAGS: [
    "button",
    "math",
    "semantics",
    "annotation",
    "mtable",
    "mtr",
    "mtd",
    "mo",
    "mi",
    "mn",
    "ms",
    "mtext",
    "mspace",
    "mover",
    "munder",
    "munderover",
    "msup",
    "msub",
    "msubsup",
    "mfrac",
    "msqrt",
    "mroot",
    "mrow",
    "mstyle",
    "mpadded",
    "menclose",
    "merror",
  ],
  ADD_ATTR: [
    "data-wikilink",
    "data-wikilink-kind",
    "data-wikilink-key",
    "data-tool-action",
    "data-code-b64",
    "type",
    "class",
    "aria-hidden",
    "style", // KaTeX html output uses inline style for sizing
  ],
};

export function renderMarkdown(text: string): string {
  if (!text) return "";
  try {
    const stripped = preprocessToolBlocks(text);
    const raw = md.render(stripped);
    if (DOMPurify && typeof DOMPurify.sanitize === "function") {
      return DOMPurify.sanitize(raw, SANITIZE_CONFIG) as string;
    }
    return raw;
  } catch (e) {
    console.error("renderMarkdown failed:", e);
    return text
      .split("\n")
      .map((line) =>
        line
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;"),
      )
      .join("<br/>");
  }
}

export function decodeCodeFromAttr(b64: string): string {
  try {
    return decodeURIComponent(escape(atob(b64)));
  } catch {
    return "";
  }
}
