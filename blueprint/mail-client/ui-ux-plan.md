# Mail Client — UI / UX Design Plan

> Companion to `plan-mail-client.md` (the system-architecture plan). This
> document covers everything *visible* — color, typography, spacing, layout,
> motion, rendering of HTML emails, interaction patterns, and an
> implementation roadmap that sequences the redesign work safely against
> the working Phase 4 baseline.

---

## 1. Vision

Mail in Clome should feel **native, calm, and dense — but never cramped**.
Three guiding principles, in priority order:

1. **One visual language across surfaces.** Mail must look like the chat
   pane, the notes vault, the inspector, the search palette — the same
   typeface, the same hairline borders, the same soft-3D buttons, the
   same hover micromotion. The current MailApp.tsx uses raw Tailwind
   zinc-* utilities and Tailwind `shadow-lg`; the rest of the app uses
   OKLCH design tokens (`--color-*`) and a custom soft-3D shadow recipe.
   This mismatch is the single biggest UX bug today.
2. **Reading is the primary verb.** A user spends 90% of mail time reading
   and 10% writing. The reading pane gets the cleanest typography, the
   most space, the most thoughtful image-handling, the best quoted-text
   collapsing. Compose is important but secondary in pixels-per-pixel.
3. **HTML email is the enemy and the deliverable.** Most emails are
   marketing HTML built by templating engines we don't control. The
   reading pane has to make that mess legible without:
   * leaking the user's network identity to trackers,
   * letting hostile CSS bleed into Clome's chrome,
   * making real conversational mail (plain text replies, threaded
     discussions) feel like an afterthought.

A user should be able to reach for keyboard alone — `j`/`k` to navigate,
`r` to reply, `e` to archive, `#` to delete, `/` to search, `c` to
compose, `⌘Enter` to send. This is the Gmail / Mutt / Superhuman / Apple
Mail "power-user" baseline that even casual users feel as "snappy".

---

## 2. Design language adoption

The audit identified **a single root cause** for nearly every UI
inconsistency: MailApp.tsx renders against the Tailwind `zinc-*`
palette and Tailwind shadow utilities, while the rest of the app
renders against OKLCH CSS custom properties and a custom soft-3D
shadow recipe. Fix that root cause and 80% of the visual mismatch
evaporates.

### 2.1 Color token swap table

| Where | Current (Tailwind) | Target (Clome token) |
|------|---------------------|----------------------|
| App background | `bg-zinc-50 dark:bg-zinc-950` | `background: var(--color-bg)` |
| Pane / sidebar background | `bg-white dark:bg-zinc-900` | `background: var(--color-bg-panel)` |
| Raised surface (modals, toolbars) | `bg-white shadow-lg` | `background: var(--color-bg-elev)` + soft-3D shadow recipe |
| Input surface | `bg-transparent` | `background: var(--color-bg-input)` (`.input-pill`) |
| Hover row | `hover:bg-zinc-50 dark:hover:bg-zinc-800/50` | `background: var(--color-bg-hover)` |
| Selected row | `bg-zinc-100 dark:bg-zinc-800` | `background: var(--surface-selected)` (`.list-row--active`) |
| Hairline border | `border-zinc-200 dark:border-zinc-800` | `border-color: var(--color-border)` (or `--surface-hairline` for paler dividers) |
| Strong border | `border-zinc-300 dark:border-zinc-700` | `border-color: var(--color-border-strong)` |
| Primary text | `text-zinc-900 dark:text-zinc-100` | `color: var(--color-text)` |
| Secondary text | `text-zinc-600 dark:text-zinc-400` | `color: var(--color-text-muted)` |
| Tertiary text | `text-zinc-500` | `color: var(--color-text-dim)` |
| Quaternary text (timestamps, hints) | `text-zinc-400` | `color: var(--color-text-subtle)` |
| Accent (selected unified inbox, link, focus ring tint) | hardcoded blue | `var(--color-accent)` |
| Success (sent confirmation, sync done badge) | `text-green-500` | `var(--color-good)` |
| Warning (remote-image banner) | `bg-amber-50 text-amber-800` | derived from `var(--color-warn)` |
| Danger (delete buttons, error banner) | `text-red-500` | `var(--color-danger)` |

### 2.2 Soft-3D button recipe (replaces Tailwind shadows)

Every interactive button — toolbar, sidebar, modal footer, sync ↻,
compose FAB — adopts `.btn-soft` (or its variants `--icon`, `--icon-sm`,
`--primary`, `--ghost`, `--danger`). Recipe (already in App.css):

* Base: `1px solid var(--color-border-strong)`, `border-radius: 999px`
  (or `0.6rem` for square pills)
* Background: `var(--color-bg-elev)` with inset highlight + shade
* Drop shadow: layered (`var(--raised-drop)` for resting, escalates on
  hover)
* Hover: `transform: translateY(-1px)`, `box-shadow` with
  `var(--raised-drop-strong)` — the button "lifts"
* Active: `transform: translateY(+1px)`, deeper inset
  `var(--raised-press-shade)` — the button "presses"
* Disabled: `opacity: 0.55`, no transform, no transition

Mapping current Mail buttons to variants:

| Element | Variant |
|---------|---------|
| Compose floating button | `.fab-soft` (uses `backdrop-filter: blur(8px)`) |
| Reply / Reply-All / Forward / Archive / Delete (toolbar) | `.btn-soft--icon-sm` |
| Send (composer footer) | `.btn-soft--primary` |
| Discard (composer footer) | `.btn-soft--ghost` |
| Add account (`+`) | `.btn-soft--icon-sm` |
| Sync (↻) | `.btn-soft--icon-sm` |
| Remove account (✕) | `.btn-soft--icon-sm` (with hover `--danger` color shift) |
| Search toggle | `.btn-soft--icon-sm` |
| "Load 100 older" | `.btn-soft--ghost` (full-width variant) |
| RSVP Accept/Decline/Tentative | `.btn-soft--sm` (`--primary` for Accept) |
| "Always load images from sender" | `.btn-soft--sm` |

### 2.3 Typography scale (mail-specific)

| Element | Size | Weight | Color token |
|---------|------|--------|-------------|
| Section header (e.g. "INBOX", "SENT") | `10.5px` | `650` | `--color-text-subtle` |
| Sidebar account email | `12.5px` | `500` | `--color-text-muted` (active: `--color-text`) |
| Sidebar account email — current | `12.5px` | `550` | `--color-text` |
| Sidebar folder name | `12.5px` | `500` | `--color-text-muted` |
| Folder unread badge | `10px` | `600` | `--color-text` on `var(--color-bg-input)` |
| Message-list sender (read) | `12.5px` | `400` | `--color-text-muted` |
| Message-list sender (unread) | `12.5px` | `600` | `--color-text` |
| Message-list subject (read) | `13px` | `400` | `--color-text-muted` |
| Message-list subject (unread) | `13px` | `540` | `--color-text` |
| Message-list snippet | `11.5px` | `400` | `--color-text-dim` (italic optional) |
| Message-list timestamp | `10.5px` | `500` | `--color-text-subtle` |
| Reading pane subject | `1.05rem` (≈16.8px) | `650` | `--color-text` |
| Reading pane meta (from / date / to) | `11.5px` | `400` | `--color-text-dim` |
| Reading pane body (HTML iframe) | inherits user CSS, target `15px` `1.55` line-height when overrideable | — | — |
| Reading pane body (plain fallback) | `14px` | `400` | `--color-text` |
| Toolbar tooltip / shortcut hint | `10.5px` | `500` | `--color-text-subtle` |
| Composer input labels (To, Cc, Subject) | `10.5px` `uppercase 0.04em letter-spacing` | `650` | `--color-text-subtle` |
| Composer input value | `13px` | `400` | `--color-text` |
| Composer body | `14px` | `400` | `--color-text`, `var(--font-mono)` toggle |

Font families always come from CSS tokens — `var(--font-sans)` for chrome
and prose, `var(--font-mono)` for the composer's optional monospace
toggle and any code in messages.

### 2.4 Spacing rhythm

The app's vertical rhythm is built on multiples of `0.12rem` (≈ 2px) for
tight elements and `0.85em` for content blocks. Mail-specific anchors:

| Element | Padding | Min height |
|---------|---------|------------|
| Sidebar header | `0.5rem 0.75rem` | `2.4rem` |
| Sidebar account row | `0.5rem 0.75rem` | `2.4rem` |
| Sidebar folder row (indented) | `0.42rem 0.75rem 0.42rem 1.6rem` | `2.05rem` |
| Message-list header | `0.5rem 0.75rem` | `2.4rem` |
| Message-list row | `0.65rem 0.75rem` | `4.4rem` (3 lines: sender · subject · snippet) |
| Reading pane header | `1.1rem 1.3rem 0.9rem` | `auto` |
| Reading pane toolbar | `0.4rem 1.3rem` | `2.4rem` |
| Composer modal | `1rem 1.3rem` (content) | header `2.4rem`, footer `3rem` |

Hairline borders are always 1px. Use `--color-border` for surface
separation, `--surface-hairline` (paler) for intra-list dividers between
message rows.

---

## 3. Layout architecture

### 3.1 Resting layout: 3-pane

```
┌──────────┬──────────────┬──────────────────────────────┐
│ Sidebar  │ Message list │  Reading pane                │
│          │              │                              │
│ 14rem    │  22rem       │  flex: 1                     │
│ (224 px) │  (352 px)    │                              │
│          │              │                              │
│ accounts │  list rows   │  toolbar                     │
│ + folders│              │  ─────────                   │
│          │              │  subject                     │
│          │              │  meta                        │
│          │              │  ─────────                   │
│          │              │  iframe (HTML)               │
│          │              │  + attachments footer        │
└──────────┴──────────────┴──────────────────────────────┘
```

* Match the app's existing pane widths (notes sidebar uses ~14 rem; chat
  composer pinned to a similar rhythm). Defining widths in `rem` rather
  than Tailwind `w-64` / `w-96` makes them respect the user's system
  font-size scaling.
* Both gutters between panes are `1px` solid `var(--color-border)`.
* Both gutters are draggable: cursor changes to `col-resize`,
  ±3px hit area, persists per-account in localStorage. The inspector
  pane's drag handle (App.tsx lines 2742–2753) is the canonical
  implementation.

### 3.2 2-pane mode (⌘\\)

Toggle hides the sidebar; folder switching moves to a header pulldown
in the message list. Useful on small screens or when the user wants
the message list wider. Persisted per-workspace.

```
┌───────────────────┬──────────────────────────────────────┐
│ Message list      │  Reading pane                        │
│ + folder selector │                                      │
│                   │                                      │
└───────────────────┴──────────────────────────────────────┘
```

### 3.3 Wide reading mode (⌘⇧\\)

Hides sidebar AND message list when reading a single message:

```
┌─────────────────────────────────────────────────────────┐
│  Reading pane (full width, max-width: 70rem centered)   │
└─────────────────────────────────────────────────────────┘
```

Pressing the same shortcut, Esc, or clicking the back-arrow returns to
3-pane. Useful for newsletters, long-form reads, calendar invites.

### 3.4 Conversation rendering — Gmail-stack inside reading pane

Reading-pane shows the entire thread, not a single message. Top-most is
oldest collapsed; expanded is the message the user clicked. Each
collapsed entry is a single row showing sender · snippet · date. Click
to expand. Latest message expanded by default.

Visual rhythm:

```
─── thread subject + thread meta ──────────────────
[oldest message — collapsed row]
[next — collapsed row]
[next — collapsed row, with author "you" badge]
─── most recent ───────────────────────────────────
[expanded message]
  toolbar: reply / reply-all / forward / star / …
  meta: from · date · to · cc
  body (iframe)
  attachments footer
```

Collapsed row is the same height as a message-list row (4.4rem) so the
visual rhythm aligns. Expanding animates `0.18s` ease-out — height +
opacity. Collapse re-uses `0.12s` ease.

### 3.5 Responsive breakpoints

Match the existing App.css media queries (lines 2736–2856):

* `>1280px`: full 3-pane, default widths
* `980–1280px`: sidebar 12.5rem, message list 20rem
* `760–980px`: 2-pane forced, sidebar collapses to icon strip (3rem) with
  flyout on hover
* `<760px`: single-pane stack (sidebar overlays as a sheet, message list
  and reading pane swap based on selection)

### 3.6 Density modes

Three densities, settable in Settings, persisted per account:

| Mode | Row min-height | Padding | Snippet visible |
|------|----------------|---------|-----------------|
| **Cozy** (default) | 4.4 rem | `0.65 rem` v | 1 line |
| **Comfortable** | 5.4 rem | `0.85 rem` v | 2 lines |
| **Compact** | 3.2 rem | `0.4 rem` v | 0 lines (sender · subject only) |

These match Gmail's three densities. Apple Mail and Mimestream offer
similar tiers. Default to Cozy because most users skim subjects, not
snippets.

---

## 4. Sidebar component spec

```
┌──────────────────────────────────────┐
│  MAIL                            +   │  header — section-label + add-account
│                                      │
│  ╔══════════════════════════════════╗│  (accent left-border + filled bg
│  ║  ⊞  Unified Inbox        12     ║│   when active)
│  ╚══════════════════════════════════╝│
│                                      │
│  rany@gmail.com         ⟳  ✕         │  account header row
│    📥 Inbox                12        │
│    📤 Sent Mail                      │
│    📝 Drafts                  3      │
│    📦 Archive                        │
│    🗑  Trash                         │
│    ⚠  Spam                           │
│    ▶  Other folders                  │  expand to show non-special folders
│                                      │
│  rany@stanford.edu      ⟳  ✕         │
│    📥 Inbox                  4       │
│    …                                 │
│                                      │
└──────────────────────────────────────┘
```

### 4.1 Specs

* **Header bar** — `.section-label` with the word "MAIL" left-aligned,
  add-account `+` button on the right. Matches the chat / notes sidebar
  headers in App.tsx.
* **Unified Inbox** — top entry, only visible when `accounts.length >= 2`.
  When active, gets a 2px left border in `var(--color-accent)` (mirroring
  the workspace-tab active-drag indicator) plus filled
  `var(--surface-selected)` background.
* **Account row** — same height/padding as folder rows. Right side:
  a syncing spinner (`Loader2` 11px when `syncing[id]`), then ↻, then ✕.
  Both icon buttons are `.btn-soft--icon-sm` and ONLY appear on row
  hover (matches `.note-row` action-row pattern).
* **Folder row** — indented `1.6rem` (lines 4.1, 4.2 above), special-use
  icon (Inbox / Send / FileText / Archive / Trash2 / AlertTriangle) at
  size 12, name center, unread count right (only when > 0).
* **Other folders** disclosure — collapses non-special folders by
  default. Click the ▶ to expand; persists per account.
* **Active row** uses `.list-row--active`: `var(--surface-selected)`
  background + 2px accent left border + `var(--color-text)` color.
* **Hover row** uses `.list-row` hover: `var(--color-bg-hover)`,
  `var(--color-text)` color, no border change.
* **Drop target** — drag a message from the list onto a folder row to
  move it. Folder row gets `var(--color-bg-hover-strong)` while the
  message hovers. (Phase 5 polish — not v1.)

### 4.2 Container

Replace the outer `<button>` (which causes the nested-button HTML
malformed warning) with `<div role="button" tabindex="0">` driven by
keyboard handlers (Enter/Space → select; ArrowDown/ArrowUp → navigate
across rows). Same fix already applied for the account row; extend to
folder rows so the entire sidebar is keyboard-traversable.

---

## 5. Message list component spec

```
┌──────────────────────────────────────────────────┐
│  INBOX · 247 messages              ⌘F  🔍        │  header
│ ─────────────────────────────────────────────── │
│  Stanford FCU                              2:14p │  unread row (bold)
│  ⭐  Welcome to your new website                  │
│       Thanks for signing up — here's how to…    │
│ ─────────────────────────────────────────────── │
│  Uber Eats                                10:42a │  read row (regular)
│      Your order has arrived                     │
│      📎 Bobaholic invoice                        │
│ ─────────────────────────────────────────────── │
│  …                                               │
│                                                  │
│  ▼  Load 100 older                               │  pagination row
└──────────────────────────────────────────────────┘
```

### 5.1 Row anatomy (Cozy default)

```
┌────────────────────────────────────────────────┐
│ Sender Name (or address)               12:34p  │  line 1 (12.5px)
│ ⭐ Subject                                      │  line 2 (13px)
│    Snippet of body, italic, dim, single line   │  line 3 (11.5px italic dim)
└────────────────────────────────────────────────┘
```

* **Unread**: sender + subject in `var(--color-text)`, weight 600 / 540.
  Plus a 4px wide × 4px round dot in `var(--color-accent)` flush to the
  left edge (vertical center). Reads as "yes I have new mail".
* **Read**: sender in `var(--color-text-muted)` weight 400; subject in
  `var(--color-text-muted)` weight 400. No dot.
* **Selected (in 3-pane)**: full-row `var(--surface-selected)`
  background + 2px left border in `var(--color-accent)` + body text
  bumps to `var(--color-text)`. Snippet still dim.
* **Hover (not selected)**: `var(--color-bg-hover)` background, no
  border change.
* **Star**: Lucide `Star` filled in `var(--color-warn)` (yellow), 11px,
  inline before subject. Unstarred = no icon (don't show outlined star
  to avoid noise — Spark / Apple Mail do this).
* **Attachment indicator**: 11px paperclip icon at the start of the
  snippet line. Only when `has_attachments`.
* **Snippet**: italic, 11.5px, single line. In Compact mode hidden
  entirely.

### 5.2 Date formatting (existing logic is correct)

* Today → `2:14p` (lowercase a/p, no minute zero-pad for hour)
* Yesterday → `Yesterday`
* This week → `Mon`, `Tue`, …
* This year → `Apr 12`
* Older → `Apr 12, 2024`

(Apple Mail / Spark convention.)

### 5.3 Header

* Title: current folder or "Search: foo" or "Unified Inbox"
* Count: total messages (right-justified in muted color)
* Actions: search toggle (⌘F hint in tooltip)
* When search is active, the header collapses into the search input
  pill (already implemented; just re-skin to `.input-pill`).

### 5.4 Empty state

`.empty-state` class (centered, 12.5px subtle):

* Folder never synced → "No messages. Click a folder to fetch." (with a
  ↻ button below)
* Folder synced + truly empty → "Nothing here." (smaller, single line)
* Search returned nothing → "No matches for `<query>`."

Each empty state has an SVG illustration (40×40, `var(--color-text-subtle)`)
above the text. Examples: empty inbox = Inbox icon; no search results =
Search icon.

### 5.5 Virtualization

Once a folder has > 500 cached messages, the list virtualizes. Use a
windowed list (just inline the math; ~30 lines of JS) — no library
needed. Renders only ~25 visible rows + 5 above + 5 below. Smooth on
50k-message Inbox (Apple Mail benchmark).

### 5.6 Multi-select (Phase 5)

Hold ⇧ to range-select, ⌘ to toggle individual rows. Toolbar above the
list appears with bulk actions (archive, delete, mark-read). Out of
v1 scope — but plan the row anatomy now to support it (a 14px
checkbox slot at the left edge that fades in when ⇧ is held).

---

## 6. Reading pane component spec

```
┌──────────────────────────────────────────────────────────┐
│  ⤺ Reply  ↩ Reply All  ↪ Forward  │ ⭐ ✉ 📦 🗑          │  toolbar (sticky)
│ ──────────────────────────────────────────────────────── │
│                                                          │
│  Welcome to your new website                             │  subject (1.05rem 650)
│                                                          │
│  Stanford FCU  ⟨offers@sfcu.org⟩    Today, 2:14 PM       │  meta (11.5px)
│  to: rany@gmail.com                                      │
│  ▼ Show details                                          │  collapsible (cc/bcc)
│                                                          │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                          │
│  ⚠  Remote images blocked. Trackers can fingerprint     │  remote-img banner
│     you. [Always load from offers@sfcu.org]              │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │  HTML iframe content — full-bleed inside the box   │ │
│  │                                                    │ │
│  │  [sandbox allow-same-origin only;                  │ │
│  │   CSP injected as <meta http-equiv>]               │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ▼  Show 3 quoted lines                                  │  quote collapser
│                                                          │
│ ──────────────────────────────────────────────────────── │
│  📎 2 attachments                                        │
│  [invoice.pdf · 124 KB] [logo.png · 8 KB]                │
└──────────────────────────────────────────────────────────┘
```

### 6.1 Toolbar

* **Sticky** — pinned to the top of the reading pane via
  `position: sticky; top: 0`, background `var(--color-bg)`, hairline
  bottom border. Stays visible while the body scrolls under.
* **Buttons** are `.btn-soft--icon-sm` (1.85rem square). Group with
  vertical hairlines: Reply / Reply-All / Forward · Star / Mark-Read /
  Archive / Delete · Snooze (Phase 5).
* **Tooltips** include keyboard shortcuts: `Reply (R)`, `Archive (E)`,
  `Delete (#)`, etc.
* **Active state** for toggles (Star, Mark unread): button background
  shifts to `var(--surface-selected)` and icon fills.

### 6.2 Subject + meta block

* **Subject**: `1.05rem` (≈16.8px) at weight 650, `var(--color-text)`,
  letter-spacing tightened slightly (`-0.005em`).
* **Sender row**: name in `var(--color-text)` regular weight; address
  in `<…>` form, `var(--color-text-dim)`, slightly smaller.
* **Date**: right-aligned, full timestamp ("Today, 2:14 PM" or
  "Apr 12, 2026 at 2:14 PM"), `var(--color-text-subtle)`.
* **To**: single line, truncate with ellipsis. ▼ disclosure to expand
  Cc / Bcc / full address details.
* **Recipient list expansion** opens an inline panel (no modal) showing
  full To/Cc/Bcc lists, each entry an `.input-pill`-styled chip.

### 6.3 Body — the HTML iframe

This is the highest-stakes part of the entire UI.

#### 6.3.1 Sandbox model

* `<iframe sandbox="allow-same-origin">` — no `allow-scripts`, no
  `allow-forms`, no `allow-popups`, no `allow-top-navigation`. Same
  permissive level Apple Mail uses.
* CSP injected as `<meta http-equiv="Content-Security-Policy">` inside
  the sanitized HTML — `default-src 'none'; img-src data: cid:;
  style-src 'unsafe-inline'; font-src data:; form-action 'none';
  base-uri 'none';`. With `allow_remote_images = true`, `img-src`
  expands to `data: cid: https:`.
* The iframe is rendered with `srcdoc=`, never `src=` to a URL.
* `frame-ancestors` is omitted from the meta — that directive only
  works as an HTTP header. Browsers correctly ignore it in `<meta>` and
  only emit a console warning, but we don't need the noise.

#### 6.3.2 Sizing & scroll

* **Width**: iframe is `width: 100%` of the reading pane (which can be
  up to ~70rem in wide mode, ~40–55rem in 3-pane).
* **Height**: dynamic. After load, the iframe's `contentDocument.body.scrollHeight`
  is read once on `load` event and again on a `ResizeObserver` watching
  the body. iframe height set to that value. The OUTER reading pane
  scrolls the document; the iframe never scrolls internally.
  * Reason: a scrollable iframe inside a scrollable pane is a usability
    disaster (scroll-event capture fights, mouse wheel jumps, the
    Apple Mail "stuck inside a sub-frame" bug).
* **Width sanity**: Some marketing emails declare `width="800"` on
  tables; they overflow the pane and force horizontal scroll. We
  inject `<style>html, body { max-width: 100% !important; word-break:
  break-word; } table { max-width: 100% !important; } img { max-width:
  100% !important; height: auto !important; }</style>` into the
  sanitized HTML head as a defensive layer. (Doesn't fix every
  pathological email but stops 95% of horizontal scroll cases.)

#### 6.3.3 Theming the iframe content

The HTML inside the iframe ignores Clome's theme by default — the
sender's CSS wins. Two approaches:

1. **Don't theme** (default). The email looks as the sender intended;
   may be black-on-white in dark mode. This is what Gmail / Apple
   Mail do.
2. **Force-light**: when the document specifies no `color` /
   `background` in its top-level style, inject a light-themed stylesheet
   so the body becomes `var(--color-bg)` + `var(--color-text)`. Hard to
   detect reliably; better to leave alone.

**v1: don't theme.** Document is what the sender sent. Phase 5 polish
adds a "Force light" toggle in Settings.

#### 6.3.4 Plain-text fallback

When `body_html` is `None`, render `body_text` inside the iframe wrapped
in `<pre style="white-space: pre-wrap; font-family: var(--font-sans);
font-size: 14px; line-height: 1.55; color: …; background: …">`. This
gives plain-text replies a clean, properly-themed presentation that
matches the rest of Clome.

When BOTH are present, prefer HTML (current behavior).

#### 6.3.5 Link rewriter

Every `<a href="…">` in the sanitized output gets `data-real-href="…"`
copied from `href`, and `target="_blank"`. Hovering shows the real
target URL via a small tooltip overlay rendered above the iframe (not
inside it — we can't run JS in there). Clicking opens via
`tauri-plugin-opener`.

Implementation: the tooltip is a Solid component listening to
`onMouseMove` on the iframe wrapper; we use the iframe's
`contentDocument` (allowed by `allow-same-origin`) to walk the DOM and
find the `<a>` under the mouse position. Tooltip pill: `.btn-soft--sm`
shape, `position: absolute`, follows cursor with a 12px offset.

#### 6.3.6 Image policy & remote-image banner

Default state for any sender NOT in `remote_image_allow`:

```
┌────────────────────────────────────────────────────┐
│ 🚫  Remote images blocked. Trackers can fingerprint│
│    your IP. [Always load from sender@example.com]  │
└────────────────────────────────────────────────────┘
```

* Banner appears between the meta block and the iframe ONLY when
  `had_remote_images` is true AND the sender isn't allowlisted.
* Background: `color-mix(in oklch, var(--color-warn) 18%,
  var(--color-bg-elev))` (gentle yellow tint).
* Action button: `.btn-soft--sm`. Text uses sender's address verbatim
  so the user knows exactly what they're allowlisting.
* On click, `mail_remote_images_allow` adds the row, the iframe is
  re-rendered with the relaxed CSP, and the banner removes itself
  with a 0.18s fade.

### 6.4 Quoted text collapsing

Real conversational replies typically include `> ` quoted text — in
HTML it's wrapped in `<blockquote>` or `<div class="gmail_quote">` or
inline `<div style="border-left: solid 1px ...">`. Most clients let
the user fold these.

* On render, walk the DOM (post-sanitize, pre-display) and tag
  `<blockquote>` elements at depth ≥ 1.
* For each, replace its content with a click-to-expand placeholder:
  ```
  <button class="quote-collapser">▼ Show quoted text</button>
  ```
* The placeholder is an in-iframe element styled to match Clome (color,
  padding, border-left). On click (handler attached via the iframe's
  `contentDocument`), the original content swaps back in.
* For `gmail_quote` divs: same treatment via class match.

This is cosmetic but enormously improves scan-ability of reply chains.
Mimestream / Spark do this; Apple Mail does it via the `…` button at
the bottom of a reply.

### 6.5 Calendar invite (`text/calendar` parts)

Inline RSVP card rendered above the body when
`detail.has_calendar_invite` is true:

```
┌──────────────────────────────────────────────────────┐
│  📅 Stanford CS Faculty Lunch                        │
│     Wednesday, May 7 · 12:00 – 1:30 PM               │
│     Stanford CS Building                             │
│                                                      │
│  [ Accept ]  [ Tentative ]  [ Decline ]              │
└──────────────────────────────────────────────────────┘
```

Reuses the existing EventKit cap (`calendar.write`). On click, posts
an iTIP REPLY via SMTP and writes the event to macOS Calendar via the
sidecar.

Phase 5 polish — not v1.

### 6.6 Attachments footer

* Sticky to the bottom of the reading pane (when scrolled).
* Padded `0.65rem 1.3rem`.
* Header: "{N} attachments" in `.section-label` style.
* Each attachment is an `.input-pill`-styled chip showing filename ·
  size. Hover reveals download / preview icons.
* Inline images (CID parts that the HTML body references via `cid:`)
  are NOT in the attachments footer — they render inline.
* Click the chip → preview modal:
  * Image / PDF / text → in-app preview (modal at 80vw × 80vh)
  * Other types → "Open with system app" via `tauri-plugin-opener`
  * Phase 5 polish: macOS QuickLook via Swift sidecar

---

## 7. Composer modal spec

```
┌──────────────────────────────────────────────────────┐
│  New message                                       ✕ │  header
├──────────────────────────────────────────────────────┤
│  FROM    rany@gmail.com   ▾                          │  account picker (only ≥2)
├──────────────────────────────────────────────────────┤
│  TO      alice@example.com, bob@example.com          │
├──────────────────────────────────────────────────────┤
│  + Add Cc / Bcc                                      │  expandable
├──────────────────────────────────────────────────────┤
│  SUBJECT  Re: Friday's review                        │
├──────────────────────────────────────────────────────┤
│                                                      │
│  Body in markdown — renders to HTML on send.         │  textarea (flex: 1)
│                                                      │
│                                                      │
│                                                      │
│                                                      │
├──────────────────────────────────────────────────────┤
│  ↳ Reply · threaded         [Discard]    [→ Send]    │  footer
└──────────────────────────────────────────────────────┘
```

### 7.1 Modal shell

* Use `.modal-scrim` + `.modal-card` (existing classes), NOT raw
  Tailwind backdrop.
* Card dimensions: `44rem × 40rem`, centered, max `90vw × 90vh`.
* Animation: same `modal-card-in` keyframe (0.18s slide+fade).
* Backdrop: `.modal-scrim` blur (existing).
* Esc closes if there's no unsent draft; if dirty, prompts
  "Discard draft?" with destructive confirmation.

### 7.2 Field rows

Each field is a `<label>` with a `.section-label`-styled column on the
left (`5.5rem` wide, uppercase 10.5px 650), a flex-1 input area on the
right, separated by a 1px hairline. No backgrounds on individual fields
— the row is the visual unit.

* **From**: Only shown when `accounts.length >= 2`. Picker is an
  `.input-pill`-styled `<select>`.
* **To**: Comma- and newline-separated addresses. Each address renders
  as an `.input-pill` chip with a small `✕` to remove. Backspace at
  start of input removes the last chip. Tab autocompletes from address
  book (Phase 5).
* **+ Add Cc / Bcc**: Tertiary text button (`.btn-soft--ghost`).
  Clicking expands two more rows.
* **Subject**: Plain text input, 13px, no decoration.

### 7.3 Body editor

* `<textarea>`, fixed-pitch optional. By default uses
  `var(--font-sans)` 14px line-height 1.55.
* Toggle button in the toolbar above the body: "MD" / "Plain". MD =
  monospace + show-rendered-preview-on-blur. Plain = plain text only,
  no markdown rendering.
* Auto-grow disabled — body uses `flex: 1` and scrolls if needed.
* Placeholder text on empty body explains the markdown→HTML pipeline.
* Body editor uses CodeMirror 6 (already a dep, used by NoteEditor) so
  syntax highlighting (markdown) works.

### 7.4 Footer

* Left: contextual hint — "Reply · threaded" when `inReplyTo` is set;
  empty otherwise.
* Right: `[Discard]` (`.btn-soft--ghost`) and `[→ Send]`
  (`.btn-soft--primary`).
* `Send` is disabled when the To list is empty.
* `⌘Enter` triggers Send from anywhere in the modal (including inside
  the body textarea).
* During send: button shows `Loader2` spinning, label "Sending…",
  disabled.
* On error: error banner across the bottom of the body in
  `var(--color-danger)` background tint, dismissible.

### 7.5 Auto-save (Phase 5)

Every 30s while the user types AND the body is non-empty, save the
draft locally + IMAP APPEND to the Drafts folder. Visual cue: tiny
"Saved 12 s ago" in the footer, refreshes on each save.

Out of v1 scope — but design the schema to support it (the `draft`
table is already there).

### 7.6 Outbox / undo-send (Phase 5)

After clicking Send, the modal closes immediately and a bottom-of-screen
toast appears:

```
┌──────────────────────────────────────────────────────┐
│  ✓ Sending in 8s …                              UNDO │
└──────────────────────────────────────────────────────┘
```

10-second default window. Click UNDO → message returns to a fresh
composer. After 10s, the toast disappears and SMTP fires.

Out of v1 scope — but the persistent outbox table exists and can carry
the state.

---

## 8. HTML email rendering — deeper spec

This is the part of the UI nobody else gets right. Both the security
side and the typography side.

### 8.1 Sanitization layer (already shipped)

`mail::sanitize::sanitize` does:

* `ammonia::Builder` whitelist — strips `<script>`, `<style>`,
  `<iframe>`, `<object>`, `<embed>`, `<link>`, `<meta>`, `<form>`,
  `<input>`, event handlers (`onclick`, `onload`, …), `javascript:`
  and `data:script` URIs.
* Adds `style` attribute back to common tags (Outlook-generated mail
  is mostly inline-style-driven).
* Preserves `<font>`, `<center>`, table layouts (older mailing
  software still emits these).

### 8.2 Defensive `<style>` block (NEW — bake into wrap_with_csp)

Inject a small reset stylesheet inside `<head>` to neutralize the most
common pathologies:

```css
html, body {
  margin: 0;
  padding: 0;
  max-width: 100% !important;
  word-break: break-word;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 14px;
  line-height: 1.55;
}
table {
  max-width: 100% !important;
}
img {
  max-width: 100% !important;
  height: auto !important;
}
blockquote {
  margin: 0.6em 0;
  padding-left: 0.8em;
  border-left: 3px solid rgba(127, 127, 127, 0.3);
}
.quote-collapser {
  cursor: pointer;
  display: inline-block;
  padding: 0.3em 0.6em;
  border-radius: 6px;
  background: rgba(127, 127, 127, 0.1);
  border: 1px solid rgba(127, 127, 127, 0.2);
  font-size: 12px;
  color: rgba(127, 127, 127, 0.9);
}
```

This is a *minimal* reset — we deliberately avoid forcing Clome's
theme onto the email. Senders' branding wins.

### 8.3 CSP-driven image gating (already shipped)

* Blocked by default: `img-src data: cid:`
* Per-sender allowlist: `mail_remote_images_allow(account_id, sender)`
  unlocks via the banner.
* The CSP `<meta>` is injected per-render — flipping the allowlist
  flag re-renders.

### 8.4 Tracking-pixel scrubber (Phase 5 polish)

Even with images allowed, strip 1×1 transparent pixel `<img>` tags
where the URL matches a known-tracker pattern. Maintain a small
URL-substring list:

```
google-analytics
googletagmanager
mailchimp open
hubspot pixel
mandrillapp track
sendgrid open
sailthru pixel
salesforce pardot
constantcontact
sparkpostmail
mxlogic
li.linkedin
fb.com/tr
```

Match by substring of the `src` URL. Strip the `<img>` outright.

Phase 5 — keep flag in `SanitizeOptions::strip_tracking_pixels` ready.

### 8.5 Quoted-text post-process (NEW)

After ammonia sanitizes, walk the DOM (using a Rust HTML walker like
`html5ever` from ammonia's deps) and:

1. Find every `<blockquote>` and every `<div class="gmail_quote">`.
2. Replace the inner content with a click-to-expand `<button
   class="quote-collapser">` element that, on click, swaps the
   content back in via inline JS we cannot use (because no
   `allow-scripts`).

Constraint: we can't run JS in the iframe. Workaround: use CSS-only
disclosure. `<details><summary>` works perfectly here:

```html
<details>
  <summary>▼ Show 12 quoted lines</summary>
  <blockquote>…original quoted content…</blockquote>
</details>
```

`<details>` is part of HTML5, browsers handle the open/close natively
without JS. No `allow-scripts` needed. The summary text counts the
lines so the user knows what they're expanding.

### 8.6 Inline `cid:` image rewriting

Sanitized HTML may reference inline images via `cid:abc@def`. The
attachments table has the actual bytes. Rewrite to local file URLs:

* On Tauri, we can't use `file://` due to webview security; instead,
  Tauri has the `convertFileSrc` API that produces a safe stream URL.
* On render, walk the post-sanitize HTML and replace
  `src="cid:abc@def"` with `src="<convertFileSrc(attachment_path)>"`,
  then expand CSP `img-src` to include the asset stream prefix.

This is the only remote-ish image type we permit by default (it's
local). Phase 5 wires it; v1 leaves `cid:` images as broken
placeholders.

---

## 9. Interactions & keyboard

### 9.1 Global mail shortcuts

Following Gmail conventions because that's what most users have in
muscle memory:

| Key | Action |
|-----|--------|
| `c` | Compose new message |
| `r` | Reply |
| `R` | Reply all |
| `f` | Forward |
| `e` | Archive |
| `#` | Delete |
| `s` | Star/Unstar |
| `u` | Mark unread |
| `j` | Next message (down) |
| `k` | Previous message (up) |
| `o` or `Enter` | Open selected message |
| `/` | Focus search |
| `g i` | Go to Inbox (sequence) |
| `g s` | Go to Sent |
| `g d` | Go to Drafts |
| `g a` | Go to Archive |
| `g t` | Go to Trash |

Plus existing app shortcuts:

| Key | Action |
|-----|--------|
| `⌘F` | Toggle search (already shipped) |
| `⌘N` | Compose (alias for `c`) |
| `⌘\\` | Toggle 2-pane / 3-pane |
| `⌘⇧\\` | Toggle wide reading mode |
| `⌘Enter` (in composer) | Send |
| `Esc` | Close modal / search / wide-read mode |

Each shortcut is a single component-scoped `keydown` listener
registered in `MailApp.tsx`'s `onMount`, similar to the existing `⌘F`.

### 9.2 Keyboard shortcut help overlay

`?` opens a modal showing all shortcuts. Same `.modal-scrim` +
`.modal-card` shell. Two columns of `kbd`-styled keys + descriptions.
This is a low-cost discoverability boost.

### 9.3 Focus ring

Every interactive element gets a focus-visible ring that matches the
`.input-pill` recipe:

```css
*:focus-visible {
  outline: none;
  box-shadow: 0 0 0 3px color-mix(in oklch, var(--color-accent) 14%, transparent);
}
```

Already in App.css for some surfaces — extend to mail.

### 9.4 Drag-drop

Phase 5 polish:

* Drag a row from the message list onto a folder in the sidebar →
  MOVE.
* Drag a draft body file (e.g., a .pdf from Finder) into the composer
  body → attach.
* Drag a single attachment chip OUT of the reading pane → save as
  file (use `tauri-plugin-fs` save dialog).

---

## 10. State design

### 10.1 Loading

* Per-account sync indicator: 11px `Loader2` with `animate-spin`,
  inline with the account email. Only visible while
  `syncing[account_id]` is true. Already shipped.
* Per-folder fetch on click: brief inline spinner in the header
  ("Syncing…") that fades after summary returns. Replace the existing
  `?` placeholder.
* Reading-pane body load: skeleton — three pulsing bars in the body
  area at 40% / 70% / 90% widths.
* Composer send: footer `Send` button transforms into spinner + label
  ("Sending…") and is disabled.

### 10.2 Empty

| Surface | Empty state |
|---------|-------------|
| No accounts | Centered illustration + "Add your first mail account" CTA |
| Folder never synced | Centered "Click ↻ to fetch this folder" with the icon button |
| Folder is empty | Centered "Nothing here." (smaller) |
| Search returned 0 | Centered "No matches for `<query>`" with "Clear search" button |
| No selected message | "Select a message" with a small Mail icon (existing) |
| Composer never opened | Empty body, the placeholder text fills with markdown hint |

All empty states use `.empty-state` class (12.5px, subtle text, center).
Illustrations are 40×40 Lucide icons in `var(--color-text-subtle)`.

### 10.3 Error

* Any backend error from a Tauri command is surfaced as a toast at
  the bottom-right (4 s auto-dismiss, manual close).
* Toast structure: `.btn-soft--danger` background tint, icon + message
  + close `✕`.
* Special errors:
  * `oauth state mismatch` → toast "Sign-in expired. Re-add your account."
  * `imap XOAUTH2 auth: ...` → toast with "Try syncing again. If
    persists, remove and re-add the account."
  * `smtp send: ...` → composer stays open; error renders inline
    (existing) so the user can fix and retry.

### 10.4 Sync status timeline (Phase 5)

A small disclosure in the footer of the sidebar shows the last sync
time per account ("Synced 2 m ago"). Click to expand a timeline of
recent fetches with summary counts. Mimics Spark's "synced just now"
indicator.

---

## 11. Animation choreography

Motion creates the perception of speed even when latency is constant.
Specific animations:

| Surface | Trigger | Animation |
|---------|---------|-----------|
| Modal open (compose, account add, RSVP) | Mount | `modal-card-in` (0.18 s ease-in-out) — fade + slide+scale |
| Modal close | Unmount | Reverse keyframe (0.12 s ease-out) |
| Toolbar button hover | mouseover | `translateY(-1px)` + drop shadow up (0.12 s ease) |
| Toolbar button active | mousedown | `translateY(+1px)` + inset (0.06 s ease) |
| Folder collapse / expand | click | `max-height` transition 0.16 s ease-out |
| Selection move (j/k) | keydown | smooth scrollIntoView with `block: 'nearest'` |
| Message-list new arrival | event | new row fades in from 0 → 1 over 0.18 s + 4 px slide-in from above |
| Remove message (archive/delete) | click | row collapses height + fades over 0.18 s before vanish |
| Quoted-text expand | click on `<details>` summary | browser default (smooth where supported) |
| Sync indicator | event | `Loader2` spin (CSS `animate-spin`) — already shipped |
| Send → undo toast | post-send | toast slides up from bottom over 0.18 s |
| Undo toast countdown | tick | progress bar fills along the bottom edge |
| Compose FAB hover | mouseover | drop shadow expands; `var(--color-bg-elev)` deepens slightly |

All durations are in the `0.06s–0.18s` range. Anything longer feels
sluggish in a desktop client.

---

## 12. Accessibility

* All buttons have `title` attributes (which double as tooltips and
  aria-labels for icon-only buttons).
* `<div role="button" tabindex="0">` patterns (already used for the
  account row to fix the nested-button bug) get
  `onKeyDown={Enter | Space → onClick}`.
* Modals trap focus (focus stays within while open, returns to the
  trigger element on close).
* Esc closes modals.
* The HTML iframe inherits the user's system text size when they zoom
  the page (we don't lock font-size).
* Screen-reader: each message-list row has an aria-label combining
  `from · subject · date · unread`.
* Color-contrast: all text/background pairings tested against WCAG
  AA at 14px+. The OKLCH token system was designed for this; check
  `--color-text-subtle` on `--color-bg-hover` if/when used.
* High-contrast mode: respect `@media (prefers-contrast: more)` —
  swap `--color-border-strong` for `--color-text` on borders.
* Reduced motion: respect `@media (prefers-reduced-motion: reduce)` —
  drop transforms, keep opacity, halve durations.

---

## 13. Performance

### 13.1 Virtualized message list

Required at 5k+ rows. Use the windowing math directly (no library):

```ts
const rowHeight = 70; // cozy cm
const visibleCount = Math.ceil(viewport.height / rowHeight) + 10;
const startIndex = Math.floor(viewport.scrollTop / rowHeight);
const slice = messages.slice(startIndex, startIndex + visibleCount);
```

Render the slice with `transform: translateY(${startIndex * rowHeight}px)`
on a wrapper. Total scroll height is computed from `messages.length *
rowHeight`.

### 13.2 Iframe rendering

* iframe is recreated per-message (cheap) rather than diffed (expensive
  and unsafe given the sandbox).
* Sanitization happens in Rust (cheap, ~1 ms for typical mail).
* `srcdoc` is set once — no re-render on selection unless the message
  changes.

### 13.3 Image lazy load

The browser handles `<img loading="lazy">` natively. The sanitizer
should add this attribute to every `<img>` it preserves. Stops the
network from getting hammered when the user opens a 50-image newsletter.

### 13.4 Snippets / FTS

The message-list renders pre-computed `snippet` text from the DB —
never re-parses the body. List rendering stays sub-16ms even at 50k
rows.

### 13.5 Send quota / rate limit

(Phase 5) Outbox enforces ≤ 10 sends per 60 s to avoid Gmail's
"too many recent" 421 responses on rapid bulk replies.

---

## 14. Implementation roadmap

The redesign is bigger than a single afternoon. Sequence the work so
the app stays shippable at every step.

### Phase R1 — token migration (1-2 sessions)

* Replace every Tailwind `zinc-*` utility in `MailApp.tsx` with CSS
  custom-property classes or inline `style={{}}` referencing
  `var(--color-*)`.
* Use the existing `.mail-*` classes from App.css (lines 2452–2714) as
  a foundation; extend where needed.
* Replace all `shadow-lg` / `shadow-xl` with the soft-3D recipe via
  `.btn-soft*`, `.modal-card`, `.fab-soft`.
* Acceptance: side-by-side screenshot of MailApp + chat surface, the
  visual language is identical (same hairlines, same hover lifts, same
  panel backgrounds, same modal shells).

### Phase R2 — typography + density (1 session)

* Apply the type scale from §2.3 to every text element.
* Apply `.section-label` to all section headers.
* Implement the three density modes (Cozy/Comfortable/Compact) wired
  to a Settings preference.
* Acceptance: typography matches the chat / notes surfaces; density
  toggle visibly changes row heights.

### Phase R3 — message list polish (1 session)

* New row anatomy (sender · subject · snippet) with proper
  weight/color states for read/unread/selected/hovered.
* Unread indicator dot (`var(--color-accent)`).
* Date formatting (today / yesterday / weekday / date).
* Empty states (`.empty-state` with icons).
* Acceptance: list scans like Apple Mail / Spark, not the current
  "name + subject + snippet jumble".

### Phase R4 — reading pane upgrade (2 sessions)

* Sticky toolbar with `.btn-soft--icon-sm` buttons + tooltips with
  shortcuts.
* Subject + meta block matching §6.2.
* Defensive `<style>` reset injected into HTML iframe.
* Iframe height auto-sizing via `ResizeObserver`.
* `<details>` / `<summary>` quote collapsing (post-sanitize DOM walk
  in Rust).
* Link rewriter + hover preview tooltip.
* Acceptance: opening a marketing email no longer breaks the layout;
  replies show collapsed quotes; the toolbar stays sticky.

### Phase R5 — keyboard shortcuts (1 session)

* All shortcuts from §9.1 wired (`j`, `k`, `r`, `R`, `f`, `e`, `#`,
  `s`, `u`, `c`, `o`, `Enter`, `g i/s/d/a/t`, `?` for help overlay).
* Help overlay modal (`.modal-card`) listing every shortcut.
* Focus-visible rings on all interactive elements.
* Acceptance: full mail workflow possible without touching the mouse.

### Phase R6 — composer redesign (1 session)

* `.modal-scrim` + `.modal-card` shell.
* Field rows with `.section-label` left columns.
* Address chip rendering for To/Cc/Bcc.
* CodeMirror 6 markdown body.
* Footer with `.btn-soft--primary` Send + `.btn-soft--ghost` Discard.
* `⌘Enter` send.
* Acceptance: composer feels like the chat composer's twin.

### Phase R7 — sidebar refinement (0.5 session)

* Account row + folder row hierarchy with proper indentation.
* "Other folders" disclosure for non-special folders.
* Drag-handles on pane gutters with persisted widths.
* Acceptance: sidebar matches notes-vault sidebar density and behavior.

### Phase R8 — animation polish (0.5 session)

* Modal in/out using `modal-card-in` keyframe.
* Row arrive / remove animations.
* Hover/active button micromotion.
* `prefers-reduced-motion` respect.
* Acceptance: every state change feels coordinated.

### Phase R9 — empty + error states (0.5 session)

* Every empty state has the right `.empty-state` styling + Lucide
  illustration.
* Error toasts via `.btn-soft--danger` color tint.
* Acceptance: no plain "No messages" zinc-text states remain.

### Phase R10 — accessibility audit (0.5 session)

* aria-labels on every icon-only button.
* Focus traps in modals.
* Color-contrast pass (manual + axe-cli).
* `prefers-contrast: more` support.
* Acceptance: full keyboard navigation; screen-reader announces every
  state change.

Total: **~9 focused sessions** to land the redesign cleanly. Each
phase is independently shippable; the app remains usable at every
step.

---

## 15. What happens to current code

The Phase 4 MailApp.tsx (~700 lines) gets replaced incrementally,
not torn down. The component structure (Sidebar, MessageListPane,
ReadingPane, ComposerModal, AddAccountModal) stays the same — it's
the right shape. What changes:

* Class strings on every element.
* Some buttons become `<div role="button">` (already done for the
  account row; extend).
* New helpers: density mode reader, keyboard-shortcut handler,
  iframe ResizeObserver wiring.
* New component file: `MailHelp.tsx` (the `?` shortcut overlay).
* Maybe a `MailRender.tsx` extraction for the iframe + tooltip + image
  banner cluster, since it's the most complex single concern.

App.css already has placeholder `.mail-*` classes (lines 2452–2714)
that anticipate this redesign. Extend them; don't fight them.

---

## 16. Open design questions to resolve before R1 starts

1. **Avatars in message list?** Apple Mail / Spark show colored
   circles with initials. Gmail's web doesn't (in default density).
   Recommendation: **NO** — they're clutter at Cozy density. Add at
   Comfortable density only.
2. **Sender prefix vs full name?** "Stanford FCU" vs "Stanford
   FCU \<offers@sfcu.org\>". Recommendation: name only in the list;
   address shown in the reading pane meta.
3. **Conversation view default expanded vs collapsed?**
   Recommendation: latest expanded, all older collapsed. Apple Mail's
   default; matches the "I want to see what's new" instinct.
4. **Star icon position?** Inline before subject (Apple) or right
   gutter (Gmail)? Recommendation: **inline before subject** — keeps
   the right gutter clean for the timestamp.
5. **What does "Archive" do for an IMAP account without `\Archive`
   special-use?** Some servers don't tag any folder. Recommendation:
   fall back to "All Mail" (Gmail-style); if absent too, surface an
   error toast with "Configure archive folder in Settings".
6. **Show sender domain favicons?** Adds branding recognition. Mimestream
   does this. Recommendation: **no** — privacy regression (favicon URL
   is a tracking vector) and adds dependence on a network roundtrip
   per row.
7. **Threading enabled by default?** Recommendation: **yes**, but with
   a per-account toggle. Mimics Apple Mail's "Organize by Thread"
   default-on.
8. **Should snooze be in v1's UI?** The IMAP-side mechanism doesn't
   exist yet — it's a local-only flag. Recommendation: ship the UI
   button (`Snooze`) but disabled with tooltip "Coming in v1.1" until
   the backend lands. Sets expectation visibly.
9. **Where do calendar invites RSVP-state live?** Currently no
   backing store; the EventKit sidecar handles the event creation but
   we don't track "I responded Yes to this invite" locally. Recommendation:
   add an `invite_response` table tracking `(account_id, message_uid,
   response, responded_at)` so re-renders show "✓ Accepted" instead of
   the original buttons.
10. **Compose modal: full-screen vs windowed?** Gmail offers both.
    Recommendation: windowed by default (focus-friendly), with a
    `⤢` button in the modal header to expand to full-screen.

Resolve these before R1 starts; record decisions in this file as
they're made.
