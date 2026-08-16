// Generates the Crisp app icon: a macOS squircle filled with a smooth
// diagonal gradient (the thing Crisp exists to preserve), with the re-drawn
// cursor arrow and a click ripple.
//
// Usage: swift scripts/GenerateIcon.swift <output.iconset dir> [dev]
//        ("dev" switches the gradient to orange so the dev build is unmistakable)
// Then:  iconutil -c icns <output.iconset>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon.swift <out.iconset> [dev]\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let isDev = args.count > 2 && args[2] == "dev"
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(canvas: Int) -> CGImage? {
    let s = CGFloat(canvas)
    guard let ctx = CGContext(
        data: nil, width: canvas, height: canvas,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS icon grid: content squircle inset ~10% on a transparent canvas.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.addPath(squircle)
    ctx.clip()

    // The gradient — diagonal, dead smooth. Release: deep indigo → teal.
    // Dev: burnt orange → amber, so the two builds are unmistakable.
    let colors: [CGColor] = isDev
        ? [
            CGColor(srgbRed: 0.45, green: 0.12, blue: 0.02, alpha: 1),
            CGColor(srgbRed: 0.85, green: 0.38, blue: 0.05, alpha: 1),
            CGColor(srgbRed: 0.98, green: 0.65, blue: 0.12, alpha: 1),
        ]
        : [
            CGColor(srgbRed: 0.10, green: 0.08, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.12, green: 0.35, blue: 0.66, alpha: 1),
            CGColor(srgbRed: 0.15, green: 0.65, blue: 0.68, alpha: 1),
        ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.minY),
        end: CGPoint(x: rect.maxX, y: rect.maxY),
        options: []
    )

    // Click ripple ring, upper-left of center.
    let ringCenter = CGPoint(x: rect.midX - rect.width * 0.10, y: rect.midY + rect.height * 0.08)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.setLineWidth(s * 0.028)
    let ringRadius = rect.width * 0.17
    ctx.strokeEllipse(in: CGRect(
        x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2
    ))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
    let ring2 = ringRadius * 1.45
    ctx.strokeEllipse(in: CGRect(
        x: ringCenter.x - ring2, y: ringCenter.y - ring2,
        width: ring2 * 2, height: ring2 * 2
    ))

    // Cursor arrow (same shape the exporter draws), tip at the ring center.
    let arrowScale = s * 0.022
    ctx.saveGState()
    ctx.translateBy(x: ringCenter.x, y: ringCenter.y)
    ctx.scaleBy(x: arrowScale, y: -arrowScale)  // cursor coords are y-down
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
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        exit(2)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// iconset sizes: (filename points, pixels)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    guard let image = drawIcon(canvas: pixels) else { exit(3) }
    write(image, to: outDir.appendingPathComponent("\(name).png"))
}
print("iconset written to \(outDir.path)")
