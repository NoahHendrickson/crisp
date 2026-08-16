import Foundation
import CoreImage
import CoreGraphics

/// Turns a decoded master frame + timestamp into the final composed frame:
/// zoom camera transform, re-drawn vector cursor, click ripples.
/// Shared by the offline exporter and the live editor preview, so the preview
/// is pixel-identical to what exports.
final class FrameComposer {
    let width: Double
    let height: Double
    private let keys: [ZoomPlanner.Keyframe]
    private let samples: [CursorSample]
    private let clicks: [MouseEvent]
    private let cursor: CursorSprite
    private let rippleScale: Double

    init(meta: RecordingMeta, keys: [ZoomPlanner.Keyframe]) {
        self.width = Double(meta.pixelWidth)
        self.height = Double(meta.pixelHeight)
        self.keys = keys
        self.samples = meta.samples
        self.clicks = meta.events.filter { $0.kind == .leftDown }
        self.cursor = CursorSprite(scaleFactor: meta.scaleFactor)
        self.rippleScale = meta.scaleFactor
    }

    func compose(source: CIImage, at t: Double) -> CIImage {
        let camera = ZoomPlanner.evaluate(keys, at: t)
        let zoom = camera.zoom
        // Convert center to Core Image's bottom-left origin and build the
        // transform that lands camera.center at the output center.
        let tx = width / 2 - zoom * camera.center.x
        let ty = height / 2 - zoom * (height - camera.center.y)
        var composed = source.transformed(by: CGAffineTransform(
            a: zoom, b: 0, c: 0, d: zoom, tx: tx, ty: ty
        ))

        if let p = Self.cursorPosition(samples: samples, at: t) {
            let outX = zoom * p.x + tx
            let outY = zoom * (height - p.y) + ty
            composed = cursor.composite(over: composed, x: outX, y: outY, zoom: zoom)
        }

        for click in clicks {
            let age = t - click.t
            guard age >= 0, age < RippleSprite.duration else { continue }
            let outX = zoom * click.x + tx
            let outY = zoom * (height - click.y) + ty
            if let ripple = RippleSprite.image(age: age, scale: rippleScale * zoom) {
                composed = ripple
                    .transformed(by: CGAffineTransform(
                        translationX: outX - ripple.extent.width / 2,
                        y: outY - ripple.extent.height / 2
                    ))
                    .composited(over: composed)
            }
        }

        return composed.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Interpolated cursor position (master pixels, top-left origin) at time t.
    static func cursorPosition(samples: [CursorSample], at t: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return (first.x, first.y) }
        guard let last = samples.last, t < last.t else {
            return samples.last.map { ($0.x, $0.y) }
        }
        var lo = 0
        var hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo]
        let b = samples[hi]
        let span = b.t - a.t
        let u = span > 0 ? (t - a.t) / span : 1
        return (a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
    }
}

/// The re-rendered cursor: drawn as a vector arrow at composite time, not baked
/// into the recording, so it stays sharp at any zoom level.
private final class CursorSprite {
    private let image: CIImage?
    /// Tip position in cursor points, measured from the top-left of the sprite.
    private let hotSpot = CGPoint(x: 1, y: 1)
    private let pointSize = CGSize(width: 14.5, height: 21)
    private let scaleFactor: Double
    /// Rasterization factor: drawn once at 8x, downscaled per frame.
    private static let raster = 8.0

    init(scaleFactor: Double) {
        self.scaleFactor = scaleFactor
        self.image = Self.drawArrow()
    }

    /// Classic macOS arrow: black fill, white outline, tip at (hotSpot).
    private static func drawArrow() -> CIImage? {
        let width = Int(14.5 * raster)
        let height = Int(21 * raster)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip so the path below can use top-left-origin cursor coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: raster, y: -raster)
        ctx.translateBy(x: 1, y: 1)

        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 16.9))
        path.addLine(to: CGPoint(x: 4.0, y: 13.0))
        path.addLine(to: CGPoint(x: 6.6, y: 18.8))
        path.addLine(to: CGPoint(x: 9.0, y: 17.7))
        path.addLine(to: CGPoint(x: 6.4, y: 12.0))
        path.addLine(to: CGPoint(x: 12.0, y: 12.0))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(1.7)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Composite the cursor with its hot spot at (x, y) in output space (bottom-left origin).
    func composite(over background: CIImage, x: Double, y: Double, zoom: Double) -> CIImage {
        guard let image else { return background }
        // Content-locked: the cursor scales with the zoom like everything else.
        let s = scaleFactor * zoom
        let drawWidth = pointSize.width * s
        let drawHeight = pointSize.height * s
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: drawWidth / image.extent.width,
            y: drawHeight / image.extent.height
        ))
        let originX = x - hotSpot.x * s
        let originY = y - (drawHeight - hotSpot.y * s)
        return scaled
            .transformed(by: CGAffineTransform(translationX: originX, y: originY))
            .composited(over: background)
    }
}

/// Expanding ring shown briefly at each click point.
private enum RippleSprite {
    static let duration = 0.45

    static func image(age: Double, scale: Double) -> CIImage? {
        let u = age / duration
        let radius = (8 + 22 * u) * scale
        let lineWidth = 2.2 * scale
        let alpha = (1 - u) * 0.65
        let size = Int(ceil((radius + lineWidth) * 2))
        guard size > 0, alpha > 0.01 else { return nil }

        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        ctx.setLineWidth(lineWidth)
        let inset = lineWidth / 2 + 0.5
        ctx.strokeEllipse(in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)).insetBy(dx: inset, dy: inset))

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
