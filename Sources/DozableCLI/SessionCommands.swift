import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List the sandboxes: phase, RAM held, disk, sessions, network.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let rows = try decode(try await query(HostRequest(.ls), g), [SandboxInfo].self, g)
        if g.json { Out.json(rows); return }
        // The sessions on this Mac: one line of their own, last — never mixed into the sandbox rows.
        let mac = await MacCLI.summaryLine(g.dozableStore)
        if rows.isEmpty { Out.stdout("no sandboxes — doz up NAME --image lab|claude-code|pi\n" + (mac.map { $0 + "\n" } ?? "")); return }
        defer { if let mac { Out.stdout(mac + "\n") } }
        var t = [["NAME", "IMAGE", "PHASE", "RAM", "DISK", "SESSIONS", "AGENT", "NETWORK", "ACCOUNT", "WORKSPACE"]]
        for r in rows {
            var phase = Out.phaseLabel(r.phase) + (r.busy ? "…" : "")
            if r.diedWithHost == true { phase += " (died with host)" }
            if r.unresponsive == true { phase += " (unresponsive)" }       // 678 B7: its guest does not answer
            var net = r.network + ((r.deniedConnections ?? 0) > 0 ? " (\(r.deniedConnections!) denied)" : "")
            if let n = r.foreignCredentials, n > 0 { net += " · own key" + (n > 1 ? " ×\(n)" : "") }
            var account = r.account ?? "—"
            if let s = r.credentialState, s != "ok" { account += " (\(s))" }
            if r.credentialPolicy == "strict" { account += " · strict" }
            // 594 (D17): no workspace is said, not left blank.
            let ws = r.workspace.map { DisplayPath.tilde($0) } ?? "isolated"
            t.append([r.name, r.image, phase, Out.mib(r.ramHeldMiB), DozableImages.formatBytes(r.diskBytes),
                      r.sessions.map(String.init) ?? "—", r.agentStatus?.label ?? "—", net, account, ws])
        }
        Out.stdout(Out.table(t, rightAligned: [3, 4, 5]))
        // 594 W28: a sandbox whose system disk came from an image an older doz made.
        for r in rows { if let line = r.olderImageLine { Out.stdout("\(r.name): \(line)\n") } }
        // 679 B6: why a sandbox's Mac account reads as unreadable — the host's own session.
        if rows.contains(where: { $0.account == "mac" && $0.credentialState != nil && $0.credentialState != "ok" }) { sayHostKeychainNote(g) }
    }
}

struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Everything about a sandbox, as JSON (--prompt: the agent's environment prompt, as its next session gets it).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Print the environment prompt the agent gets at its next session (the facts block; --json adds the doz skill).") var prompt = false

    func run() async throws {
        if prompt {
            let r = try decode(try await query(HostRequest(.agentPrompt, name: name), g), AgentPromptReport.self, g)
            if g.json { Out.json(r); return }
            Out.stdout(Self.render(r, name: name))
            if r.enabled, r.error != nil { throw ExitCode(DozableExit.failed) }
            return
        }
        let v = try await query(HostRequest(.inspect, name: name), g)
        Out.json(try decode(v, SandboxDetail.self, g))
    }

    static func render(_ r: AgentPromptReport, name: String) -> String {
        guard r.enabled else {
            return "the environment prompt is off (agent.prompt = false) — \(name)'s agent gets no facts block and no doz skill\n"
        }
        if let e = r.error {
            return "the environment prompt of \(name) does not render: \(e)\nits sessions do not start until it does (or: doz config set agent.prompt false)\n"
        }
        let how = r.agent == "pi" ? "pi's --append-system-prompt \(r.promptPath)"
            : r.agent == "codex" ? "Codex's developer instructions (-c developer_instructions — the launcher reads \(r.promptPath))"
            : "Claude Code's --append-system-prompt (the launcher reads \(r.promptPath))"
        return "the environment prompt of \(name) (\(r.layers.joined(separator: " + "))) — \(how), written at every session start:\n\n"
            + (r.text ?? "") + "\n\nand the doz skill, \(r.skillPath) (\((r.skill ?? "").split(separator: "\n").count) lines; --json has its text)\n"
    }
}

/// `doz sessions NAME` (the list — the default) and, since 0.30.0, `doz sessions end|restart NAME SESSION`.
struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The sandbox's terminal sessions: list them (the default), end one, restart one, type into one, or read its screen.",
        subcommands: [SessionsList.self, SessionsEnd.self, SessionsRestart.self, SessionsSend.self, SessionsScreen.self, SessionsWait.self,
                      SessionsResume.self, SessionsBridges.self],
        defaultSubcommand: SessionsList.self)
}

/// A fenced session on this Mac: its bridges, read or changed live.
struct SessionsBridges: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bridges",
        abstract: "A fenced session on this Mac: what it may hand to you — open web pages, open documents of its folder, the clipboard (doz sessions bridges @mac SESSION).",
        discussion: """
            A fenced program cannot open anything on this Mac itself, so it asks through its terminal: a web page opens in your \
            browser, a document of its own folder in your app, a copy reaches your clipboard (never a read) — each one announced. \
            Each switch changes at once, for the next one; with none given, prints them. The settings mac.open_url, \
            mac.open_files and mac.clipboard (and doz run @mac --open-url / --open-files / --clipboard) decide a new session's.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Option(name: .customLong("open-url"), help: "on or off: it may open web pages in your browser.") var openURL: String?
    @Option(name: .customLong("open-files"), help: "on or off: it may open documents of its folder in your apps.") var openFiles: String?
    @Option(name: .long, help: "write or off: it may put text on your clipboard.") var clipboard: String?

    func validate() throws {
        for (flag, v, ok) in [("--open-url", openURL, ["on", "off"]), ("--open-files", openFiles, ["on", "off"]), ("--clipboard", clipboard, ["write", "off"])] {
            if let v, !ok.contains(v) { throw ValidationError("\(flag) \(v): \(ok.joined(separator: " or "))") }
        }
    }

    func run() async throws {
        guard MacPlace.isPlace(name) else { throw fail(HostError(.invalid, "bridges are switched here for a fenced session on this Mac — a sandbox's are doz config set --sandbox NAME"), g, code: DozableExit.usage) }
        var r = HostRequest(.sessionBridges, name: name)
        r.session = session
        if openURL != nil || openFiles != nil || clipboard != nil {
            var b = MacFenceRequest()
            b.openURL = openURL.map { $0 == "on" }
            b.openFiles = openFiles.map { $0 == "on" }
            b.clipboard = clipboard.map { $0 == "write" }
            r.macBridges = b
        }
        let got = try decode(try call(r, g), SessionBridges.self, g)
        if g.json { Out.json(got); return }
        let b = got.bridges
        Out.stdout("\(session) on this Mac: open URL \(b.openURL ? "on" : "off") · open files \(b.openFiles ? "on" : "off") · clipboard \(b.clipboard ? "write" : "off")"
                   + (got.changed == nil ? "" : " — from the next one") + "\n")
    }
}

/// A fenced session on this Mac stopped for a git config change: continue it.
struct SessionsResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume",
        abstract: "Continue a fenced session on this Mac that was stopped for a git config change (doz sessions resume @mac SESSION).",
        discussion: """
            A fenced session that changes a git config in a way a fenced program may not (a hook path, an fsmonitor, a pager, an \
            unknown key) is stopped at once, the change taken out and kept aside: doz sessions @mac --quarantine SESSION shows \
            it. Resuming continues every process of the session — refused while such a change is there again.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String

    func run() async throws {
        guard MacPlace.isPlace(name) else { throw fail(HostError(.invalid, "only a session on this Mac is stopped this way — doz sessions resume @mac SESSION"), g, code: DozableExit.usage) }
        var r = HostRequest(.sessionResume, name: name)
        r.session = session
        let got = try decode(try call(r, g), SessionResumed.self, g)
        if g.json { Out.json(got); return }
        Out.stdout("resumed session \(session) on this Mac (\(got.processes) process\(got.processes == 1 ? "" : "es"))\n")
    }
}

/// Wait until a session's program says it is idle, done, blocked or in error (its own OSC 7501 reports).
struct SessionsWait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait",
        abstract: "Wait until a session's program reports a state: idle, done, blocked or error (what doz sessions shows as AGENT).",
        discussion: """
            doz sessions wait NAME SESSION --until idle,done,blocked,error --timeout 90 (has it stopped working?). \
            --until takes a comma list, or is given again. Returns as soon as the program reports \
            one of them (now included), printing the state; exit 124 when --timeout seconds pass first (--json says \
            timedOut). Only programs that report their status (Claude Code, pi, Grok Build) ever arrive. The sandbox must be \
            running — a wait never wakes one; NAME may be @mac. A program that ends first: exit 2, unless its last report \
            matches. A sandbox named wait needs doz sessions ls wait. From a script (no terminal), doz sessions end and \
            restart need --yes.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Option(name: .long, parsing: .upToNextOption, help: "The state(s) to wait for — idle, working, done, blocked, error — as a comma list (idle,done,blocked,error) or repeated.") var until: [String] = []
    @Option(name: .long, help: "Give up after this many seconds (exit 124). Default: none (a wait ends after a day at most).") var timeout: Int64 = 0

    func validate() throws {
        let words = until.flatMap { $0.split(separator: ",").map(String.init) }
        if words.isEmpty { throw ValidationError("--until which state? idle, done, blocked or error") }
        for w in words where ProgramStatus.State(rawValue: w) == nil {
            throw ValidationError("--until \(w): one of \(ProgramStatus.State.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if timeout < 0 { throw ValidationError("--timeout is a number of seconds") }
    }

    func run() async throws {
        var r = HostRequest(.sessionWait, name: name)
        r.session = session
        r.until = until.flatMap { $0.split(separator: ",").map(String.init) }
        r.timeoutSeconds = timeout
        let w = try decode(try call(r, g), SessionWaited.self, g)
        if g.json { Out.json(w) } else if w.timedOut {
            Out.stderr("doz: \(session) \(MacCLI.inPlace(name)) did not become \(r.until!.joined(separator: " or ")) within \(timeout) s"
                       + (w.state.map { " (it is \($0))" } ?? "") + "\n")
        } else {
            Out.stdout("\(session) \(MacCLI.inPlace(name)): \(w.status?.label ?? w.state ?? "?")\n")
        }
        if w.timedOut { throw ExitCode(DozableExitCode.timedOut) }
    }
}

/// 678 B5: type into a session from a script.
struct SessionsSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send",
        abstract: "Type into a session: text, then keys, then Enter — it returns once the session's holder has every byte.",
        discussion: """
            doz sessions send NAME SESSION --text 'make test' --enter. In this order: --text (or --text - to read it from \
            stdin), then each --keys KEY as given (\(SessionInput.keyNames.joined(separator: ", "))), then --enter. --paste \
            wraps the text in a bracketed paste (an editor or Claude Code takes it as pasted, not typed). At most 64 KiB. A \
            sleeping or hibernated sandbox is woken first (--no-wake refuses instead); one that is shut down has no sessions. \
            The answer means the bytes reached the program's input, not that it acted on them: --then-screen[=MS] waits MS \
            milliseconds (alone: 0.6 s) and prints the screen as it is then. A sandbox named send needs doz sessions ls send.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Option(name: .long, help: "Text to type (- reads it from stdin).") var text: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Keys to press after the text, in order.") var keys: [String] = []
    @Flag(name: .long, help: "Press Enter last.") var enter = false
    @Flag(name: .long, help: "Send the text as a bracketed paste.") var paste = false
    @Flag(name: .long, help: "Fail instead of waking a sleeping sandbox.") var noWake = false
    @Option(name: .customLong("then-screen"), help: ArgumentHelp("Then wait this many milliseconds and print the session's screen (0.6 s when given as --then-screen alone).", valueName: "MS"))
    var thenScreen: Int?
    @Flag(name: .customLong("then-screen-default"), help: .hidden) var thenScreenDefault = false

    /// `--then-screen` alone means 600 ms (ArgumentParser has no optional value; DozableEntry rewrites the bare flag).
    static let defaultThenScreenMs = 600

    /// A bare `--then-screen` (last, or before another option) → `--then-screen-default`; `--then-screen MS` and
    /// `--then-screen=MS` stay. Only before `--`, and only in `sessions send`.
    static func normalized(_ args: [String]) -> [String] {
        guard let s = args.firstIndex(of: "sessions"), args.index(after: s) < args.endIndex, args[args.index(after: s)] == "send" else { return args }
        var out = args
        for i in out.indices where out[i] == "--then-screen" {
            if out[..<i].contains("--") { break }
            let next = i + 1 < out.count ? out[i + 1] : nil
            if next == nil || next!.hasPrefix("-") || Int(next!) == nil { out[i] = "--then-screen-default" }
        }
        return out
    }

    func validate() throws {
        if let t = thenScreen, t < 0 || t > 60_000 { throw ValidationError("--then-screen is 0 to 60000 milliseconds") }
    }

    func run() async throws {
        var input = text
        if text == "-" {
            let d = FileHandle.standardInput.readDataToEndOfFile()
            guard d.count <= SessionInput.maximumBytes else { throw fail(HostError(.invalid, "at most 64 KiB in one send"), g, code: DozableExit.usage) }
            input = String(decoding: d, as: UTF8.self)
        }
        let bytes: Data, pieces: [Data]
        do {
            bytes = try SessionInput.bytes(text: input, keys: keys, enter: enter, paste: paste)
            pieces = try SessionInput.pieces(text: input, keys: keys, enter: enter, paste: paste)
        } catch let e as SessionInput.InputError {
            throw fail(HostError(.invalid, e.message), g, code: DozableExit.usage)
        }
        var r = HostRequest(.sessionSend, name: name)
        r.session = session
        r.input = bytes
        r.inputPieces = pieces              // the text, each key and Enter written apart (a TUI reads the Enter alone)
        r.wake = !noWake
        let sent = try decode(try call(r, g), SessionSent.self, g)
        let wait = thenScreen ?? (thenScreenDefault ? Self.defaultThenScreenMs : nil)
        var screen: SessionLive?
        if let wait {
            try? await Task.sleep(for: .milliseconds(wait))
            var q = HostRequest(.sessionLive, name: name)
            q.session = session
            screen = try decode(try call(q, g), SessionLive.self, g)
        }
        if g.json {
            var j = try JSONValue(encoding: sent)
            if let screen, case .object(var o) = j { o["screen"] = try JSONValue(encoding: screen); j = .object(o) }
            Out.json(j)
            return
        }
        Out.stdout("sent \(sent.bytes) byte\(sent.bytes == 1 ? "" : "s") to \(session) \(MacCLI.inPlace(name))" + (sent.woke ? " (woken first)" : "") + "\n")
        if let screen { Out.stdout(screen.text.isEmpty ? "" : screen.text + "\n") }
    }
}

/// 678 B5: a session's screen now.
struct SessionsScreen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "screen",
        abstract: "A session's screen as it is now (its rows as text).",
        discussion: """
            While the sandbox runs: the screen now. Asleep or hibernated: its last saved screen, and stderr says so — \
            nothing is woken unless --wake. --json adds the cursor, the size, primary or alt, and the session's status. \
            Shut down: it has no sessions. A sandbox named screen needs doz sessions ls screen.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Flag(name: .long, help: "Wake a sleeping or hibernated sandbox first and read the screen live.") var wake = false

    func run() async throws {
        var r = HostRequest(.sessionLive, name: name)
        r.session = session
        r.wake = wake ? true : nil
        // Looking never starts the host — unless --wake asks for it.
        let s = try decode(wake ? try call(r, g) : try await query(r, g), SessionLive.self, g)
        if g.json { Out.json(s); return }
        if !s.live {
            let when = s.savedAt.map { " saved \(Out.ago($0))" } ?? ""
            Out.stderr(s.reason == "gone"
                ? "\(session) on this Mac is gone — this is its screen\(when), not live (doz sessions restart @mac \(session) starts it again)\n"
                : s.reason == "unresponsive"
                ? "\(name) does not answer — this is the screen\(when), not live\n"
                : "\(name) is not running — this is the screen\(when), not live (--wake wakes it)\n")
        }
        Out.stdout(s.text.isEmpty ? "" : s.text + "\n")
    }
}

struct SessionsEnd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "end",
        abstract: "End a session's program: it is hung up (as when its terminal closes), then terminated, then killed if it must be. Its viewers see it end.",
        discussion: "A running sandbox only — this never wakes one. What the program was doing is lost.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        if !MacPlace.isPlace(name) { try await requireSandbox(name, g) }
        try confirm("End session \(session) \(MacCLI.inPlace(name))? Its program stops; what it is doing now is lost.", yes: yes || g.json, g)
        var r = HostRequest(.sessionEnd, name: name)
        r.session = session
        let e = try decode(try call(r, g), SessionEnded.self, g)
        if g.json { Out.json(e); return }
        Out.stdout(e.how == "not-running" ? "session \(session) \(MacCLI.inPlace(name)) was not running\n"
                   : "ended session \(session) \(MacCLI.inPlace(name)) (\(SessionsEnd.howText(e.how)))\n")
        if let n = e.notice { Out.stdout("\(n)\n") }
    }

    static func howText(_ how: String) -> String {
        switch how {
        case "hangup": "it hung up"
        case "terminate": "it did not hang up — terminated"
        case "kill": "it ignored hangup and terminate — killed"
        default: how
        }
    }
}

struct SessionsRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart",
        abstract: "Restart a session: end its program and start the same one again, in the same folder. An agent's session continues its conversation — each Claude Code session its own; Codex's and pi's own session the folder's newest — only the turn in progress is lost.",
        discussion: """
            A running sandbox only — this never wakes one. --fresh starts a new conversation instead. \
            Afterwards it attaches, as doz run does, when stdin and stdout are a terminal; from a script \
            (no terminal), with --json or with -d it restarts the session and returns. --attach attaches \
            even without a terminal.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var session: String
    @Flag(name: .long, help: "A new conversation instead of continuing the last one (agent sessions).") var fresh = false
    @Flag(name: [.short, .customLong("detach")], help: "Restart it and return; attach later.") var detach = false
    @Flag(name: .long, help: "Attach afterwards even when stdin or stdout is not a terminal.") var attach = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    func validate() throws {
        if attach && detach { throw ValidationError("--attach and -d/--detach contradict each other — pick one") }
        if attach && g.json { throw ValidationError("--attach and --json contradict each other — --json answers and returns") }
    }

    /// Whether the restart attaches afterwards (610, issue 609.B2: a script's `doz sessions restart … --yes` attached and
    /// never returned). Only on a terminal — stdin AND stdout — unless asked for with --attach; never with -d or --json.
    static func attaches(detach: Bool, attach: Bool, json: Bool, stdinTTY: Bool, stdoutTTY: Bool) -> Bool {
        if detach || json { return false }
        return attach || (stdinTTY && stdoutTTY)
    }

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        if !MacPlace.isPlace(name) { try await requireSandbox(name, g) }
        try confirm("Restart session \(session) \(MacCLI.inPlace(name))? Its program stops and starts again; what it is doing now is lost.", yes: yes || g.json, g)
        var r = HostRequest(.sessionRestart, name: name)
        r.session = session
        r.fresh = fresh ? true : nil
        let size = terminalSize()
        r.cols = size.cols
        r.rows = size.rows
        let s = try decode(try call(r, g), SessionRestarted.self, g)
        if g.json { Out.json(s); return }
        if let n = s.notice { Out.stderr("[doz] \(n)\n") }
        Out.stdout("restarted session \(session) \(MacCLI.inPlace(name))" + (s.resumed ? " — its conversation continues" : "") + "\n")
        guard Self.attaches(detach: detach, attach: attach, json: g.json,
                            stdinTTY: isatty(STDIN_FILENO) != 0, stdoutTTY: isatty(STDOUT_FILENO) != 0) else { return }
        AttachClient.run(store: g.dozableStore, sandbox: name, session: session, wake: false, detachKey: key, quiet: g.quiet)
    }
}

struct SessionsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls",
        abstract: "The sandbox's terminal sessions (they survive pause, sleep and hibernate).",
        discussion: """
            While the sandbox is paused, asleep or hibernated, its sessions are listed from their saved screens \
            (saved when it pauses, sleeps or hibernates, and every host.screen_capture_minutes while it runs) — \
            nothing is woken. A shut-down sandbox has no sessions (Start boots it fresh). --screen SESSION \
            prints that session's last saved screen as text; add --vt to write the terminal bytes instead (to \
            a file or a pipe — never to a terminal).
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Print this session's last saved screen (text).") var screen: String?
    @Flag(name: .long, help: "With --screen: write the saved VT bytes (redraw with `cat` in a terminal) — only to a file or a pipe.") var vt = false
    @Option(name: .long, help: "@mac: what was taken out of this fenced session's git configs (why it stopped).") var quarantine: String?
    @Option(name: .long, help: "@mac: what this session can do — one line per capability (its fence, Keychain, network, settings folder, bridges…).") var capabilities: String?
    @Option(name: .long, help: "@mac: this fenced session's conversations kept in Dozable's archive.") var transcripts: String?
    @Option(name: .long, help: "With --transcripts: copy them into this folder.") var export: String?

    func run() async throws {
        if let screen { try await printScreen(screen); return }
        if vt { throw fail(HostError(.invalid, "--vt goes with --screen SESSION"), g, code: DozableExit.usage) }
        if (capabilities != nil || transcripts != nil), !MacPlace.isPlace(name) {
            throw fail(HostError(.invalid, "--capabilities and --transcripts are for doz sessions @mac"), g, code: DozableExit.usage)
        }
        if export != nil, transcripts == nil { throw fail(HostError(.invalid, "--export goes with --transcripts SESSION"), g, code: DozableExit.usage) }
        if let c = capabilities {
            let rows = try decode(try await query(HostRequest(.sessions, name: name), g), [SessionRow].self, g)
            guard let row = rows.first(where: { $0.name == c }), let caps = row.capabilities else {
                throw fail(HostError(.notFound, "no session \(c) on this Mac opened by doz (doz sessions @mac)"), g)
            }
            if g.json { Out.json(caps); return }
            Out.stdout("\(c) on this Mac — what it can do (\(row.fenced == true ? "fenced" : "no isolation")):\n" + MacFence.capabilitiesText(caps))
            return
        }
        if let s = transcripts {
            var r = HostRequest(.sessionTranscripts, name: name)
            r.session = s
            let got = try decode(try await query(r, g), MacTranscripts.Listing.self, g)
            if let dir = export {
                let to = URL(fileURLWithPath: dir).standardizedFileURL.path
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: to, isDirectory: &isDir), isDir.boolValue else {
                    throw fail(HostError(.invalid, "--export \(dir): not a folder"), g, code: DozableExit.usage)
                }
                var copied: [String] = []
                for i in got.items {
                    let name = "\(i.endedAt)-\(i.name)"
                    guard !FileManager.default.fileExists(atPath: to + "/" + name) else { continue }
                    // The archive is the host's (in the store); copied as it is, never through a link.
                    var st = stat()
                    guard lstat(i.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                    do { try FileManager.default.copyItem(atPath: i.path, toPath: to + "/" + name); copied.append(name) } catch {
                        throw fail(HostError(.failed, "--export: \(name): \(error.localizedDescription)"), g)
                    }
                }
                if g.json { Out.json(["exported": copied]); return }
                Out.stdout("exported \(copied.count) conversation\(copied.count == 1 ? "" : "s") of \(s) to \(DisplayPath.tilde(to))\n")
                return
            }
            if g.json { Out.json(got); return }
            if got.items.isEmpty {
                Out.stdout("no conversations of \(s) are kept in Dozable's archive" + (got.carriedTo.map { " (they are copied to \(DisplayPath.tilde($0)) when it ends)" } ?? "") + "\n")
                return
            }
            var t = [["ENDED", "CONVERSATION", "SIZE"]]
            for i in got.items { t.append([i.endedAt, i.name, "\(i.bytes / 1024) KiB"]) }
            Out.stdout(Out.table(t))
            if let to = got.carriedTo { Out.stderr("also copied back to \(DisplayPath.tilde(to)); doz sessions @mac --transcripts \(s) --export DIR copies these\n") }
            return
        }
        if let q = quarantine {
            guard MacPlace.isPlace(name) else { throw fail(HostError(.invalid, "--quarantine is for doz sessions @mac"), g, code: DozableExit.usage) }
            var r = HostRequest(.sessionQuarantine, name: name)
            r.session = q
            let got = try decode(try await query(r, g), SessionQuarantine.self, g)
            if g.json { Out.json(got); return }
            if got.items.isEmpty { Out.stdout("nothing was taken out of \(q)'s git configs\n"); return }
            for i in got.items { Out.stdout("── \(i.name)\n\(i.text)\n") }
            return
        }
        let rows = try decode(try await query(HostRequest(.sessions, name: name), g), [SessionRow].self, g)
        if g.json { Out.json(rows); return }
        if MacPlace.isPlace(name) {
            let fencedRows = rows.filter { $0.fenced == true }.count
            Out.stdout(rows.isEmpty
                       ? (DozableSettings.load().string(SettingKey.macFence) == "off"
                          ? "this Mac — new sessions have no isolation (mac.fence is off)\n"
                          : "this Mac — new sessions are fenced (doz run @mac --unfenced for none)\n")
                       : fencedRows == rows.count ? "this Mac — fenced sessions, each held to its folder\n"
                       : fencedRows > 0 ? "this Mac — fenced sessions are held to their folders; the others have no isolation\n"
                       : "this Mac — no isolation (your files, Keychain and network)\n")
            for s in rows where s.fence?.stoppedForGit != nil {
                Out.stderr("\(s.name) is STOPPED: a git config change a fenced session may not make (\(s.fence!.stoppedForGit!)) — doz sessions @mac --quarantine \(s.name); doz sessions resume @mac \(s.name)\n")
            }
            Out.stdout(rows.isEmpty ? "no sessions on this Mac — doz run @mac -d --session NAME --workdir DIR -- CMD\n" : MacCLI.table(rows))
            return
        }
        if rows.isEmpty {
            var ls = HostRequest(.ls)
            ls.withSessions = false
            let phase = (try? decode(try await query(ls, g), [SandboxInfo].self, g))?.first { $0.name == name }?.phase
            if phase == Phase.off.rawValue || phase == Phase.failed.rawValue {
                Out.stdout("no sessions — \(name) is \(phase == Phase.off.rawValue ? "shut down" : "failed") (doz start \(name) boots it fresh, with new sessions)\n")
            } else {
                Out.stdout("no sessions — doz run \(name) -- CMD, or doz up \(name)\n")
            }
            return
        }
        var t = [["SESSION", "PID", "SIZE", "CLIENTS", "STATE", "AGENT", "COMMAND"]]
        for s in rows {
            let state: String
            if s.saved == true {
                state = "screen saved" + (s.savedAt.map { " " + Out.ago($0) } ?? "")
            } else {
                state = s.ended ? "ended (exit \(s.exitCode.map(String.init) ?? "?"))" : "running"
            }
            t.append([s.name, s.pid.map(String.init) ?? "—", s.cols.map { "\($0)×\(s.rows ?? 0)" } ?? "—", "\(s.clients)", state,
                      s.status?.label ?? "—", s.command])
        }
        if rows.contains(where: { $0.saved == true }) {
            Out.stderr("\(name) is not running: its sessions as last saved (doz sessions \(name) --screen SESSION shows one)\n")
        }
        Out.stdout(Out.table(t))
    }

    /// S5: the last saved screen — text (inert) by default; the VT bytes only off a terminal.
    private func printScreen(_ session: String) async throws {
        var r = HostRequest(.sessionScreen, name: name)
        r.session = session
        let s = try decode(try await query(r, g), SessionScreen.self, g)
        if vt {
            guard isatty(STDOUT_FILENO) == 0 else {
                throw fail(HostError(.invalid, "--vt writes the guest's terminal bytes: send them to a file or a pipe, not a terminal"), g, code: DozableExit.usage)
            }
            FileHandle.standardOutput.write(s.vt)
            return
        }
        if g.json { Out.json(s); return }
        let size = s.cols.map { " · \($0)×\(s.rows ?? 0)" } ?? ""
        Out.stderr("\(name) · \(s.session) — saved \(Out.ago(s.savedAt)) (\(s.reason))\(size)\(s.truncated ? " · oldest scrollback dropped" : "")\n")
        Out.stdout(s.text.isEmpty ? "" : s.text + "\n")
    }
}

struct Attach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach this terminal to a session (a paused or sleeping sandbox is woken).",
        discussion: "Ctrl-] opens a one-line menu (d detach · n next · p prev · s sessions · Esc back); Ctrl-] twice detaches (the session keeps running). The terminal's title is ui.terminal_title while attached. Hibernating disconnects you; the client waits and reattaches when the sandbox runs again.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The session (default: the image's own — claude, pi or shell).") var session: String?
    @Flag(name: .long, help: "Do not wake a sleeping sandbox; wait for it instead.") var noWake = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        noteHostBuild(g)                // W33: before the terminal is taken over
        AttachClient.run(store: g.dozableStore, sandbox: name, session: session, wake: !noWake, detachKey: key, quiet: g.quiet)
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a NEW session running a program, and attach to it. Exits with the program's exit code.",
        discussion: """
            doz run NAME -- top. The program starts without a shell in front of it; say `-- bash -lc '…'` for one. \
            doz run @mac -- CMD runs it on THIS Mac instead, held like a sandbox's session, and by default FENCED \
            (no CMD: your login shell): it reads and writes only its folder (--workdir, default: the one you \
            are in) and its own temp and caches, reads your tools but not your secrets or other folders, cannot use your \
            Keychain (--keychain opens it), and reaches the network only through Dozable's proxy, by its permissions \
            (--permissions, the setting mac.permissions; doz net allow|deny @mac --session SESSION changes them live) — never \
            this Mac's own addresses, and its own ports only with --local-port N; a git config change a fenced program may \
            not make stops it until doz sessions resume @mac SESSION. --github read|push gives it GitHub as you (the token \
            stays on the Mac; read-only refuses pushes), --ssh-agent your SSH agent for listing and signing only (git over \
            ssh goes through the proxy), --xcode Xcode's build services (DerivedData in the session: -derivedDataPath \
            "$DOZ_DERIVED"), --simulator the Simulator too (a guard rail, not a boundary: what it launches runs outside). \
            doz run @mac --unfenced -- CMD runs it with no isolation at all: your files, Keychain and network (--workdir \
            default your home) — what signing and notarisation need. The setting mac.fence (on by default) decides for a \
            new session; a session keeps its mode when it is restarted.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "The session's name (default: the program's).") var session: String?
    @Option(name: .long, help: "Working directory in the guest (@mac: on this Mac).") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE for the program (repeatable).") var env: [String] = []
    @Flag(name: [.short, .customLong("detach")], help: "Start it and return; attach later.") var detach = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    @Flag(name: .long, help: "Fail instead of starting (cold-booting) a sandbox that is off.") var noStart = false
    @Flag(name: .long, help: "@mac: run it fenced (the default; setting mac.fence) — its folder, its own temp and caches; your Keychain, secrets and other folders closed.") var fenced = false
    @Flag(name: .long, help: "@mac: run it with no isolation at all, whatever mac.fence says.") var unfenced = false
    @Flag(name: .long, help: "@mac, fenced: open your Keychain to it (signing, notarisation — and your saved logins).") var keychain = false
    @Option(name: .customLong("read"), help: "@mac, fenced: one more folder it may read (repeatable).") var readDirs: [String] = []
    @Option(name: .customLong("write"), help: "@mac, fenced: one more folder it may read and write (repeatable).") var writeDirs: [String] = []
    @Option(name: .customLong("permissions"), parsing: .unconditionalSingleValue,
            help: "@mac, fenced: what it may reach through Dozable's proxy — standard/locked/open, PERMISSION, -PERMISSION, site:HOST (doz net permissions); comma-separated or repeated (setting mac.permissions).")
    var permissions: [String] = []
    @Option(name: .customLong("local-port"), help: "@mac, fenced: a port of this Mac's loopback it may listen on and connect to — its dev server, a sign-in callback (repeatable).")
    var localPorts: [Int] = []
    @Option(name: .customLong("agent-config"), help: "@mac, fenced: the agent's settings folder — private (its own; your instructions and skills read-only) or shared (your own: less isolated) (setting mac.agent_config).")
    var agentConfig: String?
    @Option(name: .long, help: "@mac, fenced: keep its conversations (keep: copied back to yours and archived) or follow the agent's own rule (agent-default) (setting agent.history).")
    var history: String?
    @Option(name: .long, help: "@mac, fenced: the Claude login swapped in by Dozable's proxy — an account (doz account ls), mac or none (setting mac.account).")
    var account: String?
    @Option(name: .customLong("open-url"), help: "@mac, fenced: on or off — it may open web pages in your browser, each announced (setting mac.open_url).")
    var openURL: String?
    @Option(name: .customLong("open-files"), help: "@mac, fenced: on or off — it may open documents of its folder in your apps (setting mac.open_files).")
    var openFiles: String?
    @Option(name: .long, help: "@mac, fenced: write or off — it may put text on your clipboard, each copy announced (setting mac.clipboard).")
    var clipboard: String?
    @Flag(name: .long, help: "@mac, fenced: Xcode's build services too (xcodebuild with -derivedDataPath \"$DOZ_DERIVED\"); LaunchServices and the Simulator stay closed.") var xcode = false
    @Flag(name: .long, help: "@mac, fenced: --xcode and the Simulator — LaunchServices and the Simulator open; what they launch runs OUTSIDE the fence (a guard rail, not a boundary).") var simulator = false
    @Option(name: .long, help: "@mac, fenced: GitHub as you through Dozable's proxy — off, read (clone and read; pushes refused) or push; the token never enters the session.")
    var github: String?
    @Flag(name: .customLong("ssh-agent"), help: "@mac, fenced: your SSH agent, filtered to listing keys and signing (git over ssh, signed commits); never adding, removing or reading keys.") var sshAgent = false
    @Flag(name: .customLong("dry-run"), help: "@mac: say what the session would be able to do, and open nothing.") var dryRun = false
    @Argument(parsing: .postTerminator, help: "The program and its arguments, after --.") var command: [String] = []

    var fenceFlags: Bool {
        keychain || !readDirs.isEmpty || !writeDirs.isEmpty || !permissions.isEmpty || !localPorts.isEmpty || agentConfig != nil || history != nil
            || account != nil || openURL != nil || openFiles != nil || clipboard != nil || xcode || simulator || github != nil || sshAgent
    }

    func validate() throws {
        if command.isEmpty, !MacPlace.isPlace(name) { throw ValidationError("which program? doz run NAME -- CMD…") }
        if MacPlace.isPlace(name), user != nil { throw ValidationError("--user does not apply on this Mac: its sessions run as you") }
        if !MacPlace.isPlace(name), fenced || unfenced || fenceFlags || dryRun {
            throw ValidationError("--fenced, --unfenced, --keychain, --read, --write, --permissions, --local-port, --agent-config, --history, --account, --open-url, --open-files, --clipboard, --xcode, --simulator, --github, --ssh-agent and --dry-run are for doz run @mac (a sandbox is a VM of its own)")
        }
        if fenced && unfenced { throw ValidationError("--fenced and --unfenced contradict each other — pick one") }
        if unfenced && fenceFlags {
            throw ValidationError("--keychain, --read, --write, --permissions, --local-port, --agent-config, --history, --account, --open-url, --open-files, --clipboard, --xcode, --simulator, --github and --ssh-agent are for a fenced session — not with --unfenced")
        }
        for (flag, v, ok) in [("--agent-config", agentConfig, MacAgentConfig.modes), ("--history", history, AgentHistory.values),
                              ("--open-url", openURL, ["on", "off"]), ("--open-files", openFiles, ["on", "off"]), ("--clipboard", clipboard, ["write", "off"]),
                              ("--github", github, ["off", "read", "push"])] {
            if let v, !ok.contains(v) { throw ValidationError("\(flag) \(v): \(ok.joined(separator: " or "))") }
        }
        if let a = account, a.isEmpty || a.count > 64 { throw ValidationError("--account: an account's name, mac or none") }
    }

    /// The fence request this run sends (nil: unfenced).
    func fenceRequest(_ settings: DozableSettings, absolute: (String) -> String) -> MacFenceRequest {
        var q = MacFenceRequest(keychain: (keychain || settings.string(SettingKey.macKeychain) == "on") ? true : nil,
                                read: readDirs.isEmpty ? nil : readDirs.map(absolute),
                                write: writeDirs.isEmpty ? nil : writeDirs.map(absolute),
                                permissions: permissions.isEmpty ? [settings.string(SettingKey.macPermissions) ?? "standard"] : permissions,
                                localPorts: localPorts.isEmpty ? nil : localPorts)
        q.agentConfig = agentConfig
        q.history = history
        q.account = account
        q.openURL = openURL.map { $0 == "on" }
        q.openFiles = openFiles.map { $0 == "on" }
        q.clipboard = clipboard.map { $0 == "write" }
        q.xcode = xcode || simulator ? true : nil
        q.simulator = simulator ? true : nil
        q.github = github.flatMap { $0 == "off" ? nil : $0 }
        q.sshAgent = sshAgent ? true : nil
        return q
    }

    /// `--dry-run`: the capabilities of the session this would open (from the flags and the settings — the same one
    /// source as `doz sessions @mac --capabilities`). Opens nothing, asks no host.
    func dryRunShape(_ settings: DozableSettings, fence: Bool, workdir: String, absolute: (String) -> String) -> MacCapabilityShape {
        let argv = command.isEmpty ? [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "-l"] : command
        return MacCapabilityShape.planned(session: session ?? ((argv[0] as NSString).lastPathComponent), workdir: workdir, argv: argv,
                                          fenced: fence, request: fence ? fenceRequest(settings, absolute: absolute) : nil,
                                          settings: settings, home: MacSessions.plannedHome())
    }

    /// Whether this `doz run @mac` is fenced: the flag, else `mac.fence` (its environment variable, the file), else its
    /// default — ON since 683 M6. Only a NEW session reads this; a restart, resume or adoption keeps the record's mode.
    func fencedOnMac(_ settings: DozableSettings) -> Bool {
        if fenced { return true }
        if unfenced { return false }
        if fenceFlags { return true }
        return settings.string(SettingKey.macFence) == "on"
    }

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        let onMac = MacPlace.isPlace(name)
        let settings = DozableSettings.load()
        let fence = onMac && fencedOnMac(settings)
        if dryRun {
            func abs(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
            let wd = workdir.map(abs) ?? (fence ? FileManager.default.currentDirectoryPath : NSHomeDirectory())
            let caps = MacFence.capabilities(dryRunShape(settings, fence: fence, workdir: wd, absolute: abs))
            if g.json { Out.json(caps); return }
            Out.stdout("doz run @mac would open a session that can (\(fence ? "fenced" : "no isolation") — nothing was started):\n" + MacFence.capabilitiesText(caps))
            return
        }
        if onMac, !fence, !g.quiet { Out.stderr("[doz] \(MacPlace.noIsolationLine)\n") }
        var r = HostRequest(.openSession, name: name)
        r.start = !noStart      // 594 W27: an off sandbox boots first
        r.session = session
        r.argv = command.isEmpty ? nil : command
        // A folder on this Mac is absolute (the host runs elsewhere): relative to where doz runs. A fenced session's
        // folder is, by default, the one doz runs in.
        func absolute(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        r.workdir = onMac ? (workdir.map(absolute) ?? (fence ? FileManager.default.currentDirectoryPath : nil)) : workdir
        r.user = user
        r.environment = try parseEnv(env)
        if fence {
            r.v = HostProtocol.fencedVersion
            r.macFence = fenceRequest(settings, absolute: absolute)
        }
        let size = terminalSize()
        r.cols = size.cols
        r.rows = size.rows
        // A program the sandbox does not have is doz's failure, not the program's: 125, like exec.
        let m = try rawCall(r, g)
        guard m.ok == true else {
            var e = m.error ?? HostError(.failed, "the host gave no reason")
            if fence, e.code == .version {
                e = HostError(.unavailable, "the host running now predates fenced sessions — doz host stop, then run this again (nothing was started)")
            }
            throw fail(e, g, code: e.code == .notFound && r.argv != nil ? DozableExit.dozableFailed : nil)
        }
        let opened = try decode(m.result ?? .null, SessionOpened.self, g)
        if fence, opened.fenced != true {
            // Never run unfenced silently: a host that did not fence it says nothing of a fence.
            throw fail(HostError(.failed, "the host did not open \(opened.session) fenced — doz sessions end @mac \(opened.session); doz host stop, then run this again"), g)
        }
        if !g.json, let n = opened.notice { Out.stderr("[doz] \(n)\n") }
        if fence, !g.quiet, !g.json {
            if let line = opened.fenceLine { Out.stderr("[doz] \(line)\n") }
            for n in opened.fenceNotes ?? [] { Out.stderr("[doz] note: \(n)\n") }
        }
        if onMac, opened.bypassed == true, !g.quiet {
            Out.stderr("[doz] session \(opened.session): \(fence ? "permissions bypassed — fenced" : MacPlace.bypassedMark) (its own command line asked for it)\n")
        }
        if detach || g.json {
            if g.json { Out.json(opened) } else if onMac {
                Out.stdout("session \(opened.session) \(opened.created ? "started" : "is already running") on this Mac — doz attach @mac \(opened.session)\n")
            } else {
                Out.stdout("session \(opened.session) \(opened.created ? "started" : "is already running") in \(name) — \(reattachCommand(sandbox: name, session: opened.session, defaultSession: opened.defaultSession))\n")
            }
            return
        }
        AttachClient.run(store: g.dozableStore, sandbox: name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
    }
}

func parseEnv(_ pairs: [String]) throws -> [String: String]? {
    guard !pairs.isEmpty else { return nil }
    var out: [String: String] = [:]
    for p in pairs {
        guard let eq = p.firstIndex(of: "="), eq != p.startIndex else { throw ValidationError("--env \(p): KEY=VALUE") }
        out[String(p[..<eq])] = String(p[p.index(after: eq)...])
    }
    return out
}

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in the sandbox, non-interactively; its output and exit code pass through.",
        discussion: "doz exec NAME -- CMD…. No terminal, no stdin; for an interactive program use run. A paused or sleeping sandbox is woken first, and one that is off is started (--no-wake, --no-start refuse instead).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Working directory in the guest (default: the session's).") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user; `root` for root).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE (repeatable).") var env: [String] = []
    @Option(name: .long, help: "Give up after this many seconds, counted from when doz started — a wake or a start included; exit code 124 (--json says timedOut). The command is killed; a wake or a start under way goes on. Default 120.") var timeout: Int64 = 120
    @Flag(name: .long, help: "Fail instead of waking a sleeping sandbox.") var noWake = false
    @Flag(name: .long, help: "Fail instead of starting (cold-booting) a sandbox that is off.") var noStart = false
    @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("which command? doz exec NAME -- CMD…") }
    }

    /// 678: what the deadline stopped, in words.
    static func during(_ w: String?) -> String {
        switch w {
        case "waking": return " — the sandbox was still waking (the wake goes on)"
        case "starting": return " — the sandbox was still starting (the start goes on)"
        case "running": return " — the command was killed"
        default: return ""
        }
    }

    func run() async throws {
        var r = HostRequest(.exec, name: name)
        r.argv = command
        r.workdir = workdir
        r.user = user
        r.environment = try parseEnv(env)
        // 678: the deadline counts from when this doz started (its watchdog, `ExecDeadline.arm`, ends it a little
        // after); the host answers at it whatever is under way. An older host gets the seconds left.
        if timeout > 0 {
            let deadline = ExecDeadline.deadline(seconds: timeout, start: ProcessStart.date ?? Date())
            r.deadline = deadline.timeIntervalSince1970
            r.timeoutSeconds = ExecDeadline.remaining(deadline)
        } else {
            r.timeoutSeconds = timeout
        }
        r.wake = !noWake
        r.start = !noStart      // 594 W27: an off sandbox boots first (its progress on stderr)
        let m = try rawCall(r, g)
        guard m.ok == true, let v = m.result else {
            throw fail(m.error ?? HostError(.failed, "exec failed"), g, code: DozableExit.dozableFailed)
        }
        let out = try decode(v, ExecOutput.self, g)
        if g.json {
            var j: [String: JSONValue] = ["exitCode": .number(Double(out.exitCode)), "stdout": .string(String(decoding: out.stdout, as: UTF8.self)),
                                          "stderr": .string(String(decoding: out.stderr, as: UTF8.self)), "milliseconds": .number(out.milliseconds),
                                          // 594 W27: what had to happen first.
                                          "started": .bool(out.started == true), "woke": .bool(out.woke == true)]
            if let b = out.bootMilliseconds { j["bootMilliseconds"] = .number(b) }
            // 678: a deadline's 124 is told apart from a program's own.
            if out.timedOut == true { j["timedOut"] = .bool(true) }
            if let w = out.timedOutDuring { j["timedOutDuring"] = .string(w) }
            Out.json(j)
        } else {
            FileHandle.standardOutput.write(out.stdout)
            FileHandle.standardError.write(out.stderr)
            if out.timedOut == true {
                Out.stderr("\(ExecDeadline.message(timeout))\(Self.during(out.timedOutDuring))\n")
            }
        }
        if out.exitCode != 0 { throw ExitCode(out.exitCode) }
    }
}
