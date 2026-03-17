import AppKit

/// Monitors terminal surfaces for activity changes and bridges ghostty notifications
/// to per-surface state. Periodically reads terminal output for sidebar previews.
@MainActor
class TerminalActivityMonitor {
    static let shared = TerminalActivityMonitor()

    /// All registered terminal surfaces (weak references).
    private var surfaces: [WeakSurface] = []

    /// Timer for periodic output preview updates.
    private var previewTimer: Timer?

    private init() {
        observeNotifications()
        startPreviewTimer()
    }

    // MARK: - Surface Registration

    func register(_ surface: TerminalSurface) {
        // Clean up deallocated surfaces
        surfaces.removeAll { $0.surface == nil }
        surfaces.append(WeakSurface(surface))
    }

    func unregister(_ surface: TerminalSurface) {
        surfaces.removeAll { $0.surface === surface || $0.surface == nil }
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let nc = NotificationCenter.default

        nc.addObserver(
            self,
            selector: #selector(handleTitleChanged(_:)),
            name: .ghosttySurfaceTitleChanged,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(handlePwdChanged(_:)),
            name: .ghosttySurfacePwdChanged,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(handleCommandFinished(_:)),
            name: .ghosttyCommandFinished,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(handleDesktopNotification(_:)),
            name: .ghosttyDesktopNotification,
            object: nil
        )
    }

    @objc private func handleTitleChanged(_ notification: Notification) {
        guard let info = notification.userInfo,
              let title = info["title"] as? String,
              let target = info["target"] as? ghostty_target_s else { return }

        if let surface = findSurface(for: target) {
            surface.title = title
            postActivityChanged(surface)
        }
    }

    @objc private func handlePwdChanged(_ notification: Notification) {
        guard let info = notification.userInfo,
              let pwd = info["pwd"] as? String,
              let target = info["target"] as? ghostty_target_s else { return }

        if let surface = findSurface(for: target) {
            surface.workingDirectory = pwd
            postActivityChanged(surface)
        }
    }

    @objc private func handleCommandFinished(_ notification: Notification) {
        guard let info = notification.userInfo,
              let target = info["target"] as? ghostty_target_s else { return }

        if let surface = findSurface(for: target) {
            surface.isCommandRunning = false
            surface.activityState = .completed
            // Read output to get the result preview
            surface.readOutputAndDetectState()
            postActivityChanged(surface)
        }
    }

    @objc private func handleDesktopNotification(_ notification: Notification) {
        guard let info = notification.userInfo,
              let body = info["body"] as? String,
              let target = info["target"] as? ghostty_target_s else { return }

        if let surface = findSurface(for: target) {
            surface.lastNotification = body
            postActivityChanged(surface)
        }
    }

    // MARK: - Preview Timer

    private func startPreviewTimer() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePreviews()
            }
        }
    }

    private func updatePreviews() {
        surfaces.removeAll { $0.surface == nil }
        for weak in surfaces {
            guard let surface = weak.surface else { continue }
            surface.readOutputAndDetectState()
        }
        // Post a single notification for sidebar refresh
        NotificationCenter.default.post(name: .terminalActivityChanged, object: nil)
    }

    // MARK: - Helpers

    private func findSurface(for target: ghostty_target_s) -> TerminalSurface? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        let targetSurface = target.target.surface
        surfaces.removeAll { $0.surface == nil }
        return surfaces.first { $0.surface?.surface == targetSurface }?.surface
    }

    private func postActivityChanged(_ surface: TerminalSurface) {
        NotificationCenter.default.post(name: .terminalActivityChanged, object: surface)
    }
}

// MARK: - Weak reference wrapper

private struct WeakSurface {
    weak var surface: TerminalSurface?
    init(_ surface: TerminalSurface) {
        self.surface = surface
    }
}

// MARK: - Additional Notifications

extension Notification.Name {
    static let ghosttyDesktopNotification = Notification.Name("ghosttyDesktopNotification")
}
