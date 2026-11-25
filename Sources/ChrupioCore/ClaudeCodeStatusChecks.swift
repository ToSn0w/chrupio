import Foundation

extension ClaudeCodeSetup.Status {
    /// One piece of a config file's connection, worded as Settings shows it.
    public struct Check: Sendable, Equatable {
        public let title: String
        public let ok: Bool

        public init(_ title: String, ok: Bool) {
            self.title = title
            self.ok = ok
        }
    }

    /// Server, digest hook, prompt hook and any OpenKrisp leftovers, in that order. A part that is off in `components`
    /// and not there reads "off" (fine). A part switched off but still there (a hook for any path) is not OK, as
    /// `ClaudeCodeSetup.connection` counts it.
    public func checks(binary: String, components: ClaudeCodeSetup.Components) -> [Check] {
        var checks: [Check] = []
        if !components.mcp {
            checks.append(registeredCommand == nil ? Check("server off", ok: true) : Check("server still registered", ok: false))
        } else if let registeredCommand {
            checks.append(registeredCommand == binary ? Check("server OK", ok: true) : Check("server points to another copy", ok: false))
        } else {
            checks.append(Check("server missing", ok: false))
        }
        if !components.digest {
            checks.append(digestHookFound ? Check("digest still installed", ok: false) : Check("digest off", ok: true))
        } else {
            checks.append(hookInstalled ? Check("digest OK", ok: true) : Check("digest missing", ok: false))
        }
        if !components.prompt {
            checks.append(promptHookFound ? Check("prompt updates still installed", ok: false) : Check("prompt updates off", ok: true))
        } else {
            checks.append(promptHookInstalled ? Check("prompt updates OK", ok: true) : Check("prompt updates missing", ok: false))
        }
        if hasLegacy { checks.append(Check("OpenKrisp leftovers (Connect replaces them)", ok: false)) }
        return checks
    }
}
