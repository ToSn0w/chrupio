import CryptoKit
import Foundation

/// The size and SHA-256 a downloaded model must have.
public struct PinnedFile: Sendable, Hashable {
    public let bytes: Int64
    public let sha256: String
    public init(bytes: Int64, sha256: String) {
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public enum ModelVerifier {
    public enum Failure: LocalizedError, Equatable {
        case incomplete(got: Int64, expected: Int64)
        case tooLarge(got: Int64, expected: Int64)
        case mismatch

        public var errorDescription: String? {
            switch self {
            case .incomplete(let got, let expected): "The download was incomplete (\(got) of \(expected) bytes). Try again."
            case .tooLarge(let got, let expected): "The download is larger than expected (\(got) bytes, expected \(expected)), so it was deleted. Try again."
            case .mismatch: "The downloaded file isn't the expected model (checksum mismatch), so it was deleted. Try again."
            }
        }
    }

    static func size(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }

    /// Cheap check for files already in place.
    public static func hasExpectedSize(_ file: URL, _ pin: PinnedFile) -> Bool { size(file) == pin.bytes }

    /// Throws unless `file` has the pinned size and hash. Reads in chunks, so a 1.5 GB model never sits in memory.
    public static func verify(_ file: URL, against pin: PinnedFile) throws {
        let got = size(file)
        guard got <= pin.bytes else { throw Failure.tooLarge(got: got, expected: pin.bytes) }
        guard got == pin.bytes else { throw Failure.incomplete(got: max(got, 0), expected: pin.bytes) }
        guard try sha256(of: file) == pin.sha256.lowercased() else { throw Failure.mismatch }
    }

    /// Moves a finished download into place only if it matches `pin`. On any failure the download is deleted
    /// and whatever was already at `destination` stays as it was: an existing file is swapped out by
    /// `replaceItemAt`, which keeps the old file if the swap fails, never deleted first.
    public static func install(_ download: URL, to destination: URL, pin: PinnedFile) throws {
        do {
            try verify(download, against: pin)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: download)
            } else {
                try FileManager.default.moveItem(at: download, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw error
        }
    }

    static func sha256(of file: URL, chunk: Int = 4 * 1_048_576) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Each chunk is autoreleased; without a pool per chunk a 1.5 GB model would stay in memory until the loop ends.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
