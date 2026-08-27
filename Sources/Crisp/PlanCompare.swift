import Foundation
import CoreImage
import CoreGraphics

/// Anything the live compositor can drive: `FrameComposer` for the normal
/// preview, `CompareComposer` for the stacked before/after view.
protocol FrameComposing: AnyObject {
    var width: Double { get }
    var height: Double { get }
    func compose(source: CIImage, at t: Double) -> CIImage
}

/// Stacks two composed versions of the same master frame — the baseline plan
/// on top, the current plan below — into one tall frame. One player, one
/// decode, one timestamp: the halves can't drift apart.
final class CompareComposer: FrameComposing {
    let before: FrameComposer
    let after: FrameComposer
    /// Black band between the halves, in master pixels.
    static let gap: Double = 8

    var width: Double { after.width }
    var height: Double { after.height * 2 + Self.gap }

    init(meta: RecordingMeta, before: [ZoomPlanner.Keyframe], after: [ZoomPlanner.Keyframe], cursorStyle: CursorStyle) {
        self.before = FrameComposer(meta: meta, keys: before, cursorStyle: cursorStyle)
        self.after = FrameComposer(meta: meta, keys: after, cursorStyle: cursorStyle)
    }

    func compose(source: CIImage, at t: Double) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let bottom = after.compose(source: source, at: t)
        // Core Image is bottom-left origin, so "top" is translated up.
        let top = before.compose(source: source, at: t)
            .transformed(by: CGAffineTransform(translationX: 0, y: after.height + Self.gap))
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        return top.composited(over: bottom.composited(over: background)).cropped(to: extent)
    }
}

/// What changed between two zoom plans, in terms the editor can show: which
/// current zooms differ from the baseline, which baseline zooms are gone, and
/// the merged camera-motion windows that cover every difference (so compare
/// playback can loop just the edited parts).
struct PlanDiff {
    struct Range: Equatable {
        var start: Double
        var end: Double
    }

    /// IDs of current-plan zooms that are new or differ from the baseline.
    var changed: Set<UUID> = []
    /// Baseline zooms with no counterpart in the current plan.
    var removed: [ZoomSegment] = []
    /// Sorted, non-overlapping windows covering every difference.
    var ranges: [Range] = []

    var isEmpty: Bool { ranges.isEmpty }

    init(before: [ZoomSegment], after: [ZoomSegment], planner: ZoomPlanner, duration: Double) {
        // Pair by id first (hand edits keep ids), then pair leftovers by hold
        // overlap (AI replies come back with fresh ids).
        var pairs: [(ZoomSegment, ZoomSegment)] = []
        var unpairedBefore = before
        var unpairedAfter: [ZoomSegment] = []
        for seg in after {
            if let i = unpairedBefore.firstIndex(where: { $0.id == seg.id }) {
                pairs.append((unpairedBefore.remove(at: i), seg))
            } else {
                unpairedAfter.append(seg)
            }
        }
        var candidates: [(overlap: Double, b: Int, a: Int)] = []
        for (bi, b) in unpairedBefore.enumerated() {
            for (ai, a) in unpairedAfter.enumerated() {
                let overlap = min(b.end, a.end) - max(b.start, a.start)
                if overlap > 0 { candidates.append((overlap, bi, ai)) }
            }
        }
        var usedBefore = Set<Int>()
        var usedAfter = Set<Int>()
        for c in candidates.sorted(by: { $0.overlap > $1.overlap }) {
            guard !usedBefore.contains(c.b), !usedAfter.contains(c.a) else { continue }
            usedBefore.insert(c.b)
            usedAfter.insert(c.a)
            pairs.append((unpairedBefore[c.b], unpairedAfter[c.a]))
        }

        var spans: [Range] = []
        func addSpan(_ seg: ZoomSegment) {
            let span = planner.motionSpan(for: seg, duration: duration)
            spans.append(Range(start: span.moveStart, end: span.outEnd))
        }
        for (b, a) in pairs where !Self.sameContent(b, a) {
            changed.insert(a.id)
            addSpan(b)
            addSpan(a)
        }
        for (i, seg) in unpairedAfter.enumerated() where !usedAfter.contains(i) {
            changed.insert(seg.id)
            addSpan(seg)
        }
        for (i, seg) in unpairedBefore.enumerated() where !usedBefore.contains(i) {
            removed.append(seg)
            addSpan(seg)
        }

        // Merge into non-overlapping windows; windows that nearly touch join up.
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, span.start <= last.end + 0.05 {
                ranges[ranges.count - 1].end = max(last.end, span.end)
            } else {
                ranges.append(span)
            }
        }
    }

    /// Equality ignoring ids, with slack for the two-decimal rounding the AI
    /// round-trip applies to a plan it decided to leave alone.
    static func sameContent(_ a: ZoomSegment, _ b: ZoomSegment) -> Bool {
        func near(_ x: Double, _ y: Double, _ tolerance: Double) -> Bool { abs(x - y) <= tolerance }
        guard near(a.start, b.start, 0.011), near(a.end, b.end, 0.011), near(a.zoom, b.zoom, 0.011),
              near(a.zoomIn ?? -1, b.zoomIn ?? -1, 0.011), near(a.zoomOut ?? -1, b.zoomOut ?? -1, 0.011),
              a.steps.count == b.steps.count, a.pins.count == b.pins.count else { return false }
        let byStart: (PinWindow, PinWindow) -> Bool = { ($0.from ?? -1) < ($1.from ?? -1) }
        for (p, q) in zip(a.pins.sorted(by: byStart), b.pins.sorted(by: byStart)) {
            guard near(p.x, q.x, 0.5), near(p.y, q.y, 0.5),
                  near(p.from ?? -1, q.from ?? -1, 0.011), near(p.until ?? -1, q.until ?? -1, 0.011) else { return false }
        }
        for (p, q) in zip(a.steps.sorted { $0.t < $1.t }, b.steps.sorted { $0.t < $1.t }) {
            guard near(p.t, q.t, 0.011), near(p.zoom, q.zoom, 0.011) else { return false }
        }
        return true
    }
}
