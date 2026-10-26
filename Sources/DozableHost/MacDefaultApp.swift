import CoreServices
import Foundation

// 599b: the notice says WHICH app opened a workspace file ("hello-doz opened report.html in Safari").
// LaunchServices is asked, read-only, which app is the default for that file — nothing is opened here
// (`WorkspaceFiles.open` does that with /usr/bin/open). The audit confines CoreServices to this file and
// `doz ui`'s UICommand.swift. 646: it also says where an editor is installed, by its bundle identifier
// (`EditorApps`) — again read-only. 666: and it opens a URL in the default browser (`openURL`) — a web port's sign-in
// link, which must never be a process argument (`/usr/bin/open URL` would put it in every process listing).

enum MacDefaultApp {
    /// 666: open `url` in this Mac's default browser through LaunchServices. false: LaunchServices refused.
    static func openURL(_ url: URL) -> Bool {
        LSOpenCFURLRef(url as CFURL, nil) == noErr
    }

    /// The default app's name for the file at `path` (nil: none, or LaunchServices could not say).
    static func name(forFile path: String) -> String? {
        guard let app = LSCopyDefaultApplicationURLForURL(URL(fileURLWithPath: path) as CFURL, .all, nil)?.takeRetainedValue() else {
            return nil
        }
        let name = ((app as URL).lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? nil : name
    }

    /// 646: where the app with this bundle identifier is installed (its `.app` folder), as LaunchServices knows it —
    /// read-only, nothing is launched (nil: not installed). The first one LaunchServices lists (its preferred copy).
    static func appPath(bundleIdentifier id: String) -> String? {
        guard let list = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return nil
        }
        return list.first(where: { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) })?.path
    }
}
