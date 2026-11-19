import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-bots` (`doz-vmtest cli-bots --doz PATH`): Agents / Bots through the real signed doz, its daemon and the
// chat server it runs — no VM, no session started, a store of its own (/tmp/dzo-PID-bots), settings beside it, the memory
// keychain (DOZ_TEST_CREDENTIALS=memory: a held bot's token lives in the daemon's memory, never the login keychain), a
// scratch Claude Code sessions folder, a FAKE claude first on the PATH, ports from freePort(). Token files are written
// outside the store, so the leak sweep can read every file of it. Every process it stops is one it started. The rows:
//
//   1. bot ls with no daemon: answered, and no daemon starts
//   2. chat on; bot new mira --agent claude-code --isolation fenced --deliver inbox: made, with the note that a fenced bot
//      polls; bot ls and chat who list mira (claude-session · bot; --json bot: true)
//   3. the leak sweep: no dzc_ under the store or the settings, in daemon.log or server.log, in any --json, in sampled ps
//   4. bot ls / bot show with the daemon stopped: answered, and none starts
//   5. refusals — a bad name, an existing participant (names adopt), an unknown agent: bots.json unchanged
//   6. bot new far --agent codex --isolation elsewhere --to-file F: 0600; its token answers /agent/receive and sends one
//      message into a room
//   7. bot token far --new --to-file F2: the old token 401, the new one 200
//   8. bot retire far --yes: gone from chat who and bot ls, listed by --retired; its token 401; chat read shows its message
//      as far; chat add far and bot new far exit 4
//   9. bot token mira --new: only a fingerprint; mira's hash changes; the leak sweep again
//  10. adopt: chat add olda --to-file F3; bot adopt olda with no terminal and no --yes exits 64, nothing changed; with --yes
//      "token is replaced", the old token 401, chat who marks a bot
//  11. the guards: chat remove / token / set on mira refused with the doz bot command; a plain participant still removable
//  12. bot set mira --deliver poll --model M: chat who says polls; the hash unchanged; an unknown field kept; 0700/0600;
//      bot set mira --instructions-file F, then bot show mira --instructions prints the text (--json: instructionsText)
//  13. bot retire mira --yes: its hash gone from tokens.json; bot show --json says token.keeper none
func cliBotsSuite(binary: String) async {
    print("cli: Agents / Bots — no VM")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-bots")
    let xdg = URL(fileURLWithPath: root.path + "-xdg")
    let outside = URL(fileURLWithPath: root.path + "-tokens")
    let sessions = URL(fileURLWithPath: root.path + "-sessions")
    for u in [root, xdg, outside, sessions] { try? fm.removeItem(at: u) }
    for u in [root, outside, sessions] { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
    let h = CLIHarness(binary: binary, store: root)
    h.env["XDG_CONFIG_HOME"] = xdg.path
    h.env["DOZ_TEST_CREDENTIALS"] = "memory"
    h.env["DOZ_TEST_CLAUDE_SESSIONS"] = sessions.path
    let fakeBin = root.appendingPathComponent("bin")
    try? fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try? "#!/bin/sh\necho fake-claude\nexec sleep 600\n".write(to: fakeBin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(fakeBin.appendingPathComponent("claude").path, 0o755)
    h.env["DOZ_TEST_MAC_PATH"] = fakeBin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    let store = DozableStore(root: root)
    let paths = ChatPaths(store: store)
    let bots = BotStore(store: store)

    func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }
    func sh(_ argv: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
    func serversOfStore() -> [Int32] {
        sh(["/bin/ps", "-axo", "pid=,command="]).split(separator: "\n").compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.contains("chat serve"), t.contains(paths.config) else { return nil }
            return Int32(t.split(separator: " ").first ?? "")
        }
    }
    func sha(_ path: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: path))).map(WorkspaceStore.sha256) ?? "" }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func token(_ f: String) -> String { text(f).trimmingCharacters(in: .whitespacesAndNewlines) }
    func hash(_ n: String) -> String? { (try? ChatTokenHashes.load(paths))?.sha256[n] }
    func stopDaemon() {
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
    }
    var page = 0
    func code(_ t: String) -> String {
        sh(["/usr/bin/curl", "-s", "-m", "15", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Authorization: Bearer \(t)", "http://127.0.0.1:\(page)/agent/receive"])
    }
    /// Every --json answer this suite read, for the leak sweep.
    var jsonSeen: [String] = []
    func json(_ args: [String]) -> CLIRun {
        let r = h.run(args + ["--json"], timeout: 60)
        jsonSeen.append(r.out)
        return r
    }
    /// Where a token could leak: every file under the store and the settings (bytes), the daemon's and the server's logs,
    /// every --json read, and the process list now.
    func leaks(_ secrets: [String]) -> [String] {
        var out: [String] = []
        let needles = secrets.map { Data($0.utf8) }
        for base in [root, xdg] {
            for f in (try? fm.subpathsOfDirectory(atPath: base.path)) ?? [] {
                let p = base.path + "/" + f
                var dir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue, let d = fm.contents(atPath: p) else { continue }
                if needles.contains(where: { d.range(of: $0) != nil }) { out.append(DisplayPath.tilde(p)) }
            }
        }
        for (n, t) in [("daemon.log", text(store.logFile.path)), ("server.log", text(paths.serverLog)), ("--json", jsonSeen.joined()), ("ps", psArgs())]
            where secrets.contains(where: { t.contains($0) }) { out.append(n) }
        return out
    }

    defer {
        h.run(["chat", "off"], timeout: 30)
        stopDaemon()
        for p in serversOfStore() { kill(p, SIGKILL) }
        check(serversOfStore().isEmpty && !h.hostRunning, "bots: no daemon or chat server of this suite left running")
        for u in [root, xdg, outside, sessions] { try? fm.removeItem(at: u) }
    }

    // 1. ls with no daemon
    var r = h.run(["bot", "ls"])
    check(r.code == 0 && r.out.contains("Agents / Bots: none yet"), "1 bot ls with nothing: answered (\(r.code))")
    check(!h.hostRunning, "1 …and no daemon started")
    r = h.run(["bot", "--help"])
    check(["new", "ls", "show", "set", "retire", "adopt", "token"].allSatisfy { r.out.contains("  \($0)") }, "1 doz bot --help lists every command")

    // 2. chat on; a fenced Claude Code bot delivered to by inbox
    page = freePort()
    h.run(["config", "set", "chat.page_port", String(page)])
    h.run(["config", "set", "chat.line_port", String(freePort())])
    r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "2 chat on (\(r.code))")
    r = h.run(["bot", "new", "mira", "--agent", "claude-code", "--isolation", "fenced", "--deliver", "inbox"], timeout: 60)
    check(r.code == 0 && r.out.contains("Made the Agent / Bot mira") && r.out.contains("dozchat") && r.out.contains("held by Dozable · fp"),
          "2 bot new mira (fenced, inbox): made, the note says it polls, its token held (\(r.code): \(r.err.prefix(200)))")
    check(hash("mira") != nil, "2 …its hash is in tokens.json")
    r = h.run(["bot", "ls"])
    check(r.out.contains("mira") && r.out.contains("claude-code") && r.out.contains("fenced") && r.out.contains("inbox"), "2 bot ls lists mira")
    r = h.run(["chat", "who"])
    check(r.out.split(separator: "\n").contains { $0.hasPrefix("mira") && $0.contains("claude-session · bot") }, "2 chat who lists mira as claude-session · bot")
    r = json(["chat", "who"])
    let who = (try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]
    check(who?.first { $0["name"] as? String == "mira" }?["bot"] as? Bool == true, "2 chat who --json: mira has bot: true")
    check(who?.first { $0["name"] as? String == "ada" }?["bot"] == nil, "2 …and you have no bot field")

    // 3. the leak sweep (the token is made in the daemon and never leaves it: only its fixed prefix can be looked for)
    _ = json(["bot", "show", "mira"]); _ = json(["bot", "ls"]); _ = json(["daemon", "status"]); _ = json(["chat", "status"])
    var found = leaks(["dzc_"])
    check(found.isEmpty, "3 no token under the store or the settings, in daemon.log, server.log, any --json or ps\(found.isEmpty ? "" : ": " + found.joined(separator: ", "))")
    check(text(store.logFile.path).contains("bot mira: made (fenced, inbox), token fp "), "3 daemon.log says made, with the fingerprint only")

    // 4. looking with the daemon stopped
    stopDaemon()
    r = h.run(["bot", "ls"])
    check(r.code == 0 && r.out.contains("mira"), "4 bot ls with no daemon (\(r.code))")
    r = h.run(["bot", "show", "mira"])
    check(r.code == 0 && r.out.hasPrefix("mira — claude-code") && r.out.contains("held by Dozable"), "4 bot show with no daemon (\(r.code))")
    check(!h.hostRunning, "4 …and none started")

    // 5. refusals leave bots.json as it was
    let tf3 = outside.appendingPathComponent("plain.token").path
    r = h.run(["chat", "add", "plain", "--to-file", tf3], timeout: 60)
    check(r.code == 0, "5 chat add plain (\(r.code))")
    let botsSHA = sha(bots.file)
    r = h.run(["bot", "new", "Bad_Name", "--agent", "codex"])
    check(r.code == 64, "5 a bad name: exit 64 (\(r.code))")
    r = h.run(["bot", "new", "plain", "--agent", "codex"], timeout: 60)
    check(r.code == 4 && r.err.contains("doz bot adopt plain"), "5 an existing participant: exit 4, names adopt (\(r.code))")
    r = h.run(["bot", "new", "nova", "--agent", "no-such-agent-x"], timeout: 60)
    check(r.code == 2, "5 an unknown agent: exit 2 (\(r.code))")
    check(sha(bots.file) == botsSHA, "5 bots.json unchanged")

    // 6. a bot elsewhere: its token shown once, in a new file
    let tf = outside.appendingPathComponent("far.token").path
    r = h.run(["bot", "new", "far", "--agent", "codex", "--isolation", "elsewhere"], timeout: 60)
    check(r.code == 64 && !bots.readOrEmpty().bots.contains { $0.name == "far" }, "6 elsewhere with no terminal and no --to-file: refused, nothing made (\(r.code))")
    r = h.run(["bot", "new", "far", "--agent", "codex", "--isolation", "elsewhere", "--to-file", tf], timeout: 60)
    let farToken = token(tf)
    check(r.code == 0 && farToken.hasPrefix("dzc_") && mode(tf) == 0o600, "6 bot new far --isolation elsewhere --to-file: the file 0600 (\(r.code))")
    check(!r.out.contains(farToken) && r.out.contains("held elsewhere"), "6 …the token is not printed")
    check(code(farToken) == "200", "6 its token answers /agent/receive")
    h.run(["chat", "room", "room1", "@far"], timeout: 30)
    let sent = sh(["/usr/bin/curl", "-s", "-m", "15", "-H", "Authorization: Bearer \(farToken)", "-H", "Content-Type: application/json",
                   "-d", #"{"room":"room1","message":{"content":"hello from far"}}"#, "http://127.0.0.1:\(page)/agent/send"])
    check(sent.contains("\"state\""), "6 far sends one message into room1 (\(sent.prefix(100)))")

    // 7. a new token for far
    let tf2 = outside.appendingPathComponent("far2.token").path
    r = h.run(["bot", "token", "far", "--new", "--to-file", tf2], timeout: 60)
    let farToken2 = token(tf2)
    check(r.code == 0 && farToken2.hasPrefix("dzc_") && farToken2 != farToken, "7 bot token far --new --to-file (\(r.code))")
    check(code(farToken) == "401" && code(farToken2) == "200", "7 the old token 401, the new one 200")

    // 8. retire far
    r = h.run(["bot", "retire", "far"], timeout: 60)
    check(r.code == 64, "8 retire with no terminal and no --yes: exit 64 (\(r.code))")
    r = h.run(["bot", "retire", "far", "--yes"], timeout: 60)
    check(r.code == 0, "8 bot retire far --yes (\(r.code))")
    check(!h.run(["chat", "who"]).out.contains("far "), "8 gone from chat who")
    check(!h.run(["bot", "ls"]).out.contains("far"), "8 gone from bot ls")
    check(h.run(["bot", "ls", "--retired"]).out.contains("far"), "8 listed by bot ls --retired")
    check(code(farToken2) == "401", "8 its token is refused")
    check(h.run(["chat", "read", "room1"]).out.contains("far: hello from far"), "8 chat read shows its message as far")
    r = h.run(["chat", "add", "far", "--to-file", outside.appendingPathComponent("x.token").path], timeout: 60)
    check(r.code == 4 && r.err.contains("far was a bot, retired") && !fm.fileExists(atPath: outside.appendingPathComponent("x.token").path),
          "8 chat add far: exit 4, the name stays with its messages (\(r.code))")
    r = h.run(["bot", "new", "far", "--agent", "codex"], timeout: 60)
    check(r.code == 4, "8 bot new far: exit 4 (\(r.code))")

    // 9. a new token for mira: never shown
    let miraHash = hash("mira")
    r = h.run(["bot", "token", "mira", "--new"], timeout: 60)
    check(r.code == 0 && r.out.contains("fp ") && !r.out.contains("dzc_"), "9 bot token mira --new: only a fingerprint (\(r.code))")
    check(hash("mira") != nil && hash("mira") != miraHash, "9 mira's hash changed")
    r = h.run(["bot", "token", "mira"])
    check(r.code == 0 && r.out.contains("held by Dozable"), "9 bot token mira (no --new) says where it is")
    found = leaks(["dzc_"])
    check(found.isEmpty, "9 the leak sweep again\(found.isEmpty ? "" : ": " + found.joined(separator: ", "))")

    // 10. adopt
    let tfa = outside.appendingPathComponent("olda.token").path
    r = h.run(["chat", "add", "olda", "--to-file", tfa], timeout: 60)
    let oldaToken = token(tfa)
    check(r.code == 0 && code(oldaToken) == "200", "10 chat add olda (\(r.code))")
    let before10 = (sha(bots.file), sha(paths.tokens))
    r = h.run(["bot", "adopt", "olda", "--agent", "codex"], timeout: 60)
    check(r.code == 64 && sha(bots.file) == before10.0 && sha(paths.tokens) == before10.1 && code(oldaToken) == "200",
          "10 adopt with no terminal and no --yes: exit 64, nothing changed (\(r.code))")
    r = h.run(["bot", "adopt", "olda", "--agent", "codex", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("token is replaced"), "10 adopt --yes: its token is replaced (\(r.code): \(r.out.prefix(120)))")
    check(code(oldaToken) == "401", "10 the old token is refused")
    check(h.run(["chat", "who"]).out.split(separator: "\n").contains { $0.hasPrefix("olda") && $0.contains("agent · bot") }, "10 chat who marks olda a bot")

    // 11. the guards
    r = h.run(["chat", "remove", "mira"], timeout: 60)
    check(r.code == 64 && r.err.contains("doz bot retire mira"), "11 chat remove mira: refused, points to doz bot retire (\(r.code))")
    let tx = outside.appendingPathComponent("guard.token").path
    r = h.run(["chat", "token", "mira", "--new", "--to-file", tx], timeout: 60)
    check(r.code == 64 && r.err.contains("doz bot token mira --new") && !fm.fileExists(atPath: tx), "11 chat token mira: refused, points to doz bot token (\(r.code))")
    r = h.run(["chat", "set", "mira", "--deliver", "poll"], timeout: 60)
    check(r.code == 64 && r.err.contains("doz bot set mira"), "11 chat set mira: refused, points to doz bot set (\(r.code))")
    r = h.run(["chat", "remove", "plain"], timeout: 60)
    check(r.code == 0, "11 a plain participant is still removable (\(r.code))")

    // 12. set: delivery and model; the token kept; an unknown field kept; modes
    if var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: bots.file)))) as? [String: Any],
       var list = obj["bots"] as? [[String: Any]], let i = list.firstIndex(where: { $0["name"] as? String == "mira" }) {
        list[i]["later"] = ["kept": true]
        obj["bots"] = list
        try? JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: bots.file))
    }
    let hash12 = hash("mira")
    r = h.run(["bot", "set", "mira", "--deliver", "poll", "--model", "sonnet"], timeout: 60)
    check(r.code == 0, "12 bot set mira --deliver poll --model sonnet (\(r.code))")
    check(h.run(["chat", "who"]).out.split(separator: "\n").contains { $0.hasPrefix("mira") && $0.contains("polls") }, "12 chat who says mira polls")
    check(hash("mira") == hash12, "12 its token's hash is unchanged")
    let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: bots.file)))) as? [String: Any]
    let mira12 = (after?["bots"] as? [[String: Any]])?.first { $0["name"] as? String == "mira" }
    check((mira12?["later"] as? [String: Any])?["kept"] as? Bool == true && mira12?["model"] as? String == "sonnet", "12 an unknown field survives the set")
    check(mode(bots.root) == 0o700 && mode(bots.folder("mira")) == 0o700, "12 the folders are 0700")
    check([bots.file, bots.folder("mira") + "/notes.md"].allSatisfy { mode($0) == 0o600 }, "12 the files are 0600")
    // …and its instructions: bot show --instructions prints the text as given; --json carries instructionsText; plain show
    // never does.
    let words = "Answer in the room.\nKeep it short.\n"
    let instr = outside.appendingPathComponent("mira-instructions.md").path
    try? Data(words.utf8).write(to: URL(fileURLWithPath: instr))
    r = h.run(["bot", "set", "mira", "--instructions-file", instr], timeout: 60)
    check(r.code == 0, "12 bot set mira --instructions-file F (\(r.code))")
    r = h.run(["bot", "show", "mira", "--instructions"], timeout: 60)
    check(r.code == 0 && r.out == words, "12 bot show mira --instructions prints the text (\(r.code) \(r.out.prefix(80)))")
    r = json(["bot", "show", "mira", "--instructions"])
    let withText = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(withText?["instructionsText"] as? String == words, "12 …with --json: instructionsText")
    r = json(["bot", "show", "mira"])
    check(!r.out.contains("instructionsText"), "12 plain bot show --json carries no instructionsText")

    // 13. retire mira
    r = h.run(["bot", "retire", "mira", "--yes"], timeout: 60)
    check(r.code == 0 && hash("mira") == nil, "13 bot retire mira --yes: its hash is gone from tokens.json (\(r.code))")
    r = json(["bot", "show", "mira"])
    let shown = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check((shown?["token"] as? [String: Any])?["keeper"] as? String == "none", "13 bot show --json: token.keeper none")
    found = leaks(["dzc_", farToken, farToken2, oldaToken])
    check(found.isEmpty, "13 no token anywhere, the given ones included\(found.isEmpty ? "" : ": " + found.joined(separator: ", "))")
}
