import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, StreamViewDelegate {
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // kein Dock-Icon, Panels dürfen über Vollbild-Apps
        app.run()
    }

    // MARK: Zustand

    private var panel: OverlayPanel!
    private var streamView: StreamView!
    private var launcher: LauncherView!
    private var resizeCursor: ResizeCursorController!
    private var topBar: TopBar!
    private var statusItem: NSStatusItem!

    private var display: VirtualDisplay?
    private var host: HostManager?
    private let capture = DisplayCapture()
    let inputForwarder = InputForwarder()

    private var hotKey: HotKey?
    private var fullscreenHotKey: HotKey?
    private var switchHotKey: HotKey?
    private var cursorMonitors: [Any] = []
    private var lastSafeCursor = CGPoint.zero
    private var captureStarted = false
    private var permissionTimer: Timer?
    private var errorMessage: String?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nur eine Instanz: ein zweiter Start zeigt das Overlay der laufenden und beendet sich.
        if SingleInstance.anotherInstanceIsRunning() {
            SingleInstance.notifyRunningInstance()
            NSApp.terminate(nil)
            return
        }
        SingleInstance.listen { [weak self] in
            guard let self, self.panel != nil else { return }
            self.panel.orderFrontRegardless()
        }

        inputForwarder.mode = Settings.inputMode
        buildPanel()
        buildStatusItem()
        hotKey = HotKey(id: 1, keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggleOverlay()
        }
        switchHotKey = HotKey(id: 2, keyCode: kVK_Tab, modifiers: controlKey | optionKey) { [weak self] in
            self?.host?.focusNext()
        }
        fullscreenHotKey = HotKey(id: 3, keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggleFullscreen()
        }

        if !AXHelpers.isTrusted { AXHelpers.requestTrust() }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        startVirtualDisplay()
        installCursorGuard()
        if permissionsGranted { showLauncher() }
        updateHint()

        // Bedienungshilfen können zur Laufzeit erteilt werden – regelmäßig nachsehen.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionTick() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.releaseAllImmediately()
        capture.stop()
    }

    // MARK: Aufbau

    private func buildPanel() {
        let defaultSize = NSSize(width: 1000, height: 625 + TopBar.height)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screenFrame.midX - defaultSize.width / 2, y: screenFrame.midY - defaultSize.height / 2,
                          width: defaultSize.width, height: defaultSize.height)

        panel = OverlayPanel(contentRect: rect)
        panel.delegate = self
        panel.setFrameAutosaveName("KagamiOverlay")
        panel.alphaValue = Settings.opacity

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        topBar = TopBar()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        streamView = StreamView()
        streamView.translatesAutoresizingMaskIntoConstraints = false
        streamView.delegate = self

        launcher = LauncherView()
        launcher.translatesAutoresizingMaskIntoConstraints = false
        launcher.isHidden = true
        launcher.onLaunch = { [weak self] url in self?.launch([url]) }
        launcher.onDropApps = { [weak self] urls in self?.launch(urls) }
        launcher.onClose = { [weak self] in self?.hideLauncher() }
        launcher.onNeedsKeyboard = { [weak self] in
            guard let self else { return }
            self.panel.allowsKey = true
            self.panel.makeKey()
        }

        container.addSubview(streamView)
        container.addSubview(launcher)
        container.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: TopBar.height),
            streamView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            streamView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            streamView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            streamView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            launcher.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            launcher.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            launcher.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            launcher.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        topBar.addButton.target = self
        topBar.addButton.action = #selector(toggleLauncher)
        resizeCursor = ResizeCursorController(window: panel)
        topBar.fitButton.target = self
        topBar.fitButton.action = #selector(refitWindows)
        topBar.onSelectApp = { [weak self] pid in self?.host?.focus(pid: pid) }
        topBar.onAppMenu = { [weak self] pid, view in self?.showAppMenu(pid: pid, from: view) }
        topBar.fullscreenButton.target = self
        topBar.fullscreenButton.action = #selector(toggleFullscreen)
        topBar.menuButton.target = self
        topBar.menuButton.action = #selector(showOptionsMenu(_:))
        topBar.hideButton.target = self
        topBar.hideButton.action = #selector(toggleOverlay)

        panel.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
        updateTitle()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Kagami")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startVirtualDisplay() {
        guard let display = VirtualDisplay(name: "Kagami", pointSize: currentStreamSize()) else {
            errorMessage = "Virtuelles Display konnte nicht erstellt werden (macOS 14+ nötig)."
            updateHint()
            return
        }
        self.display = display
        streamView.displaySize = display.requestedPointSize
        display.onReconfigured = { [weak self] in self?.displayReconfigured() }

        let host = HostManager(display: display)
        host.fillWindows = Settings.fillWindows
        host.openFullscreen = Settings.openFullscreen
        host.onActiveAppChange = { [weak self] in self?.updateTitle() }
        host.onChange = { [weak self] in
            guard let self else { return }
            self.updateTitle()
            // Leerer Kagami-Bildschirm → Starter anbieten.
            if self.host?.hosted.isEmpty ?? true, self.permissionsGranted { self.showLauncher() } else if !(self.host?.hosted.isEmpty ?? true) { self.hideLauncher() }
            self.updateHint()
        }
        self.host = host

        capture.onFrame = { [weak self] surface in self?.streamView.display(surface: surface) }
        capture.onError = { [weak self] message in
            self?.errorMessage = message
            self?.updateHint()
        }
    }

    private func currentStreamSize() -> CGSize {
        let size = streamView?.bounds.size ?? .zero
        if size.width < 10 || size.height < 10 {
            let content = panel.contentRect(forFrameRect: panel.frame).size
            return CGSize(width: content.width, height: content.height - TopBar.height)
        }
        return size
    }

    private func displayReconfigured() {
        guard let display else { return }
        let bounds = display.bounds
        if bounds.width > 0 { streamView.displaySize = bounds.size }

        if !captureStarted, CGPreflightScreenCaptureAccess() {
            captureStarted = true
            capture.start(displayID: display.displayID, pixelSize: display.pixelSize)
        } else {
            capture.update(pixelSize: display.pixelSize)
        }
        if Settings.fillWindows { host?.refit() }
    }

    // MARK: Cursor-Schutz

    /// Verhindert, dass der echte Mauszeiger auf den (unsichtbaren) virtuellen Bildschirm wandert.
    private func installCursorGuard() {
        lastSafeCursor = Geometry.cursorLocation
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.guardCursor()
            self?.resizeCursor.update()
        }) { cursorMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.guardCursor()
            self?.resizeCursor.update()
            return event
        }) { cursorMonitors.append(local) }
    }

    private func guardCursor() {
        guard let display else { return }
        let location = Geometry.cursorLocation
        if display.bounds.contains(location) {
            if Date() > inputForwarder.cursorExcursionUntil {
                CGWarpMouseCursorPosition(lastSafeCursor)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        } else {
            lastSafeCursor = location
        }
    }

    // MARK: NSWindowDelegate

    func windowWillStartLiveResize(_ notification: Notification) { resizeCursor.liveResizeStarted() }
    func windowDidEndLiveResize(_ notification: Notification) { resizeCursor.liveResizeEnded() }

    func windowDidResize(_ notification: Notification) {
        guard Settings.resolutionFollowsWindow, let display else { return }
        display.resize(to: currentStreamSize())
    }

    // MARK: StreamViewDelegate

    func streamView(_ view: StreamView, globalPointFor normalized: CGPoint) -> CGPoint {
        guard let display else { return .zero }
        let b = display.bounds
        return CGPoint(x: b.minX + normalized.x * b.width, y: b.minY + normalized.y * b.height)
    }

    func streamView(_ view: StreamView, didReceiveAppURLs urls: [URL]) {
        launch(urls)
    }

    // MARK: Aktionen

    @objc private func toggleOverlay() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func refitWindows() {
        guard let host else { return }
        let fill = host.fillWindows
        host.fillWindows = true
        host.refit()
        host.fillWindows = fill
    }

    // MARK: Starter

    private var permissionsGranted: Bool { AXHelpers.isTrusted && CGPreflightScreenCaptureAccess() }

    @objc private func toggleLauncher() {
        if launcher.isHidden { showLauncher() } else { hideLauncher() }
    }

    private func showLauncher() {
        launcher.reload()
        launcher.isHidden = false
        panel.allowsKey = true
        streamView.setHint(nil)
    }

    private func hideLauncher() {
        guard !launcher.isHidden else { return }
        launcher.isHidden = true
        panel.makeFirstResponder(nil)
        panel.allowsKey = false
        updateHint()
    }

    /// Apps direkt auf dem Kagami-Bildschirm starten (oder hineinholen, falls sie schon laufen).
    private func launch(_ urls: [URL]) {
        guard ensureAccessibility() else { return }
        hideLauncher()
        urls.forEach { host?.host(appAt: $0) }
    }

    @objc private func toggleFullscreen() {
        guard ensureAccessibility() else { return }
        host?.toggleFullscreen()
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        addHostingItems(to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func showOptionsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        fillMainMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func ensureAccessibility() -> Bool {
        if AXHelpers.isTrusted { return true }
        AXHelpers.requestTrust()
        updateHint()
        return false
    }

    private func chooseAppFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "In Kagami öffnen"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                guard let self, self.ensureAccessibility() else { return }
                urls.forEach { self.host?.host(appAt: $0) }
            }
        }
    }

    private func restart() {
        host?.releaseAllImmediately()
        SingleInstance.restart()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Anzeige

    /// Tabs in der oberen Leiste aktualisieren.
    private func updateTitle() {
        let apps = (host?.hostedApps ?? []).map { (pid: $0.pid, name: $0.name, icon: $0.app.icon) }
        topBar.titleLabel.stringValue = "Kagami"
        topBar.setApps(apps, active: host?.activePID)
    }

    private func showAppMenu(pid: pid_t, from view: NSView) {
        guard let entry = host?.hostedApps.first(where: { $0.pid == pid }) else { return }
        let menu = NSMenu()
        let header = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(ActionMenuItem("Nach vorne holen") { [weak self] in self?.host?.focus(pid: pid) })
        menu.addItem(ActionMenuItem("Vollbild umschalten") { [weak self] in self?.host?.toggleFullscreen(pid: pid) })
        menu.addItem(ActionMenuItem("Zurück auf den Hauptbildschirm") { [weak self] in self?.host?.release(pid: pid) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("\(entry.name) beenden") { entry.app.terminate() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func permissionTick() {
        // Bildschirmaufnahme wurde evtl. gerade erlaubt → Stream starten.
        if !captureStarted, let display, CGPreflightScreenCaptureAccess() {
            captureStarted = true
            errorMessage = nil
            capture.start(displayID: display.displayID, pixelSize: display.pixelSize)
        }
        updateHint()
    }

    private func updateHint() {
        if let errorMessage {
            streamView.setHint(errorMessage)
        } else if !CGPreflightScreenCaptureAccess() {
            streamView.setHint("Kagami braucht die Berechtigung\n„Bildschirm- & Systemaudioaufnahme“.\n\nNach dem Erlauben: Menüleiste › Kagami › Neu starten.")
        } else if !AXHelpers.isTrusted {
            streamView.setHint("Kagami braucht die Berechtigung „Bedienungshilfen“,\num Fenster zu verschieben und Klicks weiterzuleiten.")
        } else if host?.hosted.isEmpty ?? true {
            streamView.setHint(launcher.isHidden ? "Zieh eine App hier hinein\noder starte eine mit ＋ oben links." : nil)
        } else {
            streamView.setHint(nil)
        }
    }

    // MARK: Menüs

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fillMainMenu(menu)
    }

    private func fillMainMenu(_ menu: NSMenu) {
        menu.addItem(ActionMenuItem(panel.isVisible ? "Overlay ausblenden" : "Overlay einblenden",
                                    key: "k", modifiers: [.control, .option]) { [weak self] in self?.toggleOverlay() })
        menu.addItem(.separator())

        addHostingItems(to: menu)
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem("Fenster an Bildschirm anpassen") { [weak self] in self?.refitWindows() })

        let fill = ActionMenuItem("Fenster immer bildschirmfüllend") { [weak self] in
            Settings.fillWindows.toggle()
            self?.host?.fillWindows = Settings.fillWindows
            if Settings.fillWindows { self?.host?.refit() }
        }
        fill.state = Settings.fillWindows ? .on : .off
        menu.addItem(fill)

        menu.addItem(ActionMenuItem("Vollbild umschalten", key: "f", modifiers: [.control, .option]) { [weak self] in
            self?.toggleFullscreen()
        })

        let openFull = ActionMenuItem("Apps im Vollbild öffnen") { [weak self] in
            Settings.openFullscreen.toggle()
            self?.host?.openFullscreen = Settings.openFullscreen
        }
        openFull.state = Settings.openFullscreen ? .on : .off
        menu.addItem(openFull)

        let follow = ActionMenuItem("Auflösung folgt Fenstergröße") { [weak self] in
            Settings.resolutionFollowsWindow.toggle()
            if Settings.resolutionFollowsWindow, let self { self.display?.resize(to: self.currentStreamSize()) }
        }
        follow.state = Settings.resolutionFollowsWindow ? .on : .off
        menu.addItem(follow)

        let inputItem = NSMenuItem(title: "Eingabe", action: nil, keyEquivalent: "")
        let inputMenu = NSMenu()
        for mode in InputMode.allCases {
            let item = ActionMenuItem(mode.title) { [weak self] in
                Settings.inputMode = mode
                self?.inputForwarder.mode = mode
            }
            item.state = inputForwarder.mode == mode ? .on : .off
            inputMenu.addItem(item)
        }
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)

        let opacityItem = NSMenuItem(title: "Deckkraft", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [1.0, 0.9, 0.75, 0.5] as [CGFloat] {
            let item = ActionMenuItem("\(Int(value * 100)) %") { [weak self] in
                Settings.opacity = value
                self?.panel.alphaValue = value
            }
            item.state = abs(Settings.opacity - value) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        let permItem = NSMenuItem(title: "Berechtigungen", action: nil, keyEquivalent: "")
        let permMenu = NSMenu()
        let sc = ActionMenuItem("Bildschirmaufnahme …") { [weak self] in self?.openPrivacyPane("Privacy_ScreenCapture") }
        sc.state = CGPreflightScreenCaptureAccess() ? .on : .off
        let ax = ActionMenuItem("Bedienungshilfen …") { [weak self] in self?.openPrivacyPane("Privacy_Accessibility") }
        ax.state = AXHelpers.isTrusted ? .on : .off
        permMenu.addItem(sc)
        permMenu.addItem(ax)
        permItem.submenu = permMenu
        menu.addItem(permItem)

        menu.addItem(ActionMenuItem("Kagami neu starten") { [weak self] in self?.restart() })
        menu.addItem(ActionMenuItem("Kagami beenden", key: "q") { NSApp.terminate(nil) })
    }

    /// Einträge: gehostete Apps (zurückholen) + laufende Apps (hineinholen) + App wählen.
    private func addHostingItems(to menu: NSMenu) {
        let hostedApps = host?.hostedApps ?? []
        if !hostedApps.isEmpty {
            let header = NSMenuItem(title: "In Kagami", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in hostedApps {
                let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
                item.image = Self.icon(for: entry.app)
                let sub = NSMenu()
                let pid = entry.app.processIdentifier
                sub.addItem(ActionMenuItem("Nach vorne holen") { [weak self] in self?.host?.focus(pid: pid) })
                sub.addItem(ActionMenuItem("Zurück auf den Hauptbildschirm") { [weak self] in self?.host?.release(pid: pid) })
                sub.addItem(ActionMenuItem("Vollbild umschalten") { [weak self] in self?.host?.toggleFullscreen(pid: pid) })
                sub.addItem(ActionMenuItem("Fenster erneut einfangen") { [weak self] in self?.host?.host(app: entry.app) })
                item.submenu = sub
                menu.addItem(item)
            }
            if hostedApps.count > 1 {
                menu.addItem(ActionMenuItem("Nächste App (⌃⌥⇥)") { [weak self] in self?.host?.focusNext() })
            }
            menu.addItem(ActionMenuItem("Alle zurück auf den Hauptbildschirm") { [weak self] in self?.host?.releaseAll() })
            menu.addItem(.separator())
        }

        let runningItem = NSMenuItem(title: "Laufende App hineinholen", action: nil, keyEquivalent: "")
        let runningMenu = NSMenu()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID
                && !SingleInstance.isKagami(bundleID: $0.bundleIdentifier) && !(host?.isHosted($0) ?? false) }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in candidates {
            let item = ActionMenuItem(app.localizedName ?? "App") { [weak self] in
                guard let self, self.ensureAccessibility() else { return }
                self.host?.host(app: app)
            }
            item.image = Self.icon(for: app)
            runningMenu.addItem(item)
        }
        if candidates.isEmpty {
            let none = NSMenuItem(title: "Keine weiteren Apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            runningMenu.addItem(none)
        }
        runningItem.submenu = runningMenu
        menu.addItem(runningItem)

        menu.addItem(ActionMenuItem("App in Kagami starten …") { [weak self] in
            guard let self else { return }
            self.panel.orderFrontRegardless()
            self.showLauncher()
        })
    }

    private static func icon(for app: NSRunningApplication) -> NSImage? {
        guard let icon = app.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
