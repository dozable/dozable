import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost

/// The menu bar app, Dozable.app — `doz app install|status|uninstall`. The app rides INSIDE doz's own folder
/// (`libexec/doz/Dozable.app`, the CLI release and `make install-cli`; `make app` puts a development copy beside
/// `.build/debug/doz`), so it updates with doz; `doz app install` copies it to /Applications (or ~/Applications), where a
/// person opens it. Install by rename, verified first, never in place: a running app keeps its own files.
/// docs/engineering/menu-bar-app.md.
enum MenuBarAppInstall {
    static let bundleName = "Dozable.app"
    static let identifier = "com.dozable.app"
    static let stagedName = ".Dozable.app.new"

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

    /// The copy that came with this doz: `Dozable.app` beside the (resolved) executable.
    static func bundled(executable: String = HostLauncher.executablePath) -> URL? {
        let dir = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        let app = dir.appendingPathComponent(bundleName)
        return FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) ? app : nil
    }

    /// Where `doz app install` puts it without `--dest`: /Applications when this person can write there, else
    /// ~/Applications. A guarded test run: ONLY its seam `DOZ_TEST_APPLICATIONS_DIR` (never a real folder).
    static func defaultDestination(env: [String: String] = ProcessInfo.processInfo.environment, guarded: Bool = TestSafety.guarded(),
                                   home: URL = TestSafety.realHome,
                                   writable: (String) -> Bool = { access($0, W_OK) == 0 }) throws -> URL {
        if guarded {
            guard let seam = env["DOZ_TEST_APPLICATIONS_DIR"], seam.hasPrefix("/") else {
                throw Failure("a test run installs the menu bar app only into --dest DIR or DOZ_TEST_APPLICATIONS_DIR — never /Applications")
            }
            return URL(fileURLWithPath: seam)
        }
        return writable("/Applications") ? URL(fileURLWithPath: "/Applications") : home.appendingPathComponent("Applications")
    }

    /// Where installed copies are looked for: /Applications and ~/Applications — in a guarded run only the seam (or none).
    static func lookPlaces(env: [String: String] = ProcessInfo.processInfo.environment, guarded: Bool = TestSafety.guarded(),
                           home: URL = TestSafety.realHome) -> [URL] {
        MenuBarAppPlaces.lookPlaces(env: env, guarded: guarded, home: home)
    }

    /// The installed copies (bundles named Dozable.app whose identifier is this app's) in `places`.
    static func installedCopies(_ places: [URL]) -> [URL] {
        places.map { $0.appendingPathComponent(bundleName) }.filter { info($0)?.identifier == identifier }
    }

    struct BundleInfo: Equatable { var identifier: String?; var version: String? }

    /// A bundle's identifier and version, from its Info.plist (nil: no readable Info.plist).
    static func info(_ app: URL) -> BundleInfo? {
        guard let d = FileManager.default.contents(atPath: app.appendingPathComponent("Contents/Info.plist").path),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return BundleInfo(identifier: p["CFBundleIdentifier"] as? String, version: p["CFBundleShortVersionString"] as? String)
    }

    /// Whether a copy must be signed by Dozable's Developer ID team: this doz is a release (its RELEASE marker) — unless a
    /// guarded test says ad hoc is fine (`DOZ_TEST_UPDATE_ALLOW_ADHOC=1`, the update installer's seam).
    static func requiresTeam(executable: String = HostLauncher.executablePath, env: [String: String] = ProcessInfo.processInfo.environment,
                             guarded: Bool = TestSafety.guarded()) -> Bool {
        if guarded, env["DOZ_TEST_UPDATE_ALLOW_ADHOC"] == "1" { return false }
        let dir = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(UpdateInstaller.releaseMarker).path)
    }

    /// Why `app` may not be installed (nil: it may): its signature verifies (strict), its identifier is this app's, its team
    /// is Dozable's when required, and its version is `version` (doz's own — the copy that came with it).
    static func verify(_ app: URL, version: String, requireTeam: Bool, run: (String, [String]) -> (status: Int32, output: String) = runTool) -> String? {
        guard let i = info(app) else { return "\(app.path) has no readable Info.plist" }
        guard i.identifier == identifier else { return "\(app.path) is not Dozable's menu bar app (\(i.identifier ?? "no identifier"))" }
        guard i.version == version else { return "\(app.path) is version \(i.version ?? "?"), not this doz's \(version)" }
        guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else {
            return "\(app.path)'s signature does not verify — not installed"
        }
        let d = run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]).output
        guard d.contains("Identifier=\(identifier)\n") else { return "\(app.path) is not signed as \(identifier)" }
        if requireTeam, !d.contains("TeamIdentifier=\(Distribution.teamID)\n") {
            return "\(app.path) is not signed by Dozable's Developer ID (team \(Distribution.teamID)) — not installed"
        }
        return nil
    }

    static func runTool(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Before a copy goes (`doz app uninstall`, `doz uninstall`): ask it to take back the login item it holds — its own
    /// `Dozable --unregister` (SMAppService's agent and the app itself; it registers and unregisters only its own) — an
    /// argv, never a shell, at most `timeout` seconds. In a test run the app records what it would do and calls nothing.
    /// An older copy without the mode, or one that does not answer, changes nothing here. The result: whether it held one.
    struct Unregistered: Encodable, Equatable { var held: Bool; var ok: Bool; var note: String? }

    static func unregister(_ app: URL, timeout: Double = 15) -> Unregistered {
        let exe = app.appendingPathComponent("Contents/MacOS/" + MenuBarAppPlaces.executableName)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return Unregistered(held: false, ok: false, note: "no executable") }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--unregister"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Unregistered(held: false, ok: false, note: "could not run it") }
        let collected = LockedData()
        let reader = Thread { collected.set(pipe.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate(); usleep(300_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            return Unregistered(held: false, ok: false, note: "it did not answer within \(Int(timeout)) s")
        }
        p.waitUntilExit()
        let readDeadline = Date().addingTimeInterval(2)
        while collected.get() == nil, Date() < readDeadline { usleep(5_000) }
        struct Answer: Decodable { var ok: Bool?; var held: Bool? }
        guard p.terminationStatus == 0, let a = try? JSONDecoder().decode(Answer.self, from: collected.get() ?? Data()) else {
            return Unregistered(held: false, ok: false, note: "an older copy (no --unregister)")
        }
        return Unregistered(held: a.held ?? false, ok: a.ok ?? false, note: nil)
    }

    final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var d: Data?
        func set(_ v: Data) { lock.withLock { d = v } }
        func get() -> Data? { lock.withLock { d } }
    }

    /// Remove the quarantine mark from every file of `root` (the copy is verified before and after).
    static func removeQuarantine(_ root: URL) {
        let fm = FileManager.default
        var paths = [root.path]
        if let e = fm.enumerator(atPath: root.path) { while let p = e.nextObject() as? String { paths.append(root.appendingPathComponent(p).path) } }
        for p in paths { _ = removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    static func hasQuarantine(_ root: URL) -> Bool {
        var paths = [root.path]
        if let e = FileManager.default.enumerator(atPath: root.path) { while let p = e.nextObject() as? String { paths.append(root.appendingPathComponent(p).path) } }
        return paths.contains { getxattr($0, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    /// The processes of this user running a program inside `app` (a running menu bar app). In a guarded run, ONLY a
    /// stand-in counts: a process running the file the seam `DOZ_TEST_APP_STANDIN` names (outside any bundle) — a test
    /// never runs a program inside a scratch bundle (Gatekeeper judges it, and a stand-in there breaks the bundle's seal:
    /// "“Dozable” is damaged" on the person's screen). Without the seam a guarded run finds none.
    ///
    /// A copy whose program file is gone — an earlier `doz app install` swapped the bundle under it and removed the old one
    /// (`proc_pidpath` then fails) — is still found by its arguments (KERN_PROCARGS2: the path it was started from, and
    /// argv[0]): under the bundle's path, or under the staged name the old copy passed through (`isCopy`). Only this
    /// user's processes, ever.
    static func runningCopies(_ app: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> [pid_t] {
        // realpath(3), not URL's resolvingSymlinksInPath (which strips /private: /tmp/x stays /tmp/x, while the kernel's
        // record of a program in it says /private/tmp/x).
        let matches: (_ path: String?, _ started: [String]) -> Bool
        if TestSafety.guarded(env) {
            guard let seam = env["DOZ_TEST_APP_STANDIN"], seam.hasPrefix("/"), let r = realpath(seam, nil) else { return [] }
            let standin = String(cString: r)
            free(r)
            matches = { path, started in path.map { $0 == standin } ?? started.contains(standin) }
        } else {
            guard let real = realpath(app.path, nil) else { return [] }
            let inside = String(cString: real) + "/"
            free(real)
            let staged = (((inside as NSString).deletingLastPathComponent as NSString).appendingPathComponent(stagedName)) + "/"
            matches = { path, started in isCopy(path: path, started: started, inside: inside, staged: staged) }
        }
        var n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        n = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        guard n > 0 else { return [] }
        let me = getuid()
        return pids.prefix(Int(n)).filter { pid in
            guard pid > 1, pid != getpid(), owner(of: pid) == me else { return false }
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                return matches(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), [])
            }
            // Its file is gone (or unreadable): how it was started.
            return matches(nil, ProcessArguments.startedAs(pid))
        }
    }

    /// Whether a process is a copy of the app at `inside` (its path with a trailing `/`): by its program's path when that
    /// can be read; otherwise by how it was started (`started`: the path it was executed from and argv[0]) — under the
    /// bundle, or under the staged name (`staged`, with a trailing `/`) an install passes the old copy through. Pure.
    static func isCopy(path: String?, started: [String], inside: String, staged: String) -> Bool {
        if let path { return path.hasPrefix(inside) }
        return started.contains { $0.hasPrefix(inside) || $0.hasPrefix(staged) }
    }

    /// The uid a process runs as (nil: not readable).
    static func owner(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    /// SIGTERM each, then wait up to `seconds` for them to go. The ones still running.
    @discardableResult
    static func quit(_ pids: [pid_t], seconds: Double = 5) -> [pid_t] {
        for p in pids { kill(p, SIGTERM) }
        let deadline = Date().addingTimeInterval(seconds)
        var left = pids
        while !left.isEmpty, Date() < deadline {
            usleep(100_000)
            left = left.filter { kill($0, 0) == 0 }
        }
        return left
    }

    struct Installed: Encodable {
        var path: String
        var version: String
        var previousVersion: String?
        /// Running copies quit (with --open).
        var quit: Int
        var opened: Bool
    }

    /// Install `bundled` into `dest`: verified, copied beside its place (`ditto`), the quarantine mark removed, verified
    /// again, then swapped in by ONE rename (`renamex_np` RENAME_SWAP when a copy is there — a running app keeps its own
    /// files; the previous copy is removed only after the swap). With `open`, a running copy is quit and the new one opened.
    static func install(bundled: URL, dest: URL, version: String, requireTeam: Bool, open: Bool,
                        opener: (URL) -> Bool) throws -> Installed {
        TestSafety.enforce(TestSafety.applicationsViolation(dest))
        if let why = verify(bundled, version: version, requireTeam: requireTeam) { throw Failure(why) }
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appendingPathComponent(bundleName)
        let staged = dest.appendingPathComponent(stagedName)
        var previous: String?
        if fm.fileExists(atPath: target.path) {
            let i = info(target)
            guard i?.identifier == identifier else {
                throw Failure("\(target.path) is another app (\(i?.identifier ?? "unreadable")) — not replaced")
            }
            previous = i?.version
        }
        try? fm.removeItem(at: staged)
        let copied = runTool("/usr/bin/ditto", [bundled.path, staged.path])
        guard copied.status == 0 else {
            try? fm.removeItem(at: staged)
            throw Failure("could not copy the menu bar app to \(staged.path): \(copied.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        removeQuarantine(staged)
        if let why = verify(staged, version: version, requireTeam: requireTeam) {
            try? fm.removeItem(at: staged)
            throw Failure("the copy does not verify: \(why)")
        }
        let running = open ? runningCopies(target) : []
        if previous != nil {
            guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                let why = String(cString: strerror(errno))
                try? fm.removeItem(at: staged)
                throw Failure("could not swap the new copy in (\(why)) — \(target.path) is unchanged")
            }
            try? fm.removeItem(at: staged)            // the previous copy, now at the staged name
        } else {
            guard rename(staged.path, target.path) == 0 else {
                let why = String(cString: strerror(errno))
                try? fm.removeItem(at: staged)
                throw Failure("could not move the copy into \(target.path) (\(why))")
            }
        }
        var opened = false
        if open {
            quit(running)
            opened = opener(target)
        }
        return Installed(path: target.path, version: version, previousVersion: previous, quit: running.count, opened: opened)
    }

    /// Open an app through LaunchServices (`open`, an argv — no shell). A guarded test run never opens anything: it writes
    /// `open <path>` to `DOZ_TEST_APP_OPEN_LOG` instead, and without that seam it STOPS (`TestSafety.appOpenViolation`).
    static func openApp(_ app: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        TestSafety.enforce(TestSafety.appOpenViolation(env: env), env: env)
        if TestSafety.guarded(env) {
            guard let log = env["DOZ_TEST_APP_OPEN_LOG"], log.hasPrefix("/") else { return false }
            let line = Data("open \(app.path)\n".utf8)
            if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { FileManager.default.createFile(atPath: log, contents: line) }
            return true
        }
        return runTool("/usr/bin/open", [app.path]).status == 0
    }
}

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "app",
        abstract: "The menu bar app (Dozable.app): the daemon's state, Start, Stop, Restart and the dashboard from the menu bar.",
        discussion: "It comes with doz and updates with it; doz app install puts it in /Applications (or ~/Applications), where you open it once.",
        subcommands: [AppInstall.self, AppStatusCommand.self, AppUninstall.self])
}

struct AppInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install",
        abstract: "Install the menu bar app that came with this doz (verified, then swapped in by rename).",
        discussion: "Into /Applications, or ~/Applications when /Applications is not writable — or --dest DIR. A running copy keeps running the version it started with until it is opened again: --open quits it and opens the new one.")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "The folder to install it in (default /Applications, else ~/Applications).") var dest: String?
    @Flag(name: .long, help: "Quit a running copy and open the new one.") var open = false

    func run() async throws {
        // A test run never asks macOS to open an app: stopped BEFORE anything is installed when it has no seam.
        if open { TestSafety.enforce(TestSafety.appOpenViolation()) }
        guard let bundled = MenuBarAppInstall.bundled() else {
            throw fail(HostError(.notFound, "this doz carries no menu bar app (the release and Homebrew's doz do; a source build: make app, or make install-cli)"), g)
        }
        let dir: URL
        do { dir = try dest.map { URL(fileURLWithPath: $0) } ?? MenuBarAppInstall.defaultDestination() } catch {
            throw fail(HostError(.invalid, "\(error)"), g)
        }
        do {
            let r = try MenuBarAppInstall.install(bundled: bundled, dest: dir.standardizedFileURL, version: DozableCommand.version,
                                                  requireTeam: MenuBarAppInstall.requiresTeam(), open: open,
                                                  opener: { MenuBarAppInstall.openApp($0) })
            if g.json { Out.json(r); return }
            let was = r.previousVersion.map { $0 == r.version ? " (it was already \($0): replaced)" : " (was \($0))" } ?? ""
            Out.stdout("installed \(DisplayPath.tilde(r.path)) — the menu bar app \(r.version)\(was)\n")
            if open { Out.stdout(r.opened ? "opened it\(r.quit > 0 ? " (the running copy was quit)" : "")\n" : "could not open it — open it from Finder\n") }
            else if !MenuBarAppInstall.runningCopies(URL(fileURLWithPath: r.path)).isEmpty {
                Out.stdout("the menu bar app that is running is still the old copy: restart it to use \(r.version) — choose Restart to Update in its menu, or doz app install --open (quits it and opens the new one)\n")
            } else if r.previousVersion != nil { Out.stdout("a running copy keeps its version until it is opened again (doz app install --open restarts it)\n") }
            else { Out.stdout("open it: open \(DisplayPath.tilde(r.path))   (or from Finder; it lives in the menu bar)\n") }
        } catch let e as MenuBarAppInstall.Failure {
            throw fail(HostError(.failed, e.description), g)
        }
    }
}

struct AppStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "The menu bar app: the copy that came with this doz, the installed copies, which run. (Changes nothing.)")
    @OptionGroup var g: GlobalOptions

    struct Copy: Encodable { var path: String; var version: String?; var running: Bool? }
    struct Report: Encodable {
        var bundled: Copy?
        var installed: [Copy]
        var defaultDestination: String?
    }

    func run() async throws {
        let bundled = MenuBarAppInstall.bundled().map { Copy(path: $0.path, version: MenuBarAppInstall.info($0)?.version, running: nil) }
        let installed = MenuBarAppInstall.installedCopies(MenuBarAppInstall.lookPlaces()).map {
            Copy(path: $0.path, version: MenuBarAppInstall.info($0)?.version, running: !MenuBarAppInstall.runningCopies($0).isEmpty)
        }
        let r = Report(bundled: bundled, installed: installed, defaultDestination: (try? MenuBarAppInstall.defaultDestination())?.path)
        if g.json { Out.json(r); return }
        Out.stdout("with this doz: " + (bundled.map { "\(DisplayPath.tilde($0.path)) (\($0.version ?? "?"))" } ?? "none (a source build: make app)") + "\n")
        if installed.isEmpty {
            Out.stdout("installed: none — doz app install\n")
        }
        for c in installed {
            let newer = bundled?.version.map { v in c.version != v ? " — doz app install updates it to \(v)" : "" } ?? ""
            Out.stdout("installed: \(DisplayPath.tilde(c.path)) (\(c.version ?? "?"))\(c.running == true ? ", running" : "")\(newer)\n")
        }
    }
}

struct AppUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall",
        abstract: "Quit and remove the installed menu bar app (the daemon keeps running).",
        discussion: "Removes Dozable.app from /Applications and ~/Applications (or --dest DIR). The copy that came with doz stays (doz uninstall, or uninstalling doz, removes it).")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "The folder it was installed in (default: /Applications and ~/Applications).") var dest: String?
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    struct Removed: Encodable { var path: String; var removed: Bool; var error: String?; var loginItem: MenuBarAppInstall.Unregistered? }

    func run() async throws {
        let places = dest.map { [URL(fileURLWithPath: $0).standardizedFileURL] } ?? MenuBarAppInstall.lookPlaces()
        for p in places { TestSafety.enforce(TestSafety.applicationsViolation(p)) }
        let copies = MenuBarAppInstall.installedCopies(places)
        if copies.isEmpty {
            if g.json { Out.json([Removed]()) } else { Out.stdout("the menu bar app is not installed\(dest.map { " in \($0)" } ?? "")\n") }
            return
        }
        if !g.json { for c in copies { Out.stdout("removes \(DisplayPath.tilde(c.path)) (and its Start at Login, when on)\n") } }
        try confirm("Quit and remove the menu bar app?", yes: yes, g)
        var out: [Removed] = []
        for c in copies {
            // Its login item first, by the copy itself (SMAppService takes back only what that app registered).
            let un = MenuBarAppInstall.unregister(c)
            if !g.json, un.held {
                Out.stdout("removed its Start at Login — doz daemon login-item on starts the daemon at login again\n")
            }
            MenuBarAppInstall.quit(MenuBarAppInstall.runningCopies(c))
            do {
                try FileManager.default.removeItem(at: c)
                out.append(Removed(path: c.path, removed: true, loginItem: un))
                if !g.json { Out.stdout("removed \(DisplayPath.tilde(c.path))\n") }
            } catch {
                out.append(Removed(path: c.path, removed: false, error: error.localizedDescription, loginItem: un))
                if !g.json { Out.stderr("doz: could not remove \(c.path): \(error.localizedDescription)\n") }
            }
        }
        if g.json { Out.json(out) }
        if out.contains(where: { !$0.removed }) { throw ExitCode(DozableExit.failed) }
    }
}
