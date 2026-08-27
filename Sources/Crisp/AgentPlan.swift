import Foundation
import CoreGraphics

/// The agent-facing plan contract, in one place: the JSON an agent reads in
/// `context.json` and writes back as `plan.json`, its validation against the
/// app's rules, the derived timing `./crisp validate` prints, the context
/// document, and the standing brief. `AIDirector` runs sessions against it;
/// `AgentTools` serves it from the command line.
enum AgentPlan {
    // MARK: - Rules

    /// The planner's rules, as the agent is held to them.
    static let zoomRange = ZoomPlanner.zoomRange
    static let minHold = ZoomPlanner.minHold
    static let minGap = ZoomPlanner.minGap
    static let easeRange: ClosedRange<Double> = 0.1...8

    // MARK: - Plan document

    /// `plan.json` as the agent writes it. Ids are kept so unchanged zooms
    /// keep their identity; `pins` is always a list (empty = follow the
    /// cursor). Two decimals throughout.
    struct Document: Codable {
        var segments: [Segment]
    }

    struct Segment: Codable {
        var id: String?
        var start: Double
        var end: Double
        var zoom: Double?
        var steps: [Step]?
        var pins: [Pin]?
        var zoomIn: Double?
        var zoomOut: Double?
    }

    struct Step: Codable {
        var id: String?
        var t: Double
        var zoom: Double
    }

    struct Pin: Codable {
        var x: Double
        var y: Double
        var from: Double?
        var until: Double?
    }

    /// An annotated still handed to the agent, as `context.json` lists it.
    struct Frame: Codable {
        var file: String
        var t: Double
        var label: String

        private enum CodingKeys: String, CodingKey {
            case file, t = "atSeconds", label
        }
    }

    static func document(from segments: [ZoomSegment]) -> Document {
        Document(segments: segments.map { seg in
            Segment(
                id: seg.id.uuidString,
                start: round2(seg.start), end: round2(seg.end), zoom: round2(seg.zoom),
                steps: seg.steps.sorted { $0.t < $1.t }.map {
                    Step(id: $0.id.uuidString, t: round2($0.t), zoom: round2($0.zoom))
                },
                pins: seg.pins.sorted { ($0.from ?? seg.start) < ($1.from ?? seg.start) }.map {
                    Pin(x: $0.x.rounded(), y: $0.y.rounded(), from: $0.from.map(round2), until: $0.until.map(round2))
                },
                zoomIn: seg.zoomIn.map(round2), zoomOut: seg.zoomOut.map(round2)
            )
        })
    }

    static func encode(_ segments: [ZoomSegment]) throws -> Data {
        try encoder.encode(document(from: segments))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    // MARK: - Parse & validate

    struct Parsed {
        var segments: [ZoomSegment]
        /// Every change the rules forced, in the agent's own numbering.
        var issues: [String]
        /// How many zooms the file declared (so "all dropped" can be told from "none").
        var declared: Int
    }

    enum ParseError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let detail): return "plan.json is not a valid plan (\(detail))"
            }
        }
    }

    /// Decode a plan file and normalise it, reporting every forced change.
    static func parse(_ data: Data, duration: Double, meta: RecordingMeta) throws -> Parsed {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch let error as DecodingError {
            throw ParseError.invalid(describe(error))
        } catch {
            throw ParseError.invalid(error.localizedDescription)
        }
        return validate(document, duration: duration, meta: meta)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "top level" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context):
            return "wrong value type at \(path(context)) (\(context.debugDescription))"
        case .valueNotFound(_, let context):
            return "null where a value is required at \(path(context))"
        case .dataCorrupted(let context):
            return "not valid JSON: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Clamp everything into legal ranges, drop degenerate zooms, enforce
    /// order — and say so, per item, in words the agent can act on.
    private static func validate(_ document: Document, duration: Double, meta: RecordingMeta) -> Parsed {
        var result: [ZoomSegment] = []
        var issues: [String] = []
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        let levels = String(format: "%.1f–%.1f", zoomRange.lowerBound, zoomRange.upperBound)
        let width = Double(meta.pixelWidth)
        let height = Double(meta.pixelHeight)
        let planner = ZoomPlanner(meta: meta)

        for (n, seg) in document.segments.sorted(by: { $0.start < $1.start }).enumerated() {
            let label = "zoom \(n + 1) (start \(f(seg.start)))"
            var start = seg.start
            var end = seg.end
            if start < 0 || start > duration {
                start = min(max(0, start), duration)
                issues.append("\(label): start is outside the video (0–\(f(duration))s) → \(f(start))")
            }
            if end < 0 || end > duration {
                end = min(max(0, end), duration)
                issues.append("\(label): end \(f(seg.end)) is outside the video (0–\(f(duration))s) → \(f(end))")
            }
            if let previous = result.last, start < previous.end + minGap {
                let moved = previous.end + minGap
                issues.append("\(label): starts before the previous zoom ends (\(f(previous.end))s) plus the \(f(minGap))s gap → start moved to \(f(moved))")
                start = moved
            }
            guard end - start >= minHold else {
                issues.append("\(label): dropped — its hold \(f(start))–\(f(end))s is shorter than \(f(minHold))s")
                continue
            }
            var zoom = seg.zoom ?? ZoomPlanner.Config().zoomLevel
            if !zoomRange.contains(zoom) {
                zoom = min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
                issues.append("\(label): zoom \(f(seg.zoom ?? zoom)) is outside \(levels) → \(f(zoom))")
            }

            var steps: [ZoomStep] = []
            for step in (seg.steps ?? []).sorted(by: { $0.t < $1.t }) {
                let slabel = "\(label) step at \(f(step.t))"
                var t = step.t
                if t < start {
                    issues.append("\(slabel): begins before the hold opens (\(f(start))s) → moved to \(f(start))")
                    t = start
                }
                guard t <= end - 0.15 else {
                    issues.append("\(slabel): begins after the hold ends (\(f(end))s) → dropped")
                    continue
                }
                var level = step.zoom
                if !zoomRange.contains(level) {
                    level = min(max(level, zoomRange.lowerBound), zoomRange.upperBound)
                    issues.append("\(slabel): zoom \(f(step.zoom)) is outside \(levels) → \(f(level))")
                }
                steps.append(ZoomStep(id: step.id.flatMap(UUID.init(uuidString:)) ?? UUID(), t: t, zoom: level))
            }

            // Pins in time order, each clamped into the frame and the hold
            // and pushed after the one before it so they never overlap.
            var pins: [PinWindow] = []
            let wanted = (seg.pins ?? []).sorted { ($0.from ?? start) < ($1.from ?? start) }
            var previousUntil = start
            for (pindex, p) in wanted.enumerated() {
                let plabel = wanted.count == 1 ? "\(label): pin" : "\(label): pin \(pindex + 1)"
                let point = CGPoint(x: min(max(p.x, 0), width), y: min(max(p.y, 0), height))
                if point != CGPoint(x: p.x, y: p.y) {
                    issues.append("\(plabel) (\(Int(p.x)), \(Int(p.y))) is outside the \(Int(width))×\(Int(height)) frame → (\(Int(point.x)), \(Int(point.y)))")
                }
                var from = start
                if let wantedFrom = p.from {
                    from = min(max(wantedFrom, start, previousUntil), max(start, end - 0.1))
                    if from != wantedFrom {
                        issues.append("\(plabel) `from` \(f(wantedFrom)) is outside the hold (or overlaps the pin before it) → \(f(from))")
                    }
                } else if previousUntil > start {
                    from = min(previousUntil, max(start, end - 0.1))
                    issues.append("\(plabel) has no `from` but comes after another pin → starts at \(f(from))")
                }
                var until: Double?
                if let wantedUntil = p.until {
                    let clamped = max(min(wantedUntil, end), min(end, from + 0.1))
                    if clamped != wantedUntil {
                        issues.append("\(plabel) `until` \(f(wantedUntil)) is outside the hold (after `from`) → \(f(clamped))")
                    }
                    until = clamped >= end - 0.001 ? nil : clamped
                }
                previousUntil = until ?? end
                pins.append(PinWindow(x: point.x, y: point.y, from: from <= start + 0.001 ? nil : from, until: until))
            }

            var segment = ZoomSegment(
                id: seg.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                start: start, end: end, zoom: zoom, steps: steps, pins: pins
            )
            if let zoomIn = seg.zoomIn {
                let clamped = min(max(zoomIn, easeRange.lowerBound), easeRange.upperBound)
                if clamped != zoomIn {
                    issues.append("\(label): zoomIn \(f(zoomIn))s is outside \(f(easeRange.lowerBound))–\(f(easeRange.upperBound))s → \(f(clamped))")
                }
                segment.zoomIn = clamped
            }
            if let zoomOut = seg.zoomOut {
                let clamped = min(max(zoomOut, easeRange.lowerBound), easeRange.upperBound)
                if clamped != zoomOut {
                    issues.append("\(label): zoomOut \(f(zoomOut))s is outside \(f(easeRange.lowerBound))–\(f(easeRange.upperBound))s → \(f(clamped))")
                }
                segment.zoomOut = clamped
            }
            // A step that would never play — its ease clamped onto the same
            // end as the step before it — is dropped, and said so.
            let playing = Set(planner.holdSteps(for: segment, duration: duration).map(\.id))
            for step in segment.steps where !playing.contains(step.id) {
                issues.append("\(label) step at \(f(step.t)): never plays — its ease would end where the step before it already does (the hold ends at \(f(end))s) → dropped")
            }
            segment.steps.removeAll { !playing.contains($0.id) }
            result.append(segment)
        }

        // A copy-pasted id would make two zooms share an identity; keep the first.
        var seen = Set<UUID>()
        for i in result.indices {
            if !seen.insert(result[i].id).inserted { result[i].id = UUID() }
            for j in result[i].steps.indices where !seen.insert(result[i].steps[j].id).inserted {
                result[i].steps[j].id = UUID()
            }
        }
        return Parsed(segments: result, issues: issues, declared: document.segments.count)
    }

    // MARK: - Derived timing

    /// Human-readable derived timing of a plan, as `./crisp validate` prints it.
    static func describe(_ segments: [ZoomSegment], planner: ZoomPlanner, duration: Double) -> String {
        guard !segments.isEmpty else { return "(no zooms — the whole video plays at full frame)" }
        var lines: [String] = []
        for (index, seg) in segments.enumerated() {
            let span = planner.motionSpan(for: seg, duration: duration)
            let windows = planner.pinWindows(for: seg, duration: duration)
            let framing: String
            if windows.isEmpty {
                framing = " | follows cursor"
            } else if windows.count == 1, let pin = seg.pins.first(where: { $0.id == windows[0].id }),
                      windows[0].from <= seg.start + 0.001, windows[0].until >= span.end - 0.001 {
                framing = String(format: " | pinned at (%.0f, %.0f)", pin.x, pin.y)
            } else {
                let parts = windows.compactMap { window -> String? in
                    guard let pin = seg.pins.first(where: { $0.id == window.id }) else { return nil }
                    return String(format: "pinned at (%.0f, %.0f) %.2f–%.2fs", pin.x, pin.y, window.from, window.until)
                }
                framing = " | " + parts.joined(separator: ", ") + ", follows cursor otherwise"
            }
            lines.append(String(
                format: "zoom %d: camera moves %.2fs → fully zoomed %.2fs (hold opens %.2fs) → hold ends %.2fs → full frame by %.2fs | %.2f×%@",
                index + 1, span.moveStart, span.arrive, seg.start, span.end, span.outEnd, seg.zoom, framing
            ))
            for step in planner.holdSteps(for: seg, duration: duration) {
                let window = planner.stepWindow(step, in: seg, duration: duration)
                lines.append(String(
                    format: "    step: from %.2fs eases to %.2f× by %.2fs",
                    window.start, step.zoom, window.end
                ))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Context document

    /// `context.json`: the recording as data — clicks, drags, the planner's
    /// click clusters, a coarse cursor path — with the current plan, its
    /// derived timing, the rules, and the tools and stills on hand.
    struct Context: Encodable {
        struct Video: Encodable {
            var durationSeconds: Double
            var pixelWidth: Int
            var pixelHeight: Int
            var fps: Double
            var scaleFactor: Double
            var source: String
            var recordedAt: String
            var coordinates: String
        }
        struct Click: Encodable {
            var t: Double
            var x: Double
            var y: Double
            var button: String
        }
        struct Drag: Encodable {
            var startT: Double
            var startX: Double
            var startY: Double
            var endT: Double
            var endX: Double
            var endY: Double
        }
        struct Cluster: Encodable {
            var start: Double
            var end: Double
            var count: Int
            var centerX: Double
            var centerY: Double
            /// 1-based index of the zoom whose hold covers it, if any.
            var coveredByZoom: Int?
        }
        struct CursorPath: Encodable {
            var format: String
            var points: [[Double]]
        }
        struct Timing: Encodable {
            struct StepTiming: Encodable {
                var startsEasing: Double
                var atLevel: Double
                var zoom: Double
            }
            var zoom: Int
            var cameraStartsMoving: Double
            var fullyZoomed: Double
            var holdEnds: Double
            var backAtFullFrame: Double
            var steps: [StepTiming]
        }
        struct Constraints: Encodable {
            var zoomMin: Double
            var zoomMax: Double
            var minHoldSeconds: Double
            var minGapBetweenZoomsSeconds: Double
            var leadInSeconds: Double
            var zoomInSeconds: Double
            var zoomOutSeconds: Double
            var stepEaseSeconds: Double
            var visibleArea: String
        }

        var video: Video
        var clicks: [Click]
        var drags: [Drag]
        var clickClusters: [Cluster]
        var cursorPath: CursorPath
        var currentPlan: Document
        var currentPlanTiming: [Timing]
        var constraints: Constraints
        var tools: [String: String]
        var frames: [Frame]
    }

    static let tools: [String: String] = [
        "frame": "./crisp frame <seconds> [--raw] — annotated still at any time",
        "preview": "./crisp preview <seconds> — the export's look at that time under plan.json",
        "validate": "./crisp validate — rule check + derived timing; finish only on OK",
        "path": "./crisp path [from] [to] [--step s] — the camera over time under plan.json (t, zoom, centre, speed)",
    ]

    static func context(
        meta: RecordingMeta, duration: Double, segments: [ZoomSegment], frames: [Frame]
    ) -> Context {
        let planner = ZoomPlanner(meta: meta)

        let clicks = meta.events
            .filter { $0.kind == .leftDown || $0.kind == .rightDown }
            .map { Context.Click(t: round2($0.t), x: round2($0.x), y: round2($0.y),
                                 button: $0.kind == .rightDown ? "right" : "left") }

        // Drags: a left press whose release lands somewhere else.
        var drags: [Context.Drag] = []
        var pressed: MouseEvent?
        for event in meta.events {
            switch event.kind {
            case .leftDown: pressed = event
            case .leftUp:
                if let down = pressed, hypot(event.x - down.x, event.y - down.y) >= 24 {
                    drags.append(Context.Drag(startT: round2(down.t), startX: round2(down.x), startY: round2(down.y),
                                              endT: round2(event.t), endX: round2(event.x), endY: round2(event.y)))
                }
                pressed = nil
            default: break
            }
        }

        let clusters = planner.clickClusters(meta.events).map { cluster in
            Context.Cluster(
                start: round2(cluster.start), end: round2(cluster.end), count: cluster.count,
                centerX: round2(cluster.center.x), centerY: round2(cluster.center.y),
                coveredByZoom: segments.firstIndex { $0.start - 0.5 <= cluster.start && cluster.end <= $0.end + 0.5 }
                    .map { $0 + 1 }
            )
        }

        // Cursor path, sampled coarsely enough to stay small on long videos.
        var points: [[Double]] = []
        let step = max(0.25, duration / 600)
        var t = 0.0
        while t <= duration {
            if let p = FrameComposer.cursorPosition(samples: meta.samples, at: t) {
                points.append([round2(t), p.x.rounded(), p.y.rounded()])
            }
            t += step
        }

        let timing = segments.enumerated().map { index, seg -> Context.Timing in
            let span = planner.motionSpan(for: seg, duration: duration)
            return Context.Timing(
                zoom: index + 1,
                cameraStartsMoving: round2(span.moveStart), fullyZoomed: round2(span.arrive),
                holdEnds: round2(span.end), backAtFullFrame: round2(span.outEnd),
                steps: seg.steps.sorted { $0.t < $1.t }.map { step in
                    let window = planner.stepWindow(step, in: seg, duration: duration)
                    return Context.Timing.StepTiming(startsEasing: round2(window.start), atLevel: round2(window.end), zoom: round2(step.zoom))
                }
            )
        }

        let config = planner.config
        return Context(
            video: Context.Video(
                durationSeconds: round2(duration), pixelWidth: meta.pixelWidth, pixelHeight: meta.pixelHeight,
                fps: meta.fps, scaleFactor: meta.scaleFactor, source: meta.source ?? "display",
                recordedAt: ISO8601DateFormatter().string(from: meta.startedAt),
                coordinates: "video pixels, origin top-left, y down"
            ),
            clicks: clicks,
            drags: drags,
            clickClusters: clusters,
            cursorPath: Context.CursorPath(format: "[t, x, y] every \(round2(step))s", points: points),
            currentPlan: document(from: segments),
            currentPlanTiming: timing,
            constraints: Context.Constraints(
                zoomMin: zoomRange.lowerBound, zoomMax: zoomRange.upperBound,
                minHoldSeconds: minHold, minGapBetweenZoomsSeconds: minGap,
                leadInSeconds: config.leadIn, zoomInSeconds: config.zoomInDuration,
                zoomOutSeconds: config.zoomOutDuration, stepEaseSeconds: config.stepDuration,
                visibleArea: "pixelWidth/zoom × pixelHeight/zoom, centred by the follower on the cursor and clicks, clamped inside the frame"
            ),
            tools: tools,
            frames: frames
        )
    }

    static func encodeContext(
        meta: RecordingMeta, duration: Double, segments: [ZoomSegment], frames: [Frame]
    ) throws -> Data {
        try encoder.encode(context(meta: meta, duration: duration, segments: segments, frames: frames))
    }

    // MARK: - Briefing

    /// The standing brief every agent gets (CLAUDE.md / AGENTS.md in its workspace).
    static func briefing(config: ZoomPlanner.Config) -> String {
        let leadIn = String(format: "%.2f", config.leadIn)
        let arriveEarly = String(format: "%.2f", config.leadIn - config.zoomInDuration)
        let zoomIn = String(format: "%.2f", config.zoomInDuration)
        let zoomOut = String(format: "%.2f", config.zoomOutDuration)
        let stepEase = String(format: "%.1f", config.stepDuration)
        return """
    # Crisp AI editor — director's brief

    You are the motion director for a screen recording made with Crisp. Crisp records the
    screen and every click, then plays it back through a virtual camera that zooms into the
    action. **Framing is automatic**: while zoomed, the camera follows the recorded cursor
    and recentres on clicks by itself (with a dead zone, a little look-ahead and a damped
    ease, so it never chases jitter). Your job is the part that needs judgement — **when**
    to be zoomed and **how far** — as an editorial pass over an automatic plan that is
    competent but unpolished. You are not re-authoring from scratch unless the user asks.

    ## What is in this directory

    - `context.json` — everything known about the video: size, duration, every click and
      drag, click clusters (the actions the automatic plan reasoned about), a
      sampled cursor path, the current plan, its derived timing, and the rules below as data.
    - `frame_N.jpg` — annotated stills: a coordinate grid in video pixels, rings on the
      clicks within ±1.5 s (with times), a blue dot for the cursor, and a green rectangle
      showing what the current plan's camera sees at that moment. Look at all of them.
    - `plan.json` — the current plan, in the exact shape you write back. Overwrite it.
    - `./crisp` — your tools (run `./crisp help`):
      - `./crisp frame <seconds>` — another annotated still at any time (`--raw` for clean).
      - `./crisp preview <seconds>` — what the export will show at that time under your
        `plan.json`: the real zoomed crop, as the follower frames it, with cursor and
        ripples. This is how you check that a level shows enough (or little enough).
      - `./crisp validate` — checks `plan.json` against the app's rules and prints the
        derived timing of every zoom and step. The app runs the same checks on apply and
        clamps anything you leave wrong, so finish only when it prints `OK`.
      - `./crisp path [from] [to]` — the camera over time under `plan.json`, as numbers
        (t, zoom, centre, speed): where the follower looks, when a still isn't enough.

    ## How the camera works

    The plan is a list of **zooms**. Each zoom is a hold window `[start, end]` in seconds
    during which the camera is zoomed to level `zoom`. Around the hold the app eases in
    and out:

    - by default the camera starts moving **\(leadIn) s before `start`** and is fully zoomed **\(arriveEarly) s
      before `start`** (a \(zoomIn) s ease-in);
    - after `end` it eases back to the full frame over **\(zoomOut) s**.
    - optional `zoomIn` / `zoomOut` (seconds) on a zoom override those ease lengths — a longer
      `zoomIn` starts the move earlier so the camera still arrives at the hold on time, just
      more slowly. A longer `zoomOut` eases back to full frame more slowly after `end`.

    So `start` should sit on the first click of the action it covers — the viewer is already
    zoomed when the click happens. Between zooms the camera is at full frame; leave at least
    a beat of full frame between them unless the actions really are one continuous thing.

    Inside a hold, a zoom may contain **steps**: at `t` the level eases (over \(stepEase) s) to the
    step's `zoom` and stays there for the rest of the hold. Use a step to tighten on a small
    control mid-action, or to loosen when the action spreads out. At zoom `z` the camera
    shows `pixelWidth / z` by `pixelHeight / z` of the frame, centred by the follower on the
    cursor and clicks and clamped inside the frame. If a preview shows the wrong thing, the
    fix is usually a different level or different timing.

    The exception is action that is **not under the cursor** — a panel that opens on the far
    side, a result appearing elsewhere while the mouse rests. For that, give the zoom a
    `pins`: a list of `{"x": …, "y": …}` in video pixels. A pinned zoom holds that centre
    instead of following (the crop is clamped inside the frame) — for its whole hold by
    default, or add `"from"` / `"until"` (seconds inside the hold) to pin only part of it and
    follow the cursor for the rest; the camera glides between the two. Several entries, in
    time order and not overlapping, pin different spots at different times. Use pins
    sparingly and only when the follower would genuinely miss the point; check them with
    `./crisp preview`.

    ## The plan file

    ```json
    {"segments": [
      {"id": "keep-if-unchanged", "start": 4.30, "end": 8.00, "zoom": 1.8,
       "steps": [{"id": "…", "t": 6.00, "zoom": 2.3}]},
      {"start": 12.00, "end": 15.50, "zoom": 2.0, "pins": [{"x": 4200, "y": 900, "until": 14.00}]}
    ]}
    ```

    - `segments` sorted by `start`, non-overlapping, with at least 0.20 s between one zoom's
      `end` and the next `start`; each hold at least 0.30 s.
    - `zoom` between 1.2 and 3.0. 1.5–2.0 suits most UI; 2.2–2.6 for a small control; go
      higher only for something tiny.
    - `steps` may be empty. Each `t` must be inside its zoom's hold.
    - `pins` may be empty or omitted: the camera follows the cursor (the default and usually
      right).
    - optional `zoomIn` / `zoomOut` (seconds) set the ease-in and ease-out lengths; omit
      them for the defaults above.
    - Keep the `id` of every zoom and step you carry over (edited or not) and omit it on new
      ones — the app uses ids to show the user exactly what changed.
    - Two decimals are plenty for times and levels.

    ## Workflow, every turn

    1. Read `context.json`. Note the click clusters, which ones the current plan covers, the
       drags (a drag is one continuous action — one zoom), and any user note.
    2. Look at every `frame_N.jpg`. Identify what the user is doing at each moment and how
       much of the screen it needs. Pull extra frames with `./crisp frame <t>` wherever the
       story is unclear (between zooms, at uncovered clicks).
    3. Write the polished plan to `plan.json`.
    4. Run `./crisp validate`. Fix anything it reports and re-run until it prints `OK`.
    5. Run `./crisp preview <t>` at each hold opening (`start + 0.1`) and each step you
       changed, and look at the images. If the element is too small, zoom in more; if the
       viewer loses context, zoom out; if the wrong thing is framed, the timing is off.
    6. Reply to the user in 2–4 plain sentences: what you changed and why, in editorial
       terms ("tightened the opening on the Save click", "merged the two form zooms"). No
       JSON in the reply.

    On follow-up turns the files are refreshed to the user's current plan, which they may
    have hand-edited since your last reply — re-read `context.json` before changing anything,
    and apply the note on top of what is there.

    ## What "polished" means, in priority order

    1. **Timing.** Every hold opens on the click it serves, never noticeably late; it ends
       when the action is done, not on a timer. Clusters that are one continuous action share
       one zoom.
    2. **Fewer, better zooms.** Drop zooms on trivial or isolated clicks (closing a dialog,
       an idle click) — emphasis means nothing if everything is emphasised. Keep the ones that
       show the viewer something.
    3. **The right level.** Enough magnification that the control being used reads clearly,
       enough context that the viewer knows where it lives. Check with `./crisp preview`.
    4. **Few steps.** Step only when the action's scale genuinely changes mid-hold.
    5. **Calm pacing.** Breathing room at full frame between bursts; no zoom shorter than
       about a second unless the user asks for punchy cuts.
    """
    }
}
