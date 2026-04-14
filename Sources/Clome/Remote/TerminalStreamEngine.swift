// TerminalStreamEngine.swift
// Captures terminal viewport content and streams screen state / deltas
// to connected remote clients (iOS companion app).

import AppKit

// MARK: - Tracked Terminal

/// Metadata for a terminal surface registered with the stream engine.
private struct TrackedTerminal {
    weak var surface: TerminalSurface?
    let paneId: String
    var tabIndex: Int

    /// Monotonically increasing sequence number for this terminal.
    var sequenceNumber: UInt64 = 0

    /// Previous frame's per-line content for delta computation.
    var previousLines: [String] = []

    /// Previous frame's terminal dimensions (cols x rows).
    var previousCols: Int = 0
    var previousRows: Int = 0

    /// Previous frame's metadata for change detection.
    var previousTitle: String = ""
    var previousActivityState: TerminalSurface.ActivityState = .idle
    var previousOutputPreview: String?

    /// Whether a full sync is needed (first frame, resize, explicit request).
    var needsFullSync: Bool = true

    /// Number of consecutive frames with no content changes.
    var idleFrameCount: Int = 0
}

// MARK: - TerminalStreamEngine

/// Periodically captures terminal viewport content from registered ghostty
/// surfaces and delivers full screen states or line-level deltas to consumers.
///
/// All work runs on `@MainActor` because ghostty surface calls must happen on
/// the main thread.
@MainActor
final class TerminalStreamEngine {

    // MARK: - Configuration

    /// Frames per second when terminal output is actively changing.
    var activeFPS: Double = 60.0

    /// Frames per second when all terminals are idle.
    var idleFPS: Double = 2.0

    /// Number of consecutive unchanged frames before switching to idle rate.
    private let idleThreshold: Int = 10

    // MARK: - Callbacks

    /// Delivers a full screen snapshot (first frame, resize, or explicit request).
    var onScreenState: ((TerminalScreenState) -> Void)?

    /// Delivers an incremental delta (changed lines + metadata).
    var onDelta: ((TerminalDelta) -> Void)?

    // MARK: - State

    private var terminals: [String: TrackedTerminal] = [:]  // keyed by paneId
    nonisolated(unsafe) private var captureTimer: Timer?
    private var currentInterval: TimeInterval = 0
    private var isRunning: Bool = false

    // MARK: - Lifecycle

    init() {}

    deinit {
        // Timer invalidation must happen on MainActor; since the class is
        // @MainActor-isolated the deinit body runs there.
        captureTimer?.invalidate()
        captureTimer = nil
    }

    /// Begin periodic capture. Safe to call multiple times (restarts the timer).
    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimer(interval: 1.0 / idleFPS)
    }

    /// Stop all capture. Registered terminals are kept so `start()` resumes.
    func stop() {
        isRunning = false
        captureTimer?.invalidate()
        captureTimer = nil
        currentInterval = 0
    }

    // MARK: - Registration

    /// Register a terminal surface for streaming.
    ///
    /// If a terminal with the same `paneId` is already registered its surface
    /// reference and tab index are updated and a full sync is scheduled.
    func register(surface: TerminalSurface, paneId: String, tabIndex: Int) {
        if var existing = terminals[paneId] {
            existing.surface = surface
            existing.tabIndex = tabIndex
            existing.needsFullSync = true
            terminals[paneId] = existing
        } else {
            terminals[paneId] = TrackedTerminal(
                surface: surface,
                paneId: paneId,
                tabIndex: tabIndex
            )
        }
    }

    /// Remove a terminal from streaming. Does nothing if not registered.
    func unregister(paneId: String) {
        terminals.removeValue(forKey: paneId)
    }

    /// Request a full screen state on the next capture for a specific terminal.
    func requestFullSync(paneId: String) {
        terminals[paneId]?.needsFullSync = true
    }

    /// Request a full sync for every registered terminal.
    func requestFullSyncAll() {
        for key in terminals.keys {
            terminals[key]?.needsFullSync = true
        }
    }

    // MARK: - Timer Management

    private func scheduleTimer(interval: TimeInterval) {
        captureTimer?.invalidate()
        currentInterval = interval
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureAll()
            }
        }
    }

    /// Adjust tick rate based on whether any terminal has active output.
    private func adaptFrameRate(anyActive: Bool) {
        let desiredInterval = anyActive
            ? 1.0 / activeFPS
            : 1.0 / idleFPS

        // Avoid rescheduling if already at the right rate (tolerance 1ms).
        guard abs(currentInterval - desiredInterval) > 0.001 else { return }
        scheduleTimer(interval: desiredInterval)
    }

    // MARK: - Capture Loop

    private func captureAll() {
        guard isRunning else { return }

        // Prune terminals whose surfaces have been deallocated.
        terminals = terminals.filter { $0.value.surface != nil }

        var anyActive = false

        for paneId in terminals.keys {
            guard var terminal = terminals[paneId] else { continue }
            let wasActive = captureOne(&terminal)
            if wasActive { anyActive = true }
            terminals[paneId] = terminal
        }

        adaptFrameRate(anyActive: anyActive)
    }

    /// Capture a single terminal. Returns `true` if content changed this frame.
    private func captureOne(_ terminal: inout TrackedTerminal) -> Bool {
        guard let surface = terminal.surface,
              let ghosttySurface = surface.surface else {
            return false
        }

        // -- Read terminal dimensions --
        let size = ghostty_surface_size(ghosttySurface)
        let cellH = max(size.cell_height_px, 1)
        let cellW = max(size.cell_width_px, 1)
        let rows = Int(size.height_px / cellH)
        let cols = Int(size.width_px / cellW)
        guard rows > 0, cols > 0 else { return false }

        // Detect resize -> force full sync.
        if cols != terminal.previousCols || rows != terminal.previousRows {
            terminal.needsFullSync = true
        }

        // -- Read viewport text (plain for change detection) --
        guard let viewportText = readViewport(
            surface: ghosttySurface,
            rows: rows
        ) else {
            return false
        }

        // Split into lines, pad/truncate to exact row count.
        var lines = viewportText.components(separatedBy: "\n")
        if lines.count > rows {
            lines = Array(lines.prefix(rows))
        }
        while lines.count < rows {
            lines.append("")
        }

        // -- Gather metadata --
        let title = surface.title
        let activityState = surface.activityState
        let outputPreview = surface.outputPreview
        let workingDirectory = surface.workingDirectory

        // Map TerminalSurface.ActivityState to TerminalActivity.ActivityState
        let mappedState = mapActivityState(activityState)

        // -- Decide: full sync or delta --
        terminal.sequenceNumber += 1

        if terminal.needsFullSync {
            terminal.needsFullSync = false
            terminal.previousLines = lines
            terminal.previousCols = cols
            terminal.previousRows = rows
            terminal.previousTitle = title
            terminal.previousActivityState = activityState
            terminal.previousOutputPreview = outputPreview
            terminal.idleFrameCount = 0

            // Read styled (ANSI) text for the wire — falls back to plain if unavailable.
            let styledText = readStyledViewport(surface: ghosttySurface, rows: rows) ?? viewportText

            let state = TerminalScreenState(
                paneId: terminal.paneId,
                tabIndex: terminal.tabIndex,
                sequenceNumber: terminal.sequenceNumber,
                rows: rows,
                cols: cols,
                cursorRow: 0,   // ghostty does not expose cursor position directly
                cursorCol: 0,
                cursorVisible: true,
                title: title,
                workingDirectory: workingDirectory,
                text: styledText,
                activityState: mappedState
            )
            onScreenState?(state)
            return true
        }

        // -- Compute delta (use plain text for comparison, styled for sending) --
        let contentChanged = lines != terminal.previousLines
        let titleChanged = title != terminal.previousTitle
        let stateChanged = activityState != terminal.previousActivityState
        let previewChanged = outputPreview != terminal.previousOutputPreview

        guard contentChanged || titleChanged || stateChanged || previewChanged else {
            terminal.idleFrameCount += 1
            return false
        }

        // Reset idle counter on any change.
        terminal.idleFrameCount = 0

        // Read styled viewport for sending changed lines with ANSI colors.
        let styledViewport = contentChanged
            ? readStyledViewport(surface: ghosttySurface, rows: rows)
            : nil
        // VT format uses \r\n — normalize to \n for line splitting.
        var styledLines: [String]? = nil
        if let sv = styledViewport {
            styledLines = sv.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
        }

        // Build changed-lines dictionary (only lines that differ).
        var changedLines: [String: String] = [:]
        for i in 0..<lines.count {
            if i >= terminal.previousLines.count || lines[i] != terminal.previousLines[i] {
                // Use styled line if available, fall back to plain
                let lineContent = styledLines?[safe: i] ?? lines[i]
                changedLines[String(i)] = lineContent
            }
        }

        // Snapshot current state for next frame comparison (always plain text).
        terminal.previousLines = lines
        terminal.previousTitle = title
        terminal.previousActivityState = activityState
        terminal.previousOutputPreview = outputPreview
        terminal.previousCols = cols
        terminal.previousRows = rows

        let delta = TerminalDelta(
            paneId: terminal.paneId,
            tabIndex: terminal.tabIndex,
            sequenceNumber: terminal.sequenceNumber,
            changedLines: changedLines,
            cursorRow: 0,
            cursorCol: 0,
            title: titleChanged ? title : nil,
            activityState: stateChanged ? mappedState : nil,
            outputPreview: previewChanged ? outputPreview : nil
        )
        onDelta?(delta)
        return true
    }

    // MARK: - Ghostty Viewport Read

    /// Build a selection spanning the entire visible viewport.
    private func viewportSelection(rows: Int) -> ghostty_selection_s {
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 999,  // Large x to cover full width
            y: UInt32(rows - 1)
        )
        selection.rectangle = false
        return selection
    }

    /// Read the full visible viewport text from a ghostty surface (plain text,
    /// used for change detection).
    private func readViewport(
        surface: ghostty_surface_t,
        rows: Int
    ) -> String? {
        let selection = viewportSelection(rows: rows)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text),
              let ptr = text.text,
              text.text_len > 0 else {
            return nil
        }

        let result = String(cString: ptr)
        ghostty_surface_free_text(surface, &text)
        return result
    }

    /// Read the full visible viewport text with ANSI SGR escape codes preserved.
    /// This output retains colors, bold, italic, etc. for remote rendering.
    /// NOTE: Falls back to plain text until ghostty_surface_read_styled_text is
    /// available in the compiled library.
    private func readStyledViewport(
        surface: ghostty_surface_t,
        rows: Int
    ) -> String? {
        // ghostty_surface_read_styled_text is declared in ghostty.h but not yet
        // exported by the compiled library.  Fall back to plain readViewport.
        return readViewport(surface: surface, rows: rows)
    }

    // MARK: - Helpers

    /// Map the terminal surface's internal `ActivityState` to the remote
    /// protocol's `TerminalActivity.ActivityState`.
    private func mapActivityState(
        _ state: TerminalSurface.ActivityState
    ) -> TerminalActivity.ActivityState {
        switch state {
        case .idle:         return .idle
        case .running:      return .running
        case .waitingInput: return .waitingInput
        case .completed:    return .completed
        }
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
