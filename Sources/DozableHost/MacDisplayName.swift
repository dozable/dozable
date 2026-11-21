import Foundation

/// 747: the name this Mac goes by in its history (the timeline's `host:` scope) and in a space's state (SpaceState's
/// `host`): the setting `daemon.mac_name`, "this Mac" by default — chosen by its owner, never read from the network
/// (not the LocalHostName, a `.local` name, a tailnet name or an address). A guarded test run keeps `DOZ_TEST_MAC_NAME`
/// when it sets one. The installable dashboard's name is the web layer's own (`WebAppName`, the LocalHostName).
public enum MacDisplayName {
    public static let fallback = "this Mac"

    /// 1–63 letters, digits, spaces and hyphens, not starting or ending with a space.
    public static func isValid(_ s: String) -> Bool {
        guard (1...63).contains(s.count), s.first != " ", s.last != " " else { return false }
        return s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == " " || $0 == "-" }
    }

    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if TestSafety.guarded(env), let t = env["DOZ_TEST_MAC_NAME"], !t.isEmpty { return t }
        let v = DozableSettings.load(environment: env).string(SettingKey.macName) ?? fallback
        return isValid(v) ? v : fallback
    }

    /// The host segment of a timeline scope: `host:this%20Mac`.
    public static func scope(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        TimelineScope.join("", "host", current(env))
    }
}
