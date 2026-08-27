import SwiftUI

// The editor's toolbar (Figma 93:1064), above the timeline. It edits the
// moment under the playhead — the zoom level in effect there and whether
// the camera follows the cursor or holds a pinned viewport — and both of
// those controls come alive inside a zoom's hold and grey out elsewhere.
// Then an overflow menu and, behind a hairline, the AI editor, Send
// timestamp to chat, Compare, and Export with zooms. Timing is edited by
// dragging the timeline, so there is deliberately little to set by hand:
// the AI editor does the editorial work.
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

    /// The level keyframe in effect at the playhead inside zoom `index`: a
    /// step's level once it has eased in, else the zoom's own. nil while a
    /// step is still easing, when there is nothing to edit.
    func levelBinding(in index: Int) -> Binding<Double>? {
        let seg = segments[index]
        guard !isMidStep(in: seg) else { return nil }
        if let s = activeStepIndex(in: seg) { return $segments[index].steps[s].zoom }
        return $segments[index].zoom
    }

    /// The level at the playhead: editable inside a hold, else the camera's
    /// interpolated level, read-only.
    var playheadLevel: (value: Binding<Double>, editable: Bool) {
        guard let i = holdIndexAtPlayhead, let level = levelBinding(in: i) else {
            return (.constant(camera(at: currentTime).zoom), false)
        }
        return (level, true)
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

    // MARK: - The row

    var controls: some View {
        let level = playheadLevel
        return HStack(spacing: 8) {
            IconTabsPicker(
                items: Array(ViewMode.allCases),
                selection: $viewMode,
                icon: { $0 == .preview ? "image-duotone" : "bounding-box" },
                fallback: { $0 == .preview ? "photo" : "viewfinder" },
                label: { $0 == .preview
                    ? "Preview: play the zooms as they will export"
                    : "Crop box: see where the camera looks on the full frame; drag a pinned box to move it, its corners to change the level" }
            )
            .disabled(aiChat.running)
            LevelStepper(level: level.value, range: Self.zoomRange)
                .disabled(!level.editable || aiChat.running)
                .tooltip(levelHelp)
            pinControl
                .disabled(aiChat.running)
            moreMenu
                .disabled(aiChat.running)
            toolbarDivider
            Button {
                withAnimation { showAIPanel.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if aiChat.running { ThemedSpinner() }
                    Text("AI editor")
                }
            }
            .buttonStyle(.themed(showAIPanel ? .primary : .outline, size: .md))
            .tooltip(showAIPanel
                  ? "Hide the AI editor"
                  : "Open the AI editor: hand the plan to Claude Code or Codex for an editorial pass")
            Button {
                aiAttachedTime = currentTime
                if !showAIPanel { withAnimation { showAIPanel = true } }
            } label: {
                Text("Send timestamp to chat")
            }
            .buttonStyle(.themed(.outline, size: .md))
            .disabled(aiChat.running)
            .tooltip("Attach the playhead's moment (\(shortTimecode(currentTime))) to your next note so the agent knows exactly where you mean")
            Button {
                setComparing(!comparing)
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "rows", size: 16, fallback: "rectangle.split.1x2")
                    Text("Compare")
                }
            }
            .buttonStyle(.themed(comparing ? .primary : .outline, size: .md, leadingIcon: true))
            .disabled(!comparing && planDiff == nil)
            .tooltip(comparing
                  ? "Back to the normal preview"
                  : "Play the edited zooms before and after your changes, stacked top and bottom")
            if let fraction = model.exportProgress[folder] {
                ExportProgressControls(fraction: fraction, width: 200) {
                    model.cancelExport(recording)
                }
            } else {
                Button {
                    recording.savePlan(segments, cursorStyle: cursorStyle)
                    model.export(recording)
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: "export-duotone", size: 16, fallback: "square.and.arrow.up")
                        Text("Export with zooms")
                    }
                }
                .buttonStyle(.themed(.outline, size: .md, leadingIcon: true))
                .tooltip("Render the zoom plan to a new \(model.exportFormat.rawValue) file next to the master. Earlier exports are kept.")
            }
            Spacer(minLength: 0)
        }
        .frame(height: ControlSizeToken.md.height)
    }

    /// Hairline between toolbar clusters (Figma 93:1066).
    var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.input)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    // MARK: - Pin viewport

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
                ToolbarField(text: shortTimecode(currentTime))
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

    // MARK: - Overflow menu

    /// The ⋮ menu: the cursor style and the plan-level actions that don't
    /// need a button of their own.
    var moreMenu: some View {
        DropdownButton(
            id: "editor.more",
            style: { _ in .themed(.outline, size: .md, iconOnly: true) },
            items: { moreItems() }
        ) { _ in
            Icon(name: "dots-three-outline-vertical", size: 16, fallback: "ellipsis")
        }
        .tooltip("More: cursor style, add or remove a zoom, reset all")
    }

    func moreItems() -> [DropdownItem] {
        var items: [DropdownItem] = CursorStyle.allCases.map { style in
            DropdownItem(id: "cursor.\(style.rawValue)", label: style.label,
                         checked: style == cursorStyle, detail: style.detail) {
                cursorStyle = style
            }
        }
        if let i = holdIndexAtPlayhead {
            items.append(DropdownItem(id: "remove", label: "Remove this zoom") {
                guard segments.indices.contains(i) else { return }
                segments.remove(at: i)
            })
        } else {
            items.append(DropdownItem(id: "add", label: "Add a zoom here",
                                      detail: "A 2s zoom at the playhead; the camera follows the cursor") {
                addZoom(at: currentTime)
            })
        }
        items.append(DropdownItem(id: "reset", label: "Reset all zooms",
                                  detail: "Regenerate from the click log; Compare keeps your edits") {
            resetZoomsToDefault()
        })
        return items
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
