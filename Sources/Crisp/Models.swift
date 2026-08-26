import Foundation
import CoreGraphics

/// Codec used for the master (recording-time) file.
enum MasterCodec: String, CaseIterable, Identifiable, Codable {
    case hevc10 = "HEVC 10-bit"
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: String { rawValue }

    var fileExtension: String { "mov" }

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
        case leftDown, leftUp, rightDown, scroll
    }

    var t: Double
    var kind: Kind
    /// Position in master-video pixel coordinates (top-left origin, y down).
    var x: Double
    var y: Double
}

/// Periodic cursor position sample, same coordinate space as MouseEvent.
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
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

/// A camera move within a zoom segment: at time `t` the camera glides from its
/// current center to (cx, cy) over `duration` seconds, staying zoomed.
struct PanMove: Codable, Identifiable, Equatable {
    var id = UUID()
    var t: Double
    var duration: Double = 0.5
    /// Target center in master-video pixels (top-left origin).
    var cx: Double
    var cy: Double
    /// Zoom level from this move on, for "zoom in further" steps inside a
    /// hold. nil keeps whatever level the camera already has.
    var zoom: Double? = nil
}

/// One zoom: the camera holds fully zoomed on (cx, cy) from `start` to `end`
/// (seconds, master-video timeline); eased transitions are added around it.
/// `pans` are re-centering moves that happen while zoomed.
struct ZoomSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var zoom: Double
    /// Initial center in master-video pixels (top-left origin).
    var cx: Double
    var cy: Double
    var pans: [PanMove] = []
}

/// Custom decoding so plan.json files written before pans existed still load.
extension ZoomSegment {
    private enum CodingKeys: String, CodingKey {
        case id, start, end, zoom, cx, cy, pans
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        zoom = try container.decode(Double.self, forKey: .zoom)
        cx = try container.decode(Double.self, forKey: .cx)
        cy = try container.decode(Double.self, forKey: .cy)
        pans = try container.decodeIfPresent([PanMove].self, forKey: .pans) ?? []
    }
}

/// Edited zoom plan, saved as plan.json next to the master. When present, the
/// exporter uses it instead of auto-generating from the click log.
struct ZoomPlan: Codable {
    var version: Int = 1
    var segments: [ZoomSegment]
}

/// A recording on disk: a folder containing master.mov + events.json
/// (+ export.mov / export 2.mp4 / … after exports).
struct Recording: Identifiable, Equatable {
    var id: URL { folder }
    var folder: URL

    var masterURL: URL { folder.appendingPathComponent("master.mov") }
    var eventsURL: URL { folder.appendingPathComponent("events.json") }
    var planURL: URL { folder.appendingPathComponent("plan.json") }

    func loadPlanSegments() -> [ZoomSegment]? {
        Self.loadPlanSegments(from: planURL)
    }

    static func loadPlanSegments(from url: URL) -> [ZoomSegment]? {
        guard let data = try? Data(contentsOf: url),
              let plan = try? JSONDecoder().decode(ZoomPlan.self, from: data) else { return nil }
        return plan.segments
    }

    func savePlan(_ segments: [ZoomSegment]) {
        Self.savePlan(segments, to: planURL)
    }

    static func savePlan(_ segments: [ZoomSegment], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(ZoomPlan(segments: segments)) {
            try? data.write(to: url)
        }
    }

    /// Sidecar written next to each export with the zoom plan that produced it
    /// ("export 2.mp4" → "export 2.plan.json"), so versions stay comparable
    /// and restorable after plan.json has moved on.
    static func planSnapshotURL(for exportURL: URL) -> URL {
        let stem = exportURL.deletingPathExtension().lastPathComponent
        return exportURL.deletingLastPathComponent().appendingPathComponent("\(stem).plan.json")
    }

    var name: String { folder.lastPathComponent }

    /// The master plus every export, for the expandable library row.
    var files: [RecordingFile] {
        [RecordingFile(url: masterURL, kind: .master)]
            + exportURLs.map { RecordingFile(url: $0, kind: .export(Self.exportIndex(of: $0.deletingPathExtension().lastPathComponent) ?? 1)) }
    }

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

    var hasExport: Bool { !exportURLs.isEmpty }

    /// What the library sidebar shows under a recording's name: the container
    /// and size of the newest file (latest export, else the master), plus the
    /// zoom and pan counts of the current plan.json.
    struct Summary: Equatable {
        var format: String
        var fileSize: Int64?
        var zoomCount: Int
        var panCount: Int
    }

    var summary: Summary {
        let url = exportURLs.last ?? masterURL
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        let segments = loadPlanSegments() ?? []
        return Summary(
            format: url.pathExtension.uppercased(),
            fileSize: size,
            zoomCount: segments.count,
            panCount: segments.reduce(0) { $0 + $1.pans.count }
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

/// One video inside a recording folder: the original master or a numbered export.
struct RecordingFile: Identifiable, Equatable {
    enum Kind: Equatable {
        case master
        case export(Int)
    }

    var id: URL { url }
    let url: URL
    let kind: Kind

    var isMaster: Bool { kind == .master }

    /// "Original", "Export", "Export 2", …
    var title: String {
        switch kind {
        case .master: return "Original"
        case .export(let n): return n == 1 ? "Export" : "Export \(n)"
        }
    }

    /// "MOV" / "MP4"
    var format: String { url.pathExtension.uppercased() }

    var planSnapshotURL: URL? {
        isMaster ? nil : Recording.planSnapshotURL(for: url)
    }

    /// Number of zooms in this export's plan snapshot; nil for the master or
    /// exports made before snapshots existed.
    var zoomCount: Int? {
        guard let planSnapshotURL else { return nil }
        return Recording.loadPlanSegments(from: planSnapshotURL)?.count
    }

    var fileSize: Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    var modifiedAt: Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
