import SwiftUI
import AVFoundation
import AppKit

// The editor's timeline: selection, the track with one bar per zoom, the
// icons inside each bar, the draggable hold edges, and the playhead.
extension EditorView {
    // MARK: - Timeline

    /// Assign `selection`, growing the window downward when the inspector
    /// first appears so the preview and timeline stay put.
    func select(_ new: Selection?) {
        if new != nil, comparing { setComparing(false) }
        selection = new
        syncWindowGrowth()
    }

    /// The camera-motion window for a segment as drawn on the timeline: the
    /// zoom-in ramp begins `leadIn` early and the zoom-out eases back after
    /// the hold ends. Mirrors ZoomPlanner.keyframes.
    func motionSpan(
        for seg: ZoomSegment
    ) -> (moveStart: Double, arrive: Double, end: Double, outEnd: Double) {
        planner().motionSpan(for: seg, duration: duration)
    }

    /// True when this segment or one of its pans is selected — or, while
    /// comparing, when it differs from the baseline.
    func isHighlighted(_ seg: ZoomSegment) -> Bool {
        if comparing, let diff = planDiff, diff.changed.contains(seg.id) { return true }
        switch selection {
        case .segment(seg.id): return true
        case .pan(segment: seg.id, pan: _): return true
        default: return false
        }
    }

    /// Transport button beside the bar (Figma 76:13691): the playhead's own
    /// play/pause, then the track with one bar per zoom.
    var timeline: some View {
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
    func segmentBar(for seg: ZoomSegment, width w: CGFloat) -> some View {
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
    func handleTimelineClick(at point: CGPoint, width w: CGFloat) {
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
    struct BarIcon: Identifiable {
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
    func barIcons(
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
    func dragEdge(of id: UUID, _ edge: HorizontalEdge, translation dx: CGFloat, width w: CGFloat) {
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
    func removedBar(for seg: ZoomSegment, width w: CGFloat) -> some View {
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
    func playhead(at time: Double, width w: CGFloat) -> some View {
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

    var durationLabel: some View {
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
