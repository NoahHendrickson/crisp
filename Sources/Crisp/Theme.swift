import SwiftUI
import AppKit
import CoreText

/// Design tokens and control styles mirrored from noey-ui
/// (src/index.css, button.tsx, tabs.tsx, select.tsx) and the Crisp v1 Figma
/// (node 23:564). Primary is the sky-blue brand (#44b4ff / #0d95ef).
enum AppAppearance: String {
    static let storageKey = "appearance"

    case light, dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    var nsAppearance: NSAppearance {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
    }

    var other: AppAppearance { self == .dark ? .light : .dark }

    func apply() {
        NSApp.appearance = nsAppearance
    }
}

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

// MARK: - Gloss (shadow-button-gloss / shadow-gloss-sm)

extension ShapeStyle {
    /// The library's "Button/Primary gloss" (or "Gloss/Small" for tabs):
    /// cool inset highlight from the top, cyan inset glow from the bottom.
    /// CSS blur radius ≈ 2× the SwiftUI shadow radius. Pair with
    /// `glossRing` for the 2px inner highlight.
    func glossed(small: Bool = false) -> some ShapeStyle {
        self
            .shadow(.inner(color: Theme.glossTop, radius: small ? 2 : 4, x: 0, y: small ? 1 : 2))
            .shadow(.inner(color: Theme.glossBottom, radius: small ? 1.5 : 3, x: 0, y: small ? -1 : -2))
    }
}

extension InsettableShape {
    /// The gloss highlight ring (spec says 2px spread; 1px reads correctly on screen).
    func glossRing(width: CGFloat = 1, insideBorder border: CGFloat = 1) -> some View {
        inset(by: border)
            .strokeBorder(Theme.glossHighlight, lineWidth: width)
            .allowsHitTesting(false)
    }
}

/// Gradient approximation of the gloss for use over images (thumbnails),
/// where an inner shadow can't be attached to a fill.
struct GlossOverlay<S: InsettableShape>: View {
    let shape: S
    var small = false
    var ringWidth: CGFloat = 1

    var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: Theme.glossTop, location: 0),
                        .init(color: .clear, location: small ? 0.3 : 0.4),
                        .init(color: .clear, location: 0.65),
                        .init(color: Theme.glossBottom, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            shape.strokeBorder(Theme.glossHighlight, lineWidth: ringWidth)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pointer cursor

/// Shows the pointing-hand cursor over a clickable control. Disabled views
/// keep the arrow. Uses AppKit cursor rects so the cursor resets when the
/// mouse leaves, even if SwiftUI hover gets out of sync.
extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.background {
            if isEnabled { PointingHandCursorView() }
        }
    }
}

private struct PointingHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> PointingHandCursorNSView {
        PointingHandCursorNSView()
    }

    func updateNSView(_ view: PointingHandCursorNSView, context: Context) {}
}

private final class PointingHandCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Buttons (button.tsx variants + sizes)

enum ControlSizeToken {
    case xs, sm, md, lg

    var height: CGFloat {
        switch self { case .xs: 24; case .sm: 28; case .md: 32; case .lg: 36 }
    }
    var horizontalPadding: CGFloat {
        switch self { case .xs: 8; case .sm: 12; case .md: 12; case .lg: 12 }
    }
    var fontSize: CGFloat {
        switch self { case .xs: 12; case .sm: 12.8; case .md: 14; case .lg: 14 }
    }
    /// Padding on the side that carries an icon (has-data-[icon]:pl-2 etc.).
    var iconSidePadding: CGFloat {
        switch self { case .xs: 6; case .sm: 6; case .md: 8; case .lg: 8 }
    }
    var gap: CGFloat {
        switch self { case .xs: 4; case .sm: 4; case .md: 6; case .lg: 6 }
    }
    var iconSize: CGFloat {
        switch self { case .xs: 12; case .sm: 14; case .md: 16; case .lg: 16 }
    }
}

enum ButtonVariant {
    case primary, outline, secondary, ghost, destructive, link
}

struct ThemedButtonStyle: ButtonStyle {
    var variant: ButtonVariant = .primary
    var size: ControlSizeToken = .md
    var iconOnly = false
    var fullWidth = false
    var corners: RectangleCornerRadii? = nil
    /// Tightens the leading / trailing padding when an icon sits there.
    var leadingIcon = false
    var trailingIcon = false
    /// Overrides the primary fill/border (e.g. red while recording).
    var tint: Color? = nil
    var tintBorder: Color? = nil
    /// Overrides `size.fontSize` (e.g. 14pt on a 28pt sm button).
    var fontSize: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, style: self)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let style: ThemedButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = UnevenRoundedRectangle(
                cornerRadii: style.corners ?? .all(Theme.radiusSm), style: .continuous
            )
            let size = style.size
            configuration.label
                .font(Theme.font(style.fontSize ?? size.fontSize, .medium))
                .foregroundStyle(foreground)
                .padding(.leading, style.iconOnly ? 0 : (style.leadingIcon ? size.iconSidePadding : size.horizontalPadding))
                .padding(.trailing, style.iconOnly ? 0 : (style.trailingIcon ? size.iconSidePadding : size.horizontalPadding))
                .frame(width: style.iconOnly ? size.height : nil, height: size.height)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .background {
                    if style.variant == .primary {
                        shape.fill(fill)
                            .overlay(shape.inset(by: 1).fill(fill.glossed()))
                    } else {
                        shape.fill(fill)
                    }
                }
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .overlay {
                    if style.variant == .primary {
                        shape.glossRing()
                    }
                }
                .contentShape(shape)
                .offset(y: configuration.isPressed ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.5)
                .pointingHandCursor()
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            switch style.variant {
            case .primary: return (style.tint ?? Theme.primary).opacity(hovering ? 0.8 : 1)
            case .outline: return hovering ? Theme.muted : Theme.card
            case .secondary: return hovering ? Theme.secondaryHover : Theme.secondary
            case .ghost: return hovering ? Theme.muted : .clear
            case .destructive: return Theme.destructive.opacity(hovering ? 0.2 : 0.1)
            case .link: return .clear
            }
        }

        private var foreground: Color {
            switch style.variant {
            case .primary: return Theme.primaryForeground
            case .outline, .ghost: return Theme.foreground
            case .secondary: return Theme.secondaryForeground
            case .destructive: return Theme.destructive
            case .link: return Theme.primary
            }
        }

        private var borderColor: Color {
            switch style.variant {
            case .primary: return style.tintBorder ?? style.tint ?? Theme.primaryBorder
            case .outline: return Theme.border
            default: return .clear
            }
        }
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static func themed(
        _ variant: ButtonVariant = .primary,
        size: ControlSizeToken = .md,
        iconOnly: Bool = false,
        fullWidth: Bool = false,
        corners: RectangleCornerRadii? = nil,
        leadingIcon: Bool = false,
        trailingIcon: Bool = false,
        tint: Color? = nil,
        tintBorder: Color? = nil,
        fontSize: CGFloat? = nil
    ) -> ThemedButtonStyle {
        ThemedButtonStyle(
            variant: variant, size: size, iconOnly: iconOnly, fullWidth: fullWidth,
            corners: corners, leadingIcon: leadingIcon, trailingIcon: trailingIcon,
            tint: tint, tintBorder: tintBorder, fontSize: fontSize
        )
    }
}

// MARK: - Tabs (tabs.tsx, variant=default)

/// Muted track with pill triggers; the active tab uses the primary button
/// treatment with the small gloss. A single pill slides between tabs.
struct TabsPicker<Item: Identifiable & Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    @State private var frames: [AnyHashable: CGRect] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let active = item == selection
                Button { selection = item } label: {
                    Text(label(item))
                        .font(Theme.font(14, .medium))
                        .foregroundStyle(active ? Theme.primaryForeground : Theme.mutedForeground)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabFramePreference.self,
                                    value: [AnyHashable(item.id): geo.frame(in: .named("tabs"))]
                                )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .coordinateSpace(name: "tabs")
        .onPreferenceChange(TabFramePreference.self) { frames = $0 }
        .background(alignment: .topLeading) {
            if let frame = frames[AnyHashable(selection.id)] {
                let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                shape.fill(Theme.primary)
                    .overlay(shape.inset(by: 1).fill(Theme.primary.glossed(small: true)))
                    .overlay(shape.strokeBorder(Theme.primaryBorder, lineWidth: 1))
                    .overlay(shape.glossRing())
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .fill(Theme.tabsTrack)
        )
        .animation(.smooth(duration: 0.22), value: selection)
    }
}

private struct TabFramePreference: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Select trigger (select.tsx, size=lg)

/// Label for a `Menu` styled like the library's SelectTrigger.
struct SelectTriggerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Theme.font(14))
                .foregroundStyle(Theme.foreground)
            Icon(name: "caret-down", size: 16, fallback: "chevron.down")
                .foregroundStyle(Theme.mutedForeground)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .strokeBorder(Theme.input, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .pointingHandCursor()
    }
}

// MARK: - Card / GroupBox

struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(Theme.font(14, .medium))
                .foregroundStyle(Theme.foreground)
            configuration.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

extension GroupBoxStyle where Self == CardGroupBoxStyle {
    static var card: CardGroupBoxStyle { CardGroupBoxStyle() }
}

// MARK: - Progress (progress.tsx + Figma 23:599)

/// 8pt track, 2pt corners. Indicator is primary + primary-border + small gloss.
struct ThemedProgress: View {
    var fraction: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        GeometryReader { geo in
            let width = geo.size.width * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                shape.fill(Theme.tabsTrack)
                if width > 0 {
                    shape.fill(Theme.primary)
                        .overlay(shape.inset(by: 1).fill(Theme.primary.glossed(small: true)))
                        .overlay(shape.strokeBorder(Theme.primaryBorder, lineWidth: 1))
                        .overlay(shape.glossRing())
                        .frame(width: width)
                }
            }
        }
        .frame(height: 8)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1)) * 100)) percent")
    }
}

// MARK: - Window chrome

/// Paints the titlebar with the theme background so the window reads as one
/// surface, like the Figma frame.
struct WindowChrome: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(nsView)
    }

    private func apply(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.appearance = NSApp.appearance
            window.backgroundColor = Theme.backgroundNSColor
        }
    }
}

/// Applies the persisted light/dark setting to SwiftUI and AppKit.
struct AppearanceGate: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue

    func body(content: Content) -> some View {
        let appearance = AppAppearance(rawValue: appearanceRaw) ?? .dark
        content
            .preferredColorScheme(appearance.colorScheme)
            .onAppear { appearance.apply() }
            .onChange(of: appearanceRaw) { _, _ in
                (AppAppearance(rawValue: appearanceRaw) ?? .dark).apply()
            }
    }
}

extension View {
    func themedAppearance() -> some View {
        modifier(AppearanceGate())
    }
}
