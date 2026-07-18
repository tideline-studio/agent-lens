import DaemonCore
import Dependencies
import Foundation
import IPC
import Linter
import LSPClient
import XCTest

// MARK: - MockLinterRunner

private struct MockLinterRunner: LinterRunner, Sendable {
    let language: Language
    let output: String

    func lint(files: [String]) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: files.map { ($0, output) })
    }
}

// MARK: - Helpers

private func lintDispatch(core: DaemonCore, command: Command) async -> ResponseResult {
    await core.dispatch(Request(command: command))
}

private func makeLintCore(root: URL, factory: @escaping @Sendable (Language, LinterConfig) -> (any LinterRunner)?) -> DaemonCore {
    withDependencies {
        $0.linterFactory = factory
    } operation: {
        DaemonCore(root: root, logger: .init(label: "test"))
    }
}

// MARK: - Tests

final class LintHandlerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testLintReturnsRawOutputForSingleFile() async throws {
        let path = root.appendingPathComponent("foo.swift").path
        let raw = #"[{"rule_id":"trailing_whitespace","reason":"msg","character":1,"file":"\#(path)","severity":"Warning","type":"t","line":3}]"#
        let core = makeLintCore(root: root) { lang, _ in
            lang == .swift ? MockLinterRunner(language: .swift, output: raw) : nil
        }

        let result = await lintDispatch(core: core, command: .lint(files: [path]))
        guard case .ok(.lint(let files)) = result else {
            XCTFail("expected .lint, got \(result)"); return
        }
        XCTAssertEqual(files[path], raw)
    }

    func testLintReturnsResultForEveryFileInBatch() async throws {
        let paths = ["a.swift", "b.swift", "c.swift"]
            .map { root.appendingPathComponent($0).path }

        let raw = #"[{"rule_id":"r","reason":"oops","character":1,"file":"f","severity":"Error","type":"t","line":1}]"#
        let core = makeLintCore(root: root) { lang, _ in
            lang == .swift ? MockLinterRunner(language: .swift, output: raw) : nil
        }

        let result = await lintDispatch(core: core, command: .lint(files: paths))
        guard case .ok(.lint(let files)) = result else {
            XCTFail("expected .lint"); return
        }
        XCTAssertEqual(files.count, 3)
        for path in paths {
            XCTAssertEqual(files[path], raw, "\(path) should have raw output")
        }
    }

    func testLintPathOutsideRootReturnsError() async throws {
        let core = makeLintCore(root: root) { _, _ in nil }
        let result = await lintDispatch(core: core, command: .lint(files: ["/etc/passwd"]))
        guard case .err(let e) = result else {
            XCTFail("expected .err"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }

    // MARK: - check (composition of diagnose + lint)

    func testCheckReturnsLintResultsUnderCheckPayload() async throws {
        let path = root.appendingPathComponent("foo.swift").path
        let raw = "foo.swift:1:1: warning: something"
        let core = makeLintCore(root: root) { lang, _ in
            lang == .swift ? MockLinterRunner(language: .swift, output: raw) : nil
        }

        let result = await lintDispatch(
            core: core,
            command: .check(files: [path], timeoutSeconds: 1)
        )
        // No LSP router is started here, so diagnostics are empty — the point of this
        // test is that check carries the lint half through in one .check payload.
        guard case .ok(.check(_, let lint)) = result else {
            XCTFail("expected .check, got \(result)"); return
        }
        XCTAssertEqual(lint[path], raw)
    }

    func testCheckPathOutsideRootReturnsError() async throws {
        let core = makeLintCore(root: root) { _, _ in nil }
        let result = await lintDispatch(
            core: core,
            command: .check(files: ["/etc/passwd"], timeoutSeconds: 1)
        )
        guard case .err(let e) = result else {
            XCTFail("expected .err"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }
}

// MARK: - ProcessLinter invocation

private actor InvocationBox {
    var args: [String] = []
    var stdin: Data?
    func record(args: [String], stdin: Data?) { self.args = args; self.stdin = stdin }
}

final class ProcessLinterTests: XCTestCase {

    // Regression: linting via SwiftLint's --use-stdin reports a null path, so it
    // can't evaluate included/excluded globs in .swiftlint.yml and applies rules
    // unconditionally. The linter must pass the real file path and not use stdin.
    func testLintPassesFilePathAndNeverUsesStdin() async throws {
        let box = InvocationBox()
        let runner = ProcessRunner(
            run: { _, args, _, stdin in
                await box.record(args: args, stdin: stdin)
                return ""
            }
        )
        let spec = LinterConfig.LinterSpec(command: "swiftlint", args: ["lint", "--reporter", "json", "$FILE"])
        let linter = withDependencies {
            $0.processRunner = runner
        } operation: {
            ProcessLinter(language: .swift, spec: spec)
        }

        _ = try await linter.lint(files: ["/proj/Sources/Foo.swift"])

        let args = await box.args
        let stdin = await box.stdin
        XCTAssertTrue(args.contains("/proj/Sources/Foo.swift"), "the real file path must be passed as an argument")
        XCTAssertFalse(args.contains("--use-stdin"), "must not use --use-stdin")
        XCTAssertNil(stdin, "must not pipe file content via stdin")
    }
}
