import SwiftUI
import AppKit
import ScreenCaptureKit

/// Main window, laid out after the Crisp v1 Figma frame (68:11635): titlebar,
/// then a library sidebar (wordmark, search, recordings; 328pt by default,
/// resizable at its border) beside the capture column (source toolbar, large preview, Record / Screenshot row).
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage("screenshot.format") private var screenshotFormatRaw = ScreenshotFormat.png16.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var libraryFilter: LibraryFilter = .all

    /// Sidebar width, dragged at its trailing border and remembered across
    /// launches. Figma's 328 is the default; the capture column keeps the
    /// space the Figma frame gives it at minimum window size.
    @AppStorage("sidebar.width") private var sidebarWidth: Double = Self.defaultSidebarWidth
    @State private var sidebarDragStart: Double?
    @State private var resizeCursorPushed = false
    private static let defaultSidebarWidth: Double = 328
    private static let sidebarWidthRange: ClosedRange<Double> = 240...480
    private static let captureColumnMinWidth: Double = 926 - 328

    var body: some View {
        VStack(spacing: 0) {
            // The window uses `.hiddenTitleBar`; this is its titlebar.
            TitlebarStrip(title: "Crisp")
            HStack(spacing: 0) {
                sidebar
                captureColumn
            }
        }
        .font(Theme.font(.body14))
        .foregroundStyle(Theme.foreground)
        .frame(minWidth: clampedSidebarWidth + Self.captureColumnMinWidth, minHeight: 596)
        .ignoresSafeArea(edges: .top)
        .background(Theme.background.ignoresSafeArea())
        .background(WindowChrome())
        .tooltipHost()
        .dropdownHost()
        .onAppear { model.refresh() }
    }

    // MARK: - Capture column (Figma 68:11643)

    /// Toolbar, preview and the action row: 16pt vertical padding, 16pt gaps;
    /// the toolbar and preview are inset 16, the action row 24.
    private var captureColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
                .padding(.horizontal, 16)
            sourcesSection
                .padding(.horizontal, 16)
            actionRow
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Toolbar

    /// Source kind | target | codec … appearance (Figma 68:11644).
    private var toolbar: some View {
        HStack(spacing: 16) {
            sourceKindSelect
            sourceTargetSelect
            codecSelect
            Spacer(minLength: 16)
            appearanceToggle
        }
        .frame(height: 32)
    }

    private var appearanceToggle: some View {
        let isDark = colorScheme == .dark
        return Button {
            AppAppearance.toggle()
        } label: {
            Icon(
                name: isDark ? "sun-duotone" : "moon-duotone",
                size: 16,
                fallback: isDark ? "sun.max" : "moon"
            )
        }
        .buttonStyle(.themed(.outline, size: .md, iconOnly: true))
        .tooltip(isDark ? "Switch to light mode" : "Switch to dark mode")
    }

    // MARK: - Action row (Record / Screenshot)

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                recordButton
                screenshotSplitButton
            }
            .frame(height: 36)

            if case .error(let message) = model.state {
                Text(message)
                    .font(Theme.font(.body14))
                    .foregroundStyle(Theme.destructive)
                    .textSelection(.enabled)
            } else if let toast = model.toast {
                Text(toast)
                    .font(Theme.font(.body14))
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
            HStack(spacing: 4) {
                if model.isRecording {
                    Icon(name: "stop-fill", size: 16, fallback: "stop.fill")
                    Text("Stop Recording")
                } else {
                    Icon(name: "record", size: 16, fallback: "record.circle")
                    Text("Record")
                }
            }
        }
        .buttonStyle(.themed(.primary, size: .lg, fullWidth: true, tint: Theme.record))
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.hasScreenAccess)
        .tooltip("Record the selected source at native Retina resolution, 60fps (⌘R). Clicks are logged for zoom animation.")
    }

    /// ButtonGroup/Split: primary action + separator + dropdown for the format.
    private var screenshotSplitButton: some View {
        HStack(spacing: -1) {
            Button {
                Task {
                    await model.screenshot(
                        format: ScreenshotFormat(rawValue: screenshotFormatRaw) ?? .png16
                    )
                }
            } label: {
                HStack(spacing: 6) {
                    Icon(name: "camera-duotone", size: 16, fallback: "camera")
                    Text("Screenshot")
                }
            }
            .buttonStyle(.themed(.outline, size: .lg, fullWidth: true, corners: .leading(Theme.radiusSm)))
            .tooltip("Capture the selected source as a high-bit-depth screenshot. Saved 10-bit to ~/Pictures/Crisp.")

            ButtonGroupSeparator(height: 32)

            DropdownButton(
                id: "screenshot.format", edge: .top, alignment: .trailing,
                style: { _ in .themed(.outline, size: .lg, iconOnly: true, corners: .trailing(Theme.radiusSm)) },
                items: {
                    ScreenshotFormat.allCases.map { format in
                        DropdownItem(id: format.rawValue, label: format.rawValue,
                                     checked: screenshotFormatRaw == format.rawValue) {
                            screenshotFormatRaw = format.rawValue
                        }
                    }
                }
            ) { _ in
                Icon(name: "caret-down", size: 16, fallback: "chevron.down")
            }
            .tooltip("Screenshot format")
        }
        .frame(maxWidth: .infinity)
        .disabled(!model.hasScreenAccess || model.isRecording)
    }

    private var codecSelect: some View {
        DropdownButton(
            id: "master.codec", alignment: .trailing,
            items: {
                MasterCodec.allCases.map { codec in
                    DropdownItem(
                        id: codec.rawValue, label: codec.rawValue,
                        checked: model.codec == codec, detail: codec.detail
                    ) {
                        model.codec = codec
                    }
                }
            }
        ) { _ in
            SelectTriggerLabel(text: model.codec.rawValue, size: .md)
        }
        .fixedSize()
        .disabled(model.isRecording)
        .tooltip("Master recording codec")
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        Group {
            if !model.accessChecked {
                panel {
                    ProgressView("Checking Screen Recording access…")
                        .font(Theme.font(.body12))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .frame(maxWidth: .infinity, minHeight: 431, maxHeight: .infinity)
            } else if model.hasScreenAccess {
                VStack(alignment: .leading, spacing: 24) {
                    if model.sourceKind == .region {
                        regionRow
                            .disabled(model.isRecording)
                    }
                    selectionPreview
                        .frame(maxWidth: .infinity, minHeight: 431, maxHeight: .infinity)
                }
            } else {
                permissionCard
                    .frame(maxWidth: .infinity, minHeight: 431, maxHeight: .infinity)
            }
        }
    }

    /// Source kind tabs (Figma IconTabList).
    private var sourceKindSelect: some View {
        IconTabsPicker(
            items: Array(AppModel.SourceKind.allCases),
            selection: $model.sourceKind,
            icon: { kind in
                switch kind {
                case .display: "desktop-duotone"
                case .window: "app-window-duotone"
                case .region: "region"
                }
            },
            fallback: { kind in
                switch kind {
                case .display: "display"
                case .window: "macwindow"
                case .region: "viewfinder"
                }
            },
            label: \.rawValue
        )
        .tooltip("Capture a full display, a single window, or a region")
        .disabled(model.isRecording)
    }

    private var sourceTargetSelect: some View {
        let (items, placeholder) = thumbItems
        let isWindow = model.sourceKind == .window
        // The Window menu is tabbed (App Windows / Chrome Tabs), so it stays
        // openable even when the current list is empty.
        let header: (() -> AnyView)? = isWindow ? { AnyView(windowPickerTabs) } : nil
        return DropdownButton(
            id: "source.target",
            header: header,
            placeholder: { placeholder },
            wide: true,
            items: {
                items.map { item in
                    DropdownItem(
                        id: item.id,
                        label: item.label,
                        checked: item.selected,
                        detail: item.detail,
                        showsThumbnail: true,
                        thumbnail: item.thumbnail,
                        placeholderSymbol: item.placeholderSymbol,
                        action: item.action
                    )
                }
            }
        ) { _ in
            SelectTriggerLabel(text: sourceTargetLabel, size: .md, maxTextWidth: 200)
        }
        .fixedSize()
        .disabled((!isWindow && items.isEmpty) || model.isRecording)
        .tooltip(sourceTargetLabel)
    }

    /// Header of the Window target menu: plain app windows, or Chrome's tabs.
    /// Tabs are listed over Apple Events, so Chrome is only asked when the
    /// Chrome list is actually shown.
    private var windowPickerTabs: some View {
        TabsPicker(
            items: Array(AppModel.WindowPickerMode.allCases),
            selection: $model.windowPickerMode,
            label: \.rawValue
        )
        .onAppear {
            if model.windowPickerMode == .chrome { model.loadChromeTabs() }
        }
        .onChange(of: model.windowPickerMode) { _, mode in
            if mode == .chrome { model.loadChromeTabs() }
        }
    }

    private var sourceTargetLabel: String {
        if model.sourceKind == .window {
            if let tab = model.selectedChromeTab { return "Chrome — \(tab.displayTitle)" }
            if let window = model.selectedWindow { return windowLabel(window) }
            return model.windows.isEmpty ? "No windows found" : "Select a window"
        }
        let (items, placeholder) = thumbItems
        if let selected = items.first(where: \.selected) { return selected.label }
        return items.isEmpty ? placeholder.text : "Select a display"
    }

    /// Rounded panel surface used for the placeholder states.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
            .fill(Theme.panel)
            .overlay(content())
    }

    private var regionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Select Region…") { model.pickRegion() }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Drag out the part of the screen to capture")
                if model.region != nil {
                    Button("Clear") { model.region = nil }
                        .buttonStyle(.themed(.ghost, size: .xs))
                        .tooltip("Forget the region and capture the whole display")
                }
            }
            if let region = model.region {
                Text(String(format: "%.0f × %.0f pt at (%.0f, %.0f)",
                            region.width, region.height, region.minX, region.minY))
                    .font(Theme.font(.body12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mutedForeground)
            } else {
                Text("Drag over the area you want to record.")
                    .font(Theme.font(.body12))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
    }

    private struct ThumbItem: Identifiable {
        var id: String
        var label: String
        var detail: String? = nil
        var thumbnail: CGImage?
        var placeholderSymbol: String? = nil
        var selected: Bool
        var action: () -> Void
    }

    private var thumbItems: (items: [ThumbItem], placeholder: DropdownPlaceholder) {
        switch model.sourceKind {
        case .display, .region:
            return (model.displays.map { display in
                ThumbItem(
                    id: "display-\(display.displayID)",
                    label: displayLabel(display),
                    thumbnail: model.thumbnails[.display(display.displayID)],
                    selected: model.selectedDisplayID == display.displayID,
                    action: { model.selectedDisplayID = display.displayID }
                )
            }, DropdownPlaceholder(text: "No displays found."))
        case .window:
            switch model.windowPickerMode {
            case .apps:
                return (model.windows.map { window in
                    ThumbItem(
                        id: "window-\(window.windowID)",
                        label: windowLabel(window),
                        thumbnail: model.thumbnails[.window(window.windowID)],
                        selected: model.selectedChromeTab == nil && model.selectedWindowID == window.windowID,
                        action: { model.selectWindow(window.windowID) }
                    )
                }, DropdownPlaceholder(text: "No windows found — open some app windows."))
            case .chrome:
                return (model.chromeTabs.map { tab in
                    // Only the visible tab of each window has a live thumbnail.
                    let window = model.chromeWindow(for: tab)
                    return ThumbItem(
                        id: "chrome-\(tab.id)",
                        label: tab.displayTitle,
                        detail: tab.host,
                        thumbnail: window.flatMap { model.thumbnails[.window($0.windowID)] },
                        placeholderSymbol: "globe",
                        selected: model.selectedChromeTab?.id == tab.id,
                        action: { model.selectChromeTab(tab) }
                    )
                }, chromePlaceholder)
            }
        }
    }

    private var chromePlaceholder: DropdownPlaceholder {
        switch model.chromeTabsStatus {
        case .idle, .loading:
            return DropdownPlaceholder(text: "Loading Chrome tabs…")
        case .loaded:
            return DropdownPlaceholder(
                text: "No tabs open in Google Chrome.",
                actionTitle: "Refresh", action: { model.loadChromeTabs() }
            )
        case .notRunning:
            return DropdownPlaceholder(
                text: "Google Chrome isn't running.",
                actionTitle: "Try Again", action: { model.loadChromeTabs() }
            )
        case .notPermitted:
            return DropdownPlaceholder(
                text: "Crisp needs permission to control Google Chrome. Allow it under Privacy & Security → Automation, then switch tabs here to retry.",
                actionTitle: "Open System Settings",
                action: { NSWorkspace.shared.open(ChromeBridge.automationSettingsURL) }
            )
        case .failed(let message):
            return DropdownPlaceholder(
                text: message,
                actionTitle: "Try Again", action: { model.loadChromeTabs() }
            )
        }
    }

    /// Large near-live preview of whatever will actually be recorded.
    private var selectionPreview: some View {
        let image: CGImage? = {
            if let live = model.livePreview { return live }
            switch model.sourceKind {
            case .display:
                return model.selectedDisplayID.flatMap { model.thumbnails[.display($0)] }
            case .window:
                return model.selectedWindowID.flatMap { model.thumbnails[.window($0)] }
            case .region:
                return nil
            }
        }()
        let shape = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)

        return shape.fill(Color.black)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(model.sourceKind == .region ? "No region selected" : "Nothing selected")
                        .font(Theme.font(.body12))
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
            .clipShape(shape)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tooltip("Preview refreshes every ~2s")
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
                    .font(Theme.font(.label14))
                Text("Toggle Crisp on in System Settings, then hit Check Again. If macOS asks to quit and reopen the app, that's fine: an in-flight recording is finalized safely first.")
                    .font(Theme.font(.body12))
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                if let probeError = model.lastProbeError {
                    Text("Last check: \(probeError)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460)
                }
                HStack(spacing: 8) {
                    Button("Grant Access…") { model.requestAccess() }
                        .buttonStyle(.themed(.primary, size: .xs))
                        .tooltip("Ask macOS for Screen Recording permission")
                    Button("Check Again") { model.checkAccessAgain() }
                        .buttonStyle(.themed(.outline, size: .xs))
                        .tooltip("Re-check whether Screen Recording has been granted")
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .buttonStyle(.themed(.outline, size: .xs))
                    .tooltip("Open Privacy & Security → Screen Recording")
                    Button("Relaunch Crisp") { model.relaunch() }
                        .buttonStyle(.themed(.ghost, size: .xs))
                        .tooltip("Restart Crisp so a new permission takes effect")
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
    }

    private func displayLabel(_ display: SCDisplay) -> String {
        "\(displayName(display)) \(display.width)×\(display.height)"
    }

    private func displayName(_ display: SCDisplay) -> String {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[numberKey] as? NSNumber)?.uint32Value == display.displayID
        }) {
            return screen.localizedName
        }
        return CGDisplayIsMain(display.displayID) != 0 ? "Built-in Display" : "Display"
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "App"
        if let title = window.title, !title.isEmpty {
            return "\(app) — \(title)"
        }
        return app
    }

    // MARK: - Library sidebar (Figma 76:13095)

    /// 328pt column with a `--border` right edge: wordmark, then the search
    /// row and the recordings list (16pt inset, 24pt between).
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            Wordmark()
            VStack(alignment: .leading, spacing: 10) {
                searchRow
                recordingsList
            }
        }
        .padding(16)
        .frame(width: clampedSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            sidebarResizeHandle
        }
    }

    private var clampedSidebarWidth: Double {
        min(max(sidebarWidth, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
    }

    /// Invisible 8pt strip straddling the sidebar's border: drag to resize,
    /// double-click to snap back to the Figma width.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in
                if inside, !resizeCursorPushed {
                    NSCursor.resizeLeftRight.push()
                    resizeCursorPushed = true
                } else if !inside, resizeCursorPushed, sidebarDragStart == nil {
                    NSCursor.pop()
                    resizeCursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = sidebarDragStart ?? clampedSidebarWidth
                        sidebarDragStart = start
                        let proposed = start + value.translation.width
                        sidebarWidth = min(
                            max(proposed, Self.sidebarWidthRange.lowerBound),
                            Self.sidebarWidthRange.upperBound
                        )
                    }
                    .onEnded { _ in
                        sidebarDragStart = nil
                        if resizeCursorPushed {
                            NSCursor.pop()
                            resizeCursorPushed = false
                        }
                    }
            )
            .onTapGesture(count: 2) {
                sidebarWidth = Self.defaultSidebarWidth
            }
    }

    /// Search field (h32) + 32pt ghost filter with a 16pt funnel, same
    /// control size as the recording-row actions.
    private var searchRow: some View {
        HStack(spacing: 4) {
            searchField
            DropdownButton(
                id: "library.filter", alignment: .trailing,
                style: { _ in .themed(.ghost, size: .md, iconOnly: true) },
                items: {
                    LibraryFilter.allCases.map { filter in
                        DropdownItem(id: filter.rawValue, label: filter.rawValue,
                                     checked: libraryFilter == filter) {
                            libraryFilter = filter
                        }
                    }
                }
            ) { _ in
                Icon(name: "funnel", size: 16, fallback: "line.3.horizontal.decrease")
            }
            .tooltip("Filter recordings")
        }
        .frame(height: 32)
    }

    /// Figma 75:12061: `--border` at 50% with the `--input` stroke, 6pt
    /// radius, 8pt inset, 16pt magnifying glass, Body/12 placeholder.
    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
        return HStack(spacing: 6) {
            Icon(name: "magnifying-glass", size: 16, fallback: "magnifyingglass")
                .foregroundStyle(Theme.mutedForeground)
            TextField("Find a recording", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.font(.body12))
                .foregroundStyle(Theme.foreground)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Icon(name: "x", size: 16, fallback: "xmark")
                }
                .buttonStyle(.themed(.ghost, size: .xs, iconOnly: true))
                .tooltip("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background {
            shape.fill(Theme.border.opacity(0.5))
                .overlay(shape.strokeBorder(Theme.input, lineWidth: 1))
        }
        .clipShape(shape)
    }

    private var filteredRecordings: [Recording] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return model.recordings.filter { recording in
            guard query.isEmpty || recording.name.localizedCaseInsensitiveContains(query) else {
                return false
            }
            switch libraryFilter {
            case .all: return true
            case .exported: return recording.hasExport
            case .unexported: return !recording.hasExport
            }
        }
    }

    /// Rows 8pt apart with 1pt `--border` rules between them (Figma 76:13108).
    private var recordingsList: some View {
        let recordings = filteredRecordings
        return Group {
            if model.recordings.isEmpty {
                Text("No recordings yet. Masters are saved in ~/Movies/Crisp.")
                    .font(Theme.font(.body12))
                    .foregroundStyle(Theme.mutedForeground)
            } else if recordings.isEmpty {
                Text("No recordings match.")
                    .font(Theme.font(.body12))
                    .foregroundStyle(Theme.mutedForeground)
            } else {
                // The scroll view reaches into the sidebar inset by the
                // rename box's text inset, so the box (offset left to keep
                // the name's glyphs in place) isn't clipped at the edge.
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recordings) { recording in
                            RecordingRow(recording: recording)
                            if recording.id != recordings.last?.id {
                                Rectangle()
                                    .fill(Theme.border)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.leading, RenameNameField.horizontalInset)
                }
                .padding(.leading, -RenameNameField.horizontalInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Sidebar filter menu behind the funnel button.
private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All recordings"
    case exported = "With exports"
    case unexported = "Not yet exported"

    var id: String { rawValue }
}

/// "1 Zoom", "3 Pans", "2 Exports".
private func countLabel(_ n: Int, _ noun: String) -> String {
    "\(n) \(noun)\(n == 1 ? "" : "s")"
}

/// Brand-green zoom / pan counts (Figma 75:11919).
private struct ZoomPanTag: View {
    let zoomCount: Int
    let stepCount: Int

    var body: some View {
        HStack(spacing: 10) {
            if zoomCount > 0 {
                Text(countLabel(zoomCount, "Zoom"))
            }
            if stepCount > 0 {
                Text(countLabel(stepCount, "Step"))
            }
        }
        .padding(.horizontal, 4)
        .foregroundStyle(Theme.brand)
        .background(Theme.brandSelected, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Flat library row (Figma 76:13109 / 76:13499): name (double-click to
/// rename), hover 32pt actions, then a Body/12 line — "MOV 50.3MB" plus
/// the zoom/pan tag.
private struct RecordingRow: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var hovering = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var clickMonitor: Any?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    var body: some View {
        let summary = recording.summary
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if renaming {
                    renameField
                } else {
                    Text(recording.name)
                        .font(Theme.font(.body14))
                        .monospacedDigit()
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: beginRename)
                }
                Spacer(minLength: 8)
                if hovering || renaming {
                    RecordingActionButtons(recording: recording)
                }
            }
            .frame(height: 32)
            .onHover { hovering = $0 }

            HStack(spacing: 8) {
                Text(fileInfo)
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                if summary.zoomCount > 0 || summary.stepCount > 0 {
                    ZoomPanTag(zoomCount: summary.zoomCount, stepCount: summary.stepCount)
                        .fixedSize()
                }
            }
            .font(Theme.font(.body12))
            .monospacedDigit()
            .frame(height: 16, alignment: .leading)

            if let fraction = model.exportProgress[recording.folder] {
                ExportProgressControls(
                    fraction: fraction, size: .md,
                    cancelIcon: "x", cancelVariant: .ghost
                ) {
                    model.cancelExport(recording)
                }
                .frame(height: 32)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// "MOV 50.3MB" — newest file's format and compact size.
    private var fileInfo: String {
        let summary = recording.summary
        guard let size = summary.fileSize else { return summary.format }
        let labeled = Self.sizeFormatter.string(fromByteCount: size)
            .replacingOccurrences(of: " ", with: "")
        return "\(summary.format) \(labeled)"
    }

    /// Figma 76:13501: fixed 152×24 box, `--background` fill with the
    /// `--input` hairline, 4pt radius, 4pt side padding, Body/14. The AppKit
    /// cell insets the field editor itself so the selection band and caret
    /// stay inside the padding (SwiftUI padding is ignored by the editor).
    /// The box is shifted left by its text inset so the glyphs stay exactly
    /// where the static name sits — entering rename must not move the text.
    private var renameField: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return RenameNameField(text: $draftName, onSubmit: commitRename, onCancel: cancelRename)
            .frame(width: RenameNameField.size.width, height: RenameNameField.size.height)
            .background {
                shape.fill(Theme.background)
                    .overlay(shape.strokeBorder(Theme.input, lineWidth: 1))
            }
            .clipShape(shape)
            .offset(x: -RenameNameField.horizontalInset)
    }

    private func beginRename() {
        if let reason = model.renameBlocker(recording) {
            model.showToast(reason)
            return
        }
        draftName = recording.name
        renaming = true
        installClickAway()
    }

    private func commitRename() {
        guard renaming else { return }
        removeClickAway()
        renaming = false
        model.rename(recording, to: draftName)
    }

    private func cancelRename() {
        removeClickAway()
        renaming = false
        draftName = recording.name
    }

    private func installClickAway() {
        removeClickAway()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            var view = event.window?.contentView?.hitTest(event.locationInWindow)
            var inField = false
            while let current = view {
                if current is NSTextView || current is NSTextField {
                    inField = true
                    break
                }
                view = current.superview
            }
            if !inField {
                DispatchQueue.main.async { commitRename() }
            }
            return event
        }
    }

    private func removeClickAway() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }
}

private struct RecordingActionButtons: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let recording: Recording

    var body: some View {
        let exporting = model.exportProgress[recording.folder] != nil
        HStack(spacing: 1) {
            Button {
                openWindow(value: recording.folder)
            } label: {
                Icon(name: "pencil-duotone", size: 16, fallback: "pencil")
            }
            .buttonStyle(.themed(.ghost, size: .md, iconOnly: true))
            .tooltip("Edit zooms")
            Button {
                model.export(recording)
            } label: {
                Icon(name: "export-duotone", size: 16, fallback: "square.and.arrow.up")
            }
            .buttonStyle(.themed(.ghost, size: .md, iconOnly: true))
            .disabled(exporting)
            .tooltip("Export with zooms as \(model.exportFormat.rawValue). Earlier exports are kept.")
            Button {
                model.reveal(recording)
            } label: {
                Icon(name: "folder-open-duotone", size: 16, fallback: "folder")
            }
            .buttonStyle(.themed(.ghost, size: .md, iconOnly: true))
            .tooltip("Reveal in Finder")
            Button {
                model.delete(recording)
            } label: {
                Icon(name: "trash-duotone", size: 16, fallback: "trash")
            }
            .buttonStyle(.themed(.ghost, size: .md, iconOnly: true))
            .tooltip("Move recording and all exports to Trash")
        }
    }
}

/// ButtonGroup/Split: "Export with zooms" + dropdown choosing the file type.
/// The chosen format is `AppModel.exportFormat` (persisted).
struct ExportSplitButton: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var size: ControlSizeToken = .xs
    /// Distinguishes this button's dropdown when several are in one window.
    var menuID: String = "main"
    /// Where the format menu opens relative to the button.
    var edge: VerticalEdge = .bottom
    let action: () -> Void

    var body: some View {
        HStack(spacing: -1) {
            Button(title, action: action)
                .buttonStyle(.themed(.primary, size: size, corners: .leading(Theme.radiusMd)))
                .tooltip("Render the zoom plan to a new \(model.exportFormat.rawValue) file next to the master. Earlier exports are kept.")
            ButtonGroupSeparator(height: size.height)
            DropdownButton(
                id: "export.format.\(menuID)", edge: edge, alignment: .trailing,
                style: { _ in .themed(.primary, size: size, iconOnly: true, corners: .trailing(Theme.radiusMd)) },
                items: {
                    ExportFormat.allCases.map { format in
                        DropdownItem(id: format.rawValue, label: format.rawValue,
                                     checked: model.exportFormat == format) {
                            model.exportFormat = format
                        }
                    }
                }
            ) { _ in
                Icon(name: "caret-down", size: 16, fallback: "chevron.down")
            }
            .tooltip("Export file type: \(model.exportFormat.rawValue)")
        }
    }
}
