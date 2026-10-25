import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Streamt den Inhalt des virtuellen Displays per ScreenCaptureKit (GPU, IOSurface, ~60 fps).
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "kagami.capture", qos: .userInteractive)
    private var displayID: CGDirectDisplayID = 0
    private var pixelSize: CGSize = .zero
    private var restarting = false
    /// Gedrosselt (2 fps), solange niemand das Bild sieht.
    private var throttled = false

    /// Neuer Frame (wird auf dem Main-Thread aufgerufen).
    var onFrame: (@MainActor (IOSurfaceRef) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    func start(displayID: CGDirectDisplayID, pixelSize: CGSize) {
        self.displayID = displayID
        self.pixelSize = pixelSize
        Task { await self.startInternal(attempt: 0) }
    }

    func update(pixelSize: CGSize) {
        guard pixelSize != self.pixelSize else { return }
        self.pixelSize = pixelSize
        guard let stream else { return }
        stream.updateConfiguration(makeConfiguration()) { error in
            if let error { NSLog("[Kagami] updateConfiguration: \(error.localizedDescription)") }
        }
    }

    /// Stream drosseln, solange weder Overlay noch Kagami-Schreibtisch sichtbar sind.
    func setThrottled(_ value: Bool) {
        guard value != throttled else { return }
        throttled = value
        guard let stream else { return }
        stream.updateConfiguration(makeConfiguration()) { error in
            if let error { NSLog("[Kagami] updateConfiguration: \(error.localizedDescription)") }
        }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(pixelSize.width))
        config.height = max(2, Int(pixelSize.height))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: throttled ? 2 : 60)
        config.queueDepth = 5
        // Der echte Cursor bleibt über dem Overlay; im Stream würde er nur flackern.
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        return config
    }

    private func startInternal(attempt: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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
            self.stream = stream
            restarting = false
        } catch {
            report("Bildschirmaufnahme fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        NSLog("[Kagami] \(message)")
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onError?(message) } }
    }

    // MARK: SCStreamOutput

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

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFrame?(surface) }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Kagami] Stream gestoppt: \(error.localizedDescription)")
        self.stream = nil
        guard !restarting else { return }
        restarting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            Task { await self.startInternal(attempt: 0) }
        }
    }
}
