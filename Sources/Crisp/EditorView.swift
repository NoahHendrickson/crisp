import SwiftUI
import AVFoundation
import AppKit

/// Bare AVPlayerLayer host. AVKit's SwiftUI `VideoPlayer` crashes at metadata
/// instantiation on this OS/toolchain combo, and we don't need its controls —
/// the editor has its own timeline and transport.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
            layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Post-recording zoom editor: video preview with zooms applied live, a
/// timeline of zoom segments, and per-segment controls. Edits autosave to
/// plan.json, which "Export with Zooms" then uses instead of the auto plan.
struct EditorView: View {
    let folder: URL

    @EnvironmentObject var model: AppModel
    @State private var meta: RecordingMeta?
    @State private var duration: Double = 1
    enum Selection: Equatable {
        case segment(UUID)
        case pan(segment: UUID, pan: UUID)
    }

    @State private var segments: [ZoomSegment] = []
    @State private var selection: Selection?
    /// The hold edge being dragged on the timeline, with the time it had when
    /// the drag began so the edge tracks the pointer instead of jumping to it.
    private struct EdgeDrag: Equatable {
        let id: UUID
        let edge: HorizontalEdge
        let origin: Double
    }
    @State private var edgeDrag: EdgeDrag?
    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    @State private var loadError: String?
    @State private var rebuildTask: Task<Void, Never>?
    /// What the preview shows (the IconTabList above the timeline): the real
    /// zoomed camera, or the full frame with an editable crop box.
    enum ViewMode: String, CaseIterable, Identifiable {
        case preview, box
        var id: String { rawValue }
    }
    @State private var viewMode: ViewMode = .preview
    /// Plan the split "Compare" preview plays against: the plan as loaded, or
    /// the one in effect before the last AI reply / revert / reset.
    @State private var compareBaseline: [ZoomSegment]?
    /// True while the preview shows baseline (top) and current (bottom)
    /// stacked, looping over the zooms that differ.
    @State private var comparing = false
    @State private var compareGrown: CGFloat = 0
    private static let compareExpansion: CGFloat = 220
    /// Which "Start from" choice the plan was last loaded from ("current",
    /// "auto", or an export's path). Only used to place the check mark.
    @State private var planSource = "current"
    /// The plan as loaded from `planSource`; the check mark stays only while
    /// `segments` still equals it.
    @State private var planSourceSegments: [ZoomSegment]?

    @StateObject private var aiChat = AIChat()
    @State private var showAIPanel = false
    @State private var windowHandle = EditorWindowHandle()
    /// How much we last added to the window for the inspector, so closing it
    /// can shrink the same amount from the bottom.
    @State private var inspectorGrown: CGFloat = 0

    private var recording: Recording { Recording(folder: folder) }
    private let baseMinWidth: CGFloat = 880
    /// Room for the zoom/pan GroupBox plus the VStack gap above it.
    private static let inspectorExpansion: CGFloat = 260

    var body: some View {
        Group {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .padding()
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 24) {
                        PlayerLayerView(player: player)
                            .frame(minHeight: 300)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                            .overlay { frameOverlay.disabled(aiChat.running) }
                            .overlay { if comparing { compareLabels } }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                        VStack(alignment: .leading, spacing: 32) {
                            // Plan edits are locked while a turn is in flight so the
                            // agent's reply can't clobber them.
                            timeline
                            controls
                            inspector
                                .disabled(aiChat.running)
                        }
                    }
                    .padding(24)
                    if showAIPanel {
                        AIPanelView(
                            chat: aiChat,
                            recording: recording,
                            meta: meta,
                            duration: duration,
                            segments: segments,
                            onApply: { plan in
                                compareBaseline = segments
                                segments = plan
                                select(nil)
                            },
                            onCompare: { baseline in
                                compareBaseline = baseline
                                setComparing(true)
                            }
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .font(Theme.font(.body12))
        .foregroundStyle(Theme.foreground)
        .groupBoxStyle(.card)
        .frame(minWidth: showAIPanel ? baseMinWidth + AIPanelView.width : baseMinWidth, minHeight: 660)
        .background(Theme.background)
        .background(WindowChrome())
        .background(EditorWindowHandleView(handle: windowHandle))
        .tooltipHost()
        .dropdownHost()
        .navigationTitle("Crisp zoom editor – \(recording.name)")
        .onAppear {
            load()
            Task { await aiChat.detectProviders() }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player.pause()
        }
        .onChange(of: segments) { _, _ in
            if comparing && planDiff == nil { setComparing(false) }
            scheduleRebuild()
        }
        .onChange(of: selection) { _, _ in
            player.currentItem?.videoComposition = makeComposition()
        }
        .onChange(of: viewMode) { _, _ in
            if comparing { setComparing(false) }
            player.currentItem?.videoComposition = makeComposition()
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            // Compare playback that ran into the end of the master wraps
            // around to the first edited window instead of stopping.
            if status == .paused && comparing && currentTime >= duration - 0.1,
               let first = planDiff?.ranges.first {
                seek(to: first.start)
                player.play()
            }
        }
    }

    // MARK: - Loading

    private func load() {
        do {
            let m = try recording.loadMeta()
            meta = m
        } catch {
            loadError = "Could not load this recording's click log: \(error.localizedDescription)"
            return
        }
        Task {
            do {
                let asset = AVURLAsset(url: recording.masterURL)
                duration = try await asset.load(.duration).seconds
                segments = recording.loadPlanSegments() ?? autoSegments()
                compareBaseline = segments
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = makeComposition()
                player.replaceCurrentItem(with: item)
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: 30), queue: .main
                ) { time in
                    currentTime = time.seconds
                    enforceCompareLoop()
                }
            } catch {
                loadError = "Could not load the master video: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Plan source ("Start from")

    /// Current plan, each export that carries a plan snapshot, then Auto.
    private var planSourceItems: [DropdownItem] {
        let exports = recording.files.filter { !$0.isMaster }
        let checked = checkedPlanSource(exports: exports)
        var items = [
            DropdownItem(id: "current", label: "Current plan", checked: checked == "current",
                         detail: "\(zoomsLabel(segments.count)) · what Export with Zooms will render") {
                loadPlan(recording.loadPlanSegments() ?? autoSegments(), source: "current")
            },
        ]
        for file in exports.reversed() {
            guard let snapshot = file.planSnapshotURL,
                  let plan = Recording.loadPlanSegments(from: snapshot) else { continue }
            var detail = zoomsLabel(plan.count)
            if let date = file.modifiedAt {
                detail += " · \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
            }
            items.append(DropdownItem(id: file.url.path, label: "\(file.title) (\(file.format))",
                                      checked: checked == file.url.path, detail: detail) {
                loadPlan(plan, source: file.url.path)
            })
        }
        items.append(DropdownItem(id: "auto", label: "Auto (from clicks)", checked: checked == "auto",
                                  detail: "Regenerate zooms from the click log") {
            try? FileManager.default.removeItem(at: recording.planURL)
            loadPlan(autoSegments(), source: "auto")
        })
        return items
    }

    /// The last-picked source keeps its check only while the plan still
    /// matches it; once edited, the working plan is simply "Current plan".
    private func checkedPlanSource(exports: [RecordingFile]) -> String {
        guard planSource != "current", let planSourceSegments, planSourceSegments == segments,
              planSource == "auto" || exports.contains(where: { $0.url.path == planSource })
        else { return "current" }
        return planSource
    }

    /// Swaps the plan in, keeping the previous one as the Compare baseline.
    private func loadPlan(_ plan: [ZoomSegment], source: String) {
        compareBaseline = segments
        segments = plan
        planSource = source
        planSourceSegments = plan
        select(nil)
    }

    private func zoomsLabel(_ n: Int) -> String {
        n == 1 ? "1 zoom" : "\(n) zooms"
    }

    private func planner() -> ZoomPlanner {
        guard let meta else { return ZoomPlanner(width: 1, height: 1) }
        return ZoomPlanner(width: Double(meta.pixelWidth), height: Double(meta.pixelHeight))
    }

    private func autoSegments() -> [ZoomSegment] {
        guard let meta else { return [] }
        return planner().segments(events: meta.events, duration: duration)
    }

    private func makeComposition() -> AVMutableVideoComposition? {
        guard let meta else { return nil }
        let clipDuration = CMTime(seconds: max(duration, 0.1), preferredTimescale: 600)
        if comparing, let compareBaseline {
            let composer = CompareComposer(
                meta: meta,
                before: planner().keyframes(from: compareBaseline, duration: duration),
                after: planner().keyframes(from: segments, duration: duration)
            )
            return CameraCompositor.makeComposition(duration: clipDuration, composer: composer)
        }
        // In the crop-box view the camera stays at full frame so the box is
        // always visible; cursor and ripples still render.
        let full = Camera(
            zoom: 1,
            center: CGPoint(x: Double(meta.pixelWidth) / 2, y: Double(meta.pixelHeight) / 2)
        )
        let keys = viewMode == .box
            ? [ZoomPlanner.Keyframe(t: 0, camera: full)]
            : planner().keyframes(from: segments, duration: duration)
        let composer = FrameComposer(meta: meta, keys: keys)
        return CameraCompositor.makeComposition(duration: clipDuration, composer: composer)
    }

    // MARK: - Compare

    /// Differences between the baseline and the current plan, or nil when
    /// there is nothing to compare.
    private var planDiff: PlanDiff? {
        guard let compareBaseline else { return nil }
        let diff = PlanDiff(before: compareBaseline, after: segments, planner: planner(), duration: duration)
        return diff.isEmpty ? nil : diff
    }

    /// Enter/leave the stacked before/after preview. Entering clears any
    /// selection (the crop box has no meaning across two plans), grows the
    /// window so each half keeps a usable size, and starts playing from the
    /// first edited window.
    private func setComparing(_ on: Bool) {
        guard on != comparing else { return }
        if on {
            select(nil)
            comparing = true
            windowHandle.growDown(by: Self.compareExpansion)
            compareGrown = Self.compareExpansion
            player.currentItem?.videoComposition = makeComposition()
            if let first = planDiff?.ranges.first { seek(to: first.start) }
            player.play()
        } else {
            comparing = false
            windowHandle.growDown(by: -compareGrown)
            compareGrown = 0
            player.currentItem?.videoComposition = makeComposition()
        }
    }

    /// While comparing, playback stays inside the edited windows: reaching the
    /// end of one (or scrubbing into unchanged footage) jumps to the next,
    /// wrapping to the first.
    private func enforceCompareLoop() {
        guard comparing, player.timeControlStatus == .playing,
              let ranges = planDiff?.ranges, !ranges.isEmpty else { return }
        let t = currentTime
        if ranges.contains(where: { t >= $0.start - 0.05 && t < $0.end - 0.03 }) { return }
        let next = ranges.first { $0.start > t } ?? ranges[0]
        seek(to: next.start)
    }

    /// "Before" / "After" tags pinned to the top-left of each stacked half,
    /// positioned against the aspect-fitted video rect.
    private var compareLabels: some View {
        GeometryReader { geo in
            if let meta {
                let w = Double(meta.pixelWidth)
                let h = Double(meta.pixelHeight)
                let stackedH = h * 2 + CompareComposer.gap
                let scale = min(geo.size.width / w, geo.size.height / stackedH)
                let fitted = CGRect(
                    x: (geo.size.width - w * scale) / 2,
                    y: (geo.size.height - stackedH * scale) / 2,
                    width: w * scale, height: stackedH * scale
                )
                let secondY = fitted.minY + (h + CompareComposer.gap) * scale
                compareTag("Before")
                    .offset(x: fitted.minX + 8, y: fitted.minY + 8)
                compareTag("After")
                    .offset(x: fitted.minX + 8, y: secondY + 8)
            }
        }
        .allowsHitTesting(false)
    }

    private func compareTag(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(.label12))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
    }

    /// Debounced: autosave the plan and swap in a fresh preview composition.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            recording.savePlan(segments)
            player.currentItem?.videoComposition = makeComposition()
        }
    }

    // MARK: - Frame overlay

    static let zoomRange: ClosedRange<Double> = 1.2...3.0

    /// Editable crop box, shown in the box view for the selected zoom or pan
    /// — or, with nothing selected, for the zoom under the playhead.
    @ViewBuilder
    private var frameOverlay: some View {
        if let meta, viewMode == .box, !comparing, let index = boxSegmentIndex {
            let seg = segments[index]
            let span = motionSpan(for: seg)
            if currentTime < span.arrive || currentTime > span.end {
                // Outside the selected zoom's hold window the box just mirrors
                // where the camera really is at the playhead: the full frame
                // when nothing is zoomed, or the in-between framing mid-ramp.
                let camera = ZoomPlanner.evaluate(
                    planner().keyframes(from: segments, duration: duration),
                    at: currentTime
                )
                ZoomFrameOverlay(
                    pixelWidth: Double(meta.pixelWidth),
                    pixelHeight: Double(meta.pixelHeight),
                    zoomRange: Self.zoomRange,
                    zoomEditable: false,
                    editable: false,
                    cx: .constant(camera.center.x),
                    cy: .constant(camera.center.y),
                    zoom: .constant(camera.zoom)
                )
            } else if case .pan(_, let panID) = selection,
                      let panIndex = seg.pans.firstIndex(where: { $0.id == panID }) {
                // Resizing the box at a pan gives that move its own zoom
                // level: the camera tightens as it glides.
                ZoomFrameOverlay(
                    pixelWidth: Double(meta.pixelWidth),
                    pixelHeight: Double(meta.pixelHeight),
                    zoomRange: Self.zoomRange,
                    zoomEditable: true,
                    cx: $segments[index].pans[panIndex].cx,
                    cy: $segments[index].pans[panIndex].cy,
                    zoom: panZoomBinding(segIndex: index, panIndex: panIndex)
                )
            } else if let panIndex = activePanIndex(in: seg) {
                // Scrubbing across the zoom retargets the box to the framing
                // in effect at the playhead: the latest pan that has started,
                // or the zoom's initial center before any pan.
                ZoomFrameOverlay(
                    pixelWidth: Double(meta.pixelWidth),
                    pixelHeight: Double(meta.pixelHeight),
                    zoomRange: Self.zoomRange,
                    zoomEditable: true,
                    cx: $segments[index].pans[panIndex].cx,
                    cy: $segments[index].pans[panIndex].cy,
                    zoom: panZoomBinding(segIndex: index, panIndex: panIndex)
                )
            } else {
                ZoomFrameOverlay(
                    pixelWidth: Double(meta.pixelWidth),
                    pixelHeight: Double(meta.pixelHeight),
                    zoomRange: Self.zoomRange,
                    zoomEditable: true,
                    cx: $segments[index].cx,
                    cy: $segments[index].cy,
                    zoom: $segments[index].zoom
                )
            }
        }
    }

    /// The zoom whose crop box the box view shows: the selection, or else
    /// whichever zoom's motion window contains the playhead.
    private var boxSegmentIndex: Int? {
        if let index = selectedSegmentIndex { return index }
        return segments.firstIndex {
            let span = motionSpan(for: $0)
            return currentTime >= span.moveStart && currentTime <= span.outEnd
        }
    }

    /// The zoom level in effect once `pan` has completed: its own, or the
    /// latest earlier step's, or the zoom's base level.
    private func zoomLevel(in seg: ZoomSegment, after pan: PanMove) -> Double {
        seg.pans
            .filter { $0.t <= pan.t && $0.zoom != nil }
            .max { $0.t < $1.t }?.zoom ?? seg.zoom
    }

    /// The zoom level the camera has at `t` inside `seg`'s hold.
    private func zoomLevel(in seg: ZoomSegment, at t: Double) -> Double {
        seg.pans
            .filter { $0.t <= t && $0.zoom != nil }
            .max { $0.t < $1.t }?.zoom ?? seg.zoom
    }

    /// Read the level a pan lands on; write it as that pan's own level.
    private func panZoomBinding(segIndex: Int, panIndex: Int) -> Binding<Double> {
        Binding(
            get: {
                guard segments.indices.contains(segIndex),
                      segments[segIndex].pans.indices.contains(panIndex) else { return 1 }
                let seg = segments[segIndex]
                return zoomLevel(in: seg, after: seg.pans[panIndex])
            },
            set: { segments[segIndex].pans[panIndex].zoom = $0 }
        )
    }

    /// The zoom whose hold window (start…end) contains the playhead: where
    /// "New pan" and an in-place "New zoom" go.
    private var holdSegmentIndex: Int? {
        segments.firstIndex { currentTime >= $0.start && currentTime <= $0.end }
    }

    /// Index of the pan whose target the camera shows at the playhead, if any.
    private func activePanIndex(in seg: ZoomSegment) -> Int? {
        let span = motionSpan(for: seg)
        guard currentTime >= span.arrive, currentTime <= span.end else { return nil }
        return seg.pans.indices
            .filter { seg.pans[$0].t <= currentTime }
            .max { seg.pans[$0].t < seg.pans[$1].t }
    }

    // MARK: - Timeline

    /// Assign `selection`, growing the window downward when the inspector
    /// first appears so the preview and timeline stay put.
    private func select(_ new: Selection?) {
        if new != nil, comparing { setComparing(false) }
        let showing = selection != nil
        let willShow = new != nil
        if !showing && willShow {
            windowHandle.growDown(by: Self.inspectorExpansion)
            inspectorGrown = Self.inspectorExpansion
        } else if showing && !willShow {
            windowHandle.growDown(by: -inspectorGrown)
            inspectorGrown = 0
        }
        selection = new
    }

    /// The camera-motion window for a segment as drawn on the timeline: the
    /// zoom-in ramp begins `leadIn` early and the zoom-out eases back after
    /// the hold ends. Mirrors ZoomPlanner.keyframes.
    private func motionSpan(
        for seg: ZoomSegment
    ) -> (moveStart: Double, arrive: Double, end: Double, outEnd: Double) {
        planner().motionSpan(for: seg, duration: duration)
    }

    /// True when this segment or one of its pans is selected — or, while
    /// comparing, when it differs from the baseline.
    private func isHighlighted(_ seg: ZoomSegment) -> Bool {
        if comparing, let diff = planDiff, diff.changed.contains(seg.id) { return true }
        switch selection {
        case .segment(seg.id): return true
        case .pan(segment: seg.id, pan: _): return true
        default: return false
        }
    }

    /// Transport button beside the bar (Figma 76:13691): the playhead's own
    /// play/pause, then the track with one bar per zoom.
    private var timeline: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                togglePlayback()
            } label: {
                Icon(
                    name: isPlaying ? "pause" : "play", size: 16,
                    fallback: isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(.themed(.primary, size: .md, iconOnly: true))
            .keyboardShortcut(.space, modifiers: [])
            .tooltip("Play / pause (Space)")
            .offset(y: 5)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.timelineTrack)
                        .frame(height: 32)
                        .offset(y: 5)
                    ForEach(segments) { seg in
                        segmentBar(for: seg, width: w)
                    }
                    if comparing, let diff = planDiff {
                        ForEach(diff.removed) { seg in
                            removedBar(for: seg, width: w)
                        }
                    }
                    playhead(at: currentTime, width: w)
                    durationLabel
                        .offset(x: w - 23)
                }
                .contentShape(Rectangle())
                .pointingHandCursor()
                // One gesture for the whole track so nothing on it can swallow
                // a click: every press scrubs, and a press that doesn't move
                // also selects whatever bar or icon it landed on.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let t = min(max(0, value.location.x / w * duration), duration)
                            seek(to: t)
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) < 3, abs(value.translation.height) < 3 else { return }
                            handleTimelineClick(at: value.location, width: w)
                        }
                )
            }
            .frame(height: 58)
            .disabled(aiChat.running)
        }
    }

    /// One zoom on the bar, split into its three camera phases: a hatched
    /// zoom-in ramp (automatic, not editable), the solid hold where the crop
    /// box and pans apply, and a hatched zoom-out ramp. The moments that
    /// matter — zoom start, hold start, each pan — carry their icons inside
    /// the bar; clicking one selects it for editing.
    @ViewBuilder
    private func segmentBar(for seg: ZoomSegment, width w: CGFloat) -> some View {
        let span = motionSpan(for: seg)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let on = isHighlighted(seg)
        let x = span.moveStart / duration * w
        let segW = max(6, (span.outEnd - span.moveStart) / duration * w)
        let inW = min(segW, max(0, (span.arrive - span.moveStart) / duration * w))
        let outW = min(segW - inW, max(0, (span.outEnd - span.end) / duration * w))
        let holdW = max(0, segW - inW - outW)
        let holdX = x + inW

        // Base: ramps are faint; the hold is the strong part of the bar.
        shape.fill(Theme.zoomBarMuted.opacity(on ? 0.6 : 0.4))
            .frame(width: segW, height: 32)
            .offset(x: x, y: 5)

        // Zoom-in ramp
        if inW > 0 {
            Hatch(color: Theme.zoomBar.opacity(on ? 0.9 : 0.5))
                .frame(width: inW, height: 32)
                .clipShape(shape)
                .offset(x: x, y: 5)
                .tooltip("Zooming in — automatic, not editable")
        }
        // Hold
        if holdW > 0 {
            Group {
                if on {
                    PrimaryChrome(shape: shape, fill: Theme.zoomBar, border: Theme.zoomBarBorder, small: true)
                } else {
                    shape.fill(Theme.zoomBarMuted)
                }
            }
            .frame(width: holdW, height: 32)
            .offset(x: holdX, y: 5)
            .tooltip(String(format: "Holding at %.1f× for %.1fs — click to edit, drag the edges to extend or shorten it",
                         seg.zoom, span.end - span.arrive))
        }
        // Zoom-out ramp
        if outW > 0 {
            Hatch(color: Theme.zoomBar.opacity(on ? 0.9 : 0.5))
                .frame(width: outW, height: 32)
                .clipShape(shape)
                .offset(x: holdX + holdW, y: 5)
                .tooltip("Zooming out — automatic, not editable")
        }

        // Icons inside the bar, 12pt, vertically centered (Figma 76:13698).
        // Plain views, not buttons: the track's gesture routes clicks to them
        // (see handleTimelineClick) so they never block scrubbing.
        ForEach(barIcons(for: seg, span: span, x: x, width: segW, timelineWidth: w)) { icon in
            HStack(spacing: 2) {
                Icon(name: icon.name, size: 12, fallback: icon.fallback)
                if let label = icon.label {
                    Text(label)
                        .font(Theme.font(.label12))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(on ? Theme.zoomBarForeground : Theme.foreground)
            .tooltip(icon.help)
            .offset(x: icon.x, y: 15)
            .zIndex(2)
        }

        // Edge grips on the hold: drag to move where the zoom starts or ends.
        if holdW > 0 {
            ForEach([HorizontalEdge.leading, .trailing], id: \.self) { edge in
                let edgeX = edge == .leading ? holdX : holdX + holdW
                TimelineEdgeHandle(
                    highlighted: on,
                    dragging: edgeDrag.map { $0.id == seg.id && $0.edge == edge } ?? false,
                    onDrag: { dx in dragEdge(of: seg.id, edge, translation: dx, width: w) },
                    onEnd: { edgeDrag = nil }
                )
                .offset(x: edgeX - TimelineEdgeHandle.width / 2, y: 5)
                .tooltip(edge == .leading
                      ? "Drag to change where this zoom starts"
                      : "Drag to change where this zoom ends")
                .zIndex(3)
            }
        }
    }

    /// A click (press without movement) on the track: select the icon it
    /// landed on, else the bar; clicks on the empty track only scrub.
    private func handleTimelineClick(at point: CGPoint, width w: CGFloat) {
        guard point.y >= 5, point.y <= 37 else { return }
        for seg in segments {
            let span = motionSpan(for: seg)
            let x = span.moveStart / duration * w
            let segW = max(6, (span.outEnd - span.moveStart) / duration * w)
            guard point.x >= x, point.x <= x + segW else { continue }
            let icons = barIcons(for: seg, span: span, x: x, width: segW, timelineWidth: w)
            if let icon = icons.first(where: { point.x >= $0.x - 2 && point.x <= $0.x + $0.width + 2 }) {
                icon.action()
            } else {
                select(.segment(seg.id))
            }
            return
        }
    }

    /// An icon placed inside a zoom's bar at the moment it marks.
    private struct BarIcon: Identifiable {
        let id: String
        let name: String
        let fallback: String
        let label: String?
        let help: String
        var x: CGFloat
        let width: CGFloat
        let action: () -> Void
    }

    /// The zoom-in, hold (with the zoom level when there is room) and pan
    /// icons for one bar. Each sits at its own time, or just after the
    /// previous icon when they would overlap; whatever no longer fits inside
    /// the bar is left off (the bar itself still selects the zoom).
    private func barIcons(
        for seg: ZoomSegment,
        span: (moveStart: Double, arrive: Double, end: Double, outEnd: Double),
        x: CGFloat, width segW: CGFloat, timelineWidth w: CGFloat
    ) -> [BarIcon] {
        let inset: CGFloat = 5
        let gap: CGFloat = 8
        let holdW = (span.end - span.arrive) / duration * w
        let level = holdW >= 48 ? String(format: "%.1f×", seg.zoom) : nil
        var wanted: [BarIcon] = [
            BarIcon(
                id: "zoom", name: "magnifying-glass-plus", fallback: "plus.magnifyingglass",
                label: nil, help: "Zoom start — click to edit",
                x: span.moveStart / duration * w + inset, width: 12
            ) { select(.segment(seg.id)) },
            BarIcon(
                id: "hold", name: "pause", fallback: "pause.fill",
                label: level, help: "Fully zoomed — the camera holds at this level from here",
                x: span.arrive / duration * w + inset, width: level == nil ? 12 : 42
            ) { select(.segment(seg.id)) },
        ]
        for pan in seg.pans.sorted(by: { $0.t < $1.t }) {
            if let stepZoom = pan.zoom {
                let stepLabel = holdW >= 96 ? String(format: "%.1f×", stepZoom) : nil
                wanted.append(BarIcon(
                    id: pan.id.uuidString, name: "magnifying-glass-plus",
                    fallback: "plus.magnifyingglass",
                    label: stepLabel, help: "Zooms in further here — click to edit",
                    x: pan.t / duration * w + inset, width: stepLabel == nil ? 12 : 42
                ) { select(.pan(segment: seg.id, pan: pan.id)) })
            } else {
                wanted.append(BarIcon(
                    id: pan.id.uuidString, name: "arrows-out-cardinal",
                    fallback: "arrow.up.and.down.and.arrow.left.and.right",
                    label: nil, help: "Pan start — click to edit",
                    x: pan.t / duration * w + inset, width: 12
                ) { select(.pan(segment: seg.id, pan: pan.id)) })
            }
        }
        var placed: [BarIcon] = []
        var cursor = x + inset
        let limit = x + segW - inset
        for var icon in wanted {
            icon.x = max(icon.x, cursor)
            guard icon.x + icon.width <= limit else { break }
            placed.append(icon)
            cursor = icon.x + icon.width + gap
        }
        return placed
    }

    /// Move a zoom's start or end by the pointer's travel since the drag
    /// began, keeping the inspector's 0.2s minimum length. The playhead is
    /// left alone: the grips only resize, they never scrub.
    private func dragEdge(of id: UUID, _ edge: HorizontalEdge, translation dx: CGFloat, width w: CGFloat) {
        guard w > 0, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = segments[index]
        let drag: EdgeDrag
        if let current = edgeDrag, current.id == id, current.edge == edge {
            drag = current
        } else {
            drag = EdgeDrag(id: id, edge: edge, origin: edge == .leading ? seg.start : seg.end)
            edgeDrag = drag
        }
        let t = drag.origin + Double(dx / w) * duration
        switch edge {
        case .leading:
            segments[index].start = min(max(0, t), seg.end - 0.2)
        case .trailing:
            segments[index].end = max(min(duration, t), seg.start + 0.2)
        }
    }

    /// A baseline zoom that the current plan no longer has: a dashed outline
    /// over its old motion window, shown only while comparing.
    private func removedBar(for seg: ZoomSegment, width w: CGFloat) -> some View {
        let span = motionSpan(for: seg)
        let x = span.moveStart / duration * w
        let segW = max(6, (span.outEnd - span.moveStart) / duration * w)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .strokeBorder(Theme.destructive.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: segW, height: 32)
            .offset(x: x, y: 5)
            .allowsHitTesting(false)
            .tooltip("Removed since the baseline")
    }

    /// 6×42 destructive playhead (Figma 38:5167) plus a Label/12 time under it.
    private func playhead(at time: Double, width w: CGFloat) -> some View {
        let x = min(max(0, time / duration * w), w) - 3
        return VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.destructive)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                )
                .frame(width: 6, height: 42)
            Text(timecodeShort(time))
                .font(Theme.font(.label12))
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .frame(width: 30)
        }
        .frame(width: 30)
        .offset(x: x - 12)
        .zIndex(1)
        .allowsHitTesting(false)
    }

    private var durationLabel: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 6, height: 42)
            Text(timecodeShort(duration))
                .font(Theme.font(.label12))
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .frame(width: 30)
        }
        .frame(width: 30)
        .allowsHitTesting(false)
    }

    // MARK: - Inspector

    private var selectedSegmentIndex: Int? {
        switch selection {
        case .segment(let id), .pan(segment: let id, pan: _):
            return segments.firstIndex { $0.id == id }
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if case .pan(let segID, let panID) = selection,
           let segIndex = segments.firstIndex(where: { $0.id == segID }),
           let panIndex = segments[segIndex].pans.firstIndex(where: { $0.id == panID }),
           let meta {
            panInspector(segIndex: segIndex, panIndex: panIndex, meta: meta)
        } else if let index = selectedSegmentIndex, let meta {
            let seg = segments[index]
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Start")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].start },
                                set: { segments[index].start = min($0, segments[index].end - 0.2) }
                            ),
                            in: 0...duration
                        )
                        Text(timecode(seg.start))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("End")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].end },
                                set: { segments[index].end = max($0, segments[index].start + 0.2) }
                            ),
                            in: 0...duration
                        )
                        Text(timecode(seg.end))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Zoom")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].zoom },
                                set: { segments[index].zoom = $0 }
                            ),
                            in: Self.zoomRange
                        )
                        Text(String(format: "%.1f×", seg.zoom))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Center X")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].cx },
                                set: { segments[index].cx = $0 }
                            ),
                            in: 0...Double(meta.pixelWidth)
                        )
                        Text("\(Int(seg.cx))px")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Center Y")
                        ThemedSlider(
                            value: Binding(
                                get: { segments[index].cy },
                                set: { segments[index].cy = $0 }
                            ),
                            in: 0...Double(meta.pixelHeight)
                        )
                        Text("\(Int(seg.cy))px")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Preview This Zoom") {
                        startLivePreview(from: max(0, seg.start - 1.2))
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Play this zoom with the real camera, starting just before it")
                    Button("Add Pan at Playhead") {
                        addPanAtPlayhead(segIndex: index)
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Insert a camera pan inside this zoom at the current playhead")
                    Button("Zoom In Further at Playhead") {
                        addZoomStepAtPlayhead(segIndex: index)
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Tighten the zoom from the playhead on, without zooming back out first")
                    Spacer()
                    Button("Remove Zoom", role: .destructive) {
                        segments.remove(at: index)
                        select(nil)
                    }
                    .buttonStyle(.themed(.destructive, size: .xs))
                    .tooltip("Delete this zoom and its pans")
                }
                .padding(.top, 4)
            } label: {
                Text("Selected Zoom")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func panInspector(segIndex: Int, panIndex: Int, meta: RecordingMeta) -> some View {
        let seg = segments[segIndex]
        let pan = seg.pans[panIndex]
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Starts at")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].t },
                            set: { segments[segIndex].pans[panIndex].t = $0 }
                        ),
                        in: seg.start...max(seg.start + 0.1, seg.end - 0.1)
                    )
                    Text(timecode(pan.t))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Travel time")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].duration },
                            set: { segments[segIndex].pans[panIndex].duration = $0 }
                        ),
                        in: 0.15...1.5
                    )
                    Text(String(format: "%.2fs", pan.duration))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Zoom")
                    ThemedSlider(
                        value: panZoomBinding(segIndex: segIndex, panIndex: panIndex),
                        in: Self.zoomRange
                    )
                    Text(String(format: "%.1f×", zoomLevel(in: seg, after: pan)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Pan to X")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].cx },
                            set: { segments[segIndex].pans[panIndex].cx = $0 }
                        ),
                        in: 0...Double(meta.pixelWidth)
                    )
                    Text("\(Int(pan.cx))px")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                GridRow {
                    Text("Pan to Y")
                    ThemedSlider(
                        value: Binding(
                            get: { segments[segIndex].pans[panIndex].cy },
                            set: { segments[segIndex].pans[panIndex].cy = $0 }
                        ),
                        in: 0...Double(meta.pixelHeight)
                    )
                    Text("\(Int(pan.cy))px")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
            HStack {
                Button("Preview This Pan") {
                    startLivePreview(from: max(0, pan.t - 1.0))
                }
                .buttonStyle(.themed(.outline, size: .xs))
                .tooltip("Play this pan with the real camera, starting just before it")
                Spacer()
                Button("Remove Pan", role: .destructive) {
                    segments[segIndex].pans.remove(at: panIndex)
                    select(.segment(seg.id))
                }
                .buttonStyle(.themed(.destructive, size: .xs))
                .tooltip("Delete this pan; the zoom stays")
            }
            .padding(.top, 4)
        } label: {
            Text("Selected \(pan.zoom == nil ? "Pan" : "Zoom-in") (in zoom \(timecode(seg.start))–\(timecode(seg.end)))")
                .font(.callout.weight(.medium))
        }
    }

    /// Switch to the preview tab (real camera) and play from `t`.
    private func startLivePreview(from t: Double) {
        viewMode = .preview
        seek(to: t)
        player.play()
    }

    private func addPanAtPlayhead(segIndex: Int) {
        guard let meta else { return }
        let seg = segments[segIndex]
        let t = min(max(currentTime, seg.start), max(seg.start, seg.end - 0.2))
        // Aim at wherever the cursor was shortly after the pan begins.
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: t + 0.4)
        let pan = PanMove(
            t: t, duration: 0.5,
            cx: p?.x ?? Double(meta.pixelWidth) / 2,
            cy: p?.y ?? Double(meta.pixelHeight) / 2
        )
        segments[segIndex].pans.append(pan)
        select(.pan(segment: seg.id, pan: pan.id))
    }

    /// A pan at the playhead that also steps the zoom up half a level
    /// (capped at the range), aimed at the cursor like a plain pan.
    private func addZoomStepAtPlayhead(segIndex: Int) {
        guard let meta else { return }
        let seg = segments[segIndex]
        let t = min(max(currentTime, seg.start), max(seg.start, seg.end - 0.2))
        let level = min(zoomLevel(in: seg, at: t) + 0.5, Self.zoomRange.upperBound)
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: t + 0.4)
        let pan = PanMove(
            t: t, duration: 0.5,
            cx: p?.x ?? seg.cx,
            cy: p?.y ?? seg.cy,
            zoom: level
        )
        segments[segIndex].pans.append(pan)
        select(.pan(segment: seg.id, pan: pan.id))
    }

    // MARK: - Controls

    private var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if duration - currentTime < 0.05 { seek(to: 0) }
            player.play()
        }
    }

    /// Row between the preview and the timeline (Figma 76:13710): the
    /// preview / crop-box tabs, plan actions, then compare and export.
    private var controls: some View {
        HStack(spacing: 8) {
            IconTabsPicker(
                items: Array(ViewMode.allCases),
                selection: $viewMode,
                icon: { $0 == .preview ? "image-duotone" : "bounding-box" },
                fallback: { $0 == .preview ? "photo" : "viewfinder" },
                label: { $0 == .preview
                    ? "Preview: play the zooms as they will export"
                    : "Crop box: edit where each zoom looks on the full frame" }
            )
            .disabled(aiChat.running)
            // Inside a zoom's hold, "New zoom" tightens that zoom from the
            // playhead on instead of starting an overlapping one.
            let inHold = holdSegmentIndex
            Button {
                if let index = inHold {
                    addZoomStepAtPlayhead(segIndex: index)
                } else {
                    addZoomAtPlayhead()
                }
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "magnifying-glass-plus", size: 16, fallback: "plus.magnifyingglass")
                    Text(inHold == nil ? "New zoom" : "Zoom in further")
                }
            }
            .buttonStyle(.themed(.outline, size: .md, leadingIcon: true))
            .disabled(aiChat.running)
            .tooltip(inHold == nil
                  ? "Add a zoom at the playhead"
                  : "Zoom in further from the playhead on, staying inside this zoom")
            Button {
                if let index = inHold { addPanAtPlayhead(segIndex: index) }
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "arrows-out-cardinal", size: 16, fallback: "arrow.up.and.down.and.arrow.left.and.right")
                    Text("New pan")
                }
            }
            .buttonStyle(.themed(.outline, size: .md, leadingIcon: true))
            .disabled(aiChat.running || inHold == nil)
            .tooltip(inHold == nil
                  ? "Move the playhead inside a zoom to add a pan there"
                  : "Glide the camera to a new spot from the playhead on, staying inside this zoom")
            DropdownButton(
                id: "editor.planSource", edge: .top, alignment: .leading,
                style: { _ in .themed(.outline, size: .md, trailingIcon: true) },
                items: { planSourceItems }
            ) { _ in
                HStack(spacing: 6) {
                    Text("Start from")
                    Icon(name: "caret-down", size: 16, fallback: "chevron.down")
                }
            }
            .disabled(aiChat.running)
            .tooltip("Load the zooms from the current plan, an earlier export, or regenerate them from the click log")
            Button {
                withAnimation { showAIPanel.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if aiChat.running {
                        ProgressView().controlSize(.mini)
                    }
                    Text("Polish with AI")
                }
            }
            .buttonStyle(.themed(.primary, size: .md, leadingIcon: aiChat.running))
            .tooltip("Open the AI Polish panel: hand the plan to Claude Code or Codex for editorial touch-up")
            Spacer()
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
                ExportProgressControls(fraction: fraction, width: 280) {
                    model.cancelExport(recording)
                }
            } else {
                ExportSplitButton(title: "Export with Zooms", edge: .top) {
                    recording.savePlan(segments)
                    model.export(recording)
                }
                .disabled(aiChat.running)
            }
        }
    }

    private func addZoomAtPlayhead() {
        guard let meta else { return }
        let start = min(currentTime, max(0, duration - 0.5))
        let end = min(start + 2.0, duration)
        // Center on wherever the cursor was at this moment, if we know.
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: start)
        let config = ZoomPlanner.Config()
        let segment = ZoomSegment(
            start: start,
            end: end,
            zoom: config.zoomLevel,
            cx: p?.x ?? Double(meta.pixelWidth) / 2,
            cy: p?.y ?? Double(meta.pixelHeight) / 2
        )
        segments.append(segment)
        select(.segment(segment.id))
    }

    // MARK: - Helpers

    private func seek(to t: Double) {
        player.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    private func timecode(_ t: Double) -> String {
        let total = max(0, t)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }

    private func timecodeShort(_ t: Double) -> String {
        let total = Int(max(0, t).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Grip straddling one edge of a zoom's hold on the timeline. Shows the
/// horizontal-resize cursor and reports pointer travel while dragged; the
/// editor turns that into a new start or end time. Its zero-distance drag
/// claims the press ahead of the track's scrub gesture, so clicking a grip
/// does nothing and only a drag has an effect.
private struct TimelineEdgeHandle: View {
    static let width: CGFloat = 10

    let highlighted: Bool
    let dragging: Bool
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        let active = hovering || dragging
        Color.clear
            .frame(width: Self.width, height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(active ? 0.95 : (highlighted ? 0.6 : 0.4)))
                    .frame(width: 2, height: active ? 18 : 12)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside, !cursorPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorPushed = true
                } else if !inside, cursorPushed, !dragging {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in onDrag(value.translation.width) }
                    .onEnded { _ in
                        onEnd()
                        if cursorPushed, !hovering {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
            )
    }
}

/// Holds the editor window so we can grow/shrink it without moving the titlebar.
private final class EditorWindowHandle {
    weak var window: NSWindow?

    func growDown(by delta: CGFloat) {
        guard delta != 0 else { return }
        guard let window else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height += delta
        frame.origin.y = top - frame.size.height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.size.height
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
                frame.size.height = min(frame.size.height, visible.height)
            }
        }
        window.setFrame(frame, display: true, animate: false)
    }
}

private struct EditorWindowHandleView: NSViewRepresentable {
    let handle: EditorWindowHandle

    func makeNSView(context: Context) -> NSView {
        HandleView(handle: handle)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? HandleView)?.handle = handle
        handle.window = view.window
    }

    private final class HandleView: NSView {
        var handle: EditorWindowHandle
        init(handle: EditorWindowHandle) {
            self.handle = handle
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            handle.window = window
        }
    }
}
