import AppKit
import ApplicationServices

private let dockBundleIdentifier = "com.apple.dock"

/// Beobachtet das Dock: Mission Control, App-Exposé und „Schreibtisch anzeigen“.
///
/// Das Dock meldet diese Zustände über (undokumentierte) Accessibility-Notifications –
/// so machen es auch Tools wie HyperDock oder DockDoor. Kagami braucht dafür nur die
/// Bedienungshilfen-Berechtigung, die es ohnehin hat.
@MainActor
final class ExposeWatcher {
    enum State: Equatable {
        case none
        /// Mission Control (3 Finger nach oben) oder App-Exposé.
        case missionControl
        /// „Schreibtisch anzeigen“ (Klick auf den Schreibtisch, Spreizgeste, F11).
        case desktop
    }

    private(set) var state: State = .none
    var onChange: (@MainActor (State) -> Void)?

    private var observer: AXObserver?
    private var dockPID: pid_t = 0
    private var launchObserver: NSObjectProtocol?

    private static let notifications: [String: State] = [
        "AXExposeShowAllWindows": .missionControl,
        "AXExposeShowFrontWindows": .missionControl,
        "AXExposeShowDesktop": .desktop,
        "AXExposeExit": .none,
    ]

    init() {
        // Wird das Dock neu gestartet (z. B. `killall Dock`), neu anmelden.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == dockBundleIdentifier else { return }
            MainActor.assumeIsolated {
                onMain(after: 1) { self?.start() }
            }
        }
    }

    /// Beim Dock anmelden. Darf beliebig oft aufgerufen werden (z. B. sobald die
    /// Bedienungshilfen erlaubt wurden).
    func start() {
        guard AXHelpers.isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleIdentifier).first
        else { return }
        let pid = dock.processIdentifier
        if observer != nil, pid == dockPID { return }
        stop()

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<ExposeWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { watcher.handle(name) }
        }
        var newObserver: AXObserver?
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in Self.notifications.keys
        where AXObserverAddNotification(newObserver, element, name as CFString, refcon) == .success {
            registered += 1
        }
        guard registered > 0 else {
            NSLog("[Kagami] Dock-Notifications nicht verfügbar")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        dockPID = pid
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockPID = 0
    }

    /// Zustand zurücksetzen, ohne `onChange` auszulösen (z. B. wenn der Nutzer das
    /// Overlay per Tastenkürzel selbst zurückholt).
    func reset() {
        state = .none
    }

    private func handle(_ name: String) {
        guard let newState = Self.notifications[name], newState != state else { return }
        state = newState
        onChange?(newState)
    }
}
