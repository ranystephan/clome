export const SOURCE_KIND_LABEL: Record<string, string> = {
  manual: "Manual",
  chat: "Chat",
  web: "Web",
  email: "Email",
  paper: "Paper",
  book: "Book",
  class: "Class",
  capture: "Capture",
};

export const SOURCE_KIND_COLOR: Record<string, string> = {
  manual: "oklch(0.74 0.05 280)",
  chat: "oklch(0.74 0.16 235)",
  web: "oklch(0.80 0.14 195)",
  email: "oklch(0.80 0.15 75)",
  paper: "oklch(0.74 0.16 305)",
  book: "oklch(0.76 0.15 145)",
  class: "oklch(0.74 0.15 0)",
  capture: "oklch(0.80 0.18 50)",
};

export function sourceLabel(kind: string): string {
  return SOURCE_KIND_LABEL[kind] ?? kind;
}

export function sourceColor(kind: string): string {
  return SOURCE_KIND_COLOR[kind] ?? SOURCE_KIND_COLOR.manual;
}
