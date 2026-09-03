import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

@MainActor
final class AppModel: ObservableObject {

    static let shared = AppModel()

    /// Append a line to ~/Library/Logs/Crisp.log (survives crashes; greppable).
    nonisolated static func log(_ message: String) {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Crisp.log")
        let fmt = ISO8601DateFormatter()
        let line = "\(fmt.string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    enum State: Equatable {
        case idle
        case recording(start: Date)
        case error(String)
    }

    struct RecordingOutcome {
        var folder: URL?
        var error: String?
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case display = "Display"
        case window = "Window"
        case region = "Region"
        var id: String { rawValue }
    }

    enum ThumbKey: Hashable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    /// The two lists in the Window target menu: plain app windows, or Chrome tabs.
    enum WindowPickerMode: String, CaseIterable, Identifiable {
        case apps = "App Windows"
        case chrome = "Chrome Tabs"
        var id: String { rawValue }
    }

    enum ChromeTabsStatus: Equatable {
        case idle
        case loading
        case loaded
        case notRunning
        case notPermitted
        case failed(String)
    }

    @Published var state: State = .idle
    /// Determined by actually probing ScreenCaptureKit once at launch — the
    /// CGPreflight* legacy check reports false negatives on modern macOS even
    /// when the "Screen & System Audio Recording" grant is in place.
    @Published var hasScreenAccess = false
    /// False until the first probe completes (UI shows a spinner meanwhile).
    @Published var accessChecked = false
    @Published var sourceKind: SourceKind = .display {
        didSet { if oldValue != sourceKind { scheduleLivePreview() } }
    }
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID? {
        didSet { if oldValue != selectedDisplayID { scheduleLivePreview() } }
    }
    @Published var selectedWindowID: CGWindowID? {
        didSet { if oldValue != selectedWindowID { scheduleLivePreview() } }
    }
    @Published var windowPickerMode: WindowPickerMode = .apps
    @Published var chromeTabs: [ChromeTab] = []
    @Published var chromeTabsStatus: ChromeTabsStatus = .idle
    /// Set when the selected window was chosen as a Chrome tab. ScreenCaptureKit
    /// records the window, so the tab is re-activated right before recording.
    @Published var selectedChromeTab: ChromeTab?
    private var chromeListTask: Task<Void, Never>?
    /// Region in points, top-left origin, local to the selected display.
    @Published var region: CGRect? {
        didSet { if oldValue != region { scheduleLivePreview() } }
    }
    @Published var codec: MasterCodec = .hevc10
    /// Container/codec for "Export with zooms"; persisted across launches.
    @Published var exportFormat: ExportFormat = ExportFormat(
        rawValue: UserDefaults.standard.string(forKey: ExportFormat.defaultsKey) ?? ""
    ) ?? .default {
        didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: ExportFormat.defaultsKey) }
    }
    @Published var recordings: [Recording] = []
    /// Sidebar summaries by folder, refreshed with `recordings` — computing
    /// one stats files and decodes plan.json, which must not happen in row
    /// bodies (the sidebar re-renders on every ~2s thumbnail tick).
    @Published private(set) var summaries: [URL: Recording.Summary] = [:]
    @Published var exportProgress: [URL: Double] = [:]
    /// Recordings open in a zoom editor window. A `Recording` is identified
    /// by its folder URL, so renaming one that is open would strand the
    /// editor's autosaves; `renameBlocker` refuses until it closes.
    @Published private(set) var openEditors: Set<URL> = []
    /// In-flight exports by folder; `cancelExport` cancels the task and the
    /// render loop bails at its next `Task.checkCancellation`.
    private var exportTasks: [URL: Task<Void, Never>] = [:]
    @Published var thumbnails: [ThumbKey: CGImage] = [:]
    /// Sharper capture for the large source preview; picker thumbs stay small.
    @Published var livePreview: CGImage?
    @Published var isPickingRegion = false
    /// Transient confirmation message (e.g. "Screenshot saved"), auto-clears.
    @Published var toast: String?

    /// Crisp's own windows, excluded from display/region screenshots.
    private var ownWindows: [SCWindow] = []
    private var toastTask: Task<Void, Never>?

    private var engine: CaptureEngine?
    private var tracker: MouseTracker?
    private(set) var currentFolder: URL?
    private var currentSource: CaptureSource?
    private var currentCodec: MasterCodec?
    private var startedAt: Date?
    private(set) var lastRecordingOutcome: RecordingOutcome?
    /// `startRecording` suspends across the stream launch and `state` only
    /// flips once it succeeds; without this guard a second ⌘R in that
    /// window would start a second session over the first.
    private var isStartingRecording = false
    /// The in-flight teardown, if any. Concurrent stops (⌘R racing the
    /// quit-time stop, or a stream error racing either) await it instead of
    /// tearing the same session down twice — and the quit path must not
    /// reply "terminate" until the master's moov atom is written.
    private var stopTask: Task<RecordingOutcome, Never>?
    private var previewTask: Task<Void, Never>?
    private var accessCheckTask: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?
    /// After preflight says yes but ScreenCaptureKit still denies, the grant
    /// needs a relaunch. Don't keep probing — that re-shows the system sheet.
    private var awaitingRelaunch = false

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var selectedDisplay: SCDisplay? {
        displays.first { $0.displayID == selectedDisplayID } ?? displays.first
    }

    var selectedWindow: SCWindow? {
        windows.first { $0.windowID == selectedWindowID }
    }

    // MARK: - Content discovery & previews

    func refresh() {
        reloadRecordings()
        observeActivation()
        startAccessCheckIfNeeded()
    }

    private func startAccessCheckIfNeeded() {
        // onAppear can fire more than once; never stack probes — each
        // ScreenCaptureKit / CGRequestScreenCaptureAccess call can show the
        // system sheet again on macOS 15+ (Deny is not a stored TCC decision).
        if accessCheckTask == nil {
            accessCheckTask = Task {
                // One ScreenCaptureKit probe to learn whether this binary is
                // allowed. Do not follow a deny with CGRequestScreenCaptureAccess:
                // on macOS 15+ that re-shows the sheet, and Deny is not sticky.
                await probeAccess(attempts: 1)
                startPreviewLoop()
            }
        }
    }

    func awaitScreenAccess() async -> Bool {
        startAccessCheckIfNeeded()
        await accessCheckTask?.value
        return accessChecked && hasScreenAccess
    }

    /// Explicitly summon the system permission dialog (used by the card button).
    func requestAccess() {
        Self.log("manual grant request")
        let granted = CGRequestScreenCaptureAccess()
        Self.log("CGRequestScreenCaptureAccess returned \(granted)")
        // If the user denied, probing ScreenCaptureKit would immediately
        // re-present the same sheet. Wait for Check Again / returning from Settings.
        if granted {
            checkAccessAgain()
        }
    }

    @Published var lastProbeError: String?

    /// Ask ScreenCaptureKit whether we're authorized.
    ///
    /// On macOS 15+, this is not silent when unauthorized: each call can show
    /// the Screen Recording sheet (Open System Settings / Deny). Deny does not
    /// stick, so callers must not loop this.
    func probeAccess(attempts: Int = 3) async {
        for attempt in 1...max(1, attempts) {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                hasScreenAccess = true
                lastProbeError = nil
                consecutiveRefreshFailures = 0
                accessChecked = true
                Self.log("probe ok (attempt \(attempt))")
                return
            } catch {
                let ns = error as NSError
                lastProbeError = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
                Self.log("probe failed (attempt \(attempt)): \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        hasScreenAccess = false
        accessChecked = true
    }

    func checkAccessAgain() {
        Task {
            // Retries are only useful after a grant (preflight true). Repeating
            // ScreenCaptureKit while unauthorized re-shows the system sheet.
            let attempts = CGPreflightScreenCaptureAccess() ? 3 : 1
            await probeAccess(attempts: attempts)
            if hasScreenAccess {
                await refreshShareableContent()
            }
        }
    }

    /// Refresh shareable content and thumbnails every couple of seconds while idle,
    /// so the source pickers act as (near-)live previews.
    ///
    /// Ticks are gated on `hasScreenAccess`. When unauthorized, only
    /// `CGPreflightScreenCaptureAccess` is used — it does not prompt.
    private func startPreviewLoop() {
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if let self, !self.isRecording, !self.isPickingRegion {
                    if self.hasScreenAccess {
                        await self.refreshShareableContent()
                    } else if tick % 10 == 0 {
                        await self.recoverAccessIfGranted()
                    }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.recoverAccessIfGranted()
            }
        }
    }

    /// Pick up a Screen Recording grant made in System Settings without
    /// prompting. `CGPreflightScreenCaptureAccess` never shows a dialog;
    /// ScreenCaptureKit is only called after preflight says we're allowed.
    private func recoverAccessIfGranted() async {
        guard accessChecked, !hasScreenAccess, !awaitingRelaunch else { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        Self.log("preflight granted — probing ScreenCaptureKit")
        await probeAccess(attempts: 1)
        if hasScreenAccess {
            await refreshShareableContent()
        } else {
            awaitingRelaunch = true
            Self.log("preflight true but probe failed — waiting for relaunch")
        }
    }

    /// The Screen Recording grant only takes effect on the next launch.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private var consecutiveRefreshFailures = 0

    func refreshShareableContent() async {
        guard hasScreenAccess else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            displays = content.displays
            if selectedDisplayID == nil {
                selectedDisplayID = content.displays.first?.displayID
            }

            ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            windows = content.windows
                .filter { window in
                    window.isOnScreen
                        && window.windowLayer == 0
                        && window.frame.width >= 120 && window.frame.height >= 90
                        && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            if let id = selectedWindowID, !windows.contains(where: { $0.windowID == id }) {
                selectedWindowID = nil
                selectedChromeTab = nil
            }

            await refreshThumbnails()
            consecutiveRefreshFailures = 0
            if case .error = state { state = .idle }
        } catch {
            // Tolerate transient failures; only fall back to the permission
            // card if the content fetch fails repeatedly (grant was revoked).
            let ns = error as NSError
            consecutiveRefreshFailures += 1
            Self.log("content refresh failed (\(consecutiveRefreshFailures)x): \(ns.domain) \(ns.code) — \(ns.localizedDescription)")
            if consecutiveRefreshFailures >= 3 && !CGPreflightScreenCaptureAccess() {
                hasScreenAccess = false
                lastProbeError = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
            }
        }
    }

    private func refreshThumbnails() async {
        var fresh: [ThumbKey: CGImage] = [:]
        for display in displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if let image = await Self.thumbnail(filter: filter) {
                fresh[.display(display.displayID)] = image
            }
        }
        // Cap window thumbnails so a cluttered desktop doesn't hammer the GPU.
        for window in windows.prefix(16) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = await Self.thumbnail(filter: filter) {
                fresh[.window(window.windowID)] = image
            }
        }
        thumbnails = fresh
        await refreshLivePreview()
    }

    /// Enough pixels to fill a large Retina preview pane without upscaling.
    private static let livePreviewMaxWidth: Double = 3840
    private var livePreviewGeneration = 0

    private func scheduleLivePreview() {
        livePreview = nil
        livePreviewGeneration += 1
        let generation = livePreviewGeneration
        Task { await refreshLivePreview(generation: generation) }
    }

    private func refreshLivePreview(generation: Int? = nil) async {
        let generation = generation ?? livePreviewGeneration
        guard hasScreenAccess, !isRecording else { return }
        let image: CGImage?
        switch sourceKind {
        case .display:
            guard let display = selectedDisplay else {
                if generation == livePreviewGeneration { livePreview = nil }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            image = await Self.thumbnail(filter: filter, maxWidth: Self.livePreviewMaxWidth)
        case .window:
            guard let window = selectedWindow else {
                if generation == livePreviewGeneration { livePreview = nil }
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            image = await Self.thumbnail(filter: filter, maxWidth: Self.livePreviewMaxWidth)
        case .region:
            guard let display = selectedDisplay, let region else {
                if generation == livePreviewGeneration { livePreview = nil }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            image = await Self.thumbnail(filter: filter, sourceRect: region, maxWidth: Self.livePreviewMaxWidth)
        }
        guard generation == livePreviewGeneration else { return }
        livePreview = image
    }

    private static func thumbnail(
        filter: SCContentFilter, sourceRect: CGRect? = nil, maxWidth: Double = 480
    ) async -> CGImage? {
        let config = SCStreamConfiguration()
        let size = sourceRect?.size ?? filter.contentRect.size
        guard size.width > 0, size.height > 0 else { return nil }
        if let sourceRect {
            config.sourceRect = sourceRect
        }
        let nativeWidth = size.width * Double(filter.pointPixelScale)
        let nativeHeight = size.height * Double(filter.pointPixelScale)
        guard nativeWidth > 0, nativeHeight > 0 else { return nil }
        let width = min(nativeWidth, maxWidth)
        let height = nativeHeight * (width / nativeWidth)
        config.width = max(1, Int(width.rounded()))
        config.height = max(1, Int(height.rounded()))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Window & Chrome tab selection

    func selectWindow(_ id: CGWindowID) {
        selectedChromeTab = nil
        selectedWindowID = id
    }

    /// The Chrome window (as ScreenCaptureKit sees it) currently showing `tab`.
    /// Only active tabs are visible, so only they can have a thumbnail.
    func chromeWindow(for tab: ChromeTab) -> SCWindow? {
        guard tab.isActive else { return nil }
        return ChromeBridge.matchWindow(title: tab.title, bounds: tab.windowBounds, in: windows)
    }

    /// (Re)list Chrome's tabs. First use triggers the system's
    /// "Crisp wants to control Google Chrome" prompt.
    func loadChromeTabs() {
        guard ChromeBridge.isRunning else {
            chromeListTask?.cancel()
            chromeTabs = []
            chromeTabsStatus = .notRunning
            return
        }
        // One listing at a time: scripts run serially, so piling on Try Again
        // clicks would only queue duplicate work behind the one in flight.
        guard chromeListTask == nil else { return }
        if chromeTabs.isEmpty { chromeTabsStatus = .loading }
        chromeListTask = Task {
            defer { chromeListTask = nil }
            do {
                let tabs = try await ChromeBridge.listTabs()
                chromeTabs = tabs
                chromeTabsStatus = .loaded
                Self.log("chrome: listed \(tabs.count) tabs")
            } catch {
                chromeTabs = []
                chromeTabsStatus = Self.chromeStatus(for: error)
            }
        }
    }

    private static func chromeStatus(for error: Error) -> ChromeTabsStatus {
        switch error as? ChromeBridgeError {
        case .notRunning: return .notRunning
        case .notPermitted: return .notPermitted
        default: return .failed(error.localizedDescription)
        }
    }

    /// Pick a Chrome tab: bring it forward in its window and target that window.
    func selectChromeTab(_ tab: ChromeTab) {
        selectedChromeTab = tab
        Task {
            do {
                let window = try await activateChromeTab(tab)
                guard selectedChromeTab?.id == tab.id else { return }
                selectedWindowID = window.windowID
            } catch {
                guard selectedChromeTab?.id == tab.id else { return }
                selectedChromeTab = nil
                state = .error(error.localizedDescription)
                loadChromeTabs()
            }
        }
    }

    private func activateChromeTab(_ tab: ChromeTab) async throws -> SCWindow {
        let activated = try await ChromeBridge.activate(tab)
        // Give Chrome a beat to retitle the window before re-listing.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await refreshShareableContent()
        guard let window = ChromeBridge.matchWindow(
            title: activated.title, bounds: activated.bounds, in: windows
        ) else {
            let chromeWindows = windows
                .filter { $0.owningApplication?.bundleIdentifier == ChromeBridge.bundleID }
                .map { "\"\($0.title ?? "")\" \($0.frame)" }
            Self.log("chrome: no window matched title=\"\(activated.title)\" bounds=\(activated.bounds); candidates=\(chromeWindows)")
            throw ChromeBridgeError.windowNotFound
        }
        return window
    }

    // MARK: - Region picking

    func pickRegion() {
        guard let display = selectedDisplay else { return }
        isPickingRegion = true
        Task {
            let picked = await RegionPicker.shared.pick(displayID: display.displayID)
            if let picked {
                region = picked
            }
            isPickingRegion = false
            await refreshShareableContent()
        }
    }

    // MARK: - Recording

    private func buildSource() -> CaptureSource? {
        switch sourceKind {
        case .display:
            guard let display = selectedDisplay else { return nil }
            return .display(display)
        case .window:
            guard let window = selectedWindow else { return nil }
            return .window(window)
        case .region:
            guard let display = selectedDisplay, let region else { return nil }
            return .region(display, region)
        }
    }

    @discardableResult
    func startRecording() async -> URL? {
        guard beginRecordingStart() else { return nil }
        defer { isStartingRecording = false }
        guard hasScreenAccess else {
            return failRecordingStart(
                "Screen Recording permission is not active for this build. Use the Grant Access button, approve in System Settings, then Relaunch."
            )
        }
        if sourceKind == .window, let tab = selectedChromeTab {
            // The user may have switched tabs since picking; show theirs again.
            do {
                selectedWindowID = try await activateChromeTab(tab).windowID
            } catch {
                return failRecordingStart(error.localizedDescription)
            }
        }
        guard let source = buildSource() else {
            switch sourceKind {
            case .display: return failRecordingStart("No display available to record.")
            case .window: return failRecordingStart("Pick a window to record first.")
            case .region:
                return failRecordingStart(
                    "Select a region first (choose a display, then “Select Region”)."
                )
            }
        }
        return await startResolvedRecording(source: source, codec: codec)
    }

    @discardableResult
    func startRecording(source: CaptureSource, codec: MasterCodec) async -> URL? {
        guard beginRecordingStart() else { return nil }
        defer { isStartingRecording = false }
        guard hasScreenAccess else {
            return failRecordingStart("Screen Recording permission is not active for this Crisp build.")
        }
        return await startResolvedRecording(source: source, codec: codec)
    }

    private func beginRecordingStart() -> Bool {
        guard !isStartingRecording, !isRecording else { return false }
        isStartingRecording = true
        return true
    }

    private func failRecordingStart(_ message: String) -> URL? {
        state = .error(message)
        lastRecordingOutcome = RecordingOutcome(folder: nil, error: message)
        return nil
    }

    private func startResolvedRecording(source: CaptureSource, codec: MasterCodec) async -> URL? {
        let folder: URL
        do {
            folder = try Recording.newFolder()
        } catch {
            return failRecordingStart("Could not start recording: \(error.localizedDescription)")
        }
        do {
            let engine = CaptureEngine()
            let tracker = MouseTracker()

            engine.onSessionStart = { hostSeconds in
                DispatchQueue.main.async {
                    tracker.markSessionStart(hostSeconds: hostSeconds)
                }
            }
            engine.onStreamError = { [weak self, weak engine] error in
                Task { @MainActor in
                    // Only the engine that is still the live session may
                    // trigger salvage: a late error from an already-replaced
                    // stream must not stop (or delete) a newer recording.
                    guard let self, let engine, self.engine === engine else { return }
                    await self.salvageAfterStreamError(error)
                }
            }

            try await engine.start(
                options: .init(source: source, codec: codec),
                masterURL: folder.appendingPathComponent("master.mov")
            )
            var windowID: CGWindowID?
            if case .window(let window) = source { windowID = window.windowID }
            tracker.start(
                originQuartz: engine.captureOriginQuartz,
                sizePoints: engine.capturePointSize,
                scale: engine.scaleFactor,
                windowID: windowID
            )

            self.engine = engine
            self.tracker = tracker
            self.currentFolder = folder
            self.currentSource = source
            self.currentCodec = codec
            self.startedAt = Date()
            lastRecordingOutcome = nil
            state = .recording(start: Date())

            // Get out of the way of what's being recorded.
            NSApp.hide(nil)
            return folder
        } catch {
            // Don't leave the freshly created folder (and any zero-frame
            // master.mov in it) as a dead entry in the library.
            try? FileManager.default.removeItem(at: folder)
            return failRecordingStart("Could not start recording: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func stopRecording() async -> URL? {
        let outcome: RecordingOutcome?
        if let stopTask {
            outcome = await stopTask.value
        } else {
            outcome = await beginStop(streamError: nil)
        }
        guard outcome?.error == nil else { return nil }
        return outcome?.folder
    }

    /// The stream died out from under a recording (display unplugged, grant
    /// revoked, writer failure): salvage what was captured — everything up
    /// to the failure stays usable instead of being abandoned without a
    /// moov atom. Bails when a stop is already in flight: that stop owns
    /// the teardown.
    private func salvageAfterStreamError(_ streamError: Error) async {
        guard stopTask == nil else { return }
        Self.log("stream error mid-recording: \(streamError.localizedDescription)")
        _ = await beginStop(streamError: streamError)
    }

    /// The one teardown envelope: guard the live session fields, run
    /// `finishRecording` inside the published `stopTask` (which concurrent
    /// stops and the quit path await), and clear it after.
    private func beginStop(streamError: Error?) async -> RecordingOutcome? {
        guard let engine, let tracker, let folder = currentFolder,
              let source = currentSource, let codec = currentCodec, let startedAt else { return nil }
        let task = Task {
            await finishRecording(engine: engine, tracker: tracker, folder: folder,
                                  source: source, codec: codec, startedAt: startedAt,
                                  streamError: streamError)
        }
        stopTask = task
        let outcome = await task.value
        stopTask = nil
        return outcome
    }

    /// Tear the active session down: stop the tracker, finalize the writer,
    /// and write the click log — used by Stop and by stream failure.
    private func finishRecording(
        engine: CaptureEngine, tracker: MouseTracker, folder: URL,
        source: CaptureSource, codec: MasterCodec, startedAt: Date, streamError: Error?
    ) async -> RecordingOutcome {
        tracker.stop()
        var failure: Error?
        var outcomeFolder: URL? = folder
        do {
            try await engine.stop()
        } catch {
            failure = error
        }
        let masterExists = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("master.mov").path)
        if let failure, failure as? CaptureEngine.CaptureError == .noFramesCaptured || !masterExists {
            // Nothing playable was captured (zero frames, or the writer died
            // and its file was discarded): don't leave a dead folder behind.
            try? FileManager.default.removeItem(at: folder)
            outcomeFolder = nil
        } else {
            // Write the click log even when finalizing threw: the events are
            // valid in memory, and the master often is too.
            do {
                try writeEvents(engine: engine, tracker: tracker, folder: folder,
                                source: source, codec: codec, startedAt: startedAt)
            } catch {
                if failure == nil { failure = error }
            }
            if let failure, streamError != nil {
                Self.log("salvage after stream error also failed: \(failure.localizedDescription)")
            }
        }

        let message: String?
        if let streamError {
            message = "Recording stopped: \(streamError.localizedDescription)"
        } else if failure as? CaptureEngine.CaptureError == .noFramesCaptured {
            message = "Nothing was captured — the recording stopped before the first frame arrived."
        } else if let failure {
            message = "Could not finish recording: \(failure.localizedDescription)"
        } else if outcomeFolder == nil {
            message = "The recording stopped without producing a playable master."
        } else {
            message = nil
        }
        state = message.map(State.error) ?? .idle
        let outcome = RecordingOutcome(folder: outcomeFolder, error: message)
        lastRecordingOutcome = outcome
        cleanupAfterStop()
        reloadRecordings()
        NSApp.activate(ignoringOtherApps: true)
        return outcome
    }

    private func writeEvents(
        engine: CaptureEngine, tracker: MouseTracker, folder: URL,
        source: CaptureSource, codec: MasterCodec, startedAt: Date
    ) throws {
        let meta = RecordingMeta(
            source: source.kindName,
            displayID: source.displayID,
            pixelWidth: engine.pixelWidth,
            pixelHeight: engine.pixelHeight,
            scaleFactor: engine.scaleFactor,
            fps: 60,
            codec: codec.rawValue,
            startedAt: startedAt,
            sessionStartHostSeconds: engine.sessionStartHostSeconds ?? 0,
            events: tracker.events,
            samples: tracker.samples
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: folder.appendingPathComponent("events.json"))
    }

    private func cleanupAfterStop() {
        // Belt and braces: `stop()` is idempotent, and no exit path may
        // leave the global event monitors and the 60Hz timer installed.
        tracker?.stop()
        engine = nil
        tracker = nil
        currentFolder = nil
        currentSource = nil
        currentCodec = nil
        startedAt = nil
    }

    // MARK: - Screenshots

    func screenshot(format: ScreenshotFormat) async {
        guard hasScreenAccess else {
            state = .error("Screen Recording permission is needed for screenshots too.")
            return
        }
        guard let source = buildSource() else {
            state = .error("Pick a display, window, or region to screenshot first.")
            return
        }
        do {
            let url = try await Screenshotter.capture(
                source: source, format: format, excluding: ownWindows
            )
            Self.log("screenshot saved: \(url.lastPathComponent)")
            showToast("Saved \(url.lastPathComponent) — revealing in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            state = .error("Screenshot failed: \(error.localizedDescription)")
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Export & library

    /// Render the whole video (inside its trim) with its zooms to a new file.
    func export(_ recording: Recording) {
        let format = exportFormat
        runExport(recording) { renderer, report in
            [try await renderer.export(recording: recording, format: format, progress: report)]
        }
    }

    /// Render the plan's clips — all of them, or just `only` — each to a
    /// file of its own, one after another; the progress bar spans the whole
    /// run. Cancelling stops at the current clip and keeps the ones already
    /// written.
    func exportClips(_ recording: Recording, only: Set<UUID>? = nil) {
        let format = exportFormat
        runExport(recording) { renderer, report in
            let length = try await AVURLAsset(url: recording.masterURL).load(.duration).seconds
            let clips = (recording.loadPlan()?.clipRanges(duration: length) ?? [])
                .filter { only?.contains($0.id) ?? true }
            guard !clips.isEmpty else { throw Renderer.RenderError.noClips }
            var urls: [URL] = []
            for (i, clip) in clips.enumerated() {
                urls.append(try await renderer.export(recording: recording, format: format, clip: clip) { fraction in
                    report((Double(i) + fraction) / Double(clips.count))
                })
            }
            return urls
        }
    }

    /// One export at a time per recording: `job` renders with `renderer`,
    /// reporting progress in 0…1, and returns the files it wrote, which are
    /// revealed in the Finder when it is done.
    private func runExport(
        _ recording: Recording,
        job: @escaping (Renderer, @escaping (Double) -> Void) async throws -> [URL]
    ) {
        guard exportProgress[recording.folder] == nil else { return }
        exportProgress[recording.folder] = 0
        let renderer = Renderer()
        exportTasks[recording.folder] = Task.detached { [weak self] in
            do {
                let urls = try await job(renderer) { fraction in
                    DispatchQueue.main.async {
                        self?.exportProgress[recording.folder] = fraction
                    }
                }
                await MainActor.run { [weak self] in
                    self?.clearExport(recording.folder)
                    self?.reloadRecordings()
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.clearExport(recording.folder)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.clearExport(recording.folder)
                    self?.state = .error("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelExport(_ recording: Recording) {
        exportTasks[recording.folder]?.cancel()
    }

    private func clearExport(_ folder: URL) {
        exportProgress[folder] = nil
        exportTasks[folder] = nil
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.masterURL])
    }

    /// Ignore a slow summary pass finishing after a newer reload started.
    private var summaryGeneration = 0

    private func reloadRecordings() {
        recordings = Recording.loadAll()
        // Summaries stat files and decode plan.json per folder — computed off
        // the main actor, or a big library beachballs every stop, delete and
        // rename. The previous cache stays up meanwhile, so rows show at most
        // a beat of stale (or placeholder) info before the fresh set lands.
        summaryGeneration += 1
        let generation = summaryGeneration
        let recordings = recordings
        Task.detached(priority: .userInitiated) { [weak self] in
            let fresh = Dictionary(uniqueKeysWithValues: recordings.map { ($0.folder, $0.summary) })
            await MainActor.run {
                guard let self, generation == self.summaryGeneration else { return }
                self.summaries = fresh
            }
        }
    }

    /// Recompute one folder's cached summary, off the main actor — called by
    /// whatever rewrites its plan.json (the editor autosave), so the sidebar
    /// counts never wait for the editor window to close.
    func refreshSummary(for folder: URL) {
        guard let recording = recordings.first(where: { $0.folder == folder }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let summary = recording.summary
            await MainActor.run {
                // A reload may have replaced the dictionary meanwhile; only
                // patch a folder the sidebar still lists.
                guard let self, self.recordings.contains(where: { $0.folder == folder }) else { return }
                self.summaries[folder] = summary
            }
        }
    }

    func editorOpened(_ folder: URL) { openEditors.insert(folder) }

    func editorClosed(_ folder: URL) { openEditors.remove(folder) }

    /// Why `recording` can't be renamed right now, or nil when it can. Every
    /// consumer holds the folder URL, so the move must wait until nothing
    /// (an export writing into it, an editor autosaving to it) is using it.
    func renameBlocker(_ recording: Recording) -> String? {
        if exportProgress[recording.folder] != nil {
            return "Wait for the export to finish (or cancel it) before renaming"
        }
        if openEditors.contains(recording.folder) {
            return "Close this recording's zoom editor before renaming"
        }
        return nil
    }

    /// Renames the recording folder and the exports inside it (see
    /// `Recording.renamed(to:)`). No-op if the name is unchanged, empty,
    /// contains path characters, collides with an existing folder, or the
    /// recording is in use (see `renameBlocker`).
    func rename(_ recording: Recording, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.name,
              !trimmed.contains("/"), !trimmed.contains(":"),
              renameBlocker(recording) == nil
        else { return }
        let dest = recording.folder.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        do {
            _ = try recording.renamed(to: trimmed)
        } catch {
            Self.log("rename failed: \(error.localizedDescription)")
            return
        }
        reloadRecordings()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
        reloadRecordings()
    }

}
