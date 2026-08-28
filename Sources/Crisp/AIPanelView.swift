import SwiftUI

/// One row in the AI editor conversation.
struct AIMessage: Identifiable {
    enum Role { case user, assistant, system }

    struct Activity: Identifiable {
        let id = UUID()
        var kind: AIEvent.ActivityKind
        var detail: String
    }

    let id = UUID()
    var role: Role
    var text: String
    /// The moment (seconds) a user note was about, attached from the playhead.
    var timestamp: Double? = nil
    /// Tool steps the agent took before replying.
    var activities: [Activity] = []
    /// Plan in effect before this reply was applied — enables "Revert".
    var before: [ZoomSegment]?
    /// Plan this reply put in place. "Compare" plays `before` against this,
    /// not against whatever the editor holds now.
    var after: [ZoomSegment]?

    mutating func append(paragraph: String) {
        text = text.isEmpty ? paragraph : text + "\n\n" + paragraph
    }
}

/// Conversation state for the editor's AI editor panel. One per editor window;
/// the underlying provider session is recreated if the provider changes.
@MainActor
final class AIChat: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published private(set) var running = false
    /// True once a turn has succeeded: the provider picker locks, later sends
    /// are follow-up notes. Mirrors `Session.started`.
    @Published private(set) var hasStarted = false
    @Published var providers: [AIProvider] = []
    @Published var provider: AIProvider? {
        didSet {
            model = Self.storedModel(for: provider)
            effort = Self.storedEffort(for: provider)
        }
    }
    /// Model within the chosen provider. Starts as the CLI's own configured
    /// default; an explicit pick is remembered per provider across launches.
    @Published var model: AIModel? {
        didSet {
            guard let provider else { return }
            UserDefaults.standard.set(model?.id, forKey: Self.modelKey(provider.kind))
            if let effort, !efforts.contains(effort) {
                self.effort = model?.defaultEffort ?? provider.defaultEffort
            }
        }
    }
    /// Reasoning effort, likewise defaulted from the CLI and remembered per provider.
    @Published var effort: String? {
        didSet {
            guard let provider else { return }
            UserDefaults.standard.set(effort, forKey: Self.effortKey(provider.kind))
        }
    }

    /// Effort levels the chosen model accepts.
    var efforts: [String] {
        model?.efforts ?? provider?.defaultModel?.efforts ?? AIModel.standardEfforts
    }

    private var session: AIDirector.Session?
    private var turn: Task<Void, Never>?
    /// Identity of the turn that owns `running`; a cancelled turn's tail
    /// must not reset state that a newer turn has since taken over.
    private var turnID = UUID()

    func detectProviders() async {
        providers = await AIDirector.detectProviders()
        if provider == nil { provider = providers.first }
    }

    private static func modelKey(_ kind: AIProvider.Kind) -> String { "ai.model.\(kind.rawValue)" }
    private static func effortKey(_ kind: AIProvider.Kind) -> String { "ai.effort.\(kind.rawValue)" }

    private static func storedEffort(for provider: AIProvider?) -> String? {
        guard let provider else { return nil }
        let model = storedModel(for: provider)
        if let stored = UserDefaults.standard.string(forKey: effortKey(provider.kind)),
           model?.efforts.contains(stored) ?? true {
            return stored
        }
        return model?.defaultEffort ?? provider.defaultEffort
    }

    private static func storedModel(for provider: AIProvider?) -> AIModel? {
        guard let provider else { return nil }
        if let id = UserDefaults.standard.string(forKey: modelKey(provider.kind)),
           let stored = provider.models.first(where: { $0.id == id }) {
            return stored
        }
        return provider.defaultModel
    }

    /// Send a note (may be empty on the first turn = the default brief).
    /// `apply` is called on the main actor with the validated new plan, after
    /// every streamed event has landed in the transcript.
    func send(
        note: String, timestamp: Double? = nil,
        recording: Recording, meta: RecordingMeta, duration: Double,
        segments: [ZoomSegment],
        apply: @escaping ([ZoomSegment]) -> Void
    ) {
        guard let provider, !running else { return }
        if session == nil || session?.provider != provider
            || session?.model != model?.id || session?.effort != effort {
            do {
                session = try AIDirector.Session(
                    provider: provider, model: model?.id, effort: effort,
                    recording: recording, meta: meta, duration: duration
                )
            } catch {
                messages.append(AIMessage(role: .system, text: error.localizedDescription))
                return
            }
        }
        guard let session else { return }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(AIMessage(role: .user, text: trimmed.isEmpty ? "Default brief" : trimmed,
                                  timestamp: timestamp))
        let reply = AIMessage(role: .assistant, text: "")
        messages.append(reply)
        running = true
        let myTurn = UUID()
        turnID = myTurn

        turn = Task {
            // Events are yielded from the pipe thread into an ordered stream and
            // drained here, on the main actor, before the outcome is handled —
            // so the transcript is complete when the plan is applied.
            let (events, continuation) = AsyncStream<AIEvent>.makeStream()
            async let outcome: Result<AIDirector.Outcome, Error> = {
                defer { continuation.finish() }
                do {
                    return .success(try await session.send(note: trimmed, timestamp: timestamp, segments: segments) { continuation.yield($0) })
                } catch {
                    return .failure(error)
                }
            }()
            for await event in events {
                absorb(event, into: reply.id)
            }
            let result = await outcome
            guard turnID == myTurn else { return }   // superseded by clear()/a newer turn
            switch result {
            case .success(let outcome):
                let plan = outcome.plan
                let steps = plan.reduce(0) { $0 + $1.steps.count }
                update(reply.id) {
                    $0.before = segments
                    $0.after = plan
                    $0.append(paragraph: "Applied: \(segments.count) → \(plan.count) zooms" + (steps > 0 ? ", \(steps) zoom-in \(steps == 1 ? "step" : "steps")." : "."))
                    if !outcome.adjustments.isEmpty {
                        $0.append(paragraph: "Adjusted to fit the rules:\n" + outcome.adjustments.map { "• \($0)" }.joined(separator: "\n"))
                    }
                }
                hasStarted = true
                apply(plan)
            case .failure(is CancellationError):
                update(reply.id) { $0.append(paragraph: "Cancelled.") }
            case .failure(let error):
                update(reply.id) { $0.append(paragraph: "⚠︎ \(error.localizedDescription)") }
            }
            running = false
            turn = nil
        }
    }

    /// Cancel any in-flight turn and forget the conversation.
    func clear() {
        turn?.cancel()
        turn = nil
        turnID = UUID()
        running = false
        messages.removeAll()
        session = nil
        hasStarted = false
    }

    private func absorb(_ event: AIEvent, into id: UUID) {
        update(id) { message in
            switch event {
            case .text(let text):
                message.append(paragraph: text)
            case .activity(let kind, let detail):
                message.activities.append(.init(kind: kind, detail: detail))
            }
        }
    }

    private func update(_ id: UUID, _ edit: (inout AIMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        edit(&messages[index])
    }
}

/// Right-hand chat sidebar (Figma 29:4691): the transcript on top, and a
/// composer group pinned to the bottom — note field + send, then a row of
/// provider / model / effort chips. The first send polishes with the
/// built-in brief (plus any note); later sends are follow-up director's
/// notes in the same session.
struct AIPanelView: View {
    static let width: CGFloat = 445

    @ObservedObject var chat: AIChat
    let recording: Recording
    let meta: RecordingMeta?
    let duration: Double
    /// A moment attached to the next note (Figma 83:14758), set by the
    /// editor toolbar's "Send timestamp to chat".
    @Binding var attachedTime: Double?
    /// Mirrors the composer's focus out to the editor, which suspends its
    /// bare-key Space shortcut only while the user is actually typing here.
    @Binding var composerIsFocused: Bool
    let segments: [ZoomSegment]
    let onApply: ([ZoomSegment]) -> Void
    /// Open the split preview of one reply's change: its `before` plan
    /// against the `after` plan it applied.
    let onCompare: (_ before: [ZoomSegment], _ after: [ZoomSegment]) -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            transcript
            composer
        }
        .padding(24)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Theme.card)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .onChange(of: composerFocused) { _, focused in composerIsFocused = focused }
        .onDisappear { composerIsFocused = false }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.messages.isEmpty {
                        intro
                    }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, isLast: message.id == chat.messages.last?.id,
                                   running: chat.running, onRevert: onApply, onCompare: onCompare)
                            .id(message.id)
                    }
                }
            }
            .onChange(of: scrollKey) { _, _ in
                if let id = chat.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    /// Changes whenever the last message appears or grows.
    private var scrollKey: String {
        guard let last = chat.messages.last else { return "" }
        return "\(last.id)/\(last.text.count)/\(last.activities.count)"
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hand your zoom plan to an agent for an editorial pass: tighter timing, fewer and better zooms, the right levels. It sees annotated stills of the recording, can render previews of its plan through the real camera, and checks it against the app's rules before replying.")
            Text("Describe the polish you want, or just send to use the default brief.")
                .foregroundStyle(Theme.mutedForeground)
            if chat.providers.isEmpty {
                Text("No agent CLI found. Install Claude Code or Codex and sign in.")
                    .foregroundStyle(Theme.destructive)
                    .padding(.top, 4)
            }
        }
        .font(Theme.font(.body12))
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: - Composer (Figma 29:4692)

    private var composer: some View {
        composerBox
    }

    private var composerBox: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let attachedTime {
                    HStack(spacing: 10) {
                        Text("Timestamp \(shortTimecode(attachedTime))")
                            .font(Theme.font(.label12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.foreground)
                        Button {
                            self.attachedTime = nil
                        } label: {
                            Icon(name: "x", size: 16, fallback: "xmark")
                                .foregroundStyle(Theme.foreground)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .tooltip("Remove the timestamp")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Theme.muted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.secondary))
                }
                HStack(spacing: 16) {
                    TextField(
                        attachedTime != nil ? "What changes do you want at this moment?"
                            : (chat.hasStarted ? "Follow-up note…" : "Describe the polish"),
                        text: $draft, axis: .vertical
                    )
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(Theme.font(.body12))
                    .focused($composerFocused)
                    .disabled(chat.running)
                    .onSubmit(send)
                    Button(action: send) {
                        if chat.running {
                            ThemedSpinner(size: 12)
                        } else {
                            Icon(name: "arrow-return", size: 12, fallback: "return")
                        }
                    }
                    .buttonStyle(.themed(.primary, size: .xs, iconOnly: true, corners: .all(Theme.radiusMd)))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .tooltip(chat.hasStarted ? "Send follow-up (⌘↩)" : "Send (⌘↩)")
                }
            }
            .padding(8)
            .frame(minHeight: 44)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.input))

            HStack(spacing: 6) {
                chip(Self.providerMenu, title: chat.provider?.kind.rawValue ?? "No agent",
                     help: chat.hasStarted ? "Clear the conversation to switch provider" : "Agent CLI to use")
                if !chat.messages.isEmpty {
                    Button {
                        chat.clear()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.themed(.ghost, size: .xs, iconOnly: true, corners: .all(Theme.radiusMd)))
                    .tooltip(chat.running ? "Stop and start a new conversation" : "Start a new conversation")
                }
                Spacer()
                if let provider = chat.provider, !provider.models.isEmpty {
                    chip(Self.modelMenu, title: chat.model?.label ?? "Model",
                         help: chat.hasStarted ? "Clear the conversation to switch model" : "Model for \(provider.kind.rawValue)")
                    chip(Self.effortMenu, title: chat.effort?.capitalized ?? "Effort",
                         help: chat.hasStarted ? "Clear the conversation to change effort" : "Reasoning effort")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Theme.track, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .onAppear { composerFocused = true }
    }

    private static let providerMenu = "provider"
    private static let modelMenu = "model"
    private static let effortMenu = "effort"

    /// Footer chip (Figma "Button" xs ghost + trailing CaretDown); secondary
    /// fill while its dropdown is open above it.
    private func chip(_ id: String, title: String, help: String) -> some View {
        DropdownButton(
            id: id, edge: .top, alignment: .trailing,
            style: { .themed($0 ? .secondary : .ghost, size: .xs, corners: .all(Theme.radiusMd), trailingIcon: true) },
            items: { menuItems(for: id) }
        ) { _ in
            HStack(spacing: 4) {
                Text(title)
                Icon(name: "caret-down", size: 12, fallback: "chevron.down")
            }
        }
        .fixedSize()
        .disabled(chat.running || chat.hasStarted)
        .tooltip(help)
    }

    private func menuItems(for id: String) -> [DropdownItem] {
        func pick(_ action: @escaping () -> Void) -> () -> Void { action }
        switch id {
        case Self.providerMenu:
            return chat.providers.map { provider in
                DropdownItem(id: provider.id, label: provider.kind.rawValue,
                             checked: chat.provider == provider, action: pick { chat.provider = provider })
            }
        case Self.modelMenu:
            return (chat.provider?.models ?? []).map { model in
                DropdownItem(id: model.id, label: model.label, checked: chat.model == model,
                             action: pick { chat.model = model })
            }
        case Self.effortMenu:
            return chat.efforts.map { level in
                DropdownItem(id: level, label: level.capitalized, checked: chat.effort == level,
                             action: pick { chat.effort = level })
            }
        default:
            return []
        }
    }

    private var canSend: Bool {
        guard chat.provider != nil, meta != nil, !chat.running else { return false }
        let hasNote = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if chat.hasStarted || attachedTime != nil {
            // Follow-ups (and any note about a moment) need words; an empty
            // plan is a legitimate state to iterate from.
            return hasNote
        }
        // The first turn may be note-less (default brief) but needs a plan to polish.
        return !segments.isEmpty
    }

    private func send() {
        guard canSend, let meta else { return }
        let note = draft
        let timestamp = attachedTime
        draft = ""
        attachedTime = nil
        chat.send(note: note, timestamp: timestamp, recording: recording, meta: meta, duration: duration,
                  segments: segments, apply: onApply)
    }
}

private struct MessageRow: View {
    let message: AIMessage
    let isLast: Bool
    let running: Bool
    let onRevert: ([ZoomSegment]) -> Void
    let onCompare: (_ before: [ZoomSegment], _ after: [ZoomSegment]) -> Void

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .leading, spacing: 8) {
                if let timestamp = message.timestamp {
                    Text("Timestamp \(shortTimecode(timestamp))")
                        .font(Theme.font(.label12))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.secondary))
                }
                Text(message.text)
            }
                .font(Theme.font(.label12))
                .foregroundStyle(Theme.foreground)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.muted, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.input))
                .textSelection(.enabled)
        case .system:
            Text(message.text)
                .font(Theme.font(.body12))
                .foregroundStyle(Theme.destructive)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.activities) { activity in
                    Label(label(for: activity), systemImage: icon(for: activity.kind))
                        .font(Theme.font(.body12))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                if !message.text.isEmpty {
                    Text(markdown(message.text))
                        .font(Theme.font(.body12))
                        .foregroundStyle(Theme.foreground)
                        .textSelection(.enabled)
                        .padding(.top, message.activities.isEmpty ? 0 : 2)
                } else if isLast && running {
                    Text("Thinking…")
                        .font(Theme.font(.body12))
                        .foregroundStyle(Theme.mutedForeground)
                }
                if let before = message.before {
                    HStack(spacing: 12) {
                        if let after = message.after {
                            Button("Compare") { onCompare(before, after) }
                                .buttonStyle(.themed(.link, size: .xs))
                                .tooltip("Play the zooms as they were before and after this change, stacked")
                        }
                        Button("Revert this change") { onRevert(before) }
                            .buttonStyle(.themed(.link, size: .xs))
                            .tooltip("Put the zooms back to how they were before this change")
                    }
                    .disabled(running)
                }
            }
        }
    }

    private func label(for activity: AIMessage.Activity) -> String {
        switch activity.kind {
        case .viewed: return "Viewed \(activity.detail)"
        case .wrote: return "Wrote \(activity.detail)"
        case .ran: return "Ran \(activity.detail)"
        case .other: return activity.detail
        case .sessionRestarted: return "Started a new session"
        }
    }

    private func icon(for kind: AIEvent.ActivityKind) -> String {
        switch kind {
        case .viewed: return "eye"
        case .wrote: return "square.and.pencil"
        case .ran: return "terminal"
        case .other: return "wrench"
        case .sessionRestarted: return "arrow.triangle.2.circlepath"
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
