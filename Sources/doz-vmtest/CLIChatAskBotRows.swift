// `make test-cli-chat`, rows D3, D7–D9 and D13: asks for bots, with `dozchat-mac` (beside doz: `make cli`) and the bot's own
// token in CHAT_TOKEN_FILE, against the suite's chat server (CHAT_URL names its port; no proxy). After D1–D12.
//
//  D3. a bot asks with dozchat; doz chat read shows "ask #N · open" above its text
//  D7. dozchat decide with the decider role → decided; without it → exit 3
//  D8. the asking bot withdraws its own; another bot's withdraw is refused (exit 3)
//  D9. doz chat ask --wait exits 0 (decided) and 11 (expired); dozchat ask-show --wait exits 0, 10, 11 and 12
//  D13. the token in no argv, ps line, output or log
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliChatAskBotRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, sh: (_ argv: [String], _ stdin: Data?) -> (Int32, String)) {
    let dozchat = URL(fileURLWithPath: h.binary).deletingLastPathComponent().appendingPathComponent("dozchat-mac").path
    guard FileManager.default.isExecutableFile(atPath: dozchat) else { check(false, "D3 dozchat-mac beside doz (make cli)"); return }
    func tokenFile(_ name: String) -> String { root.appendingPathComponent("\(name).token").path }
    func token(_ name: String) -> String {
        ((try? String(contentsOfFile: tokenFile(name), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var outputs = ""
    var argvs: [[String]] = []
    /// dozchat as `bot`: its exit code and what it printed (stdout, then stderr).
    func bot(_ name: String, _ args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dozchat)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": tokenFile(name)]
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        try? p.run()
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        outputs += out + err
        argvs.append(args)
        return (p.terminationStatus, out, err)
    }
    /// The number of the ask a dozchat ask answered (0: none).
    func number(_ out: String) -> Int {
        guard let id = (try? ChatJSON.parse(Array(out.utf8)))?.field("msg_id")?.stringValue else { return 0 }
        let (_, show, _) = bot("decbot", ["ask-show", "askroom", id])
        return Int(((try? (try? ChatJSON.parse(Array(show.utf8)))?.field("ask")?.field("number")?.goInt("number")) ?? nil) ?? 0)
    }

    // D3. a bot asks; a person reads it as an ask
    var (code, out, err) = bot("plainbot", ["ask", "askroom", "Deploy", "now?", "--option", "go=Go", "--option", "wait=Wait", "--reason", "the release is ready"])
    check(code == 0 && out.contains("\"state\":\"queued\""), "D3 dozchat ask (\(code) \(out.prefix(120)) \(err.prefix(160)))")
    var n = number(out)
    let read = h.run(["chat", "read", "askroom", "--last", "3"])
    check(n > 0 && read.out.contains("plainbot: ask #\(n) · open\n") && read.out.contains("Deploy now?"), "D3 doz chat read shows ask #\(n) · open (\(read.out.suffix(300)))")

    // D7. deciding with the role, and without
    (code, out, err) = bot("askbot", ["decide", "askroom", "#\(n)", "go"])
    check(code == 3 && err.contains("askbot does not have the decider role"), "D7 without the role: exit 3 (\(code) \(err.prefix(200)))")
    _ = bot("plainbot", ["withdraw", "askroom", "#\(n)"])
    (code, out, err) = bot("plainbot", ["ask", "askroom", "Roll back?", "--option", "yes=Yes", "--decider", "decbot"])
    n = number(out)
    (code, out, err) = bot("decbot", ["decide", "askroom", "\(n)", "yes", "it", "is", "safe"])
    check(code == 0 && out.contains("\"state\":\"decided\""), "D7 decbot with the role decides (\(code) \(out.prefix(120)) \(err.prefix(160)))")
    (code, out, _) = bot("decbot", ["ask-show", "askroom", "#\(n)"])
    check(code == 0 && out.contains("\"decider_role\":true") && out.contains("\"text\":\"it is safe\""), "D7 …ask-show reads it decided by role")

    // D8. withdrawing
    (code, out, err) = bot("plainbot", ["ask", "askroom", "Lunch?", "--decider", "decbot"])
    n = number(out)
    (code, out, err) = bot("askbot", ["withdraw", "askroom", "#\(n)"])
    check(code == 3 && err.contains("only plainbot, who asked it, can withdraw this ask"), "D8 another bot's withdraw: exit 3 (\(code) \(err.prefix(200)))")
    (code, out, err) = bot("plainbot", ["withdraw", "askroom", "#\(n)"])
    check(code == 0 && out.contains("\"state\":\"withdrawn\""), "D8 the asker withdraws its own (\(code) \(out.prefix(120)))")
    (code, _, _) = bot("plainbot", ["ask-show", "askroom", "#\(n)", "--wait", "5"])
    check(code == 12, "D9 ask-show --wait: withdrawn, exit 12 (\(code))")

    // D13. the token in no argv, ps line, output or log (a wait running, then the ask withdrawn)
    (code, out, _) = bot("plainbot", ["ask", "askroom", "Still?", "--decider", "decbot"])
    n = number(out)
    let wait = Process()
    wait.executableURL = URL(fileURLWithPath: dozchat)
    wait.arguments = ["ask-show", "askroom", "#\(n)", "--wait", "20"]
    wait.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": tokenFile("plainbot")]
    wait.standardOutput = FileHandle.nullDevice
    wait.standardError = FileHandle.nullDevice
    try? wait.run()
    usleep(700_000)
    let ps = sh(["/bin/ps", "-axww", "-o", "args="], nil).1
    _ = bot("plainbot", ["withdraw", "askroom", "#\(n)"])
    wait.waitUntilExit()
    check(wait.terminationStatus == 12, "D13 …the waiting ask-show ends when it is withdrawn: exit 12 (\(wait.terminationStatus))")
    let secrets = ["plainbot", "decbot", "askbot"].map(token).filter { !$0.isEmpty }
    let logs = [paths.serverLog].map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }.joined()
    let leaked = secrets.filter { s in ps.contains(s) || outputs.contains(s) || logs.contains(s) || argvs.contains { $0.contains(s) } }
    check(secrets.count == 3 && leaked.isEmpty && ps.contains("ask-show askroom #\(n)"), "D13 the token in no argv, ps line, output or log (\(leaked.count) found)")

    // D9. the waits — decided, then the ones that start a cooldown (declined, expired), each by another asker
    (code, out, _) = bot("plainbot", ["ask", "askroom", "Ship?", "--option", "yes=Yes", "--decider", "decbot"])
    n = number(out)
    _ = bot("decbot", ["decide", "askroom", "#\(n)", "yes"])
    (code, _, _) = bot("plainbot", ["ask-show", "askroom", "#\(n)", "--wait", "5"])
    check(code == 0, "D9 ask-show --wait: decided, exit 0 (\(code))")
    // doz chat ask --wait: the next number decided by decbot two seconds after it is asked.
    let next = n + 1
    let later = Process()
    later.executableURL = URL(fileURLWithPath: "/bin/sh")
    later.arguments = ["-c", "sleep 2; exec \"$0\" decide askroom '#\(next)' mon", dozchat]
    later.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": tokenFile("decbot")]
    later.standardOutput = FileHandle.nullDevice
    later.standardError = FileHandle.nullDevice
    try? later.run()
    var r = h.run(["chat", "ask", "askroom", "Which day?", "--option", "mon=Monday", "--decider", "decbot", "--wait"], timeout: 60)
    later.waitUntilExit()
    check(r.code == 0 && r.out.contains("Asked #\(next)") && r.out.contains("#\(next): A. Monday (decided by decbot)."), "D9 doz chat ask --wait: decided, exit 0 (\(r.code) \(r.out) \(r.err.prefix(160)))")
    r = h.run(["chat", "ask", "askroom", "Quick?", "--decider", "decbot", "--expires", "2s", "--wait"], timeout: 60)
    check(r.code == 11 && r.out.contains("expired: its answer was decline."), "D9 doz chat ask --wait: expired, exit 11 (\(r.code) \(r.out))")
    (code, out, _) = bot("plainbot", ["ask", "askroom", "Ship later?", "--option", "yes=Yes", "--decider", "decbot"])
    n = number(out)
    _ = bot("decbot", ["decide", "askroom", "#\(n)", "--decline", "not", "today"])
    (code, _, _) = bot("plainbot", ["ask-show", "askroom", "#\(n)", "--wait", "5"])
    check(code == 10, "D9 ask-show --wait: declined, exit 10 (\(code))")
    (code, out, _) = bot("decbot", ["ask", "askroom", "Soon?", "--expires-in", "2"])
    n = number(out)
    (code, _, _) = bot("decbot", ["ask-show", "askroom", "#\(n)", "--wait", "10"])
    check(code == 11, "D9 ask-show --wait: expired, exit 11 (\(code))")
}
