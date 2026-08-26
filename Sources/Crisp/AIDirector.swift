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
    /// Models the CLI can be pointed at with `--model`; `nil` in the UI means
    /// "whatever the CLI is configured to use".
    var models: [AIModel] = []
    /// What the CLI would use with no flags, read from its own config;
    /// pre-selected in the UI.
    var defaultModel: AIModel?
    var defaultEffort: String?
    var id: String { kind.rawValue }
}

/// A model choice for one provider. `id` is what's passed to the CLI.
struct AIModel: Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    /// Reasoning-effort levels this model accepts, lowest first.
    var efforts: [String] = AIModel.standardEfforts
    /// Effort the CLI picks for this model when none is configured.
    var defaultEffort: String = "high"

    /// Claude's `--effort` levels; also the fallback for Codex models whose
    /// catalogue entry doesn't list any.
    static let standardEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// Claude Code accepts aliases that always resolve to the latest release.
    static let claude: [AIModel] = [
        AIModel(id: "fable", label: "Fable 5"),
        AIModel(id: "opus", label: "Opus 5"),
        AIModel(id: "sonnet", label: "Sonnet 5"),
        AIModel(id: "haiku", label: "Haiku 4.5"),
    ]

    /// Fallback when Codex's local model catalogue can't be read.
    static let codexFallback: [AIModel] = [
        AIModel(id: "gpt-5.6-sol", label: "GPT-5.6-Sol", defaultEffort: "medium"),
        AIModel(id: "gpt-5.5", label: "GPT-5.5", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
        AIModel(id: "gpt-5.4", label: "GPT-5.4", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
        AIModel(id: "gpt-5.4-mini", label: "GPT-5.4-Mini", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
    ]

    /// Codex keeps the model catalogue it last fetched in ~/.codex/models_cache.json.
    static func codex() -> [AIModel] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["models"] as? [[String: Any]] else { return codexFallback }
        let listed = entries
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { entry -> AIModel? in
                guard let slug = entry["slug"] as? String, !slug.isEmpty else { return nil }
                let levels = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                    .compactMap { $0["effort"] as? String }
                let efforts = levels.isEmpty ? standardEfforts : levels
                let defaultLevel = entry["default_reasoning_level"] as? String
                return AIModel(
                    id: slug, label: entry["display_name"] as? String ?? slug,
                    efforts: efforts,
                    defaultEffort: defaultLevel.flatMap { efforts.contains($0) ? $0 : nil } ?? "medium"
                )
            }
        return listed.isEmpty ? codexFallback : listed
    }

    // MARK: CLI defaults

    /// `model` / `effortLevel` from ~/.claude/settings.json. A full model id
    /// ("claude-fable-5") is matched to its alias ("fable").
    static func claudeDefaults(models: [AIModel]) -> (AIModel?, String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        var model: AIModel?
        if let configured = (obj["model"] as? String)?.lowercased() {
            model = models.first { configured == $0.id || configured.contains($0.id) }
        }
        let effort = (obj["effortLevel"] as? String ?? obj["effort"] as? String)?.lowercased()
        return (model, effort)
    }

    /// `model` / `model_reasoning_effort` from ~/.codex/config.toml.
    static func codexDefaults(models: [AIModel]) -> (AIModel?, String?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }   // top-level keys only
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        let model = values["model"].flatMap { id in models.first { $0.id == id } }
        return (model, values["model_reasoning_effort"]?.lowercased())
    }
}

/// One streamed item from an agent turn.
enum AIEvent {
    /// A complete assistant message block (markdown-ish prose).
    case text(String)
    /// A tool step the agent took, e.g. `.activity(.viewed, "frame_2.jpg")`.
    case activity(ActivityKind, String)

    enum ActivityKind {
        case viewed, wrote, ran, other
        /// The previous provider session was unusable; a fresh one was started.
        case sessionRestarted
    }
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
                let models = kind == .claude ? AIModel.claude : AIModel.codex()
                let (configuredModel, configuredEffort) = kind == .claude
                    ? AIModel.claudeDefaults(models: models)
                    : AIModel.codexDefaults(models: models)
                let model = configuredModel ?? models.first
                let effort = configuredEffort.flatMap { level in
                    (model?.efforts ?? AIModel.standardEfforts).contains(level) ? level : nil
                } ?? model?.defaultEffort
                found.append(AIProvider(
                    kind: kind, path: path, models: models, defaultModel: model, defaultEffort: effort
                ))
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
        /// CLI model id (`--model`); nil leaves the CLI's own default in place.
        let model: String?
        /// Reasoning effort (`claude --effort`, codex `model_reasoning_effort`);
        /// nil leaves the CLI's own default in place.
        let effort: String?
        let recording: Recording
        let meta: RecordingMeta
        let duration: Double

        private let workspace: URL
        private var frames: [Frame] = []
        /// Claude: a UUID we choose up front (`--session-id`). Codex: the
        /// thread id reported by its first `thread.started` event. Cleared
        /// whenever a turn fails before the conversation is established so a
        /// possibly-taken id is never reused.
        private var sessionID: String?
        /// True once a turn has completed successfully; later turns resume.
        private(set) var started = false

        init(
            provider: AIProvider, model: String? = nil, effort: String? = nil,
            recording: Recording, meta: RecordingMeta, duration: Double
        ) throws {
            self.provider = provider
            self.model = model
            self.effort = effort
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
            // Frames follow the current plan (one per zoom opening), so refresh
            // them every turn along with context.json — the user may have
            // hand-edited, or the agent may have rewritten the plan last turn.
            frames = try await AIDirector.extractFrames(
                masterURL: recording.masterURL, segments: segments, duration: duration, into: workspace
            )
            let context = try AIDirector.buildContext(meta: meta, duration: duration, segments: segments, frames: frames)
            try context.write(to: workspace.appendingPathComponent("context.json"))
            // Seed plan.json with the current plan so "nothing to change" is a
            // valid outcome: the agent overwrites it, or leaves it as is.
            let planURL = workspace.appendingPathComponent("plan.json")
            try AIDirector.encodePlan(segments).write(to: planURL)

            var retriedFresh = false
            while true {
                let resuming = started
                let prompt = resuming
                    ? AIDirector.followUpPrompt(note: note)
                    : AIDirector.firstPrompt(note: note, frames: frames, workspace: workspace)
                try Data(prompt.utf8).write(to: workspace.appendingPathComponent("prompt.txt"))

                var sawEvent = false
                var errorMessage: String?
                var failure: Error?
                do {
                    try await AIDirector.runShell(makeCommand(resume: resuming), cwd: workspace, timeout: 300) { line in
                        guard let event = self.parseLine(line, error: &errorMessage) else { return }
                        sawEvent = true
                        onEvent(event)
                    }
                } catch {
                    failure = error
                }
                if Task.isCancelled { throw CancellationError() }
                if failure == nil, let errorMessage {
                    failure = DirectorError.cliFailed(errorMessage)
                }
                guard let failure else { break }

                // A stale provider session (e.g. cleared CLI history) fails —
                // via exit status or an error envelope — before emitting any
                // event. Fall back once to a fresh conversation.
                if resuming && !sawEvent && !retriedFresh && !(failure is CancellationError) {
                    AppModel.log("AI polish: resume failed, starting a fresh session: \(failure.localizedDescription)")
                    retriedFresh = true
                    started = false
                    sessionID = nil
                    onEvent(.activity(.sessionRestarted, ""))
                    continue
                }
                if !started { sessionID = nil }
                throw failure
            }
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
            let tag = [provider.kind.rawValue, model, effort].compactMap { $0 }.joined(separator: " / ")
            AppModel.log("AI polish (\(tag)): \(segments.count) → \(cleaned.count) segments")
            return cleaned
        }

        // MARK: Commands

        private func makeCommand(resume: Bool) -> String {
            let bin = "\"\(provider.path)\""
            // Both CLIs take model/effort per invocation, so they're repeated on resume.
            let modelFlag = model.map { " --model \"\($0)\"" } ?? ""
            switch provider.kind {
            case .claude:
                let id = sessionID ?? UUID().uuidString.lowercased()
                sessionID = id
                let session = resume ? "--resume \(id)" : "--session-id \(id)"
                let effortFlag = effort.map { " --effort \($0)" } ?? ""
                // acceptEdits: file writes inside the workspace cwd are auto-approved.
                return "\(bin) -p \(session)\(modelFlag)\(effortFlag) --output-format stream-json --verbose --permission-mode acceptEdits < prompt.txt"
            case .codex:
                let images = frames.map { "-i \"\($0.file)\"" }.joined(separator: " ")
                let effortFlag = effort.map { " -c model_reasoning_effort=\\\"\($0)\\\"" } ?? ""
                let common = "--json --skip-git-repo-check -c sandbox_mode=\\\"workspace-write\\\"" + modelFlag + effortFlag
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
                    var activity: AIEvent?
                    for block in content {
                        if block["type"] as? String == "text", let text = block["text"] as? String {
                            texts.append(text)
                        } else if activity == nil, block["type"] as? String == "tool_use",
                                  let name = block["name"] as? String {
                            let input = block["input"] as? [String: Any] ?? [:]
                            let path = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
                            switch name {
                            case "Read": activity = .activity(.viewed, path ?? "file")
                            case "Write", "Edit": activity = .activity(.wrote, path ?? "file")
                            case "Bash": activity = .activity(.ran, AIDirector.firstLine(of: input["command"] as? String ?? "command"))
                            default: activity = .activity(.other, name)
                            }
                        }
                    }
                    // A block list is either text or tool uses in practice.
                    if !texts.isEmpty { return .text(texts.joined(separator: "\n")) }
                    return activity
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
                        return .activity(.wrote, names.joined(separator: ", "))
                    case "command_execution":
                        var cmd = item["command"] as? String ?? "command"
                        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc "] where cmd.hasPrefix(prefix) {
                            cmd = String(cmd.dropFirst(prefix.count))
                        }
                        return .activity(.ran, AIDirector.firstLine(of: cmd.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
                    case "reasoning", "user_message":
                        return nil
                    default:
                        return .activity(.other, itemType.replacingOccurrences(of: "_", with: " "))
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

    private static func firstLine(of command: String) -> String {
        guard let line = command.split(separator: "\n", maxSplits: 1).first else { return command }
        return line.count < command.count ? "\(line) …" : String(line)
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
        let plan = try JSONSerialization.jsonObject(with: encodePlan(segments))
        let context: [String: Any] = [
            "video": ["durationSeconds": round2(duration), "pixelWidth": meta.pixelWidth, "pixelHeight": meta.pixelHeight],
            "clicks": clicks,
            "currentPlan": plan,
            "frames": frames.map { ["file": $0.file, "atSeconds": round2($0.t), "label": $0.label] },
        ]
        return try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// The plan in the exact shape the agent is asked to write back.
    private static func encodePlan(_ segments: [ZoomSegment]) throws -> Data {
        let plan: [[String: Any]] = segments.map { seg in
            [
                "start": round2(seg.start), "end": round2(seg.end), "zoom": round2(seg.zoom),
                "cx": round2(seg.cx), "cy": round2(seg.cy),
                "pans": seg.pans.map { pan in
                    var dto: [String: Any] = [
                        "t": round2(pan.t), "duration": round2(pan.duration),
                        "cx": round2(pan.cx), "cy": round2(pan.cy),
                    ]
                    if let zoom = pan.zoom { dto["zoom"] = round2(zoom) }
                    return dto
                },
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["segments": plan], options: [.sortedKeys])
    }

    private static let planShape =
        #"{"segments":[{"start":0.0,"end":0.0,"zoom":1.8,"cx":0.0,"cy":0.0,"pans":[{"t":0.0,"duration":0.5,"cx":0.0,"cy":0.0,"zoom":2.2}]}]}"#

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
        (cx, cy) at time `t` over `duration` seconds, and must lie within its segment. A pan \
        may also carry its own `zoom` to tighten (or loosen) the camera as it glides — use \
        this to zoom in further on a small element mid-hold instead of zooming out and back \
        in; omit `zoom` to keep the current level.

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
        \(workspace.appendingPathComponent("plan.json").path) currently holds the current plan. \
        When you're done, overwrite it with your polished plan — a JSON object with exactly this shape:
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
        since your last reply), and the frame_*.jpg stills have been re-extracted at each of \
        its zoom openings. plan.json also holds the current plan. Apply the note by overwriting \
        plan.json in the same shape as before (leave it untouched only if the note is already \
        satisfied), and reply in 2–4 plain sentences describing what you changed.
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
            var zoom: Double?
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
                    cy: min(max(pan.cy, 0), h),
                    zoom: pan.zoom.map { min(max($0, 1.2), 3.0) }
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
    /// incrementally and, when `onLine` is given, delivered line by line as
    /// it arrives (and not retained); otherwise the full stdout is returned.
    ///
    /// Fails on any non-zero exit, on the timeout, and on task cancellation
    /// (the child is terminated in both cases). Completion waits for stdout
    /// EOF so the last lines are delivered, but only briefly after exit so a
    /// backgrounded grandchild holding the pipe can't hang us.
    private static func runShell(
        _ command: String, cwd: URL?, timeout: TimeInterval,
        onLine: ((String) -> Void)?
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        if let cwd { process.currentDirectoryURL = cwd }
        // If Crisp itself was launched from inside a Claude Code session, the
        // nested CLI would otherwise attach to that session (and has been seen
        // to take the parent down with SIGTERM). Give it a clean slate.
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key == "CLAUDECODE" || key == "CLAUDE_PID" || key.hasPrefix("CLAUDE_CODE_"))
        }

        let queue = DispatchQueue(label: "crisp.ai.pipe")
        var cancelled = false   // set from onCancel, read in finish(); both on `queue`

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                var outData = Data()           // only filled when onLine == nil
                var errData = Data()
                var lineBuffer = Data()
                var stdoutClosed = false
                var exited = false
                var timedOut = false
                var finished = false

                func finish() {
                    guard !finished else { return }
                    finished = true
                    if onLine != nil, !lineBuffer.isEmpty {
                        onLine?(String(decoding: lineBuffer, as: UTF8.self))
                    }
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    // Not Task.isCancelled: finish() runs on the pipe queue, outside the task.
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if timedOut {
                        continuation.resume(throwing: DirectorError.timedOut)
                    } else if process.terminationStatus != 0 {
                        let err = String(decoding: errData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: DirectorError.cliFailed(
                            err.isEmpty ? "exit status \(process.terminationStatus)" : String(err.suffix(300))
                        ))
                    } else {
                        continuation.resume(returning: String(decoding: outData, as: UTF8.self))
                    }
                }

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    queue.async {
                        if chunk.isEmpty {
                            // EOF: stop the handler (Foundation re-invokes it otherwise).
                            stdout.fileHandleForReading.readabilityHandler = nil
                            stdoutClosed = true
                            if exited { finish() }
                            return
                        }
                        guard let onLine else { outData.append(chunk); return }
                        var scanFrom = lineBuffer.endIndex
                        lineBuffer.append(chunk)
                        while let newline = lineBuffer[scanFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self)
                            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                            scanFrom = lineBuffer.startIndex
                            if !line.isEmpty { onLine(line) }
                        }
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    queue.async {
                        if chunk.isEmpty {
                            stderr.fileHandleForReading.readabilityHandler = nil
                        } else {
                            errData.append(chunk)
                        }
                    }
                }

                let timeoutWork = DispatchWorkItem {
                    queue.async { timedOut = true }
                    if process.isRunning { process.terminate() }
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

                process.terminationHandler = { _ in
                    timeoutWork.cancel()
                    queue.async {
                        exited = true
                        if stdoutClosed {
                            finish()
                        } else {
                            // Grace period for the pipe to drain before giving up on EOF.
                            queue.asyncAfter(deadline: .now() + 1.0) { finish() }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    timeoutWork.cancel()
                    queue.async {
                        guard !finished else { return }
                        finished = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            queue.async { cancelled = true }
            if process.isRunning { process.terminate() }
        }
    }

    enum DirectorError: LocalizedError {
        case cliFailed(String)
        case timedOut
        case unparseableOutput
        case noPlanWritten
        case emptyPlan

        var errorDescription: String? {
            switch self {
            case .cliFailed(let detail):
                return "The AI tool failed: \(detail)"
            case .timedOut:
                return "The AI tool took too long and was stopped — your zooms are unchanged."
            case .unparseableOutput:
                return "The AI wrote an invalid plan.json (see ~/Library/Logs/Crisp.log)."
            case .noPlanWritten:
                return "The AI removed the plan file — your zooms are unchanged."
            case .emptyPlan:
                return "The AI returned an empty plan — kept your current zooms."
            }
        }
    }
}
