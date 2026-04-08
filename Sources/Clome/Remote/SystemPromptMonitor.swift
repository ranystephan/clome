// SystemPromptMonitor.swift
// Clome — Detects macOS system permission dialogs (TCC, etc.) and forwards them to iOS.
// Uses the Accessibility API to read dialog content and click buttons remotely.

import AppKit
import ApplicationServices

@MainActor
final class SystemPromptMonitor {

    private struct PromptTarget {
        let sourceApp: String
        let ownerPID: pid_t?
        let buttons: [String]
    }

    private struct DetectedPrompt {
        let info: SystemPromptInfo
        let target: PromptTarget
    }

    // MARK: - Callbacks

    /// Called when a new system prompt is detected.
    var onPromptDetected: ((SystemPromptInfo) -> Void)?

    // MARK: - State

    private var pollTimer: Timer?
    private var knownPromptIds: Set<String> = []
    private var promptTargets: [String: PromptTarget] = [:]
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
            var detected: [DetectedPrompt] = []

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

    private nonisolated func scanOwnAppDialogsSync(pid: pid_t) -> [DetectedPrompt] {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return [] }

        var prompts: [DetectedPrompt] = []
        for window in windows {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = subroleRef as? String ?? ""

            if subrole == "AXDialog" || subrole == "AXSheet" || subrole == "AXSystemDialog" {
                if let prompt = extractPromptInfo(from: window, sourceApp: "Clome", ownerPID: pid) {
                    prompts.append(prompt)
                }
            }
        }
        return prompts
    }

    private nonisolated func scanAppDialogsSync(pid: pid_t, appName: String) -> [DetectedPrompt] {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return [] }

        var prompts: [DetectedPrompt] = []
        for window in windows {
            if let prompt = extractPromptInfo(from: window, sourceApp: appName, ownerPID: pid) {
                prompts.append(prompt)
            }
        }
        return prompts
    }

    private nonisolated func scanCGWindowAlertsSync() -> [DetectedPrompt] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }

        var prompts: [DetectedPrompt] = []
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
                    if let prompt = extractPromptInfo(from: axWindow, sourceApp: ownerName, ownerPID: ownerPID) {
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
                let info = SystemPromptInfo(
                    id: promptId,
                    title: title,
                    message: message,
                    buttons: ["Don't Allow", "Allow"],
                    sourceApp: ownerName,
                    promptType: .generic,
                    timestamp: .now
                )
                prompts.append(DetectedPrompt(
                    info: info,
                    target: PromptTarget(sourceApp: ownerName, ownerPID: ownerPID, buttons: info.buttons)
                ))
            }
        }
        return prompts
    }

    // MARK: - AX Element Parsing

    private nonisolated func extractPromptInfo(from window: AXUIElement, sourceApp: String, ownerPID: pid_t) -> DetectedPrompt? {
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

        let uniqueTexts = orderedUnique(texts)
        let uniqueButtons = orderedUnique(buttons)
        let message = uniqueTexts.joined(separator: "\n")
        let promptId = "\(sourceApp)-\(message.hashValue)"

        // Classify the prompt type
        let promptType = classifyPrompt(message: message, title: title)

        let info = SystemPromptInfo(
            id: promptId,
            title: title.isEmpty ? sourceApp : title,
            message: message,
            buttons: uniqueButtons,
            sourceApp: sourceApp,
            promptType: promptType,
            timestamp: .now
        )
        return DetectedPrompt(
            info: info,
            target: PromptTarget(sourceApp: sourceApp, ownerPID: ownerPID, buttons: uniqueButtons)
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

    private nonisolated func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var unique: [T] = []
        for value in values {
            guard seen.insert(value).inserted else { continue }
            unique.append(value)
        }
        return unique
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

    private func reportPrompt(_ detectedPrompt: DetectedPrompt) {
        let prompt = detectedPrompt.info
        promptTargets[prompt.id] = detectedPrompt.target
        guard !knownPromptIds.contains(prompt.id) else { return }
        knownPromptIds.insert(prompt.id)
        print("[SystemPromptMonitor] Detected system prompt: \(prompt.title) - \(prompt.message.prefix(80))")
        print("[SystemPromptMonitor] Buttons: \(prompt.buttons)")
        onPromptDetected?(prompt)

        // Clean up old known IDs after 60 seconds
        let promptId = prompt.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.knownPromptIds.remove(promptId)
            self?.promptTargets.removeValue(forKey: promptId)
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
        let target = promptTargets[response.promptId]

        // Run AppleScript on a background queue to avoid blocking @MainActor.
        // NSAppleScript.executeAndReturnError can take several seconds for system dialogs,
        // and blocking the main thread prevents ping/pong keepalive from working.
        DispatchQueue.global(qos: .userInitiated).async {
            self.clickButtonViaAppleScript(buttonLabel: buttonLabel, buttonIndex: buttonIndex, target: target)

            // Fallback: try direct AX approach on main thread
            Task { @MainActor in
                self.clickButtonViaAccessibility(buttonLabel: buttonLabel, buttonIndex: buttonIndex, target: target)
            }
        }
    }

    /// Runs on a background thread — NOT @MainActor.
    private nonisolated func clickButtonViaAppleScript(buttonLabel: String, buttonIndex: Int, target: PromptTarget?) {
        let escapedLabel = appleScriptEscaped(buttonLabel)
        let buttonNumber = max(buttonIndex + 1, 1)
        let targetSource = target?.sourceApp ?? ""
        let escapedTargetSource = appleScriptEscaped(targetSource)
        let script = """
        on clickInContainer(containerRef, targetLabel, targetIndex)
            try
                click button targetLabel of containerRef
                return true
            end try
            try
                click button targetIndex of containerRef
                return true
            end try
            return false
        end clickInContainer

        on clickInProcess(processName, targetLabel, targetIndex)
            tell application "System Events"
                if not (exists application process processName) then return false
                tell application process processName
                    repeat with w in every window
                        if clickInContainer(w, targetLabel, targetIndex) then return true
                        try
                            if clickInContainer(sheet 1 of w, targetLabel, targetIndex) then return true
                        end try
                    end repeat
                end tell
            end tell
            return false
        end clickInProcess

        tell application "System Events"
            try
                if "\(escapedTargetSource)" is not equal to "" then
                    if clickInProcess("\(escapedTargetSource)", "\(escapedLabel)", \(buttonNumber)) then return "clicked-target"
                end if
            end try
            try
                set frontApp to name of first application process whose frontmost is true
                if clickInProcess(frontApp, "\(escapedLabel)", \(buttonNumber)) then return "clicked-front"
            end try
            if clickInProcess("Clome", "\(escapedLabel)", \(buttonNumber)) then return "clicked-clome"
            if clickInProcess("CoreServicesUIAgent", "\(escapedLabel)", \(buttonNumber)) then return "clicked-core"
            if clickInProcess("SecurityAgent", "\(escapedLabel)", \(buttonNumber)) then return "clicked-security"
            if clickInProcess("UserNotificationCenter", "\(escapedLabel)", \(buttonNumber)) then return "clicked-unc"
            if clickInProcess("System Settings", "\(escapedLabel)", \(buttonNumber)) then return "clicked-settings"
        end tell
        return "not_found"
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

    private func clickButtonViaAccessibility(buttonLabel: String, buttonIndex: Int, target: PromptTarget?) {
        if let ownerPID = target?.ownerPID,
           clickButtonInApplication(pid: ownerPID, label: buttonLabel, index: buttonIndex) {
            print("[SystemPromptMonitor] Clicked button '\(buttonLabel)' via Accessibility for pid \(ownerPID)")
            return
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }

        let systemProcesses = Set(["UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent", "Clome", "System Settings"])
        let pids: [pid_t] = orderedUnique(windowList.compactMap { window in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  systemProcesses.contains(ownerName) else { return nil }
            return ownerPID
        })

        for pid in pids {
            if clickButtonInApplication(pid: pid, label: buttonLabel, index: buttonIndex) {
                print("[SystemPromptMonitor] Clicked button '\(buttonLabel)' via Accessibility")
                return
            }
        }
    }

    private func clickButtonInApplication(pid: pid_t, label: String, index: Int) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return false }

        for axWindow in axWindows {
            if clickButton(in: axWindow, label: label, index: index) {
                return true
            }
        }
        return false
    }

    /// Collect all buttons in the AX tree and try exact-label match first, then index fallback.
    private func clickButton(in element: AXUIElement, label: String, index: Int) -> Bool {
        var buttons: [AXUIElement] = []
        collectButtons(from: element, buttons: &buttons, depth: 0)
        guard !buttons.isEmpty else { return false }

        let normalizedLabel = normalizedButtonLabel(label)
        if let button = buttons.first(where: { normalizedButtonLabel(buttonTitle(of: $0)) == normalizedLabel }) {
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }

        guard buttons.indices.contains(index) else { return false }
        return AXUIElementPerformAction(buttons[index], kAXPressAction as CFString) == .success
    }

    private nonisolated func collectButtons(from element: AXUIElement, buttons: inout [AXUIElement], depth: Int) {
        guard depth < 10 else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXButton" {
            buttons.append(element)
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            collectButtons(from: child, buttons: &buttons, depth: depth + 1)
        }
    }

    private nonisolated func buttonTitle(of element: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        return titleRef as? String ?? ""
    }

    private nonisolated func normalizedButtonLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated func appleScriptEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
