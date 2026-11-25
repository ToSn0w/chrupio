import Foundation

/// Files only this account can read: meeting notes, the local API token and the file that says where the app listens.
public enum FilePermissions {
    /// Creates `folder` (and its parents) if needed and sets it to 0700.
    public static func ensurePrivateDirectory(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Writes `data` to a new 0600 file next to `file`, then renames it over `file`. The file is never readable
    /// by other accounts, not even between the write and a chmod. The temporary name is short and fixed-length, so
    /// any name that fits on disk can be written. `mode` replaces 0600 when rewriting someone else's file whose
    /// mode should stay as it was. `onlyIf` runs after the new file is written and synced, right before the rename;
    /// when it returns false the new file is deleted, `file` is left as it is, and the result is false.
    @discardableResult
    public static func writePrivately(_ data: Data, to file: URL, mode: mode_t = 0o600,
                                      onlyIf: () throws -> Bool = { true }) throws -> Bool {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".chrupio-\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closed = false
        do {
            if mode != 0o600, fchmod(descriptor, mode) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            closed = true // close() releases the descriptor even when it throws; never close it twice.
            try handle.close()
            guard try onlyIf() else {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            guard rename(temp.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return true
        } catch {
            if !closed { try? handle.close() }
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Why `readPrivately` refused a file. The description names the file and the reason in plain words; `path` is
    /// the full path, for messages that ask the user to delete what's there.
    public struct UnsafeFile: Error, Equatable, LocalizedError {
        public enum Reason: Sendable, Equatable { case link, folder, notAFile, notOwned, readableByOthers }
        public let name: String
        public let path: String
        public let reason: Reason

        public var errorDescription: String? {
            switch reason {
            case .link: return "\(name) is a link to another file"
            case .folder: return "\(name) is a folder"
            case .notAFile: return "\(name) is not a regular file"
            case .notOwned: return "\(name) belongs to another account"
            case .readableByOthers: return "\(name) can be read by other accounts"
            }
        }
    }

    /// Reads a secret file only when it is a regular file (not a link), owned by `owner` and readable by nobody
    /// else (no group or other bits). Nil when the file doesn't exist. The checks run on the opened descriptor, so
    /// a file swapped after the first look is still checked. Reads at most `maxBytes`.
    public static func readPrivately(_ file: URL, owner: uid_t = getuid(), maxBytes: Int = 64 * 1024) throws -> Data? {
        func unsafe(_ reason: UnsafeFile.Reason) -> UnsafeFile { UnsafeFile(name: file.lastPathComponent, path: file.path, reason: reason) }
        func check(_ info: stat) throws {
            switch info.st_mode & S_IFMT {
            case S_IFREG: break
            case S_IFLNK: throw unsafe(.link)
            case S_IFDIR: throw unsafe(.folder)
            default: throw unsafe(.notAFile)
            }
            if info.st_uid != owner { throw unsafe(.notOwned) }
            if info.st_mode & 0o077 != 0 { throw unsafe(.readableByOthers) }
        }
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try check(info)
        // O_NOFOLLOW: a file replaced by a link after the lstat fails with ELOOP instead of opening the target.
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw unsafe(.link) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try check(info)
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    /// Sets every note this app wrote directly in `folder` (named like `MeetingExporter.fileName(for:)`) to 0600,
    /// and `folder` itself to 0700 when `includingFolder`. Other files, and anything that is not a regular file
    /// (symlinks included, so a link's target is never changed), are left alone. Returns how many files changed.
    /// A missing folder is left alone.
    @discardableResult
    public static func tighten(folder: URL, includingFolder: Bool) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        if includingFolder { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        var changed = 0
        for name in names where MeetingExporter.isExportFileName(name) {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 != 0 else { continue }
            // AT_SYMLINK_NOFOLLOW: a file swapped for a link after the lstat still doesn't change the link's target.
            if fchmodat(AT_FDCWD, path, 0o600, AT_SYMLINK_NOFOLLOW) == 0 { changed += 1 }
        }
        return changed
    }
}
