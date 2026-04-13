import AppKit

/// Shows the animated Clome mark with construction lines when a workspace has no content.
/// Uses the exact bezier curves from the logo SVG, adapted for the dark app theme.
@MainActor
final class EmptyStateView: NSView {

    // MARK: - Logo geometry (from clome-lines SVG, pre-scaled to 0–1 range)

    /// Quadratic bezier segments for the front curve (arches up)
    private static let frontSegments: [(sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat, ex: CGFloat, ey: CGFloat)] = [
        (224, 608, 265.661, 608, 322.081, 507.074),
        (322.081, 507.074, 362.298, 435.131, 390.383, 405.911),
        (390.383, 405.911, 442.2, 352, 512, 352),
        (512, 352, 581.8, 352, 633.617, 405.911),
        (633.617, 405.911, 661.702, 435.131, 701.919, 507.074),
        (701.919, 507.074, 758.339, 608, 800, 608),
    ]

    /// Quadratic bezier segments for the back curve (dips down)
    private static let backSegments: [(sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat, ex: CGFloat, ey: CGFloat)] = [
        (224, 352, 278.573, 352, 320.759, 398.584),
        (320.759, 398.584, 342.937, 423.074, 377.944, 485.697),
        (377.944, 485.697, 414.145, 550.455, 436.525, 573.74),
        (436.525, 573.74, 469.455, 608, 512, 608),
        (512, 608, 554.545, 608, 587.474, 573.74),
        (587.474, 573.74, 609.855, 550.454, 646.056, 485.697),
        (646.056, 485.697, 681.063, 423.074, 703.241, 398.584),
        (703.241, 398.584, 745.427, 352, 800, 352),
    ]

    // Pre-sampled displacement arrays (computed once)
    private static let sampleCount = 120
    private let frontDisp: [CGFloat]
    private let backDisp: [CGFloat]

    // Animation state
    private var animTimer: Timer?
    private var startTime: CFTimeInterval = 0
    private var drawProgress: CGFloat = 0
    private var time: CGFloat = 0

    // Label
    private let hintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "⌘T  new terminal  ·  ⌘O  open file  ·  ⌘N  new workspace")
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.15)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Init

    override init(frame: NSRect) {
        frontDisp = Self.precompute(segments: Self.frontSegments)
        backDisp = Self.precompute(segments: Self.backSegments)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -48),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startAnimation() } else { stopAnimation() }
    }

    override func removeFromSuperview() {
        stopAnimation()
        super.removeFromSuperview()
    }

    // MARK: - Precompute

    private static func precompute(segments: [(sx: CGFloat, sy: CGFloat, cx: CGFloat, cy: CGFloat, ex: CGFloat, ey: CGFloat)]) -> [CGFloat] {
        // Sample the Q bezier chain densely, then resample at uniform x spacing
        var raw: [(x: CGFloat, y: CGFloat)] = []
        for (i, seg) in segments.enumerated() {
            let n = 40
            let start = (i == 0) ? 0 : 1
            for j in start...n {
                let t = CGFloat(j) / CGFloat(n)
                let m = 1 - t
                let x = m * m * seg.sx + 2 * m * t * seg.cx + t * t * seg.ex
                let y = m * m * seg.sy + 2 * m * t * seg.cy + t * t * seg.ey
                raw.append((x, y))
            }
        }

        var result: [CGFloat] = []
        var ri = 0
        for j in 0...sampleCount {
            let targetX = 224 + 576 * CGFloat(j) / CGFloat(sampleCount)
            while ri < raw.count - 2 && raw[ri + 1].x < targetX { ri += 1 }
            let a = raw[ri], b = raw[min(ri + 1, raw.count - 1)]
            let f = b.x > a.x ? max(0, min(1, (targetX - a.x) / (b.x - a.x))) : 0
            let y = a.y + (b.y - a.y) * f
            result.append((480 - y) / 128) // displacement: +1 = top, -1 = bottom
        }
        return result
    }

    // MARK: - Animation

    private func startAnimation() {
        guard animTimer == nil else { return }
        startTime = CACurrentMediaTime()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    private func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let elapsed = CGFloat(CACurrentMediaTime() - startTime)

        // Draw-on progress (first 2 seconds)
        drawProgress = min(elapsed / 2.0, 1.0)
        drawProgress = 1 - pow(1 - drawProgress, 3) // ease out

        // Breathing
        let breathe = sin(elapsed * 0.4) * 0.006
        let amp: CGFloat = 0.22 + breathe

        // Layout
        let w = bounds.width
        let h = bounds.height
        let logoW: CGFloat = min(280, w * 0.35)
        let logoH = logoW * 0.6
        let logoX = (w - logoW) / 2
        let logoY = (h - logoH) / 2 + 20 // slight upward offset

        let padX = logoW * 0.1
        let cy = logoH / 2

        // Colors (adapted for dark theme)
        let bright = NSColor.white.withAlphaComponent(0.7).cgColor
        let dim = NSColor.white.withAlphaComponent(0.15).cgColor
        let construction = NSColor.white.withAlphaComponent(0.06).cgColor
        let constructionStrong = NSColor.white.withAlphaComponent(0.1).cgColor

        ctx.saveGState()
        ctx.translateBy(x: logoX, y: logoY)

        // --- Construction lines ---
        let gridAlpha = max(0, min(1, (elapsed - 1.0) / 1.0))
        if gridAlpha > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(gridAlpha)

            // Center axis
            ctx.setStrokeColor(construction)
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [4, 5])
            ctx.move(to: CGPoint(x: padX - 4, y: cy))
            ctx.addLine(to: CGPoint(x: logoW - padX + 4, y: cy))
            ctx.strokePath()

            // Amplitude guides
            ctx.move(to: CGPoint(x: padX, y: cy - amp * logoH))
            ctx.addLine(to: CGPoint(x: logoW - padX, y: cy - amp * logoH))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: padX, y: cy + amp * logoH))
            ctx.addLine(to: CGPoint(x: logoW - padX, y: cy + amp * logoH))
            ctx.strokePath()

            // Vertical center
            let midX = logoW / 2
            ctx.move(to: CGPoint(x: midX, y: cy - amp * logoH - 6))
            ctx.addLine(to: CGPoint(x: midX, y: cy + amp * logoH + 6))
            ctx.strokePath()

            ctx.setLineDash(phase: 0, lengths: [])

            // Tick marks
            ctx.setStrokeColor(constructionStrong)
            ctx.setLineWidth(0.6)
            for i in 0...10 {
                let tx = padX + CGFloat(i) / 10 * (logoW - 2 * padX)
                ctx.move(to: CGPoint(x: tx, y: cy - 3))
                ctx.addLine(to: CGPoint(x: tx, y: cy + 3))
                ctx.strokePath()
            }

            // Center dot
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(0.8)
            ctx.addArc(center: CGPoint(x: midX, y: cy), radius: 3, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()

            ctx.restoreGState()
        }

        // --- Logo curves ---
        let sw = min(logoW, logoH) * 0.05
        let visCount = Int(ceil(drawProgress * CGFloat(Self.sampleCount + 1)))

        func curvePoint(_ disp: [CGFloat], _ i: Int) -> CGPoint {
            let nx = CGFloat(i) / CGFloat(Self.sampleCount)
            let x = padX + nx * (logoW - 2 * padX)
            let y = cy - amp * logoH * disp[i]
            return CGPoint(x: x, y: y)
        }

        func drawCurve(_ disp: [CGFloat], color: CGColor) {
            guard visCount > 1 else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(sw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let first = curvePoint(disp, 0)
            ctx.move(to: first)
            for i in 1..<min(visCount, disp.count) {
                ctx.addLine(to: curvePoint(disp, i))
            }
            ctx.strokePath()
        }

        // Back curve (dim)
        drawCurve(backDisp, color: dim)
        // Front curve (bright)
        drawCurve(frontDisp, color: bright)

        // --- Tracer dot ---
        if drawProgress >= 1 {
            let t = (sin(elapsed * 0.7) + 1) / 2
            let idx = Int(round(t * CGFloat(Self.sampleCount)))
            let p = curvePoint(frontDisp, idx)

            // Tangent
            let i0 = max(0, idx - 3)
            let i1 = min(Self.sampleCount, idx + 3)
            let p0 = curvePoint(frontDisp, i0)
            let p1 = curvePoint(frontDisp, i1)
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = sqrt(dx * dx + dy * dy)
            if len > 1 {
                let nx = dx / len * 18, ny = dy / len * 18
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
                ctx.setLineWidth(0.7)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.move(to: CGPoint(x: p.x - nx, y: p.y - ny))
                ctx.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }

            // Glow
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.03).cgColor)
            ctx.addArc(center: p, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.fillPath()

            // Dot
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
            ctx.addArc(center: p, radius: 3, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.fillPath()
        }

        ctx.restoreGState()
    }
}
