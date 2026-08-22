import SwiftUI

/// One row in the AI Polish conversation.
struct AIMessage: Identifiable {
    enum Role { case user, assistant, system }

    let id = UUID()
    var role: Role
    var text: String
    /// Tool steps the agent took before replying ("Viewed frame_2.jpg").
    var activities: [String] = []
    /// Plan in effect before this reply was applied — enables "Revert".
    var before: [ZoomSegment]?
}

/// Conversation state for the editor's AI Polish panel. One per editor window;
/// the underlying provider session is recreated if the provider changes.
@MainActor
final class AIChat: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var running = false
    @Published var providers: [AIProvider] = []
    @Published var provider: AIProvider?

    private var session: AIDirector.Session?

    var hasStarted: Bool { messages.contains { $0.role == .assistant } }

    func detectProviders() async {
        providers = await AIDirector.detectProviders()
        if provider == nil { provider = providers.first }
    }

    /// Send a note (may be empty on the first turn = "default polish").
    /// `apply` is called on the main actor with the validated new plan.
    func send(
        note: String,
        recording: Recording, meta: RecordingMeta, duration: Double,
        segments: [ZoomSegment],
        apply: @escaping ([ZoomSegment]) -> Void
    ) {
        guard let provider, !running else { return }
        if session == nil || session?.provider != provider {
            do {
                session = try AIDirector.Session(
                    provider: provider, recording: recording, meta: meta, duration: duration
                )
            } catch {
                messages.append(AIMessage(role: .system, text: error.localizedDescription))
                return
            }
        }
        guard let session else { return }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(AIMessage(role: .user, text: trimmed.isEmpty ? "Polish with the default brief" : trimmed))
        messages.append(AIMessage(role: .assistant, text: ""))
        let replyID = messages[messages.count - 1].id
        running = true

        Task {
            do {
                let plan = try await session.send(note: trimmed, segments: segments) { event in
                    Task { @MainActor in self.absorb(event, into: replyID) }
                }
                update(replyID) { $0.before = segments }
                apply(plan)
                let summary = "Applied: \(segments.count) → \(plan.count) zooms."
                update(replyID) { $0.text = $0.text.isEmpty ? summary : $0.text + "\n\n" + summary }
            } catch {
                update(replyID) {
                    $0.text = $0.text.isEmpty ? "" : $0.text + "\n\n"
                    $0.text += "⚠︎ \(error.localizedDescription)"
                }
            }
            running = false
        }
    }

    func clear() {
        messages.removeAll()
        session = nil
    }

    private func absorb(_ event: AIEvent, into id: UUID) {
        update(id) { message in
            switch event {
            case .text(let text):
                message.text = message.text.isEmpty ? text : message.text + "\n\n" + text
            case .activity(let activity):
                message.activities.append(activity)
            }
        }
    }

    private func update(_ id: UUID, _ edit: (inout AIMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        edit(&messages[index])
    }
}

/// Right-hand chat panel: header with provider picker, the transcript, and a
/// composer. The first send polishes with the built-in brief (plus any note);
/// later sends are follow-up director's notes in the same session.
struct AIPanelView: View {
    @ObservedObject var chat: AIChat
    let recording: Recording
    let meta: RecordingMeta?
    let duration: Double
    let segments: [ZoomSegment]
    let onApply: ([ZoomSegment]) -> Void
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            transcript
            Divider().overlay(Theme.border)
            composer
        }
        .frame(width: 320)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(Theme.border))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Theme.mutedForeground)
            Text("AI Polish")
                .font(Theme.font(13, .semibold))
            Spacer()
            Picker("", selection: $chat.provider) {
                ForEach(chat.providers) { provider in
                    Text(provider.kind.rawValue).tag(Optional(provider))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(chat.running || chat.hasStarted)
            .help(chat.hasStarted ? "Clear the conversation to switch provider" : "Agent CLI to use")
            if chat.hasStarted {
                Button {
                    chat.clear()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.themed(.ghost, size: .xs))
                .disabled(chat.running)
                .help("Start a new conversation")
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.themed(.ghost, size: .xs))
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                                   running: chat.running, onRevert: onApply)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                if let id = chat.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .onChange(of: chat.messages.last?.activities.count) { _, _ in
                if let id = chat.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hand your zoom plan to an agent for an editorial pass: tighter timing, fewer zooms and pans, better framing.")
            Text("Add a director's note if you want something specific, or just hit Polish.")
                .foregroundStyle(Theme.mutedForeground)
            if chat.providers.isEmpty {
                Text("No agent CLI found. Install Claude Code or Codex and sign in.")
                    .foregroundStyle(Theme.destructive)
                    .padding(.top, 4)
            }
        }
        .font(Theme.font(12))
        .foregroundStyle(Theme.textSecondary)
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(
                chat.hasStarted ? "Follow-up note…" : "Director's note (optional) — e.g. “calmer, only zoom on the form”",
                text: $draft, axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .font(Theme.font(12))
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.input))
            .focused($composerFocused)
            .disabled(chat.running)
            .onSubmit(send)
            HStack {
                if chat.running {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.mutedForeground)
                }
                Spacer()
                Button(chat.hasStarted ? "Send" : "Polish", action: send)
                    .buttonStyle(.themed(.primary, size: .sm))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .onAppear { composerFocused = true }
    }

    private var canSend: Bool {
        guard chat.provider != nil, meta != nil, !chat.running, !segments.isEmpty else { return false }
        // First turn may be note-less (default brief); follow-ups need a note.
        return !chat.hasStarted || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let meta else { return }
        let note = draft
        draft = ""
        chat.send(note: note, recording: recording, meta: meta, duration: duration,
                  segments: segments, apply: onApply)
    }
}

private struct MessageRow: View {
    let message: AIMessage
    let isLast: Bool
    let running: Bool
    let onRevert: ([ZoomSegment]) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.primaryForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .textSelection(.enabled)
            }
        case .system:
            Text(message.text)
                .font(Theme.font(11))
                .foregroundStyle(Theme.destructive)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.activities.enumerated()), id: \.offset) { _, activity in
                    Label(activity, systemImage: icon(for: activity))
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                if !message.text.isEmpty {
                    Text(markdown(message.text))
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.foreground)
                        .textSelection(.enabled)
                        .padding(.top, message.activities.isEmpty ? 0 : 2)
                } else if isLast && running {
                    Text("Thinking…")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.mutedForeground)
                }
                if let before = message.before {
                    Button("Revert this change") { onRevert(before) }
                        .buttonStyle(.themed(.link, size: .xs))
                        .disabled(running)
                }
            }
        }
    }

    private func icon(for activity: String) -> String {
        if activity.hasPrefix("Viewed") { return "eye" }
        if activity.hasPrefix("Wrote") { return "square.and.pencil" }
        if activity.hasPrefix("Ran") { return "terminal" }
        if activity.hasPrefix("Started") { return "arrow.triangle.2.circlepath" }
        return "wrench"
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
