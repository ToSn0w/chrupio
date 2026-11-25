import Foundation

/// When each audio track last delivered sound and was last rebuilt. Devices deliver buffers continuously
/// (silence included), so a gap means the device went away.
public struct TrackWatch: Sendable {
    /// A track this long without audio is rebuilt, and rebuilt again at most this often while it stays down.
    public static let restartAfter: TimeInterval = 5
    /// A track this long without audio counts as lost: the user is warned, since that stretch is recorded as silence.
    public static let lostAfter: TimeInterval = 15
    /// The level meter drops to 0 once a track has been quiet this long, instead of freezing at its last value.
    public static let levelTimeout: TimeInterval = 1

    /// A track delivering only exact zeros this long is broken: a process tap can do that while sound is audible.
    public static let digitalZeroAfter: TimeInterval = 10
    /// Rebuilds for digital zero back off up to this, since a silent output (nothing playing) is digital zero too.
    public static let digitalZeroMaxInterval: TimeInterval = 120

    private var lastAudio: [AudioChunk.Track: Date] = [:]
    private var lastRestart: [AudioChunk.Track: Date] = [:]
    /// Start of the current run of all-zero buffers.
    private var zeroSince: [AudioChunk.Track: Date] = [:]
    private var lastZeroRestart: [AudioChunk.Track: Date] = [:]
    private var zeroInterval: [AudioChunk.Track: TimeInterval] = [:]
    /// Device or sample-rate changes waiting for a rebuild.
    private var faults: Set<AudioChunk.Track> = []

    public init() {}

    /// Starts watching a track. A rebuild keeps the old time, so a track that comes back without sound stays stalled.
    public mutating func started(_ track: AudioChunk.Track, at date: Date) {
        if lastAudio[track] == nil { lastAudio[track] = date }
    }

    /// Records audio from a watched track.
    /// - Parameter digitalZero: every sample in the buffer was exactly 0.
    public mutating func heard(_ track: AudioChunk.Track, at date: Date, digitalZero: Bool = false) {
        guard lastAudio[track] != nil else { return }
        lastAudio[track] = date
        if !digitalZero {
            zeroSince[track] = nil
            lastZeroRestart[track] = nil
            zeroInterval[track] = nil
        } else if zeroSince[track] == nil {
            zeroSince[track] = date
        }
    }

    /// The track's device changed (default output switched, sample rate changed): rebuild it on the next check.
    public mutating func fault(_ track: AudioChunk.Track) {
        if lastAudio[track] != nil { faults.insert(track) }
    }

    /// Tracks due for a rebuild; each is then not due again for `restartAfter`.
    public mutating func dueForRestart(now: Date) -> [AudioChunk.Track] {
        let stalled = lastAudio.keys.filter { track in
            silence(track, now: now) > Self.restartAfter && now.timeIntervalSince(lastRestart[track] ?? .distantPast) > Self.restartAfter
        }
        let zeroed = lastAudio.keys.filter { track in
            guard let since = zeroSince[track], now.timeIntervalSince(since) >= Self.digitalZeroAfter else { return false }
            let interval = zeroInterval[track] ?? Self.digitalZeroAfter
            return lastZeroRestart[track].map { now.timeIntervalSince($0) >= interval } ?? true
        }
        for track in zeroed {
            if lastZeroRestart[track] != nil {
                zeroInterval[track] = min(Self.digitalZeroMaxInterval, (zeroInterval[track] ?? Self.digitalZeroAfter) * 2)
            } else {
                zeroInterval[track] = Self.digitalZeroAfter * 2
            }
            lastZeroRestart[track] = now
        }
        let due = Set(stalled).union(zeroed).union(faults)
        faults = []
        for track in due { lastRestart[track] = now }
        return due.sorted { $0.rawValue < $1.rawValue }
    }

    /// Tracks that have delivered no audio for `lostAfter` or longer.
    public func lost(now: Date) -> Set<AudioChunk.Track> {
        Set(lastAudio.keys.filter { silence($0, now: now) >= Self.lostAfter })
    }

    /// Whether the track's level is stale and should read 0.
    public func isQuiet(_ track: AudioChunk.Track, now: Date) -> Bool {
        silence(track, now: now) > Self.levelTimeout
    }

    private func silence(_ track: AudioChunk.Track, now: Date) -> TimeInterval {
        lastAudio[track].map { now.timeIntervalSince($0) } ?? 0
    }
}
