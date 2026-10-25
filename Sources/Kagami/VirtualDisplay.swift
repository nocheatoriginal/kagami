import AppKit
import CGVirtualDisplayPrivate

/// Ein echter (virtueller) Monitor, den macOS wie ein angeschlossenes Display behandelt.
/// Apps, deren Fenster hier liegen, laufen ganz normal – Kagami zeigt das Bild nur im Overlay.
@MainActor
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    private var generation = 0

    /// Gewünschte Größe in Punkten (logische Auflösung).
    private(set) var requestedPointSize: CGSize = .zero

    /// Wird aufgerufen, nachdem eine neue Auflösung aktiv ist.
    var onReconfigured: (@MainActor () -> Void)?

    var displayID: CGDirectDisplayID { display.displayID }

    /// Position und Größe in globalen CG-Koordinaten (Punkte).
    var bounds: CGRect { CGDisplayBounds(displayID) }

    /// Nutzbarer Bereich (ohne Menüleiste / Dock) in CG-Koordinaten.
    var visibleBounds: CGRect {
        if let screen = Geometry.screen(for: displayID) {
            return Geometry.cgRect(fromCocoa: screen.visibleFrame)
        }
        return bounds
    }

    /// Tatsächliche Pixelgröße des Framebuffers.
    var pixelSize: CGSize {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let b = bounds
        return CGSize(width: b.width * 2, height: b.height * 2)
    }

    static let maxPointSize = CGSize(width: 3840, height: 2400)
    static let minPointSize = CGSize(width: 640, height: 360)

    init?(name: String, pointSize: CGSize) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = 7680
        descriptor.maxPixelsHigh = 4800
        // Physische Größe bestimmt die "DPI" – so wählt macOS bevorzugt HiDPI-Modi.
        descriptor.sizeInMillimeters = CGSize(width: 340, height: 220)
        descriptor.vendorID = 0x4B47   // "KG"
        descriptor.productID = 0x4D49  // "MI"
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { return nil }
        self.display = display
        apply(pointSize: pointSize, immediately: true)
    }

    /// Ändert die Auflösung, damit sie zum Overlay-Fenster passt (entprellt).
    func resize(to pointSize: CGSize) {
        apply(pointSize: pointSize, immediately: false)
    }

    private func apply(pointSize: CGSize, immediately: Bool) {
        let width = Self.roundTo8(pointSize.width.clamped(to: Self.minPointSize.width...Self.maxPointSize.width))
        let height = Self.roundTo8(pointSize.height.clamped(to: Self.minPointSize.height...Self.maxPointSize.height))
        let size = CGSize(width: width, height: height)
        if size == requestedPointSize { return }
        requestedPointSize = size

        generation += 1
        let myGeneration = generation
        onMain(after: immediately ? 0 : 0.35) { [weak self] in
            guard let self, self.generation == myGeneration else { return }  // entprellen
            self.applyNow()
        }
    }

    private func applyNow() {
        let w = Int(requestedPointSize.width)
        let h = Int(requestedPointSize.height)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Je nach macOS-Version werden Modi als Punkte oder Pixel interpretiert –
        // wir bieten beide an und wählen danach gezielt den HiDPI-Modus aus.
        var modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]
        if w * 2 <= 7680, h * 2 <= 4800 {
            modes.append(CGVirtualDisplayMode(width: UInt(w * 2), height: UInt(h * 2), refreshRate: 60))
        }
        settings.modes = modes

        if !display.applySettings(settings) {
            NSLog("[Kagami] applySettings fehlgeschlagen für \(w)x\(h)")
        }

        // macOS braucht einen Moment, bis die neuen Modi sichtbar sind.
        onMain(after: 0.25) { [weak self] in
            guard let self else { return }
            self.selectModeAndPlace(width: w, height: h)
            onMain(after: 0.25) { [weak self] in
                self?.onReconfigured?()
            }
        }
    }

    private func selectModeAndPlace(width: Int, height: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []

        let best = modes.first { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }
            ?? modes.first { $0.width == width && $0.height == height }
            ?? modes.max { ($0.width * $0.height) < ($1.width * $1.height) }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }

        if let best, CGDisplayCopyDisplayMode(displayID).map({ !Self.same($0, best) }) ?? true {
            CGConfigureDisplayWithDisplayMode(config, displayID, best, nil)
        }

        // Display diagonal an die äußerste Ecke aller anderen Monitore setzen,
        // damit der Mauszeiger praktisch nie versehentlich hinüberwandert.
        let others = Geometry.activeDisplays().filter { $0 != displayID }.map { CGDisplayBounds($0) }
        let union = others.reduce(CGRect.null) { $0.union($1) }
        if !union.isNull {
            CGConfigureDisplayOrigin(config, displayID, Int32(union.maxX), Int32(union.maxY))
        }

        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success {
            NSLog("[Kagami] Displaykonfiguration fehlgeschlagen: \(result.rawValue)")
        }
    }

    private static func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth
    }

    private static func roundTo8(_ value: CGFloat) -> CGFloat {
        (value / 8).rounded() * 8
    }
}
