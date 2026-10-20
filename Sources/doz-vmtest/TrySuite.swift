import Darwin
import Foundation
import DozableHost
import DozableKit

// 617 — `doz try` the way a person uses it: on a terminal (script(1) gives it one, as test-cli-projectwizard does),
// through SEAMS only — the stand-in provider (Scripts/fake-provider.py, its own CA) for xAI, a FAKE key typed into the
// card's hidden prompt, held in the host's memory; never the owner's keychain, store or projects folder.
//   1. no key yet: the card, a pasted key (not echoed, never in accounts.json), the try made and attached; Ctrl-] twice
//      detaches and "Leaving try-grok — Sleep / delete / keep running" is asked — Enter = Sleep: it hibernates (634: an
//      ordinary sandbox, its Dozable-made folder recorded)
//   2. an answer that is none of them is asked again; d deletes it and its empty folder
//   3. k keeps it running
//   4. --rm deletes it on the way out without asking; --keep keeps it without asking
//   5. the slept try wakes on use; its check turn reaches the stand-in with the key swapped in (never in the guest)
//   6. 634: any sandbox's Dozable-made folder goes with `doz rm` while empty; a folder that was there stays
// OpenCode 1 is the agent (`opencode@1`, its pin; the image is prepared once) — 634: it was Grok Build, unpublished since
// 629 (a new try of it is refused); the same xAI key path. `make test-cli-try`.

func cliTrySuite(binary: String) async {
    let pid = getpid()
    let t = onboardingHarness(binary, "try", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let fm = FileManager.default
    let projects = "/tmp/dzo-\(pid)-tryp"         // beside the store: Dozable never makes a workspace inside one
    try? fm.removeItem(atPath: projects)
    let xdg = t.store.appendingPathComponent("xdg/doz")
    try? fm.createDirectory(at: xdg, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: projects, withIntermediateDirectories: true)
    // The try's folder goes under a scratch projects folder — never the person's.
    try? "[defaults]\nprojects_dir = \"\(projects)\"\n".write(to: xdg.appendingPathComponent("doz.toml"), atomically: true, encoding: .utf8)
    t.env["DO_NOT_TRACK"] = "1"
    t.env["DOZ_TEST_BASE_REGISTRY"] = "pinned"
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    let ws = "/tmp/dzo-\(pid)-tryf"
    try? fm.removeItem(atPath: ws)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let xaiKey = "xai-FAKE-TRYSUITE-0123456789abcdef"
    // 634: the tool tried — OpenCode 1, by the name a person types for that major (its family's recommended is 2).
    let tool = "opencode", typed = "opencode@1"
    defer {
        for s in t.ls() { t.run(["rm", s.name, "--yes"], timeout: 300) }
        t.run(["host", "stop"], timeout: 300)
        if let p = try? String(contentsOfFile: ws + "/pid", encoding: .utf8), let n = Int32(p.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(n, SIGTERM) }
        try? fm.removeItem(at: t.store)
        try? fm.removeItem(atPath: ws)
        try? fm.removeItem(atPath: projects)
    }
    print("cli: doz try on a terminal — the key card, the exit question (sleep, delete, keep), --rm/--keep (617)")

    // The stand-in provider.
    let up = Process()
    up.executableURL = URL(fileURLWithPath: "/bin/sh")
    up.arguments = [repo.appendingPathComponent("Scripts/fake-provider-up.sh").path, ws]
    var uenv = ProcessInfo.processInfo.environment
    uenv["FAKE_XAI_KEY"] = xaiKey
    up.environment = uenv
    let upOut = Pipe()
    up.standardOutput = upOut
    do { try up.run() } catch { check(false, "start the stand-in provider: \(error)"); return }
    up.waitUntilExit()
    let port = String(decoding: upOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    check(up.terminationStatus == 0 && !port.isEmpty, "the stand-in provider listens on 127.0.0.1:\(port) (TLS, its own CA)")
    t.env["DOZ_TEST_PROVIDER_UPSTREAM"] = "127.0.0.1:\(port)"
    t.env["DOZ_TEST_PROVIDER_CA"] = ws + "/ca.pem"
    t.run(["host", "stop"], timeout: 300)
    // 634: OpenCode 1 (published; an xAI key by default — the same key path Grok Build, unpublished since 629, took).
    guard let r = AgentRecipes.recipe(tool), let versionKey = SettingKey.agentVersion(tool) else { check(false, "the \(tool) recipe"); return }
    check(t.run(["config", "set", versionKey, r.install.pinned.version]).code == 0, "\(versionKey) = its pin \(r.install.pinned.version)")
    // The image a try of it makes (the planner's — its base follows the store's), prepared once.
    let dry = t.run(["try", typed, "--dry-run", "--json"])
    let image = ((try? JSONSerialization.jsonObject(with: Data(dry.out.utf8))) as? [String: Any])?["image"] as? String ?? tool
    let made = t.run(["image", "bake", image, "--yes", "-q"], timeout: 1800)
    check(made.code == 0, "the \(image) image is prepared (once)")

    /// A recorded workspace is resolved (/tmp is a link to /private/tmp).
    func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
    let sh = CLIHarness(binary: "/usr/bin/script", store: t.store)
    sh.env = t.env
    // 634: what a try makes is an ordinary sandbox (no mark) — the tries are told apart by name, before and after.
    func trials() -> Set<String> { Set(t.ls().map(\.name)) }
    func requests() -> [[String: Any]] {
        ((try? String(contentsOfFile: ws + "/requests.log", encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    /// `doz try opencode@1 ARGS` on a terminal: waits for the agent's screen, detaches (Ctrl-] twice), answers the
    /// question with each of `answers` in turn (none: it must not be asked). Returns the try's name, the output, the exit.
    func tryOnTerminal(_ extra: [String] = [], answers: [String], key: Bool = false, _ what: String) -> (name: String, text: String, code: Int32?) {
        let before = trials()
        do {
            let c = try PTYClient(sh, ["-q", "/dev/null", binary, "try", typed] + extra)
            defer { c.close() }
            if key {
                check(c.wait(120) { $0.text.contains("Choose 1–") }, "\(what): the card asks how to give \(r.title) its key")
                // The option that pastes a key (its number, from the card's own lines).
                let card = c.text
                let n = card.split(separator: "\n").compactMap { l -> Int? in
                    let s = l.trimmingCharacters(in: .whitespaces)
                    guard s.lowercased().contains("paste"), let d = s.first?.wholeNumberValue else { return nil }
                    return d
                }.first ?? 1
                c.type("\(n)\r")
                check(c.wait(30) { $0.text.contains("Account name") }, "\(what): the account's name is asked")
                c.type("\r")
                check(c.wait(30) { $0.text.contains("not echoed") }, "\(what): the key is asked, not echoed")
                c.type(xaiKey + "\r")
            }
            check(c.wait(300) { $0.text.contains("attaching to") }, "\(what): the try is made, started and attached")
            // The agent's own screen (OpenCode draws its prompt), then Ctrl-] twice: the menu, then detach.
            _ = c.wait(30) { $0.bytes.count > 4000 }
            sleep(3)
            c.type(byte: 0x1D)
            usleep(120_000)
            c.type(byte: 0x1D)
            let q = TryExitChoice.choices
            if answers.isEmpty {
                let code = c.exited(within: 120)
                check(!c.text.contains(q), "\(what): nothing is asked")
                let name = trials().subtracting(before).first ?? before.subtracting(trials()).first ?? ""
                return (name, c.text, code)
            }
            for (i, a) in answers.enumerated() {
                check(c.wait(60) { $0.text.components(separatedBy: q).count > i + 1 }, "\(what): asked \"Leaving … — Sleep / delete / keep running\"\(i > 0 ? " again" : "")")
                c.type(a + "\r")
            }
            let code = c.exited(within: 300)
            let name = trials().subtracting(before).first ?? ""
            return (name, c.text, code)
        } catch {
            check(false, "\(what): a pseudo-terminal: \(error)")
            return ("", "", nil)
        }
    }

    // 1. No key yet: the card; Enter = Sleep.
    let n0 = requests().count
    let one = tryOnTerminal(answers: [""], key: true, "1 (no key, then Sleep)")
    check(one.code == 0, "1: doz try exits 0 (\(one.code.map(String.init) ?? "still running"))")
    check(!one.text.contains(xaiKey), "1: the key never appears on the terminal")
    let accounts = (try? String(contentsOf: t.store.appendingPathComponent("accounts.json"), encoding: .utf8)) ?? ""
    check(accounts.contains("\"xai\"") && !accounts.contains(xaiKey), "1: the account xai is kept, accounts.json holds no key")
    let slept = t.row(one.name)
    check(slept?.phase == "hibernated", "1: Sleep hibernates it (\(one.name): \(slept?.phase ?? "gone"))")
    check(slept?.createdFolder.map(resolved) == resolved(projects + "/" + one.name), "1: its folder is recorded as Dozable's own (\(slept?.createdFolder ?? "none"))")
    check(t.run(["ls"]).out.contains("(try)") == false, "1: doz ls marks nothing as a try (634)")

    // 2. Not an answer → asked again; d deletes it and its empty folder.
    let two = tryOnTerminal(answers: ["x", "d"], "2 (an unknown answer, then delete)")
    let twoName = two.name.isEmpty ? (two.text.components(separatedBy: " · ").first?.split(separator: "\n").last.map(String.init) ?? "") : two.name
    check(two.code == 0, "2: doz try exits 0")
    check(!twoName.isEmpty && t.row(twoName) == nil, "2: d deleted the try (\(twoName))")
    check(!twoName.isEmpty && !fm.fileExists(atPath: projects + "/" + twoName), "2: and its empty folder")
    check(t.row(one.name) != nil, "2: the first try is untouched")

    // 3. k keeps it running.
    let three = tryOnTerminal(answers: ["k"], "3 (keep)")
    check(three.code == 0 && three.text.contains("keeps running"), "3: k keeps it running, and says how to come back")
    check(t.row(three.name)?.phase == "running", "3: \(three.name) is running")

    // 4. --rm and --keep answer before: nothing is asked.
    let four = tryOnTerminal(["--rm"], answers: [], "4 (--rm)")
    check(four.code == 0 && t.ls().count == 2, "4: --rm deleted its try on the way out")
    let five = tryOnTerminal(["--keep"], answers: [], "4 (--keep)")
    check(five.code == 0 && five.text.contains("keeps running") && t.row(five.name)?.phase == "running", "4: --keep kept it running (\(five.name))")

    // 5. The slept try wakes when used again (off a terminal: exec wakes it the same way) — its check turn (the recipe's
    //    `launch.check`), which reaches the stand-in with the key the proxy swapped in (634: moved here from part 1 —
    //    Grok Build called its model at start, OpenCode does at its first turn).
    let w = t.run(["exec", one.name, "--", "opencode", "--version"], timeout: 180)
    check(w.code == 0 && w.out.contains(r.install.pinned.version), "5: the slept try wakes and runs (\(w.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(40)))")
    let turn = t.run(["exec", one.name, "--"] + (r.smoke?.argv ?? ["opencode", "run", "say ok"]), timeout: 180)
    check(turn.out.contains("DOZ_FAKE_OK"), "5: its check turn answers through the stand-in (\(turn.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(60)))")
    check(requests().dropFirst(n0).contains { (($0["auth"] as? [String: String]) ?? [:]).values.contains("Bearer " + xaiKey) },
          "5: \(r.title) reached the stand-in with the key swapped in by the proxy")
    check(!turn.out.contains(xaiKey), "5: the key is nowhere in what the sandbox printed")

    // 6. 634 — the easy delete is every sandbox's: a `doz new`-style sandbox whose folder Dozable made loses it with
    //    `doz rm` while empty; one whose folder was there keeps it.
    let made6 = projects + "/plain-six"
    let c6 = t.run(["create", "plain-six", "--image", "lab", "--memory", "384M", "--workspace", made6])
    check(c6.code == 0 && t.row("plain-six")?.createdFolder.map(resolved) == resolved(made6), "6: create with a new folder records it (\(t.row("plain-six")?.createdFolder ?? "none"))")
    let rm6 = t.run(["rm", "plain-six", "--yes"], timeout: 300)
    check(rm6.code == 0 && !fm.fileExists(atPath: made6), "6: doz rm removed its empty folder too (\(rm6.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    let kept6 = projects + "/plain-seven"
    try? fm.createDirectory(atPath: kept6, withIntermediateDirectories: true)
    let c7 = t.run(["create", "plain-seven", "--image", "lab", "--memory", "384M", "--workspace", kept6])
    check(c7.code == 0 && t.row("plain-seven")?.createdFolder == nil, "6: a folder that was there is not Dozable's")
    check(t.run(["rm", "plain-seven", "--yes"], timeout: 300).code == 0 && fm.fileExists(atPath: kept6), "6: doz rm keeps a folder that was there")
}
