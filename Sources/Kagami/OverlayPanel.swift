import AppKit

/// Schwebendes Fenster, das auf allen Spaces liegt – auch über Vollbild-Apps.
/// Es wird nie "key" und aktiviert Kagami nicht, damit Tastatureingaben bei der
/// gehosteten App bzw. der Vollbild-App bleiben.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        buttons.forEach { standardWindowButton($0)?.isHidden = true }

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        backgroundColor = .black
        hasShadow = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 320, height: 220)
    }

    /// Nur während der Starter sichtbar ist, darf das Overlay Tastatureingaben bekommen
    /// (für das Suchfeld). Sonst gehen alle Tasten an die gehostete App.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Während das Overlay zur Seite geschoben ist (Mission Control / Schreibtisch),
    /// darf es über den Bildschirmrand hinaus.
    var allowsOffscreen = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Button, der auch im inaktiven Fenster beim ersten Klick reagiert.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Schmale Leiste oben: zum Verschieben des Overlays, plus Bedienelemente.
@MainActor
final class TopBar: NSView {
    static let height: CGFloat = 30

    let titleLabel = NSTextField(labelWithString: "Kagami")
    let addButton = TopBar.button("plus", tip: "App starten oder hineinholen")
    let fitButton = TopBar.button("macwindow", tip: "Fenster an Bildschirm anpassen")
    let fullscreenButton = TopBar.button("arrow.up.left.and.arrow.down.right", tip: "Vollbild umschalten (⌃⌥F)")
    let menuButton = TopBar.button("ellipsis.circle", tip: "Optionen")
    let hideButton = TopBar.button("eye.slash", tip: "Overlay ausblenden (⌃⌥K)")
    /// Tabs der gehosteten Apps (Icon pro App).
    private let appStack = NSStackView()
    var onSelectApp: (@MainActor (pid_t) -> Void)?
    var onAppMenu: (@MainActor (pid_t, NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.85, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let left = NSStackView(views: [addButton, fitButton, fullscreenButton])
        let right = NSStackView(views: [menuButton, hideButton])
        for stack in [left, right] {
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        addSubview(titleLabel)

        appStack.spacing = 2
        appStack.translatesAutoresizingMaskIntoConstraints = false
        appStack.setHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(appStack)

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8),
            appStack.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultHigh),
            appStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            appStack.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
            appStack.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Tabs für die gehosteten Apps setzen; `active` wird hervorgehoben.
    func setApps(_ apps: [(pid: pid_t, name: String, icon: NSImage?)], active: pid_t?) {
        appStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titleLabel.isHidden = !apps.isEmpty
        for app in apps {
            let tab = AppTabButton(pid: app.pid, icon: app.icon, name: app.name, active: app.pid == active)
            tab.onClick = { [weak self] pid in self?.onSelectApp?(pid) }
            tab.onRightClick = { [weak self] pid, view in self?.onAppMenu?(pid, view) }
            appStack.addArrangedSubview(tab)
        }
    }

    private static func button(_ symbol: String, tip: String) -> FirstMouseButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = FirstMouseButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = NSColor(white: 0.85, alpha: 1)
        button.toolTip = tip
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

/// Ein App-Tab in der oberen Leiste: Klick = wechseln, Rechtsklick = Menü.
@MainActor
final class AppTabButton: NSView {
    let pid: pid_t
    var onClick: (@MainActor (pid_t) -> Void)?
    var onRightClick: (@MainActor (pid_t, NSView) -> Void)?
    private var trackingArea: NSTrackingArea?
    private let active: Bool
    private var hovering = false { didSet { updateBackground() } }

    init(pid: pid_t, icon: NSImage?, name: String, active: Bool) {
        self.pid = pid
        self.active = active
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = active ? "\(name) (aktiv) – Rechtsklick für mehr" : "\(name) – Klick zum Wechseln, Rechtsklick für mehr"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true

        let imageView = NSImageView(frame: NSRect(x: 6, y: 3, width: 18, height: 18))
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        if active {   // kleiner Balken unter dem aktiven Tab
            let bar = NSView(frame: NSRect(x: 9, y: 0, width: 12, height: 2))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            bar.layer?.cornerRadius = 1
            addSubview(bar)
        }
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    private func updateBackground() {
        let alpha: CGFloat = active ? 0.2 : (hovering ? 0.1 : 0)
        layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?(pid, self) }
    }
    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control),
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(pid)
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(pid, self) }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// Bewegt ein Fenster flüssig im Takt des Bildschirms (auch 120 Hz) – deutlich direkter
/// als `animator().setFrame`, das spürbar hinterherzieht.
@MainActor
final class WindowMover: NSObject {
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var from = NSPoint.zero
    private var to = NSPoint.zero
    private var fromAlpha: CGFloat = 1
    private var toAlpha: CGFloat = 1
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.2
    private var completion: (@MainActor () -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    var isAnimating: Bool { link != nil }
    /// Ziel der laufenden (bzw. letzten) Bewegung.
    var targetOrigin: NSPoint { to }

    /// `screen`: Bildschirm, dessen Takt benutzt wird. Wichtig: Ein Display-Link am Fenster
    /// selbst bleibt stehen, sobald das Fenster unsichtbar/außerhalb des Bildschirms ist.
    func move(to origin: NSPoint, alpha: CGFloat, duration: CFTimeInterval, on screen: NSScreen?,
              completion: (@MainActor () -> Void)? = nil) {
        guard let window else { return }
        stop()
        from = window.frame.origin
        to = origin
        fromAlpha = window.alphaValue
        toAlpha = alpha
        self.duration = max(duration, 0.01)
        self.completion = completion
        start = CACurrentMediaTime()
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            finish()
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // Sicherheitsnetz: Kommt der Takt nicht, trotzdem am Ziel ankommen.
        let startedAt = start
        onMain(after: duration + 0.3) { [weak self] in
            guard let self, self.link != nil, self.start == startedAt else { return }
            self.finish()
        }
    }

    /// Laufende Bewegung abbrechen (ohne Abschluss).
    func stop() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { stop(); return }
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        let eased = CGFloat(1 - pow(1 - t, 3))   // ease-out: sofort schnell, weich am Ende
        window.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased))
        window.alphaValue = fromAlpha + (toAlpha - fromAlpha) * eased
        if t >= 1 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        window?.setFrameOrigin(to)
        window?.alphaValue = toAlpha
        let done = completion
        completion = nil
        done?()
    }
}
