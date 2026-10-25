import AppKit
import ApplicationServices

/// Fenster auf *allen* Spaces finden.
///
/// `kAXWindowsAttribute` liefert nur Fenster des aktuellen Spaces. Fenster auf anderen
/// Schreibtischen oder in Vollbild-Spaces bekommt man nur über die private Funktion
/// `_AXUIElementCreateWithRemoteToken` (derselbe Trick wie in AltTab): man baut die
/// AX-Elemente anhand ihrer internen ID selbst zusammen.
extension AXHelpers {
    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let createWithRemoteToken: CreateWithRemoteToken? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(sym, to: CreateWithRemoteToken.self)
    }()

    private static let getWindow: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindow.self)
    }()

    /// CGWindowID eines AX-Fensters (0, falls unbekannt).
    static func windowID(_ window: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        guard let getWindow = Self.getWindow, getWindow(window, &id) == .success else { return 0 }
        return id
    }

    /// Alle Fenster einer App – auch die auf anderen Spaces und im Vollbild.
    static func windowsOnAllSpaces(pid: pid_t) -> [AXUIElement] {
        var result = windows(pid: pid)
        var known = Set(result.map(windowID).filter { $0 != 0 })
        guard let createWithRemoteToken = Self.createWithRemoteToken else { return result }

        // Token-Aufbau: pid (4 Byte) · 0 (4 Byte) · "coco" (4 Byte) · Element-ID (8 Byte)
        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0)) { token.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: Int32(0x636F_636F)) { token.replaceSubrange(8..<12, with: $0) }

        let deadline = Date().addingTimeInterval(0.6)
        for elementID in UInt64(0)..<1000 {
            if Date() > deadline { break }
            withUnsafeBytes(of: elementID) { token.replaceSubrange(12..<20, with: $0) }
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            guard isStandardWindow(element) else { continue }
            let id = windowID(element)
            if id != 0, known.contains(id) { continue }
            if id != 0 { known.insert(id) }
            result.append(element)
        }
        return result
    }
}
