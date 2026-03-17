import AppKit

/// Overlay that shows drop zones on individual panes during a drag.
/// Repositions itself over whichever pane the cursor is hovering on.
class SplitDropZoneView: NSView {

    enum DropZone: Equatable {
        case left, right, top, bottom, center
        case none

        var splitDirection: SplitDirection? {
            switch self {
            case .left: return .left
            case .right: return .right
            case .top: return .up
            case .bottom: return .down
            case .center, .none: return nil
            }
        }
    }

    /// The result of a drop: which pane was targeted and which zone.
    /// targetPane is nil for root-level (outer edge) splits.
    struct DropResult {
        let targetPane: NSView?
        let zone: DropZone
    }

    private(set) var activeZone: DropZone = .none
    /// The pane currently being hovered over.
    private(set) weak var targetPane: NSView?

    private let zoneAlpha: CGFloat = 0.12
    private let activeAlpha: CGFloat = 0.28
    private let accentColor = NSColor.controlAccentColor

    // Zone layers (frame-based, no constraints — we reposition per pane)
    private let leftZone = NSView()
    private let rightZone = NSView()
    private let topZone = NSView()
    private let bottomZone = NSView()
    private let centerZone = NSView()

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true

        for zone in [leftZone, rightZone, topZone, bottomZone, centerZone] {
            zone.wantsLayer = true
            zone.layer?.backgroundColor = accentColor.withAlphaComponent(zoneAlpha).cgColor
            zone.layer?.cornerRadius = 6
            zone.layer?.cornerCurve = .continuous
            zone.layer?.borderColor = accentColor.withAlphaComponent(0.25).cgColor
            zone.layer?.borderWidth = 1.5
            addSubview(zone)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show the drop zones.
    func show() {
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    /// Hide the drop zones.
    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: {
            self.isHidden = true
            self.activeZone = .none
            self.targetPane = nil
        })
    }

    /// Reposition zones over a specific pane's frame (in our coordinate space).
    func positionOverPane(_ pane: NSView, paneFrame: NSRect) {
        targetPane = pane
        frame = paneFrame
        layoutZones()
    }

    /// Update hover based on a point in window coordinates.
    func updateHover(at windowPoint: NSPoint) {
        let local = convert(windowPoint, from: nil)
        let w = bounds.width
        let h = bounds.height
        let inset: CGFloat = 4
        let edgeFraction: CGFloat = 0.28

        let newZone: DropZone
        // Check edges by fraction of the pane
        if local.x < inset + w * edgeFraction && local.x >= inset && local.y >= inset && local.y <= h - inset {
            newZone = .left
        } else if local.x > w - inset - w * edgeFraction && local.x <= w - inset && local.y >= inset && local.y <= h - inset {
            newZone = .right
        } else if local.y > h - inset - h * edgeFraction && local.y <= h - inset && local.x >= inset && local.x <= w - inset {
            newZone = .top
        } else if local.y < inset + h * edgeFraction && local.y >= inset && local.x >= inset && local.x <= w - inset {
            newZone = .bottom
        } else if local.x >= inset && local.x <= w - inset && local.y >= inset && local.y <= h - inset {
            newZone = .center
        } else {
            newZone = .none
        }

        if newZone != activeZone {
            activeZone = newZone
            updateZoneHighlights()
        }
    }

    /// Position zones over the full content area for root-level splits (no specific target pane).
    func positionOverArea(frame areaFrame: NSRect) {
        targetPane = nil
        frame = areaFrame
        layoutZones()
    }

    /// The current drop result (target pane + zone).
    var dropResult: DropResult? {
        guard activeZone != .none else { return nil }
        return DropResult(targetPane: targetPane, zone: activeZone)
    }

    // MARK: - Layout

    private func layoutZones() {
        let w = bounds.width
        let h = bounds.height
        let inset: CGFloat = 4
        let edge: CGFloat = 0.28

        let ew = w * edge  // edge width
        let eh = h * edge  // edge height

        leftZone.frame   = NSRect(x: inset, y: inset, width: ew, height: h - 2 * inset)
        rightZone.frame  = NSRect(x: w - inset - ew, y: inset, width: ew, height: h - 2 * inset)
        topZone.frame    = NSRect(x: inset + ew + inset, y: h - inset - eh, width: w - 2 * (inset + ew + inset), height: eh)
        bottomZone.frame = NSRect(x: inset + ew + inset, y: inset, width: w - 2 * (inset + ew + inset), height: eh)
        centerZone.frame = NSRect(x: inset + ew + inset, y: inset + eh + inset, width: w - 2 * (inset + ew + inset), height: h - 2 * (inset + eh + inset))

        updateZoneHighlights()
    }

    override func layout() {
        super.layout()
        layoutZones()
    }

    private func updateZoneHighlights() {
        let zones: [(NSView, DropZone)] = [
            (leftZone, .left), (rightZone, .right),
            (topZone, .top), (bottomZone, .bottom),
            (centerZone, .center)
        ]

        for (view, zone) in zones {
            let isActive = zone == activeZone
            view.layer?.backgroundColor = accentColor.withAlphaComponent(isActive ? activeAlpha : zoneAlpha).cgColor
            view.layer?.borderWidth = isActive ? 2.5 : 1.5
        }
    }
}
