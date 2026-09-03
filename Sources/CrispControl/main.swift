import AppKit
import CrispAutomationProtocol
import Darwin
import Foundation

@main
struct CrispControl {
    static let usage = """
    usage: crisp <command> [options]

      sources [--json]
          List displays, app windows, and Chrome tabs with current source IDs.
      start (--source ID | --chrome-url TEXT | --window TEXT | --display TEXT)
            [--codec hevc10|prores422|prores4444] [--json]
          Start recording one unambiguous source.
      status [--json]
          Report whether Crisp is idle, recording, or showing an error.
      stop [--json]
          Stop cleanly and print the recording artifact paths.

    Global option: --app /path/to/Crisp.app
    """

    static func main() async {
        do {
            let invocation = try parse(Array(CommandLine.arguments.dropFirst()))
            let app = try locateApp(explicit: invocation.appPath)
            let bundle = Bundle(url: app)
            guard let bundleIdentifier = bundle?.bundleIdentifier else {
                throw ControlError.message("Could not read the bundle identifier from \(app.path).")
            }
            try launch(app)
            let response = try await send(invocation.request, bundleIdentifier: bundleIdentifier)
            printResponse(response, json: invocation.json)
            exit(response.ok ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    struct Invocation {
        var request: AutomationRequest
        var json: Bool
        var appPath: String?
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        var args = arguments
        if args.isEmpty || args.contains("--help") || args.first == "help" {
            print(usage)
            exit(0)
        }
        func takeFlag(_ flag: String) -> Bool {
            guard let index = args.firstIndex(of: flag) else { return false }
            args.remove(at: index)
            return true
        }
        func takeOption(_ option: String) throws -> String? {
            guard let index = args.firstIndex(of: option) else { return nil }
            guard index + 1 < args.count else {
                throw ControlError.message("\(option) requires a value.")
            }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }

        let json = takeFlag("--json")
        let appPath = try takeOption("--app")
        guard let rawCommand = args.first, let command = AutomationCommand(rawValue: rawCommand) else {
            throw ControlError.message("Unknown command.\n\n\(usage)")
        }
        args.removeFirst()

        let codec = try takeOption("--codec")
        var selectors: [AutomationSelector] = []
        if let value = try takeOption("--source") {
            selectors.append(AutomationSelector(kind: .source, value: value))
        }
        if let value = try takeOption("--chrome-url") {
            selectors.append(AutomationSelector(kind: .chromeURL, value: value))
        }
        if let value = try takeOption("--window") {
            selectors.append(AutomationSelector(kind: .window, value: value))
        }
        if let value = try takeOption("--display") {
            selectors.append(AutomationSelector(kind: .display, value: value))
        }
        guard args.isEmpty else {
            throw ControlError.message("Unexpected argument: \(args[0])")
        }
        if command == .start, selectors.count != 1 {
            throw ControlError.message("Start requires exactly one source selector.")
        }
        if command != .start, !selectors.isEmpty || codec != nil {
            throw ControlError.message("Source and codec options are only valid with start.")
        }
        return Invocation(
            request: AutomationRequest(command: command, selector: selectors.first, codec: codec),
            json: json,
            appPath: appPath
        )
    }

    static func locateApp(explicit: String?) throws -> URL {
        if let explicit {
            let url = URL(fileURLWithPath: explicit).standardizedFileURL
            guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
                throw ControlError.message("No app exists at \(url.path).")
            }
            return url
        }

        let argument = CommandLine.arguments[0]
        let executable: URL
        if argument.contains("/") {
            executable = URL(fileURLWithPath: argument).standardizedFileURL
        } else {
            let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
            guard let match = paths
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(argument) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw ControlError.message("Could not resolve \(argument) on PATH.")
            }
            executable = match
        }
        var url = executable.resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        throw ControlError.message(
            "This crisp binary is not inside a Crisp app. Pass --app /path/to/Crisp.app."
        )
    }

    static func launch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ControlError.message("Could not launch \(app.lastPathComponent).")
        }
    }

    static func send(
        _ request: AutomationRequest, bundleIdentifier: String
    ) async throws -> AutomationResponse {
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
        throw ControlError.message(
            "Crisp did not answer within 60 seconds. Open the app and check its permission or error state."
        )
    }

    static func printResponse(_ response: AutomationResponse, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }
        for warning in response.warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
        if let error = response.error {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return
        }
        if let sources = response.sources {
            for source in sources {
                let detail = source.url.map { "\t\($0)" } ?? ""
                print("\(source.id)\t\(source.label)\(detail)")
            }
        }
        if let status = response.status {
            var line = status.state.rawValue
            if let folder = status.recordingFolder { line += "\t\(folder)" }
            if let message = status.message { line += "\t\(message)" }
            print(line)
        }
        if let recording = response.recording {
            print("master\t\(recording.master)")
            print("events\t\(recording.events)")
        }
    }

    enum ControlError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }
}
