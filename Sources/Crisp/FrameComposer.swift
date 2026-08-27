import Foundation
import CoreImage
import CoreGraphics

/// Turns a decoded master frame + timestamp into the final composed frame:
/// zoom camera transform, re-drawn vector cursor, click ripples.
/// Shared by the offline exporter and the live editor preview, so the preview
/// is pixel-identical to what exports.
final class FrameComposer: FrameComposing {
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
            composed = cursor.composite(over: composed, x: outX, y: outY, zoom: zoom, kind: p.kind)
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
    /// Kind is held from the sample at or before t, not interpolated.
    static func cursorPosition(samples: [CursorSample], at t: Double) -> (x: Double, y: Double, kind: CursorKind)? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return (first.x, first.y, first.kind ?? .arrow) }
        guard let last = samples.last, t < last.t else {
            return samples.last.map { ($0.x, $0.y, $0.kind ?? .arrow) }
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
        return (a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.kind ?? .arrow)
    }
}

/// The re-rendered cursor: drawn as a vector sprite at composite time, not baked
/// into the recording, so it stays sharp at any zoom level. One raster per kind.
private final class CursorSprite {
    private struct Sprite {
        var image: CIImage
        var hotSpot: CGPoint
        var pointSize: CGSize
    }

    private let sprites: [CursorKind: Sprite]
    private let scaleFactor: Double
    /// Rasterization factor: drawn once at 8x, downscaled per frame.
    private static let raster = 8.0

    init(scaleFactor: Double) {
        self.scaleFactor = scaleFactor
        var built: [CursorKind: Sprite] = [:]
        if let image = Self.drawArrow() {
            built[.arrow] = Sprite(
                image: image, hotSpot: CGPoint(x: 1, y: 1),
                pointSize: CGSize(width: 14.5, height: 21)
            )
        }
        if let image = Self.drawPointer() {
            // 32×32 so NSCursor.pointingHand.hotSpot (13, 8) applies directly.
            built[.pointer] = Sprite(
                image: image, hotSpot: CGPoint(x: 13, y: 8),
                pointSize: CGSize(width: 32, height: 32)
            )
        }
        if let image = Self.drawIBeam() {
            built[.iBeam] = Sprite(
                image: image, hotSpot: CGPoint(x: 12, y: 11),
                pointSize: CGSize(width: 23, height: 22)
            )
        }
        self.sprites = built
    }

    /// Classic macOS arrow: black fill, white outline, tip at (hotSpot).
    private static func drawArrow() -> CIImage? {
        rasterize(width: 14.5, height: 21) { ctx in
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
            strokeAndFill(path, in: ctx)
        }
    }

    /// Pointing hand in a 32×32 box; index fingertip at (13, 8).
    private static func drawPointer() -> CIImage? {
        rasterize(width: 32, height: 32) { ctx in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 13.0, y: 8.0))
            path.addLine(to: CGPoint(x: 10.7, y: 8.7))
            path.addLine(to: CGPoint(x: 10.7, y: 19.2))
            path.addLine(to: CGPoint(x: 6.0, y: 17.4))
            path.addLine(to: CGPoint(x: 4.6, y: 19.0))
            path.addLine(to: CGPoint(x: 4.6, y: 23.2))
            path.addLine(to: CGPoint(x: 7.4, y: 26.6))
            path.addLine(to: CGPoint(x: 10.4, y: 28.8))
            path.addLine(to: CGPoint(x: 20.6, y: 28.8))
            path.addLine(to: CGPoint(x: 23.6, y: 25.6))
            path.addLine(to: CGPoint(x: 23.6, y: 21.0))
            path.addLine(to: CGPoint(x: 21.5, y: 19.0))
            path.addLine(to: CGPoint(x: 21.5, y: 16.5))
            path.addLine(to: CGPoint(x: 19.5, y: 15.0))
            path.addLine(to: CGPoint(x: 19.5, y: 13.0))
            path.addLine(to: CGPoint(x: 15.6, y: 12.5))
            path.addLine(to: CGPoint(x: 15.6, y: 8.7))
            path.closeSubpath()
            strokeAndFill(path, in: ctx)
        }
    }

    /// I-beam in a 23×22 box; hotspot (12, 11) at the centre.
    private static func drawIBeam() -> CIImage? {
        rasterize(width: 23, height: 22) { ctx in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 6, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 5.4))
            path.addLine(to: CGPoint(x: 13.3, y: 5.4))
            path.addLine(to: CGPoint(x: 13.3, y: 16.6))
            path.addLine(to: CGPoint(x: 18, y: 16.6))
            path.addLine(to: CGPoint(x: 18, y: 19))
            path.addLine(to: CGPoint(x: 6, y: 19))
            path.addLine(to: CGPoint(x: 6, y: 16.6))
            path.addLine(to: CGPoint(x: 10.7, y: 16.6))
            path.addLine(to: CGPoint(x: 10.7, y: 5.4))
            path.addLine(to: CGPoint(x: 6, y: 5.4))
            path.closeSubpath()
            strokeAndFill(path, in: ctx)
        }
    }

    private static func rasterize(width: Double, height: Double, draw: (CGContext) -> Void) -> CIImage? {
        let pixelW = Int(width * raster)
        let pixelH = Int(height * raster)
        guard let ctx = CGContext(
            data: nil, width: pixelW, height: pixelH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: raster, y: -raster)
        draw(ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    private static func strokeAndFill(_ path: CGPath, in ctx: CGContext) {
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(1.7)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
    }

    /// Composite the cursor with its hot spot at (x, y) in output space (bottom-left origin).
    func composite(over background: CIImage, x: Double, y: Double, zoom: Double, kind: CursorKind) -> CIImage {
        guard let sprite = sprites[kind] ?? sprites[.arrow] else { return background }
        // Content-locked: the cursor scales with the zoom like everything else.
        let s = scaleFactor * zoom
        let drawWidth = sprite.pointSize.width * s
        let drawHeight = sprite.pointSize.height * s
        let scaled = sprite.image.transformed(by: CGAffineTransform(
            scaleX: drawWidth / sprite.image.extent.width,
            y: drawHeight / sprite.image.extent.height
        ))
        let originX = x - sprite.hotSpot.x * s
        let originY = y - (drawHeight - sprite.hotSpot.y * s)
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
