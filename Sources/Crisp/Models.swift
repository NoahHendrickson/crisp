import Foundation
import CoreGraphics

/// Codec used for the master (recording-time) file.
enum MasterCodec: String, CaseIterable, Identifiable, Codable {
    case hevc10 = "HEVC 10-bit"
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: String { rawValue }

    var fileExtension: String { "mov" }
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

/// A recording on disk: a folder containing master.mov + events.json (+ export.mov after export).
struct Recording: Identifiable, Equatable {
    var id: URL { folder }
    var folder: URL

    var masterURL: URL { folder.appendingPathComponent("master.mov") }
    var eventsURL: URL { folder.appendingPathComponent("events.json") }
    var exportURL: URL { folder.appendingPathComponent("export.mov") }
    var planURL: URL { folder.appendingPathComponent("plan.json") }

    func loadPlanSegments() -> [ZoomSegment]? {
        guard let data = try? Data(contentsOf: planURL),
              let plan = try? JSONDecoder().decode(ZoomPlan.self, from: data) else { return nil }
        return plan.segments
    }

    func savePlan(_ segments: [ZoomSegment]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(ZoomPlan(segments: segments)) {
            try? data.write(to: planURL)
        }
    }

    var name: String { folder.lastPathComponent }

    var hasExport: Bool {
        FileManager.default.fileExists(atPath: exportURL.path)
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
