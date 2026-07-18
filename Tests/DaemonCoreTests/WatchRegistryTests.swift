import DaemonCore
import IPC
import XCTest

final class WatchRegistryTests: XCTestCase {

    func testRegisterAndMatchGlob() async {
        let registry = WatchRegistry()
        await registry.register("reg-1", serverID: "sourcekit-lsp", globs: ["**/*.swift"])

        let matches = await registry.serversMatching(path: "/project/Sources/Foo.swift")
        XCTAssertEqual(matches, ["sourcekit-lsp"])
    }

    func testNoMatchForUnregisteredPattern() async {
        let registry = WatchRegistry()
        await registry.register("reg-1", serverID: "sourcekit-lsp", globs: ["**/*.swift"])

        let matches = await registry.serversMatching(path: "/project/index.ts")
        XCTAssertTrue(matches.isEmpty)
    }

    func testUnregisterRemovesEntry() async {
        let registry = WatchRegistry()
        await registry.register("reg-1", serverID: "sourcekit-lsp", globs: ["**/*.swift"])
        await registry.unregister("reg-1")

        let matches = await registry.serversMatching(path: "/project/Foo.swift")
        XCTAssertTrue(matches.isEmpty)
    }

    func testMultipleServersCanMatchSamePath() async {
        let registry = WatchRegistry()
        await registry.register("reg-1", serverID: "server-a", globs: ["**/*.swift"])
        await registry.register("reg-2", serverID: "server-b", globs: ["**/*.swift"])

        let matches = await registry.serversMatching(path: "/project/Foo.swift")
        XCTAssertEqual(Set(matches), Set(["server-a", "server-b"]))
    }

    func testLiteralFilenameGlob() async {
        let registry = WatchRegistry()
        await registry.register("reg-1", serverID: "sourcekit-lsp", globs: ["**/Package.swift"])

        let yes = await registry.serversMatching(path: "/project/Package.swift")
        let no  = await registry.serversMatching(path: "/project/OtherFile.swift")
        XCTAssertFalse(yes.isEmpty)
        XCTAssertTrue(no.isEmpty)
    }

    func testUnregisterUnknownIDIsNoop() async {
        let registry = WatchRegistry()
        await registry.register("reg-1", serverID: "sourcekit-lsp", globs: ["**/*.swift"])
        await registry.unregister("does-not-exist")  // must not crash

        let matches = await registry.serversMatching(path: "/project/Foo.swift")
        XCTAssertFalse(matches.isEmpty)
    }
}

// MARK: - Glob matching unit tests (isExcludedPath)

final class GlobMatchingTests: XCTestCase {

    func testExcludedGitPath() {
        XCTAssertTrue(isExcludedPath("/project/.git/COMMIT_EDITMSG"))
    }

    func testExcludedNodeModules() {
        XCTAssertTrue(isExcludedPath("/project/node_modules/lodash/index.js"))
    }

    func testExcludedBuild() {
        XCTAssertTrue(isExcludedPath("/project/.build/debug/Module.o"))
    }

    func testExcludedDerivedData() {
        XCTAssertTrue(isExcludedPath("/Users/me/Library/Developer/Xcode/DerivedData/App/Build/foo.o"))
    }

    func testNonExcludedSourceFile() {
        XCTAssertFalse(isExcludedPath("/project/Sources/App.swift"))
    }

    func testNonExcludedTsConfig() {
        XCTAssertFalse(isExcludedPath("/project/tsconfig.json"))
    }

    func testExcludedVenv() {
        XCTAssertTrue(isExcludedPath("/project/.venv/lib/python3.11/site-packages/foo.py"))
        XCTAssertTrue(isExcludedPath("/project/venv/lib/site-packages/bar.py"))
    }

    func testExcludedVendor() {
        XCTAssertTrue(isExcludedPath("/project/vendor/github.com/pkg/errors/errors.go"))
    }

    func testExcludedDist() {
        XCTAssertTrue(isExcludedPath("/project/dist/bundle.js"))
    }

    func testExcludedYarn() {
        XCTAssertTrue(isExcludedPath("/project/.yarn/cache/lodash-npm-4.17.21.zip"))
    }
}
