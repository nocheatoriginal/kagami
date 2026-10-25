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

/// Übersetzt Maus-Events aus dem Overlay in Events auf dem virtuellen Display.
@MainActor
final class InputForwarder {
    var mode: InputMode = .direct
    /// Prozess-ID von Kagami selbst – eigene Fenster werden ignoriert.
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    /// Bis zu diesem Zeitpunkt darf der Cursor auf dem virtuellen Display sein (Kompatibel-Modus).
    private(set) var cursorExcursionUntil = Date.distantPast

    /// Ziel eines laufenden Drags – damit alle Drag-Events an dasselbe Fenster gehen.
    private var dragTarget: WindowTarget?
    private var hoverCache: (point: CGPoint, target: WindowTarget?, time: Date)?

    /// Fenster auf dem virtuellen Display unter einem Punkt.
    struct WindowTarget {
        let windowID: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    // MARK: Maus

    func mouseDown(_ button: CGMouseButton, at point: CGPoint, clickCount: Int, flags: CGEventFlags) {
        let target = window(at: point)
        dragTarget = target
        if let target { bringToFront(target) }
        post(Self.downType(button), button: button, at: point, clickCount: clickCount, flags: flags, target: target)
    }

    func mouseDragged(_ button: CGMouseButton, at point: CGPoint, flags: CGEventFlags) {
        post(Self.dragType(button), button: button, at: point, clickCount: 1, flags: flags, target: dragTarget ?? window(at: point))
    }

    func mouseUp(_ button: CGMouseButton, at point: CGPoint, clickCount: Int, flags: CGEventFlags) {
        post(Self.upType(button), button: button, at: point, clickCount: clickCount, flags: flags, target: dragTarget ?? window(at: point))
        dragTarget = nil
    }

    /// Hover – nur im Direkt-Modus, sonst würde der Cursor ständig springen.
    func mouseMoved(at point: CGPoint, flags: CGEventFlags) {
        guard mode == .direct else { return }
        let target: WindowTarget?
        if let cache = hoverCache, Date().timeIntervalSince(cache.time) < 0.25,
           let t = cache.target, t.bounds.contains(point) {
            target = t
        } else {
            target = window(at: point)
            hoverCache = (point, target, Date())
        }
        guard let target else { return }
        post(.mouseMoved, button: .left, at: point, clickCount: 0, flags: flags, target: target)
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, at point: CGPoint, flags: CGEventFlags) {
        let units: CGScrollEventUnit = precise ? .pixel : .line
        let dy = Int32(precise ? deltaY.rounded() : deltaY.rounded(.awayFromZero))
        let dx = Int32(precise ? deltaX.rounded() : deltaX.rounded(.awayFromZero))
        guard dx != 0 || dy != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.location = point
        event.flags = flags
        deliver(event, at: point, target: window(at: point))
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
        // Direkt-Modus nur für Fenster echter Apps. Menüleiste, Dock & Co. gehören
        // System-Prozessen und brauchen echte HID-Events.
        let directPossible: Bool = {
            guard let target, let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
            return app.activationPolicy != .prohibited
        }()

        if mode == .direct, directPossible, let target {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                       value: Int64(target.windowID))
            event.postToPid(target.pid)
            return
        }
        if mode == .direct, event.type == .mouseMoved { return }  // Hover nie per Cursorsprung

        let home = Geometry.cursorLocation
        cursorExcursionUntil = Date().addingTimeInterval(0.12)
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

    /// Macht die App unter dem Klick zur aktiven App, damit Tastatureingaben dort landen.
    private func bringToFront(_ target: WindowTarget) {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = AXHelpers.windowElement(pid: target.pid, matching: target.bounds) {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
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
            return WindowTarget(windowID: number, pid: pid, bounds: bounds)
        }
        return nil
    }

    private static func displayContaining(_ point: CGPoint) -> CGDirectDisplayID {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        return id
    }

    private static func downType(_ b: CGMouseButton) -> CGEventType {
        switch b { case .left: return .leftMouseDown; case .right: return .rightMouseDown; default: return .otherMouseDown }
    }
    private static func upType(_ b: CGMouseButton) -> CGEventType {
        switch b { case .left: return .leftMouseUp; case .right: return .rightMouseUp; default: return .otherMouseUp }
    }
    private static func dragType(_ b: CGMouseButton) -> CGEventType {
        switch b { case .left: return .leftMouseDragged; case .right: return .rightMouseDragged; default: return .otherMouseDragged }
    }
}
