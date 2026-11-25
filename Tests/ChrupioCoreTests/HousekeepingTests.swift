import Network
import XCTest
@testable import ChrupioCore

/// Item #10: the 15 s safety-net cancel skips connections that are already closed.
final class ExtensionServerCancelTests: XCTestCase {
    func testSafetyNetCancelSkipsClosedConnections() {
        XCTAssertFalse(ExtensionServer.needsCancel(.cancelled))
        XCTAssertFalse(ExtensionServer.needsCancel(.failed(.posix(.ECONNRESET))))
        XCTAssertTrue(ExtensionServer.needsCancel(.ready))
        XCTAssertTrue(ExtensionServer.needsCancel(.preparing))
    }
}

/// Item #10: the meetings folder is watched instead of listed every 3 s.
final class FolderWatchTests: XCTestCase {
    func testEditInsideAMeetingFolderFiresOnceAfterTheDebounce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meeting = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = LockedCounter()
        let watch = FolderWatch(root: root, debounce: 0.3) { count.increment() }
        watch.start()
        defer { watch.stop() }
        // FSEvents can still report the folder created just before start() ("since now" covers changes
        // fseventsd hasn't journaled yet). Let that settle and count only what the writes cause.
        Thread.sleep(forTimeInterval: 1)
        let baseline = count.value
        for i in 0..<5 { try Data("\(i)".utf8).write(to: meeting.appendingPathComponent("meeting.json"), options: .atomic) }
        let deadline = Date().addingTimeInterval(5)
        while count.value == baseline, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(count.value - baseline, 1)
    }

    func testAudioWritesAloneAreIgnored() {
        XCTAssertFalse(FolderWatch.matters(["/m/x/audio/system-0001.wav", "/m/x/audio/system-0001.json"]))
        XCTAssertTrue(FolderWatch.matters(["/m/x/audio/a.wav", "/m/x/meeting.json"]))
        XCTAssertTrue(FolderWatch.matters(["/m/x"]))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
