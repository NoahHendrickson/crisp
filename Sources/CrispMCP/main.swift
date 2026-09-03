import CrispAutomationProtocol
import Foundation

@main
struct CrispMCP {
    static let supportedProtocolVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    static func main() {
        do {
            let control = try ControlCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            let server = Server(control: control)
            while let line = readLine() {
                server.receive(line)
            }
        } catch {
            FileHandle.standardError.write(Data("crisp-mcp: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private final class Server {
    private let control: ControlCommand

    init(control: ControlCommand) {
        self.control = control
    }

    func receive(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let message = try JSONSerialization.jsonObject(with: data)
            if let batch = message as? [Any] {
                guard !batch.isEmpty else {
                    write(protocolError(id: NSNull(), code: -32600, message: "Invalid Request"))
                    return
                }
                let responses = batch.compactMap(handle)
                if !responses.isEmpty { write(responses) }
            } else if let response = handle(message) {
                write(response)
            }
        } catch {
            write(protocolError(id: NSNull(), code: -32700, message: "Parse error"))
        }
    }

    private func handle(_ message: Any) -> [String: Any]? {
        guard let request = message as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return protocolError(id: NSNull(), code: -32600, message: "Invalid Request")
        }

        guard let id = request["id"] else {
            return nil
        }

        switch method {
        case "initialize":
            let params = request["params"] as? [String: Any]
            let requested = params?["protocolVersion"] as? String
            let version = requested.flatMap {
                CrispMCP.supportedProtocolVersions.contains($0) ? $0 : nil
            } ?? CrispMCP.supportedProtocolVersions[0]
            let serverVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "dev"
            return success(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "crisp", "version": serverVersion],
                "instructions": "Use Crisp to record requested app, project, browser, or web-view demonstrations. List sources when the target is uncertain, start recording before computer-use interactions, and always stop recording cleanly afterward. Do not start a second recording while one is active.",
            ])

        case "ping":
            return success(id: id, result: [:])

        case "tools/list":
            return success(id: id, result: ["tools": tools])

        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return protocolError(id: id, code: -32602, message: "tools/call requires a tool name")
            }
            guard tools.contains(where: { $0["name"] as? String == name }) else {
                return protocolError(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments: [String: Any]
            if let rawArguments = params["arguments"] {
                guard let object = rawArguments as? [String: Any] else {
                    return protocolError(id: id, code: -32602, message: "Tool arguments must be an object")
                }
                arguments = object
            } else {
                arguments = [:]
            }
            let result: [String: Any]
            do {
                let response = try control.call(tool: name, arguments: arguments)
                result = toolResult(response: response, isError: !response.ok)
            } catch {
                result = toolError(error.localizedDescription)
            }
            return success(id: id, result: result)

        default:
            return protocolError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private var tools: [[String: Any]] {
        let emptySchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
        ]
        return [
            [
                "name": "list_sources",
                "title": "List Crisp recording sources",
                "description": "List the displays, native app windows, and Google Chrome tabs Crisp can currently record. Use this when the target is uncertain or a convenient selector was ambiguous.",
                "inputSchema": emptySchema,
                "annotations": readOnlyAnnotations,
            ],
            [
                "name": "start_recording",
                "title": "Start a Crisp recording",
                "description": "Start recording exactly one source. Prefer source_id from list_sources; chrome_url, window, and display are convenient case-insensitive selectors that must match one source. After this succeeds, perform the requested demonstration with computer use and then call stop_recording.",
                "inputSchema": startSchema,
                "annotations": [
                    "readOnlyHint": false,
                    "destructiveHint": false,
                    "idempotentHint": false,
                    "openWorldHint": false,
                ],
            ],
            [
                "name": "get_recording_status",
                "title": "Get Crisp recording status",
                "description": "Report whether Crisp is idle, recording, or showing an error. Use this to diagnose uncertainty; do not start another recording when the state is recording.",
                "inputSchema": emptySchema,
                "annotations": readOnlyAnnotations,
            ],
            [
                "name": "stop_recording",
                "title": "Stop a Crisp recording",
                "description": "Stop the active recording cleanly, wait for movie finalization, and return the recording folder plus master.mov and events.json paths. Always call this after the requested computer-use demonstration.",
                "inputSchema": emptySchema,
                "annotations": [
                    "readOnlyHint": false,
                    "destructiveHint": false,
                    "idempotentHint": false,
                    "openWorldHint": false,
                ],
            ],
        ]
    }

    private var readOnlyAnnotations: [String: Any] {
        [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        ]
    }

    private var startSchema: [String: Any] {
        let selector: (String) -> [String: Any] = { description in
            ["type": "string", "minLength": 1, "description": description]
        }
        return [
            "type": "object",
            "properties": [
                "source_id": selector("Exact source ID returned by list_sources."),
                "chrome_url": selector("URL, host, or title text that identifies one Chrome tab."),
                "window": selector("App name, window title, or label that identifies one native window."),
                "display": selector("Display name or ID that identifies one display."),
                "codec": [
                    "type": "string",
                    "enum": ["hevc10", "prores422", "prores4444"],
                    "description": "Optional master recording codec. Omit for Crisp's current default.",
                ],
            ],
            "oneOf": [
                ["required": ["source_id"]],
                ["required": ["chrome_url"]],
                ["required": ["window"]],
                ["required": ["display"]],
            ],
            "additionalProperties": false,
        ]
    }

    private func toolResult(response: AutomationResponse, isError: Bool) -> [String: Any] {
        let object = (try? encodeObject(response)) ?? [:]
        let text = (try? prettyJSON(object)) ?? (response.error ?? "Crisp returned an unreadable response.")
        return [
            "content": [["type": "text", "text": text]],
            "structuredContent": object,
            "isError": isError,
        ]
    }

    private func toolError(_ message: String) -> [String: Any] {
        let object: [String: Any] = ["ok": false, "error": message]
        return [
            "content": [["type": "text", "text": message]],
            "structuredContent": object,
            "isError": true,
        ]
    }

    private func encodeObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.message("Could not encode Crisp's response.")
        }
        return object
    }

    private func prettyJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func protocolError(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
    }

    private func write(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

private struct ControlCommand {
    let executable: URL
    let app: URL?

    init(arguments: [String]) throws {
        var args = arguments
        if args.contains("--help") || args.contains("-h") {
            print("usage: crisp-mcp [--crispctl /path/to/crispctl] [--app /path/to/Crisp.app]")
            exit(0)
        }

        func take(_ option: String) throws -> String? {
            guard let index = args.firstIndex(of: option) else { return nil }
            guard index + 1 < args.count else { throw MCPError.message("\(option) requires a value.") }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }

        let explicitControl = try take("--crispctl")
        let explicitApp = try take("--app")
        guard args.isEmpty else { throw MCPError.message("Unexpected argument: \(args[0])") }

        if let explicitControl {
            executable = URL(fileURLWithPath: explicitControl).standardizedFileURL
        } else {
            executable = Self.siblingControlExecutable()
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPError.message("crispctl is not executable at \(executable.path).")
        }

        if let explicitApp {
            let url = URL(fileURLWithPath: explicitApp).standardizedFileURL
            guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
                throw MCPError.message("No app exists at \(url.path).")
            }
            app = url
        } else {
            app = nil
        }
    }

    func call(tool: String, arguments: [String: Any]) throws -> AutomationResponse {
        var command: [String]
        switch tool {
        case "list_sources":
            try requireEmpty(arguments)
            command = ["sources"]
        case "get_recording_status":
            try requireEmpty(arguments)
            command = ["status"]
        case "stop_recording":
            try requireEmpty(arguments)
            command = ["stop"]
        case "start_recording":
            command = ["start"]
            let selectors = [
                ("source_id", "--source"),
                ("chrome_url", "--chrome-url"),
                ("window", "--window"),
                ("display", "--display"),
            ].compactMap { key, option -> (String, String)? in
                guard let value = arguments[key] as? String, !value.isEmpty else { return nil }
                return (option, value)
            }
            guard selectors.count == 1 else {
                throw MCPError.message("start_recording requires exactly one of source_id, chrome_url, window, or display.")
            }
            command += [selectors[0].0, selectors[0].1]
            if let codec = arguments["codec"] as? String {
                guard ["hevc10", "prores422", "prores4444"].contains(codec) else {
                    throw MCPError.message("codec must be hevc10, prores422, or prores4444.")
                }
                command += ["--codec", codec]
            }
            let allowed = Set(["source_id", "chrome_url", "window", "display", "codec"])
            let extras = Set(arguments.keys).subtracting(allowed)
            guard extras.isEmpty else {
                throw MCPError.message("Unexpected start_recording argument: \(extras.sorted()[0])")
            }
        default:
            throw MCPError.message("Unknown tool: \(tool)")
        }

        command.append("--json")
        if let app { command += ["--app", app.path] }
        return try run(command)
    }

    private func requireEmpty(_ arguments: [String: Any]) throws {
        guard arguments.isEmpty else {
            throw MCPError.message("This tool does not accept arguments.")
        }
    }

    private func run(_ arguments: [String]) throws -> AutomationResponse {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let response = try? JSONDecoder().decode(AutomationResponse.self, from: data) {
            return response
        }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw MCPError.message(detail.isEmpty
            ? "crispctl exited with status \(process.terminationStatus) without a JSON response."
            : detail)
    }

    private static func siblingControlExecutable() -> URL {
        let raw = CommandLine.arguments[0]
        let server = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        return server.deletingLastPathComponent().appendingPathComponent("crispctl")
    }
}

private enum MCPError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
