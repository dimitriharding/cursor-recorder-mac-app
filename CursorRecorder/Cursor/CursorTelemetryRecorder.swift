import Foundation
import CoreGraphics

/// Thread-safe store of cursor telemetry captured during a recording. Samples are stored
/// in normalized phone-video coordinates with timestamps relative to recording start.
final class CursorTelemetryRecorder {

    private let lock = NSLock()
    private var samples: [CursorTelemetrySample] = []
    private var startTime: TimeInterval?

    /// Begin a new telemetry track. `now` is the absolute reference for t=0.
    func begin(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        startTime = now
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        startTime = nil
    }

    /// Record a sample. `absoluteTime` is e.g. `CACurrentMediaTime()`.
    func record(normalizedPoint: CGPoint, visible: Bool, interaction: CursorInteraction, absoluteTime: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let start = startTime else { return }
        let t = max(0, absoluteTime - start)
        samples.append(CursorTelemetrySample(
            time: t,
            normalizedPoint: clamp(normalizedPoint),
            visible: visible,
            interaction: interaction
        ))
    }

    var allSamples: [CursorTelemetrySample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Returns the interpolated cursor state at `time` (seconds since start). Used by the
    /// exporter to look up where the cursor was for each video frame.
    func state(at time: TimeInterval) -> (point: CGPoint, visible: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return (CGPoint(x: 0.5, y: 0.5), false) }

        if time <= samples.first!.time {
            let s = samples.first!
            return (s.normalizedPoint, s.visible)
        }
        if time >= samples.last!.time {
            let s = samples.last!
            return (s.normalizedPoint, s.visible)
        }

        // Binary search for the surrounding samples.
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let span = b.time - a.time
        let frac = span > 0 ? CGFloat((time - a.time) / span) : 0
        let point = CGPoint(
            x: a.normalizedPoint.x + (b.normalizedPoint.x - a.normalizedPoint.x) * frac,
            y: a.normalizedPoint.y + (b.normalizedPoint.y - a.normalizedPoint.y) * frac
        )
        // Visibility is not interpolated; use the earlier sample's value.
        return (point, a.visible)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
    }
}
