import SwiftUI
import AVFoundation

// The editor's plan and playback: loading, resetting and regenerating the
// zoom plan, the planner it is evaluated with, the preview composition the
// player shows, and the transport.
extension EditorView {
    // MARK: - Plan

    /// Swaps the plan in, keeping the previous one as the Compare baseline.
    func loadPlan(_ plan: [ZoomSegment]) {
        compareBaseline = segments
        compareTarget = nil
        segments = plan
    }

    /// Throw away the edited plan and regenerate the zooms from the click
    /// log; the edited plan stays available as the Compare baseline.
    func resetZoomsToDefault() {
        try? FileManager.default.removeItem(at: recording.planURL)
        loadPlan(autoSegments())
    }

    /// A 2s zoom whose hold begins at `t`; the follower frames it.
    func addZoom(at t: Double) {
        let start = min(t, max(0, duration - 0.5))
        let end = min(start + 2.0, duration)
        segments.append(ZoomSegment(start: start, end: end, zoom: ZoomPlanner.Config().zoomLevel))
    }

    func planner() -> ZoomPlanner {
        guard let meta else { return ZoomPlanner(width: 1, height: 1) }
        return ZoomPlanner(meta: meta)
    }

    func autoSegments() -> [ZoomSegment] {
        guard let meta else { return [] }
        return planner().segments(events: meta.events, duration: duration)
    }

    // MARK: - Preview composition

    func makeComposition() -> AVMutableVideoComposition? {
        guard let meta else { return nil }
        let clipDuration = CMTime(seconds: max(duration, 0.1), preferredTimescale: 600)
        if comparing, let compareBaseline {
            let composer = CompareComposer(
                meta: meta,
                before: planner().keyframes(from: compareBaseline, duration: duration),
                after: planner().keyframes(from: compareTarget ?? segments, duration: duration)
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

    // MARK: - Transport

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if duration - currentTime < 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to t: Double) {
        player.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }
}
