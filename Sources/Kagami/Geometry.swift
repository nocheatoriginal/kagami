import AppKit

/// Hilfsfunktionen für die zwei Koordinatensysteme von macOS:
/// - CoreGraphics / Accessibility / CGEvent: Ursprung oben links am Hauptbildschirm, y nach unten.
/// - Cocoa (NSScreen / NSWindow): Ursprung unten links am Hauptbildschirm, y nach oben.
@MainActor
enum Geometry {
    /// Höhe des Hauptbildschirms (der mit Ursprung 0,0 im Cocoa-System).
    static var primaryScreenHeight: CGFloat {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        return primary?.frame.height ?? 0
    }

    static func cgRect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cgPoint(fromCocoa point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
    }

    /// Aktuelle Cursorposition in CG-Koordinaten.
    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Rechteck, in dem ein Inhalt mit `contentSize` per Aspect-Fit in `bounds` dargestellt wird.
    static func aspectFitRect(content contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Führt `block` (nach `delay` Sekunden) auf dem Main-Actor aus.
func onMain(after delay: TimeInterval = 0, _ block: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        MainActor.assumeIsolated { block() }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
