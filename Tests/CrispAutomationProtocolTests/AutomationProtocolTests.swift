import CrispAutomationProtocol
import XCTest

final class AutomationProtocolTests: XCTestCase {
    func testStartCommandRoundTripsWithRequiredSelectorAndTypedCodec() throws {
        let request = AutomationRequest(
            command: .start(
                selector: AutomationSelector(kind: .chromeURL, value: "localhost:5173"),
                codec: .proRes422
            )
        )

        let decoded = try JSONDecoder().decode(
            AutomationRequest.self,
            from: JSONEncoder().encode(request)
        )
        guard case .start(let selector, let codec) = decoded.command else {
            return XCTFail("Expected a start command")
        }
        XCTAssertEqual(selector.kind, .chromeURL)
        XCTAssertEqual(selector.value, "localhost:5173")
        XCTAssertEqual(codec, .proRes422)
        XCTAssertEqual(decoded.clientProcessID, request.clientProcessID)
    }

    func testStartCommandWithoutSelectorIsRejected() {
        let malformed = Data(
            #"{"id":"one","createdAt":0,"clientProcessID":1,"command":{"type":"start"}}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationRequest.self, from: malformed))
    }

    func testSelectorPrefersExactMatchAndRejectsAmbiguity() throws {
        let sources = [
            AutomationSource(id: "window:1", kind: .window, label: "Notes — Draft", app: "Notes"),
            AutomationSource(id: "window:2", kind: .window, label: "Notes — Final", app: "Notes"),
        ]

        let exact = try AutomationSelector(kind: .source, value: "WINDOW:2").resolve(in: sources)
        XCTAssertEqual(exact.id, "window:2")
        XCTAssertThrowsError(
            try AutomationSelector(kind: .window, value: "Notes").resolve(in: sources)
        )
    }

    func testFailureResponseHasOneDiscriminatedResult() throws {
        let response = AutomationResponse(
            requestID: "request",
            result: .failure(
                message: "Could not finish recording",
                status: AutomationStatus(
                    state: .error,
                    message: "Could not finish recording",
                    recordingFolder: "/tmp/salvaged"
                )
            )
        )
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])

        XCTAssertEqual(result["type"] as? String, "error")
        XCTAssertEqual(result["message"] as? String, "Could not finish recording")
        XCTAssertNil(result["sources"])
        XCTAssertNil(result["recording"])
    }
}
