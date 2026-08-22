import Foundation
import AppKit
import AVFoundation
import CoreImage
import VideoToolbox

/// Offline export: reads the master file, applies the animated zoom camera,
/// re-draws the cursor and click ripples, and writes a high-bitrate HEVC export.
///
/// Renders on a fixed 60fps output clock (the master has variable frame timing
/// because ScreenCaptureKit only emits frames on screen changes — the camera
/// must keep animating even when the source is static).
final class Renderer {

    struct Cancelled: Error {}

    var isCancelled = false

    private let ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
        ])
    }()

    func export(recording: Recording, progress: @escaping (Double) -> Void) async throws {
        let meta = try recording.loadMeta()
        let asset = AVURLAsset(url: recording.masterURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let width = meta.pixelWidth
        let height = meta.pixelHeight
        let fps = 60.0

        // Use the hand-edited plan when one exists; otherwise auto-generate.
        let planner = ZoomPlanner(width: Double(width), height: Double(height))
        let segments = recording.loadPlanSegments()
            ?? planner.segments(events: meta.events, duration: duration)
        let keys = planner.keyframes(from: segments, duration: duration)
        let composer = FrameComposer(meta: meta, keys: keys)

        // Reader: decode to 10-bit RGB.
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_ARGB2101010LEPacked,
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // Writer: 10-bit HEVC, high bitrate.
        try? FileManager.default.removeItem(at: recording.exportURL)
        let writer = try AVAssetWriter(outputURL: recording.exportURL, fileType: .mov)
        let bitrate = min(max(Double(width * height) * fps * 0.12, 15_000_000), 100_000_000)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? RenderError.readerFailed }
        guard writer.startWriting() else { throw writer.error ?? RenderError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let outputRect = CGRect(x: 0, y: 0, width: width, height: height)
        let frameCount = max(1, Int(duration * fps))

        var currentFrame: CIImage?
        var pendingSample: CMSampleBuffer? = readerOutput.copyNextSampleBuffer()

        for frameIndex in 0..<frameCount {
            if isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw Cancelled()
            }

            let t = Double(frameIndex) / fps

            // Pull source frames up to the current output time.
            while let sample = pendingSample,
                  CMSampleBufferGetPresentationTimeStamp(sample).seconds <= t {
                if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                    currentFrame = CIImage(cvPixelBuffer: imageBuffer)
                }
                pendingSample = readerOutput.copyNextSampleBuffer()
            }
            guard let source = currentFrame else {
                // No frame decoded yet; skip until the first one arrives.
                continue
            }

            let composed = composer.compose(source: source, at: t)

            // Wait for the writer to drain (offline export, simple polling is fine).
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 4_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else { throw RenderError.writerFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw RenderError.writerFailed }

            ciContext.render(composed, to: pixelBuffer, bounds: outputRect, colorSpace: srgb)
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw writer.error ?? RenderError.writerFailed
            }

            if frameIndex % 30 == 0 {
                progress(Double(frameIndex) / Double(frameCount))
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        progress(1)
    }

    enum RenderError: LocalizedError {
        case noVideoTrack, readerFailed, writerFailed
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The master file has no video track."
            case .readerFailed: return "Could not read the master file."
            case .writerFailed: return "Could not write the export file."
            }
        }
    }
}
