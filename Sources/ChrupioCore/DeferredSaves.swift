import Foundation

/// Meetings whose save gave up waiting for the write lock, retried after 5, 10, then every 30 s, so a lock held
/// for long by another process costs a short wait now and then, not one on every tick.
public struct DeferredSaves: Sendable, Equatable {
    public static let backoff: [TimeInterval] = [5, 10, 30]

    private var entries: [UUID: (attempts: Int, next: Date)] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public func contains(_ id: UUID) -> Bool { entries[id] != nil }
    public var ids: Set<UUID> { Set(entries.keys) }

    /// A save of `id` was deferred at `now`; the next try waits longer each time.
    public mutating func deferred(_ id: UUID, now: Date = Date()) {
        let attempts = (entries[id]?.attempts ?? 0) + 1
        let delay = Self.backoff[min(attempts, Self.backoff.count) - 1]
        entries[id] = (attempts, now.addingTimeInterval(delay))
    }

    public mutating func saved(_ id: UUID) { entries[id] = nil }

    /// Meetings whose next try is due, in a stable order.
    public func due(now: Date = Date()) -> [UUID] {
        entries.filter { $0.value.next <= now }.keys.sorted { $0.uuidString < $1.uuidString }
    }

    /// When the next try of `id` is due.
    public func nextTry(_ id: UUID) -> Date? { entries[id]?.next }

    public static func == (lhs: DeferredSaves, rhs: DeferredSaves) -> Bool {
        lhs.entries.mapValues(\.attempts) == rhs.entries.mapValues(\.attempts)
            && lhs.entries.mapValues(\.next) == rhs.entries.mapValues(\.next)
    }
}
