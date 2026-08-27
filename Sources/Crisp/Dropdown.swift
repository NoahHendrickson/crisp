import SwiftUI

// The dropdown subsystem (Figma 29:4731): the menu card, the trigger button,
// and the per-window host that positions and dismisses the open menu. Split
// out of ThemeControls so the control catalog there stays a catalog.
//
// `header` is type-erased (`AnyView`) on purpose: the open menu is rebuilt by
// the host from a preference value, and a preference dictionary can't carry a
// generic view type per entry.

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
    private let minWidth: CGFloat = 149
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
