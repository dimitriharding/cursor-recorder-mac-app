import Foundation
import CoreGraphics

/// The platform of a connected phone.
enum PhonePlatform: String, Codable, Sendable {
    case iphone
    case android
}

/// How a phone is connected. V1 only supports USB.
enum PhoneConnection: String, Codable, Sendable {
    case usb
}

/// Readiness of a discovered capture device. Drives the setup UI.
enum DeviceReadiness: Equatable, Sendable {
    case ready
    case waitingForTrust
    case missingAndroidTools
    case missingUSBDebugging
    case unsupported
    case disconnected
}

/// Which capture implementation a device is served by.
enum CaptureBackend: Sendable {
    case iphoneUSB      // AVFoundation muxed USB screen source
    case mirroring      // ScreenCaptureKit capture of the iPhone Mirroring window
    case android        // scrcpy + adb
}

/// A phone the app can capture from.
struct PhoneCaptureDevice: Identifiable, Equatable, Sendable {
    let id: String
    let platform: PhonePlatform
    let name: String
    let connection: PhoneConnection
    let width: Int?
    let height: Int?
    let supportsAudio: Bool
    let readiness: DeviceReadiness
    var backend: CaptureBackend = .iphoneUSB

    var isReady: Bool { readiness == .ready }

    /// Aspect ratio (w/h) of the source, defaulting to a phone-ish portrait ratio
    /// when dimensions are unknown.
    var aspectRatio: CGFloat {
        if let w = width, let h = height, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 9.0 / 19.5
    }
}

/// Configuration for the Mac-controlled cursor overlay.
struct CursorOverlayConfig: Equatable, Sendable {
    /// Source PNG (transparent) used for the cursor. `nil` falls back to a drawn pointer.
    var imageURL: URL?
    /// Normalized hotspot inside the cursor image (0,0 = top-left .. 1,1 = bottom-right).
    var hotspot: CGPoint
    /// Cursor scale relative to a base size (1.0 == base size).
    var scale: CGFloat
    /// Opacity 0...1.
    var opacity: CGFloat
    /// Whether to draw a soft drop shadow under the cursor.
    var shadowEnabled: Bool
    /// Pointer smoothing 0 (none) ... 1 (very smooth) applied to live + export motion.
    var smoothing: CGFloat

    static let `default` = CursorOverlayConfig(
        imageURL: nil,
        hotspot: CGPoint(x: 0.15, y: 0.08),
        scale: 1.0,
        opacity: 1.0,
        shadowEnabled: true,
        smoothing: 0.35
    )
}

/// A single recorded pointer sample, in normalized phone-video coordinates.
struct CursorTelemetrySample: Equatable, Sendable {
    /// Seconds since recording start.
    let time: TimeInterval
    /// Normalized point (0,0 = top-left .. 1,1 = bottom-right of the phone video).
    let normalizedPoint: CGPoint
    /// Whether the cursor is visible (pointer inside the preview bounds).
    let visible: Bool
    let interaction: CursorInteraction
}

enum CursorInteraction: String, Sendable {
    case move
    case click
    case mouseUp
}

/// Fractional crop applied to a window-captured source (0...1 per edge), used to trim window
/// chrome / device bezels so the output is "just the screen".
struct CropInsets: Equatable, Sendable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    static let zero = CropInsets()
    var isZero: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }

    /// Remaining fractions after cropping, floored so the region never collapses.
    var widthFraction: CGFloat { max(0.05, 1 - left - right) }
    var heightFraction: CGFloat { max(0.05, 1 - top - bottom) }
}

/// Output resolution / quality presets. Each caps the shorter edge (width for portrait
/// phone video) and sets a target H.264 bitrate. Presets never upscale beyond the source.
enum RecordingQuality: String, CaseIterable, Identifiable, Sendable {
    case source
    case p720
    case p1080
    case p1440
    case p2160

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .p720: return "720p"
        case .p1080: return "1080p (web)"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    /// Short, filename-safe tag (e.g. appended when re-exporting at another quality).
    var fileTag: String {
        switch self {
        case .source: return "source"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    /// Cap on the shorter edge in pixels; `nil` means use the native capture size.
    var shortEdgeCap: Int? {
        switch self {
        case .source: return nil
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }

    /// Target average bitrate (bits/sec) for the given output pixel size.
    func bitrate(forWidth w: Int, height h: Int) -> Int {
        switch self {
        case .p720: return 5_000_000
        case .p1080: return 10_000_000
        case .p1440: return 18_000_000
        case .p2160: return 40_000_000
        case .source:
            // Scale ~10 Mbps/1080p by pixel area, clamped to a sensible range.
            let ref = 1920.0 * 1080.0
            let area = Double(max(1, w * h))
            return min(60_000_000, max(6_000_000, Int(area / ref * 10_000_000)))
        }
    }

    /// Computes the even, aspect-preserving output size for a given source size.
    func outputSize(forWidth w: Int, height h: Int) -> (width: Int, height: Int) {
        guard let cap = shortEdgeCap else { return (evenize(w), evenize(h)) }
        let shortEdge = min(w, h)
        guard shortEdge > cap else { return (evenize(w), evenize(h)) }   // never upscale
        let scale = Double(cap) / Double(shortEdge)
        return (evenize(Int((Double(w) * scale).rounded())),
                evenize(Int((Double(h) * scale).rounded())))
    }

    private func evenize(_ v: Int) -> Int { max(2, v - (v % 2)) }
}

/// An active recording.
struct RecordingSession: Identifiable, Sendable {
    let id: UUID
    let device: PhoneCaptureDevice
    let startedAt: Date
    let outputURL: URL
    var quality: RecordingQuality = .p1080
    let cursor: CursorOverlayConfig
}

/// High-level state surfaced to the UI. Mirrors the "User-Facing States" in PLAN.md.
enum RecorderState: Equatable {
    case idle                       // No phone connected.
    case ready                      // Phone connected and ready.
    case waitingForTrust            // iPhone connected but not trusted.
    case unsupported                // iPhone source unsupported on this Mac/macOS/device.
    case androidToolsMissing        // adb/scrcpy not installed.
    case androidUnauthorized        // Android device unauthorized.
    case androidDebuggingMissing    // USB debugging disabled.
    case recording                  // Actively recording.
    case stopping                   // Finishing capture.
    case postProcessing(Double)     // Compositing cursor into final MP4 (0...1 progress).
    case saved(URL)                 // Recording saved to URL.
    case failed(String)             // Recording failed with message.

    var isBusy: Bool {
        switch self {
        case .recording, .stopping, .postProcessing: return true
        default: return false
        }
    }
}
