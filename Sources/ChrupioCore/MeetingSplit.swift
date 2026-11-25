import Foundation

extension MeetingStore {
    public enum SplitFailure: LocalizedError, Equatable {
        case outsideMeeting(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .outsideMeeting(let offset): "\(Int(offset)) s is not inside the meeting."
            }
        }
    }

    /// Splits one recording into two meetings at `offset` seconds: two calls the recorder merged into one.
    /// Audio chunks after the offset move to the new meeting and a chunk spanning it is cut in two. The transcript and
    /// speaker events move with their time, the summary is dropped (it described both calls), and with `retranscribe`
    /// both are left "transcribing" so the app redoes them, and then the summaries, the next time it starts.
    public func split(_ id: UUID, at offset: TimeInterval, retranscribe: Bool) throws -> (first: Meeting, second: Meeting) {
        try withWriteLock { try splitUnlocked(id, at: offset, retranscribe: retranscribe) }
    }

    /// `split` for a caller that already holds the write lock (orphan recovery).
    func splitUnlocked(_ id: UUID, at offset: TimeInterval, retranscribe: Bool) throws -> (first: Meeting, second: Meeting) {
        do {
            var first = try load(id)
            guard offset > 0, offset < first.duration else { throw SplitFailure.outsideMeeting(offset) }
            let chunks = AudioChunkScanner.chunks(in: audioDirectory(for: id))
            let cut = offset

            let second = Meeting(
                title: first.title, platform: first.platform, startedAt: first.startedAt.addingTimeInterval(cut), endedAt: first.endedAt,
                attendees: first.attendees, selfName: first.selfName, url: first.url,
                segments: first.segments.filter { $0.start >= offset }.map {
                    TranscriptSegment(start: $0.start - cut, end: $0.end - cut, speaker: $0.speaker, text: $0.text)
                },
                speakerEvents: first.speakerEvents.filter { $0.time >= offset }.map { $0.shifted(by: -cut) },
                status: retranscribe ? .transcribing : .done, language: first.language
            )
            first.segments = first.segments.filter { $0.start < offset }
            first.speakerEvents = first.speakerEvents.filter { $0.time < offset }
            first.endedAt = first.startedAt.addingTimeInterval(cut)
            first.summary = nil
            first.error = nil
            first.summaryError = nil
            if retranscribe { first.status = .transcribing }

            // Failures undo every step, newest first, so no audio is left without a meeting. The new meeting is saved
            // before any audio moves: if the process dies midway, every chunk still sits under a saved meeting.
            var undo: [() -> Void] = []
            do {
                let fm = FileManager.default
                let destination = audioDirectory(for: second.id)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                undo.append { [directory = directory(for: second.id)] in try? fm.removeItem(at: directory) }
                try writeUnlocked(second)

                let sidecar = { (url: URL) in url.deletingPathExtension().appendingPathExtension("json") }
                var head: (chunk: AudioChunk, samples: [Float])?
                var counts: [AudioChunk.Track: Int] = [:]
                for chunk in chunks where chunk.startOffset + chunk.duration > cut {
                    counts[chunk.track, default: 0] += 1
                    var moved = chunk
                    moved.index = counts[chunk.track]!
                    moved.url = destination.appendingPathComponent(String(format: "%@-%04d.wav", chunk.track.rawValue, moved.index))
                    if chunk.startOffset >= cut {
                        // A compressed chunk moves as it is; only cut chunks are written again (as WAV).
                        moved.url = moved.url.deletingPathExtension().appendingPathExtension(chunk.url.pathExtension)
                        moved.startOffset = chunk.startOffset - cut
                        try fm.moveItem(at: chunk.url, to: moved.url)
                        undo.append { try? fm.moveItem(at: moved.url, to: chunk.url) }
                        if let data = try? Data(contentsOf: sidecar(chunk.url)) {
                            try fm.removeItem(at: sidecar(chunk.url))
                            undo.append { try? data.write(to: sidecar(chunk.url), options: .atomic) }
                        }
                    } else {
                        // The tail goes to the new meeting now; the original is cut last, once everything else worked.
                        let samples = try WAVFile.read(chunk.url)
                        let split = min(samples.count, Int((cut - chunk.startOffset) * Double(ChunkWriter.sampleRate)))
                        var kept = chunk
                        kept.duration = Double(split) / Double(ChunkWriter.sampleRate)
                        kept.rms = WAVFile.rms(Array(samples[..<split]))
                        head = (kept, Array(samples[..<split]))
                        moved.startOffset = 0
                        moved.duration = Double(samples.count - split) / Double(ChunkWriter.sampleRate)
                        moved.rms = WAVFile.rms(Array(samples[split...]))
                        try WAVFile.write(Array(samples[split...]), sampleRate: ChunkWriter.sampleRate, to: moved.url)
                    }
                    try JSONEncoder().encode(moved).write(to: sidecar(moved.url), options: .atomic)
                }
                if let (head, samples) = head {
                    var kept = head
                    let original = kept.url
                    let audio = try Data(contentsOf: original)
                    let json = try? Data(contentsOf: sidecar(original))
                    // The cut head of a compressed chunk becomes a WAV; the next retention pass compresses it again.
                    kept.url = original.deletingPathExtension().appendingPathExtension("wav")
                    undo.append { [kept] in
                        if kept.url != original { try? fm.removeItem(at: kept.url) }
                        try? audio.write(to: original, options: .atomic)
                        if let json { try? json.write(to: sidecar(original), options: .atomic) }
                    }
                    try WAVFile.write(samples, sampleRate: ChunkWriter.sampleRate, to: kept.url)
                    if kept.url != original { try fm.removeItem(at: original) }
                    try JSONEncoder().encode(kept).write(to: sidecar(kept.url), options: .atomic)
                }
                try writeUnlocked(first)
            } catch {
                undo.reversed().forEach { $0() }
                throw error
            }
            return (first, second)
        }
    }
}
