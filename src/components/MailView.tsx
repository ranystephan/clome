import {
  createMemo,
  createResource,
  createSignal,
  For,
  Show,
} from "solid-js";
import { invoke } from "@tauri-apps/api/core";
import { Inbox, Mail as MailIcon, Star } from "lucide-solid";

type Mailbox = {
  id: number;
  url: string;
  displayName: string;
  unreadCount: number;
  totalCount: number;
};

type MailMessage = {
  id: number;
  subject: string;
  sender: string;
  snippet: string;
  dateReceived: number;
  mailboxId: number;
  read: boolean;
  flagged: boolean;
};

type MailBody = {
  id: number;
  subject: string;
  from: string;
  to: string;
  cc: string | null;
  date: string;
  html: string;
  plain: string;
};

// Mail.app uses Cocoa epoch for dateReceived: seconds since
// 2001-01-01. Convert to JS Date.
const COCOA_EPOCH_OFFSET_SECONDS = 978_307_200;
function cocoaToDate(seconds: number) {
  return new Date((seconds + COCOA_EPOCH_OFFSET_SECONDS) * 1000);
}

function formatDate(seconds: number) {
  const d = cocoaToDate(seconds);
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  if (sameDay) {
    return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }
  const sameYear = d.getFullYear() === now.getFullYear();
  if (sameYear) {
    return d.toLocaleDateString([], { month: "short", day: "numeric" });
  }
  return d.toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
}

function senderName(s: string) {
  // Mail's `addresses.address || ' (' || comment || ')'` form. Strip
  // the parenthesized comment for the list view; prefer comment over
  // address when comment looks like a real name.
  const m = s.match(/^(.*?)\s*\((.+)\)$/);
  if (m) {
    const name = m[2].trim();
    if (name.length > 0) return name;
  }
  return s;
}

export default function MailView() {
  const [selectedMailboxId, setSelectedMailboxId] = createSignal<number | null>(null);
  const [selectedMessageId, setSelectedMessageId] = createSignal<number | null>(null);

  const [mailboxes] = createResource<Mailbox[]>(async () => {
    try {
      return await invoke<Mailbox[]>("mail_list_mailboxes");
    } catch (e) {
      console.error("mail_list_mailboxes:", e);
      return [];
    }
  });

  // Group mailboxes by likely-INBOX vs everything else. Mail.app's
  // url scheme puts the human folder at the tail; we use that to
  // show inboxes prominently.
  const groupedMailboxes = createMemo(() => {
    const list = mailboxes() ?? [];
    const inboxes: Mailbox[] = [];
    const others: Mailbox[] = [];
    for (const mb of list) {
      const tail = mb.displayName.toUpperCase();
      if (tail === "INBOX" || tail === "INBOX_UNREAD") {
        inboxes.push(mb);
      } else {
        others.push(mb);
      }
    }
    return { inboxes, others };
  });

  // Auto-select first inbox when mailboxes arrive.
  const initSelection = createMemo(() => {
    if (selectedMailboxId() !== null) return null;
    const firstInbox = groupedMailboxes().inboxes[0];
    if (firstInbox) {
      setSelectedMailboxId(firstInbox.id);
    }
    return null;
  });
  void initSelection;

  const [messages] = createResource(
    () => selectedMailboxId(),
    async (mailboxId): Promise<MailMessage[]> => {
      if (mailboxId === null) return [];
      try {
        return await invoke<MailMessage[]>("mail_list_messages", {
          mailboxId,
          limit: 200,
        });
      } catch (e) {
        console.error("mail_list_messages:", e);
        return [];
      }
    },
  );

  const [body] = createResource(
    () => selectedMessageId(),
    async (messageId): Promise<MailBody | null> => {
      if (messageId === null) return null;
      try {
        return await invoke<MailBody>("mail_get_body", { messageId });
      } catch (e) {
        console.error("mail_get_body:", e);
        return null;
      }
    },
  );

  return (
    <div class="mail-view flex h-full min-h-0 w-full">
      {/* Mailbox column */}
      <aside class="mail-mailboxes">
        <div class="mail-mailboxes__header">
          <MailIcon size={13} strokeWidth={2.2} />
          <span>Mail</span>
        </div>
        <Show
          when={(mailboxes() ?? []).length > 0}
          fallback={
            <div class="mail-empty">
              <Show when={mailboxes.loading} fallback={<span>No mailboxes found. Open Mail.app once to set up an account.</span>}>
                <span>Loading…</span>
              </Show>
            </div>
          }
        >
          <Show when={groupedMailboxes().inboxes.length > 0}>
            <div class="mail-mailboxes__section">Inboxes</div>
            <For each={groupedMailboxes().inboxes}>
              {(mb) => (
                <button
                  type="button"
                  class="mail-mailbox-row"
                  classList={{ "mail-mailbox-row--active": selectedMailboxId() === mb.id }}
                  onClick={() => {
                    setSelectedMailboxId(mb.id);
                    setSelectedMessageId(null);
                  }}
                >
                  <Inbox size={12} strokeWidth={2} />
                  <span class="truncate flex-1 text-left">{mb.displayName}</span>
                  <Show when={mb.unreadCount > 0}>
                    <span class="mail-mailbox-row__badge">{mb.unreadCount}</span>
                  </Show>
                </button>
              )}
            </For>
          </Show>
          <Show when={groupedMailboxes().others.length > 0}>
            <div class="mail-mailboxes__section">Folders</div>
            <For each={groupedMailboxes().others}>
              {(mb) => (
                <button
                  type="button"
                  class="mail-mailbox-row"
                  classList={{ "mail-mailbox-row--active": selectedMailboxId() === mb.id }}
                  onClick={() => {
                    setSelectedMailboxId(mb.id);
                    setSelectedMessageId(null);
                  }}
                >
                  <span class="mail-mailbox-row__dot" />
                  <span class="truncate flex-1 text-left">{mb.displayName}</span>
                  <Show when={mb.totalCount > 0}>
                    <span class="mail-mailbox-row__count">{mb.totalCount}</span>
                  </Show>
                </button>
              )}
            </For>
          </Show>
        </Show>
      </aside>

      {/* Message list column */}
      <section class="mail-messages">
        <Show
          when={(messages() ?? []).length > 0}
          fallback={
            <div class="mail-empty">
              <Show when={messages.loading} fallback={<span>Empty mailbox.</span>}>
                <span>Loading messages…</span>
              </Show>
            </div>
          }
        >
          <For each={messages()}>
            {(msg) => (
              <button
                type="button"
                class="mail-msg-row"
                classList={{
                  "mail-msg-row--active": selectedMessageId() === msg.id,
                  "mail-msg-row--unread": !msg.read,
                }}
                onClick={() => setSelectedMessageId(msg.id)}
              >
                <div class="mail-msg-row__left">
                  <Show when={!msg.read}>
                    <span class="mail-msg-row__unread-dot" />
                  </Show>
                </div>
                <div class="mail-msg-row__main">
                  <div class="mail-msg-row__top">
                    <span class="mail-msg-row__sender truncate">
                      {senderName(msg.sender)}
                    </span>
                    <span class="mail-msg-row__date">{formatDate(msg.dateReceived)}</span>
                  </div>
                  <div class="mail-msg-row__subject truncate">
                    <Show when={msg.flagged}>
                      <Star size={10} strokeWidth={2.2} class="mr-1 inline-block text-warn" />
                    </Show>
                    {msg.subject || "(no subject)"}
                  </div>
                  <div class="mail-msg-row__snippet truncate">{msg.snippet}</div>
                </div>
              </button>
            )}
          </For>
        </Show>
      </section>

      {/* Preview pane */}
      <section class="mail-preview">
        <Show
          when={body()}
          fallback={
            <div class="mail-empty">
              <Show when={body.loading} fallback={<span>Select a message.</span>}>
                <span>Loading…</span>
              </Show>
            </div>
          }
        >
          {(b) => (
            <div class="mail-preview__inner">
              <header class="mail-preview__header">
                <h2 class="mail-preview__subject">{b().subject || "(no subject)"}</h2>
                <div class="mail-preview__meta">
                  <div>
                    <span class="mail-preview__label">From</span>
                    <span class="truncate">{b().from}</span>
                  </div>
                  <div>
                    <span class="mail-preview__label">To</span>
                    <span class="truncate">{b().to}</span>
                  </div>
                  <Show when={b().cc}>
                    <div>
                      <span class="mail-preview__label">Cc</span>
                      <span class="truncate">{b().cc}</span>
                    </div>
                  </Show>
                  <div>
                    <span class="mail-preview__label">Date</span>
                    <span>{b().date}</span>
                  </div>
                </div>
              </header>
              {/* Sandbox iframe — emails are arbitrary HTML, we don't
                  let them run scripts or load top-level navigation. */}
              <iframe
                class="mail-preview__body"
                sandbox=""
                srcdoc={b().html}
                title={b().subject}
              />
            </div>
          )}
        </Show>
      </section>
    </div>
  );
}
