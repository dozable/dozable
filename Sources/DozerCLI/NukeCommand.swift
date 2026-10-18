import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost
import DozerWeb

/// 623 — `doz nuke`: this Mac back to a fresh install, with `doz` itself left installed (owner, 2026-10-19:
/// "remove everything back to a fresh install, doz stays installed; dry run with --dry-run; lists everything and their
/// sizes and location with a prompt to confirm by default"). `doz uninstall`'s rules, plus the keychain items Dozable
/// made, minus the installed doz. It lists every item with its place and size, then asks (`--yes`, `--dry-run`).
/// Never: the person's own folders (workspaces), the Mac's Claude Code or Codex login, Apple's `container` data.
struct Nuke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put this Mac back to a fresh install of Dozable: every sandbox, image, setting and saved key goes; doz stays installed.",
        discussion: "Lists each item, where it is and its size, then asks once. --dry-run lists and changes nothing; --yes does not ask. Never your workspace folders, the Mac's Claude Code or Codex login, or Apple's container data. A running doz ui or doz serve for the store must be stopped first; a running host is stopped first (its sandboxes shut down with the store).")

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "List what would be removed, with sizes, and change nothing.") var dryRun = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    struct Item: Encodable, Equatable {
        enum Kind: String, Encodable { case folder, keychain }
        var kind: Kind
        var location: String
        var what: String
        /// Bytes on disk (allocated, clones counted in full); nil for a keychain item.
        var bytes: Int64?
        var removed: Bool?
        var error: String?
    }

    struct Report: Encodable {
        var dryRun: Bool
        var items: [Item]
        var kept: [String]
    }

    /// Everything a fresh install does not have — computed, never removed here (tests call it on scratch paths).
    static func plan(store: DozerStore, configDir: URL?, cacheDir: URL?, keychain: any KeychainAccess) throws -> (items: [Item], kept: [String]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var items: [Item] = []
        var kept: [String] = []
        if fm.fileExists(atPath: store.root.path) {
            guard store.root.path != "/", store.root.path != home else { throw HostError(.invalid, "refusing to remove \(store.root.path)") }
            guard Uninstall.looksLikeStore(store.root) else {
                throw HostError(.invalid, "\(store.root.path) does not look like a Dozable store — not removing it (check --store / $DOZ_STORE)")
            }
            let n = store.sandboxNames().count
            items.append(Item(kind: .folder, location: store.root.path,
                              what: "the store: \(n) sandbox\(n == 1 ? "" : "es"), every image, kernel, restore point and template, the host's log and metrics",
                              bytes: allocatedBytes(store.root)))
        }
        if let dir = configDir, fm.fileExists(atPath: dir.path) {
            guard dir.lastPathComponent == DozerSettings.directoryName else { throw HostError(.invalid, "refusing to remove \(dir.path)") }
            items.append(Item(kind: .folder, location: dir.path, what: "the settings: doz.toml, agent-prompt.md, the update and usage records",
                              bytes: allocatedBytes(dir)))
        }
        if let cacheDir, fm.fileExists(atPath: cacheDir.path), cacheDir.lastPathComponent == DozerSettings.directoryName {
            items.append(Item(kind: .folder, location: cacheDir.path, what: "the download cache (Apple's container installer)",
                              bytes: allocatedBytes(cacheDir)))
        }
        for i in keychain.items(servicePrefix: "doz-") where i.account == Keychain.user
            && (AccountStore.isDozItem(i.service) || i.service == Access.githubKeyService) {
            items.append(Item(kind: .keychain, location: "login keychain: \(i.service)", what: keychainWhat(i.service), bytes: nil))
        }
        kept.append("doz itself (\(HostLauncher.executablePath)) — `doz uninstall` removes it")
        kept.append("your workspace folders (\(DozerSettings.load().string(SettingKey.projectsDir).map { DisplayPath.tilde($0) } ?? "the projects folder") and any sandbox's folder)")
        kept.append("the Mac's own Claude Code and Codex logins")
        kept.append("Apple's container data (Dockerfile bases' builds) — `doz resources` shows it")
        return (items, kept)
    }

    static func keychainWhat(_ service: String) -> String {
        if service == Access.githubKeyService { return "the default GitHub key (doz access)" }
        if service.contains("#") { return "part of a saved sign-in" }
        let name = service.split(separator: ":", maxSplits: 1).last.map(String.init) ?? service
        return "the key of account \(name)"
    }

    /// Bytes allocated on disk under `url` (as `du`), links not followed.
    static func allocatedBytes(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// The one listing `doz nuke` and `doz inventory` print: each item's size, place and what it is, the total, what stays.
    static func printList(_ items: [Item], _ kept: [String], heading: String, keeps: String) {
        Out.stdout(heading + "\n")
        for i in items {
            Out.stdout("  \(i.bytes.map { size($0).padding(toLength: 10, withPad: " ", startingAt: 0) } ?? "          ")\(DisplayPath.tilde(i.location))\n")
            Out.stdout("            \(i.what)\n")
        }
        Out.stdout("  \(size(items.compactMap(\.bytes).reduce(0, +))) on disk in all (clones counted in full)\n")
        Out.stdout(keeps + "\n")
        for k in kept { Out.stdout("  \(k)\n") }
    }

    static func currentPlan(_ g: GlobalOptions) throws -> (store: DozerStore, keychain: any KeychainAccess, items: [Item], kept: [String]) {
        let store = g.dozerStore
        // A guarded test run never sees this Mac's own keychain or cache: an in-memory keychain, and the cache only
        // from the seam DOZ_TEST_CACHE_DIR (else none) — a `nuke --yes` in a test must not reach either.
        let env = ProcessInfo.processInfo.environment
        let guarded = TestSafety.guarded(env)
        let keychain = guarded ? MemoryKeychain() : CredentialServices.forHost().keychain
        let cacheDir: URL? = env["DOZ_TEST_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (guarded ? nil : TestSafety.realHome.appendingPathComponent("Library/Caches/\(DozerSettings.directoryName)"))
        do {
            let p = try plan(store: store, configDir: DozerSettings.fileURL()?.deletingLastPathComponent(), cacheDir: cacheDir, keychain: keychain)
            return (store, keychain, p.items, p.kept)
        } catch let e as HostError { throw fail(e, g) }
    }

    static func lockHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let held = flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
        if !held { flock(fd, LOCK_UN) }
        return held
    }

    func run() async throws {
        var (store, keychain, items, kept) = try Self.currentPlan(g)
        if items.isEmpty {
            if g.json { Out.json(Report(dryRun: dryRun, items: [], kept: kept)) } else { Out.stdout("nothing to remove: this Mac is already a fresh install\n") }
            return
        }
        if !g.json { Self.printList(items, kept, heading: dryRun ? "doz nuke would remove:" : "doz nuke removes:", keeps: "and keeps:") }
        if dryRun {
            if g.json { Out.json(Report(dryRun: true, items: items, kept: kept)) } else { Out.stdout("(dry run: nothing was removed)\n") }
            return
        }
        // A UI or doz serve working on this store would lose it under them.
        if Self.lockHeld(WebControl.lockFile(store)) { throw fail(HostError(.failed, "a doz ui is running for this store — stop it first (doz ui stop), then nuke"), g) }
        if Self.lockHeld(WebServeControl.lockFile(store.root)) { throw fail(HostError(.failed, "doz serve is running for this store — stop it first (doz serve stop), then nuke"), g) }
        try confirm("Remove all of the above? This cannot be undone.", yes: yes, g)
        if store.hostIsRunning() {
            if !g.json { Out.stdout("stopping the host …\n") }
            switch try? stopHostShowingProgress(store, g) {
            case .done(let r)?: if !g.json { Out.stdout(HostStopView.summary(r) + "\n") }
            case .exited(let seen)?: if !g.json { Out.stdout(HostStopView.seen(seen) + "\n") }
            default: break
            }
            let deadline = Date().addingTimeInterval(120)
            while store.hostIsRunning(), Date() < deadline { usleep(200_000) }
            if store.hostIsRunning() { throw fail(HostError(.failed, "the host did not stop within 2 minutes — nothing was removed"), g) }
        }
        var failed = false
        for i in items.indices {
            do {
                switch items[i].kind {
                case .folder: try FileManager.default.removeItem(atPath: items[i].location)
                case .keychain: try keychain.delete(service: String(items[i].location.dropFirst("login keychain: ".count)), account: Keychain.user)
                }
                items[i].removed = true
                if !g.json { Out.stdout("removed \(DisplayPath.tilde(items[i].location))\n") }
            } catch {
                failed = true
                items[i].removed = false
                items[i].error = error.localizedDescription
                if !g.json { Out.stderr("doz: could not remove \(items[i].location): \(error.localizedDescription)\n") }
            }
        }
        if g.json { Out.json(Report(dryRun: false, items: items, kept: kept)) }
        else if !failed { Out.stdout("This Mac is back to a fresh install of Dozable. Start again with: doz onboard (or doz ui)\n") }
        if failed { throw ExitCode(DozerExit.failed) }
    }
}

/// 623 — `doz inventory`: everything Dozable keeps on this Mac, with places and sizes — `doz nuke`'s list, for
/// information only (owner, 2026-10-19: "a doz inventory command that lists everything (same that nuke shows; just for
/// information only)"). Changes nothing and never starts a host.
struct Inventory: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List everything Dozable keeps on this Mac — where and how big — and change nothing (doz nuke's list).")

    @OptionGroup var g: GlobalOptions

    func run() throws {
        let (_, _, items, kept) = try Nuke.currentPlan(g)
        if g.json { Out.json(Nuke.Report(dryRun: true, items: items, kept: kept)); return }
        if items.isEmpty { Out.stdout("Dozable keeps nothing on this Mac yet\n"); return }
        Nuke.printList(items, kept, heading: "Dozable keeps on this Mac:", keeps: "and does not count:")
    }
}
