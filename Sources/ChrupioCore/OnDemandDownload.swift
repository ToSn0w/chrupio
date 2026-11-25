import Foundation

/// Fetches a model the first time something needs it, without making the caller wait: `ensure` reports whether the model
/// is there and, when it isn't, starts one background download. A failed download is tried again on the next `ensure`.
/// Parakeet uses it, so the first Polish call goes to whisper while Parakeet downloads.
public actor OnDemandDownload {
    private let isPresent: @Sendable () -> Bool
    private let download: @Sendable () async throws -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private var running: Task<Void, Never>?

    public init(isPresent: @escaping @Sendable () -> Bool,
                download: @escaping @Sendable () async throws -> Void,
                onFinish: @escaping @Sendable (Error?) -> Void = { _ in }) {
        self.isPresent = isPresent
        self.download = download
        self.onFinish = onFinish
    }

    /// True when the model is there. Otherwise starts the download, unless one is running, and returns false.
    public func ensure() -> Bool {
        if isPresent() { return true }
        guard running == nil else { return false }
        let download = download, onFinish = onFinish
        running = Task.detached(priority: .utility) { [weak self] in
            do { try await download(); onFinish(nil) } catch { onFinish(error) }
            await self?.ended()
        }
        return false
    }

    /// Waits for the running download, if any (for tests).
    public func waitForDownload() async { await running?.value }

    private func ended() { running = nil }
}
