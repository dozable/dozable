import Darwin
import Foundation

/// A fenced session's Seatbelt profile (SBPL), rendered from its `MacFence` — pure; `MacFenceProfileTests`.
///
/// Deny by default; the LAST matching rule wins, so the sections come in this order: process; reads (the system roots,
/// then the home's allowlist); the terminal; writes (the folder, `--write` folders); the Mach services allowed; IPC and
/// the sysctl allowlist; the network — only its proxy's loopback port and its own `--local-port`s (every other socket,
/// DNS included, stays closed); the protection rules
/// (git's execution paths, renames); and last the fence's own folders: the fence root closed, this session's folder
/// opened again (its `etc/` read-only), then the store, the holders' sockets and doz's settings closed whatever came
/// before. Every path is resolved and checked (`MacFencePaths.pathProblem`: no quote, backslash or control character),
/// so a string literal needs no escaping beyond that check; regexes take paths only through `regexEscape`.
///
/// The Mach-service and sysctl lists were compared against Codex's and Gemini CLI's Seatbelt policies and Chromium's
/// `common.sb` (NOTICE), and checked against this Mac's tools with `Scripts/fence-read-probe.sh` (which carries a hand
/// copy of these rules — keep the two in step).
public enum MacFenceProfile {
    /// A literal path in a profile.
    static func lit(_ p: String) -> String { "\"\(p)\"" }

    /// Escape a path for a regex inside `#"…"`.
    public static func regexEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\^$.|?*+()[]{}".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Programs a fenced session may not run — DEFENCE IN DEPTH only (a copy of a binary escapes a path rule): what
    /// actually stops them is the profile's other rules (no LaunchServices, no launchd/XPC services, no sockets, no
    /// setuid elevation).
    public static let deniedPrograms = ["/usr/bin/sudo", "/usr/bin/su", "/usr/bin/login", "/usr/bin/open", "/usr/bin/osascript",
                                        "/bin/launchctl", "/usr/bin/sandbox-exec"]
    static let deniedContainerTools = ["docker", "podman", "colima", "limactl", "orb", "orbctl", "tart", "container", "utmctl"]
    static let deniedApps = ["/Applications/Docker.app", "/Applications/OrbStack.app", "/Applications/UTM.app"]

    public static let systemReadRoots = ["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/opt", "/private/etc",
                                         "/private/var/db/timezone", "/private/var/select"]
    static let deviceReads = ["/dev/null", "/dev/urandom", "/dev/random", "/dev/zero", "/dev/dtracehelper", "/dev/autofs_nowait"]

    /// The `agent` profile's Mach services: what networking, certificate trust, DNS configuration, the logger, the
    /// preferences daemon and FSEvents need — never SecurityServer (the Keychain), LaunchServices or launchd.
    /// PROVISIONAL (the freeze from a person's live session is still to come — `Scripts/fence-freeze.sh`): checked with the
    /// real Claude Code 2.1.323 on macOS 27.0.1 (26A434), `claude -p` fenced, private config, a fake login swapped and a
    /// fake model (Standard and Locked): it answered with no service added; the only services it was refused are the
    /// Keychain's (by design) and LaunchServices/DiskArbitration/analytics asked by git's xcrun shim (xcodebuild — the
    /// Xcode profile's question).
    public static let agentMachServices = [
        "com.apple.trustd", "com.apple.trustd.agent", "com.apple.ocspd", "com.apple.networkd",
        "com.apple.SystemConfiguration.configd", "com.apple.SystemConfiguration.DNSConfiguration", "com.apple.bsd.dirhelper",
        "com.apple.system.opendirectoryd.membership", "com.apple.system.opendirectoryd.libinfo", "com.apple.system.logger",
        "com.apple.system.notification_center", "com.apple.logd", "com.apple.diagnosticd", "com.apple.cfprefsd.daemon",
        "com.apple.cfprefsd.agent", "com.apple.FSEvents",
    ]
    /// 683 M4 — `--xcode`: Xcode's build services on top of the agent's. PROVISIONAL — EMPTY until the person's freeze run
    /// (`Scripts/fence-freeze.sh --xcode --run 'xcodebuild … build'` against a real app): on macOS 27.0.1 (26A434) with Xcode
    /// 27.2 (27B52), `xcodebuild build` of a scratch macOS tool (no signing, -derivedDataPath "$DOZ_DERIVED") built and ran
    /// with the agent's services alone; what it was refused and did without: CoreDevice, coreservicesd, DiskArbitration,
    /// FileCoordination, PowerManagement, analyticsd, backupd, the quarantine resolver, distributed notifications, mds,
    /// syspolicy.exec, the Keychain's, LaunchServices (lsd) and CoreSimulator. A real app (asset catalogues, storyboards,
    /// packages, signing) may need some: the freeze adds exactly those, reviewed. LaunchServices and CoreSimulator never.
    public static let xcodeMachServices: [String] = []
    public static let xcodeMachPrefixes: [String] = []
    /// 683 M4: the programs whose item-replacement folders (`TemporaryItems/NSIRD_<program>_…`) a fenced program may use.
    public static let replacementPrograms = ["xcodebuild", "XCBBuildService", "SWBBuildService", "swift-build", "swift-package", "ibtool", "actool"]
    /// 683 M4 — `--simulator` (with `--xcode`): LaunchServices, the Simulator and the test manager — things launched OUTSIDE
    /// the fence (a guard rail, not a boundary).
    public static let simulatorMachServices: [String] = [
        "com.apple.coreservices.launchservicesd", "com.apple.lsd.mapdb", "com.apple.lsd.modifydb", "com.apple.coreservices.quarantine-resolver",
        "com.apple.CoreServices.coreservicesd", "com.apple.DiskArbitration.diskarbitrationd", "com.apple.window_proxies",
        "com.apple.windowserver.active", "com.apple.dock.server",
    ]
    public static let simulatorMachPrefixes = ["com.apple.CoreSimulator.", "com.apple.testmanagerd", "com.apple.dt.testmanagerd"]

    /// `--keychain`: the Keychain's services.
    public static let keychainMachServices = ["com.apple.SecurityServer", "com.apple.securityd.xpc", "com.apple.secd", "com.apple.security.agent"]

    /// The sysctls a fenced program may read (Chromium's `common.sb`, Codex's list, and what this Mac's tools asked for).
    /// Never `kern.proc*` / `kern.procargs2` (another process's argv and environment), never a write.
    public static let sysctlNames = [
        "hw.activecpu", "hw.busfrequency_compat", "hw.byteorder", "hw.cacheconfig", "hw.cachelinesize_compat", "hw.cpufamily",
        "hw.cpufrequency_compat", "hw.cputype", "hw.l1dcachesize_compat", "hw.l1icachesize_compat", "hw.l2cachesize_compat",
        "hw.l3cachesize_compat", "hw.logicalcpu_max", "hw.machine", "hw.memsize", "hw.ncpu", "hw.nperflevels", "hw.packages",
        "hw.pagesize_compat", "hw.pagesize", "hw.physicalcpu", "hw.physicalcpu_max", "hw.logicalcpu", "hw.cpufrequency",
        "hw.cpufrequency_max", "hw.tbfrequency_compat", "hw.vectorunit", "hw.model", "hw.cachesize", "machdep.cpu.brand_string",
        "kern.argmax", "kern.hostname", "kern.maxfilesperproc", "kern.maxproc", "kern.osproductversion", "kern.osrelease",
        "kern.ostype", "kern.osvariant_status", "kern.osversion", "kern.secure_kernel", "kern.usrstack64", "kern.version",
        "kern.boottime", "kern.ngroups", "kern.safeboot", "kern.iossupportversion", "kern.bootargs", "kern.willshutdown",
        "kern.hv_vmm_present", "security.mac.lockdown_mode_state", "sysctl.proc_cputype", "vm.loadavg",
    ]
    public static let sysctlPrefixes = ["hw.optional.", "hw.perflevel", "net.routetable."]

    /// The profile text for `f`.
    public static func render(_ f: MacFence) -> String {
        var s: [String] = []
        let home = f.places.home
        // 1.
        s.append("(version 1)")
        s.append("(deny default (with message \"doz-fence:\(f.tag)\"))")
        // 2. Processes: what this session started, and only its own.
        s.append("(allow process-fork)")
        s.append("(allow process-exec)")
        s.append("(deny process-exec " + deniedPrograms.map { "(literal \(lit($0)))" }.joined(separator: " ")
                 + " (regex #\"^/(usr/local|opt/homebrew)/bin/(" + deniedContainerTools.joined(separator: "|") + ")$\")"
                 + deniedApps.map { " (subpath \(lit($0)))" }.joined() + ")")
        s.append("(allow signal (target same-sandbox))")
        s.append("(allow process-info* (target same-sandbox))")
        // 3. Reads: names and sizes everywhere (a stated residual), the system, the home's allowlist.
        s.append("(allow file-read-metadata)")
        s.append("(allow file-read* (literal \"/\"))")
        s.append("(allow file-read* " + (systemReadRoots.map { "(subpath \(lit($0)))" } + deviceReads.map { "(literal \(lit($0)))" }
                                         + ["(literal \(lit(home + "/.CFUserTextEncoding")))"]).joined(separator: " ") + ")")
        s.append("(deny file-read* (subpath \"/opt/homebrew/var\"))")
        s.append("(allow file-write-data (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))")
        s.append("(allow file-ioctl (literal \"/dev/dtracehelper\"))")
        s.append("(allow file-read* file-write-data (subpath \"/dev/fd\"))")
        if !f.homeReads.folders.isEmpty {
            s.append("(allow file-read* " + f.homeReads.folders.map { "(subpath \(lit($0)))" }.joined(separator: " ") + ")")
        }
        if !f.homeReads.files.isEmpty {
            s.append("(allow file-read* " + f.homeReads.files.map { "(literal \(lit($0)))" }.joined(separator: " ") + ")")
        }
        if !f.homeReads.closed.isEmpty {
            s.append("(deny file-read* " + f.homeReads.closed.map { "(subpath \(lit($0)))" }.joined(separator: " ") + ")")
        }
        // 683 M4: doz itself (only the file), so `doz fence-connect` — git's and ssh's way through the proxy — runs inside.
        if let d = f.dozExecutable { s.append("(allow file-read* (literal \(lit(d))))") }
        if !f.readable.isEmpty {
            s.append("(allow file-read* " + f.readable.map { "(subpath \(lit($0)))" }.joined(separator: " ") + ")")
        }
        // 683: a private agent folder's links — their resolved targets (and every nested link that passed the policy),
        // read-only. Never writable: the home is not, and a target in a writable place was not followed.
        if let a = f.agent, a.isPrivate, !(a.readFolders.isEmpty && a.readFiles.isEmpty) {
            s.append("(allow file-read* " + (a.readFolders.map { "(subpath \(lit($0)))" } + a.readFiles.map { "(literal \(lit($0)))" }).joined(separator: " ") + ")")
        }
        // 4. Its terminal: /dev/tty and the holder's pty (the holder puts its path in TTY at start).
        s.append("(allow file-read* file-write* file-ioctl (literal \"/dev/tty\") (literal (param \"TTY\")))")
        // 5. Writes: the folder, --write folders (its own temp, caches and DerivedData are in the session's folder, last).
        s.append("(allow file-read* file-write* " + f.writableRoots.map { "(subpath \(lit($0)))" }.joined(separator: " ") + ")")
        // 683 M4: Apple's build tools (swift build, xcodebuild) save through Foundation's "item replacement" folders, which
        // macOS puts in the user temp folder's TemporaryItems whatever TMPDIR says (`NSIRD_<program>_<random>`, made with
        // mkdtemp by the program itself; found by probe: without them `swift build` and `xcodebuild build` fail) — only
        // those of these programs, never the rest of the user temp folder (TemporaryItems itself is not listable).
        s.append("(allow file-read* file-write* (regex #\"^\(regexEscape(f.places.userTemp))TemporaryItems/NSIRD_(" + replacementPrograms.joined(separator: "|") + ")_[^/]+(/|$)\"))")
        // …and the Swift driver's temporary folders (`TemporaryDirectory.<random>`, mkdtemp): Swift Build starts it without
        // the session's TMPDIR. Its own folders only — the user temp folder itself is neither listable nor writable.
        s.append("(allow file-read* file-write* (regex #\"^\(regexEscape(f.places.userTemp))TemporaryDirectory\\.[A-Za-z0-9]+(/|$)\"))")
        // 683 M4: a worktree's repository's common git folder (its commits, refs and config; its hooks closed below).
        if !f.gitCommon.isEmpty {
            s.append("(allow file-read* file-write* " + f.gitCommon.map { "(subpath \(lit($0)))" }.joined(separator: " ") + ")")
        }
        // 683: a SHARED agent folder — the person's own config home and the file beside it (with the temp and backup names
        // it writes that one through), read and written: less isolated, by the person's choice.
        if let a = f.agent, !a.isPrivate {
            var rules = ["(subpath \(lit(a.personHome)))"]
            if let b = a.personBeside { rules.append("(regex #\"^\(regexEscape(b))(\\.[^/]*)?$\")") }
            s.append("(allow file-read* file-write* " + rules.joined(separator: " ") + ")")
        }
        // 6. Mach services.
        // Under Locked, certificate trust (trustd, OCSP) is closed too: it fetches on the program's behalf.
        let mach = f.trust ? agentMachServices : agentMachServices.filter { !trustMachServices.contains($0) }
        s.append("(allow mach-lookup " + mach.map { "(global-name \(lit($0)))" }.joined(separator: " ") + ")")
        // 683 M4: the Xcode profiles.
        if f.xcode {
            let names = xcodeMachServices + (f.profile == "simulator" ? simulatorMachServices : [])
            let prefixes = xcodeMachPrefixes + (f.profile == "simulator" ? simulatorMachPrefixes : [])
            let rules = names.map { "(global-name \(lit($0)))" } + prefixes.map { "(global-name-prefix \(lit($0)))" }
            if !rules.isEmpty { s.append("(allow mach-lookup " + rules.joined(separator: " ") + ")") }
        }
        s.append("(allow user-preference-read (preference-domain \"kCFPreferencesAnyApplication\") (preference-domain-prefix \"com.apple.\"))")
        // 7. The Keychain, only when asked.
        if f.keychain {
            s.append("(allow mach-lookup " + keychainMachServices.map { "(global-name \(lit($0)))" }.joined(separator: " ") + ")")
        }
        // 8. IPC and the system.
        s.append("(allow ipc-posix-shm* ipc-posix-sem)")
        s.append("(allow sysctl-read " + sysctlNames.map { "(sysctl-name \(lit($0)))" }.joined(separator: " ") + " "
                 + sysctlPrefixes.map { "(sysctl-name-prefix \(lit($0)))" }.joined(separator: " ") + ")")
        s.append("(allow system-info)")
        // 9. Network: ONLY its proxy's port on this Mac's loopback (its holder holds that socket); per --local-port, that
        // port to listen on and connect to. Nothing else: no other bind, no DNS (mDNSResponder's socket), no UDP, no
        // other unix socket — all closed by the default.
        if let p = f.proxyPort { s.append("(allow network-outbound (remote tcp \"localhost:\(p)\"))") }
        for p in f.localPorts {
            s.append("(allow network-bind network-inbound (local tcp \"localhost:\(p)\"))")
            s.append("(allow network-outbound (remote tcp \"localhost:\(p)\"))")
        }
        // 683 M4: the host's two doors in the (closed) socket folder — the filtered SSH agent and gh's way into its proxy.
        // Connecting is all: the folder stays closed to reads and writes (verified: a connect needs no file access).
        for sock in [f.agentSocket, f.ghSocket].compactMap({ $0 }) {
            s.append("(allow network-outbound (literal \(lit(sock))))")
        }
        // 10. Protection: git's execution paths, at any depth, and what a rename could expose.
        for root in f.writableRoots {
            let r = regexEscape(root)
            s.append("(deny file-write-unlink (regex #\"^\(r)/(.*/)?\\.git$\"))")
            s.append("(deny file-write* (regex #\"^\(r)/(.*/)?\\.git/hooks(/|$)\"))")
            // 683 M4: a submodule's hooks (`.git/modules/NAME/hooks`, nested modules too).
            s.append("(deny file-write* (regex #\"^\(r)/(.*/)?\\.git/modules/(.*/)?hooks(/|$)\"))")
            s.append("(deny file-write-unlink (literal \(lit(root))))")
        }
        for c in f.gitCommon {
            s.append("(deny file-write* (subpath \(lit(c + "/hooks"))))")
            s.append("(deny file-write* (regex #\"^\(regexEscape(c))/modules/(.*/)?hooks(/|$)\"))")
            s.append("(deny file-write-unlink (literal \(lit(c))))")
        }
        switch f.workdirGit {
        case nil: s.append("(deny file-write-create (literal \(lit(f.workdir + "/.git"))))")
        case S_IFREG?: s.append("(deny file-write* (literal \(lit(f.workdir + "/.git"))))")
        default: break
        }
        for p in f.protectedPaths {
            s.append("(deny file-write* (subpath \(lit(p))))")
            for a in ancestors(of: p, upTo: f.workdir) { s.append("(deny file-write-unlink (literal \(lit(a))))") }
        }
        // 11. Last: the fence's own folders, then the store, the sockets and doz's settings.
        s.append("(deny file-read* file-write* (subpath \(lit(f.places.fenceRoot))))")
        s.append("(allow file-read* file-write* (subpath \(lit(f.sessionFolder))))")
        s.append("(deny file-write-unlink (literal \(lit(f.sessionFolder))))")
        s.append("(deny file-write* (subpath \(lit(f.etc))))")
        // 683: the private agent folder stays where it is, and what the host put in it (the links, the cleaned settings)
        // cannot be written, replaced, renamed or removed.
        if let a = f.agent, a.isPrivate {
            s.append("(deny file-write-unlink (literal \(lit(a.agentDir))))")
            if !a.hostOwned.isEmpty {
                s.append("(deny file-write* " + a.hostOwned.map { "(literal \(lit(a.agentDir + "/" + $0)))" }.joined(separator: " ") + ")")
            }
        }
        s.append("(deny file-read* file-write* (subpath \(lit(f.places.store))) (subpath \(lit(f.places.socketDirectory)))"
                 + " (regex #\"^\(regexEscape(f.places.userTemp))dh-\") (subpath \(lit(f.places.dozConfig))))")
        // Every refusal carries this session's tag (the system log's line ends with it — the ONLY place it is matched),
        // so a path the program chooses can never put another session's tag last.
        let tag = " (with message \"doz-fence:\(f.tag)\"))"
        return s.map { $0.hasPrefix("(deny ") && !$0.hasPrefix("(deny default") ? String($0.dropLast()) + tag : $0 }.joined(separator: "\n") + "\n"
    }

    /// Certificate trust's services — closed under Locked.
    public static let trustMachServices: Set<String> = ["com.apple.trustd", "com.apple.trustd.agent", "com.apple.ocspd"]

    /// The folders between `path` and `top` (both included when `path` is below `top`), innermost first.
    static func ancestors(of path: String, upTo top: String) -> [String] {
        var out: [String] = []
        var p = (path as NSString).deletingLastPathComponent
        while MacFencePaths.isWithin(p, top) {
            out.append(p)
            if p == top { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return out
    }
}
