import AppKit
import Carbon.HIToolbox

/// Fenster des Kagami-Schreibtischs. Darf (anders als das Overlay) key werden,
/// damit der Starter dort Tastatureingaben bekommt.
final class KagamiSpaceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Der Kagami-Schreibtisch: ein eigener Space auf dem Hauptbildschirm.
///
/// Ein normales Fenster im nativen Vollbildmodus bekommt von macOS automatisch einen
/// eigenen Space – der taucht in Mission Control als „Kagami“ auf und ist ganz normal per
/// Drei-Finger-Wischen erreichbar. Das Fenster zeigt den virtuellen Monitor bildschirmfüllend.
///
/// Der Space existiert, solange Kagami läuft – unabhängig davon, ob das Overlay
/// ein- oder ausgeblendet ist.
@MainActor
final class KagamiSpace: NSObject, NSWindowDelegate {
    let window: KagamiSpaceWindow
    let streamView = StreamView()
    let launcher = LauncherView()

    /// Der Kagami-Schreibtisch ist gerade der aktive Space.
    private(set) var isActive = false
    var onActiveChange: (@MainActor (Bool) -> Void)?
    /// Der Kagami-Schreibtisch ist (zumindest teilweise) zu sehen – schon während man
    /// hineinwischt. So kann die Auflösung umgestellt werden, bevor die Geste fertig ist.
    private(set) var isVisible = false
    var onVisibleChange: (@MainActor (Bool) -> Void)?

    /// Maus-Events werden direkt an die gehostete App weitergereicht. Darf nicht über das
    /// eigene Fenster laufen: Ein Klick auf ein normales Fenster würde Kagami aktivieren,
    /// und dann landen Tastatur und Klick bei Kagami statt bei der App.
    weak var inputForwarder: InputForwarder?
    /// Gibt es gerade etwas, an das Eingaben gehen können?
    var canForwardInput: (@MainActor () -> Bool)?
    private var tap: CFMachPort?
    private var dragging = false
    /// Während Mission Control zählt „sichtbar“ nicht (dort ist nur die Vorschau zu sehen).
    var suppressesPreview = false {
        didSet { checkActive() }
    }
    /// Apps aus dem Starter bzw. per Drag & Drop.
    var onLaunch: (@MainActor ([URL]) -> Void)?

    private var enabled = false
    /// Vollbild steht und der Wechsel zurück nach dem Anlegen ist erledigt.
    private var ready = false
    private var awaitingReturn = false
    private var returnTo: NSRunningApplication?
    private var createAttempts = 0
    private var spaceObserver: NSObjectProtocol?

    /// Größe des Bildschirms, auf dem der Space liegt (Punkte).
    var screenSize: CGSize {
        (window.screen ?? NSScreen.screens.first)?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    var exists: Bool { window.styleMask.contains(.fullScreen) }

    init(streamDelegate: StreamViewDelegate) {
        let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = KagamiSpaceWindow(contentRect: frame,
                                   styleMask: [.titled, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        super.init()

        window.title = "Kagami"   // so heißt der Space in Mission Control
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .none
        window.delegate = self

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        streamView.delegate = streamDelegate
        streamView.translatesAutoresizingMaskIntoConstraints = false

        launcher.translatesAutoresizingMaskIntoConstraints = false
        launcher.isHidden = true
        launcher.onLaunch = { [weak self] url in self?.onLaunch?([url]) }
        launcher.onDropApps = { [weak self] urls in self?.onLaunch?(urls) }
        launcher.onClose = { [weak self] in self?.hideLauncher() }
        launcher.onNeedsKeyboard = { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKey()
        }

        container.addSubview(streamView)
        container.addSubview(launcher)
        NSLayoutConstraint.activate([
            streamView.topAnchor.constraint(equalTo: container.topAnchor),
            streamView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            streamView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            streamView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            launcher.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            launcher.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            launcher.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.6),
            launcher.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.7),
        ])
        window.contentView = container

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
    }

    // MARK: Anlegen / Entfernen

    /// Space anlegen (und danach dorthin zurück, wo man vorher war).
    func enable() {
        enabled = true
        createAttempts = 0
        create()
    }

    /// Space entfernen.
    func disable() {
        enabled = false
        ready = false
        checkActive()
        if exists { window.toggleFullScreen(nil) } else { window.orderOut(nil) }
    }

    private func create() {
        guard enabled, !exists else { return }
        ready = false
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { returnTo = front }

        // Immer auf dem Hauptbildschirm – nie auf dem virtuellen Monitor.
        if let screen = NSScreen.screens.first { window.setFrame(screen.visibleFrame, display: false) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        onMain(after: 0.15) { [weak self] in
            guard let self, self.enabled, !self.exists else { return }
            self.window.toggleFullScreen(nil)
            // Falls macOS den Vollbildmodus verweigert hat: noch ein paar Versuche.
            onMain(after: 3) { [weak self] in
                guard let self, self.enabled, !self.exists else { return }
                self.window.orderOut(nil)
                self.createAttempts += 1
                if self.createAttempts < 3 {
                    self.create()
                } else {
                    NSLog("[Kagami] Kagami-Schreibtisch konnte nicht angelegt werden")
                }
            }
        }
    }

    /// Nach dem Anlegen steht man auf dem neuen Space – zurück zum vorherigen.
    private func returnToPreviousSpace() {
        awaitingReturn = true
        // 1. Versuch: vorherige App aktivieren – macOS wechselt dann zu ihrem Space.
        if let app = returnTo, !app.isTerminated { app.activate(options: []) }
        returnTo = nil

        // 2. Versuch: „Einen Space nach links“ (⌃←). Der neue Vollbild-Space liegt immer
        // direkt rechts neben dem, auf dem man war.
        onMain(after: 1.2) { [weak self] in
            guard let self, self.awaitingReturn else { return }
            self.awaitingReturn = false
            if self.window.isOnActiveSpace { Self.postMoveOneSpaceLeft() }
            onMain(after: 1.0) { [weak self] in self?.finishCreate() }
        }
    }

    private func finishCreate() {
        guard enabled, exists else { return }
        ready = true
        checkActive()
    }

    private static func postMoveOneSpaceLeft() {
        let source = CGEventSource(stateID: .hidSystemState)
        // Echte Pfeiltasten tragen zusätzlich die Fn- und Ziffernblock-Flags.
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow),
                                      keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Wechseln

    /// Zum Kagami-Schreibtisch wechseln.
    func reveal() {
        guard exists else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showLauncher() {
        guard launcher.isHidden else { return }
        launcher.reload()
        launcher.isHidden = false
    }

    func hideLauncher() {
        guard !launcher.isHidden else { return }
        launcher.isHidden = true
        window.makeFirstResponder(nil)
    }

    private func activeSpaceChanged() {
        if awaitingReturn, !window.isOnActiveSpace {
            // Zurückwechseln nach dem Anlegen hat geklappt.
            awaitingReturn = false
            onMain(after: 0.3) { [weak self] in self?.finishCreate() }
            return
        }
        onMain(after: 0.05) { [weak self] in self?.checkActive() }
    }

    private func checkActive() {
        let usable = enabled && ready && exists
        let active = usable && window.isOnActiveSpace
        let visible = active || (usable && !suppressesPreview && window.occlusionState.contains(.visible))
        if visible != isVisible {
            isVisible = visible
            onVisibleChange?(visible)
        }
        guard active != isActive else { return }
        isActive = active
        setInputCapture(active)
        onActiveChange?(active)
    }

    // MARK: Eingaben

    private func setInputCapture(_ on: Bool) {
        dragging = false
        if on, tap == nil { createTap() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    private func createTap() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let space = Unmanaged<KagamiSpace>.fromOpaque(refcon).takeUnretainedValue()
            let consumed = MainActor.assumeIsolated { space.handleTapped(type: type, event: event) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[Kagami] Event-Tap konnte nicht angelegt werden (Bedienungshilfen?)")
            return
        }
        NSLog("[Kagami] Event-Tap für den Kagami-Schreibtisch aktiv")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
    }

    /// `true` = Event wurde an die gehostete App weitergereicht und wird verschluckt.
    private func handleTapped(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isActive, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // Eigene, weitergeleitete Events nie erneut abfangen.
        if event.getIntegerValueField(.eventSourceUserData) == InputForwarder.eventMarker { return false }
        guard isActive, launcher.isHidden, let forwarder = inputForwarder,
              canForwardInput?() ?? false else { return false }

        let screenFrame = (window.screen ?? NSScreen.screens.first)?.frame ?? .zero
        let screenRect = Geometry.cgRect(fromCocoa: screenFrame)
        let location = event.location
        // Nur Events auf diesem Bildschirm (vom InputForwarder erzeugte Events liegen
        // auf dem virtuellen Display und laufen unverändert durch).
        guard screenRect.contains(location) else { return false }

        // Menüleiste, Dock, Mitteilungen usw. bleiben normal bedienbar.
        let windowUnder = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let overUs = windowUnder == 0 || windowUnder == Int64(window.windowNumber)
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        if !overUs, !(dragging && !isDown) { return false }

        guard let point = streamView.displayPoint(forScreenPoint: location, screenRect: screenRect,
                                                  clamp: dragging && !isDown) else {
            return isDown   // Klick neben das Bild: verschlucken, damit Kagami nicht aktiv wird
        }
        let flags = event.flags
        let clicks = Int(event.getIntegerValueField(.mouseEventClickState))

        switch type {
        case .leftMouseDown:
            dragging = true
            forwarder.mouseDown(.left, at: point, clickCount: clicks, flags: flags)
        case .leftMouseDragged:
            forwarder.mouseDragged(.left, at: point, flags: flags)
        case .leftMouseUp:
            dragging = false
            forwarder.mouseUp(.left, at: point, clickCount: clicks, flags: flags)
        case .rightMouseDown:
            dragging = true
            forwarder.mouseDown(.right, at: point, clickCount: clicks, flags: flags)
        case .rightMouseDragged:
            forwarder.mouseDragged(.right, at: point, flags: flags)
        case .rightMouseUp:
            dragging = false
            forwarder.mouseUp(.right, at: point, clickCount: clicks, flags: flags)
        case .otherMouseDown:
            dragging = true
            forwarder.mouseDown(.center, at: point, clickCount: clicks, flags: flags)
        case .otherMouseDragged:
            forwarder.mouseDragged(.center, at: point, flags: flags)
        case .otherMouseUp:
            dragging = false
            forwarder.mouseUp(.center, at: point, clickCount: clicks, flags: flags)
        case .scrollWheel:
            // Original weiterreichen – behält Trägheit und Scroll-Phasen.
            guard let copy = event.copy() else { return false }
            forwarder.forward(copy, to: point)
        default:
            return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    func windowDidEnterFullScreen(_ notification: Notification) {
        createAttempts = 0
        onMain(after: 0.3) { [weak self] in self?.returnToPreviousSpace() }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        ready = false
        awaitingReturn = false
        checkActive()
        window.orderOut(nil)
        // Der Space soll bestehen bleiben, solange Kagami läuft → wieder anlegen.
        guard enabled else { return }
        onMain(after: 0.6) { [weak self] in self?.create() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        checkActive()
    }
}
