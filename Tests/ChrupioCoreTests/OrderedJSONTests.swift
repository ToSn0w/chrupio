import Foundation
@testable import ChrupioCore
import XCTest

final class OrderedJSONTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ordered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testRoundTripKeepsOrderNumbersAndEscapes() throws {
        let text = """
        {
          "zeta": 1,
          "alpha": {
            "b": 1.50,
            "a": [
              true,
              false,
              null,
              "x\\"y/z",
              1e3
            ]
          },
          "empty": {},
          "list": [],
          "emoji": "zażółć 🎙"
        }

        """
        let value = try OrderedJSON.parse(Data(text.utf8))
        XCTAssertEqual(OrderedJSON.serialize(value), text)
    }

    func testMergeKeepsOrderAndAppendsNewKeysSorted() throws {
        let original = try OrderedJSON.parse(Data(#"{"zeta": 1, "hooks": {"Stop": []}, "alpha": 2.0}"#.utf8))
        let edited: [String: Any] = ["zeta": 1, "alpha": 2.0, "hooks": ["Stop": [], "SessionStart": [["hooks": []]]], "new": true, "beta": "b"]
        let merged = OrderedJSON.serialize(OrderedJSON.merge(edited, into: original))
        XCTAssertEqual(merged, """
        {
          "zeta": 1,
          "hooks": {
            "Stop": [],
            "SessionStart": [
              {
                "hooks": []
              }
            ]
          },
          "alpha": 2.0,
          "beta": "b",
          "new": true
        }

        """)
    }

    func testMergeDropsRemovedKeysAndKeepsBooleansApartFromNumbers() throws {
        let original = try OrderedJSON.parse(Data(#"{"a": 1, "b": true, "c": 0}"#.utf8))
        let merged = OrderedJSON.serialize(OrderedJSON.merge(["a": 1, "b": false, "d": NSNumber(value: 1)], into: original))
        XCTAssertEqual(merged, "{\n  \"a\": 1,\n  \"b\": false,\n  \"d\": 1\n}\n")
    }

    func testParseRefusesARepeatedKey() {
        // JSONSerialization keeps the first value and Claude Code the last, so no merge can be trusted.
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": 1, "b": 2, "a": 3}"#.utf8)))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"x": {"a": 1, "a": 1}}"#.utf8)))
        XCTAssertNoThrow(try OrderedJSON.parse(Data(#"{"a": {"a": 1}, "b": [{"a": 1}, {"a": 2}]}"#.utf8)))
    }

    /// Claude Code keys `projects` by folder path, and macOS can hand out the same folder name composed (é) or decomposed
    /// (e + ◌́). Swift's `String ==` calls those equal; the bytes, JSONSerialization and Claude Code don't.
    private let composed = "/Users/a/Caf\u{E9}", decomposed = "/Users/a/Cafe\u{301}"

    func testKeysThatDifferOnlyInUnicodeNormalizationAreTwoKeys() throws {
        let text = "{\n  \"\(composed)\": 1,\n  \"\(decomposed)\": 2\n}\n"
        let value = try OrderedJSON.parse(Data(text.utf8))
        guard case .object(let members) = value else { return XCTFail("not an object") }
        XCTAssertEqual(members.map { Array($0.key.unicodeScalars) }, [Array(composed.unicodeScalars), Array(decomposed.unicodeScalars)])
        XCTAssertEqual(OrderedJSON.serialize(value), text)
        XCTAssertThrowsError(try OrderedJSON.parse(Data("{\"\(composed)\": 1, \"\(composed)\": 2}".utf8)), "the same bytes twice is still a repeat")
    }

    func testMergeKeepsBothNormalizationsOfAKey() throws {
        let text = "{\"x\": {\"\(composed)\": 1, \"\(decomposed)\": 2}}"
        let original = try OrderedJSON.parse(Data(text.utf8))
        let foundation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        let merged = OrderedJSON.serialize(OrderedJSON.merge(foundation, into: original))
        XCTAssertEqual(merged, "{\n  \"x\": {\n    \"\(composed)\": 1,\n    \"\(decomposed)\": 2\n  }\n}\n")
    }

    func testParseRefusesDeepNestingWithoutCrashing() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        XCTAssertThrowsError(try OrderedJSON.parse(Data(deep.utf8)))
        let objects = String(repeating: #"{"a":"#, count: 600) + "1" + String(repeating: "}", count: 600)
        XCTAssertThrowsError(try OrderedJSON.parse(Data(objects.utf8)))
        let fine = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        XCTAssertNoThrow(try OrderedJSON.parse(Data(fine.utf8)))
    }

    func testParseRejectsTrailingDataAndBrokenJSON() {
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": 1} x"#.utf8)))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": }"#.utf8)))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": 1-2}"#.utf8)))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": "open"#.utf8)))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"[1,]"#.utf8)))
    }

    func testOutputParsesBackToTheSameDictionary() throws {
        let edited: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "'/A b/chrupio-mcp' digest", "timeout": 10]]]]]]
        let data = Data(OrderedJSON.serialize(OrderedJSON.merge(edited, into: nil)).utf8)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: back).isEqual(to: edited))
    }

    func testWriteSettingsKeepsOrderAndMakesOneFirstBackup() throws {
        let file = folder.appendingPathComponent("settings.json")
        let original = "{\n  \"model\": \"opus\",\n  \"env\": {\"B\": \"1\", \"A\": \"2\"}\n}\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        try ClaudeCodeSetup.updateSettings(file, now: Date(timeIntervalSince1970: 0)) { settings in
            var settings = settings
            settings["hooks"] = ["SessionStart": []]
            return settings
        }
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(written.range(of: "\"model\"")).lowerBound, try XCTUnwrap(written.range(of: "\"env\"")).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(written.range(of: "\"B\"")).lowerBound, try XCTUnwrap(written.range(of: "\"A\"")).lowerBound)

        try ClaudeCodeSetup.updateSettings(file, now: Date(timeIntervalSince1970: 3_600)) { settings in
            var settings = settings
            settings["hooks"] = nil
            return settings
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let firsts = names.filter { $0.hasPrefix("settings.json.chrupio-backup-") }
        XCTAssertEqual(firsts.count, 1, "the first backup is made once: \(names)")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(firsts[0]), encoding: .utf8), original)
        XCTAssertTrue(names.contains("settings.json.chrupio-backup"), "the latest backup is still kept")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("settings.json.chrupio-backup"), encoding: .utf8), written)
    }

    func testWriteSettingsKeepsTheFileModeAndMakesANewFilePrivate() throws {
        let file = folder.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try ClaudeCodeSetup.updateSettings(file) { _ in ["a": 1] }
        XCTAssertEqual(try mode(file), 0o640, "a rewrite keeps the user's mode")
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".chrupio-backup") }
        XCTAssertEqual(backups.count, 2)
        for name in backups { XCTAssertEqual(try mode(folder.appendingPathComponent(name)), 0o600, "backups are private: \(name)") }

        let fresh = folder.appendingPathComponent("sub/settings.json")
        try ClaudeCodeSetup.updateSettings(fresh) { _ in ["a": 1] }
        XCTAssertEqual(try mode(fresh), 0o600, "a file Chrupio creates is private")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.deletingLastPathComponent().path), ["settings.json"],
                       "no backup of a file that didn't exist")
    }

    func testWriteSettingsThroughASymlinkEditsTheTargetAndBacksUpItsContent() throws {
        let real = folder.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"z\": 1, \"a\": 2}\n".utf8).write(to: real)
        let link = folder.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try ClaudeCodeSetup.updateSettings(link) { _ in ["z": 1, "a": 2, "b": 3] }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "the link stays a link")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{\n  \"z\": 1,\n  \"a\": 2,\n  \"b\": 3\n}\n")
        let latest = folder.appendingPathComponent("settings.json.chrupio-backup")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: latest.path)[.type] as? FileAttributeType, .typeRegular,
                       "a backup is a copy, not a link to the live file")
        XCTAssertEqual(try String(contentsOf: latest, encoding: .utf8), "{\"z\": 1, \"a\": 2}\n")
    }

    // MARK: Refusing files Chrupio can't edit exactly

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".chrupio-backup") }
    }

    private func assertRefused(_ bytes: Data, file name: String = "settings.json", line: UInt = #line) throws {
        let file = folder.appendingPathComponent(name)
        try bytes.write(to: file)
        XCTAssertThrowsError(try ClaudeCodeSetup.updateSettings(file) { settings in
            var settings = settings
            settings["hooks"] = ["SessionStart": []]
            return settings
        }, line: line) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Chrupio didn't change \(file.path): it couldn't read the file exactly as written. Fix it or add the setting by hand.",
                           line: line)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes, "the file is left as it was", line: line)
        XCTAssertEqual(try backups(), [], "nothing is written, not even a backup", line: line)
    }

    func testAFileOnlyFoundationReadsIsRefusedAndLeftAlone() throws {
        try assertRefused(Data(#"{"z": 1, "a": 2,}"#.utf8))
        try assertRefused(try XCTUnwrap(#"{"z": 1, "a": 2}"#.data(using: .utf16)))
    }

    func testARepeatedKeyIsRefusedAndLeftAlone() throws {
        try assertRefused(Data(#"{"model": "opus", "theme": "dark", "model": "sonnet"}"#.utf8))
    }

    func testAByteOrderMarkIsReadAndKept() throws {
        let file = folder.appendingPathComponent("settings.json")
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data(#"{"z": 1, "a": 2}"#.utf8)).write(to: file)
        try ClaudeCodeSetup.updateSettings(file) { settings in
            var settings = settings
            settings["b"] = 3
            return settings
        }
        XCTAssertEqual(try Data(contentsOf: file), bom + Data("{\n  \"z\": 1,\n  \"a\": 2,\n  \"b\": 3\n}".utf8),
                       "no newline at the end, as before")
    }

    func testAChangeMadeWhileChrupioEditsIsKeptAndChrupiosChangeAppliedOnTop() throws {
        let file = folder.appendingPathComponent("settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: file)
        var interruptions = 0
        try ClaudeCodeSetup.updateSettings(file, beforeWrite: {
            interruptions += 1
            // Claude Code saves its own change between Chrupio's read and write, once.
            if interruptions == 1 { try Data(#"{"model": "opus", "theme": "dark"}"#.utf8).write(to: file) }
        }) { settings in
            var settings = settings
            settings["hooks"] = ["SessionStart": []]
            return settings
        }
        XCTAssertEqual(interruptions, 2, "read and merged again once")
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(written["theme"] as? String, "dark", "Claude Code's change survives")
        XCTAssertNotNil(written["hooks"], "Chrupio's change is made")
    }

    func testAFileThatKeepsChangingIsLeftAlone() throws {
        let file = folder.appendingPathComponent("settings.json")
        try Data(#"{"n": 0}"#.utf8).write(to: file)
        var count = 0
        XCTAssertThrowsError(try ClaudeCodeSetup.updateSettings(file, beforeWrite: {
            count += 1
            try Data(#"{"n": \#(count)}"#.utf8).write(to: file)
        }) { settings in
            var settings = settings
            settings["hooks"] = ["SessionStart": []]
            return settings
        }) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Chrupio didn't change \(file.path): it changed while Chrupio was editing it. Try again.")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"n": 2}"#, "the other program's write is kept")
    }

    func testSettingsWithBothNormalizationsOfAKeyAreEditedAndKeepBoth() throws {
        let file = folder.appendingPathComponent("settings.json")
        try Data("{\"env\": {\"\(composed)\": \"1\", \"\(decomposed)\": \"2\"}}\n".utf8).write(to: file)
        try ClaudeCodeSetup.updateSettings(file) { settings in
            var settings = settings
            settings["hooks"] = ["SessionStart": []]
            return settings
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "{\n  \"env\": {\n    \"\(composed)\": \"1\",\n    \"\(decomposed)\": \"2\"\n  },\n  \"hooks\": {\n    \"SessionStart\": []\n  }\n}\n")
    }

    func testSettingsWithLookalikeTopLevelKeysAreRefused() throws {
        // Chrupio edits the top level and `hooks` as Swift dictionaries, which would silently drop one of the two.
        try assertRefused(Data("{\"\(composed)\": 1, \"\(decomposed)\": 2}".utf8))
        try assertRefused(Data("{\"hooks\": {\"\(composed)\": [], \"\(decomposed)\": []}}".utf8))
    }

    func testADanglingSymlinkIsRefusedAndStaysALink() throws {
        let missing = folder.appendingPathComponent("dotfiles/settings.json")
        let link = folder.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        XCTAssertThrowsError(try ClaudeCodeSetup.updateSettings(link) { _ in ["a": 1] }) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Chrupio didn't change \(link.path): it links to \(missing.path), which doesn't exist. Fix the link or add the setting by hand.")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), missing.path, "the link stays a link")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
