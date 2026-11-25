import Foundation

/// Copy for loading the unpacked Chrome extension, shared by onboarding and Settings > Meetings.
public enum ExtensionLoadGuide {
    public static let steps = [
        "Open chrome://extensions in Chrome.",
        "Turn on Developer mode (top right).",
        "Click Load unpacked.",
        "Press Cmd+Shift+G and paste the folder path.",
        "Select the ChromeExtension folder and click Select.",
    ]

    public static let connectedNote = "When it works, Chrupio shows the extension as Connected within 30 seconds."

    public static let developerModeNote = "Chrome shows a notice about Developer mode extensions. That is expected for extensions loaded this way. Chrome loads the extension from this folder, so leave it where it is. Chrupio updates it for you."

    /// Shown when a Chrome profile still loads the old Desktop copy, or that copy still exists.
    public static func movedFolderNotice(profileLoadsLegacy: Bool, legacyExists: Bool) -> String? {
        let fix = "In chrome://extensions, remove Chrupio Companion, then load the new folder with the steps below. After that, delete the \"\(ExtensionPackage.legacyFolderName)\" folder from your Desktop."
        if profileLoadsLegacy {
            return "The extension folder moved. Chrome still loads the old copy on your Desktop, and that copy no longer gets updates. " + fix
        }
        if legacyExists {
            return "The extension folder moved. The old copy on your Desktop no longer gets updates. If Chrome loads it, " + fix.prefix(1).lowercased() + fix.dropFirst()
        }
        return nil
    }
}
