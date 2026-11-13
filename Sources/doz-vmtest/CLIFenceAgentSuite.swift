import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence`, the agent's part: a FAKE `claude` (a shell script in the scratch home's ~/.local/bin) in fenced
// sessions — its own config folder (private) or the twin ~/.claude (shared), the history value, its conversations carried
// back into the twin ~/.claude and archived, the Claude login swapped through the session's proxy (a FAKE setup token held
// in the host's memory keychain; api.anthropic.com is the fake provider over TLS — `Scripts/fake-provider-up.sh`, its own
// throwaway CA, the guarded seam `DOZ_TEST_PROVIDER_*`), the facts prompt, the capabilities, and the bridges through a
// real attach on a pseudo-terminal (`DOZ_TEST_OPEN_URL`, `DOZ_TEST_PASTEBOARD`: files, never a browser or the clipboard).
// Never the real ~/.claude, a real login or a real key. Row numbers are the plan's test table (M3).

func cliFenceAgentChecks(_ t: CLIHarness, root: String, home: String, store: String, started: inout Set<String>) async {
    print("cli: a fenced agent — its config folder, conversations, the swapped login, the facts, capabilities, bridges")
    let base = root + "/agent"
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    func put(_ p: String, _ s: String, mode: mode_t = 0o644) {
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(s.utf8))
        chmod(p, mode)
    }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func folder(_ name: String) -> String {
        let d = base + "/" + name
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return MacFencePaths.resolve(d) ?? d
    }
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func row(_ s: String) -> SessionRow? { rows().first { $0.name == s } }
    func run(_ s: String, _ wd: String, _ extra: [String] = [], argv: [String] = ["claude"]) -> CLIRun {
        let r = t.run(["run", "@mac", "-d", "--fenced", "--session", s, "--workdir", wd] + extra + ["--"] + argv, timeout: 90)
        if r.code == 0 { started.insert(s) }
        return r
    }
    @discardableResult func end(_ s: String) -> CLIRun {
        let r = t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60)
        started.remove(s)
        return r
    }

    // The fake provider (TLS, its own CA): the fake setup token is the only credential it accepts.
    let fake = base + "/fake"
    let token = "sk-ant-oat01-FAKE-cli-fence-" + String(repeating: "0", count: 40)
    let up = Process()
    up.executableURL = URL(fileURLWithPath: "/bin/sh")
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    up.arguments = [repo.appendingPathComponent("Scripts/fake-provider-up.sh").path, fake]
    up.environment = ["PATH": "/usr/bin:/bin", "FAKE_ANTHROPIC_KEY": token]
    let upOut = Pipe()
    up.standardOutput = upOut
    up.standardError = FileHandle.nullDevice
    try? up.run()
    up.waitUntilExit()
    let port = String(decoding: upOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    check(up.terminationStatus == 0 && Int(port) != nil, "the fake provider runs (127.0.0.1:\(port), its own CA)")
    defer { if let pid = Int32(get(fake + "/pid").trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGTERM) } }
    // The host again, with the seams (a host reads them at its start).
    t.run(["host", "stop"], timeout: 60)
    let opened = base + "/opened", board = base + "/pasteboard"
    t.env["DOZ_TEST_PROVIDER_UPSTREAM"] = "127.0.0.1:\(port)"
    t.env["DOZ_TEST_PROVIDER_CA"] = fake + "/ca.pem"
    t.env["DOZ_TEST_PROVIDER_HOSTS"] = "api.anthropic.com"
    t.env["DOZ_TEST_OPEN_URL"] = opened
    t.env["DOZ_TEST_PASTEBOARD"] = board

    // The twin ~/.claude (scratch): settings with keys that must never come, instructions, a skill, a conversation.
    let claudeHome = home + "/.claude"
    put(claudeHome + "/settings.json", "{\"env\":{\"X\":\"TWINSECRET\"},\"hooks\":{\"Stop\":[]},\"statusLine\":{\"command\":\"x\"},\"model\":\"opus\",\"permissions\":{\"allow\":[\"Bash(ls)\"]}}\n")
    put(claudeHome + "/CLAUDE.md", "TWIN INSTRUCTIONS")
    put(claudeHome + "/skills/one/SKILL.md", "SKILL ONE")
    put(home + "/.claude.json", "{\"theme\":\"dark\",\"oauthAccount\":\"TWINSECRET\"}\n")
    // The fake claude: records its argv and environment, runs the folder's steps.sh, then waits.
    put(home + "/.local/bin/claude", "#!/bin/sh\nprintf '%s\\n' \"$@\" > argv.txt\nenv > cenv.txt\n[ -f steps.sh ] && . ./steps.sh\necho done > DONE\nsleep 600\n", mode: 0o755)
    let u1 = "0b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3"
    let curl = "curl -sS --max-time 15 https://api.anthropic.com/v1/messages -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' "
        + "--data-binary @body.json"

    // MARK: account, private folder, the swap, the facts (3.1–3.8, 3.7)
    var r = t.run(["account", "add", "ct", "--setup-token", "--no-verify", "--force"], stdin: Data((token + "\n").utf8))
    check(r.code == 0, "account add ct --setup-token < stdin (a FAKE token, the host's memory keychain)\(r.code == 0 ? "" : ": " + r.err)")
    let pw = folder("pw")
    put(pw + "/body.json", "{\"model\":\"claude-haiku-4-5\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
    let enc = MacPlace.claudeProjectFolderName(pw)
    put(pw + "/steps.sh", """
    r() { n=$1; shift; ( "$@" ) > "res-$n.out" 2>&1; echo $? > "res-$n"; }
    r swap sh -c "\(curl) -H \\"Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN\\""
    r foreign sh -c "\(curl) -H 'x-api-key: sk-ant-api03-Fx1\(String(repeating: "q1Z", count: 31))AA'"
    r both sh -c "\(curl) -H \\"Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN\\" -H 'x-api-key: sk-ant-api03-Fx2\(String(repeating: "w2Y", count: 31))AA'"
    r person cat ~/.claude/settings.json
    r personjson cat ~/.claude.json
    r md cat "$CLAUDE_CONFIG_DIR/CLAUDE.md"
    r skill cat "$CLAUDE_CONFIG_DIR/skills/one/SKILL.md"
    r mdw sh -c 'echo x >> "$CLAUDE_CONFIG_DIR/CLAUDE.md"'
    r rmlink rm "$CLAUDE_CONFIG_DIR/skills"
    r settingsw sh -c 'echo {} > "$CLAUDE_CONFIG_DIR/settings.json"'
    r caw sh -c 'echo x >> "$NODE_EXTRA_CA_CERTS"'
    cp "$CLAUDE_CONFIG_DIR/settings.json" settings.copy; cp "$CLAUDE_CONFIG_DIR/.claude.json" first.copy
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/\(enc)/memory" "$CLAUDE_CONFIG_DIR/todos"
    printf '{"type":"user","cwd":"%s"}\\n' "$(pwd -P)" > "$CLAUDE_CONFIG_DIR/projects/\(enc)/\(u1).jsonl"
    echo planted > "$CLAUDE_CONFIG_DIR/projects/\(enc)/memory/x.md"; echo t > "$CLAUDE_CONFIG_DIR/todos/y.json"
    echo note > "$CLAUDE_CONFIG_DIR/projects/\(enc)/notes.jsonl"
    printf 'not json\\n' > "$CLAUDE_CONFIG_DIR/projects/\(enc)/1b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl"
    printf '{"cwd":"/elsewhere"}\\n' > "$CLAUDE_CONFIG_DIR/projects/\(enc)/2b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl"
    """)
    r = run("cc", pw, ["--account", "ct"])
    check(r.code == 0 && r.err.contains("Claude Code settings"), "run @mac --fenced --account ct -- claude: the fenced line names its own settings\(r.code == 0 ? "" : ": " + r.err)")
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: pw + "/DONE") }, "the fake claude ran its steps")
    func res(_ d: String, _ n: String) -> Int? { Int(get(d + "/res-" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    func out(_ d: String, _ n: String) -> String { get(d + "/res-" + n + ".out") }
    let env = get(pw + "/cenv.txt")
    let ph = env.split(separator: "\n").first { $0.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN=") }.map { String($0.dropFirst(24)) } ?? ""
    check(ph.hasPrefix("doz_cred_") && !env.contains(token), "3.1 the program has a placeholder (doz_cred_…), never the token")
    let swapped = out(pw, "swap").contains("DOZ_FAKE_OK")
    if !swapped { print("  INFO  swap: " + out(pw, "swap").suffix(2500)); print("  INFO  fake: " + get(fake + "/requests.log").suffix(1500) + " // " + get(fake + "/fake.out").suffix(600)); print("  INFO  hostlog: " + hostLog(t).split(separator: "\n").filter { $0.lowercased().contains("anthropic") || $0.contains("upstream") || $0.contains("TLS") }.suffix(8).joined(separator: " / ")); print("  INFO  host.log: " + hostLog(t).split(separator: "\n").filter { $0.contains("@mac") }.suffix(12).joined(separator: " / ")) }
    check(swapped, "3.1 its request reached the model with the real token swapped in (\(out(pw, "swap").prefix(160)))")
    check(!out(pw, "foreign").contains("DOZ_FAKE_OK") && out(pw, "foreign").contains("refused"), "3.2 its own credential is refused, nothing injected beside it (\(out(pw, "foreign").prefix(160)))")
    // The vault (a sandbox's too) swaps a placeholder the program sent even beside a credential of its own — its own choice;
    // what it never does is ADD ours beside one (the row above). Said, not asserted.
    print("  INFO  3.2 its placeholder beside a credential of its own: " + (out(pw, "both").contains("DOZ_FAKE_OK") ? "swapped (as in a sandbox)" : "not swapped"))
    let fakeLog = get(fake + "/requests.log")
    check(fakeLog.contains(token) && !fakeLog.contains("sk-ant-api03-Fx1"), "3.2 the provider saw the real token only — a request with only its own credential never reached it")
    check(env.contains("CLAUDE_CONFIG_DIR=") && !env.split(separator: "\n").contains { $0.hasPrefix("CLAUDE") && !$0.hasPrefix("CLAUDE_CONFIG_DIR=") && !$0.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN=") && !$0.hasPrefix("CLAUDE_CODE_TMPDIR=") },
          "1.17 the only CLAUDE_* variables are its config folder, its temp folder and the placeholder")
    check(res(pw, "person").map { $0 != 0 } == true && res(pw, "personjson").map { $0 != 0 } == true, "3.8 the person's ~/.claude and ~/.claude.json stay closed")
    check(res(pw, "md") == 0 && res(pw, "skill") == 0, "3.8 the instructions and a skill, read through their links")
    check(res(pw, "mdw").map { $0 != 0 } == true && res(pw, "rmlink").map { $0 != 0 } == true, "3.8 not writable through a link, a link not removable")
    check(res(pw, "settingsw").map { $0 != 0 } == true, "3.8 its settings changes are refused")
    check(res(pw, "caw").map { $0 != 0 } == true, "3.5 the CA copy in etc/ is not writable")
    check(get(claudeHome + "/CLAUDE.md") == "TWIN INSTRUCTIONS", "…the twin's instructions unchanged")
    let settings = get(pw + "/settings.copy")
    check(settings.contains("\"model\"") && settings.contains("cleanupPeriodDays") && !settings.contains("TWINSECRET") && !settings.contains("hooks") && !settings.contains("statusLine"),
          "3.8 settings.json: the allowlisted keys and keep's cleanupPeriodDays only")
    let first = get(pw + "/first.copy")
    check(first.contains("hasCompletedOnboarding") && first.contains("hasTrustDialogAccepted") && first.contains("dark") && !first.contains("TWINSECRET"),
          "3.8 .claude.json: onboarding done, the folder trusted, the person's theme — nothing else")
    let argv = get(pw + "/argv.txt")
    check(argv.hasPrefix("--append-system-prompt\n" + MacAgentPrompt.firstLine), "3.7 the facts arrive as one --append-system-prompt")
    check(row("cc")?.argv == ["claude"], "3.7 …the record keeps the person's argv")
    let cc = row("cc")
    check(cc?.fence?.agent == "claude-code" && cc?.fence?.agentConfig == "private" && cc?.fence?.account == "ct" && cc?.fence?.history == "keep",
          "sessions @mac --json: agent claude-code, private, account ct, history keep")
    check(cc?.capabilities?.first { $0.id == "claude-login" }?.state == "swapped in (account ct)", "capabilities: the login swapped in")
    r = t.run(["sessions", "@mac", "--capabilities", "cc"])
    check(r.code == 0 && r.out.contains("Agent config") && r.out.contains("private") && r.out.contains("(live)"), "sessions @mac --capabilities cc")
    r = t.run(["run", "@mac", "--fenced", "--dry-run", "--session", "cc", "--workdir", pw, "--json", "--", "claude"])
    let dry = (try? HostWire.decoder.decode([MacCapability].self, from: Data(r.out.utf8))) ?? []
    check(r.code == 0 && dry.map(\.id) == (cc?.capabilities ?? []).map(\.id) && dry.first { $0.id == "agent-config" }?.state == "private",
          "--dry-run: the same capabilities, from the same source, nothing started")

    // 3.9: its end carries the conversation back — only it; archived under keep.
    r = end("cc")
    let personProjects = claudeHome + "/projects/" + enc
    check(r.code == 0 && r.out.contains("written by a fenced session"), "3.9 the end message: written by a fenced session (\(r.out.prefix(200)))")
    check(get(personProjects + "/\(u1).jsonl").contains("\"cwd\""), "3.9 the conversation is in the twin ~/.claude/projects/<folder>")
    let carried = (try? FileManager.default.contentsOfDirectory(atPath: personProjects)) ?? []
    check(carried == [u1 + ".jsonl"], "3.9c only it: no memory/, no notes.jsonl, no non-JSON or other-folder file (\(carried))")
    check(!FileManager.default.fileExists(atPath: claudeHome + "/todos"), "3.9 no todos carried")
    check(r.out.contains("notes.jsonl") && r.out.contains("1b1c2d3e"), "3.9c what was not carried is named")
    r = t.run(["sessions", "@mac", "--transcripts", "cc"])
    check(r.code == 0 && r.out.contains(u1), "3.9b --transcripts lists the archived conversation")
    let exp = folder("export")
    r = t.run(["sessions", "@mac", "--transcripts", "cc", "--export", exp])
    check(r.code == 0 && ((try? FileManager.default.contentsOfDirectory(atPath: exp)) ?? []).contains { $0.hasSuffix(u1 + ".jsonl") }, "3.9b --export writes copies")
    t.run(["sessions", "end", "@mac", "cc", "--yes"], timeout: 60)            // forgotten: carried once, nothing again

    // 3.9d + 3.9a + 3.10: a restart continues from its own folder; a grown conversation replaces its prefix; agent-default.
    let hd = folder("hd")
    let encH = MacPlace.claudeProjectFolderName(hd)
    put(claudeHome + "/projects/" + encH + "/\(u1).jsonl", "{\"cwd\":\"\(hd)\",\"n\":1}\n")
    put(hd + "/steps.sh", "printf '{\"cwd\":\"%s\",\"n\":2}\\n' \"$(pwd -P)\" >> \"$CLAUDE_CONFIG_DIR/projects/\(encH)/\(u1).jsonl\"\n")
    r = run("hd", hd, ["--history", "agent-default", "--account", "none"])
    check(r.code == 0 && t.waitFor(20) { FileManager.default.fileExists(atPath: hd + "/DONE") }, "a session with --history agent-default --account none")
    check(!get(hd + "/cenv.txt").contains("CLAUDE_CODE_OAUTH_TOKEN"), "--account none: no placeholder at all")
    check(row("hd")?.fence?.history == "agent-default" && row("hd")?.fence?.historySource == "flag", "3.10 history: the session's own (flag)")
    r = end("hd")
    check(get(claudeHome + "/projects/" + encH + "/\(u1).jsonl") == "{\"cwd\":\"\(hd)\",\"n\":1}\n{\"cwd\":\"\(hd)\",\"n\":2}\n",
          "3.9d the person's copy (a prefix, cloned in at the first open) is replaced by the longer one")
    check(r.out.contains("older than 30 days"), "3.9 agent-default: the end says Claude Code's own rule (\(r.out.prefix(200)))")
    r = t.run(["sessions", "@mac", "--transcripts", "hd"])
    check(!r.out.contains(u1), "3.9 agent-default: not archived")
    t.run(["sessions", "end", "@mac", "hd", "--yes"], timeout: 60)
    r = run("nope", hd, ["--account", "nobody"])
    check(r.code != 0 && r.err.contains("nobody"), "an account that does not exist is refused (no fallback) (\(r.code))")
    r = run("nope", hd, ["-e", "ANTHROPIC_API_KEY=sk-x"])
    check(r.code != 0 && r.err.contains("--account"), "a key in its environment is refused (\(r.code))")
    r = run("nope", hd, ["--agent-config", "shared"], argv: ["/bin/sh", "-c", "sleep 1"])
    check(r.code != 0 && r.err.contains("--agent-config"), "--agent-config for a program that declares no folder is refused (\(r.code))")

    // 3.3 + 3.4: this Mac's login (none in a guarded run — the memory keychain is empty) with --keychain: still only a
    // placeholder; the proxy's own 401 says what to do, nothing else is tried.
    let c3 = folder("c3")
    put(c3 + "/body.json", get(pw + "/body.json"))
    put(c3 + "/steps.sh", "( \(curl) -H \"Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN\" ) > res-mac.out 2>&1\n")
    r = run("c3", c3, ["--account", "mac", "--keychain"])
    check(r.code == 0 && t.waitFor(30) { FileManager.default.fileExists(atPath: c3 + "/DONE") }, "a session with --account mac --keychain")
    check(get(c3 + "/cenv.txt").contains("CLAUDE_CODE_OAUTH_TOKEN=doz_cred_"), "3.4 --keychain: still the placeholder")
    let m3 = get(c3 + "/res-mac.out")
    check(!m3.contains("DOZ_FAKE_OK") && (m3.contains("signed out") || m3.contains("could not read") || m3.contains("no Claude login")),
          "3.3 no login behind it: the proxy's own answer says what to do, no fallback (\(m3.prefix(200)))")
    end("c3")
    t.run(["sessions", "end", "@mac", "c3", "--yes"], timeout: 60)

    // 3.8b: shared —the twin ~/.claude read and written; said; no history key written into it.
    let sh = folder("sh")
    put(sh + "/steps.sh", "echo w > ~/.claude/from-session.txt; echo $? > res-w; cat ~/.claude/settings.json > /dev/null; echo $? > res-r\n")
    r = run("sh", sh, ["--agent-config", "shared"])
    check(r.code == 0 && r.err.contains("less isolated"), "3.8b shared: said at the start (less isolated)")
    check(t.waitFor(20) { FileManager.default.fileExists(atPath: sh + "/DONE") }, "…it ran")
    check(get(sh + "/res-w").hasPrefix("0") && get(sh + "/res-r").hasPrefix("0") && get(claudeHome + "/from-session.txt") == "w\n",
          "3.8b the twin ~/.claude is readable and writable")
    check(!get(claudeHome + "/settings.json").contains("cleanupPeriodDays"), "3.8b no history key written into the person's own config")
    check(row("sh")?.fence?.agentConfig == "shared" && t.run(["sessions", "@mac"]).out.contains("shared config"), "3.8b sessions @mac and --json say shared")
    check(row("sh")?.capabilities?.first { $0.id == "agent-config" }?.state == "shared (less isolated)", "3.8b the capability says less isolated")
    end("sh")
    t.run(["sessions", "end", "@mac", "sh", "--yes"], timeout: 60)

    // MARK: the bridges, through a real attach (3.12–3.15, 3.17)
    let br = folder("br")
    put(br + "/doc.md", "# doc")
    put(br + "/tool.sh", "#!/bin/sh\n", mode: 0o755)
    put(br + "/steps.sh", """
    while [ ! -e go1 ]; do sleep 0.2; done
    printf 'HTTP/1.0 200 OK\\r\\n\\r\\nCALLBACK-OK' > cbans.txt
    ( nc -l 127.0.0.1 8765 < cbans.txt > cb.txt & ) ; sleep 0.5
    open 'https://allowed.example/x?state=SECRET'; echo $? > o1
    $BROWSER 'https://allowed.example/b'; echo $? > o2
    open 'https://auth.example/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A8765%2Fcb&state=S2'; echo $? > o3
    open 'https://auth.example/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A9999%2Fcb'; echo $? > o4
    printf '\\033]6340;doz-open;file:///etc/passwd\\007' > /dev/tty
    open 'http://127.0.0.1:5432/'; echo $? > o5
    open doc.md; echo $? > f1
    open -R doc.md; echo $? > f2
    printf '\\033]6340;doz-file;;/etc/hosts\\007' > /dev/tty
    printf '\\033]6340;doz-file;;%s/tool.sh\\007' "$(pwd -P)" > /dev/tty
    printf '\\033]52;c;%s\\007' "$(printf 'npm run dev\\tX' | base64)"
    printf '\\033]52;c;?\\007'
    echo step1 > S1
    while [ ! -e go2 ]; do sleep 0.2; done
    printf '\\033]52;c;%s\\007' "$(printf 'second' | base64)"
    open 'https://allowed.example/after'; echo $? > o6
    echo step2 > S2
    """)
    r = run("br", br, ["--local-port", "8765", "--account", "none"])
    check(r.code == 0, "a fenced session with --local-port 8765 for the bridges")
    do {
        let c = try PTYClient(t, ["attach", "@mac", "br"])
        defer { c.close() }
        usleep(1_500_000)
        FileManager.default.createFile(atPath: br + "/go1", contents: nil)
        check(t.waitFor(30) { FileManager.default.fileExists(atPath: br + "/S1") }, "the program asked for its opens and copies")
        usleep(1_500_000)
        let seam = get(opened)
        check(seam.contains("open https://allowed.example/x?state=SECRET") && seam.contains("open https://allowed.example/b"),
              "3.12 open and $BROWSER reach the browser (o2=\(get(br + "/o2").trimmingCharacters(in: .whitespacesAndNewlines)) \(get(br + "/cenv.txt").split(separator: "\n").filter { $0.hasPrefix("BROWSER") }) the seam: \(seam.replacingOccurrences(of: "\n", with: " / ")))")
        check(c.text.contains("(fenced) opened https://allowed.example/x") && !c.text.contains("SECRET"), "3.12 announced — scheme, host, path; never the query")
        check(!hostLog(t).contains("SECRET"), "3.12 the host's log never has the query")
        check(t.waitFor(15) { get(opened).contains("callback 8765") } && !get(opened).contains("callback 8765 refused") && get(br + "/cb.txt").contains("GET /cb"),
              "3.14 a sign-in calling back to an allowed --local-port opens; the browser reaches the program directly (\(get(opened).components(separatedBy: "\n").filter { $0.hasPrefix("callback") }))")
        check(!seam.contains("localhost%3A9999") && c.text.contains("calls back to localhost:9999"), "3.14 a callback to a port it may not listen on: refused BEFORE opening, the flag named (\(c.text.contains("9999")))")
        check(!seam.contains("file:///etc/passwd") && !seam.contains("127.0.0.1:5432"), "3.13 file: and this Mac's loopback are never opened")
        check(seam.contains("open-file default \(br)/doc.md") && seam.contains("reveal"), "3.15 a document of its folder opens; -R reveals it (\(seam.components(separatedBy: "\n").filter { $0.contains("file") || $0.contains("reveal") }))")
        check(!seam.contains("/etc/hosts") && !seam.contains("tool.sh") && c.text.contains("only files in its folder"), "3.15 outside its folder and an executable: refused")
        check(get(board) == "npm run dev\tX", "3.17 a copy reaches the clipboard (the seam)")
        check(c.text.contains("br (fenced) copied") && c.text.contains("npm run dev·X"), "3.17 the notice says (fenced) and the first characters, controls as ·")
        check(occurrences(hostLog(t), "asked to READ the Mac clipboard") == 1, "3.17 a read is never answered (logged once)")
        r = t.run(["sessions", "bridges", "@mac", "br", "--clipboard", "off", "--open-url", "off"])
        check(r.code == 0 && r.out.contains("clipboard off"), "doz sessions bridges @mac br --clipboard off --open-url off (live)")
        check(row("br")?.capabilities?.first { $0.id == "clipboard" }?.state == "off", "…the capability follows")
        FileManager.default.createFile(atPath: br + "/go2", contents: nil)
        check(t.waitFor(20) { FileManager.default.fileExists(atPath: br + "/S2") }, "the program copied and opened again")
        usleep(1_500_000)
        check(get(board) == "npm run dev\tX" && c.text.contains("clipboard is off"), "3.17 --clipboard off: not copied, said")
        check(!get(opened).contains("after") && c.text.contains("opening pages is off"), "a switched-off open is not opened, said")
    } catch { check(false, "attach on a pseudo-terminal: \(error)") }
    end("br")
    t.run(["sessions", "end", "@mac", "br", "--yes"], timeout: 60)
    t.run(["account", "rm", "ct", "--force"], timeout: 60)
}
