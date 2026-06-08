import Foundation
import AVFoundation
import CoreImage
import QuartzCore

/// Writes an MP4 with the cursor overlay composited into each video frame, live, as
/// sample buffers arrive (the iPhone "direct" path from PLAN.md). Audio sample buffers
/// are passed through. Lazily configures the writer from the first video frame.
final class FrameCompositorWriter {

    private let outputURL: URL
    private let renderer: CursorRenderer
    private let liveCursor: LiveCursor
    private let telemetry: CursorTelemetryRecorder
    private let includeAudio: Bool
    private let quality: RecordingQuality
    private let ciContext: CIContext

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var started = false
    private var failed = false
    private var videoSize = CGSize.zero       // source pixel size
    private var outputSize = CGSize.zero      // scaled output size (per quality)
    private let queue = DispatchQueue(label: "FrameCompositorWriter")

    init(outputURL: URL, renderer: CursorRenderer, liveCursor: LiveCursor,
         telemetry: CursorTelemetryRecorder, includeAudio: Bool, quality: RecordingQuality) {
        self.outputURL = outputURL
        self.renderer = renderer
        self.liveCursor = liveCursor
        self.telemetry = telemetry
        self.includeAudio = includeAudio
        self.quality = quality
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }

    var hasAudioInput: Bool { audioInput != nil }

    // MARK: - Video

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            guard !failed else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if writer == nil {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                videoSize = CGSize(width: width, height: height)
                configure(size: videoSize)
            }
            guard let writer, let videoInput, let adaptor else { return }

            if !started {
                writer.startSession(atSourceTime: pts)
                started = true
            }
            guard videoInput.isReadyForMoreMediaData else { return }
            guard let pool = adaptor.pixelBufferPool else { return }

            var outPB: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
            guard let outputPixelBuffer = outPB else { return }

            let cursor = liveCursor.current
            telemetry.record(
                normalizedPoint: cursor.point,
                visible: cursor.visible,
                interaction: .move,
                absoluteTime: CACurrentMediaTime()
            )

            let base = CIImage(cvPixelBuffer: pixelBuffer)
            var composited = renderer.composite(
                base: base,
                normalizedPoint: cursor.point,
                visible: cursor.visible,
                baseSize: videoSize
            )
            // Scale to the chosen output resolution if it differs from the source.
            if outputSize != videoSize, videoSize.width > 0, videoSize.height > 0 {
                let sx = outputSize.width / videoSize.width
                let sy = outputSize.height / videoSize.height
                composited = composited.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            ciContext.render(composited, to: outputPixelBuffer)
            adaptor.append(outputPixelBuffer, withPresentationTime: pts)
        }
    }

    // MARK: - Audio

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            guard !failed, started, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - Lifecycle

    private func configure(size: CGSize) {
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            // Resolve the output size + bitrate from the selected quality preset.
            let out = quality.outputSize(forWidth: Int(size.width), height: Int(size.height))
            outputSize = CGSize(width: out.width, height: out.height)
            let bitrate = quality.bitrate(forWidth: out.width, height: out.height)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: out.width,
                AVVideoHeightKey: out.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                ],
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: out.width,
                    kCVPixelBufferHeightKey as String: out.height,
                ]
            )
            if writer.canAdd(videoInput) { writer.add(videoInput) }

            // Audio input (AAC), only when the source is expected to provide audio. Adding
            // an audio track that never receives samples can produce an empty/odd track.
            var audioInput: AVAssetWriterInput?
            if includeAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 128000,
                ]
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aIn.expectsMediaDataInRealTime = true
                if writer.canAdd(aIn) { writer.add(aIn); audioInput = aIn }
            }

            guard writer.startWriting() else {
                failed = true
                NSLog("FrameCompositorWriter: startWriting failed: \(String(describing: writer.error))")
                return
            }

            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
        } catch {
            failed = true
            NSLog("FrameCompositorWriter: configure failed: \(error)")
        }
    }

    func finish() async throws -> URL {
        if failed { throw CaptureError.writerFailed("Writer failed during recording.") }
        guard let writer else { throw CaptureError.writerFailed("No frames were recorded.") }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "Unknown writer error.")
        }
        return outputURL
    }

    func cancel() {
        queue.sync {
            failed = true
            writer?.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
