import Foundation

/// A stretch of remote speech the diarizer gave to one voice, in seconds from meeting start.
public struct DiarizedTurn: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var cluster: String

    public init(start: TimeInterval, end: TimeInterval, cluster: String) {
        self.start = start
        self.end = end
        self.cluster = cluster
    }
}

/// Who spoke when on the system track, with one voice embedding per cluster.
public struct Diarization: Sendable {
    public var turns: [DiarizedTurn]
    public var centroids: [String: [Float]]

    public init(turns: [DiarizedTurn], centroids: [String: [Float]]) {
        self.turns = turns
        self.centroids = centroids
    }

    /// The cluster talking most during `start...end`.
    public func cluster(start: TimeInterval, end: TimeInterval) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            overlap[turn.cluster, default: 0] += min(end, turn.end) - max(start, turn.start)
        }
        return overlap.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// The cluster of the turn nearest to `start...end` within `reach` seconds, for speech the diarizer missed.
    public func nearestCluster(start: TimeInterval, end: TimeInterval, reach: TimeInterval = 2) -> String? {
        turns.map { turn in (turn.cluster, max(0, max(turn.start - end, start - turn.end))) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Voice embeddings (WeSpeaker, from the diarizer) of people a live signal named, kept across meetings.
/// Separate from the older `VoicePrints`, whose features are not comparable.
public struct SpeakerPrints: Codable, Sendable, Equatable {
    public struct Print: Codable, Sendable, Equatable {
        public var embedding: [Float]
        public var count: Int
    }

    public var people: [String: Print] = [:]
    /// Meetings already learned from, so retranscribing one doesn't count it twice.
    public var learnedMeetings: Set<UUID> = []

    public init(people: [String: Print] = [:]) { self.people = people }

    public static func load(from url: URL) -> SpeakerPrints {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SpeakerPrints.self, from: $0) } ?? SpeakerPrints()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : -1
    }

    /// Similarity a stored voice needs to name a cluster; people on the attendee list need a little less.
    /// On 21 Oct 2026 Slack huddles the right person scored 0.74 to 0.91 and the best wrong one up to 0.60 (prints learned
    /// once, from Teams), so both bars sit above that.
    public static let threshold: Float = 0.70
    public static let attendeeThreshold: Float = 0.62
    /// No longer applied: `match` never names someone outside the meeting. Kept for calibration runs.
    public static let outsiderThreshold: Float = 0.80
    /// How far the best voice must lead the next one, outsiders included.
    public static let margin: Float = 0.05

    /// The similarity bars `match` applies; calibration runs try other values.
    public struct Bars: Sendable, Equatable {
        public var threshold, attendee, outsider, margin: Float
        public init(threshold: Float, attendee: Float, outsider: Float, margin: Float) {
            self.threshold = threshold; self.attendee = attendee; self.outsider = outsider; self.margin = margin
        }
        public static let standard = Bars(threshold: SpeakerPrints.threshold, attendee: SpeakerPrints.attendeeThreshold,
                                          outsider: SpeakerPrints.outsiderThreshold, margin: SpeakerPrints.margin)
    }

    /// The stored person whose voice matches `embedding`, if clearly better than the runner-up.
    /// `only`: when set, the people in this meeting; anyone else is never returned, and still counts as the best
    /// voice or a runner-up, so a voice closer to an outsider names nobody.
    public func closest(to embedding: [Float], attendees: [String], excluding: Set<String>, only: [String]? = nil) -> String? {
        match(to: embedding, attendees: attendees, excluding: excluding, only: only)?.name
    }

    /// `closest` with the winning similarity.
    public func match(to embedding: [Float], attendees: [String], excluding: Set<String>,
                      only: [String]? = nil, bars: Bars = .standard) -> (name: String, similarity: Float)? {
        let attendeeKeys = Set(attendees.map(PersonName.key))
        let allowed = only.map { Set($0.map(PersonName.key)) }
        let excluded = Set(excluding.map(PersonName.key))
        let scored = people
            .filter { !excluded.contains(PersonName.key($0.key)) }
            .map { (name: $0.key, similarity: Self.cosine($0.value.embedding, embedding)) }
            .sorted { ($0.similarity, $1.name) > ($1.similarity, $0.name) }
        guard let best = scored.first else { return nil }
        let key = PersonName.key(best.name)
        let needed: Float
        if let allowed, !allowed.contains(key) { return nil }
        needed = attendeeKeys.contains(key) ? bars.attendee : bars.threshold
        guard best.similarity >= needed else { return nil }
        if scored.count > 1, best.similarity - scored[1].similarity < bars.margin { return nil }
        return best
    }

    /// Adds a confirmed voice; prints are running means capped so old meetings don't freeze them.
    public mutating func learn(_ name: String, embedding: [Float], weight: Int = 1) {
        if var existing = people[name], existing.embedding.count == embedding.count {
            let old = Float(min(existing.count, 50)), added = Float(weight)
            existing.embedding = zip(existing.embedding, embedding).map { ($0 * old + $1 * added) / (old + added) }
            existing.count += weight
            people[name] = existing
        } else {
            people[name] = Print(embedding: embedding, count: weight)
        }
    }
}

/// Names diarization clusters and puts the names on remote lines.
public enum DiarizationNaming {
    /// Live events a cluster needs before its name is trusted enough to learn the voice.
    public static let confirmingEvents = 3
    /// Share of a cluster's live evidence the leading name needs.
    public static let confirmingShare = 0.6

    public struct Outcome: Sendable, Equatable {
        /// Cluster to name.
        public var names: [String: String]
        /// Clusters named by enough live evidence to learn their voice.
        public var confirmed: Set<String>
    }

    /// Similarity two cluster centroids need to count as one voice for the 1:1 rule; the attendee bar of SpeakerPrints.
    public static let sameVoiceSimilarity: Float = SpeakerPrints.attendeeThreshold
    /// Share of a line's duration a live name must cover to override the cluster's name.
    public static let liveCoverageShare = 0.5

    /// Picks a name per cluster: live events, then stored voices of people the call reported (never anyone outside the
    /// meeting), then the only other attendee, then the one attendee left, then "Speaker N".
    public static func names(for diarization: Diarization, meeting: Meeting, prints: SpeakerPrints) -> Outcome {
        let me = meeting.selfName?.lowercased()
        let clusters = orderOfAppearance(diarization.turns)
        var names: [String: String] = [:]
        var confirmed = Set<String>()
        var taken = Set<String>()

        // 1. Live events: how much of each cluster's speech each name's indicator covered.
        var evidence: [String: [String: Double]] = [:]
        var eventCounts: [String: [String: Int]] = [:]
        for turn in diarization.turns {
            for event in meeting.speakerEvents {
                let overlap = event.overlap(start: turn.start, end: turn.end)
                guard overlap > 0 else { continue }
                let speakers = event.names.filter { !meeting.isSelf($0) }
                // A run of reports counts as the heartbeats it stands for inside this turn.
                let reports = max(1, Int((overlap / (2 * SpeakerAttribution.eventReach)).rounded(.up)))
                for name in speakers {
                    evidence[turn.cluster, default: [:]][name, default: 0] += overlap / Double(speakers.count)
                    eventCounts[turn.cluster, default: [:]][name, default: 0] += reports
                }
            }
        }
        let candidates = evidence.flatMap { cluster, votes in votes.map { (cluster: cluster, name: $0.key, weight: $0.value) } }
            .sorted { ($0.weight, $1.cluster, $1.name) > ($1.weight, $0.cluster, $0.name) }
        for candidate in candidates where names[candidate.cluster] == nil && !taken.contains(PersonName.key(candidate.name)) {
            let total = evidence[candidate.cluster]!.values.reduce(0, +)
            guard candidate.weight >= 0.5 * total else { continue }
            names[candidate.cluster] = candidate.name
            taken.insert(PersonName.key(candidate.name))
            if candidate.weight >= confirmingShare * total, eventCounts[candidate.cluster]![candidate.name]! >= confirmingEvents {
                confirmed.insert(candidate.cluster)
            }
        }
        // 3. Stored voices, of the people the call reported only: a voice never takes the name of someone outside this
        // meeting, even one the project context expects.
        let reported = meeting.attendees + meeting.speakerEvents.flatMap(\.names)
        // A print stored under another spelling of a reported name labels lines with the name as this meeting reports it
        // (attendee spelling first). Two prints that fold to one spelling can't be told apart, so they name nobody.
        var reportedSpelling: [String: String] = [:]
        for name in reported where reportedSpelling[PersonName.key(name)] == nil { reportedSpelling[PersonName.key(name)] = name }
        let printKeys = prints.people.keys.map(PersonName.key)
        let ambiguous = Set(printKeys.filter { key in printKeys.filter { $0 == key }.count > 1 })
        // Best match first: a voice that clearly is someone claims them before a cluster that only resembles them.
        while true {
            let best = clusters.filter { names[$0] == nil }.compactMap { cluster -> (cluster: String, name: String, similarity: Float)? in
                guard let centroid = diarization.centroids[cluster],
                      let match = prints.match(to: centroid, attendees: reported,
                                               excluding: taken.union([me].compactMap { $0 }), only: reported),
                      !ambiguous.contains(PersonName.key(match.name)) else { return nil }
                return (cluster, reportedSpelling[PersonName.key(match.name)] ?? match.name, match.similarity)
            }.max { ($0.similarity, $1.cluster) < ($1.similarity, $0.cluster) }
            guard let best else { break }
            names[best.cluster] = best.name
            taken.insert(PersonName.key(best.name))
        }
        // A voice that clearly is someone outside the meeting is not an attendee either; it stays "Speaker N".
        let reportedKeys = Set(reported.map(PersonName.key))
        let strangers = Set(clusters.filter { cluster in
            guard names[cluster] == nil, let centroid = diarization.centroids[cluster],
                  let match = prints.match(to: centroid, attendees: [], excluding: taken.union([me].compactMap { $0 })) else { return false }
            return !reportedKeys.contains(PersonName.key(match.name))
        })
        // 2. With exactly one other attendee the remote voices left unnamed are theirs, even one split in two (say after
        // a mic change), which the live events above can name only once. Runs after stored voices so a third person
        // who joined keeps their name, and only when one cluster is left or all the leftover ones sound alike: two
        // different voices are two people, whatever the attendee list says.
        let others = meeting.attendees.filter { !meeting.isSelf($0) }
        let leftover = clusters.filter { names[$0] == nil && !strangers.contains($0) }
        if others.count == 1, leftover.count == 1 || soundAlike(leftover, diarization: diarization) {
            for cluster in leftover { names[cluster] = others[0] }
        }
        // 4. One unnamed voice and one attendee nobody claimed.
        let unnamed = clusters.filter { names[$0] == nil && !strangers.contains($0) }
        let free = meeting.attendees.filter { !meeting.isSelf($0) && !taken.contains(PersonName.key($0)) }
        if unnamed.count == 1, free.count == 1 { names[unnamed[0]] = free[0] }
        var number = 0
        for cluster in clusters where names[cluster] == nil {
            number += 1
            names[cluster] = "Speaker \(number)"
        }
        return Outcome(names: names, confirmed: confirmed)
    }

    /// Re-labels remote lines from the diarization, splitting a line where the voice changes.
    /// The extension's name wins where its events cover at least half a part, or agree with the cluster's name: a cluster
    /// carries one name, and a voice the diarizer split in two would otherwise lose it. A brief overlap (indicator lag)
    /// doesn't beat the cluster's name. Cluster names fill the remaining parts, and a line
    /// the diarizer heard no voice in keeps the name it had.
    public static func apply(_ diarization: Diarization, names: [String: String], to meeting: inout Meeting) {
        let events = meeting.speakerEvents, me = meeting.selfName
        meeting.segments = meeting.segments.flatMap { segment -> [TranscriptSegment] in
            guard !segment.speaker.isMe else { return [segment] }
            return SegmentSplitter.split(segment) { diarization.cluster(start: $0, end: $1) }.map { part, _ in
                var updated = part
                let cluster = diarization.cluster(start: part.start, end: part.end)
                    ?? diarization.nearestCluster(start: part.start, end: part.end)
                let clusterName = cluster.flatMap { names[$0] }
                if let live = SpeakerAttribution.liveSpeakerCoverage(start: part.start, end: part.end, events: events,
                                                                     selfName: me, lookAhead: false),
                   clusterName == nil || PersonName.same(live.name, clusterName)
                    || live.seconds >= liveCoverageShare * max(part.end - part.start, 0) {
                    updated.speaker = .remote(live.name)
                    return updated
                }
                if let clusterName { updated.speaker = .remote(clusterName) }
                return updated
            }
        }
    }

    /// Learns the voices of live-confirmed clusters, once per meeting.
    public static func learn(_ outcome: Outcome, diarization: Diarization, meetingID: UUID, into prints: inout SpeakerPrints) {
        guard !prints.learnedMeetings.contains(meetingID) else { return }
        var learned = false
        for cluster in outcome.confirmed.sorted() {
            guard let name = outcome.names[cluster], let centroid = diarization.centroids[cluster] else { continue }
            prints.learn(name, embedding: centroid)
            learned = true
        }
        if learned { prints.learnedMeetings.insert(meetingID) }
    }

    /// The voice behind each cluster name; clusters sharing a name are averaged.
    public static func voices(_ diarization: Diarization, names: [String: String]) -> [String: [Float]] {
        var sums: [String: (vector: [Float], count: Float)] = [:]
        for (cluster, name) in names {
            guard let centroid = diarization.centroids[cluster] else { continue }
            if let sum = sums[name], sum.vector.count == centroid.count {
                sums[name] = (zip(sum.vector, centroid).map(+), sum.count + 1)
            } else if sums[name] == nil {
                sums[name] = (centroid, 1)
            }
        }
        return sums.mapValues { sum in sum.vector.map { $0 / sum.count } }
    }

    /// True when every pair of these clusters' centroids is at least `sameVoiceSimilarity` alike.
    static func soundAlike(_ clusters: [String], diarization: Diarization) -> Bool {
        let centroids = clusters.compactMap { diarization.centroids[$0] }
        guard centroids.count == clusters.count else { return false }
        for i in centroids.indices { for j in centroids.indices where j > i {
            if SpeakerPrints.cosine(centroids[i], centroids[j]) < sameVoiceSimilarity { return false }
        } }
        return true
    }

    static func orderOfAppearance(_ turns: [DiarizedTurn]) -> [String] {
        var seen = Set<String>()
        return turns.sorted { $0.start < $1.start }.compactMap { seen.insert($0.cluster).inserted ? $0.cluster : nil }
    }
}
