import Darwin
import DozableHost
import DozableKit
import Foundation

// 653 — `doz recipe check --full`: the core of `make recipe-check` (Scripts/recipe-check.py, a dev tool in Python) done by an
// INSTALLED doz, which cannot assume Python. It runs THIS executable as child processes in a scratch store, under the guarded
// test environment (DOZ_TEST_GUARD=1: TestSafety refuses the person's store, keychain, Mac login and ~/.codex), with FAKE keys
// in the scratch host's memory and a stand-in model provider on this Mac (`StandInProvider`, DozableKit) that the scratch
// host's proxy is pointed at by the existing seams. The recipe under check is put in the scratch settings dir as "yours".
//
// Steps: build at the pin (the bake checks the integrity and runs verify) · a fresh Locked try · its first screen (a pty,
// nothing typed) · verify again · the check turn (its output, its exit, the fake key SEEN by the stand-in) · the guide's steps
// · no key in the guest, a placeholder there · the leak guard. NOT here (make recipe-check's): the OSC 7501 states, web
// ports, every model source but the default, tool-call answers, Google Stitch, OpenCode Zen.

struct RecipeFullCheck {
    let recipe: AgentRecipe
    /// Your YAML (nil: a community recipe's compiled document is put in as JSON — JSON is YAML).
    let yaml: Data?
    let compiled: Data
    let g: GlobalOptions
    let scratch: String?

    struct Step: Codable { var name: String; var seconds: Double; var ok: Bool }
    struct Report: Codable {
        var scratch: String
        var source: String?
        var version: String?
        var steps: [Step] = []
        var failures: [String] = []
        var notes: [String] = []
    }

    /// The model sources the stand-in answers, and how a fake key of each is added.
    static let accountArgs: [String: [String]] = [
        "xai": ["--provider", "xai", "--no-verify"], "google": ["--provider", "google", "--no-verify"],
        "anthropic": ["--api-key", "--no-verify"], "openai": ["--openai-key", "--no-verify"],
        "openrouter": ["--provider", "openrouter", "--no-verify"], "vercel-ai-gateway": ["--provider", "vercel-ai-gateway", "--no-verify"],
    ]
    /// A source's host and how a key rides on it — for the leak guard.
    static let leakTarget: [String: (host: String, header: String, path: String)] = [
        "xai": ("api.x.ai", "Authorization: Bearer %@", "/v1/models"),
        "google": ("generativelanguage.googleapis.com", "x-goog-api-key: %@", "/v1beta/models"),
    ]
    /// recipe-check.py's SETUP_SCREEN: what a ready agent's first screen never asks.
    static let setupScreen: [(String, String)] = [
        (#"\bwelcome\b"#, "a welcome screen"),
        (#"let'?s get (?:you )?(?:set up|started)|\bsetup\b|set ?up wizard|\bget started\b"#, "set-up"),
        (#"let'?s configure|\bconfigure (?:your|a|an) |configuration (?:wizard|setup)"#, "configuration"),
        (#"\bsign[ -]?in\b|\blog[ -]?in\b"#, "a sign-in"),
        (#"would you like|how would you like|do you want to (?:share|send|allow|enable|help|opt)"#, "a question"),
        (#"usage data|anonymous (?:usage|data|statistics)|telemetry|analytics|improve (?:the )?product"#, "a usage-data consent"),
        (#"\btrust\b.{0,30}\b(?:folder|directory|workspace|files|project)|do you trust"#, "a trust question"),
        (#"(?:select|choose|pick) (?:a |your )?(?:theme|colou?r scheme|style)"#, "a theme choice"),
        (#"\bonboarding\b"#, "onboarding"),
        (#"(?:enter|paste|provide) (?:your |an? )?(?:own )?(?:\w+ )?api[ _-]?key"#, "a key request"),
        (#"terms of (?:service|use)|privacy (?:policy|notice)"#, "terms"),
    ]

    func say(_ s: String) { if !g.json { Out.stdout(s + "\n") } }

    func run() async -> Report {
        var r = await runSteps()
        r.failures += failuresSink.lines
        r.notes += failuresSink.notes
        return r
    }

    func runSteps() async -> Report {
        let root = URL(fileURLWithPath: scratch.map { ($0 as NSString).expandingTildeInPath } ?? NSTemporaryDirectory() + "dzrc", isDirectory: true)
        var report = Report(scratch: root.path)
        let store = root.appendingPathComponent("store").path
        let xdg = root.appendingPathComponent("xdg")
        let fm = FileManager.default
        for d in ["xdg/doz/recipes/mine", "store", "projects", "codex"] {
            try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard store.utf8.count + "/host.sock".utf8.count < 100 else {
            report.failures.append("the scratch folder's path is too long for the host's socket — --scratch with a shorter one")
            return report
        }
        try? "[store]\npath = \"\(store)\"\n\n[defaults]\nprojects_dir = \"\(root.path)/projects\"\n"
            .write(to: xdg.appendingPathComponent("doz/doz.toml"), atomically: true, encoding: .utf8)
        // Only the recipe under check, as "yours", in the scratch settings dir; the snapshot made here so every child
        // process uses it from its start.
        let mine = xdg.appendingPathComponent("doz/recipes/mine")
        for f in (try? fm.contentsOfDirectory(atPath: mine.path)) ?? [] { try? fm.removeItem(at: mine.appendingPathComponent(f)) }
        try? (yaml ?? compiled).write(to: mine.appendingPathComponent("\(recipe.id).yaml"))
        // The stand-in.
        let stand: StandInProvider
        do { stand = try StandInProvider() } catch {
            report.failures.append("the stand-in provider did not start: \(error.localizedDescription)")
            return report
        }
        defer { stand.stop() }
        let ca = root.appendingPathComponent("stand-in-ca.pem")
        try? stand.caPEM.write(to: ca, atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DOZ_") || ["DOZ_KERNEL_CACHE", "DOZ_KERNEL"].contains($0.key) }
        env.merge(["XDG_CONFIG_HOME": xdg.path, "DO_NOT_TRACK": "1", "DOZ_TEST_GUARD": "1", "DOZ_TEST_NO_MAC_LOGIN": "1",
                   "DOZ_TEST_CREDENTIALS": "memory", "DOZ_TEST_CODEX_HOME": root.appendingPathComponent("codex").path,
                   "DOZ_TEST_BASE_REGISTRY": "pinned", "DOZ_PROGRESS": "plain", "NO_COLOR": "1",
                   "DOZ_TEST_PROVIDER_UPSTREAM": "127.0.0.1:\(stand.port)", "DOZ_TEST_PROVIDER_CA": ca.path,
                   "DOZ_TEST_PROVIDER_HOSTS": "api.anthropic.com",
                   "DOZ_TEST_OPENAI_UPSTREAM": "127.0.0.1:\(stand.port)", "DOZ_TEST_OPENAI_CA": ca.path]) { $1 }
        RecipeExtras.rebuild(RecipeExtrasPaths(dir: xdg.appendingPathComponent("doz/recipes")), compile: RecipeSource.compile,
                             version: DozableCommand.version, promote: true, env: env)
        let run = Runner(executable: HostLauncher.executablePath, store: store, env: env)
        defer { _ = run.doz(["host", "stop"], timeout: 300) }
        _ = run.doz(["host", "stop"], timeout: 300)        // a host started under another environment

        func step(_ name: String, _ body: () -> Bool) -> Bool {
            let t = Date()
            let ok = body()
            let s = (Date().timeIntervalSince(t) * 10).rounded() / 10
            report.steps.append(Step(name: name, seconds: s, ok: ok))
            say("  \(ok ? "✓" : "✕") \(name) (\(s) s)")
            return ok
        }
        func failed(_ s: String) -> Bool { report.failures.append(s); say("      \(s)"); return false }

        let r = recipe
        let source = r.models?.default ?? r.provider ?? ""
        report.source = source
        guard let args = Self.accountArgs[source], let key = StandInProvider.fakeKeys[source] else {
            report.failures.append("the stand-in does not answer \(source) — the full check covers xAI, Google, Anthropic, OpenAI, OpenRouter and Vercel AI Gateway")
            return report
        }
        for (p, k) in StandInProvider.fakeKeys {
            guard let a = Self.accountArgs[p] else { continue }
            _ = run.doz(["account", "add", "rc-\(p)"] + a + ["--force"], stdin: k + "\n", timeout: 120)
        }
        _ = run.doz(["account", "default", "rc-\(source)"], timeout: 60)
        _ = args

        // The model and base URL a check turn may name (models@1): the plan's.
        var model = "", baseURL = ""
        if r.models != nil {
            let (_, out) = run.doz(["try", r.id, "--dry-run", "--json"], timeout: 120)
            if let o = Self.jsonObject(out), let m = o["model"] as? [String: Any] {
                model = m["model"] as? String ?? ""
                baseURL = ((m["offered"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == source }?["baseURL"] as? String ?? ""
            }
        }

        // 1. build — at the pin (a recipe that is not Dozable's always installs its pin).
        guard step("build at the pin \(r.install.pinned.version)", {
            let (code, out) = run.doz(["image", "bake", r.id, "--yes", "-q"], timeout: 2400)
            guard code == 0 else { return failed("doz image bake \(r.id) exited \(code): \(Self.tail(out))") }
            let (_, ls) = run.doz(["image", "ls", "--json"], timeout: 120)
            let row = (Self.jsonArray(ls) ?? []).first { $0["name"] as? String == r.id }
            report.version = row?["version"] as? String
            let v = (report.version ?? "").split(separator: "+").first.map(String.init) ?? ""
            guard v == r.install.pinned.version.split(separator: "+").first.map(String.init) else {
                return failed("the image holds \(report.version ?? "nothing"), not the pin \(r.install.pinned.version)")
            }
            return true
        }) else { return report }

        // 2. a fresh try — Locked (the strictest: it must be refused nothing it needs).
        var name = ""
        let before = Set((Self.jsonArray(run.doz(["ls", "--json"], timeout: 120).1) ?? []).compactMap { $0["name"] as? String })
        guard step("a fresh try (Locked, isolated)", {
            let sel = r.models == nil ? [] : [["openrouter", "vercel-ai-gateway"].contains(source) ? "--gateway" : "--provider", source, "--account", "rc-\(source)"]
            // Isolated: the scratch folder may be where no workspace is made (a system location), and the check needs none.
            let (code, out) = run.doz(["try", r.id] + sel + ["--network", "locked", "--isolated", "-d", "-q"], timeout: 1500)
            let after = (Self.jsonArray(run.doz(["ls", "--json"], timeout: 120).1) ?? []).compactMap { $0["name"] as? String }
            guard code == 0, let n = after.first(where: { !before.contains($0) }) else { return failed("doz try \(r.id) exited \(code): \(Self.tail(out))") }
            name = n
            return true
        }) else { return report }
        defer {
            _ = run.doz(["rm", name, "--yes"], timeout: 300)
            let folder = root.appendingPathComponent("projects/\(name)")
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }

        // 3. the first screen — before anything else runs in it.
        if r.launch.session != "shell" {
            _ = step("its first screen (nothing typed)") { firstScreen(run, name) }
        }
        // 4. verify
        let version = (report.version ?? r.install.pinned.version).split(separator: "+").first.map(String.init) ?? ""
        func verify(_ after: String) -> Bool {
            var ok = true
            for v in r.verify {
                let (code, out) = run.doz(["exec", name, "--"] + v.argv, timeout: 180)
                let exp = (v.expect ?? "").replacingOccurrences(of: "{version}", with: version)
                if code != 0 || (!exp.isEmpty && !out.contains(exp)) {
                    ok = failed("verify\(after): \(v.argv.joined(separator: " ")) → exit \(code), \(Self.tail(out, 200)) (expected \(exp))")
                }
            }
            return ok
        }
        _ = step("verify") { verify("") }
        // 5. the check turn
        if let c = r.smoke {
            _ = step("its check turn") {
                let argv = c.argv.map { $0.replacingOccurrences(of: "${{ dozable.model }}", with: model).replacingOccurrences(of: "${{ dozable.base_url }}", with: baseURL) }
                let n0 = stand.requests.count
                let (code, out) = run.doz(["exec", name, "--"] + argv, timeout: TimeInterval((c.timeout ?? 240) + 30))
                var ok = true
                if !out.contains(c.expect) { ok = failed("\(argv.joined(separator: " ")) did not print \(c.expect) (exit \(code)): \(Self.tail(out, 400))") }
                if code != Int32(c.exit ?? 0) { ok = failed("\(argv.joined(separator: " ")) exited \(code), expected \(c.exit ?? 0)") }
                let seen = stand.requests.dropFirst(n0)
                if !seen.contains(where: { $0.auth.values.contains { $0.contains(key) } }) {
                    ok = failed("the stand-in never saw the \(source) key swapped in by the proxy (\(seen.count) requests: \(Set(seen.map { $0.host + $0.path }).sorted().prefix(6).joined(separator: ", ")))")
                }
                return ok
            }
        }
        // 6. the guide's later steps (the first with a command is the check turn)
        if let gd = r.guide {
            let first = gd.steps.firstIndex { $0.command != nil }
            let later = gd.steps.enumerated().filter { $0.offset != first && $0.element.command != nil && $0.element.edit != true }
            if !later.isEmpty {
                _ = step("its guide's steps") {
                    var ok = true
                    for (i, s) in later {
                        let (code, out) = run.doz(["exec", name, "--", "sh", "-c", s.command!], timeout: TimeInterval((r.smoke?.timeout ?? 240) + 30))
                        if code != 0 { ok = failed("guide step \(i + 1): \(s.command!) exited \(code): \(Self.tail(out, 300))") }
                    }
                    return ok
                }
            }
        }
        _ = step("verify again, after the turn") { verify(" after the turn") }
        // 7. keys + the leak guard
        _ = step("no key in the sandbox; the leak guard") { keys(run, name, source, stand) }
        report.notes.append("not checked here (make recipe-check's): the agent's status reports, web ports, model sources but \(source), tool-call answers")
        return report
    }

    func keys(_ run: Runner, _ name: String, _ source: String, _ stand: StandInProvider) -> Bool {
        var ok = true
        let dirs = recipe.state.persist.map { $0.hasPrefix("~/") ? "/home/agent/" + $0.dropFirst(2) : $0 }.map { "'\($0)'" }.joined(separator: " ")
        let (_, out) = run.doz(["exec", name, "--", "sh", "-c",
                                "env; for d in \(dirs); do find \"$d\" -maxdepth 2 -type f -size -64k -exec cat {} + 2>/dev/null; done; true"], timeout: 120)
        let placeholder = out.range(of: "doz_cred_[A-Za-z0-9_-]+", options: .regularExpression).map { String(out[$0]) }
        if placeholder == nil { ok = false; report(&ok, "no doz placeholder in the guest (its environment or state folders)") }
        let pats = StandInProvider.fakeKeys.values.map { "-e '\($0)'" }.joined(separator: " ")
        let (_, found) = run.doz(["exec", name, "--user", "root", "--", "sh", "-c",
                                  "grep -rlsF \(pats) /proc/[0-9]*/environ /home /root /run /tmp /etc 2>/dev/null | head -3; echo scanned"], timeout: 300)
        if found.trimmingCharacters(in: .whitespacesAndNewlines) != "scanned" { report(&ok, "a key is in the guest: \(Self.tail(found, 200))") }
        guard let placeholder else { return ok }
        let other = source == "xai" ? "google" : "xai"
        guard let t = Self.leakTarget[other] else { return ok }
        _ = run.doz(["net", "allow", name, "site:" + t.host, "--yes"], timeout: 120)
        let n0 = stand.requests.count
        let header = String(format: t.header, placeholder)
        let (_, code) = run.doz(["exec", name, "--", "sh", "-c", "curl -s -m 20 -o /dev/null -w '%{http_code}' -H '\(header)' https://\(t.host)\(t.path)"], timeout: 120)
        let leaked = stand.requests.dropFirst(n0).filter { $0.host == t.host && $0.auth.values.contains { $0.contains("doz_cred_") || StandInProvider.fakeKeys.values.contains(where: $0.contains) } }
        let got = String(code.trimmingCharacters(in: .whitespacesAndNewlines).suffix(3))
        if !["400", "401", "403"].contains(got) || !leaked.isEmpty {
            report(&ok, "the placeholder sent to \(t.host) was not refused by the proxy (HTTP \(got), \(leaked.count) reached the stand-in)")
        }
        return ok
    }

    /// A failure line, under the step.
    func report(_ ok: inout Bool, _ s: String) {
        ok = false
        say("      \(s)")
        failuresSink.append(s)
    }
    final class Sink: @unchecked Sendable { var lines: [String] = []; var notes: [String] = []; func append(_ s: String) { lines.append(s) } }
    let failuresSink = Sink()

    /// The default session as a person first sees it: attached on a 120×40 pseudo-terminal, nothing typed (the recipe's
    /// screen keys only), left to settle, then read back with deckhold's dump.
    func firstScreen(_ run: Runner, _ name: String) -> Bool {
        let screen = recipe.smoke?.screen
        var master: Int32 = 0, slave: Int32 = 0
        var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else { failuresSink.append("screen: no pseudo-terminal"); return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: run.executable)
        p.arguments = ["attach", name, "--store", run.store]
        p.environment = run.env
        let h = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardInput = h; p.standardOutput = h; p.standardError = h
        do { try p.run() } catch { close(master); close(slave); failuresSink.append("screen: could not attach: \(error.localizedDescription)"); return false }
        close(slave)
        var raw = [UInt8]()
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            var buf = [UInt8](repeating: 0, count: 65536)
            while Date() < end {
                var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 250) > 0 else { continue }
                let n = read(master, &buf, buf.count)
                if n <= 0 { return }
                raw += buf[0..<n]
                if raw.suffix(n + 4).elementsEqual(Array("\u{1B}[6n".utf8)) || String(decoding: buf[0..<n], as: UTF8.self).contains("\u{1B}[6n") {
                    _ = "\u{1B}[1;1R".withCString { write(master, $0, 6) }
                }
            }
        }
        pump(Double(screen?.wait ?? 15))
        let keys: [String: String] = ["enter": "\r", "esc": "\u{1B}", "up": "\u{1B}[A", "down": "\u{1B}[B", "tab": "\t", "space": " "]
        for k in screen?.keys ?? [] {
            if let s = keys[k] { _ = s.withCString { write(master, $0, strlen($0)) } }
            pump(4)
        }
        var text = ""
        if let rows = Self.jsonArray(run.doz(["sessions", name, "--json"], timeout: 60).1),
           let session = (rows.first { $0["saved"] as? Bool != true } ?? rows.first)?["name"] as? String {
            let (code, out) = run.doz(["exec", name, "--user", "root", "--", "/usr/local/bin/deckhold", "dump", "-s", session], timeout: 60)
            if code == 0 { text = out }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "[\u{00}-\u{08}\u{0B}-\u{1F}\u{7F}]", with: "", options: .regularExpression)
            failuresSink.notes.append("screen: read from the attach's bytes (no live session to dump)")
        }
        for _ in 0..<2 { _ = "\u{1D}".withCString { write(master, $0, 1) }; usleep(150_000) }
        p.terminate()
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { pump(0.1) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        close(master)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let allow = (screen?.allow ?? []).compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        func matches(_ p: String, _ s: String) -> Bool { s.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        var found: [String] = []
        for (pat, what) in Self.setupScreen {
            for l in lines where matches(pat, l) && !allow.contains(where: { $0.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil }) {
                found.append("\(what): \(l.prefix(120))")
            }
        }
        for pat in screen?.refuse ?? [] { for l in lines where matches(pat, l) { found.append("refused \(pat): \(l.prefix(120))") } }
        var ok = true
        if !found.isEmpty { report(&ok, "the first screen is not the agent ready to work — " + Array(NSOrderedSet(array: found)).compactMap { $0 as? String }.joined(separator: "; ").prefix(900)) }
        for pat in screen?.expect ?? [] where !matches(pat, text) { report(&ok, "the first screen does not show \(pat)") }
        if !lines.contains(where: { !$0.isEmpty }) { report(&ok, "the first screen is empty") }
        return ok
    }

    static func tail(_ s: String, _ n: Int = 600) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).suffix(n)) }
    static func jsonObject(_ s: String) -> [String: Any]? {
        guard let i = s.firstIndex(of: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s[i...].utf8))) as? [String: Any]
    }
    static func jsonArray(_ s: String) -> [[String: Any]]? {
        guard let i = s.firstIndex(of: "[") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s[i...].utf8))) as? [[String: Any]]
    }

    /// This executable, as a child process with the scratch environment and store.
    struct Runner {
        let executable: String
        let store: String
        let env: [String: String]

        func doz(_ args: [String], stdin: String? = nil, timeout: TimeInterval) -> (Int32, String) {
            var a = args
            if let i = a.firstIndex(of: "--") { a.insert(contentsOf: ["--store", store], at: i) } else { a += ["--store", store] }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = a
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let inp = Pipe()
            p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
            do { try p.run() } catch { return (125, "could not run doz: \(error.localizedDescription)") }
            if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
            let box = DataBox()
            let reader = Thread { box.data = out.fileHandleForReading.readDataToEndOfFile() }
            reader.start()
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning, Date() < deadline { usleep(100_000) }
            var timedOut = false
            if p.isRunning { timedOut = true; p.terminate(); usleep(500_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            p.waitUntilExit()
            while !box.done { usleep(20_000) }
            let text = String(decoding: box.data, as: UTF8.self) + (timedOut ? "\n(timed out after \(Int(timeout)) s)" : "")
            return (timedOut ? 124 : p.terminationStatus, text)
        }
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        private var _done = false
        var data: Data {
            get { lock.lock(); defer { lock.unlock() }; return _data }
            set { lock.lock(); _data = newValue; _done = true; lock.unlock() }
        }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    }
}
