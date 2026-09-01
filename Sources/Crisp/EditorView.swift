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

/// Post-recording editor: video preview with zooms applied live, a
/// toolbar that edits the zoom level, framing, clips and speed-ups at the
/// playhead, and a five-row timeline (video with its trim, zooms, framing,
/// clips, speed-ups).
/// Edits autosave to plan.json, which the exports then use instead of the
/// auto plan.
struct EditorView: View {
    let folder: URL

    @EnvironmentObject var model: AppModel
    @State var meta: RecordingMeta?
    @State var duration: Double = 1
    /// The master's duration in its own timescale. The preview composition's
    /// instruction must cover the video track exactly — rebuilding a CMTime
    /// from `duration` can land a tick short and AVFoundation then rejects
    /// the whole composition (black preview).
    @State var assetDuration: CMTime = CMTime(value: 60, timescale: 600)

    @State var segments: [ZoomSegment] = []
    /// The zoom started from the toolbar and still waiting for its end. It
    /// sits in `segments` with a provisional end (the next zoom or the end
    /// of the video) until End zoom closes it — the plan never carries an
    /// open-ended zoom the way it does an open pin or clip.
    @State var openZoomID: UUID?
    /// How the cursor is drawn, per recording; saved with the plan.
    @State var cursorStyle: CursorStyle = .classic
    /// The stretch the whole-video export keeps. Saved with the plan.
    @State var trim = Trim()
    /// Stretches that export as files of their own. Saved with the plan;
    /// the whole-video export ignores them.
    @State var clips: [Clip] = []
    /// Stretches every export fast-forwards. Saved with the plan; the
    /// preview approximates them by boosting the playback rate.
    @State var speeds: [SpeedWindow] = []
    /// The rate the next speed-up starts with — what the toolbar's rate
    /// button shows while the playhead isn't on a speed-up.
    @State var speedRate: Double = SpeedWindow.defaultRate
    /// Draw the rate in the video's bottom-right corner while a speed-up
    /// plays (preview and exports). Saved with the plan.
    @State var speedBadge = false
    /// A keyframe being dragged along the timeline, with the time it had
    /// when the drag began so it tracks the pointer instead of jumping to it.
    struct TimelineDrag {
        enum Target: Equatable {
            case zoomStart(UUID), zoomEnd(UUID)
            case pinStart(segment: UUID, pin: UUID), pinEnd(segment: UUID, pin: UUID)
            case clipStart(UUID), clipEnd(UUID)
            case speedStart(UUID), speedEnd(UUID)
            case trimStart, trimEnd
        }
        let target: Target
        let origin: Double
    }
    @State var timelineDrag: TimelineDrag?
    /// The plan's baked camera (levels + follower framing), rebuilt off the
    /// main thread a beat after the plan changes (see `scheduleRebuild`) so
    /// the crop box and the toolbar never re-run the follower per render.
    @State var cameraKeys: [ZoomPlanner.Keyframe] = []
    /// One planner per recording: it sorts the click log once.
    @State var plannerCache: ZoomPlanner?
    @State var player = AVPlayer()
    /// Preview transport speed: cycles 1× → 2× → 4× → 1× from the button
    /// under Play. Export is always 1×; this only affects the editor player.
    @State var playbackRate: Float = 1
    @State var currentTime: Double = 0
    @State var timeObserver: Any?
    @State var loadError: String?
    @State var rebuildTask: Task<Void, Never>?
    @State var saveTask: Task<Void, Never>?
    /// What the preview shows (the IconTabList on the toolbar): the real
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
    @StateObject var aiChat = AIChat()
    @State var showAIPanel = false
    /// True while the AI panel's composer field has keyboard focus — the
    /// timeline's bare-key Space shortcut yields only then, so Space still
    /// plays/pauses while the panel is open but not being typed into.
    @State var aiComposerFocused = false
    /// The moment "Send timestamp to chat" attached to the AI panel's next note.
    @State var aiAttachedTime: Double?
    @State private var windowHandle = EditorWindowHandle()
    /// How far the window is currently grown below its natural height for
    /// the compare view (see `syncWindowGrowth`).
    @State var windowGrown: CGFloat = 0

    var recording: Recording { Recording(folder: folder) }
    /// Wide enough for the toolbar (its controls compacted) with an export
    /// running.
    let baseMinWidth: CGFloat = 1260
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
                        // Plan edits are locked while a turn is in flight so the
                        // agent's reply can't clobber them (each control checks).
                        VStack(alignment: .leading, spacing: 16) {
                            controls
                            timeline
                        }
                    }
                    .padding(24)
                    if showAIPanel {
                        AIPanelView(
                            chat: aiChat,
                            recording: recording,
                            meta: meta,
                            duration: duration,
                            attachedTime: $aiAttachedTime,
                            currentTime: currentTime,
                            composerIsFocused: $aiComposerFocused,
                            segments: segments,
                            onApply: { loadPlan($0) },
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
        .frame(minWidth: showAIPanel ? baseMinWidth + AIPanelView.width : baseMinWidth, minHeight: 744)
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
        .onChange(of: viewMode) { _, _ in
            if comparing { setComparing(false) }
            player.currentItem?.videoComposition = makeComposition()
        }
        .onChange(of: cursorStyle) { _, _ in scheduleRebuild() }
        .onChange(of: clips) { _, _ in schedulePlanSave() }
        .onChange(of: speeds) { _, _ in
            // The badge windows are baked into the preview composition.
            if speedBadge { player.currentItem?.videoComposition = makeComposition() }
            schedulePlanSave()
        }
        .onChange(of: speedBadge) { _, _ in
            player.currentItem?.videoComposition = makeComposition()
            schedulePlanSave()
        }
        .onChange(of: trim) { _, _ in schedulePlanSave() }
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
            plannerCache = ZoomPlanner(meta: m)
        } catch {
            loadError = "Could not load this recording's click log: \(error.localizedDescription)"
            return
        }
        Task {
            do {
                let asset = AVURLAsset(url: recording.masterURL)
                assetDuration = try await asset.load(.duration)
                duration = assetDuration.seconds
                let plan = recording.loadPlan()
                trim = plan?.trim ?? Trim()
                clips = plan?.clips ?? []
                speeds = plan?.speeds ?? []
                speedBadge = plan?.speedBadge ?? false
                segments = plan?.segments ?? autoSegments()
                cursorStyle = plan?.cursorStyle ?? .classic
                cameraKeys = planner().keyframes(from: segments, duration: duration)
                compareBaseline = segments
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = makeComposition()
                player.replaceCurrentItem(with: item)
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: 30), queue: .main
                ) { time in
                    currentTime = time.seconds
                    enforceCompareLoop()
                    enforcePreviewSpeed()
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

    /// The window is grown below its natural height while the compare view
    /// is showing, so the preview and timeline stay put. The target height
    /// is derived from state; only the delta since the last sync is applied.
    func syncWindowGrowth() {
        let wanted: CGFloat = comparing ? Self.compareExpansion : 0
        windowHandle.growDown(by: wanted - windowGrown)
        windowGrown = wanted
    }

    /// Enter/leave the stacked before/after preview. Entering grows the
    /// window so each half keeps a usable size, and starts playing from the
    /// first edited window.
    func setComparing(_ on: Bool) {
        guard on != comparing else { return }
        if on {
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

    /// Debounced, and off the main thread: bake the camera for the plan as
    /// it now stands, then autosave it and swap in a fresh preview
    /// composition. A drag mutates the plan on every pointer sample; only
    /// the last one, 150ms on, pays for the follower.
    func scheduleRebuild() {
        rebuildTask?.cancel()
        let plan = segments
        let style = cursorStyle
        let planner = planner()
        let duration = duration
        rebuildTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let keys = await Task.detached(priority: .userInitiated) {
                planner.keyframes(from: plan, duration: duration)
            }.value
            guard !Task.isCancelled else { return }
            cameraKeys = keys
            savePlanNow(segments: plan, cursorStyle: style)
            player.currentItem?.videoComposition = makeComposition()
        }
    }

    /// Debounced autosave for edits that don't move the camera (the trim
    /// and the clips): a drag mutates them on every pointer sample; only
    /// the last one writes.
    func schedulePlanSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            savePlanNow()
        }
    }

    /// The plan as it stands, with `segments`/`cursorStyle` overridable by
    /// a rebuild that baked a particular version of them.
    func currentPlan(segments: [ZoomSegment]? = nil, cursorStyle: CursorStyle? = nil) -> ZoomPlan {
        ZoomPlan(
            segments: segments ?? self.segments, cursorStyle: cursorStyle ?? self.cursorStyle,
            trim: trim, clips: clips, speeds: speeds, speedBadge: speedBadge
        )
    }

    func savePlanNow(segments: [ZoomSegment]? = nil, cursorStyle: CursorStyle? = nil) {
        recording.savePlan(currentPlan(segments: segments, cursorStyle: cursorStyle))
        // The sidebar caches zoom/step counts; every plan write refreshes
        // them, so the library stays live while the editor is open.
        model.refreshSummary(for: folder)
    }

    // MARK: - Frame overlay

    static let zoomRange = ZoomPlanner.zoomRange

    /// Crop box over the full frame in the box view: where the camera is at
    /// the playhead, editable inside a zoom's hold.
    @ViewBuilder
    var frameOverlay: some View {
        if let meta, viewMode == .box, !comparing, let target = boxTarget {
            ZoomFrameOverlay(
                pixelWidth: Double(meta.pixelWidth),
                pixelHeight: Double(meta.pixelHeight),
                zoomRange: Self.zoomRange,
                zoomEditable: target.zoomEditable,
                editable: target.movable,
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
        /// The corners set the level: the playhead is parked on a level
        /// keyframe (the zoom's own, or a step once it has eased in).
        var zoomEditable: Bool
        /// Dragging the box moves a pin: the playhead is inside one. While
        /// the camera follows the cursor the box only mirrors it.
        var movable: Bool
    }

    /// Resolve the crop box from the playhead. Mid-ramp and mid-step it is
    /// view-only; inside the hold its corners edit the level in effect and,
    /// while a pin applies, dragging it places that pin.
    var boxTarget: BoxTarget? {
        guard let index = boxSegmentIndex else { return nil }
        let seg = segments[index]
        let span = motionSpan(for: seg)
        let camera = camera(at: currentTime)
        var cx = Binding<Double>.constant(camera.center.x)
        var cy = Binding<Double>.constant(camera.center.y)
        guard currentTime >= span.arrive - Self.keyframeSlop, currentTime <= span.end + Self.keyframeSlop,
              let zoom = levelBinding(in: index) else {
            return BoxTarget(cx: cx, cy: cy, zoom: .constant(camera.zoom), zoomEditable: false, movable: false)
        }
        var movable = false
        if let pinID = pinIDAtPlayhead(in: seg) {
            movable = true
            cx = Binding(
                get: { pin(pinID, in: index)?.x ?? camera.center.x },
                set: { v in updatePin(pinID, in: index) { $0.x = v } }
            )
            cy = Binding(
                get: { pin(pinID, in: index)?.y ?? camera.center.y },
                set: { v in updatePin(pinID, in: index) { $0.y = v } }
            )
        }
        return BoxTarget(cx: cx, cy: cy, zoom: zoom, zoomEditable: true, movable: movable)
    }

    /// The zoom whose motion window (ramps included) contains the playhead.
    var boxSegmentIndex: Int? {
        segments.firstIndex {
            let span = motionSpan(for: $0)
            return currentTime >= span.moveStart && currentTime <= span.outEnd
        }
    }

    func pin(_ pinID: UUID, in index: Int) -> PinWindow? {
        guard segments.indices.contains(index) else { return nil }
        return segments[index].pins.first { $0.id == pinID }
    }

    func updatePin(_ pinID: UUID, in index: Int, _ edit: (inout PinWindow) -> Void) {
        guard segments.indices.contains(index),
              let p = segments[index].pins.firstIndex(where: { $0.id == pinID }) else { return }
        edit(&segments[index].pins[p])
    }

    /// Where the camera really is at `t` under the current plan.
    func camera(at t: Double) -> Camera {
        let keys = cameraKeys.isEmpty ? planner().keyframes(from: segments, duration: duration) : cameraKeys
        return ZoomPlanner.evaluate(keys, at: t)
    }

    /// When a step begins easing and when it has reached its level.
    func stepWindow(_ step: ZoomStep, in seg: ZoomSegment) -> (start: Double, end: Double) {
        planner().stepWindow(step, in: seg, duration: duration)
    }

    /// When each of a zoom's pins applies, in time order.
    func pinWindows(for seg: ZoomSegment) -> [(id: UUID, from: Double, until: Double)] {
        planner().pinWindows(for: seg, duration: duration)
    }

    /// The steps that begin inside a zoom's hold, in time order.
    func holdSteps(in seg: ZoomSegment) -> [ZoomStep] {
        planner().holdSteps(for: seg, duration: duration)
    }

    /// Slack around a keyframe's time, so a playhead parked on one still
    /// counts as being on it after the player reports back.
    static let keyframeSlop = 0.03

    /// True while the playhead is strictly inside one of `seg`'s step eases.
    func isMidStep(in seg: ZoomSegment) -> Bool {
        holdSteps(in: seg).contains { step in
            let window = stepWindow(step, in: seg)
            return currentTime > window.start + Self.keyframeSlop
                && currentTime < window.end - Self.keyframeSlop
        }
    }

    /// Index of the latest step whose level the camera has reached by the
    /// playhead, if any.
    func activeStepIndex(in seg: ZoomSegment) -> Int? {
        guard let step = holdSteps(in: seg).last(where: {
            stepWindow($0, in: seg).end <= currentTime + Self.keyframeSlop
        }) else { return nil }
        return seg.steps.firstIndex { $0.id == step.id }
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
