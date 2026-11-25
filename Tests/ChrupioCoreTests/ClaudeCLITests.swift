import Foundation
@testable import ChrupioCore
import XCTest

final class ClaudeCLITests: XCTestCase {
    func testKnownPathsKeepTheSummarizerOrder() {
        XCTAssertEqual(ClaudeCLI.knownPaths(home: "/Users/x"),
                       ["/Users/x/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/Users/x/.claude/local/claude"])
    }

    func testShellOutputTakesTheLastAbsoluteExecutableLine() {
        let output = "Welcome to zsh\n/Users/x/.nvm/versions/node/v22/bin/claude\n"
        XCTAssertEqual(ClaudeCLI.path(fromShell: output) { $0.hasSuffix("/claude") }?.path, "/Users/x/.nvm/versions/node/v22/bin/claude")
        XCTAssertNil(ClaudeCLI.path(fromShell: "claude not found") { _ in true })
        XCTAssertNil(ClaudeCLI.path(fromShell: "/Users/x/bin/claude") { _ in false }, "must be executable")
        XCTAssertNil(ClaudeCLI.path(fromShell: "") { _ in true })
    }

    func testLocateAsksTheShellOnlyWhenNoKnownPathExists() async {
        let asked = Counter()
        let known = await ClaudeCLI.locate(home: "/Users/x", isExecutable: { $0 == "/usr/local/bin/claude" }) {
            asked.increment(); return "/Users/x/.volta/bin/claude"
        }
        XCTAssertEqual(known?.path, "/usr/local/bin/claude")
        XCTAssertEqual(asked.value, 0)

        let fromShell = await ClaudeCLI.locate(home: "/Users/x", isExecutable: { $0 == "/Users/x/.volta/bin/claude" }) {
            asked.increment(); return "/Users/x/.volta/bin/claude"
        }
        XCTAssertEqual(fromShell?.path, "/Users/x/.volta/bin/claude")
        XCTAssertEqual(asked.value, 1)

        let none = await ClaudeCLI.locate(home: "/Users/x", isExecutable: { _ in false }) { nil }
        XCTAssertNil(none)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
