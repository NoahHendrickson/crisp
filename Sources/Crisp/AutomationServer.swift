import AppKit
import CrispAutomationProtocol
import Darwin
import Foundation
import ScreenCaptureKit

@MainActor
final class AutomationServer {
    static let shared = AutomationServer()

    private var observer: NSObjectProtocol?
    private var handling: Set<String> = []

    func start() {
        guard observer == nil, let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let directory = CrispAutomation.directory(bundleIdentifier: bundleIdentifier)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            AppModel.log("automation: could not create control directory — \(error.localizedDescription)")
            return
        }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: CrispAutomation.notification,
            object: bundleIdentifier,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.userInfo?["id"] as? String else { return }
            Task {
                await self?.handle(id: id, bundleIdentifier: bundleIdentifier, allowStart: true)
            }
        }

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try? Data(pid.utf8).write(
            to: CrispAutomation.readyURL(bundleIdentifier: bundleIdentifier), options: .atomic
        )
        pruneOrphanResponses(in: directory)
        for url in requestFiles(in: directory) {
            let id = Self.requestID(from: url)
            if Self.isStale(url) {
                Self.removeRequestAndResponse(id: id, bundleIdentifier: bundleIdentifier)
            } else {
                // A start left by a killed client must never begin unattended.
                Task { await handle(id: id, bundleIdentifier: bundleIdentifier, allowStart: false) }
            }
        }
        AppModel.log("automation: ready for \(bundleIdentifier)")
    }

    private func handle(id: String, bundleIdentifier: String, allowStart: Bool) async {
        guard !handling.contains(id) else { return }
        let requestURL = CrispAutomation.requestURL(id: id, bundleIdentifier: bundleIdentifier)
        let responseURL = CrispAutomation.responseURL(id: id, bundleIdentifier: bundleIdentifier)
        guard !FileManager.default.fileExists(atPath: responseURL.path) else { return }
        handling.insert(id)
        defer { handling.remove(id) }

        let response: AutomationResponse
        do {
            let data = try Data(contentsOf: requestURL)
            let request = try JSONDecoder().decode(AutomationRequest.self, from: data)
            guard request.id == id else {
                throw CrispAutomationError.message("Request ID does not match its filename.")
            }
            guard abs(request.createdAt.timeIntervalSinceNow) < 120 else {
                throw CrispAutomationError.message("Ignoring a stale automation request.")
            }
            guard allowStart || !request.command.isStart else {
                throw CrispAutomationError.message(
                    "Crisp finished launching after this start request was abandoned. Retry the request."
                )
            }
            response = try await execute(request) {
                FileManager.default.fileExists(atPath: requestURL.path)
                    && Self.processIsRunning(request.clientProcessID)
            }
        } catch {
            response = AutomationResponse(
                requestID: id,
                result: .failure(message: error.localizedDescription, status: AppModel.shared.automationStatus)
            )
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(response).write(to: responseURL, options: .atomic)
            try? FileManager.default.removeItem(at: requestURL)
        } catch {
            AppModel.log("automation: could not write response \(id) — \(error.localizedDescription)")
        }
    }

    private func execute(
        _ request: AutomationRequest, callerIsWaiting: () -> Bool
    ) async throws -> AutomationResponse {
        let model = AppModel.shared
        switch request.command {
        case .status:
            return AutomationResponse(requestID: request.id, result: .status(model.automationStatus))

        case .sources:
            let snapshot = try await availableSources(includeChrome: true)
            return AutomationResponse(
                requestID: request.id,
                result: .sources(
                    status: model.automationStatus,
                    sources: snapshot.items.map(\.info),
                    warnings: snapshot.warnings
                )
            )

        case .start(let selector, let automationCodec):
            let includeChrome = selector.kind == .chromeURL
                || (selector.kind == .source && selector.value.lowercased().hasPrefix("chrome:"))
            let snapshot = try await availableSources(includeChrome: includeChrome)
            let selected = try selector.resolve(in: snapshot.items.map(\.info))
            guard let item = snapshot.items.first(where: { $0.info.id == selected.id }) else {
                throw CrispAutomationError.message("That source is no longer available.")
            }
            let source = try await captureSource(for: item)
            guard callerIsWaiting() else {
                throw CrispAutomationError.message("The recording request was cancelled before capture started.")
            }
            let codec = automationCodec.map(MasterCodec.init) ?? model.codec
            guard let folder = await model.startRecording(source: source, codec: codec) else {
                throw CrispAutomationError.message(
                    model.automationStatus.message ?? "Crisp is already starting or recording."
                )
            }
            return AutomationResponse(
                requestID: request.id,
                result: .started(
                    status: model.automationStatus,
                    recording: Self.recording(folder: folder)
                )
            )

        case .stop:
            guard model.isRecording else {
                throw CrispAutomationError.message(
                    model.automationStatus.message ?? "Crisp is not recording."
                )
            }
            guard let folder = await model.stopRecording() else {
                throw CrispAutomationError.message(
                    model.automationStatus.message
                        ?? "The recording stopped without producing a playable master."
                )
            }
            return AutomationResponse(
                requestID: request.id,
                result: .stopped(
                    status: model.automationStatus,
                    recording: Self.recording(folder: folder)
                )
            )
        }
    }

    private enum AvailableTarget {
        case display(SCDisplay)
        case window(SCWindow)
        case chromeTab(ChromeTab)
    }

    private struct AvailableItem {
        var info: AutomationSource
        var target: AvailableTarget
    }

    private struct SourceSnapshot {
        var items: [AvailableItem]
        var warnings: [String]
    }

    private func availableSources(includeChrome: Bool) async throws -> SourceSnapshot {
        guard await AppModel.shared.awaitScreenAccess() else {
            throw CrispAutomationError.message(
                "Screen Recording permission is not active for this Crisp build. Open Crisp, grant access, and relaunch it."
            )
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        let windows = Self.recordableWindows(content.windows)
        var items = content.displays.map { display in
            let name = Self.displayName(display)
            return AvailableItem(
                info: AutomationSource(
                    id: "display:\(display.displayID)", kind: .display,
                    label: "\(name) \(display.width)×\(display.height)",
                    title: name, width: display.width, height: display.height
                ),
                target: .display(display)
            )
        }
        items += windows.map { window in
            let app = window.owningApplication?.applicationName ?? "App"
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
            return AvailableItem(
                info: AutomationSource(
                    id: "window:\(window.windowID)", kind: .window,
                    label: title.map { "\(app) — \($0)" } ?? app,
                    app: app, title: title,
                    width: Int(window.frame.width), height: Int(window.frame.height)
                ),
                target: .window(window)
            )
        }

        var warnings: [String] = []
        if includeChrome, ChromeBridge.isRunning {
            do {
                let tabs = try await ChromeBridge.listTabs()
                items += tabs.map { tab in
                    AvailableItem(
                        info: AutomationSource(
                            id: "chrome:\(tab.windowID):\(tab.tabID)", kind: .chromeTab,
                            label: "Chrome — \(tab.displayTitle)", app: "Google Chrome",
                            title: tab.displayTitle, url: tab.url,
                            width: Int(tab.windowBounds.width), height: Int(tab.windowBounds.height)
                        ),
                        target: .chromeTab(tab)
                    )
                }
            } catch {
                warnings.append("Chrome tabs unavailable: \(error.localizedDescription)")
            }
        }
        return SourceSnapshot(items: items, warnings: warnings)
    }

    private func captureSource(for item: AvailableItem) async throws -> CaptureSource {
        switch item.target {
        case .display(let display):
            return .display(display)
        case .window(let window):
            return .window(window)
        case .chromeTab(let tab):
            let activated = try await ChromeBridge.activate(tab)
            try? await Task.sleep(nanoseconds: 150_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            guard let window = ChromeBridge.matchWindow(
                title: activated.title,
                bounds: activated.bounds,
                in: Self.recordableWindows(content.windows)
            ) else {
                throw CrispAutomationError.message("The selected Chrome tab's window is no longer available.")
            }
            return .window(window)
        }
    }

    private static func recordableWindows(_ windows: [SCWindow]) -> [SCWindow] {
        windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width >= 120
                && window.frame.height >= 90
                && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }.sorted {
            ($0.owningApplication?.applicationName ?? "")
                < ($1.owningApplication?.applicationName ?? "")
        }
    }

    private static func displayName(_ display: SCDisplay) -> String {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[numberKey] as? NSNumber)?.uint32Value == display.displayID
        }) {
            return screen.localizedName
        }
        return CGDisplayIsMain(display.displayID) != 0 ? "Built-in Display" : "Display"
    }

    private static func recording(folder: URL) -> AutomationRecording {
        AutomationRecording(
            folder: folder.path,
            master: folder.appendingPathComponent("master.mov").path,
            events: folder.appendingPathComponent("events.json").path
        )
    }

    private func requestFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("request-") && $0.pathExtension == "json"
        }
    }

    private func pruneOrphanResponses(in directory: URL) {
        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [] where url.lastPathComponent.hasPrefix("response-") && Self.isStale(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func requestID(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "request-", with: "")
    }

    private static func isStale(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate.map { abs($0.timeIntervalSinceNow) >= 120 } ?? true
    }

    private static func removeRequestAndResponse(id: String, bundleIdentifier: String) {
        try? FileManager.default.removeItem(
            at: CrispAutomation.requestURL(id: id, bundleIdentifier: bundleIdentifier)
        )
        try? FileManager.default.removeItem(
            at: CrispAutomation.responseURL(id: id, bundleIdentifier: bundleIdentifier)
        )
    }

    private static func processIsRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        return kill(processID, 0) == 0 || errno == EPERM
    }
}

extension AppModel {
    var automationStatus: AutomationStatus {
        switch state {
        case .recording:
            return AutomationStatus(state: .recording, recordingFolder: currentFolder?.path)
        case .error(let message):
            return AutomationStatus(
                state: .error,
                message: message,
                recordingFolder: lastRecordingOutcome?.error == nil
                    ? nil : lastRecordingOutcome?.folder?.path
            )
        case .idle:
            if let outcome = lastRecordingOutcome, let message = outcome.error {
                return AutomationStatus(
                    state: .error, message: message, recordingFolder: outcome.folder?.path
                )
            }
            return AutomationStatus(state: .idle)
        }
    }
}

private extension MasterCodec {
    init(_ codec: AutomationCodec) {
        switch codec {
        case .hevc10: self = .hevc10
        case .proRes422: self = .proRes422
        case .proRes4444: self = .proRes4444
        }
    }
}
