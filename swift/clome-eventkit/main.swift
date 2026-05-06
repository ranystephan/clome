// clome-eventkit — Tauri sidecar for macOS Calendar + Reminders.
//
// Why a Swift sidecar instead of JXA via osascript?
// JXA goes through the AppleEvents TCC bucket, which on signed Tauri
// dev binaries is a permanent dead end: macOS won't show the prompt
// (no Info.plist NSAppleEventsUsageDescription on the bare dev binary),
// and even when injected post-build the re-sign sometimes invalidates
// the grant. EventKit uses its own TCC buckets (NSCalendarsUsageDescription,
// NSRemindersUsageDescription) which the parent .app already declares,
// and prompts reliably.
//
// CLI shape (subcommand + JSON arg):
//   clome-eventkit list-events     '{"from":"<iso>","to":"<iso>"}'
//   clome-eventkit create-event    '{"title":"...","start":"<iso>","end":"<iso>","calendar":"...","location":"...","notes":"..."}'
//   clome-eventkit delete-event    '{"id":"<event-id>"}' or '{"title":"...","on":"<iso-date>"}'
//   clome-eventkit list-reminders  '{"include_completed":false}'
//   clome-eventkit create-reminder '{"title":"...","due":"<iso>","list":"...","notes":"..."}'
//
// Output:
//   stdout = JSON (array for list-*, object for create-*)
//   stderr = nothing on success; debug-only on hard failure
//   exit 0 on success, 1 on TCC denial / save failure, 2 on usage error.
//
// Errors are emitted as `{"error": "..."}` on stdout AND a non-zero
// exit code, so the Rust caller can detect both.

import Foundation
import EventKit

// ─── helpers ───────────────────────────────────────────────────────

func emitJSON(_ obj: Any) {
    if JSONSerialization.isValidJSONObject(obj),
       let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{\"error\":\"failed to serialize result\"}")
    }
}

func emitError(_ msg: String) {
    emitJSON(["error": msg])
}

func parseDate(_ s: String) -> Date? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: trimmed) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: trimmed) { return d }
    // Local-time fallback (no timezone): "2026-05-01T15:00:00"
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    return df.date(from: trimmed)
}

/// Format a Date as ISO 8601 *in the user's local timezone* with the
/// offset baked in (e.g. `2026-05-03T05:00:00-07:00`). The default
/// ISO8601DateFormatter writes UTC with a `Z` suffix, which causes
/// the model to read `12:00:00Z` as "12 PM" instead of "12 PM UTC =
/// 5 AM local" — every wall-clock answer ends up off by the offset.
func formatISO(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f.string(from: d)
}

func parseInputJSON(_ raw: String?) -> [String: Any] {
    guard let raw = raw, !raw.isEmpty else { return [:] }
    guard let data = raw.data(using: .utf8) else { return [:] }
    do {
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return [:]
    } catch {
        emitError("invalid JSON arg: \(error.localizedDescription)")
        exit(2)
    }
}

// ─── access requests ───────────────────────────────────────────────

let store = EKEventStore()

func requestEventAccess() -> (granted: Bool, error: String?) {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    var errMsg: String?
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { granted, err in
            ok = granted
            errMsg = err?.localizedDescription
            sem.signal()
        }
    } else {
        store.requestAccess(to: .event) { granted, err in
            ok = granted
            errMsg = err?.localizedDescription
            sem.signal()
        }
    }
    sem.wait()
    return (ok, errMsg)
}

func requestReminderAccess() -> (granted: Bool, error: String?) {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    var errMsg: String?
    if #available(macOS 14.0, *) {
        store.requestFullAccessToReminders { granted, err in
            ok = granted
            errMsg = err?.localizedDescription
            sem.signal()
        }
    } else {
        store.requestAccess(to: .reminder) { granted, err in
            ok = granted
            errMsg = err?.localizedDescription
            sem.signal()
        }
    }
    sem.wait()
    return (ok, errMsg)
}

// ─── subcommands ───────────────────────────────────────────────────

func cmdListEvents(_ input: [String: Any]) {
    let (ok, err) = requestEventAccess()
    if !ok {
        emitError(err.map { "calendar access denied: \($0)" } ?? "calendar access denied")
        exit(1)
    }
    let now = Date()
    let from = (input["from"] as? String).flatMap(parseDate) ?? now
    let to = (input["to"] as? String).flatMap(parseDate) ?? now.addingTimeInterval(7 * 86400)

    let calendars = store.calendars(for: .event)
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    let events = store.events(matching: predicate)
    let out: [[String: Any]] = events.prefix(100).map { e -> [String: Any] in
        return [
            "id": e.eventIdentifier ?? "",
            "title": e.title ?? "",
            "start": formatISO(e.startDate),
            "end": formatISO(e.endDate),
            "location": e.location ?? "",
            "calendar": e.calendar?.title ?? "",
        ]
    }
    emitJSON(out)
}

func cmdDeleteEvent(_ input: [String: Any]) {
    let (ok, err) = requestEventAccess()
    if !ok {
        emitError(err.map { "calendar access denied: \($0)" } ?? "calendar access denied")
        exit(1)
    }
    // Two paths: by stable EKEvent.eventIdentifier (preferred — the id
    // is what list-events returns), or fuzzy match by title + day.
    var target: EKEvent?
    if let id = input["id"] as? String, !id.isEmpty {
        target = store.event(withIdentifier: id)
    } else if let title = input["title"] as? String, !title.isEmpty {
        let cal = Calendar.current
        let day: Date
        if let onStr = input["on"] as? String, let d = parseDate(onStr) {
            day = d
        } else {
            day = Date()
        }
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? day
        let pred = store.predicateForEvents(
            withStart: dayStart, end: dayEnd,
            calendars: store.calendars(for: .event)
        )
        target = store.events(matching: pred).first { $0.title == title }
    }
    guard let event = target else {
        emitError("event not found")
        exit(1)
    }
    do {
        try store.remove(event, span: .thisEvent, commit: true)
        emitJSON(["ok": true])
    } catch {
        emitError("delete failed: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdCreateEvent(_ input: [String: Any]) {
    let (ok, err) = requestEventAccess()
    if !ok {
        emitError(err.map { "calendar access denied: \($0)" } ?? "calendar access denied")
        exit(1)
    }
    guard let title = input["title"] as? String, !title.isEmpty else {
        emitError("missing title"); exit(2)
    }
    guard let startStr = input["start"] as? String, let start = parseDate(startStr) else {
        emitError("missing or invalid start (need ISO 8601)"); exit(2)
    }
    guard let endStr = input["end"] as? String, let end = parseDate(endStr) else {
        emitError("missing or invalid end (need ISO 8601)"); exit(2)
    }

    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = start
    event.endDate = end
    if let loc = input["location"] as? String, !loc.isEmpty { event.location = loc }
    if let notes = input["notes"] as? String, !notes.isEmpty { event.notes = notes }

    if let calName = input["calendar"] as? String,
       !calName.isEmpty,
       let cal = store.calendars(for: .event).first(where: { $0.title == calName }) {
        event.calendar = cal
    } else if let cal = store.defaultCalendarForNewEvents {
        event.calendar = cal
    } else {
        emitError("no default calendar found"); exit(1)
    }

    do {
        try store.save(event, span: .thisEvent, commit: true)
        emitJSON(["ok": true, "id": event.eventIdentifier ?? ""])
    } catch {
        emitError("save failed: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdListReminders(_ input: [String: Any]) {
    let (ok, err) = requestReminderAccess()
    if !ok {
        emitError(err.map { "reminders access denied: \($0)" } ?? "reminders access denied")
        exit(1)
    }
    let includeCompleted = input["include_completed"] as? Bool ?? false
    let predicate: NSPredicate = includeCompleted
        ? store.predicateForReminders(in: nil)
        : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)

    let sem = DispatchSemaphore(value: 0)
    var rems: [EKReminder] = []
    store.fetchReminders(matching: predicate) { result in
        rems = result ?? []
        sem.signal()
    }
    sem.wait()

    let cal = Calendar.current
    let out: [[String: Any]] = rems.prefix(100).map { r -> [String: Any] in
        var due: Any = NSNull()
        if let comps = r.dueDateComponents, let d = cal.date(from: comps) {
            due = formatISO(d)
        }
        return [
            "title": r.title ?? "",
            "due": due,
            "list": r.calendar?.title ?? "",
            "completed": r.isCompleted,
        ]
    }
    emitJSON(out)
}

func cmdCreateReminder(_ input: [String: Any]) {
    let (ok, err) = requestReminderAccess()
    if !ok {
        emitError(err.map { "reminders access denied: \($0)" } ?? "reminders access denied")
        exit(1)
    }
    guard let title = input["title"] as? String, !title.isEmpty else {
        emitError("missing title"); exit(2)
    }
    let r = EKReminder(eventStore: store)
    r.title = title
    if let notes = input["notes"] as? String, !notes.isEmpty { r.notes = notes }
    if let dueStr = input["due"] as? String, let due = parseDate(dueStr) {
        r.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due
        )
    }
    if let listName = input["list"] as? String,
       !listName.isEmpty,
       let cal = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
        r.calendar = cal
    } else if let cal = store.defaultCalendarForNewReminders() {
        r.calendar = cal
    } else {
        emitError("no default reminder list found"); exit(1)
    }
    do {
        try store.save(r, commit: true)
        emitJSON(["ok": true])
    } catch {
        emitError("save failed: \(error.localizedDescription)")
        exit(1)
    }
}

// ─── dispatch ──────────────────────────────────────────────────────

let args = CommandLine.arguments
if args.count < 2 {
    emitError("usage: clome-eventkit <list-events|create-event|delete-event|list-reminders|create-reminder> [<json>]")
    exit(2)
}

let cmd = args[1]
let inputJSON = args.count >= 3 ? args[2] : nil
let input = parseInputJSON(inputJSON)

switch cmd {
case "list-events":     cmdListEvents(input)
case "create-event":    cmdCreateEvent(input)
case "delete-event":    cmdDeleteEvent(input)
case "list-reminders":  cmdListReminders(input)
case "create-reminder": cmdCreateReminder(input)
default:
    emitError("unknown subcommand: \(cmd)")
    exit(2)
}
