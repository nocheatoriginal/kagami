import AppKit

/// Eine installierte App für den Starter.
struct InstalledApp {
    let url: URL
    let name: String
    let bundleID: String?
}

/// Startbildschirm im Overlay: alle installierten Apps mit Suche – ein Klick startet die App
/// direkt auf dem Kagami-Bildschirm (bzw. holt sie hinein, wenn sie schon läuft).
@MainActor
final class LauncherView: NSView, NSSearchFieldDelegate {
    var onLaunch: (@MainActor (URL) -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onDropApps: (@MainActor ([URL]) -> Void)?
    /// Wird gerufen, wenn das Suchfeld Tastatureingaben braucht (Overlay darf dann "key" werden).
    var onNeedsKeyboard: (@MainActor () -> Void)?

    private let background = NSVisualEffectView()
    private let searchField = KeySearchField()
    private let closeButton = FirstMouseButton()
    private let scrollView = NSScrollView()
    private let grid = AppGridView()
    private var allApps: [InstalledApp] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        searchField.placeholderString = "App suchen …"
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onMouseDown = { [weak self] in self?.onNeedsKeyboard?() }
        addSubview(searchField)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Schließen")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Starter schließen (esc)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        grid.onSelect = { [weak self] app in self?.onLaunch?(app.url) }
        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            searchField.centerXAnchor.constraint(equalTo: centerXAnchor),
            searchField.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5, constant: 40),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            closeButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    // Klicks/Scrollen sollen nicht zum Stream darunter durchfallen.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    /// Liste neu einlesen (laufende Apps markieren) und Suche zurücksetzen.
    func reload() {
        allApps = Self.scanInstalledApps()
        searchField.stringValue = ""
        applyFilter()
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func closeTapped() { onClose?() }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let apps = query.isEmpty ? allApps : allApps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
        grid.set(apps: apps, running: running)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let first = grid.apps.first { onLaunch?(first.url) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { onClose?() } else { searchField.stringValue = ""; applyFilter() }
            return true
        default:
            return false
        }
    }

    // MARK: Drag & Drop

    private func appURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "app" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        appURLs(from: sender).isEmpty ? [] : .link
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = appURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropApps?(urls)
        return true
    }

    // MARK: Apps finden

    static func scanInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", home.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var result: [InstalledApp] = []

        func add(_ url: URL) {
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier
            let key = id ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            result.append(InstalledApp(url: url, name: name, bundleID: id))
        }

        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let items = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          item.lastPathComponent != "Utilities" {
                    // Eine Ebene tiefer, z.B. /Applications/Adobe Photoshop/…app
                    let sub = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? []
                    sub.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        // Kagami selbst (jede Kopie) nicht anbieten.
        result.removeAll { SingleInstance.isKagami(bundleID: $0.bundleID) || $0.url.lastPathComponent == "Kagami.app" }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Suchfeld, das meldet, wenn es angeklickt wird (damit das Overlay Tastatur bekommen kann).
final class KeySearchField: NSSearchField {
    var onMouseDown: (@MainActor () -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

/// Einfaches Icon-Raster (flipped), das seine Kacheln selbst anordnet.
@MainActor
final class AppGridView: NSView {
    var onSelect: (@MainActor (InstalledApp) -> Void)?
    private(set) var apps: [InstalledApp] = []
    private var tiles: [AppTile] = []

    private let tileSize = CGSize(width: 96, height: 98)
    private let spacing: CGFloat = 6
    private let inset: CGFloat = 18

    private var trackingArea: NSTrackingArea?
    private weak var observedClipView: NSClipView?
    private weak var hoveredTile: AppTile?

    override var isFlipped: Bool { true }

    func set(apps: [InstalledApp], running: Set<String>) {
        self.apps = apps
        hoveredTile = nil
        tiles.forEach { $0.removeFromSuperview() }
        tiles = apps.map { app in
            let tile = AppTile(app: app, isRunning: app.bundleID.map(running.contains) ?? false)
            tile.onClick = { [weak self] in self?.onSelect?(app) }
            addSubview(tile)
            return tile
        }
        needsLayout = true
        relayout()
        updateHover()
    }

    // MARK: Hover – genau eine Kachel unter dem Mauszeiger

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Beim Scrollen wandert der Inhalt unter dem Cursor weg → Hover neu bestimmen.
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        observedClipView = clip
    }

    @objc private func clipViewScrolled() { updateHover() }

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// Kachel unter der aktuellen Mausposition hervorheben (alle anderen nicht).
    func updateHover() {
        guard let window else { return setHovered(nil) }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = visibleRect.contains(point)
        setHovered(visible ? tiles.first { $0.frame.contains(point) } : nil)
    }

    private func setHovered(_ tile: AppTile?) {
        guard tile !== hoveredTile else { return }
        hoveredTile?.highlighted = false
        tile?.highlighted = true
        hoveredTile = tile
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        let columns = max(1, Int((width - 2 * inset + spacing) / (tileSize.width + spacing)))
        let rowWidth = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * spacing
        let startX = max(inset, (width - rowWidth) / 2)
        for (index, tile) in tiles.enumerated() {
            let row = index / columns, col = index % columns
            tile.frame = CGRect(x: startX + CGFloat(col) * (tileSize.width + spacing),
                                y: 8 + CGFloat(row) * (tileSize.height + spacing),
                                width: tileSize.width, height: tileSize.height)
        }
        let rows = (tiles.count + columns - 1) / columns
        let height = 8 + CGFloat(rows) * (tileSize.height + spacing) + inset
        let newSize = CGSize(width: width, height: max(height, enclosingScrollView?.contentSize.height ?? 0))
        if frame.size != newSize { setFrameSize(newSize) }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        relayout()
    }
}

/// Eine Kachel: Icon + Name, Hover-Hervorhebung, Punkt für "läuft bereits".
@MainActor
final class AppTile: NSView {
    var onClick: (@MainActor () -> Void)?
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let runningDot = NSView()
    /// Wird vom Raster gesetzt – es ist immer höchstens eine Kachel hervorgehoben.
    var highlighted = false {
        didSet { layer?.backgroundColor = highlighted ? NSColor(white: 1, alpha: 0.12).cgColor : nil }
    }

    init(app: InstalledApp, isRunning: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        toolTip = isRunning ? "\(app.name) – läuft bereits, wird hineingeholt" : app.name

        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 56, height: 56)
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = CGRect(x: 20, y: 6, width: 56, height: 56)
        addSubview(imageView)

        label.stringValue = app.name
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = CGRect(x: 4, y: 66, width: 88, height: 16)
        addSubview(label)

        runningDot.wantsLayer = true
        runningDot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        runningDot.layer?.cornerRadius = 2
        runningDot.frame = CGRect(x: 46, y: 86, width: 4, height: 4)
        runningDot.isHidden = !isRunning
        addSubview(runningDot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil   // Klicks auf Icon/Label gehen an die Kachel
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
