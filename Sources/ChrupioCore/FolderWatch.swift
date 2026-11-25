import CoreServices
import Foundation

/// Watches the meetings folder (recursively, FSEvents) and calls `onChange` once per burst of changes,
/// `debounce` seconds after the last one. Audio chunk writes during a call are ignored.
public final class FolderWatch: @unchecked Sendable {
    public let root: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "chrupio.folderwatch", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    public init(root: URL, debounce: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    /// False when every changed path is a chunk in an `audio` folder (WAV, its sidecar, or compressed audio).
    static func matters(_ paths: [String]) -> Bool {
        paths.contains { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name == "index.json" || name.hasPrefix("index.json.") { return false }
            return !(path.contains("/audio/") && ["wav", "json", "caf"].contains(URL(fileURLWithPath: path).pathExtension))
        }
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
                let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
                if FolderWatch.matters(Array(list.prefix(count))) { watch.schedule() }
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                                 | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        let stopNow = {
            self.pending?.cancel()
            self.pending = nil
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        queue.sync(execute: stopNow)
    }

    /// Runs on `queue` (the stream's dispatch queue).
    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
