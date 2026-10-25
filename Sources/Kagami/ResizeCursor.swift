import AppKit

/// Zeigt die nativen macOS-Größenänderungs-Pfeile an den Rändern des Overlays.
/// Nötig, weil das Overlay nie "key" wird und macOS die Pfeile sonst nicht anzeigt.
@MainActor
final class ResizeCursorController {
    enum Edge { case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }

    private weak var window: NSWindow?
    private var showing = false
    private var liveEdge: Edge?

    /// Abstand außerhalb/innerhalb des Rahmens, in dem die Pfeile erscheinen.
    private let outside: CGFloat = 6
    private let inside: CGFloat = 4
    private let corner: CGFloat = 14

    init(window: NSWindow) {
        self.window = window
        Self.allowBackgroundCursor()
    }

    /// Bei jeder Mausbewegung aufrufen.
    func update() {
        guard let window, window.isVisible else { return reset() }
        if window.inLiveResize, let liveEdge { Self.cursor(for: liveEdge).set(); return }

        if let edge = edge(at: NSEvent.mouseLocation, frame: window.frame) {
            Self.cursor(for: edge).set()
            showing = true
        } else {
            reset()
        }
    }

    func liveResizeStarted() { liveEdge = edge(at: NSEvent.mouseLocation, frame: window?.frame ?? .zero) }
    func liveResizeEnded() { liveEdge = nil; update() }

    private func reset() {
        guard showing else { return }
        showing = false
        NSCursor.arrow.set()
    }

    private func edge(at p: NSPoint, frame f: NSRect) -> Edge? {
        guard f.insetBy(dx: -outside, dy: -outside).contains(p),
              !f.insetBy(dx: inside, dy: inside).contains(p) || nearCorner(p, f) else { return nil }
        let left = p.x < f.minX + corner, right = p.x > f.maxX - corner
        let bottom = p.y < f.minY + corner, top = p.y > f.maxY - corner
        // Ecken haben eine größere Zone als die Kanten.
        if top && left { return .topLeft }
        if top && right { return .topRight }
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if p.x < f.minX + inside { return .left }
        if p.x > f.maxX - inside { return .right }
        if p.y < f.minY + inside { return .bottom }
        if p.y > f.maxY - inside { return .top }
        return nil
    }

    private func nearCorner(_ p: NSPoint, _ f: NSRect) -> Bool {
        let nearX = p.x < f.minX + inside || p.x > f.maxX - inside
        let nearY = p.y < f.minY + inside || p.y > f.maxY - inside
        let cornerX = p.x < f.minX + corner || p.x > f.maxX - corner
        let cornerY = p.y < f.minY + corner || p.y > f.maxY - corner
        return (nearX && cornerY) || (nearY && cornerX)
    }

    private static func cursor(for edge: Edge) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edge {
            case .top: position = .top
            case .bottom: position = .bottom
            case .left: position = .left
            case .right: position = .right
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return privateCursor("_windowResizeNorthWestSouthEastCursor") ?? .crosshair
        case .topRight, .bottomLeft: return privateCursor("_windowResizeNorthEastSouthWestCursor") ?? .crosshair
        }
    }

    /// Diagonale Pfeile gibt es vor macOS 15 nur als private Klassenmethoden.
    private static func privateCursor(_ name: String) -> NSCursor? {
        let selector = NSSelectorFromString(name)
        let cls: AnyObject = NSCursor.self
        guard cls.responds(to: selector) else { return nil }
        return cls.perform(selector)?.takeUnretainedValue() as? NSCursor
    }

    /// Erlaubt Kagami, den Cursor zu setzen, obwohl eine andere App aktiv ist (private CGS-API).
    private static func allowBackgroundCursor() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSym, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
