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

    private let imageLayer = CALayer()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let hintBackground = NSVisualEffectView()
    private var dropHighlight = false { didSet { updateBorder() } }
    private var trackingArea: NSTrackingArea?
    private var lastMoveForward = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)

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

    private var frozen = false
    private var fadeNextFrame = false

    func display(surface: IOSurfaceRef) {
        guard !frozen else { return }
        if fadeNextFrame {
            fadeNextFrame = false
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            imageLayer.add(fade, forKey: "fade")
        }
        imageLayer.contents = surface
    }

    /// Letztes Bild stehen lassen (z. B. während der virtuelle Monitor die Auflösung wechselt);
    /// beim Auftauen wird weich auf das neue Bild übergeblendet.
    func setFrozen(_ frozen: Bool) {
        guard frozen != self.frozen else { return }
        self.frozen = frozen
        if !frozen { fadeNextFrame = true }
    }

    /// Für bildschirmfüllende Fenster: globaler CG-Punkt auf dem Bildschirm → Punkt auf dem
    /// virtuellen Display. Mit `clamp` auch außerhalb des Bildes (an den Rand gesetzt).
    func displayPoint(forScreenPoint point: CGPoint, screenRect: CGRect, clamp: Bool) -> CGPoint? {
        guard let delegate else { return nil }
        let local = CGPoint(x: point.x - screenRect.minX, y: point.y - screenRect.minY)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(local) else { return nil }
        let nx = ((local.x - rect.minX) / rect.width).clamped(to: 0...0.9999)
        let ny = ((local.y - rect.minY) / rect.height).clamped(to: 0...0.9999)
        return delegate.streamView(self, globalPointFor: CGPoint(x: nx, y: ny))
    }

    /// Aktuell angezeigter Hinweis (nil = keiner).
    var currentHint: String? { hintBackground.isHidden ? nil : hintLabel.stringValue }

    /// Hinweistext in der Mitte (nil = ausblenden).
    func setHint(_ text: String?) {
        hintLabel.stringValue = text ?? ""
        hintBackground.isHidden = (text == nil)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
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

    private func globalPoint(for event: NSEvent) -> CGPoint? {
        guard let delegate else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let nx = ((p.x - rect.minX) / rect.width).clamped(to: 0...0.9999)
        let ny = ((p.y - rect.minY) / rect.height).clamped(to: 0...0.9999)
        return delegate.streamView(self, globalPointFor: CGPoint(x: nx, y: ny))
    }

    private func flags(_ event: NSEvent) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
    }

    private func isInsideImage(_ event: NSEvent) -> Bool {
        imageRect.contains(convert(event.locationInWindow, from: nil))
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) {
        guard isInsideImage(event), let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseDown(.left, at: p, clickCount: event.clickCount, flags: flags(event))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseDragged(.left, at: p, flags: flags(event))
    }
    override func mouseUp(with event: NSEvent) {
        guard let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseUp(.left, at: p, clickCount: event.clickCount, flags: flags(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInsideImage(event), let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseDown(.right, at: p, clickCount: event.clickCount, flags: flags(event))
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseDragged(.right, at: p, flags: flags(event))
    }
    override func rightMouseUp(with event: NSEvent) {
        guard let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseUp(.right, at: p, clickCount: event.clickCount, flags: flags(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isInsideImage(event), let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseDown(.center, at: p, clickCount: event.clickCount, flags: flags(event))
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseDragged(.center, at: p, flags: flags(event))
    }
    override func otherMouseUp(with event: NSEvent) {
        guard let p = globalPoint(for: event) else { return }
        delegate?.inputForwarder.mouseUp(.center, at: p, clickCount: event.clickCount, flags: flags(event))
    }

    override func mouseMoved(with event: NSEvent) {
        // Auf ~60 Hz drosseln.
        let now = Date()
        guard now.timeIntervalSince(lastMoveForward) > 1.0 / 60.0, isInsideImage(event),
              let p = globalPoint(for: event) else { return }
        lastMoveForward = now
        delegate?.inputForwarder.mouseMoved(at: p, flags: flags(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInsideImage(event), let p = globalPoint(for: event) else { return }
        // Stream ist ggf. skaliert: Pixel-Deltas entsprechend umrechnen.
        let scale = imageRect.width > 0 ? displaySize.width / imageRect.width : 1
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX * scale : event.scrollingDeltaX
        let dy = precise ? event.scrollingDeltaY * scale : event.scrollingDeltaY
        delegate?.inputForwarder.scroll(deltaX: dx, deltaY: dy, precise: precise, at: p, flags: flags(event))
    }

    // MARK: Drag & Drop von Apps

    private func appURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "app" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !appURLs(from: sender).isEmpty
        dropHighlight = ok
        return ok ? .link : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        appURLs(from: sender).isEmpty ? [] : .link
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let urls = appURLs(from: sender)
        guard !urls.isEmpty else { return false }
        delegate?.streamView(self, didReceiveAppURLs: urls)
        return true
    }

    private func updateBorder() {
        layer?.borderWidth = dropHighlight ? 3 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
