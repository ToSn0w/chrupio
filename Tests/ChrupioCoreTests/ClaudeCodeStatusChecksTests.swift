@testable import ChrupioCore
import XCTest

final class ClaudeCodeStatusChecksTests: XCTestCase {
    let binary = "/Apps/Chrupio.app/Contents/MacOS/chrupio-mcp"
    let target = ClaudeCodeSetup.Target(configDir: nil,
                                        mcpConfigFile: URL(fileURLWithPath: "/tmp/home/.claude.json"),
                                        settingsFile: URL(fileURLWithPath: "/tmp/home/.claude/settings.json"))

    func testFullyConnectedFileShowsThreeOKLines() {
        let status = ClaudeCodeSetup.Status(target: target, registeredCommand: binary, hookInstalled: true, promptHookInstalled: true)
        XCTAssertEqual(status.checks(binary: binary, components: .all), [
            .init("server OK", ok: true), .init("digest OK", ok: true), .init("prompt updates OK", ok: true),
        ])
    }

    func testMissingPiecesUseSettingsWording() {
        let status = ClaudeCodeSetup.Status(target: target, registeredCommand: nil, hookInstalled: false, promptHookInstalled: false)
        XCTAssertEqual(status.checks(binary: binary, components: .all).map(\.title), ["server missing", "digest missing", "prompt updates missing"])
        XCTAssertTrue(status.checks(binary: binary, components: .all).allSatisfy { !$0.ok })
    }

    func testAnotherCopyAndLegacyLeftovers() {
        let status = ClaudeCodeSetup.Status(target: target, registeredCommand: "/old/chrupio-mcp", hookInstalled: true,
                                            promptHookInstalled: true, legacyCommand: "/old/openkrisp-mcp")
        XCTAssertEqual(status.checks(binary: binary, components: .all), [
            .init("server points to another copy", ok: false), .init("digest OK", ok: true), .init("prompt updates OK", ok: true),
            .init("OpenKrisp leftovers (Connect replaces them)", ok: false),
        ])
    }
}
