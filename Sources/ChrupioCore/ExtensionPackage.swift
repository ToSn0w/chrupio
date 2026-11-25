import Foundation

/// The unpacked Chrome extension: where the user loads it from, and keeping that copy current.
public enum ExtensionPackage {
    /// Name of the folder Chrome loads the extension from, inside Chrupio's Application Support folder.
    public static let folderName = "ChromeExtension"
    /// Name of the Desktop copy made by versions before phase 4. Kept only to recognise it; never written or removed.
    public static let legacyFolderName = "Chrupio Chrome Extension"

    /// `<support>/ChromeExtension`, where `support` is Chrupio's Application Support folder (`AppPaths.support` in the app).
    public static func installedFolder(support: URL) -> URL {
        support.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Where older versions put the copy. The app leaves it alone; the UI tells the user to load the new folder instead.
    public static func legacyDesktopFolder(home: URL = UserHome.url) -> URL {
        home.appendingPathComponent("Desktop", isDirectory: true).appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// True when an old Desktop copy exists, so the user should re-load the extension from the new folder in Chrome.
    public static func hasLegacyDesktopCopy(home: URL = UserHome.url) -> Bool {
        FileManager.default.fileExists(atPath: legacyDesktopFolder(home: home).path)
    }

    /// True when the installed copy is missing or differs from `source` (e.g. after an app update).
    public static func needsRefresh(from source: URL, support: URL) -> Bool {
        let destination = installedFolder(support: support)
        return !FileManager.default.fileExists(atPath: destination.path) || !sameContents(source, destination)
    }

    /// Copies `source` into `<support>/ChromeExtension` when missing or different. Returns that folder.
    @discardableResult
    public static func install(from source: URL, support: URL) throws -> URL {
        let destination = installedFolder(support: support)
        try install(from: source, to: destination)
        return destination
    }

    /// What the app does at launch: writes `<support>/ChromeExtension` when it is missing (fresh user) or differs from
    /// `source` (app update). Returns true when it wrote.
    @discardableResult
    public static func installIfNeeded(from source: URL, support: URL) throws -> Bool {
        guard needsRefresh(from: source, support: support) else { return false }
        return try install(from: source, to: installedFolder(support: support))
    }

    public static func version(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version"] as? String
    }

    public static var chromeFolder: URL { chromeFolder(home: UserHome.url) }

    public static func chromeFolder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// Chrome profiles where the extension isn't loaded or is turned off, by display name.
    /// Calls in those profiles are only caught by the microphone fallback: no title, no names, and back-to-back calls merge.
    public static func chromeProfilesWithoutExtension(chromeFolder: URL = chromeFolder) -> [String] {
        guard let data = try? Data(contentsOf: chromeFolder.appendingPathComponent("Local State")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        let names = cache.mapValues { $0["name"] as? String ?? "" }
        let repeated = Set(names.values.filter { name in names.values.filter { $0 == name }.count > 1 })
        return cache.keys.sorted().filter { !hasExtension(profile: chromeFolder.appendingPathComponent($0, isDirectory: true)) }.map { folder in
            let name = names[folder] ?? ""
            return name.isEmpty ? folder : repeated.contains(name) ? "\(name) (\(folder))" : name
        }
    }

    /// Unpacked extensions are listed in "Secure Preferences" (older Chrome: "Preferences") by the folder they load from.
    static func hasExtension(profile: URL) -> Bool {
        ["Secure Preferences", "Preferences"].contains { file in
            guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: [String: Any]] else { return false }
            return settings.values.contains { entry in
                guard let path = entry["path"] as? String, isChrupioFolder(URL(fileURLWithPath: path)) else { return false }
                let disabled = (entry["disable_reasons"] as? [Any]).map { !$0.isEmpty } ?? ((entry["disable_reasons"] as? Int ?? 0) != 0)
                return !disabled && (entry["state"] as? Int ?? 1) != 0
            }
        }
    }

    /// True when any Chrome profile lists an extension loaded from the old Desktop folder, turned on or not.
    public static func anyProfileLoadsLegacyCopy(chromeFolder: URL = chromeFolder) -> Bool {
        guard let data = try? Data(contentsOf: chromeFolder.appendingPathComponent("Local State")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return false }
        return cache.keys.contains { profile in
            ["Secure Preferences", "Preferences"].contains { file in
                guard let data = try? Data(contentsOf: chromeFolder.appendingPathComponent(profile, isDirectory: true).appendingPathComponent(file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: [String: Any]] else { return false }
                return settings.values.contains { ($0["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent == legacyFolderName } ?? false }
            }
        }
    }

    /// The current folder (`.../Chrupio/ChromeExtension`) or the old Desktop one.
    static func isChrupioFolder(_ url: URL) -> Bool {
        url.lastPathComponent == legacyFolderName
            || (url.lastPathComponent == folderName && url.deletingLastPathComponent().lastPathComponent == "Chrupio")
    }

    /// Compares dotted versions numerically ("0.10.0" is newer than "0.9.1").
    public static func isOlder(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// True when both folders hold the same files with the same bytes.
    static func sameContents(_ first: URL, _ second: URL) -> Bool {
        func files(_ root: URL) -> [String: Data] {
            let base = root.resolvingSymlinksInPath().path + "/"
            var result: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey])
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      !url.lastPathComponent.hasPrefix(".") else { continue }
                result[url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")] = try? Data(contentsOf: url)
            }
            return result
        }
        return files(first) == files(second)
    }

    /// Copies `source` to `destination` when it is missing or differs. Replaces the folder in one step,
    /// so Chrome never sees a half-written extension. Returns true when it wrote.
    @discardableResult
    public static func install(from source: URL, to destination: URL) throws -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path), sameContents(source, destination) { return false }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        // Removed on failure; after a successful move or replace it no longer exists.
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        return true
    }
}
