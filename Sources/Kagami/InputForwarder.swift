import AppKit
import ApplicationServices

/// Wie Maus-Events auf das virtuelle Display gelangen.
enum InputMode: String, CaseIterable {
    /// Events werden direkt an den Prozess geschickt – der Cursor bewegt sich nicht,
    /// Hover funktioniert. Klappt mit den meisten nativen (AppKit/SwiftUI) Apps.
    case direct
    /// Echte HID-Events: Cursor springt für Millisekunden auf das virtuelle Display
    /// und sofort zurück. Funktioniert mit praktisch jeder App (auch Electron/Chrome/Spiele).
    case compatible

    var title: String {
        switch self {
        case .direct: return "Direkt (ohne Cursorsprung)"
        case .compatible: return "Kompatibel (für Electron, Browser, Spiele)"
        }
    }
}

/// Phase eines Maus-Klicks bzw. -Drags.
enum MousePhase {
    case down, dragged, up

    func eventType(_ button: CGMouseButton) -> CGEventType {
        switch (self, button) {
        case (.down, .left): return .leftMouseDown
        case (.down, .right): return .rightMouseDown
        case (.down, _): return .otherMouseDown
        case (.dragged, .left): return .leftMouseDragged
        case (.dragged, .right): return .rightMouseDragged
        case (.dragged, _): return .otherMouseDragged
        case (.up, .left): return .leftMouseUp
        case (.up, .right): return .rightMouseUp
        case (.up, _): return .otherMouseUp
        }
    }

    /// Umkehrung von `eventType`: welche Phase/Taste ein CGEvent-Typ ist (nil = kein Klick/Drag).
    static func from(_ type: CGEventType) -> (phase: MousePhase, button: CGMouseButton)? {
        switch type {
        case .leftMouseDown: return (.down, .left)
        case .leftMouseDragged: return (.dragged, .left)
        case .leftMouseUp: return (.up, .left)
        case .rightMouseDown: return (.down, .right)
        case .rightMouseDragged: return (.dragged, .right)
        case .rightMouseUp: return (.up, .right)
        case .otherMouseDown: return (.down, .center)
        case .otherMouseDragged: return (.dragged, .center)
        case .otherMouseUp: return (.up, .center)
        default: return nil
        }
    }
}

/// Übersetzt Maus-Events aus dem Overlay in Events auf dem virtuellen Display.
@MainActor
final class InputForwarder {
    var mode: InputMode = .direct
    /// Klicks, Ziehen und Scrollen immer als echte HID-Events (Kagami-Schreibtisch):
    /// Chrome/Brave/Electron (Discord, Slack …) ignorieren direkt zugestellte Events, und
    /// nur ein echter Klick macht die App zuverlässig aktiv – dann folgt auch die Tastatur.
    /// Hover bleibt im Direkt-Modus, damit der Cursor nicht ständig springt.
    var forceHIDClicks = false
    /// Markierung an allen Events, die Kagami selbst erzeugt (damit Event-Taps sie erkennen).
    static let eventMarker: Int64 = 0x4B47_4D49
    /// Prozess-ID von Kagami selbst – eigene Fenster werden ignoriert.
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    /// Bis zu diesem Zeitpunkt (CACurrentMediaTime) darf der Cursor auf dem virtuellen Display sein.
    private(set) var cursorExcursionUntil: CFTimeInterval = 0

    /// Ziel eines laufenden Drags – damit alle Drag-Events an dasselbe Fenster gehen.
    private var dragTarget: WindowTarget?
    /// Zuletzt gefundenes Fenster. Die Fensterliste vom WindowServer zu holen kostet einige ms –
    /// bei Hover und Scrollen (bis 120 Events/s) wäre das spürbar.
    private var targetCache: (target: WindowTarget, time: CFTimeInterval)?
    /// Darf der Prozess Events direkt bekommen? (Menüleiste, Dock & Co. nicht.)
    private var directCapable: [pid_t: Bool] = [:]

    /// Fenster auf dem virtuellen Display unter einem Punkt.
    struct WindowTarget {
        let windowID: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    // MARK: Maus

    func mouse(_ phase: MousePhase, _ button: CGMouseButton, at point: CGPoint, clickCount: Int, flags: CGEventFlags) {
        let target: WindowTarget?
        switch phase {
        case .down:
            target = window(at: point)
            dragTarget = target
            if let target { bringToFront(target) }
        case .dragged, .up:
            target = dragTarget ?? cachedWindow(at: point)
        }
        post(phase.eventType(button), button: button, at: point,
             clickCount: phase == .dragged ? 1 : clickCount, flags: flags, target: target)
        if phase == .up { dragTarget = nil }
    }

    /// Hover – nur im Direkt-Modus, sonst würde der Cursor ständig springen.
    func mouseMoved(at point: CGPoint, flags: CGEventFlags) {
        guard mode == .direct, let target = cachedWindow(at: point) else { return }
        post(.mouseMoved, button: .left, at: point, clickCount: 0, flags: flags, target: target)
    }

    /// Ein vorhandenes Event (z. B. Scrollen mit Trägheit und Phasen) unverändert an
    /// einen Punkt auf dem virtuellen Display weiterreichen.
    func forward(_ event: CGEvent, to point: CGPoint) {
        event.location = point
        deliver(event, at: point, target: cachedWindow(at: point))
    }

    // MARK: Intern

    private func post(_ type: CGEventType, button: CGMouseButton, at point: CGPoint,
                      clickCount: Int, flags: CGEventFlags, target: WindowTarget?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, type == .mouseMoved ? 0 : 1)))
        event.flags = flags
        deliver(event, at: point, target: target)
    }

    private func deliver(_ event: CGEvent, at point: CGPoint, target: WindowTarget?) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        let wantsHID = forceHIDClicks && event.type != .mouseMoved
        if mode == .direct, !wantsHID, let target, canReceiveDirect(target.pid) {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                       value: Int64(target.windowID))
            event.postToPid(target.pid)
            return
        }
        if mode == .direct, event.type == .mouseMoved { return }  // Hover nie per Cursorsprung

        let home = Geometry.cursorLocation
        cursorExcursionUntil = CACurrentMediaTime() + 0.12
        // Scroll-Events bewegen den Cursor nicht selbst – sie gehen an das Fenster unter dem
        // Cursor. Also kurz hinspringen.
        if event.type == .scrollWheel { CGWarpMouseCursorPosition(point) }
        event.post(tap: .cghidEventTap)
        // Cursor sofort zurück – und nach kurzer Zeit noch einmal, falls das Event
        // erst nach unserem Warp verarbeitet wurde.
        CGWarpMouseCursorPosition(home)
        CGAssociateMouseAndMouseCursorPosition(1)
        let homeDisplay = Self.displayContaining(home)
        onMain(after: 0.03) {
            if Self.displayContaining(Geometry.cursorLocation) != homeDisplay {
                CGWarpMouseCursorPosition(home)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    /// Direkt-Modus nur für Fenster echter Apps. Menüleiste, Dock & Co. gehören
    /// System-Prozessen und brauchen echte HID-Events.
    private func canReceiveDirect(_ pid: pid_t) -> Bool {
        if let known = directCapable[pid] { return known }
        let capable = NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy != .prohibited } ?? false
        directCapable[pid] = capable
        return capable
    }

    /// Macht die App unter dem Klick zur aktiven App, damit Tastatureingaben dort landen.
    private func bringToFront(_ target: WindowTarget) {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = AXHelpers.windowElement(pid: target.pid, matching: target.bounds) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    /// Wie `window(at:)`, aber mit kurzem Cache, solange der Punkt im selben Fenster bleibt.
    private func cachedWindow(at point: CGPoint) -> WindowTarget? {
        let now = CACurrentMediaTime()
        if let cache = targetCache, now - cache.time < 0.2, cache.target.bounds.contains(point) {
            return cache.target
        }
        return window(at: point)
    }

    /// Oberstes Fenster (fremder Apps) unter `point` in CG-Koordinaten.
    func window(at point: CGPoint) -> WindowTarget? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {   // von vorne nach hinten sortiert
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.01 { continue }
            let target = WindowTarget(windowID: number, pid: pid, bounds: bounds)
            targetCache = (target, CACurrentMediaTime())
            return target
        }
        targetCache = nil
        return nil
    }

    private static func displayContaining(_ point: CGPoint) -> CGDirectDisplayID {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        return id
    }
}
