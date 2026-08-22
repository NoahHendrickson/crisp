import Foundation
import CoreGraphics

/// The virtual camera state at a moment in time.
struct Camera {
    /// Zoom factor: 1 = full frame, 2 = 2x zoom.
    var zoom: Double
    /// Center of the visible region, in master-video pixels.
    var center: CGPoint
}

/// Turns the raw click log into smooth camera keyframes:
/// cluster nearby clicks, zoom into each cluster, ease in/out, pan between them.
struct ZoomPlanner {

    struct Keyframe {
        var t: Double
        var camera: Camera
    }

    struct Config {
        var zoomLevel: Double = 1.8
        /// Clicks closer than this (seconds) stay in one zoom segment.
        var clusterGap: Double = 2.5
        /// Lead time before the first click of a segment. The camera starts
        /// moving this early so it has ARRIVED by the time the click happens.
        var leadIn: Double = 0.7
        var zoomInDuration: Double = 0.5
        var zoomOutDuration: Double = 0.7
        /// How long to stay zoomed after the last click of a segment.
        var holdAfter: Double = 1.3
        /// While zoomed, re-center if a click lands this far (fraction of frame) from center.
        var recenterThreshold: Double = 0.18
    }

    let width: Double
    let height: Double
    var config = Config()

    /// Auto-generate editable zoom segments from the click log: one segment per
    /// click cluster. `start...end` is the fully-zoomed hold window; the eased
    /// zoom-in/out transitions are added by `keyframes(from:duration:)`.
    func segments(events: [MouseEvent], duration: Double) -> [ZoomSegment] {
        let clicks = events.filter { $0.kind == .leftDown || $0.kind == .rightDown }
        guard !clicks.isEmpty else { return [] }

        var clusters: [[MouseEvent]] = []
        var current: [MouseEvent] = []
        for click in clicks {
            if let last = current.last, click.t - last.t > config.clusterGap {
                clusters.append(current)
                current = []
            }
            current.append(click)
        }
        if !current.isEmpty { clusters.append(current) }

        return clusters.compactMap { cluster in
            let start = cluster[0].t
            let end = min(duration, cluster[cluster.count - 1].t + config.holdAfter)
            guard end > start + 0.05 else { return nil }
            let zoom = config.zoomLevel

            // Open on the first click; later clicks that drift far from the
            // current center become editable pan moves.
            var center = clampedCenter(CGPoint(x: cluster[0].x, y: cluster[0].y), zoom: zoom)
            let initialCenter = center
            var pans: [PanMove] = []
            for click in cluster.dropFirst() {
                let p = CGPoint(x: click.x, y: click.y)
                let dx = abs(p.x - center.x) / width
                let dy = abs(p.y - center.y) / height
                if max(dx, dy) > config.recenterThreshold {
                    let target = clampedCenter(p, zoom: zoom)
                    pans.append(PanMove(
                        t: max(start, click.t - 0.35), duration: 0.5,
                        cx: target.x, cy: target.y
                    ))
                    center = target
                }
            }

            return ZoomSegment(
                start: start, end: end, zoom: zoom,
                cx: initialCenter.x, cy: initialCenter.y, pans: pans
            )
        }
    }

    /// Expand segments into camera keyframes covering [0, duration], with the
    /// zoom-in starting `leadIn` before each segment so the camera has arrived
    /// by the time the hold window opens.
    func keyframes(from segments: [ZoomSegment], duration: Double) -> [Keyframe] {
        let fullFrame = Camera(zoom: 1, center: CGPoint(x: width / 2, y: height / 2))
        var keys: [Keyframe] = [Keyframe(t: 0, camera: fullFrame)]

        for seg in segments.sorted(by: { $0.start < $1.start }) {
            var center = clampedCenter(CGPoint(x: seg.cx, y: seg.cy), zoom: seg.zoom)
            let moveStart = max(0, seg.start - config.leadIn)
            let arrive = min(moveStart + config.zoomInDuration, max(seg.start, moveStart + 0.05))
            let end = min(seg.end, duration)
            guard end > moveStart else { continue }

            appendHoldIfGap(&keys, at: moveStart, fullFrame: fullFrame)
            keys.append(Keyframe(t: arrive, camera: Camera(zoom: seg.zoom, center: center)))

            // Pan moves inside the hold window, in order.
            var lastT = arrive
            for pan in seg.pans.sorted(by: { $0.t < $1.t }) {
                let panStart = min(max(pan.t, seg.start), end)
                let panEnd = min(panStart + max(0.1, pan.duration), end)
                guard panEnd > lastT else { continue }
                let target = clampedCenter(CGPoint(x: pan.cx, y: pan.cy), zoom: seg.zoom)
                keys.append(Keyframe(t: max(panStart, lastT), camera: Camera(zoom: seg.zoom, center: center)))
                keys.append(Keyframe(t: panEnd, camera: Camera(zoom: seg.zoom, center: target)))
                center = target
                lastT = panEnd
            }

            keys.append(Keyframe(t: end, camera: Camera(zoom: seg.zoom, center: center)))
            keys.append(Keyframe(t: min(end + config.zoomOutDuration, duration), camera: fullFrame))
        }

        if let last = keys.last, last.t < duration {
            keys.append(Keyframe(t: duration, camera: fullFrame))
        }

        // Guarantee monotonic times (overlapping segments can reorder slightly).
        var cleaned: [Keyframe] = []
        for key in keys {
            if let last = cleaned.last, key.t <= last.t {
                cleaned[cleaned.count - 1] = key
            } else {
                cleaned.append(key)
            }
        }
        return cleaned
    }

    /// Camera state at time t, smoothstep-eased between keyframes.
    static func evaluate(_ keys: [Keyframe], at t: Double) -> Camera {
        guard let first = keys.first else {
            return Camera(zoom: 1, center: .zero)
        }
        if t <= first.t { return first.camera }
        guard let last = keys.last, t < last.t else {
            return keys.last!.camera
        }
        for i in 1..<keys.count where t < keys[i].t {
            let a = keys[i - 1]
            let b = keys[i]
            let span = b.t - a.t
            let raw = span > 0 ? (t - a.t) / span : 1
            let u = raw * raw * (3 - 2 * raw)  // smoothstep
            return Camera(
                zoom: a.camera.zoom + (b.camera.zoom - a.camera.zoom) * u,
                center: CGPoint(
                    x: a.camera.center.x + (b.camera.center.x - a.camera.center.x) * u,
                    y: a.camera.center.y + (b.camera.center.y - a.camera.center.y) * u
                )
            )
        }
        return last.camera
    }

    /// Keep the zoomed crop fully inside the frame.
    private func clampedCenter(_ p: CGPoint, zoom: Double) -> CGPoint {
        let halfW = width / zoom / 2
        let halfH = height / zoom / 2
        return CGPoint(
            x: min(max(p.x, halfW), width - halfW),
            y: min(max(p.y, halfH), height - halfH)
        )
    }

    /// If the previous keyframe is well before `start`, pin full-frame right before zooming
    /// so the camera doesn't drift in slowly from the previous segment.
    private func appendHoldIfGap(_ keys: inout [Keyframe], at start: Double, fullFrame: Camera) {
        if let last = keys.last, start - last.t > 0.01, last.camera.zoom == 1 {
            keys.append(Keyframe(t: start, camera: fullFrame))
        }
    }
}
