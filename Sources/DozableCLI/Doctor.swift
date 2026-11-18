import ArgumentParser
import Darwin
import Foundation
import Security
import DozableKit
import DozableHost
import Virtualization

/// One `doctor` finding.
struct DoctorCheck: Codable, Equatable {
    enum Status: String, Codable { case ok, warn, fail }
    var check: String
    var status: Status
    var detail: String
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check this Mac and the store: macOS, Apple silicon, the entitlement, the kernel, vmnet, disk, the daemon.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let checks = Self.checks(store: g.dozableStore)
        if g.json { Out.json(checks) } else {
            for c in checks {
                let mark = switch c.status { case .ok: "ok  "; case .warn: "warn"; case .fail: "FAIL" }
                Out.stdout("\(mark)  \(c.check.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.detail)\n")
            }
        }
        if checks.contains(where: { $0.status == .fail }) { throw ExitCode(DozableExit.failed) }
        // 594: a store never onboarded says how to start.
        if !g.json, OnboardingRecord.read(g.dozableStore) == nil {
            Out.stdout("\nthis store has not been onboarded — doz onboard sets up this Mac (checks, account, settings, images)\n")
        }
    }

    /// `claude: false` (594: `doz onboard --key …`) leaves out the Claude Code checks — the ones
    /// that run `claude --version` and read the Mac login's keychain item.
    /// 714: what the daemon row adds when the running daemon is another build than this doz (nil: the same). Advice for
    /// the OLDER side: an older daemon is stopped (the next command starts this build); a NEWER daemon means this doz is
    /// the old one — a copy still running from before an upgrade (the dashboard's, in the background) when the daemon's
    /// release is installed, else one to upgrade. (It said "doz daemon stop" for both: wrong when the daemon was newer.)
    static func daemonVersionAdvice(daemon: String, this: String, installed: String?, upgrade: String?) -> String? {
        guard daemon != this else { return nil }
        switch SemVer.compare(daemon, this) {
        case .orderedAscending?: return " — this CLI is \(this): doz daemon stop"
        case .orderedSame?: return nil
        case .orderedDescending?:
            if let installed, SemVer.compare(installed, this) == .orderedDescending {
                return " — this doz is \(this), older than the daemon: doz \(installed) is installed, and this is an older copy still running (the dashboard: Restart dashboard, or doz ui restart)"
            }
            return " — this doz is \(this), older than the daemon: upgrade it\(upgrade.map { " (\($0))" } ?? "")"
        case nil: return " — this CLI is \(this), a different build"
        }
    }

    static func checks(store: DozableStore, claude: Bool = true) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        var hostKeychain: (reason: String, pid: Int32, startedAt: Date)?
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let release = withUnsafeBytes(of: &uts.release) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        out.append(DoctorCheck(check: "macOS", status: v.majorVersion >= 26 ? .ok : .fail,
                               detail: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (Darwin \(release))" + (v.majorVersion >= 26 ? "" : " — macOS 26 or later is needed")))
        out.append(DoctorCheck(check: "chip", status: machine == "arm64" ? .ok : .fail,
                               detail: "\(machine) · \(sysctl("machdep.cpu.brand_string")) · \(sysctl("hw.model"))" + (machine == "arm64" ? "" : " — Apple silicon is needed")))
        out.append(DoctorCheck(check: "virtualization", status: VZVirtualMachine.isSupported ? .ok : .fail,
                               detail: VZVirtualMachine.isSupported ? "supported (up to \(VZVirtualMachineConfiguration.maximumAllowedCPUCount) CPUs per VM)" : "Virtualization.framework reports no support"))
        // 678: a doz clamped to background priority (taskpolicy -b, a background agent worker) runs everything slowly.
        let mine = ProcessPriority.current()
        out.append(DoctorCheck(check: "priority", status: mine.clamped ? .warn : .ok,
                               detail: mine.warning("doz", pid: getpid()) ?? "normal (QoS \(mine.qos)\(mine.pri.map { ", pri \($0)" } ?? ""))"))
        let ent = hasVirtualizationEntitlement()
        out.append(DoctorCheck(check: "entitlement", status: ent ? .ok : .fail,
                               detail: ent ? "com.apple.security.virtualization — \(HostLauncher.executablePath)"
                                           : "this binary lacks com.apple.security.virtualization: build it with `make cli` (it signs), or codesign --entitlements Scripts/doz.entitlements"))
        let deckhold = DeckholdBinary.locate(), net = DoznetBinary.locate()
        out.append(DoctorCheck(check: "guest tools", status: deckhold != nil && net != nil ? .ok : .fail,
                               detail: deckhold != nil && net != nil ? "deckhold + doznet found (\(deckhold!.deletingLastPathComponent().path))"
                                                                    : "\(DeckholdBinary.bundleName) is not beside the executable (make install-cli copies it)"))
        // The store.
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: store.root.path, isDirectory: &isDir), isDir.boolValue {
            let writable = fm.isWritableFile(atPath: store.root.path)
            let vals = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey])
            let free = vals?.volumeAvailableCapacityForImportantUsage ?? 0
            let format = vals?.volumeLocalizedFormatDescription ?? "?"
            let apfs = format.contains("APFS")
            out.append(DoctorCheck(check: "store", status: writable && free > 10 << 30 && apfs ? .ok : (writable ? .warn : .fail),
                                   detail: "\(store.root.path) — \(format), \(DozableImages.formatBytes(free)) free, \(store.sandboxNames().count) sandbox(es)"
                                   + (apfs ? "" : " — not APFS: disks are copied instead of cloned") + (free > 10 << 30 ? "" : " — under 10 GiB free")))
        } else {
            out.append(DoctorCheck(check: "store", status: .ok, detail: "\(store.root.path) — not created yet (the first create makes it)"))
        }
        if !store.socketPathFits {
            out.append(DoctorCheck(check: "socket", status: .fail, detail: "\(store.socket.path) is over 103 bytes — use a shorter --store"))
        }
        let kernelDir = DozableSettings.load().string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? store.layout("_").kernels
        let provider = KernelProvider(cacheDirectory: kernelDir)
        let kernel = provider.cachedKernel
        if fm.fileExists(atPath: kernel.path) {
            out.append(DoctorCheck(check: "kernel", status: .ok, detail: "\(KernelArtifact.recommended.fileName) cached (\(kernelDir.path))"))
        } else if let seed = provider.localSeed(), KernelProvider.isBundled(seed) {
            // 675: a release carries the pinned kernel (libexec/doz/kernels): the first start copies it in.
            out.append(DoctorCheck(check: "kernel", status: .ok,
                                   detail: "carried by this doz (\(seed.path)) — the first start copies it into the store; no download needed"))
        } else if provider.localSeed() != nil {
            // 594 W5: Apple's container kernels hold a byte-identical copy: it is copied, not downloaded.
            out.append(DoctorCheck(check: "kernel", status: .ok,
                                   detail: "found locally (Apple's container kernels, byte-identical to the pin) — no download needed"))
        } else {
            out.append(DoctorCheck(check: "kernel", status: .warn, detail: "not cached yet — the first start downloads it (~570 MiB, once)"))
        }
        // 599h: the tools layer's downloads on this Mac (gh, for sandboxes with GitHub as you).
        let toolsCache = ToolsCache(root: store.root.appendingPathComponent("tools"))
        if let e = toolsCache.entries().first {
            out.append(DoctorCheck(check: "tools layer", status: .ok,
                                   detail: "\(e.id) \(e.version) cached (\(e.bytes / 1_048_576) MiB, sha256 checked) — copied into sandboxes with GitHub as you"))
        } else {
            out.append(DoctorCheck(check: "tools layer", status: .ok,
                                   detail: "gh \(ToolsLayer.ghVersion) not downloaded yet — the first sandbox with GitHub as you fetches it (~14 MB, once)"))
        }
        // 657: the person's dotfiles — the setting, what this Mac's cache holds, a sandbox whose last apply failed.
        do {
            let source = DozableSettings.load().string(SettingKey.dotfiles) ?? ""
            let cached = DotfilesCache(root: store.root.appendingPathComponent("dotfiles")).cached().count
            let failed = store.sandboxNames().compactMap { name -> String? in
                let f = store.layout(name).sandboxDirectory.appendingPathComponent("dotfiles-run.json")
                guard let d = try? Data(contentsOf: f), let r = try? Sandbox.runDecoder.decode(DotfilesRun.self, from: d), !r.ok else { return nil }
                return "\(name): \(r.summary)"
            }
            var isDir: ObjCBool = false
            let normalized = try? DotfilesSource.normalized(source, home: TestSafety.realHome.path)
            if let n = normalized ?? nil, DotfilesSource.isLocal(n), !(fm.fileExists(atPath: n, isDirectory: &isDir) && isDir.boolValue) {
                out.append(DoctorCheck(check: "dotfiles", status: .warn, detail: "sandbox.dotfiles is \(DisplayPath.tilde(n)), which is not a folder on this Mac — a new sandbox cannot be made with it (--dotfiles none, or doz config set sandbox.dotfiles …)"))
            } else if !failed.isEmpty {
                out.append(DoctorCheck(check: "dotfiles", status: .warn, detail: "the last apply failed in " + failed.joined(separator: "; ") + " — doz dotfiles NAME says more; --update applies them again"))
            } else {
                out.append(DoctorCheck(check: "dotfiles", status: .ok, detail: (normalized ?? nil).map {
                    "\(DotfilesSource.isLocal($0) ? DisplayPath.tilde($0) : $0) for every new sandbox (\(cached) repositor\(cached == 1 ? "y" : "ies") fetched on this Mac)"
                } ?? "none set — doz config set sandbox.dotfiles URL|PATH puts yours in every new sandbox"))
            }
        }
        // 660: each sandbox that uses a model server on this Mac — does something answer on its one port?
        do {
            let rows = store.sandboxNames().compactMap { name -> (String, Int)? in
                SandboxConfig.read(store.configFile(name))?.localModelPort.map { (name, $0) }
            }
            if !rows.isEmpty {
                let silent = rows.filter { !MacModelServer.answers(port: $0.1) }
                let list = rows.map { "\($0.0) → 127.0.0.1:\($0.1)" }.joined(separator: ", ")
                out.append(DoctorCheck(check: "models on this Mac", status: silent.isEmpty ? .ok : .warn,
                                       detail: silent.isEmpty ? "\(list) (each sandbox reaches only its own port)"
                                           : "nothing answers on " + silent.map { "port \($0.1) (\($0.0))" }.joined(separator: ", ")
                                             + " — start the model server on this Mac (ollama serve, LM Studio's server) before Claude Code asks it"))
            }
        }
        // 604 → 667: sound — the setting, the sound kernel this doz carries, and the microphone: macOS's answer for the
        // app it asks about (a preflight: it never shows a question; the seam in a test run).
        do {
            let carried = MacAudio.bundledSoundKernel()
            let ok = carried.map(SoundKernel.isVerified) ?? false
            let settings = DozableSettings.load()
            let mode = settings.resolve(SettingKey.audio).value.plain
            let ask = MicrophoneAsk.of(settings.resolve(SettingKey.microphoneAsk).value)     // 667
            let access = MicrophoneAccess.current()
            let permission = access.status()
            let who = MacAudio.responsibleApp()?.description ?? "an app macOS did not name"
            let kernel = ok ? "the sound kernel is here (\(SoundKernel.fileName), sha256 checked)"
                : carried == nil ? "this doz carries no sound kernel — a sandbox cannot have sound"
                : "the sound kernel beside this doz is damaged (sha256 differs) — reinstall doz"
            let status: DoctorCheck.Status = carried != nil && !ok ? .warn : (ok && permission == .denied && mode == SoundMode.on.rawValue ? .warn : .ok)
            out.append(DoctorCheck(check: "sound", status: status,
                                   detail: "sandbox.audio = \(mode) for new sandboxes; \(kernel); the microphone for \(who): \(permission.sentence(ask: ask))"
                                       + (access.seamed ? " (test seam)" : "")))
        }
        // The recipes this doz uses: its own, or a verified recipe catalogue — and one waiting, or the last refused.
        let recipeLine = RecipeCatalogueSelection.describe(version: DozableCommand.version)
        out.append(DoctorCheck(check: "recipes", status: recipeLine.contains("last problem:") ? .warn : .ok,
                               detail: String(recipeLine.dropFirst("recipes: ".count))))
        // 653: yours and the community catalogues' (a line of its own — the one above stays Dozable's).
        if let x = RecipeExtras.describe() {
            let waits = RecipeExtrasPaths.at().map(RecipeExtras.pending) == true ? " · a change waits for the next daemon start (doz daemon restart)" : ""
            out.append(DoctorCheck(check: "recipes, not Dozable's", status: x.contains(" refused: ") ? .warn : .ok, detail: x + waits))
        }
        // 594 W28: an agent image an older doz made, or a newer agent release — said, never rebuilt by itself.
        let settings = DozableSettings.load()
        // 0.51: a doz.toml line under a name renamed for the folder is not read.
        if !settings.renamedLines.isEmpty {
            out.append(DoctorCheck(check: "settings", status: .warn, detail: settings.renamedLines.joined(separator: "; ")))
        }
        for image in ["claude-code", "pi", "codex"] {
            let s = AgentVersions.standing(image, store: store, settings: settings)
            guard s.version != nil else { continue }
            var parts: [String] = []
            if let o = s.olderRecipeLine { parts.append(o) }
            if let a = s.available, let v = s.version { parts.append("\(AgentImages.agentName(image) ?? image) \(a) is available (image has \(v))") }
            out.append(parts.isEmpty
                ? DoctorCheck(check: "image \(image)", status: .ok, detail: "up to date (\(s.version!))")
                : DoctorCheck(check: "image \(image)", status: .warn, detail: parts.joined(separator: "; ") + " — rebuild when ready: doz image bake \(image) (existing sandboxes keep their disks)"))
        }
        out.append(DoctorCheck(check: "vmnet", status: .ok,
                               detail: "needed only for --network nat (a free 192.168.100–199.0/24 subnet is picked); proxied sandboxes have no interface"))
        // The host.
        var daemonStatus: HostStatus?                // 695: the running daemon's word (its keep-alive)
        if store.hostIsRunning() {
            var detail = "running, pid \(store.hostPID().map(String.init) ?? "?")"
            var status = DoctorCheck.Status.ok
            var hostPriority: DoctorCheck?
            if let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false),
               let st = try? m.result?.decode(HostStatus.self) {
                daemonStatus = st
                // 693: always on, or its idle timeout (an older daemon: its timeout).
                detail += ", \(st.version), \(st.liveSandboxes.count) running, "
                    + (st.alwaysOn == true ? "always on" : st.idleTimeoutMinutes > 0 ? "idle timeout \(st.idleTimeoutMinutes.formatted()) min" : "never exits by itself")
                if let advice = Doctor.daemonVersionAdvice(daemon: st.version, this: DozableCommand.version,
                                                           installed: StableExecutable.installedVersion(),
                                                           upgrade: InstallMethod.detect(executable: HostLauncher.executablePath).upgradeCommand) {
                    status = .warn; detail += advice
                }
                // 700: always-on off with the timeout 0 — it never switches off by idling.
                if let alwaysOn = st.alwaysOn, let w = DozableSettings.daemonIdleWarning(alwaysOn: alwaysOn, idleTimeoutMinutes: st.idleTimeoutMinutes) {
                    status = .warn; detail += " — " + w
                }
                // 593: a host never lives in a client's process tree (stopping that tree killed one mid-save).
                if let pp = st.parentPid {
                    if pp == 1 {
                        detail += ", parent launchd (detached)"
                    } else if st.launchedDetached == false {
                        detail += ", parent \(pp) — run in the foreground on purpose (doz daemon start --foreground)"
                    } else {
                        if status == .ok { status = .warn }
                        detail += ", parent \(pp), NOT launchd — it lives in another process's tree, and stopping that tree stops it: doz daemon stop, then let a command start it again"
                    }
                }
                if let app = st.microphoneApp { detail += ", microphone asked as \(app) (sandboxes with sound)" }
                if let why = st.keychainLocked { hostKeychain = (why, st.pid, st.startedAt) }       // 679 B6
                // 678: the host's own scheduling — a clamped host makes every wake crawl.
                if let p = st.priority {
                    hostPriority = DoctorCheck(check: "daemon priority", status: p.clamped ? .warn : .ok,
                                               detail: p.warning("the daemon", pid: st.pid)
                                                   ?? "normal (QoS \(p.qos)\(p.pri.map { ", pri \($0)" } ?? ""))"
                                                   + (st.priorityRestored == true ? " — moved out of the background priority it inherited from the command that started it" : ""))
                }
                // 591: its program changed under it — overwritten in place is a failure (its VMs are refused).
                if let note = st.executableNote {
                    status = st.executableChange == "overwritten" ? .fail : (status == .ok ? .warn : status)
                    detail += " — " + note
                }
            } else {
                status = .warn
                detail += " but it does not answer its socket"
            }
            out.append(DoctorCheck(check: "daemon", status: status, detail: detail))
            if let hostPriority { out.append(hostPriority) }
            // 608: a sandbox whose live view of its folder could not start is shared directly — say so.
            var ls = HostRequest(.ls); ls.withSessions = false
            if let m = try? HostClient.request(ls, store: store, autostart: false), let rows = try? m.result?.decode([SandboxInfo].self) {
                let fb = rows.filter { $0.folderView == "fallback" }.map(\.name)
                if !fb.isEmpty {
                    out.append(DoctorCheck(check: "folder view", status: .warn,
                                           detail: "\(fb.joined(separator: ", ")): the live view of /workspace could not start, so the folder is shared directly — a program working there loses its folder at a wake from hibernation. The sandbox's boot log says why; a restart (doz shutdown + start) tries again"))
                }
            }
        } else {
            let recover = store.needsRecovery()
            out.append(DoctorCheck(check: "daemon", status: recover.isEmpty ? .ok : .warn,
                                   detail: recover.isEmpty ? "not running (nothing is — the next command that needs it starts it)"
                                                           : "not running, and \(recover.joined(separator: ", ")) had a VM when the last daemon went away — the next command recovers it"))
        }
        // 694: the login item — present, loaded, switched off, out of date, or missing (read only; starts nothing).
        out.append(Self.loginItemCheck(DaemonLoginItem.status(store: store), daemonLocked: hostKeychain?.reason,
                                       held: LoginStart.heldAt(store) != nil && !store.hostIsRunning()))
        // The chat server the daemon runs (read only: the setting, the supervisor's record, the server's own status).
        out.append(chatDoctorCheck(store))
        out += chatRemoteDoctorChecks(store)
        // 695: the Claude login keep-alive — the mode, the last try and the next (the store's record; the daemon's word when
        // one runs: a locked daemon never runs it). Read only, no token.
        do {
            let settings = DozableSettings.load()
            let accounts = AccountStore(store: store, settings: settings).load()
            let k = daemonStatus?.keepalive ?? KeepaliveStatus.fromStore(store, settings: settings)
            var inUse = !(daemonStatus?.fencedSessions ?? []).isEmpty
            if !inUse, KeepaliveMode.of(accounts) == .on, daemonStatus != nil, let m = try? HostClient.request(HostRequest(.accountList), store: store, autostart: false),
               let rows = try? m.result?.decode([AccountRow].self) {
                inUse = rows.contains { $0.kind == AccountKind.mac.rawValue && !$0.usedBy.isEmpty }
            }
            out.append(Self.keepaliveCheck(k, mode: KeepaliveMode.of(accounts), daemonRunning: daemonStatus != nil, inUse: inUse))
        }
        let metricsOK = fm.fileExists(atPath: store.metrics.path)
        out.append(DoctorCheck(check: "metrics", status: .ok, detail: metricsOK ? store.metrics.path : "none yet"))
        // 611: under a test seam the Mac's own Claude login (keychain, ~/.claude, its binary) is never looked at.
        if claude, ProcessInfo.processInfo.environment["DOZ_TEST_NO_MAC_LOGIN"] == "1" {
            out.append(DoctorCheck(check: "claude login", status: .ok, detail: "not looked at (DOZ_TEST_NO_MAC_LOGIN=1)"))
        } else if claude { out += claudeChecks(store: store, keychain: macLoginKeychain()) }
        // 679 B6: doctor reads the login in ITS session; the host reads it in its own — say when they differ.
        if let h = hostKeychain {
            let mine = out.first { $0.check == "claude login" }
            let doctorReads: Bool? = mine.map { $0.status == .ok && !$0.detail.hasPrefix("not looked at") ? true : nil } ?? nil
            out.append(Self.hostLoginCheck(doctorReads: doctorReads, reason: h.reason, pid: h.pid, startedAt: h.startedAt))
        }
        out.append(codexLoginCheck(home: CodexMacLogin.resolveHome(), settings: .load()))
        #if !DOZ_NO_WEB
        out += ServeDoctor.checks(store: store, settings: .load())
        out += PublishDoctor.checks(store: store)
        #endif
        return out
    }

    /// 599i rc.3: this Mac's Codex login (`mac` for Codex) — read-only: its state and expiry, never a token.
    static func codexLoginCheck(home: URL?, settings: DozableSettings, now: Date = Date()) -> DoctorCheck {
        let r = CodexMacLogin.read(home, now: now)
        let keep = settings.bool(SettingKey.codexKeepAlive)
        switch r.state {
        case .ok:
            let exp = r.token?.expiresAt.map { " — access token until \(CredentialVaultClock.hm($0))" } ?? ""
            return DoctorCheck(check: "codex login", status: .ok, detail: "this Mac's Codex is signed in (ChatGPT)\(exp) · Codex sandboxes can use it as mac · renews while Codex runs on this Mac"
                               + (keep ? " · keep-alive on" : ""))
        case .expired:
            return DoctorCheck(check: "codex login", status: .warn, detail: "this Mac's Codex login has expired — run codex on the Mac (it renews it), or turn on Codex's keep_alive (doz config set --agent codex keep_alive true)")
        case .signedOut:
            return DoctorCheck(check: "codex login", status: .ok, detail: "this Mac's Codex is not signed in — Codex sandboxes need another account (doz account add NAME --chatgpt)")
        case .keyring, .apiKey, .unreadable:
            return DoctorCheck(check: "codex login", status: .warn, detail: CodexMacSession(codexHome: home, keepaliveEnabled: { false }).problem(now: now) ?? r.state.label)
        }
    }

    /// 588: the Mac's Claude Code, its login(s), and the store's accounts. Reads only: `claude
    /// --version`, the keychain item (parsed in memory, never printed), attributes of the others.
    static func claudeChecks(store: DozableStore, keychain: KeychainAccess, now: Date = Date(),
                             binary: (() -> String?)? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             listItems: Bool = true) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let st = ClaudeLoginStatus.check(configDir: nil, keychain: keychain, probeBinary: true, home: home, binary: binary)
        if let b = st.binary {
            out.append(DoctorCheck(check: "claude", status: .ok, detail: "Claude Code \(st.version ?? "?") (\(b))"))
        } else {
            out.append(DoctorCheck(check: "claude", status: .warn, detail: "Claude Code isn't installed on this Mac — needed only for the mac account (the Mac's own login)"))
        }
        let accounts = AccountStore(store: store, settings: .load()).load()
        let macInUse = accounts.defaultAccount == "mac"
        switch st.state {
        case .signedIn:
            let expired = st.expiresAt.map { $0 <= now } ?? false
            let soon = st.expiresAt.map { !expired && $0.timeIntervalSince(now) < 15 * 60 } ?? false
            var detail = st.summary(now: now)
            if expired {
                detail += " — it renews only while Claude Code runs on this Mac: open it (any prompt); sandboxes using it get \"login expired\" until then"
            } else {
                detail += " · renews while Claude Code runs on this Mac"
                if soon, !ClaudeLogin.isClaudeRunning() { detail += " — and none is running now" }
            }
            out.append(DoctorCheck(check: "claude login", status: expired || soon ? .warn : .ok, detail: detail))
        default:
            let p = st.problem(now: now)?.message ?? st.state.rawValue
            out.append(DoctorCheck(check: "claude login", status: macInUse ? .warn : .ok, detail: p + (macInUse ? "" : " (not used: the default account is \(accounts.defaultAccount))")))
        }
        if listItems {
            let items = keychain.items(servicePrefix: ClaudeLogin.baseService)
            if items.count > 1 {
                var known: [String: String] = [ClaudeLogin.baseService: "~/.claude"]
                for a in accounts.accounts where a.kind == .mac { known[ClaudeLogin.service(configDir: a.configDir)] = a.configDir ?? "~/.claude" }
                let list = items.map { i -> String in
                    let name = i.service == ClaudeLogin.baseService ? "default" : String(i.service.dropFirst(ClaudeLogin.baseService.count + 1))
                    let modified = i.modified.map { " written \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                    return "\(name) (\(known[i.service] ?? "unknown dir")\(modified.isEmpty ? "" : ",")\(modified))"
                }
                out.append(DoctorCheck(check: "claude logins", status: .ok, detail: "\(items.count) in the keychain: " + list.joined(separator: " · ")))
            }
        }
        let rows = accounts.accounts.map { a -> String in
            var s = a.name + (accounts.defaultAccount == a.name || accounts.openaiDefault == a.name
                              || accounts.providerDefaults?.values.contains(a.name) == true ? " (default)" : "")
            switch a.kind {
            case .mac: s += a.configDir.map { " (Mac login, \($0))" } ?? ""
            case .setupToken: s += " (setup-token" + (a.expiresAt.map { ", expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") + ")"
            case .apiKey: s += " (api-key)"
            case .openaiKey: s += " (openai-key)"
            case .chatgpt: s += " (chatgpt" + (a.plan.map { ", \($0)" } ?? "") + ")"
            case .codexMac: s += " (codex-mac)"
            case .key: s += a.custom != nil ? " (custom key)" : " (key, \(a.provider ?? "?"))"          // 617
            }
            if a.readsOnUse, let src = a.source { s += " ← \(src.label)" }
            return s
        }
        // 617 (§7): a key read on use whose tool is missing.
        var said = Set<String>()
        for a in accounts.accounts where a.readsOnUse {
            if let src = a.source, let why = SecretSources.missingTool(src) {
                out.append(DoctorCheck(check: "key source", status: .warn, detail: "account \(a.name): \(why)"))
                said.insert(a.name)
            }
        }
        // 617: and the running host's last read that FAILED — the same words the proxy answered with.
        if accounts.accounts.contains(where: \.readsOnUse), store.hostIsRunning(),
           let m = try? HostClient.request(HostRequest(.accountList), store: store, autostart: false),
           let rows = try? m.result?.decode([AccountRow].self) {
            for r in rows where r.sourceState == "failed" && !said.contains(r.name) {
                out.append(DoctorCheck(check: "key source", status: .warn, detail: r.sourceProblem ?? "account \(r.name): its last read failed"))
            }
        }
        let expiring = accounts.accounts.filter { a in a.kind != .mac && (a.expiresAt.map { $0.timeIntervalSince(now) < 30 * 86_400 } ?? false) }
        out.append(DoctorCheck(check: "accounts", status: expiring.isEmpty ? .ok : .warn,
                               detail: rows.joined(separator: " · ") + (accounts.defaultAccount == "none" ? " · default: none" : "")
                               + (accounts.keepalive ? " · keep-alive \(KeepaliveMode.of(accounts).rawValue)" : "")
                               + (expiring.isEmpty ? "" : " — \(expiring.map(\.name).joined(separator: ", ")) expire\(expiring.count == 1 ? "s" : "") within 30 days: claude setup-token, then doz account add NAME --setup-token --force")))
        return out
    }

    /// 694: the "login item" row. `daemonLocked`: why the running daemon cannot read the login keychain (nil: it can, or
    /// none runs). `held`: `doz daemon stop` holds it (none runs).
    static func loginItemCheck(_ li: LoginItemStatus, daemonLocked: String?, held: Bool) -> DoctorCheck {
        func row(_ s: DoctorCheck.Status, _ d: String) -> DoctorCheck {
            DoctorCheck(check: "login item", status: s, detail: d + (held ? " · held by doz daemon stop (until a doz command" + (li.installed ? " or your next login)" : ")") : ""))
        }
        if li.owner == "app" { return row(.ok, "the Dozable menu bar app starts the daemon at login") }
        if li.path.isEmpty, let n = li.note { return row(.ok, n) }
        if !li.installed {
            switch li.setting {
            case "on": return li.wanted ? row(.warn, "missing — daemon.login_item is on but there is none: doz daemon login-item on adds it")
                                        : row(.ok, "none — \(li.note ?? "the rule does not hold")")
            case "off": return row(.ok, "off — the daemon starts with the first doz command (doz daemon login-item on starts it when you log in)")
            default: return row(.ok, "not set up — doz daemon login-item on starts the daemon when you log in")
            }
        }
        let path = DisplayPath.tilde(li.path)
        if li.disabled == true {
            return row(.warn, "\(path) is switched off in System Settings › General › Login Items — switch it on there, or doz daemon login-item off")
        }
        if li.stale {
            return row(.warn, "\(path) runs \(li.program.map { DisplayPath.tilde($0) } ?? "nothing"), not this doz — doz daemon login-item on rewrites it")
        }
        if !li.wanted { return row(.warn, "\(path) is there but \(li.note ?? "not wanted") — the next daemon start removes it (or doz daemon login-item off)") }
        if !li.loaded { return row(.warn, "\(path) is not loaded — it loads at your next login") }
        if let why = daemonLocked {
            return row(.warn, "\(path) loaded, but the running daemon was started where the login keychain is locked (\(why)) — doz daemon restart starts one through the login item")
        }
        return row(.ok, "\(path) loaded — the daemon starts when you log in")
    }

    /// 695: the "Claude login keep-alive" row — ok, or a warning on a failed renewal, a daemon that can never run it (its
    /// login keychain locked), or `on` with nothing using the login (it then never runs: always does).
    static func keepaliveCheck(_ k: KeepaliveStatus, mode: KeepaliveMode, daemonRunning: Bool, inUse: Bool, now: Date = Date()) -> DoctorCheck {
        let line = k.line(now: now)
        func row(_ s: DoctorCheck.Status, _ d: String) -> DoctorCheck { DoctorCheck(check: "Claude login keep-alive", status: s, detail: d) }
        switch mode {
        case .off: return row(.ok, line)
        case .on, .always:
            if k.failed { return row(.warn, line + " — Claude Code on this Mac could not renew its login: run claude on the Mac (any prompt) to see why") }
            if k.keychainLocked != nil { return row(.warn, line) }
            if mode == .on, !inUse {
                return row(.warn, line + " — on renews only while a sandbox or fenced session uses this Mac's login, and none does now"
                           + (daemonRunning ? "" : " (no daemon runs)") + ": doz account keepalive always renews it with nothing using it")
            }
            if mode == .always, !daemonRunning { return row(.ok, line + " — the daemon runs it (none is running now; doz daemon login-item on starts it at login)") }
            return row(.ok, line)
        }
    }

    /// 679 B6: the running host cannot read the login keychain. A failure when doctor itself can (its own session reads
    /// it — the mismatch that hid an ssh-started host), else a warning.
    static func hostLoginCheck(doctorReads: Bool?, reason: String, pid: Int32, startedAt: Date) -> DoctorCheck {
        let advice = HostSessionKind.hostAdvice(pid: pid, startedAt: startedAt, reason: reason)
        if doctorReads == true {
            return DoctorCheck(check: "daemon login", status: .fail, detail: "doctor can read your Claude login, the daemon cannot — " + advice)
        }
        return DoctorCheck(check: "daemon login", status: .warn, detail: advice)
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Whether this process's own signature carries com.apple.security.virtualization.
    static func hasVirtualizationEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let v = SecTaskCopyValueForEntitlement(task, "com.apple.security.virtualization" as CFString, nil)
        return (v as? Bool) == true
    }
}
