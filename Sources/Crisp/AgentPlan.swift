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

    // MARK: - Rhythm

    /// The editorial targets the brief holds the agent to, and the summary
    /// measures the plan against. Not rules — the validator never enforces
    /// them — but the numbers the brief quotes, kept here so they agree.

    /// Full frame between two zooms shorter than this reads as one run of
    /// zooms, not two shots.
    static let breathSeconds = 3.0
    /// The follower moving more than this many visible widths per second of
    /// hold is a camera chasing the cursor, not a shot. (A calm real hold
    /// measures 0.00–0.10; the follower's own speed cap is 1.6.)
    static let panChurnLimit = 0.25
    /// The share of the runtime a plan should zoom, at most.
    static let zoomedPercentTarget = 35.0
    /// Clicks per minute below which a recording is "calm", and at or above
    /// which it is "hectic"; "busy" in between.
    static let calmClicksPerMinute = 6.0
    static let hecticClicksPerMinute = 15.0

    static func pace(clicksPerMinute: Double) -> String {
        clicksPerMinute < calmClicksPerMinute ? "calm" : (clicksPerMinute < hecticClicksPerMinute ? "busy" : "hectic")
    }

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
        let keys = planner.keyframes(from: segments, duration: duration)
        var lines: [String] = []
        for (index, seg) in segments.enumerated() {
            let span = planner.motionSpan(for: seg, duration: duration)
            let pan = planner.panTravel(for: seg, keys: keys, duration: duration)
            let panning = pan.perSecond > panChurnLimit
                ? String(format: " | PANS %.2f widths/s — the camera chases the cursor here", pan.perSecond)
                : String(format: " | pans %.2f widths/s", pan.perSecond)
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
                format: "zoom %d: camera moves %.2fs → fully zoomed %.2fs (hold opens %.2fs) → hold ends %.2fs → full frame by %.2fs | %.2f×%@%@",
                index + 1, span.moveStart, span.arrive, seg.start, span.end, span.outEnd, seg.zoom, framing, panning
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

    /// `context.json`: the recording as data — a summary of its pace and how
    /// much of it the plan zooms, the stretches of activity an editor thinks
    /// in, every click and drag, the planner's finer click clusters, a coarse
    /// cursor path — with the current plan, its derived timing (including how
    /// much each zoom pans), the rules, and the tools and stills on hand.
    struct Context: Encodable {
        /// The numbers that say at a glance whether this recording is busy
        /// and whether the plan is over-zoomed. Listed first in the file.
        struct Summary: Encodable {
            var durationSeconds: Double
            var clicks: Int
            var clicksPerMinute: Double
            /// "calm", "busy" or "hectic" from `clicksPerMinute` — see the brief.
            var pace: String
            var clicksByMinute: [Int]
            var drags: Int
            var stretches: Int
            var stretchesWithoutZoom: Int
            var zooms: Int
            var zoomedSeconds: Double
            var zoomedPercent: Double
            /// The most zooms in a row with less than a breath of full frame
            /// between them.
            var longestRunOfZooms: Int
            var zoomsThatPan: Int
        }
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
        /// A run of clusters with less than `stretchGap` between them: one
        /// task the user was doing, the unit to decide zooms over.
        struct Stretch: Encodable {
            var start: Double
            var end: Double
            var durationSeconds: Double
            var clicks: Int
            var drags: Int
            var centerX: Double
            var centerY: Double
            /// The box the clicks span, in video pixels.
            var spreadWidth: Double
            var spreadHeight: Double
            /// The tightest level that still shows every click of the stretch
            /// without the follower panning; null when even the loosest
            /// level would have to pan.
            var maxZoomWithoutPanning: Double?
            /// "focused" when `maxZoomWithoutPanning` is set, else "spread".
            var kind: String
            /// 1-based indexes of the zooms whose holds overlap it.
            var coveredByZooms: [Int]
        }
        struct Cluster: Encodable {
            var start: Double
            var end: Double
            var count: Int
            var centerX: Double
            var centerY: Double
            var spreadWidth: Double
            var spreadHeight: Double
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
            var holdSeconds: Double
            var clicksCovered: Int
            /// How far the follower moves during the hold, in visible widths
            /// (a width at the level in effect) — and per second of hold.
            var panWidths: Double
            var panWidthsPerSecond: Double
            var steps: [StepTiming]
        }
        struct Constraints: Encodable {
            var zoomMin: Double
            var zoomMax: Double
            var minHoldSeconds: Double
            var minGapBetweenZoomsSeconds: Double
            var clusterGapSeconds: Double
            var stretchGapSeconds: Double
            var leadInSeconds: Double
            var zoomInSeconds: Double
            var zoomOutSeconds: Double
            var stepEaseSeconds: Double
            var visibleArea: String
        }

        var summary: Summary
        var video: Video
        var stretches: [Stretch]
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
                spreadWidth: cluster.bounds.width.rounded(), spreadHeight: cluster.bounds.height.rounded(),
                coveredByZoom: segments.firstIndex { $0.start - 0.5 <= cluster.start && cluster.end <= $0.end + 0.5 }
                    .map { $0 + 1 }
            )
        }

        let stretches = planner.clickClusters(meta.events, gap: planner.config.stretchGap).map { stretch in
            let fit = planner.maxZoomWithoutPanning(over: stretch.bounds)
            return Context.Stretch(
                start: round2(stretch.start), end: round2(stretch.end),
                durationSeconds: round2(stretch.end - stretch.start), clicks: stretch.count,
                drags: drags.filter { $0.startT >= stretch.start - 0.01 && $0.startT <= stretch.end + 0.01 }.count,
                centerX: round2(stretch.center.x), centerY: round2(stretch.center.y),
                spreadWidth: stretch.bounds.width.rounded(), spreadHeight: stretch.bounds.height.rounded(),
                maxZoomWithoutPanning: fit.map(round2), kind: fit == nil ? "spread" : "focused",
                coveredByZooms: segments.enumerated()
                    .filter { $0.element.start <= stretch.end && stretch.start <= $0.element.end }
                    .map { $0.offset + 1 }
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

        let keys = planner.keyframes(from: segments, duration: duration)
        let timing = segments.enumerated().map { index, seg -> Context.Timing in
            let span = planner.motionSpan(for: seg, duration: duration)
            let pan = planner.panTravel(for: seg, keys: keys, duration: duration)
            return Context.Timing(
                zoom: index + 1,
                cameraStartsMoving: round2(span.moveStart), fullyZoomed: round2(span.arrive),
                holdEnds: round2(span.end), backAtFullFrame: round2(span.outEnd),
                holdSeconds: round2(span.end - seg.start),
                clicksCovered: clicks.filter { $0.t >= seg.start && $0.t <= span.end }.count,
                panWidths: round2(pan.widths), panWidthsPerSecond: round2(pan.perSecond),
                steps: seg.steps.sorted { $0.t < $1.t }.map { step in
                    let window = planner.stepWindow(step, in: seg, duration: duration)
                    return Context.Timing.StepTiming(startsEasing: round2(window.start), atLevel: round2(window.end), zoom: round2(step.zoom))
                }
            )
        }

        let config = planner.config
        let zoomed = timing.reduce(0.0) { $0 + max(0, $1.backAtFullFrame - $1.cameraStartsMoving) }
        var longestRun = 0
        var run = 0
        for (index, seg) in segments.enumerated() {
            run = index > 0 && seg.start - segments[index - 1].end < breathSeconds ? run + 1 : 1
            longestRun = max(longestRun, run)
        }
        let perMinute = duration > 0 ? Double(clicks.count) / duration * 60 : 0
        let summary = Context.Summary(
            durationSeconds: round2(duration), clicks: clicks.count, clicksPerMinute: round2(perMinute),
            pace: pace(clicksPerMinute: perMinute),
            clicksByMinute: (0..<max(1, Int((duration / 60).rounded(.up)))).map { minute in
                clicks.filter { Int($0.t / 60) == minute }.count
            },
            drags: drags.count, stretches: stretches.count,
            stretchesWithoutZoom: stretches.filter { $0.coveredByZooms.isEmpty }.count,
            zooms: segments.count, zoomedSeconds: round2(min(zoomed, duration)),
            zoomedPercent: duration > 0 ? (min(zoomed, duration) / duration * 100).rounded() : 0,
            longestRunOfZooms: longestRun,
            zoomsThatPan: timing.filter { $0.panWidthsPerSecond > panChurnLimit }.count
        )
        return Context(
            summary: summary,
            video: Context.Video(
                durationSeconds: round2(duration), pixelWidth: meta.pixelWidth, pixelHeight: meta.pixelHeight,
                fps: meta.fps, scaleFactor: meta.scaleFactor, source: meta.source ?? "display",
                recordedAt: ISO8601DateFormatter().string(from: meta.startedAt),
                coordinates: "video pixels, origin top-left, y down"
            ),
            stretches: stretches,
            clicks: clicks,
            drags: drags,
            clickClusters: clusters,
            cursorPath: Context.CursorPath(format: "[t, x, y] every \(round2(step))s", points: points),
            currentPlan: document(from: segments),
            currentPlanTiming: timing,
            constraints: Context.Constraints(
                zoomMin: zoomRange.lowerBound, zoomMax: zoomRange.upperBound,
                minHoldSeconds: minHold, minGapBetweenZoomsSeconds: minGap,
                clusterGapSeconds: config.clusterGap, stretchGapSeconds: config.stretchGap,
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

    // MARK: - Rhythm line

    /// The plan against the brief's rhythm targets, as `./crisp validate`
    /// prints it after the timing — the same numbers as `summary`.
    static func rhythm(of segments: [ZoomSegment], meta: RecordingMeta, duration: Double) -> String {
        let s = context(meta: meta, duration: duration, segments: segments, frames: []).summary
        var over: [String] = []
        if s.zoomedPercent > zoomedPercentTarget {
            over.append(String(format: "zoomed %.0f%% of the runtime, target at most %.0f%%", s.zoomedPercent, zoomedPercentTarget))
        }
        if s.longestRunOfZooms > 3 {
            over.append(String(format: "%d zooms back-to-back with under %.0fs of full frame between them", s.longestRunOfZooms, breathSeconds))
        }
        if s.zoomsThatPan > 0 {
            over.append(String(format: "%d zoom(s) pan more than %.1f widths/s", s.zoomsThatPan, panChurnLimit))
        }
        let line = String(
            format: "Rhythm: %@ recording (%.1f clicks/min, %d stretch(es)); %d zoom(s) covering %d stretch(es); zoomed %.0f%% of %.0fs; longest run %d.",
            s.pace, s.clicksPerMinute, s.stretches, s.zooms, s.stretches - s.stretchesWithoutZoom,
            s.zoomedPercent, s.durationSeconds, s.longestRunOfZooms
        )
        return over.isEmpty ? line + " Within the brief's targets." : line + "\n  OVER TARGET: " + over.joined(separator: "; ")
    }

    // MARK: - Briefing

    /// The standing brief every agent gets (CLAUDE.md / AGENTS.md in its workspace).
    static func briefing(config: ZoomPlanner.Config) -> String {
        let leadIn = String(format: "%.2f", config.leadIn)
        let arriveEarly = String(format: "%.2f", config.leadIn - config.zoomInDuration)
        let zoomIn = String(format: "%.2f", config.zoomInDuration)
        let zoomOut = String(format: "%.2f", config.zoomOutDuration)
        let stepEase = String(format: "%.1f", config.stepDuration)
        let clusterGap = String(format: "%.1f", config.clusterGap)
        let stretchGap = String(format: "%.0f", config.stretchGap)
        let breath = String(format: "%.0f", breathSeconds)
        let churn = String(format: "%.1f", panChurnLimit)
        let zoomedTarget = String(format: "%.0f", zoomedPercentTarget)
        let calm = String(format: "%.0f", calmClicksPerMinute)
        let hectic = String(format: "%.0f", hecticClicksPerMinute)
        return """
    # Crisp AI editor — director's brief

    You are the motion director for a screen recording made with Crisp. Crisp records the
    screen and every click, then plays it back through a virtual camera that zooms into the
    action. **Framing is automatic**: while zoomed, the camera follows the recorded cursor
    and recentres on clicks by itself (with a dead zone, a little look-ahead and a damped
    ease, so it never chases jitter). Your job is the part that needs judgement — **which
    moments earn a zoom, when, and how far**.

    You start from an automatic plan that **over-covers on purpose**: every burst of clicks
    (clicks less than \(clusterGap) s apart) gets its own zoom, so nothing is missed. On a short,
    calm recording that draft is nearly right and you are polishing it. On a long or busy
    one it is far too much — a zoom every few seconds, the camera forever diving in and
    pulling back — and your main work is choosing the few moments that deserve emphasis
    and letting everything else play at full frame. Emphasis means nothing if everything
    is emphasised. `summary` in `context.json` tells you which situation you are in.

    ## What is in this directory

    - `context.json` — everything known about the video, in the order to read it:
      - `summary` — the pace (`clicksPerMinute`, and `pace`: `calm` under \(calm)/min, `hectic`
        from \(hectic)/min, `busy` between), `clicksByMinute`, and how much the current plan
        zooms: `zooms`, `zoomedPercent` of the runtime, `longestRunOfZooms` back-to-back,
        `zoomsThatPan`. Read this first: it says whether you are polishing or pruning.
      - `stretches` — the recording cut into tasks: runs of clicks with less than \(stretchGap) s
        between them, each with its duration, click and drag counts, the box its clicks
        span (`spreadWidth` × `spreadHeight`), `maxZoomWithoutPanning` — the tightest level
        that shows every click of the stretch without the follower moving — and `kind`:
        `focused` fits in one shot, `spread` cannot be held without panning. Decide zooms
        stretch by stretch; `coveredByZooms` says what the current plan does with each.
      - every `click` and `drag`, the finer `clickClusters` the automatic plan gave a zoom
        each, and a sampled `cursorPath`;
      - `currentPlan`, and `currentPlanTiming` — each zoom's derived timing, `holdSeconds`,
        `clicksCovered`, and how much it pans (`panWidthsPerSecond`, see Rhythm);
      - the rules below as data (`constraints`), the tools, and the stills.
    - `frame_N.jpg` — annotated stills: one per stretch across the *whole* runtime (thinned
      evenly on long recordings), plus zoom openings and steps that fall elsewhere. Each has
      a coordinate grid in video pixels, rings on the clicks within ±1.5 s (with times), a
      blue dot for the cursor, and a green rectangle showing what the current plan's camera
      sees at that moment. Look at all of them.
    - `plan.json` — the current plan, in the exact shape you write back. Overwrite it.
    - `./crisp` — your tools (run `./crisp help`):
      - `./crisp frame <seconds>` — another annotated still at any time (`--raw` for clean).
      - `./crisp preview <seconds>` — what the export will show at that time under your
        `plan.json`: the real zoomed crop, as the follower frames it, with cursor and
        ripples. This is how you check that a level shows enough (or little enough).
      - `./crisp validate` — checks `plan.json` against the app's rules, prints the derived
        timing of every zoom and step with how much each pans, and a `Rhythm:` line
        against the targets below. The app runs the same checks on apply and clamps
        anything you leave wrong, so finish only when it prints `OK`.
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

    ## Rhythm — how much zoom a video can carry

    These are targets, not rules: the validator reports them but never enforces them. The
    viewer notices every one of them.

    - **Zoomed for at most about \(zoomedTarget)% of the runtime** (`summary.zoomedPercent`). Full
      frame is the resting state; a zoom is an event.
    - **A breath between zooms.** At least \(breath) s of full frame between one zoom's end and
      the next one's start — unless the two are one continuous action, in which case they
      are one zoom. Never more than three zooms back-to-back (`summary.longestRunOfZooms`).
    - **At most one zoom per stretch**, and on a `busy` or `hectic` recording most stretches
      get none. A stretch earns a zoom when it shows the viewer something they need to
      *read*: a small control being used, a value being typed, a result appearing.
      Navigating between places, scrolling, closing dialogs, idle or exploratory clicks:
      full frame.
    - **Never hold a shot the follower cannot keep.** Zooming on a `spread` stretch means
      the camera pans the whole time. Zoom no tighter than the stretch's
      `maxZoomWithoutPanning`, or leave it at full frame. Any zoom whose
      `panWidthsPerSecond` is above \(churn) is chasing the cursor: loosen it, split it into two
      stiller shots with full frame between, or drop it. `./crisp validate` flags these.
    - **Holds of roughly 3–12 s.** Under a second only for punchy cuts the user asked for;
      over about 15 s usually means two moments, or one that wanted full frame.

    As a rule of thumb, a `hectic` three-minute recording arrives with 30–40 automatic
    zooms; a polished plan for it has 6–12.

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

    1. Read `context.json`: `summary` first, then `stretches`. Decide, stretch by stretch,
       which ones earn a zoom and at what level (no tighter than `maxZoomWithoutPanning`),
       and what the user note asks for. Note the drags (a drag is one continuous action —
       one zoom, at a level that fits its whole extent).
    2. Look at every `frame_N.jpg`. Identify what the user is doing in each stretch and how
       much of the screen it needs. Pull extra frames with `./crisp frame <t>` wherever the
       story is unclear.
    3. Write the polished plan to `plan.json`.
    4. Run `./crisp validate`. Fix anything it reports and re-run until it prints `OK`, and
       read the `Rhythm:` line and the pan figures — bring anything over target back in.
    5. Run `./crisp preview <t>` at each hold opening (`start + 0.1`) and each step you
       changed, and look at the images. If the element is too small, zoom in more; if the
       viewer loses context, zoom out; if the wrong thing is framed, the timing is off.
    6. Reply to the user in 2–4 plain sentences: what you changed and why, in editorial
       terms ("kept three zooms of the twenty-two, on the name field, the drag and the
       result"; "tightened the opening on the Save click"). No JSON in the reply.

    On follow-up turns the files are refreshed to the user's current plan, which they may
    have hand-edited since your last reply — re-read `context.json` before changing anything,
    and apply the note on top of what is there.

    ## What "polished" means, in priority order

    1. **Few enough zooms.** Within the rhythm targets above: the moments that show the
       viewer something get a zoom, the rest play at full frame. On a calm recording that
       may mean keeping most of the automatic plan; on a hectic one, a small fraction.
    2. **Timing.** Every hold opens on the click it serves, never noticeably late; it ends
       when the action is done, not on a timer. Clusters that are one continuous action share
       one zoom.
    3. **The right level.** Enough magnification that the control being used reads clearly,
       enough context that the viewer knows where it lives, and never tighter than the
       stretch can hold still. Check with `./crisp preview`.
    4. **A still camera.** No zoom that pans its way through a stretch; no more than three
       zooms in a row; breathing room at full frame between bursts.
    5. **Few steps.** Step only when the action's scale genuinely changes mid-hold.

    ## A worked example

    A three-minute `hectic` recording: 58 clicks, 22 stretches, and an automatic plan of 37
    zooms zoomed for 71% of the runtime with a longest run of 9. The user creates a project:
    a new-file dialog, a long spell of wandering through menus and side panels, typing a
    name into a small field, dragging a panel wider, then browsing the results.

    The polished plan kept 8 zooms. The name field — a `focused` stretch spanning 140×30 px
    — got 2.2× from its first click until typing stopped, six seconds. The drag got 1.6×
    over its whole extent (`maxZoomWithoutPanning` 1.7). The dialog, the first result and a
    settings toggle each got one zoom of 4–8 s at 1.8×. Everything else went to full frame:
    the menu wandering was a `spread` stretch whose zooms had panned at 0.9 widths/s, and
    the dialog closes and idle clicks showed the viewer nothing. Zoomed share fell to 28%,
    longest run to 2, and the reply said so in three sentences.
    """
    }
}
