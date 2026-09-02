import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The AI editor: hand the current zoom plan + click log + annotated frames
/// from the video to a locally-installed, subscription-authenticated agent
/// CLI (Claude Code or Codex) — with a standing brief and `./crisp` tools to
/// see any moment, preview its own plan and validate it — and get back a
/// touched-up plan: better timing, fewer redundant zooms, the right levels.
///
/// No API keys, no OAuth: the CLIs bring the user's existing sign-in.
struct AIProvider: Identifiable, Equatable {
    enum Kind: String {
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
struct AIModel: Identifiable, Equatable {
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
        AIModel(id: "fable", label: "Fable 5.1"),
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

    /// What one turn produced: the validated plan, and anything the app had
    /// to change to make it legal. The agent is asked once to fix such
    /// issues itself; whatever remains is applied clamped and shown to the user.
    struct Outcome {
        var plan: [ZoomSegment]
        var adjustments: [String]
    }

    /// A multi-turn conversation with one agent CLI about one recording.
    ///
    /// Each turn spawns a fresh CLI process that resumes the same provider
    /// session (`claude -p --resume`, `codex exec resume`), so the model keeps
    /// its memory of the video and earlier notes without us holding a
    /// long-lived child process. The workspace — briefing, `./crisp` tools,
    /// frames, context.json, plan.json — lives for the whole session.
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
        private var frames: [AgentPlan.Frame] = []
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
            try AgentTools.installWorkspace(in: workspace, recording: recording)
        }

        deinit {
            try? FileManager.default.removeItem(at: workspace)
        }

        /// Send one turn. `onEvent` is called on an arbitrary thread as the
        /// agent works; the returned plan is the validated contents of the
        /// plan.json the agent wrote.
        func send(
            note: String,
            timestamp: Double? = nil,
            segments: [ZoomSegment],
            onEvent: @escaping (AIEvent) -> Void
        ) async throws -> Outcome {
            // Frames follow the current plan (one per zoom opening), so refresh
            // them every turn along with context.json — the user may have
            // hand-edited, or the agent may have rewritten the plan last turn.
            frames = try await AgentTools.extractFrames(
                recording: recording, meta: meta, segments: segments, duration: duration, into: workspace
            )
            let context = try AgentPlan.encodeContext(meta: meta, duration: duration, segments: segments, frames: frames)
            try context.write(to: workspace.appendingPathComponent("context.json"))
            // Seed plan.json with the current plan so "nothing to change" is a
            // valid outcome: the agent overwrites it, or leaves it as is.
            let planURL = workspace.appendingPathComponent("plan.json")
            try AgentPlan.encode(segments).write(to: planURL)

            // A note about a moment: hand over that exact frame, annotated,
            // with where the camera is there, so "this bit" is unambiguous.
            var moment: String?
            if let timestamp {
                let t = min(max(0, timestamp), duration)
                let name = String(format: "moment_t%05.2f.jpg", t)
                let planner = ZoomPlanner(meta: meta)
                let keys = planner.keyframes(from: segments, duration: duration)
                let camera = ZoomPlanner.evaluate(keys, at: t)
                if let image = try? await AgentTools.extractFrame(masterURL: recording.masterURL, at: t),
                   let annotated = AgentTools.annotate(
                       image, meta: meta, at: t, crop: segments.isEmpty ? nil : camera,
                       clicks: AgentTools.clicks(in: meta, near: t),
                       cursor: FrameComposer.cursorPosition(samples: meta.samples, at: t).map { ($0.x, $0.y) },
                       caption: AgentTools.caption(for: meta, at: t, extra: "the moment the note is about")
                   ) {
                    try? AgentTools.writeJPEG(annotated, to: workspace.appendingPathComponent(name))
                    frames.append(AgentPlan.Frame(file: name, t: t, label: "the moment the user's note is about"))
                }
                let covering = segments.enumerated().first { _, seg in
                    let span = planner.motionSpan(for: seg, duration: duration)
                    return t >= span.moveStart && t <= span.outEnd
                }
                let state = covering.map { index, seg in
                    String(format: "inside zoom %d (hold %.2f–%.2fs)%@", index + 1, seg.start, seg.end,
                           seg.pins.isEmpty ? "" : ", pinned")
                } ?? "at full frame, not inside any zoom"
                moment = String(
                    format: "The note is about the moment at %.2fs (%@). The camera there is %@, zoom %.2f× centred on (%.0f, %.0f). See %@ — an annotated still of exactly that frame.",
                    t, shortTimecode(t), state, camera.zoom, camera.center.x, camera.center.y,
                    workspace.appendingPathComponent(name).path
                )
            }

            // When a stale resume falls back to a fresh conversation, the new
            // session has seen nothing: it needs the full first prompt (with
            // the frame list), not the follow-up.
            let firstPrompt = AIDirector.firstPrompt(
                note: note, moment: moment, frames: frames, workspace: workspace
            )
            try await runTurn(
                prompt: started ? AIDirector.followUpPrompt(note: note, moment: moment) : firstPrompt,
                freshFallbackPrompt: firstPrompt,
                onEvent: onEvent
            )

            var (parsed, issues) = planState(planURL)
            if !issues.isEmpty {
                // Give the agent one shot at fixing its own plan; `./crisp
                // validate` prints exactly these checks, so it can iterate.
                AppModel.log("AI editor: plan needs fixes, asking the agent: \(issues.joined(separator: " | "))")
                onEvent(.activity(.other, "Fixing \(issues.count) rule issue\(issues.count == 1 ? "" : "s") in the plan"))
                // A fresh fallback here has no session history either: give it
                // the first-turn briefing with the fixup appended, not the
                // context-free fixup alone.
                try await runTurn(
                    prompt: AIDirector.fixupPrompt(issues: issues),
                    freshFallbackPrompt: firstPrompt + "\n\n" + AIDirector.fixupPrompt(issues: issues),
                    onEvent: onEvent
                )
                (parsed, issues) = planState(planURL)
            }
            guard let parsed else { throw DirectorError.unparseableOutput(issues.first ?? "unknown problem") }
            guard !parsed.segments.isEmpty || parsed.declared == 0 else { throw DirectorError.emptyPlan }
            let tag = [provider.kind.rawValue, model, effort].compactMap { $0 }.joined(separator: " / ")
            AppModel.log("AI editor (\(tag)): \(segments.count) → \(parsed.segments.count) segments; \(issues.count) adjustment(s)")
            return Outcome(plan: parsed.segments, adjustments: issues)
        }

        /// Run one CLI invocation, falling back once to a fresh conversation
        /// when resuming a stale provider session fails before it emits
        /// anything (e.g. cleared CLI history). A fresh session has no
        /// history, so it gets `freshFallbackPrompt` — the full first-turn
        /// briefing — instead of the follow-up `prompt`.
        private func runTurn(
            prompt: String, freshFallbackPrompt: String? = nil, onEvent: @escaping (AIEvent) -> Void
        ) async throws {
            var retriedFresh = false
            while true {
                let resuming = started
                let text = resuming ? prompt : (freshFallbackPrompt ?? prompt)
                try Data(text.utf8).write(to: workspace.appendingPathComponent("prompt.txt"))

                var sawEvent = false
                var errorMessage: String?
                var failure: Error?
                do {
                    try await AIDirector.runShell(makeCommand(resume: resuming), cwd: workspace, timeout: 900) { line in
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

                if resuming && !sawEvent && !retriedFresh && !(failure is CancellationError) {
                    AppModel.log("AI editor: resume failed, starting a fresh session: \(failure.localizedDescription)")
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
        }

        /// The plan file as it stands: parsed, with the rule adjustments it
        /// would need; or nil with the reason it can't be read at all.
        private func planState(_ url: URL) -> (AgentPlan.Parsed?, [String]) {
            guard let data = try? Data(contentsOf: url) else {
                return (nil, ["plan.json is missing — write the plan to plan.json in this directory"])
            }
            do {
                let parsed = try AgentPlan.parse(data, duration: duration, meta: meta)
                return (parsed, parsed.issues)
            } catch {
                AppModel.log("AI editor: bad plan.json: \(error.localizedDescription)")
                return (nil, ["plan.json could not be read: \(error.localizedDescription)"])
            }
        }

        // MARK: Commands

        /// The whole command runs through `zsh -l -c`, so every interpolated
        /// value is quoted as an inert single word (`shellQuoted` — double
        /// quotes would still expand `$(…)`; the Codex model slug comes from
        /// a network-fed cache and the resume id from the CLI's own output).
        /// `exec` replaces the shell with the CLI so terminate/kill signals
        /// reach the agent process itself, not a wrapper that would orphan it.
        private func makeCommand(resume: Bool) -> String {
            let q = AgentTools.shellQuoted
            let bin = q(provider.path)
            // Both CLIs take model/effort per invocation, so they're repeated on resume.
            let modelFlag = model.map { " --model \(q($0))" } ?? ""
            switch provider.kind {
            case .claude:
                let id = sessionID ?? UUID().uuidString.lowercased()
                sessionID = id
                let session = resume ? "--resume \(q(id))" : "--session-id \(q(id))"
                let effortFlag = effort.map { " --effort \(q($0))" } ?? ""
                // acceptEdits: file writes inside the workspace cwd are auto-approved;
                // the allow-list lets the agent run the ./crisp tools unprompted.
                return "exec \(bin) -p \(session)\(modelFlag)\(effortFlag) --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools \(q("Read,Write,Edit,Bash(./crisp:*)")) < prompt.txt"
            case .codex:
                let images = frames.map { "-i \(q($0.file))" }.joined(separator: " ")
                let effortFlag = effort.map { " -c \(q("model_reasoning_effort=\"\($0)\""))" } ?? ""
                let common = "--json --skip-git-repo-check -c \(q("sandbox_mode=\"workspace-write\""))" + modelFlag + effortFlag
                if resume, let sessionID {
                    return "exec \(bin) exec resume \(q(sessionID)) \(common) \(images) - < prompt.txt"
                }
                return "exec \(bin) exec \(common) \(images) - < prompt.txt"
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

    // MARK: - Prompts

    private static func firstPrompt(note: String, moment: String?, frames: [AgentPlan.Frame], workspace: URL) -> String {
        let frameList = frames
            .map { "- \(workspace.appendingPathComponent($0.file).path) — \($0.label)" }
            .joined(separator: "\n")
        var userNote = note.trimmingCharacters(in: .whitespaces).isEmpty
            ? "There is no note from the user this time: apply the default brief."
            : "Director's note from the user — follow it, it outranks the default brief:\n\(note)"
        if let moment { userNote += "\n\n\(moment)" }
        return """
        Polish the camera plan for this screen recording. Your full brief is AGENTS.md / \
        CLAUDE.md in this directory (\(workspace.path)) — read it first if it hasn't been \
        loaded for you. In short: context.json holds the video info, clicks, cursor path and \
        the current plan; the annotated stills below show what was on screen; ./crisp gives \
        you more frames, previews of your plan through the real camera, and a validator.

        Frames (video pixels on the grid; green box = what the current plan shows):
        \(frameList)

        \(userNote)

        Overwrite plan.json with your polished plan, run ./crisp validate until it prints OK, \
        preview the moments you changed with ./crisp preview and adjust any level that shows \
        too little or too much, then reply in 2–4 plain sentences about what you changed and why.
        """
    }

    private static func followUpPrompt(note: String, moment: String?) -> String {
        """
        Director's note: \(note)
        \(moment.map { "\n\($0)\n" } ?? "")
        context.json, plan.json and the frame_*.jpg stills have been refreshed to the user's \
        current plan, which may have been hand-edited since your last reply — re-read \
        context.json before changing anything. Apply the note on top of what is there: \
        overwrite plan.json, run ./crisp validate until it prints OK, preview what you \
        changed, and reply in 2–4 plain sentences. Leave plan.json untouched only if the note \
        is already satisfied.
        """
    }

    private static func fixupPrompt(issues: [String]) -> String {
        """
        The app checked plan.json and would have to change it to fit its rules:
        \(issues.map { "- \($0)" }.joined(separator: "\n"))

        Fix these in plan.json yourself so nothing is clamped behind your back — ./crisp \
        validate prints exactly these checks; run it until it prints OK. Then reply in one \
        sentence saying what you adjusted.
        """
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
                    Self.terminateThenKill(process, after: 2.0, on: queue)
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
                    // A cancel that landed before run() saw isRunning false
                    // and terminated nothing; catch up with it here.
                    queue.async {
                        if cancelled { Self.terminateThenKill(process, after: 2.0, on: queue) }
                    }
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
            terminateThenKill(process, after: 2.0, on: queue)
        }
    }

    /// SIGTERM, escalating to SIGKILL after `grace` if the process is still
    /// running — a CLI that ignores the polite signal must not keep burning
    /// the user's subscription (or hang the turn's continuation) forever.
    private static func terminateThenKill(_ process: Process, after grace: TimeInterval, on queue: DispatchQueue) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        queue.asyncAfter(deadline: .now() + grace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    enum DirectorError: LocalizedError {
        case cliFailed(String)
        case timedOut
        case unparseableOutput(String)
        case emptyPlan

        var errorDescription: String? {
            switch self {
            case .cliFailed(let detail):
                return "The AI tool failed: \(detail)"
            case .timedOut:
                return "The AI tool took too long and was stopped — your zooms are unchanged."
            case .unparseableOutput(let detail):
                return "The AI wrote an invalid plan.json (\(detail)) — your zooms are unchanged."
            case .emptyPlan:
                return "The AI returned an empty plan — kept your current zooms."
            }
        }
    }
}
