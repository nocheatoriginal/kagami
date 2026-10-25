import AppKit

/// Sorgt dafür, dass immer nur ein Kagami läuft – egal ob aus build/ oder /Applications.
/// Ein zweiter Start blendet stattdessen das Overlay der laufenden Instanz ein.
enum SingleInstance {
    static let restartArgument = "--kagami-restart"
    private static let showNotification = Notification.Name("io.github.nocheatoriginal.kagami.show")

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.nocheatoriginal.kagami" }

    private static func otherInstances() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
    }

    /// `true`, wenn bereits ein anderes Kagami läuft. Nach einem Neustart wird kurz gewartet,
    /// bis sich die alte Instanz beendet hat.
    static func anotherInstanceIsRunning() -> Bool {
        let isRestart = CommandLine.arguments.contains(restartArgument)
        let deadline = Date().addingTimeInterval(isRestart ? 5 : 0.5)
        while !otherInstances().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !otherInstances().isEmpty
    }

    /// Der laufenden Instanz sagen, dass sie ihr Overlay zeigen soll.
    static func notifyRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        otherInstances().first?.activate()
    }

    /// In der laufenden Instanz: auf "zeig dich" von einem zweiten Start hören.
    static func listen(_ handler: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: showNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Kagami neu starten: neue Instanz verzögert starten, diese hier beenden.
    @MainActor
    static func restart() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\" --args \(restartArgument)", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Ist diese App Kagami selbst (egal welche Kopie)?
    static func isKagami(bundleID other: String?) -> Bool {
        guard let other else { return false }
        return other == bundleID
    }
}
