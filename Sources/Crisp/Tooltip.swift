import SwiftUI
import AppKit

// MARK: - Tooltip
//
// Custom hover tooltips styled like `DropdownMenu` (card fill, 1px input
// border, 8pt radius, md shadow, Body/12) so they don't look foreign next
// to the rest of the chrome. `.tooltip("…")` replaces `.help("…")`: it keeps
// the accessibility help text, but the visible bubble is drawn by the nearest
// `.tooltipHost()` instead of the system tooltip window.

/// Which tooltip (by id) is showing in a window. Owned by `.tooltipHost()`.
@MainActor
final class TooltipState: ObservableObject {
    @Published var active: String?
    private var showTask: Task<Void, Never>?
    private var hiddenAt: Date?

    /// Delay before a tooltip appears; skipped when one was just showing so
    /// moving along a toolbar switches tooltips immediately.
    static let delay: Duration = .milliseconds(550)
    static let handoff: TimeInterval = 0.35

    func hover(_ id: String, entering: Bool) {
        showTask?.cancel()
        if entering {
            if let hiddenAt, Date().timeIntervalSince(hiddenAt) < Self.handoff {
                active = id
                return
            }
            showTask = Task { [weak self] in
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled, let self else { return }
                self.active = id
            }
        } else if active == id {
            hide()
        }
    }

    func hide() {
        showTask?.cancel()
        if active != nil { hiddenAt = Date() }
        active = nil
    }
}

struct TooltipSpec {
    let anchor: Anchor<CGRect>
    let text: String
}

struct TooltipPreference: PreferenceKey {
    static var defaultValue: [String: TooltipSpec] = [:]
    static func reduce(value: inout [String: TooltipSpec], nextValue: () -> [String: TooltipSpec]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct TooltipStateKey: EnvironmentKey {
    static let defaultValue: TooltipState? = nil
}

extension EnvironmentValues {
    var tooltipState: TooltipState? {
        get { self[TooltipStateKey.self] }
        set { self[TooltipStateKey.self] = newValue }
    }
}

/// Registers a hover tooltip. Falls back to nothing visible (accessibility
/// help only) when no `.tooltipHost()` is above the view.
private struct TooltipModifier: ViewModifier {
    let text: String
    @Environment(\.tooltipState) private var state
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { state?.hover(id, entering: $0) }
            .onDisappear { if state?.active == id { state?.hide() } }
            .anchorPreference(key: TooltipPreference.self, value: .bounds) {
                [id: TooltipSpec(anchor: $0, text: text)]
            }
    }
}

extension View {
    /// Themed replacement for `.help(_:)`. The bubble sits below the view,
    /// or above it when there is no room.
    func tooltip(_ text: String) -> some View {
        modifier(TooltipModifier(text: text))
    }
}

/// The bubble: the dropdown card's fill, border, radius and shadow at
/// tooltip size.
struct TooltipBubble: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        FitWidth(maxWidth: 280) {
            Text(text)
                .font(Theme.font(.body12))
                .foregroundStyle(Theme.foreground)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(Theme.input, lineWidth: 1))
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 4)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 2)
        .fixedSize()
    }
}

/// Wrap-and-hug: propose `maxWidth` when SwiftUI asks for ideal size so
/// multiline `Text` reports its wrapped height. `Text.fixedSize()` is the
/// unwrapped line, so `frame(maxWidth:)` after it clips the extra lines.
private struct FitWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return child.sizeThatFits(.init(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: .init(bounds.size))
    }
}

/// Hosts a window's tooltips: owns the hover state and draws the active
/// bubble next to its anchor, clamped to the window. Apply to a window's
/// root view, inside `.dropdownHost()` so menus draw above tooltips and
/// opening one dismisses them.
private struct TooltipHost: ViewModifier {
    @StateObject private var state = TooltipState()
    @EnvironmentObject private var dropdowns: DropdownState
    @State private var clickMonitor: Any?

    private static let gap: CGFloat = 4
    private static let margin: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .environment(\.tooltipState, state)
            .overlayPreferenceValue(TooltipPreference.self) { specs in
                GeometryReader { geo in
                    if let id = state.active, let spec = specs[id] {
                        let rect = geo[spec.anchor]
                        let below = rect.maxY + Self.gap + 60 < geo.size.height
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            TooltipBubble(text: spec.text)
                                .alignmentGuide(.leading) { d in
                                    let x = rect.midX - d.width / 2
                                    let clamped = min(max(x, Self.margin), geo.size.width - d.width - Self.margin)
                                    return -clamped
                                }
                                .alignmentGuide(.top) { d in
                                    below ? -(rect.maxY + Self.gap) : d[.bottom] - (rect.minY - Self.gap)
                                }
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: state.active)
            }
            .onChange(of: dropdowns.open) { _, open in
                if open != nil { state.hide() }
            }
            .onAppear {
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    state.hide()
                    return event
                }
            }
            .onDisappear {
                if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                clickMonitor = nil
            }
    }
}

extension View {
    func tooltipHost() -> some View { modifier(TooltipHost()) }
}
