import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// "AI Polish": hand the current zoom plan + click log + real frames from the
/// video to a locally-installed, subscription-authenticated agent CLI
/// (Claude Code or Codex) and get back a touched-up plan — better timing,
/// fewer redundant zooms/pans, centers framed on actual UI elements.
///
/// No API keys, no OAuth: the CLIs bring the user's existing sign-in.
struct AIProvider: Identifiable, Equatable, Hashable {
    enum Kind: String, CaseIterable {
        case claude = "Claude"
        case codex = "Codex"
    }

    let kind: Kind
    let path: String
    var id: String { kind.rawValue }
}

enum AIDirector {

    // MARK: - Provider detection

    /// Find agent CLIs via a login shell (GUI apps don't inherit shell PATH).
    static func detectProviders() async -> [AIProvider] {
        var found: [AIProvider] = []
        for (kind, binary) in [(AIProvider.Kind.claude, "claude"), (.codex, "codex")] {
            if let out = try? await runShell("which \(binary)", cwd: nil, timeout: 10),
               case let path = out.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, path.hasPrefix("/") {
                found.append(AIProvider(kind: kind, path: path))
            }
        }
        return found
    }

    // MARK: - Polish

    static func polish(
        recording: Recording,
        meta: RecordingMeta,
        duration: Double,
        segments: [ZoomSegment],
        note: String,
        provider: AIProvider
    ) async throws -> [ZoomSegment] {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("crisp-ai-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let frames = try await extractFrames(
            masterURL: recording.masterURL, segments: segments, duration: duration, into: workspace
        )
        let context = try buildContext(meta: meta, duration: duration, segments: segments, frames: frames)
        let contextURL = workspace.appendingPathComponent("context.json")
        try context.write(to: contextURL)

        let prompt = buildPrompt(note: note, frames: frames, workspace: workspace)
        let promptURL = workspace.appendingPathComponent("prompt.txt")
        try Data(prompt.utf8).write(to: promptURL)

        let output: String
        switch provider.kind {
        case .claude:
            output = try await runShell(
                "\"\(provider.path)\" -p --output-format text < prompt.txt",
                cwd: workspace, timeout: 240
            )
        case .codex:
            let images = frames.map { "-i \"\($0.file)\"" }.joined(separator: " ")
            output = try await runShell(
                "\"\(provider.path)\" exec --skip-git-repo-check \(images) -o last_message.txt - < prompt.txt >/dev/null 2>&1; cat last_message.txt",
                cwd: workspace, timeout: 240
            )
        }

        let dto = try parsePlan(from: output)
        let cleaned = validate(dto, duration: duration, meta: meta)
        guard !cleaned.isEmpty || dto.segments.isEmpty else {
            throw DirectorError.emptyPlan
        }
        AppModel.log("AI polish (\(provider.kind.rawValue)): \(segments.count) → \(cleaned.count) segments")
        return cleaned
    }

    // MARK: - Context assembly

    private struct Frame {
        var file: String
        var t: Double
        var label: String
    }

    /// A wide establishing frame plus one frame at each zoom's opening moment
    /// (or at click times if there are no segments yet), capped at 8.
    private static func extractFrames(
        masterURL: URL, segments: [ZoomSegment], duration: Double, into workspace: URL
    ) async throws -> [Frame] {
        let asset = AVURLAsset(url: masterURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        var wanted: [(Double, String)] = [(min(0.5, duration / 2), "wide establishing shot")]
        for seg in segments.prefix(7) {
            wanted.append((min(seg.start + 0.1, duration - 0.05), "at zoom starting \(String(format: "%.2f", seg.start))s"))
        }

        var frames: [Frame] = []
        for (index, (t, label)) in wanted.enumerated() {
            let time = CMTime(seconds: max(0, t), preferredTimescale: 600)
            guard let cg = try? await generator.image(at: time).image else { continue }
            let name = "frame_\(index).jpg"
            let url = workspace.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            CGImageDestinationFinalize(dest)
            frames.append(Frame(file: name, t: t, label: label))
        }
        return frames
    }

    private static func buildContext(
        meta: RecordingMeta, duration: Double, segments: [ZoomSegment], frames: [Frame]
    ) throws -> Data {
        var clicks: [[String: Double]] = []
        for event in meta.events where event.kind == .leftDown || event.kind == .rightDown {
            clicks.append(["t": round2(event.t), "x": round2(event.x), "y": round2(event.y)])
        }
        let plan: [[String: Any]] = segments.map { seg in
            [
                "start": round2(seg.start), "end": round2(seg.end), "zoom": round2(seg.zoom),
                "cx": round2(seg.cx), "cy": round2(seg.cy),
                "pans": seg.pans.map { [
                    "t": round2($0.t), "duration": round2($0.duration),
                    "cx": round2($0.cx), "cy": round2($0.cy),
                ] },
            ]
        }
        let context: [String: Any] = [
            "video": ["durationSeconds": round2(duration), "pixelWidth": meta.pixelWidth, "pixelHeight": meta.pixelHeight],
            "clicks": clicks,
            "currentPlan": ["segments": plan],
            "frames": frames.map { ["file": $0.file, "atSeconds": round2($0.t), "label": $0.label] },
        ]
        return try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    private static func buildPrompt(note: String, frames: [Frame], workspace: URL) -> String {
        let frameList = frames
            .map { "- \(workspace.appendingPathComponent($0.file).path) — \($0.label)" }
            .joined(separator: "\n")
        let userNote = note.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : "\nDirector's note from the user (follow it): \(note)\n"
        return """
        You are a motion director polishing the automatic zoom plan of a screen recording. \
        The automatic plan is decent but unpolished: zooms can start a beat late or early, \
        there can be too many zooms or too many pans, and centers don't always frame the \
        UI element being clicked. Your job is editorial touch-up, not re-authoring.

        Read \(workspace.appendingPathComponent("context.json").path) for the video info, \
        every click (t = seconds, x/y = pixels, top-left origin), and the current plan. \
        Look at these frames from the actual video to understand what was on screen:
        \(frameList)

        Semantics: a segment is the fully-zoomed hold window [start, end] in seconds; the \
        camera automatically begins moving ~0.7s before `start` and arrives just before it, \
        and eases back out ~0.7s after `end`. So `start` should be at (or a hair before) the \
        first click of the action it covers. A pan glides the zoomed camera to a new center \
        (cx, cy) at time `t` over `duration` seconds, and must lie within its segment.

        Polish goals, in priority order:
        1. Timing: each zoom's hold should open on the click it serves — never noticeably late.
        2. Fewer, better zooms: merge segments covering one continuous action; drop zooms on \
        trivial or isolated clicks that don't deserve emphasis.
        3. Fewer pans: only pan when the action genuinely leaves the framed area; drop jittery \
        re-centers.
        4. Framing: adjust cx/cy so the zoomed view frames the UI element being interacted \
        with (use the frames), not just the raw click point. Keep zoom levels between 1.5 \
        and 2.2 unless a tiny UI element justifies more.
        5. Calm pacing: leave breathing room at full frame between zoom bursts.
        \(userNote)
        Output ONLY a JSON object, no prose and no markdown fences, exactly this shape:
        {"segments":[{"start":0.0,"end":0.0,"zoom":1.8,"cx":0.0,"cy":0.0,"pans":[{"t":0.0,"duration":0.5,"cx":0.0,"cy":0.0}]}]}
        All times in seconds within the video duration; cx/cy in pixels within the video size. \
        Segments sorted and non-overlapping. `pans` may be an empty array.
        """
    }

    // MARK: - Parse & validate

    private struct PlanDTO: Decodable {
        var segments: [SegDTO]
        struct SegDTO: Decodable {
            var start: Double
            var end: Double
            var zoom: Double?
            var cx: Double
            var cy: Double
            var pans: [PanDTO]?
        }
        struct PanDTO: Decodable {
            var t: Double
            var duration: Double?
            var cx: Double
            var cy: Double
        }
    }

    private static func parsePlan(from output: String) throws -> PlanDTO {
        var candidates: [String] = []
        // Fenced block, if the model ignored "no fences".
        if let fenceRange = output.range(of: "```") {
            let afterFence = output[fenceRange.upperBound...]
            if let close = afterFence.range(of: "```") {
                var block = String(afterFence[..<close.lowerBound])
                if block.hasPrefix("json") { block = String(block.dropFirst(4)) }
                candidates.append(block)
            }
        }
        if let first = output.firstIndex(of: "{"), let last = output.lastIndex(of: "}") {
            candidates.append(String(output[first...last]))
        }
        let decoder = JSONDecoder()
        for candidate in candidates {
            if let dto = try? decoder.decode(PlanDTO.self, from: Data(candidate.utf8)) {
                return dto
            }
        }
        AppModel.log("AI polish: unparseable output: \(output.prefix(400))")
        throw DirectorError.unparseableOutput
    }

    /// Clamp everything into legal ranges; drop degenerate segments; enforce order.
    private static func validate(_ dto: PlanDTO, duration: Double, meta: RecordingMeta) -> [ZoomSegment] {
        let w = Double(meta.pixelWidth)
        let h = Double(meta.pixelHeight)
        var result: [ZoomSegment] = []

        for seg in dto.segments.sorted(by: { $0.start < $1.start }) {
            var start = min(max(0, seg.start), duration)
            let end = min(max(0, seg.end), duration)
            if let previous = result.last, start < previous.end + 0.2 {
                start = previous.end + 0.2
            }
            guard end - start >= 0.3 else { continue }

            let zoom = min(max(seg.zoom ?? 1.8, 1.2), 3.0)
            var pans: [PanMove] = []
            for pan in (seg.pans ?? []).sorted(by: { $0.t < $1.t }) {
                let t = min(max(pan.t, start), end - 0.15)
                guard t > start else { continue }
                pans.append(PanMove(
                    t: t,
                    duration: min(max(pan.duration ?? 0.5, 0.15), 1.5),
                    cx: min(max(pan.cx, 0), w),
                    cy: min(max(pan.cy, 0), h)
                ))
            }
            result.append(ZoomSegment(
                start: start, end: end, zoom: zoom,
                cx: min(max(seg.cx, 0), w),
                cy: min(max(seg.cy, 0), h),
                pans: pans
            ))
        }
        return result
    }

    // MARK: - Shell

    /// Run a command through a login shell (for PATH), collecting stdout
    /// incrementally so large outputs can't deadlock the pipe.
    private static func runShell(_ command: String, cwd: URL?, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            if let cwd { process.currentDirectoryURL = cwd }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            var outData = Data()
            var errData = Data()
            let dataQueue = DispatchQueue(label: "crisp.ai.pipe")
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                dataQueue.sync { outData.append(chunk) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                dataQueue.sync { errData.append(chunk) }
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            process.terminationHandler = { proc in
                timeoutWork.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                dataQueue.sync {
                    outData.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
                }
                let out = String(data: outData, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 && out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: DirectorError.cliFailed(String(err.suffix(300))))
                } else {
                    continuation.resume(returning: out)
                }
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    enum DirectorError: LocalizedError {
        case cliFailed(String)
        case unparseableOutput
        case emptyPlan

        var errorDescription: String? {
            switch self {
            case .cliFailed(let detail):
                return "The AI tool failed: \(detail)"
            case .unparseableOutput:
                return "The AI didn't return a valid plan (see ~/Library/Logs/Crisp.log)."
            case .emptyPlan:
                return "The AI returned an empty plan — kept your current zooms."
            }
        }
    }
}
