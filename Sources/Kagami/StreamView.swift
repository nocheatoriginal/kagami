import AppKit

@MainActor
protocol StreamViewDelegate: AnyObject {
    /// Normierter Punkt (0…1, Ursprung oben links) → globaler CG-Punkt auf dem virtuellen Display.
    func streamView(_ view: StreamView, globalPointFor normalized: CGPoint) -> CGPoint
    var inputForwarder: InputForwarder { get }
    func streamView(_ view: StreamView, didReceiveAppURLs urls: [URL])
}

/// Zeigt den Live-Stream des virtuellen Displays und nimmt Maus-Eingaben sowie Drag & Drop an.
@MainActor
final class StreamView: NSView {
    weak var delegate: StreamViewDelegate?

    /// Seitenverhältnis des Displays (Punkte) – für Aspect-Fit und Koordinaten-Mapping.
    var displaySize: CGSize = CGSize(width: 16, height: 10) {
        didSet { needsLayout = true }
    }

    /// Bekommt die Frames direkt von `DisplayCapture` (ohne Umweg über den Main-Thread).
    let streamLayer = StreamLayer()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let hintBackground = NSVisualEffectView()
    private var dropHighlight = false { didSet { updateBorder() } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        streamLayer.contentsGravity = .resizeAspect
        streamLayer.magnificationFilter = .linear
        streamLayer.minificationFilter = .trilinear
        streamLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(streamLayer)

        hintBackground.material = .hudWindow
        hintBackground.blendingMode = .withinWindow
        hintBackground.state = .active
        hintBackground.wantsLayer = true
        hintBackground.layer?.cornerRadius = 14
        hintBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintBackground)

        hintLabel.font = .systemFont(ofSize: 15, weight: .medium)
        hintLabel.textColor = .labelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintBackground.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            hintBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintBackground.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            hintLabel.leadingAnchor.constraint(equalTo: hintBackground.leadingAnchor, constant: 22),
            hintLabel.trailingAnchor.constraint(equalTo: hintBackground.trailingAnchor, constant: -22),
            hintLabel.topAnchor.constraint(equalTo: hintBackground.topAnchor, constant: 16),
            hintLabel.bottomAnchor.constraint(equalTo: hintBackground.bottomAnchor, constant: -16),
        ])

        registerForDraggedTypes([.fileURL])
        setHint(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Letztes Bild stehen lassen (z. B. während der virtuelle Monitor die Auflösung wechselt);
    /// beim Auftauen wird weich auf das neue Bild übergeblendet.
    func setFrozen(_ frozen: Bool) {
        streamLayer.setFrozen(frozen)
    }

    /// Für bildschirmfüllende Fenster: globaler CG-Punkt auf dem Bildschirm → Punkt auf dem
    /// virtuellen Display. Mit `clamp` auch außerhalb des Bildes (an den Rand gesetzt).
    func displayPoint(forScreenPoint point: CGPoint, screenRect: CGRect, clamp: Bool) -> CGPoint? {
        let local = CGPoint(x: point.x - screenRect.minX, y: point.y - screenRect.minY)
        guard clamp || imageRect.contains(local) else { return nil }
        return globalPoint(forLocal: local)
    }

    /// Aktuell angezeigter Hinweis (nil = keiner).
    var currentHint: String? { hintBackground.isHidden ? nil : hintLabel.stringValue }

    /// Hinweistext in der Mitte (nil = ausblenden).
    func setHint(_ text: String?) {
        guard text != currentHint else { return }
        hintLabel.stringValue = text ?? ""
        hintBackground.isHidden = (text == nil)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        streamLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Koordinaten

    /// Bereich, in dem das Bild tatsächlich gezeigt wird (Aspect-Fit, in View-Koordinaten).
    var imageRect: CGRect { Geometry.aspectFitRect(content: displaySize, in: bounds) }

    /// Punkt in View-Koordinaten → globaler CG-Punkt auf dem virtuellen Display (an den Rand geklemmt).
    private func globalPoint(forLocal p: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard let delegate, rect.width > 0, rect.height > 0 else { return nil }
        let nx = ((p.x - rect.minX) / rect.width).clamped(to: 0...0.9999)
        let ny = ((p.y - rect.minY) / rect.height).clamped(to: 0...0.9999)
        return delegate.streamView(self, globalPointFor: CGPoint(x: nx, y: ny))
    }

    private func localPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func flags(_ event: NSEvent) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) { forward(.down, .left, event) }
    override func mouseDragged(with event: NSEvent) { forward(.dragged, .left, event) }
    override func mouseUp(with event: NSEvent) { forward(.up, .left, event) }
    override func rightMouseDown(with event: NSEvent) { forward(.down, .right, event) }
    override func rightMouseDragged(with event: NSEvent) { forward(.dragged, .right, event) }
    override func rightMouseUp(with event: NSEvent) { forward(.up, .right, event) }
    override func otherMouseDown(with event: NSEvent) { forward(.down, .center, event) }
    override func otherMouseDragged(with event: NSEvent) { forward(.dragged, .center, event) }
    override func otherMouseUp(with event: NSEvent) { forward(.up, .center, event) }

    /// Klicks starten nur auf dem Bild; Drags und Loslassen werden an den Rand geklemmt.
    private func forward(_ phase: MousePhase, _ button: CGMouseButton, _ event: NSEvent) {
        let local = localPoint(event)
        if phase == .down, !imageRect.contains(local) { return }
        guard let p = globalPoint(forLocal: local) else { return }
        delegate?.inputForwarder.mouse(phase, button, at: p, clickCount: event.clickCount, flags: flags(event))
    }

    override func mouseMoved(with event: NSEvent) {
        // AppKit fasst Mausbewegungen bereits pro Bildschirm-Frame zusammen – keine eigene Drosselung,
        // damit die letzte Position (und damit der Hover-Zustand) nie verloren geht.
        let local = localPoint(event)
        guard imageRect.contains(local), let p = globalPoint(forLocal: local) else { return }
        delegate?.inputForwarder.mouseMoved(at: p, flags: flags(event))
    }

    override func scrollWheel(with event: NSEvent) {
        let local = localPoint(event)
        guard imageRect.contains(local), let p = globalPoint(forLocal: local),
              let copy = event.cgEvent?.copy() else { return }
        // Original weiterreichen – behält Trägheit, Gummiband und Scroll-Phasen.
        // Ist der Stream skaliert, die Pixel-Deltas entsprechend umrechnen.
        let rect = imageRect
        let scale = rect.width > 0 ? displaySize.width / rect.width : 1
        if event.hasPreciseScrollingDeltas, abs(scale - 1) > 0.02 {
            Self.scaleScrollDeltas(copy, by: scale)
        }
        delegate?.inputForwarder.forward(copy, to: p)
    }

    private static func scaleScrollDeltas(_ event: CGEvent, by scale: CGFloat) {
        let pointFields: [CGEventField] = [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
        for field in pointFields {
            let value = Double(event.getIntegerValueField(field)) * Double(scale)
            event.setIntegerValueField(field, value: Int64(value.rounded()))
        }
        let fixedFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        for field in fixedFields {
            event.setDoubleValueField(field, value: event.getDoubleValueField(field) * Double(scale))
        }
    }

    // MARK: Drag & Drop von Apps

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !sender.appURLs.isEmpty
        dropHighlight = ok
        return ok ? .link : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlight ? .link : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let urls = sender.appURLs
        guard !urls.isEmpty else { return false }
        delegate?.streamView(self, didReceiveAppURLs: urls)
        return true
    }

    private func updateBorder() {
        layer?.borderWidth = dropHighlight ? 3 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
