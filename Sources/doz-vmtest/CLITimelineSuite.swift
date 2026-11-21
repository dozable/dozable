import CryptoKit
import DozableHost
import DozableKit
import Foundation

// 747 — `make test-cli-timeline` (no VM) and `make test-cli-timeline-vm` (one scratch lab VM): this Mac's history end to
// end through the signed doz, a scratch store and settings file only. The no-VM rows: the catalogue names "this Mac" with
// no daemon (and starts none); an action, a workspace line and a grant appear with the contract's ids; a daemon restart
// keeps them and closes the earlier daemon run; retention settings and a clock moved ahead (`DOZ_TEST_TIMELINE_NOW`, a
// guarded seam) → `prune --dry-run` → a real prune: only the history file's and the four new tables' old rows go —
// `doz workspace log` still answers, an old sentinel metrics row of every existing table and an old grants line remain;
// `rebuild` gives the same ids; the history file deleted is made again; the live feed; daemon stopped → the CLI starts
// none; no real host name and no `path` in any answer. The VM rows: a denied connection's host only as a sensitive attr;
// samples after two minutes, each within 2 ms; a fake key's use (its placeholder refused over plain HTTP) as `key.use`.

private func timelineQueryFile(_ dir: URL, _ name: String, _ q: TimelineQuery) -> String {
    let p = dir.appendingPathComponent(name).path
    try? HostWire.encoder.encode(q).write(to: URL(fileURLWithPath: p))
    return p
}

private func sqliteCount(_ path: String, _ sql: String) -> Int64 {
    ((try? SQLiteDB(path: path, readOnly: true).scalar(sql))?.int) ?? -1
}

private func fileSHA(_ path: String) -> String {
    SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

/// The names this Mac goes by on the network (none may appear in an answer).
private func realMacNames() -> [String] {
    var out: [String] = []
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) == 0, let first = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: ".").first, first.count > 2 { out.append(String(first)) }
    if let n = Host.current().localizedName, n.count > 2 { out.append(n) }
    return out
}

func cliTimelineSuite(binary: String) async {
    print("cli: the timeline — this Mac's history, no VM")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-tl")
    let work = URL(fileURLWithPath: root.path + "-work")
    for u in [root, work] { try? fm.removeItem(at: u); try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
    let h = CLIHarness(binary: binary, store: root)
    h.env["DOZ_TEST_MAC_NAME"] = nil
    h.env["DOZ_TEST_CREDENTIALS"] = "memory"
    h.env["DO_NOT_TRACK"] = "1"
    h.env["DOZ_TEST_MODEL_LIST"] = "offline"
    let store = DozableStore(root: root)
    defer {
        h.run(["rm", "tlbox", "--yes"], timeout: 120)
        h.run(["daemon", "stop"], timeout: 120)
        _ = h.waitFor(30) { !h.hostRunning }
        check(!h.hostRunning, "T0 no daemon of this suite left running")
        for u in [root, work] { try? fm.removeItem(at: u) }
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let host = "host:this%20Mac"
    let week = TimelineQuery(scope: host, depth: 1, from: now - 30 * 86_400_000, to: now + 86_400_000, limit: 10_000)
    let qWeek = timelineQueryFile(work, "week.json", week)
    func ids() -> Set<String> { Set((h.json(["timeline", "query", qWeek], TimelineResult.self)?.events ?? []).map(\.id)) }
    func result(_ file: String) -> TimelineResult? { h.json(["timeline", "query", file], TimelineResult.self) }

    // T1. No daemon: the catalogue names this Mac, starts none.
    var r = h.run(["timeline", "catalog", "--json"])
    let cat = try? HostWire.decoder.decode(TimelineCatalog.self, from: r.outData)
    check(r.code == 0 && cat?.hosts == ["this Mac"] && cat?.sources.filter { $0.status == "kept" }.count == 12,
          "T1 catalog with no daemon: \"this Mac\", twelve sources kept (\(cat?.hosts ?? []))")
    check(!h.hostRunning, "T1 …and no daemon was started")
    for n in realMacNames() { check(!r.out.contains(n), "T1 the catalogue never names the Mac's network name") }

    // Seed what existed before: sentinel rows older than every cut in each existing metrics table, and records the
    // history will index (a recent daemon event, a connection with a key's use, a sample — the four new tables).
    let old = Date().addingTimeInterval(-400 * 86_400), recent = Date().addingTimeInterval(-5 * 86_400)
    if let m = try? MetricsStore(url: store.metrics) {
        let run = m.beginRun(.init(kind: "sentinel", appVersion: "0.1.0", build: "0", machine: "m", chip: "c", macOS: "x"), at: old)
        m.record(run: run, action: "sentinel-old-action", sandbox: "gone-vm", image: "lab", startedAt: old, durationMs: 5)
        let s = m.sessionOpened(run: run, sandbox: "gone-vm", image: "lab", session: "sentinel", command: "sh", openedAt: old, openMs: 1)
        m.sessionEnded(s, at: old.addingTimeInterval(60), exitCode: 0)
        m.addNetwork(run: run, sandbox: "gone-vm", minute: Int64(old.timeIntervalSince1970 / 60), allowed: 1, denied: 0, failed: 0, bytesUp: 1, bytesDown: 1)
        let run2 = m.beginRun(.init(kind: "seed", appVersion: "0.1.0", build: "0", machine: "m", chip: "c", macOS: "x"), at: recent)
        m.hostEvent(run: run2, at: recent, kind: "note", sandbox: "gone-vm", summary: "a seeded note", ms: nil, failed: false)
        var c = ConnectionRecord(kind: .tcp, host: "seeded.example.net", port: 22, verdict: .denied, rule: "deny", time: recent)
        c.credentialUse = .rejected
        _ = m.recordConnections(run: run2, sandbox: "gone-vm", [c])
        m.sample(run: run2, sandbox: "gone-vm", minute: Int64(recent.timeIntervalSince1970 / 60), cpuPercent: 3, memoryBytes: 1 << 20, diskBytes: 1 << 20)
        // Today's of each, so every source's newest record is now (a cut counts back from it).
        let today = Date()
        m.hostEvent(run: run2, at: today, kind: "note", sandbox: "gone-vm", summary: "a note of today", ms: nil, failed: false)
        var c2 = ConnectionRecord(kind: .tcp, host: "today.example.net", port: 22, verdict: .denied, rule: "deny", time: today)
        c2.credentialUse = .rejected
        _ = m.recordConnections(run: run2, sandbox: "gone-vm", [c2])
        m.sample(run: run2, sandbox: "gone-vm", minute: Int64(today.timeIntervalSince1970 / 60), cpuPercent: 4, memoryBytes: 1 << 20, diskBytes: 1 << 20)
    }
    let g = GrantStore(store: store)
    try? g.append(GrantLogEntry(at: old, by: "you", action: "granted", subject: "agent:tl/sentinel", perm: "folder.write", scope: "workspace:tl", id: "g-old"))
    try? g.append(GrantLogEntry(at: recent, by: "you", action: "granted", subject: "agent:tl/bot1", perm: "net.open", scope: "workspace:tl", id: "g1"))
    let metricsCounts = { ["events", "sessions", "runs", "network"].map { sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM \($0)") } }
    let grantsSHA = fileSHA(g.logFile)

    // T2. The daemon indexes them; an action, a workspace line and a grant appear with the contract's ids.
    r = h.run(["daemon", "start"], timeout: 60)
    check(r.code == 0, "T2 daemon start")
    try? "the brief".write(to: work.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "new", "tl", "--prompt-file", work.appendingPathComponent("brief.md").path, "--no-room"], timeout: 60)
    check(r.code == 0, "T2 workspace new tl (\(r.code))")
    r = h.run(["create", "tlbox", "--image", "lab"], timeout: 120)
    check(r.code == 0, "T2 create tlbox (an action)")
    var seen = Set<String>()
    _ = h.waitFor(30) {
        seen = ids()
        return seen.contains { $0.hasPrefix("actions/") } && seen.contains { $0.hasPrefix("workspace/tl@") } && seen.contains { $0.hasPrefix("grants/_@") }
            && seen.contains { $0.hasPrefix("daemon/") }
    }
    check(seen.contains { $0.hasPrefix("actions/") }, "T2 an action: actions/<rowid>")
    check(seen.contains { $0.hasPrefix("workspace/tl@") }, "T2 a workspace line: workspace/tl@<created>/<offset>")
    check(seen.contains { $0.hasPrefix("grants/_@") }, "T2 a grant: grants/_@<first line>/<offset>")
    check(seen.contains { $0.hasPrefix("daemon-events/") } && seen.contains { $0.hasPrefix("egress/") } && seen.contains { $0.hasPrefix("keys/") },
          "T2 the daemon's events, a connection and a key's use")
    let weekRes = result(qWeek)
    check(weekRes.map { ($0.events ?? []).allSatisfy { TimelineScope.isScope($0.scope) && $0.scope.hasPrefix(host) } } == true,
          "T2 every event is under host:this%20Mac")
    let weekText = h.run(["timeline", "query", qWeek, "--json"]).out
    check(!weekText.contains("\"path\"") && !weekText.contains("seeded.example.net"), "T2 no path attr; a host only when asked")
    for n in realMacNames() { check(!weekText.contains(n), "T2 no real host name in a result") }

    // T3. A restart keeps the ids and closes the earlier daemon run.
    let before = ids()
    h.run(["daemon", "stop"], timeout: 120)
    _ = h.waitFor(30) { !h.hostRunning }
    h.run(["daemon", "start"], timeout: 60)
    var after = Set<String>()
    _ = h.waitFor(30) { after = ids(); return after.count > before.count }
    check(before.isSubset(of: after), "T3 a daemon restart keeps every id (\(Array(before.subtracting(after).prefix(3))))")
    let runs = (result(qWeek)?.events ?? []).filter { $0.kind == "daemon.run" }.sorted { $0.t < $1.t }
    check(runs.count >= 2 && runs.dropLast().allSatisfy { $0.open == nil && $0.dur != nil } && runs.last?.open == true,
          "T3 the earlier daemon.run spans are closed, the current one open (\(runs.count))")

    // T4. The live feed: a new action arrives as a batch.
    let tailQ = timelineQueryFile(work, "tail.json", TimelineQuery(scope: host, depth: 1, from: now, to: now + 86_400_000))
    let tail = h.process(["timeline", "tail", tailQ, "--json"])
    let tailOut = Pipe()
    tail.standardOutput = tailOut
    tail.standardError = FileHandle.nullDevice
    try? tail.run()
    sleep(2)
    h.run(["rename", "tlbox", "tlbox2"], timeout: 60)
    h.run(["rename", "tlbox2", "tlbox"], timeout: 60)
    sleep(4)
    tail.terminate(); tail.waitUntilExit()
    let tailText = String(decoding: tailOut.fileHandleForReading.availableData, as: UTF8.self)
    check(tailText.contains("\"type\":\"batch\"") && tailText.contains("rename"), "T4 tail: a batch with the rename (\(tailText.count) bytes)")

    // T5. Retention: settings, a clock moved ahead, a dry run, a real prune — only what the history added goes.
    h.run(["config", "set", "timeline.daemon_events", "1/1/1/1"])
    h.run(["config", "set", "timeline.egress", "1/1/1/1"])
    h.run(["config", "set", "timeline.keys", "1/1/1/1"])
    h.run(["config", "set", "timeline.resources", "1/1/1/1"])
    h.run(["config", "set", "timeline.actions", "1/1/1/1"])
    var rep = h.json(["timeline", "retention"], TimelineRetentionReport.self)
    check(rep?.sources.first { $0.source == "egress" }.map { $0.retention.setBy == "user" && $0.retention.retention.events == 1 } == true,
          "T5 retention: the egress setting is the user's, 1 day")
    let real = h.json(["timeline", "prune", "--dry-run"], TimelineRetentionReport.self)
    h.env["DOZ_TEST_TIMELINE_NOW"] = "+400d"
    let ahead = h.json(["timeline", "prune", "--dry-run"], TimelineRetentionReport.self)
    h.env["DOZ_TEST_TIMELINE_NOW"] = nil
    func removed(_ r: TimelineRetentionReport?, _ s: String) -> [String: Int] { r?.sources.first { $0.source == s }?.removed ?? [:] }
    check((removed(real, "daemon-events")["host_events rows"] ?? 0) >= 1 && (removed(real, "egress")["egress rows"] ?? 0) >= 1,
          "T5 the dry run: the seeded daemon event and connection would go (\(removed(real, "daemon-events")), \(removed(real, "egress")))")
    check(ahead.map { a in TimelineSources.kept.allSatisfy { removed(a, $0.name) == removed(real, $0.name) } } == true,
          "T5 a clock 400 days ahead (DOZ_TEST_TIMELINE_NOW): the dry run removes nothing more")
    check(sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM host_events WHERE summary = 'a seeded note'") == 1, "T5 the dry run removed nothing")
    rep = h.json(["timeline", "prune"], TimelineRetentionReport.self)
    check(rep?.pruned == true, "T5 prune")
    check(sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM host_events WHERE summary = 'a seeded note'") == 0
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM egress WHERE host = 'seeded.example.net'") == 0
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM key_use WHERE sandbox = 'gone-vm'") == 1
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM samples WHERE sandbox = 'gone-vm'") == 1
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM host_events WHERE summary = 'a note of today'") == 1,
          "T5 the four new tables' old rows went, today's stayed")
    check(metricsCounts().enumerated().allSatisfy { $0.element >= 1 } && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM events WHERE action = 'sentinel-old-action'") == 1
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM sessions WHERE session = 'sentinel'") == 1
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM runs WHERE kind = 'sentinel'") == 1
          && sqliteCount(store.metrics.path, "SELECT COUNT(*) FROM network WHERE sandbox = 'gone-vm'") == 1,
          "T5 the sentinel rows of events, sessions, runs and network (400 days old) remain")
    check(fileSHA(g.logFile) == grantsSHA, "T5 the grants log is byte for byte the same (its 400-day-old line remains)")
    r = h.run(["workspace", "log", "tl"])
    check(r.code == 0 && r.out.contains("created"), "T5 doz workspace log still answers")
    check(h.run(["workspace", "show", "tl"]).code == 0, "T5 doz workspace show still answers")

    // T6. A rebuild gives the same ids; the file deleted is made again.
    let beforeRebuild = ids()
    r = h.run(["timeline", "rebuild", "--json"], timeout: 120)
    check(r.code == 0, "T6 rebuild")
    let afterRebuild = ids()
    check(beforeRebuild == afterRebuild, "T6 the same ids after a rebuild (\(Array(beforeRebuild.symmetricDifference(afterRebuild).prefix(3))))")
    let tl = TimelineStore.url(store).path
    for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tl + s) }
    h.run(["rename", "tlbox", "tlbox3"], timeout: 60)
    var remade = Set<String>()
    _ = h.waitFor(40) { remade = ids(); return remade.contains { $0.hasPrefix("workspace/tl@") } && remade.contains { $0.hasPrefix("actions/") } }
    check(fm.fileExists(atPath: tl) && remade.contains { $0.hasPrefix("workspace/tl@") }, "T6 the history file deleted is made again from the records")
    h.run(["rename", "tlbox3", "tlbox"], timeout: 60)
    var st = stat()
    check(lstat(tl, &st) == 0 && st.st_mode & 0o777 == 0o600, "T6 timeline.sqlite is 0600")

    // T7. With the daemon stopped the CLI answers and starts none.
    h.run(["daemon", "stop"], timeout: 120)
    _ = h.waitFor(30) { !h.hostRunning }
    let offline = result(qWeek)
    check(offline != nil && (offline?.total ?? 0) > 0, "T7 query with the daemon stopped answers in-process (\(offline?.total ?? 0) events)")
    check(h.run(["timeline", "catalog"]).code == 0 && h.run(["timeline", "retention"]).code == 0, "T7 catalog and retention too")
    r = h.run(["timeline", "rebuild"])
    check(r.code != 0, "T7 rebuild needs the daemon")
    check(!h.hostRunning, "T7 …and none was started")
    info("timeline.sqlite after the rows: \(DozableImages.formatBytes(Int64(((try? fm.attributesOfItem(atPath: tl))?[.size] as? Int) ?? 0)))")
}

func cliTimelineVMSuite(binary: String) async {
    print("cli: the timeline with a lab VM — a connection, samples, a key's use")
    let h = onboardingHarness(binary, "tlvm", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let fm = FileManager.default
    h.env["DOZ_TEST_MAC_NAME"] = nil
    h.env["DOZ_TEST_CREDENTIALS"] = "memory"
    h.env["DO_NOT_TRACK"] = "1"
    h.env["DOZ_TIMELINE_SAMPLE_SECONDS"] = "10"
    let work = URL(fileURLWithPath: h.store.path + "-work")
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer {
        h.run(["rm", "tlvm", "--yes"], timeout: 300)
        h.run(["daemon", "stop"], timeout: 300)
        _ = h.waitFor(60) { !h.hostRunning }
        check(!h.hostRunning, "V0 no daemon of this suite left running")
        try? fm.removeItem(at: h.store)
        try? fm.removeItem(at: work)
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let host = "host:this%20Mac"
    var r = h.run(["create", "tlvm", "--image", "lab"], timeout: 600)
    check(r.code == 0, "V1 create tlvm (lab)")
    r = h.run(["start", "tlvm"], timeout: 600)
    check(r.code == 0, "V1 start tlvm")
    // A denied connection: its host is kept only as a sensitive attr.
    _ = h.run(["exec", "tlvm", "--", "sh", "-c", "wget -q -T 5 -O /dev/null http://blocked-tl.invalid/a/path?q=1 || true"], timeout: 120)
    // A fake key's placeholder refused over plain HTTP: a key's use, refused.
    let fake = "sk-ant-FAKE-doz-timeline-0000"
    r = h.run(["key", "set", "tlvm", "--anthropic"], stdin: Data((fake + "\n").utf8))
    check(r.code == 0, "V2 key set tlvm --anthropic < stdin (a fake key)")
    _ = h.json(["net", "policy", "tlvm", "--allow", "example.com"], NetworkPolicy.self)
    _ = h.run(["exec", "tlvm", "--", "sh", "-c", "wget -q -T 5 -O /dev/null --header \"x-api-key: $ANTHROPIC_API_KEY\" http://example.com/ || true"], timeout: 120)
    let all = TimelineQuery(scope: host, depth: 2, from: now - 3_600_000, to: now + 86_400_000, limit: 10_000)
    let qAll = timelineQueryFile(work, "all.json", all)
    var res: TimelineResult?
    _ = h.waitFor(60) {
        res = h.json(["timeline", "query", qAll], TimelineResult.self)
        return (res?.events ?? []).contains { $0.source == "egress" } && (res?.events ?? []).contains { $0.kind == "key.use" }
    }
    let egress = (res?.events ?? []).filter { $0.source == "egress" }
    check(!egress.isEmpty, "V1 a connection is in the history (\(egress.count))")
    check(egress.allSatisfy { $0.attrs["dest"] == nil && !$0.summary.contains("blocked-tl") }, "V1 …its host neither an attr nor in the summary")
    let text = h.run(["timeline", "query", qAll, "--json"]).out
    check(!text.contains("blocked-tl") && !text.contains("/a/path") && !text.contains("q=1"), "V1 no host, path or query string in the answer")
    let asked = TimelineQuery(scope: host, depth: 2, from: now - 3_600_000, to: now + 86_400_000,
                              where: TimelineSearchAst(all: [TimelineAstTerm(any: [.attr(key: "dest", value: "blocked-tl.invalid")])]))
    let askedRes = h.json(["timeline", "query", timelineQueryFile(work, "asked.json", asked)], TimelineResult.self)
    check(askedRes?.events?.contains { $0.attrs["dest"] == .string("blocked-tl.invalid") } == true, "V1 attr.dest: finds it, the host shown")
    let byText = TimelineQuery(scope: host, depth: 2, from: now - 3_600_000, to: now + 86_400_000,
                               where: TimelineSearchAst(all: [TimelineAstTerm(any: [.text("blocked-tl")])]))
    check(h.json(["timeline", "query", timelineQueryFile(work, "text.json", byText)], TimelineResult.self)?.total == 0, "V1 free text never finds a host")
    let key = (res?.events ?? []).first { $0.kind == "key.use" }
    check(key?.attrs["key"] == .string("anthropic") && key?.attrs["ok"] == .bool(false) && !text.contains(fake), "V2 key.use: the anthropic key, refused, its value nowhere")
    // Samples: two minutes' worth, each within its budget.
    var mem = 0
    _ = h.waitFor(150) {
        let m = h.json(["timeline", "query", qAll], TimelineResult.self)?.metrics ?? []
        mem = Set(m.filter { $0.series == "memory" }.map(\.t)).count
        return mem >= 2
    }
    check(mem >= 2, "V3 samples after two intervals (\(mem) minutes of memory)")
    let rep = h.json(["timeline", "retention"], TimelineRetentionReport.self)
    let cost = rep?.sampler
    check((cost?.samples ?? 0) >= 2 && (cost?.maxMicros ?? 9e9) < 2000, "V3 a sample costs under 2 ms (max \(Int(cost?.maxMicros ?? -1)) µs, mean \(Int(cost?.meanMicros ?? -1)) µs, \(cost?.samples ?? 0) samples; the helper found in \(Int(cost?.maxSearchMicros ?? -1)) µs)")
    info("sampler: \(cost.map { "\($0.samples) samples, mean \(Int($0.meanMicros)) µs, max \(Int($0.maxMicros)) µs, \($0.searches) helper searches (max \(Int($0.maxSearchMicros)) µs)" } ?? "—")")
    let cpu = (h.json(["timeline", "query", qAll], TimelineResult.self)?.metrics ?? []).filter { $0.series == "cpu" }
    check(!cpu.isEmpty, "V3 CPU from the VM helper (\(cpu.count) points)")
}
