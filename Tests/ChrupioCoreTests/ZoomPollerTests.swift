import Foundation
@testable import ChrupioCore
import XCTest

private final class ScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var scans: [(participants: Bool, labels: Bool)] = []
    var all: [(participants: Bool, labels: Bool)] { lock.withLock { scans } }
    func add(_ participants: Bool, _ labels: Bool) { lock.withLock { scans.append((participants, labels)) } }
}

@MainActor
final class ZoomPollerTests: XCTestCase {
    private let snapshot = ZoomMonitor.Snapshot(isRunning: true, hasMeetingWindow: true, title: "Zoom Meeting", participants: [], selfName: nil)

    /// Polls once and waits for the scan it started, if any.
    private func poll(_ poller: ZoomPoller, at now: Date, recordingZoom: Bool) async {
        poller.poll(now: now, recordingZoom: recordingZoom)
        let deadline = Date().addingTimeInterval(5)
        while poller.isScanning, Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func testWithoutAZoomRecordingWindowsAreCheckedEveryFiveSecondsWithoutParticipants() async {
        let log = ScanLog()
        let snapshot = snapshot
        let poller = ZoomPoller { log.add($0, $1); return snapshot }
        let start = Date()
        await poll(poller, at: start, recordingZoom: false)
        await poll(poller, at: start + 2, recordingZoom: false)
        await poll(poller, at: start + 4.9, recordingZoom: false)
        await poll(poller, at: start + 5, recordingZoom: false)
        XCTAssertEqual(log.all.count, 2)
        XCTAssertTrue(log.all.allSatisfy { !$0.participants && !$0.labels })
        XCTAssertEqual(poller.snapshot, snapshot)
    }

    func testDuringAZoomRecordingEveryPollScansAndParticipantsEveryTenSeconds() async {
        let log = ScanLog()
        let snapshot = snapshot
        let poller = ZoomPoller { log.add($0, $1); return snapshot }
        var landed: [Bool] = []
        poller.onSnapshot = { _, participants, _ in landed.append(participants) }
        let start = Date()
        for offset in [0.0, 2, 4, 10, 10.5, 12] { await poll(poller, at: start + offset, recordingZoom: true) }
        XCTAssertEqual(log.all.map(\.participants), [true, false, false, false, true, false])
        XCTAssertTrue(log.all.allSatisfy(\.labels))
        XCTAssertEqual(landed, log.all.map(\.participants))
    }

    func testOneScanAtATimeAndASkippedParticipantScanIsRetriedNextPoll() async {
        let release = DispatchSemaphore(value: 0)
        let log = ScanLog()
        let snapshot = snapshot
        let poller = ZoomPoller { participants, labels in
            log.add(participants, labels)
            if log.all.count == 1 { release.wait() }
            return snapshot
        }
        let start = Date()
        poller.poll(now: start, recordingZoom: false)
        XCTAssertTrue(poller.isScanning)
        // The call is now recorded, but the slow detection scan still runs: nothing new starts.
        poller.poll(now: start + 2, recordingZoom: true)
        release.signal()
        await poll(poller, at: start + 2, recordingZoom: false)
        XCTAssertEqual(log.all.count, 1)
        // The participant scan that was skipped wasn't counted as done, so the next poll asks for it.
        await poll(poller, at: start + 4, recordingZoom: true)
        XCTAssertEqual(log.all.map(\.participants), [false, true])
    }
}
