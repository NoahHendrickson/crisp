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
    /// Points-to-points size multiplier of the style.
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
            styleScale = 1
            sprites = Self.bevelSprites()
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

    // MARK: - Bevel: bundled cute arrow, matching hand and I-beam

    /// Black outline around the white face; also the stroke used for the
    /// extruded side so the rim and the 3D depth read as one mass.
    private static let bevelOutline: CGFloat = 2.4
    /// Down-right in the sprite's top-left space, matching cute-arrow.svg.
    private static let bevelExtrude = CGPoint(x: 2.0, y: 2.6)

    /// Each shape sits inside a padded box so its rim, extrusion and shadow
    /// never clip; hot spots are the shape's own plus the padding.
    private static func bevelSprites() -> [CursorKind: Sprite] {
        var built: [CursorKind: Sprite] = [:]
        let arrowBox = CGSize(width: 28, height: 30)
        if let image = rasterize(width: arrowBox.width, height: arrowBox.height, draw: { ctx in
            drawCuteArrow(in: ctx)
        }) {
            // Tip of the artwork is about (4.25, 0).
            built[.arrow] = Sprite(
                image: image,
                hotSpot: CGPoint(x: 4.25, y: 0.4),
                pointSize: arrowBox
            )
        }
        let handPad = CGPoint(x: 4, y: 4)
        let handBox = CGSize(width: 36, height: 44)
        if let image = rasterize(width: handBox.width, height: handBox.height, draw: { ctx in
            bevel(classicPointerPath(), in: ctx, pad: handPad)
        }) {
            built[.pointer] = Sprite(
                image: image,
                hotSpot: CGPoint(x: 13 + handPad.x, y: 8 + handPad.y),
                pointSize: handBox
            )
        }
        let beamPad = CGPoint(x: 4, y: 4)
        let beamBox = CGSize(width: 32, height: 34)
        if let image = rasterize(width: beamBox.width, height: beamBox.height, draw: { ctx in
            bevel(classicIBeamPath(), in: ctx, pad: beamPad)
        }) {
            built[.iBeam] = Sprite(
                image: image,
                hotSpot: CGPoint(x: 12 + beamPad.x, y: 11 + beamPad.y),
                pointSize: beamBox
            )
        }
        return built
    }

    /// The bundled cute-arrow.svg: black 3D silhouette with a white face.
    private static func drawCuteArrow(in ctx: CGContext) {
        guard let paths = cuteArrowPaths() else {
            bevel(classicArrowPath(), in: ctx, pad: CGPoint(x: 8, y: 4))
            return
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(paths.outer)
        ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(paths.inner)
        ctx.fillPath()
    }

    private static func cuteArrowPaths() -> (outer: CGPath, inner: CGPath)? {
        guard let url = Bundle.module.url(
            forResource: "cute-arrow", withExtension: "svg", subdirectory: "Resources/Cursors"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let ds = svgPathData(in: text)
        guard ds.count >= 2 else { return nil }
        return (cgPath(svgPath: ds[0]), cgPath(svgPath: ds[1]))
    }

    private static func svgPathData(in svg: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"path d="([^"]+)""#) else { return [] }
        let ns = svg as NSString
        return regex.matches(in: svg, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    /// Absolute M / L / C / Z only — enough for cute-arrow.svg.
    private static func cgPath(svgPath d: String) -> CGPath {
        let path = CGMutablePath()
        guard let regex = try? NSRegularExpression(
            pattern: #"[MLCZ]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?"#
        ) else { return path }
        let ns = d as NSString
        let tokens = regex.matches(in: d, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
        var i = 0
        var cmd = "M"
        var x: CGFloat = 0, y: CGFloat = 0
        var start = CGPoint.zero
        func num() -> CGFloat {
            let v = CGFloat(Double(tokens[i]) ?? 0)
            i += 1
            return v
        }
        while i < tokens.count {
            let t = tokens[i]
            if t.count == 1, t.first?.isLetter == true {
                cmd = t
                i += 1
                if cmd == "Z" {
                    path.closeSubpath()
                    x = start.x
                    y = start.y
                }
                continue
            }
            switch cmd {
            case "M":
                x = num(); y = num()
                start = CGPoint(x: x, y: y)
                path.move(to: start)
                cmd = "L"
            case "L":
                x = num(); y = num()
                path.addLine(to: CGPoint(x: x, y: y))
            case "C":
                let x1 = num(), y1 = num(), x2 = num(), y2 = num()
                x = num(); y = num()
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: x1, y: y1),
                    control2: CGPoint(x: x2, y: y2)
                )
            default:
                i += 1
            }
        }
        return path
    }

    /// Soft gray shadow, stacked black copies along `bevelExtrude` for the
    /// 3D side, then a white face with a black rim. `pad` is where the
    /// path's origin sits inside the sprite box.
    private static func bevel(_ path: CGPath, in ctx: CGContext, pad: CGPoint) {
        ctx.translateBy(x: pad.x, y: pad.y)
        let black = CGColor(gray: 0, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)

        func stamp(_ fill: CGColor, stroke: CGColor?) {
            ctx.setFillColor(fill)
            ctx.setLineWidth(bevelOutline)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.addPath(path)
            ctx.fillPath()
            if let stroke {
                ctx.setStrokeColor(stroke)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 1.2, height: -2.4),
            blur: 3.4,
            color: CGColor(gray: 0.22, alpha: 0.28)
        )
        ctx.translateBy(x: bevelExtrude.x, y: bevelExtrude.y)
        stamp(black, stroke: black)
        ctx.restoreGState()

        let dist = hypot(bevelExtrude.x, bevelExtrude.y)
        let steps = max(1, Int(ceil(dist * raster)))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            ctx.saveGState()
            ctx.translateBy(x: bevelExtrude.x * t, y: bevelExtrude.y * t)
            stamp(black, stroke: black)
            ctx.restoreGState()
        }

        stamp(black, stroke: black)
        stamp(white, stroke: nil)
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
