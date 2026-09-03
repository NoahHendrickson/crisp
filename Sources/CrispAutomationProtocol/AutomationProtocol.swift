import Foundation

public enum CrispAutomation {
    public static let notification = Notification.Name("com.noey.crisp.automation.request")

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
}

public enum AutomationCommand: String, Codable, Sendable {
    case sources
    case start
    case status
    case stop
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
}

public struct AutomationRequest: Codable, Sendable {
    public var id: String
    public var createdAt: Date
    public var command: AutomationCommand
    public var selector: AutomationSelector?
    public var codec: String?

    public init(
        id: String = UUID().uuidString,
        command: AutomationCommand,
        selector: AutomationSelector? = nil,
        codec: String? = nil
    ) {
        self.id = id
        self.createdAt = Date()
        self.command = command
        self.selector = selector
        self.codec = codec
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

public struct AutomationResponse: Codable, Sendable {
    public var requestID: String
    public var ok: Bool
    public var error: String?
    public var warnings: [String]
    public var status: AutomationStatus?
    public var sources: [AutomationSource]?
    public var recording: AutomationRecording?

    public init(
        requestID: String,
        ok: Bool,
        error: String? = nil,
        warnings: [String] = [],
        status: AutomationStatus? = nil,
        sources: [AutomationSource]? = nil,
        recording: AutomationRecording? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.error = error
        self.warnings = warnings
        self.status = status
        self.sources = sources
        self.recording = recording
    }
}
