// Rich inline cards for executed tool calls. Built as plain HTML
// strings so MarkdownContent's post-processor can swap a chip for a
// card with a single replaceWith — no Solid components in the
// rendered tree (innerHTML is set imperatively).
//
// Design language:
//   - Lean, no chrome-y title bars; an accent left-edge carries the
//     action color so the card reads as an annotation in flow rather
//     than a separate widget.
//   - list_events groups by day (one date header + multiple rows)
//     because a flat time-stamped list at week scale is hard to scan.
//   - Each calendar gets a stable color from a small palette (hashed
//     on its name) so "Work" is consistently one hue across messages.
//
// All cards use <span> as the outer element with `display: block`
// styling, because chips render inside markdown-it's wrapping <p>
// tags and a real <div> would force the browser to close the
// paragraph and break the text flow.

export type ToolResult = {
  index: number;
  action: string;
  headers: Record<string, unknown> | null;
  result: unknown;
};

function escapeHtml(s: string): string {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── time formatting ───────────────────────────────────────────────

function fmtTime(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  // "12:00 PM", "9:30 AM" — drop the leading zero on the hour.
  return d
    .toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
    .replace(/^0/, "");
}

function fmtDayHeader(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const today = new Date();
  const tomorrow = new Date(today);
  tomorrow.setDate(today.getDate() + 1);
  const sameDay = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate();

  const long = d.toLocaleDateString(undefined, {
    weekday: "long",
    month: "short",
    day: "numeric",
  });
  if (sameDay(d, today)) return `Today · ${long.split(",")[0]}`;
  if (sameDay(d, tomorrow)) return `Tomorrow · ${long.split(",")[0]}`;
  return long;
}

function fmtCompactDate(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const today = new Date();
  const tomorrow = new Date(today);
  tomorrow.setDate(today.getDate() + 1);
  const sameDay = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate();
  if (sameDay(d, today)) return "Today";
  if (sameDay(d, tomorrow)) return "Tomorrow";
  return d.toLocaleDateString(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
}

function dayKey(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

function isAllDay(start: string, end: string): boolean {
  // Heuristic: an event that starts at 7:00 AM and ends at 6:59 PM
  // (12-hour holiday-style block) or whose duration is >= 22h is
  // effectively an "all-day" marker — render without a time range.
  const s = new Date(start);
  const e = new Date(end);
  if (isNaN(s.getTime()) || isNaN(e.getTime())) return false;
  const hours = (e.getTime() - s.getTime()) / 3_600_000;
  if (hours >= 22) return true;
  if (hours >= 11 && hours <= 13 && s.getHours() === 7 && e.getHours() === 18) {
    return true;
  }
  return false;
}

// ── calendar color palette ────────────────────────────────────────
// Stable hash on calendar name → one of these hues. Picked to be
// distinguishable on the dark theme without competing with the
// accent orange.

const CAL_HUES: number[] = [
  210, // sky blue
  145, // green
  290, // purple
  35, // amber (close to accent — safe because we usually only show one)
  330, // pink
  175, // teal
  255, // indigo
  90, // chartreuse
];

function hashStr(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return Math.abs(h);
}

function calColor(name?: string): string {
  if (!name) return `oklch(0.62 0.04 280)`; // neutral
  const hue = CAL_HUES[hashStr(name) % CAL_HUES.length];
  return `oklch(0.72 0.13 ${hue})`;
}

// ── types ─────────────────────────────────────────────────────────

type Event = {
  id?: string;
  title: string;
  start: string;
  end: string;
  location?: string;
  calendar?: string;
};

type Reminder = {
  title: string;
  due: string | null;
  list?: string;
  completed?: boolean;
};

type MailSummary = {
  id: string;
  sender: string;
  subject: string;
  date_received: string;
  mailbox: string;
  snippet: string;
};

type RawMailSummary = Partial<MailSummary> & {
  thread_id?: string;
  account_id?: string;
  from_addr?: string;
  from_name?: string;
  unread?: boolean;
};

type MailThread = {
  id: string;
  sender: string;
  subject: string;
  date_received: string;
  mailbox: string;
  body: string;
};

type DirEntry = {
  name: string;
  path: string;
  kind: string;
  size: number | null;
};

type DirListing = {
  path: string;
  entries: DirEntry[];
};

type FileRead = {
  path: string;
  bytes: number;
  truncated: boolean;
  content: string;
};

type GraphNode = {
  id: unknown;
  kind: string;
  label: string;
  source_kind: string | null;
  updated_at: string | null;
};

type GraphEdge = {
  from_node: unknown;
  to_node: unknown;
  kind: string;
  context: string | null;
};

type GraphSlice = {
  nodes: GraphNode[];
  edges: GraphEdge[];
};

// ── builders ──────────────────────────────────────────────────────

function listEventsCard(
  headers: Record<string, unknown> | null,
  events: Event[],
): string {
  const from = String(headers?.from ?? "");
  const to = String(headers?.to ?? "");
  const range =
    from && to
      ? `${fmtCompactDate(from)} → ${fmtCompactDate(to)}`
      : from
        ? `from ${fmtCompactDate(from)}`
        : "this week";

  const count = events.length;
  if (count === 0) {
    return `
      <span class="tcard tcard--cal">
        <span class="tcard__edge"></span>
        <span class="tcard__inner">
          <span class="tcard__head">
            <span class="tcard__kind">Calendar · ${escapeHtml(range)}</span>
            <span class="tcard__count tcard__count--empty">nothing scheduled</span>
          </span>
        </span>
      </span>`;
  }

  // Group by day, in chronological order.
  const groups = new Map<string, { label: string; iso: string; events: Event[] }>();
  for (const e of events) {
    const k = dayKey(e.start);
    if (!groups.has(k)) {
      groups.set(k, { label: fmtDayHeader(e.start), iso: e.start, events: [] });
    }
    groups.get(k)!.events.push(e);
  }
  // Sort the groups by their day's first start time.
  const sortedGroups = [...groups.values()].sort(
    (a, b) => new Date(a.iso).getTime() - new Date(b.iso).getTime(),
  );

  const dayBlocks = sortedGroups
    .map((g) => {
      const rows = g.events
        .map((e) => {
          const cal = e.calendar ?? "";
          const allDay = isAllDay(e.start, e.end);
          const time = allDay
            ? `<span class="evt__time evt__time--all">all-day</span>`
            : `<span class="evt__time">${escapeHtml(fmtTime(e.start))}</span>`;
          const meta = [
            cal ? escapeHtml(cal) : "",
            e.location ? `📍 ${escapeHtml(e.location)}` : "",
          ]
            .filter(Boolean)
            .join("  ·  ");

          return `
            <span class="evt" title="${escapeHtml(cal || "")}">
              <span class="evt__dot" style="background:${calColor(cal)}"></span>
              ${time}
              <span class="evt__title">${escapeHtml(e.title || "(untitled)")}</span>
              ${meta ? `<span class="evt__meta">${meta}</span>` : ""}
            </span>`;
        })
        .join("");

      return `
        <span class="tcard__day">
          <span class="tcard__day-label">${escapeHtml(g.label)}</span>
          <span class="tcard__day-events">${rows}</span>
        </span>`;
    })
    .join("");

  return `
    <span class="tcard tcard--cal">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__head">
          <span class="tcard__kind">Calendar · ${escapeHtml(range)}</span>
          <span class="tcard__count">${count} event${count === 1 ? "" : "s"}</span>
        </span>
        <span class="tcard__body">
          ${dayBlocks}
        </span>
      </span>
    </span>`;
}

function createEventCard(headers: Record<string, unknown> | null): string {
  const title = String(headers?.title ?? "(untitled)");
  const start = String(headers?.start ?? "");
  const end = String(headers?.end ?? "");
  const cal = headers?.calendar ? String(headers.calendar) : "";
  const loc = headers?.location ? String(headers.location) : "";

  const allDay = isAllDay(start, end);
  const dateLine = fmtCompactDate(start);
  const timeLine = allDay ? "all-day" : `${fmtTime(start)} – ${fmtTime(end)}`;

  const metaPills: string[] = [];
  if (cal) {
    metaPills.push(
      `<span class="tcard__pill"><span class="tcard__pill-dot" style="background:${calColor(cal)}"></span>${escapeHtml(cal)}</span>`,
    );
  }
  if (loc) {
    metaPills.push(`<span class="tcard__pill">📍 ${escapeHtml(loc)}</span>`);
  }

  return `
    <span class="tcard tcard--cal tcard--detail">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">Added to Calendar</span>
        <span class="tcard__detail-title">${escapeHtml(title)}</span>
        <span class="tcard__detail-when">
          <span>${escapeHtml(dateLine)}</span>
          <span class="tcard__bullet">·</span>
          <span class="tcard__time-strong">${escapeHtml(timeLine)}</span>
        </span>
        ${metaPills.length ? `<span class="tcard__pills">${metaPills.join("")}</span>` : ""}
      </span>
    </span>`;
}

function deleteEventCard(
  headers: Record<string, unknown> | null,
  result: unknown,
): string {
  const ok = !!(result && typeof result === "object" && (result as any).ok);
  const title = headers?.title
    ? String(headers.title)
    : headers?.id
      ? String(headers.id)
      : "event";
  const on = headers?.on ? fmtCompactDate(String(headers.on)) : "";

  if (!ok) {
    const err =
      result && (result as any).error
        ? String((result as any).error)
        : "couldn't find the event";
    return `
      <span class="tcard tcard--err">
        <span class="tcard__edge"></span>
        <span class="tcard__inner">
          <span class="tcard__kind tcard__kind--mini">Couldn't remove</span>
          <span class="tcard__detail-title">${escapeHtml(title)}</span>
          <span class="tcard__err">${escapeHtml(err)}</span>
        </span>
      </span>`;
  }

  return `
    <span class="tcard tcard--del tcard--detail">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">Removed from Calendar</span>
        <span class="tcard__detail-title tcard__detail-title--strike">${escapeHtml(title)}</span>
        ${on ? `<span class="tcard__detail-when"><span>${escapeHtml(on)}</span></span>` : ""}
      </span>
    </span>`;
}

function listRemindersCard(
  headers: Record<string, unknown> | null,
  rems: Reminder[],
): string {
  const includeCompleted = !!headers?.include_completed;
  const count = rems.length;
  if (count === 0) {
    return `
      <span class="tcard tcard--rem">
        <span class="tcard__edge"></span>
        <span class="tcard__inner">
          <span class="tcard__head">
            <span class="tcard__kind">Reminders</span>
            <span class="tcard__count tcard__count--empty">${includeCompleted ? "nothing here" : "all caught up"}</span>
          </span>
        </span>
      </span>`;
  }

  // Group by list — that's how the user sees them in Reminders.app.
  const groups = new Map<string, Reminder[]>();
  for (const r of rems) {
    const k = r.list || "Other";
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k)!.push(r);
  }
  const blocks = [...groups.entries()]
    .map(([listName, items]) => {
      const rows = items
        .map((r) => {
          const due = r.due
            ? `<span class="rem__due">${escapeHtml(fmtCompactDate(r.due))} · ${escapeHtml(fmtTime(r.due))}</span>`
            : "";
          return `
            <span class="rem">
              <span class="rem__check">${r.completed ? "☑" : "○"}</span>
              <span class="rem__title ${r.completed ? "rem__title--done" : ""}">${escapeHtml(r.title || "(untitled)")}</span>
              ${due}
            </span>`;
        })
        .join("");
      return `
        <span class="tcard__day">
          <span class="tcard__day-label">
            <span class="tcard__pill-dot" style="background:${calColor(listName)}"></span>
            ${escapeHtml(listName)}
          </span>
          <span class="tcard__day-events">${rows}</span>
        </span>`;
    })
    .join("");

  return `
    <span class="tcard tcard--rem">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__head">
          <span class="tcard__kind">Reminders</span>
          <span class="tcard__count">${count}</span>
        </span>
        <span class="tcard__body">
          ${blocks}
        </span>
      </span>
    </span>`;
}

function createReminderCard(
  headers: Record<string, unknown> | null,
): string {
  const title = String(headers?.title ?? "(untitled)");
  const due = headers?.due ? String(headers.due) : "";
  const list = headers?.list ? String(headers.list) : "";

  const metaPills: string[] = [];
  if (due) {
    metaPills.push(
      `<span class="tcard__pill">⏰ ${escapeHtml(fmtCompactDate(due))} · ${escapeHtml(fmtTime(due))}</span>`,
    );
  }
  if (list) {
    metaPills.push(
      `<span class="tcard__pill"><span class="tcard__pill-dot" style="background:${calColor(list)}"></span>${escapeHtml(list)}</span>`,
    );
  }

  return `
    <span class="tcard tcard--rem tcard--detail">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">Reminder added</span>
        <span class="tcard__detail-title">${escapeHtml(title)}</span>
        ${metaPills.length ? `<span class="tcard__pills">${metaPills.join("")}</span>` : ""}
      </span>
    </span>`;
}

function listMailCard(
  headers: Record<string, unknown> | null,
  rows: MailSummary[],
): string {
  const limit = String(headers?.limit ?? (rows.length || 10));
  if (rows.length === 0) {
    return `
      <span class="tcard tcard--mail">
        <span class="tcard__edge"></span>
        <span class="tcard__inner">
          <span class="tcard__head">
            <span class="tcard__kind">Mail · recent inbox</span>
            <span class="tcard__count tcard__count--empty">no messages</span>
          </span>
        </span>
      </span>`;
  }

  const items = rows
    .slice(0, 10)
    .map((m) => {
      const meta = [m.sender, m.mailbox, m.date_received].filter(Boolean).join(" · ");
      return `
        <span class="mail">
          <span class="mail__id">#${escapeHtml(m.id)}</span>
          <span class="mail__subject">${escapeHtml(m.subject || "(no subject)")}</span>
          <span class="mail__meta">${escapeHtml(meta)}</span>
          <span class="mail__snippet">${escapeHtml(m.snippet || "")}</span>
        </span>`;
    })
    .join("");

  return `
    <span class="tcard tcard--mail">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__head">
          <span class="tcard__kind">Mail · recent inbox</span>
          <span class="tcard__count">${rows.length}/${escapeHtml(limit)}</span>
        </span>
        <span class="tcard__body">${items}</span>
      </span>
    </span>`;
}

function normalizeMailRows(rows: unknown[]): MailSummary[] {
  return rows
    .filter((row): row is RawMailSummary => !!row && typeof row === "object")
    .map((m) => {
      const fromName = String(m.from_name ?? "").trim();
      const fromAddr = String(m.from_addr ?? "").trim();
      const sender =
        m.sender ??
        (fromName && fromAddr
          ? `${fromName} <${fromAddr}>`
          : fromName || fromAddr || "");
      return {
        id: String(m.id ?? m.thread_id ?? ""),
        sender: String(sender),
        subject: String(m.subject ?? ""),
        date_received: String(m.date_received ?? ""),
        mailbox: String(m.mailbox ?? (m.account_id ? `account ${m.account_id}` : "")),
        snippet: String(m.snippet ?? ""),
      };
    });
}

function readThreadCard(thread: MailThread): string {
  const meta = [thread.sender, thread.mailbox, thread.date_received]
    .filter(Boolean)
    .join(" · ");
  const body = (thread.body || "").replace(/\s+/g, " ").trim();
  const snippet = body.length > 360 ? `${body.slice(0, 360)}…` : body;
  return `
    <span class="tcard tcard--mail tcard--detail">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">Mail thread</span>
        <span class="tcard__detail-title">${escapeHtml(thread.subject || "(no subject)")}</span>
        <span class="mail__meta">${escapeHtml(meta)}</span>
        <span class="mail__snippet">${escapeHtml(snippet)}</span>
      </span>
    </span>`;
}

function formatBytes(n: number | null | undefined): string {
  if (n === null || n === undefined) return "";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function listDirCard(listing: DirListing): string {
  const entries = listing.entries || [];
  const rows = entries
    .slice(0, 20)
    .map((e) => {
      const glyph = e.kind === "dir" ? "▸" : e.kind === "file" ? "·" : "◇";
      const size = e.kind === "file" ? formatBytes(e.size) : e.kind;
      return `
        <span class="file-row">
          <span class="file-row__glyph">${escapeHtml(glyph)}</span>
          <span class="file-row__name">${escapeHtml(e.name)}</span>
          <span class="file-row__meta">${escapeHtml(size)}</span>
        </span>`;
    })
    .join("");
  return `
    <span class="tcard tcard--file">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__head">
          <span class="tcard__kind">Files · ${escapeHtml(listing.path)}</span>
          <span class="tcard__count">${entries.length}</span>
        </span>
        <span class="tcard__body">${rows}</span>
      </span>
    </span>`;
}

function readFileCard(file: FileRead): string {
  const content = (file.content || "").replace(/\s+/g, " ").trim();
  const snippet = content.length > 420 ? `${content.slice(0, 420)}…` : content;
  return `
    <span class="tcard tcard--file tcard--detail">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">File read</span>
        <span class="tcard__detail-title">${escapeHtml(file.path)}</span>
        <span class="file-row__meta">${escapeHtml(formatBytes(file.bytes))}${file.truncated ? " · truncated" : ""}</span>
        <span class="file-snippet">${escapeHtml(snippet)}</span>
      </span>
    </span>`;
}

// Map node kind → small unicode glyph. The vault is notes-only today
// but the layer is shaped so future kinds (email_thread, event,
// project, terminal_session) slot in here without touching the row
// renderer.
const KIND_GLYPH: Record<string, string> = {
  note: "✎",
  email_thread: "✉",
  event: "◆",
  file_ref: "▤",
  terminal_session: "›_",
  project: "◇",
  chat: "◌",
  agent: "◉",
};

function graphResultCard(
  kind: "search" | "neighbors",
  headers: Record<string, unknown> | null,
  slice: GraphSlice,
): string {
  const label = (() => {
    if (kind === "search") {
      const q = headers?.query ? String(headers.query) : "(unspecified)";
      return `Graph · "${q}"`;
    }
    const t = headers?.title ? String(headers.title) : "(node)";
    return `Graph · neighbors of "${t}"`;
  })();

  const nodes = slice.nodes ?? [];
  const edges = slice.edges ?? [];
  const focus = kind === "neighbors" && headers?.title ? String(headers.title) : "";

  if (nodes.length === 0) {
    return `
      <span class="tcard tcard--graph">
        <span class="tcard__edge"></span>
        <span class="tcard__inner">
          <span class="tcard__head">
            <span class="tcard__kind">${escapeHtml(label)}</span>
            <span class="tcard__count tcard__count--empty">no matches</span>
          </span>
        </span>
      </span>`;
  }

  // Hide the focused node in the row list (already implicit in the
  // header label) so the body shows only the connected set.
  const rowNodes = focus
    ? nodes.filter((n) => n.label !== focus)
    : nodes.slice(0, 14);
  const overflow = nodes.length - rowNodes.length - (focus ? 1 : 0);

  const rows = rowNodes
    .slice(0, 14)
    .map((n) => {
      const glyph = KIND_GLYPH[n.kind] ?? "·";
      const meta = [
        n.kind === "note" ? null : escapeHtml(n.kind),
        n.source_kind && n.source_kind !== "manual" ? escapeHtml(n.source_kind) : null,
      ]
        .filter(Boolean)
        .join(" · ");
      // [[wikilink]] chip lets the user cmd-click into the inspector
      // without retyping the title — same interaction MarkdownContent
      // wires up for any wikilink in agent prose.
      return `
        <span class="graph-row">
          <span class="graph-row__glyph">${escapeHtml(glyph)}</span>
          <span class="graph-row__title">${escapeHtml(n.label)}</span>
          ${meta ? `<span class="graph-row__meta">${meta}</span>` : ""}
          <span class="wikilink-chip" data-wikilink="${escapeHtml(n.label)}">[[${escapeHtml(n.label)}]]</span>
        </span>`;
    })
    .join("");

  const edgeBadge =
    edges.length > 0
      ? `<span class="tcard__count">${nodes.length} node${nodes.length === 1 ? "" : "s"} · ${edges.length} edge${edges.length === 1 ? "" : "s"}</span>`
      : `<span class="tcard__count">${nodes.length} node${nodes.length === 1 ? "" : "s"}</span>`;

  return `
    <span class="tcard tcard--graph">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__head">
          <span class="tcard__kind">${escapeHtml(label)}</span>
          ${edgeBadge}
        </span>
        <span class="tcard__body">
          ${rows}
          ${overflow > 0 ? `<span class="graph-row graph-row--more">+ ${overflow} more</span>` : ""}
        </span>
      </span>
    </span>`;
}

/**
 * Build a rich card HTML string for one tool result, or return null if
 * we don't have a richer rendering than the chip already provides
 * (e.g. vault writes, link_notes — those keep their inline chip).
 */
export function buildCardHtml(tr: ToolResult): string | null {
  const r = tr.result;
  // Capability-denied path takes precedence over per-action handling
  // — we want the same "Permission denied" card regardless of action.
  if (r && typeof r === "object" && (r as any).denied) {
    return deniedCard(
      String((r as any).action || tr.action),
      String((r as any).capability || ""),
    );
  }
  switch (tr.action) {
    case "list_events":
      if (Array.isArray(r)) return listEventsCard(tr.headers, r as Event[]);
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Calendar", String((r as any).error));
      }
      return null;
    case "create_event":
      return createEventCard(tr.headers);
    case "delete_event":
      return deleteEventCard(tr.headers, r);
    case "list_reminders":
      if (Array.isArray(r)) return listRemindersCard(tr.headers, r as Reminder[]);
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Reminders", String((r as any).error));
      }
      return null;
    case "create_reminder":
      return createReminderCard(tr.headers);
    case "list_recent_mail":
    case "list_mail":
    case "search_mail":
      if (Array.isArray(r)) return listMailCard(tr.headers, normalizeMailRows(r));
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Mail", String((r as any).error));
      }
      return null;
    case "read_thread":
      if (r && typeof r === "object" && (r as any).body !== undefined) {
        return readThreadCard(r as MailThread);
      }
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Mail", String((r as any).error));
      }
      return null;
    case "list_dir":
      if (r && typeof r === "object" && Array.isArray((r as any).entries)) {
        return listDirCard(r as DirListing);
      }
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Files", String((r as any).error));
      }
      return null;
    case "read_file":
      if (r && typeof r === "object" && (r as any).content !== undefined) {
        return readFileCard(r as FileRead);
      }
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Files", String((r as any).error));
      }
      return null;
    case "graph_search":
      if (r && typeof r === "object" && Array.isArray((r as any).nodes)) {
        return graphResultCard("search", tr.headers, r as GraphSlice);
      }
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Graph", String((r as any).error));
      }
      return null;
    case "graph_neighbors":
      if (r && typeof r === "object" && Array.isArray((r as any).nodes)) {
        return graphResultCard("neighbors", tr.headers, r as GraphSlice);
      }
      if (r && typeof r === "object" && (r as any).error) {
        return errorCard("Graph", String((r as any).error));
      }
      return null;
    default:
      return null;
  }
}

// Pretty labels for the capability lookup so the user-facing card
// reads as English rather than dotted keys.
const CAP_LABELS: Record<string, string> = {
  "calendar.read": "Calendar (read)",
  "calendar.write": "Calendar (write)",
  "reminders.read": "Reminders (read)",
  "reminders.write": "Reminders (write)",
  "email.read": "Email (read)",
  "filesystem.read": "Filesystem (read)",
};

function deniedCard(action: string, capability: string): string {
  const capLabel = CAP_LABELS[capability] || capability || "this capability";
  return `
    <span class="tcard tcard--denied">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">Permission denied</span>
        <span class="tcard__detail-title">No access to ${escapeHtml(capLabel)}</span>
        <span class="tcard__denied-msg">
          This agent tried <code>${escapeHtml(action)}</code> but doesn't have the
          required capability. Open Manage agents and grant
          <strong>${escapeHtml(capLabel)}</strong>, or ask an agent that already
          has it.
        </span>
      </span>
    </span>`;
}

function errorCard(kind: string, msg: string): string {
  return `
    <span class="tcard tcard--err">
      <span class="tcard__edge"></span>
      <span class="tcard__inner">
        <span class="tcard__kind tcard__kind--mini">${escapeHtml(kind)} unavailable</span>
        <span class="tcard__err">${escapeHtml(msg)}</span>
      </span>
    </span>`;
}
