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
        private var frames: [AgentTools.Frame] = []
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
            try AIDirector.installBriefing(in: workspace, recording: recording)
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
            let context = try AIDirector.buildContext(meta: meta, duration: duration, segments: segments, frames: frames)
            try context.write(to: workspace.appendingPathComponent("context.json"))
            // Seed plan.json with the current plan so "nothing to change" is a
            // valid outcome: the agent overwrites it, or leaves it as is.
            let planURL = workspace.appendingPathComponent("plan.json")
            try AIDirector.encodePlan(segments).write(to: planURL)

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
                    frames.append(AgentTools.Frame(file: name, t: t, label: "the moment the user's note is about"))
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

            try await runTurn(
                prompt: started
                    ? AIDirector.followUpPrompt(note: note, moment: moment)
                    : AIDirector.firstPrompt(note: note, moment: moment, frames: frames, workspace: workspace),
                onEvent: onEvent
            )

            var (parsed, issues) = planState(planURL)
            if !issues.isEmpty {
                // Give the agent one shot at fixing its own plan; `./crisp
                // validate` prints exactly these checks, so it can iterate.
                AppModel.log("AI editor: plan needs fixes, asking the agent: \(issues.joined(separator: " | "))")
                onEvent(.activity(.other, "Fixing \(issues.count) rule issue\(issues.count == 1 ? "" : "s") in the plan"))
                try await runTurn(prompt: AIDirector.fixupPrompt(issues: issues), onEvent: onEvent)
                (parsed, issues) = planState(planURL)
            }
            guard let parsed else { throw DirectorError.unparseableOutput(issues.first ?? "unknown problem") }
            guard !parsed.segments.isEmpty || parsed.declared == 0 else { throw DirectorError.emptyPlan }
            let tag = [provider.kind.rawValue, model, effort].compactMap { $0 }.joined(separator: " / ")
            AppModel.log("AI editor (\(tag)): \(segments.count) → \(parsed.segments.count) segments; \(issues.count) adjustment(s)")
            return Outcome(plan: parsed.segments, adjustments: issues)
        }

        /// Run one CLI invocation with `prompt`, falling back once to a fresh
        /// conversation when resuming a stale provider session fails before
        /// it emits anything (e.g. cleared CLI history).
        private func runTurn(prompt: String, onEvent: @escaping (AIEvent) -> Void) async throws {
            var retriedFresh = false
            while true {
                let resuming = started
                try Data(prompt.utf8).write(to: workspace.appendingPathComponent("prompt.txt"))

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
        private func planState(_ url: URL) -> (ParsedPlan?, [String]) {
            guard let data = try? Data(contentsOf: url) else {
                return (nil, ["plan.json is missing — write the plan to plan.json in this directory"])
            }
            do {
                let parsed = try AIDirector.parsePlan(data, duration: duration, meta: meta)
                return (parsed, parsed.issues)
            } catch {
                AppModel.log("AI editor: bad plan.json: \(error.localizedDescription)")
                return (nil, ["plan.json could not be read: \(error.localizedDescription)"])
            }
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
                // acceptEdits: file writes inside the workspace cwd are auto-approved;
                // the allow-list lets the agent run the ./crisp tools unprompted.
                return "\(bin) -p \(session)\(modelFlag)\(effortFlag) --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools \"Read,Write,Edit,Bash(./crisp:*)\" < prompt.txt"
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

    // MARK: - Workspace briefing

    /// The standing brief every agent gets: CLAUDE.md for Claude Code and
    /// AGENTS.md for Codex (both CLIs load these from the working directory
    /// on their own), plus the `./crisp` wrapper that re-enters this binary
    /// headlessly for frames, previews and validation.
    static func installBriefing(in workspace: URL, recording: Recording) throws {
        let briefing = Data(briefingText(config: ZoomPlanner.Config()).utf8)
        try briefing.write(to: workspace.appendingPathComponent("CLAUDE.md"))
        try briefing.write(to: workspace.appendingPathComponent("AGENTS.md"))

        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let script = """
        #!/bin/zsh
        # Crisp agent tools — see AGENTS.md. Runs the app headlessly.
        exec "\(executable)" --agent-tool --recording "\(recording.folder.path)" --workspace "\(workspace.path)" "$@"

        """
        let scriptURL = workspace.appendingPathComponent("crisp")
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func briefingText(config: ZoomPlanner.Config) -> String {
        let leadIn = String(format: "%.2f", config.leadIn)
        let arriveEarly = String(format: "%.2f", config.leadIn - config.zoomInDuration)
        let zoomIn = String(format: "%.2f", config.zoomInDuration)
        let zoomOut = String(format: "%.2f", config.zoomOutDuration)
        let stepEase = String(format: "%.1f", config.stepDuration)
        return """
    # Crisp AI editor — director's brief

    You are the motion director for a screen recording made with Crisp. Crisp records the
    screen and every click, then plays it back through a virtual camera that zooms into the
    action. **Framing is automatic**: while zoomed, the camera follows the recorded cursor
    and recentres on clicks by itself (with a dead zone, a little look-ahead and a damped
    ease, so it never chases jitter). Your job is the part that needs judgement — **when**
    to be zoomed and **how far** — as an editorial pass over an automatic plan that is
    competent but unpolished. You are not re-authoring from scratch unless the user asks.

    ## What is in this directory

    - `context.json` — everything known about the video: size, duration, every click and
      drag, click clusters (the actions the automatic plan reasoned about), a
      sampled cursor path, the current plan, its derived timing, and the rules below as data.
    - `frame_N.jpg` — annotated stills: a coordinate grid in video pixels, rings on the
      clicks within ±1.5 s (with times), a blue dot for the cursor, and a green rectangle
      showing what the current plan's camera sees at that moment. Look at all of them.
    - `plan.json` — the current plan, in the exact shape you write back. Overwrite it.
    - `./crisp` — your tools (run `./crisp help`):
      - `./crisp frame <seconds>` — another annotated still at any time (`--raw` for clean).
      - `./crisp preview <seconds>` — what the export will show at that time under your
        `plan.json`: the real zoomed crop, as the follower frames it, with cursor and
        ripples. This is how you check that a level shows enough (or little enough).
      - `./crisp validate` — checks `plan.json` against the app's rules and prints the
        derived timing of every zoom and step. The app runs the same checks on apply and
        clamps anything you leave wrong, so finish only when it prints `OK`.
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
    `pin`: `{"x": …, "y": …}` in video pixels. A pinned zoom holds that centre instead of
    following (the crop is clamped inside the frame) — for its whole hold by default, or add
    `"from"` / `"until"` (seconds inside the hold) to pin only part of it and follow the
    cursor for the rest; the camera glides between the two. A hold that needs more than
    one pinned stretch (different spots at different times) uses `pins` instead: a list of
    those objects in time order, not overlapping. Use pins sparingly and only when the
    follower would genuinely miss the point; check them with `./crisp preview`.

    ## The plan file

    ```json
    {"segments": [
      {"id": "keep-if-unchanged", "start": 4.30, "end": 8.00, "zoom": 1.8,
       "steps": [{"id": "…", "t": 6.00, "zoom": 2.3}]},
      {"start": 12.00, "end": 15.50, "zoom": 2.0, "pin": {"x": 4200, "y": 900, "until": 14.00}}
    ]}
    ```

    - `segments` sorted by `start`, non-overlapping, with at least 0.20 s between one zoom's
      `end` and the next `start`; each hold at least 0.30 s.
    - `zoom` between 1.2 and 3.0. 1.5–2.0 suits most UI; 2.2–2.6 for a small control; go
      higher only for something tiny.
    - `steps` may be empty. Each `t` must be inside its zoom's hold.
    - `pin` is optional; omit it to follow the cursor (the default and usually right).
      `pins` (a list) only when one hold needs several pinned stretches.
    - optional `zoomIn` / `zoomOut` (seconds) set the ease-in and ease-out lengths; omit
      them for the defaults above.
    - Keep the `id` of every zoom and step you carry over (edited or not) and omit it on new
      ones — the app uses ids to show the user exactly what changed.
    - Two decimals are plenty for times and levels.

    ## Workflow, every turn

    1. Read `context.json`. Note the click clusters, which ones the current plan covers, the
       drags (a drag is one continuous action — one zoom), and any user note.
    2. Look at every `frame_N.jpg`. Identify what the user is doing at each moment and how
       much of the screen it needs. Pull extra frames with `./crisp frame <t>` wherever the
       story is unclear (between zooms, at uncovered clicks).
    3. Write the polished plan to `plan.json`.
    4. Run `./crisp validate`. Fix anything it reports and re-run until it prints `OK`.
    5. Run `./crisp preview <t>` at each hold opening (`start + 0.1`) and each step you
       changed, and look at the images. If the element is too small, zoom in more; if the
       viewer loses context, zoom out; if the wrong thing is framed, the timing is off.
    6. Reply to the user in 2–4 plain sentences: what you changed and why, in editorial
       terms ("tightened the opening on the Save click", "merged the two form zooms"). No
       JSON in the reply.

    On follow-up turns the files are refreshed to the user's current plan, which they may
    have hand-edited since your last reply — re-read `context.json` before changing anything,
    and apply the note on top of what is there.

    ## What "polished" means, in priority order

    1. **Timing.** Every hold opens on the click it serves, never noticeably late; it ends
       when the action is done, not on a timer. Clusters that are one continuous action share
       one zoom.
    2. **Fewer, better zooms.** Drop zooms on trivial or isolated clicks (closing a dialog,
       an idle click) — emphasis means nothing if everything is emphasised. Keep the ones that
       show the viewer something.
    3. **The right level.** Enough magnification that the control being used reads clearly,
       enough context that the viewer knows where it lives. Check with `./crisp preview`.
    4. **Few steps.** Step only when the action's scale genuinely changes mid-hold.
    5. **Calm pacing.** Breathing room at full frame between bursts; no zoom shorter than
       about a second unless the user asks for punchy cuts.
    """
    }

    // MARK: - Context assembly

    static func buildContext(
        meta: RecordingMeta, duration: Double, segments: [ZoomSegment], frames: [AgentTools.Frame]
    ) throws -> Data {
        let planner = ZoomPlanner(meta: meta)

        var clicks: [[String: Any]] = []
        for event in meta.events where event.kind == .leftDown || event.kind == .rightDown {
            clicks.append(["t": round2(event.t), "x": round2(event.x), "y": round2(event.y),
                           "button": event.kind == .rightDown ? "right" : "left"])
        }

        // Drags: a left press whose release lands somewhere else.
        var drags: [[String: Any]] = []
        var pressed: MouseEvent?
        for event in meta.events {
            switch event.kind {
            case .leftDown: pressed = event
            case .leftUp:
                if let down = pressed, hypot(event.x - down.x, event.y - down.y) >= 24 {
                    drags.append(["startT": round2(down.t), "startX": round2(down.x), "startY": round2(down.y),
                                  "endT": round2(event.t), "endX": round2(event.x), "endY": round2(event.y)])
                }
                pressed = nil
            default: break
            }
        }

        let clusters = AgentTools.clickClusters(meta: meta, duration: duration, planner: planner).map { cluster -> [String: Any] in
            let covering = segments.firstIndex { $0.start - 0.5 <= cluster.start && cluster.end <= $0.end + 0.5 }
            return ["start": round2(cluster.start), "end": round2(cluster.end), "count": cluster.count,
                    "centerX": round2(cluster.centerX), "centerY": round2(cluster.centerY),
                    "coveredByZoom": covering.map { $0 + 1 } as Any? ?? NSNull()]
        }

        // Cursor path, sampled coarsely enough to stay small on long videos.
        var cursorPath: [[Double]] = []
        let step = max(0.25, duration / 600)
        var t = 0.0
        while t <= duration {
            if let p = FrameComposer.cursorPosition(samples: meta.samples, at: t) {
                cursorPath.append([round2(t), p.x.rounded(), p.y.rounded()])
            }
            t += step
        }

        let timing: [[String: Any]] = segments.enumerated().map { index, seg in
            let span = planner.motionSpan(for: seg, duration: duration)
            return [
                "zoom": index + 1,
                "cameraStartsMoving": round2(span.moveStart), "fullyZoomed": round2(span.arrive),
                "holdEnds": round2(span.end), "backAtFullFrame": round2(span.outEnd),
                "steps": seg.steps.sorted { $0.t < $1.t }.map { step -> [String: Any] in
                    let window = planner.stepWindow(step, in: seg, duration: duration)
                    return ["startsEasing": round2(window.start), "atLevel": round2(window.end), "zoom": round2(step.zoom)]
                },
            ]
        }

        let iso = ISO8601DateFormatter()
        let plan = try JSONSerialization.jsonObject(with: encodePlan(segments))
        let context: [String: Any] = [
            "video": [
                "durationSeconds": round2(duration), "pixelWidth": meta.pixelWidth, "pixelHeight": meta.pixelHeight,
                "fps": meta.fps, "scaleFactor": meta.scaleFactor, "source": meta.source ?? "display",
                "recordedAt": iso.string(from: meta.startedAt),
                "coordinates": "video pixels, origin top-left, y down",
            ],
            "clicks": clicks,
            "drags": drags,
            "clickClusters": clusters,
            "cursorPath": ["format": "[t, x, y] every \(round2(step))s", "points": cursorPath],
            "currentPlan": plan,
            "currentPlanTiming": timing,
            "constraints": [
                "zoomMin": 1.2, "zoomMax": 3.0, "minHoldSeconds": 0.3, "minGapBetweenZoomsSeconds": 0.2,
                "leadInSeconds": planner.config.leadIn, "zoomInSeconds": planner.config.zoomInDuration,
                "zoomOutSeconds": planner.config.zoomOutDuration, "stepEaseSeconds": planner.config.stepDuration,
                "visibleArea": "pixelWidth/zoom × pixelHeight/zoom, centred by the follower on the cursor and clicks, clamped inside the frame",
            ],
            "tools": [
                "frame": "./crisp frame <seconds> [--raw] — annotated still at any time",
                "preview": "./crisp preview <seconds> — the export's look at that time under plan.json",
                "validate": "./crisp validate — rule check + derived timing; finish only on OK",
                "path": "./crisp path [from] [to] [--step s] — the camera over time under plan.json (t, zoom, centre, speed)",
            ],
            "frames": frames.map { ["file": $0.file, "atSeconds": round2($0.t), "label": $0.label] },
        ]
        return try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .prettyPrinted])
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// The plan in the exact shape the agent is asked to write back, ids
    /// included so unchanged zooms keep their identity.
    static func encodePlan(_ segments: [ZoomSegment]) throws -> Data {
        let plan: [[String: Any]] = segments.map { seg in
            var dto: [String: Any] = [
                "id": seg.id.uuidString,
                "start": round2(seg.start), "end": round2(seg.end), "zoom": round2(seg.zoom),
                "steps": seg.steps.sorted { $0.t < $1.t }.map { step in
                    ["id": step.id.uuidString, "t": round2(step.t), "zoom": round2(step.zoom)]
                },
            ]
            let pins = seg.pins
                .sorted { ($0.from ?? seg.start) < ($1.from ?? seg.start) }
                .map { pin -> [String: Any] in
                    var pinDTO: [String: Any] = ["x": pin.x.rounded(), "y": pin.y.rounded()]
                    if let from = pin.from { pinDTO["from"] = round2(from) }
                    if let until = pin.until { pinDTO["until"] = round2(until) }
                    return pinDTO
                }
            if pins.count == 1 {
                dto["pin"] = pins[0]
            } else if pins.count > 1 {
                dto["pins"] = pins
            }
            if let zoomIn = seg.zoomIn { dto["zoomIn"] = round2(zoomIn) }
            if let zoomOut = seg.zoomOut { dto["zoomOut"] = round2(zoomOut) }
            return dto
        }
        return try JSONSerialization.data(withJSONObject: ["segments": plan], options: [.sortedKeys, .prettyPrinted])
    }

    /// Human-readable derived timing of a plan, as `./crisp validate` prints it.
    static func describe(_ segments: [ZoomSegment], planner: ZoomPlanner, duration: Double) -> String {
        guard !segments.isEmpty else { return "(no zooms — the whole video plays at full frame)" }
        var lines: [String] = []
        for (index, seg) in segments.enumerated() {
            let span = planner.motionSpan(for: seg, duration: duration)
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
                format: "zoom %d: camera moves %.2fs → fully zoomed %.2fs (hold opens %.2fs) → hold ends %.2fs → full frame by %.2fs | %.2f×%@",
                index + 1, span.moveStart, span.arrive, seg.start, span.end, span.outEnd, seg.zoom, framing
            ))
            for step in seg.steps.sorted(by: { $0.t < $1.t }) {
                let window = planner.stepWindow(step, in: seg, duration: duration)
                lines.append(String(
                    format: "    step: from %.2fs eases to %.2f× by %.2fs",
                    window.start, step.zoom, window.end
                ))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompts

    private static func firstPrompt(note: String, moment: String?, frames: [AgentTools.Frame], workspace: URL) -> String {
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

    // MARK: - Parse & validate

    struct ParsedPlan {
        var segments: [ZoomSegment]
        /// Every change the rules forced, in the agent's own numbering.
        var issues: [String]
        /// How many zooms the file declared (so "all dropped" can be told from "none").
        var declared: Int
    }

    private struct PlanDTO: Decodable {
        var segments: [SegDTO]
        struct SegDTO: Decodable {
            var id: String?
            var start: Double
            var end: Double
            var zoom: Double?
            var steps: [StepDTO]?
            var pin: PinDTO?
            /// Several pinned stretches of one hold, in time order.
            var pins: [PinDTO]?
            var zoomIn: Double?
            var zoomOut: Double?
        }
        struct PinDTO: Decodable {
            var x: Double
            var y: Double
            var from: Double?
            var until: Double?
        }
        struct StepDTO: Decodable {
            var id: String?
            var t: Double
            var zoom: Double
        }
    }

    /// Decode a plan file and normalise it, reporting every forced change.
    static func parsePlan(_ data: Data, duration: Double, meta: RecordingMeta) throws -> ParsedPlan {
        let dto: PlanDTO
        do {
            dto = try JSONDecoder().decode(PlanDTO.self, from: data)
        } catch let error as DecodingError {
            throw DirectorError.unparseableOutput(describe(error))
        } catch {
            throw DirectorError.unparseableOutput(error.localizedDescription)
        }
        return validate(dto, duration: duration, meta: meta)
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
    private static func validate(_ dto: PlanDTO, duration: Double, meta: RecordingMeta) -> ParsedPlan {
        var result: [ZoomSegment] = []
        var issues: [String] = []
        func f(_ x: Double) -> String { String(format: "%.2f", x) }

        for (n, seg) in dto.segments.sorted(by: { $0.start < $1.start }).enumerated() {
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
            if let previous = result.last, start < previous.end + 0.2 {
                let moved = previous.end + 0.2
                issues.append("\(label): starts before the previous zoom ends (\(f(previous.end))s) plus the 0.20s gap → start moved to \(f(moved))")
                start = moved
            }
            guard end - start >= 0.3 else {
                issues.append("\(label): dropped — its hold \(f(start))–\(f(end))s is shorter than 0.30s")
                continue
            }
            var zoom = seg.zoom ?? 1.8
            if zoom < 1.2 || zoom > 3.0 {
                zoom = min(max(zoom, 1.2), 3.0)
                issues.append("\(label): zoom \(f(seg.zoom ?? 1.8)) is outside 1.2–3.0 → \(f(zoom))")
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
                if level < 1.2 || level > 3.0 {
                    level = min(max(level, 1.2), 3.0)
                    issues.append("\(slabel): zoom \(f(step.zoom)) is outside 1.2–3.0 → \(f(level))")
                }
                steps.append(ZoomStep(id: step.id.flatMap(UUID.init(uuidString:)) ?? UUID(), t: t, zoom: level))
            }
            var segment = ZoomSegment(
                id: seg.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                start: start, end: end, zoom: zoom, steps: steps
            )
            // Pins in time order, each clamped into the hold and pushed
            // after the one before it so they never overlap.
            let pinDTOs = ((seg.pins ?? []) + (seg.pin.map { [$0] } ?? []))
                .sorted { ($0.from ?? start) < ($1.from ?? start) }
            var previousUntil = start
            for (pindex, p) in pinDTOs.enumerated() {
                let plabel = pinDTOs.count == 1 ? "\(label): pin" : "\(label): pin \(pindex + 1)"
                let w = Double(meta.pixelWidth)
                let h = Double(meta.pixelHeight)
                let clamped = CGPoint(x: min(max(p.x, 0), w), y: min(max(p.y, 0), h))
                if clamped != CGPoint(x: p.x, y: p.y) {
                    issues.append("\(plabel) (\(Int(p.x)), \(Int(p.y))) is outside the \(Int(w))×\(Int(h)) frame → (\(Int(clamped.x)), \(Int(clamped.y)))")
                }
                var from = start
                if let wanted = p.from {
                    from = min(max(wanted, start, previousUntil), max(start, end - 0.1))
                    if from != wanted {
                        issues.append("\(plabel) `from` \(f(wanted)) is outside the hold (or overlaps the pin before it) → \(f(from))")
                    }
                } else if previousUntil > start {
                    from = min(previousUntil, max(start, end - 0.1))
                    issues.append("\(plabel) has no `from` but comes after another pin → starts at \(f(from))")
                }
                var until: Double?
                if let wanted = p.until {
                    let clamped = max(min(wanted, end), min(end, from + 0.1))
                    if clamped != wanted {
                        issues.append("\(plabel) `until` \(f(wanted)) is outside the hold (after `from`) → \(f(clamped))")
                    }
                    until = clamped >= end - 0.001 ? nil : clamped
                }
                previousUntil = until ?? end
                segment.pins.append(PinWindow(
                    x: clamped.x, y: clamped.y,
                    from: from <= start + 0.001 ? nil : from, until: until
                ))
            }
            if let zoomIn = seg.zoomIn {
                let clamped = min(max(zoomIn, 0.1), 8)
                if clamped != zoomIn {
                    issues.append("\(label): zoomIn \(f(zoomIn))s is outside 0.10–8.00s → \(f(clamped))")
                }
                segment.zoomIn = clamped
            }
            if let zoomOut = seg.zoomOut {
                let clamped = min(max(zoomOut, 0.1), 8)
                if clamped != zoomOut {
                    issues.append("\(label): zoomOut \(f(zoomOut))s is outside 0.10–8.00s → \(f(clamped))")
                }
                segment.zoomOut = clamped
            }
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
        return ParsedPlan(segments: result, issues: issues, declared: dto.segments.count)
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
