import SwiftUI

// The editor's toolbar (Figma 93:1064), above the timeline. It edits the
// moment under the playhead — the zoom level in effect there, whether a
// zoom starts or ends there, whether the camera follows the cursor or
// holds a pinned viewport (both alive inside a zoom's hold and greyed out
// elsewhere), and whether a clip or a speed-up starts or ends there. Then an overflow menu and, behind a hairline, the AI editor,
// Send timestamp to chat, Compare, and Export. Timing is edited by
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

    // MARK: - Zoom cycle

    /// What the zoom control does at the playhead. Start opens a zoom here
    /// — it runs to the next zoom (or the end of the video) until ended;
    /// End closes the open zoom here. Zooms are added one cycle at a time:
    /// Start, scrub ahead, End; the camera follows the cursor inside it.
    enum ZoomMove { case start, end }

    /// The zoom still waiting for its end (see `openZoomID`).
    var openZoom: ZoomSegment? {
        guard let id = openZoomID else { return nil }
        return segments.first { $0.id == id }
    }

    var zoomMove: ZoomMove {
        openZoom == nil ? .start : .end
    }

    var zoomMoveEnabled: Bool {
        switch zoomMove {
        case .start: return ZoomPlanner.freeRoom(at: currentTime, in: segments, duration: duration) != nil
        case .end: return true
        }
    }

    var zoomHelp: String {
        switch zoomMove {
        case .start:
            if holdIndexAtPlayhead != nil {
                return "A zoom already covers this moment — drag its edges on the timeline to change when"
            }
            if ZoomPlanner.freeRoom(at: currentTime, in: segments, duration: duration) == nil {
                return "Too close to the neighbouring zooms to start one here"
            }
            return "Start a zoom here: it runs to the next zoom (or the end of the video) until you end it. Scrub ahead and End the zoom where the camera should pull back out; the framing follows the cursor"
        case .end:
            let start = openZoom?.start ?? 0
            return currentTime <= start + 0.1
                ? "Drop this zoom"
                : "End the zoom here — the camera holds from \(shortTimecode(start)) and pulls back out at \(shortTimecode(currentTime))"
        }
    }

    func startZoom() {
        guard zoomMove == .start, zoomMoveEnabled,
              let room = ZoomPlanner.freeRoom(at: currentTime, in: segments, duration: duration) else { return }
        let start = min(max(currentTime, room.lowerBound), room.upperBound - ZoomPlanner.minHold)
        let seg = ZoomSegment(start: start, end: room.upperBound, zoom: ZoomPlanner.Config().zoomLevel)
        segments.append(seg)
        openZoomID = seg.id
    }

    func endZoom() {
        defer { openZoomID = nil }
        guard let open = openZoom, let i = segments.firstIndex(where: { $0.id == open.id }) else { return }
        if currentTime <= open.start + 0.1 {
            segments.remove(at: i)
            return
        }
        let ceiling = ZoomPlanner.holdRoom(for: open.id, in: segments, duration: duration).upperBound
        segments[i].end = min(max(currentTime, open.start + ZoomPlanner.minHold), ceiling)
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

    // MARK: - Clip cycle

    /// What the clip control does at the playhead. Start opens a clip here
    /// — it runs to the next clip (or the end) until ended; End closes the
    /// open clip here. Clips are added one cycle at a time: Start, scrub
    /// ahead, End; each exports as a file of its own.
    enum ClipMove { case start, end }

    /// The clip still waiting for its end.
    var openClip: Clip? {
        clips.first { $0.end == nil }
    }

    var clipMove: ClipMove {
        openClip == nil ? .start : .end
    }

    /// The clip whose stretch contains the playhead.
    var clipAtPlayhead: Clip.Range? {
        clipRanges.first {
            currentTime >= $0.start - Self.keyframeSlop && currentTime <= $0.end + Self.keyframeSlop
        }
    }

    /// How far a clip started at the playhead could run: to the next clip,
    /// or the end of the video.
    var clipRoomAtPlayhead: Double {
        (clipRanges.first { $0.start > currentTime }?.start ?? duration) - currentTime
    }

    var clipMoveEnabled: Bool {
        switch clipMove {
        case .start: return clipAtPlayhead == nil && clipRoomAtPlayhead >= Clip.minLength
        case .end: return true
        }
    }

    var clipHelp: String {
        switch clipMove {
        case .start:
            if let clip = clipAtPlayhead {
                return "Clip \(clip.number) already covers this moment — drag its edges on the timeline to change when"
            }
            if clipRoomAtPlayhead < Clip.minLength { return "Too close to the end (or the next clip) to start a clip" }
            return "Start a clip here: it runs to the next clip (or the end of the video) until you end it. Scrub ahead and End the clip where it should stop. Export then offers each clip as a file of its own"
        case .end:
            let start = openClip?.start ?? 0
            return currentTime <= start + 0.1
                ? "Drop this clip"
                : "End the clip here — it will export as the footage from \(shortTimecode(start)) to \(shortTimecode(currentTime))"
        }
    }

    func startClip() {
        guard clipMove == .start, clipMoveEnabled else { return }
        clips.append(Clip(start: currentTime))
    }

    func endClip() {
        guard let open = openClip, let i = clips.firstIndex(where: { $0.id == open.id }) else { return }
        if currentTime <= open.start + 0.1 {
            clips.remove(at: i)
            return
        }
        let ceiling = clipRanges.first { $0.id == open.id }?.end ?? duration
        clips[i].end = min(currentTime, ceiling)
    }

    // MARK: - Speed cycle

    /// What the speed control does at the playhead. Start opens a speed-up
    /// here — it runs to the next one (or the end) until ended; End closes
    /// the open speed-up here. Speed-ups are added one cycle at a time:
    /// Start, scrub ahead, End; every export fast-forwards the stretch.
    enum SpeedMove { case start, end }

    /// The speed-up still waiting for its end.
    var openSpeed: SpeedWindow? {
        speeds.first { $0.end == nil }
    }

    var speedMove: SpeedMove {
        openSpeed == nil ? .start : .end
    }

    /// The speed-up whose stretch contains the playhead.
    var speedAtPlayhead: SpeedWindow.Range? {
        speedRanges.first {
            currentTime >= $0.start - Self.keyframeSlop && currentTime <= $0.end + Self.keyframeSlop
        }
    }

    /// How far a speed-up started at the playhead could run: to the next
    /// one, or the end of the video.
    var speedRoomAtPlayhead: Double {
        (speedRanges.first { $0.start > currentTime }?.start ?? duration) - currentTime
    }

    var speedMoveEnabled: Bool {
        switch speedMove {
        case .start: return speedAtPlayhead == nil && speedRoomAtPlayhead >= SpeedWindow.minLength
        case .end: return true
        }
    }

    var speedHelp: String {
        switch speedMove {
        case .start:
            if let window = speedAtPlayhead {
                return String(format: "Already speeding up %g× here — the rate button changes how much; drag the bar's edges on the timeline to change when", window.rate)
            }
            if speedRoomAtPlayhead < SpeedWindow.minLength { return "Too close to the end (or the next speed-up) to start one here" }
            return String(format: "Fast-forward from the playhead: the stretch plays %g× faster (the rate button sets how much) in every export until you end it. Scrub ahead and End the speed-up where the video should run normally again", speedRate)
        case .end:
            let start = openSpeed?.start ?? 0
            return currentTime <= start + 0.1
                ? "Drop this speed-up"
                : String(format: "End the speed-up here — %@ to %@ plays %g× faster", shortTimecode(start), shortTimecode(currentTime), openSpeed?.rate ?? SpeedWindow.defaultRate)
        }
    }

    func startSpeedUp() {
        guard speedMove == .start, speedMoveEnabled else { return }
        speeds.append(SpeedWindow(start: currentTime, rate: speedRate))
    }

    func endSpeedUp() {
        guard let open = openSpeed, let i = speeds.firstIndex(where: { $0.id == open.id }) else { return }
        if currentTime <= open.start + 0.1 {
            speeds.remove(at: i)
            return
        }
        let ceiling = speedRanges.first { $0.id == open.id }?.end ?? duration
        speeds[i].end = min(currentTime, ceiling)
    }

    // MARK: - Speed rate

    /// The speed-up the toolbar's rate button edits: the one under the
    /// playhead, else the open one still waiting for its end. nil means the
    /// button sets `speedRate`, the rate the next speed-up starts with.
    var speedRateTargetID: UUID? {
        speedAtPlayhead?.id ?? openSpeed?.id
    }

    /// What the rate button shows.
    var speedRateValue: Double {
        if let window = speedAtPlayhead { return window.rate }
        if let open = openSpeed { return open.rate }
        return speedRate
    }

    /// The rate menu: the presets, then (behind a divider) the corner-badge
    /// toggle. Picking a rate retargets the speed-up under the playhead (or
    /// the open one), else the rate the next speed-up starts with.
    func speedRateItems() -> [DropdownItem] {
        var items = SpeedWindow.rates.map { rate in
            DropdownItem(
                id: "rate.\(rate)", label: String(format: "%g× faster", rate),
                checked: abs(rate - speedRateValue) < 0.001
            ) {
                if let id = speedRateTargetID {
                    setSpeedRate(rate, for: id)
                } else {
                    speedRate = rate
                }
            }
        }
        items.append(.divider("rate.divider"))
        items.append(DropdownItem(
            id: "rate.badge", label: "Show rate on the video", checked: speedBadge,
            detail: "Draws \"2×\" in the bottom-right corner while it's sped up, in the preview and every export",
            checkbox: true, keepsOpen: true
        ) {
            speedBadge.toggle()
        })
        return items
    }

    var speedRateHelp: String {
        speedRateTargetID != nil
            ? "How much faster this speed-up plays — click to choose the rate, or to badge it on the video"
            : "How much faster the next speed-up plays — click to choose the rate, or to badge it on the video"
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
            zoomControl(level: level)
                .disabled(aiChat.running)
            pinControl
                .disabled(aiChat.running)
            clipControl
                .disabled(aiChat.running)
            speedControl
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
            } else if clipRanges.isEmpty {
                Button {
                    savePlanNow()
                    model.export(recording)
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: "export-duotone", size: 16, fallback: "square.and.arrow.up")
                        Text("Export with zooms")
                    }
                }
                .buttonStyle(.themed(.outline, size: .md, leadingIcon: true))
                .tooltip(wholeExportHelp)
            } else {
                exportMenu
            }
            Spacer(minLength: 0)
        }
        .frame(height: ControlSizeToken.md.height)
    }

    /// "0:03–0:30" when trimmed, else nil.
    var trimLabel: String? {
        trim.isDefault ? nil : "\(shortTimecode(trimRange.lowerBound))–\(shortTimecode(trimRange.upperBound))"
    }

    var wholeExportHelp: String {
        "Render the \(trimLabel.map { "trimmed video (\($0)) with the " } ?? "")zoom plan to a new \(model.exportFormat.rawValue) file next to the master. Earlier exports are kept."
    }

    /// Once there are clips, Export offers the whole video, every clip, or
    /// one clip at a time.
    var exportMenu: some View {
        let ranges = clipRanges
        let ext = model.exportFormat.fileExtension.uppercased()
        return DropdownButton(
            id: "editor.export",
            style: { _ in .themed(.outline, size: .md, leadingIcon: true, trailingIcon: true) },
            items: {
                var items = [
                    DropdownItem(id: "whole", label: "Whole video with zooms",
                                 detail: "\(trimLabel.map { "Trimmed to \($0), as one" } ?? "One") \(ext) file next to the master") {
                        savePlanNow()
                        model.export(recording)
                    },
                ]
                if ranges.count > 1 {
                    items.append(DropdownItem(id: "clips", label: "All \(ranges.count) clips",
                                              detail: "One \(ext) file per clip: clip 1, clip 2, …") {
                        savePlanNow()
                        model.exportClips(recording)
                    })
                }
                for clip in ranges {
                    items.append(DropdownItem(
                        id: "clip.\(clip.id.uuidString)", label: "Clip \(clip.number)",
                        detail: "\(shortTimecode(clip.start))–\(shortTimecode(clip.end)) (\(String(format: "%.1fs", clip.length))) as clip \(clip.number).\(model.exportFormat.fileExtension)"
                    ) {
                        savePlanNow()
                        model.exportClips(recording, only: [clip.id])
                    })
                }
                return items
            }
        ) { _ in
            HStack(spacing: 6) {
                Icon(name: "export-duotone", size: 16, fallback: "square.and.arrow.up")
                Text("Export")
                Icon(name: "caret-down", size: 12, fallback: "chevron.down")
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
        .tooltip("Export the whole video, every clip, or one clip as its own \(model.exportFormat.rawValue) file. Earlier exports are kept.")
    }

    /// Hairline between toolbar clusters (Figma 93:1066).
    var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.input)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    // MARK: - Zoom group

    /// The "Zoom" group: the plus (or x) square starts a zoom at the
    /// playhead / ends the open one — one cycle per zoom, like the pin and
    /// the clip — and the steppers edit the level in effect there.
    func zoomControl(level: (value: Binding<Double>, editable: Bool)) -> some View {
        let move = zoomMove
        return LevelStepper(
            level: level.value, range: Self.zoomRange,
            levelEnabled: level.editable, levelHelp: levelHelp,
            cycle: .init(
                icon: move == .start ? "plus" : "x",
                fallback: move == .start ? "plus" : "xmark",
                label: "\(move == .start ? "Start zoom at" : "End zoom at") \(shortTimecode(currentTime))",
                active: move == .end, enabled: zoomMoveEnabled, help: zoomHelp
            ) {
                switch move {
                case .start: startZoom()
                case .end: endZoom()
                }
            }
        )
    }

    // MARK: - Pin viewport

    /// "Pin viewport at 0:42" (Figma 93:746): one button whose small square
    /// carries the action and whose well shows the playhead's time. When the
    /// toolbar is tight, the label drops and the square stands in for it.
    var pinControl: some View {
        let move = pinMove
        return cycleControl(
            icon: move == .pin ? "plus" : "x", fallback: move == .pin ? "plus" : "xmark",
            captions: (start: "Pin viewport at", end: "Unpin viewport at"), active: move == .unpin,
            activeColor: Theme.pinBar, enabled: pinMoveEnabled, help: pinHelp
        ) {
            switch move {
            case .pin: pinViewport()
            case .unpin: unpinViewport()
            }
        }
    }

    // MARK: - Clip

    /// "Start clip at 0:42" / "End clip at 0:58": the same control as the
    /// pin, one cycle per clip.
    var clipControl: some View {
        let move = clipMove
        return cycleControl(
            icon: move == .start ? "scissors" : "x", fallback: move == .start ? "scissors" : "xmark",
            captions: (start: "Start clip at", end: "End clip at"), active: move == .end,
            activeColor: Theme.clipBar, enabled: clipMoveEnabled, help: clipHelp
        ) {
            switch move {
            case .start: startClip()
            case .end: endClip()
            }
        }
    }

    // MARK: - Speed-up

    /// "Speed up [2×]" / "End speed-up [2×]": the square starts or ends a
    /// speed-up at the playhead (scrub there first — no time is shown), and
    /// the well is the rate button: it drops down the rate presets for the
    /// speed-up under the playhead (or the next one to be started) and the
    /// corner-badge toggle.
    var speedControl: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        return ViewThatFits(in: .horizontal) {
            speedRow(compact: false)
            speedRow(compact: true)
        }
        .frame(minWidth: 0)
        .frame(height: ControlSizeToken.md.height)
        .background(shape.fill(Theme.iconTabsList))
    }

    func speedRow(compact: Bool) -> some View {
        let move = speedMove
        let captions = (start: "Speed up", end: "End speed-up")
        let active = move == .end
        return HStack(spacing: 8) {
            Button {
                switch move {
                case .start: startSpeedUp()
                case .end: endSpeedUp()
                }
            } label: {
                HStack(spacing: 4) {
                    CycleSquare(
                        icon: move == .start ? "fast-forward" : "x",
                        fallback: move == .start ? "forward" : "xmark",
                        active: active, activeColor: Theme.speedBar
                    )
                    if !compact {
                        cycleCaption(captions, active: active)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(!speedMoveEnabled)
            .opacity(speedMoveEnabled ? 1 : 0.5)
            .accessibilityLabel("\(active ? captions.end : captions.start) at \(shortTimecode(currentTime))")
            .tooltip(speedHelp)
            .padding(.leading, 2)
            DropdownButton(id: "editor.speedRate", items: { speedRateItems() }) { _ in
                ToolbarField(text: String(format: "%g×", speedRateValue), width: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(format: "Speed-up rate %g×", speedRateValue))
            .tooltip(speedRateHelp)
            .padding(.trailing, 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A toolbar control whose small square carries an action and whose
    /// well shows the playhead's time. When the toolbar is tight, the
    /// caption drops and the square stands in for it. The control reserves
    /// the width of its longer caption so it never reflows (and never drops
    /// the caption) mid-cycle; while the cycle is open the square lights up
    /// primary so it reads as "now pick the end".
    func cycleControl(
        icon: String, fallback: String, captions: (start: String, end: String), active: Bool,
        activeColor: Color, enabled: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        return Button(action: action) {
            ViewThatFits(in: .horizontal) {
                cycleRow(icon: icon, fallback: fallback, captions: captions, active: active,
                         activeColor: activeColor, compact: false)
                cycleRow(icon: icon, fallback: fallback, captions: captions, active: active,
                         activeColor: activeColor, compact: true)
            }
            .frame(minWidth: 0)
            .frame(height: ControlSizeToken.md.height)
            .background(shape.fill(Theme.iconTabsList))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel("\(active ? captions.end : captions.start) \(shortTimecode(currentTime))")
        .tooltip(help)
    }

    func cycleRow(
        icon: String, fallback: String, captions: (start: String, end: String), active: Bool,
        activeColor: Color, compact: Bool
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                CycleSquare(icon: icon, fallback: fallback, active: active, activeColor: activeColor)
                if !compact {
                    cycleCaption(captions, active: active)
                }
            }
            .padding(.leading, 2)
            ToolbarField(text: shortTimecode(currentTime))
                .padding(.trailing, 1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The cycle's caption, sized to the longer of its two states so the
    /// control keeps its width when a click flips it.
    func cycleCaption(_ captions: (start: String, end: String), active: Bool) -> some View {
        ZStack(alignment: .leading) {
            Text(captions.start).hidden()
            Text(captions.end).hidden()
            Text(active ? captions.end : captions.start)
        }
        .font(Theme.font(.label12))
        .foregroundStyle(Theme.mutedForeground)
        .lineLimit(1)
        .fixedSize()
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
        .tooltip("More: cursor style, trim the video at the playhead, remove a zoom, a clip or a speed-up, reset the trim or the zooms")
    }

    func moreItems() -> [DropdownItem] {
        var items: [DropdownItem] = CursorStyle.allCases.map { style in
            DropdownItem(id: "cursor.\(style.rawValue)", label: style.label,
                         checked: style == cursorStyle, detail: style.detail) {
                cursorStyle = style
            }
        }
        if let clip = clipAtPlayhead {
            items.append(DropdownItem(id: "removeClip", label: "Remove clip \(clip.number)") {
                removeClip(clip.id)
            })
        }
        if let window = speedAtPlayhead {
            items.append(DropdownItem(id: "removeSpeed", label: "Remove this speed-up") {
                removeSpeed(window.id)
            })
        }
        let kept = trimRange
        if currentTime > 0.05, currentTime < kept.upperBound - Trim.minLength {
            items.append(DropdownItem(id: "trimStart", label: "Trim the start to here",
                                      detail: "The whole-video export begins at \(shortTimecode(currentTime))") {
                trim.start = currentTime
            })
        }
        if currentTime < duration - 0.05, currentTime > kept.lowerBound + Trim.minLength {
            items.append(DropdownItem(id: "trimEnd", label: "Trim the end to here",
                                      detail: "The whole-video export stops at \(shortTimecode(currentTime))") {
                trim.end = currentTime
            })
        }
        if let trimLabel {
            items.append(DropdownItem(id: "resetTrim", label: "Reset the trim",
                                      detail: "Export the whole recording again instead of \(trimLabel)") {
                resetTrim()
            })
        }
        if let i = holdIndexAtPlayhead {
            let id = segments[i].id
            items.append(DropdownItem(id: "remove", label: "Remove this zoom") {
                removeZoom(id)
            })
        }
        items.append(DropdownItem(id: "reset", label: "Reset all zooms",
                                  detail: "Regenerate from the click log; Compare keeps your edits") {
            resetZoomsToDefault()
        })
        return items
    }
}

/// "[+]  Zoom  −  1.8×  +" (Figma 93:697): a muted group whose leading
/// square starts a zoom at the playhead (an x ends the open one) and
/// whose level sits in a well between two 12pt steppers, in tenths, clamped
/// to the editor's range. The square and the steppers enable on their own —
/// the square wherever a zoom could start or end, the steppers only inside
/// a hold. When the toolbar is tight, the word "Zoom" becomes a magnifying
/// glass.
struct LevelStepper: View {
    /// The start/end action on the group's leading square; `active` while
    /// a zoom is open, lighting the square primary until the end is picked.
    struct Cycle {
        let icon: String
        let fallback: String
        let label: String
        let active: Bool
        let enabled: Bool
        let help: String
        let action: () -> Void
    }

    @Binding var level: Double
    let range: ClosedRange<Double>
    let levelEnabled: Bool
    let levelHelp: String
    let cycle: Cycle
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chrome { zoomCaption(compact: false) }
            chrome { zoomCaption(compact: true) }
        }
        .frame(minWidth: 0)
        .opacity(isEnabled ? 1 : 0.5)
    }

    /// The 28pt action square, styled like the pin and clip controls'.
    private var cycleButton: some View {
        Button(action: cycle.action) {
            CycleSquare(icon: cycle.icon, fallback: cycle.fallback, active: cycle.active,
                        activeColor: Theme.zoomBar)
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(!cycle.enabled)
        .opacity(cycle.enabled ? 1 : 0.5)
        .accessibilityLabel(cycle.label)
        .tooltip(cycle.help)
    }

    @ViewBuilder
    private func zoomCaption(compact: Bool) -> some View {
        if compact {
            Icon(name: "magnifying-glass", size: 16, fallback: "magnifyingglass")
                .foregroundStyle(Theme.mutedForeground)
                .padding(.horizontal, 8)
                .accessibilityLabel("Zoom")
        } else {
            Text("Zoom")
                .font(Theme.font(.label12))
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
        }
    }

    private func chrome<Caption: View>(@ViewBuilder caption: () -> Caption) -> some View {
        HStack(spacing: 0) {
            cycleButton
                .padding(.leading, 2)
            caption()
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
            .disabled(!levelEnabled)
            .opacity(levelEnabled ? 1 : 0.5)
            .tooltip(levelHelp)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: ControlSizeToken.md.height)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(Theme.iconTabsList))
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

/// The 28pt square that carries a cycle's start/end action: paper while
/// waiting to start, filled with the feature's timeline-bar colour while
/// the cycle is open so the flipped label ("End clip at", "Unpin viewport
/// at", …) is unmissable and reads as its row on the timeline.
struct CycleSquare: View {
    let icon: String
    let fallback: String
    var active = false
    var activeColor: Color = Theme.primary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        Icon(name: icon, size: 16, fallback: fallback)
            .foregroundStyle(active ? Theme.primaryForeground : Theme.foreground)
            .frame(width: 28, height: 28)
            .background {
                shape.fill(active ? activeColor : Theme.background)
                    .overlay(shape.strokeBorder(
                        active ? Color.black.opacity(0.15) : Theme.input, lineWidth: 1
                    ))
            }
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
