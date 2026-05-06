const WIKILINK_RE = /\[\[([^\[\]]+)\]\]/g;

export type Segment =
  | { kind: "text"; text: string }
  | { kind: "wikilink"; title: string };

export function parseWikilinks(text: string): Segment[] {
  const segments: Segment[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  WIKILINK_RE.lastIndex = 0;
  while ((match = WIKILINK_RE.exec(text)) !== null) {
    if (match.index > lastIndex) {
      segments.push({ kind: "text", text: text.slice(lastIndex, match.index) });
    }
    segments.push({ kind: "wikilink", title: match[1].trim() });
    lastIndex = WIKILINK_RE.lastIndex;
  }
  if (lastIndex < text.length) {
    segments.push({ kind: "text", text: text.slice(lastIndex) });
  }
  return segments;
}

export function extractLinkTitles(text: string): string[] {
  const titles = new Set<string>();
  const re = /\[\[([^\[\]]+)\]\]/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    titles.add(m[1].trim());
  }
  return Array.from(titles);
}
