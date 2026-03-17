import AppKit
import UserNotifications

/// Notification ring system for terminal surfaces.
/// Supports OSC 9 (desktop notification), OSC 99 (progress), and OSC 777 (custom).
/// Shows notification badges on sidebar workspace items.
@MainActor
class NotificationSystem {
    static let shared = NotificationSystem()

    struct PendingNotification {
        let workspaceId: UUID
        let surfaceTitle: String
        let message: String
        let timestamp: Date
    }

    private(set) var pendingNotifications: [UUID: [PendingNotification]] = [:]
    private(set) var unreadCounts: [UUID: Int] = [:]

    private init() {
        requestPermissions()
    }

    private func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Called when a terminal produces a notification (OSC 9/99/777).
    func notify(workspaceId: UUID, surfaceTitle: String, message: String, showDesktop: Bool = true) {
        let notification = PendingNotification(
            workspaceId: workspaceId,
            surfaceTitle: surfaceTitle,
            message: message,
            timestamp: Date()
        )

        pendingNotifications[workspaceId, default: []].append(notification)
        unreadCounts[workspaceId, default: 0] += 1

        NotificationCenter.default.post(
            name: .clomeNotificationCountChanged,
            object: nil,
            userInfo: ["workspaceId": workspaceId, "count": unreadCounts[workspaceId] ?? 0]
        )

        if showDesktop {
            sendDesktopNotification(title: surfaceTitle, body: message)
        }
    }

    /// Mark all notifications for a workspace as read.
    func markRead(workspaceId: UUID) {
        unreadCounts[workspaceId] = 0
        pendingNotifications[workspaceId] = nil
        NotificationCenter.default.post(
            name: .clomeNotificationCountChanged,
            object: nil,
            userInfo: ["workspaceId": workspaceId, "count": 0]
        )
    }

    func unreadCount(for workspaceId: UUID) -> Int {
        unreadCounts[workspaceId] ?? 0
    }

    private func sendDesktopNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let clomeNotificationCountChanged = Notification.Name("clomeNotificationCountChanged")
}
