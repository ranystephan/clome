import { onMount, onCleanup } from "solid-js";
import { EditorState, RangeSetBuilder } from "@codemirror/state";
import {
  EditorView,
  Decoration,
  DecorationSet,
  ViewPlugin,
  ViewUpdate,
  drawSelection,
  highlightActiveLine,
  keymap,
} from "@codemirror/view";
import {
  history,
  historyKeymap,
  defaultKeymap,
  indentWithTab,
} from "@codemirror/commands";
import {
  syntaxHighlighting,
  HighlightStyle,
  bracketMatching,
  indentOnInput,
} from "@codemirror/language";
import {
  closeBrackets,
  closeBracketsKeymap,
} from "@codemirror/autocomplete";
import { searchKeymap } from "@codemirror/search";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { languages as cmLanguages } from "@codemirror/language-data";
import { tags as t } from "@lezer/highlight";

type Props = {
  initialValue: string;
  onChange: (text: string) => void;
  autofocus?: boolean;
  onEscape?: () => void;
};

// Custom highlight that maps lezer tags onto our design tokens. Drives
// both the markdown structure (headings/bold/italic/wikilinks) and the
// fenced-language tokens (keyword/string/number/comment).
const clomeHighlight = HighlightStyle.define([
  // Markdown structure
  {
    tag: t.heading1,
    color: "var(--color-text)",
    fontWeight: "700",
    fontSize: "1.45em",
  },
  {
    tag: t.heading2,
    color: "var(--color-text)",
    fontWeight: "700",
    fontSize: "1.25em",
  },
  {
    tag: t.heading3,
    color: "var(--color-text)",
    fontWeight: "600",
    fontSize: "1.1em",
  },
  {
    tag: [t.heading4, t.heading5, t.heading6],
    color: "var(--color-text)",
    fontWeight: "600",
  },
  { tag: t.strong, fontWeight: "700", color: "var(--color-text)" },
  { tag: t.emphasis, fontStyle: "italic", color: "var(--color-text)" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  {
    tag: t.link,
    color: "var(--color-accent)",
    textDecoration: "none",
  },
  {
    tag: t.url,
    color: "var(--color-accent)",
    textDecoration: "underline",
  },
  {
    tag: t.monospace,
    color: "oklch(0.85 0.13 200)",
    fontFamily: "var(--font-mono)",
    background: "color-mix(in oklch, oklch(0.85 0.13 200) 14%, transparent)",
    borderRadius: "0.25rem",
    padding: "0 0.2em",
  },
  { tag: t.contentSeparator, color: "var(--color-text-subtle)" },
  { tag: t.list, color: "var(--color-accent)" },
  {
    tag: t.processingInstruction,
    color: "var(--color-text-subtle)",
  },
  { tag: t.meta, color: "var(--color-text-subtle)" },
  {
    tag: t.quote,
    color: "var(--color-text-muted)",
    fontStyle: "italic",
  },
  { tag: t.atom, color: "oklch(0.78 0.15 30)" },
  { tag: t.invalid, color: "oklch(0.7 0.18 30)" },
  // Code-fence tokens (when @codemirror/language-data resolves a lang)
  { tag: t.keyword, color: "oklch(0.78 0.18 320)" },
  { tag: t.controlKeyword, color: "oklch(0.78 0.18 320)" },
  { tag: t.operatorKeyword, color: "oklch(0.78 0.18 320)" },
  { tag: t.modifier, color: "oklch(0.78 0.18 320)" },
  { tag: [t.string, t.special(t.string)], color: "oklch(0.82 0.13 145)" },
  { tag: [t.number, t.bool, t.null], color: "oklch(0.78 0.15 30)" },
  { tag: t.comment, color: "var(--color-text-subtle)", fontStyle: "italic" },
  { tag: t.docComment, color: "var(--color-text-subtle)", fontStyle: "italic" },
  { tag: t.variableName, color: "var(--color-text)" },
  { tag: t.function(t.variableName), color: "oklch(0.82 0.13 220)" },
  { tag: t.function(t.propertyName), color: "oklch(0.82 0.13 220)" },
  { tag: t.propertyName, color: "var(--color-text)" },
  { tag: t.typeName, color: "oklch(0.82 0.14 220)" },
  { tag: t.className, color: "oklch(0.82 0.14 220)" },
  { tag: t.namespace, color: "var(--color-text-muted)" },
  { tag: t.definition(t.variableName), color: "var(--color-text)" },
  { tag: t.tagName, color: "oklch(0.82 0.13 220)" },
  { tag: t.attributeName, color: "oklch(0.82 0.14 60)" },
  { tag: t.attributeValue, color: "oklch(0.82 0.13 145)" },
  { tag: t.regexp, color: "oklch(0.82 0.13 145)" },
  { tag: t.escape, color: "oklch(0.82 0.13 30)" },
  { tag: t.punctuation, color: "var(--color-text-muted)" },
  { tag: t.bracket, color: "var(--color-text-muted)" },
  { tag: t.angleBracket, color: "var(--color-text-muted)" },
  { tag: t.squareBracket, color: "var(--color-text-muted)" },
  { tag: t.brace, color: "var(--color-text-muted)" },
  { tag: t.operator, color: "var(--color-text-muted)" },
]);

// ── [[wikilink]] decoration ───────────────────────────────────────
// markdown-lang doesn't know about Obsidian-style wikilinks. Tokenize
// them ourselves so they pop in the editor like the chip in the
// rendered view.
const wikilinkRegex = /\[\[([^\[\]\n]+)\]\]/g;
const wikilinkPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = this.build(view);
    }
    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = this.build(update.view);
      }
    }
    build(view: EditorView): DecorationSet {
      const builder = new RangeSetBuilder<Decoration>();
      for (const { from, to } of view.visibleRanges) {
        const text = view.state.sliceDoc(from, to);
        wikilinkRegex.lastIndex = 0;
        let m: RegExpExecArray | null;
        while ((m = wikilinkRegex.exec(text)) !== null) {
          const start = from + m.index;
          const end = start + m[0].length;
          builder.add(
            start,
            end,
            Decoration.mark({ class: "cm-wikilink" }),
          );
        }
      }
      return builder.finish();
    }
  },
  { decorations: (v) => v.decorations },
);

// ── math decoration ───────────────────────────────────────────────
// markdown-lang has no concept of LaTeX math. Tokenize $…$ / $$…$$ /
// \(…\) / \[…\] in the source so the user sees what will render.
// Skip ranges inside ```fenced code``` so a literal `$x` in a shell
// example doesn't get math'd.
type MathRange = { start: number; end: number; display: boolean };

function findCodeBlockRanges(text: string): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  let inBlock = false;
  let blockStart = -1;
  let pos = 0;
  const lines = text.split("\n");
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    if (line.trimStart().startsWith("```")) {
      if (!inBlock) {
        inBlock = true;
        blockStart = pos;
      } else {
        out.push([blockStart, pos + line.length]);
        inBlock = false;
      }
    }
    pos += line.length + 1;
  }
  if (inBlock) {
    out.push([blockStart, text.length]);
  }
  return out;
}

function findMathRanges(text: string): MathRange[] {
  const code = findCodeBlockRanges(text);
  const inCode = (p: number): boolean => {
    for (const [s, e] of code) if (p >= s && p < e) return true;
    return false;
  };
  const out: MathRange[] = [];
  let i = 0;
  while (i < text.length) {
    if (inCode(i)) {
      i++;
      continue;
    }
    if (text.startsWith("\\[", i)) {
      const end = text.indexOf("\\]", i + 2);
      if (end !== -1) {
        out.push({ start: i, end: end + 2, display: true });
        i = end + 2;
        continue;
      }
    }
    if (text.startsWith("\\(", i)) {
      const end = text.indexOf("\\)", i + 2);
      if (end !== -1 && !text.slice(i + 2, end).includes("\n")) {
        out.push({ start: i, end: end + 2, display: false });
        i = end + 2;
        continue;
      }
    }
    if (text.startsWith("$$", i)) {
      const end = text.indexOf("$$", i + 2);
      if (end !== -1) {
        out.push({ start: i, end: end + 2, display: true });
        i = end + 2;
        continue;
      }
    }
    if (text[i] === "$") {
      let j = i + 1;
      while (j < text.length && text[j] !== "\n" && text[j] !== "$") j++;
      if (text[j] === "$") {
        const next = text[j + 1];
        const nextIsDigit = next !== undefined && /[0-9]/.test(next);
        const inner = text.slice(i + 1, j);
        if (!nextIsDigit && inner.trim().length > 0) {
          out.push({ start: i, end: j + 1, display: false });
          i = j + 1;
          continue;
        }
      }
    }
    i++;
  }
  return out;
}

const mathPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = this.build(view);
    }
    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = this.build(update.view);
      }
    }
    build(view: EditorView): DecorationSet {
      const builder = new RangeSetBuilder<Decoration>();
      const text = view.state.doc.toString();
      const ranges = findMathRanges(text);
      for (const r of ranges) {
        builder.add(
          r.start,
          r.end,
          Decoration.mark({
            class: r.display ? "cm-math cm-math-display" : "cm-math cm-math-inline",
          }),
        );
      }
      return builder.finish();
    }
  },
  { decorations: (v) => v.decorations },
);

// ── code-block line shading ──────────────────────────────────────
// Make ```fence``` regions visually distinct in source mode, even
// though sub-language token highlighting is already kicking in.
const codeBlockPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = this.build(view);
    }
    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = this.build(update.view);
      }
    }
    build(view: EditorView): DecorationSet {
      const builder = new RangeSetBuilder<Decoration>();
      const lineDeco = Decoration.line({ class: "cm-codeblock-line" });
      const fenceDeco = Decoration.line({
        class: "cm-codeblock-line cm-codeblock-fence",
      });
      let inBlock = false;
      const total = view.state.doc.lines;
      for (let i = 1; i <= total; i++) {
        const line = view.state.doc.line(i);
        const trimmed = line.text.trimStart();
        if (trimmed.startsWith("```")) {
          builder.add(line.from, line.from, fenceDeco);
          inBlock = !inBlock;
          continue;
        }
        if (inBlock) {
          builder.add(line.from, line.from, lineDeco);
        }
      }
      return builder.finish();
    }
  },
  { decorations: (v) => v.decorations },
);

const editorTheme = EditorView.theme(
  {
    "&": {
      backgroundColor: "transparent",
      color: "var(--color-text)",
      fontSize: "14px",
      fontFamily: "var(--font-mono)",
    },
    ".cm-content": {
      caretColor: "var(--color-accent)",
      padding: "0",
    },
    ".cm-gutters": { display: "none" },
    ".cm-activeLine": { backgroundColor: "transparent" },
    ".cm-activeLineGutter": { backgroundColor: "transparent" },
    "&.cm-focused": { outline: "none" },
    ".cm-scroller": {
      fontFamily: "var(--font-mono)",
      lineHeight: "1.65",
    },
    ".cm-selectionBackground, &.cm-focused > .cm-scroller .cm-selectionBackground, ::selection": {
      backgroundColor:
        "color-mix(in oklch, var(--color-accent) 28%, transparent) !important",
    },
    ".cm-cursor, .cm-dropCursor": {
      borderLeftColor: "var(--color-accent)",
    },
    // Render fenced code blocks visually distinct in the editor too —
    // line wrapping inside still applies because the wrapper is inline.
    ".cm-line:has(.tok-monospace)": {
      backgroundColor: "color-mix(in oklch, var(--color-text) 4%, transparent)",
    },
  },
  { dark: true },
);

/**
 * CodeMirror 6 wrapper. Editor owns the buffer; parent reacts to onChange
 * to drive auto-save. Re-mount the component (key by note title) when you
 * want to load a different note's body — we don't sync prop → editor.
 */
export default function NoteEditor(props: Props) {
  let containerEl!: HTMLDivElement;
  let view: EditorView | null = null;

  onMount(() => {
    const state = EditorState.create({
      doc: props.initialValue,
      extensions: [
        history(),
        drawSelection(),
        highlightActiveLine(),
        bracketMatching(),
        closeBrackets(),
        indentOnInput(),
        EditorView.lineWrapping,
        markdown({
          base: markdownLanguage,
          codeLanguages: cmLanguages,
        }),
        editorTheme,
        syntaxHighlighting(clomeHighlight),
        wikilinkPlugin,
        codeBlockPlugin,
        mathPlugin,
        keymap.of([
          ...closeBracketsKeymap,
          ...defaultKeymap,
          ...historyKeymap,
          ...searchKeymap,
          indentWithTab,
          {
            key: "Escape",
            run: () => {
              if (props.onEscape) {
                props.onEscape();
                return true;
              }
              return false;
            },
          },
        ]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            props.onChange(update.state.doc.toString());
          }
        }),
      ],
    });

    view = new EditorView({
      state,
      parent: containerEl,
    });

    if (props.autofocus) {
      queueMicrotask(() => view?.focus());
    }
  });

  onCleanup(() => {
    view?.destroy();
    view = null;
  });

  return <div ref={containerEl} class="note-editor h-full" />;
}
