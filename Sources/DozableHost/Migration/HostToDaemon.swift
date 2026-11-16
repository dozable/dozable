// TEMPORARY MIGRATION — added in 0.50.0, when Dozable's background process was renamed from "the host" to "the daemon"
// (`doz host …` → `doz daemon …`, `<store>/host.lock|sock|pid|log` → `daemon.*`, settings `host.*` → `daemon.*`).
// The owner's ruling: no alias and no permanent backward compatibility — `doz host` is an unknown command; this file
// only carries a store and a settings file across ONE upgrade from 0.40.x.
//
// What it does (all through `begin`, called once, first thing, by `DozableEntry.main`):
//   · the store's former file names (`DozableStore.formerDaemonFiles`): a daemon of this build takes the old lock
//     `host.lock` as well as `daemon.lock` (after it, the same way: waiting for an older daemon that is exiting) and
//     holds both for its life, so an older doz that tries to start its host on this store never becomes a second
//     owner; a client reaches an older daemon still running on its old socket (it serves until it exits by itself
//     once idle, as after any update — the CLI's note names its version and `doz daemon stop`); the old log is renamed
//     to `daemon.log` the first time a daemon is launched;
//   · the settings' former names (`DozableSettings.formerNames`): `host.*` in doz.toml is read as `daemon.*` (with a
//     note) and moved by the first write, exactly as a 0.37 name is. `DOZ_HOST_IDLE` is NOT read (DOZ_DAEMON_IDLE is);
//   · the hand-over of fenced sessions from a 0.40.x host: that host starts the program now installed the way it
//     knows, `doz host start --launch-detached …`, whose intermediate runs `doz host start --foreground --launched …`.
//     Exactly those two internal forms (hidden flags no person types) are taken as `doz daemon start …`; anything
//     else beginning `doz host` stays an unknown command.
//
// To delete it (once every install has run a daemon of 0.50.0 or later): remove this file, its one call
// (`HostToDaemon.begin` in Sources/DozableCLI/UpdateCommands.swift, `DozableEntry.main`) and
// Tests/DozableCLITests/HostToDaemonMigrationTests.swift. The seams it fills are then inert (nil / empty); delete them
// in the same change: `DozableStore.FormerDaemonFiles` and its `former*` / `daemonSockets` / `adoptFormerLog` uses,
// `HostServer.takeLock`'s second lock (`formerLockFD`), `HostClient.connectAny`'s second socket,
// `DozableSettings.formerNames` / `aliasTarget`.
import Foundation

public enum HostToDaemon {
    /// The store's files as a 0.40.x host named them.
    public static let formerFiles = DozableStore.FormerDaemonFiles(lock: "host.lock", socket: "host.sock", pid: "host.pid", log: "host.log")

    /// doz.toml's keys as 0.40.x named them → their names now.
    public static let formerSettings: [String: String] = [
        "host.idle_timeout_minutes": SettingKey.idleTimeout,
        "host.screen_capture_minutes": SettingKey.screenCapture,
        "host.boot_logs_kept": SettingKey.bootLogsKept,
        "host.keepalive": SettingKey.keepalive,
    ]

    /// Install the migration's seams and return the arguments this process runs (`args` without the program name).
    public static func begin(_ args: [String]) -> [String] {
        DozableStore.formerDaemonFiles = formerFiles
        DozableSettings.formerNames = formerSettings
        return launcherArguments(args)
    }

    /// A 0.40.x host's launcher forms → `daemon start …`; every other argument list unchanged.
    public static func launcherArguments(_ args: [String]) -> [String] {
        guard args.count >= 2, args[0] == "host", args[1] == "start" else { return args }
        let intermediate = args.contains("--launch-detached")
        let launched = args.contains("--foreground") && args.contains("--launched")
        guard intermediate || launched else { return args }
        return ["daemon"] + args.dropFirst()
    }
}
