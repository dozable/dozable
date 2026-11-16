import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost
#if !DOZ_NO_WEB
import DozableWeb
#endif

/// 594 (D13) — `doz uninstall`: a clean slate without a hand-typed `rm -rf`. It lists EXACTLY what it
/// removes and asks once (plainly; `--yes` for scripts): the store (every sandbox, image, kernel and
/// the host's files), the settings directory, and the installed `doz` (`make install-cli`'s
/// `<prefix>/libexec/doz/` and the `<prefix>/bin/doz` link to it). It never touches the keychain
/// (items `doz account add` made are listed, with how to remove them) nor anything of Claude Code's.
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove Dozable from this Mac: the store, the settings and the installed doz — listed first, asked once.",
        discussion: "Never the keychain and never Claude Code's own files. --keep-store and --keep-config leave those. A running doz ui for the store must be stopped first; a running daemon is stopped first (its sandboxes hibernate, then the store goes).")

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Leave the store (sandboxes, images) where it is.") var keepStore = false
    @Flag(name: .long, help: "Leave the settings directory (doz.toml, agent-prompt.md).") var keepConfig = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    struct Item: Encodable {
        var path: String
        var what: String
        var removed: Bool?
        var error: String?
    }

    struct Report: Encodable {
        var removed: [Item]
        var kept: [String]
        var keychain: [String]
    }

    // 693: `installation`, `homebrewKeg` and `formula` live in DozableHost (`StableExecutable`) — the daemon's hand-over
    // and its restart in place need them too.

    /// A store directory is removed only when it looks like one (or is empty): never a folder
    /// someone pointed --store at by mistake.
    static func looksLikeStore(_ root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if names.isEmpty { return true }
        let known: Set<String> = ["sandboxes", "images", "kernels", "golden", "content", "initfs.ext4", "daemon.log", "daemon.lock", "host.log", "host.lock", "metrics.sqlite",
                                  "accounts.json", "onboarded.json", "ui.lock", "ui.port", "ui.sessions", "state.json", "containers"]
        return names.contains(where: known.contains)
    }

    func run() async throws {
        let fm = FileManager.default
        let store = g.dozableStore
        var items: [Item] = []
        var kept: [String] = []
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        // The store.
        if keepStore {
            kept.append("the store \(store.root.path) (--keep-store)")
        } else if fm.fileExists(atPath: store.root.path) {
            guard store.root.path != "/", store.root.path != home else { throw fail(HostError(.invalid, "refusing to remove \(store.root.path)"), g) }
            guard Self.looksLikeStore(store.root) else {
                throw fail(HostError(.invalid, "\(store.root.path) does not look like a Dozable store — not removing it (check --store / $DOZ_STORE)"), g)
            }
            let n = store.sandboxNames().count
            items.append(Item(path: store.root.path, what: "the store: \(n) sandbox\(n == 1 ? "" : "es"), every image, kernel and restore point, the daemon's log and metrics"))
        }
        // The settings.
        let configDir = DozableSettings.fileURL()?.deletingLastPathComponent()
        if keepConfig {
            kept.append("the settings \(configDir?.path ?? "(none)") (--keep-config)")
        } else if let dir = configDir, fm.fileExists(atPath: dir.path) {
            guard dir.lastPathComponent == DozableSettings.directoryName else { throw fail(HostError(.invalid, "refusing to remove \(dir.path)"), g) }
            items.append(Item(path: dir.path, what: "the settings: doz.toml, agent-prompt.md"))
        }
        // The installed doz — unless Homebrew installed it (then brew removes it, and says so below).
        let keg = StableExecutable.homebrewKeg()
        if let keg {
            kept.append("the doz Homebrew installed (\(keg.path)) — `brew uninstall \(StableExecutable.formula(keg))` removes it (and `brew untap \(Distribution.tap)` the tap)")
        } else if let inst = StableExecutable.installation() {
            items.append(Item(path: inst.libexec.path, what: "the installed doz and its resources"))
            if let link = inst.link { items.append(Item(path: link.path, what: "the doz command (a link to it)")) }
        } else {
            kept.append("this doz (\(HostLauncher.executablePath)) — not an installed one (make install-cli installs to <prefix>/libexec/doz)")
        }
        // 694: this store's login item (bootout, then the plist) — never another store's, which are listed only.
        let agents = LaunchAgentsFolder.current()
        let loginItem = DaemonLoginItem.plistURL(store, folder: agents)
        if fm.fileExists(atPath: loginItem.path) {
            items.insert(Item(path: loginItem.path, what: "this store's login item (it starts the daemon when you log in)"), at: 0)
        }
        for other in DaemonLoginItem.otherItems(store, folder: agents) {
            kept.append("\(DisplayPath.tilde(other.path)) — another store's login item (doz uninstall --store THAT-STORE removes it)")
        }
        // Never the keychain: say what is left there.
        let accounts = AccountStore(store: store, settings: .load()).load().accounts.compactMap { a -> String? in
            guard let s = a.keychainService, a.adopted != true else { return nil }
            return "\(s) (account \(a.name) — doz account rm \(a.name) removes it; do that BEFORE uninstalling)"
        }
        kept.append("the keychain (never touched)" + (accounts.isEmpty ? "" : ": " + accounts.joined(separator: " · ")))
        kept.append("Claude Code's own files and login (never touched)")

        if items.isEmpty {
            if g.json { Out.json(Report(removed: [], kept: kept, keychain: accounts)) } else { Out.stdout("nothing to remove\n") }
            return
        }
        if !g.json {
            Out.stdout("doz uninstall removes exactly this:\n")
            for i in items { Out.stdout("  \(i.path)\n      \(i.what)\n") }
            Out.stdout("and leaves:\n")
            for k in kept { Out.stdout("  \(k)\n") }
        }
        // A UI serving this store would lose its store under it.
        let uiLock = open(WebControl.lockFile(store).path, O_RDONLY | O_CLOEXEC)
        if uiLock >= 0 {
            let held = flock(uiLock, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
            if !held { flock(uiLock, LOCK_UN) }
            close(uiLock)
            if held { throw fail(HostError(.failed, "a doz ui is running for this store — stop it first (Ctrl-C where it runs), then uninstall"), g) }
        }
        try confirm("Remove all of the above?", yes: yes, g)
        // The sessions on this Mac are not the store's: asked whether to end them (--yes ends them). Left running, no doz
        // reaches them again once their records are gone.
        let onMac = keepStore ? [] : await MacCLI.running(store)
        if !onMac.isEmpty {
            let list = onMac.joined(separator: ", ")
            if yes || MacCLI.ask("End the \(onMac.count) session\(onMac.count == 1 ? "" : "s") running on this Mac (\(list))? Left running, doz cannot reach them again") {
                let ended = MacCLI.endAll(onMac, g)
                if !g.json { Out.stdout("ended \(ended.count) session\(ended.count == 1 ? "" : "s") on this Mac\n") }
            } else if !g.json {
                Out.stdout("the sessions on this Mac keep running (\(list)) — end them yourself when you are done\n")
            }
        }
        // 694: the login item before the daemon (its next look would start one for a store about to go).
        if let i = items.firstIndex(where: { $0.path == loginItem.path }) {
            items[i].removed = DaemonLoginItem.remove(store: store, folder: agents)
            if items[i].removed == false { items[i].error = "could not remove it" }
            if !g.json { Out.stdout(items[i].removed == true ? "removed \(loginItem.path)\n" : "doz: could not remove \(loginItem.path)\n") }
        }
        // The host goes first (it owns every VM); it shuts them down as it stops.
        if !keepStore, store.hostIsRunning() {
            if !g.json { Out.stdout("stopping the daemon …\n") }
            // 594 W22: the same progress as `doz host stop` (each sandbox as it hibernates, then the summary).
            switch try? stopHostShowingProgress(store, g) {
            case .done(let r)?: if !g.json { Out.stdout(HostStopView.summary(r) + "\n") }
            case .exited(let seen)?: if !g.json { Out.stdout(HostStopView.seen(seen) + "\n") }
            default: break
            }
            let deadline = Date().addingTimeInterval(120)
            while store.hostIsRunning(), Date() < deadline { usleep(200_000) }
            if store.hostIsRunning() { throw fail(HostError(.failed, "the daemon did not stop within 2 minutes — nothing was removed"), g) }
        }
        var failed = false
        for i in items.indices where items[i].path != loginItem.path {
            do {
                try fm.removeItem(atPath: items[i].path)
                items[i].removed = true
                if !g.json { Out.stdout("removed \(items[i].path)\n") }
            } catch {
                failed = true
                items[i].removed = false
                items[i].error = error.localizedDescription
                if !g.json { Out.stderr("doz: could not remove \(items[i].path): \(error.localizedDescription)\n") }
            }
        }
        // The store's socket folder for sessions on this Mac, once nothing runs in it.
        if !keepStore, await MacCLI.running(store).isEmpty { MacCLI.removeSocketFolder(store) }
        if g.json { Out.json(Report(removed: items, kept: kept, keychain: accounts)) }
        else if !failed {
            if let keg {
                Out.stdout("Dozable's store and settings are removed. Finish with: brew uninstall \(StableExecutable.formula(keg))   (then, if you like: brew untap \(Distribution.tap))\n")
            } else {
                Out.stdout("Dozable is removed from this Mac. (To install again: brew install \(Distribution.tap)/doz — or make install-cli in a source checkout — then doz onboard.)\n")
            }
        }
        if failed { throw ExitCode(DozableExit.failed) }
    }
}
