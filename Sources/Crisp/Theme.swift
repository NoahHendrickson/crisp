import SwiftUI
import AppKit
import CoreText

/// Design tokens mirrored from noey-ui (src/index.css) and the Crisp v1
/// Figma (node 23:564). Primary is the sky-blue brand (#44b4ff / #0d95ef).
/// Control styles live in ThemeControls.swift.
enum Theme {
    // MARK: - Colors (light / dark from :root and .dark in index.css)

    static let background = dynamic("#f9f6f0", "#191919")      // Figma window bg / --background
    static let panel = dynamic("#ece9e4", "#252525")           // Figma preview panel / --card
    static let card = dynamic("#ffffff", "#2a2a2a")            // bg-background / input/30
    static let foreground = dynamic("#0a0a0a", "#fafafa")
    static let textSecondary = dynamic("#525252", "#d4d4d4")
    static let mutedForeground = dynamic("#737373", "#a1a1a1")
    static let muted = dynamic("#f5f5f5", "#373737")
    static let secondary = dynamic("#f5f5f5", "#373737")
    static let secondaryHover = dynamic("#ededed", "#3f3f3f")   // color-mix(secondary, foreground 5%)
    static let secondaryForeground = dynamic("#171717", "#fafafa")
    static let border = dynamic("#00000014", "#ffffff1a")       // --border (light: black/8)
    static let input = dynamic("#0000001f", "#ffffff26")        // --input  (light: black/12)
    static let ring = dynamic("#a1a1a1", "#737373")
    static let tabsTrack = dynamic("#00000014", "#ffffff14")    // rgba(0,0,0,0.08)
    static let destructive = dynamic("#e7000b", "#ff6467")
    static let success = dynamic("#15803d", "#4ade80")
    static let primary = Color(hex: "#44b4ff")
    static let primaryBorder = Color(hex: "#0d95ef")
    static let primaryForeground = Color(hex: "#fafafa")

    static let glossHighlight = Color.white.opacity(0.25)
    static let glossTop = Color(hex: "#d3e5fc").opacity(0.24)
    static let glossBottom = Color(hex: "#6fffff").opacity(0.5)

    static let radiusSm: CGFloat = 6   // buttons, select, tabs track
    static let radiusMd: CGFloat = 8   // tab pill, thumbnails
    static let radiusLg: CGFloat = 16  // panels

    static var backgroundNSColor: NSColor { nsDynamic("#f9f6f0", "#191919") }

    private static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(nsColor: nsDynamic(light, dark))
    }

    private static func nsDynamic(_ light: String, _ dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    // MARK: - Typography (Geist, bundled)

    enum Weight { case regular, medium, semibold }

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "Geist-Regular"
        case .medium: name = "Geist-Medium"
        case .semibold: name = "Geist-SemiBold"
        }
        return fontsRegistered ? .custom(name, size: size) : .system(size: size, weight: weight.system)
    }

    private static var fontsRegistered = false

    /// Registers the bundled Geist faces for this process. Safe to call once
    /// at launch; a face that's already installed system-wide is fine too.
    static func registerFonts() {
        let names = ["Geist-Regular", "Geist-Medium", "Geist-SemiBold"]
        var ok = false
        for name in names {
            guard let url = Bundle.module.url(
                forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts"
            ) else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                ok = true
            } else if let error = error?.takeRetainedValue(),
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
                ok = true
            }
        }
        fontsRegistered = ok
    }

    // MARK: - Bundled vector assets

    private static var imageCache: [String: NSImage] = [:]

    /// Loads an SVG from Resources/Icons as a template image (tinted by the
    /// current foreground style). Returns nil if the asset is missing.
    static func icon(_ name: String) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "svg", subdirectory: "Resources/Icons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        imageCache[name] = image
        return image
    }
}

extension Theme.Weight {
    var system: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }
}

extension NSColor {
    /// "#rgb", "#rrggbb" or "#rrggbbaa".
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

extension RectangleCornerRadii {
    static func all(_ r: CGFloat) -> RectangleCornerRadii {
        .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r)
    }
    static func leading(_ r: CGFloat) -> RectangleCornerRadii {
        .init(topLeading: r, bottomLeading: r, bottomTrailing: 0, topTrailing: 0)
    }
    static func trailing(_ r: CGFloat) -> RectangleCornerRadii {
        .init(topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r)
    }
}

// MARK: - Icons

/// A Phosphor icon (or the Crisp wordmark) from the bundled SVGs, tinted by
/// the surrounding foreground style. `fallback` is an SF Symbol used only if
/// the resource bundle is missing.
struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var fallback: String = "questionmark"

    var body: some View {
        Group {
            if let image = Theme.icon(name) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

struct Wordmark: View {
    var body: some View {
        Group {
            if let image = Theme.icon("crisp-wordmark") {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("Crisp").font(Theme.font(28, .semibold))
            }
        }
        .frame(width: 69.6, height: 24)
        .foregroundStyle(Theme.primary)
        .accessibilityLabel("Crisp")
    }
}
