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
    @State var meta: RecordingMeta?
    @State var duration: Double = 1
    enum Selection: Equatable {
        case segment(UUID)
        case pan(segment: UUID, pan: UUID)
    }

    @State var segments: [ZoomSegment] = []
    @State var selection: Selection?
    /// The hold edge being dragged on the timeline, with the time it had when
    /// the drag began so the edge tracks the pointer instead of jumping to it.
    struct EdgeDrag: Equatable {
        let id: UUID
        let edge: HorizontalEdge
        let origin: Double
    }
    @State var edgeDrag: EdgeDrag?
    @State var player = AVPlayer()
    @State var currentTime: Double = 0
    @State var timeObserver: Any?
    @State var loadError: String?
    @State var rebuildTask: Task<Void, Never>?
    /// What the preview shows (the IconTabList above the timeline): the real
    /// zoomed camera, or the full frame with an editable crop box.
    enum ViewMode: String, CaseIterable, Identifiable {
        case preview, box
        var id: String { rawValue }
    }
    @State var viewMode: ViewMode = .preview
    /// Plan the split "Compare" preview plays against: the plan as loaded, or
    /// the one in effect before the last AI reply / revert / reset.
    @State var compareBaseline: [ZoomSegment]?
    /// What the baseline is compared with while comparing: a specific plan
    /// (the result of one AI reply) or, when nil, the live `segments`.
    @State var compareTarget: [ZoomSegment]?
    /// True while the preview shows baseline (top) and current (bottom)
    /// stacked, looping over the zooms that differ.
    @State var comparing = false
    /// Where the working plan was last loaded from, with the plan it loaded.
    /// The "Start from" check mark stays on a source only while `segments`
    /// still equals that plan; any edit makes it simply "Current plan".
    enum PlanSource: Equatable {
        case current
        case auto(loaded: [ZoomSegment])
        case export(URL, loaded: [ZoomSegment])

        var isAuto: Bool {
            if case .auto = self { return true } else { return false }
        }
        var exportURL: URL? {
            if case .export(let url, _) = self { return url } else { return nil }
        }
    }
    @State var planSource: PlanSource = .current

    @StateObject var aiChat = AIChat()
    @State var showAIPanel = false
    @State private var windowHandle = EditorWindowHandle()
    /// How far the window is currently grown below its natural height for
    /// the inspector and/or the compare view (see `syncWindowGrowth`).
    @State var windowGrown: CGFloat = 0

    var recording: Recording { Recording(folder: folder) }
    let baseMinWidth: CGFloat = 880
    /// Room for the zoom/pan GroupBox plus the VStack gap above it.
    static let inspectorExpansion: CGFloat = 260
    /// Extra height so each half of the stacked compare view stays usable.
    static let compareExpansion: CGFloat = 220

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
                                // A historical Compare must not outlive the plan it
                                // was comparing; from here on compare shows the plan
                                // this apply replaced vs. the live segments.
                                compareTarget = nil
                                compareBaseline = segments
                                segments = plan
                                select(nil)
                            },
                            onCompare: { before, after in
                                compareBaseline = before
                                compareTarget = after
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
            model.editorOpened(folder)
            load()
            Task { await aiChat.detectProviders() }
        }
        .onDisappear {
            model.editorClosed(folder)
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

    func load() {
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

    // MARK: - Compare

    /// Differences between the baseline and the current plan, or nil when
    /// there is nothing to compare.
    var planDiff: PlanDiff? {
        guard let compareBaseline else { return nil }
        let diff = PlanDiff(
            before: compareBaseline, after: compareTarget ?? segments,
            planner: planner(), duration: duration
        )
        return diff.isEmpty ? nil : diff
    }

    /// The window is grown below its natural height while the inspector
    /// and/or the compare view are showing, so the preview and timeline stay
    /// put. The target height is derived from state; only the delta since
    /// the last sync is applied.
    func syncWindowGrowth() {
        let wanted = (selection != nil ? Self.inspectorExpansion : 0)
            + (comparing ? Self.compareExpansion : 0)
        windowHandle.growDown(by: wanted - windowGrown)
        windowGrown = wanted
    }

    /// Enter/leave the stacked before/after preview. Entering clears any
    /// selection (the crop box has no meaning across two plans), grows the
    /// window so each half keeps a usable size, and starts playing from the
    /// first edited window.
    func setComparing(_ on: Bool) {
        guard on != comparing else { return }
        if on {
            select(nil)
            comparing = true
            syncWindowGrowth()
            player.currentItem?.videoComposition = makeComposition()
            if let first = planDiff?.ranges.first { seek(to: first.start) }
            player.play()
        } else {
            comparing = false
            compareTarget = nil
            syncWindowGrowth()
            player.currentItem?.videoComposition = makeComposition()
        }
    }

    /// While comparing, playback stays inside the edited windows: reaching the
    /// end of one (or scrubbing into unchanged footage) jumps to the next,
    /// wrapping to the first.
    func enforceCompareLoop() {
        guard comparing, player.timeControlStatus == .playing,
              let ranges = planDiff?.ranges, !ranges.isEmpty else { return }
        let t = currentTime
        if ranges.contains(where: { t >= $0.start - 0.05 && t < $0.end - 0.03 }) { return }
        let next = ranges.first { $0.start > t } ?? ranges[0]
        seek(to: next.start)
    }

    /// "Before" / "After" tags pinned to the top-left of each stacked half,
    /// positioned against the aspect-fitted video rect.
    var compareLabels: some View {
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

    func compareTag(_ text: String) -> some View {
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
    func scheduleRebuild() {
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
    var frameOverlay: some View {
        if let meta, viewMode == .box, !comparing, let target = boxTarget {
            ZoomFrameOverlay(
                pixelWidth: Double(meta.pixelWidth),
                pixelHeight: Double(meta.pixelHeight),
                zoomRange: Self.zoomRange,
                zoomEditable: target.editable,
                editable: target.editable,
                cx: target.cx,
                cy: target.cy,
                zoom: target.zoom
            )
        }
    }

    /// What the crop box shows and edits.
    struct BoxTarget {
        var cx: Binding<Double>
        var cy: Binding<Double>
        var zoom: Binding<Double>
        var editable: Bool
    }

    /// Resolve the crop box from the playhead and selection. Outside the
    /// zoom's hold it only mirrors where the camera really is (full frame, or
    /// the in-between framing mid-ramp). Inside, it edits the selected pan,
    /// else the latest pan that has started, else the zoom's own framing;
    /// resizing the box at a pan gives that move its own zoom level.
    var boxTarget: BoxTarget? {
        guard let index = boxSegmentIndex else { return nil }
        let seg = segments[index]
        let span = motionSpan(for: seg)
        if currentTime < span.arrive || currentTime > span.end {
            let camera = ZoomPlanner.evaluate(
                planner().keyframes(from: segments, duration: duration),
                at: currentTime
            )
            return BoxTarget(
                cx: .constant(camera.center.x), cy: .constant(camera.center.y),
                zoom: .constant(camera.zoom), editable: false
            )
        }
        var panIndex = activePanIndex(in: seg)
        if case .pan(_, let panID) = selection,
           let selected = seg.pans.firstIndex(where: { $0.id == panID }) {
            panIndex = selected
        }
        if let panIndex {
            return BoxTarget(
                cx: $segments[index].pans[panIndex].cx,
                cy: $segments[index].pans[panIndex].cy,
                zoom: panZoomBinding(segIndex: index, panIndex: panIndex),
                editable: true
            )
        }
        return BoxTarget(
            cx: $segments[index].cx, cy: $segments[index].cy,
            zoom: $segments[index].zoom, editable: true
        )
    }

    /// The zoom whose crop box the box view shows: the selection, or else
    /// whichever zoom's motion window contains the playhead.
    var boxSegmentIndex: Int? {
        if let index = selectedSegmentIndex { return index }
        return segments.firstIndex {
            let span = motionSpan(for: $0)
            return currentTime >= span.moveStart && currentTime <= span.outEnd
        }
    }

    /// The zoom level in effect once `pan` has completed: its own, or the
    /// latest earlier step's, or the zoom's base level.
    func zoomLevel(in seg: ZoomSegment, after pan: PanMove) -> Double {
        seg.pans
            .filter { $0.t <= pan.t && $0.zoom != nil }
            .max { $0.t < $1.t }?.zoom ?? seg.zoom
    }

    /// The zoom level the camera has at `t` inside `seg`'s hold.
    func zoomLevel(in seg: ZoomSegment, at t: Double) -> Double {
        seg.pans
            .filter { $0.t <= t && $0.zoom != nil }
            .max { $0.t < $1.t }?.zoom ?? seg.zoom
    }

    /// Read the level a pan lands on; write it as that pan's own level.
    func panZoomBinding(segIndex: Int, panIndex: Int) -> Binding<Double> {
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
    var holdSegmentIndex: Int? {
        segments.firstIndex { currentTime >= $0.start && currentTime <= $0.end }
    }

    /// Index of the pan whose target the camera shows at the playhead, if any.
    func activePanIndex(in seg: ZoomSegment) -> Int? {
        let span = motionSpan(for: seg)
        guard currentTime >= span.arrive, currentTime <= span.end else { return nil }
        return seg.pans.indices
            .filter { seg.pans[$0].t <= currentTime }
            .max { seg.pans[$0].t < seg.pans[$1].t }
    }

    // MARK: - Helpers

    func seek(to t: Double) {
        player.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func timecode(_ t: Double) -> String {
        let total = max(0, t)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }

    func timecodeShort(_ t: Double) -> String {
        let total = Int(max(0, t).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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
