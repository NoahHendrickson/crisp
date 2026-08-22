import Foundation
import AppKit
import ScreenCaptureKit

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

    @Published var state: State = .idle
    /// Determined by actually probing ScreenCaptureKit once at launch — the
    /// CGPreflight* legacy check reports false negatives on modern macOS even
    /// when the "Screen & System Audio Recording" grant is in place.
    @Published var hasScreenAccess = false
    /// False until the first probe completes (UI shows a spinner meanwhile).
    @Published var accessChecked = false
    @Published var sourceKind: SourceKind = .display
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    /// Region in points, top-left origin, local to the selected display.
    @Published var region: CGRect?
    @Published var codec: MasterCodec = .hevc10
    @Published var recordings: [Recording] = []
    @Published var exportProgress: [URL: Double] = [:]
    private var exportRenderers: [URL: Renderer] = [:]
    @Published var thumbnails: [ThumbKey: CGImage] = [:]
    @Published var regionPreview: CGImage?
    @Published var isPickingRegion = false
    /// Transient confirmation message (e.g. "Screenshot saved"), auto-clears.
    @Published var toast: String?

    /// Crisp's own windows, excluded from display/region screenshots.
    private var ownWindows: [SCWindow] = []
    private var toastTask: Task<Void, Never>?

    private var engine: CaptureEngine?
    private var tracker: MouseTracker?
    private var currentFolder: URL?
    private var currentSource: CaptureSource?
    private var startedAt: Date?
    private var previewTask: Task<Void, Never>?

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
        recordings = Recording.loadAll()
        Task {
            await probeAccess(attempts: 1)
            if !hasScreenAccess {
                // SCShareableContent does NOT auto-prompt on modern macOS — it
                // silently records a deny. This is the call that actually shows
                // the system permission dialog (no-op if a decision exists).
                Self.log("requesting access via CGRequestScreenCaptureAccess")
                let granted = CGRequestScreenCaptureAccess()
                Self.log("CGRequestScreenCaptureAccess returned \(granted)")
                if granted {
                    await probeAccess(attempts: 2)
                }
            }
            startPreviewLoop()
        }
    }

    /// Explicitly summon the system permission dialog (used by the card button).
    func requestAccess() {
        Self.log("manual grant request")
        let granted = CGRequestScreenCaptureAccess()
        Self.log("CGRequestScreenCaptureAccess returned \(granted)")
        checkAccessAgain()
    }

    @Published var lastProbeError: String?

    /// Ask ScreenCaptureKit directly whether we're authorized. This is the only
    /// reliable check. For an unauthorized process, macOS shows the permission
    /// dialog at most once; after TCC has a stored decision, calls fail silently.
    /// Retries cover transient failures right after launch.
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
            await probeAccess()
            if hasScreenAccess {
                await refreshShareableContent()
            }
        }
    }

    /// Refresh shareable content and thumbnails every couple of seconds while idle,
    /// so the source pickers act as (near-)live previews.
    ///
    /// IMPORTANT: ticks are gated on `hasScreenAccess` — calling ScreenCaptureKit
    /// on a loop while unauthorized would spam the system permission dialog.
    private func startPreviewLoop() {
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if let self, !self.isRecording, !self.isPickingRegion {
                    if self.hasScreenAccess {
                        await self.refreshShareableContent()
                    } else if tick % 10 == 0 {
                        // Auto-recover every ~20s: once TCC has a stored decision
                        // this is silent (no dialog), and it picks up a grant made
                        // in System Settings without requiring Check Again.
                        await self.probeAccess(attempts: 1)
                    }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
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
            if consecutiveRefreshFailures >= 3 {
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

        if let display = selectedDisplay, let region {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            regionPreview = await Self.thumbnail(filter: filter, sourceRect: region)
        } else {
            regionPreview = nil
        }
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
        let aspect = size.height / size.width
        config.width = Int(maxWidth)
        config.height = max(1, Int(maxWidth * aspect))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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

    func startRecording() async {
        guard hasScreenAccess else {
            state = .error("Screen Recording permission is not active for this build. Use the Grant Access button, approve in System Settings, then Relaunch.")
            return
        }
        guard let source = buildSource() else {
            switch sourceKind {
            case .display: state = .error("No display available to record.")
            case .window: state = .error("Pick a window to record first.")
            case .region: state = .error("Select a region first (choose a display, then “Select Region”).")
            }
            return
        }
        do {
            let folder = try Recording.newFolder()
            let engine = CaptureEngine()
            let tracker = MouseTracker()

            engine.onSessionStart = { hostSeconds in
                DispatchQueue.main.async {
                    tracker.markSessionStart(hostSeconds: hostSeconds)
                }
            }
            engine.onStreamError = { [weak self] error in
                DispatchQueue.main.async {
                    self?.state = .error("Recording stopped: \(error.localizedDescription)")
                    self?.cleanupAfterStop()
                }
            }

            try await engine.start(
                options: .init(source: source, codec: codec),
                masterURL: folder.appendingPathComponent("master.mov")
            )
            tracker.start(
                originQuartz: engine.captureOriginQuartz,
                sizePoints: engine.capturePointSize,
                scale: engine.scaleFactor
            )

            self.engine = engine
            self.tracker = tracker
            self.currentFolder = folder
            self.currentSource = source
            self.startedAt = Date()
            state = .recording(start: Date())

            // Get out of the way of what's being recorded.
            NSApp.hide(nil)
        } catch {
            state = .error("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard let engine, let tracker, let folder = currentFolder,
              let source = currentSource, let startedAt else { return }
        tracker.stop()
        do {
            try await engine.stop()
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
            state = .idle
        } catch {
            state = .error("Could not finish recording: \(error.localizedDescription)")
        }
        cleanupAfterStop()
        recordings = Recording.loadAll()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func cleanupAfterStop() {
        engine = nil
        tracker = nil
        currentFolder = nil
        currentSource = nil
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

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Export & library

    func export(_ recording: Recording) {
        guard exportProgress[recording.folder] == nil else { return }
        exportProgress[recording.folder] = 0
        let renderer = Renderer()
        exportRenderers[recording.folder] = renderer
        Task.detached { [weak self] in
            do {
                try await renderer.export(recording: recording) { fraction in
                    DispatchQueue.main.async {
                        self?.exportProgress[recording.folder] = fraction
                    }
                }
                await MainActor.run { [weak self] in
                    self?.clearExport(recording.folder)
                    self?.recordings = Recording.loadAll()
                    NSWorkspace.shared.activateFileViewerSelecting([recording.exportURL])
                }
            } catch is Renderer.Cancelled {
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
        exportRenderers[recording.folder]?.isCancelled = true
    }

    private func clearExport(_ folder: URL) {
        exportProgress[folder] = nil
        exportRenderers[folder] = nil
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.masterURL])
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
        recordings = Recording.loadAll()
    }
}
