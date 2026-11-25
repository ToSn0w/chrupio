@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import ChrupioObjC
import os

private let recorderLog = Logger(subsystem: "Chrupio", category: "recorder")

public enum AudioRecorderError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): "Audio capture failed at \(step) (OSStatus \(status))."
        case .noInputDevice: "No microphone is available."
        }
    }
}

/// Records the microphone ("You") and everything the Mac plays ("others") as two chunked 16 kHz tracks.
public final class AudioRecorder: @unchecked Sendable {
    public typealias ChunkHandler = @Sendable (AudioChunk) -> Void

    private let pipeline: ChunkPipeline
    private let queue = DispatchQueue(label: "chrupio.audio-recorder")
    private let startDate = Date()
    /// Guards engine/tap setup and teardown, which happen on the caller's thread and on device-change notifications.
    private let control = NSLock()
    private let levels = OSAllocatedUnfairLock(initialState: (mic: Float(0), system: Float(0), systemPeak: Float(0)))

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var isStopped = false
    /// The mic tap's ring, emptied on `queue`; each engine build has its own, with its own format.
    private var micDrain: RingDrain?

    private var systemTap: SystemAudioTap?
    private var systemConverter: Resampler?
    private var systemRestarting = false
    /// Set while a mic rebuild is queued or running, so stall checks don't pile up rebuilds.
    private let micRestarting = OSAllocatedUnfairLock(initialState: false)
    private let watch: OSAllocatedUnfairLock<TrackWatch> = {
        var watch = TrackWatch()
        watch.started(.mic, at: Date())
        return OSAllocatedUnfairLock(initialState: watch)
    }()

    /// Latest input levels (0...1) for the UI meter; 0 while a track delivers nothing.
    public var micLevel: Float { level(.mic) }
    public var systemLevel: Float { level(.system) }
    /// Loudest system-audio level so far. Stays 0 when macOS withholds system audio.
    public var systemPeakLevel: Float { levels.withLock { $0.systemPeak } }
    private let systemError = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Set when system audio can't be recorded. Filled in shortly after `start`, because setup runs in the background.
    public var systemCaptureError: String? { systemError.withLock { $0 } }
    /// Set while audio can't be written to disk; it stays buffered in memory until writes succeed again.
    /// After `stop`, set when the final chunks couldn't be written, so that audio is lost.
    public var writeError: String? { pipeline.writeError }

    /// - Parameter onChunk: runs on the writer queue once a chunk's WAV and sidecar are on disk.
    public init(directory: URL, onChunk: @escaping ChunkHandler) {
        pipeline = ChunkPipeline(directory: directory, onChunk: onChunk)
    }

    public func start(captureSystemAudio: Bool) throws {
        try startMicrophone()
        guard captureSystemAudio else { return }
        // Creating a process tap blocks until macOS's consent prompt is answered or times out (up to a minute or two),
        // so it must not run on the caller's (main) thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try startSystemAudio()
            } catch {
                // Mic-only recording is still useful; surface the problem instead of failing.
                systemError.withLock { $0 = error.localizedDescription }
            }
        }
    }

    /// Stops capture and returns the final, partially filled chunks once every earlier chunk is on disk and passed
    /// to `onChunk`. The final ones are not passed to `onChunk`, so the caller can account for them before deciding
    /// the meeting is finished. Both rings are drained and the writer queue emptied first.
    public func stop() -> [AudioChunk] {
        let tap = control.withLock { () -> SystemAudioTap? in
            isStopped = true
            tearDownMicrophone()
            defer { systemTap = nil }
            return systemTap
        }
        let chunks = queue.sync {
            // The mic's last frames were drained by `tearDownMicrophone`'s block, queued ahead of this one.
            tap?.drainNow()
            for track in [AudioChunk.Track.mic, .system] {
                // A track that went quiet at the end (device gone, nothing playing) still spans the whole meeting.
                padToNow(track)
            }
            return pipeline.finish()
        }
        // Tearing the tap down can block as long as creating it.
        if let tap { DispatchQueue.global(qos: .utility).async { tap.stop() } }
        return chunks
    }

    /// Rebuilds a track whose device stopped delivering audio (headset unplugged, AirPods gone, output switched).
    /// Call every few seconds while recording; failed rebuilds are retried on later calls. Never blocks the caller.
    public func reviveStalledTracks(now: Date = Date()) {
        for track in watch.withLock({ $0.dueForRestart(now: now) }) {
            recorderLog.notice("rebuilding the \(track.rawValue, privacy: .public) track: no audio, digital zero or a device change")
            switch track {
            case .mic:
                // Building an engine can block on Core Audio; keep it off the caller's (main) thread.
                guard micRestarting.withLock({ busy in defer { busy = true }; return !busy }) else { continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    restartMicrophone()
                    micRestarting.withLock { $0 = false }
                }
            case .system:
                restartSystemAudio()
            }
        }
    }

    /// Tracks that have delivered no audio for `TrackWatch.lostAfter`; their gap is recorded as silence.
    public func lostTracks(now: Date = Date()) -> Set<AudioChunk.Track> {
        watch.withLock { $0.lost(now: now) }
    }

    private func level(_ track: AudioChunk.Track) -> Float {
        if watch.withLock({ $0.isQuiet(track, now: Date()) }) { return 0 }
        return levels.withLock { track == .mic ? $0.mic : $0.system }
    }

    private func offsetNow() -> TimeInterval { Date().timeIntervalSince(startDate) }

    private func startMicrophone() throws {
        try control.withLock { try buildMicrophone() }
    }

    /// Call with `control` held. Always a fresh engine: reusing one right after a device change fails with
    /// "Failed to create tap, config change pending".
    private func buildMicrophone() throws {
        let engine = AVAudioEngine()
        try configureMicrophone(engine)
        self.engine = engine
        // Headsets connecting or the default input changing stop the engine; rebuild once the change settles.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let recorder = self else { return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { recorder.restartMicrophone() }
        }
    }

    /// Call with `control` held.
    private func tearDownMicrophone() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine { try? OKObjC.catchException { engine.inputNode.removeTap(onBus: 0); engine.stop() } }
        engine = nil
        // The tap is gone, so nothing writes to the ring any more: hand over what's left, then stop the timer.
        if let drain = micDrain {
            micDrain = nil
            queue.async { drain.drainNow(); drain.cancel() }
        }
    }

    /// Call with `control` held.
    private func configureMicrophone(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard format.commonFormat == .pcmFormatFloat32,
              let ringFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: format.channelCount, interleaved: true) else {
            throw AudioRecorderError.coreAudio("microphone format", -1)
        }
        let resampler = try Resampler(from: ringFormat)
        var reported = 0
        guard let drain = RingDrain(format: ringFormat, onBuffer: { [weak self] buffer, dropped in
            guard let self else { return }
            if dropped > reported {
                recorderLog.error("microphone dropped \(dropped - reported, privacy: .public) frames (\(dropped, privacy: .public) total)")
                reported = dropped
            }
            self.process(buffer, track: .mic, converter: resampler)
        }) else { throw AudioRecorderError.coreAudio("microphone ring", -1) }
        let ring = drain.ring
        let offset = offsetNow()
        queue.sync { pipeline.open(.mic, offset: offset) }
        // AVFoundation raises Objective-C exceptions here while a device is switching.
        var startError: Error?
        try OKObjC.catchException {
            // Copies into the preallocated ring only: no allocation or dispatch per buffer on the tap's thread.
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                ring.write(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: Int(buffer.frameLength))
            }
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let startError {
            try? OKObjC.catchException { input.removeTap(onBus: 0) }
            throw startError
        }
        micDrain = drain
        drain.start(on: queue)
    }

    private func restartMicrophone() {
        control.withLock {
            guard !isStopped else { return }
            tearDownMicrophone()
            // On failure the stale check retries (and warns after a while); the mic gap is padded once input returns.
            do { try buildMicrophone() } catch { recorderLog.error("microphone rebuild failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func restartSystemAudio() {
        let old = control.withLock { () -> SystemAudioTap?? in
            guard !isStopped, !systemRestarting else { return nil }
            systemRestarting = true
            defer { systemTap = nil }
            return .some(systemTap)
        }
        guard let old else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            old?.stop()
            // On failure the stale check fires again and retries; the gap is padded with silence once audio returns.
            do { try startSystemAudio() } catch { recorderLog.error("system audio rebuild failed: \(error.localizedDescription, privacy: .public)") }
            control.withLock { systemRestarting = false }
        }
    }

    private func startSystemAudio() throws {
        let tap = SystemAudioTap()
        var reported = 0
        try tap.start(queue: queue, onDeviceChange: { [weak self] in
            // Picked up by the next `reviveStalledTracks`, which rebuilds the tap on the new device and rate.
            self?.watch.withLock { $0.fault(.system) }
        }) { [weak self] buffer, dropped in
            guard let self else { return }
            if dropped > reported {
                // The queue stalled longer than the ring holds; padToNow fills the gap with silence.
                recorderLog.error("system audio dropped \(dropped - reported, privacy: .public) frames (\(dropped, privacy: .public) total)")
                reported = dropped
            }
            guard let converter = self.systemConverter else { return }
            self.process(buffer, track: .system, converter: converter)
        }
        let resampler = try Resampler(from: tap.format)
        let offset = offsetNow()
        let accepted = control.withLock { () -> Bool in
            // The recording may have stopped while macOS was asking for permission.
            guard !isStopped else { return false }
            systemTap = tap
            queue.sync {
                systemConverter = resampler
                // A rebuilt tap keeps writing the same track; a new writer would restart numbering and overwrite chunks.
                pipeline.open(.system, offset: offset)
            }
            watch.withLock { $0.started(.system, at: Date()) }
            return true
        }
        if !accepted { tap.stop() }
    }

    /// Runs on `queue`. Appends silence if the track is more than a second behind the clock.
    private func padToNow(_ track: AudioChunk.Track, minus pending: TimeInterval = 0) {
        guard let end = pipeline.endOffset(track) else { return }
        let lag = offsetNow() - pending - end
        guard lag > 1 else { return }
        // In pieces, so a long gap (the Mac slept mid-call) never allocates hours of samples at once.
        var remaining = Int(lag * Double(ChunkWriter.sampleRate))
        while remaining > 0 {
            let piece = min(remaining, 30 * ChunkWriter.sampleRate)
            pipeline.append([Float](repeating: 0, count: piece), to: track)
            remaining -= piece
        }
    }

    /// Runs on `queue`.
    private func process(_ buffer: AVAudioPCMBuffer, track: AudioChunk.Track, converter: Resampler) {
        // All-zero buffers for a long stretch mean a broken tap; `reviveStalledTracks` rebuilds it.
        watch.withLock { $0.heard(track, at: Date(), digitalZero: buffer.isDigitalZero) }
        let samples = converter.convert(buffer)
        let level = min(1, WAVFile.rms(samples) * 8)
        levels.withLock {
            if track == .mic { $0.mic = level } else { $0.system = level; $0.systemPeak = max($0.systemPeak, level) }
        }

        // Dropped buffers, slow device start-up or a device switch leave the track behind the clock.
        // Pad with silence so later speech keeps its real timestamp.
        padToNow(track, minus: Double(samples.count) / Double(ChunkWriter.sampleRate))
        // Cutting and disk writes run on the pipeline's writer queue, which passes each chunk on once it's written.
        pipeline.append(samples, to: track)
    }
}

/// Converts any PCM buffer to 16 kHz mono Float32 samples.
final class Resampler {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init(from input: AVAudioFormat) throws {
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ChunkWriter.sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioRecorderError.coreAudio("AVAudioConverter", -1)
        }
        // Downmix all channels instead of taking only the first one.
        converter.downmix = input.channelCount > 1
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

extension AVAudioPCMBuffer {
    /// Every sample in every channel is exactly 0 (as bytes): what a faulty tap delivers, unlike real quiet.
    var isDigitalZero: Bool {
        for buffer in UnsafeMutableAudioBufferListPointer(mutableAudioBufferList) {
            guard let data = buffer.mData else { continue }
            let bytes = UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))
            if bytes.contains(where: { $0 != 0 }) { return false }
        }
        return true
    }
}

/// Captures all audio the Mac plays (except this app) with a Core Audio process tap (macOS 14.2+).
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Read from the tap and the device in `start`; valid after it returns.
    private(set) var format: AVAudioFormat!
    /// The output device the tap's aggregate follows; watched for a switch or a sample-rate change.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "chrupio.tap-listener")
    /// Filled on the IO thread, emptied on the recorder's queue every `RingDrain.interval`; holds
    /// `RingDrain.ringSeconds`, so the queue can stall that long before frames drop.
    private var drain: RingDrain?

    /// - Parameter onDeviceChange: the default output device or its sample rate changed (AirPods switching to the
    ///   headset profile); the tap keeps the old format and has to be rebuilt.
    /// - Parameter onBuffer: runs on `queue` with interleaved Float32 audio in `format` (see `RingDrain`).
    func start(queue: DispatchQueue, onDeviceChange: @escaping @Sendable () -> Void = {},
               onBuffer: @escaping (AVAudioPCMBuffer, Int) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.uuid = UUID()
        description.name = "Chrupio meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check("kAudioTapPropertyFormat", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription))
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription), tapFormat.commonFormat == .pcmFormatFloat32 else {
            throw AudioRecorderError.coreAudio("tap format", -1)
        }
        let output = try Self.defaultOutputDevice()
        let outputUID = try Self.uid(of: output)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Chrupio Tap",
            kAudioAggregateDeviceUIDKey: "com.chrupio.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("AudioHardwareCreateAggregateDevice", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // The tap reports a format, but the aggregate runs at its device's actual rate (24 kHz on AirPods in a call).
        let deviceFormat = Self.format(tapFormat, deviceSampleRate: Self.nominalSampleRate(of: aggregateID))
        let channels = Int(deviceFormat.channelCount)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.sampleRate,
                                         channels: deviceFormat.channelCount, interleaved: true) else {
            throw AudioRecorderError.coreAudio("tap format", -1)
        }
        self.format = format
        // The IO thread is realtime: no allocation, locks or dispatch there, only a copy into a preallocated ring.
        guard let drain = RingDrain(format: format, onBuffer: onBuffer) else { throw AudioRecorderError.coreAudio("tap buffer", -1) }
        let ring = drain.ring
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (deviceFormat.isInterleaved ? channels : 1))
        try check("AudioDeviceCreateIOProcIDWithBlock", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = list.first, bytesPerFrame > 0 else { return }
            ring.write(list, frames: Int(first.mDataByteSize / bytesPerFrame))
        })
        drain.start(on: queue)
        self.drain = drain
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
        let rate = format.sampleRate
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) {
            if (try? Self.defaultOutputDevice()) != output { onDeviceChange() }
        }
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice) {
            if (try? Self.defaultOutputDevice()) != output { onDeviceChange() }
        }
        listen(output, kAudioDevicePropertyNominalSampleRate) {
            let now = Self.nominalSampleRate(of: output)
            if now > 0, now != rate { onDeviceChange() }
        }
    }

    /// The tap's format at the device's actual rate when the two disagree; the tap's own format otherwise.
    static func format(_ tap: AVAudioFormat, deviceSampleRate: Double) -> AVAudioFormat {
        guard deviceSampleRate > 0, deviceSampleRate != tap.sampleRate,
              let adjusted = AVAudioFormat(commonFormat: tap.commonFormat, sampleRate: deviceSampleRate,
                                           channels: tap.channelCount, interleaved: tap.isInterleaved) else { return tap }
        return adjusted
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
        listeners = []
        drain?.cancel()
        drain = nil
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Hands over what the ring holds now. Call on the recorder's queue.
    func drainNow() { drain?.drainNow() }

    deinit { stop() }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw AudioRecorderError.coreAudio(step, status)
        }
    }

    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw AudioRecorderError.coreAudio("default output device", status) }
        return device
    }

    private static func uid(of device: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioRecorderError.coreAudio("output device UID", status) }
        return uid.takeRetainedValue() as String
    }
}
