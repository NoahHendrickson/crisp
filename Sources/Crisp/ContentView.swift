import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage(ZoomPlanner.Config.levelKey) private var zoomLevel = 1.8
    @AppStorage(ZoomPlanner.Config.leadInKey) private var zoomLeadIn = 0.7
    @AppStorage(ZoomPlanner.Config.inDurationKey) private var zoomInDuration = 0.5
    @AppStorage(ZoomPlanner.Config.holdAfterKey) private var zoomHoldAfter = 1.3
    @AppStorage("screenshot.format") private var screenshotFormatRaw = ScreenshotFormat.png16.rawValue
    @State private var zoomSettingsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            recorderPanel
            Divider()
            recordingsList
        }
        .frame(minWidth: 560, minHeight: 680)
        .onAppear { model.refresh() }
    }

    /// True in the Crisp Dev build (separate bundle id) — shown in orange so
    /// the two side-by-side builds are unmistakable.
    private var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? true
    }

    private var recorderPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isDevBuild ? "Crisp Dev" : "Crisp")
                    .font(.title2.bold())
                    .foregroundStyle(isDevBuild ? Color.orange : Color.primary)
                if isDevBuild {
                    Text("DEV BUILD")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if case .recording(let start) = model.state {
                    RecordingTimer(start: start)
                }
            }

            if case .error(let message) = model.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !model.accessChecked {
                HStack {
                    Spacer()
                    ProgressView("Checking Screen Recording access…")
                    Spacer()
                }
                .padding(.vertical, 60)
            } else if model.hasScreenAccess {
                Picker("", selection: $model.sourceKind) {
                    ForEach(AppModel.SourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRecording)

                sourcePicker
                    .disabled(model.isRecording)

                selectionPreview
            } else {
                permissionCard
            }

            zoomSettings

            HStack(spacing: 12) {
                Picker("Codec", selection: $model.codec) {
                    ForEach(MasterCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .frame(maxWidth: 220)
                .disabled(model.isRecording)

                Spacer()

                Menu {
                    Picker("Format", selection: $screenshotFormatRaw) {
                        ForEach(ScreenshotFormat.allCases) { format in
                            Text(format.rawValue).tag(format.rawValue)
                        }
                    }
                } label: {
                    Label("Screenshot", systemImage: "camera")
                } primaryAction: {
                    Task {
                        await model.screenshot(
                            format: ScreenshotFormat(rawValue: screenshotFormatRaw) ?? .png16
                        )
                    }
                }
                .fixedSize()
                .disabled(!model.hasScreenAccess || model.isRecording)
                .help("Capture the selected source as a high-bit-depth screenshot (click for options)")

                Button {
                    Task {
                        if model.isRecording {
                            await model.stopRecording()
                        } else {
                            await model.startRecording()
                        }
                    }
                } label: {
                    Label(
                        model.isRecording ? "Stop Recording" : "Start Recording",
                        systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .frame(minWidth: 150)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .controlSize(.large)
                .tint(model.isRecording ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Native Retina resolution, 60fps, cursor re-drawn at export. Clicks are logged for zoom animation. Screenshots save 10-bit to ~/Pictures/Crisp. Previews refresh every ~2s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// Knobs for the zoom camera. Applied when "Export with Zooms" runs — you
    /// can tweak and re-export the same recording as often as you like.
    private var zoomSettings: some View {
        DisclosureGroup(isExpanded: $zoomSettingsExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                zoomRow("Zoom level", value: $zoomLevel, range: 1.2...3.0,
                        format: "%.1f×",
                        help: "How far the camera pushes in on a click")
                zoomRow("Start early", value: $zoomLeadIn, range: 0.2...1.5,
                        format: "%.2fs",
                        help: "How long before a click the zoom begins — raise this if zooms feel late")
                zoomRow("Zoom-in time", value: $zoomInDuration, range: 0.25...1.2,
                        format: "%.2fs",
                        help: "How long the push-in takes")
                zoomRow("Hold after", value: $zoomHoldAfter, range: 0.5...3.0,
                        format: "%.1fs",
                        help: "How long to stay zoomed after the last click")
            }
            .padding(.top, 6)
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    let defaults = UserDefaults.standard
                    for key in [ZoomPlanner.Config.levelKey, ZoomPlanner.Config.leadInKey,
                                ZoomPlanner.Config.inDurationKey, ZoomPlanner.Config.holdAfterKey] {
                        defaults.removeObject(forKey: key)
                    }
                    let fresh = ZoomPlanner.Config()
                    zoomLevel = fresh.zoomLevel
                    zoomLeadIn = fresh.leadIn
                    zoomInDuration = fresh.zoomInDuration
                    zoomHoldAfter = fresh.holdAfter
                }
                .buttonStyle(.link)
            }
        } label: {
            Text("Zoom Settings")
                .font(.callout.weight(.medium))
        }
    }

    private func zoomRow(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        format: String, help: String
    ) -> some View {
        GridRow {
            Text(title)
                .gridColumnAlignment(.leading)
            Slider(value: value, in: range)
                .frame(minWidth: 180)
                .help(help)
            Text(String(format: format, value.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .help(help)
    }

    /// Shown instead of the pickers when the current build has no Screen
    /// Recording grant. Nothing here (or anywhere) calls capture APIs until
    /// the user explicitly asks, so the system dialog can't spam.
    private var permissionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Screen Recording permission needed")
                .font(.headline)
            Text("Toggle Crisp on in System Settings. Crisp re-checks automatically every 20 seconds — or hit Check Again. If macOS asks to quit and reopen the app, that's fine: an in-flight recording is finalized safely first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let probeError = model.lastProbeError {
                Text("Last check: \(probeError)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 12) {
                Button("Grant Access…") { model.requestAccess() }
                    .buttonStyle(.borderedProminent)
                Button("Check Again") { model.checkAccessAgain() }
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("Relaunch Crisp") { model.relaunch() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Source pickers

    @ViewBuilder
    private var sourcePicker: some View {
        switch model.sourceKind {
        case .display:
            thumbnailRow(
                items: model.displays.map { display in
                    ThumbItem(
                        key: .display(display.displayID),
                        label: displayLabel(display),
                        selected: model.selectedDisplayID == display.displayID,
                        action: { model.selectedDisplayID = display.displayID }
                    )
                },
                emptyText: "No displays found."
            )
        case .window:
            thumbnailRow(
                items: model.windows.map { window in
                    ThumbItem(
                        key: .window(window.windowID),
                        label: windowLabel(window),
                        selected: model.selectedWindowID == window.windowID,
                        action: { model.selectedWindowID = window.windowID }
                    )
                },
                emptyText: "No windows found — open some app windows."
            )
        case .region:
            VStack(alignment: .leading, spacing: 8) {
                thumbnailRow(
                    items: model.displays.map { display in
                        ThumbItem(
                            key: .display(display.displayID),
                            label: displayLabel(display),
                            selected: model.selectedDisplayID == display.displayID,
                            action: { model.selectedDisplayID = display.displayID }
                        )
                    },
                    emptyText: "No displays found."
                )
                HStack(spacing: 10) {
                    Button("Select Region…") {
                        model.pickRegion()
                    }
                    if let region = model.region {
                        Text(String(format: "%.0f × %.0f pt at (%.0f, %.0f)",
                                    region.width, region.height, region.minX, region.minY))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Clear") { model.region = nil }
                            .buttonStyle(.link)
                    } else {
                        Text("Drag over the area you want to record.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
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

    private func thumbnailRow(items: [ThumbItem], emptyText: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if items.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .frame(height: 96)
                }
                ForEach(items) { item in
                    VStack(spacing: 4) {
                        Group {
                            if let cg = model.thumbnails[item.key] {
                                Image(decorative: cg, scale: 2)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                                    .overlay(ProgressView().controlSize(.small))
                            }
                        }
                        .frame(width: 150, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    item.selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: item.selected ? 2.5 : 1
                                )
                        )
                        Text(item.label)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 150)
                            .foregroundStyle(item.selected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: item.action)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Large near-live preview of whatever will actually be recorded.
    @ViewBuilder
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

        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Group {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay(
                            Text(model.sourceKind == .region ? "No region selected" : "Nothing selected")
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
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

    private var recordingsList: some View {
        List {
            Section("Recordings") {
                if model.recordings.isEmpty {
                    Text("No recordings yet. Masters are saved in ~/Movies/Crisp.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recordings) { recording in
                    RecordingRow(recording: recording)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct RecordingRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .font(.body.monospacedDigit())
                if recording.hasExport {
                    Text("Exported")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()

            if let fraction = model.exportProgress[recording.folder] {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button("Edit Zooms") {
                    openWindow(value: recording.folder)
                }
                Button("Export with Zooms") {
                    model.export(recording)
                }
                Button {
                    model.reveal(recording)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                Button(role: .destructive) {
                    model.delete(recording)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Move to Trash")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(start))
            Text(String(format: "● %d:%02d", elapsed / 60, elapsed % 60))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.red)
        }
    }
}
