import SwiftUI
import AppKit

// The editor's timeline (Figma 93:1015): a ruler and three rows in one
// card. The video row is the recording with the playhead on it; the zoom
// row has one blue bar per zoom's hold, labelled with its level (divided
// where a step changes it) and with grips on its edges to move where the
// zoom starts and ends; the framing row shows, for each hold, where the
// camera follows the cursor (grey, cursor glyph) and where it holds a
// pinned viewport (orange band, pin glyph, edges draggable). A press
// anywhere scrubs; the toolbar above edits the moment under the playhead.
extension EditorView {
    // MARK: - Geometry

    static let rowHeight: CGFloat = 20
    static let rowGap: CGFloat = 8
    /// Row icon plus the gap before each track.
    static let rowInset: CGFloat = 32
    static let rulerHeight: CGFloat = 16
    static var rowsHeight: CGFloat { rowHeight * 3 + rowGap * 2 }
    static let barCorner: CGFloat = 8
    static let barGlyphSize: CGFloat = 12
    /// A hold part narrower than this drops its level label.
    static let minLabelledWidth: CGFloat = 36

    /// The camera-motion window for a segment: the zoom-in ramp begins
    /// `leadIn` early and the zoom-out eases back after the hold ends.
    func motionSpan(
        for seg: ZoomSegment
    ) -> (moveStart: Double, arrive: Double, end: Double, outEnd: Double) {
        planner().motionSpan(for: seg, duration: duration)
    }

    /// While comparing, the zooms that differ from the baseline stand out
    /// and the rest fade; otherwise every bar is lit.
    func isLit(_ seg: ZoomSegment) -> Bool {
        guard comparing, let diff = planDiff else { return true }
        return diff.changed.contains(seg.id)
    }

    func x(of t: Double, width w: CGFloat) -> CGFloat {
        duration > 0 ? t / duration * w : 0
    }

    func time(atX x: CGFloat, width w: CGFloat) -> Double {
        min(max(0, Double(x / max(w, 1)) * duration), duration)
    }

    /// A hold's bar on a track: its x and width (at least 6pt wide).
    func holdBounds(_ seg: ZoomSegment, width w: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let holdX = x(of: seg.start, width: w)
        return (holdX, max(6, x(of: min(seg.end, duration), width: w) - holdX))
    }

    // MARK: - Timeline

    var timeline: some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                togglePlayback()
            } label: {
                Icon(
                    name: isPlaying ? "pause" : "play", size: 16,
                    fallback: isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(.themed(.outline, size: .md, iconOnly: true))
            // Unmodified key equivalents are matched before the focused view
            // sees the event: while the AI panel is open (its composer takes
            // focus), Space must type a space, not toggle playback.
            .keyboardShortcut(showAIPanel ? nil : KeyboardShortcut(.space, modifiers: []))
            .tooltip("Play / pause (Space)")
            VStack(alignment: .leading, spacing: Self.rowGap) {
                ruler
                GeometryReader { geo in
                    let w = max(1, geo.size.width - Self.rowInset)
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: Self.rowGap) {
                            row(icon: "video-camera", fallback: "video",
                                help: "The recording — press anywhere on the timeline to scrub") {
                                videoTrack(width: w)
                            }
                            row(icon: "magnifying-glass-plus", fallback: "plus.magnifyingglass",
                                help: "Zooms: one bar per zoom with its level; drag a bar's edges to change when it starts and ends") {
                                zoomTrack(width: w)
                            }
                            row(icon: "mouse-middle-click", fallback: "cursorarrow.motionlines",
                                help: "Framing: grey where the camera follows the cursor, orange where the viewport is pinned") {
                                framingTrack(width: w)
                            }
                        }
                        playhead(width: w)
                    }
                    .contentShape(Rectangle())
                    .pointingHandCursor()
                    // One gesture for the rows: every press scrubs. Grips carry
                    // their own zero-distance drags, which claim the press first.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                seek(to: time(atX: value.location.x - Self.rowInset, width: w))
                            }
                    )
                }
                .frame(height: Self.rowsHeight)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(Theme.iconTabsList))
            .disabled(aiChat.running)
        }
    }

    /// "0:00", a tick every 5pt, and the length at the far end.
    var ruler: some View {
        HStack(spacing: 8) {
            Text("0:00")
                .font(Theme.font(.label12))
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .frame(width: Self.rowInset - 8, alignment: .leading)
            Canvas { context, size in
                var x: CGFloat = 0.5
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 4, width: 1, height: 8)), with: .color(Theme.ruler))
                    x += 5
                }
            }
            .overlay(alignment: .trailing) {
                Text(shortTimecode(duration))
                    .font(Theme.font(.label12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.foreground)
                    .padding(.leading, 6)
                    .background(Theme.iconTabsList)
            }
        }
        .frame(height: Self.rulerHeight)
    }

    /// A row's 16pt icon and its track.
    func row<Track: View>(icon: String, fallback: String, help: String, @ViewBuilder track: () -> Track) -> some View {
        HStack(spacing: 16) {
            Icon(name: icon, size: 16, fallback: fallback)
                .foregroundStyle(Theme.foreground)
                .tooltip(help)
            track()
        }
        .frame(height: Self.rowHeight)
    }

    /// A bar on a track: a solid fill with a white@50 hairline (Figma 93:789).
    func bar(_ fill: Color, border: Color = Theme.barBorder) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.barCorner, style: .continuous)
        return shape.fill(fill)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
    }

    // MARK: - Video row

    func videoTrack(width w: CGFloat) -> some View {
        bar(Theme.videoBar)
            .frame(width: w, height: Self.rowHeight)
            .allowsHitTesting(false)
    }

    // MARK: - Zoom row

    func zoomTrack(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Self.barCorner, style: .continuous)
                .fill(Theme.timelineTrack)
                .frame(width: w, height: Self.rowHeight)
                .allowsHitTesting(false)
            ForEach(segments) { seg in
                zoomBar(for: seg, width: w)
            }
            if comparing, let diff = planDiff {
                ForEach(diff.removed) { seg in
                    removedBar(for: seg, width: w)
                }
            }
        }
        .frame(width: w, height: Self.rowHeight, alignment: .topLeading)
    }

    /// One stretch of a hold at a single level: from the zoom's start (or a
    /// step) to the next step (or the end).
    struct HoldPart: Identifiable {
        let id: String
        let x: CGFloat
        let width: CGFloat
        let level: Double
        let help: String
    }

    /// The hold split at each step, left to right.
    func holdParts(for seg: ZoomSegment, x holdX: CGFloat, width holdW: CGFloat, trackWidth w: CGFloat) -> [HoldPart] {
        var edges: [(x: CGFloat, level: Double, help: String)] = [(
            holdX, seg.zoom,
            String(format: "Zoomed %.1f× — drag the edges to change when it starts and ends; the toolbar sets the level at the playhead", seg.zoom)
        )]
        for step in holdSteps(in: seg) {
            let window = stepWindow(step, in: seg)
            edges.append((
                x(of: window.start, width: w), step.zoom,
                String(format: "Zoom changes to %.1f× from here (eases over %.1fs)", step.zoom, window.end - window.start)
            ))
        }
        return edges.indices.map { i in
            let next = i + 1 < edges.count ? edges[i + 1].x : holdX + holdW
            return HoldPart(
                id: "\(seg.id)-\(i)", x: edges[i].x, width: max(0, next - edges[i].x),
                level: edges[i].level, help: edges[i].help
            )
        }
    }

    /// A zoom's hold as a blue bar with its level in every part, a hairline
    /// where a step changes it, and grips on both edges.
    @ViewBuilder
    func zoomBar(for seg: ZoomSegment, width w: CGFloat) -> some View {
        let (holdX, holdW) = holdBounds(seg, width: w)
        let lit = isLit(seg)

        bar(Theme.zoomBar)
            .frame(width: holdW, height: Self.rowHeight)
            .offset(x: holdX)
            .opacity(lit ? 1 : 0.4)
            .allowsHitTesting(false)

        // Each part carries its level and its tooltip; the press itself
        // falls through to the track gesture, which scrubs.
        ForEach(holdParts(for: seg, x: holdX, width: holdW, trackWidth: w)) { part in
            Color.clear
                .frame(width: part.width, height: Self.rowHeight)
                .overlay {
                    if part.width >= Self.minLabelledWidth {
                        Text(String(format: "%.1f×", part.level))
                            .font(Theme.font(.label12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.primaryForeground)
                    }
                }
                .contentShape(Rectangle())
                .offset(x: part.x)
                .tooltip(part.help)
        }

        ForEach(holdSteps(in: seg)) { step in
            Rectangle()
                .fill(Theme.barBorder)
                .frame(width: 1, height: Self.rowHeight - 4)
                .offset(x: x(of: stepWindow(step, in: seg).start, width: w), y: 2)
                .allowsHitTesting(false)
        }

        ForEach([HorizontalEdge.leading, .trailing], id: \.self) { edge in
            let edgeX = edge == .leading ? holdX : holdX + holdW
            let target: TimelineDrag.Target = edge == .leading ? .zoomStart(seg.id) : .zoomEnd(seg.id)
            TimelineEdgeHandle(
                color: Theme.zoomBar,
                dragging: timelineDrag?.target == target,
                onDrag: { dx in dragKeyframe(target, translation: dx, width: w) },
                onEnd: { timelineDrag = nil }
            )
            .offset(x: edgeX - TimelineEdgeHandle.width / 2)
            .tooltip(edge == .leading
                  ? "Zoom start — drag to change where this zoom starts"
                  : "Zoom end — drag to change where this zoom ends")
            .zIndex(3)
        }
    }

    /// A baseline zoom that the current plan no longer has: a dashed outline
    /// over its old hold, shown only while comparing.
    func removedBar(for seg: ZoomSegment, width w: CGFloat) -> some View {
        let (holdX, holdW) = holdBounds(seg, width: w)
        return RoundedRectangle(cornerRadius: Self.barCorner, style: .continuous)
            .strokeBorder(Theme.destructive.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: holdW, height: Self.rowHeight)
            .offset(x: holdX)
            .allowsHitTesting(false)
            .tooltip("Removed since the baseline")
    }

    // MARK: - Framing row

    struct TimeRange: Identifiable {
        let from: Double
        let until: Double
        var id: Double { from }
    }

    /// The stretches of a hold where the camera follows the cursor: the
    /// gaps between (and around) its pins.
    func followStretches(for seg: ZoomSegment, windows: [(id: UUID, from: Double, until: Double)]) -> [TimeRange] {
        var out: [TimeRange] = []
        var cursor = seg.start
        for window in windows {
            if window.from > cursor + 0.001 { out.append(TimeRange(from: cursor, until: window.from)) }
            cursor = max(cursor, window.until)
        }
        let end = min(seg.end, duration)
        if end > cursor + 0.001 { out.append(TimeRange(from: cursor, until: end)) }
        return out
    }

    func framingTrack(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: w, height: Self.rowHeight)
            ForEach(segments) { seg in
                framingSpan(for: seg, width: w)
            }
        }
        .frame(width: w, height: Self.rowHeight, alignment: .topLeading)
    }

    /// A hold on the framing row: a grey span with a cursor glyph at the
    /// start of each following stretch and an orange band for each pin.
    @ViewBuilder
    func framingSpan(for seg: ZoomSegment, width w: CGFloat) -> some View {
        let (holdX, holdW) = holdBounds(seg, width: w)
        let lit = isLit(seg)
        let windows = pinWindows(for: seg)

        RoundedRectangle(cornerRadius: Self.barCorner, style: .continuous)
            .fill(Theme.timelineTrack)
            .frame(width: holdW, height: Self.rowHeight)
            .offset(x: holdX)
            .allowsHitTesting(false)

        ForEach(followStretches(for: seg, windows: windows)) { stretch in
            let fromX = x(of: stretch.from, width: w)
            glyphSpan(
                x: fromX, width: max(0, x(of: stretch.until, width: w) - fromX),
                icon: "cursor-click", fallback: "cursorarrow.click",
                help: windows.isEmpty
                    ? "The camera follows the cursor through this zoom — Pin viewport holds it still"
                    : "The camera follows the cursor here"
            )
        }

        ForEach(windows, id: \.id) { window in
            pinBand(for: seg, window: window, lit: lit, trackWidth: w)
        }
    }

    /// The part of a hold whose viewport is pinned: an orange band with a
    /// pin glyph at its start; both edges drag.
    @ViewBuilder
    func pinBand(for seg: ZoomSegment, window: (id: UUID, from: Double, until: Double), lit: Bool, trackWidth w: CGFloat) -> some View {
        let fromX = x(of: window.from, width: w)
        let bandW = max(4, x(of: window.until, width: w) - fromX)
        let open = seg.pins.first { $0.id == window.id }?.until == nil

        bar(Theme.pinBar, border: Theme.pinBarBorder)
            .frame(width: bandW, height: Self.rowHeight)
            .offset(x: fromX)
            .opacity(lit ? 1 : 0.4)
            .allowsHitTesting(false)

        glyphSpan(
            x: fromX, width: bandW,
            icon: "map-pin-simple-area", fallback: "mappin.and.ellipse",
            help: open
                ? "Viewport pinned from \(shortTimecode(window.from)) to the end of this zoom — scrub ahead and Unpin where the camera should follow again; drag the crop box to move the pinned spot"
                : "Viewport pinned \(shortTimecode(window.from))–\(shortTimecode(window.until)) — drag the edges to change when; drag the crop box to move the pinned spot"
        )

        ForEach([HorizontalEdge.leading, .trailing], id: \.self) { edge in
            let target: TimelineDrag.Target = edge == .leading
                ? .pinStart(segment: seg.id, pin: window.id)
                : .pinEnd(segment: seg.id, pin: window.id)
            TimelineEdgeHandle(
                color: Theme.pinBar,
                dragging: timelineDrag?.target == target,
                onDrag: { dx in dragKeyframe(target, translation: dx, width: w) },
                onEnd: { timelineDrag = nil }
            )
            .offset(x: (edge == .leading ? fromX : fromX + bandW) - TimelineEdgeHandle.width / 2)
            .tooltip(edge == .leading
                  ? "Pin starts here — drag to change when"
                  : "Pin releases here — drag to change when the camera follows the cursor again")
            .zIndex(3)
        }
    }

    /// A stretch on the framing row that carries a tooltip and, when wide
    /// enough, a glyph at its start. The press falls through to the scrub.
    func glyphSpan(x: CGFloat, width: CGFloat, icon: String, fallback: String, help: String) -> some View {
        Color.clear
            .frame(width: width, height: Self.rowHeight)
            .overlay(alignment: .leading) {
                if width >= Self.barGlyphSize + 14 {
                    Icon(name: icon, size: Self.barGlyphSize, fallback: fallback)
                        .foregroundStyle(Theme.foreground)
                        .padding(.leading, 7)
                }
            }
            .contentShape(Rectangle())
            .offset(x: x)
            .tooltip(help)
    }

    // MARK: - Playhead

    /// 5×24 destructive handle on the video row (Figma 94:1558) and a
    /// hairline down the other rows so pins line up with zooms.
    func playhead(width w: CGFloat) -> some View {
        let px = min(max(0, x(of: currentTime, width: w)), w)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.destructive.opacity(0.5))
                .frame(width: 1, height: Self.rowsHeight)
                .offset(x: px)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.destructive)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                )
                .frame(width: 5, height: 24)
                .offset(x: px - 2, y: -2)
        }
        .offset(x: Self.rowInset)
        .zIndex(4)
        .allowsHitTesting(false)
    }

    // MARK: - Moving keyframes

    /// Move a keyframe by the pointer's travel since its drag began. Zoom
    /// edges keep the minimum hold and stay clear of the neighbouring
    /// zooms; a pin stays inside its hold and clear of the pins either side
    /// of it. Drags only move keyframes, they never scrub.
    func dragKeyframe(_ target: TimelineDrag.Target, translation dx: CGFloat, width w: CGFloat) {
        guard w > 0 else { return }
        let drag: TimelineDrag
        if let current = timelineDrag, current.target == target {
            drag = current
        } else {
            guard let origin = keyframeTime(target) else { return }
            drag = TimelineDrag(target: target, origin: origin)
            timelineDrag = drag
        }
        let t = drag.origin + Double(dx / w) * duration
        switch target {
        case .zoomStart(let id):
            guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
            let room = ZoomPlanner.holdRoom(for: id, in: segments, duration: duration)
            segments[i].start = min(max(room.lowerBound, t), segments[i].end - ZoomPlanner.minHold)
        case .zoomEnd(let id):
            guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
            let room = ZoomPlanner.holdRoom(for: id, in: segments, duration: duration)
            segments[i].end = max(min(room.upperBound, t), segments[i].start + ZoomPlanner.minHold)
        case .pinStart(let segID, let pinID):
            guard let at = pinIndices(segment: segID, pin: pinID) else { return }
            let seg = segments[at.seg]
            let windows = pinWindows(for: seg)
            guard let wi = windows.firstIndex(where: { $0.id == pinID }) else { return }
            let floor = wi > 0 ? windows[wi - 1].until : seg.start
            let from = min(max(t, floor), max(floor, windows[wi].until - 0.1))
            // Back at the hold's start means "from the start" — store nothing.
            segments[at.seg].pins[at.pin].from = from <= seg.start + 0.001 ? nil : from
        case .pinEnd(let segID, let pinID):
            guard let at = pinIndices(segment: segID, pin: pinID) else { return }
            let seg = segments[at.seg]
            let windows = pinWindows(for: seg)
            guard let wi = windows.firstIndex(where: { $0.id == pinID }) else { return }
            let ceiling = wi + 1 < windows.count ? windows[wi + 1].from : seg.end
            let until = max(min(t, ceiling), min(ceiling, windows[wi].from + 0.1))
            // At the hold's end the pin is open again: held until released.
            segments[at.seg].pins[at.pin].until = until >= seg.end - 0.001 ? nil : until
        }
    }

    /// The model time a drag target currently has (unclamped, so a drag
    /// stays relative to the pointer).
    func keyframeTime(_ target: TimelineDrag.Target) -> Double? {
        switch target {
        case .zoomStart(let id):
            return segments.first { $0.id == id }?.start
        case .zoomEnd(let id):
            return segments.first { $0.id == id }?.end
        case .pinStart(let segID, let pinID):
            guard let seg = segments.first(where: { $0.id == segID }) else { return nil }
            return planner().pinWindow(pinID, in: seg, duration: duration)?.from
        case .pinEnd(let segID, let pinID):
            guard let seg = segments.first(where: { $0.id == segID }) else { return nil }
            return planner().pinWindow(pinID, in: seg, duration: duration)?.until
        }
    }

    func pinIndices(segment segID: UUID, pin pinID: UUID) -> (seg: Int, pin: Int)? {
        guard let seg = segments.firstIndex(where: { $0.id == segID }),
              let pin = segments[seg].pins.firstIndex(where: { $0.id == pinID }) else { return nil }
        return (seg, pin)
    }
}

/// Grip straddling one edge of a bar: a 2×10 pill in the bar's colour
/// with a pale rim that grows on hover. Shows the horizontal-resize
/// cursor and reports pointer travel while dragged; the editor turns that
/// into a new time. Its zero-distance drag claims the press ahead of the
/// track's scrub gesture, so clicking a grip does nothing and only a drag
/// has an effect.
private struct TimelineEdgeHandle: View {
    static let width: CGFloat = 10

    let color: Color
    let dragging: Bool
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        let active = hovering || dragging
        Color.clear
            .frame(width: Self.width, height: EditorView.rowHeight)
            .overlay {
                Capsule()
                    .fill(color)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.13), radius: 1, x: -1, y: 0)
                    .frame(width: 2, height: active ? 14 : 10)
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
