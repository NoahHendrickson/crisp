import Foundation
import AVFoundation
import CoreImage
import VideoToolbox

/// Offline export: reads the master file, applies the animated zoom camera,
/// re-draws the cursor and click ripples, and writes a high-bitrate export in
/// the requested container/codec.
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

    /// Writes a new, never-overwriting export file next to the master and
    /// returns its URL.
    @discardableResult
    func export(
        recording: Recording,
        format: ExportFormat = .default,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
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
        let planner = ZoomPlanner(meta: meta)
        let plan = recording.loadPlan()
        let segments = plan?.segments
            ?? planner.segments(events: meta.events, duration: duration)
        let cursorStyle = plan?.cursorStyle ?? .classic
        let keys = planner.keyframes(from: segments, duration: duration)
        let composer = FrameComposer(meta: meta, keys: keys, cursorStyle: cursorStyle)

        // Reader: decode to 10-bit RGB.
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_ARGB2101010LEPacked,
        ])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // Writer: high bitrate in the chosen container/codec. Each export gets a
        // fresh numbered filename so earlier exports are never overwritten.
        let outputURL = recording.nextExportURL(for: format)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: Self.fileType(for: format))
        // Nothing that fails (or is cancelled) from here on may leave the
        // numbered file behind: the library would list a broken export and
        // later exports would number around it. Success is only declared once
        // the file and its plan snapshot are both on disk.
        var succeeded = false
        defer {
            if !succeeded {
                if reader.status == .reading { reader.cancelReading() }
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(format: format, width: width, height: height, fps: fps)
        )
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
            if isCancelled { throw Cancelled() }

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
        // Remember which zooms produced this file, so the library can compare
        // and restore versions after plan.json changes. The snapshot is part of
        // the export: if it cannot be written the export is not a success and
        // the defer above discards the video rather than leaving an
        // unversioned file behind.
        try Recording.writePlan(segments, cursorStyle: cursorStyle, to: Recording.planSnapshotURL(for: outputURL))
        succeeded = true
        progress(1)
        return outputURL
    }

    // MARK: - Encoder settings

    static func fileType(for format: ExportFormat) -> AVFileType {
        switch format {
        case .movHEVC: return .mov
        case .mp4HEVC, .mp4H264: return .mp4
        }
    }

    static func videoSettings(format: ExportFormat, width: Int, height: Int, fps: Double) -> [String: Any] {
        let bitrate = min(max(Double(width * height) * fps * 0.12, 15_000_000), 100_000_000)
        let codec: AVVideoCodecType
        let profile: String
        switch format {
        case .movHEVC, .mp4HEVC:
            codec = .hevc
            profile = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .mp4H264:
            // 8-bit, for players that can't decode HEVC. VideoToolbox downconverts
            // from the half-float frames we render.
            codec = .h264
            profile = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoProfileLevelKey: profile,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            ],
        ]
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
