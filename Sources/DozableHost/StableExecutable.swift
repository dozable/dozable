import Foundation

/// 693 — the path a new daemon is started from when this one hands over or restarts in place: the path that names "the
/// doz installed now", which an upgrade does not take away.
///
/// A daemon knows its program by the RESOLVED path (`HostLauncher.executablePath`). For a Homebrew install that is the
/// keg (`…/Cellar/doz/0.50.4/libexec/doz/doz`) — which the next `brew upgrade` leaves behind and `brew cleanup` deletes. A
/// daemon that never exits must re-spawn from the formula's `opt` link instead (`…/opt/doz/libexec/doz/doz`), and must see
/// a new build there as its program replaced even when its own keg is still on disk (`ExecutableIdentity.change(now:
/// stableNow:)`), or an always-on daemon stays old forever.
///
///   · a keg `<prefix>/Cellar/<formula>/<version>/libexec/doz/doz` (formula doz, doz-beta, doz-canary) →
///     `<prefix>/opt/<formula>/libexec/doz/doz`, when that exists;
///   · a release tarball's or `make install-cli`'s `<prefix>/libexec/doz/doz` stays as it is (the folder is swapped in place);
///   · anything else: its resolved path.
public enum StableExecutable {
    /// The stable path of `executable` (default: this process's program).
    public static func path(for executable: String = HostLauncher.executablePath) -> String {
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        guard let keg = homebrewKeg(executable: exe.path) else { return exe.path }
        let prefix = keg.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // above Cellar
        let opt = prefix.appendingPathComponent("opt").appendingPathComponent(formula(keg)).appendingPathComponent("libexec/doz/doz")
        return FileManager.default.fileExists(atPath: opt.path) ? opt.path : exe.path
    }

    /// 598: this executable is a Homebrew keg's (`…/Cellar/doz/<version>/libexec/doz/doz`) — Homebrew owns those files:
    /// `brew uninstall doz` removes them, never `doz uninstall`. Returns the keg.
    public static func homebrewKeg(executable: String = HostLauncher.executablePath) -> URL? {
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let keg = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // …/Cellar/doz/<version>
        guard exe.pathComponents.suffix(3) == ["libexec", "doz", "doz"],
              UpdateChannel.ofFormula(keg.deletingLastPathComponent().lastPathComponent) != nil,   // doz, doz-beta, doz-canary (611)
              keg.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Cellar" else { return nil }
        return keg
    }

    /// 714: the release installed NOW at this executable's stable path — the `VERSION` beside the program the formula's
    /// `opt` link names (after a `brew upgrade`: the new keg's), or beside this program itself for any other install. nil
    /// without a stamp (a `swift build`). A process still running an old keg compares its own version with this one.
    public static func installedVersion(for executable: String = HostLauncher.executablePath) -> String? {
        ReleaseStamp.read(executable: path(for: executable))
    }

    /// The formula a keg belongs to (`…/Cellar/<formula>/<version>`): doz, doz-beta or doz-canary.
    public static func formula(_ keg: URL) -> String { keg.deletingLastPathComponent().lastPathComponent }

    /// The installation this executable belongs to, when it is one `make install-cli` (or the release tarball) made:
    /// `<prefix>/libexec/doz/doz` (and `<prefix>/bin/doz` when it links there).
    public static func installation(executable: String = HostLauncher.executablePath) -> (libexec: URL, link: URL?)? {
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let libexec = exe.deletingLastPathComponent()
        guard exe.lastPathComponent == "doz", libexec.lastPathComponent == "doz", libexec.deletingLastPathComponent().lastPathComponent == "libexec" else { return nil }
        let prefix = libexec.deletingLastPathComponent().deletingLastPathComponent()
        let link = prefix.appendingPathComponent("bin/doz")
        // The link counts only when it leads to this very executable (paths compared resolved: /tmp is /private/tmp).
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map {
            URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).resolvingSymlinksInPath().path
        }
        return (libexec, target == exe.path ? link : nil)
    }
}
