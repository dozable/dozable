// `doz-vmtest upgrade --old PATH --doz PATH` (591, `make test-vm-upgrade`): an update of doz
// never costs a sleeping sandbox its sessions.
//
//   A. THE PREVIOUS RELEASE sleeps, THIS BUILD wakes. With the old `doz` (the last release tag's,
//      built once by the Makefile): create a lab sandbox and an agent-image sandbox, start them, run a
//      session in each that prints a marker and keeps running, write a marker file, hibernate both and
//      stop the old host. With this build: wake each — the session is the same process, its screen
//      still shows the marker, the file is there. Then hibernate and wake again with this build: the
//      layout this build recorded is compatible with the VM it rebuilds.
//   B. THE INCIDENT (591, the owner's store): the file a running host executes is overwritten in place
//      (cp + codesign, as the old install did). The host reports "its program was updated underneath
//      it" — on a wake it cannot do, and in `host status` — instead of a raw VZ error; `host stop` keeps
//      the snapshots; a host of this build (the intact file) wakes the sandbox with its session.
//   C. A host whose program was REPLACED by an update (a rename: the new install) exits by itself once
//      nothing runs and nobody is connected, so the next command runs the installed build.
//   D. (689, the previous release says "host": `doz host`, `host.lock`, `host.sock`) AN OLDER DAEMON STILL RUNNING when
//      this build arrives: this build's CLI is answered by it (its old socket) and says which build answers; a daemon
//      of this build started by hand gives up (never a second owner: by lock and by pid); `doz daemon stop` stops it;
//      then a daemon of this build holds BOTH locks, and the previous release's `host start --foreground` gives up.
//   E. (689) THE HAND-OVER old → new: the previous release's host serves a fenced session on this Mac; the program's
//      folder is replaced by rename (an install); the old host hands the session to the build now installed (it runs
//      `doz host start --launch-detached`, which this build takes as `daemon start`) and exits — the new daemon takes
//      both locks only after the old one let go (the logs' order), and the session runs on, the same holder.
//
// 592: the first DozableKit release is v0.10.0, and a store of a pre-rename release (v0.9.0 or older) is
// NOT expected to wake under doz (owner ruling: no backward compatibility). Until a DozableKit tag exists the Makefile
// passes a COPY of this build as --old: A is then a reinstall of the same version, B and C unchanged.
//
// Inputs: --old PATH (the previous release's signed doz), --doz PATH (this build's), --store DIR
// (a SCRATCH store; the agent image is baked once in it), --entitlements PATH (for the in-place re-sign;
// default Scripts/doz.entitlements). Sandboxes: upl (lab), upa (pi). Nothing outside the store.
import Darwin
import Foundation
import DozableKit
import DozableHost

func upgradeSuite() async throws {
    func arg(_ name: String, _ def: String) -> String {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        return def
    }
    let oldBin = URL(fileURLWithPath: arg("--old", "")).standardizedFileURL.path
    let newBin = URL(fileURLWithPath: arg("--doz", ".build/debug/doz")).standardizedFileURL.path
    let entitlements = URL(fileURLWithPath: arg("--entitlements", "Scripts/doz.entitlements")).standardizedFileURL.path
    guard FileManager.default.isExecutableFile(atPath: oldBin) else {
        check(false, "the previous release's doz (--old) is missing: \(oldBin)")
        return
    }
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let old = CLIHarness(binary: oldBin, store: storeRoot)
    let new = CLIHarness(binary: newBin, store: storeRoot)
    // 689: the previous release (0.40.x) calls its daemon "the host" — `doz host …`, `<store>/host.lock`; a copy of this
    // build (no release tag yet) says daemon. Its environment variable too (DOZ_HOST_IDLE before 0.50).
    let oldCmd = old.run(["host", "--help"]).code == 0 ? "host" : "daemon"
    let oldLock = oldCmd + ".lock", oldPidFile = oldCmd + ".pid"
    old.env["DOZ_HOST_IDLE"] = "30"
    let oldVersion = old.run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    let newVersion = new.run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    info("old doz \(oldVersion) (\(oldBin)) · new doz \(newVersion) (\(newBin)) · store \(storeRoot.path)")
    let boxes: [(name: String, image: String)] = [("upl", "lab"), ("upa", "pi")]
    let marker = "UPGRADE-" + String(UInt32.random(in: 100_000...999_999))

    /// Whether a daemon (of either build) holds the store's lock file `name` — a flock probe.
    func lockHeld(_ name: String) -> Bool {
        let fd = open(storeRoot.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
    func pidIn(_ name: String) -> Int32? {
        (try? String(contentsOf: storeRoot.appendingPathComponent(name), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func cleanUp() {
        for b in boxes { new.run(["rm", b.name, "--yes"]) }
        new.run(["daemon", "stop"])
    }
    cleanUp()

    // ── A. the previous release sleeps them.
    var pids: [String: Int] = [:]
    for b in boxes {
        // 610: `--account none` — nothing here calls a model, and a scratch store must never bind the Mac's Claude login
        // (the store's default, `mac`, made the host read the login keychain's access token for upl); pi also needs it
        // (594: an API-key account, or `none` chosen explicitly).
        let c = old.run(["create", b.name, "--image", b.image, "--account", "none"], timeout: 60)
        check(c.code == 0, "\(oldVersion): create \(b.name) (\(b.image))" + (c.code == 0 ? "" : " — \(c.err.suffix(200))"))
        let s = old.run(["start", b.name], timeout: 1500)            // a first start bakes the image (minutes, network)
        check(s.code == 0, "\(oldVersion): start \(b.name)")
        let r = old.run(["run", b.name, "--session", "keep", "-d", "--", "sh", "-c", "echo SCREEN-\(marker); exec sleep 1000000"], timeout: 60)
        check(r.code == 0, "\(oldVersion): a session in \(b.name) that prints a marker and keeps running")
        check(old.run(["exec", b.name, "--", "sh", "-c", "echo FILE-\(marker) > /tmp/upgrade-marker"], timeout: 60).code == 0, "\(oldVersion): a marker file in \(b.name)")
        _ = old.waitFor(10) { old.sessions(b.name).first { $0.name == "keep" }?.pid != nil }
        pids[b.name] = old.sessions(b.name).first { $0.name == "keep" }?.pid
        check(pids[b.name] != nil, "\(b.name): session keep runs, pid \(pids[b.name].map(String.init) ?? "?")")
        check(old.run(["hibernate", b.name], timeout: 120).code == 0, "\(oldVersion): hibernate \(b.name)")
    }
    check(old.run([oldCmd, "stop"], timeout: 120).code == 0, "\(oldVersion): \(oldCmd) stop")
    _ = old.waitFor(30) { !lockHeld(oldLock) }

    /// This build wakes `name`: the same session process, its screen, its file.
    func wakeIntact(_ h: CLIHarness, _ name: String, _ who: String) {
        let w = h.run(["wake", name], timeout: 180)
        check(w.code == 0, "\(who): wake \(name)" + (w.code == 0 ? "" : " — \(w.err.suffix(300))"))
        guard w.code == 0 else { return }
        let keep = h.sessions(name).first { $0.name == "keep" }
        check(keep != nil && !(keep?.ended ?? true) && keep?.pid == pids[name],
              "\(name): session keep is the SAME process (pid \(keep?.pid.map(String.init) ?? "?") vs \(pids[name].map(String.init) ?? "?"))")
        let f = h.run(["exec", name, "--", "cat", "/tmp/upgrade-marker"], timeout: 60)
        check(f.out.contains("FILE-\(marker)"), "\(name): the marker file is there")
        if let c = try? AttachedClient(h, ["attach", name, "keep"]) {
            let seen = c.wait(20) { $0.text.contains("SCREEN-\(marker)") }
            c.close()
            check(seen, "\(name): the session's screen still shows its marker")
        } else {
            check(false, "\(name): attach")
        }
    }
    for b in boxes { wakeIntact(new, b.name, "\(newVersion) (slept by \(oldVersion))") }
    // 610: the wake brought THIS build's deckhold to the guest's disk (sessions opened from now on run it); the running
    // session kept its own holder (the same pid, above).
    if let bin = DeckholdBinary.locate(), let want = Sandbox.digest(bin) {
        for b in boxes {
            let have = new.run(["exec", b.name, "--", "sh", "-c", GuestCommand.deckholdDigestScript], timeout: 60).out.trimmingCharacters(in: .whitespacesAndNewlines)
            check(have == want, "\(b.name): the wake put this build's deckhold in the guest (\(have.prefix(12)) vs \(want.prefix(12)))")
        }
    } else {
        check(false, "this build's deckhold resource is found")
    }
    // The layout this build records, on its own next wake.
    for b in boxes {
        check(new.run(["hibernate", b.name], timeout: 120).code == 0, "\(newVersion): hibernate \(b.name)")
        let rec = PersistedSandbox.read(from: DozableStore(root: storeRoot).layout(b.name).persistedState)
        check(rec?.vmLayout != nil && rec?.vmLayout?.recordedBy == "doz \(newVersion)",
              "\(b.name): the snapshot's VM layout is recorded (\(rec?.vmLayout?.recordedBy ?? "none"), \(rec?.vmLayout?.disks.count ?? 0) disks)")
    }
    for b in boxes { wakeIntact(new, b.name, "\(newVersion) (its own layout)") }

    // ── B. the incident: the running host's program overwritten in place.
    let binDir = storeRoot.appendingPathComponent("bin-under-test")
    try? FileManager.default.removeItem(at: binDir)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let newDir = URL(fileURLWithPath: newBin).deletingLastPathComponent()
    for bundle in ["DozableKit_DozableKit.bundle", "DozableKit_DozableWeb.bundle"] {
        try? FileManager.default.copyItem(at: newDir.appendingPathComponent(bundle), to: binDir.appendingPathComponent(bundle))
    }
    let t = binDir.appendingPathComponent("doz").path
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
    check(sh(["/bin/cp", newBin, t]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t]) == 0,
          "a copy of this build to run a host from")
    let under = CLIHarness(binary: t, store: storeRoot)
    new.run(["daemon", "stop"])                                        // hibernates both
    _ = new.waitFor(30) { !new.hostRunning }
    check(boxes.allSatisfy { new.row($0.name)?.phase == "hibernated" }, "both are hibernated")
    check(under.run(["daemon", "start"], timeout: 60).code == 0 && under.waitFor(30) { under.hostRunning }, "a daemon runs from the copy")
    // A held attach (no wake) keeps a connection open, so the host does not exit by itself (part C).
    let held = try AttachedClient(under, ["attach", "upa", "keep", "--no-wake"])
    _ = held.wait(3) { _ in false }
    // The incident: write the previous release INTO the running host's file, then re-sign it.
    // 592: the incident needs DIFFERENT code written into the running host's file. When --old is a copy
    // of this build (no DozableKit release to build yet), its bytes are identical — the running code then
    // stays valid, and codesign's rewrite reads as a mere "replaced" — so another program of this
    // build is written in instead: this test host's own executable.
    let sameBytes = FileManager.default.contentsEqual(atPath: oldBin, andPath: newBin)
    let intruder = sameBytes ? (Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? oldBin) : oldBin
    info("the program written into the running host's file: \(sameBytes ? "this test host (--old has this build's bytes)" : "the previous release (--old)")")
    check(sh(["/bin/cp", intruder, t]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t]) == 0,
          "the running host's program overwritten in place (cp + codesign, as the old install did)")
    // This build's CLI asks the running host (the file it started from is what changed).
    let st = new.json(["daemon", "status"], HostStatus.self)
    check(st?.executableChange == "overwritten" && (st?.executableNote ?? "").contains("updated underneath it"),
          "daemon status says its program was updated underneath it (\(st?.executableChange ?? "no change seen"))")
    let doctor = new.run(["doctor"], timeout: 120)
    check(doctor.out.contains("updated underneath it"), "doctor says so too")
    let w = new.run(["wake", "upl"], timeout: 180)
    info("wake on the overwritten host → \(w.code): \(w.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))")
    check(w.code != 0 ? w.err.contains("this daemon's program was updated underneath it") : true,
          w.code != 0 ? "a wake it cannot do says why (not a raw Virtualization error)"
                      : "the overwritten host still woke upl (macOS did not refuse it this time) — the error mapping was not exercised")
    held.close()
    if w.code == 0 { new.run(["hibernate", "upl"], timeout: 120) }
    let stop = new.run(["daemon", "stop"], timeout: 120)
    _ = new.waitFor(60) { !new.hostRunning }
    check(stop.code == 0 || !new.hostRunning, "daemon stop")
    let layoutL = DozableStore(root: storeRoot).layout("upl")
    if w.code != 0 {
        check(FileManager.default.fileExists(atPath: layoutL.snapshot.path), "upl's snapshot is kept after the failed wake and the stop")
    }
    // A host of THIS build (its intact file) wakes it, session and all.
    if new.row("upl")?.phase == "running" { new.run(["hibernate", "upl"], timeout: 120) }
    wakeIntact(new, "upl", "\(newVersion) after the incident")
    wakeIntact(new, "upa", "\(newVersion) after the incident")

    // ── C. replaced by an update (rename): an idle host exits by itself.
    for b in boxes { new.run(["hibernate", b.name], timeout: 120) }
    new.run(["daemon", "stop"])
    _ = new.waitFor(30) { !new.hostRunning }
    check(sh(["/bin/cp", newBin, t + ".new"]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t + ".new"]) == 0
          && rename(t + ".new", t) == 0, "a copy of this build again")
    check(under.run(["daemon", "start"], timeout: 60).code == 0 && under.waitFor(30) { under.hostRunning }, "a daemon runs from it, with nothing running")
    check(sh(["/bin/cp", newBin, t + ".new"]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t + ".new"]) == 0
          && rename(t + ".new", t) == 0, "an update renames a new file over it (the install since e1af862)")
    let exited = under.waitFor(60) { !under.hostRunning }
    check(exited, "the idle daemon whose program was replaced exits by itself, so the next command runs the installed build")

    if oldCmd == "host" {
        try await olderDaemonStillRunning(old: old, new: new, oldVersion: oldVersion, newVersion: newVersion, held: lockHeld, pidIn: pidIn)
        try await handOverOldToNew(old: old, new: new, oldBin: oldBin, newBin: newBin, oldVersion: oldVersion, newVersion: newVersion,
                                   marker: marker, held: lockHeld, pidIn: pidIn)
    } else {
        print("  SKIP  D, E: the previous build already says daemon (a copy of this build) — nothing to migrate")
    }

    cleanUp()
    try? FileManager.default.removeItem(at: binDir)
}

// ── D. (689) an older daemon (the previous release's "host") still running when this build arrives.
private func olderDaemonStillRunning(old: CLIHarness, new: CLIHarness, oldVersion: String, newVersion: String,
                                     held: (String) -> Bool, pidIn: (String) -> Int32?) async throws {
    new.run(["daemon", "stop"], timeout: 120)
    _ = new.waitFor(30) { !held("daemon.lock") && !held("host.lock") }
    check(old.run(["host", "start"], timeout: 60).code == 0 && old.waitFor(30) { held("host.lock") }, "\(oldVersion): its host runs (host.lock)")
    guard let oldPid = pidIn("host.pid") else { check(false, "\(oldVersion): its host wrote host.pid"); return }
    // This build's CLI is answered by it, on its old socket, and says which build that is.
    let st = new.json(["daemon", "status"], HostStatus.self)
    check(st?.version == oldVersion && st?.pid == oldPid,
          "\(newVersion): daemon status answers from the older daemon (doz \(st?.version ?? "?"), pid \(st.map { String($0.pid) } ?? "?") vs \(oldPid))")
    let ls = new.run(["ls"], timeout: 60)
    check(ls.code == 0 && ls.err.contains("the doz daemon is \(oldVersion)") && ls.err.contains("doz daemon stop"),
          "\(newVersion): a command says the older build answers and how to switch (\(ls.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))")
    // A daemon of this build started by hand is never a second owner: it takes daemon.lock, finds host.lock held by a
    // daemon that answers, and gives up.
    let p = new.process(["daemon", "start", "--foreground", "--idle-timeout", "1"])
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    let gaveUp = new.waitFor(30) { !p.isRunning }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    check(gaveUp && p.terminationStatus != 0, "\(newVersion): `daemon start --foreground` while it runs gives up (exit \(p.terminationStatus))")
    check(!held("daemon.lock") && held("host.lock") && pidIn("host.pid") == oldPid && kill(oldPid, 0) == 0 && pidIn("daemon.pid") == nil,
          "one owner: the older daemon alone holds the store (host.lock, pid \(oldPid)); daemon.lock free, no daemon.pid")
    // `doz daemon stop` (this build) stops it.
    let stop = new.run(["daemon", "stop"], timeout: 120)
    check(stop.code == 0 && new.waitFor(30) { !held("host.lock") && kill(oldPid, 0) != 0 }, "\(newVersion): daemon stop stops the older daemon")
    // A daemon of this build holds BOTH locks; the previous release's host started by hand then gives up after its wait.
    check(new.run(["daemon", "start"], timeout: 60).code == 0 && new.waitFor(30) { held("daemon.lock") && held("host.lock") },
          "\(newVersion): a daemon of this build holds daemon.lock AND host.lock")
    let newPid = pidIn("daemon.pid")
    let t0 = Date()
    let o = old.run(["host", "start", "--foreground", "--idle-timeout", "1"], timeout: 150)
    check(o.code != 0, String(format: "\(oldVersion): `host start --foreground` on this store gives up (exit \(o.code), after %.0f s) — never a second owner", Date().timeIntervalSince(t0)))
    check(newPid != nil && pidIn("daemon.pid") == newPid && kill(newPid!, 0) == 0 && pidIn("host.pid") == nil && held("host.lock"),
          "…the daemon of this build is still the one owner (pid \(newPid.map(String.init) ?? "?")); the older build wrote no pid")
    new.run(["daemon", "stop"], timeout: 120)
    _ = new.waitFor(30) { !held("daemon.lock") }
}

// ── E. (689) the 683 hand-over of a fenced session on this Mac, from the previous release's host to this build.
private func handOverOldToNew(old: CLIHarness, new: CLIHarness, oldBin: String, newBin: String, oldVersion: String, newVersion: String,
                              marker: String, held: (String) -> Bool, pidIn: (String) -> Int32?) async throws {
    let fm = FileManager.default
    let root = "/private/tmp/dzu-\(getpid())"          // short: the holders' sockets; never in the store or the home
    try? fm.removeItem(atPath: root)
    defer { try? fm.removeItem(atPath: root) }
    let work = root + "/work", home = root + "/home", cur = root + "/cur", next = root + "/next"
    for d in [work, home, cur, next] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    guard let holder = MacDeckhold.locate(executable: newBin).url else { check(false, "E: deckhold-mac beside this build (make cli builds it)"); return }
    // Each "installed" folder: its doz, its resource bundles, deckhold-mac (this build's: the previous release's build
    // from its tag has none of its own beside it).
    func fill(_ dir: String, from bin: String) throws {
        let src = URL(fileURLWithPath: bin).deletingLastPathComponent().path
        try fm.copyItem(atPath: bin, toPath: dir + "/doz")
        for b in (try fm.contentsOfDirectory(atPath: src)) where b.hasSuffix(".bundle") { try fm.copyItem(atPath: src + "/" + b, toPath: dir + "/" + b) }
        try fm.copyItem(atPath: holder.path, toPath: dir + "/deckhold-mac")
        // doz reads its version from a VERSION beside it (make cli / prev-cli put one there).
        if fm.fileExists(atPath: src + "/VERSION") { try fm.copyItem(atPath: src + "/VERSION", toPath: dir + "/VERSION") }
    }
    try fill(cur, from: oldBin)
    try fill(next, from: newBin)
    let inst = CLIHarness(binary: cur + "/doz", store: new.store)
    inst.env = old.env
    inst.env["DOZ_HOST_IDLE"] = "0.1"             // the old host's idle loop looks every 1.5 s (the fenced session keeps it up)
    inst.env["DOZ_DAEMON_IDLE"] = "0.1"
    inst.env["DOZ_TEST_FENCE_HOME"] = home
    new.run(["daemon", "stop"], timeout: 120)
    _ = new.waitFor(30) { !held("daemon.lock") && !held("host.lock") }
    let r = inst.run(["run", "@mac", "-d", "--fenced", "--session", "upho", "--workdir", work, "--",
                      "/bin/sh", "-c", "echo HO-\(marker) > ho.txt; exec sleep 600"], timeout: 90)
    check(r.code == 0, "E \(oldVersion): a fenced session on this Mac, the host's only live work" + (r.code == 0 ? "" : " — \(r.err.suffix(300))"))
    guard r.code == 0, let oldPid = pidIn("host.pid") else { return }
    defer { new.run(["sessions", "end", "@mac", "upho", "--yes"], timeout: 60); new.run(["daemon", "stop"], timeout: 120) }
    let holderPid = inst.json(["sessions", "@mac"], [SessionRow].self)?.first { $0.name == "upho" }?.pid
    check(holderPid != nil && new.waitFor(10) { fm.fileExists(atPath: work + "/ho.txt") }, "E: it runs (pid \(holderPid.map(String.init) ?? "?"))")
    usleep(1_500_000)
    // The update: the installed folder replaced by rename (the old host keeps its own files, open by inode).
    check(rename(cur, cur + ".old") == 0 && rename(next, cur) == 0, "E: the program's folder replaced by rename (\(oldVersion) → \(newVersion))")
    check(new.waitFor(90) { kill(oldPid, 0) != 0 }, "E: the older host hands the session over and exits (pid \(oldPid))")
    check(new.waitFor(60) { held("daemon.lock") && held("host.lock") }, "E: a daemon of this build took over — both locks")
    let st = new.json(["daemon", "status"], HostStatus.self)
    check(st?.version == newVersion && st?.pid != oldPid && st?.pid == pidIn("daemon.pid"),
          "E: the daemon now serving is this build's (doz \(st?.version ?? "?"), pid \(st.map { String($0.pid) } ?? "?"))")
    let row = new.json(["sessions", "@mac"], [SessionRow].self)?.first { $0.name == "upho" }
    check(row != nil && row?.ended == false && row?.pid == holderPid && row?.fence != nil,
          "E: the fenced session runs on, adopted — the same holder (pid \(row?.pid.map(String.init) ?? "?"))")
    // Never two owners: the old host's last line (written before it lets go of host.lock) precedes the new daemon's
    // first (written once it holds both locks). Each log line starts with its ISO-8601 time.
    func lines(_ name: String) -> [String] {
        ((try? String(contentsOf: new.store.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func time(_ l: String?) -> Date? { l.flatMap { $0.split(separator: " ").first.map(String.init) }.flatMap { iso.date(from: $0) } }
    let all = lines("host.log") + lines("daemon.log")
    let oldLast = all.last { $0.contains("the new host takes over") }
    let newFirst = st.flatMap { s in all.first { $0.contains("doz daemon \(newVersion) (pid \(s.pid))") } }
    let (a, b) = (time(oldLast), time(newFirst))
    check(a != nil && b != nil && a! <= b!, "E: never two owners — the older host drained and let go (\(oldLast.map { String($0.prefix(30)) } ?? "no line")) before the daemon of this build began (\(newFirst.map { String($0.prefix(30)) } ?? "no line"))")
}
