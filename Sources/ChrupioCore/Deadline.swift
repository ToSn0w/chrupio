import Foundation

public struct DeadlineExceeded: LocalizedError, Equatable {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
    public var errorDescription: String? { "gave up after \(Int(seconds)) s" }
}

public enum Deadline {
    /// How long diarization may take: twice the audio, never under two minutes.
    public static func diarization(audioSeconds: TimeInterval) -> TimeInterval { max(120, 2 * audioSeconds) }

    /// Runs `operation` and throws `DeadlineExceeded` if it hasn't finished after `seconds`.
    /// Returns at the deadline even when the operation ignores cancellation (a task group would wait for it);
    /// the operation is cancelled and its late result dropped.
    public static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            let work = Task {
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.resume(.failure(DeadlineExceeded(seconds: seconds))) { work.cancel() }
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) { lock.withLock { self.continuation = continuation } }

    /// True when this call was the one that resumed.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
        return pending != nil
    }
}
