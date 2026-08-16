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
    @State private var player = AVPlayer()
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    @State private var loadError: String?
    @State private var rebuildTask: Task<Void, Never>?

    @State private var aiProviders: [AIProvider] = []
    @State private var aiProvider: AIProvider?
    @State private var aiNote = ""
    @State private var aiRunning = false
    @State private var aiStatus: String?
    @State private var aiBackup: [ZoomSegment]?

    private var recording: Recording { Recording(folder: folder) }

    var body: some View {
        Group {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .padding()
            } else {
                VStack(spacing: 12) {
                    PlayerLayerView(player: player)
                        .frame(minHeight: 300)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    timeline
                    inspector
                    aiRow
                    controls
                }
                .padding(14)
            }
        }
        .frame(minWidth: 880, minHeight: 660)
        .navigationTitle("Zoom Editor — \(recording.name)")
        .onAppear {
            load()
            Task {
                aiProviders = await AIDirector.detectProviders()
                aiProvider = aiProviders.first
            }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player.pause()
        }
        .onChange(of: segments) { _, _ in
            scheduleRebuild()
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
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = makeComposition()
                player.replaceCurrentItem(with: item)
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: 30), queue: .main
                ) { time in
                    currentTime = time.seconds
                }
            } catch {
                loadError = "Could not load the master video: \(error.localizedDescription)"
            }
        }
    }

    private func planner() -> ZoomPlanner {
        guard let meta else { return ZoomPlanner(width: 1, height: 1) }
        var p = ZoomPlanner(width: Double(meta.pixelWidth), height: Double(meta.pixelHeight))
        p.config = ZoomPlanner.Config.fromUserDefaults()
        return p
    }

    private func autoSegments() -> [ZoomSegment] {
        guard let meta else { return [] }
        return planner().segments(events: meta.events, duration: duration)
    }

    private func makeComposition() -> AVMutableVideoComposition? {
        guard let meta else { return nil }
        let keys = planner().keyframes(from: segments, duration: duration)
        let composer = FrameComposer(meta: meta, keys: keys)
        return CameraCompositor.makeComposition(
            duration: CMTime(seconds: max(duration, 0.1), preferredTimescale: 600),
            composer: composer
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

    // MARK: - Timeline

    /// True when this segment or one of its pans is selected.
    private func isHighlighted(_ seg: ZoomSegment) -> Bool {
        switch selection {
        case .segment(seg.id): return true
        case .pan(segment: seg.id, pan: _): return true
        default: return false
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 2) {
            markerLane
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 30)
                    ForEach(segments) { seg in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isHighlighted(seg)
                                  ? Color.accentColor
                                  : Color.accentColor.opacity(0.45))
                            .frame(
                                width: max(6, (seg.end - seg.start) / duration * w),
                                height: 30
                            )
                            .offset(x: seg.start / duration * w)
                        // Tick where each pan lands inside the block.
                        ForEach(seg.pans) { pan in
                            Rectangle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: 2, height: 30)
                                .offset(x: min(max(0, pan.t / duration * w), w - 2))
                        }
                    }
                    Rectangle()
                        .fill(.red)
                        .frame(width: 2, height: 38)
                        .offset(x: min(max(0, currentTime / duration * w), w - 2), y: -4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let t = min(max(0, value.location.x / w * duration), duration)
                        seek(to: t)
                        selection = segments
                            .first { t >= $0.start && t <= $0.end }
                            .map { .segment($0.id) }
                    }
                )
            }
            .frame(height: 38)
            HStack {
                Text(timecode(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drag the bar to scrub · 🔍 selects a zoom · → selects a pan")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(timecode(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Icon lane above the bar: a magnifier where each zoom-in starts, an
    /// arrow where each pan starts. Clicking selects for editing.
    private var markerLane: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(segments) { seg in
                    timelineMarker(
                        systemImage: "plus.magnifyingglass",
                        selected: selection == .segment(seg.id),
                        x: min(max(0, seg.start / duration * w - 7), w - 14)
                    ) {
                        selection = .segment(seg.id)
                        seek(to: seg.start)
                    }
                    ForEach(seg.pans) { pan in
                        timelineMarker(
                            systemImage: "arrow.right.circle.fill",
                            selected: selection == .pan(segment: seg.id, pan: pan.id),
                            x: min(max(0, pan.t / duration * w - 7), w - 14)
                        ) {
                            selection = .pan(segment: seg.id, pan: pan.id)
                            seek(to: pan.t)
                        }
                    }
                }
            }
        }
        .frame(height: 18)
    }

    private func timelineMarker(
        systemImage: String, selected: Bool, x: Double, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .offset(x: x)
        .help(systemImage.hasPrefix("plus") ? "Zoom start — click to edit" : "Pan start — click to edit")
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
                        Slider(
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
                        Slider(
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
                        Slider(
                            value: Binding(
                                get: { segments[index].zoom },
                                set: { segments[index].zoom = $0 }
                            ),
                            in: 1.2...3.0
                        )
                        Text(String(format: "%.1f×", seg.zoom))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    GridRow {
                        Text("Center X")
                        Slider(
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
                        Slider(
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
                        seek(to: max(0, seg.start - 1.2))
                        player.play()
                    }
                    Button("Add Pan at Playhead") {
                        addPanAtPlayhead(segIndex: index)
                    }
                    .help("Insert a camera pan inside this zoom at the current playhead")
                    Spacer()
                    Button("Remove Zoom", role: .destructive) {
                        segments.remove(at: index)
                        selection = nil
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Selected Zoom")
                    .font(.callout.weight(.medium))
            }
        } else {
            Text("Scrub to a zoom on the timeline to select and edit it, or add one at the playhead. Click 🔍/→ markers to edit zooms and pans.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    private func panInspector(segIndex: Int, panIndex: Int, meta: RecordingMeta) -> some View {
        let seg = segments[segIndex]
        let pan = seg.pans[panIndex]
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Starts at")
                    Slider(
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
                    Slider(
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
                    Text("Pan to X")
                    Slider(
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
                    Slider(
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
                    seek(to: max(0, pan.t - 1.0))
                    player.play()
                }
                Spacer()
                Button("Remove Pan", role: .destructive) {
                    segments[segIndex].pans.remove(at: panIndex)
                    selection = .segment(seg.id)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Selected Pan (in zoom \(timecode(seg.start))–\(timecode(seg.end)))")
                .font(.callout.weight(.medium))
        }
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
        selection = .pan(segment: seg.id, pan: pan.id)
    }

    // MARK: - Controls

    // MARK: - AI polish

    /// Provider row: hand the current plan to Claude Code or Codex (using the
    /// user's existing CLI sign-in / subscription) for editorial touch-up.
    @ViewBuilder
    private var aiRow: some View {
        if !aiProviders.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                TextField("Director's note (optional) — e.g. “calmer, only zoom on the form”", text: $aiNote)
                    .textFieldStyle(.roundedBorder)
                    .disabled(aiRunning)
                Picker("", selection: $aiProvider) {
                    ForEach(aiProviders) { provider in
                        Text(provider.kind.rawValue).tag(Optional(provider))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(aiRunning)
                if aiRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Polishing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("AI Polish") { runAIPolish() }
                        .disabled(aiProvider == nil || segments.isEmpty)
                        .help("Send the click log, current plan, and video frames to the selected agent for timing/framing touch-up (~10–60s)")
                    if aiBackup != nil {
                        Button("Undo AI") {
                            if let backup = aiBackup {
                                segments = backup
                                aiBackup = nil
                                aiStatus = nil
                                selection = nil
                            }
                        }
                    }
                }
            }
            if let aiStatus {
                Text(aiStatus)
                    .font(.caption)
                    .foregroundStyle(aiStatus.hasPrefix("AI") ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func runAIPolish() {
        guard let provider = aiProvider, let meta, !aiRunning else { return }
        aiRunning = true
        aiStatus = nil
        let current = segments
        let dur = duration
        let note = aiNote
        let rec = recording
        Task {
            do {
                let polished = try await AIDirector.polish(
                    recording: rec, meta: meta, duration: dur,
                    segments: current, note: note, provider: provider
                )
                aiBackup = current
                segments = polished
                selection = nil
                aiStatus = "AI polished: \(current.count) → \(polished.count) zooms. Review the preview — Undo AI restores your previous plan."
            } catch {
                aiStatus = error.localizedDescription
            }
            aiRunning = false
        }
    }

    private var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying {
                    player.pause()
                } else {
                    if duration - currentTime < 0.05 { seek(to: 0) }
                    player.play()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 28)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")
            Button("Add Zoom at Playhead") {
                addZoomAtPlayhead()
            }
            Button("Revert to Auto") {
                try? FileManager.default.removeItem(at: recording.planURL)
                segments = autoSegments()
                selection = nil
            }
            .help("Discard edits and regenerate zooms from the click log")
            Spacer()
            if let fraction = model.exportProgress[folder] {
                ProgressView(value: fraction)
                    .frame(width: 140)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button("Export with Zooms") {
                    recording.savePlan(segments)
                    model.export(recording)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func addZoomAtPlayhead() {
        guard let meta else { return }
        let start = min(currentTime, max(0, duration - 0.5))
        let end = min(start + 2.0, duration)
        // Center on wherever the cursor was at this moment, if we know.
        let p = FrameComposer.cursorPosition(samples: meta.samples, at: start)
        let config = ZoomPlanner.Config.fromUserDefaults()
        let segment = ZoomSegment(
            start: start,
            end: end,
            zoom: config.zoomLevel,
            cx: p?.x ?? Double(meta.pixelWidth) / 2,
            cy: p?.y ?? Double(meta.pixelHeight) / 2
        )
        segments.append(segment)
        selection = .segment(segment.id)
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
}
