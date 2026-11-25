import AVFoundation
import XCTest
@testable import ChrupioCore

/// Cutting and disk writes run on the pipeline's writer queue; a chunk is passed on only once it's fully on disk.
final class ChunkPipelineTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.1) }
    }

    /// Checks on disk, on the writer queue, as each chunk is passed on.
    final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [AudioChunk] = []
        private var problems: [String] = []

        func received(_ chunk: AudioChunk) {
            var problem: String?
            let sidecar = chunk.url.deletingPathExtension().appendingPathExtension("json")
            if !FileManager.default.fileExists(atPath: sidecar.path) {
                problem = "chunk \(chunk.index) passed on before its sidecar"
            } else if abs(WAVFile.duration(of: chunk.url) - chunk.duration) > 0.001 {
                problem = "chunk \(chunk.index) passed on before its WAV was complete"
            }
            lock.withLock {
                chunks.append(chunk)
                if let problem { problems.append(problem) }
            }
        }

        var all: [AudioChunk] { lock.withLock { chunks } }
        var issues: [String] { lock.withLock { problems } }
    }

    func testChunkIsPassedOnOnlyAfterItsFileIsComplete() throws {
        let directory = try directory()
        let deliveries = Deliveries()
        let pipeline = ChunkPipeline(directory: directory) { deliveries.received($0) }
        pipeline.open(.mic, offset: 0)
        pipeline.open(.system, offset: 0.5)
        // 20 ms buffers, as the drain hands them over, for 95 s on both tracks.
        let buffer = tone(0.02)
        for _ in 0..<(95 * 50) {
            pipeline.append(buffer, to: .mic)
            pipeline.append(buffer, to: .system)
        }
        XCTAssertEqual(try XCTUnwrap(pipeline.endOffset(.mic)), 95, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pipeline.endOffset(.system)), 95.5, accuracy: 0.001)
        let last = pipeline.finish()
        XCTAssertEqual(deliveries.issues, [])
        XCTAssertEqual(pipeline.pendingSamples, 0)
        for track in [AudioChunk.Track.mic, .system] {
            let delivered = deliveries.all.filter { $0.track == track }
            XCTAssertEqual(delivered.map(\.index), Array(1...delivered.count), "in order")
            let all = delivered + last.filter { $0.track == track }
            XCTAssertEqual(all.map(\.duration).reduce(0, +), 95, accuracy: 0.001, "\(track): every sample is in a chunk")
        }
        XCTAssertEqual(AudioChunkScanner.chunks(in: directory).count, deliveries.all.count + last.count)
    }

    func testFinishDrainsTheRingAndTheWriterQueue() throws {
        let directory = try directory()
        let deliveries = Deliveries()
        let pipeline = ChunkPipeline(directory: directory) { deliveries.received($0) }
        pipeline.open(.system, offset: 0)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true))
        let drain = try XCTUnwrap(RingDrain(format: format) { buffer, _ in
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            pipeline.append(samples, to: .system)
        })
        // 50 s sit in the ring, undrained, when the quit comes.
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        input.frameLength = 16_000
        for i in 0..<16_000 { input.floatChannelData![0][i] = 0.2 * sin(Float(i) * 0.1) }
        for _ in 0..<50 { drain.ring.write(UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList), frames: 16_000) }
        // What `AudioRecorder.stop` does on its queue.
        drain.drainNow()
        let last = pipeline.finish()
        XCTAssertEqual(drain.ring.available, 0)
        XCTAssertEqual(pipeline.pendingSamples, 0)
        XCTAssertEqual((deliveries.all + last).map(\.duration).reduce(0, +), 50, accuracy: 0.001)
        XCTAssertEqual(deliveries.issues, [])
        // Audio after the quit is ignored instead of written to a closed track.
        pipeline.append(tone(1), to: .system)
        XCTAssertEqual(pipeline.pendingSamples, 0)
        XCTAssertEqual(pipeline.finish(), [])
    }

    func testWriteErrorIsReportedWithoutAskingTheWriterQueue() throws {
        let directory = try directory()
        let pipeline = ChunkPipeline(directory: directory) { _ in }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("mic-0001.wav"), withIntermediateDirectories: true)
        pipeline.open(.mic, offset: 0)
        pipeline.append(tone(31), to: .mic)
        _ = pipeline.finish()
        XCTAssertNotNil(pipeline.writeError, "the final write failed too")
    }
}
