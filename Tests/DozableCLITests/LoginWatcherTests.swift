import Darwin
import Foundation
import DozableKit
import XCTest
@testable import DozableHost

// 695 — the login keep-alive's decisions, without a real claude, keychain or clock: a fake keychain (AccountTests'), a
// recording runner, explicit `now:`. The real `claude -p` is never run (TestSafety stops a guarded run that would).
// Every token here is a made-up string.

/// Records each run: its argv, the names of its environment, its folder (and what was in it, and its mode, at the run).
final class RecordingRunner: KeepaliveRunning, @unchecked Sendable {
    struct Seen { var binary: String; var arguments: [String]; var environment: [String: String]; var directory: URL; var entries: [String]; var mode: Int }
    private let lock = NSLock()
    private var _runs: [Seen] = []
    var result = KeepaliveRun(code: 0, lastErrorLine: nil)
    /// Results for the first runs, in order (then `result`).
    var script: [KeepaliveRun] = []
    var onRun: () -> Void = {}
    var runs: [Seen] { lock.withLock { _runs } }
    func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32 {
        runCapturing(binary: binary, arguments: arguments, environment: environment, directory: directory, timeout: timeout).code
    }
    func runCapturing(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> KeepaliveRun {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["<missing>"]
        let mode = ((try? FileManager.default.attributesOfItem(atPath: directory.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let r: KeepaliveRun = lock.withLock {
            _runs.append(Seen(binary: binary, arguments: arguments, environment: environment, directory: directory, entries: entries, mode: mode))
            return script.isEmpty ? result : script.removeFirst()
        }
        if r.code == 0 { onRun() }
        return r
    }
}

final class LoginWatcherTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()
    let svc = ClaudeLogin.baseService
    let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-lw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func watcher(_ mode: KeepaliveMode, runner: RecordingRunner, holders: @escaping @Sendable () -> ClaudeHolders = { ClaudeHolders() },
                 binary: String? = "/fake/claude", locked: String? = nil, reports: Locked<[KeepaliveRecord]>) -> LoginWatcher {
        let w = LoginWatcher(account: "mac", configDir: nil, keychain: keychain, pinned: nil, identityReader: { nil }, identityStamp: { nil },
                             credentialsFile: { nil })
        var k = KeepaliveConfig(mode: mode, runner: runner, holders: holders, binary: { binary })
        k.keychainLocked = { locked }
        k.runDirectory = root.appendingPathComponent("keepalive/run")
        k.report = { r in reports.mutate { $0.append(r) } }
        w.keepalive = k
        w.readNow(now: now)
        return w
    }

    func renewing(_ r: RecordingRunner) {
        r.onRun = { [keychain, svc] in keychain.put(svc, claudeItem("sk-ant-oat01-RENEWED", expires: Date().addingTimeInterval(8 * 3600))) }
    }

    // MARK: always

    func testAlwaysRenewsWithNoSubscriberTheMinimalRun() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(300)))
        let runner = RecordingRunner()
        renewing(runner)
        let reports = Locked<[KeepaliveRecord]>([])
        // A file left in the run's folder by an earlier run is gone at the next.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keepalive/run"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("keepalive/run/left-over").path, contents: Data("x".utf8))
        let w = watcher(.always, runner: runner, reports: reports)
        XCTAssertTrue(w.isEmpty, "no subscriber at all")
        XCTAssertFalse(w.keepaliveIfDue(now: now), "not before the expiry: Claude Code renews only an expired token")
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(299)))
        XCTAssertEqual(runner.runs.count, 0)
        XCTAssertTrue(w.keepaliveIfDue(now: now.addingTimeInterval(301)), "at the expiry")
        XCTAssertEqual(runner.runs.count, 1)
        let seen = runner.runs[0]
        XCTAssertEqual(seen.binary, "/fake/claude")
        XCTAssertEqual(seen.arguments, ["-p", "ok", "--model", "haiku", "--max-turns", "1", "--no-session-persistence",
                                        "--tools", "", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#])
        XCTAssertTrue(Set(seen.environment.keys).isSubset(of: ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL", "CLAUDE_CONFIG_DIR"]),
                      "the env allowlist: \(seen.environment.keys.sorted())")
        XCTAssertEqual(seen.directory.path, root.appendingPathComponent("keepalive/run").path)
        XCTAssertEqual(seen.entries, [], "a fresh, EMPTY folder")
        XCTAssertEqual(seen.mode, 0o700)
        XCTAssertEqual(reports.value.map(\.outcome), [.renewed])
        let r = try XCTUnwrap(reports.value.first)
        XCTAssertEqual(r.mode, "always")
        XCTAssertGreaterThan(r.expiresAfter ?? .distantPast, now.addingTimeInterval(3600))
        XCTAssertEqual(r.lastRenewedAt, now.addingTimeInterval(301))
        XCTAssertEqual(r.nextTryAt, r.expiresAfter, "the next try is the new expiry")
        XCTAssertEqual(w.state, .ok)
        // Once per expiry: the renewed login is hours away.
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(400)))
        XCTAssertEqual(runner.runs.count, 1)
    }

    /// The environment allowlist itself: nothing that would override the login (or name a sandbox) reaches the run.
    func testTheRunsEnvironmentIsTheAllowlist() {
        let e = LoginWatcher.scrubbedEnvironment(configDir: nil, from: ["PATH": "/usr/bin", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "sk-ant-api03-X",
                                                                        "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-X", "CLAUDECODE": "1",
                                                                        "CLAUDE_CODE_ENTRYPOINT": "x", "DOZ_STORE": "/s", "ANTHROPIC_BASE_URL": "http://x"])
        XCTAssertEqual(Set(e.keys), ["PATH", "HOME"])
    }

    // MARK: on

    func testOnNeedsAUseAndAFencedSessionCountsAsOne() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(300)))
        let runner = RecordingRunner()
        renewing(runner)
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.on, runner: runner, reports: reports)
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(301)), "on, expired, nothing uses it: nothing runs")
        XCTAssertEqual(runner.runs.count, 0)
        XCTAssertEqual(reports.value.count, 0, "not due is not a try")
        // A fenced session's proxy IS a subscriber whose vault records the use (683: it subscribes like a sandbox).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        let p = try MacFenceProxy(session: "fs", fd: fd, port: 1, policy: .permissions(["model"], preset: "locked"), secretSHA256: "00",
                                  ca: nil, environment: [:])
        w.subscribe("@mac fs", p)
        _ = p.proxy.vault.rewrite(head: Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n".utf8), host: "api.anthropic.com")
        XCTAssertNotNil(p.proxy.vault.lastUsed(CredentialBinding.claudeOAuth.id), "the fenced session used the login")
        XCTAssertTrue(w.keepaliveIfDue(now: now.addingTimeInterval(301)), "on: a fenced session's use counts")
        XCTAssertEqual(runner.runs.count, 1)
    }

    // MARK: the skips

    func testAnUnfencedHolderSkipsNamingItAndTheRunWaitsForIt() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()
        renewing(runner)
        let reports = Locked<[KeepaliveRecord]>([])
        let held = Locked(true)
        let w = watcher(.always, runner: runner, holders: {
            held.value ? ClaudeHolders(holders: [ClaudeHolder(pid: 812, session: "admin")], fenced: [ClaudeHolder(pid: 900, session: "fs")]) : ClaudeHolders()
        }, reports: reports)
        XCTAssertFalse(w.keepaliveIfDue(now: now))
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(120)), "still held")
        XCTAssertEqual(runner.runs.count, 0)
        XCTAssertEqual(reports.value.count, 1, "a skip repeated at every look is recorded once")
        let r = try XCTUnwrap(reports.value.first)
        XCTAssertEqual(r.outcome, .skipped)
        XCTAssertEqual(r.reason, "Claude Code (pid 812, session admin on this Mac) holds its own copy of this Mac's login; renewing now would cancel that copy. It renews when that Claude Code is next used.")
        // The holder ends: the next look runs (a skip never used up the expiry).
        held.mutate { $0 = false }
        XCTAssertTrue(w.keepaliveIfDue(now: now.addingTimeInterval(240)))
        XCTAssertEqual(runner.runs.count, 1)
        XCTAssertEqual(ClaudeHolder(pid: 77, session: nil).label, "Claude Code (pid 77, not Dozable's)")
    }

    func testALockedDaemonAndNoClaudeNeverRun() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.always, runner: runner, locked: "ssh", reports: reports)
        XCTAssertFalse(w.keepaliveIfDue(now: now))
        XCTAssertEqual(runner.runs.count, 0)
        XCTAssertEqual(reports.value.first?.outcome, .skipped)
        XCTAssertTrue(reports.value.first?.reason?.contains("login keychain is locked (ssh)") == true, reports.value.first?.reason ?? "")
        let reports2 = Locked<[KeepaliveRecord]>([])
        let w2 = watcher(.always, runner: runner, binary: nil, reports: reports2)
        XCTAssertFalse(w2.keepaliveIfDue(now: now))
        XCTAssertEqual(runner.runs.count, 0)
        XCTAssertEqual(reports2.value.first?.reason, "Claude Code isn't installed on this Mac")
    }

    // MARK: outcomes

    func testAFailedRunIsRecordedWithoutATokenAndRetriedOnTheSchedule() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()
        runner.result = KeepaliveRun(code: 1, lastErrorLine: "Error: OAuth refresh failed for sk-ant-ort01-AAAABBBBCCCCDDDDEEEEFFFF (Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc)")
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.always, runner: runner, reports: reports)
        XCTAssertTrue(w.keepaliveIfDue(now: now))
        let r = try XCTUnwrap(reports.value.first)
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertEqual(r.exit, 1)
        let reason = try XCTUnwrap(r.reason)
        XCTAssertTrue(reason.hasPrefix("exit 1: Error: OAuth refresh failed for …"), reason)
        XCTAssertFalse(reason.contains("sk-ant") || reason.contains("eyJ") || reason.contains("AAAABBBB"), reason)
        XCTAssertTrue(reason.hasSuffix("— tried again"), reason)
        XCTAssertEqual(r.nextTryAt.map { Int($0.timeIntervalSince(now).rounded()) }, 59, "the next retry, 1 min after the expiry")
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(30)), "not before the next retry")
        XCTAssertTrue(w.keepaliveIfDue(now: now.addingTimeInterval(60)), "a failure is retried (a network down for a minute)")
        XCTAssertEqual(runner.runs.count, 2)
    }

    /// A Claude Code that fails twice (say, offline), then renews: renewed at the third run, and no run after.
    func testTwoFailuresThenARenewal() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()
        renewing(runner)                                     // onRun renews — only for a run that exits 0
        runner.script = [KeepaliveRun(code: 1, lastErrorLine: "network down"), KeepaliveRun(code: -2, lastErrorLine: nil)]
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.always, runner: runner, reports: reports)
        for t in [0.0, 60, 300] { XCTAssertTrue(w.keepaliveIfDue(now: now.addingTimeInterval(t)), "at +\(Int(t)) s") }
        XCTAssertEqual(reports.value.map(\.outcome), [.failed, .failed, .renewed])
        XCTAssertTrue(reports.value[1].reason?.hasPrefix("timed out after 120 s") == true, reports.value[1].reason ?? "")
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(900)), "renewed: no more runs")
        XCTAssertEqual(runner.runs.count, 3)
    }

    /// One that always fails: 6 runs on the schedule, then it gives up until the login changes or the mode is set again.
    func testAlwaysFailingGivesUpAfterSixRuns() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()
        runner.result = KeepaliveRun(code: 1, lastErrorLine: "Error: no network")
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.always, runner: runner, reports: reports)
        for (t, ran) in [(0.0, true), (60, true), (300, true), (900, true), (2700, true), (4500, true), (6300, false), (99_000, false)] {
            XCTAssertEqual(w.keepaliveIfDue(now: now.addingTimeInterval(t)), ran, "at +\(Int(t)) s")
        }
        XCTAssertEqual(runner.runs.count, 6)
        let last = try XCTUnwrap(reports.value.last)
        XCTAssertEqual(last.outcome, .failed)
        XCTAssertNil(last.nextTryAt)
        XCTAssertTrue(last.reason?.contains("gave up after 6 tries") == true, last.reason ?? "")
        XCTAssertEqual(KeepaliveStatus(mode: .always, record: last, expiresAt: last.expiresBefore).waitsForChange, true)
        // The mode set again: tried again.
        w.resetRuns()
        XCTAssertTrue(w.keepaliveIfDue(now: now.addingTimeInterval(99_100)))
    }

    /// A run that leaves the login unchanged is tried again 1, 5 and 15 minutes after the expiry, then every 30 — six runs at
    /// most, then `failed`; never before the next due time, never two at once.
    func testARunThatLeftTheLoginUnchangedIsRetriedWithBackoffThenFailed() throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()                       // exits 0, renews nothing (as Claude Code before the expiry)
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.always, runner: runner, reports: reports)
        XCTAssertTrue(w.keepaliveIfDue(now: now))
        XCTAssertEqual(reports.value.last?.outcome, .unchanged)
        XCTAssertEqual(reports.value.last?.reason, "Claude Code did not renew the login (the token had not expired yet) — tried again")
        XCTAssertEqual(reports.value.last?.nextTryAt.map { Int($0.timeIntervalSince(now).rounded()) }, 59, "1 min after the expiry")
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(30)), "not before the next due time")
        for (t, ran) in [(60.0, true), (200, false), (300, true), (900, true), (2000, false), (2700, true), (4500, true), (9000, false)] {
            XCTAssertEqual(w.keepaliveIfDue(now: now.addingTimeInterval(t)), ran, "at +\(Int(t)) s")
        }
        XCTAssertEqual(runner.runs.count, 6)
        XCTAssertEqual(reports.value.map(\.outcome), [.unchanged, .unchanged, .unchanged, .unchanged, .unchanged, .failed])
        let last = try XCTUnwrap(reports.value.last)
        XCTAssertNil(last.nextTryAt)
        XCTAssertTrue(last.reason?.contains("gave up after 6 tries") == true, last.reason ?? "")
        XCTAssertEqual(KeepaliveSchedule.due(expiry: now, runs: 6), nil)
    }

    func testOffNeverRuns() {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(-1)))
        let runner = RecordingRunner()
        let reports = Locked<[KeepaliveRecord]>([])
        let w = watcher(.off, runner: runner, reports: reports)
        XCTAssertFalse(w.keepaliveIfDue(now: now))
        XCTAssertEqual(runner.runs.count + reports.value.count, 0)
    }

    // MARK: who holds the login

    func testFencedMembersAndTheKeepalivesOwnRunAreNotHolders() {
        var fencedRec = MacSessionRecord(argv: ["claude"], workdir: "/w", openedAt: Date())
        fencedRec.pid = 100
        fencedRec.fence = MacFenceRecord(profile: "agent", keychain: false, readable: [], writable: [], sessionFolder: "/f/s1",
                                         grants: MacFenceGrants(profile: "agent", keychain: false, readable: [], writable: []), tag: "t1",
                                         templateVersion: 1, profileSHA256: "x", gitBaseline: nil, stoppedForGit: nil, stoppedPids: nil)
        var admin = MacSessionRecord(argv: ["claude"], workdir: "/w", openedAt: Date())
        admin.pid = 200
        let parents: [pid_t: pid_t] = [300: 200, 301: 50, 102: 100]
        let look = ClaudeHolders.find(candidates: [100, 102, 200, 300, 301, 400],
                                      records: ["f1": fencedRec, "admin": admin],
                                      own: { $0 == 400 },
                                      isFencedMember: { pid, f, program in f.tag == "t1" && (pid == program || pid == 102) },
                                      parent: { parents[$0] })
        XCTAssertEqual(look.fenced.map(\.pid), [100, 102])
        XCTAssertEqual(look.fenced.map(\.session), ["f1", "f1"])
        XCTAssertEqual(look.holders, [ClaudeHolder(pid: 200, session: "admin"), ClaudeHolder(pid: 300, session: "admin"), ClaudeHolder(pid: 301, session: nil)])
    }

    /// The services' fallback (older tests give only "is a Claude Code running"): one unnamed holder.
    func testIsClaudeRunningAloneIsOneUnnamedHolder() {
        let k = KeepaliveConfig(enabled: true, runner: RecordingRunner(), isClaudeRunning: { true }, binary: { nil })
        XCTAssertEqual(k.mode, .on)
        XCTAssertEqual(k.holders().holders.map(\.label), ["Claude Code (not Dozable's)"])
    }

    /// The daemon's side: `always` keeps a watcher on the Mac login with no sandbox at all; on/off let it go; `account ls`'s
    /// Mac row carries the keep-alive; a run's record lands in `<store>/keepalive.json`.
    func testAlwaysKeepsAStandingWatcherAndTheRowSaysIt() async throws {
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(-1)))
        let runner = RecordingRunner()
        renewing(runner)
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { "/fake/claude" }, home: home,
                                   keepaliveRunner: runner, isClaudeRunning: { false }, watchInterval: .seconds(3600), claudeProcesses: { [] })
        let c = HostCore(store: DozableStore(root: root.appendingPathComponent("store")), readOnly: false, version: "test", services: s)
        await c.load()
        let none = await c.loginWatcherCount
        XCTAssertEqual(none, 0)
        var r = HostRequest(.accountKeepalive)
        r.enabled = true
        r.keepaliveMode = "always"
        var m = await c.handle(r)
        XCTAssertNil(m.error)
        XCTAssertEqual(KeepaliveMode.of(try XCTUnwrap(m.result).decode(AccountsFile.self)), .always)
        let w = try await XCTUnwrapAsync(await c.loginWatcher("mac"))
        XCTAssertTrue(w.standing)
        XCTAssertEqual(w.keepalive?.mode, .always)
        // Made standing, it looks at once (no subscriber, nothing used it): the login has expired → one run.
        let recordStore = DozableStore(root: root.appendingPathComponent("store"))
        let t0 = Date()
        while KeepaliveRecord.read(recordStore) == nil && Date().timeIntervalSince(t0) < 10 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(w.keepaliveIfDue(), "once per expiry")
        XCTAssertEqual(runner.runs.count, 1)
        XCTAssertEqual(runner.runs.first?.directory.path, root.appendingPathComponent("store/keepalive/run").path)
        let rec = try XCTUnwrap(KeepaliveRecord.read(recordStore))
        XCTAssertEqual(rec.outcome, .renewed)
        m = await c.handle(HostRequest(.accountList))
        let mac = try XCTUnwrap(try XCTUnwrap(m.result).decode([AccountRow].self).first { $0.name == "mac" })
        XCTAssertEqual(mac.keepalive?.mode, "always")
        XCTAssertEqual(mac.keepalive?.outcome, "renewed")
        // The dashboard's switch (enabled only) keeps always; off lets the watcher go.
        r = HostRequest(.accountKeepalive)
        r.enabled = true
        m = await c.handle(r)
        XCTAssertEqual(KeepaliveMode.of(try XCTUnwrap(m.result).decode(AccountsFile.self)), .always)
        r.enabled = false
        _ = await c.handle(r)
        let after = await c.loginWatcherCount
        XCTAssertEqual(after, 0, "off: no subscriber, no watcher")
        r = HostRequest(.accountKeepalive)
        r.keepaliveMode = "sometimes"
        m = await c.handle(r)
        XCTAssertNotNil(m.error)
    }

    /// The real runner keeps the last stderr line (never the run's stdout) and its exit.
    func testTheRunnerKeepsTheLastErrorLine() {
        let r = ProcessKeepaliveRunner().runCapturing(binary: "/bin/sh", arguments: ["-c", "echo out; echo first >&2; echo 'the last one' >&2; exit 3"],
                                                      environment: ["PATH": "/usr/bin:/bin"], directory: root, timeout: 20)
        XCTAssertEqual(r, KeepaliveRun(code: 3, lastErrorLine: "the last one"))
        let t = ProcessKeepaliveRunner().runCapturing(binary: "/bin/sleep", arguments: ["30"], environment: [:], directory: root, timeout: 0.5)
        XCTAssertEqual(t.code, -2, "killed at its timeout")
    }
}
