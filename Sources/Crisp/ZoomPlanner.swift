import Foundation
import CoreGraphics

/// The virtual camera state at a moment in time.
struct Camera {
    /// Zoom factor: 1 = full frame, 2 = 2x zoom.
    var zoom: Double
    /// Center of the visible region, in master-video pixels.
    var center: CGPoint
}

/// Turns zoom windows into a smooth camera: the *level* comes from the plan
/// (hold windows and mid-hold steps, eased in and out), the *framing* comes
/// from a follower that keeps the recorded cursor and clicks in view. The
/// user only ever decides how zoomed the camera is, and when.
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
        var leadIn: Double = 0.8
        var zoomInDuration: Double = 0.6
        var zoomOutDuration: Double = 0.75
        /// How long to stay zoomed after the last click of a segment.
        var holdAfter: Double = 1.3
        /// How long a mid-hold zoom step takes to ease to its new level.
        var stepDuration: Double = 0.5

        // Follower
        /// The camera only moves once the cursor leaves the central part of
        /// the crop: this fraction of the visible size, centred.
        var deadZone: Double = 0.5
        /// Once it does move, it brings the cursor in to this tighter zone,
        /// so one glide settles things instead of a stream of nudges.
        var settleZone: Double = 0.3
        /// How far ahead of the playhead the follower looks at the cursor —
        /// offline we know the future, so moves begin a beat early.
        var cursorLookAhead: Double = 0.25
        /// Upcoming clicks are aimed at this early, and held this long after.
        var clickLookAhead: Double = 0.7
        var clickHold: Double = 0.5
        /// Time constant of the ease that blends one target into the next,
        /// so switching targets never steps the spring's input.
        var aimSmoothing: Double = 0.18
        /// Period of the critically-damped spring that carries the centre.
        var followPeriod: Double = 0.72
        /// Speed cap, in visible widths per second, so a flick never whips.
        var maxSpeed: Double = 1.6
        /// Acceleration cap, in visible widths per second², so even a big
        /// target change becomes a lean rather than a lurch.
        var maxAcceleration: Double = 5.0
    }

    let width: Double
    let height: Double
    var config = Config()
    /// Recorded cursor path and clicks, for the follower. Empty means the
    /// camera stays centred (tests, or a recording without samples).
    var samples: [CursorSample] = []
    var clicks: [MouseEvent] = []

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    init(meta: RecordingMeta) {
        width = Double(meta.pixelWidth)
        height = Double(meta.pixelHeight)
        samples = meta.samples
        clicks = meta.events.filter { $0.kind == .leftDown || $0.kind == .rightDown }.sorted { $0.t < $1.t }
    }

    /// Samples per second of the baked centre path.
    static let followRate = 60.0

    var frameCenter: CGPoint { CGPoint(x: width / 2, y: height / 2) }

    // MARK: - Automatic plan

    /// One action in the click log: clicks closer together than
    /// `clusterGap`. The automatic plan gives each one a zoom; the agent's
    /// context and stills list them.
    struct ClickCluster {
        var start: Double
        var end: Double
        var count: Int
        var center: CGPoint
    }

    func clickClusters(_ events: [MouseEvent]) -> [ClickCluster] {
        var groups: [[MouseEvent]] = []
        var current: [MouseEvent] = []
        for click in events where click.kind == .leftDown || click.kind == .rightDown {
            if let last = current.last, click.t - last.t > config.clusterGap {
                groups.append(current)
                current = []
            }
            current.append(click)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map { group in
            ClickCluster(
                start: group[0].t, end: group[group.count - 1].t, count: group.count,
                center: CGPoint(x: group.map(\.x).reduce(0, +) / Double(group.count),
                                y: group.map(\.y).reduce(0, +) / Double(group.count))
            )
        }
    }

    /// Auto-generate editable zoom segments from the click log: one per
    /// click cluster. `start...end` is the fully-zoomed hold window; the
    /// eased zoom-in/out transitions and the framing are added by `keyframes`.
    func segments(events: [MouseEvent], duration: Double) -> [ZoomSegment] {
        clickClusters(events).compactMap { cluster in
            let end = min(duration, cluster.end + config.holdAfter)
            guard end > cluster.start + 0.05 else { return nil }
            return ZoomSegment(start: cluster.start, end: end, zoom: config.zoomLevel)
        }
    }

    // MARK: - Timing

    /// The camera-motion window of a segment: the zoom-in ramp begins
    /// `leadIn` early and the zoom-out eases back after the hold ends.
    /// A segment's own `zoomIn` / `zoomOut` stretch those ramps without
    /// moving when the hold arrives or ends. Mirrors `levelKeyframes`.
    func motionSpan(
        for seg: ZoomSegment, duration: Double
    ) -> (moveStart: Double, arrive: Double, end: Double, outEnd: Double) {
        let moveStartDefault = max(0, seg.start - config.leadIn)
        let arrive = min(moveStartDefault + config.zoomInDuration, max(seg.start, moveStartDefault + 0.05))
        let end = min(seg.end, duration)
        let moveStart = seg.zoomIn.map { max(0, arrive - max(0.1, $0)) } ?? moveStartDefault
        let outEnd = seg.zoomOut.map { min(end + max(0.1, $0), duration) }
            ?? min(end + config.zoomOutDuration, duration)
        return (moveStart, arrive, end, outEnd)
    }

    /// When a mid-hold step begins easing and when it has reached its level,
    /// clamped into the hold like `levelKeyframes` clamps it.
    func stepWindow(_ step: ZoomStep, in seg: ZoomSegment, duration: Double) -> (start: Double, end: Double) {
        let span = motionSpan(for: seg, duration: duration)
        let start = min(max(step.t, seg.start), span.end)
        return (start, min(start + config.stepDuration, span.end))
    }

    /// The steps that begin inside a hold, in time order. A step left past
    /// the hold's end (the zoom was shortened under it) has no window and is
    /// ignored until the hold grows back over it.
    func holdSteps(for seg: ZoomSegment, duration: Double) -> [ZoomStep] {
        let end = motionSpan(for: seg, duration: duration).end
        return seg.steps.filter { $0.t < end - 1e-6 }.sorted { $0.t < $1.t }
    }

    // MARK: - Keyframes

    /// The plan's zoom level over time as sparse keyframes (centres are the
    /// frame centre; the follower supplies real ones): full frame → ease in
    /// `leadIn` before each hold → hold, stepping to each step's level →
    /// ease out after the hold.
    func levelKeyframes(from segments: [ZoomSegment], duration: Double) -> [Keyframe] {
        let fullFrame = Camera(zoom: 1, center: frameCenter)
        var keys: [Keyframe] = [Keyframe(t: 0, camera: fullFrame)]

        for seg in segments.sorted(by: { $0.start < $1.start }) {
            let span = motionSpan(for: seg, duration: duration)
            guard span.end > span.moveStart else { continue }

            if let last = keys.last, span.moveStart - last.t > 0.01, last.camera.zoom == 1 {
                keys.append(Keyframe(t: span.moveStart, camera: fullFrame))
            }
            var level = seg.zoom
            keys.append(Keyframe(t: span.arrive, camera: Camera(zoom: level, center: frameCenter)))
            var lastT = span.arrive
            for step in holdSteps(for: seg, duration: duration) {
                let window = stepWindow(step, in: seg, duration: duration)
                guard window.end > lastT else { continue }
                keys.append(Keyframe(t: max(window.start, lastT), camera: Camera(zoom: level, center: frameCenter)))
                keys.append(Keyframe(t: window.end, camera: Camera(zoom: step.zoom, center: frameCenter)))
                level = step.zoom
                lastT = window.end
            }
            keys.append(Keyframe(t: span.end, camera: Camera(zoom: level, center: frameCenter)))
            keys.append(Keyframe(t: span.outEnd, camera: fullFrame))
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

    /// The complete camera: the plan's levels with the follower's framing,
    /// baked at `followRate` wherever the camera is zoomed (sparse full-frame
    /// keys elsewhere). Deterministic from the recording, so the live preview
    /// and the export agree frame for frame.
    func keyframes(from segments: [ZoomSegment], duration: Double) -> [Keyframe] {
        follow(levelKeyframes(from: segments, duration: duration), segments: segments, duration: duration)
    }

    /// One zoom's motion window with the levels it ramps to and from.
    private struct Window {
        var moveStart: Double
        var arrive: Double
        var end: Double
        var outEnd: Double
        var levelIn: Double
        var levelOut: Double
        var holdStart: Double
        var pins: [(point: CGPoint, from: Double, until: Double)]
    }

    /// When each of a zoom's pins applies: `from`/`until` clamped into the
    /// hold (defaulting to its edges), in time order, each cut short at the
    /// next pin's start so they never overlap. A pin the hold no longer
    /// reaches (the zoom was shortened under it) has no window and is
    /// ignored until the hold grows back over it.
    func pinWindows(for seg: ZoomSegment, duration: Double) -> [(id: UUID, from: Double, until: Double)] {
        let span = motionSpan(for: seg, duration: duration)
        let sorted = seg.pins.sorted { ($0.from ?? seg.start) < ($1.from ?? seg.start) }
        return sorted.indices.compactMap { i -> (id: UUID, from: Double, until: Double)? in
            let pin = sorted[i]
            let from = min(max(pin.from ?? seg.start, seg.start), span.end)
            var until = min(max(pin.until ?? span.end, from), span.end)
            if i + 1 < sorted.count {
                let nextFrom = min(max(sorted[i + 1].from ?? seg.start, seg.start), span.end)
                until = min(until, max(from, nextFrom))
            }
            guard until > from + 1e-6 else { return nil }
            return (pin.id, from, until)
        }
    }

    /// When one pin of a zoom applies (see `pinWindows`).
    func pinWindow(_ id: UUID, in seg: ZoomSegment, duration: Double) -> (from: Double, until: Double)? {
        pinWindows(for: seg, duration: duration).first { $0.id == id }.map { ($0.from, $0.until) }
    }

    private func windows(for segments: [ZoomSegment], duration: Double) -> [Window] {
        segments.sorted { $0.start < $1.start }.compactMap { seg in
            let span = motionSpan(for: seg, duration: duration)
            guard span.end > span.moveStart else { return nil }
            // The last step inside the hold is the level the zoom-out starts from.
            let levelOut = holdSteps(for: seg, duration: duration).last?.zoom ?? seg.zoom
            let pins = pinWindows(for: seg, duration: duration).compactMap { window in
                seg.pins.first { $0.id == window.id }.map { ($0.point, window.from, window.until) }
            }
            return Window(moveStart: span.moveStart, arrive: span.arrive, end: span.end, outEnd: span.outEnd,
                          levelIn: seg.zoom, levelOut: levelOut, holdStart: seg.start, pins: pins)
        }
    }

    /// Where `t` sits in the camera's motion: `progress` is 0 at full frame
    /// and 1 fully zoomed (smoothstep-eased through the ramps, like the zoom
    /// itself), and `holdZoom` is the level the follower should frame for —
    /// during a ramp, the level it is heading to or coming from.
    private func rampState(
        at t: Double, windows: [Window], zoom: Double
    ) -> (progress: Double, holdZoom: Double, pin: CGPoint?)? {
        for w in windows where t >= w.moveStart && t <= w.outEnd {
            // The pin holds through the ramps that border its range: a pin
            // from the hold's start also frames the zoom-in, one to its end
            // also frames the zoom-out.
            let pinned: CGPoint? = w.pins.first { pin in
                let from = pin.from <= w.holdStart + 1e-6 ? w.moveStart : pin.from
                let until = pin.until >= w.end - 1e-6 ? w.outEnd : pin.until
                return t >= from && t <= until
            }?.point
            if t < w.arrive {
                let r = (t - w.moveStart) / max(w.arrive - w.moveStart, 1e-6)
                return (r * r * (3 - 2 * r), w.levelIn, pinned)
            }
            if t <= w.end { return (1, zoom, pinned) }
            let r = (t - w.end) / max(w.outEnd - w.end, 1e-6)
            return (1 - r * r * (3 - 2 * r), w.levelOut, pinned)
        }
        return nil
    }

    /// Carry the centre along the cursor and clicks while zoomed.
    ///
    /// The follower runs at the hold level the whole way through a zoom's
    /// motion window, and what is emitted is its centre blended from the
    /// frame centre by the ramp's own smoothstep: full frame at the start of
    /// the zoom-in, the follower's framing once fully zoomed, back to the
    /// frame centre by the end of the zoom-out. The crop stays inside the
    /// frame by construction, so the ramps never fight the clamp. It opens
    /// on the first click of the action (or the cursor), so the zoom-in
    /// itself carries the camera there.
    ///
    /// Inside the hold, each tick picks a raw target: an upcoming click
    /// (aimed at up to `clickLookAhead` early and held `clickHold` after
    /// it), else the cursor a moment ahead — but only once the cursor has
    /// left the dead zone, and then far enough to bring it into the settle
    /// zone, so idle wiggles don't move the shot and one glide settles it.
    /// The raw target is eased into an `aim` (no steps), and a critically
    /// damped spring with speed and acceleration caps carries the centre.
    ///
    /// While a zoom's pin applies, the pin is simply the target: the same
    /// eased spring carries the camera onto it and, when the pin releases,
    /// back to following — so pinning and releasing are glides, not cuts.
    private func follow(_ levels: [Keyframe], segments: [ZoomSegment], duration: Double) -> [Keyframe] {
        let windows = windows(for: segments, duration: duration)
        guard !windows.isEmpty, levels.contains(where: { $0.camera.zoom > 1.001 }) else { return levels }
        let dt = 1 / Self.followRate
        let omega = 2 * Double.pi / config.followPeriod
        let aimBlend = 1 - exp(-dt / config.aimSmoothing)
        let fullFrame = Camera(zoom: 1, center: frameCenter)

        var out: [Keyframe] = [Keyframe(t: 0, camera: fullFrame)]
        var center = frameCenter
        var velocity = CGPoint.zero
        var aim = frameCenter
        var target = frameCenter
        var held: HeldClick?
        var nextClick = 0
        var inWindow = false
        var levelIndex = 0

        var t = dt
        while t <= duration + dt / 2 {
            let time = min(t, duration)
            let zoom = Self.evaluate(levels, at: time, from: &levelIndex).zoom
            guard let state = rampState(at: time, windows: windows, zoom: zoom), zoom > 1.0001 || state.progress > 0 else {
                if inWindow {
                    out.append(Keyframe(t: time, camera: fullFrame))
                    held = nil
                }
                inWindow = false
                t += dt
                continue
            }
            let holdZoom = max(state.holdZoom, 1.0001)
            while nextClick < clicks.count, clicks[nextClick].t < time - 0.001 { nextClick += 1 }
            if !inWindow {
                // Pin full frame right before the ramp so the previous
                // full-frame stretch doesn't drift toward this key.
                let before = time - dt
                if let last = out.last, before > last.t + 1e-6 {
                    out.append(Keyframe(t: before, camera: fullFrame))
                }
                center = clampedCenter(openingTarget(at: time, pin: state.pin, nextClick: nextClick), zoom: holdZoom)
                aim = center
                target = center
                velocity = .zero
            }

            target = clampedCenter(
                selectTarget(at: time, pin: state.pin, holdZoom: holdZoom, center: center, previous: target,
                             held: &held, nextClick: &nextClick),
                zoom: holdZoom
            )

            // Ease the target into the aim, then spring the centre to the aim.
            aim.x += (target.x - aim.x) * aimBlend
            aim.y += (target.y - aim.y) * aimBlend
            aim = clampedCenter(aim, zoom: holdZoom)

            var ax = omega * omega * (aim.x - center.x) - 2 * omega * velocity.x
            var ay = omega * omega * (aim.y - center.y) - 2 * omega * velocity.y
            let accel = hypot(ax, ay)
            let maxAccel = width / holdZoom * config.maxAcceleration
            if accel > maxAccel {
                ax *= maxAccel / accel
                ay *= maxAccel / accel
            }
            velocity.x += ax * dt
            velocity.y += ay * dt
            let speed = hypot(velocity.x, velocity.y)
            let maxSpeed = width / holdZoom * config.maxSpeed
            if speed > maxSpeed {
                velocity.x *= maxSpeed / speed
                velocity.y *= maxSpeed / speed
            }
            let moved = CGPoint(x: center.x + velocity.x * dt, y: center.y + velocity.y * dt)
            let clamped = clampedCenter(moved, zoom: holdZoom)
            if clamped.x != moved.x { velocity.x = 0 }
            if clamped.y != moved.y { velocity.y = 0 }
            center = clamped

            // Emit: the follower's framing, blended from the frame centre by
            // the ramp progress, then clamped for the zoom actually in effect
            // (a no-op except for rounding — see the docs above).
            let u = state.progress
            let blended = CGPoint(
                x: frameCenter.x + (center.x - frameCenter.x) * u,
                y: frameCenter.y + (center.y - frameCenter.y) * u
            )
            out.append(Keyframe(t: time, camera: Camera(zoom: zoom, center: clampedCenter(blended, zoom: zoom))))
            inWindow = true
            t += dt
        }
        if let last = out.last, last.t < duration {
            out.append(Keyframe(t: duration, camera: inWindow ? last.camera : fullFrame))
        }
        return out
    }

    // MARK: Target policy

    /// A click the follower is holding on: aimed at up to `clickLookAhead`
    /// early and kept until `clickHold` after it.
    private struct HeldClick {
        var point: CGPoint
        var until: Double
    }

    /// Where a zoom opens: the pin if it applies from the start, else the
    /// first click coming up, else the cursor a lead-in ahead — so the
    /// zoom-in itself carries the camera onto the action.
    private func openingTarget(at time: Double, pin: CGPoint?, nextClick: Int) -> CGPoint {
        if let pin { return pin }
        if nextClick < clicks.count, clicks[nextClick].t <= time + config.leadIn + config.clickLookAhead {
            return CGPoint(x: clicks[nextClick].x, y: clicks[nextClick].y)
        }
        if let p = FrameComposer.cursorPosition(samples: samples, at: time + config.leadIn) {
            return CGPoint(x: p.x, y: p.y)
        }
        return frameCenter
    }

    /// The raw target for one tick: the pin while it applies; else an
    /// upcoming click, held past it; else the cursor a moment ahead — but
    /// only once it has strayed out of the dead zone around `center`, and
    /// then pulled far enough in to land in the settle zone, so idle
    /// wiggles don't move the shot and one glide settles it. `previous` is
    /// kept while nothing calls for a move.
    private func selectTarget(
        at time: Double, pin: CGPoint?, holdZoom: Double, center: CGPoint, previous: CGPoint,
        held: inout HeldClick?, nextClick: inout Int
    ) -> CGPoint {
        if let pin {
            held = nil
            return pin
        }
        if nextClick < clicks.count, clicks[nextClick].t <= time + config.clickLookAhead {
            let click = clicks[nextClick]
            held = HeldClick(point: CGPoint(x: click.x, y: click.y), until: click.t + config.clickHold)
            nextClick += 1
        }
        if let click = held, time <= click.until { return click.point }
        held = nil
        guard let p = FrameComposer.cursorPosition(samples: samples, at: time + config.cursorLookAhead) else {
            return previous
        }
        let deadW = width / holdZoom / 2 * config.deadZone
        let deadH = height / holdZoom / 2 * config.deadZone
        let settleW = width / holdZoom / 2 * config.settleZone
        let settleH = height / holdZoom / 2 * config.settleZone
        var tx = previous.x
        var ty = previous.y
        if p.x > center.x + deadW { tx = p.x - settleW } else if p.x < center.x - deadW { tx = p.x + settleW }
        if p.y > center.y + deadH { ty = p.y - settleH } else if p.y < center.y - deadH { ty = p.y + settleH }
        return CGPoint(x: tx, y: ty)
    }

    /// Camera state at time t, smoothstep-eased between keyframes.
    static func evaluate(_ keys: [Keyframe], at t: Double) -> Camera {
        var cursor = 0
        return evaluate(keys, at: t, from: &cursor)
    }

    /// `evaluate` with a resumable cursor for sequential callers, plus a
    /// binary search for random access into dense keyframe lists.
    static func evaluate(_ keys: [Keyframe], at t: Double, from cursor: inout Int) -> Camera {
        guard let first = keys.first else {
            return Camera(zoom: 1, center: .zero)
        }
        if t <= first.t { return first.camera }
        let last = keys[keys.count - 1]
        if t >= last.t { return last.camera }
        // Find i with keys[i-1].t <= t < keys[i].t.
        var i: Int
        if cursor >= 1, cursor < keys.count, keys[cursor - 1].t <= t, t < keys[cursor].t {
            i = cursor
        } else if cursor >= 1, cursor + 1 < keys.count, keys[cursor].t <= t, t < keys[cursor + 1].t {
            i = cursor + 1
        } else {
            var lo = 1
            var hi = keys.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if keys[mid].t <= t { lo = mid + 1 } else { hi = mid }
            }
            i = lo
        }
        cursor = i
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

    /// Keep the zoomed crop fully inside the frame.
    func clampedCenter(_ p: CGPoint, zoom: Double) -> CGPoint {
        Self.clampedCenter(p, zoom: zoom, width: width, height: height)
    }

    /// The same clamp for callers without a planner (the editor's crop box),
    /// so what the box shows is exactly what renders.
    static func clampedCenter(_ p: CGPoint, zoom: Double, width: Double, height: Double) -> CGPoint {
        let halfW = width / zoom / 2
        let halfH = height / zoom / 2
        return CGPoint(
            x: min(max(p.x, halfW), width - halfW),
            y: min(max(p.y, halfH), height - halfH)
        )
    }
}
