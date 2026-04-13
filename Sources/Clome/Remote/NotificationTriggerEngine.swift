// NotificationTriggerEngine.swift
// Clome — Monitors terminal activity and fires smart notifications for remote clients.

import Foundation

@MainActor
final class NotificationTriggerEngine {

    var onNotification: ((RemoteNotification) -> Void)?

    private var commandStartTimes: [String: Date] = [:]  // workspace key -> start time
    private var longRunningAlerted: Set<String> = []
    private let longRunningThreshold: TimeInterval = 300  // 5 minutes

    /// Called when terminal activity state changes in any workspace.
    func activityChanged(workspaceIndex: Int, activity: TerminalActivity, previousState: TerminalActivity.ActivityState?) {
        let key = "ws-\(workspaceIndex)"

        switch activity.state {
        case .running:
            // Track command start time
            if previousState != .running {
                commandStartTimes[key] = Date()
                longRunningAlerted.remove(key)
            }

            // Check for long-running process
            if let start = commandStartTimes[key],
               Date().timeIntervalSince(start) > longRunningThreshold,
               !longRunningAlerted.contains(key) {
                longRunningAlerted.insert(key)
                let program = activity.runningProgram ?? "Process"
                fire(.longRunningAlert, workspace: workspaceIndex,
                     title: "\(program) running for 5+ minutes",
                     message: "The process has been running for over 5 minutes.")
            }

        case .completed:
            // Command finished — notify if it ran for more than 30 seconds
            if let start = commandStartTimes[key] {
                let duration = Date().timeIntervalSince(start)
                commandStartTimes.removeValue(forKey: key)

                if duration > 30 {
                    let durationStr = formatDuration(duration)
                    fire(.commandFinished, workspace: workspaceIndex,
                         title: "Command finished (\(durationStr))",
                         message: activity.outputPreview ?? "Process completed.")
                }
            }

            // Claude Code completion
            if activity.isClaudeCode {
                fire(.claudeComplete, workspace: workspaceIndex,
                     title: "Claude finished",
                     message: activity.outputPreview ?? "Claude Code task completed.")
            }

        case .idle:
            commandStartTimes.removeValue(forKey: key)

        case .waitingInput:
            if activity.isClaudeCode && activity.needsAttention {
                fire(.claudeNeedsInput, workspace: workspaceIndex,
                     title: "Claude needs input",
                     message: "Claude Code is waiting for your response.")
            }
        }
    }

    /// Called when terminal output contains error indicators.
    func terminalErrorDetected(workspaceIndex: Int, preview: String) {
        fire(.terminalError, workspace: workspaceIndex,
             title: "Error detected",
             message: preview)
    }

    private func fire(_ type: RemoteNotification.NotificationType, workspace: Int, title: String, message: String) {
        let notification = RemoteNotification(
            workspaceIndex: workspace,
            title: title,
            message: message,
            type: type
        )
        onNotification?(notification)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(seconds / 3600))h \(Int((seconds / 60).truncatingRemainder(dividingBy: 60)))m"
    }
}
