import SwiftUI
import ScreenCaptureKit

/// Main window, laid out after the Crisp v1 Figma frame: wordmark, the
/// Record / Screenshot / codec row, source tabs with a thumbnail column next
/// to a large preview, then the recordings list.
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage("screenshot.format") private var screenshotFormatRaw = ScreenshotFormat.png16.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue

    private let inset: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            controlsRow
            sourcesSection
            recordingsSection
        }
        .font(Theme.font(14))
        .foregroundStyle(Theme.foreground)
        .padding(inset)
        .frame(minWidth: 880, minHeight: 760)
        .background(Theme.background)
        .background(WindowChrome())
        .onAppear { model.refresh() }
    }

    /// True in the Crisp Dev build (separate bundle id) — badged so the two
    /// side-by-side builds are unmistakable.
    private var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? true
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .dark
    }

    private var appearanceToggle: some View {
        Button {
            appearanceRaw = appearance.other.rawValue
        } label: {
            Icon(
                name: appearance == .dark ? "sun" : "moon",
                size: 14,
                fallback: appearance == .dark ? "sun.max" : "moon"
            )
        }
        .buttonStyle(.themed(.outline, size: .sm, iconOnly: true))
        .help(appearance == .dark ? "Switch to light mode" : "Switch to dark mode")
    }

    // MARK: - Controls row

    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Wordmark()
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                if isDevBuild {
                    Text("DEV")
                        .font(Theme.font(11, .semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.primary.opacity(0.15)))
                }
                recordButton
                    .frame(maxWidth: .infinity)
                screenshotSplitButton
                    .frame(maxWidth: .infinity)
                codecSelect
                if case .recording(let start) = model.state {
                    RecordingTimer(start: start)
                }
                appearanceToggle
            }

            if case .error(let message) = model.state {
                Text(message)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.destructive)
                    .textSelection(.enabled)
            } else if let toast = model.toast {
                Text(toast)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.success)
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                if model.isRecording {
                    await model.stopRecording()
                } else {
                    await model.startRecording()
                }
            }
        } label: {
            HStack(spacing: ControlSizeToken.lg.gap) {
                if model.isRecording {
                    Icon(name: "stop-fill", size: 16, fallback: "stop.fill")
                    Text("Stop Recording")
                } else {
                    Icon(name: "record", size: 16, fallback: "record.circle")
                    Text("Record")
                }
            }
        }
        .buttonStyle(.themed(
            .primary, size: .lg, fullWidth: true, leadingIcon: true,
            tint: model.isRecording ? Theme.destructive : nil,
            tintBorder: model.isRecording ? Theme.destructive : nil
        ))
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.hasScreenAccess)
        .help("Record the selected source at native Retina resolution, 60fps (⌘R). Clicks are logged for zoom animation.")
    }

    /// ButtonGroup/Split: primary action + separator + dropdown for the format.
    private var screenshotSplitButton: some View {
        HStack(spacing: 0) {
            Button {
                Task {
                    await model.screenshot(
                        format: ScreenshotFormat(rawValue: screenshotFormatRaw) ?? .png16
                    )
                }
            } label: {
                HStack(spacing: ControlSizeToken.lg.gap) {
                    Icon(name: "camera-duotone", size: 16, fallback: "camera")
                    Text("Screenshot")
                }
            }
            .buttonStyle(.themed(
                .outline, size: .lg, fullWidth: true, corners: .leading(Theme.radiusSm),
                leadingIcon: true
            ))
            .help("Capture the selected source as a high-bit-depth screenshot. Saved 10-bit to ~/Pictures/Crisp.")

            Rectangle()
                .fill(Theme.input)
                .frame(width: 1, height: 32)
                .padding(.horizontal, -1)
                .zIndex(1)

            Menu {
                ForEach(ScreenshotFormat.allCases) { format in
                    Button {
                        screenshotFormatRaw = format.rawValue
                    } label: {
                        if screenshotFormatRaw == format.rawValue {
                            Label(format.rawValue, systemImage: "checkmark")
                        } else {
                            Text(format.rawValue)
                        }
                    }
                }
            } label: {
                Icon(name: "caret-down", size: 16, fallback: "chevron.down")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.themed(
                .outline, size: .lg, iconOnly: true, corners: .trailing(Theme.radiusSm)
            ))
            .help("Screenshot format")
        }
        .disabled(!model.hasScreenAccess || model.isRecording)
    }

    private var codecSelect: some View {
        Menu {
            ForEach(MasterCodec.allCases) { codec in
                Button {
                    model.codec = codec
                } label: {
                    if model.codec == codec {
                        Label(codec.rawValue, systemImage: "checkmark")
                    } else {
                        Text(codec.rawValue)
                    }
                }
            }
        } label: {
            SelectTriggerLabel(text: model.codec.rawValue)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .pointingHandCursor()
        .fixedSize()
        .disabled(model.isRecording)
        .help("Master recording codec")
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        Group {
            if !model.accessChecked {
                panel {
                    ProgressView("Checking Screen Recording access…")
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.mutedForeground)
                }
            } else if model.hasScreenAccess {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        TabsPicker(
                            items: AppModel.SourceKind.allCases,
                            selection: $model.sourceKind
                        ) { $0.rawValue }
                        .disabled(model.isRecording)

                        if model.sourceKind == .region {
                            regionRow
                        }

                        thumbnailColumn
                    }
                    .frame(width: 220)
                    .disabled(model.isRecording)

                    selectionPreview
                }
            } else {
                permissionCard
            }
        }
        .frame(maxWidth: .infinity, minHeight: 362, maxHeight: .infinity)
    }

    /// Rounded panel surface used for the preview and placeholder states.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
            .fill(Theme.panel)
            .overlay(content())
    }

    private var regionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Select Region…") { model.pickRegion() }
                    .buttonStyle(.themed(.outline, size: .sm))
                if model.region != nil {
                    Button("Clear") { model.region = nil }
                        .buttonStyle(.themed(.ghost, size: .sm))
                }
            }
            if let region = model.region {
                Text(String(format: "%.0f × %.0f pt at (%.0f, %.0f)",
                            region.width, region.height, region.minX, region.minY))
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mutedForeground)
            } else {
                Text("Drag over the area you want to record.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
    }

    private struct ThumbItem: Identifiable {
        var key: AppModel.ThumbKey
        var label: String
        var selected: Bool
        var action: () -> Void
        var id: AppModel.ThumbKey { key }
    }

    private var thumbItems: (items: [ThumbItem], emptyText: String) {
        switch model.sourceKind {
        case .display, .region:
            return (model.displays.map { display in
                ThumbItem(
                    key: .display(display.displayID),
                    label: displayLabel(display),
                    selected: model.selectedDisplayID == display.displayID,
                    action: { model.selectedDisplayID = display.displayID }
                )
            }, "No displays found.")
        case .window:
            return (model.windows.map { window in
                ThumbItem(
                    key: .window(window.windowID),
                    label: windowLabel(window),
                    selected: model.selectedWindowID == window.windowID,
                    action: { model.selectedWindowID = window.windowID }
                )
            }, "No windows found — open some app windows.")
        }
    }

    private var thumbnailColumn: some View {
        let (items, emptyText) = thumbItems
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                if items.isEmpty {
                    Text(emptyText)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.mutedForeground)
                }
                ForEach(items) { item in
                    Button(action: item.action) {
                        VStack(alignment: .leading, spacing: 6) {
                            thumbnail(for: item)
                            Text(item.label)
                                .font(Theme.font(12))
                                .lineLimit(1)
                                .foregroundStyle(item.selected ? Theme.foreground : Theme.mutedForeground)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(2)
        }
    }

    /// 220×117 thumbnail; the selected one gets the 2px primary border plus
    /// the gloss, matching the Figma "selected display" card.
    private func thumbnail(for item: ThumbItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
        return Group {
            if let cg = model.thumbnails[item.key] {
                Image(decorative: cg, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Theme.panel)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: 220, height: 117)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                item.selected ? Theme.primaryBorder : Theme.border,
                lineWidth: item.selected ? 2 : 1
            )
        )
        .overlay {
            if item.selected {
                // Figma 23:587 — soft sheen plus a 2px white/50% ring just
                // inside the 2px primary border.
                GlossOverlay(shape: shape, ringWidth: 0)
                    .opacity(0.5)
                shape.inset(by: 2)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Large near-live preview of whatever will actually be recorded.
    private var selectionPreview: some View {
        let image: CGImage? = {
            switch model.sourceKind {
            case .display:
                return model.selectedDisplayID.flatMap { model.thumbnails[.display($0)] }
            case .window:
                return model.selectedWindowID.flatMap { model.thumbnails[.window($0)] }
            case .region:
                return model.regionPreview
            }
        }()

        return panel {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                    .padding(16)
            } else {
                Text(model.sourceKind == .region ? "No region selected" : "Nothing selected")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Preview refreshes every ~2s")
    }

    /// Shown instead of the pickers when the current build has no Screen
    /// Recording grant. Nothing here (or anywhere) calls capture APIs until
    /// the user explicitly asks, so the system dialog can't spam.
    private var permissionCard: some View {
        panel {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.mutedForeground)
                Text("Screen Recording permission needed")
                    .font(Theme.font(16, .medium))
                Text("Toggle Crisp on in System Settings. Crisp re-checks automatically every 20 seconds — or hit Check Again. If macOS asks to quit and reopen the app, that's fine: an in-flight recording is finalized safely first.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                if let probeError = model.lastProbeError {
                    Text("Last check: \(probeError)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460)
                }
                HStack(spacing: 8) {
                    Button("Grant Access…") { model.requestAccess() }
                        .buttonStyle(.themed(.primary))
                    Button("Check Again") { model.checkAccessAgain() }
                        .buttonStyle(.themed(.outline))
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .buttonStyle(.themed(.outline))
                    Button("Relaunch Crisp") { model.relaunch() }
                        .buttonStyle(.themed(.ghost))
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
    }

    private func displayLabel(_ display: SCDisplay) -> String {
        let main = CGDisplayIsMain(display.displayID) != 0 ? " (Main)" : ""
        return "\(display.width)×\(display.height)\(main)"
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "App"
        if let title = window.title, !title.isEmpty {
            return "\(app) — \(title)"
        }
        return app
    }

    // MARK: - Recordings

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recordings")
                .font(Theme.font(16, .medium))
                .foregroundStyle(Theme.textSecondary)
            if model.recordings.isEmpty {
                Text("No recordings yet. Masters are saved in ~/Movies/Crisp.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.mutedForeground)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.recordings) { recording in
                            RecordingRow(recording: recording)
                            if recording.id != model.recordings.last?.id {
                                Rectangle()
                                    .fill(Theme.border)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
    }
}

private struct RecordingRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let recording: Recording

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 16) {
                Text(recording.name)
                    .font(Theme.font(16))
                    .monospacedDigit()
                if recording.hasExport && model.exportProgress[recording.folder] == nil {
                    Text("Exported with zooms")
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                }
            }
            Spacer()

            if let fraction = model.exportProgress[recording.folder] {
                ExportProgressControls(fraction: fraction, width: 299) {
                    model.cancelExport(recording)
                }
            } else {
                Button("Edit zooms") {
                    openWindow(value: recording.folder)
                }
                .buttonStyle(.themed(.outline, size: .sm))
                Button("Export with zooms") {
                    model.export(recording)
                }
                .buttonStyle(.themed(.primary, size: .sm))
                Button {
                    model.reveal(recording)
                } label: {
                    Icon(name: "folder-open-duotone", size: 16, fallback: "folder")
                }
                .buttonStyle(.themed(.outline, size: .sm, iconOnly: true))
                .help("Reveal in Finder")
                Button {
                    model.delete(recording)
                } label: {
                    Icon(name: "trash-duotone", size: 16, fallback: "trash")
                        .foregroundStyle(Theme.destructive)
                }
                .buttonStyle(.themed(.outline, size: .sm, iconOnly: true))
                .help("Move to Trash")
            }
        }
        .frame(height: 28)
    }
}

private struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(start))
            Text(String(format: "● %d:%02d", elapsed / 60, elapsed % 60))
                .font(Theme.font(16, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.destructive)
        }
    }
}
