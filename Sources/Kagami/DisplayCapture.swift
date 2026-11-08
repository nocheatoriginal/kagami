import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Streamt den Inhalt des virtuellen Displays per ScreenCaptureKit (GPU, IOSurface, ~60 fps).
///
/// Frames werden direkt auf der Capture-Queue in die `StreamLayer`s geschrieben – nicht über
/// den Main-Thread. So läuft das Bild flüssig weiter, auch wenn der Main-Thread gerade mit
/// Accessibility-Aufrufen, Menüs oder Layout beschäftigt ist.
///
/// `@unchecked Sendable`: Der Zustand (`stream`, `restarting` …) wird nur auf dem Main-Thread
/// geändert, die Frame-Ziele sind per Lock geschützt.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "kagami.capture", qos: .userInteractive)
    private var displayID: CGDirectDisplayID = 0
    private var pixelSize: CGSize = .zero
    private var restarting = false
    /// Gedrosselt (2 fps), solange niemand das Bild sieht.
    private var throttled = false

    /// Ziele für neue Frames (werden auf der Capture-Queue gelesen).
    private let sinksLock = NSLock()
    private var sinks: [StreamLayer] = []

    var onError: (@MainActor (String) -> Void)?

    /// Layer, der ab jetzt jeden Frame bekommt.
    func addSink(_ layer: StreamLayer) {
        sinksLock.lock()
        sinks.append(layer)
        sinksLock.unlock()
    }

    func start(displayID: CGDirectDisplayID, pixelSize: CGSize) {
        self.displayID = displayID
        self.pixelSize = pixelSize
        Task { await self.startInternal(attempt: 0) }
    }

    func update(pixelSize: CGSize) {
        guard pixelSize != self.pixelSize else { return }
        self.pixelSize = pixelSize
        applyConfiguration()
    }

    /// Stream drosseln, solange weder Overlay noch Kagami-Schreibtisch sichtbar sind.
    func setThrottled(_ value: Bool) {
        guard value != throttled else { return }
        throttled = value
        applyConfiguration()
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    private func applyConfiguration() {
        stream?.updateConfiguration(makeConfiguration()) { error in
            if let error { NSLog("[Kagami] updateConfiguration: \(error.localizedDescription)") }
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(pixelSize.width))
        config.height = max(2, Int(pixelSize.height))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: throttled ? 2 : 60)
        // Ein Surface hängt im Layer, eins wird gerade beschrieben – 4 reichen ohne Frame-Verluste
        // und sparen bei großen Auflösungen viel Speicher.
        config.queueDepth = 4
        // Der echte Cursor bleibt über dem Overlay; im Stream würde er nur flackern.
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        return config
    }

    private func startInternal(attempt: Int) async {
        do {
            // Es werden nur die Displays gebraucht – keine (teure) Liste aller Fenster.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                // Das virtuelle Display taucht manchmal erst nach kurzer Zeit auf.
                if attempt < 20 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await startInternal(attempt: attempt + 1)
                } else {
                    report("Virtuelles Display nicht in ScreenCaptureKit gefunden.")
                }
                return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            DispatchQueue.main.async {
                self.stream = stream
                self.restarting = false
            }
        } catch {
            DispatchQueue.main.async { self.restarting = false }
            report("Bildschirmaufnahme fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        NSLog("[Kagami] \(message)")
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onError?(message) } }
    }

    // MARK: SCStreamOutput (Capture-Queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer,
            let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        sinksLock.lock()
        let targets = sinks
        sinksLock.unlock()
        targets.forEach { $0.present(surface) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Kagami] Stream gestoppt: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.stream = nil
            guard !self.restarting else { return }
            self.restarting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                Task { await self.startInternal(attempt: 0) }
            }
        }
    }
}

/// Layer für das Live-Bild. Nimmt Frames von beliebigen Threads an (explizite Transaktion,
/// keine impliziten Animationen) und kann eingefroren werden – z. B. während der virtuelle
/// Monitor die Auflösung wechselt. Beim Auftauen wird weich auf das neue Bild übergeblendet.
final class StreamLayer: CALayer {
    private let lock = NSLock()
    private var frozen = false
    private var fadeNextFrame = false

    func setFrozen(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard value != frozen else { return }
        frozen = value
        if !value { fadeNextFrame = true }
    }

    /// Thread-sicher; wird von der Capture-Queue aufgerufen.
    func present(_ surface: IOSurfaceRef) {
        lock.lock()
        let skip = frozen
        let fade = !skip && fadeNextFrame
        if fade { fadeNextFrame = false }
        lock.unlock()
        guard !skip else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            add(transition, forKey: "fade")
        }
        contents = surface
        CATransaction.commit()
    }
}
