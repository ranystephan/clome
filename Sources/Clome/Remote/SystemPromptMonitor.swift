// SystemPromptMonitor.swift
// Clome — Detects macOS system permission dialogs (TCC, etc.) and forwards them to iOS.
// Uses the Accessibility API to read dialog content and click buttons remotely.

import AppKit
import ApplicationServices

@MainActor
final class SystemPromptMonitor {

    // MARK: - Callbacks

    /// Called when a new system prompt is detected.
    var onPromptDetected: ((SystemPromptInfo) -> Void)?

    // MARK: - State

    private var pollTimer: Timer?
    private var knownPromptIds: Set<String> = []
    private var isRunning = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Check for Accessibility permission
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        if !trusted {
            print("[SystemPromptMonitor] Accessibility permission not yet granted. Will poll when granted.")
        }

        // Poll for system dialogs every 1.5 seconds.
        // Resolve PIDs on the main thread (NSRunningApplication requires it), then
        // scan on a background queue so AX API calls don't block the main thread
        // (which would prevent keepalive pong responses and cause disconnections).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dispatchScan()
            }
        }
        print("[SystemPromptMonitor] Started monitoring for system prompts")
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Dialog Detection

    /// Resolve PIDs on the main thread, then dispatch the heavy AX scanning to background.
    private func dispatchScan() {
        let hasTrust = AXIsProcessTrusted()

        // Resolve PIDs on the main thread (NSRunningApplication requires MainActor)
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let systemApps: [(pid: pid_t, name: String)] = [
            "com.apple.UserNotificationCenter",
            "com.apple.SecurityAgent",
            "com.apple.CoreServicesUIAgent",
        ].compactMap { bundleId in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
            return (app.processIdentifier, app.localizedName ?? bundleId)
        }

        // Do the scanning off the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var detected: [SystemPromptInfo] = []

            if hasTrust {
                // Full AX scanning — reads dialog content and buttons
                detected.append(contentsOf: self.scanOwnAppDialogsSync(pid: ownPid))
                for app in systemApps {
                    detected.append(contentsOf: self.scanAppDialogsSync(pid: app.pid, appName: app.name))
                }
            }

            // CGWindowList fallback — works without Accessibility permission.
            // Can detect that a dialog exists (window layer, owner process).
            // With AX trust it also reads content; without it, reports a generic prompt.
            detected.append(contentsOf: self.scanCGWindowAlertsSync())

            // Report on main actor
            if !detected.isEmpty {
                Task { @MainActor [weak self] in
                    for prompt in detected {
                        self?.reportPrompt(prompt)
                    }
                }
            }
        }
    }

    // Background-safe scan methods (nonisolated, return collected prompts)

    private nonisolated func scanOwnAppDialogsSync(pid: pid_t) -> [SystemPromptInfo] {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return [] }

        var prompts: [SystemPromptInfo] = []
        for window in windows {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = subroleRef as? String ?? ""

            if subrole == "AXDialog" || subrole == "AXSheet" || subrole == "AXSystemDialog" {
                if let prompt = extractPromptInfo(from: window, sourceApp: "Clome") {
                    prompts.append(prompt)
                }
            }
        }
        return prompts
    }

    private nonisolated func scanAppDialogsSync(pid: pid_t, appName: String) -> [SystemPromptInfo] {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return [] }

        var prompts: [SystemPromptInfo] = []
        for window in windows {
            if let prompt = extractPromptInfo(from: window, sourceApp: appName) {
                prompts.append(prompt)
            }
        }
        return prompts
    }

    private nonisolated func scanCGWindowAlertsSync() -> [SystemPromptInfo] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }

        var prompts: [SystemPromptInfo] = []
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { continue }

            let isSystemDialog = layer > 0 && (
                ownerName == "UserNotificationCenter" ||
                ownerName == "SecurityAgent" ||
                ownerName == "CoreServicesUIAgent" ||
                ownerName.contains("tccd")
            )

            guard isSystemDialog else { continue }

            // Try AX approach first (requires Accessibility permission)
            let app = AXUIElementCreateApplication(ownerPID)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            if result == .success, let axWindows = windowsRef as? [AXUIElement] {
                for axWindow in axWindows {
                    if let prompt = extractPromptInfo(from: axWindow, sourceApp: ownerName) {
                        prompts.append(prompt)
                    }
                }
            } else {
                // No AX access — create a generic prompt from CGWindowList metadata.
                // We know a system dialog exists but can't read its content.
                let windowName = window[kCGWindowName as String] as? String ?? ""
                let promptId = "cg-\(ownerName)-\(ownerPID)-\(windowName.hashValue)"
                let title = windowName.isEmpty ? "System Permission" : windowName
                let message = "A system dialog is waiting on your Mac. Tap a button to respond, or handle it directly on the Mac."
                prompts.append(SystemPromptInfo(
                    id: promptId,
                    title: title,
                    message: message,
                    buttons: ["Allow", "Don't Allow"],
                    sourceApp: ownerName,
                    promptType: .generic,
                    timestamp: .now
                ))
            }
        }
        return prompts
    }

    // MARK: - AX Element Parsing

    private nonisolated func extractPromptInfo(from window: AXUIElement, sourceApp: String) -> SystemPromptInfo? {
        // Get window title
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""

        // Get all children to find text and buttons
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        var texts: [String] = []
        var buttons: [String] = []

        collectTextsAndButtons(from: children, texts: &texts, buttons: &buttons, depth: 0)

        // Need at least some text and at least one button to be a prompt
        guard !texts.isEmpty, !buttons.isEmpty else { return nil }

        let message = texts.joined(separator: "\n")
        let promptId = "\(sourceApp)-\(message.hashValue)"

        // Classify the prompt type
        let promptType = classifyPrompt(message: message, title: title)

        return SystemPromptInfo(
            id: promptId,
            title: title.isEmpty ? sourceApp : title,
            message: message,
            buttons: buttons,
            sourceApp: sourceApp,
            promptType: promptType,
            timestamp: .now
        )
    }

    /// Recursively collect static text and button labels from an AX element tree.
    private nonisolated func collectTextsAndButtons(from elements: [AXUIElement], texts: inout [String], buttons: inout [String], depth: Int) {
        guard depth < 10 else { return } // prevent infinite recursion

        for element in elements {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)

            let value = valueRef as? String ?? ""
            let title = titleRef as? String ?? ""

            switch role {
            case "AXStaticText":
                let text = !value.isEmpty ? value : title
                if !text.isEmpty, text.count > 3 { // skip very short labels
                    texts.append(text)
                }
            case "AXButton":
                if !title.isEmpty {
                    buttons.append(title)
                }
            default:
                break
            }

            // Recurse into children
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            if let children = childrenRef as? [AXUIElement] {
                collectTextsAndButtons(from: children, texts: &texts, buttons: &buttons, depth: depth + 1)
            }
        }
    }

    private nonisolated func classifyPrompt(message: String, title: String) -> SystemPromptInfo.PromptType {
        let lower = (message + " " + title).lowercased()
        if lower.contains("desktop") || lower.contains("documents") || lower.contains("downloads") ||
           lower.contains("folder") || lower.contains("files in") || lower.contains("access to") {
            return .folderAccess
        }
        if lower.contains("accessibility") || lower.contains("control your computer") {
            return .accessibility
        }
        if lower.contains("microphone") || lower.contains("audio") {
            return .microphone
        }
        if lower.contains("camera") || lower.contains("video") {
            return .camera
        }
        return .generic
    }

    // MARK: - Prompt Reporting

    private func reportPrompt(_ prompt: SystemPromptInfo) {
        guard !knownPromptIds.contains(prompt.id) else { return }
        knownPromptIds.insert(prompt.id)
        print("[SystemPromptMonitor] Detected system prompt: \(prompt.title) - \(prompt.message.prefix(80))")
        print("[SystemPromptMonitor] Buttons: \(prompt.buttons)")
        onPromptDetected?(prompt)

        // Clean up old known IDs after 60 seconds
        let promptId = prompt.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.knownPromptIds.remove(promptId)
        }
    }

    // MARK: - Button Clicking

    /// Click a button on a system dialog. Uses AppleScript as the most reliable method.
    /// Runs AppleScript off the main thread to avoid blocking the run loop (which would
    /// prevent pong responses and cause the iOS client to think the connection is dead).
    func respondToPrompt(_ response: SystemPromptResponse) {
        print("[SystemPromptMonitor] Responding to prompt \(response.promptId): clicking '\(response.selectedButton)'")

        let buttonLabel = response.selectedButton
        let buttonIndex = response.buttonIndex

        // Run AppleScript on a background queue to avoid blocking @MainActor.
        // NSAppleScript.executeAndReturnError can take several seconds for system dialogs,
        // and blocking the main thread prevents ping/pong keepalive from working.
        DispatchQueue.global(qos: .userInitiated).async {
            self.clickButtonViaAppleScript(buttonLabel: buttonLabel)

            // Fallback: try direct AX approach on main thread
            Task { @MainActor in
                self.clickButtonViaAccessibility(buttonLabel: buttonLabel, buttonIndex: buttonIndex)
            }
        }
    }

    /// Runs on a background thread — NOT @MainActor.
    private nonisolated func clickButtonViaAppleScript(buttonLabel: String) {
        // Try clicking the button in the frontmost dialog
        let script = """
        tell application "System Events"
            try
                -- Try clicking in the frontmost app's dialog
                set frontApp to name of first application process whose frontmost is true
                tell application process frontApp
                    set dialogWindows to every window whose subrole is "AXDialog" or subrole is "AXSheet"
                    repeat with w in dialogWindows
                        try
                            click button "\(buttonLabel)" of w
                            return "clicked"
                        end try
                    end repeat
                    -- Also try sheets
                    repeat with w in every window
                        try
                            click button "\(buttonLabel)" of sheet 1 of w
                            return "clicked"
                        end try
                    end repeat
                end tell
            end try
            -- Try UserNotificationCenter dialogs
            try
                tell application process "UserNotificationCenter"
                    click button "\(buttonLabel)" of window 1
                    return "clicked"
                end tell
            end try
            -- Try CoreServicesUIAgent
            try
                tell application process "CoreServicesUIAgent"
                    click button "\(buttonLabel)" of window 1
                    return "clicked"
                end tell
            end try
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error {
                print("[SystemPromptMonitor] AppleScript error: \(error)")
            } else {
                print("[SystemPromptMonitor] AppleScript result: \(result.stringValue ?? "nil")")
            }
        }
    }

    private func clickButtonViaAccessibility(buttonLabel: String, buttonIndex: Int) {
        // Scan all apps for a button matching the label
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }

        let systemProcesses = Set(["UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent", "Clome"])
        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  systemProcesses.contains(ownerName) else { continue }

            let app = AXUIElementCreateApplication(ownerPID)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                if clickButton(in: axWindow, label: buttonLabel, index: buttonIndex) {
                    print("[SystemPromptMonitor] Clicked button '\(buttonLabel)' via Accessibility")
                    return
                }
            }
        }
    }

    /// Recursively find and click a button in an AX element tree.
    private func clickButton(in element: AXUIElement, label: String, index: Int, depth: Int = 0) -> Bool {
        guard depth < 10 else { return false }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return false }

        var buttonCount = 0
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            if role == "AXButton" {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""

                if title == label || buttonCount == index {
                    AXUIElementPerformAction(child, kAXPressAction as CFString)
                    return true
                }
                buttonCount += 1
            }

            // Recurse
            if clickButton(in: child, label: label, index: index, depth: depth + 1) {
                return true
            }
        }
        return false
    }
}
