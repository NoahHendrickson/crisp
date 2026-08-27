import SwiftUI
import AppKit

/// Control styles mirrored from noey-ui (button.tsx, tabs.tsx, select.tsx,
/// progress.tsx) and the Crisp v1 Figma (43:5307). Tokens live in Theme.swift.

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
/// keep the arrow.
///
/// Driven by SwiftUI hover rather than AppKit cursor rects: a cursor-rect
/// view under SwiftUI content never receives cursor-update events (the
/// hosting view hit-tests everything itself), so rects silently do nothing.
/// Every hovered control registers with `PointerCursor`, which sets the
/// hand while any control is hovered and puts the arrow back when none is
/// — so nested clickables, controls that vanish mid-hover and disabled
/// states can't strand the cursor. The hand is re-asserted on each mouse
/// move because the hosting view resets to the arrow on its own.
extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

/// The set of controls currently under the pointer.
@MainActor
enum PointerCursor {
    private static var hovered = Set<UUID>()

    static func enter(_ id: UUID) {
        hovered.insert(id)
        if NSCursor.current != NSCursor.pointingHand { NSCursor.pointingHand.set() }
    }

    static func reassert(_ id: UUID) {
        guard hovered.contains(id), NSCursor.current != NSCursor.pointingHand else { return }
        NSCursor.pointingHand.set()
    }

    static func exit(_ id: UUID) {
        guard hovered.remove(id) != nil, hovered.isEmpty else { return }
        NSCursor.arrow.set()
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard isEnabled else { return }
                    if inside {
                        PointerCursor.reassert(id)
                    } else {
                        inside = true
                        PointerCursor.enter(id)
                    }
                case .ended:
                    guard inside else { return }
                    inside = false
                    PointerCursor.exit(id)
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, inside {
                    inside = false
                    PointerCursor.exit(id)
                }
            }
            .onDisappear {
                if inside {
                    inside = false
                    PointerCursor.exit(id)
                }
            }
    }
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
    case primary, outline, secondary, ghost, link
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
            case .link: return .clear
            }
        }

        private var foreground: Color {
            switch style.variant {
            case .primary: return style.tint == nil ? Theme.background : Theme.primaryForeground
            case .outline, .ghost, .secondary: return Theme.foreground
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

