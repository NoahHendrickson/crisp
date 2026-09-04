import CrispAutomationProtocol
import Foundation

@main
struct CrispControl {
    static let usage = """
    usage: crispctl <command> [options]

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
            let client = try CrispAutomationClient(appPath: invocation.appPath)
            let response = try await client.send(invocation.request)
            printResponse(response, json: invocation.json)
            exit(response.isSuccess ? 0 : 1)
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
                throw CrispAutomationError.message("\(option) requires a value.")
            }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }

        let json = takeFlag("--json")
        let appPath = try takeOption("--app")
        guard let rawCommand = args.first else {
            throw CrispAutomationError.message("Missing command.\n\n\(usage)")
        }
        args.removeFirst()

        let codec = try takeOption("--codec").map { try AutomationCodec(argument: $0) }
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
            throw CrispAutomationError.message("Unexpected argument: \(args[0])")
        }

        let command: AutomationCommand
        switch rawCommand {
        case "sources": command = .sources
        case "status": command = .status
        case "stop": command = .stop
        case "start":
            guard selectors.count == 1 else {
                throw CrispAutomationError.message("Start requires exactly one source selector.")
            }
            command = .start(selector: selectors[0], codec: codec)
        default:
            throw CrispAutomationError.message("Unknown command \"\(rawCommand)\".\n\n\(usage)")
        }
        if rawCommand != "start", !selectors.isEmpty || codec != nil {
            throw CrispAutomationError.message("Source and codec options are only valid with start.")
        }
        return Invocation(
            request: AutomationRequest(command: command), json: json, appPath: appPath
        )
    }

    static func printResponse(_ response: AutomationResponse, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(response) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }

        switch response.result {
        case .status(let status):
            printStatus(status)
        case .sources(let status, let sources, let warnings):
            for warning in warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
            for source in sources {
                let detail = source.url.map { "\t\($0)" } ?? ""
                print("\(source.id)\t\(source.label)\(detail)")
            }
            if sources.isEmpty { printStatus(status) }
        case .started(let status, let recording), .stopped(let status, let recording):
            printStatus(status)
            print("master\t\(recording.master)")
            print("events\t\(recording.events)")
        case .failure(let message, let status):
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            if let status, let folder = status.recordingFolder {
                FileHandle.standardError.write(Data("recording\t\(folder)\n".utf8))
            }
        }
    }

    static func printStatus(_ status: AutomationStatus) {
        var line = status.state.rawValue
        if let folder = status.recordingFolder { line += "\t\(folder)" }
        if let message = status.message { line += "\t\(message)" }
        print(line)
    }
}
