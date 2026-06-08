import Foundation
import AVFoundation
import QuartzCore

/// Captures a USB-tethered, trusted iPhone screen source via AVFoundation. The iPhone is
/// exposed as a muxed/external CoreMediaIO device once `CoreMediaIOEnabler` runs. Frames are
/// composited with the cursor live and written straight to the final MP4.
final class IPhoneUSBCaptureAdapter: NSObject, PhoneCaptureAdapter {

    let platform: PhonePlatform = .iphone

    private let renderer: CursorRenderer
    private let liveCursor: LiveCursor
    private let telemetry: CursorTelemetryRecorder

    private let session = AVCaptureSession()
    private let sampleQueue = DispatchQueue(label: "IPhoneCapture.samples")
    private lazy var preview: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        return layer
    }()

    private var currentAVDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var writer: FrameCompositorWriter?
    private var outputURL: URL?

    /// Called when the capture session hits a runtime error or the device disconnects
    /// (e.g. the iPhone is unplugged mid-recording).
    var onRuntimeError: ((String) -> Void)?

    init(renderer: CursorRenderer, liveCursor: LiveCursor, telemetry: CursorTelemetryRecorder) {
        self.renderer = renderer
        self.liveCursor = liveCursor
        self.telemetry = telemetry
        super.init()
        CoreMediaIOEnabler.enableScreenCaptureDevices()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDeviceDisconnected(_:)),
            name: .AVCaptureDeviceWasDisconnected, object: nil
        )
    }

    @objc private func handleRuntimeError(_ note: Notification) {
        let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
            ?? "The capture session stopped unexpectedly."
        onRuntimeError?(message)
    }

    @objc private func handleDeviceDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice,
              device.uniqueID == currentAVDevice?.uniqueID else { return }
        onRuntimeError?("The iPhone was disconnected.")
    }

    var previewLayer: CALayer? { preview }

    // MARK: - Discovery

    func scanDevices() async throws -> [PhoneCaptureDevice] {
        CoreMediaIOEnabler.enableScreenCaptureDevices()

        let videoGranted = await requestAccess(for: .video)
        if !videoGranted {
            throw CaptureError.permissionDenied(
                "Camera/recording permission was denied. Grant it in System Settings ▸ Privacy & Security ▸ Camera."
            )
        }
        _ = await requestAccess(for: .audio)

        // CoreMediaIO devices can take a moment to enumerate after being enabled; retry a
        // few times so a freshly-plugged iPhone screen source is found without a manual rescan.
        var screens = discoverScreenDevices()
        var attempts = 0
        while screens.isEmpty && (iPhoneCameraPresent() || USBDetector.appleMobileDevicePresent()) && attempts < 5 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            screens = discoverScreenDevices()
            attempts += 1
        }

        if screens.isEmpty {
            // An iPhone is around (Continuity Camera or USB) but is NOT exposing its screen.
            // This is the common "wireless Continuity Camera, no USB screen tether" case.
            if iPhoneCameraPresent() || USBDetector.appleMobileDevicePresent() {
                return [PhoneCaptureDevice(
                    id: "iphone-no-screen",
                    platform: .iphone,
                    name: "iPhone — screen not shared yet",
                    connection: .usb,
                    width: nil, height: nil,
                    supportsAudio: false,
                    readiness: .waitingForTrust
                )]
            }
            return []
        }

        return screens.map { dev in
            let dims = Self.dimensions(of: dev)
            return PhoneCaptureDevice(
                id: dev.uniqueID,
                platform: .iphone,
                name: dev.localizedName,
                connection: .usb,
                width: dims?.width,
                height: dims?.height,
                supportsAudio: dev.hasMediaType(.muxed) || dev.hasMediaType(.audio),
                readiness: .ready
            )
        }
    }

    /// The iPhone *screen* source is exposed by CoreMediaIO as a MUXED device (video + audio
    /// together). We require muxed so we only ever capture the screen — never the iPhone
    /// camera / Continuity Camera (which are video-only).
    private func discoverScreenDevices() -> [AVCaptureDevice] {
        let muxed = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified
        ).devices
        let externalMuxed = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: nil, position: .unspecified
        ).devices.filter { $0.hasMediaType(.muxed) }

        var seen = Set<String>()
        var result: [AVCaptureDevice] = []
        for dev in (muxed + externalMuxed) where !seen.contains(dev.uniqueID) {
            seen.insert(dev.uniqueID)
            result.append(dev)
        }
        return result
    }

    /// True if an iPhone is visible only as a (Continuity) Camera — i.e. present but not
    /// sharing its screen. Used to give precise "connect via USB & Trust" guidance.
    private func iPhoneCameraPresent() -> Bool {
        var types: [AVCaptureDevice.DeviceType] = [.external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
        return devices.contains { $0.localizedName.lowercased().contains("iphone") }
    }

    // MARK: - Preview

    func startPreview(device: PhoneCaptureDevice) async throws {
        guard device.readiness == .ready else {
            throw CaptureError.deviceNotReady("This iPhone is not ready to capture yet.")
        }
        guard let avDevice = AVCaptureDevice(uniqueID: device.id) else {
            throw CaptureError.noVideoSource
        }
        currentAVDevice = avDevice

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let input = try AVCaptureDeviceInput(device: avDevice)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.noVideoSource
        }
        session.addInput(input)

        let vOut = AVCaptureVideoDataOutput()
        vOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        vOut.alwaysDiscardsLateVideoFrames = false
        vOut.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(vOut) { session.addOutput(vOut) }
        videoOutput = vOut

        let aOut = AVCaptureAudioDataOutput()
        aOut.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(aOut) { session.addOutput(aOut) }
        audioOutput = aOut

        session.commitConfiguration()

        if !session.isRunning {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                sampleQueue.async {
                    self.session.startRunning()
                    cont.resume()
                }
            }
        }
    }

    func stopPreview() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sampleQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                cont.resume()
            }
        }
    }

    // MARK: - Recording

    func startRecording(session recordingSession: RecordingSession) async throws {
        guard self.session.isRunning else {
            throw CaptureError.deviceNotReady("Preview is not running.")
        }
        renderer.update(config: recordingSession.cursor)
        telemetry.begin(at: CACurrentMediaTime())
        let w = FrameCompositorWriter(
            outputURL: recordingSession.outputURL,
            renderer: renderer,
            liveCursor: liveCursor,
            telemetry: telemetry,
            includeAudio: recordingSession.device.supportsAudio,
            quality: recordingSession.quality
        )
        outputURL = recordingSession.outputURL
        sampleQueue.sync { self.writer = w }
    }

    func stopRecording() async throws -> URL {
        let w: FrameCompositorWriter? = sampleQueue.sync {
            let current = self.writer
            self.writer = nil
            return current
        }
        guard let w else { throw CaptureError.writerFailed("No active recording.") }
        return try await w.finish()
    }

    func cancelRecording() async {
        let w: FrameCompositorWriter? = sampleQueue.sync {
            let current = self.writer
            self.writer = nil
            return current
        }
        w?.cancel()
    }

    // MARK: - Helpers

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: mediaType) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }

    private static func dimensions(of device: AVCaptureDevice) -> (width: Int, height: Int)? {
        let desc = device.activeFormat.formatDescription
        let d = CMVideoFormatDescriptionGetDimensions(desc)
        guard d.width > 0, d.height > 0 else { return nil }
        return (Int(d.width), Int(d.height))
    }
}

// MARK: - Sample buffer delegates

extension IPhoneUSBCaptureAdapter: AVCaptureVideoDataOutputSampleBufferDelegate,
                                   AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let writer else { return }
        if output === videoOutput {
            writer.appendVideo(sampleBuffer)
        } else if output === audioOutput {
            writer.appendAudio(sampleBuffer)
        }
    }
}
