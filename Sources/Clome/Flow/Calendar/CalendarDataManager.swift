import SwiftUI
import EventKit
import Combine
import ClomeModels

// MARK: - Calendar View Mode

enum CalendarViewMode: String, CaseIterable {
    case day
    case week
    case month
}

// MARK: - Calendar Data Manager

@MainActor
final class CalendarDataManager: ObservableObject {

    // MARK: - Singleton

    static let shared = CalendarDataManager()

    // MARK: - Published State

    @Published var items: [any CalendarItemProtocol] = []
    @Published var selectedDate: Date = Date()
    @Published var viewMode: CalendarViewMode = .day
    @Published private(set) var hasCalendarAccess = false
    @Published private(set) var hasReminderAccess = false

    // MARK: - Private

    private let store = EKEventStore()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        // Initialize access status via backing storage to avoid publishing during init
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        _hasCalendarAccess = Published(initialValue: eventStatus == .fullAccess || eventStatus == .authorized)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        _hasReminderAccess = Published(initialValue: reminderStatus == .fullAccess || reminderStatus == .authorized)
        observeChanges()
    }

    // MARK: - Access

    /// Checks current authorization status for calendar events and reminders.
    func checkAccess() {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        hasCalendarAccess = (eventStatus == .fullAccess || eventStatus == .authorized)

        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        hasReminderAccess = (reminderStatus == .fullAccess || reminderStatus == .authorized)
    }

    /// Requests calendar (event) access using the completion-handler API.
    /// The async requestFullAccessToEvents causes XPC invalidation on macOS debug builds.
    func requestCalendarAccess() {
        store.requestAccess(to: .event) { [weak self] granted, error in
            if let error {
                NSLog("[CalendarData] Calendar access error: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                self?.hasCalendarAccess = granted
                if granted { self?.refresh() }
            }
        }
    }

    /// Requests reminder access using the completion-handler API.
    func requestReminderAccess() {
        store.requestAccess(to: .reminder) { [weak self] granted, error in
            if let error {
                NSLog("[CalendarData] Reminder access error: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                self?.hasReminderAccess = granted
                if granted { self?.refresh() }
            }
        }
    }

    // MARK: - Refresh

    /// Main refresh method. Computes date range from viewMode + selectedDate,
    /// fetches all sources, and publishes unified items array.
    func refresh() {
        let calendar = Calendar.current
        let (rangeStart, rangeEnd) = dateRange(for: viewMode, around: selectedDate, calendar: calendar)

        var collected: [any CalendarItemProtocol] = []

        // System events
        if hasCalendarAccess {
            let events = fetchSystemEvents(from: rangeStart, to: rangeEnd)
            collected.append(contentsOf: events)
        }

        // Reminders (async fetch, will update items when complete)
        if hasReminderAccess {
            fetchReminders(from: rangeStart, to: rangeEnd)
        }

        // Scheduled todos from FlowSyncService
        let todos = FlowSyncService.shared.todos
        for todo in todos {
            guard todo.scheduledDate != nil else { continue }
            let item = ScheduledTodoItem(todo: todo)
            if item.startDate <= rangeEnd && item.endDate >= rangeStart {
                collected.append(item)
            }
        }

        // Deadlines from FlowSyncService
        let deadlines = FlowSyncService.shared.deadlines
        for deadline in deadlines {
            if deadline.dueDate >= rangeStart && deadline.dueDate <= rangeEnd {
                collected.append(DeadlineCalendarItem(deadline: deadline))
            }
        }

        items = collected
    }

    // MARK: - Date Range Computation

    private func dateRange(for mode: CalendarViewMode, around date: Date, calendar: Calendar) -> (Date, Date) {
        switch mode {
        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            return (start, end)

        case .week:
            // Sunday-based week
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            components.weekday = 1 // Sunday
            let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 7, to: start)!.addingTimeInterval(-1)
            return (start, end)

        case .month:
            // First day of month
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
            // First visible day in month grid (could be previous month's Sunday)
            let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
            let gridStart = calendar.date(byAdding: .day, value: -(weekdayOfFirst - 1), to: monthStart)!
            // Last day of month
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
            // Last visible day in month grid (fill out to Saturday)
            let weekdayOfLast = calendar.component(.weekday, from: monthEnd)
            let gridEnd = calendar.date(byAdding: .day, value: (7 - weekdayOfLast), to: monthEnd)!
            let end = calendar.date(byAdding: .day, value: 1, to: gridEnd)!.addingTimeInterval(-1)
            return (gridStart, end)
        }
    }

    // MARK: - Fetch System Events

    /// Fetches EKEvents in the given range. Extracts data into SystemEventItem
    /// structs — does NOT retain EKEvent references.
    private func fetchSystemEvents(from start: Date, to end: Date) -> [SystemEventItem] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = store.events(matching: predicate)

        return ekEvents.map { event in
            let cgColor = event.calendar.cgColor ?? CGColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1.0)
            let color = Color(cgColor: cgColor)
            let isClome = event.notes?.contains("[clome") ?? false

            return SystemEventItem(
                calendarItemID: "event-\(event.eventIdentifier ?? UUID().uuidString)",
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarColor: color,
                eventIdentifier: event.eventIdentifier ?? "",
                isClomeCreated: isClome,
                location: event.location,
                notes: event.notes,
                calendarName: event.calendar.title,
                hasRecurrence: event.hasRecurrenceRules,
                hasAlarms: event.hasAlarms
            )
        }
    }

    // MARK: - Fetch Reminders

    /// Fetches EKReminders in the given range asynchronously.
    /// Merges results into the items array on completion.
    private func fetchReminders(from start: Date, to end: Date) {
        let predicate = store.predicateForReminders(in: nil)
        let calendar = Calendar.current

        store.fetchReminders(matching: predicate) { [weak self] reminders in
            guard let reminders else { return }

            let reminderItems: [ReminderCalendarItem] = reminders.compactMap { reminder in
                guard let dueDateComponents = reminder.dueDateComponents,
                      let dueDate = calendar.date(from: dueDateComponents),
                      dueDate >= start && dueDate <= end
                else { return nil }

                return ReminderCalendarItem(
                    calendarItemID: "reminder-\(reminder.calendarItemIdentifier)",
                    title: reminder.title ?? "Untitled Reminder",
                    dueDate: dueDate,
                    isCompleted: reminder.isCompleted,
                    reminderIdentifier: reminder.calendarItemIdentifier
                )
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Merge reminders into existing items (remove old reminders first)
                var current = self.items.filter { $0.kind != .reminder }
                current.append(contentsOf: reminderItems)
                self.items = current
            }
        }
    }

    // MARK: - Create Event

    /// Creates a new calendar event with Clome metadata.
    func createSystemEvent(title: String, start: Date, end: Date, calendarIdentifier: String? = nil) {
        guard hasCalendarAccess else {
            NSLog("[CalendarData] No calendar access — cannot create event")
            return
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = "[clome:user]"

        if let identifier = calendarIdentifier,
           let calendar = store.calendar(withIdentifier: identifier) {
            event.calendar = calendar
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        do {
            try store.save(event, span: .thisEvent)
            NSLog("[CalendarData] Created event: \(title)")
            refresh()
        } catch {
            NSLog("[CalendarData] Failed to save event: \(error.localizedDescription)")
        }
    }

    // MARK: - Move Event

    /// Moves an existing system event to a new time, preserving duration.
    func moveSystemEvent(identifier: String, newStart: Date, newEnd: Date) {
        guard hasCalendarAccess else { return }
        guard let event = store.event(withIdentifier: identifier) else {
            NSLog("[CalendarData] Event not found: \(identifier)")
            return
        }
        event.startDate = newStart
        event.endDate = newEnd
        do {
            try store.save(event, span: .thisEvent)
            NSLog("[CalendarData] Moved event: \(event.title ?? "")")
            refresh()
        } catch {
            NSLog("[CalendarData] Failed to move event: \(error.localizedDescription)")
        }
    }

    // MARK: - Resize Event

    /// Resizes an existing system event by changing its end time.
    func resizeSystemEvent(identifier: String, newEnd: Date) {
        guard hasCalendarAccess else { return }
        guard let event = store.event(withIdentifier: identifier) else { return }
        event.endDate = newEnd
        do {
            try store.save(event, span: .thisEvent)
            NSLog("[CalendarData] Resized event: \(event.title ?? "")")
            refresh()
        } catch {
            NSLog("[CalendarData] Failed to resize event: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Event

    /// Deletes a system event by its identifier.
    func deleteSystemEvent(identifier: String) {
        guard hasCalendarAccess else { return }
        guard let event = store.event(withIdentifier: identifier) else {
            NSLog("[CalendarData] Event not found for deletion: \(identifier)")
            return
        }
        do {
            try store.remove(event, span: .thisEvent)
            NSLog("[CalendarData] Deleted event: \(event.title ?? "")")
            refresh()
        } catch {
            NSLog("[CalendarData] Failed to delete event: \(error.localizedDescription)")
        }
    }

    /// Finds an event by title (case-insensitive partial match). Returns the identifier.
    func findEventIdentifier(title: String) -> String? {
        let lowered = title.lowercased()
        let match = items.first { item in
            item.kind == .systemEvent && item.title.lowercased().contains(lowered)
        }
        if let sysEvent = match as? SystemEventItem {
            return sysEvent.eventIdentifier
        }
        return nil
    }

    // MARK: - Update Event

    /// Updates properties of an existing system event.
    func updateSystemEvent(identifier: String, title: String? = nil,
                           location: String? = nil, notes: String? = nil) {
        guard hasCalendarAccess else { return }
        guard let event = store.event(withIdentifier: identifier) else {
            NSLog("[CalendarData] Event not found for update: \(identifier)")
            return
        }
        if let title { event.title = title }
        if let location { event.location = location }
        if let notes {
            // Preserve Clome metadata tag if present
            let clomeTag = event.notes?.contains("[clome") == true ? "" : ""
            event.notes = notes + clomeTag
        }
        do {
            try store.save(event, span: .thisEvent)
            NSLog("[CalendarData] Updated event: \(event.title ?? "")")
            refresh()
        } catch {
            NSLog("[CalendarData] Failed to update event: \(error.localizedDescription)")
        }
    }

    // MARK: - List Calendars

    /// Returns all writable calendars for events.
    func listCalendars() -> [(identifier: String, title: String, color: Color)] {
        let calendars = store.calendars(for: .event)
        return calendars.map { cal in
            let cgColor = cal.cgColor ?? CGColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1.0)
            return (identifier: cal.calendarIdentifier, title: cal.title, color: Color(cgColor: cgColor))
        }
    }

    // MARK: - Check Availability

    /// Returns true if the given time slot has no overlapping system events.
    func checkAvailability(start: Date, end: Date) -> Bool {
        guard hasCalendarAccess else { return true }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events.isEmpty
    }

    // MARK: - Query Events

    /// Fetches system events in a specific date range and returns them as SystemEventItems.
    func queryEvents(from start: Date, to end: Date) -> [SystemEventItem] {
        guard hasCalendarAccess else { return [] }
        return fetchSystemEvents(from: start, to: end)
    }

    // MARK: - Observe Changes

    /// Sets up Combine subscriptions to refresh when data sources change.
    private func observeChanges() {
        // Refresh when todos change
        FlowSyncService.shared.$todos
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // Refresh when deadlines change
        FlowSyncService.shared.$deadlines
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // Refresh when system calendar store changes
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkAccess()
                self?.refresh()
            }
            .store(in: &cancellables)
    }
}
