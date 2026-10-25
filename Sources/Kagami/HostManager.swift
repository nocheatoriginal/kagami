import AppKit
import ApplicationServices

/// Verwaltet die Apps, die "in Kagami liegen": verschiebt ihre Fenster auf das virtuelle
/// Display, fängt neue Fenster automatisch ein, erhält den Vollbildmodus und wechselt
/// zwischen den Apps.
///
/// Alles, was Spaces wechselt (Vollbild an/aus, App kurz besuchen), läuft über eine
/// Warteschlange nacheinander – sonst kommen sich die Animationen von macOS in die Quere.
@MainActor
final class HostManager {
    final class HostedApp {
        let app: NSRunningApplication
        var observer: AXObserver?
        /// Gestartet mit "versteckt" – wird eingeblendet, sobald die Fenster auf dem Kagami-Bildschirm sind.
        var revealPending = false
        var revealSince = Date()
        /// Wurde die App schon einmal kurz aktiviert, um Fenster auf anderen Spaces zu erreichen?
        var visited = false
        let hostedAt = Date()
        init(app: NSRunningApplication) { self.app = app }
        var name: String { app.localizedName ?? app.bundleIdentifier ?? "App" }
        var pid: pid_t { app.processIdentifier }
    }

    typealias Done = @MainActor () -> Void
    typealias Operation = @MainActor (_ done: @escaping Done) -> Void

    private(set) var hosted: [pid_t: HostedApp] = [:]
    /// Reihenfolge, in der die Apps hinzugefügt wurden (für Tabs und ⌃⌥Tab).
    private(set) var order: [pid_t] = []
    private let display: VirtualDisplay
    private var observers: [NSObjectProtocol] = []
    /// Fenster, die gerade in den/aus dem Vollbild wechseln (nicht anfassen!).
    private var transitioning = Set<UInt>()
    private var queue: [Operation] = []
    private var queueBusy = false

    /// Fenster beim Hineinholen und bei Auflösungswechsel auf volle Displaygröße ziehen.
    var fillWindows = true
    /// Hineingeholte Apps automatisch in den Vollbildmodus schalten.
    var openFullscreen = false
    var onChange: (@MainActor () -> Void)?
    /// Die aktive App hat gewechselt (für die Tabs).
    var onActiveAppChange: (@MainActor () -> Void)?

    init(display: VirtualDisplay) {
        self.display = display
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.forget(pid: app.processIdentifier) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActiveAppChange?() }
        })
    }

    var hostedApps: [HostedApp] { order.compactMap { hosted[$0] } }

    func isHosted(_ app: NSRunningApplication) -> Bool { hosted[app.processIdentifier] != nil }

    /// Die gehostete App, die gerade vorne ist (falls eine).
    var activePID: pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, hosted[front] != nil else { return nil }
        return front
    }

    // MARK: Warteschlange

    private func enqueue(timeout: TimeInterval = 10, _ operation: @escaping Operation) {
        queue.append { done in
            var finished = false
            let once: Done = {
                guard !finished else { return }
                finished = true
                done()
            }
            onMain(after: timeout) { once() }   // Sicherheitsnetz, falls etwas hängen bleibt
            operation(once)
        }
        runQueue()
    }

    private func runQueue() {
        guard !queueBusy, !queue.isEmpty else { return }
        queueBusy = true
        let operation = queue.removeFirst()
        operation { [weak self] in
            onMain(after: 0.2) {
                self?.queueBusy = false
                self?.runQueue()
            }
        }
    }

    // MARK: Hineinholen

    /// Startet eine App direkt auf dem Kagami-Bildschirm – oder holt sie hinein, wenn sie schon läuft.
    func host(appAt url: URL) {
        let bundleID = Bundle(url: url)?.bundleIdentifier
        // Kagami in Kagami? Nein danke – das gäbe einen Spiegel im Spiegel.
        guard !SingleInstance.isKagami(bundleID: bundleID), url.lastPathComponent != "Kagami.app" else {
            NSSound.beep()
            return
        }
        if let bundleID, let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            host(app: running)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        // Erst unsichtbar starten, dann Fenster verschieben, dann einblenden –
        // so blitzen sie nicht auf dem Hauptbildschirm auf.
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            onMain {
                guard let self else { return }
                if let app {
                    self.host(app: app, launchedHidden: true)
                } else {
                    NSLog("[Kagami] Konnte \(url.lastPathComponent) nicht öffnen: \(error?.localizedDescription ?? "?")")
                }
            }
        }
    }

    func host(app: NSRunningApplication, launchedHidden: Bool = false) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              !SingleInstance.isKagami(bundleID: app.bundleIdentifier) else { return }
        if hosted[pid] == nil {
            let entry = HostedApp(app: app)
            hosted[pid] = entry
            order.append(pid)
            observeNewWindows(entry)
            onChange?()
        }
        guard let entry = hosted[pid] else { return }
        entry.visited = false
        if launchedHidden {
            entry.revealPending = true
            entry.revealSince = Date()
        } else if app.isHidden {
            app.unhide()
        }
        // Läuft schon, hat aber kein Fenster? Dann wie ein Klick aufs Dock-Icon ein neues anfordern.
        if !launchedHidden, AXHelpers.windowsOnAllSpaces(pid: pid).filter(AXHelpers.isStandardWindow).isEmpty,
           let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
        enqueue(timeout: 14) { [weak self] done in
            self?.captureWindows(pid: pid, attempt: 0, done: done)
        }
    }

    private func isOnVirtualDisplay(_ window: AXUIElement) -> Bool {
        guard let f = AXHelpers.frame(window) else { return false }
        return display.bounds.contains(CGPoint(x: f.midX, y: f.midY))
    }

    private func captureWindows(pid: pid_t, attempt: Int, done: @escaping Done) {
        guard let entry = hosted[pid] else { return done() }
        let maxAttempts = 30
        // Die (teure) Suche über alle Spaces nur ab und zu.
        let all = attempt % 4 == 0 ? AXHelpers.windowsOnAllSpaces(pid: pid) : AXHelpers.windows(pid: pid)
        let windows = all.filter(AXHelpers.isStandardWindow)
        var transfers = 0

        for window in windows where !transitioning.contains(Self.key(window)) {
            let fullscreen = AXHelpers.isFullScreen(window)
            if isOnVirtualDisplay(window) {
                if !fullscreen, fillWindows { AXHelpers.place(window, in: display.visibleBounds, fill: true) }
                if !fullscreen, openFullscreen { setFullScreen(window, true) }
                continue
            }
            transfers += 1
            // Vollbild-Fenster bleiben Vollbild – nur eben auf dem Kagami-Bildschirm.
            transfer(window, toDisplay: display.displayID, fullscreen: fullscreen || openFullscreen)
        }

        let pending = windows.isEmpty || windows.contains { !isOnVirtualDisplay($0) }

        if entry.revealPending {
            let waited = Date().timeIntervalSince(entry.revealSince)
            // Einblenden, sobald alles drüben ist – spätestens nach 2 s (manche Apps
            // erzeugen ihre Fenster erst, wenn sie sichtbar sind).
            if !pending || waited > 2 || attempt >= maxAttempts {
                entry.revealPending = false
                entry.app.unhide()
            }
        }

        if !pending {
            // Kurz warten, bis laufende Vollbild-Übergänge fertig sind, dann ist die Operation erledigt.
            waitUntil(timeout: 6, { [weak self] in self?.transitioning.isEmpty ?? true }) { _ in done() }
            return
        }

        // Fenster lassen sich nicht erreichen (z.B. auf einem anderen Space und das Verschieben
        // klappt von außen nicht)? Dann die App kurz nach vorne holen – genau das, was du
        // sonst von Hand machen müsstest – und danach zur vorherigen App zurückkehren.
        if attempt == 4, !entry.visited, !entry.revealPending, transfers == 0 || windows.isEmpty {
            entry.visited = true
            visit(pid: pid) { [weak self] restore in
                self?.captureWindows(pid: pid, attempt: attempt + 1) {
                    restore()
                    done()
                }
            }
            return
        }

        if attempt < maxAttempts {
            onMain(after: 0.4) { [weak self] in
                guard let self else { return done() }
                self.captureWindows(pid: pid, attempt: attempt + 1, done: done)
            }
        } else {
            done()
        }
    }

    /// Holt eine App kurz nach vorne (macOS springt dabei in ihren Space) und gibt eine Funktion
    /// zurück, mit der die vorher aktive App wiederhergestellt wird.
    private func visit(pid: pid_t, then: @escaping @MainActor (_ restore: @escaping Done) -> Void) {
        let previous = NSWorkspace.shared.frontmostApplication
        Self.activate(pid: pid)
        onMain(after: 0.8) {
            then {
                guard let previous, previous.processIdentifier != pid,
                      self.hosted[previous.processIdentifier] == nil,
                      previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                Self.activate(pid: previous.processIdentifier)
            }
        }
    }

    private static func activate(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.unhide()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Passt alle Fenster der gehosteten Apps an die aktuelle Displaygröße an.
    func refit() {
        let target = display.visibleBounds
        for pid in order {
            for window in AXHelpers.windows(pid: pid) where AXHelpers.isStandardWindow(window) {
                guard !transitioning.contains(Self.key(window)), isOnVirtualDisplay(window) else { continue }
                if AXHelpers.isFullScreen(window) {
                    refreshFullscreenSize(window)
                } else {
                    AXHelpers.place(window, in: target, fill: fillWindows)
                }
            }
        }
    }

    /// Position eines Fensters relativ zur Größe des virtuellen Monitors (0…1).
    struct WindowLayout {
        let window: AXUIElement
        let relative: CGRect
    }

    /// Merkt sich die Lage aller normalen (nicht-Vollbild) Fenster relativ zum Monitor –
    /// damit sie nach einem Auflösungswechsel wieder an derselben Stelle stehen.
    func layoutSnapshot() -> [WindowLayout] {
        let b = display.bounds
        guard b.width > 0, b.height > 0 else { return [] }
        var result: [WindowLayout] = []
        for pid in order {
            for window in AXHelpers.windows(pid: pid) where AXHelpers.isStandardWindow(window) {
                guard isOnVirtualDisplay(window), !AXHelpers.isFullScreen(window),
                      let f = AXHelpers.frame(window) else { continue }
                let relative = CGRect(x: (f.minX - b.minX) / b.width, y: (f.minY - b.minY) / b.height,
                                      width: f.width / b.width, height: f.height / b.height)
                result.append(WindowLayout(window: window, relative: relative))
            }
        }
        return result
    }

    /// Stellt eine mit `layoutSnapshot()` gemerkte Lage auf der aktuellen Auflösung wieder her.
    func apply(_ layout: [WindowLayout]) {
        let b = display.bounds
        guard b.width > 0, b.height > 0 else { return }
        for entry in layout {
            let window = entry.window
            guard !transitioning.contains(Self.key(window)), !AXHelpers.isFullScreen(window) else { continue }
            let r = entry.relative
            let frame = CGRect(x: b.minX + r.minX * b.width, y: b.minY + r.minY * b.height,
                               width: r.width * b.width, height: r.height * b.height)
            AXHelpers.setPosition(window, frame.origin)
            AXHelpers.setSize(window, frame.size)
            AXHelpers.setPosition(window, frame.origin)
        }
    }

    /// Vollbild-Fenster folgen einem Auflösungswechsel normalerweise selbst.
    /// Falls nicht, einmal kurz aus dem Vollbild und wieder hinein.
    private func refreshFullscreenSize(_ window: AXUIElement) {
        onMain(after: 0.6) { [weak self] in
            guard let self, AXHelpers.isFullScreen(window), let f = AXHelpers.frame(window) else { return }
            let b = self.display.bounds
            guard abs(f.width - b.width) > 2 || abs(f.height - b.height) > 2 else { return }
            self.enqueue { done in
                self.transfer(window, toDisplay: self.display.displayID, fullscreen: true, completion: done)
            }
        }
    }

    // MARK: Wechseln

    /// Bringt eine gehostete App nach vorne (auf dem Kagami-Bildschirm) – Tastatur geht dann an sie.
    func focus(pid: pid_t) {
        guard let entry = hosted[pid] else { return }
        entry.app.unhide()
        Self.activate(pid: pid)
        let windows = AXHelpers.windows(pid: pid).filter { AXHelpers.isStandardWindow($0) && isOnVirtualDisplay($0) }
        if let window = windows.first(where: { AXHelpers.bool($0, kAXMainAttribute) == true }) ?? windows.first {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        onActiveAppChange?()
    }

    /// Zur nächsten gehosteten App wechseln (⌃⌥Tab).
    func focusNext() {
        guard !order.isEmpty else { return }
        let current = activePID.flatMap { order.firstIndex(of: $0) } ?? -1
        focus(pid: order[(current + 1) % order.count])
    }

    // MARK: Vollbild

    /// Schaltet das aktive Fenster einer gehosteten App in den Vollbildmodus bzw. heraus.
    func toggleFullscreen(pid: pid_t? = nil) {
        guard let window = activeWindow(pid: pid) else { NSSound.beep(); return }
        if AXHelpers.isFullScreen(window) {
            let key = Self.key(window)
            transitioning.insert(key)
            AXHelpers.setFullScreen(window, false)
            waitUntil(timeout: 4, { !AXHelpers.isFullScreen(window) }) { [weak self] _ in
                onMain(after: 0.6) {
                    guard let self else { return }
                    self.transitioning.remove(key)
                    AXHelpers.place(window, in: self.display.visibleBounds, fill: self.fillWindows)
                }
            }
        } else {
            setFullScreen(window, true)
        }
    }

    /// Fenster der (vordersten) gehosteten App, das gerade aktiv ist.
    private func activeWindow(pid: pid_t?) -> AXUIElement? {
        let candidates: [pid_t] = [pid, activePID].compactMap { $0 }.filter { hosted[$0] != nil } + order
        for pid in candidates {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement  // swiftlint:disable:this force_cast
                if isOnVirtualDisplay(window) { return window }
            }
            if let window = AXHelpers.windows(pid: pid).first(where: { AXHelpers.isStandardWindow($0) && isOnVirtualDisplay($0) }) {
                return window
            }
        }
        return nil
    }

    private func setFullScreen(_ window: AXUIElement, _ on: Bool) {
        let key = Self.key(window)
        transitioning.insert(key)
        AXHelpers.setFullScreen(window, on)
        waitUntil(timeout: 4, { AXHelpers.isFullScreen(window) == on }) { [weak self] _ in
            onMain(after: 0.3) { self?.transitioning.remove(key) }
        }
    }

    /// Bringt ein Fenster auf ein anderes Display und stellt danach den Vollbildmodus (wieder) her.
    /// Ablauf: Vollbild verlassen → warten bis die Animation fertig ist → verschieben → Vollbild an.
    private func transfer(_ window: AXUIElement, toDisplay displayID: CGDirectDisplayID, fullscreen: Bool,
                          completion: Done? = nil) {
        let key = Self.key(window)
        guard !transitioning.contains(key) else { completion?(); return }
        transitioning.insert(key)

        let finish: Done = { [weak self] in
            onMain(after: 0.4) {
                self?.transitioning.remove(key)
                completion?()
            }
        }

        let moveAndRestore: Done = {
            AXHelpers.place(window, in: Self.visibleBounds(of: displayID), fill: true)
            // Ein zweites Mal, weil manche Apps beim Displaywechsel die Größe begrenzen.
            onMain(after: 0.25) { [weak self] in
                AXHelpers.place(window, in: Self.visibleBounds(of: displayID), fill: true)
                guard fullscreen, let self else { finish(); return }
                onMain(after: 0.35) {
                    AXHelpers.setFullScreen(window, true)
                    self.waitUntil(timeout: 4, { AXHelpers.isFullScreen(window) }) { ok in
                        if !ok { AXHelpers.setFullScreen(window, true) }   // zweiter Versuch
                        finish()
                    }
                }
            }
        }

        if AXHelpers.isFullScreen(window) {
            AXHelpers.setFullScreen(window, false)
            waitUntil(timeout: 4, { !AXHelpers.isFullScreen(window) }) { _ in
                // Die Space-Animation läuft noch kurz nach, bevor sich das Fenster verschieben lässt.
                onMain(after: 0.7) { moveAndRestore() }
            }
        } else {
            moveAndRestore()
        }
    }

    /// Prüft `condition` alle 0,15 s, bis sie erfüllt ist oder `timeout` abläuft.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool,
                           then: @escaping @MainActor (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { then(true); return }
            if Date() > deadline { then(false); return }
            onMain(after: 0.15) { poll() }
        }
        onMain(after: 0.15) { poll() }
    }

    private static func visibleBounds(of displayID: CGDirectDisplayID) -> CGRect {
        if let screen = Geometry.screen(for: displayID) {
            return Geometry.cgRect(fromCocoa: screen.visibleFrame)
        }
        return CGDisplayBounds(displayID)
    }

    private static func key(_ window: AXUIElement) -> UInt {
        let id = AXHelpers.windowID(window)
        return id != 0 ? UInt(id) : UInt(CFHash(window))
    }

    // MARK: Zurückgeben

    /// Gibt eine App zurück auf den Hauptbildschirm (Vollbild bleibt Vollbild).
    func release(pid: pid_t) {
        guard let entry = hosted[pid] else { return }
        // Sofort aus der Liste nehmen, damit keine neuen Fenster mehr eingefangen werden.
        stopObserving(entry)
        hosted[pid] = nil
        order.removeAll { $0 == pid }
        onChange?()
        enqueue(timeout: 15) { [weak self] done in
            self?.releaseWindows(of: entry, done: done)
        }
    }

    /// Alle Apps zurückgeben – nacheinander, damit sich die Vollbild-Wechsel nicht stören.
    func releaseAll() {
        for pid in order { release(pid: pid) }
    }

    /// Beim Beenden von Kagami: nicht warten, nur die normalen Fenster sofort zurücksetzen
    /// (der Rest landet automatisch auf dem Hauptbildschirm, wenn der virtuelle Monitor verschwindet).
    func releaseAllImmediately() {
        let home = Self.visibleBounds(of: CGMainDisplayID())
        for pid in order {
            for window in AXHelpers.windows(pid: pid) where AXHelpers.isStandardWindow(window) && isOnVirtualDisplay(window) {
                AXHelpers.place(window, in: home.insetBy(dx: home.width * 0.1, dy: home.height * 0.1), fill: false)
            }
        }
    }

    private func releaseWindows(of entry: HostedApp, done: @escaping Done) {
        let pid = entry.pid
        let windows = AXHelpers.windowsOnAllSpaces(pid: pid).filter { isOnVirtualDisplay($0) }
        let needsVisit = windows.isEmpty || windows.contains { AXHelpers.isFullScreen($0) }

        let work: @MainActor (_ restore: Done?) -> Void = { [weak self] restore in
            guard let self else { return done() }
            // Nach einem Besuch sind evtl. weitere Fenster sichtbar → neu einsammeln.
            let current = restore == nil ? windows
                : AXHelpers.windowsOnAllSpaces(pid: pid).filter { self.isOnVirtualDisplay($0) }
            self.releaseSequentially(current) {
                restore?()
                done()
            }
        }

        if needsVisit {
            // In den Space der App springen, damit Vollbild-Fenster sicher reagieren.
            visit(pid: pid) { restore in work(restore) }
        } else {
            work(nil)
        }
    }

    /// Fenster eins nach dem anderen zurückbringen.
    private func releaseSequentially(_ windows: [AXUIElement], done: @escaping Done) {
        guard let window = windows.first else { return done() }
        let rest = Array(windows.dropFirst())
        let mainID = CGMainDisplayID()
        if AXHelpers.isFullScreen(window) {
            transfer(window, toDisplay: mainID, fullscreen: true) { [weak self] in
                guard let self else { return done() }
                self.releaseSequentially(rest, done: done)
            }
        } else {
            let home = Self.visibleBounds(of: mainID)
            AXHelpers.place(window, in: home.insetBy(dx: home.width * 0.1, dy: home.height * 0.1), fill: false)
            releaseSequentially(rest, done: done)
        }
    }

    private func forget(pid: pid_t) {
        guard let entry = hosted[pid] else { return }
        stopObserving(entry)
        hosted[pid] = nil
        order.removeAll { $0 == pid }
        onChange?()
    }

    // MARK: Neue Fenster beobachten

    private func observeNewWindows(_ entry: HostedApp) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<HostManager>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { manager.windowCreated(element) }
        }
        guard AXObserverCreate(entry.pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(entry.pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        entry.observer = observer
    }

    private func stopObserving(_ entry: HostedApp) {
        guard let observer = entry.observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        entry.observer = nil
    }

    private func windowCreated(_ window: AXUIElement) {
        onMain(after: 0.15) { [weak self] in
            guard let self, AXHelpers.isStandardWindow(window),
                  !self.transitioning.contains(Self.key(window)), !self.isOnVirtualDisplay(window) else { return }
            // Fenster gehört evtl. zu einer App, die gerade zurückgegeben wird.
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            guard self.hosted[pid] != nil else { return }
            self.transfer(window, toDisplay: self.display.displayID, fullscreen: AXHelpers.isFullScreen(window))
        }
    }
}
