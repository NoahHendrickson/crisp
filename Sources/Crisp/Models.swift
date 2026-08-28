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
    /// Chunky rounded shapes with a glossy body and soft shadow, drawn a
    /// little bigger.
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
        case .bubbly: return "Rounded, glossy and a little bigger"
        }
    }
}

/// Edited zoom plan, saved as plan.json next to the master. When present, the
/// exporter uses it instead of auto-generating from the click log.
struct ZoomPlan: Codable {
    var version: Int = 1
    var segments: [ZoomSegment]
    /// nil = classic. Omitted from JSON so older plans round-trip unchanged.
    var cursorStyle: CursorStyle? = nil
}

/// A recording on disk: a folder containing master.mov + events.json
/// (+ export.mov / export 2.mp4 / … after exports).
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

    func savePlan(_ segments: [ZoomSegment], cursorStyle: CursorStyle) {
        try? Self.writePlan(segments, cursorStyle: cursorStyle, to: planURL)
    }

    /// Throwing form for callers that must know the plan reached disk
    /// (the export snapshot gates "export succeeded" on it).
    static func writePlan(_ segments: [ZoomSegment], cursorStyle: CursorStyle, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plan = ZoomPlan(segments: segments, cursorStyle: cursorStyle == .classic ? nil : cursorStyle)
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

    /// Existing exports, oldest first ("export.mov", "export 2.mp4", …).
    var exportURLs: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .compactMap { name -> (Int, String)? in
                let url = URL(fileURLWithPath: name)
                guard ExportFormat.fileExtensions.contains(url.pathExtension.lowercased()),
                      let index = Self.exportIndex(of: url.deletingPathExtension().lastPathComponent)
                else { return nil }
                return (index, name)
            }
            .sorted { $0.0 < $1.0 }
            .map { folder.appendingPathComponent($0.1) }
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
            hasExport: !exports.isEmpty
        )
    }

    /// Next unused export filename: "export.<ext>", then "export 2.<ext>",
    /// "export 3.<ext>", … Numbering is shared across formats so re-exports
    /// never overwrite an earlier one, whatever container it used.
    func nextExportURL(for format: ExportFormat) -> URL {
        let used = Set(exportURLs.compactMap {
            Self.exportIndex(of: $0.deletingPathExtension().lastPathComponent)
        })
        var index = 1
        while used.contains(index) { index += 1 }
        let stem = index == 1 ? "export" : "export \(index)"
        return folder.appendingPathComponent(stem).appendingPathExtension(format.fileExtension)
    }

    /// "export" → 1, "export 2" → 2, anything else → nil.
    private static func exportIndex(of stem: String) -> Int? {
        if stem == "export" { return 1 }
        guard stem.hasPrefix("export "), let n = Int(stem.dropFirst("export ".count)), n >= 2 else {
            return nil
        }
        return n
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
