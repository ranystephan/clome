import AppKit
import WebKit

/// A pane that holds multiple surfaces (terminal, browser, etc.) with a tab bar.
/// This is the "Surface" level in the Window → Workspace → Pane → Surface hierarchy.
class SurfacePane: NSView, @preconcurrency TabBarDelegate, BrowserPanelDelegate {
    private let tabBar = TabBarView()
    private let contentView = NSView()
    private var surfaces: [NSView] = []
    private(set) var selectedIndex: Int = 0
    weak var ghosttyApp: GhosttyAppManager?

    var activeSurface: NSView? {
        guard selectedIndex >= 0, selectedIndex < surfaces.count else { return nil }
        return surfaces[selectedIndex]
    }

    var activeTerminal: TerminalSurface? {
        activeSurface as? TerminalSurface
    }

    var tabCount: Int { surfaces.count }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        tabBar.delegate = self
        setupLayout()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surfaceTitleChanged),
            name: .terminalSurfaceTitleChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func surfaceTitleChanged(_ note: Notification) {
        guard let view = note.object as? NSView, surfaces.contains(where: { $0 === view }) else { return }
        updateTabBar()
    }

    private func setupLayout() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        addSubview(contentView)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Surface Management

    func addTerminal() {
        guard let app = ghosttyApp else { return }
        let terminal = TerminalSurface(ghosttyApp: app)
        addSurface(terminal)
    }

    func addBrowser(url: String? = nil) {
        let browser = BrowserPanel()
        browser.delegate = self
        if let url {
            browser.loadURL(url)
        }
        addSurface(browser)
    }

    // MARK: - BrowserPanelDelegate

    func browserPanel(_ panel: BrowserPanel, openNewTabWith url: URL) -> Bool {
        let newBrowser = BrowserPanel()
        newBrowser.delegate = self
        addSurface(newBrowser)
        newBrowser.loadURL(url)
        return true
    }


    func addSurface(_ view: NSView) {
        surfaces.append(view)
        selectTab(surfaces.count - 1)
        updateTabBar()
    }

    func removeSurface(at index: Int) {
        guard index >= 0, index < surfaces.count else { return }
        let surface = surfaces.remove(at: index)
        if let terminal = surface as? TerminalSurface {
            terminal.destroySurface()
        }
        surface.removeFromSuperview()

        if surfaces.isEmpty {
            selectedIndex = -1
        } else if selectedIndex >= surfaces.count {
            selectTab(surfaces.count - 1)
        } else {
            selectTab(selectedIndex)
        }
        updateTabBar()
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < surfaces.count else { return }
        selectedIndex = index

        contentView.subviews.forEach { $0.removeFromSuperview() }
        let view = surfaces[index]
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Focus terminal
        if let terminal = view as? TerminalSurface {
            window?.makeFirstResponder(terminal)
        }

        updateTabBar()
    }

    private func updateTabBar() {
        let titles = surfaces.map { titleForSurface($0) }
        let icons = surfaces.map { surface -> NSImage? in
            if let browser = surface as? BrowserPanel {
                return browser.favicon
            }
            return nil
        }
        tabBar.updateTabs(titles: titles, icons: icons, selectedIndex: selectedIndex)
    }

    private func titleForSurface(_ surface: NSView) -> String {
        if let terminal = surface as? TerminalSurface {
            return terminal.title
        } else if let browser = surface as? BrowserPanel {
            return browser.title
        } else if let editor = surface as? EditorPanel {
            return editor.title
        } else if let pdf = surface as? PDFPanel {
            return pdf.title
        }
        return "Panel"
    }

    // MARK: - TabBarDelegate

    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int) {
        selectTab(index)
    }

    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int) {
        removeSurface(at: index)
    }

    func tabBarDidRequestNewTab(_ tabBar: TabBarView) {
        addTerminal()
    }
}
