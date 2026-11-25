import AVFoundation
import XCTest
@testable import ChrupioCore

/// Item #9: a tap that delivers digital zero, or whose device or sample rate changed, is rebuilt.
final class TapFaultTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func watching(_ track: AudioChunk.Track) -> TrackWatch {
        var watch = TrackWatch()
        watch.started(track, at: start)
        return watch
    }

    func testTenSecondsOfDigitalZeroIsAFault() {
        var watch = watching(.mic)
        for second in 0...9 { watch.heard(.mic, at: at(Double(second)), digitalZero: true) }
        XCTAssertEqual(watch.dueForRestart(now: at(9)), [], "under 10 s of zeros is fine")
        watch.heard(.mic, at: at(10.5), digitalZero: true)
        XCTAssertEqual(watch.dueForRestart(now: at(10.5)), [.mic])
        XCTAssertEqual(watch.dueForRestart(now: at(11)), [], "not again right away")
    }

    func testRealAudioClearsTheZeroRun() {
        var watch = watching(.mic)
        for second in 0...8 { watch.heard(.mic, at: at(Double(second)), digitalZero: true) }
        watch.heard(.mic, at: at(9), digitalZero: false)
        for second in 10...15 { watch.heard(.mic, at: at(Double(second)), digitalZero: true) }
        XCTAssertEqual(watch.dueForRestart(now: at(15)), [])
    }

    func testZerosAfterARebuildBackOff() {
        // A silent system output (nothing playing) is also digital zero; don't rebuild every 10 s all call long.
        var watch = watching(.system)
        var restarts: [TimeInterval] = []
        for tenth in 0...1500 {
            let now = at(Double(tenth) / 10)
            watch.heard(.system, at: now, digitalZero: true)
            if !watch.dueForRestart(now: now).isEmpty { restarts.append(Double(tenth) / 10) }
        }
        XCTAssertEqual(restarts.count, 4, "\(restarts)") // ~10, 30, 70, 150 s
        XCTAssertEqual(restarts.first ?? 0, 10, accuracy: 0.2)
    }

    func testDeviceChangeFaultIsDueOnNextCheck() {
        var watch = watching(.system)
        watch.heard(.system, at: at(1), digitalZero: false)
        watch.fault(.system)
        XCTAssertEqual(watch.dueForRestart(now: at(1.5)), [.system])
        XCTAssertEqual(watch.dueForRestart(now: at(2)), [])
    }

    func testFaultOnAnUnwatchedTrackIsIgnored() {
        var watch = watching(.mic)
        watch.fault(.system)
        XCTAssertEqual(watch.dueForRestart(now: at(1)), [])
    }

    func testDigitalZeroBufferDetection() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 480) }
        XCTAssertTrue(buffer.isDigitalZero)
        buffer.floatChannelData![1][479] = 1e-7
        XCTAssertFalse(buffer.isDigitalZero, "quiet but real noise is not a fault")
    }

    func testFormatUsesTheDeviceRateWhenTheTapDisagrees() throws {
        let tap = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        XCTAssertEqual(SystemAudioTap.format(tap, deviceSampleRate: 24_000).sampleRate, 24_000)
        XCTAssertEqual(SystemAudioTap.format(tap, deviceSampleRate: 24_000).channelCount, 2)
        XCTAssertEqual(SystemAudioTap.format(tap, deviceSampleRate: 0).sampleRate, 48_000)
        XCTAssertTrue(SystemAudioTap.format(tap, deviceSampleRate: 48_000) === tap)
    }
}
