import XCTest
@testable import ChrupioCore

final class LegacyMigrationTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private let meetingID = UUID().uuidString
    private var fm: FileManager { .default }
    private func path(_ relative: String) -> String { base.appendingPathComponent(relative).path }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var asideName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Chrupio.pre-migration-\(formatter.string(from: now))"
    }

    private func write(_ relative: String, _ text: String = "x") throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeOld() throws {
        try write("OpenKrisp/meetings/\(meetingID)/meeting.json")
        try write("OpenKrisp/meetings/index.json")
    }

    func testMovesOldFolderWhenNewIsMissing() throws {
        try makeOld()
        XCTAssertEqual(LegacyMigration.moveSupportFolder(base: base, now: now), .moved)
        XCTAssertTrue(fm.fileExists(atPath: path("Chrupio/meetings/\(meetingID)/meeting.json")))
        XCTAssertFalse(fm.fileExists(atPath: path("OpenKrisp")))
    }

    func testSetsAsideANewFolderHoldingOnlyModels() throws {
        try makeOld()
        try write("Chrupio/models/ggml-small.bin", "w")
        XCTAssertEqual(LegacyMigration.moveSupportFolder(base: base, now: now), .movedSettingAside(asideName: asideName))
        XCTAssertTrue(fm.fileExists(atPath: path("\(asideName)/models/ggml-small.bin")))
        XCTAssertTrue(fm.fileExists(atPath: path("Chrupio/meetings/\(meetingID)/meeting.json")))
        XCTAssertFalse(fm.fileExists(atPath: path("OpenKrisp")))
    }

    func testSetsAsideANewFolderHoldingTokenSessionsAndAnIndex() throws {
        try makeOld()
        try write("Chrupio/token", "t")
        try write("Chrupio/claude-sessions/s.json")
        try write("Chrupio/meetings/index.json", "[]")
        XCTAssertEqual(LegacyMigration.moveSupportFolder(base: base, now: now), .movedSettingAside(asideName: asideName))
        XCTAssertTrue(fm.fileExists(atPath: path("\(asideName)/token")))
        XCTAssertTrue(fm.fileExists(atPath: path("\(asideName)/claude-sessions/s.json")))
        XCTAssertTrue(fm.fileExists(atPath: path("\(asideName)/meetings/index.json")))
        XCTAssertTrue(fm.fileExists(atPath: path("Chrupio/meetings/\(meetingID)/meeting.json")))
        XCTAssertFalse(fm.fileExists(atPath: path("OpenKrisp")))
    }

    func testLeavesBothAloneWhenNewHoldsAMeeting() throws {
        try makeOld()
        let newMeeting = UUID().uuidString
        try write("Chrupio/meetings/\(newMeeting)/meeting.json")
        XCTAssertEqual(LegacyMigration.moveSupportFolder(base: base, now: now), .skippedNewHoldsMeetings)
        XCTAssertTrue(fm.fileExists(atPath: path("OpenKrisp/meetings/\(meetingID)/meeting.json")))
        XCTAssertTrue(fm.fileExists(atPath: path("Chrupio/meetings/\(newMeeting)/meeting.json")))
        XCTAssertFalse(fm.fileExists(atPath: path(asideName)))
    }

    func testNothingToDoWithoutOldFolder() throws {
        try write("Chrupio/models/ggml-small.bin", "w")
        XCTAssertEqual(LegacyMigration.moveSupportFolder(base: base, now: now), .noLegacyFolder)
        XCTAssertTrue(fm.fileExists(atPath: path("Chrupio/models/ggml-small.bin")))
        XCTAssertFalse(fm.fileExists(atPath: path(asideName)))
    }

    /// Never touches the real Application Support folder: under XCTest it returns before resolving any path.
    func testMigrateIfNeededDoesNothingUnderTests() throws {
        // Belt and braces: never call it unless the guard it relies on holds in this process.
        guard NSClassFromString("XCTestCase") != nil else { return XCTFail("XCTestCase not visible; not calling migrateIfNeeded") }
        XCTAssertEqual(LegacyMigration.migrateIfNeeded(), .skippedUnderTests)
    }

    func testCopiesPreferencesOnceIntoAnEmptyDomain() {
        let old = "test.old.\(UUID())", new = "test.new.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: old); UserDefaults.standard.removePersistentDomain(forName: new) }
        UserDefaults.standard.setPersistentDomain(["contextFile": "/x.json", "hasCompletedOnboarding": true], forName: old)

        XCTAssertEqual(LegacyMigration.copyPreferences(from: old, to: new), 2)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: new)?["contextFile"] as? String, "/x.json")

        UserDefaults.standard.setPersistentDomain(["contextFile": "/changed.json"], forName: old)
        XCTAssertEqual(LegacyMigration.copyPreferences(from: old, to: new), 0, "a domain with keys is never overwritten")
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: new)?["contextFile"] as? String, "/x.json")
    }
}
