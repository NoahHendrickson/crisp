import SwiftUI
import AppKit

/// Control styles mirrored from noey-ui (button.tsx, tabs.tsx, select.tsx,
/// progress.tsx). Tokens live in Theme.swift.

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

/// The primary "glossed pill": fill, inset gloss, 1px border and the gloss
/// highlight ring. Used by primary buttons, the active tab and the
/// progress indicator.
struct PrimaryChrome<S: InsettableShape>: View {
    let shape: S
    var fill: Color = Theme.primary
    var border: Color = Theme.primaryBorder
    var small = false

    var body: some View {
        shape.fill(fill)
            .overlay(shape.inset(by: 1).fill(fill.glossed(small: small)))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .overlay(shape.glossRing())
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
                        PrimaryChrome(shape: shape, fill: fill, border: borderColor)
                    } else {
                        shape.fill(fill)
                            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
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
                PrimaryChrome(
                    shape: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous),
                    small: true
                )
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
                    PrimaryChrome(shape: shape, small: true)
                        .frame(width: width)
                }
            }
        }
        .frame(height: 8)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1)) * 100)) percent")
    }
}

/// Progress bar + percentage + cancel button shown while an export runs.
/// Shared by the recordings list and the editor toolbar.
struct ExportProgressControls: View {
    var fraction: Double
    var onCancel: () -> Void
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            ThemedProgress(fraction: fraction)
            Text("\(Int(fraction * 100))%")
                .font(Theme.font(11, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .frame(width: 28)
            Button(action: onCancel) {
                Icon(name: "stop-fill", size: 16, fallback: "stop.fill")
                    .foregroundStyle(Theme.destructive)
            }
            .buttonStyle(.themed(.outline, size: .sm, iconOnly: true))
            .help("Cancel export")
        }
        .frame(width: width)
    }
}
