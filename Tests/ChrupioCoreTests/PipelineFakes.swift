import Foundation
@testable import ChrupioCore

/// A saver whose outcomes the test scripts; unscripted saves succeed. Completions run at once.
final class FakeSaver: MeetingSaving, @unchecked Sendable {
    let store: MeetingStore
    var external = ExternalChanges()
    private let lock = NSLock()
    private var scripted: [MeetingSaver.Outcome] = []
    private(set) var saved: [Meeting] = []
    var deleteError: Error?
    private(set) var deleted: [UUID] = []

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("fake-saver-\(UUID().uuidString)")) {
        store = MeetingStore(root: root)
    }

    func script(_ outcomes: MeetingSaver.Outcome...) { lock.withLock { scripted += outcomes } }

    private func next(_ meeting: Meeting) -> MeetingSaver.Outcome {
        lock.withLock {
            saved.append(meeting)
            return scripted.isEmpty ? .saved(merged: nil) : scripted.removeFirst()
        }
    }

    func updateExternal<T>(_ change: (inout ExternalChanges) -> T) -> T { lock.withLock { change(&external) } }
    func isSaving(_ id: UUID) -> Bool { false }
    func save(_ meeting: Meeting, completion: @escaping @Sendable (MeetingSaver.Outcome) -> Void) { completion(next(meeting)) }
    func saveNow(_ meeting: Meeting) -> MeetingSaver.Outcome { next(meeting) }
    func delete(_ id: UUID) throws {
        try lock.withLock {
            if let deleteError { throw deleteError }
            deleted.append(id)
        }
    }
    func flush() {}
}

@MainActor
final class FakeNotifier: MeetingNotifying {
    private(set) var posted: [(title: String, body: String, important: Bool, identifier: String?)] = []
    private(set) var removed: [String] = []
    var titles: [String] { posted.map(\.title) }

    func post(title: String, body: String, important: Bool, identifier: String?) { posted.append((title, body, important, identifier)) }
    func remove(identifier: String) { removed.append(identifier) }
}

@MainActor
final class FakeLibraryHooks: MeetingLibraryHooks {
    var keepAudio = true
    var busy: Set<UUID> = []
    private(set) var saved: [Meeting] = []
    private(set) var loaded: [Meeting] = []
    private(set) var removed: [UUID] = []

    func saved(_ meeting: Meeting) { saved.append(meeting) }
    func loadedExternally(_ meeting: Meeting) { loaded.append(meeting) }
    func removed(_ id: UUID) { removed.append(id) }
    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }
}

/// Waits for main-actor tasks the code under test started (save completions, summaries).
@MainActor
func settle(_ rounds: Int = 20) async {
    for _ in 0..<rounds { await Task.yield() }
}

@MainActor
func until(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}
