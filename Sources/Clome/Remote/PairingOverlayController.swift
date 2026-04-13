// PairingOverlayController.swift
// Clome — Floating HUD panel that displays the 6-digit pairing code in-app.

import AppKit

@MainActor
final class PairingOverlayController {
    static let shared = PairingOverlayController()

    private var panel: NSPanel?
    private var codeLabel: NSTextField?
    private var connectedObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Public

    func show(code: String) {
        // Dismiss any existing panel first
        dismiss()

        guard let mainWindow = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }

        // ──── Panel ────
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable, .hudWindow, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(red: 14/255, green: 14/255, blue: 18/255, alpha: 0.95)
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        // ──── Content ────
        let contentView = NSView(frame: panel.contentView!.bounds)
        contentView.wantsLayer = true

        // Instruction label
        let instructionLabel = NSTextField(labelWithString: "Enter this code on your iOS device")
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        instructionLabel.textColor = NSColor(white: 1.0, alpha: 0.55)
        instructionLabel.alignment = .center
        contentView.addSubview(instructionLabel)

        // Code digits — large, monospaced, with letter spacing via attributed string
        let codeFont = NSFont.monospacedSystemFont(ofSize: 48, weight: .bold)
        let codeString = NSAttributedString(string: code, attributes: [
            .font: codeFont,
            .foregroundColor: NSColor(white: 1.0, alpha: 0.95),
            .kern: 18.0  // letter spacing between digits
        ])
        let codeLabel = NSTextField(labelWithString: "")
        codeLabel.attributedStringValue = codeString
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.alignment = .center
        codeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(codeLabel)
        self.codeLabel = codeLabel

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "Clome Remote Pairing")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 1.0, alpha: 0.35)
        subtitleLabel.alignment = .center
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            instructionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            instructionLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            codeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            codeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 4),

            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            subtitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])

        panel.contentView = contentView

        // Center on the main window
        let mainFrame = mainWindow.frame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: mainFrame.midX - panelSize.width / 2,
            y: mainFrame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)

        self.panel = panel

        // ──── Auto-dismiss on connection ────
        connectedObserver = NotificationCenter.default.addObserver(
            forName: .remoteClientConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        if let observer = connectedObserver {
            NotificationCenter.default.removeObserver(observer)
            connectedObserver = nil
        }
        panel?.close()
        panel = nil
        codeLabel = nil
    }
}
