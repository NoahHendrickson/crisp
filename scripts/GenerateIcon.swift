// Generates the Crisp app icon as Icon Composer packages, so macOS 26 renders
// it with Liquid Glass: assets/AppIcon.icon (release) and assets/AppIcon-Dev.icon.
//
// The geometry is the Figma design (Crisp v1, node 163:3173 / 163:3178): a
// ring with a wedge sweep, a core disc, and an orbiting dot that punches a gap
// through the ring. Figma draws that gap as a background-colored stroke on the
// dot; glass layers can't fake it that way, so the gap is subtracted from the
// ring and wedge paths here and each shape becomes its own glass layer.
//
// Usage: swift scripts/GenerateIcon.swift
// Then:  ./scripts/bundle.sh compiles the .icon with actool (Xcode 26).

import CoreGraphics
import Foundation

struct Variant {
    let package: String
    let fill: String   // Icon Composer color string
}

let variants = [
    Variant(package: "assets/AppIcon.icon", fill: "srgb:1.00000,0.17647,0.34118,1.00000"),      // #FF2D57
    Variant(package: "assets/AppIcon-Dev.icon", fill: "srgb:0.99216,0.32549,0.10588,1.00000"),  // #FD531B
]

let ink = "#E8E4E1"
let canvas: CGFloat = 1024

// MARK: - Geometry (Figma coordinates, y down)

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
}

// Ellipse 5: the dot, plus its 32pt background stroke which reads as a gap.
let dot = circle(724, 310, 84)
let dotGap = circle(724, 310, 100)

// Ellipse 4: 24pt ring stroke, minus the gap.
let ring = circle(512.5, 511.5, 292.5)
    .copy(strokingWithWidth: 24, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    .subtracting(dotGap)

// Ellipse 3: the core disc.
let core = circle(512, 512, 112)

// Vector 51: the wedge sweep, minus the gap (the dot sits over its tip).
let wedgePath = CGMutablePath()
wedgePath.move(to: CGPoint(x: 717.5, y: 273.5))
wedgePath.addLine(to: CGPoint(x: 290.5, y: 701.5))
wedgePath.addCurve(to: CGPoint(x: 717.5, y: 718.5),
                   control1: CGPoint(x: 409, y: 810.5), control2: CGPoint(x: 569.5, y: 845.7))
wedgePath.addCurve(to: CGPoint(x: 717.5, y: 273.5),
                   control1: CGPoint(x: 865.5, y: 591.3), control2: CGPoint(x: 788.5, y: 367))
wedgePath.closeSubpath()
let wedge = wedgePath.subtracting(dotGap)

// MARK: - SVG

func fmt(_ v: CGFloat) -> String {
    let s = String(format: "%.3f", v)
    return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

func svgData(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addLineToPoint: d += "L\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y))"
        case .addCurveToPoint:
            d += "C\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) \(fmt(p[2].x)) \(fmt(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(_ path: CGPath, fill: String, opacity: CGFloat = 1) -> String {
    let alpha = opacity < 1 ? " fill-opacity=\"\(fmt(opacity))\"" : ""
    return """
    <svg width="\(Int(canvas))" height="\(Int(canvas))" viewBox="0 0 \(Int(canvas)) \(Int(canvas))" xmlns="http://www.w3.org/2000/svg">
    <path d="\(svgData(path))" fill="\(fill)"\(alpha) fill-rule="nonzero"/>
    </svg>

    """
}

let layers: [(file: String, svg: String)] = [
    ("wedge.svg", svg(wedge, fill: ink, opacity: 0.35)),
    ("ring.svg", svg(ring, fill: ink)),
    ("core.svg", svg(core, fill: ink)),
    ("dot.svg", svg(dot, fill: "#FFFFFF")),
]

// MARK: - icon.json

func iconJSON(fill: String) -> String {
    // Layers list top-first, as Icon Composer writes them.
    """
    {
      "fill" : {
        "solid" : "\(fill)"
      },
      "groups" : [
        {
          "blend-mode" : "normal",
          "layers" : [
            {
              "blend-mode" : "normal",
              "fill" : "automatic",
              "glass" : true,
              "hidden" : false,
              "image-name" : "dot.svg",
              "name" : "Dot"
            },
            {
              "blend-mode" : "normal",
              "fill" : "automatic",
              "glass" : true,
              "hidden" : false,
              "image-name" : "core.svg",
              "name" : "Core"
            },
            {
              "blend-mode" : "normal",
              "fill" : "automatic",
              "glass" : true,
              "hidden" : false,
              "image-name" : "ring.svg",
              "name" : "Ring"
            },
            {
              "blend-mode" : "normal",
              "fill" : "automatic",
              "glass" : true,
              "hidden" : false,
              "image-name" : "wedge.svg",
              "name" : "Wedge"
            }
          ],
          "lighting" : "individual",
          "name" : "Mark",
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.5
          },
          "specular" : true,
          "translucency" : {
            "enabled" : true,
            "value" : 0.5
          }
        }
      ],
      "supported-platforms" : {
        "circles" : [
          "watchOS"
        ],
        "squares" : "shared"
      }
    }

    """
}

// MARK: - Write

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
for variant in variants {
    let package = root.appendingPathComponent(variant.package, isDirectory: true)
    let assets = package.appendingPathComponent("Assets", isDirectory: true)
    try? fm.removeItem(at: package)
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    try iconJSON(fill: variant.fill).write(to: package.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    for layer in layers {
        try layer.svg.write(to: assets.appendingPathComponent(layer.file), atomically: true, encoding: .utf8)
    }
    print("wrote \(variant.package)")
}
