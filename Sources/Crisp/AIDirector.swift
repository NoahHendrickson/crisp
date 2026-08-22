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

/// One streamed item from an agent turn.
enum AIEvent {
    /// A complete assistant message block (markdown-ish prose).
    case text(String)
    /// A one-line description of a tool step: "Viewed frame_2.jpg", "Wrote plan.json".
    case activity(String)
}

enum AIDirector {

    // MARK: - Provider detection

    /// Find agent CLIs via a login shell (GUI apps don't inherit shell PATH).
    static func detectProviders() async -> [AIProvider] {
        var found: [AIProvider] = []
        for (kind, binary) in [(AIProvider.Kind.claude, "claude"), (.codex, "codex")] {
            if let out = try? await runShell("which \(binary)", cwd: nil, timeout: 10, onLine: nil),
               case let path = out.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, path.hasPrefix("/") {
                found.append(AIProvider(kind: kind, path: path))
            }
        }
        return found
    }

    // MARK: - Session

    /// A multi-turn conversation with one agent CLI about one recording.
    ///
    /// Each turn spawns a fresh CLI process that resumes the same provider
    /// session (`claude -p --resume`, `codex exec resume`), so the model keeps
    /// its memory of the video and earlier notes without us holding a
    /// long-lived child process. The workspace (frames, context.json,
    /// plan.json) lives for the whole session.
    final class Session {
        let provider: AIProvider
        let recording: Recording
        let meta: RecordingMeta
        let duration: Double

        private let workspace: URL
        private var frames: [Frame] = []
        /// Claude: a UUID we choose up front (`--session-id`). Codex: the
        /// thread id reported by its first `thread.started` event.
        private var sessionID: String?
        private var started = false

        init(provider: AIProvider, recording: Recording, meta: RecordingMeta, duration: Double) throws {
            self.provider = provider
            self.recording = recording
            self.meta = meta
            self.duration = duration
            workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("crisp-ai-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: workspace)
        }

        /// Send one turn. `onEvent` is called on an arbitrary thread as the
        /// agent works; the returned plan is the validated contents of the
        /// plan.json the agent wrote.
        func send(
            note: String,
            segments: [ZoomSegment],
            onEvent: @escaping (AIEvent) -> Void
        ) async throws -> [ZoomSegment] {
            if frames.isEmpty {
                frames = try await AIDirector.extractFrames(
                    masterURL: recording.masterURL, segments: segments, duration: duration, into: workspace
                )
            }
            // Always refresh: the user may have hand-edited since the last turn.
            let context = try AIDirector.buildContext(meta: meta, duration: duration, segments: segments, frames: frames)
            try context.write(to: workspace.appendingPathComponent("context.json"))
            let planURL = workspace.appendingPathComponent("plan.json")
            try? FileManager.default.removeItem(at: planURL)

            let prompt = started
                ? AIDirector.followUpPrompt(note: note)
                : AIDirector.firstPrompt(note: note, frames: frames, workspace: workspace)
            try Data(prompt.utf8).write(to: workspace.appendingPathComponent("prompt.txt"))

            var sawEvent = false
            var errorMessage: String?
            let command = makeCommand(resume: started)
            do {
                _ = try await AIDirector.runShell(command, cwd: workspace, timeout: 300) { line in
                    guard let event = self.parseLine(line, error: &errorMessage) else { return }
                    sawEvent = true
                    onEvent(event)
                }
            } catch {
                // A stale provider session (e.g. cleared CLI history) fails
                // before emitting anything; fall back to a fresh conversation.
                if started && !sawEvent {
                    AppModel.log("AI polish: resume failed, starting a fresh session: \(error.localizedDescription)")
                    started = false
                    sessionID = nil
                    onEvent(.activity("Started a new session"))
                    return try await send(note: note, segments: segments, onEvent: onEvent)
                }
                throw error
            }
            if let errorMessage { throw DirectorError.cliFailed(errorMessage) }
            started = true

            guard let data = try? Data(contentsOf: planURL) else {
                throw DirectorError.noPlanWritten
            }
            let dto: PlanDTO
            do {
                dto = try JSONDecoder().decode(PlanDTO.self, from: data)
            } catch {
                AppModel.log("AI polish: bad plan.json: \(error)")
                throw DirectorError.unparseableOutput
            }
            let cleaned = AIDirector.validate(dto, duration: duration, meta: meta)
            guard !cleaned.isEmpty || dto.segments.isEmpty else { throw DirectorError.emptyPlan }
            AppModel.log("AI polish (\(provider.kind.rawValue)): \(segments.count) → \(cleaned.count) segments")
            return cleaned
        }

        // MARK: Commands

        private func makeCommand(resume: Bool) -> String {
            let bin = "\"\(provider.path)\""
            switch provider.kind {
            case .claude:
                if sessionID == nil { sessionID = UUID().uuidString.lowercased() }
                let session = resume ? "--resume \(sessionID!)" : "--session-id \(sessionID!)"
                // acceptEdits: file writes inside the workspace cwd are auto-approved.
                return "\(bin) -p \(session) --output-format stream-json --verbose --permission-mode acceptEdits < prompt.txt"
            case .codex:
                let images = frames.map { "-i \"\($0.file)\"" }.joined(separator: " ")
                let common = "--json --skip-git-repo-check -c sandbox_mode=\\\"workspace-write\\\""
                if resume, let sessionID {
                    return "\(bin) exec resume \(sessionID) \(common) \(images) - < prompt.txt"
                }
                return "\(bin) exec \(common) \(images) - < prompt.txt"
            }
        }

        // MARK: Event parsing

        /// Map one JSONL line from either CLI onto an `AIEvent`.
        /// Claude (`--output-format stream-json`): `assistant` events carry
        /// complete content blocks. Codex (`--json`): `item.completed` events.
        private func parseLine(_ line: String, error: inout String?) -> AIEvent? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return nil }

            switch provider.kind {
            case .claude:
                switch type {
                case "assistant":
                    guard let message = obj["message"] as? [String: Any],
                          let content = message["content"] as? [[String: Any]] else { return nil }
                    var texts: [String] = []
                    var activities: [String] = []
                    for block in content {
                        if block["type"] as? String == "text", let text = block["text"] as? String {
                            texts.append(text)
                        } else if block["type"] as? String == "tool_use",
                                  let name = block["name"] as? String {
                            let input = block["input"] as? [String: Any] ?? [:]
                            let path = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
                            switch name {
                            case "Read": activities.append("Viewed \(path ?? "file")")
                            case "Write", "Edit": activities.append("Wrote \(path ?? "file")")
                            case "Bash":
                                let cmd = input["command"] as? String ?? "command"
                                activities.append("Ran \(cmd.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? cmd)")
                            default: activities.append(name)
                            }
                        }
                    }
                    // A block list is either text or tool uses in practice.
                    if !texts.isEmpty { return .text(texts.joined(separator: "\n")) }
                    if !activities.isEmpty { return .activity(activities.joined(separator: ", ")) }
                    return nil
                case "result":
                    if obj["is_error"] as? Bool == true {
                        error = obj["result"] as? String ?? "Claude reported an error"
                    }
                    return nil
                default:
                    return nil
                }
            case .codex:
                switch type {
                case "thread.started":
                    sessionID = obj["thread_id"] as? String
                    return nil
                case "item.completed":
                    guard let item = obj["item"] as? [String: Any],
                          let itemType = item["type"] as? String else { return nil }
                    switch itemType {
                    case "agent_message":
                        return (item["text"] as? String).map { .text($0) }
                    case "file_change":
                        let names = (item["changes"] as? [[String: Any]] ?? [])
                            .compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
                        return .activity("Wrote \(names.joined(separator: ", "))")
                    case "command_execution":
                        var cmd = item["command"] as? String ?? "command"
                        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc "] where cmd.hasPrefix(prefix) {
                            cmd = String(cmd.dropFirst(prefix.count))
                        }
                        cmd = cmd.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        let firstLine = cmd.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? cmd
                        return .activity("Ran \(firstLine)\(firstLine.count < cmd.count ? " …" : "")")
                    case "reasoning":
                        return nil
                    default:
                        return .activity(itemType.replacingOccurrences(of: "_", with: " "))
                    }
                case "error":
                    error = obj["message"] as? String ?? "Codex reported an error"
                    return nil
                default:
                    return nil
                }
            }
        }
    }

    // MARK: - Context assembly

    fileprivate struct Frame {
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

    private static let planShape =
        #"{"segments":[{"start":0.0,"end":0.0,"zoom":1.8,"cx":0.0,"cy":0.0,"pans":[{"t":0.0,"duration":0.5,"cx":0.0,"cy":0.0}]}]}"#

    private static func firstPrompt(note: String, frames: [Frame], workspace: URL) -> String {
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
        When you're done, write the plan to \(workspace.appendingPathComponent("plan.json").path) \
        as a JSON object with exactly this shape:
        \(planShape)
        All times in seconds within the video duration; cx/cy in pixels within the video size. \
        Segments sorted and non-overlapping. `pans` may be an empty array.

        Then reply to the user in 2–4 plain sentences: what you changed and why. \
        Don't paste the JSON into your reply. The user may send follow-up notes later; \
        each time, apply them to the plan in context.json and rewrite plan.json.
        """
    }

    private static func followUpPrompt(note: String) -> String {
        """
        Director's note: \(note)

        The current plan is in context.json in this directory (it may have been hand-edited \
        since your last reply). Apply the note, write the updated plan to plan.json in the same \
        shape as before, and reply in 2–4 plain sentences describing what you changed.
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

    /// Run a command through a login shell (for PATH). stdout is consumed
    /// incrementally (so large outputs can't deadlock the pipe) and, when
    /// `onLine` is given, delivered line by line as it arrives.
    private static func runShell(
        _ command: String, cwd: URL?, timeout: TimeInterval,
        onLine: ((String) -> Void)?
    ) async throws -> String {
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
            var lineBuffer = Data()
            let dataQueue = DispatchQueue(label: "crisp.ai.pipe")

            func drainLines(final: Bool) {
                guard let onLine else { return }
                while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self)
                    lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                    if !line.isEmpty { onLine(line) }
                }
                if final, !lineBuffer.isEmpty {
                    onLine(String(decoding: lineBuffer, as: UTF8.self))
                    lineBuffer.removeAll()
                }
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                dataQueue.sync {
                    outData.append(chunk)
                    lineBuffer.append(chunk)
                    drainLines(final: false)
                }
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
                    let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                    outData.append(rest)
                    lineBuffer.append(rest)
                    drainLines(final: true)
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
        case noPlanWritten
        case emptyPlan

        var errorDescription: String? {
            switch self {
            case .cliFailed(let detail):
                return "The AI tool failed: \(detail)"
            case .unparseableOutput:
                return "The AI wrote an invalid plan.json (see ~/Library/Logs/Crisp.log)."
            case .noPlanWritten:
                return "The AI replied but didn't write a plan — your zooms are unchanged."
            case .emptyPlan:
                return "The AI returned an empty plan — kept your current zooms."
            }
        }
    }
}
