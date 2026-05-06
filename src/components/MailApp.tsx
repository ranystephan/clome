// Native mail client UI. Replaces the legacy MailView (Mail.app
// reader) with the OAuth + IMAP path landed in src-tauri/src/mail/.
// Phase 2 ships the read surface: account onboarding, sync trigger,
// folder list, message list, threaded reading pane with sandboxed
// HTML iframe + per-sender remote-image allowlist.

import {
  createEffect,
  createMemo,
  createResource,
  createSignal,
  For,
  Show,
  onCleanup,
  onMount,
} from "solid-js";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import {
  Inbox,
  Send,
  FileText as DraftIcon,
  Trash2,
  Archive,
  Star,
  Plus,
  RefreshCw,
  Search,
  X,
  Eye,
  EyeOff,
  Loader2,
  Layers,
  Reply,
  ReplyAll,
  Forward,
  MailOpen,
  ChevronDown,
} from "lucide-solid";

// ── Types mirroring src-tauri/src/mail/{types,commands}.rs ──

type ProviderKind = "gmail" | "outlook" | "icloud" | "fastmail" | "yahoo" | "imap";

type Account = {
  id: string;
  email: string;
  displayName: string | null;
  provider: ProviderKind;
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
  signature: string | null;
  notifyEnabled: boolean;
  attachmentAutoDlMaxMb: number;
  createdAt: string;
  lastSyncAt: string | null;
};

type AutoconfigResult = {
  email: string;
  displayName: string | null;
  provider: ProviderKind;
  imap: { host: string; port: number; security: "tls" | "starttls"; username: string };
  smtp: { host: string; port: number; security: "tls" | "starttls"; username: string };
  oauth: { authUrl: string; tokenUrl: string; clientId: string; scopes: string[] } | null;
  source: "builtin" | "ispdb" | "srv" | "autodiscover" | "manual";
};

type OAuthStartResult = {
  state: string;
  authUrl: string;
  redirectUri: string;
};

type Folder = {
  name: string;
  role: string | null;
  uidvalidity: number | null;
  unreadCount: number;
  totalCount: number;
};

type EmailAddr = { addr: string; name: string | null };

type MessageHeader = {
  accountId: string;
  folder: string;
  uid: number;
  messageId: string | null;
  threadId: string | null;
  fromAddr: string | null;
  fromName: string | null;
  subject: string | null;
  snippet: string | null;
  dateReceived: number;
  hasAttachments: boolean;
  unread: boolean;
  flagged: boolean;
};

type AttachmentInfo = {
  contentId: string;
  filename: string | null;
  mime: string;
  size: number;
  isInline: boolean;
};

type MessageDetail = {
  header: MessageHeader;
  to: EmailAddr[];
  cc: EmailAddr[];
  html: string;
  plainFallback: string | null;
  hadRemoteImages: boolean;
  remoteImagesAllowed: boolean;
  attachments: AttachmentInfo[];
  hasCalendarInvite: boolean;
};

type SyncSummary = {
  accountId: string;
  folder: string;
  uidvalidity: number;
  fetched: number;
  stored: number;
};

// ── Helpers ─────────────────────────────────────────────────

function formatDate(unixSeconds: number) {
  const d = new Date(unixSeconds * 1000);
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  if (sameDay) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const sameYear = d.getFullYear() === now.getFullYear();
  return d.toLocaleDateString(
    [],
    sameYear
      ? { month: "short", day: "numeric" }
      : { year: "numeric", month: "short", day: "numeric" },
  );
}

function senderLabel(h: MessageHeader) {
  return h.fromName ?? h.fromAddr ?? "(unknown sender)";
}

function messageKey(ctx: { accountId: string; folder: string; uid: number }) {
  return `${ctx.accountId}::${ctx.folder}::${ctx.uid}`;
}

function folderLabel(folder: Pick<Folder, "name" | "role">) {
  return folderDisplayName(folder.name, folder.role);
}

function folderDisplayName(name: string, role?: string | null) {
  switch (role) {
    case "inbox":
      return "Inbox";
    case "sent":
      return "Sent";
    case "drafts":
      return "Drafts";
    case "trash":
      return "Trash";
    case "junk":
      return "Spam";
    default:
      break;
  }

  const cleaned = name
    .replace(/^\[Gmail\]\//i, "")
    .replace(/^gmail\//i, "")
    .replace(/^INBOX$/i, "Inbox")
    .trim();

  return cleaned || name;
}

function folderIcon(role: string | null) {
  switch (role) {
    case "inbox":
      return Inbox;
    case "sent":
      return Send;
    case "drafts":
      return DraftIcon;
    case "trash":
      return Trash2;
    case "archive":
      return Archive;
    case "junk":
      return Trash2;
    default:
      return Inbox;
  }
}

function providerLabel(provider: ProviderKind) {
  switch (provider) {
    case "gmail":
      return "Gmail";
    case "outlook":
      return "Outlook";
    case "icloud":
      return "iCloud";
    case "fastmail":
      return "Fastmail";
    case "yahoo":
      return "Yahoo";
    case "imap":
      return "IMAP";
  }
}

function providerLogoSrc(provider: ProviderKind) {
  switch (provider) {
    case "gmail":
      return "/mail-providers/gmail.png";
    case "outlook":
      return "/mail-providers/outlook.png";
    case "icloud":
      return "/mail-providers/icloud.png";
    case "fastmail":
      return "/mail-providers/fastmail.png";
    case "yahoo":
      return "/mail-providers/yahoo.png";
    case "imap":
      return null;
  }
}

function ProviderMark(props: { provider: ProviderKind }) {
  const label = providerLabel(props.provider);
  const src = providerLogoSrc(props.provider);

  if (!src) {
    return <span class="mail-provider-mark mail-provider-mark--imap" title={label}>@</span>;
  }

  return (
    <span class={`mail-provider-mark mail-provider-mark--${props.provider}`} title={label}>
      <img src={src} alt="" loading="eager" decoding="async" />
    </span>
  );
}

// ── Pane resize handle ─────────────────────────────────────
// 6px draggable strip on the right edge of a pane. Updates a CSS
// custom property on `:root` (so the pane's `flex: 0 0 var(...)`
// follows) and persists the pixel width per `storageKey` so the
// next session starts at the same place.
function ResizeHandle(props: {
  cssVar: string;
  storageKey: string;
  minPx: number;
  maxPx: number;
}) {
  const [active, setActive] = createSignal(false);

  function onPointerDown(e: PointerEvent) {
    e.preventDefault();
    const handle = e.currentTarget as HTMLDivElement;
    const pane = handle.parentElement as HTMLElement | null;
    if (!pane) return;
    const startX = e.clientX;
    const startWidth = pane.getBoundingClientRect().width;
    setActive(true);
    handle.setPointerCapture(e.pointerId);
    document.body.style.cursor = "col-resize";

    const onMove = (ev: PointerEvent) => {
      const delta = ev.clientX - startX;
      const next = Math.max(
        props.minPx,
        Math.min(props.maxPx, Math.round(startWidth + delta)),
      );
      document.documentElement.style.setProperty(props.cssVar, `${next}px`);
    };
    const onUp = () => {
      setActive(false);
      document.body.style.cursor = "";
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      // Persist the final value (read back from the CSS var so the
      // clamping above is honoured).
      const finalVal = getComputedStyle(document.documentElement)
        .getPropertyValue(props.cssVar)
        .trim();
      if (finalVal) {
        try {
          localStorage.setItem(props.storageKey, finalVal);
        } catch (e) {
          console.warn("[MailApp] persist resize failed:", e);
        }
      }
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }

  return (
    <div
      class={`mail-resize-handle${active() ? " mail-resize-handle--active" : ""}`}
      onPointerDown={onPointerDown}
    />
  );
}

// ── Component ───────────────────────────────────────────────

export default function MailApp() {
  const [accountsResource, { refetch: refetchAccounts }] = createResource(() =>
    invoke<Account[]>("mail_account_list"),
  );
  const accounts = () => accountsResource() ?? [];

  const [selectedAccountId, setSelectedAccountId] = createSignal<string | null>(null);
  const [selectedFolder, setSelectedFolder] = createSignal<string | null>(null);
  const [selectedUid, setSelectedUid] = createSignal<number | null>(null);
  const [showAddModal, setShowAddModal] = createSignal(false);
  const [syncing, setSyncing] = createSignal<Record<string, boolean>>({});
  // `null` = the synthetic "Unified Inbox" view (cross-account, role=inbox).
  // Frontend treats it as a sentinel folder; the backend has a dedicated
  // command (`mail_unified_inbox`).
  const [unifiedView, setUnifiedView] = createSignal(false);
  const [searchQuery, setSearchQuery] = createSignal("");
  const [searchActive, setSearchActive] = createSignal(false);
  const [composer, setComposer] = createSignal<ComposerInitial | null>(null);
  // Tracks folder names that have been synced this session so we
  // don't re-fetch on every click. Cleared on account switch.
  const [syncedFolders, setSyncedFolders] = createSignal<Set<string>>(new Set());
  const [loadingMore, setLoadingMore] = createSignal(false);
  const [loadImagesOnceKeys, setLoadImagesOnceKeys] = createSignal<Set<string>>(new Set());
  const [hiddenMessageKeys, setHiddenMessageKeys] = createSignal<Set<string>>(new Set());
  const [flagOverrides, setFlagOverrides] = createSignal<
    Record<string, Partial<Pick<MessageHeader, "flagged" | "unread">>>
  >({});
  // Per-account sync state — driven by mail:sync_status events.
  // The sidebar reads this to render "Synced 2m ago" / red error dot.
  const [accountSync, setAccountSync] = createSignal<Record<string, AccountSyncState>>(
    {},
  );
  // Forces a one-second re-render of the sidebar's relative
  // timestamps so "Synced 1m ago" stays accurate without polling
  // the backend.
  const [tickNow, setTickNow] = createSignal(Math.floor(Date.now() / 1000));
  // Sidebar visibility — toggled with Cmd+\. Persisted.
  const [sidebarVisible, setSidebarVisible] = createSignal(
    (() => {
      try {
        return localStorage.getItem("mail.sidebar.hidden") !== "1";
      } catch {
        return true;
      }
    })(),
  );

  // First account auto-select on mount.
  const defaultAccountSelector = createMemo(() => {
    if (selectedAccountId()) return selectedAccountId();
    const first = accounts()[0];
    if (first) {
      queueMicrotask(() => setSelectedAccountId(first.id));
      return first.id;
    }
    return null;
  });

  // ── Folders for selected account ──
  const [foldersResource, { refetch: refetchFolders }] = createResource(
    selectedAccountId,
    (id) => invoke<Folder[]>("mail_folder_list", { accountId: id }),
  );
  const folders = () => foldersResource() ?? [];

  // Auto-select Inbox once folders arrive.
  createMemo(() => {
    const fs = folders();
    if (!selectedFolder() && fs.length > 0) {
      const inbox = fs.find((f) => f.role === "inbox") ?? fs[0];
      queueMicrotask(() => setSelectedFolder(inbox.name));
    }
  });

  // ── Messages for selected view ──
  // Source of truth resolves in priority order:
  //   1. active search query  → mail_search
  //   2. unified inbox toggle → mail_unified_inbox
  //   3. (account, folder)    → mail_message_list
  const [messagesResource, { refetch: refetchMessages }] = createResource(
    () => ({
      search: searchActive() ? searchQuery() : "",
      unified: unifiedView(),
      accountId: selectedAccountId(),
      folder: selectedFolder(),
    }),
    async (args) => {
      if (args.search.trim().length > 0) {
        return invoke<MessageHeader[]>("mail_search", {
          accountId: args.accountId,
          query: args.search,
          limit: 200,
          offset: 0,
        });
      }
      if (args.unified) {
        return invoke<MessageHeader[]>("mail_unified_inbox", {
          limit: 200,
          offset: 0,
        });
      }
      if (!args.accountId || !args.folder) return [];
      return invoke<MessageHeader[]>("mail_message_list", {
        accountId: args.accountId,
        folder: args.folder,
        limit: 200,
        offset: 0,
      });
    },
  );
  function applyMessageOverrides<T extends MessageHeader>(message: T): T {
    const key = messageKey({
      accountId: message.accountId,
      folder: message.folder,
      uid: message.uid,
    });
    const overrides = flagOverrides()[key];
    return overrides ? ({ ...message, ...overrides } as T) : message;
  }

  const messages = () =>
    (messagesResource() ?? [])
      .filter((m) => {
        const key = messageKey({ accountId: m.accountId, folder: m.folder, uid: m.uid });
        return !hiddenMessageKeys().has(key);
      })
      .map(applyMessageOverrides);

  const selectedMessageHeader = () => {
    const uid = selectedUid();
    if (uid == null) return null;
    const currentDetail = detailResource();
    return currentDetail?.header ?? messages().find((m) => m.uid === uid) ?? null;
  };

  // ── Selected message detail ──
  const [detailResource, { refetch: refetchDetail }] = createResource(
    () => {
      const uid = selectedUid();
      if (uid == null) return null;
      const selectedHeader = selectedMessageHeader();
      const acc = selectedHeader?.accountId ?? selectedAccountId();
      const fol = selectedHeader?.folder ?? selectedFolder();
      if (!acc || !fol) return null;
      const ctx = { accountId: acc, folder: fol, uid } as const;
      return {
        ...ctx,
        allowRemoteImagesOnce: loadImagesOnceKeys().has(messageKey(ctx)),
      } as const;
    },
    async (args) =>
      args
        ? invoke<MessageDetail>("mail_message_get", {
            accountId: args.accountId,
            folder: args.folder,
            uid: args.uid,
            allowRemoteImagesOnce: args.allowRemoteImagesOnce,
          })
        : null,
  );

  const detail = () => {
    const d = detailResource();
    if (!d) return d;
    return {
      ...d,
      header: applyMessageOverrides(d.header),
    };
  };

  // Thread context — sibling messages in the same conversation.
  // Fetched whenever the open message has a thread_id; surfaces in
  // the reading pane as a "Show more from this thread" strip below
  // the body so the user can navigate the conversation without
  // bouncing back to the message list.
  const [threadResource] = createResource(
    () => {
      const d = detailResource();
      return d?.header.threadId ?? null;
    },
    async (tid) =>
      tid ? invoke<MessageHeader[]>("mail_thread_get", { threadId: tid }) : [],
  );

  // ── Sync status events from Rust ──
  let unlisten: UnlistenFn | undefined;
  // Bad-reference toast — set when an agent-emitted `[[email:...]]`
  // points at a thread_id that doesn't exist in mail.db. Surfaces in
  // the mail header so the user knows the click "didn't go anywhere"
  // rather than silently leaving them on the previous selection.
  const [badRefToast, setBadRefToast] = createSignal<
    { threadId: string } | null
  >(null);
  let badRefTimer: number | null = null;

  // External "focus this thread" requests — used by clickable email
  // refs in agent chat (`[[email:THREAD_ID|Subject]]`). The detail is
  // dispatched as a window CustomEvent from the App router so MailApp
  // doesn't need to import it directly.
  function onFocusEmailThread(e: Event) {
    const detail = (e as CustomEvent).detail as
      | { threadId?: string }
      | undefined;
    const threadId = detail?.threadId;
    if (!threadId) return;
    void (async () => {
      try {
        const headers = await invoke<MessageHeader[]>("mail_thread_get", {
          threadId,
        });
        // Headers come back ordered ASC by date — last item is the
        // most recent reply, which is what the user almost always
        // wants to land on.
        const latest = headers[headers.length - 1];
        if (!latest) {
          flagBadRef(threadId);
          return;
        }
        setBadRefToast(null);
        if (badRefTimer != null) {
          clearTimeout(badRefTimer);
          badRefTimer = null;
        }
        setSelectedAccountId(latest.accountId);
        setSelectedFolder(latest.folder);
        setSelectedUid(latest.uid);
        setUnifiedView(false);
        setSearchActive(false);
        setSearchQuery("");
      } catch (err) {
        console.error("focus_email_thread failed:", err);
        flagBadRef(threadId);
      }
    })();
  }
  function flagBadRef(threadId: string) {
    setBadRefToast({ threadId });
    if (badRefTimer != null) clearTimeout(badRefTimer);
    badRefTimer = window.setTimeout(() => {
      setBadRefToast(null);
      badRefTimer = null;
    }, 6000);
  }
  onMount(() => {
    window.addEventListener("clome:focus_email_thread", onFocusEmailThread);
  });
  onCleanup(() => {
    window.removeEventListener("clome:focus_email_thread", onFocusEmailThread);
  });

  let unlistenFlags: UnlistenFn | undefined;
  onMount(async () => {
    // Flag-refresh-only event — fired after mail_refresh_flags writes
    // updated flags_json rows. Refetch the message list so unread
    // dots / star icons follow what other clients are doing.
    unlistenFlags = await listen<{
      accountId: string;
      folder: string;
      updated: number;
    }>("mail:flags_refreshed", () => {
      refetchMessages();
      refetchDetail();
      refetchFolders();
    });

    unlisten = await listen<{
      accountId: string;
      status: "syncing" | "idle" | "error";
      error?: string;
      ts?: number;
    }>("mail:sync_status", (evt) => {
      const id = evt.payload.accountId;
      const isSyncing = evt.payload.status === "syncing";
      setSyncing((prev) => ({ ...prev, [id]: isSyncing }));
      setAccountSync((prev) => {
        const cur = prev[id] ?? {
          syncing: false,
          lastOk: null,
          lastError: null,
        };
        if (evt.payload.status === "syncing") {
          return { ...prev, [id]: { ...cur, syncing: true } };
        }
        if (evt.payload.status === "idle") {
          return {
            ...prev,
            [id]: { syncing: false, lastOk: evt.payload.ts ?? null, lastError: null },
          };
        }
        if (evt.payload.status === "error") {
          return {
            ...prev,
            [id]: {
              syncing: false,
              lastOk: cur.lastOk,
              lastError: evt.payload.error ?? "Sync failed",
            },
          };
        }
        return prev;
      });
      if (!isSyncing) {
        refetchMessages();
        refetchFolders();
      }
    });
  });
  onCleanup(() => {
    unlisten?.();
    unlistenFlags?.();
  });

  // 1Hz tick for relative-time labels.
  let nowTickHandle: ReturnType<typeof setInterval> | undefined;
  onMount(() => {
    nowTickHandle = setInterval(() => {
      setTickNow(Math.floor(Date.now() / 1000));
    }, 1000);
  });
  onCleanup(() => {
    if (nowTickHandle) clearInterval(nowTickHandle);
  });

  // Restore persisted pane widths on mount.
  onMount(() => {
    const sidebarWidth = (() => {
      try {
        return localStorage.getItem("mail.sidebar.width");
      } catch {
        return null;
      }
    })();
    if (sidebarWidth) {
      document.documentElement.style.setProperty("--mail-sidebar-width", sidebarWidth);
    }
    const messagesWidth = (() => {
      try {
        return localStorage.getItem("mail.messages.width");
      } catch {
        return null;
      }
    })();
    if (messagesWidth) {
      document.documentElement.style.setProperty("--mail-messages-width", messagesWidth);
    }
  });

  // Periodic background sync. Until we have the IMAP IDLE supervisor
  // landed, poll every 30s for:
  //   * INBOX of every account (so new mail arrives no matter what
  //     folder the user is currently viewing)
  //   * the currently-selected folder if it isn't INBOX (so Sent /
  //     Drafts / Archive / Trash refresh while the user reads them)
  //
  // The incremental fetch on the backend filters on UID > MAX(local
  // uid), so most ticks short-circuit cheaply.
  const POLL_INTERVAL_MS = 30_000;
  let pollHandle: ReturnType<typeof setInterval> | undefined;

  async function pollOnce() {
    const allAccountIds = accounts().map((a) => a.id);
    if (allAccountIds.length === 0) return;
    // 1. New-mail fetch on INBOX (heavy path — sometimes flaky on
    //    Gmail because of the LIST step).
    for (const id of allAccountIds) {
      if (syncing()[id]) continue;
      try {
        await invoke("mail_sync_inbox", { accountId: id });
      } catch (e) {
        console.warn("[MailApp] periodic sync_inbox failed:", id, e);
      }
    }
    // 2. Flag-only refresh — lean, decoupled. Survives the heavy
    //    path's transient drops. This is what keeps unread/star
    //    state aligned with Gmail web / Apple Mail / Outlook even
    //    when (1) failed.
    for (const id of allAccountIds) {
      try {
        await invoke("mail_refresh_flags", { accountId: id });
      } catch (e) {
        console.warn("[MailApp] flag refresh failed:", id, e);
      }
    }
    // 3. Active folder when it isn't INBOX.
    const acc = selectedAccountId();
    const fol = selectedFolder();
    const inbox = folders().find((f) => f.role === "inbox");
    if (acc && fol && (!inbox || fol !== inbox.name)) {
      try {
        await invoke("mail_sync_folder", { accountId: acc, folder: fol });
      } catch (e) {
        console.warn("[MailApp] periodic sync_folder failed:", fol, e);
      }
      try {
        await invoke("mail_refresh_flags", { accountId: acc, folder: fol });
      } catch (e) {
        console.warn("[MailApp] active folder flag refresh failed:", fol, e);
      }
    }
  }

  onMount(() => {
    // Trigger one immediately on mount so a fresh tab refreshes
    // without waiting 30s.
    void pollOnce();
    pollHandle = setInterval(pollOnce, POLL_INTERVAL_MS);
  });
  onCleanup(() => {
    if (pollHandle) clearInterval(pollHandle);
  });

  // ── Keyboard shortcuts ────────────────────────────────────────
  // Gmail-class set: j/k navigate, r/R reply, f forward, e archive,
  // # delete, s star, u toggle-read, c compose, o/Enter open, /
  // search, g-i/s/d/a/t go-to-folder by role, ? help overlay,
  // ⌘F search, Esc dismiss.
  let searchInputRef: HTMLInputElement | undefined;
  const [pendingG, setPendingG] = createSignal(false);
  const [showHelp, setShowHelp] = createSignal(false);
  let pendingGTimer: ReturnType<typeof setTimeout> | undefined;

  function inFormElement(target: EventTarget | null): boolean {
    if (!target || !(target instanceof HTMLElement)) return false;
    const tag = target.tagName;
    return (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT" ||
      target.isContentEditable
    );
  }

  function navigateMessages(delta: 1 | -1) {
    const list = messages();
    if (list.length === 0) return;
    const cur = selectedUid();
    const idx = cur == null ? -1 : list.findIndex((m) => m.uid === cur);
    const next = Math.max(0, Math.min(list.length - 1, idx + delta));
    if (list[next]) setSelectedUid(list[next].uid);
  }

  function gotoFolderByRole(role: string) {
    const fs = folders();
    const target = fs.find((f) => f.role === role);
    if (!target) return;
    setUnifiedView(false);
    setSelectedFolder(target.name);
    setSelectedUid(null);
    setSearchActive(false);
    const acc = selectedAccountId();
    if (acc) handleFolderSync(acc, target.name);
  }

  onMount(() => {
    const handler = (e: KeyboardEvent) => {
      // Always-handled chords (regardless of focus, so the user can
      // bail out of the search box with Esc or open compose with ⌘N).
      if ((e.metaKey || e.ctrlKey) && e.key === "f") {
        e.preventDefault();
        setSearchActive(true);
        queueMicrotask(() => searchInputRef?.focus());
        return;
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "n") {
        e.preventDefault();
        openCompose();
        return;
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "\\") {
        e.preventDefault();
        const next = !sidebarVisible();
        setSidebarVisible(next);
        try {
          localStorage.setItem("mail.sidebar.hidden", next ? "0" : "1");
        } catch {
          /* ignore */
        }
        return;
      }
      if (e.key === "Escape") {
        if (showHelp()) {
          setShowHelp(false);
          return;
        }
        if (searchActive()) {
          setSearchActive(false);
          setSearchQuery("");
          return;
        }
      }

      // Don't capture single-key shortcuts while typing.
      if (inFormElement(e.target)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;

      // g-prefix sequence (g-i / g-s / g-d / g-a / g-t).
      if (pendingG()) {
        if (pendingGTimer) clearTimeout(pendingGTimer);
        setPendingG(false);
        switch (e.key) {
          case "i":
            e.preventDefault();
            gotoFolderByRole("inbox");
            return;
          case "s":
            e.preventDefault();
            gotoFolderByRole("sent");
            return;
          case "d":
            e.preventDefault();
            gotoFolderByRole("drafts");
            return;
          case "a":
            e.preventDefault();
            gotoFolderByRole("archive");
            return;
          case "t":
            e.preventDefault();
            gotoFolderByRole("trash");
            return;
        }
        // Fall through if it wasn't a recognised sequence key.
      }

      switch (e.key) {
        case "j":
          e.preventDefault();
          navigateMessages(1);
          break;
        case "k":
          e.preventDefault();
          navigateMessages(-1);
          break;
        case "Enter":
        case "o":
          // List rows already select on click; this is a no-op when a
          // message is highlighted via j/k since the resource refetch
          // is keyed off `selectedUid`. Kept here for muscle memory.
          break;
        case "r": {
          e.preventDefault();
          const d = detail();
          if (d) handleReply(d, false);
          break;
        }
        case "R":
          if (e.shiftKey) {
            e.preventDefault();
            const d = detail();
            if (d) handleReply(d, true);
          }
          break;
        case "f": {
          e.preventDefault();
          const d = detail();
          if (d) handleForward(d);
          break;
        }
        case "e":
          e.preventDefault();
          handleArchive();
          break;
        case "#":
          e.preventDefault();
          handleDelete();
          break;
        case "s": {
          e.preventDefault();
          const d = detail();
          if (d) handleToggleFlag("\\Flagged", !d.header.flagged);
          break;
        }
        case "u": {
          e.preventDefault();
          const d = detail();
          if (d) handleToggleFlag("\\Seen", d.header.unread);
          break;
        }
        case "c":
          e.preventDefault();
          openCompose();
          break;
        case "/":
          e.preventDefault();
          setSearchActive(true);
          queueMicrotask(() => searchInputRef?.focus());
          break;
        case "?":
          e.preventDefault();
          setShowHelp(true);
          break;
        case "g":
          e.preventDefault();
          setPendingG(true);
          if (pendingGTimer) clearTimeout(pendingGTimer);
          pendingGTimer = setTimeout(() => setPendingG(false), 1500);
          break;
      }
    };
    window.addEventListener("keydown", handler);
    onCleanup(() => {
      window.removeEventListener("keydown", handler);
      if (pendingGTimer) clearTimeout(pendingGTimer);
    });
  });

  // Debounce search input → 200ms before triggering a re-fetch.
  let searchDebounce: number | undefined;
  createEffect(() => {
    const q = searchQuery();
    if (searchDebounce) window.clearTimeout(searchDebounce);
    if (!searchActive()) return;
    searchDebounce = window.setTimeout(() => {
      void q;
      refetchMessages();
    }, 200);
  });

  // Auto-mark-as-read: when an unread message becomes the active
  // detail, set its `\Seen` flag locally + on the server. Tracked
  // by uid so a re-render of the same message doesn't refire.
  const autoReadFiredFor = new Set<string>();
  createEffect(() => {
    const d = detail();
    if (!d || !d.header.unread) return;
    const key = messageKey(d.header);
    if (autoReadFiredFor.has(key)) return;
    autoReadFiredFor.add(key);
    setFlagOverrides((prev) => ({
      ...prev,
      [key]: { ...prev[key], unread: false },
    }));
    invoke("mail_message_set_flag", {
      accountId: d.header.accountId,
      folder: d.header.folder,
      uid: d.header.uid,
      flag: "\\Seen",
      set: true,
    })
      .then(() => {
        refetchMessages();
        refetchDetail();
        refetchFolders();
      })
      .catch((e) => {
        console.warn("[MailApp] auto mark-read failed:", e);
        // Remove from cache so a manual retry isn't blocked.
        autoReadFiredFor.delete(key);
        setFlagOverrides((prev) => ({
          ...prev,
          [key]: { ...prev[key], unread: true },
        }));
      });
  });

  async function handleSync(accountId: string) {
    setSyncing((p) => ({ ...p, [accountId]: true }));
    try {
      await invoke<SyncSummary>("mail_sync_inbox", { accountId });
    } catch (e) {
      console.error("mail_sync_inbox failed:", e);
    } finally {
      setSyncing((p) => ({ ...p, [accountId]: false }));
      refetchMessages();
      refetchFolders();
    }
  }

  async function handleFolderSync(accountId: string, folder: string) {
    const key = `${accountId}::${folder}`;
    if (syncedFolders().has(key)) return; // session-scoped guard
    setSyncing((p) => ({ ...p, [accountId]: true }));
    try {
      await invoke<SyncSummary>("mail_sync_folder", { accountId, folder });
      setSyncedFolders((prev) => new Set(prev).add(key));
    } catch (e) {
      console.error("mail_sync_folder failed:", folder, e);
    } finally {
      setSyncing((p) => ({ ...p, [accountId]: false }));
      refetchMessages();
      refetchFolders();
    }
  }

  async function handleLoadOlder() {
    const accountId = selectedAccountId();
    const folder = selectedFolder();
    if (!accountId || !folder) return;
    setLoadingMore(true);
    try {
      await invoke<SyncSummary>("mail_load_older", {
        accountId,
        folder,
        count: 100,
      });
      refetchMessages();
    } catch (e) {
      console.error("mail_load_older failed:", e);
    } finally {
      setLoadingMore(false);
    }
  }

  // ── Mailbox actions on the currently-selected message ──

  function activeContext() {
    const uid = selectedUid();
    if (uid == null) return null;
    const selectedHeader = selectedMessageHeader();
    const accountId = selectedHeader?.accountId ?? selectedAccountId();
    const folder = selectedHeader?.folder ?? selectedFolder();
    if (!accountId || !folder) return null;
    return { accountId, folder, uid };
  }

  function handleLoadImagesOnce() {
    const ctx = activeContext();
    if (!ctx) return;
    setLoadImagesOnceKeys((prev) => {
      const next = new Set(prev);
      next.add(messageKey(ctx));
      return next;
    });
  }

  function hideActiveMessage() {
    const ctx = activeContext();
    if (!ctx) return null;
    const key = messageKey(ctx);
    const priorUid = selectedUid();
    const list = messages();
    const idx = list.findIndex((m) => m.uid === ctx.uid && m.folder === ctx.folder);
    const next = list[idx + 1] ?? list[idx - 1] ?? null;
    setHiddenMessageKeys((prev) => {
      const nextKeys = new Set(prev);
      nextKeys.add(key);
      return nextKeys;
    });
    setSelectedUid(next?.uid ?? null);
    return { ctx, key, priorUid };
  }

  function restoreHiddenMessage(hidden: { key: string; priorUid: number | null }) {
    setHiddenMessageKeys((prev) => {
      const next = new Set(prev);
      next.delete(hidden.key);
      return next;
    });
    setSelectedUid(hidden.priorUid);
  }

  function handleArchive() {
    const ctx = activeContext();
    if (!ctx) return;
    const hidden = hideActiveMessage();
    void invoke("mail_message_archive", ctx)
      .then(() => refetchMessages())
      .catch((e) => {
        console.error("archive failed:", e);
        if (hidden) restoreHiddenMessage(hidden);
        alert(`Archive failed: ${e}`);
      });
  }

  function handleDelete() {
    const ctx = activeContext();
    if (!ctx) return;
    const hidden = hideActiveMessage();
    void invoke("mail_message_delete", ctx)
      .then(() => refetchMessages())
      .catch((e) => {
        console.error("delete failed:", e);
        if (hidden) restoreHiddenMessage(hidden);
        alert(`Delete failed: ${e}`);
      });
  }

  function handleToggleFlag(flag: "\\Seen" | "\\Flagged", set: boolean) {
    const ctx = activeContext();
    if (!ctx) return;
    const key = messageKey(ctx);
    const field = flag === "\\Flagged" ? "flagged" : "unread";
    const optimisticValue = flag === "\\Seen" ? !set : set;
    const prior = flagOverrides()[key]?.[field] ?? detail()?.header[field];
    setFlagOverrides((prev) => ({
      ...prev,
      [key]: { ...prev[key], [field]: optimisticValue },
    }));
    void invoke("mail_message_set_flag", { ...ctx, flag, set })
      .then(() => {
        refetchMessages();
        refetchDetail();
      })
      .catch((e) => {
        console.error("set_flag failed:", flag, e);
        setFlagOverrides((prev) => ({
          ...prev,
          [key]: { ...prev[key], [field]: prior },
        }));
      });
  }

  async function handleAllowImages() {
    const currentDetail = detail();
    const sender = currentDetail?.header.fromAddr;
    const accountId = selectedAccountId();
    if (!currentDetail || !sender || !accountId) return;
    await invoke("mail_remote_images_allow", { accountId, senderEmail: sender });
    refetchDetail();
  }

  // ── Composer entry points ──

  function openCompose(initial?: Partial<ComposerInitial>) {
    const accountId = selectedAccountId() ?? accounts()[0]?.id;
    if (!accountId) {
      alert("Add an account first.");
      return;
    }
    setComposer({
      accountId,
      to: initial?.to ?? [],
      cc: initial?.cc ?? [],
      subject: initial?.subject ?? "",
      bodyMd: initial?.bodyMd ?? "",
      inReplyTo: initial?.inReplyTo ?? null,
      references: initial?.references ?? [],
    });
  }

  function quoteBody(detail: MessageDetail): string {
    const date = new Date(detail.header.dateReceived * 1000).toLocaleString();
    const from = detail.header.fromName ?? detail.header.fromAddr ?? "(unknown)";
    const text = detail.plainFallback ?? "";
    const quoted = text
      .split("\n")
      .map((line) => `> ${line}`)
      .join("\n");
    return `\n\nOn ${date}, ${from} wrote:\n${quoted}`;
  }

  function handleReply(detail: MessageDetail, all: boolean) {
    const replyTo = detail.header.fromAddr;
    const cc = all
      ? detail.cc.map((a) => a.addr).filter((a) => a !== detail.header.fromAddr)
      : [];
    const subj = detail.header.subject ?? "";
    const subject = subj.startsWith("Re:") ? subj : `Re: ${subj}`;
    const refs = detail.header.messageId ? [detail.header.messageId] : [];
    openCompose({
      to: replyTo ? [replyTo] : [],
      cc,
      subject,
      bodyMd: quoteBody(detail),
      inReplyTo: detail.header.messageId,
      references: refs,
    });
  }

  function handleForward(detail: MessageDetail) {
    const subj = detail.header.subject ?? "";
    const subject = subj.startsWith("Fwd:") ? subj : `Fwd: ${subj}`;
    const intro = `\n\n---------- Forwarded message ----------\nFrom: ${
      detail.header.fromName ?? detail.header.fromAddr ?? ""
    }\nDate: ${new Date(detail.header.dateReceived * 1000).toLocaleString()}\nSubject: ${
      detail.header.subject ?? ""
    }\n\n${detail.plainFallback ?? ""}`;
    openCompose({
      to: [],
      subject,
      bodyMd: intro,
    });
  }

  // Keep the memo subscribed even when not read directly — its
  // side-effect auto-selects the first account on mount.
  void defaultAccountSelector;

  async function handleAccountRemoved(id: string) {
    if (!confirm(`Remove account ${id}? Tokens will be deleted from Keychain.`)) return;
    await invoke("mail_account_remove", { accountId: id });
    if (selectedAccountId() === id) {
      setSelectedAccountId(null);
      setSelectedFolder(null);
      setSelectedUid(null);
    }
    refetchAccounts();
  }

  return (
    <div class={`mail-shell mail-view${sidebarVisible() ? "" : " mail-shell--no-sidebar"}`}>
      {/* Bad-reference banner — shown when an agent-emitted email link
          points at a thread that doesn't exist in mail.db. Auto-clears
          after 6 seconds; clickable X dismisses immediately. */}
      <Show when={badRefToast()}>
        {(t) => (
          <div class="mail-bad-ref-banner">
            <span class="mail-bad-ref-banner__title">Email reference not found</span>
            <span class="mail-bad-ref-banner__detail">
              No message in your mail with thread id{" "}
              <code>{t().threadId}</code>. The agent may have invented
              this reference — try asking it to <em>list_mail</em> or{" "}
              <em>search_mail</em> first.
            </span>
            <button
              type="button"
              onClick={() => setBadRefToast(null)}
              class="mail-bad-ref-banner__close"
            >
              <X size={12} strokeWidth={2.5} />
            </button>
          </div>
        )}
      </Show>
      <Sidebar
        accounts={accounts()}
        folders={folders()}
        selectedAccountId={selectedAccountId()}
        selectedFolder={selectedFolder()}
        unifiedView={unifiedView()}
        syncing={syncing()}
        accountSync={accountSync()}
        nowSecs={tickNow()}
        onSelectUnified={() => {
          setUnifiedView(true);
          setSelectedFolder(null);
          setSelectedUid(null);
          setSearchActive(false);
        }}
        onSelectAccount={(id) => {
          setUnifiedView(false);
          setSelectedAccountId(id);
          setSelectedFolder(null);
          setSelectedUid(null);
          setSearchActive(false);
        }}
        onSelectFolder={(name) => {
          setUnifiedView(false);
          setSelectedFolder(name);
          setSelectedUid(null);
          setSearchActive(false);
          // Lazy-sync this folder if we haven't yet this session.
          // Inbox is already populated by the periodic poll, but
          // Sent / Trash / Archive only sync on first click.
          const acc = selectedAccountId();
          if (acc) handleFolderSync(acc, name);
        }}
        onSync={handleSync}
        onAdd={() => setShowAddModal(true)}
        onRemove={handleAccountRemoved}
      />

      <MessageListPane
        title={
          searchActive()
            ? `Search: ${searchQuery() || "…"}`
            : unifiedView()
              ? "Unified Inbox"
              : selectedFolder()
                ? folderDisplayName(selectedFolder())
                : "Mail"
          }
        messages={messages()}
        loading={messagesResource.loading}
        selectedUid={selectedUid()}
        searchActive={searchActive()}
        searchQuery={searchQuery()}
        onSearchToggle={() => {
          const next = !searchActive();
          setSearchActive(next);
          if (!next) setSearchQuery("");
          else queueMicrotask(() => searchInputRef?.focus());
        }}
        onSearchInput={setSearchQuery}
        searchInputRef={(el) => (searchInputRef = el)}
        onSelect={setSelectedUid}
        canLoadOlder={
          !searchActive() && !unifiedView() && selectedFolder() != null
        }
        loadingOlder={loadingMore()}
        onLoadOlder={handleLoadOlder}
      />

      <ReadingPane
        detail={detail()}
        loading={detailResource.loading}
        threadHeaders={threadResource() ?? []}
        onLoadImagesOnce={handleLoadImagesOnce}
        onAllowImages={handleAllowImages}
        onReply={(d) => handleReply(d, false)}
        onReplyAll={(d) => handleReply(d, true)}
        onForward={handleForward}
        onArchive={handleArchive}
        onDelete={handleDelete}
        onToggleRead={(unread) => handleToggleFlag("\\Seen", unread)}
        onToggleStar={(flagged) => handleToggleFlag("\\Flagged", !flagged)}
        onSelectThreadMessage={(h) => {
          // Switching folder is sometimes required since other thread
          // members may live elsewhere (Sent, Archive, etc.).
          if (h.accountId !== selectedAccountId()) {
            setSelectedAccountId(h.accountId);
          }
          if (h.folder !== selectedFolder()) {
            setSelectedFolder(h.folder);
          }
          setSelectedUid(h.uid);
          setUnifiedView(false);
          setSearchActive(false);
        }}
      />

      <Show when={showAddModal()}>
        <AddAccountModal
          onClose={() => setShowAddModal(false)}
          onAdded={() => {
            setShowAddModal(false);
            refetchAccounts();
          }}
        />
      </Show>

      <Show when={composer()}>
        <ComposerModal
          accounts={accounts()}
          initial={composer() as ComposerInitial}
          onClose={() => setComposer(null)}
          onSent={() => setComposer(null)}
        />
      </Show>

      <Show when={showHelp()}>
        <MailHelpOverlay onClose={() => setShowHelp(false)} />
      </Show>

      <MailToasts />

      {/* Floating "Compose" button — fixed bottom-right.
          Uses .fab-soft for the blur backdrop + soft-3D recipe so it
          matches the Capture FAB elsewhere in the app. */}
      <Show when={accounts().length > 0}>
        <button
          class="fab-soft btn-soft btn-soft--primary"
          onClick={() => openCompose()}
          title="New message (⌘N)"
          style={{ position: "fixed", bottom: "1.5rem", right: "1.5rem", "z-index": 50 }}
        >
          <MailOpen size={13} />
          <span style={{ "margin-left": "0.4rem" }}>Compose</span>
        </button>
      </Show>
    </div>
  );
}

// ── Send / undo toast stack ────────────────────────────────
// Listens to `mail:outbox_update` events from the backend supervisor
// and renders a transient toast per outbox row. The toast shows the
// undo countdown while the row is `queued` and within its window;
// transitions to "Sending…" → "Sent." (auto-dismiss) or "Send
// cancelled." once the outbox state moves on.

type ToastState = {
  id: string;
  state: "queued" | "sending" | "sent" | "cancelled" | "failed" | "leaving";
  subject: string;
  undoUntil: number; // unix-second
  expiresAt: number | null; // unix-millisecond — when to remove
  lastError?: string;
};

function MailToasts() {
  const [toasts, setToasts] = createSignal<Record<string, ToastState>>({});
  const [now, setNow] = createSignal(Date.now());

  // Tick every 250ms for countdowns + expiry sweep.
  let tickHandle: ReturnType<typeof setInterval> | undefined;
  onMount(() => {
    tickHandle = setInterval(() => {
      setNow(Date.now());
      setToasts((prev) => {
        const t = Date.now();
        const next: Record<string, ToastState> = { ...prev };
        for (const [id, toast] of Object.entries(next)) {
          if (toast.expiresAt != null && t >= toast.expiresAt) {
            // Mark leaving for the exit animation, then drop after
            // its 140ms.
            if (toast.state !== "leaving") {
              next[id] = { ...toast, state: "leaving", expiresAt: t + 160 };
            } else {
              delete next[id];
            }
          }
        }
        return next;
      });
    }, 250);
  });
  onCleanup(() => {
    if (tickHandle) clearInterval(tickHandle);
  });

  // Backend events.
  let unlisten: UnlistenFn | undefined;
  onMount(async () => {
    unlisten = await listen<{
      id: string;
      state: string;
      undoUntil?: number;
      subject?: string;
      lastError?: string;
    }>("mail:outbox_update", (evt) => {
      const p = evt.payload;
      setToasts((prev) => {
        const existing = prev[p.id];
        switch (p.state) {
          case "queued":
            return {
              ...prev,
              [p.id]: {
                id: p.id,
                state: "queued",
                subject: p.subject ?? existing?.subject ?? "Message",
                undoUntil: p.undoUntil ?? existing?.undoUntil ?? Math.floor(Date.now() / 1000),
                expiresAt: null,
                lastError: p.lastError,
              },
            };
          case "sending":
            if (!existing) return prev;
            return {
              ...prev,
              [p.id]: { ...existing, state: "sending", expiresAt: null },
            };
          case "sent":
            if (!existing) return prev;
            return {
              ...prev,
              [p.id]: {
                ...existing,
                state: "sent",
                expiresAt: Date.now() + 2200,
              },
            };
          case "cancelled":
            return {
              ...prev,
              [p.id]: {
                id: p.id,
                state: "cancelled",
                subject: existing?.subject ?? "Message",
                undoUntil: existing?.undoUntil ?? 0,
                expiresAt: Date.now() + 1500,
              },
            };
          case "failed":
            return {
              ...prev,
              [p.id]: {
                id: p.id,
                state: "failed",
                subject: existing?.subject ?? "Message",
                undoUntil: existing?.undoUntil ?? 0,
                expiresAt: Date.now() + 8000,
                lastError: p.lastError,
              },
            };
          default:
            return prev;
        }
      });
    });
  });
  onCleanup(() => {
    unlisten?.();
  });

  async function handleUndo(id: string) {
    try {
      await invoke("mail_outbox_undo", { outboxId: id });
    } catch (e) {
      console.warn("[MailApp] undo send failed:", e);
    }
  }

  function summarise(t: ToastState): { title: string; detail: string; cls: string } {
    switch (t.state) {
      case "queued": {
        const remaining = Math.max(0, t.undoUntil - Math.floor(now() / 1000));
        return {
          title: remaining > 0 ? `Sending in ${remaining}s…` : "Sending…",
          detail: t.subject || "Message",
          cls: "",
        };
      }
      case "sending":
        return { title: "Sending…", detail: t.subject || "Message", cls: "" };
      case "sent":
        return { title: "Sent", detail: t.subject || "Message", cls: " mail-toast--success" };
      case "cancelled":
        return { title: "Send cancelled", detail: t.subject || "Message", cls: "" };
      case "failed":
        return {
          title: "Couldn't send",
          detail: t.lastError ?? "SMTP error",
          cls: " mail-toast--error",
        };
      case "leaving":
      default:
        return { title: "", detail: "", cls: "" };
    }
  }

  function progressPct(t: ToastState): number {
    if (t.state !== "queued") return 0;
    const total = t.undoUntil - (t.undoUntil - 10); // length of window in seconds
    const elapsed = Math.max(
      0,
      10 - Math.max(0, t.undoUntil - Math.floor(now() / 1000)),
    );
    if (total <= 0) return 0;
    return Math.min(100, Math.round((elapsed / total) * 100));
  }

  return (
    <div class="mail-toasts">
      <For each={Object.values(toasts())}>
        {(t) => {
          const sum = summarise(t);
          return (
            <div class={`mail-toast${sum.cls}${t.state === "leaving" ? " mail-toast--leaving" : ""}`}>
              <Send size={14} class="mail-toast__icon" />
              <div class="mail-toast__body">
                <span class="mail-toast__title">{sum.title}</span>
                <span class="mail-toast__detail">{sum.detail}</span>
              </div>
              <Show when={t.state === "queued"}>
                <button
                  class="btn-soft btn-soft--sm btn-soft--ghost"
                  onClick={() => handleUndo(t.id)}
                >
                  Undo
                </button>
                <span
                  class="mail-toast__progress"
                  style={{ width: `${progressPct(t)}%` }}
                />
              </Show>
            </div>
          );
        }}
      </For>
    </div>
  );
}

// ── Keyboard help overlay ──────────────────────────────────

const SHORTCUT_GROUPS: { title: string; rows: { keys: string[]; label: string }[] }[] = [
  {
    title: "Navigation",
    rows: [
      { keys: ["j"], label: "Next message" },
      { keys: ["k"], label: "Previous message" },
      { keys: ["g", "i"], label: "Go to Inbox" },
      { keys: ["g", "s"], label: "Go to Sent" },
      { keys: ["g", "d"], label: "Go to Drafts" },
      { keys: ["g", "a"], label: "Go to Archive" },
      { keys: ["g", "t"], label: "Go to Trash" },
    ],
  },
  {
    title: "Compose & reply",
    rows: [
      { keys: ["c"], label: "New message" },
      { keys: ["⌘", "N"], label: "New message" },
      { keys: ["r"], label: "Reply" },
      { keys: ["⇧", "R"], label: "Reply all" },
      { keys: ["f"], label: "Forward" },
      { keys: ["⌘", "↩"], label: "Send (in composer)" },
    ],
  },
  {
    title: "Mailbox actions",
    rows: [
      { keys: ["e"], label: "Archive" },
      { keys: ["#"], label: "Delete" },
      { keys: ["s"], label: "Star / unstar" },
      { keys: ["u"], label: "Toggle read / unread" },
    ],
  },
  {
    title: "View & search",
    rows: [
      { keys: ["/"], label: "Focus search" },
      { keys: ["⌘", "F"], label: "Focus search" },
      { keys: ["?"], label: "Show this help" },
      { keys: ["esc"], label: "Close / cancel" },
    ],
  },
];

function MailHelpOverlay(props: { onClose: () => void }) {
  return (
    <div class="modal-scrim" onClick={props.onClose}>
      <div
        class="modal-card"
        style={{
          margin: "auto",
          padding: "1.1rem 1.3rem 1.2rem",
          width: "36rem",
          "max-width": "92vw",
          "max-height": "82vh",
          "overflow-y": "auto",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <header
          style={{
            display: "flex",
            "align-items": "center",
            "justify-content": "space-between",
            "margin-bottom": "0.85rem",
          }}
        >
          <h2 style={{ "font-size": "1rem", "font-weight": 650, color: "var(--color-text)" }}>
            Keyboard shortcuts
          </h2>
          <button
            class="btn-soft btn-soft--icon-sm btn-soft--ghost"
            onClick={props.onClose}
          >
            <X size={13} />
          </button>
        </header>

        <div
          style={{
            display: "grid",
            "grid-template-columns": "1fr 1fr",
            gap: "1rem 1.2rem",
          }}
        >
          <For each={SHORTCUT_GROUPS}>
            {(group) => (
              <div>
                <div
                  class="section-label"
                  style={{ "margin-bottom": "0.4rem" }}
                >
                  {group.title}
                </div>
                <div style={{ display: "flex", "flex-direction": "column", gap: "0.32rem" }}>
                  <For each={group.rows}>
                    {(row) => (
                      <div
                        style={{
                          display: "flex",
                          "align-items": "center",
                          "justify-content": "space-between",
                          gap: "0.5rem",
                          "font-size": "12px",
                          color: "var(--color-text-muted)",
                        }}
                      >
                        <span>{row.label}</span>
                        <span
                          style={{
                            display: "inline-flex",
                            "align-items": "center",
                            gap: "0.25rem",
                          }}
                        >
                          <For each={row.keys}>
                            {(k, i) => (
                              <>
                                <Show when={i() > 0}>
                                  <span style={{ color: "var(--color-text-subtle)" }}>+</span>
                                </Show>
                                <kbd
                                  style={{
                                    display: "inline-block",
                                    padding: "0.1rem 0.4rem",
                                    "border-radius": "4px",
                                    border: "1px solid var(--color-border-strong)",
                                    background: "var(--color-bg-input)",
                                    "font-family": "var(--font-mono)",
                                    "font-size": "11px",
                                    color: "var(--color-text)",
                                    "min-width": "1.2rem",
                                    "text-align": "center",
                                  }}
                                >
                                  {k}
                                </kbd>
                              </>
                            )}
                          </For>
                        </span>
                      </div>
                    )}
                  </For>
                </div>
              </div>
            )}
          </For>
        </div>

        <p
          style={{
            "margin-top": "1rem",
            "font-size": "11px",
            color: "var(--color-text-subtle)",
            "line-height": "1.5",
          }}
        >
          Sequences like <kbd>g</kbd> <kbd>i</kbd> are entered one key at a time within 1.5
          seconds. Single-key shortcuts are ignored while you're typing in any input.
        </p>
      </div>
    </div>
  );
}

// ── Composer ────────────────────────────────────────────────

type ComposerInitial = {
  accountId: string;
  to: string[];
  cc: string[];
  subject: string;
  bodyMd: string;
  inReplyTo: string | null;
  references: string[];
};

// ── Sidebar ─────────────────────────────────────────────────

type AccountSyncState = {
  syncing: boolean;
  lastOk: number | null;
  lastError: string | null;
};

function relativeAgo(secsAgo: number): string {
  if (secsAgo < 5) return "Just now";
  if (secsAgo < 60) return `${secsAgo}s ago`;
  if (secsAgo < 3600) return `${Math.floor(secsAgo / 60)}m ago`;
  if (secsAgo < 86400) return `${Math.floor(secsAgo / 3600)}h ago`;
  return `${Math.floor(secsAgo / 86400)}d ago`;
}

function Sidebar(props: {
  accounts: Account[];
  folders: Folder[];
  selectedAccountId: string | null;
  selectedFolder: string | null;
  unifiedView: boolean;
  syncing: Record<string, boolean>;
  accountSync: Record<string, AccountSyncState>;
  nowSecs: number;
  onSelectUnified: () => void;
  onSelectAccount: (id: string) => void;
  onSelectFolder: (name: string) => void;
  onSync: (id: string) => void;
  onAdd: () => void;
  onRemove: (id: string) => void;
}) {
  return (
    <aside class="mail-mailboxes">
      <header class="mail-sidebar-header">
        <span class="section-label">Mail</span>
        <button
          class="btn-soft btn-soft--icon-sm"
          title="Add account"
          onClick={props.onAdd}
        >
          <Plus size={13} />
        </button>
      </header>

      <Show when={props.accounts.length > 1}>
        <div
          role="button"
          tabIndex={0}
          class={`mail-unified-row${props.unifiedView ? " mail-unified-row--active" : ""}`}
          onClick={() => props.onSelectUnified()}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              props.onSelectUnified();
            }
          }}
        >
          <Layers size={13} />
          <span class="flex-1 truncate">Unified Inbox</span>
        </div>
      </Show>

      <Show
        when={props.accounts.length > 0}
        fallback={
          <div class="mail-empty-with-icon">
            <Inbox size={36} class="mail-empty-with-icon__icon" />
            <div>No accounts yet.</div>
            <button
              class="btn-soft btn-soft--sm btn-soft--primary"
              onClick={props.onAdd}
            >
              <Plus size={11} />
              <span style={{ "margin-left": "0.3rem" }}>Add account</span>
            </button>
          </div>
        }
      >
        <div class="flex-1 overflow-y-auto">
          <For each={props.accounts}>
            {(acc) => (
              <div>
                {/* Row container is a `<div role="button">`, not a
                    `<button>`, so the nested sync / remove buttons
                    remain valid HTML. The browser would otherwise
                    hoist them out of the outer button at parse time,
                    breaking layout AND Solid's hydration tree. */}
                <div
                  role="button"
                  tabIndex={0}
                  class={`mail-account-row${
                    acc.id === props.selectedAccountId ? " mail-account-row--active" : ""
                  }`}
                  onClick={() => props.onSelectAccount(acc.id)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      props.onSelectAccount(acc.id);
                    }
                  }}
                >
                  <ProviderMark provider={acc.provider} />
                  <div style={{ flex: 1, "min-width": 0, display: "flex", "flex-direction": "column", gap: "0.05rem" }}>
                    <span class="mail-account-row__email">{acc.email}</span>
                    {(() => {
                      const s = props.accountSync[acc.id];
                      if (!s) return null;
                      if (s.lastError) {
                        return (
                          <span
                            title={s.lastError}
                            style={{
                              "font-size": "10.5px",
                              color: "var(--color-danger)",
                              display: "flex",
                              "align-items": "center",
                              gap: "0.3rem",
                            }}
                          >
                            <span
                              style={{
                                width: "0.4rem",
                                height: "0.4rem",
                                "border-radius": "999px",
                                background: "var(--color-danger)",
                                display: "inline-block",
                              }}
                            />
                            Sync failed — click ↻ to retry
                          </span>
                        );
                      }
                      if (s.syncing) {
                        return (
                          <span
                            style={{
                              "font-size": "10.5px",
                              color: "var(--color-text-subtle)",
                            }}
                          >
                            Syncing…
                          </span>
                        );
                      }
                      if (s.lastOk) {
                        return (
                          <span
                            style={{
                              "font-size": "10.5px",
                              color: "var(--color-text-subtle)",
                            }}
                          >
                            {relativeAgo(props.nowSecs - s.lastOk)}
                          </span>
                        );
                      }
                      return null;
                    })()}
                  </div>
                  <span class="mail-account-row__actions">
                    <Show when={props.syncing[acc.id]}>
                      <Loader2 size={11} class="animate-spin mail-account-row__sync-spin" />
                    </Show>
                    <button
                      class="btn-soft btn-soft--icon-sm btn-soft--ghost"
                      title="Sync inbox"
                      onClick={(e) => {
                        e.stopPropagation();
                        props.onSync(acc.id);
                      }}
                    >
                      <RefreshCw size={11} />
                    </button>
                    <button
                      class="btn-soft btn-soft--icon-sm btn-soft--ghost"
                      title="Remove account"
                      onClick={(e) => {
                        e.stopPropagation();
                        props.onRemove(acc.id);
                      }}
                    >
                      <X size={11} />
                    </button>
                  </span>
                </div>

                <Show when={acc.id === props.selectedAccountId}>
                  <For each={props.folders}>
                    {(f) => {
                      const Icon = folderIcon(f.role);
                      return (
                        <div
                          role="button"
                          tabIndex={0}
                          title={f.name}
                          class={`mail-folder-row${
                            f.name === props.selectedFolder ? " mail-folder-row--active" : ""
                          }`}
                          onClick={() => props.onSelectFolder(f.name)}
                          onKeyDown={(e) => {
                            if (e.key === "Enter" || e.key === " ") {
                              e.preventDefault();
                              props.onSelectFolder(f.name);
                            }
                          }}
                        >
                          <Icon size={12} class="mail-folder-row__icon" />
                          <span class="mail-folder-row__name">{folderLabel(f)}</span>
                          <Show when={f.unreadCount > 0}>
                            <span class="mail-folder-row__count">{f.unreadCount}</span>
                          </Show>
                        </div>
                      );
                    }}
                  </For>
                </Show>
              </div>
            )}
          </For>
        </div>
      </Show>
      <ResizeHandle
        cssVar="--mail-sidebar-width"
        storageKey="mail.sidebar.width"
        minPx={160}
        maxPx={360}
      />
    </aside>
  );
}

// ── Message list ────────────────────────────────────────────

function MessageListPane(props: {
  title: string;
  messages: MessageHeader[];
  loading: boolean;
  selectedUid: number | null;
  searchActive: boolean;
  searchQuery: string;
  onSearchToggle: () => void;
  onSearchInput: (value: string) => void;
  searchInputRef: (el: HTMLInputElement) => void;
  onSelect: (uid: number) => void;
  canLoadOlder: boolean;
  loadingOlder: boolean;
  onLoadOlder: () => void;
}) {
  return (
    <section class="mail-messages">
      <header class="mail-messages-header">
        <Show
          when={props.searchActive}
          fallback={
            <>
              <span class="mail-messages-header__title">
                {props.title} · {props.loading ? "…" : `${props.messages.length}`}
              </span>
              <button
                class="btn-soft btn-soft--icon-sm btn-soft--ghost"
                title="Search (⌘F)"
                onClick={() => props.onSearchToggle()}
              >
                <Search size={13} />
              </button>
            </>
          }
        >
          <div class="mail-messages-header__search">
            <Search size={13} style={{ color: "var(--color-text-subtle)" }} />
            <input
              ref={props.searchInputRef}
              value={props.searchQuery}
              onInput={(e) => props.onSearchInput(e.currentTarget.value)}
              placeholder="from:foo subject:invoice has:attachment is:unread"
            />
            <button
              class="btn-soft btn-soft--icon-sm btn-soft--ghost"
              title="Close search (esc)"
              onClick={() => props.onSearchToggle()}
            >
              <X size={13} />
            </button>
          </div>
        </Show>
      </header>
      <div class="flex-1 overflow-y-auto">
        <For
          each={props.messages}
          fallback={
            <div class="mail-empty-with-icon">
              <Inbox size={36} class="mail-empty-with-icon__icon" />
              <div>{props.loading ? "Loading…" : "No messages. Click ↻ on the account to sync."}</div>
            </div>
          }
        >
          {(m) => (
            <div
              role="button"
              tabIndex={0}
              class={`mail-msg-row${m.uid === props.selectedUid ? " mail-msg-row--active" : ""}${m.unread ? " mail-msg-row--unread" : ""}`}
              onClick={() => props.onSelect(m.uid)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  props.onSelect(m.uid);
                }
              }}
            >
              <div class="mail-msg-row__left">
                <Show when={m.unread}>
                  <span class="mail-msg-row__unread-dot" />
                </Show>
              </div>
              <div class="mail-msg-row__main">
                <div class="mail-msg-row__top">
                  <span class="mail-msg-row__sender">{senderLabel(m)}</span>
                  <span class="mail-msg-row__date">{formatDate(m.dateReceived)}</span>
                </div>
                <span class="mail-msg-row__subject truncate">
                  <Show when={m.flagged}>
                    <Star
                      size={10}
                      class="inline-block"
                      style={{
                        "margin-right": "0.25rem",
                        color: "var(--color-warn)",
                        fill: "var(--color-warn)",
                        "vertical-align": "-1px",
                      }}
                    />
                  </Show>
                  {m.subject ?? "(no subject)"}
                </span>
                <Show when={m.snippet}>
                  <span class="mail-msg-row__snippet truncate">{m.snippet}</span>
                </Show>
              </div>
            </div>
          )}
        </For>
        <Show when={props.canLoadOlder && props.messages.length > 0}>
          <button
            class="mail-load-older"
            onClick={props.onLoadOlder}
            disabled={props.loadingOlder}
          >
            <Show
              when={props.loadingOlder}
              fallback={<ChevronDown size={12} />}
            >
              <Loader2 size={12} class="animate-spin" />
            </Show>
            {props.loadingOlder ? "Loading…" : "Load 100 older"}
          </button>
        </Show>
      </div>
      <ResizeHandle
        cssVar="--mail-messages-width"
        storageKey="mail.messages.width"
        minPx={280}
        maxPx={520}
      />
    </section>
  );
}

// ── Reading pane ────────────────────────────────────────────

function ReadingPane(props: {
  detail: MessageDetail | null | undefined;
  loading: boolean;
  threadHeaders: MessageHeader[];
  onLoadImagesOnce: () => void;
  onAllowImages: () => void;
  onReply: (d: MessageDetail) => void;
  onReplyAll: (d: MessageDetail) => void;
  onForward: (d: MessageDetail) => void;
  onArchive: () => void;
  onDelete: () => void;
  onToggleRead: (unread: boolean) => void;
  onToggleStar: (flagged: boolean) => void;
  onSelectThreadMessage: (h: MessageHeader) => void;
}) {
  return (
    <section class="mail-preview">
      <Show
        when={props.detail}
        fallback={
          <div class="mail-empty">
            {props.loading ? "Loading message…" : "Select a message"}
          </div>
        }
      >
        {(detail) => (
          <div class="mail-preview__inner">
            <div class="mail-toolbar">
              <ToolbarButton title="Reply (R)" onClick={() => props.onReply(detail())}>
                <Reply size={13} />
              </ToolbarButton>
              <ToolbarButton title="Reply all (⇧R)" onClick={() => props.onReplyAll(detail())}>
                <ReplyAll size={13} />
              </ToolbarButton>
              <ToolbarButton title="Forward (F)" onClick={() => props.onForward(detail())}>
                <Forward size={13} />
              </ToolbarButton>
              <span class="mail-toolbar__divider" />
              <ToolbarButton
                title={detail().header.flagged ? "Unstar (S)" : "Star (S)"}
                onClick={() => props.onToggleStar(detail().header.flagged)}
              >
                <Star
                  size={13}
                  style={
                    detail().header.flagged
                      ? { fill: "var(--color-warn)", color: "var(--color-warn)" }
                      : undefined
                  }
                />
              </ToolbarButton>
              <ToolbarButton
                title={detail().header.unread ? "Mark read (U)" : "Mark unread (U)"}
                onClick={() => props.onToggleRead(detail().header.unread)}
              >
                <MailOpen size={13} />
              </ToolbarButton>
              <ToolbarButton title="Archive (E)" onClick={props.onArchive}>
                <Archive size={13} />
              </ToolbarButton>
              <ToolbarButton title="Delete (#)" onClick={props.onDelete}>
                <Trash2 size={13} />
              </ToolbarButton>
            </div>

            <header class="mail-preview__header">
              <h2 class="mail-preview__subject">
                {detail().header.subject ?? "(no subject)"}
              </h2>
              <div class="mail-preview__meta">
                <div>
                  <span class="mail-preview__label">from</span>
                  <span>
                    {detail().header.fromName ?? detail().header.fromAddr ?? "(unknown)"}
                    <Show when={detail().header.fromName && detail().header.fromAddr}>
                      <span style={{ color: "var(--color-text-subtle)", "margin-left": "0.4rem" }}>
                        &lt;{detail().header.fromAddr}&gt;
                      </span>
                    </Show>
                  </span>
                </div>
                <div>
                  <span class="mail-preview__label">date</span>
                  <span>{formatDate(detail().header.dateReceived)}</span>
                </div>
                <Show when={detail().to.length > 0}>
                  <div>
                    <span class="mail-preview__label">to</span>
                    <span class="truncate">
                      {detail().to.map((a) => a.name ?? a.addr).join(", ")}
                    </span>
                  </div>
                </Show>
              </div>
              <Show when={detail().cc.length > 0}>
                <details class="mail-meta-detail">
                  <summary>
                    <ChevronDown size={11} />
                    {detail().cc.length} cc
                  </summary>
                  <div style={{ "padding-left": "0.85rem" }}>
                    {detail().cc.map((a) => a.name ?? a.addr).join(", ")}
                  </div>
                </details>
              </Show>
            </header>

            <Show when={detail().hadRemoteImages && !detail().remoteImagesAllowed}>
              <div class="mail-banner-images">
                <EyeOff size={13} class="mail-banner-images__icon" />
                <span class="mail-banner-images__text">
                  Remote images blocked. Trackers can fingerprint you when loaded.
                </span>
                <button
                  class="btn-soft btn-soft--sm btn-soft--ghost"
                  onClick={() => props.onLoadImagesOnce()}
                  title="Load remote images for this message only"
                >
                  <Eye size={11} />
                  <span style={{ "margin-left": "0.35rem" }}>Load once</span>
                </button>
                <button
                  class="btn-soft btn-soft--sm"
                  onClick={() => props.onAllowImages()}
                  title="Allowlist this sender for remote images"
                >
                  <Eye size={11} />
                  <span style={{ "margin-left": "0.35rem" }}>
                    Always load from {detail().header.fromAddr}
                  </span>
                </button>
              </div>
            </Show>

            <MailIframe
              html={detail().html}
              title={detail().header.subject ?? "Message"}
            />

            <Show when={detail().attachments.length > 0}>
              <footer class="mail-attachments">
                <span class="section-label">
                  {detail().attachments.length} attachment{detail().attachments.length === 1 ? "" : "s"}
                </span>
                <div class="mail-attachments__list">
                  <For each={detail().attachments}>
                    {(a) => (
                      <span
                        class="mail-attachments__chip"
                        title={`${a.mime} · ${(a.size / 1024).toFixed(1)} KB`}
                      >
                        {a.filename ?? a.contentId}
                      </span>
                    )}
                  </For>
                </div>
              </footer>
            </Show>

            {/* Thread context: other messages in this conversation,
                listed in chronological order. Hidden when the thread
                has just one message (the current one). */}
            <Show when={props.threadHeaders.filter((h) => h.uid !== detail().header.uid).length > 0}>
              <section class="mail-thread-context">
                <header class="mail-thread-context__header">
                  <span class="section-label">
                    {props.threadHeaders.length} messages in this thread
                  </span>
                </header>
                <div class="mail-thread-context__items">
                  <For
                    each={props.threadHeaders.filter(
                      (h) => h.uid !== detail().header.uid,
                    )}
                  >
                    {(h) => (
                      <div
                        role="button"
                        tabIndex={0}
                        class="mail-thread-row"
                        onClick={() => props.onSelectThreadMessage(h)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter" || e.key === " ") {
                            e.preventDefault();
                            props.onSelectThreadMessage(h);
                          }
                        }}
                        title={`${h.subject ?? "(no subject)"}\n${h.fromName ?? h.fromAddr ?? ""}`}
                      >
                        <span class="mail-thread-row__sender">{senderLabel(h)}</span>
                        <span class="mail-thread-row__snippet">
                          {h.snippet ?? h.subject ?? "(empty)"}
                        </span>
                        <span class="mail-thread-row__date">{formatDate(h.dateReceived)}</span>
                      </div>
                    )}
                  </For>
                </div>
              </section>
            </Show>
          </div>
        )}
      </Show>
    </section>
  );
}

function ToolbarButton(props: {
  title: string;
  onClick: () => void;
  children: any;
}) {
  return (
    <button
      class="btn-soft btn-soft--icon-sm btn-soft--ghost"
      title={props.title}
      onClick={(e) => {
        e.stopPropagation();
        props.onClick();
      }}
    >
      {props.children}
    </button>
  );
}

// ── Auto-sizing sandboxed iframe for HTML message bodies ────
//
// Sets iframe height to the content document's scrollHeight on load
// and watches for changes via ResizeObserver. The outer
// `.mail-preview__inner` is the scroll container; the iframe never
// scrolls itself. Without this, scroll-event capture inside the
// iframe fights with the parent and the user gets stuck inside a
// nested scroll cylinder. The srcdoc is also patched with a final
// defensive stylesheet because email HTML often arrives with fixed
// 600-800px tables that would otherwise explode narrow Clome windows.
function emailFrameSrcdoc(html: string) {
  const viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">";
  const fitCss = `
    <style>
      :root {
        color-scheme: light;
        background: #fff;
      }
      html {
        width: 100% !important;
        min-width: 0 !important;
        overflow-x: hidden !important;
        background: #fff !important;
      }
      body {
        width: 100% !important;
        min-width: 0 !important;
        max-width: 100% !important;
        margin: 0 !important;
        padding: 20px 22px 24px !important;
        overflow-x: hidden !important;
        background: #fff !important;
        color: #202124;
        box-sizing: border-box !important;
      }
      body > center,
      body > div,
      body > table {
        max-width: 100% !important;
      }
      table,
      tbody,
      thead,
      tfoot,
      tr,
      td,
      th {
        max-width: 100% !important;
      }
      table {
        width: auto !important;
      }
      table[width],
      td[width],
      th[width] {
        width: auto !important;
      }
      img,
      picture,
      video,
      canvas,
      svg {
        max-width: 100% !important;
        height: auto !important;
      }
      pre,
      code {
        white-space: pre-wrap !important;
        word-break: break-word !important;
      }
      a {
        overflow-wrap: anywhere;
      }
      @media (max-width: 520px) {
        body {
          padding: 14px 14px 18px !important;
          font-size: 13px !important;
          line-height: 1.5 !important;
        }
      }
    </style>
  `;

  const withViewport = html.includes("name=\"viewport\"")
    ? html
    : html.replace(/<\/head>/i, `${viewport}</head>`);

  if (withViewport.match(/<\/head>/i)) {
    return withViewport.replace(/<\/head>/i, `${fitCss}</head>`);
  }

  return `<!doctype html><html><head>${viewport}${fitCss}</head><body>${withViewport}</body></html>`;
}

function MailIframe(props: { html: string; title: string }) {
  let iframeEl: HTMLIFrameElement | undefined;
  let resizeObserver: ResizeObserver | undefined;
  let detachWheelBridge: (() => void) | undefined;

  function syncHeight() {
    if (!iframeEl?.contentDocument) return;
    const docEl = iframeEl.contentDocument.documentElement;
    const body = iframeEl.contentDocument.body;
    if (!body) return;
    // Add a small fudge factor so descenders / margin-bottom on the
    // last block don't get clipped.
    const h = Math.max(
      body.scrollHeight,
      body.offsetHeight,
      docEl?.scrollHeight ?? 0,
      docEl?.offsetHeight ?? 0,
      80,
    ) + 4;
    iframeEl.style.height = `${h}px`;
  }

  function handleLoad() {
    syncHeight();
    if (!iframeEl?.contentDocument?.body) return;
    detachWheelBridge?.();
    // Tear down any prior observer (re-render swaps the doc).
    resizeObserver?.disconnect();
    resizeObserver = new ResizeObserver(() => syncHeight());
    resizeObserver.observe(iframeEl.contentDocument.body);
    resizeObserver.observe(iframeEl.contentDocument.documentElement);
    resizeObserver.observe(iframeEl);
    // Late image loads can change height after the initial pass —
    // wire a one-shot delayed re-measure.
    setTimeout(syncHeight, 240);
    setTimeout(syncHeight, 800);

    const scrollParent = iframeEl.closest(".mail-preview__inner") as HTMLElement | null;
    const doc = iframeEl.contentDocument;
    if (scrollParent && doc) {
      const onWheel = (event: WheelEvent) => {
        if (scrollParent.scrollHeight <= scrollParent.clientHeight) return;
        event.preventDefault();
        scrollParent.scrollBy({
          top: event.deltaY,
          left: event.deltaX,
          behavior: "auto",
        });
      };
      doc.addEventListener("wheel", onWheel, { passive: false });
      detachWheelBridge = () => doc.removeEventListener("wheel", onWheel);
    }
  }

  onCleanup(() => {
    detachWheelBridge?.();
    resizeObserver?.disconnect();
  });

  return (
    <iframe
      ref={(el) => (iframeEl = el)}
      class="mail-preview__body"
      sandbox="allow-same-origin"
      srcdoc={emailFrameSrcdoc(props.html)}
      title={props.title}
      scrolling="no"
      onLoad={handleLoad}
    />
  );
}

// ── Composer modal ──────────────────────────────────────────

function ComposerModal(props: {
  accounts: Account[];
  initial: ComposerInitial;
  onClose: () => void;
  onSent: () => void;
}) {
  const [accountId, setAccountId] = createSignal(props.initial.accountId);
  const [to, setTo] = createSignal(props.initial.to.join(", "));
  const [cc, setCc] = createSignal(props.initial.cc.join(", "));
  const [bcc, setBcc] = createSignal("");
  const [showCc, setShowCc] = createSignal(props.initial.cc.length > 0);
  const [subject, setSubject] = createSignal(props.initial.subject);
  const [body, setBody] = createSignal(props.initial.bodyMd);
  const [sending, setSending] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  function splitAddrs(s: string): string[] {
    return s
      .split(/[,;\n]/)
      .map((a) => a.trim())
      .filter((a) => a.length > 0);
  }

  async function handleSend() {
    setError(null);
    setSending(true);
    try {
      await invoke("mail_send", {
        args: {
          accountId: accountId(),
          to: splitAddrs(to()),
          cc: splitAddrs(cc()),
          bcc: splitAddrs(bcc()),
          subject: subject(),
          bodyMd: body(),
          inReplyTo: props.initial.inReplyTo,
          references: props.initial.references,
        },
      });
      props.onSent();
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setSending(false);
    }
  }

  // Cmd/Ctrl + Enter sends from anywhere in the modal.
  function onKeyDown(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      if (!sending() && splitAddrs(to()).length > 0) handleSend();
    }
  }

  return (
    <div class="modal-scrim" onKeyDown={onKeyDown}>
      <div class="modal-card mail-compose" style={{ margin: "auto" }}>
        <header class="mail-compose__header">
          <span>New message</span>
          <button
            class="btn-soft btn-soft--icon-sm btn-soft--ghost"
            onClick={props.onClose}
          >
            <X size={13} />
          </button>
        </header>

        <Show when={props.accounts.length > 1}>
          <div class="mail-compose__field">
            <label class="mail-compose__label">From</label>
            <select
              value={accountId()}
              onChange={(e) => setAccountId(e.currentTarget.value)}
            >
              <For each={props.accounts}>
                {(a) => <option value={a.id}>{a.email}</option>}
              </For>
            </select>
          </div>
        </Show>

        <div class="mail-compose__field">
          <label class="mail-compose__label">To</label>
          <input
            type="text"
            placeholder="user@example.com, user2@example.com"
            value={to()}
            onInput={(e) => setTo(e.currentTarget.value)}
          />
        </div>

        <Show when={showCc()} fallback={
          <button
            class="mail-compose__add-cc"
            onClick={() => setShowCc(true)}
          >
            + Add Cc / Bcc
          </button>
        }>
          <div class="mail-compose__field">
            <label class="mail-compose__label">Cc</label>
            <input
              type="text"
              value={cc()}
              onInput={(e) => setCc(e.currentTarget.value)}
            />
          </div>
          <div class="mail-compose__field">
            <label class="mail-compose__label">Bcc</label>
            <input
              type="text"
              value={bcc()}
              onInput={(e) => setBcc(e.currentTarget.value)}
            />
          </div>
        </Show>

        <div class="mail-compose__field">
          <label class="mail-compose__label">Subject</label>
          <input
            type="text"
            value={subject()}
            onInput={(e) => setSubject(e.currentTarget.value)}
          />
        </div>

        <textarea
          class="mail-compose__body"
          placeholder="Write in markdown — it renders to HTML on send. Recipients receive both a plain-text and HTML alternative. ⌘↩ to send."
          value={body()}
          onInput={(e) => setBody(e.currentTarget.value)}
        />

        <Show when={error()}>
          <div class="mail-compose__error">{error()}</div>
        </Show>

        <footer class="mail-compose__footer">
          <span class="mail-compose__hint">
            <Show when={props.initial.inReplyTo} fallback={<span>⌘↩ to send</span>}>
              Reply · threaded · ⌘↩ to send
            </Show>
          </span>
          <div class="flex items-center gap-2">
            <button
              class="btn-soft btn-soft--sm btn-soft--ghost"
              onClick={props.onClose}
              disabled={sending()}
            >
              Discard
            </button>
            <button
              class="btn-soft btn-soft--sm btn-soft--primary"
              onClick={handleSend}
              disabled={sending() || splitAddrs(to()).length === 0}
            >
              <Show when={sending()} fallback={<Send size={12} />}>
                <Loader2 size={12} class="animate-spin" />
              </Show>
              <span style={{ "margin-left": "0.35rem" }}>{sending() ? "Sending…" : "Send"}</span>
            </button>
          </div>
        </footer>
      </div>
    </div>
  );
}

// ── Add-account modal ───────────────────────────────────────

function AddAccountModal(props: { onClose: () => void; onAdded: (acc: Account) => void }) {
  const [email, setEmail] = createSignal("");
  const [step, setStep] = createSignal<"email" | "resolving" | "auth" | "error">("email");
  const [error, setError] = createSignal<string | null>(null);
  const [autoconfig, setAutoconfig] = createSignal<AutoconfigResult | null>(null);
  const [pendingState, setPendingState] = createSignal<string | null>(null);

  async function handleNext() {
    setError(null);
    setStep("resolving");
    try {
      const result = await invoke<AutoconfigResult>("mail_autoconfig", { email: email() });
      setAutoconfig(result);
      if (!result.oauth) {
        setError(
          `${result.provider} doesn't support OAuth in v1 — use an app-specific password (manual setup landing in a later phase).`,
        );
        setStep("error");
        return;
      }
      const start = await invoke<OAuthStartResult>("mail_oauth_start", { autoconfig: result });
      setPendingState(start.state);
      setStep("auth");
    } catch (e: unknown) {
      setError(String(e));
      setStep("error");
    }
  }

  async function handleComplete() {
    const state = pendingState();
    const ac = autoconfig();
    if (!state || !ac) return;
    try {
      const acc = await invoke<Account>("mail_oauth_complete", {
        args: { state, autoconfig: ac },
      });
      props.onAdded(acc);
    } catch (e: unknown) {
      setError(String(e));
      setStep("error");
    }
  }

  return (
    <div class="modal-scrim">
      <div class="modal-card mail-account-modal" style={{ margin: "auto" }}>
        <header class="mail-account-modal__header">
          <h2 class="mail-account-modal__title">Add mail account</h2>
          <button
            class="btn-soft btn-soft--icon-sm btn-soft--ghost"
            onClick={props.onClose}
          >
            <X size={13} />
          </button>
        </header>

        <Show when={step() === "email"}>
          <label class="input-pill" style={{ display: "block" }}>
            <input
              type="email"
              autofocus
              value={email()}
              onInput={(e) => setEmail(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && handleNext()}
              placeholder="you@gmail.com"
              style={{ width: "100%", "background": "transparent", "border": "none", "outline": "none", "font-size": "13px", "color": "var(--color-text)", "font-family": "var(--font-sans)" }}
            />
          </label>
          <p class="mail-account-modal__hint">
            We'll resolve your provider, hand you off to the browser for sign-in, and store
            the OAuth token in macOS Keychain.
          </p>
          <div class="mail-account-modal__row">
            <button class="btn-soft btn-soft--sm btn-soft--ghost" onClick={props.onClose}>
              Cancel
            </button>
            <button
              class="btn-soft btn-soft--sm btn-soft--primary"
              onClick={handleNext}
              disabled={!email().includes("@")}
            >
              Continue
            </button>
          </div>
        </Show>

        <Show when={step() === "resolving"}>
          <div style={{ display: "flex", "align-items": "center", gap: "0.5rem", "font-size": "13px", color: "var(--color-text-muted)" }}>
            <Loader2 size={13} class="animate-spin" /> Resolving provider…
          </div>
        </Show>

        <Show when={step() === "auth"}>
          <p style={{ "font-size": "13px", color: "var(--color-text)", "line-height": "1.5" }}>
            A browser window has opened for {autoconfig()?.email}. Complete sign-in there, then
            click "I'm signed in" below.
          </p>
          <p class="mail-account-modal__hint">
            Provider: <strong>{autoconfig()?.provider}</strong> · IMAP{" "}
            {autoconfig()?.imap.host}:{autoconfig()?.imap.port}
          </p>
          <div class="mail-account-modal__row">
            <button class="btn-soft btn-soft--sm btn-soft--ghost" onClick={props.onClose}>
              Cancel
            </button>
            <button class="btn-soft btn-soft--sm btn-soft--primary" onClick={handleComplete}>
              I'm signed in
            </button>
          </div>
        </Show>

        <Show when={step() === "error"}>
          <p class="mail-account-modal__error">{error()}</p>
          <div class="mail-account-modal__row">
            <button
              class="btn-soft btn-soft--sm btn-soft--primary"
              onClick={() => setStep("email")}
            >
              Try again
            </button>
          </div>
        </Show>
      </div>
    </div>
  );
}
