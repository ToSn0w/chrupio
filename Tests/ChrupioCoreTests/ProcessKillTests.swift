import Foundation
@testable import ChrupioCore
import XCTest

final class ProcessKillTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chrupio-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testChildIgnoringSIGTERMIsKilledAfterTheGrace() throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let url = try script("trap '' TERM\ntouch '\(ready.path)'\nwhile true; do sleep 0.1; done")
        let process = Process()
        process.executableURL = url
        let exited = expectation(description: "exited")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        let started = Date()
        while !FileManager.default.fileExists(atPath: ready.path), Date().timeIntervalSince(started) < 5 { usleep(10_000) }
        let start = Date()
        ProcessGroupKill.terminate(process, grace: 0.5)
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4, "SIGKILL came before the grace")
    }

    func testTimeoutKillsAGrandchildThatHoldsStdoutOpen() async throws {
        // The grandchild ignores SIGTERM and keeps stdout open; without the group kill and the read bound this hangs.
        // The timeout must leave sh time to start, ignore TERM and echo: a SIGTERM that lands before the trap kills
        // sh with empty stdout (seen once at 0.3 s under a loaded full test run).
        let url = try script("trap '' TERM\necho partial\n(trap '' TERM; while true; do sleep 0.1; done) &\nwhile true; do sleep 0.1; done")
        let start = Date()
        let result = try await ProcessRunner.run(url, arguments: [], timeout: 2)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.stdout, "partial\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
    }

    func testOutputReadIsBoundedWhenAGrandchildOutlivesTheChild() async throws {
        // The child exits at once; a detached grandchild keeps the pipe open for 30 s.
        let url = try script("echo done\nsleep 30 &")
        let start = Date()
        let result = try await ProcessRunner.run(url, arguments: [], timeout: 60)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }
}
