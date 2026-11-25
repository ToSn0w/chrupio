import AppKit
import CoreAudio
import Foundation

/// Asks Core Audio which processes are currently capturing from an input device (macOS 14+).
public enum ProcessAudioMonitor {
    public struct AudioProcess: Sendable, Hashable {
        public var pid: pid_t
        public var bundleID: String?
    }

    public static func processesUsingMicrophone() -> [AudioProcess] {
        processObjects().compactMap { object in
            guard boolProperty(object, kAudioProcessPropertyIsRunningInput) else { return nil }
            var pid: pid_t = -1
            var size = UInt32(MemoryLayout<pid_t>.size)
            var address = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return nil }
            return AudioProcess(pid: pid, bundleID: bundleID(object))
        }
    }

    /// True when Zoom (or its meeting host helper) holds the microphone.
    public static func isZoomUsingMicrophone(_ processes: [AudioProcess]) -> Bool {
        processes.contains { process in
            if let id = process.bundleID, id.hasPrefix("us.zoom") { return true }
            let name = NSRunningApplication(processIdentifier: process.pid)?.localizedName ?? ""
            return name.localizedCaseInsensitiveContains("zoom") || name == "CptHost"
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(selector)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(kAudioProcessPropertyBundleID)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
