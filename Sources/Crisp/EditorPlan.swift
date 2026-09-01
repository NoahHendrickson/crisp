import SwiftUI
import AVFoundation

// The editor's plan and playback: loading, resetting and regenerating the
// zoom plan, the planner it is evaluated with, the trim and the clips, the
// preview composition the player shows, and the transport.
extension EditorView {
    // MARK: - Plan

    /// Swaps the plan in, keeping the previous one as the Compare baseline.
    func loadPlan(_ plan: [ZoomSegment]) {
        compareBaseline = segments
        compareTarget = nil
        segments = plan
        openZoomID = nil
    }

    /// Throw away the edited plan and regenerate the zooms from the click
    /// log; the edited plan stays available as the Compare baseline.
    func resetZoomsToDefault() {
        try? FileManager.default.removeItem(at: recording.planURL)
        loadPlan(autoSegments())
    }

    func removeZoom(_ id: UUID) {
        segments.removeAll { $0.id == id }
        if openZoomID == id { openZoomID = nil }
    }

    func removePin(_ pinID: UUID, in segmentID: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[i].pins.removeAll { $0.id == pinID }
    }

    func planner() -> ZoomPlanner {
        plannerCache ?? ZoomPlanner(width: 1, height: 1)
    }

    func autoSegments() -> [ZoomSegment] {
        guard let meta else { return [] }
        return planner().segments(events: meta.events, duration: duration)
    }

    // MARK: - Trim & clips

    /// What the whole-video export keeps.
    var trimRange: ClosedRange<Double> {
        trim.range(duration: duration)
    }

    func resetTrim() {
        trim = Trim()
    }

    /// The clips as they export, in time order (see `Clip.ranges`).
    var clipRanges: [Clip.Range] {
        Clip.ranges(of: clips, duration: duration)
    }

    func removeClip(_ id: UUID) {
        clips.removeAll { $0.id == id }
    }

    // MARK: - Speed-ups

    /// The speed-ups as they apply, in time order (see `SpeedWindow.ranges`).
    var speedRanges: [SpeedWindow.Range] {
        SpeedWindow.ranges(of: speeds, duration: duration)
    }

    func removeSpeed(_ id: UUID) {
        speeds.removeAll { $0.id == id }
    }

    func setSpeedRate(_ rate: Double, for id: UUID) {
        guard let i = speeds.firstIndex(where: { $0.id == id }) else { return }
        speeds[i].rate = rate
    }

    // MARK: - Preview composition

    func makeComposition() -> AVMutableVideoComposition? {
        guard let meta else { return nil }
        let clipDuration = assetDuration
        if comparing, let compareBaseline {
            let composer = CompareComposer(
                meta: meta,
                before: planner().keyframes(from: compareBaseline, duration: duration),
                after: planner().keyframes(from: compareTarget ?? segments, duration: duration),
                cursorStyle: cursorStyle
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
            : cameraKeys
        let composer = FrameComposer(
            meta: meta, keys: keys, cursorStyle: cursorStyle,
            speedBadges: speedBadge ? speedRanges : []
        )
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

    /// 1× → 2× → 4× → 1×. `defaultRate` is what `play()` uses after a
    /// pause; `rate` is updated live when already playing.
    func cyclePlaybackRate() {
        playbackRate = playbackRate == 1 ? 2 : playbackRate == 2 ? 4 : 1
        player.defaultRate = playbackRate
        if isPlaying { player.rate = playbackRate }
    }

    var playbackRateLabel: String {
        String(format: "%.0f×", playbackRate)
    }

    /// The preview's stand-in for the export's fast-forward: while the
    /// playhead is inside a speed-up, the player runs that much faster on
    /// top of the transport speed. The export retimes frames instead; this
    /// only approximates it live. Compare runs its own loop and stays 1×.
    func enforcePreviewSpeed() {
        guard !comparing, player.timeControlStatus == .playing else { return }
        let boost = speedRanges.first { currentTime >= $0.start && currentTime < $0.end }?.rate ?? 1
        let wanted = playbackRate * Float(boost)
        if abs(player.rate - wanted) > 0.01 { player.rate = wanted }
    }

    func seek(to t: Double) {
        player.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }
}
