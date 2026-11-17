// `make test-cli-chat`, rows 22–27: `doz chat import` end to end, no VM, in a store of its own (/tmp/dzo-PID-ci), with
// a copy of the reference-built fixture `Tests/DozableChatTests/Fixtures/import1` (neutral names: ada, bot1, bot2):
//
//  22. --dry-run in a fresh store: exit 2 with the commands that add bot1 and bot2; no daemon, no chat folder
//  23. a copy holding secrets (agents.json) is refused, exit 1, nothing written; the copy is never changed
//  24. bot1 and bot2 added; chat on --name ada: the import is refused (exit 6); off: imported as ada, and the
//      first start's own folder is kept aside
//  25. chat on: nobody woken — the suite's listener (bot1's webhook entry) gets no call, bot2's receive is empty, no line
//      was added (the last message is the history's last), room2 archived
//  26. the same copy again: exit 4 (history); --replace: imported, the earlier folder kept aside
//  27. --json carries no token and no secret; doz chat --help lists import
//
// Every daemon and server it starts is stopped at the end; the store is removed.
import Darwin
import DozableChat
import DozableHost
import DozableKit
import Foundation

func cliChatImportRows(binary: String) async {
    print("cli: doz chat import")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-ci")
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let h = CLIHarness(binary: binary, store: root)
    let store = DozableStore(root: root)
    let paths = ChatPaths(store: store)
    defer {
        h.run(["chat", "off"], timeout: 30)
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
        let left = ChatServer.status(dataDir: paths.data, release: "")
        if left.running { kill(Int32(left.pid), SIGKILL) }
        check(!h.hostRunning, "import: no daemon of these rows left running")
        try? fm.removeItem(at: root)
    }
    let fixture = URL(fileURLWithPath: "Tests/DozableChatTests/Fixtures/import1").standardizedFileURL.path
    let copy = root.appendingPathComponent("copy").path
    guard (try? fm.copyItem(atPath: fixture, toPath: copy)) != nil else { check(false, "22 a copy of the import fixture (run from the repository)"); return }
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
    let page = freePort(), line = freePort()
    h.run(["config", "set", "chat.page_port", String(page)])
    h.run(["config", "set", "chat.line_port", String(line)])

    // 22. the dry run
    var r = h.run(["chat", "import", copy, "--dry-run"])
    check(r.code == 2 && r.out.contains("doz chat add bot1 --kind grok-bot --webhook --to-file bot1.token")
          && r.out.contains("doz chat add bot2 --kind claude-session --to-file bot2.token"), "22 --dry-run: exit 2 and the commands that add bot1 and bot2 (\(r.code))")
    check(r.out.contains("room1: 12 messages") && r.out.contains("room2 (archived): 3 messages") && r.out.contains("You are ada in chat — the name the history has."),
          "22 --dry-run: the rooms, their counts, the person")
    check(!h.hostRunning && !fm.fileExists(atPath: paths.folder), "22 …no daemon started, no chat folder made")

    // 23. a copy holding secrets
    let bad = root.appendingPathComponent("bad").path
    try? fm.copyItem(atPath: copy, toPath: bad)
    fm.createFile(atPath: bad + "/agents.json", contents: Data(#"{"participants":null,"tokens":{}}"#.utf8))
    r = h.run(["chat", "import", bad], timeout: 60)
    check(r.code == 1 && r.err.contains("it holds secrets (agents.json)"), "23 a copy holding agents.json is refused, exit 1 (\(r.code))")
    check(!fm.fileExists(atPath: paths.data), "23 …nothing written")

    // 24. the participants first; refused while chat is on; then imported
    let t1 = root.appendingPathComponent("bot1.token").path, t2 = root.appendingPathComponent("bot2.token").path
    r = h.run(["chat", "add", "bot1", "--kind", "grok-bot", "--webhook", "--to-file", t1], timeout: 60)
    let r2 = h.run(["chat", "add", "bot2", "--kind", "claude-session", "--to-file", t2], timeout: 60)
    check(r.code == 0 && r2.code == 0, "24 add bot1 (grok-bot, webhook) and bot2 (claude-session)")
    r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "24 chat on (\(r.code))")
    r = h.run(["chat", "import", copy], timeout: 60)
    check(r.code == 6 && r.err.contains("doz chat off first"), "24 refused while chat is on: exit 6 (\(r.code))")
    _ = h.run(["chat", "off"], timeout: 30)
    let before = (try? fm.contentsOfDirectory(atPath: copy + "/rooms")) ?? []
    r = h.run(["chat", "import", copy], timeout: 60)
    check(r.code == 0 && r.out.contains("Imported 2 rooms, 15 messages and 1 attachment file.") && r.out.contains("You: ada"),
          "24 imported (\(r.code): \(r.err.trimmingCharacters(in: .newlines)))")
    check(r.out.contains("data.before-import-"), "24 …the first start's own folder kept aside")
    check(((try? fm.contentsOfDirectory(atPath: copy + "/rooms")) ?? []) == before, "24 …and the copy unchanged")

    // 25. nobody woken
    guard let hook = SuiteHook() else { check(false, "25 a listener for bot1's webhook"); return }
    defer { hook.stop() }
    r = h.run(["chat", "webhook", "set", "bot1"], stdin: Data("http://127.0.0.1:\(hook.port)/hook\n\n".utf8), timeout: 60)
    check(r.code == 0, "25 bot1's webhook entry set to the suite's listener (\(r.code))")
    r = h.run(["chat", "on"], timeout: 60)
    check(r.code == 0, "25 chat on (\(r.code))")
    let token2 = ((try? String(contentsOfFile: t2, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let got = (try? Process.run1(["/usr/bin/curl", "-s", "-m", "10", "-H", "Authorization: Bearer \(token2)", "http://127.0.0.1:\(page)/agent/receive?wait=2"])) ?? ""
    check(got.contains("\"messages\":[]"), "25 bot2's receive is empty (\(got.prefix(80)))")
    usleep(3_000_000)
    check(hook.requests.isEmpty, "25 bot1's webhook got no call (\(hook.requests.count))")
    r = h.run(["chat", "read", "room1", "--last", "1"])
    check(r.out.contains("bot1: bot1 in a row 3"), "25 room1's last message is the history's last: no line added (\(r.out.trimmingCharacters(in: .newlines)))")
    r = h.run(["chat", "send", "room2", "x"])
    check(r.code != 0 && r.err.contains("archived"), "25 room2 is archived (\(r.code))")

    // 26. again
    _ = h.run(["chat", "off"], timeout: 30)
    r = h.run(["chat", "import", copy], timeout: 60)
    check(r.code == 4 && r.err.contains("--replace"), "26 the same copy again: exit 4, history is never merged (\(r.code))")
    r = h.run(["chat", "import", copy, "--replace", "--json"], timeout: 60)
    check(r.code == 0 && r.out.contains("\"imported\" : true") && r.out.contains("data.before-import-"), "26 --replace: imported, the earlier folder kept aside")
    let aside = ((try? fm.contentsOfDirectory(atPath: paths.folder)) ?? []).filter { $0.hasPrefix("data.before-import-") }
    check(aside.count == 2, "26 …both earlier folders are there, none deleted (\(aside))")

    // 27. no token, no secret; listed in help
    let t1v = ((try? String(contentsOfFile: t1, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    check(!t1v.isEmpty && !r.out.contains(t1v) && !r.out.contains(token2), "27 --json names no token")
    r = h.run(["chat", "--help"])
    check(r.out.contains("  import"), "27 doz chat --help lists import")
}

extension Process {
    /// Runs a program to its end; its standard output.
    static func run1(_ argv: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        try p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}
