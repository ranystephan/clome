import AppKit
import WebKit

/// A pane that holds multiple surfaces (terminal, browser, etc.) with a tab bar.
/// This is the "Surface" level in the Window → Workspace → Pane → Surface hierarchy.
class SurfacePane: NSView, TabBarDelegate, BrowserPanelDelegate {
    private let tabBar = TabBarView()
    private let contentView = NSView()
    private var surfaces: [NSView] = []
    private(set) var selectedIndex: Int = 0
    private var pendingFocusWork: DispatchWorkItem?
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
        guard let view = note.object as? NSView,
              let index = surfaces.firstIndex(where: { $0 === view }) else { return }
        let title = titleForSurface(view)
        let icon = (view as? BrowserPanel)?.favicon
        tabBar.updateTabTitle(at: index, title: title, icon: icon)
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


    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func addSurface(_ view: NSView) {
        surfaces.append(view)
        // Add to content view immediately with constraints, but hidden
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        // Rebuild tabs first so updateSelection operates on current tab views
        updateTabBar()
        selectTab(surfaces.count - 1)
    }

    func removeSurface(at index: Int) {
        guard index >= 0, index < surfaces.count else { return }
        let surface = surfaces.remove(at: index)
        if let terminal = surface as? TerminalSurface {
            terminal.destroySurface()
        }
        if let browser = surface as? BrowserPanel {
            browser.willClose()
        }
        surface.removeFromSuperview()

        // Rebuild tabs first so selectTab's updateSelection operates on current tab views
        updateTabBar()
        if surfaces.isEmpty {
            selectedIndex = -1
        } else if selectedIndex >= surfaces.count {
            selectTab(surfaces.count - 1)
        } else {
            selectTab(selectedIndex)
        }
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < surfaces.count else { return }
        guard index != selectedIndex || surfaces[index].isHidden else {
            tabBar.updateSelection(index: index)
            return
        }

        // Hide the previously selected surface
        if selectedIndex >= 0, selectedIndex < surfaces.count {
            surfaces[selectedIndex].isHidden = true
        }

        selectedIndex = index
        let view = surfaces[index]
        view.isHidden = false

        // Focus terminal on next runloop tick so it doesn't block click processing.
        // Cancel any pending focus from a previous rapid tab switch.
        pendingFocusWork?.cancel()
        if let terminal = view as? TerminalSurface {
            let work = DispatchWorkItem { [weak self, weak terminal] in
                guard let terminal else { return }
                self?.window?.makeFirstResponder(terminal)
            }
            pendingFocusWork = work
            DispatchQueue.main.async(execute: work)
        } else {
            pendingFocusWork = nil
        }

        tabBar.updateSelection(index: index)
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
