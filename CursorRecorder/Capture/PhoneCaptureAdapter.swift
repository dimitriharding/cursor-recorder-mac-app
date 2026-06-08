import Foundation
import QuartzCore

/// Errors surfaced by capture adapters.
enum CaptureError: LocalizedError {
    case deviceNotReady(String)
    case noVideoSource
    case permissionDenied(String)
    case toolMissing(String)
    case processFailed(String)
    case writerFailed(String)
    case sourceInvalid(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .deviceNotReady(let m): return m
        case .noVideoSource: return "No usable phone video source was found."
        case .permissionDenied(let m): return m
        case .toolMissing(let m): return m
        case .processFailed(let m): return m
        case .writerFailed(let m): return m
        case .sourceInvalid(let m): return m
        case .cancelled: return "Recording was cancelled."
        }
    }
}

/// Common boundary for iPhone and Android capture implementations.
protocol PhoneCaptureAdapter: AnyObject {
    var platform: PhonePlatform { get }

    /// Discover connected phones and report readiness.
    func scanDevices() async throws -> [PhoneCaptureDevice]

    /// Start a live preview for `device`. For iPhone this brings up an AVCaptureSession;
    /// for Android it prepares the source dimensions for the placeholder canvas.
    func startPreview(device: PhoneCaptureDevice) async throws
    func stopPreview() async

    /// A live preview layer, when the adapter renders one directly (iPhone).
    var previewLayer: CALayer? { get }

    func startRecording(session: RecordingSession) async throws

    /// Finish recording and return the URL of the final MP4.
    func stopRecording() async throws -> URL

    /// Abort recording and clean up any temporary files / final output.
    func cancelRecording() async
}

/// Thread-safe holder for the current cursor position, shared between the preview's mouse
/// tracking (writer) and the iPhone capture delegate (reader, per video frame).
final class LiveCursor {
    private let lock = NSLock()
    private var _point = CGPoint(x: 0.5, y: 0.5)
    private var _visible = false

    var current: (point: CGPoint, visible: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_point, _visible)
    }

    func update(point: CGPoint, visible: Bool) {
        lock.lock(); defer { lock.unlock() }
        _point = point
        _visible = visible
    }
}
