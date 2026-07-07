import XCTest
import Foundation
@testable import Linter

/// The partitioner is what makes batching safe: one linter process for many files, then
/// results split back per file. These cover the real reporter shapes we ship defaults for.
final class LintOutputPartitionerTests: XCTestCase {

    private func entryCount(_ json: String) throws -> Int {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        return array.count
    }

    func testSwiftLintGroupsMultipleIssuesPerFile() throws {
        let a = "/proj/A.swift", b = "/proj/B.swift"
        let output = """
        [{"file":"\(a)","rule_id":"r1"},{"file":"\(a)","rule_id":"r2"},{"file":"\(b)","rule_id":"r3"}]
        """
        let result = LintOutputPartitioner.partition(output, files: [a, b], resultsKey: nil, fileField: "file")
        XCTAssertEqual(try entryCount(result[a] ?? ""), 2)
        XCTAssertEqual(try entryCount(result[b] ?? ""), 1)
    }

    func testESLintAttributesByFilePathField() throws {
        let x = "/proj/x.ts", y = "/proj/y.ts"
        let output = """
        [{"filePath":"\(x)","messages":[{"ruleId":"no-unused"}]},{"filePath":"\(y)","messages":[]}]
        """
        let result = LintOutputPartitioner.partition(output, files: [x, y], resultsKey: nil, fileField: "filePath")
        XCTAssertEqual(try entryCount(result[x] ?? ""), 1)
        XCTAssertEqual(try entryCount(result[y] ?? ""), 1)
    }

    func testGolangciNestedResultsAndRelativePaths() throws {
        let main = "/proj/main.go", util = "/proj/pkg/util.go"
        // golangci nests issues under "Issues" and reports relative paths.
        let output = """
        {"Issues":[{"Pos":{"Filename":"main.go"}},{"Pos":{"Filename":"pkg/util.go"}},{"Pos":{"Filename":"main.go"}}]}
        """
        let result = LintOutputPartitioner.partition(output, files: [main, util], resultsKey: "Issues", fileField: "Pos.Filename")
        XCTAssertEqual(try entryCount(result[main] ?? ""), 2)
        XCTAssertEqual(try entryCount(result[util] ?? ""), 1)
    }

    func testCleanFileGetsEmptyArray() throws {
        let a = "/proj/A.swift"
        let result = LintOutputPartitioner.partition("[]", files: [a], resultsKey: nil, fileField: "file")
        XCTAssertEqual(result[a], "[]")
    }

    func testEveryInputFileIsRepresentedEvenWhenAbsentFromOutput() throws {
        let a = "/proj/A.swift", b = "/proj/B.swift"
        let output = #"[{"file":"\#(a)","rule_id":"r1"}]"#
        let result = LintOutputPartitioner.partition(output, files: [a, b], resultsKey: nil, fileField: "file")
        XCTAssertEqual(try entryCount(result[a] ?? ""), 1)
        XCTAssertEqual(result[b], "[]", "a file with no issues is clean, not missing")
    }

    func testNonJSONMultiFileCannotAttributeSoEmpty() {
        let a = "/proj/A.swift", b = "/proj/B.swift"
        let result = LintOutputPartitioner.partition("fatal: boom", files: [a, b], resultsKey: nil, fileField: "file")
        XCTAssertEqual(result[a], "")
        XCTAssertEqual(result[b], "")
    }

    func testNonJSONSingleFileReturnsRawOutput() {
        let a = "/proj/A.swift"
        let result = LintOutputPartitioner.partition("fatal: boom", files: [a], resultsKey: nil, fileField: "file")
        XCTAssertEqual(result[a], "fatal: boom")
    }
}
