import SwiftUI

// What the toolbar edits at the playhead: the zoom level in effect there
// and whether the camera follows the cursor or holds a pinned viewport.
// Both come alive inside a zoom's hold and grey out elsewhere. Timing is
// edited by dragging the timeline, so there is deliberately little to set
// by hand — the AI editor does the editorial work.
extension EditorView {
    // MARK: - Where the playhead is

    /// The zoom whose hold (start…end) the playhead is in.
    var holdIndexAtPlayhead: Int? {
        segments.firstIndex {
            currentTime >= $0.start - Self.keyframeSlop && currentTime <= $0.end + Self.keyframeSlop
        }
    }

    /// The pin whose window contains the playhead.
    func pinIDAtPlayhead(in seg: ZoomSegment) -> UUID? {
        pinWindows(for: seg).first {
            currentTime >= $0.from - Self.keyframeSlop && currentTime <= $0.until + Self.keyframeSlop
        }?.id
    }

    /// A pin still waiting for its release (`until == nil`): it holds to
    /// the end of the zoom until Unpin closes it, and no other pin can be
    /// started in that zoom meanwhile.
    func openPin(in seg: ZoomSegment) -> PinWindow? {
        seg.pins.first { $0.until == nil }
    }

    // MARK: - Level

    /// The level in effect at the playhead, editable only inside a hold and
    /// not mid-way through a step's ease: the step's level once one has
    /// eased in, else the zoom's own. Elsewhere it is the camera's
    /// interpolated level, read-only.
    var playheadLevel: (value: Binding<Double>, editable: Bool) {
        guard let i = holdIndexAtPlayhead, !isMidStep(in: segments[i]) else {
            return (.constant(camera(at: currentTime).zoom), false)
        }
        if let s = activeStepIndex(in: segments[i]) {
            return ($segments[i].steps[s].zoom, true)
        }
        return ($segments[i].zoom, true)
    }

    var levelHelp: String {
        if playheadLevel.editable {
            return "Zoom level from here on — the crop box corners set it too"
        }
        return holdIndexAtPlayhead == nil
            ? "Zoom level here — park the playhead inside a zoom to change it"
            : "The level is changing here"
    }

    // MARK: - Pin cycle

    /// What the pin control does at the playhead. Pin starts a pin here —
    /// the framing the follower has at this moment, held to the end of the
    /// zoom until released; Unpin closes the zoom's open pin here. Pins are
    /// added one cycle at a time: Pin, scrub ahead, Unpin.
    enum PinMove { case pin, unpin }

    var pinMove: PinMove {
        guard let i = holdIndexAtPlayhead, openPin(in: segments[i]) != nil else { return .pin }
        return .unpin
    }

    var pinMoveEnabled: Bool {
        guard let i = holdIndexAtPlayhead else { return false }
        let seg = segments[i]
        switch pinMove {
        case .pin: return pinIDAtPlayhead(in: seg) == nil && currentTime <= seg.end - 0.1
        case .unpin: return true
        }
    }

    var pinHelp: String {
        guard let i = holdIndexAtPlayhead else {
            return "Park the playhead inside a zoom to pin the viewport there"
        }
        let seg = segments[i]
        switch pinMove {
        case .pin:
            if pinIDAtPlayhead(in: seg) != nil {
                return "The viewport is already pinned here — drag the orange band's edges on the timeline to change when"
            }
            if currentTime > seg.end - 0.1 { return "Too close to the end of this zoom to pin" }
            return "Hold the viewport where the camera is right now, from here to the end of this zoom. Scrub ahead and Unpin where it should follow the cursor again; drag the crop box to move the pinned spot"
        case .unpin:
            let from = openPin(in: seg)?.from ?? seg.start
            return currentTime <= from + 0.1
                ? "Drop this pin"
                : "Let the camera follow the cursor again from here"
        }
    }

    func pinViewport() {
        guard let i = holdIndexAtPlayhead, pinMove == .pin, pinMoveEnabled else { return }
        let seg = segments[i]
        let t = currentTime
        let center = camera(at: t).center
        segments[i].pins.append(PinWindow(
            x: center.x, y: center.y,
            from: t <= seg.start + 0.1 ? nil : t
        ))
    }

    func unpinViewport() {
        guard let i = holdIndexAtPlayhead, let open = openPin(in: segments[i]),
              let p = segments[i].pins.firstIndex(where: { $0.id == open.id }) else { return }
        let seg = segments[i]
        let from = open.from ?? seg.start
        if currentTime <= from + 0.1 {
            segments[i].pins.remove(at: p)
        } else {
            segments[i].pins[p].until = min(currentTime, seg.end)
        }
    }

    // MARK: - Toolbar groups

    /// "Pin viewport at 0:42" (Figma 93:746): one button whose small square
    /// carries the action and whose well shows the playhead's time.
    var pinControl: some View {
        let move = pinMove
        let enabled = pinMoveEnabled
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        return Button {
            switch move {
            case .pin: pinViewport()
            case .unpin: unpinViewport()
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Icon(name: move == .pin ? "plus" : "x", size: 16, fallback: move == .pin ? "plus" : "xmark")
                        .foregroundStyle(Theme.foreground)
                        .frame(width: 28, height: 28)
                        .background {
                            shape.fill(Theme.background)
                                .overlay(shape.strokeBorder(Theme.input, lineWidth: 1))
                        }
                    Text(move == .pin ? "Pin viewport at" : "Unpin viewport at")
                        .font(Theme.font(.label12))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .padding(.leading, 2)
                ToolbarField(text: timecodeShort(currentTime))
                    .padding(.trailing, 1)
            }
            .frame(height: ControlSizeToken.md.height)
            .background(shape.fill(Theme.iconTabsList))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .tooltip(pinHelp)
    }
}

/// "Zoom  −  1.8×  +" (Figma 93:697): a muted group with the level in a
/// well between two 12pt steppers, in tenths, clamped to the editor's range.
struct LevelStepper: View {
    @Binding var level: Double
    let range: ClosedRange<Double>
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Text("Zoom")
                .font(Theme.font(.label12))
                .foregroundStyle(Theme.mutedForeground)
                .padding(.horizontal, 8)
            HStack(spacing: 4) {
                step(icon: "minus", fallback: "minus", help: "Zoom out a little",
                     disabled: level <= range.lowerBound + 0.001) {
                    level = max(range.lowerBound, ((level - 0.1) * 10).rounded() / 10)
                }
                ToolbarField(text: String(format: "%.1f×", level), width: 40)
                step(icon: "plus", fallback: "plus", help: "Zoom in a little",
                     disabled: level >= range.upperBound - 0.001) {
                    level = min(range.upperBound, ((level + 0.1) * 10).rounded() / 10)
                }
            }
            .padding(.horizontal, 7)
        }
        .frame(height: ControlSizeToken.md.height)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(Theme.iconTabsList))
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func step(icon: String, fallback: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 12, fallback: fallback)
                .foregroundStyle(Theme.foreground)
                .frame(width: 16, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .tooltip(help)
    }
}

/// A read-only value well inside a toolbar group (Figma 93:745): paper
/// with a foreground@24 hairline, 28pt, Body/12.
struct ToolbarField: View {
    let text: String
    var width: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd - 1, style: .continuous)
        Text(text)
            .font(Theme.font(.body12))
            .monospacedDigit()
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 8)
            .frame(width: width, height: 28)
            .background {
                shape.fill(Theme.background)
                    .overlay(shape.strokeBorder(Theme.fieldBorder, lineWidth: 1))
            }
    }
}
