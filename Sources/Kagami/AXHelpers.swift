import AppKit
import ApplicationServices

/// Dünne Hülle um die Accessibility-API zum Lesen und Verschieben fremder Fenster.
enum AXHelpers {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// Nur "normale" Fenster – keine Paletten, Tooltips, Sheets.
    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard let role = string(window, kAXRoleAttribute), role == kAXWindowRole as String else { return false }
        let subrole = string(window, kAXSubroleAttribute)
        return subrole == nil || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    /// Verschiebt ein Fenster in `rect` (CG-Koordinaten). Mit `fill` wird es auf die volle Größe gezogen,
    /// sonst nur so verkleinert, dass es hineinpasst, und zentriert.
    static func place(_ window: AXUIElement, in rect: CGRect, fill: Bool) {
        // Vollbild-Fenster werden nicht verschoben – das übernimmt HostManager.transfer.
        if isFullScreen(window) { return }
        if bool(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let current = frame(window)?.size ?? rect.size
        let size = fill ? rect.size : CGSize(width: min(current.width, rect.width), height: min(current.height, rect.height))
        let origin = CGPoint(x: rect.midX - size.width / 2, y: fill ? rect.minY : rect.midY - size.height / 2)
        // Zuerst Position (damit das Fenster auf dem Zieldisplay ist), dann Größe, dann erneut Position,
        // weil manche Apps die Größe beim Displaywechsel begrenzen.
        setPosition(window, CGPoint(x: rect.minX, y: rect.minY))
        setSize(window, size)
        setPosition(window, CGPoint(x: max(rect.minX, origin.x), y: max(rect.minY, origin.y)))
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        bool(window, "AXFullScreen") == true
    }

    /// Nativer macOS-Vollbildmodus (eigener Space) – wie der grüne Knopf.
    static func setFullScreen(_ window: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// AX-Fenster, dessen Rahmen zu `bounds` passt (für das Fenster unter dem Mauszeiger).
    static func windowElement(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        windows(pid: pid).first { window in
            guard let f = frame(window) else { return false }
            return abs(f.minX - bounds.minX) < 2 && abs(f.minY - bounds.minY) < 2
                && abs(f.width - bounds.width) < 2 && abs(f.height - bounds.height) < 2
        }
    }
}
