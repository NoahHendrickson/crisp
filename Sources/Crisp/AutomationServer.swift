import AppKit
import CrispAutomationProtocol
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
            Task { @MainActor in await self?.handle(id: id, bundleIdentifier: bundleIdentifier) }
        }

        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [] where url.lastPathComponent.hasPrefix("request-") && url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "request-", with: "")
            Task { await handle(id: id, bundleIdentifier: bundleIdentifier) }
        }
        AppModel.log("automation: ready for \(bundleIdentifier)")
    }

    private func handle(id: String, bundleIdentifier: String) async {
        guard !handling.contains(id) else { return }
        let responseURL = CrispAutomation.responseURL(id: id, bundleIdentifier: bundleIdentifier)
        guard !FileManager.default.fileExists(atPath: responseURL.path) else { return }
        handling.insert(id)
        defer { handling.remove(id) }

        let requestURL = CrispAutomation.requestURL(id: id, bundleIdentifier: bundleIdentifier)
        let response: AutomationResponse
        do {
            let data = try Data(contentsOf: requestURL)
            let request = try JSONDecoder().decode(AutomationRequest.self, from: data)
            guard request.id == id else { throw AutomationError.message("Request ID does not match its filename.") }
            guard abs(request.createdAt.timeIntervalSinceNow) < 120 else {
                throw AutomationError.message("Ignoring a stale automation request.")
            }
            response = try await execute(request)
        } catch {
            response = AutomationResponse(requestID: id, ok: false, error: error.localizedDescription)
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(response).write(to: responseURL, options: .atomic)
        } catch {
            AppModel.log("automation: could not write response \(id) — \(error.localizedDescription)")
        }
    }

    private func execute(_ request: AutomationRequest) async throws -> AutomationResponse {
        let model = AppModel.shared
        switch request.command {
        case .status:
            return AutomationResponse(
                requestID: request.id, ok: true, status: model.automationStatus
            )

        case .sources:
            let snapshot = try await model.automationSources()
            return AutomationResponse(
                requestID: request.id, ok: true, warnings: snapshot.warnings,
                status: model.automationStatus, sources: snapshot.sources
            )

        case .start:
            guard let selector = request.selector else {
                throw AutomationError.message("Start requires a source selector.")
            }
            let folder = try await model.automationStart(selector: selector, codec: request.codec)
            return AutomationResponse(
                requestID: request.id, ok: true, status: model.automationStatus,
                recording: Self.recording(folder: folder)
            )

        case .stop:
            guard model.isRecording else {
                throw AutomationError.message("Crisp is not recording.")
            }
            guard let folder = await model.stopRecording() else {
                throw AutomationError.message("The recording stopped without producing a playable master.")
            }
            return AutomationResponse(
                requestID: request.id, ok: true, status: model.automationStatus,
                recording: Self.recording(folder: folder)
            )
        }
    }

    private static func recording(folder: URL) -> AutomationRecording {
        AutomationRecording(
            folder: folder.path,
            master: folder.appendingPathComponent("master.mov").path,
            events: folder.appendingPathComponent("events.json").path
        )
    }

    enum AutomationError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }
}

extension AppModel {
    struct AutomationSourceSnapshot {
        var sources: [AutomationSource]
        var warnings: [String]
    }

    var automationStatus: AutomationStatus {
        switch state {
        case .idle:
            return AutomationStatus(state: .idle)
        case .recording:
            return AutomationStatus(state: .recording, recordingFolder: currentFolder?.path)
        case .error(let message):
            return AutomationStatus(state: .error, message: message, recordingFolder: currentFolder?.path)
        }
    }

    func automationSources() async throws -> AutomationSourceSnapshot {
        refresh()
        for _ in 0..<100 where !accessChecked {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard accessChecked, hasScreenAccess else {
            throw AutomationServer.AutomationError.message(
                "Screen Recording permission is not active for this Crisp build. Open Crisp, grant access, and relaunch it."
            )
        }
        await refreshShareableContent()

        var sources = displays.map { display in
            let name = automationDisplayName(display)
            return AutomationSource(
                id: "display:\(display.displayID)", kind: .display,
                label: "\(name) \(display.width)×\(display.height)",
                title: name, width: display.width, height: display.height
            )
        }
        sources += windows.map { window in
            let app = window.owningApplication?.applicationName ?? "App"
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
            return AutomationSource(
                id: "window:\(window.windowID)", kind: .window,
                label: title.map { "\(app) — \($0)" } ?? app,
                app: app, title: title,
                width: Int(window.frame.width), height: Int(window.frame.height)
            )
        }

        var warnings: [String] = []
        if ChromeBridge.isRunning {
            do {
                chromeTabs = try await ChromeBridge.listTabs()
                sources += chromeTabs.map { tab in
                    AutomationSource(
                        id: "chrome:\(tab.windowID):\(tab.tabID)", kind: .chromeTab,
                        label: "Chrome — \(tab.displayTitle)", app: "Google Chrome",
                        title: tab.displayTitle, url: tab.url,
                        width: Int(tab.windowBounds.width), height: Int(tab.windowBounds.height)
                    )
                }
            } catch {
                chromeTabs = []
                warnings.append("Chrome tabs unavailable: \(error.localizedDescription)")
            }
        }
        return AutomationSourceSnapshot(sources: sources, warnings: warnings)
    }

    func automationStart(selector: AutomationSelector, codec rawCodec: String?) async throws -> URL {
        guard !isRecording else {
            throw AutomationServer.AutomationError.message("Crisp is already recording.")
        }
        let snapshot = try await automationSources()
        let source = try automationResolve(selector, in: snapshot.sources)
        if let rawCodec { codec = try automationCodec(rawCodec) }

        switch source.kind {
        case .display:
            guard let id = source.id.split(separator: ":").last.flatMap({ CGDirectDisplayID($0) }),
                  displays.contains(where: { $0.displayID == id }) else {
                throw AutomationServer.AutomationError.message("That display is no longer available.")
            }
            sourceKind = .display
            selectedDisplayID = id
            selectedChromeTab = nil

        case .window:
            guard let id = source.id.split(separator: ":").last.flatMap({ CGWindowID($0) }),
                  windows.contains(where: { $0.windowID == id }) else {
                throw AutomationServer.AutomationError.message("That window is no longer available.")
            }
            sourceKind = .window
            selectedWindowID = id
            selectedChromeTab = nil

        case .chromeTab:
            let parts = source.id.split(separator: ":")
            guard parts.count == 3, let windowID = Int(parts[1]), let tabID = Int(parts[2]),
                  let tab = chromeTabs.first(where: { $0.windowID == windowID && $0.tabID == tabID }) else {
                throw AutomationServer.AutomationError.message("That Chrome tab is no longer available.")
            }
            sourceKind = .window
            selectedChromeTab = tab
        }

        guard let folder = await startRecording() else {
            let message = automationStatus.message ?? "Crisp could not start recording."
            throw AutomationServer.AutomationError.message(message)
        }
        return folder
    }

    private func automationResolve(
        _ selector: AutomationSelector, in sources: [AutomationSource]
    ) throws -> AutomationSource {
        let candidates: [AutomationSource]
        switch selector.kind {
        case .source:
            candidates = sources.filter { $0.id.caseInsensitiveCompare(selector.value) == .orderedSame }
        case .chromeURL:
            candidates = automationMatches(
                sources.filter { $0.kind == .chromeTab }, value: selector.value,
                fields: { [$0.url, $0.title, Optional($0.label)].compactMap { $0 } }
            )
        case .window:
            candidates = automationMatches(
                sources.filter { $0.kind == .window }, value: selector.value,
                fields: { [$0.app, $0.title, Optional($0.label)].compactMap { $0 } }
            )
        case .display:
            candidates = automationMatches(
                sources.filter { $0.kind == .display }, value: selector.value,
                fields: { [$0.title, Optional($0.label), Optional($0.id)].compactMap { $0 } }
            )
        }

        guard !candidates.isEmpty else {
            let warning = selector.kind == .chromeURL
                ? " Run `crisp sources` and check any Chrome warning."
                : " Run `crisp sources` to see current IDs."
            throw AutomationServer.AutomationError.message("No source matched \"\(selector.value)\".\(warning)")
        }
        guard candidates.count == 1 else {
            let choices = candidates.map { "\($0.id) (\($0.label))" }.joined(separator: ", ")
            throw AutomationServer.AutomationError.message(
                "Source selector \"\(selector.value)\" is ambiguous: \(choices). Use --source with an exact ID."
            )
        }
        return candidates[0]
    }

    private func automationMatches(
        _ sources: [AutomationSource], value: String,
        fields: (AutomationSource) -> [String]
    ) -> [AutomationSource] {
        let exact = sources.filter { source in
            fields(source).contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        }
        if !exact.isEmpty { return exact }
        return sources.filter { source in
            fields(source).contains { $0.localizedCaseInsensitiveContains(value) }
        }
    }

    private func automationCodec(_ value: String) throws -> MasterCodec {
        switch value.lowercased().replacingOccurrences(of: " ", with: "") {
        case "hevc", "hevc10", "hevc10-bit": return .hevc10
        case "prores422": return .proRes422
        case "prores4444": return .proRes4444
        default:
            throw AutomationServer.AutomationError.message(
                "Unknown codec \"\(value)\". Use hevc10, prores422, or prores4444."
            )
        }
    }

    private func automationDisplayName(_ display: SCDisplay) -> String {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[numberKey] as? NSNumber)?.uint32Value == display.displayID
        }) {
            return screen.localizedName
        }
        return CGDisplayIsMain(display.displayID) != 0 ? "Built-in Display" : "Display"
    }
}
