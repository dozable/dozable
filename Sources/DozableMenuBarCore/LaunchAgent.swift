import Foundation
import os

/// `Dozable --launch-daemon` — what launchd runs at login (and every 15 minutes) for the app's agent
/// `com.dozable.app.daemon`. No NSApplication, nothing drawn: it finds doz (`DozLocator`, the standard places, a link kept
/// as found), requires Dozable's team signature in a release build, and REPLACES itself (`execv`) with
/// `doz daemon start --login-item` — doz's own login job: it starts the daemon the usual way (the double spawn: the
/// daemon's parent is launchd, never this job) and exits. doz missing, or refused: one log line, exit 0 — a Mac without
/// doz must not see a failing job every 15 minutes.
public enum LaunchAgent {
    public static let arguments = ["daemon", "start", "--login-item"]
    static let logger = Logger(subsystem: "com.dozable.app", category: "login")

    public enum Decision: Equatable, Sendable {
        /// Run this file (the candidate as found — a link is followed by the kernel) with `arguments`.
        case run(String)
        /// Nothing to run: why, in one line (logged).
        case none(String)
    }

    /// Which doz to run, if any: the first candidate that is an executable file and that `locator` accepts (the team
    /// check, in a release build). A candidate that exists but is refused is named in the reason.
    public static func decide(_ locator: DozLocator) -> Decision {
        var refused: [String] = []
        for c in locator.candidates where c.hasPrefix("/") && DozLocator.isExecutableFile(c) {
            if locator.accept(c) { return .run(c) }
            refused.append(c)
        }
        if !refused.isEmpty {
            return .none("doz at \(refused.joined(separator: ", ")) is not signed by Dozable (team \(DozSignature.teamID)) — the daemon was not started")
        }
        return .none("doz is not installed (looked in \(locator.candidates.joined(separator: ", "))) — nothing to start")
    }

    /// The dev flavour has no login agent (it registers nothing, and its bundle carries no agent plist): even if
    /// launchd or a person ran `--launch-daemon`, it starts nothing.
    public static let devRefusal = "the dev build has no login agent — the daemon was not started"

    public static func decide(_ locator: DozLocator, flavour: MenuBarFlavour) -> Decision {
        flavour.isDev ? .none(devRefusal) : decide(locator)
    }

    /// Whether this build requires Dozable's team signature of doz: a release build does; a development build (`make app`)
    /// does not — unless a test run asks for it (`DOZ_TEST_MENUBAR_REQUIRE_TEAM=1`, guarded runs only).
    public static func requiresTeam(releaseBuild: Bool, env: [String: String]) -> Bool {
        releaseBuild || (MenuBarSeams.guarded(env) && env["DOZ_TEST_MENUBAR_REQUIRE_TEAM"] == "1")
    }

    /// Run the agent: exec doz, or log why not and exit 0. Never returns.
    public static func run(locator: DozLocator, flavour: MenuBarFlavour = .release) -> Never {
        switch decide(locator, flavour: flavour) {
        case .none(let why):
            logger.notice("launch-daemon: \(why, privacy: .public)")
            exit(0)
        case .run(let doz):
            logger.notice("launch-daemon: \(doz, privacy: .public) daemon start --login-item")
            let argv = [doz] + arguments
            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            cargs.append(nil)
            execv(doz, &cargs)
            // Only when the exec itself failed.
            let e = String(cString: strerror(errno))
            logger.notice("launch-daemon: could not run \(doz, privacy: .public): \(e, privacy: .public)")
            exit(0)
        }
    }
}
