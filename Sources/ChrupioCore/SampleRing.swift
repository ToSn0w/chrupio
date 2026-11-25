@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// A fixed-size single-producer, single-consumer ring of interleaved Float32 frames. The producer is an audio
/// thread (Core Audio's realtime IO thread, AVAudioEngine's tap), which must not allocate, lock or wait: `write`
/// only copies, and drops what doesn't fit.
final class SampleRing: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Frames ever written and read; their difference is what's buffered.
    private let written = Atomic<Int>(0)
    private let readCount = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    /// Frames the producer had to throw away because the consumer fell behind.
    var dropped: Int { droppedFrames.load(ordering: .relaxed) }
    var available: Int { written.load(ordering: .acquiring) - readCount.load(ordering: .relaxed) }

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        storage = .allocate(capacity: channels * capacity)
        storage.initialize(repeating: 0, count: channels * capacity)
    }

    deinit { storage.deallocate() }

    /// Producer side. Takes interleaved buffers (one buffer of `channels` channels) or non-interleaved ones
    /// (one buffer per channel) of Float32 samples.
    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let start = written.load(ordering: .relaxed)
        let free = capacity - (start - readCount.load(ordering: .acquiring))
        let count = min(frames, free)
        if count < frames { droppedFrames.add(frames - count, ordering: .relaxed) }
        guard count > 0 else { return }
        let interleaved = list.count == 1
        for frame in 0..<count {
            let slot = ((start + frame) % capacity) * channels
            for channel in 0..<channels {
                let buffer = list[interleaved ? 0 : min(channel, list.count - 1)]
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    storage[slot + channel] = 0
                    continue
                }
                let index = interleaved ? frame * Int(buffer.mNumberChannels) + min(channel, Int(buffer.mNumberChannels) - 1) : frame
                storage[slot + channel] = data[index]
            }
        }
        written.store(start + count, ordering: .releasing)
    }

    /// Consumer side. Copies up to `maxFrames` interleaved frames into `destination`; returns how many.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let start = readCount.load(ordering: .relaxed)
        let count = min(maxFrames, written.load(ordering: .acquiring) - start)
        for frame in 0..<count {
            let slot = ((start + frame) % capacity) * channels
            (destination + frame * channels).update(from: storage + slot, count: channels)
        }
        readCount.store(start + count, ordering: .releasing)
        return count
    }
}

/// A `SampleRing` for one track and the timer that empties it on the recorder's queue into one reused buffer.
final class RingDrain: @unchecked Sendable {
    /// Seconds of audio the ring holds, so the recorder's queue can stall this long before frames drop.
    static let ringSeconds = 60.0
    /// Drained this often.
    static let interval: DispatchTimeInterval = .milliseconds(20)
    /// Frames handed over per call; a backlog is drained in several calls.
    static let batchSeconds = 1.0

    let ring: SampleRing
    let format: AVAudioFormat
    private let buffer: AVAudioPCMBuffer
    private let onBuffer: (AVAudioPCMBuffer, Int) -> Void
    private var timer: DispatchSourceTimer?

    /// - Parameter format: interleaved Float32, the layout `onBuffer` receives.
    /// - Parameter onBuffer: runs on the draining queue with up to `batchSeconds` of audio in `format`. The buffer is
    ///   reused, so it must not be kept. The second argument is the total frames dropped so far because the ring was full.
    init?(format: AVAudioFormat, seconds: Double = RingDrain.ringSeconds, onBuffer: @escaping (AVAudioPCMBuffer, Int) -> Void) {
        guard format.commonFormat == .pcmFormatFloat32, format.isInterleaved, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, format.sampleRate * Self.batchSeconds))) else { return nil }
        self.format = format
        self.buffer = buffer
        self.onBuffer = onBuffer
        ring = SampleRing(channels: Int(format.channelCount), capacity: Int(format.sampleRate * seconds))
    }

    /// Drains every `interval` on `queue` until `cancel`.
    func start(on queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.drainNow() }
        timer.resume()
        self.timer = timer
    }

    /// Hands over everything buffered. Call on the draining queue (the ring has one consumer).
    func drainNow() {
        guard let data = buffer.floatChannelData?[0] else { return }
        while true {
            let frames = ring.read(into: data, maxFrames: Int(buffer.frameCapacity))
            guard frames > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            onBuffer(buffer, ring.dropped)
        }
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
