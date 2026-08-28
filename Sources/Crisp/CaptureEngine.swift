import Foundation
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import CoreMedia

/// Captures one display with ScreenCaptureKit and writes a high-quality master file
/// via AVAssetWriter. Cursor is NOT captured — it is re-rendered at export time.
/// What to capture: a whole display, a single window, or a region of a display.
/// Region rects are in points, top-left origin, local to the display.
enum CaptureSource {
    case display(SCDisplay)
    case window(SCWindow)
    case region(SCDisplay, CGRect)

    var kindName: String {
        switch self {
        case .display: return "display"
        case .window: return "window"
        case .region: return "region"
        }
    }

    var displayID: CGDirectDisplayID {
        switch self {
        case .display(let d), .region(let d, _): return d.displayID
        case .window: return 0
        }
    }
}

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    struct Options {
        var source: CaptureSource
        var codec: MasterCodec
        var fps: Double = 60
    }

    private let queue = DispatchQueue(label: "crisp.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastPTS: CMTime = .invalid

    /// Host-clock seconds of the first written frame; set once the session starts.
    private(set) var sessionStartHostSeconds: Double?
    /// Called on an arbitrary queue when the first frame lands (used to sync the mouse tracker).
    var onSessionStart: ((Double) -> Void)?
    /// Called if the stream dies unexpectedly.
    var onStreamError: ((Error) -> Void)?

    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var scaleFactor = 1.0
    /// Quartz-global origin (points, top-left origin space) of the captured area,
    /// used by the mouse tracker to map clicks into video pixels.
    private(set) var captureOriginQuartz: CGPoint = .zero
    private(set) var capturePointSize: CGSize = .zero

    // MARK: - Start / stop

    func start(options: Options, masterURL: URL) async throws {
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        let sizePoints: CGSize

        switch options.source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            sizePoints = filter.contentRect.size
            captureOriginQuartz = CGDisplayBounds(display.displayID).origin
        case .region(let display, let rect):
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.sourceRect = rect
            sizePoints = rect.size
            let displayOrigin = CGDisplayBounds(display.displayID).origin
            captureOriginQuartz = CGPoint(x: displayOrigin.x + rect.minX, y: displayOrigin.y + rect.minY)
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            sizePoints = window.frame.size
            // SCWindow.frame is already Quartz-global (top-left origin).
            captureOriginQuartz = window.frame.origin
        }

        // Capture at physical pixel resolution, rounded down to even numbers
        // (odd dimensions upset 4:2:0 video encoders).
        let scale = Double(filter.pointPixelScale)
        let width = max(2, Int(sizePoints.width * scale) / 2 * 2)
        let height = max(2, Int(sizePoints.height * scale) / 2 * 2)
        pixelWidth = width
        pixelHeight = height
        scaleFactor = scale
        capturePointSize = sizePoints

        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 8
        config.showsCursor = false
        // 10-bit capture so slow gradients don't band in the master.
        config.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = false

        let writer = try AVAssetWriter(outputURL: masterURL, fileType: .mov)
        let settings = Self.videoSettings(
            codec: options.codec, width: width, height: height, fps: options.fps
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.writerFailed
        }

        self.writer = writer
        self.input = input
        self.sessionStarted = false
        self.sessionStartHostSeconds = nil
        self.lastPTS = .invalid

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            // startCapture is where a stale permission grant fails: don't
            // leave the opened writer (and its output file) dangling.
            self.stream = nil
            self.writer = nil
            self.input = nil
            writer.cancelWriting()
            throw error
        }
    }

    func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let writer, let input else {
                    cont.resume()
                    return
                }
                self.writer = nil
                self.input = nil
                input.markAsFinished()
                guard sessionStarted, lastPTS.isValid else {
                    // No complete frame ever arrived: finalizing a writer
                    // whose session never started is undefined, and the file
                    // would only be a dead entry in the library.
                    writer.cancelWriting()
                    cont.resume(throwing: CaptureError.noFramesCaptured)
                    return
                }
                writer.endSession(atSourceTime: lastPTS)
                writer.finishWriting {
                    if let error = writer.error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    // MARK: - Encoder settings

    static func videoSettings(codec: MasterCodec, width: Int, height: Int, fps: Double) -> [String: Any] {
        switch codec {
        case .hevc10:
            // ~0.15 bits per pixel per frame, clamped. 4K@60 lands around 75 Mbps —
            // far above screen-recorder defaults, which is what keeps gradients clean.
            let bpp = 0.15
            let bitrate = min(max(Double(width * height) * fps * bpp, 20_000_000), 120_000_000)
            return [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(bitrate),
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                    AVVideoExpectedSourceFrameRateKey: Int(fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        case .proRes422:
            return [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        case .proRes4444:
            return [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let writer, let input else { return }

        // Only write frames marked complete (skip the initial blank/partial ones).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            let startSeconds = pts.seconds
            sessionStartHostSeconds = startSeconds
            onSessionStart?(startSeconds)
        }

        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) {
                lastPTS = pts
            } else {
                // The writer died mid-recording (disk full is the classic
                // case). Surface it now rather than at Stop — otherwise the
                // app keeps showing "Recording…" while writing nothing.
                let error = writer.error ?? CaptureError.writerFailed
                self.writer = nil
                self.input = nil
                onStreamError?(error)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    enum CaptureError: LocalizedError, Equatable {
        case writerFailed
        case noFramesCaptured
        var errorDescription: String? {
            switch self {
            case .writerFailed: return "Could not write the video file."
            case .noFramesCaptured: return "No frames were captured."
            }
        }
    }
}
