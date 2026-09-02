import Foundation
import CoreGraphics

/// Codec used for the master (recording-time) file.
enum MasterCodec: String, CaseIterable, Identifiable, Codable {
    case hevc10 = "HEVC 10-bit"
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: String { rawValue }

    /// Shown under the name in the codec select.
    var detail: String {
        switch self {
        case .hevc10:
            return "10-bit color, smaller files. Best for most recordings."
        case .proRes422:
            return "Intra-frame master. Easier to edit, larger files."
        case .proRes4444:
            return "Full 4:4:4 chroma. Best gradients, ~1 GB per minute."
        }
    }
}

/// Container + codec used for "Export with zooms" output.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case movHEVC = "MOV (HEVC 10-bit)"
    case mp4HEVC = "MP4 (HEVC 10-bit)"
    case mp4H264 = "MP4 (H.264)"

    var id: String { rawValue }

    static let `default`: ExportFormat = .movHEVC
    static let defaultsKey = "export.format"

    /// Every extension an export can have, used when scanning a recording folder.
    static let fileExtensions = ["mov", "mp4"]

    var fileExtension: String {
        switch self {
        case .movHEVC: return "mov"
        case .mp4HEVC, .mp4H264: return "mp4"
        }
    }
}

/// A single mouse event captured during recording.
/// Times are in seconds relative to the capture session start (first video frame).
struct MouseEvent: Codable {
    enum Kind: String, Codable {
        case leftDown, leftUp, rightDown
    }

    var t: Double
    var kind: Kind
    /// Position in master-video pixel coordinates (top-left origin, y down).
    var x: Double
    var y: Double
}

/// Appearance of the system cursor at a sample. Missing/nil in JSON is arrow
/// (old recordings, and ticks where the cursor was the default arrow).
enum CursorKind: String, Codable {
    case arrow, pointer, iBeam
}

/// Periodic cursor position sample, same coordinate space as MouseEvent.
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
    /// nil = arrow. Omitted from JSON so arrow ticks stay `{t,x,y}`.
    var kind: CursorKind? = nil
}

/// Sidecar metadata written next to master.mov as events.json.
struct RecordingMeta: Codable {
    var version: Int = 1
    /// "display", "window", or "region". Optional so pre-existing recordings still decode.
    var source: String?
    var displayID: UInt32
    /// Master video size in pixels.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Retina scale factor (pixels per point) of the captured display.
    var scaleFactor: Double
    var fps: Double
    var codec: String
    var startedAt: Date
    /// Host-clock time (seconds) of the first video frame; event times are relative to this.
    var sessionStartHostSeconds: Double
    var events: [MouseEvent]
    var samples: [CursorSample]
}

/// A mid-hold zoom keyframe: from `t` the camera eases to `zoom` (over the
/// planner's `stepDuration`) and holds it for the rest of the zoom.
struct ZoomStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var t: Double
    var zoom: Double
}

/// A stretch of a zoom's hold where the camera holds a fixed framing
/// instead of following the cursor — for action that isn't under the
/// mouse. `x`/`y` are master-video pixels; `from`/`until` are seconds on
/// the master timeline, nil meaning the hold's start / end. A zoom can
/// carry several, one after another; a pin with no `until` is "open":
/// it holds to the end of the zoom until the user releases it.
struct PinWindow: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var from: Double? = nil
    var until: Double? = nil

    var point: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = Double(newValue.x); y = Double(newValue.y) }
    }
}

/// One zoom: the camera holds fully zoomed at `zoom` from `start` to `end`
/// (seconds, master-video timeline); eased transitions are added around it
/// and the framing follows the recorded cursor automatically. `steps` change
/// the level part-way through the hold; `pins` hold the framing still for
/// parts of it.
struct ZoomSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var zoom: Double
    var steps: [ZoomStep] = []
    var pins: [PinWindow] = []
    /// Ease-in / ease-out length in seconds. nil = the planner defaults
    /// (`zoomInDuration` / `zoomOutDuration`). A longer zoom-in starts the
    /// camera earlier so it still arrives at the hold on time, just slower.
    var zoomIn: Double? = nil
    var zoomOut: Double? = nil
}

/// Lenient decoding: plans written before steps existed load, plans from
/// the era of hand-placed pans keep their "zoom in further" moves as steps
/// (their centres are dropped — the follower frames the shot now), and a
/// plan's single `pinX`/`pinY`/`pinFrom`/`pinUntil` becomes its one pin.
extension ZoomSegment {
    private enum CodingKeys: String, CodingKey {
        case id, start, end, zoom, steps, pans, pins, pinX, pinY, pinFrom, pinUntil, zoomIn, zoomOut
    }

    private struct LegacyPan: Decodable {
        var id: UUID?
        var t: Double
        var zoom: Double?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        zoom = try container.decode(Double.self, forKey: .zoom)
        var steps = try container.decodeIfPresent([ZoomStep].self, forKey: .steps) ?? []
        if steps.isEmpty, let pans = try? container.decodeIfPresent([LegacyPan].self, forKey: .pans) {
            steps = pans.compactMap { pan in
                pan.zoom.map { ZoomStep(id: pan.id ?? UUID(), t: pan.t, zoom: $0) }
            }
        }
        self.steps = steps
        var pins = try container.decodeIfPresent([PinWindow].self, forKey: .pins) ?? []
        if pins.isEmpty,
           let x = try container.decodeIfPresent(Double.self, forKey: .pinX),
           let y = try container.decodeIfPresent(Double.self, forKey: .pinY) {
            pins = [PinWindow(
                x: x, y: y,
                from: try container.decodeIfPresent(Double.self, forKey: .pinFrom),
                until: try container.decodeIfPresent(Double.self, forKey: .pinUntil)
            )]
        }
        self.pins = pins
        zoomIn = try container.decodeIfPresent(Double.self, forKey: .zoomIn)
        zoomOut = try container.decodeIfPresent(Double.self, forKey: .zoomOut)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(steps, forKey: .steps)
        if !pins.isEmpty { try container.encode(pins, forKey: .pins) }
        try container.encodeIfPresent(zoomIn, forKey: .zoomIn)
        try container.encodeIfPresent(zoomOut, forKey: .zoomOut)
    }
}

/// How the re-drawn cursor looks in the preview and the export. Chosen per
/// recording and saved in plan.json; missing there is classic (older plans).
enum CursorStyle: String, Codable, CaseIterable, Identifiable {
    /// The macOS arrow, hand and I-beam, redrawn as flat vectors.
    case classic
    /// Classic shapes with a white face and a black bevel, drawn a little
    /// bigger.
    case bubbly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "Classic cursor"
        case .bubbly: return "Cute cursor"
        }
    }

    var detail: String {
        switch self {
        case .classic: return "The macOS pointer, redrawn sharp at any zoom"
        case .bubbly: return "White face with a black bevel"
        }
    }
}

/// The stretch of the recording the whole-video export keeps: seconds on
/// the master timeline, `end` nil meaning the end of the video. Footage
/// outside it is left out of that export (the clips are unaffected — they
/// name their own stretches).
struct Trim: Codable, Equatable {
    var start: Double = 0
    var end: Double? = nil

    /// The shortest stretch a trim may keep.
    static let minLength = 0.5

    /// Nothing trimmed.
    var isDefault: Bool { start <= 0 && end == nil }

    /// `start...end` resolved against the video's length.
    func range(duration: Double) -> ClosedRange<Double> {
        let from = min(max(start, 0), duration)
        let to = min(end ?? duration, duration)
        return from...max(from, to)
    }
}

/// A stretch of the recording that "Export clips" writes as a file of its
/// own: seconds on the master timeline. `end` nil is an open clip — it runs
/// to the next clip's start (or the end of the video) until the user ends
/// it. Clips are exported one by one; the whole-video export is untouched.
struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double? = nil

    /// The shortest clip.
    static let minLength = 0.5

    /// One clip as it exports: `start...end` resolved, numbered in time
    /// order ("clip 1", "clip 2", …).
    struct Range: Identifiable, Equatable {
        var id: UUID
        var number: Int
        var start: Double
        var end: Double
        var length: Double { end - start }
    }

    /// The clips in time order with every open end resolved to the next
    /// clip's start or the end of the video, cut short so they never
    /// overlap; a clip that resolves to nothing is skipped.
    static func ranges(of clips: [Clip], duration: Double) -> [Range] {
        let sorted = clips.sorted { $0.start < $1.start }
        var out: [Range] = []
        for (i, clip) in sorted.enumerated() {
            let start = min(max(clip.start, 0), duration)
            var end = min(clip.end ?? duration, duration)
            if i + 1 < sorted.count { end = min(end, sorted[i + 1].start) }
            guard end > start + 1e-6 else { continue }
            out.append(Range(id: clip.id, number: out.count + 1, start: start, end: end))
        }
        return out
    }
}

/// A stretch of the recording that exports fast-forwarded: seconds on the
/// master timeline, played `rate`× faster in every export (and approximated
/// in the preview). `end` nil is an open speed-up — it runs to the next
/// one's start (or the end of the video) until the user ends it.
struct SpeedWindow: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double? = nil
    /// Fast-forward factor (> 1); slow motion may extend this later.
    var rate: Double = SpeedWindow.defaultRate
    /// Draw the rate ("3×") in the video's bottom-right corner while this
    /// speed-up plays, in the preview and every export. Per speed-up: one
    /// can badge while the next stays silent.
    var badge = false

    init(
        id: UUID = UUID(), start: Double, end: Double? = nil,
        rate: Double = SpeedWindow.defaultRate, badge: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.rate = rate
        self.badge = badge
    }

    private enum CodingKeys: String, CodingKey { case id, start, end, rate, badge }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decodeIfPresent(Double.self, forKey: .end)
        rate = try container.decode(Double.self, forKey: .rate)
        badge = try container.decodeIfPresent(Bool.self, forKey: .badge) ?? false
    }

    /// `badge` is omitted at its default so an unbadged plan round-trips
    /// unchanged.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encode(rate, forKey: .rate)
        if badge { try container.encode(badge, forKey: .badge) }
    }

    /// The shortest speed-up.
    static let minLength = 0.5
    static let defaultRate = 2.0
    /// The rates the menus offer.
    static let rates: [Double] = [2, 3, 4, 8]

    /// One speed-up as it applies: `start...end` resolved.
    struct Range: Identifiable, Equatable {
        var id: UUID
        var start: Double
        var end: Double
        var rate: Double
        var badge: Bool
        var length: Double { end - start }
    }

    /// The speed-ups in time order with every open end resolved to the next
    /// one's start or the end of the video, cut short so they never overlap;
    /// one that resolves to nothing is skipped.
    static func ranges(of windows: [SpeedWindow], duration: Double) -> [Range] {
        let sorted = windows.sorted { $0.start < $1.start }
        var out: [Range] = []
        for (i, window) in sorted.enumerated() {
            let start = min(max(window.start, 0), duration)
            var end = min(window.end ?? duration, duration)
            if i + 1 < sorted.count { end = min(end, sorted[i + 1].start) }
            guard end > start + 1e-6 else { continue }
            out.append(Range(
                id: window.id, start: start, end: end, rate: max(1, window.rate), badge: window.badge
            ))
        }
        return out
    }

    /// How long a stretch of the master runs once the speed-ups inside it
    /// are applied: each sped stretch contributes `length / rate`.
    static func outputLength(of window: ClosedRange<Double>, ranges: [Range]) -> Double {
        var length = window.upperBound - window.lowerBound
        for range in ranges {
            let overlap = min(range.end, window.upperBound) - max(range.start, window.lowerBound)
            if overlap > 0 { length -= overlap * (1 - 1 / range.rate) }
        }
        return length
    }

    /// The master time on show `t` seconds into the sped-up rendering of
    /// `window` — piecewise linear: one output second covers `rate` master
    /// seconds inside a speed-up, one outside. `ranges` must be in time
    /// order and non-overlapping (see `ranges(of:duration:)`).
    static func sourceTime(atOutput t: Double, in window: ClosedRange<Double>, ranges: [Range]) -> Double {
        var remaining = t
        var source = window.lowerBound
        for range in ranges where range.end > window.lowerBound && range.start < window.upperBound {
            let start = max(range.start, window.lowerBound)
            let end = min(range.end, window.upperBound)
            let plain = start - source
            if remaining <= plain { return source + remaining }
            remaining -= plain
            let sped = (end - start) / range.rate
            if remaining <= sped { return start + remaining * range.rate }
            remaining -= sped
            source = end
        }
        return min(source + remaining, window.upperBound)
    }
}

/// Edited plan, saved as plan.json next to the master: the zooms, the
/// cursor style, the trim, the clips and the speed-ups. When present, the
/// exporter uses it instead of auto-generating from the click log. Older
/// plans carry only the zooms; the other keys are omitted when they are at
/// their defaults, so such a plan round-trips unchanged.
struct ZoomPlan: Codable {
    var version: Int = 1
    var segments: [ZoomSegment]
    var cursorStyle: CursorStyle = .classic
    var trim = Trim()
    var clips: [Clip] = []
    var speeds: [SpeedWindow] = []

    init(
        segments: [ZoomSegment], cursorStyle: CursorStyle = .classic, trim: Trim = Trim(),
        clips: [Clip] = [], speeds: [SpeedWindow] = []
    ) {
        self.segments = segments
        self.cursorStyle = cursorStyle
        self.trim = trim
        self.clips = clips
        self.speeds = speeds
    }

    private enum CodingKeys: String, CodingKey {
        case version, segments, cursorStyle, trim, clips, speeds
        /// Pre-0.2.1 plans badged every speed-up with one flag; read once
        /// and folded into each speed-up's `badge`.
        case speedBadge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        segments = try container.decode([ZoomSegment].self, forKey: .segments)
        cursorStyle = try container.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? .classic
        trim = try container.decodeIfPresent(Trim.self, forKey: .trim) ?? Trim()
        clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        speeds = try container.decodeIfPresent([SpeedWindow].self, forKey: .speeds) ?? []
        if try container.decodeIfPresent(Bool.self, forKey: .speedBadge) ?? false {
            for i in speeds.indices { speeds[i].badge = true }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(segments, forKey: .segments)
        if cursorStyle != .classic { try container.encode(cursorStyle, forKey: .cursorStyle) }
        if !trim.isDefault { try container.encode(trim, forKey: .trim) }
        if !clips.isEmpty { try container.encode(clips, forKey: .clips) }
        if !speeds.isEmpty { try container.encode(speeds, forKey: .speeds) }
    }

    /// The clips as they export (see `Clip.ranges`).
    func clipRanges(duration: Double) -> [Clip.Range] {
        Clip.ranges(of: clips, duration: duration)
    }
}

/// A recording on disk: a folder containing master.mov + events.json
/// (+ "<name>.mov" / "<name> 2.mp4" / "<name> clip 1.mov" / … after
/// exports, each with a .plan.json snapshot beside it).
struct Recording: Identifiable, Equatable {
    var id: URL { folder }
    var folder: URL

    var masterURL: URL { folder.appendingPathComponent("master.mov") }
    var eventsURL: URL { folder.appendingPathComponent("events.json") }
    var planURL: URL { folder.appendingPathComponent("plan.json") }

    func loadPlan() -> ZoomPlan? {
        Self.loadPlan(from: planURL)
    }

    static func loadPlan(from url: URL) -> ZoomPlan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ZoomPlan.self, from: data)
    }

    func loadPlanSegments() -> [ZoomSegment]? {
        loadPlan()?.segments
    }

    func savePlan(_ plan: ZoomPlan) {
        try? Self.writePlan(plan, to: planURL)
    }

    /// Throwing form for callers that must know the plan reached disk
    /// (the export snapshot gates "export succeeded" on it).
    static func writePlan(_ plan: ZoomPlan, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(plan).write(to: url, options: .atomic)
    }

    /// Sidecar written next to each export with the zoom plan that produced it
    /// ("export 2.mp4" → "export 2.plan.json"), so versions stay comparable
    /// and restorable after plan.json has moved on.
    static func planSnapshotURL(for exportURL: URL) -> URL {
        let stem = exportURL.deletingPathExtension().lastPathComponent
        return exportURL.deletingLastPathComponent().appendingPathComponent("\(stem).plan.json")
    }

    var name: String { folder.lastPathComponent }

    /// Which export a file in the folder is, read off its stem. Exports are
    /// named after the recording — "<name>", "<name> 2", "<name> clip 1",
    /// "<name> clip 1 (2)" — so the files match the sidebar after a rename
    /// (`renamed(to:)` moves them along with the folder). Stems from before
    /// that scheme ("export", "export 2", "clip 1") still count, so an old
    /// library keeps its exports until it is renamed.
    enum ExportKey: Equatable {
        case whole(index: Int)
        case clip(number: Int, run: Int)
    }

    /// The name-based stems come first so a recording called "clip 1" still
    /// tells its own whole-video export from a clip.
    func exportKey(of stem: String) -> ExportKey? {
        if let index = Self.exportIndex(of: stem, prefix: name) { return .whole(index: index) }
        if let key = Self.clipExportKey(of: stem, prefix: "\(name) clip ") { return .clip(number: key.number, run: key.run) }
        if let index = Self.exportIndex(of: stem, prefix: "export") { return .whole(index: index) }
        if let key = Self.clipExportKey(of: stem, prefix: "clip ") { return .clip(number: key.number, run: key.run) }
        return nil
    }

    /// The stem an export is written under today (no extension).
    func exportStem(for key: ExportKey) -> String {
        switch key {
        case .whole(let index):
            return index == 1 ? name : "\(name) \(index)"
        case .clip(let number, let run):
            return run == 1 ? "\(name) clip \(number)" : "\(name) clip \(number) (\(run))"
        }
    }

    /// Every export in the folder with what it is, in directory order.
    private var keyedExports: [(key: ExportKey, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            let url = URL(fileURLWithPath: name)
            guard ExportFormat.fileExtensions.contains(url.pathExtension.lowercased()),
                  let key = exportKey(of: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            return (key, folder.appendingPathComponent(name))
        }
    }

    /// Existing whole-video exports, oldest first ("<name>.mov",
    /// "<name> 2.mp4", …).
    var exportURLs: [URL] {
        keyedExports
            .compactMap { entry -> (Int, URL)? in
                guard case .whole(let index) = entry.key else { return nil }
                return (index, entry.url)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Existing clip exports, by clip number then by run ("<name> clip 1.mov",
    /// "<name> clip 1 (2).mov", "<name> clip 2.mov", …).
    var clipExportURLs: [URL] {
        keyedExports
            .compactMap { entry -> (Int, Int, URL)? in
                guard case .clip(let number, let run) = entry.key else { return nil }
                return (number, run, entry.url)
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }

    /// What the library sidebar shows under a recording's name: the container
    /// and size of the newest file (latest export, else the master), plus the
    /// zoom and step counts of the current plan.json.
    ///
    /// Computing one stats files and decodes plan.json — AppModel caches them
    /// per folder so view bodies never touch the disk.
    struct Summary: Equatable {
        var format: String
        var fileSize: Int64?
        var zoomCount: Int
        var stepCount: Int
        /// A whole-video or clip export exists.
        var hasExport: Bool
    }

    var summary: Summary {
        let exports = exportURLs
        let url = exports.last ?? masterURL
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        let segments = loadPlanSegments() ?? []
        return Summary(
            format: url.pathExtension.uppercased(),
            fileSize: size,
            zoomCount: segments.count,
            stepCount: segments.reduce(0) { $0 + $1.steps.count },
            hasExport: !exports.isEmpty || !clipExportURLs.isEmpty
        )
    }

    /// Next unused whole-video export filename: "<name>.<ext>", then
    /// "<name> 2.<ext>", "<name> 3.<ext>", … Numbering is shared across
    /// formats so re-exports never overwrite an earlier one, whatever
    /// container it used.
    func nextExportURL(for format: ExportFormat) -> URL {
        let used = Set(keyedExports.compactMap { entry -> Int? in
            guard case .whole(let index) = entry.key else { return nil }
            return index
        })
        var index = 1
        while used.contains(index) { index += 1 }
        return folder.appendingPathComponent(exportStem(for: .whole(index: index)))
            .appendingPathExtension(format.fileExtension)
    }

    /// Next unused filename for clip `number`: "<name> clip 1.<ext>", then
    /// "<name> clip 1 (2).<ext>", "<name> clip 1 (3).<ext>", … — a re-export
    /// never overwrites an earlier run, whatever container it used.
    func nextClipExportURL(number: Int, for format: ExportFormat) -> URL {
        let used = Set(keyedExports.compactMap { entry -> Int? in
            guard case .clip(number, let run) = entry.key else { return nil }
            return run
        })
        var run = 1
        while used.contains(run) { run += 1 }
        return folder.appendingPathComponent(exportStem(for: .clip(number: number, run: run)))
            .appendingPathExtension(format.fileExtension)
    }

    /// Moves the folder to `newName` beside it and renames every export (and
    /// its plan snapshot) inside to carry the new name, returning the moved
    /// recording. The folder move is the only step that can throw; a file
    /// that can't follow (its target already exists) keeps its old stem,
    /// which `exportKey(of:)` no longer recognises unless it is a legacy one.
    func renamed(to newName: String) throws -> Recording {
        let fm = FileManager.default
        let dest = Recording(folder: folder.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true))
        // Pair each file with its new stem before the move: after it, the
        // old stems no longer parse under the new name.
        let moves: [(from: String, to: String)] = keyedExports.flatMap { entry -> [(String, String)] in
            let stem = dest.exportStem(for: entry.key)
            let ext = entry.url.pathExtension
            let oldStem = entry.url.deletingPathExtension().lastPathComponent
            guard stem != oldStem else { return [] }
            var pairs = [(entry.url.lastPathComponent, "\(stem).\(ext)")]
            let snapshot = Self.planSnapshotURL(for: entry.url)
            if fm.fileExists(atPath: snapshot.path) {
                pairs.append((snapshot.lastPathComponent, "\(stem).plan.json"))
            }
            return pairs
        }
        try fm.moveItem(at: folder, to: dest.folder)
        for move in moves {
            let to = dest.folder.appendingPathComponent(move.to)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: dest.folder.appendingPathComponent(move.from), to: to)
        }
        return dest
    }

    /// "<prefix>" → 1, "<prefix> 2" → 2, anything else → nil.
    private static func exportIndex(of stem: String, prefix: String) -> Int? {
        if stem == prefix { return 1 }
        guard stem.hasPrefix(prefix + " "), let n = Int(stem.dropFirst(prefix.count + 1)), n >= 2 else {
            return nil
        }
        return n
    }

    /// "<prefix>3" → (3, 1), "<prefix>3 (2)" → (3, 2), anything else → nil.
    private static func clipExportKey(of stem: String, prefix: String) -> (number: Int, run: Int)? {
        guard stem.hasPrefix(prefix) else { return nil }
        let rest = stem.dropFirst(prefix.count)
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let first = parts.first, let number = Int(first), number >= 1 else { return nil }
        if parts.count == 1 { return (number, 1) }
        let tail = parts[1]
        guard tail.hasPrefix("("), tail.hasSuffix(")"),
              let run = Int(tail.dropFirst().dropLast()), run >= 2 else { return nil }
        return (number, run)
    }

    static func library() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Crisp", isDirectory: true)
    }

    static func newFolder() throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = library().appendingPathComponent(fmt.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadAll() -> [Recording] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: library(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.hasDirectoryPath && fm.fileExists(atPath: $0.appendingPathComponent("master.mov").path) }
            .map { Recording(folder: $0) }
            .sorted { $0.name > $1.name }
    }

    func loadMeta() throws -> RecordingMeta {
        let data = try Data(contentsOf: eventsURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMeta.self, from: data)
    }
}

/// "0:04" — a moment as m:ss, rounded to the second: how the editor's
/// toolbar, the AI panel's timestamp chips and the agent's briefing show it.
func shortTimecode(_ t: Double) -> String {
    let total = Int(max(0, t).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
