import DozableHost
import Foundation

/// A first-run confusion: a second store named with `DOZ_STORE` (or `--store`) still reads and writes this Mac's ONE
/// settings file (`${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml`) — and with it the chat server's ports — unless
/// `XDG_CONFIG_HOME` is set too; `doz config set` with a throwaway store wrote the real file. Config resolution is
/// unchanged; `doz config set`, `doz doctor` and `doz onboard` say which file they use when it is so.
enum SharedSettingsNote {
    /// The line, or nil: no store of its own is named, or the settings are already its own (`XDG_CONFIG_HOME` set).
    static func line(storeOption: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                     settingsPath: String? = DozableSettings.fileURL()?.path) -> String? {
        let named = (storeOption?.isEmpty == false ? storeOption : nil) ?? environment["DOZ_STORE"].flatMap { $0.isEmpty ? nil : $0 }
        guard let named, (environment["XDG_CONFIG_HOME"] ?? "").isEmpty else { return nil }
        let file = settingsPath.map { DisplayPath.tilde($0) } ?? "~/.config/doz/doz.toml"
        return "the store \(DisplayPath.tilde(named)) uses this Mac's settings file \(file) — shared, with the chat server's ports, by every store that has no XDG_CONFIG_HOME of its own; set XDG_CONFIG_HOME as well to give this store settings of its own"
    }
}
