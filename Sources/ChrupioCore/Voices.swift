import Accelerate
import Foundation

/// A small voice fingerprint for one stretch of speech: means and spreads of 13 cepstral coefficients.
/// No model download; good enough to tell different-sounding voices on one call apart.
public enum VoiceFeatures {
    public static let size = 26
    static let frame = 400        // 25 ms at 16 kHz
    static let hop = 160          // 10 ms
    static let fftSize = 512
    static let bands = 26
    static let coefficients = 13
    /// Less voiced audio than this gives an unstable fingerprint.
    static let minimumVoicedFrames = 60

    /// Features of `samples` (16 kHz mono), or nil when there is too little voiced audio.
    public static func compute(_ samples: [Float], sampleRate: Int = 16_000) -> [Float]? {
        guard sampleRate == 16_000, samples.count >= frame else { return nil }
        let frameCount = 1 + (samples.count - frame) / hop
        var energies = [Float](repeating: 0, count: frameCount)
        var cepstra: [[Float]] = []
        cepstra.reserveCapacity(frameCount)

        let log2n = vDSP_Length(9)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: frame, isHalfWindow: false)
        let filters = melFilters
        var buffer = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2)

        for index in 0..<frameCount {
            let start = index * hop
            let slice = Array(samples[start..<start + frame])
            energies[index] = vDSP.sumOfSquares(slice) / Float(frame)
            buffer.replaceSubrange(0..<frame, with: vDSP.multiply(slice, window))
            for i in frame..<fftSize { buffer[i] = 0 }
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    buffer.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
                }
            }
            let logMel = filters.map { filter in log(max(1e-10, zip(filter.weights, power[filter.offset..<filter.offset + filter.weights.count]).reduce(0) { $0 + $1.0 * $1.1 })) }
            cepstra.append(dct(logMel))
        }

        // Keep the louder frames: speech, not the pauses between words.
        let threshold = max(1e-6, percentile(energies, 0.4))
        let voiced = cepstra.indices.filter { energies[$0] >= threshold }.map { cepstra[$0] }
        guard voiced.count >= minimumVoicedFrames else { return nil }
        var mean = [Float](repeating: 0, count: coefficients)
        var spread = [Float](repeating: 0, count: coefficients)
        for row in voiced { for c in 0..<coefficients { mean[c] += row[c] } }
        mean = mean.map { $0 / Float(voiced.count) }
        for row in voiced { for c in 0..<coefficients { spread[c] += (row[c] - mean[c]) * (row[c] - mean[c]) } }
        spread = spread.map { ($0 / Float(voiced.count)).squareRoot() }
        return mean + spread
    }

    struct Filter { let offset: Int; let weights: [Float] }

    /// Triangular mel filters from 80 Hz to 7.6 kHz over the 256 power bins.
    static let melFilters: [Filter] = {
        func mel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let low = mel(80), high = mel(7600)
        let points = (0...bands + 1).map { hz(low + (high - low) * Float($0) / Float(bands + 1)) }
        let bins = points.map { Int(($0 / 8000) * Float(fftSize / 2 - 1)) }
        return (1...bands).map { band in
            let left = bins[band - 1], center = max(bins[band], left + 1), right = max(bins[band + 1], center + 1)
            var weights: [Float] = []
            for bin in left..<min(right, fftSize / 2) {
                weights.append(bin < center ? Float(bin - left) / Float(center - left) : Float(right - bin) / Float(right - center))
            }
            return Filter(offset: left, weights: weights)
        }
    }()

    /// DCT-II of the log mel energies; coefficient 0 (loudness) is dropped.
    static func dct(_ values: [Float]) -> [Float] {
        let n = Float(values.count)
        return (1...coefficients).map { k in
            var sum: Float = 0
            for (i, value) in values.enumerated() { sum += value * cos(Float.pi * Float(k) * (Float(i) + 0.5) / n) }
            return sum
        }
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// Features for each remote segment of a transcribed system-audio chunk.
    public static func annotate(_ segments: [TranscriptSegment], chunk: AudioChunk, samples: [Float]) -> [TranscriptSegment] {
        guard chunk.track == .system else { return segments }
        return segments.map { segment in
            var updated = segment
            let from = max(0, Int((segment.start - chunk.startOffset) * 16_000))
            let to = min(samples.count, Int((segment.end - chunk.startOffset) * 16_000))
            if to - from > frame { updated.voice = compute(Array(samples[from..<to])) }
            return updated
        }
    }
}

/// Groups remote segments by voice and names the groups.
public enum VoiceAttribution {
    /// Distance (in per-meeting standardized units, averaged per dimension) below which two groups are one voice.
    public static let mergeDistance: Float = 1.2
    /// Distance to a stored voice print that still counts as that person.
    public static let printDistance: Float = 0.85
    /// Lines shorter than this are not clustered.
    public static let minimumSeconds: TimeInterval = 2

    /// Agglomerative clustering with average linkage. Returns a cluster index per vector.
    public static func cluster(_ vectors: [[Float]], threshold: Float = mergeDistance) -> [Int] {
        let n = vectors.count
        guard n > 1 else { return Array(repeating: 0, count: n) }
        let scaled = standardize(vectors)
        var distance = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in i + 1..<n { let d = meanDistance(scaled[i], scaled[j]); distance[i][j] = d; distance[j][i] = d } }
        var members: [[Int]?] = (0..<n).map { [$0] }
        while true {
            var best: (Int, Int, Float)?
            for i in 0..<n where members[i] != nil {
                for j in i + 1..<n where members[j] != nil && distance[i][j] < (best?.2 ?? threshold) {
                    best = (i, j, distance[i][j])
                }
            }
            guard let (i, j, _) = best else { break }
            let sizeI = Float(members[i]!.count), sizeJ = Float(members[j]!.count)
            for k in 0..<n where k != i && k != j && members[k] != nil {
                let merged = (distance[i][k] * sizeI + distance[j][k] * sizeJ) / (sizeI + sizeJ)
                distance[i][k] = merged
                distance[k][i] = merged
            }
            members[i]! += members[j]!
            members[j] = nil
        }
        // Stray lines (laughter, crosstalk, a cough) form tiny groups of their own; fold them into the closest real voice.
        var groups = members.compactMap { $0 }
        let minimum = max(3, Int((Double(n) * 0.04).rounded()))
        let large = groups.filter { $0.count >= minimum }
        if !large.isEmpty, large.count < groups.count {
            let centroids = large.map { group in VoicePrints.average(group.map { scaled[$0] }) }
            var merged = large
            for group in groups where group.count < minimum {
                let centroid = VoicePrints.average(group.map { scaled[$0] })
                let nearest = centroids.indices.min { meanDistance(centroid, centroids[$0]) < meanDistance(centroid, centroids[$1]) }!
                merged[nearest] += group
            }
            groups = merged
        }
        var labels = [Int](repeating: 0, count: n)
        // Number clusters in order of first appearance.
        groups.sort { $0.min()! < $1.min()! }
        for (label, group) in groups.enumerated() { for index in group { labels[index] = label } }
        return labels
    }

    static func standardize(_ vectors: [[Float]]) -> [[Float]] {
        guard let dimensions = vectors.first?.count else { return vectors }
        var mean = [Float](repeating: 0, count: dimensions)
        var deviation = [Float](repeating: 0, count: dimensions)
        for v in vectors { for d in 0..<dimensions { mean[d] += v[d] } }
        mean = mean.map { $0 / Float(vectors.count) }
        for v in vectors { for d in 0..<dimensions { deviation[d] += (v[d] - mean[d]) * (v[d] - mean[d]) } }
        deviation = deviation.map { max(1e-3, ($0 / Float(vectors.count)).squareRoot()) }
        return vectors.map { v in (0..<dimensions).map { (v[$0] - mean[$0]) / deviation[$0] } }
    }

    static func meanDistance(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += (a[i] - b[i]) * (a[i] - b[i]) }
        return (sum / Float(max(1, a.count))).squareRoot()
    }

    /// "Speaker 2" style labels mark voices nobody has named yet.
    public static func isPlaceholder(_ name: String) -> Bool {
        name.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// Names remote segments that live signals left unnamed.
    /// A voice group takes the name most of its already-named segments carry, then the closest stored voice print,
    /// then the only other attendee; otherwise it becomes "Speaker N".
    public static func apply(to meeting: inout Meeting, prints: VoicePrints, threshold: Float = mergeDistance) {
        // Short lines give noisy fingerprints; they take a neighbour's name at the end instead.
        let voiced = meeting.segments.indices.filter {
            !meeting.segments[$0].speaker.isMe && meeting.segments[$0].voice?.count == VoiceFeatures.size
                && meeting.segments[$0].end - meeting.segments[$0].start >= minimumSeconds
        }
        guard !voiced.isEmpty else { return }
        let labels = cluster(voiced.map { meeting.segments[$0].voice! }, threshold: threshold)
        let me = meeting.selfName?.lowercased()
        var taken = Set<String>()
        var names: [Int: String] = [:]

        // 1. Live names already on segments of the group.
        for label in Set(labels).sorted() {
            let group = voiced.indices.filter { labels[$0] == label }.map { voiced[$0] }
            var counts: [String: Int] = [:]
            for index in group { if case .remote(let name?) = meeting.segments[index].speaker, !isPlaceholder(name) { counts[name, default: 0] += 1 } }
            if let (name, count) = counts.max(by: { $0.value < $1.value }), Double(count) >= 0.5 * Double(counts.values.reduce(0, +)), !taken.contains(name) {
                names[label] = name
                taken.insert(name)
            }
        }
        // 2. Stored voice prints of attendees only. A group closest to someone outside the meeting stays "Speaker N".
        let attendeeKeys = Set(meeting.attendees.map(PersonName.key))
        let printKeys = prints.people.keys.map(PersonName.key)
        var strangers = Set<Int>()
        for label in Set(labels).sorted() where names[label] == nil {
            let group = voiced.indices.filter { labels[$0] == label }.map { meeting.segments[voiced[$0]].voice! }
            let centroid = VoicePrints.average(group)
            guard let name = prints.closest(to: centroid, preferring: meeting.attendees, excluding: taken.union([me].compactMap { $0 })) else { continue }
            let key = PersonName.key(name)
            // Two prints folding to one spelling can't be told apart.
            if printKeys.filter({ $0 == key }).count > 1 { continue }
            if attendeeKeys.contains(key) {
                // The attendee's spelling, as this meeting reports it.
                let spelled = meeting.attendees.first { PersonName.key($0) == key } ?? name
                names[label] = spelled
                taken.insert(spelled)
            } else {
                strangers.insert(label)
            }
        }
        // 3. One unnamed group and one unnamed attendee left.
        let unnamedGroups = Set(labels).filter { names[$0] == nil && !strangers.contains($0) }
        let freeAttendees = meeting.attendees.filter { attendee in
            !meeting.isSelf(attendee) && !taken.contains { PersonName.key($0) == PersonName.key(attendee) }
        }
        if unnamedGroups.count == 1, freeAttendees.count == 1 { names[unnamedGroups.first!] = freeAttendees[0] }

        var placeholder = 0
        for label in Set(labels).sorted() where names[label] == nil {
            placeholder += 1
            names[label] = "Speaker \(placeholder)"
        }
        for (position, index) in voiced.enumerated() {
            // A live name on the segment itself wins over its group's name.
            if case .remote(let name?) = meeting.segments[index].speaker, !isPlaceholder(name) { continue }
            meeting.segments[index].speaker = .remote(names[labels[position]])
        }
        // Short segments without a fingerprint take the name of the nearest voiced neighbour.
        for index in meeting.segments.indices where !meeting.segments[index].speaker.isMe {
            guard case .remote(nil) = meeting.segments[index].speaker else { continue }
            let segment = meeting.segments[index]
            let nearest = voiced.min { abs(meeting.segments[$0].start - segment.start) < abs(meeting.segments[$1].start - segment.start) }
            if let nearest, abs(meeting.segments[nearest].start - segment.start) < 8 {
                meeting.segments[index].speaker = meeting.segments[nearest].speaker
            }
        }
    }
}

/// Voice prints of people named by a live signal (extension or Zoom), kept across meetings in `voices.json`.
public struct VoicePrints: Codable, Sendable, Equatable {
    public struct Print: Codable, Sendable, Equatable {
        public var mean: [Float]
        public var count: Int
    }

    public var people: [String: Print] = [:]

    public init(people: [String: Print] = [:]) { self.people = people }

    public static func load(from url: URL) -> VoicePrints {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(VoicePrints.self, from: $0) } ?? VoicePrints()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func average(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in sum.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    /// Learns from segments a live signal named. Prints are running means, capped so old meetings don't freeze them.
    public mutating func learn(from meeting: Meeting, liveNames: Set<String>) {
        var grouped: [String: [[Float]]] = [:]
        for segment in meeting.segments {
            guard case .remote(let name?) = segment.speaker, liveNames.contains(name), let voice = segment.voice, voice.count == VoiceFeatures.size else { continue }
            grouped[name, default: []].append(voice)
        }
        for (name, vectors) in grouped where vectors.count >= 3 {
            let fresh = Self.average(vectors)
            if var existing = people[name], existing.mean.count == fresh.count {
                let weight = Float(min(existing.count, 200))
                let added = Float(vectors.count)
                existing.mean = zip(existing.mean, fresh).map { ($0 * weight + $1 * added) / (weight + added) }
                existing.count += vectors.count
                people[name] = existing
            } else {
                people[name] = Print(mean: fresh, count: vectors.count)
            }
        }
    }

    /// The stored person closest to `vector`, if close enough. Distances use the spread across all stored prints as scale.
    public func closest(to vector: [Float], preferring attendees: [String], excluding: Set<String>) -> String? {
        let excluded = Set(excluding.map(PersonName.key))
        let candidates = people.filter { !excluded.contains(PersonName.key($0.key)) && $0.value.mean.count == vector.count }
        guard !candidates.isEmpty else { return nil }
        let scale = Self.scale(people.values.map(\.mean) + [vector])
        let attendeeKeys = Set(attendees.map { $0.lowercased() })
        let scored: [(String, Float)] = candidates.map { entry in
            let distance = Self.distance(entry.value.mean, vector, scale: scale)
            let weight: Float = attendeeKeys.contains(entry.key.lowercased()) ? 0.85 : 1
            return (entry.key, distance * weight)
        }
        .sorted { $0.1 < $1.1 }
        guard let best = scored.first, best.1 < VoiceAttribution.printDistance else { return nil }
        // Too close a runner-up means the voices can't be told apart.
        if scored.count > 1, scored[1].1 - best.1 < 0.05 { return nil }
        return best.0
    }

    /// Root mean square of the per-dimension differences, each divided by its scale.
    static func distance(_ a: [Float], _ b: [Float], scale: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count, scale.count) {
            let difference: Float = (a[index] - b[index]) / scale[index]
            sum += difference * difference
        }
        return (sum / Float(b.count)).squareRoot()
    }

    /// Per-dimension spread; a floor keeps a single stored print from dividing by zero.
    static func scale(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let mean = average(vectors)
        var spread = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in spread.indices { spread[i] += (v[i] - mean[i]) * (v[i] - mean[i]) } }
        return spread.map { max(1, ($0 / Float(vectors.count)).squareRoot()) }
    }
}

extension MeetingStore {
    /// Fills in voice features for the remote segments of a saved meeting from its kept system audio.
    public func annotateVoices(_ meeting: Meeting) -> Meeting {
        var result = meeting
        for chunk in AudioChunkScanner.chunks(in: audioDirectory(for: meeting.id)) where chunk.track == .system {
            guard let samples = try? WAVFile.read(chunk.url) else { continue }
            let inside = result.segments.indices.filter {
                !result.segments[$0].speaker.isMe && result.segments[$0].start >= chunk.startOffset - 0.05
                    && result.segments[$0].start < chunk.startOffset + chunk.duration
            }
            let annotated = VoiceFeatures.annotate(inside.map { result.segments[$0] }, chunk: chunk, samples: samples)
            for (index, segment) in zip(inside, annotated) { result.segments[index].voice = segment.voice }
        }
        return result
    }
}
