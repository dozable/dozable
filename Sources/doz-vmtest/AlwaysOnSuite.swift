// `doz-vmtest cli-alwayson --doz PATH` (693, `make test-cli-alwayson`; also part of `make test-cli`): the always-on daemon,
// no VM, a scratch store of its own (/tmp/dzo-PID-ao) and its own settings file.
//
//   1. With DEFAULT settings (no DOZ_DAEMON_ALWAYS_ON — the Makefile's guarded "off" is removed for this suite's daemons
//      only) a daemon started with a 3 s idle timeout says it is always on, and is still up, the same pid, after 5× that
//      timeout with nothing running.
//   2. `doz config set daemon.always_on off` applies at once: the running daemon exits by itself (the idle exit as before).
//   3. A daemon whose program is replaced by rename (an install) while nothing runs RESTARTS IN PLACE, with no command
//      typed: one daemon, a new pid, parent launchd, running the new file (its identity unchanged since it started), the
//      old one's log saying so.
//   4. The dashboard follows an upgrade (`dashboardFollowsUpgradeChecks`): started by a Homebrew-shaped opt path, a new keg
//      linked in → it restarts itself with no page open; `doz ui restart` runs the keg installed now.
//
// Every daemon it starts is stopped at the end; the store and the copies are removed.
import Darwin
import Foundation
import DozableKit
import DozableHost

func cliAlwaysOnSuite(binary: String) async {
    print("cli: the always-on daemon")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-ao")          // short: the daemon's socket path
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let h = CLIHarness(binary: binary, store: root)
    h.env.removeValue(forKey: "DOZ_DAEMON_ALWAYS_ON")                  // the default: on
    h.env["DOZ_DAEMON_IDLE"] = "0.05"                                    // 3 s — it would exit at once were it not always on
    let store = DozableStore(root: root)
    func pidFile() -> Int32? {
        (try? String(contentsOf: store.pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    /// The daemons of THIS store: every process whose command line is a daemon's for it (the launcher's `--launched`).
    func daemonsOfStore() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let o = Pipe()
        p.standardOutput = o
        try? p.run()
        let data = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.contains("daemon start --foreground"), l.contains("--store \(root.path)") else { return nil }
            return Int32(l.split(separator: " ").first ?? "")
        }
    }
    let copies = root.appendingPathComponent("installed")
    defer {
        h.run(["daemon", "stop"], timeout: 120)
        _ = h.waitFor(30) { !h.hostRunning }
        check(!h.hostRunning && daemonsOfStore().isEmpty, "always-on: no daemon of this suite left running")
        try? fm.removeItem(at: root)
    }

    // 1. the default: always on.
    var r = h.run(["daemon", "start"], timeout: 60)
    check(r.code == 0 && h.hostRunning, "always-on: daemon start with default settings (idle timeout 3 s)")
    let st = h.json(["daemon", "status"], HostStatus.self)
    check(st?.alwaysOn == true && st?.idleTimeoutMinutes == 0 && st?.keepers == 0,
          "always-on: daemon status --json says alwaysOn true, idleTimeoutMinutes 0, keepers 0 (\(st?.alwaysOn.map(String.init) ?? "nil"), \(st?.idleTimeoutMinutes ?? -1), \(st?.keepers.map(String.init) ?? "nil"))")
    r = h.run(["daemon", "status"])
    check(r.out.contains("always on: it keeps running with nothing open"), "always-on: daemon status says it in words (\(r.out.split(separator: "\n").last ?? ""))")
    let pid0 = st?.pid
    usleep(15_000_000)                                                   // 5× its idle timeout (3 looks)
    check(h.hostRunning && pidFile() == pid0 && pid0.map { kill($0, 0) == 0 } == true,
          "always-on: still up after 15 s with nothing running — 5× its idle timeout (pid \(pid0.map(String.init) ?? "?"))")

    // 2. off → the idle exit, at once (the running daemon re-reads the setting).
    r = h.run(["config", "set", "daemon.always_on", "off"])
    check(r.code == 0 && r.out.contains("applies at once"), "always-on: config set daemon.always_on off (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))")
    let t0 = Date()
    let exited = h.waitFor(30) { !h.hostRunning }
    check(exited, String(format: "always-on off: the running daemon exited by itself after %.1f s (idle timeout 3 s)", Date().timeIntervalSince(t0)))
    r = h.run(["config", "set", "daemon.always_on", "on"])
    check(r.code == 0, "always-on: config set daemon.always_on on")

    // 3. replaced by rename while nothing runs → restarted in place, no command typed.
    let src = URL(fileURLWithPath: binary).deletingLastPathComponent()
    let entitlements = URL(fileURLWithPath: "Scripts/doz.entitlements").standardizedFileURL.path
    func sh(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    try? fm.createDirectory(at: copies, withIntermediateDirectories: true)
    for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where item.hasSuffix(".bundle") || item == "VERSION" || item == "deckhold-mac" {
        try? fm.copyItem(at: src.appendingPathComponent(item), to: copies.appendingPathComponent(item))
    }
    let t = copies.appendingPathComponent("doz").path
    /// A signed copy of this build renamed over `t` (a new file, as an install makes).
    func install() -> Bool {
        sh(["/bin/cp", binary, t + ".new"]) == 0
            && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t + ".new"]) == 0
            && rename(t + ".new", t) == 0
    }
    check(install(), "always-on: an installed copy of this build")
    let inst = CLIHarness(binary: t, store: root)
    inst.env = h.env
    r = inst.run(["daemon", "start"], timeout: 60)
    let before = inst.json(["daemon", "status"], HostStatus.self)
    check(r.code == 0 && before?.alwaysOn == true && before?.executable == URL(fileURLWithPath: t).resolvingSymlinksInPath().path,
          "always-on: a daemon runs from the copy (\(before?.executable ?? "?"), pid \(before.map { String($0.pid) } ?? "?"))")
    guard let oldPid = before?.pid else { return }
    usleep(1_000_000)
    check(install(), "always-on: a new build renamed over its program (an install)")
    let inode = ExecutableIdentity.of(path: t)?.inode
    let t1 = Date()
    // No command: only the pid file and the process table are read until it has happened.
    let restarted = h.waitFor(45) { kill(oldPid, 0) != 0 && pidFile().map { $0 != oldPid && kill($0, 0) == 0 } == true }
    let took = Date().timeIntervalSince(t1)
    usleep(1_000_000)
    let after = inst.json(["daemon", "status"], HostStatus.self)
    let all = daemonsOfStore()
    check(restarted, String(format: "always-on: replaced by rename with nothing running → it restarted in place in %.1f s, no command typed (pid %d → %@)",
                            took, oldPid, pidFile().map(String.init) ?? "none"))
    check(all.count == 1 && after?.pid == all.first, "always-on: one daemon of this store (\(all))")
    check(after?.parentPid == 1, "always-on: the new daemon's parent is launchd (\(after?.parentPid.map(String.init) ?? "?"))")
    check(after?.executable == before?.executable && after?.executableChange == nil && ExecutableIdentity.of(path: t)?.inode == inode,
          "always-on: it runs the new file — its program unchanged since it started (\(after?.executableChange ?? "no change"))")
    check(after?.alwaysOn == true, "always-on: and it is always on too")
    let log = (try? String(contentsOf: store.logFile, encoding: .utf8)) ?? ""
    check(log.contains("restarting in place, from the installed build") && log.contains("daemon exiting (restarted in place)"),
          "always-on: the old daemon's log says it restarted in place")

    // 4. the dashboard follows an upgrade (DashboardUpgradeChecks.swift).
    dashboardFollowsUpgradeChecks(h, root: root, binary: binary)
}
