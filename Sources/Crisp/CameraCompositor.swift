import Foundation
import AVFoundation
import CoreImage

/// Carries the frame composer into the compositor (AVFoundation instantiates
/// the compositor class itself, so state travels via the instruction).
final class CameraInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]? = nil
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let composer: any FrameComposing
    /// Preview renders at reduced size for smooth scrubbing (export uses the
    /// offline 10-bit Renderer instead, at full resolution).
    let renderScale: Double

    init(timeRange: CMTimeRange, composer: any FrameComposing, renderScale: Double) {
        self.timeRange = timeRange
        self.composer = composer
        self.renderScale = renderScale
    }
}

/// Applies the zoom camera + cursor + ripples live during AVPlayer playback,
/// using the exact same FrameComposer as the exporter — the editor preview is
/// faithful to the final render.
final class CameraCompositor: NSObject, AVVideoCompositing {

    private static let context = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    ])

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            Int(kCVPixelFormatType_ARGB2101010LEPacked),
            Int(kCVPixelFormatType_32BGRA),
        ]
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? CameraInstruction,
                  let trackID = request.sourceTrackIDs.first,
                  let frame = request.sourceFrame(byTrackID: trackID.int32Value) else {
                request.finish(with: CompositorError.missingSource)
                return
            }

            let t = request.compositionTime.seconds
            var image = instruction.composer.compose(source: CIImage(cvPixelBuffer: frame), at: t)
            if instruction.renderScale != 1 {
                image = image.transformed(by: CGAffineTransform(
                    scaleX: instruction.renderScale, y: instruction.renderScale
                ))
            }

            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.noBuffer)
                return
            }
            let size = request.renderContext.size
            Self.context.render(
                image, to: output,
                bounds: CGRect(origin: .zero, size: size),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
            request.finish(withComposedVideoFrame: output)
        }
    }

    /// Build a preview composition for the master asset.
    static func makeComposition(
        duration: CMTime, composer: any FrameComposing, renderScale: Double = 0.5
    ) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = CameraCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        composition.renderSize = CGSize(
            width: (composer.width * renderScale).rounded(),
            height: (composer.height * renderScale).rounded()
        )
        composition.instructions = [CameraInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            composer: composer,
            renderScale: renderScale
        )]
        return composition
    }

    enum CompositorError: Error {
        case missingSource, noBuffer
    }
}
