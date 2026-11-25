import AVFoundation
import XCTest
@testable import ChrupioCore

/// The system tap's IO thread copies into a fixed ring instead of allocating; the recorder's queue drains it.
final class SampleRingTests: XCTestCase {
    private func stereo(frames: Int, interleaved: Bool, first: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<frames {
            // Left is the frame number, right its negative.
            let left = first + Float(frame)
            if interleaved {
                data[0][frame * 2] = left
                data[0][frame * 2 + 1] = -left
            } else {
                data[0][frame] = left
                data[1][frame] = -left
            }
        }
        return buffer
    }

    private func drain(_ ring: SampleRing, max: Int = 100) -> [Float] {
        var out = [Float](repeating: 0, count: max * ring.channels)
        let frames = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: max) }
        return Array(out.prefix(frames * ring.channels))
    }

    func testBothLayoutsComeOutInterleaved() throws {
        for interleaved in [true, false] {
            let ring = SampleRing(channels: 2, capacity: 8)
            let buffer = try stereo(frames: 3, interleaved: interleaved, first: 1)
            ring.write(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: 3)
            XCTAssertEqual(drain(ring), [1, -1, 2, -2, 3, -3], "interleaved: \(interleaved)")
            XCTAssertEqual(ring.available, 0)
        }
    }

    func testWrapsAroundAndCountsWhatDidNotFit() throws {
        let ring = SampleRing(channels: 2, capacity: 4)
        let first = try stereo(frames: 3, interleaved: false, first: 1)
        ring.write(UnsafeMutableAudioBufferListPointer(first.mutableAudioBufferList), frames: 3)
        XCTAssertEqual(drain(ring, max: 2), [1, -1, 2, -2])
        // One frame buffered, room for three: the last two of five are dropped.
        let second = try stereo(frames: 5, interleaved: false, first: 10)
        ring.write(UnsafeMutableAudioBufferListPointer(second.mutableAudioBufferList), frames: 5)
        XCTAssertEqual(ring.dropped, 2)
        XCTAssertEqual(drain(ring), [3, -3, 10, -10, 11, -11, 12, -12])
        XCTAssertEqual(ring.dropped, 2)
    }

    func testSixtySecondRingWrapsManyTimesWithoutLosingAFrame() throws {
        let rate = 48_000
        let ring = SampleRing(channels: 2, capacity: Int(Double(rate) * RingDrain.ringSeconds))
        XCTAssertEqual(ring.capacity, 60 * rate)
        // 10 ms device buffers for 150 s; the consumer falls 50 s behind before catching up, three times over.
        let slice = rate / 100
        var next: Float = 0
        var expected: Float = 0
        var mismatches = 0
        var out = [Float](repeating: 0, count: rate * 2)
        func consume() {
            while true {
                let frames = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxFrames: rate) }
                guard frames > 0 else { return }
                for frame in 0..<frames {
                    if out[frame * 2] != expected || out[frame * 2 + 1] != -expected { mismatches += 1 }
                    // Float holds every integer up to 2^24 exactly; wrap the counter below that.
                    expected = expected == 9_999_999 ? 0 : expected + 1
                }
            }
        }
        for step in 0..<15_000 {
            let buffer = try stereo(frames: slice, interleaved: step % 2 == 0, first: 0)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<slice {
                if step % 2 == 0 { data[0][frame * 2] = next; data[0][frame * 2 + 1] = -next } else { data[0][frame] = next; data[1][frame] = -next }
                next = next == 9_999_999 ? 0 : next + 1
            }
            ring.write(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: slice)
            if step % 5_000 == 4_999 { consume() }
        }
        consume()
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(expected, next, "every frame came out")
        XCTAssertEqual(ring.dropped, 0)
        XCTAssertEqual(ring.available, 0)
    }

    func testDrainHandsOverABacklogInBatches() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        var received = 0
        var batches = 0
        let drain = try XCTUnwrap(RingDrain(format: format) { buffer, dropped in
            received += Int(buffer.frameLength)
            batches += 1
            XCTAssertEqual(dropped, 0)
        })
        let buffer = try stereo(frames: 4_800, interleaved: false, first: 0)
        for _ in 0..<50 { drain.ring.write(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: 4_800) }
        drain.drainNow()
        XCTAssertEqual(received, 240_000)
        XCTAssertEqual(batches, 5, "1 s per batch")
        XCTAssertEqual(drain.ring.available, 0)
    }
}
