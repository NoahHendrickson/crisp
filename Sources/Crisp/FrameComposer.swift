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

    init(meta: RecordingMeta, keys: [ZoomPlanner.Keyframe], cursorStyle: CursorStyle) {
        self.width = Double(meta.pixelWidth)
        self.height = Double(meta.pixelHeight)
        self.keys = keys
        self.samples = meta.samples
        self.clicks = meta.events.filter { $0.kind == .leftDown }
        self.cursor = CursorSprite(style: cursorStyle, scaleFactor: meta.scaleFactor)
        self.rippleScale = meta.scaleFactor
    }

    /// Which cursor kinds `style` has a sprite for (self-test).
    static func cursorKinds(drawnBy style: CursorStyle) -> Set<CursorKind> {
        CursorSprite(style: style, scaleFactor: 1).kinds
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
        let last = samples[samples.count - 1]
        if t >= last.t { return (last.x, last.y, last.kind ?? .arrow) }
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
/// into the recording, so it stays sharp at any zoom level. One raster per kind,
/// in the recording's chosen style.
private final class CursorSprite {
    private struct Sprite {
        var image: CIImage
        /// Hot spot in the sprite's point box, top-left origin.
        var hotSpot: CGPoint
        var pointSize: CGSize
    }

    private let sprites: [CursorKind: Sprite]
    private let scaleFactor: Double
    /// Points-to-points size multiplier of the style (the bubbly set is drawn bigger).
    private let styleScale: Double
    /// Rasterization factor: drawn once at 8x, downscaled per frame.
    private static let raster = 8.0

    var kinds: Set<CursorKind> { Set(sprites.keys) }

    init(style: CursorStyle, scaleFactor: Double) {
        self.scaleFactor = scaleFactor
        switch style {
        case .classic:
            styleScale = 1
            sprites = Self.classicSprites()
        case .bubbly:
            styleScale = 1.35
            sprites = Self.bubblySprites()
        }
    }

    // MARK: - Classic: flat black fill, white outline

    private static func classicSprites() -> [CursorKind: Sprite] {
        var built: [CursorKind: Sprite] = [:]
        // Classic macOS arrow, tip at the hot spot.
        if let image = rasterize(width: 14.5, height: 21, draw: { ctx in
            ctx.translateBy(x: 1, y: 1)
            strokeAndFill(classicArrowPath(), in: ctx)
        }) {
            built[.arrow] = Sprite(image: image, hotSpot: CGPoint(x: 1, y: 1), pointSize: CGSize(width: 14.5, height: 21))
        }
        // 32×32 so NSCursor.pointingHand.hotSpot (13, 8) applies directly.
        if let image = rasterize(width: 32, height: 32, draw: { ctx in
            strokeAndFill(classicPointerPath(), in: ctx)
        }) {
            built[.pointer] = Sprite(image: image, hotSpot: CGPoint(x: 13, y: 8), pointSize: CGSize(width: 32, height: 32))
        }
        // I-beam in a 23×22 box; hotspot (12, 11) at the centre.
        if let image = rasterize(width: 23, height: 22, draw: { ctx in
            strokeAndFill(classicIBeamPath(), in: ctx)
        }) {
            built[.iBeam] = Sprite(image: image, hotSpot: CGPoint(x: 12, y: 11), pointSize: CGSize(width: 23, height: 22))
        }
        return built
    }

    private static func classicArrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 16.9))
        path.addLine(to: CGPoint(x: 4.0, y: 13.0))
        path.addLine(to: CGPoint(x: 6.6, y: 18.8))
        path.addLine(to: CGPoint(x: 9.0, y: 17.7))
        path.addLine(to: CGPoint(x: 6.4, y: 12.0))
        path.addLine(to: CGPoint(x: 12.0, y: 12.0))
        path.closeSubpath()
        return path
    }

    /// Pointing hand in a 32×32 box; index fingertip at (13, 8).
    private static func classicPointerPath() -> CGPath {
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
        return path
    }

    private static func classicIBeamPath() -> CGPath {
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
        return path
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

    // MARK: - Bubbly: rounded body, gradient, gloss, soft shadow

    /// Each shape sits inside a padded box so its rim and shadow never clip;
    /// hot spots are the shape's own plus the padding.
    private static func bubblySprites() -> [CursorKind: Sprite] {
        var built: [CursorKind: Sprite] = [:]
        let arrowBox = CGSize(width: 20, height: 26)
        if let image = rasterize(width: arrowBox.width, height: arrowBox.height, draw: { ctx in
            bubbly(bubblyArrowPath(), in: ctx, box: arrowBox, pad: CGPoint(x: 2.8, y: 2.8),
                   gloss: CGRect(x: 0, y: 0, width: 14, height: 9))
        }) {
            built[.arrow] = Sprite(image: image, hotSpot: CGPoint(x: 2.8, y: 2.8), pointSize: arrowBox)
        }
        let handBox = CGSize(width: 32, height: 36)
        if let image = rasterize(width: handBox.width, height: handBox.height, draw: { ctx in
            bubbly(bubblyPointerPath(), in: ctx, box: handBox, pad: CGPoint(x: 1.5, y: 1.5),
                   gloss: CGRect(x: 0, y: 3, width: 28, height: 13),
                   creases: [
                       (CGPoint(x: 15.9, y: 13.5), CGPoint(x: 15.9, y: 19.0)),
                       (CGPoint(x: 20.1, y: 15.5), CGPoint(x: 20.1, y: 20.5)),
                       (CGPoint(x: 23.9, y: 18.0), CGPoint(x: 23.9, y: 22.0)),
                   ])
        }) {
            // Fingertip is the path's (13, 3).
            built[.pointer] = Sprite(image: image, hotSpot: CGPoint(x: 14.5, y: 4.5), pointSize: handBox)
        }
        let beamBox = CGSize(width: 26, height: 28)
        if let image = rasterize(width: beamBox.width, height: beamBox.height, draw: { ctx in
            bubbly(bubblyIBeamPath(), in: ctx, box: beamBox, pad: CGPoint(x: 2, y: 2),
                   gloss: CGRect(x: 0, y: 2, width: 22, height: 9))
        }) {
            // Centre of the stem is the path's (11, 12).
            built[.iBeam] = Sprite(image: image, hotSpot: CGPoint(x: 13, y: 14), pointSize: beamBox)
        }
        return built
    }

    /// A slightly stouter arrow than the classic one, tip at the origin.
    private static func bubblyArrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17.5))
        path.addLine(to: CGPoint(x: 4.6, y: 13.4))
        path.addLine(to: CGPoint(x: 7.4, y: 19.4))
        path.addLine(to: CGPoint(x: 10.6, y: 17.9))
        path.addLine(to: CGPoint(x: 7.8, y: 12.2))
        path.addLine(to: CGPoint(x: 13.8, y: 12.2))
        path.closeSubpath()
        return path
    }

    /// Chubby pointing hand: index finger, three knuckles, thumb and palm as
    /// overlapping rounded rects; fingertip at (13, 3).
    private static func bubblyPointerPath() -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 10.2, y: 3.0, width: 5.6, height: 18), cornerWidth: 2.8, cornerHeight: 2.8)
        path.addRoundedRect(in: CGRect(x: 15.4, y: 12.0, width: 4.8, height: 9), cornerWidth: 2.4, cornerHeight: 2.4)
        path.addRoundedRect(in: CGRect(x: 19.6, y: 14.0, width: 4.6, height: 8), cornerWidth: 2.3, cornerHeight: 2.3)
        path.addRoundedRect(in: CGRect(x: 23.4, y: 16.5, width: 4.2, height: 7), cornerWidth: 2.1, cornerHeight: 2.1)
        path.addRoundedRect(in: CGRect(x: 4.5, y: 15.5, width: 6.5, height: 8), cornerWidth: 3.0, cornerHeight: 3.0)
        path.addRoundedRect(in: CGRect(x: 7.0, y: 18.5, width: 20.6, height: 12.0), cornerWidth: 5.5, cornerHeight: 5.5)
        return path
    }

    /// Chunky I-beam: stem and two serifs; centred on (11, 12).
    private static func bubblyIBeamPath() -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 8.9, y: 3.5, width: 4.2, height: 17), cornerWidth: 1.6, cornerHeight: 1.6)
        path.addRoundedRect(in: CGRect(x: 4.0, y: 2.0, width: 14, height: 4.2), cornerWidth: 2.1, cornerHeight: 2.1)
        path.addRoundedRect(in: CGRect(x: 4.0, y: 17.8, width: 14, height: 4.2), cornerWidth: 2.1, cornerHeight: 2.1)
        return path
    }

    /// Soft shadow, fat white rim, dark gradient body with a gloss across
    /// `gloss` (path coordinates), then optional crease lines. `pad` is
    /// where the path's origin sits inside `box`.
    private static func bubbly(
        _ path: CGPath, in ctx: CGContext, box: CGSize, pad: CGPoint, gloss: CGRect,
        creases: [(CGPoint, CGPoint)] = []
    ) {
        let rim = 3.4
        ctx.translateBy(x: pad.x, y: pad.y)
        // Shadow, cast by the rim.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.3), blur: 2.6, color: CGColor(gray: 0, alpha: 0.38))
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(rim)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
        // Rim.
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(rim)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
        // Body: the fill plus a round-joined stroke, as one alpha mask so the
        // gradient has no seams and the corners come out rounded.
        guard let mask = bodyMask(path, box: box, pad: pad) else { return }
        ctx.saveGState()
        // clip(to:mask:) takes the mask in the context's current space; undo
        // the padding and the flip so it lands on the whole box.
        ctx.translateBy(x: -pad.x, y: -pad.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -box.height)
        ctx.clip(to: CGRect(origin: .zero, size: box), mask: mask)
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: pad.x, y: pad.y)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bounds = path.boundingBox
        if let body = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.40, green: 0.40, blue: 0.45, alpha: 1),
            CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(body, start: CGPoint(x: bounds.minX, y: bounds.minY),
                                   end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
        }
        if let sheen = CGGradient(colorsSpace: space, colors: [
            CGColor(gray: 1, alpha: 0.42), CGColor(gray: 1, alpha: 0),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(sheen, start: CGPoint(x: gloss.minX, y: gloss.minY),
                                   end: CGPoint(x: gloss.minX, y: gloss.maxY), options: [])
        }
        ctx.restoreGState()
        if !creases.isEmpty {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
            ctx.setLineWidth(1.1)
            ctx.setLineCap(.round)
            for (a, b) in creases {
                ctx.move(to: a)
                ctx.addLine(to: b)
            }
            ctx.strokePath()
        }
    }

    private static func bodyMask(_ path: CGPath, box: CGSize, pad: CGPoint) -> CGImage? {
        let pixelW = Int(box.width * raster)
        let pixelH = Int(box.height * raster)
        guard let ctx = CGContext(
            data: nil, width: pixelW, height: pixelH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: raster, y: -raster)
        ctx.translateBy(x: pad.x, y: pad.y)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.fillPath()
        return ctx.makeImage()
    }

    // MARK: - Raster + composite

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

    /// Composite the cursor with its hot spot at (x, y) in output space (bottom-left origin).
    func composite(over background: CIImage, x: Double, y: Double, zoom: Double, kind: CursorKind) -> CIImage {
        guard let sprite = sprites[kind] ?? sprites[.arrow] else { return background }
        // Content-locked: the cursor scales with the zoom like everything else.
        let s = scaleFactor * zoom * styleScale
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
