import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the permission rows (after the wide views', in the same scratch store): what agents may do, through
// the real doz and its daemon — no VM, the memory keychain, a harmless program on this Mac. `myapp-tests` (no room) has mira as
// its manager (recorded, never started) and bot2, an adopted session on this Mac running `sleep` — a worker by its record.
//
//  P1. the daemon stopped: permissions show (all, a workspace's agent, --roles), why and grant ls answer, and none starts
//  P2. grant bot2 net.allow=allow --in myapp-tests: why says allow (step 2); a log line in grants/log.jsonl and the
//      workspace's log; revoke: ask again, a log line; --until 2h listed with its date; a past --until refused (64)
//  P3. why bot2 folder.read --in myapp-tests: the mockups' five steps exactly, then → ask, mira not a decider
//  P4. bot ceiling otto sudo=never, then grant otto sudo=allow --in myapp-tests: why says never (otto's ceiling)
//  P5. the owner is never gated: before row 12 every permission is set never in this Mac's ceiling and by an everywhere never
//      for every role (cliWorkspaceOwnerUnderNevers) — rows 12–47, L1–L14 and V1–V5 (the managers, worker add and end, the
//      lifecycle) all ran under them, exactly as before; here they are found still in force, then cleared
//  P6. --as myapp-tests/bot2 worker add: refused "would ask; Asks come later", exit 9; nothing made; a permission-decided line
//  P7. a never refused with its reason (exit 9): an unfenced worker (the worker role), a bot made (Dozable's own: another
//      workspace), ls (Dozable's own)
//  P8. grant otto net.allow=allow --in myapp-tests does not reach permb: why there says ask, step 2 none
//  P9. permissions show says not enforced yet — no agent can drive Dozable; --agent's rows each say so
//  P10. the --json leak sweep: every permissions answer parses and carries no token; nor do the grants' files
/// P5's first half, run before row 12: every permission never — this Mac's ceiling, and an everywhere never for every role.
func cliWorkspaceOwnerUnderNevers(_ h: CLIHarness) {
    print("cli: every ceiling at never — the owner's commands below run under them")
    let words = GrantPermissions.ids.map { "\($0)=never" }
    var r = h.run(["permissions", "ceiling", "--mac"] + words, timeout: 60)
    check(r.code == 0, "P5 this Mac's ceiling: every permission never (\(r.code) \(r.err.prefix(200)))")
    // chat.decide is never a grant (deciders are made in chat, by you only): every other permission.
    let grantable = GrantPermissions.ids.filter { !GrantPermissions.ownerOnly.contains($0) }.map { "\($0)=never" }
    for role in ["manager", "worker", "member"] {
        r = h.run(["permissions", "grant", "role:\(role)"] + grantable + ["--everywhere"], timeout: 60)
        check(r.code == 0, "P5 an everywhere never on every permission for every \(role) (\(r.code) \(r.err.prefix(200)))")
    }
}

func cliWorkspacePermissionRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: what agents may do — permissions, grants, ceilings, why")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let grants = GrantStore(store: store)
    let pid = getpid()
    let work = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsp-work")
    try? fm.removeItem(at: work)
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    func stopDaemon() {
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
    }
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func why(_ args: [String]) -> GrantDecision? { h.json(["why"] + args, GrantDecision.self) }
    let brief = root.appendingPathComponent("perm-brief.md").path
    try? "Fix the tests.\n".write(toFile: brief, atomically: true, encoding: .utf8)

    // The fixture: mira (a bot) recorded as the manager, bot2 an adopted session on this Mac.
    h.run(["bot", "new", "mira", "--agent", "claude-code", "--isolation", "fenced"], timeout: 60)
    h.run(["bot", "new", "otto", "--agent", "claude-code", "--isolation", "fenced"], timeout: 60)
    var r = h.run(["workspace", "new", "myapp-tests", "--prompt-file", brief, "--no-room", "--manager", "mira"], timeout: 60)
    check(r.code == 0, "P new myapp-tests --manager mira (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "pbot2", "--folder", work.path, "--", "/bin/sh", "-c", "exec sleep 600"], timeout: 60)
    if r.code == 0 { started.insert("pbot2") }
    check(r.code == 0, "P a harmless session on this Mac, pbot2 (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "adopt", "myapp-tests", "@mac/pbot2", "--as", "bot2"], timeout: 60)
    check(r.code == 0 && (try? ws.read("myapp-tests"))??.agents.contains { $0.name == "bot2" && $0.role == "worker" } == true,
          "P adopt @mac/pbot2 --as bot2: a worker by its record (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "new", "permb", "--prompt-file", brief, "--no-room"], timeout: 60)
    check(r.code == 0, "P new permb (\(r.code))")
    check((try? ws.read("myapp-tests"))??.permissions == nil, "P nothing is written for today's agents: no permissions section")

    // P5. the owner's commands ran under every never; still in force — then cleared for the rows below.
    let mac = h.json(["permissions", "show", "--mac"], PermissionsShown.self)
    check(mac?.ceilings.count == GrantPermissions.ids.count && mac?.ceilings.allSatisfy { $0.answer == "never" } == true
          && mac?.grants.filter { $0.what.hasSuffix("=never") && $0.scope == "everywhere" }.count == (GrantPermissions.ids.count - 1) * 3,
          "P5 rows 12–V5 (worker add and end, the managers, the lifecycle) ran as before under this Mac's ceiling and an everywhere never on everything")
    r = h.run(["permissions", "ceiling", "--mac"] + GrantPermissions.ids.flatMap { ["--clear", $0] }, timeout: 60)
    check(r.code == 0, "P5 this Mac's ceiling cleared (\(r.code))")
    for role in ["manager", "worker", "member"] {
        r = h.run(["permissions", "revoke", "role:\(role)"] + GrantPermissions.ids.filter { !GrantPermissions.ownerOnly.contains($0) } + ["--everywhere"], timeout: 60)
        check(r.code == 0, "P5 every \(role)'s nevers revoked (\(r.code) \(r.err.prefix(160)))")
    }

    // P1. looking never starts the daemon.
    stopDaemon()
    for args in [["permissions", "show"], ["permissions", "show", "myapp-tests", "--agent", "bot2"], ["permissions", "show", "--roles"],
                 ["why", "bot2", "folder.read", "--in", "myapp-tests"], ["grant", "ls", "myapp-tests"], ["permissions", "show", "--bot", "mira"]] {
        r = h.run(args, timeout: 60)
        check(r.code == 0, "P1 \(args.joined(separator: " ")) with the daemon stopped (\(r.code) \(r.err.prefix(160)))")
    }
    check(!h.hostRunning, "P1 …and no daemon started")

    // P2. grant, revoke, --until — each a log line.
    r = h.run(["grant", "bot2", "net.allow=allow", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 0 && r.out.contains("granted myapp-tests/bot2 net.allow=allow in myapp-tests"), "P2 grant bot2 net.allow=allow --in myapp-tests (\(r.code) \(r.out.prefix(160)) \(r.err.prefix(160)))")
    var d = why(["bot2", "net.allow", "--in", "myapp-tests"])
    check(d?.answer == .allow && d?.decidedAt == 2, "P2 why: allow, from the grant (step \(d?.decidedAt ?? 0))")
    var log = grants.log()
    check(log.last?.action == "granted" && log.last?.subject == "agent:myapp-tests/bot2" && log.last?.perm == "net.allow" && log.last?.by == "you",
          "P2 grants/log.jsonl: granted, by you (\(log.last?.action ?? "none"))")
    check(((try? ws.log("myapp-tests")) ?? []).last?.action == "granted", "P2 …and the workspace's log")
    check(mode(ws.folder("myapp-tests") + "/workspace.json") == 0o600 && mode(grants.root) == 0o700 && mode(grants.logFile) == 0o600,
          "P2 the record 0600, grants/ 0700, its log 0600")
    r = h.run(["permissions", "revoke", "bot2", "net.allow", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 0 && r.out.contains("revoked myapp-tests/bot2's net.allow=allow in myapp-tests"), "P2 revoke (\(r.code) \(r.out.prefix(160)))")
    d = why(["bot2", "net.allow", "--in", "myapp-tests"])
    check(d?.answer == .ask && d?.decidedAt == 3, "P2 why: ask again, from the worker role")
    log = grants.log()
    check(log.last?.action == "revoked", "P2 a revoked line (\(log.last?.action ?? "none"))")
    r = h.run(["grant", "bot2", "folder.write=allow", "--in", "myapp-tests", "--until", "2h"], timeout: 60)
    let shown = h.json(["permissions", "show", "myapp-tests"], PermissionsShown.self)
    let until = shown?.grants.first { $0.what == "folder.write=allow" }
    check(r.code == 0 && until?.until != nil && until?.ended == false && log.count + 1 == grants.log().count && grants.log().last?.until != nil,
          "P2 --until 2h: listed with its end, not ended; a log line with it (\(r.code) \(String(describing: until)))")
    let before = text(ws.folder("myapp-tests") + "/workspace.json")
    r = h.run(["grant", "bot2", "folder.write=ask", "--in", "myapp-tests", "--until", "2020-01-01"], timeout: 60)
    check(r.code == 64 && text(ws.folder("myapp-tests") + "/workspace.json") == before, "P2 a past --until: refused, nothing changed (\(r.code))")
    r = h.run(["grant", "bot2", "net.allow=allow", "--in", "myapp-tests", "--everywhere"], timeout: 60)
    check(r.code == 64, "P2 two scopes refused (\(r.code))")
    r = h.run(["grant", "bot2", "teleport=allow", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 64 && r.err.contains("is not a permission") && r.err.contains("workspace.read"), "P2 an unknown permission: refused with the list (\(r.code))")
    r = h.run(["grant", "mira", "owner", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 64, "P2 the owner role refused (\(r.code))")
    r = h.run(["grant", "mira", "admin", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 64 && r.err.contains("everywhere only"), "P2 admin outside everywhere refused (\(r.code))")
    r = h.run(["grant", "otto", "chat.decide=allow", "--everywhere"], timeout: 60)
    check(r.code == 64 && r.err.contains("deciders are made in chat"), "P2 chat.decide refused (\(r.code))")
    r = h.run(["permissions", "revoke", "mira", "manager", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 64 && r.err.contains("myapp-tests's manager") && r.err.contains("change the workspace"), "P2 the record's role is not a grant: refused (\(r.code) \(r.err.prefix(160)))")

    // P3. the mockups' five lines.
    r = h.run(["why", "bot2", "folder.read", "--in", "myapp-tests"], timeout: 60)
    let lines = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    check(r.code == 0 && lines.count >= 7 && Array(lines[1...5]) == [
        "1 any never               none (no ceiling, no never in any scope)",
        "2 permission grants        none (room, workspace, everywhere)",
        "3 roles here               worker (myapp-tests): ask",
        "4 —",
        "5 bot2's ceiling           none set: no cap",
    ], "P3 why bot2 folder.read --in myapp-tests: the five steps exactly (\(r.out.prefix(500)))")
    check(lines.first == "bot2 · folder.read · in myapp-tests" && lines.count > 6 && lines[6].hasPrefix("→ ask · an Ask to ")
          && lines[6].hasSuffix("(owner); mira is not a decider here"), "P3 …and → ask, mira not a decider (\(lines.count > 6 ? lines[6] : "?"))")
    check(h.run(["grant", "why", "bot2", "folder.read", "--in", "myapp-tests"], timeout: 60).out == r.out
          && h.run(["permissions", "why", "bot2", "folder.read", "--in", "myapp-tests"], timeout: 60).out == r.out, "P3 grant why and permissions why say the same")

    // P4. a bot's ceiling beats a grant.
    r = h.run(["bot", "ceiling", "otto", "sudo=never"], timeout: 60)
    check(r.code == 0, "P4 bot ceiling otto sudo=never (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["grant", "otto", "sudo=allow", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 0, "P4 grant otto sudo=allow --in myapp-tests (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["why", "otto", "sudo", "--in", "myapp-tests"], timeout: 60)
    check(r.code == 0 && r.out.contains("→ never · refused: otto's ceiling: sudo=never"), "P4 why otto sudo: never, otto's ceiling (\(r.out.suffix(200)))")

    // P6. a request made as an agent that would ask: refused, nothing made.
    let rec6 = text(ws.folder("myapp-tests") + "/workspace.json")
    let decided = grants.log().filter { $0.action == "permission-decided" }.count
    r = h.run(["worker", "add", "myapp-tests", "--task", "list the files", "--as", "myapp-tests/bot2"], timeout: 60)
    check(r.code == 9 && r.err.contains("worker.start for bot2 in myapp-tests would ask; Asks come later. See: doz why bot2 worker.start --in myapp-tests"),
          "P6 --as myapp-tests/bot2 worker add: would ask, Asks come later, exit 9 (\(r.code) \(r.err.prefix(240)))")
    check(text(ws.folder("myapp-tests") + "/workspace.json") == rec6, "P6 …nothing made")
    let line6 = grants.log().last
    check(grants.log().filter { $0.action == "permission-decided" }.count == decided + 1 && line6?.answer == "ask" && line6?.reason == "refused: Asks come later"
          && line6?.op == "worker-add", "P6 …one permission-decided line: ask, refused (\(line6?.reason ?? "none"))")
    r = h.run(["worker", "add", "myapp-tests", "--task", "x", "--as", "myapp-tests/bot2", "--json"], timeout: 60)
    check(r.code == 9 && r.out.contains("not-permitted"), "P6 …--json: the code not-permitted (\(r.out.prefix(200)))")
    r = h.run(["workspace", "show", "myapp-tests", "--as", "myapp-tests/bot2"], timeout: 60)
    check(r.code == 0, "P6 the same agent may read its workspace (allow) (\(r.code) \(r.err.prefix(160)))")

    // P7. a never, with its reason.
    r = h.run(["worker", "add", "myapp-tests", "--task", "x", "--isolation", "unfenced", "--as", "myapp-tests/bot2"], timeout: 60)
    check(r.code == 9 && r.err.contains("isolation.unfenced for bot2 in myapp-tests is never: the worker role (myapp-tests)"),
          "P7 an unfenced worker: never, the worker role (\(r.code) \(r.err.prefix(240)))")
    r = h.run(["bot", "new", "zed", "--agent", "claude-code", "--as", "myapp-tests/bot2"], timeout: 60)
    check(r.code == 9 && r.err.contains("bot.manage for bot2 in myapp-tests is never: Dozable's own: another workspace") && h.json(["bot", "show", "zed"], BotDetail.self) == nil,
          "P7 bot new: never, Dozable's own — no bot made (\(r.code) \(r.err.prefix(240)))")
    r = h.run(["ls", "--as", "myapp-tests/bot2"], timeout: 60)
    check(r.code == 9 && r.err.contains("ls is Dozable's own: never for an agent"), "P7 ls: Dozable's own (\(r.code) \(r.err.prefix(200)))")
    check(((try? ws.log("myapp-tests")) ?? []).contains { $0.action == "permission-decided" && $0.answer == "never" }, "P7 …in the workspace's log too")

    // P8. a grant in one workspace does not reach another.
    r = h.run(["grant", "otto", "net.allow=allow", "--in", "myapp-tests"], timeout: 60)
    check(why(["otto", "net.allow", "--in", "myapp-tests"])?.answer == .allow, "P8 otto net.allow in myapp-tests: allow (\(r.code))")
    d = why(["otto", "net.allow", "--in", "permb"])
    check(d?.answer == .ask && d?.steps.first { $0.n == 2 }?.found == "none (room, workspace, everywhere)", "P8 …in permb: ask, no grant there")

    // P9. not enforced yet.
    r = h.run(["permissions", "show"], timeout: 60)
    check(r.out.contains("not yet — no agent can drive Dozable"), "P9 permissions show: not enforced yet")
    let agent = h.json(["permissions", "show", "myapp-tests", "--agent", "bot2"], PermissionsShown.self)?.agents.first
    check(agent?.rows.count == GrantPermissions.ids.count && agent?.rows.allSatisfy { $0.enforced == "not yet — no agent can drive Dozable" } == true,
          "P9 --agent bot2: every row says not yet (\(agent?.rows.count ?? 0))")

    // P10. the --json leak sweep.
    var answers = ""
    for args in [["permissions", "show"], ["permissions", "show", "myapp-tests"], ["permissions", "show", "myapp-tests", "--agent", "bot2"],
                 ["permissions", "show", "--bot", "otto"], ["permissions", "show", "--mac"], ["permissions", "show", "--roles"],
                 ["why", "bot2", "folder.read", "--in", "myapp-tests"], ["bot", "ceiling", "otto"], ["grant", "ls"]] {
        r = h.run(args + ["--json"], timeout: 60)
        answers += r.out + r.err
        check(r.code == 0 && (try? JSONSerialization.jsonObject(with: r.outData)) != nil, "P10 \(args.joined(separator: " ")) --json parses (\(r.code))")
    }
    let files = text(grants.file) + text(grants.logFile) + text(ws.folder("myapp-tests") + "/workspace.json") + text(ws.folder("myapp-tests") + "/log.jsonl")
    check(!answers.contains("dzc_") && !answers.contains("doz_cred_") && !files.contains("dzc_"), "P10 no token in any answer or the grants' files")

    h.run(["sessions", "end", "@mac", "pbot2", "--yes"], timeout: 30)
    started.remove("pbot2")
}
