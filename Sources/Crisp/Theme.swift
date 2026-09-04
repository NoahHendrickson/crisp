import SwiftUI
import AppKit
import CoreText

/// Design tokens mirrored from noey-ui (src/index.css) and the Crisp v1
/// Figma (node 61:9313). Monochrome "ink / paper" system: light mode is ink
/// on paper, dark mode is paper on ink. Borders use the solid `--border`
/// swatch; secondary fills and tracks are foreground alphas so they follow
/// the mode on their own. The sky-blue `primary` survives as the editor's
/// crop box and zoom bars and the dropdown check.
/// Control styles live in ThemeControls.swift.
enum Theme {
    // MARK: - Colors (light / dark)

    static let background = dynamic("#f8f7eb", "#23201e")        // --background
    static let foreground = dynamic("#23201e", "#f8f7eb")        // --foreground / text-primary
    static let textSecondary = dynamic("#55514f", "#d4d4d4")     // --text-secondary
    static let mutedForeground = dynamic("#737373", "#a1a1a1")   // --muted-foreground
    static let card = dynamic("#f8f7eb", "#2b2825")              // --card / --popover
    /// Composer field and action pills: Figma `bg-white` on paper; in dark,
    /// the panel itself (`--card`) so they don't lift off the page.
    static let well = dynamic("#ffffff", "#2b2825")
    static let panel = dynamic("#eeebe2", "#2b2825")             // placeholder surfaces
    static let muted = dynamic("#23201e0f", "#ffffff14")         // ghost hover
    static let border = dynamic("#e8e4e1", "#ffffff1f")          // --border
    static let input = dynamic("#23201e1f", "#f8f7eb1f")         // foreground/12: select stroke
    static let secondary = dynamic("#23201e1f", "#f8f7eb1f")     // bg-foreground/12
    static let secondaryHover = dynamic("#23201e29", "#f8f7eb29") // bg-foreground/16
    static let outlineHover = dynamic("#23201e0d", "#f8f7eb0d")  // bg-foreground/5
    /// Text-selection band (Figma 76:13676): sky blue at 30%.
    static let selection = Color(red: 57 / 255, green: 147 / 255, blue: 244 / 255).opacity(0.3)
    static let destructive = dynamic("#e7000b", "#ff6467")
    static let success = dynamic("#15803d", "#4ade80")
    /// Brand green (`--secondary`, Figma 75:11919): the zoom / step count tag.
    static let brand = dynamic("#359e70", "#4ade80")
    /// `secondary/_states/selected` — brand green at 8% (16% on ink).
    static let brandSelected = dynamic("#007e4814", "#4ade8029")
    /// Editor timeline (Figma 93:1015): a black@12 track; the video row is
    /// `secondary/light`, zoom holds are blue, pinned stretches orange, all
    /// with a white@50 hairline; ruler ticks black@24.
    static let timelineTrack = dynamic("#0000001f", "#ffffff1f")
    static let videoBar = dynamic("#33c27b", "#4ade80")
    static let zoomBar = dynamic("#47a6ff", "#47a6ff")
    static let pinBar = dynamic("#ff9a42", "#ff9a42")
    static let pinBarBorder = dynamic("#ffe19a", "#ffe19a")
    static let clipBar = dynamic("#a96cff", "#a96cff")
    static let speedBar = dynamic("#14b8a6", "#2dd4bf")
    static let barBorder = Color.white.opacity(0.5)
    static let ruler = dynamic("#0000003d", "#ffffff3d")
    /// Value wells in the toolbar's Zoom / Pin groups (Figma 93:745):
    /// paper with a foreground@24 hairline.
    static let fieldBorder = dynamic("#23201e3d", "#f8f7eb3d")
    /// Record button (Figma 43:5324) — the one saturated control.
    static let record = Color(hex: "#ff2d57")
    /// `--emphatic` (Figma 173:3873): the blue call-to-action fill behind the
    /// library row's Edit button.
    static let emphatic = Color(hex: "#4580e5")

    // Raised surface: the progress track / indicator (progress.tsx). Light: muted + background; dark:
    // white @12 / @16 with white @8 / @24 borders.
    static let track = dynamic("#23201e14", "#ffffff1f")
    static let trackBorder = dynamic("#23201e14", "#ffffff14")
    static let raised = dynamic("#f8f7eb", "#ffffff29")
    static let raisedBorder = dynamic("#23201e1f", "#ffffff3d")
    /// Figma "Shadow/raised": 2px 0 8px black@8 + 3px 0 12px black@12.
    static let raisedShadowNear = Color.black.opacity(0.08)
    static let raisedShadowFar = Color.black.opacity(0.12)

    /// IconTabList track (Figma 174:925): solid --border in light, white@12 in dark.
    static let iconTabsList = dynamic("#e8e4e1", "#ffffff1f")

    // Zoom accent (editor timeline, crop box): the library's sky-blue primary.
    static let primary = Color(hex: "#44b4ff")
    static let primaryBorder = Color(hex: "#0d95ef")
    /// Label color on tinted (record / primary-blue) fills.
    static let primaryForeground = Color(hex: "#f8f7eb")

    static let radiusSm: CGFloat = 6   // select trigger, tags
    static let radiusMd: CGFloat = 8   // buttons, tabs, thumbnails, panels
    static let radiusLg: CGFloat = 16  // editor preview

    static var backgroundNSColor: NSColor { nsDynamic("#f8f7eb", "#23201e") }

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

    /// The type ramp, mirroring the Noey UI text styles: Label (Geist Medium)
    /// and Body (Geist Regular) at 12/14/16, plus three semibold headings.
    /// Components pick from this ramp instead of carrying their own sizes.
    enum TextStyle {
        case label12, label14, label16
        case body12, body14, body16
        case heading1, heading2, heading3

        var size: CGFloat {
            switch self {
            case .label12, .body12: 12
            case .label14, .body14: 14
            case .label16, .body16: 16
            case .heading3: 20
            case .heading2: 24
            case .heading1: 30
            }
        }

        var weight: Weight {
            switch self {
            case .body12, .body14, .body16: .regular
            case .label12, .label14, .label16: .medium
            case .heading1, .heading2, .heading3: .semibold
            }
        }
    }

    static func font(_ style: TextStyle) -> Font {
        font(style.size, style.weight)
    }

    private static func font(_ size: CGFloat, _ weight: Weight) -> Font {
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
                Text("Crisp").font(Theme.font(.heading2))
            }
        }
        .frame(width: 70, height: 20)
        .foregroundStyle(Theme.foreground)
        .accessibilityLabel("Crisp")
    }
}
