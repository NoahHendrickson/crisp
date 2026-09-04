import AppKit
import Foundation

public enum CrispAutomation {
    public static let notification = Notification.Name("com.noey.crisp.automation.request")
    public static let backgroundLaunchArgument = "--automation-background"

    public static func directory(bundleIdentifier: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crisp/Automation", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static func requestURL(id: String, bundleIdentifier: String) -> URL {
        directory(bundleIdentifier: bundleIdentifier)
            .appendingPathComponent("request-\(id).json")
    }

    public static func responseURL(id: String, bundleIdentifier: String) -> URL {
        directory(bundleIdentifier: bundleIdentifier)
            .appendingPathComponent("response-\(id).json")
    }

    public static func readyURL(bundleIdentifier: String) -> URL {
        directory(bundleIdentifier: bundleIdentifier).appendingPathComponent("ready")
    }

    /// Process id written to `ready` by the instance that answers automation.
    public static func readyProcessID(bundleIdentifier: String) -> Int32? {
        guard let data = try? Data(contentsOf: readyURL(bundleIdentifier: bundleIdentifier)) else {
            return nil
        }
        return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum CrispAutomationError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public enum AutomationCodec: String, Codable, CaseIterable, Sendable {
    case hevc10
    case proRes422 = "prores422"
    case proRes4444 = "prores4444"

    public init(argument: String) throws {
        switch argument.lowercased().replacingOccurrences(of: " ", with: "") {
        case "hevc", "hevc10", "hevc10-bit": self = .hevc10
        case "prores422": self = .proRes422
        case "prores4444": self = .proRes4444
        default:
            throw CrispAutomationError.message(
                "Unknown codec \"\(argument)\". Use hevc10, prores422, or prores4444."
            )
        }
    }
}

public struct AutomationSelector: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case source
        case chromeURL
        case window
        case display
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public func resolve(in sources: [AutomationSource]) throws -> AutomationSource {
        let candidates: [AutomationSource]
        switch kind {
        case .source:
            candidates = sources.filter { $0.id.caseInsensitiveCompare(value) == .orderedSame }
        case .chromeURL:
            candidates = Self.matches(
                sources.filter { $0.kind == .chromeTab }, value: value,
                fields: { [$0.url, $0.title, Optional($0.label)].compactMap { $0 } }
            )
        case .window:
            candidates = Self.matches(
                sources.filter { $0.kind == .window }, value: value,
                fields: { [$0.app, $0.title, Optional($0.label)].compactMap { $0 } }
            )
        case .display:
            candidates = Self.matches(
                sources.filter { $0.kind == .display }, value: value,
                fields: { [$0.title, Optional($0.label), Optional($0.id)].compactMap { $0 } }
            )
        }

        guard !candidates.isEmpty else {
            let hint = kind == .chromeURL
                ? " Run `crispctl sources` and check any Chrome warning."
                : " Run `crispctl sources` to see current IDs."
            throw CrispAutomationError.message("No source matched \"\(value)\".\(hint)")
        }
        guard candidates.count == 1 else {
            let choices = candidates.map { "\($0.id) (\($0.label))" }.joined(separator: ", ")
            throw CrispAutomationError.message(
                "Source selector \"\(value)\" is ambiguous: \(choices). Use an exact source ID."
            )
        }
        return candidates[0]
    }

    private static func matches(
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
}

public enum AutomationCommand: Codable, Sendable {
    case sources
    case start(selector: AutomationSelector, codec: AutomationCodec?)
    case status
    case stop

    public var isStart: Bool {
        if case .start = self { return true }
        return false
    }

    private enum Kind: String, Codable { case sources, start, status, stop }
    private enum CodingKeys: String, CodingKey { case type, selector, codec }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .sources: self = .sources
        case .status: self = .status
        case .stop: self = .stop
        case .start:
            self = .start(
                selector: try values.decode(AutomationSelector.self, forKey: .selector),
                codec: try values.decodeIfPresent(AutomationCodec.self, forKey: .codec)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sources:
            try values.encode(Kind.sources, forKey: .type)
        case .status:
            try values.encode(Kind.status, forKey: .type)
        case .stop:
            try values.encode(Kind.stop, forKey: .type)
        case .start(let selector, let codec):
            try values.encode(Kind.start, forKey: .type)
            try values.encode(selector, forKey: .selector)
            try values.encodeIfPresent(codec, forKey: .codec)
        }
    }
}

public struct AutomationRequest: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var clientProcessID: Int32
    public var command: AutomationCommand

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        clientProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        command: AutomationCommand
    ) {
        self.id = id
        self.createdAt = createdAt
        self.clientProcessID = clientProcessID
        self.command = command
    }
}

public struct AutomationSource: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case display
        case window
        case chromeTab = "chrome-tab"
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var app: String?
    public var title: String?
    public var url: String?
    public var width: Int?
    public var height: Int?

    public init(
        id: String, kind: Kind, label: String, app: String? = nil,
        title: String? = nil, url: String? = nil, width: Int? = nil, height: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.app = app
        self.title = title
        self.url = url
        self.width = width
        self.height = height
    }
}

public struct AutomationStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle
        case recording
        case error
    }

    public var state: State
    public var message: String?
    public var recordingFolder: String?

    public init(state: State, message: String? = nil, recordingFolder: String? = nil) {
        self.state = state
        self.message = message
        self.recordingFolder = recordingFolder
    }
}

public struct AutomationRecording: Codable, Sendable {
    public var folder: String
    public var master: String
    public var events: String

    public init(folder: String, master: String, events: String) {
        self.folder = folder
        self.master = master
        self.events = events
    }
}

public enum AutomationResult: Codable, Sendable {
    case status(AutomationStatus)
    case sources(status: AutomationStatus, sources: [AutomationSource], warnings: [String])
    case started(status: AutomationStatus, recording: AutomationRecording)
    case stopped(status: AutomationStatus, recording: AutomationRecording)
    case failure(message: String, status: AutomationStatus?)

    private enum Kind: String, Codable { case status, sources, started, stopped, error }
    private enum CodingKeys: String, CodingKey {
        case type, status, sources, warnings, recording, message
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .status:
            self = .status(try values.decode(AutomationStatus.self, forKey: .status))
        case .sources:
            self = .sources(
                status: try values.decode(AutomationStatus.self, forKey: .status),
                sources: try values.decode([AutomationSource].self, forKey: .sources),
                warnings: try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
            )
        case .started:
            self = .started(
                status: try values.decode(AutomationStatus.self, forKey: .status),
                recording: try values.decode(AutomationRecording.self, forKey: .recording)
            )
        case .stopped:
            self = .stopped(
                status: try values.decode(AutomationStatus.self, forKey: .status),
                recording: try values.decode(AutomationRecording.self, forKey: .recording)
            )
        case .error:
            self = .failure(
                message: try values.decode(String.self, forKey: .message),
                status: try values.decodeIfPresent(AutomationStatus.self, forKey: .status)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let status):
            try values.encode(Kind.status, forKey: .type)
            try values.encode(status, forKey: .status)
        case .sources(let status, let sources, let warnings):
            try values.encode(Kind.sources, forKey: .type)
            try values.encode(status, forKey: .status)
            try values.encode(sources, forKey: .sources)
            if !warnings.isEmpty { try values.encode(warnings, forKey: .warnings) }
        case .started(let status, let recording):
            try values.encode(Kind.started, forKey: .type)
            try values.encode(status, forKey: .status)
            try values.encode(recording, forKey: .recording)
        case .stopped(let status, let recording):
            try values.encode(Kind.stopped, forKey: .type)
            try values.encode(status, forKey: .status)
            try values.encode(recording, forKey: .recording)
        case .failure(let message, let status):
            try values.encode(Kind.error, forKey: .type)
            try values.encode(message, forKey: .message)
            try values.encodeIfPresent(status, forKey: .status)
        }
    }
}

public struct AutomationResponse: Codable, Sendable {
    public var requestID: String
    public var result: AutomationResult

    public init(requestID: String, result: AutomationResult) {
        self.requestID = requestID
        self.result = result
    }

    public var isSuccess: Bool {
        if case .failure = result { return false }
        return true
    }
}

public struct CrispAutomationClient {
    public let appURL: URL
    public let bundleIdentifier: String

    public init(appPath: String?, executablePath: String = CommandLine.arguments[0]) throws {
        appURL = try Self.locateApp(explicit: appPath, executablePath: executablePath)
        guard let identifier = Bundle(url: appURL)?.bundleIdentifier else {
            throw CrispAutomationError.message("Could not read the bundle identifier from \(appURL.path).")
        }
        bundleIdentifier = identifier
    }

    public func send(_ request: AutomationRequest) async throws -> AutomationResponse {
        try await ensureAppIsReady()
        let directory = CrispAutomation.directory(bundleIdentifier: bundleIdentifier)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let requestURL = CrispAutomation.requestURL(id: request.id, bundleIdentifier: bundleIdentifier)
        let responseURL = CrispAutomation.responseURL(id: request.id, bundleIdentifier: bundleIdentifier)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        let deadline = Date().addingTimeInterval(60)
        var nextNotification = Date.distantPast
        while Date() < deadline {
            try Task.checkCancellation()
            if Date() >= nextNotification {
                DistributedNotificationCenter.default().postNotificationName(
                    CrispAutomation.notification,
                    object: bundleIdentifier,
                    userInfo: ["id": request.id],
                    deliverImmediately: true
                )
                nextNotification = Date().addingTimeInterval(0.5)
            }
            if let data = try? Data(contentsOf: responseURL) {
                return try JSONDecoder().decode(AutomationResponse.self, from: data)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CrispAutomationError.message(
            "Crisp did not answer within 60 seconds. Open the app and check its permission or error state."
        )
    }

    /// Notification id that carries no request: it only asks a running Crisp
    /// to take over automation when the instance named in `ready` has quit.
    public static let readyProbeID = "ready-probe"

    private func ensureAppIsReady() async throws {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if running.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [
                "-g", appURL.path, "--args", CrispAutomation.backgroundLaunchArgument,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CrispAutomationError.message("Could not launch \(appURL.lastPathComponent).")
            }
        }

        let deadline = Date().addingTimeInterval(10)
        var nextProbe = Date.distantPast
        while Date() < deadline {
            try Task.checkCancellation()
            running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            // Several copies of one build can run at once (an installed app
            // beside a fresh `build/` one); `ready` names the instance that
            // answers, and any running copy may be it.
            if let owner = CrispAutomation.readyProcessID(bundleIdentifier: bundleIdentifier),
               running.contains(where: { $0.processIdentifier == owner }) {
                return
            }
            if !running.isEmpty, Date() >= nextProbe {
                // The named instance quit while another copy kept running:
                // a probe lets the survivor take over.
                DistributedNotificationCenter.default().postNotificationName(
                    CrispAutomation.notification,
                    object: bundleIdentifier,
                    userInfo: ["id": Self.readyProbeID],
                    deliverImmediately: true
                )
                nextProbe = Date().addingTimeInterval(0.5)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CrispAutomationError.message(
            "Crisp launched but its automation server did not become ready within 10 seconds."
        )
    }

    private static func locateApp(explicit: String?, executablePath: String) throws -> URL {
        if let explicit {
            let url = URL(fileURLWithPath: explicit).standardizedFileURL
            guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
                throw CrispAutomationError.message("No app exists at \(url.path).")
            }
            return url
        }

        let executable: URL
        if executablePath.contains("/") {
            executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        } else {
            let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
            guard let match = paths
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(executablePath) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw CrispAutomationError.message("Could not resolve \(executablePath) on PATH.")
            }
            executable = match
        }

        var url = executable.resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        throw CrispAutomationError.message(
            "This executable is not inside a Crisp app. Pass --app /path/to/Crisp.app."
        )
    }
}
