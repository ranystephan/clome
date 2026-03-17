import AppKit
import QuartzCore

// MARK: - Onboarding Window Controller

@MainActor
class OnboardingWindowController: NSWindowController {
    private static var shared: OnboardingWindowController?

    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "clome.onboardingComplete")
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: "clome.onboardingComplete")
    }

    static func showIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        show()
    }

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let ctrl = OnboardingWindowController()
        shared = ctrl
        ctrl.window?.makeKeyAndOrderFront(nil)
        ctrl.window?.center()
    }

    private var pages: [OnboardingPageView] = []
    private var currentPage = 0
    private var containerView: NSView!
    private var pageContainer: NSView!
    private var dotIndicator: DotIndicatorView!
    private var grainLayer: GrainOverlayView!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.024, green: 0.024, blue: 0.039, alpha: 1.0) // #06060A
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Colors.void.cgColor

        // Main container
        containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        contentView.addSubview(containerView)

        // Film grain overlay
        grainLayer = GrainOverlayView()
        grainLayer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grainLayer)

        // Page container (clips pages)
        pageContainer = NSView()
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.wantsLayer = true
        pageContainer.layer?.masksToBounds = true
        containerView.addSubview(pageContainer)

        // Dot indicator
        dotIndicator = DotIndicatorView(count: 4)
        dotIndicator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dotIndicator)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            grainLayer.topAnchor.constraint(equalTo: contentView.topAnchor),
            grainLayer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            grainLayer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            grainLayer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            pageContainer.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 32),
            pageContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: dotIndicator.topAnchor, constant: -16),

            dotIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            dotIndicator.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -28),
            dotIndicator.heightAnchor.constraint(equalToConstant: 8),
        ])

        buildPages()
        showPage(0, animated: false)
    }

    // MARK: - Pages

    private func buildPages() {
        let welcome = WelcomePage(onNext: { [weak self] in self?.nextPage() })
        let setup = EnvironmentSetupPage(onNext: { [weak self] in self?.nextPage() })
        let shortcuts = ShortcutsPage(onNext: { [weak self] in self?.nextPage() })
        let getStarted = GetStartedPage(onFinish: { [weak self] in self?.finish() })

        pages = [welcome, setup, shortcuts, getStarted]

        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            ])
            page.alphaValue = 0
            page.isHidden = true
        }
    }

    private func showPage(_ index: Int, animated: Bool) {
        guard index >= 0, index < pages.count else { return }
        let oldPage = pages[currentPage]
        let newPage = pages[index]
        currentPage = index
        dotIndicator.setActive(index)

        // Unhide new page, bring to front
        newPage.isHidden = false

        if animated {
            newPage.alphaValue = 0
            newPage.layer?.transform = CATransform3DMakeTranslation(40, 0, 0)

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                oldPage.animator().alphaValue = 0
                oldPage.animator().layer?.transform = CATransform3DMakeTranslation(-40, 0, 0)
            }, completionHandler: {
                oldPage.isHidden = true
            })

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    newPage.animator().alphaValue = 1
                    newPage.animator().layer?.transform = CATransform3DIdentity
                })
            }
        } else {
            // Hide all others
            for (i, page) in pages.enumerated() {
                page.isHidden = (i != index)
            }
            newPage.alphaValue = 1
            newPage.layer?.transform = CATransform3DIdentity
        }
    }

    private func nextPage() {
        showPage(currentPage + 1, animated: true)
    }

    private func finish() {
        OnboardingWindowController.markComplete()
        window?.close()
        OnboardingWindowController.shared = nil
    }
}

// MARK: - Design Tokens

private enum Colors {
    static let void       = NSColor(red: 0.024, green: 0.024, blue: 0.039, alpha: 1.0)
    static let voidSoft   = NSColor(red: 0.047, green: 0.047, blue: 0.078, alpha: 1.0)
    static let surface    = NSColor(red: 0.063, green: 0.063, blue: 0.102, alpha: 1.0)
    static let border     = NSColor(red: 0.110, green: 0.110, blue: 0.157, alpha: 1.0)
    static let copper     = NSColor(red: 0.710, green: 0.380, blue: 0.247, alpha: 1.0) // #B5613F
    static let copperLight = NSColor(red: 0.831, green: 0.518, blue: 0.369, alpha: 1.0) // #D4845E
    static let text       = NSColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 1.0) // #F0EDE8
    static let textDim    = NSColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 0.60)
    static let textMuted  = NSColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 0.30)
    static let green      = NSColor(red: 0.30, green: 0.75, blue: 0.45, alpha: 1.0)
    static let yellow     = NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1.0)
    static let red        = NSColor(red: 0.85, green: 0.35, blue: 0.35, alpha: 1.0)
}

private enum Fonts {
    static func display(size: CGFloat) -> NSFont {
        NSFont(name: "NewYorkLarge-Bold", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }

    static func displayRegular(size: CGFloat) -> NSFont {
        NSFont(name: "NewYorkLarge-Regular", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static func body(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }
}

// MARK: - Base Page View

@MainActor
class OnboardingPageView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// MARK: - Film Grain Overlay

@MainActor
private class GrainOverlayView: NSView {
    private var timer: Timer?

    // Let all mouse events pass through — equivalent to pointer-events: none
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0.035

        // ~6fps — slow film stock drift
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = Int(bounds.width)
        let h = Int(bounds.height)
        guard w > 0, h > 0 else { return }

        // Full resolution grain — no scaling artifacts
        let sw = w
        let sh = h
        let colorSpace = CGColorSpaceCreateDeviceGray()

        var pixels = [UInt8](repeating: 0, count: sw * sh)
        for i in 0 ..< pixels.count {
            pixels[i] = UInt8.random(in: 0...255)
        }

        pixels.withUnsafeBytes { buf in
            guard let baseAddress = buf.baseAddress else { return }
            if let bitmapCtx = CGContext(
                data: UnsafeMutableRawPointer(mutating: baseAddress),
                width: sw, height: sh,
                bitsPerComponent: 8, bytesPerRow: sw,
                space: colorSpace, bitmapInfo: 0
            ), let image = bitmapCtx.makeImage() {
                ctx.interpolationQuality = .low
                ctx.draw(image, in: bounds)
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
    }
}

// MARK: - Dot Page Indicator

private class DotIndicatorView: NSView {
    private let count: Int
    private var dots: [CALayer] = []
    private var activeIndex = 0

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        wantsLayer = true
        buildDots()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func buildDots() {
        let spacing: CGFloat = 12
        let dotSize: CGFloat = 6
        let totalWidth = CGFloat(count) * dotSize + CGFloat(count - 1) * (spacing - dotSize)

        for i in 0 ..< count {
            let dot = CALayer()
            dot.frame = CGRect(
                x: (bounds.width - totalWidth) / 2 + CGFloat(i) * spacing,
                y: 1,
                width: dotSize,
                height: dotSize
            )
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = Colors.textMuted.cgColor
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        dots.first?.backgroundColor = Colors.copper.cgColor
    }

    override func layout() {
        super.layout()
        let spacing: CGFloat = 12
        let dotSize: CGFloat = 6
        let totalWidth = CGFloat(count) * dotSize + CGFloat(count - 1) * (spacing - dotSize)
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(
                x: (bounds.width - totalWidth) / 2 + CGFloat(i) * spacing,
                y: 1,
                width: dotSize,
                height: dotSize
            )
        }
    }

    func setActive(_ index: Int) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        for (i, dot) in dots.enumerated() {
            dot.backgroundColor = (i == index ? Colors.copper : Colors.textMuted).cgColor
        }
        CATransaction.commit()
        activeIndex = index
    }
}

// MARK: - Copper Accent Line

@MainActor
private func makeCopperRule() -> NSView {
    let rule = NSView()
    rule.translatesAutoresizingMaskIntoConstraints = false
    rule.wantsLayer = true

    let grad = CAGradientLayer()
    grad.colors = [
        NSColor.clear.cgColor,
        Colors.copper.withAlphaComponent(0.5).cgColor,
        Colors.copper.cgColor,
        Colors.copper.withAlphaComponent(0.5).cgColor,
        NSColor.clear.cgColor,
    ]
    grad.startPoint = CGPoint(x: 0, y: 0.5)
    grad.endPoint = CGPoint(x: 1, y: 0.5)
    grad.locations = [0, 0.2, 0.5, 0.8, 1.0]
    rule.layer?.addSublayer(grad)

    rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

    // Layout gradient with the view
    class GradientLayoutView: NSView {
        override func layout() {
            super.layout()
            layer?.sublayers?.first?.frame = bounds
        }
    }

    return rule
}

// MARK: - Styled Button

@MainActor
private func makeButton(title: String, primary: Bool, action: Selector, target: AnyObject) -> NSButton {
    let btn = NSButton(frame: .zero)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.title = title
    btn.bezelStyle = .roundRect
    btn.isBordered = false
    btn.wantsLayer = true
    btn.target = target
    btn.action = action

    let font = Fonts.body(size: 14, weight: .semibold)
    let color = primary ? Colors.void : Colors.textDim

    let attrTitle = NSAttributedString(string: title, attributes: [
        .font: font,
        .foregroundColor: color,
    ])
    btn.attributedTitle = attrTitle

    if primary {
        btn.layer?.backgroundColor = Colors.copper.cgColor
        btn.layer?.cornerRadius = 10
    } else {
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.layer?.cornerRadius = 10
        btn.layer?.borderWidth = 1
        btn.layer?.borderColor = Colors.border.cgColor
    }

    btn.heightAnchor.constraint(equalToConstant: 42).isActive = true

    return btn
}

// MARK: - Page 1: Welcome

@MainActor
private class WelcomePage: OnboardingPageView {
    private let onNext: () -> Void

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init(frame: .zero)
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupContent() {
        // Logo
        let logoIcon = NSImageView()
        logoIcon.translatesAutoresizingMaskIntoConstraints = false
        logoIcon.imageScaling = .scaleProportionallyUpOrDown
        logoIcon.image = Bundle.main.image(forResource: "clome-logo")
        addSubview(logoIcon)

        // Title
        let title = NSTextField(labelWithString: "Welcome to Clome")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = Fonts.display(size: 32)
        title.textColor = Colors.text
        title.alignment = .center
        addSubview(title)

        // Copper rule
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Colors.copper.withAlphaComponent(0.3).cgColor
        addSubview(rule)

        // Subtitle
        let subtitle = NSTextField(wrappingLabelWithString: "A native development environment built for\nthe agentic era. No Electron. No compromise.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = Fonts.body(size: 15, weight: .light)
        subtitle.textColor = Colors.textDim
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3
        addSubview(subtitle)

        // Tech strip
        let techStrip = makeTechStrip()
        addSubview(techStrip)

        // Continue button
        let btn = makeButton(title: "Get Started", primary: true, action: #selector(nextTapped), target: self)
        addSubview(btn)

        // Meta line
        let meta = NSTextField(labelWithString: "macOS 14.0+  ·  Apple Silicon  ·  v0.1.0-alpha")
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.font = Fonts.mono(size: 11)
        meta.textColor = Colors.textMuted
        meta.alignment = .center
        addSubview(meta)

        NSLayoutConstraint.activate([
            logoIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            logoIcon.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            logoIcon.widthAnchor.constraint(equalToConstant: 96),
            logoIcon.heightAnchor.constraint(equalToConstant: 96),

            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: logoIcon.bottomAnchor, constant: 16),

            rule.centerXAnchor.constraint(equalTo: centerXAnchor),
            rule.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            rule.widthAnchor.constraint(equalToConstant: 48),
            rule.heightAnchor.constraint(equalToConstant: 1),

            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 400),

            techStrip.centerXAnchor.constraint(equalTo: centerXAnchor),
            techStrip.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),

            btn.centerXAnchor.constraint(equalTo: centerXAnchor),
            btn.topAnchor.constraint(equalTo: techStrip.bottomAnchor, constant: 28),
            btn.widthAnchor.constraint(equalToConstant: 180),

            meta.centerXAnchor.constraint(equalTo: centerXAnchor),
            meta.topAnchor.constraint(equalTo: btn.bottomAnchor, constant: 16),
            meta.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])

    }

    private func makeTechStrip() -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 24

        let items = ["Swift + AppKit", "Metal", "libghostty", "CoreText", "LSP"]
        for item in items {
            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true

            let label = NSTextField(labelWithString: item)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = Fonts.mono(size: 10)
            label.textColor = Colors.textMuted
            pill.addSubview(label)

            // Copper dot
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = Colors.copper.withAlphaComponent(0.4).cgColor
            dot.layer?.cornerRadius = 2
            pill.addSubview(dot)

            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 4),
                dot.heightAnchor.constraint(equalToConstant: 4),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
                label.topAnchor.constraint(equalTo: pill.topAnchor),
                label.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
                label.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            ])

            stack.addArrangedSubview(pill)
        }

        return stack
    }

    @objc private func nextTapped() {
        onNext()
    }
}

// MARK: - Page 2: Environment Setup

@MainActor
private class EnvironmentSetupPage: OnboardingPageView {
    private let onNext: () -> Void
    private var checkRows: [(label: String, detail: String, status: NSView)] = []

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init(frame: .zero)
        setupContent()
        runChecks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupContent() {
        // Section label
        let label = NSTextField(labelWithString: "ENVIRONMENT")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Fonts.mono(size: 11)
        label.textColor = Colors.copper
        addSubview(label)

        // Title
        let title = NSTextField(labelWithString: "Your setup")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = Fonts.display(size: 28)
        title.textColor = Colors.text
        addSubview(title)

        // Description
        let desc = NSTextField(wrappingLabelWithString: "Optional tools that enhance your experience.")
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.font = Fonts.body(size: 14, weight: .light)
        desc.textColor = Colors.textDim
        addSubview(desc)

        // Check items
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        addSubview(stack)

        let checks: [(String, String)] = [
            ("Git", "File explorer status indicators"),
            ("Language Servers", "Completions, diagnostics, go-to-definition"),
            ("Python", "Jupyter notebook kernel execution"),
            ("Xcode CLT", "sourcekit-lsp for Swift development"),
        ]

        for (name, detail) in checks {
            let row = makeCheckRow(name: name, detail: detail)
            stack.addArrangedSubview(row.view)
            row.view.widthAnchor.constraint(equalToConstant: 460).isActive = true
            checkRows.append((name, detail, row.statusDot))
        }

        // Continue button
        let btn = makeButton(title: "Continue", primary: true, action: #selector(nextTapped), target: self)
        addSubview(btn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 32),

            title.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            title.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),

            desc.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            desc.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            desc.widthAnchor.constraint(lessThanOrEqualToConstant: 400),

            stack.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            stack.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),

            btn.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            btn.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
            btn.widthAnchor.constraint(equalToConstant: 140),
            btn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    private func makeCheckRow(name: String, detail: String) -> (view: NSView, statusDot: NSView) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true

        // Top border
        let border = NSView()
        border.translatesAutoresizingMaskIntoConstraints = false
        border.wantsLayer = true
        border.layer?.backgroundColor = Colors.border.cgColor
        row.addSubview(border)

        // Status dot (starts as dim, will be colored after check)
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Colors.textMuted.cgColor
        dot.layer?.cornerRadius = 4
        row.addSubview(dot)

        // Name
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Fonts.body(size: 14, weight: .medium)
        nameLabel.textColor = Colors.text
        row.addSubview(nameLabel)

        // Detail
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = Fonts.mono(size: 11)
        detailLabel.textColor = Colors.textMuted
        row.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: row.topAnchor),
            border.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ])

        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return (row, dot)
    }

    private func runChecks() {
        let checkers: [() -> Bool] = [
            { Self.commandExists("git") },
            { Self.commandExists("sourcekit-lsp") || Self.commandExists("pyright") || Self.commandExists("typescript-language-server") || Self.commandExists("gopls") },
            { Self.commandExists("python3") || Self.commandExists("python") },
            { FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp") || Self.commandExists("xcrun") },
        ]

        for (i, check) in checkers.enumerated() {
            let delay = 0.3 + Double(i) * 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let found = check()
                let dot = self.checkRows[i].status
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    dot.layer?.backgroundColor = (found ? Colors.green : Colors.yellow).cgColor
                }
                // Add glow
                if found {
                    dot.layer?.shadowColor = Colors.green.cgColor
                    dot.layer?.shadowRadius = 6
                    dot.layer?.shadowOpacity = 0.5
                    dot.layer?.shadowOffset = .zero
                }
            }
        }
    }

    private static func commandExists(_ cmd: String) -> Bool {
        let process = Process()
        process.launchPath = "/usr/bin/which"
        process.arguments = [cmd]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @objc private func nextTapped() {
        onNext()
    }
}

// MARK: - Page 3: Shortcuts

@MainActor
private class ShortcutsPage: OnboardingPageView {
    private let onNext: () -> Void

    init(onNext: @escaping () -> Void) {
        self.onNext = onNext
        super.init(frame: .zero)
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupContent() {
        // Section label
        let label = NSTextField(labelWithString: "KEYBOARD")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Fonts.mono(size: 11)
        label.textColor = Colors.copper
        addSubview(label)

        // Title
        let title = NSTextField(labelWithString: "Essential shortcuts")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = Fonts.display(size: 28)
        title.textColor = Colors.text
        addSubview(title)

        // Shortcuts grid
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        addSubview(stack)

        let shortcuts: [(String, String)] = [
            ("\u{2318}D", "Split pane right"),
            ("\u{2318}\u{21E7}D", "Split pane down"),
            ("\u{2318}\u{2325}Click", "Add cursor"),
            ("\u{2318}D", "Select next occurrence"),
            ("\u{2318}F", "Find in file"),
            ("\u{2318}O", "Open file"),
            ("\u{2318}\u{2303}S", "Toggle sidebar"),
            ("F12", "Go to definition"),
        ]

        for (key, desc) in shortcuts {
            let row = makeShortcutRow(key: key, description: desc)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }

        // Continue button
        let btn = makeButton(title: "Continue", primary: true, action: #selector(nextTapped), target: self)
        addSubview(btn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 80),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 24),

            title.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            title.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),

            stack.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),

            btn.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            btn.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            btn.widthAnchor.constraint(equalToConstant: 140),
            btn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    private func makeShortcutRow(key: String, description: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true

        // Border
        let border = NSView()
        border.translatesAutoresizingMaskIntoConstraints = false
        border.wantsLayer = true
        border.layer?.backgroundColor = Colors.border.cgColor
        row.addSubview(border)

        // Key badge
        let keyBadge = NSTextField(labelWithString: key)
        keyBadge.translatesAutoresizingMaskIntoConstraints = false
        keyBadge.font = Fonts.mono(size: 12)
        keyBadge.textColor = Colors.copperLight
        keyBadge.wantsLayer = true
        keyBadge.layer?.backgroundColor = Colors.copper.withAlphaComponent(0.08).cgColor
        keyBadge.layer?.cornerRadius = 5
        keyBadge.layer?.borderWidth = 1
        keyBadge.layer?.borderColor = Colors.copper.withAlphaComponent(0.2).cgColor
        // Padding via insets isn't easy on NSTextField, use alignment rect
        row.addSubview(keyBadge)

        // Wrap key badge with padding
        let keyContainer = NSView()
        keyContainer.translatesAutoresizingMaskIntoConstraints = false
        keyContainer.wantsLayer = true
        keyContainer.layer?.backgroundColor = Colors.copper.withAlphaComponent(0.08).cgColor
        keyContainer.layer?.cornerRadius = 5
        keyContainer.layer?.borderWidth = 1
        keyContainer.layer?.borderColor = Colors.copper.withAlphaComponent(0.2).cgColor
        row.addSubview(keyContainer)

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.font = Fonts.mono(size: 11)
        keyLabel.textColor = Colors.copperLight
        keyContainer.addSubview(keyLabel)

        // Remove the raw keyBadge, use container instead
        keyBadge.removeFromSuperview()

        // Description
        let descLabel = NSTextField(labelWithString: description)
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = Fonts.body(size: 13, weight: .regular)
        descLabel.textColor = Colors.textDim
        row.addSubview(descLabel)

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: row.topAnchor),
            border.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            keyContainer.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            keyContainer.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            keyLabel.topAnchor.constraint(equalTo: keyContainer.topAnchor, constant: 4),
            keyLabel.bottomAnchor.constraint(equalTo: keyContainer.bottomAnchor, constant: -4),
            keyLabel.leadingAnchor.constraint(equalTo: keyContainer.leadingAnchor, constant: 8),
            keyLabel.trailingAnchor.constraint(equalTo: keyContainer.trailingAnchor, constant: -8),

            keyContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            descLabel.leadingAnchor.constraint(equalTo: keyContainer.trailingAnchor, constant: 16),
            descLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            row.heightAnchor.constraint(equalToConstant: 36),
        ])

        return row
    }

    @objc private func nextTapped() {
        onNext()
    }
}

// MARK: - Page 4: Get Started

@MainActor
private class GetStartedPage: OnboardingPageView {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(frame: .zero)
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupContent() {
        // Big centered title
        let title = NSTextField(labelWithString: "Start building")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = Fonts.display(size: 36)
        title.textColor = Colors.text
        title.alignment = .center
        addSubview(title)

        // Copper rule
        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Colors.copper.withAlphaComponent(0.3).cgColor
        addSubview(rule)

        // Subtitle
        let subtitle = NSTextField(wrappingLabelWithString: "Open a project folder or start a new terminal.\nClome is ready when you are.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = Fonts.body(size: 15, weight: .light)
        subtitle.textColor = Colors.textDim
        subtitle.alignment = .center
        addSubview(subtitle)

        // Action buttons
        let openBtn = makeButton(title: "Open a Project", primary: true, action: #selector(openProject), target: self)
        let termBtn = makeButton(title: "New Terminal", primary: false, action: #selector(startTerminal), target: self)

        let btnStack = NSStackView(views: [openBtn, termBtn])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.orientation = .horizontal
        btnStack.spacing = 12
        addSubview(btnStack)

        // Footnote
        let footnote = NSTextField(wrappingLabelWithString: "You can reopen this guide from\nClome \u{2192} Settings at any time.")
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnote.font = Fonts.body(size: 12, weight: .light)
        footnote.textColor = Colors.textMuted
        footnote.alignment = .center
        addSubview(footnote)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 100),

            rule.centerXAnchor.constraint(equalTo: centerXAnchor),
            rule.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            rule.widthAnchor.constraint(equalToConstant: 48),
            rule.heightAnchor.constraint(equalToConstant: 1),

            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 20),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            btnStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            btnStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 40),

            openBtn.widthAnchor.constraint(equalToConstant: 160),
            termBtn.widthAnchor.constraint(equalToConstant: 160),

            footnote.centerXAnchor.constraint(equalTo: centerXAnchor),
            footnote.topAnchor.constraint(equalTo: btnStack.bottomAnchor, constant: 32),
        ])
    }

    @objc private func openProject() {
        onFinish()

        // Open folder picker
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Post notification for the main window to handle
            NotificationCenter.default.post(
                name: .init("clomeOpenProjectFolder"),
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    @objc private func startTerminal() {
        onFinish()
    }
}
