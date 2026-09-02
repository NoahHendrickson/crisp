import Foundation
import CoreImage
import CoreGraphics
import CoreText

/// Turns a decoded master frame + timestamp into the final composed frame:
/// zoom camera transform, re-drawn vector cursor, click ripples, and the
/// optional speed-up badge.
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
    /// The speed-ups that asked for a badge: while `t` is inside one, its
    /// rate is drawn in the bottom-right corner.
    private let speedBadges: [SpeedWindow.Range]
    private let badge: SpeedBadgeSprite

    /// `speeds` are the plan's speed-ups as they apply; only those with
    /// `badge` set draw anything.
    init(
        meta: RecordingMeta, keys: [ZoomPlanner.Keyframe], cursorStyle: CursorStyle,
        speeds: [SpeedWindow.Range] = []
    ) {
        self.width = Double(meta.pixelWidth)
        self.height = Double(meta.pixelHeight)
        self.keys = keys
        self.samples = meta.samples
        self.clicks = meta.events.filter { $0.kind == .leftDown }
        self.cursor = CursorSprite(style: cursorStyle, scaleFactor: meta.scaleFactor)
        self.rippleScale = meta.scaleFactor
        self.speedBadges = speeds.filter(\.badge)
        self.badge = SpeedBadgeSprite(frameHeight: Double(meta.pixelHeight))
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

        var out = composed.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        // The badge is screen-space: composited after the camera, so it holds
        // its size and corner through zooms. A short fade at the window's
        // edges keeps it from popping.
        if let range = speedBadges.first(where: { t >= $0.start && t < $0.end }),
           let sprite = badge.image(rate: range.rate) {
            let alpha = min(1, max(0, min(t - range.start, range.end - t) / 0.2))
            out = sprite
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)),
                ])
                .transformed(by: CGAffineTransform(
                    translationX: width - sprite.extent.width - badge.margin,
                    y: badge.margin
                ))
                .composited(over: out)
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return out
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

/// The speed-up badge: a dark capsule with the rate ("3×") in white, sized
/// against the frame so it reads the same at any recording resolution. One
/// raster per rate, built on first use.
private final class SpeedBadgeSprite {
    private var cache: [Double: CIImage] = [:]
    /// Badge height in master pixels.
    private let height: Double
    /// Gap between the badge and the frame's bottom-right corner.
    let margin: Double

    init(frameHeight: Double) {
        height = max(22, (frameHeight * 0.045).rounded())
        margin = (height * 0.55).rounded()
    }

    func image(rate: Double) -> CIImage? {
        if let cached = cache[rate] { return cached }
        guard let built = build(rate: rate) else { return nil }
        cache[rate] = built
        return built
    }

    private func build(rate: Double) -> CIImage? {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, height * 0.52, nil)
        let attributed = CFAttributedStringCreate(
            nil, String(format: "%g×", rate) as CFString,
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            ] as CFDictionary
        )
        guard let attributed else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        let text = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        let width = (text.width + height * 0.84).rounded()
        guard let ctx = CGContext(
            data: nil, width: Int(width), height: Int(height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath()
        ctx.textPosition = CGPoint(
            x: (width - text.width) / 2 - text.minX,
            y: (height - text.height) / 2 - text.minY
        )
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
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

    // MARK: - Classic: the system cursors — black arrow and I-beam with a white
    // outline, white pointing hand with a black rim

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
            drawClassicPointer(in: ctx)
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

    /// The macOS pointing hand: white face inside a 1pt black rim with a soft
    /// drop shadow, in a 32×32 box with the index fingertip at (13, 8). Built
    /// from one capsule per finger over a palm-and-thumb shape, so the rim
    /// between fingers falls out of the overlap instead of being traced.
    private static func drawClassicPointer(in ctx: CGContext) {
        // Finger centre x and tip-cap centre y: index, middle, ring, pinky.
        let fingers: [(cx: CGFloat, tip: CGFloat)] = [(13.75, 8.75), (16.25, 13.5), (18.75, 14.5), (20.75, 15.75)]
        let black = CGColor(gray: 0, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)

        ctx.saveGState()
        // Shadow offset and blur are in device pixels, so scale by the raster.
        ctx.setShadow(
            offset: CGSize(width: 0.4 * raster, height: -1.0 * raster),
            blur: 1.6 * raster,
            color: CGColor(gray: 0, alpha: 0.45)
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(black)
        ctx.addPath(pointerPalmSilhouette())
        ctx.fillPath()
        for finger in fingers {
            ctx.addPath(capsule(cx: finger.cx, top: finger.tip, bottom: 20, halfWidth: 1.75))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        ctx.setFillColor(white)
        ctx.addPath(pointerPalmFace())
        ctx.fillPath()
        for finger in fingers {
            ctx.addPath(capsule(cx: finger.cx, top: finger.tip, bottom: 17, halfWidth: 0.75))
            ctx.fillPath()
        }
        ctx.setFillColor(black)
        ctx.addPath(pointerThumbCrease())
        ctx.fillPath()
    }

    /// Black outer shape of the palm and thumb, including the slit between the
    /// thumb and index finger. The finger capsules sit on top.
    private static func pointerPalmSilhouette() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 8, y: 16.5))
        path.addLine(to: CGPoint(x: 8, y: 15.25))
        addCapOverTop(path, cx: 9.75, cy: 15.25, r: 1.75)
        path.addLine(to: CGPoint(x: 11.5, y: 16.7))
        path.addLine(to: CGPoint(x: 12.5, y: 16.7))
        path.addLine(to: CGPoint(x: 12.5, y: 16))
        path.addLine(to: CGPoint(x: 22.5, y: 16))
        path.addLine(to: CGPoint(x: 22.5, y: 22.3))
        path.addCurve(
            to: CGPoint(x: 19, y: 25.5),
            control1: CGPoint(x: 22.5, y: 24.2), control2: CGPoint(x: 21.3, y: 25.5)
        )
        path.addLine(to: CGPoint(x: 14.5, y: 25.5))
        path.addCurve(
            to: CGPoint(x: 11.4, y: 23.2),
            control1: CGPoint(x: 12.8, y: 25.5), control2: CGPoint(x: 11.8, y: 24.4)
        )
        path.closeSubpath()
        return path
    }

    /// White face of the palm and thumb, 1pt inside the silhouette. Its top
    /// edge steps down toward the pinky so each finger gap ends at its own depth.
    private static func pointerPalmFace() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 13, y: 15.25))
        path.addLine(to: CGPoint(x: 17.25, y: 15.25))
        path.addLine(to: CGPoint(x: 17.25, y: 16))
        path.addLine(to: CGPoint(x: 19.6, y: 16))
        path.addLine(to: CGPoint(x: 19.6, y: 16.5))
        path.addLine(to: CGPoint(x: 21.5, y: 16.5))
        path.addLine(to: CGPoint(x: 21.5, y: 22))
        path.addCurve(
            to: CGPoint(x: 18.5, y: 24.5),
            control1: CGPoint(x: 21.5, y: 23.3), control2: CGPoint(x: 20.3, y: 24.5)
        )
        path.addLine(to: CGPoint(x: 15, y: 24.5))
        path.addCurve(
            to: CGPoint(x: 12.3, y: 22.8),
            control1: CGPoint(x: 13.5, y: 24.5), control2: CGPoint(x: 12.6, y: 23.7)
        )
        path.addLine(to: CGPoint(x: 9, y: 15.75))
        path.addLine(to: CGPoint(x: 9, y: 15.25))
        addCapOverTop(path, cx: 9.75, cy: 15.25, r: 0.75)
        path.closeSubpath()
        return path
    }

    /// Black wedge between the thumb and the index finger, rounded where it
    /// meets the palm.
    private static func pointerThumbCrease() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10.5, y: 14.5))
        path.addLine(to: CGPoint(x: 13, y: 14.5))
        path.addLine(to: CGPoint(x: 13, y: 17.8))
        path.addCurve(
            to: CGPoint(x: 12, y: 18.5),
            control1: CGPoint(x: 13, y: 18.3), control2: CGPoint(x: 12.5, y: 18.5)
        )
        path.addLine(to: CGPoint(x: 11.5, y: 18.2))
        path.addLine(to: CGPoint(x: 11.5, y: 17.5))
        path.closeSubpath()
        return path
    }

    /// Vertical capsule with a round top centred at (cx, top) and a flat bottom.
    private static func capsule(cx: CGFloat, top: CGFloat, bottom: CGFloat, halfWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx - halfWidth, y: bottom))
        path.addLine(to: CGPoint(x: cx - halfWidth, y: top))
        addCapOverTop(path, cx: cx, cy: top, r: halfWidth)
        path.addLine(to: CGPoint(x: cx + halfWidth, y: bottom))
        path.closeSubpath()
        return path
    }

    /// Semicircle from (cx - r, cy) over the top to (cx + r, cy), top-left space.
    private static func addCapOverTop(_ path: CGMutablePath, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let k: CGFloat = 0.5523
        path.addCurve(
            to: CGPoint(x: cx, y: cy - r),
            control1: CGPoint(x: cx - r, y: cy - k * r), control2: CGPoint(x: cx - k * r, y: cy - r)
        )
        path.addCurve(
            to: CGPoint(x: cx + r, y: cy),
            control1: CGPoint(x: cx + k * r, y: cy - r), control2: CGPoint(x: cx + r, y: cy - k * r)
        )
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

    // MARK: - Bevel: bundled cute arrow, used for every cursor kind

    /// Black outline around the white face; also the stroke used for the
    /// extruded side so the rim and the 3D depth read as one mass.
    private static let bevelOutline: CGFloat = 2.4
    /// Down-right in the sprite's top-left space, matching cute-arrow.svg.
    private static let bevelExtrude = CGPoint(x: 2.0, y: 2.6)

    /// Only the arrow: the beveled hand and I-beam variants read badly, so
    /// the cute arrow stands in for every kind via the composite fallback.
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
