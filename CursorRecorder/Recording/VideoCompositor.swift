import Foundation
import AVFoundation
import CoreImage

/// Post-processes a clean source MP4 into a final MP4 with the cursor overlay composited
/// in, using recorded telemetry. This is the Android path from PLAN.md (and the iPhone
/// fallback path). Audio, when present, is re-encoded to AAC.
enum VideoCompositor {

    static func export(
        source: URL,
        output: URL,
        renderer: CursorRenderer,
        telemetry: CursorTelemetryRecorder,
        quality: RecordingQuality = .source,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {

        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CaptureError.sourceInvalid("Source video has no video track.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(0.001, CMTimeGetSeconds(duration))

        // Compute the oriented render size and a base transform that maps source pixels into
        // the positive quadrant of that render space.
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(transformedRect.width.rounded()),
                                height: abs(transformedRect.height.rounded()))
        var baseTransform = transform
        baseTransform.tx -= transformedRect.minX
        baseTransform.ty -= transformedRect.minY

        // Apply the quality preset to derive the final output size + bitrate.
        let out = quality.outputSize(forWidth: Int(renderSize.width), height: Int(renderSize.height))
        let outputSize = CGSize(width: out.width, height: out.height)
        let videoBitrate = quality.bitrate(forWidth: out.width, height: out.height)
        let outputScale = CGAffineTransform(scaleX: outputSize.width / renderSize.width,
                                            y: outputSize.height / renderSize.height)

        // Reader.
        let reader = try AVAssetReader(asset: asset)
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw CaptureError.sourceInvalid("Cannot read source video track.")
        }
        reader.add(videoReaderOutput)

        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            if reader.canAdd(out) { reader.add(out); audioReaderOutput = out }
        }

        // Writer.
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: out.width,
            AVVideoHeightKey: out.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitrate],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: out.width,
                kCVPixelBufferHeightKey as String: out.height,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerFailed("Cannot add video input.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000,
            ])
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) { writer.add(aIn); audioInput = aIn }
        }

        guard reader.startReading() else {
            throw CaptureError.sourceInvalid(reader.error?.localizedDescription ?? "Reader failed to start.")
        }
        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "Writer failed to start.")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Video pass.
        try await pump(input: videoInput, queueLabel: "compositor.video") {
            guard let sample = videoReaderOutput.copyNextSampleBuffer() else { return false }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return true }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let seconds = CMTimeGetSeconds(pts)

            guard let pool = adaptor.pixelBufferPool else { return true }
            var outPB: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
            guard let outputPixelBuffer = outPB else { return true }

            let cursor = telemetry.state(at: seconds)
            let base = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: baseTransform)
            var composited = renderer.composite(
                base: base,
                normalizedPoint: cursor.point,
                visible: cursor.visible,
                baseSize: renderSize
            )
            if outputSize != renderSize { composited = composited.transformed(by: outputScale) }
            ciContext.render(composited, to: outputPixelBuffer)
            adaptor.append(outputPixelBuffer, withPresentationTime: pts)
            progress(min(0.99, seconds / durationSeconds))
            return true
        }

        // Audio pass.
        if let audioInput, let audioReaderOutput {
            try await pump(input: audioInput, queueLabel: "compositor.audio") {
                guard let sample = audioReaderOutput.copyNextSampleBuffer() else { return false }
                audioInput.append(sample)
                return true
            }
        }

        if reader.status == .failed {
            throw CaptureError.sourceInvalid(reader.error?.localizedDescription ?? "Reading failed.")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "Writing failed.")
        }
        progress(1.0)
        return output
    }

    /// Drives an asset writer input, calling `provide` whenever it's ready for more data.
    /// `provide` returns false when the source is exhausted.
    private static func pump(
        input: AVAssetWriterInput,
        queueLabel: String,
        provide: @escaping () -> Bool
    ) async throws {
        let queue = DispatchQueue(label: queueLabel)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if !provide() {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}
