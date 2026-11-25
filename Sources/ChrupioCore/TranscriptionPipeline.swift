import Foundation

/// How transcribed chunks become a meeting's transcript.
public struct TranscriptionPipeline: Sendable {
    /// A chunk's transcript lines, made off the main thread from the engine's result.
    public struct ChunkResult: Sendable {
        public var segments: [TranscriptSegment]
        public var language: String?
        public var speechCount: Int

        public init(segments: [TranscriptSegment], language: String?, speechCount: Int) {
            self.segments = segments
            self.language = language
            self.speechCount = speechCount
        }
    }

    /// While a meeting's chunks are finishing it is saved at most this often; once more when it finishes.
    public static let persistInterval: TimeInterval = 30

    /// The lines of `chunk`, with project spellings corrected and, for call audio, voice features from its samples.
    /// Reads (and for compressed audio decodes) the chunk, so call it off the main thread.
    public static func prepare(_ chunk: AudioChunk, transcription: Transcription,
                               correct: (@Sendable (String) -> String)?) -> ChunkResult {
        var segments = TranscriptAssembler.segments(for: chunk, speech: transcription.speech)
        if let correct {
            segments = segments.map { segment in
                var fixed = segment
                fixed.text = correct(segment.text)
                // A line split at a speaker change is rebuilt from its words.
                fixed.words = segment.words?.map { var word = $0; word.text = correct($0.text); return word }
                return fixed
            }
        }
        if chunk.track == .system, let samples = try? WAVFile.read(chunk.url) {
            segments = VoiceFeatures.annotate(segments, chunk: chunk, samples: samples)
        }
        return ChunkResult(segments: segments, language: transcription.language, speechCount: transcription.speech.count)
    }

    /// Adds a chunk's lines to the meeting in time order and names only those from the speaker events, instead of
    /// sorting and re-attributing the whole transcript per chunk. Lines with the same start keep the existing ones first,
    /// as appending and a stable sort would.
    public static func merge(_ new: [TranscriptSegment], into meeting: inout Meeting) {
        guard !new.isEmpty else { return }
        var added = meeting
        added.segments = stableSorted(new)
        SpeakerAttribution.apply(to: &added, onlyUnnamed: true)
        let existing = isSorted(meeting.segments) ? meeting.segments : stableSorted(meeting.segments)
        meeting.segments = mergeSorted(existing, added.segments)
    }

    static func isSorted(_ segments: [TranscriptSegment]) -> Bool {
        zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start }
    }

    static func stableSorted(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    static func mergeSorted(_ a: [TranscriptSegment], _ b: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        result.reserveCapacity(a.count + b.count)
        // New lines are almost always after the existing ones: find the insertion point from the end.
        var i = a.startIndex, j = b.startIndex
        if let firstNew = b.first {
            var low = a.startIndex, high = a.endIndex
            while low < high {
                let mid = (low + high) / 2
                if a[mid].start <= firstNew.start { low = mid + 1 } else { high = mid }
            }
            result.append(contentsOf: a[..<low])
            i = low
        }
        while i < a.endIndex, j < b.endIndex {
            if a[i].start <= b[j].start { result.append(a[i]); i += 1 } else { result.append(b[j]); j += 1 }
        }
        result.append(contentsOf: a[i...])
        result.append(contentsOf: b[j...])
        return result
    }
}
