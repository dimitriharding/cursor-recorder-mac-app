import Foundation
import ScreenCaptureKit
import AVFoundation
import QuartzCore
import CoreGraphics

/// Captures the **iPhone Mirroring** window via ScreenCaptureKit. This works wirelessly
/// (no USB screen source needed) by recording the window that Apple's iPhone Mirroring app
/// already displays. Frames are shown live and composited with the cursor on record.
final class MirroringCaptureAdapter: NSObject, PhoneCaptureAdapter {

    let platform: PhonePlatform = .iphone

    private let renderer: CursorRenderer
    private let liveCursor: LiveCursor
    private let telemetry: CursorTelemetryRecorder

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let sampleQueue = DispatchQueue(label: "Mirroring.samples")
    private let audioQueue = DispatchQueue(label: "Mirroring.audio")

    private var stream: SCStream?
    private var windowsByID: [CGWindowID: SCWindow] = [:]
    private var writer: FrameCompositorWriter?

    /// The window currently being captured, so the coordinator can track the pointer over it.
    private(set) var capturedWindowID: CGWindowID?

    /// Capture options (set by the coordinator before preview starts).
    var fps: Int = 60
    var capturesAudio: Bool = true
    var crop: CropInsets = .zero

    /// Surfaced when the stream stops unexpectedly (e.g. the Mirroring window closes).
    var onRuntimeError: ((String) -> Void)?

    init(renderer: CursorRenderer, liveCursor: LiveCursor, telemetry: CursorTelemetryRecorder) {
        self.renderer = renderer
        self.liveCursor = liveCursor
        self.telemetry = telemetry
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    var previewLayer: CALayer? { displayLayer }

    /// True if Apple's iPhone Mirroring app is currently running.
    static var iPhoneMirroringRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenContinuity"
            || ($0.localizedName?.localizedCaseInsensitiveContains("iPhone Mirroring") ?? false)
        }
    }

    // MARK: - Discovery

    /// Screen Recording permission status — checked WITHOUT prompting, so routine scans /
    /// auto-rescans never re-trigger the system dialog once the user has decided.
    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Explicitly ask for Screen Recording permission (shows the prompt only when the status
    /// is undetermined). Call this from a user action, never from a background scan.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func scanDevices() async throws -> [PhoneCaptureDevice] {
        // Do NOT call SCShareableContent unless permission is already granted — calling it
        // while undetermined re-pops the system prompt on every scan.
        guard Self.hasScreenRecordingPermission else { return [] }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // No Screen Recording permission yet (or SCK unavailable) — surface nothing here;
            // the coordinator shows a hint when iPhone Mirroring is running but unusable.
            NSLog("MirroringScan: SCShareableContent FAILED: \(error)")
            return []
        }

        windowsByID.removeAll()
        var phones: [PhoneCaptureDevice] = []
        var windows: [(area: CGFloat, device: PhoneCaptureDevice)] = []

        for window in content.windows {
            guard let kind = captureKind(for: window) else { continue }
            guard window.frame.width > 120, window.frame.height > 120 else { continue }
            windowsByID[window.windowID] = window

            let name: String
            switch kind {
            case .mirroring: name = "iPhone (Mirroring)"
            case .simulator: name = "Simulator: \(window.title ?? "iOS")"
            case .window:
                let app = window.owningApplication?.applicationName ?? "App"
                let title = window.title ?? ""
                name = title.isEmpty ? "Window: \(app)" : "Window: \(app) — \(title)"
            }

            let device = PhoneCaptureDevice(
                id: "mirroring-\(window.windowID)",
                platform: .iphone,
                name: name,
                connection: .usb,
                width: Int(window.frame.width),
                height: Int(window.frame.height),
                supportsAudio: false,
                readiness: .ready,
                backend: .mirroring
            )
            if kind == .window {
                windows.append((window.frame.width * window.frame.height, device))
            } else {
                phones.append(device)
            }
        }

        // Phone sources first, then the largest windows (capped to keep the picker usable).
        let topWindows = windows.sorted { $0.area > $1.area }.prefix(12).map { $0.device }
        return phones + topWindows
    }

    private enum CaptureKind: Equatable { case mirroring, simulator, window }

    /// Classifies a window: the iPhone Mirroring window, an iOS Simulator device window, or
    /// any other normal application window. All are captured the same way via ScreenCaptureKit.
    private func captureKind(for window: SCWindow) -> CaptureKind? {
        let app = window.owningApplication
        let bundle = app?.bundleIdentifier ?? ""
        let appName = app?.applicationName ?? ""
        let title = window.title ?? ""

        if bundle == "com.apple.ScreenContinuity"
            || appName.localizedCaseInsensitiveContains("iPhone Mirroring")
            || title.localizedCaseInsensitiveContains("iPhone Mirroring") {
            return .mirroring
        }
        if bundle == "com.apple.iphonesimulator", !title.isEmpty {
            return .simulator
        }
        // Any other normal, on-screen application window (layer 0), excluding our own windows
        // and untitled chrome/utility surfaces.
        if window.windowLayer == 0, window.isOnScreen, !title.isEmpty,
           bundle != Bundle.main.bundleIdentifier {
            return .window
        }
        return nil
    }

    private func windowID(from deviceID: String) -> CGWindowID? {
        guard deviceID.hasPrefix("mirroring-"),
              let raw = UInt32(deviceID.dropFirst("mirroring-".count)) else { return nil }
        return CGWindowID(raw)
    }

    // MARK: - Preview

    func startPreview(device: PhoneCaptureDevice) async throws {
        guard let wid = windowID(from: device.id), let window = windowsByID[wid] else {
            throw CaptureError.noVideoSource
        }
        try await startStream(window: window)
    }

    private func startStream(window: SCWindow) async throws {
        await stopStreamInternal()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Cropped region (in window points) — trims chrome/bezel so output is "just the screen".
        let w = window.frame.width, h = window.frame.height
        let cropRect = CGRect(
            x: w * crop.left,
            y: h * crop.top,
            width: w * crop.widthFraction,
            height: h * crop.heightFraction
        )

        let config = SCStreamConfiguration()
        config.width = max(2, Int(cropRect.width * scale))
        config.height = max(2, Int(cropRect.height * scale))
        if !crop.isZero { config.sourceRect = cropRect }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false        // we composite our own cursor
        config.queueDepth = 6
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(10, min(60, fps))))
        if capturesAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true   // don't record our own sounds
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.capturedWindowID = window.windowID
    }

    func stopPreview() async {
        await stopStreamInternal()
    }

    private func stopStreamInternal() async {
        capturedWindowID = nil
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - Recording

    func startRecording(session: RecordingSession) async throws {
        guard stream != nil else { throw CaptureError.deviceNotReady("Mirroring preview is not running.") }
        renderer.update(config: session.cursor)
        telemetry.begin(at: CACurrentMediaTime())
        let w = FrameCompositorWriter(
            outputURL: session.outputURL,
            renderer: renderer,
            liveCursor: liveCursor,
            telemetry: telemetry,
            includeAudio: capturesAudio,
            quality: session.quality
        )
        sampleQueue.sync { self.writer = w }
    }

    func stopRecording() async throws -> URL {
        let w: FrameCompositorWriter? = sampleQueue.sync {
            let current = self.writer; self.writer = nil; return current
        }
        guard let w else { throw CaptureError.writerFailed("No active recording.") }
        return try await w.finish()
    }

    func cancelRecording() async {
        let w: FrameCompositorWriter? = sampleQueue.sync {
            let current = self.writer; self.writer = nil; return current
        }
        w?.cancel()
    }
}

// MARK: - SCStream delegate & output

extension MirroringCaptureAdapter: SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onRuntimeError?("iPhone Mirroring capture stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        if type == .audio {
            writer?.appendAudio(sampleBuffer)
            return
        }

        guard type == .screen else { return }

        // Only present completed frames (skip blank/idle status frames).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
        writer?.appendVideo(sampleBuffer)
    }
}
