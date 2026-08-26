import SwiftUI
import AppKit

/// Control styles mirrored from noey-ui (button.tsx, tabs.tsx, select.tsx,
/// progress.tsx) and the Crisp v1 Figma (43:5307). Tokens live in Theme.swift.

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

/// The blue "glossed pill": fill, inset gloss, 1px border and the gloss
/// highlight ring. Only the editor timeline's hold bar still uses it.
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

// MARK: - Raised surface (--shadow-raised)

extension View {
    /// Figma "Shadow/raised": two soft drop shadows cast to the right
    /// (2px 0 8px black@8 + 3px 0 12px black@12). CSS blur ≈ 2× SwiftUI radius.
    func raisedShadow() -> some View {
        self.shadow(color: Theme.raisedShadowNear, radius: 4, x: 2, y: 0)
            .shadow(color: Theme.raisedShadowFar, radius: 6, x: 3, y: 0)
    }
}

/// The library's raised surface: `raised` fill, 1px `raisedBorder`, raised
/// shadow. Used by the progress indicator.
struct RaisedChrome<S: InsettableShape>: View {
    let shape: S
    var fill: Color = Theme.raised

    var body: some View {
        shape.fill(fill)
            .overlay(shape.strokeBorder(Theme.raisedBorder, lineWidth: 1))
            .raisedShadow()
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
    /// Label style from the shared type ramp (Noey UI Label/12, Label/14):
    /// compact controls use Label/12, default and large use Label/14.
    var textStyle: Theme.TextStyle {
        switch self { case .xs, .sm: .label12; case .md, .lg: .label14 }
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
    /// Overrides the primary fill (e.g. the red Record button).
    var tint: Color? = nil

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
                cornerRadii: style.corners ?? .all(Theme.radiusMd), style: .continuous
            )
            let size = style.size
            configuration.label
                .font(Theme.font(size.textStyle))
                .foregroundStyle(foreground)
                .padding(.leading, style.iconOnly ? 0 : (style.leadingIcon ? size.iconSidePadding : size.horizontalPadding))
                .padding(.trailing, style.iconOnly ? 0 : (style.trailingIcon ? size.iconSidePadding : size.horizontalPadding))
                .frame(width: style.iconOnly ? size.height : nil, height: size.height)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .background {
                    shape.fill(fill)
                        .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                }
                .contentShape(shape)
                .offset(y: configuration.isPressed ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.5)
                .pointingHandCursor()
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        // button.tsx: default is monochrome (bg-foreground text-background,
        // hover foreground/80); outline is a --border stroke on a clear fill;
        // secondary is a foreground/12 fill. No strokes elsewhere.
        private var fill: Color {
            switch style.variant {
            case .primary: return (style.tint ?? Theme.foreground).opacity(hovering ? 0.8 : 1)
            case .outline: return hovering ? Theme.outlineHover : .clear
            case .secondary: return hovering ? Theme.secondaryHover : Theme.secondary
            case .ghost: return hovering ? Theme.muted : .clear
            case .destructive: return Theme.destructive.opacity(hovering ? 0.2 : 0.1)
            case .link: return .clear
            }
        }

        private var foreground: Color {
            switch style.variant {
            case .primary: return style.tint == nil ? Theme.background : Theme.primaryForeground
            case .outline, .ghost, .secondary: return Theme.foreground
            case .destructive: return Theme.destructive
            case .link: return Theme.primary
            }
        }

        private var borderColor: Color {
            style.variant == .outline ? Theme.border : .clear
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
        tint: Color? = nil
    ) -> ThemedButtonStyle {
        ThemedButtonStyle(
            variant: variant, size: size, iconOnly: iconOnly, fullWidth: fullWidth,
            corners: corners, leadingIcon: leadingIcon, trailingIcon: trailingIcon,
            tint: tint
        )
    }
}

/// 1px join between Button Group/Split halves (Figma 49:7567): `--input`
/// over the fill, inset 2pt from the top and bottom of the button.
struct ButtonGroupSeparator: View {
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Theme.input)
            .frame(width: 1, height: max(0, height - 4))
            .zIndex(1)
    }
}

// MARK: - Tabs (tabs.tsx, variant=default)

/// Noey UI "Tabs List" (54:372 light / 54:393 dark; tabs.tsx variant=default):
/// a flush muted track (black@8 / white@12, rounded 6, no stroke) of 32pt
/// triggers (px 12, Label/12) that share the width equally (flex-1). The
/// active tab is a raised pill (paper + foreground@12 hairline in light,
/// white@24 with no border in dark, Shadow/raised) that slides between them.
struct TabsPicker<Item: Identifiable & Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    @State private var frames: [AnyHashable: CGRect] = [:]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
        HStack(spacing: 0) {
            ForEach(items) { item in
                TabTrigger(title: label(item), active: item == selection) {
                    selection = item
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabFramePreference.self,
                            value: [AnyHashable(item.id): geo.frame(in: .named("tabs"))]
                        )
                    }
                }
            }
        }
        .coordinateSpace(name: "tabs")
        .onPreferenceChange(TabFramePreference.self) { frames = $0 }
        .background(alignment: .topLeading) {
            if let frame = frames[AnyHashable(selection.id)] {
                shape.fill(Theme.tabsActive)
                    .overlay(shape.strokeBorder(Theme.tabsActiveBorder, lineWidth: 1))
                    .raisedShadow()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .background(shape.fill(Theme.tabsList))
        .clipShape(shape)
        .animation(.smooth(duration: 0.22), value: selection)
    }

    private struct TabTrigger: View {
        let title: String
        let active: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(Theme.font(.label12))
                    .foregroundStyle(active || hovering ? Theme.foreground : Theme.mutedForeground)
                    .padding(.horizontal, ControlSizeToken.md.horizontalPadding)   // px-3
                    .frame(maxWidth: .infinity)                                   // flex-1
                    .frame(height: ControlSizeToken.md.height)                    // h-8
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { hovering = $0 }
        }
    }
}

private struct TabFramePreference: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Noey UI "IconTabList" (Figma 174:925): a 32pt track of 32×32 icon tabs
/// (radius 8). The active tab is paper with a 1px track-colored hairline;
/// inactive tabs are transparent. Icons are 16pt, foreground when active
/// and text-secondary otherwise.
struct IconTabsPicker<Item: Identifiable & Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let icon: (Item) -> String
    let fallback: (Item) -> String
    let label: (Item) -> String
    @State private var frames: [AnyHashable: CGRect] = [:]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        HStack(spacing: 0) {
            ForEach(items) { item in
                IconTabTrigger(
                    name: icon(item),
                    fallback: fallback(item),
                    label: label(item),
                    active: item == selection
                ) {
                    selection = item
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabFramePreference.self,
                            value: [AnyHashable(item.id): geo.frame(in: .named("icon-tabs"))]
                        )
                    }
                }
            }
        }
        .coordinateSpace(name: "icon-tabs")
        .onPreferenceChange(TabFramePreference.self) { frames = $0 }
        .background(alignment: .topLeading) {
            if let frame = frames[AnyHashable(selection.id)] {
                shape.fill(Theme.background)
                    .overlay(shape.strokeBorder(Theme.iconTabsList, lineWidth: 1))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .background(shape.fill(Theme.iconTabsList))
        .clipShape(shape)
        .animation(.smooth(duration: 0.22), value: selection)
    }

    private struct IconTabTrigger: View {
        let name: String
        let fallback: String
        let label: String
        let active: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Icon(name: name, size: 16, fallback: fallback)
                    .foregroundStyle(active || hovering ? Theme.foreground : Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .tooltip(label)
            .accessibilityLabel(label)
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - Select trigger (select.tsx)

/// Label for a `Menu` styled like the library's SelectTrigger (Figma 158:1043).
/// Default is LG (h36, Body/14, CaretUpDown) to match Button lg.
struct SelectTriggerLabel: View {
    let text: String
    var size: ControlSizeToken = .lg
    var maxTextWidth: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
        HStack(spacing: size.gap) {
            Text(text)
                .font(Theme.font(size.height >= 32 ? .body14 : .body12))
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: maxTextWidth ?? .infinity, alignment: .leading)
            Icon(name: "caret-up-down", size: size.iconSize, fallback: "chevron.up.chevron.down")
                .foregroundStyle(Theme.mutedForeground)
        }
        .padding(.leading, size.horizontalPadding)
        .padding(.trailing, size.iconSidePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: size.height)
        .background {
            shape.fill(Theme.iconTabsList)
                .overlay(shape.strokeBorder(Theme.input, lineWidth: 1))
        }
        .contentShape(shape)
        .pointingHandCursor()
    }
}

// MARK: - Card / GroupBox

struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(Theme.font(.label12))
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

// MARK: - Progress (progress.tsx + Figma 43:5350)

/// 8pt pill track with a 1px border; the indicator is the raised surface
/// with a foreground/80 fill (per the Crisp screen), inset 1pt.
struct ThemedProgress: View {
    var fraction: Double

    var body: some View {
        let shape = Capsule(style: .continuous)
        GeometryReader { geo in
            let inner = max(0, geo.size.width - 2)
            let width = inner * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                shape.fill(Theme.track)
                    .overlay(shape.strokeBorder(Theme.trackBorder, lineWidth: 1))
                if width > 0 {
                    RaisedChrome(shape: shape, fill: Theme.foreground.opacity(0.8))
                        .frame(width: width, height: 6)
                        .offset(x: 1)
                }
            }
            .clipShape(shape)
        }
        .frame(height: 8)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1)) * 100)) percent")
    }
}

/// Slider whose track is `ThemedProgress` (8pt, 2pt corners, primary gloss).
struct ThemedSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    init(value: Binding<Double>, in range: ClosedRange<Double>) {
        self._value = value
        self.range = range
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let span = range.upperBound - range.lowerBound
            let t = span > 0 ? (value - range.lowerBound) / span : 0
            let clamped = min(max(t, 0), 1)
            ZStack(alignment: .leading) {
                ThemedProgress(fraction: clamped)
                Circle()
                    .fill(Theme.background)
                    .overlay(Circle().strokeBorder(Theme.foreground, lineWidth: 1))
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(clamped) * (w - 12))
            }
            .frame(width: w, height: 16)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let p = min(max(g.location.x / w, 0), 1)
                    value = range.lowerBound + p * span
                }
            )
        }
        .frame(height: 16)
        .accessibilityValue(Text(String(format: "%.2f", value)))
    }
}

/// Progress bar + percentage + cancel button shown while an export runs.
/// Shared by the recordings list and the editor toolbar.
struct ExportProgressControls: View {
    var fraction: Double
    var width: CGFloat? = nil
    /// Cancel button size: `.sm` in the editor toolbar, `.md` in the library
    /// sidebar (Figma 76:12347).
    var size: ControlSizeToken = .sm
    /// Library cancel is an X on a ghost 32pt button; the editor keeps outline + stop.
    var cancelIcon: String = "stop-duotone"
    var cancelVariant: ButtonVariant = .outline
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ThemedProgress(fraction: fraction)
            Text("\(Int(fraction * 100))%")
                .font(Theme.font(.label12))
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .frame(width: 28)
            Button(action: onCancel) {
                Icon(name: cancelIcon, size: size == .xs ? 12 : 16, fallback: "xmark")
            }
            .buttonStyle(.themed(cancelVariant, size: size, iconOnly: true))
            .tooltip("Cancel export")
        }
        .frame(width: width)
    }
}

// MARK: - Dropdown menu (Figma 29:4731)

/// One row of a `DropdownMenu`. The host closes the menu after `action`.
struct DropdownItem: Identifiable {
    let id: String
    var label: String
    var checked = false
    var detail: String? = nil
    /// When true, the row uses the source-picker layout (60×40 thumbnail).
    var showsThumbnail = false
    var thumbnail: CGImage? = nil
    /// SF Symbol drawn in the thumbnail slot when there is no thumbnail.
    var placeholderSymbol: String? = nil
    var action: () -> Void
}

/// What a `DropdownMenu` shows instead of rows when it has nothing to list
/// (loading, empty, or an error), optionally with one action.
struct DropdownPlaceholder {
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

/// The library's dropdown panel: white card, 1px input border, 8px radius,
/// 8px padding and the md shadow; 32pt rows, 14pt regular, with a 16pt
/// primary check on the selected row. Source pickers (`showsThumbnail`) use
/// the Figma Select Menu (158:1079): 4pt padding, 60×40 thumbs, 18pt check.
/// Shown by `DropdownButton` through the nearest `.dropdownHost()`.
struct DropdownMenu: View {
    let items: [DropdownItem]
    var minWidth: CGFloat = 149
    /// Drawn above the rows (e.g. a `TabsPicker` switching between lists).
    var header: AnyView? = nil
    /// Shown instead of rows when there is nothing to list.
    var placeholder: DropdownPlaceholder? = nil
    /// Use the source-picker layout (307pt, thumbnail rows) even with no rows.
    var wide = false

    private var isThumbnail: Bool { wide || items.contains(where: \.showsThumbnail) }
    private static let maxRowsHeight: CGFloat = 360

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        VStack(spacing: 4) {
            if let header {
                header
            }
            if items.isEmpty, let placeholder {
                placeholderView(placeholder)
            } else {
                rows
            }
        }
        .padding(isThumbnail ? 4 : 6)
        .frame(minWidth: isThumbnail ? 307 : minWidth, alignment: .leading)
        .frame(width: isThumbnail ? 307 : nil)
        .frame(height: isThumbnail && !items.isEmpty ? thumbnailHeight : nil, alignment: .top)
        .background(shape.fill(isThumbnail ? Theme.background : Theme.card))
        .overlay(shape.strokeBorder(Theme.input, lineWidth: 1))
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 4)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 2)
    }

    /// 52pt rows + 1pt gaps.
    private var rowsHeight: CGFloat {
        let n = CGFloat(items.count)
        return n * 52 + max(0, n - 1)
    }

    /// 32pt tabs + the stack gap.
    private var headerHeight: CGFloat { header == nil ? 0 : ControlSizeToken.md.height + 4 }

    /// 4pt padding + header + rows (capped, then scrolling).
    private var thumbnailHeight: CGFloat {
        8 + headerHeight + min(rowsHeight, Self.maxRowsHeight)
    }

    @ViewBuilder
    private var rows: some View {
        let stack = VStack(spacing: isThumbnail ? 1 : 0) {
            ForEach(items) { item in
                if isThumbnail {
                    ThumbnailRow(item: item)
                } else {
                    DropdownRow(item: item)
                }
            }
        }
        if isThumbnail {
            ScrollView(.vertical, showsIndicators: rowsHeight > Self.maxRowsHeight) {
                stack.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            stack
        }
    }

    private func placeholderView(_ placeholder: DropdownPlaceholder) -> some View {
        VStack(spacing: 10) {
            Text(placeholder.text)
                .font(Theme.font(.body12))
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let title = placeholder.actionTitle, let action = placeholder.action {
                Button(title, action: action)
                    .buttonStyle(.themed(.outline, size: .xs))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 72)
    }

    /// Figma Select Item (158:1091): 60×40 thumb, Body/12 label (same as other selects).
    private struct ThumbnailRow: View {
        let item: DropdownItem
        @State private var hovering = false

        var body: some View {
            Button(action: item.action) {
                HStack(spacing: 6) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(Theme.font(.body12))
                            .foregroundStyle(Theme.foreground)
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(Theme.font(.body12))
                                .foregroundStyle(Theme.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if item.checked {
                        Icon(name: "check", size: 16, fallback: "checkmark")
                            .foregroundStyle(Theme.primaryBorder)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? Theme.muted : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .pointingHandCursor()
            .onHover { hovering = $0 }
        }

        private var thumbnail: some View {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            return Group {
                if let image = item.thumbnail {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    shape.fill(Theme.panel)
                        .overlay {
                            if let symbol = item.placeholderSymbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.mutedForeground)
                            }
                        }
                }
            }
            .frame(width: 60, height: 40)
            .clipShape(shape)
        }
    }

    private struct DropdownRow: View {
        let item: DropdownItem
        @State private var hovering = false

        var body: some View {
            Button(action: item.action) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(Theme.font(.body12))
                            .foregroundStyle(Theme.foreground)
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(Theme.font(.body12))
                                .foregroundStyle(Theme.mutedForeground)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if item.checked {
                        Icon(name: "check", size: 16, fallback: "checkmark")
                            .foregroundStyle(Theme.primaryBorder)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, item.detail == nil ? 0 : 6)
                .frame(minHeight: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .fill(hovering ? Theme.muted : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { hovering = $0 }
        }
    }
}

/// Which dropdown (by id) is open in a window. Owned by `.dropdownHost()`.
@MainActor
final class DropdownState: ObservableObject {
    @Published var open: String?

    func toggle(_ id: String) { open = open == id ? nil : id }
}

/// Where a trigger wants its menu: above or below, aligned to its leading or
/// trailing edge, plus the items to show.
struct DropdownSpec {
    let anchor: Anchor<CGRect>
    let edge: VerticalEdge
    let alignment: HorizontalAlignment
    let header: (() -> AnyView)?
    let placeholder: (() -> DropdownPlaceholder?)?
    let wide: Bool
    let items: () -> [DropdownItem]
}

struct DropdownPreference: PreferenceKey {
    static var defaultValue: [String: DropdownSpec] = [:]
    static func reduce(value: inout [String: DropdownSpec], nextValue: () -> [String: DropdownSpec]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// A button that opens a `DropdownMenu` (4pt from the trigger, per Figma).
/// `style` gets `isOpen` so a trigger can show an open state; nil renders
/// the label as-is (`.plain`).
struct DropdownButton<Label: View>: View {
    let id: String
    var edge: VerticalEdge = .bottom
    var alignment: HorizontalAlignment = .leading
    var style: ((Bool) -> ThemedButtonStyle)?
    /// Optional view above the menu's rows (see `DropdownMenu.header`).
    var header: (() -> AnyView)? = nil
    /// Shown when `items` is empty (see `DropdownMenu.placeholder`).
    var placeholder: (() -> DropdownPlaceholder?)? = nil
    /// Keep the wide thumbnail layout even when `items` is empty.
    var wide = false
    let items: () -> [DropdownItem]
    @ViewBuilder let label: (Bool) -> Label

    @EnvironmentObject private var dropdowns: DropdownState

    var body: some View {
        let isOpen = dropdowns.open == id
        let button = Button {
            dropdowns.toggle(id)
        } label: {
            label(isOpen)
        }
        Group {
            if let style {
                button.buttonStyle(style(isOpen))
            } else {
                button.buttonStyle(.plain).pointingHandCursor()
            }
        }
        .anchorPreference(key: DropdownPreference.self, value: .bounds) {
            [id: DropdownSpec(anchor: $0, edge: edge, alignment: alignment,
                              header: header, placeholder: placeholder, wide: wide, items: items)]
        }
    }
}

/// Hosts the window's dropdowns: owns the open state, draws the open menu
/// next to its trigger, and dismisses on click-away or Escape. Apply to a
/// window's root view.
private struct DropdownHost: ViewModifier {
    @StateObject private var state = DropdownState()

    func body(content: Content) -> some View {
        content
            .environmentObject(state)
            .overlayPreferenceValue(DropdownPreference.self) { specs in
                GeometryReader { geo in
                    if let id = state.open, let spec = specs[id] {
                        let rect = geo[spec.anchor]
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { state.open = nil }
                            DropdownMenu(
                                items: spec.items().map { item in
                                    var closing = item
                                    closing.action = { item.action(); state.open = nil }
                                    return closing
                                },
                                header: spec.header?(),
                                placeholder: spec.placeholder?(),
                                wide: spec.wide
                            )
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                spec.alignment == .trailing ? d[.trailing] - rect.maxX : -rect.minX
                            }
                            .alignmentGuide(.top) { d in
                                spec.edge == .top ? d[.bottom] - (rect.minY - 4) : -(rect.maxY + 4)
                            }
                        }
                        .onExitCommand { state.open = nil }
                    }
                }
            }
    }
}

extension View {
    func dropdownHost() -> some View { modifier(DropdownHost()) }
}

// MARK: - Hatch

/// Diagonal stripes used on the timeline to mark automatic (non-editable)
/// camera phases. Draws over the view's frame; clip to shape as needed.
struct Hatch: View {
    var color: Color
    var spacing: CGFloat = 7
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let span = size.width + size.height
            var offset: CGFloat = -size.height
            while offset < span {
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += spacing
            }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }
}
