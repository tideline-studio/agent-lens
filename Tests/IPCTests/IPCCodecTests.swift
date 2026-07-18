import IPC
import XCTest

// Tests observable behavior: the JSON codec roundtrip and wire-format shape.
// If a message type can't survive encode→decode it will never transit the socket correctly.

final class IPCCodecTests: XCTestCase {

    // MARK: - Command roundtrips

    func testAllCommandVariantsRoundtrip() throws {
        let commands: [Command] = [
            .start(idleSeconds: 7200, logLevel: .info),
            .start(idleSeconds: 30, logLevel: .debug),
            .stop,
            .status,
            .diagnose(files: ["/a/b.swift", "/c/d.swift"], timeoutSeconds: 5),
            .diagnose(files: [], timeoutSeconds: 0.5),
            .lint(files: ["/x/y.ts"]),
            .lint(files: []),
            .check(files: ["/a/b.swift", "/c/d.ts"], timeoutSeconds: 5),
            .check(files: [], timeoutSeconds: 0.5)
        ]
        for cmd in commands {
            XCTAssertEqual(try roundTrip(cmd), cmd, "roundtrip failed for \(cmd)")
        }
    }

    func testCommandStartWireShape() throws {
        let data = try JSONEncoder().encode(Command.start(idleSeconds: 3600, logLevel: .warn))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "start")
        XCTAssertEqual(obj["idle"] as? Double, 3600)
        XCTAssertEqual(obj["logLevel"] as? String, "warn")
    }

    func testCommandDiagnoseWireShape() throws {
        let data = try JSONEncoder().encode(Command.diagnose(files: ["/foo.swift"], timeoutSeconds: 5))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "diagnose")
        XCTAssertEqual(obj["files"] as? [String], ["/foo.swift"])
        XCTAssertEqual(obj["timeout"] as? Double, 5)
    }

    func testCommandCheckWireShape() throws {
        let data = try JSONEncoder().encode(Command.check(files: ["/foo.swift"], timeoutSeconds: 5))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "check")
        XCTAssertEqual(obj["files"] as? [String], ["/foo.swift"])
        XCTAssertEqual(obj["timeout"] as? Double, 5)
    }

    func testPayloadCheckWireShapeKeepsMapsSeparate() throws {
        let data = try JSONEncoder().encode(Payload.check(
            diagnostics: [:],
            lint: ["foo.swift": "raw output"]
        ))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "check")
        XCTAssertNotNil(obj["diagnostics"], "diagnose results live under their own key")
        let lint = try XCTUnwrap(obj["lint"] as? [String: String])
        XCTAssertEqual(lint["foo.swift"], "raw output")
    }

    func testUnknownCommandTypeThrows() {
        let badJSON = Data(#"{"type":"unknown_cmd"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Command.self, from: badJSON))
    }

    // MARK: - Payload roundtrips

    func testAllPayloadVariantsRoundtrip() throws {
        let payloads: [Payload] = [
            .ack,
            .status(StatusReport(servers: [], uptimeSeconds: 42)),
            .status(StatusReport(
                servers: [ServerStatus(language: "swift", readinessState: .ready)],
                uptimeSeconds: 100
            )),
            .diagnose([:]),
            .diagnose(["foo.swift": FileDiagnostics(
                diagnostics: [Diagnostic(
                    range: DiagnosticRange(
                        start: Position(line: 0, character: 0),
                        end: Position(line: 0, character: 5)
                    ),
                    severity: .error,
                    message: "cannot find 'foo' in scope"
                )],
                readinessState: .ready,
                stale: false
            )]),
            .lint([:]),
            .lint(["bar.ts": #"[{"ruleId":"no-unused-vars","severity":1,"message":"unused var","line":3,"column":1}]"#]),
            .check(diagnostics: [:], lint: [:]),
            .check(
                diagnostics: ["foo.swift": FileDiagnostics(
                    diagnostics: [Diagnostic(
                        range: DiagnosticRange(
                            start: Position(line: 1, character: 2),
                            end: Position(line: 1, character: 8)
                        ),
                        severity: .warning,
                        message: "unused variable"
                    )],
                    readinessState: .ready,
                    stale: false
                )],
                lint: ["foo.swift": "foo.swift:1:2: warning: trailing whitespace"]
            )
        ]
        for payload in payloads {
            XCTAssertEqual(try roundTrip(payload), payload, "roundtrip failed for \(payload)")
        }
    }

    func testAckWireShape() throws {
        let data = try JSONEncoder().encode(Payload.ack)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "ack")
    }

    // MARK: - ResponseResult

    func testOkResultRoundtrip() throws {
        let r = ResponseResult.ok(.ack)
        XCTAssertEqual(try roundTrip(r), r)
    }

    func testErrResultRoundtrip() throws {
        let r = ResponseResult.err(ErrorPayload(code: .noDaemon, message: "no daemon"))
        XCTAssertEqual(try roundTrip(r), r)
    }

    func testErrWireShape() throws {
        let data = try JSONEncoder().encode(ResponseResult.err(ErrorPayload(code: .timeout, message: "timed out")))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["ok"])
        let err = try XCTUnwrap(obj["err"] as? [String: Any])
        XCTAssertEqual(err["code"] as? String, "timeout")
        XCTAssertEqual(err["message"] as? String, "timed out")
    }

    // MARK: - Request / Response correlation

    func testRequestPreservesID() throws {
        let req = Request(id: "abc-123", command: .status)
        XCTAssertEqual(try roundTrip(req), req)
        XCTAssertEqual(req.v, protocolVersion)
    }

    func testResponsePreservesID() throws {
        let resp = Response(id: "abc-123", result: .ok(.ack))
        XCTAssertEqual(try roundTrip(resp), resp)
    }

    // MARK: - Version mismatch detection

    func testVersionFieldDecodes() throws {
        let json = Data(#"{"v":99,"id":"x","result":{"ok":{"type":"ack"}}}"#.utf8)
        let resp = try JSONDecoder().decode(Response.self, from: json)
        XCTAssertEqual(resp.v, 99)
        XCTAssertNotEqual(resp.v, protocolVersion)
    }

    func testErrorCodeAllValuesRoundtrip() throws {
        let all: [ErrorCode] = [
            .noDaemon, .noServer, .serverNotReady,
            .fileNotFound, .pathOutsideRoot, .pathIsDirectory,
            .lspError, .timeout, .versionMismatch, .internalError
        ]
        for code in all {
            let payload = ErrorPayload(code: code, message: "test")
            XCTAssertEqual(try roundTrip(payload), payload, "roundtrip failed for \(code)")
        }
    }

    // MARK: - Helpers

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
