// `doz-vmtest cli-agentstream --doz PATH` (`make test-cli-agentstream`): `doz agent-stream` end to end — the REAL signed doz
// from separate processes, a store of its own (`/tmp/dzo-PID-as`), FAKE agents only (a line-echo shell loop that can be slow,
// ignore SIGHUP, or keep running after its input ends). Parts (AGENTSTREAM_PARTS, comma-separated; default the first five):
//
//   framing   — the exit code passes through; stdout and stderr live and apart; 3 MB out, 2 MB in; the ready answer; inspect
//               lists the open stream; host.log has the program's name and byte counts, never its text
//   user      — the image's user by default, --user root, --user another
//   lifecycle — pause and sleep stall a stream that then continues; a line sent to a paused or asleep sandbox wakes it;
//               hibernate severs it (`sleeping`) within 1 s of the command, shut down (`stopped`), host stop
//               (`host-stopping`) before `doz host stop` returns — exit 75 and one stderr line each
//   orphan    — a program that ignores SIGHUP, severed by hibernate and by a host stop: after the wake (and the new host's
//               adoption) a new stream opens beside exactly ONE fake-agent process — the orphan was ended first (TERM)
//   hangup    — a client killed mid-stream leaves no guest process of it after 6 s; killed while paused, it is ended at the
//               resume (never woken to clean up)
//   env       — (prepares claude-code; network) the stream runs as the agent; its environment, read as the agent, holds a
//               `doz_cred_…` placeholder and never the FAKE key it was given
//   claude    — (owner-run: DOZ_TEST_CLAUDE_LOGIN=1 with DOZ_TEST_REAL_MAC=1, this Mac's login read-only) a real two-turn
//               stream-json chat, severed by hibernate (exit 75), resumed with --resume: it remembers turn 1, one claude
//               process is left, and the resume time is reported
import Darwin
import Foundation
import DozableKit
import DozableHost

/// The fake agent: `ready PID`, then each input line as `out:LINE` (stdout) and `err:LINE` (stderr); `slow N` sleeps N s
/// first; `exit N` exits N. Mode `hold` keeps running after its input ends; `nohup-hold` also ignores SIGHUP (its children
/// inherit that) and SIGPIPE (its dead stdout) — an orphan only TERM or KILL ends.
private let fakeAgent = #"""
#!/bin/sh
case "$1" in nohup*) trap '' HUP PIPE ;; esac
echo "ready $$"
while IFS= read -r l; do
  case "$l" in
    slow\ *) sleep "${l#slow }"; echo "slow-done" ;;
    exit\ *) exit "${l#exit }" ;;
    *) echo "out:$l"; echo "err:$l" >&2 ;;
  esac
done
echo "eof"
case "$1" in *hold) while :; do sleep 1; done ;; esac
exit 0
"""#

/// Lists the guest's processes that carry an agent stream's marker: `PID PGRP SID` each (zombies left out).
private let markedProcesses = #"""
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -q '^DOZ_AGENT_STREAM_ID=' || continue
  s=$(cat "$d/stat" 2>/dev/null) || continue
  s=${s##*) }; set -- $s
  [ "$1" = Z ] && continue
  echo "$p $3 $4"
done
"""#

/// Collects a pipe on its own thread, with WHEN text arrived.
private final class TimedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var marks: [(Date, Int)] = []
    init(_ h: FileHandle) {
        Thread.detachNewThread { [self] in
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                lock.lock(); data.append(d); marks.append((Date(), data.count)); lock.unlock()
            }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var bytes: Data { lock.withLock { data } }
    /// When `needle` was first wholly there.
    func when(_ needle: String) -> Date? {
        lock.withLock {
            guard let r = data.range(of: Data(needle.utf8)) else { return nil }
            return marks.first { $0.1 >= r.upperBound }?.0
        }
    }
}

/// One `doz agent-stream` in the background: stdin a pipe, stdout and stderr collected with their times.
private final class StreamClient: @unchecked Sendable {
    let process: Process
    let input = Pipe()
    let out: TimedCollector
    let err: TimedCollector
    private let lock = NSLock()
    private var _exitedAt: Date?

    init(_ h: CLIHarness, _ args: [String], env extra: [String: String] = [:]) throws {
        process = h.process(["agent-stream"] + args)
        process.environment = h.env.merging(extra) { $1 }
        let o = Pipe(), e = Pipe()
        process.standardOutput = o
        process.standardError = e
        process.standardInput = input
        out = TimedCollector(o.fileHandleForReading)
        err = TimedCollector(e.fileHandleForReading)
        let box = self
        process.terminationHandler = { _ in box.lock.withLock { box._exitedAt = Date() } }
        try process.run()
    }

    var exitedAt: Date? { lock.withLock { _exitedAt } }
    func send(_ line: String) { try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
    func closeInput() { try? input.fileHandleForWriting.close() }

    func waitOut(_ seconds: Double, _ needle: String) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if out.text.contains(needle) { return true }; usleep(50_000) }
        return out.text.contains(needle)
    }

    func exited(within seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func kill9() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    func close() {
        closeInput()
        if exited(within: 5) == nil { kill9() }
    }
}

func cliAgentStreamSuite(binary: String, parts: Set<String>) async {
    let t = onboardingHarness(binary, "as", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: agent-stream — a program on a pipe (676), parts: \(parts.sorted().joined(separator: ","))")
    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    let lab = "as1"
    let lifecycleParts: Set<String> = ["framing", "user", "lifecycle", "orphan", "hangup"]
    if !parts.isDisjoint(with: lifecycleParts) {
        check(t.run(["create", lab, "--image", "lab", "--isolated", "--memory", "512M", "--start"], timeout: 900).code == 0, "create \(lab) --image lab --start")
        let script = Data(fakeAgent.utf8).base64EncodedString()
        check(t.run(["exec", lab, "--", "sh", "-c", "echo \(script) | base64 -d > /tmp/fake-agent.sh && chmod 755 /tmp/fake-agent.sh"]).code == 0,
              "the fake agent is in the guest")
    }
    let fake = "/tmp/fake-agent.sh"
    /// The guest's processes that carry a stream's marker (read as root — the lab's streams run as root).
    func marked() -> [(pid: Int, pgrp: Int, sid: Int)] {
        t.run(["exec", lab, "--", "sh", "-c", markedProcesses]).out.split(separator: "\n").compactMap { l in
            let f = l.split(separator: " ").compactMap { Int($0) }
            return f.count == 3 ? (f[0], f[1], f[2]) : nil
        }
    }
    func phase(_ name: String) -> String { t.row(name)?.phase ?? "?" }
    func open(_ label: String, _ mode: String? = nil, env: [String: String] = [:]) -> StreamClient? {
        guard let s = try? StreamClient(t, [lab, "--stream", label, "--", fake] + (mode.map { [$0] } ?? []), env: env) else {
            check(false, "could not run doz agent-stream"); return nil
        }
        check(s.waitOut(60, "ready "), "stream \(label)\(mode.map { " (\($0))" } ?? ""): the fake agent runs")
        return s
    }

    if parts.contains("framing") {
        print("agent-stream: framing")
        var r = t.run(["agent-stream", lab, "--", "sh", "-c", "exit 3"])
        check(r.code == 3, "doz agent-stream \(lab) -- sh -c 'exit 3' exits 3 (\(r.code))")
        if let s = open("frame", env: ["DOZ_AGENT_STREAM_READY": "1"]) {
            check(s.err.text.contains("doz-agent-stream ready ") && s.err.text.contains("\"stream\":\"frame\""), "DOZ_AGENT_STREAM_READY=1: the ready answer on stderr")
            s.send("zebra-7731")
            check(s.waitOut(10, "out:zebra-7731"), "a line in → its answer on stdout")
            let deadline = Date().addingTimeInterval(5)
            while !s.err.text.contains("err:zebra-7731") && Date() < deadline { usleep(50_000) }
            check(s.err.text.contains("err:zebra-7731") && s.process.isRunning, "…its stderr arrives live, while the program runs")
            check(!s.out.text.contains("err:") && !s.err.text.contains("out:"), "stdout and stderr stay apart")
            let streams = t.json(["inspect", lab], SandboxDetail.self)?.agentStreams ?? []
            check(streams.count == 1 && streams.first?.stream == "frame" && streams.first?.argv0 == fake && (streams.first?.stdinBytes ?? 0) == 11,
                  "inspect: the open stream, its program and its byte counts (\(streams.map { "\($0.stream) \($0.argv0) in \($0.stdinBytes) out \($0.stdoutBytes) pid \($0.pid.map(String.init) ?? "-")" }))")
            s.closeInput()
            let code = s.exited(within: 10)
            check(code == 0 && s.out.text.contains("eof"), "stdin's end reaches the program (F): it says eof and exits 0 (\(code.map(String.init) ?? "running"))")
        }
        r = t.run(["agent-stream", lab, "--", "sh", "-c", "yes 0123456789abcdef | head -c 3000000"], timeout: 120)
        check(r.code == 0 && r.outData.count == 3_000_000, "3 MB out, in frames of at most 1 MiB (\(r.outData.count) bytes)")
        r = t.run(["agent-stream", lab, "--", "wc", "-c"], stdin: Data(repeating: 0x61, count: 2_000_000), timeout: 120)
        check(r.code == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "2000000", "2 MB in (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
        r = t.run(["agent-stream", lab, "--", "/no/such/program"])
        check(r.code == 125 && r.err.contains("does not exist"), "a missing program is said plainly (\(r.code): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)))")
        let log = hostLog(t)
        check(log.contains("agent-stream frame opened — fake-agent.sh as root"), "host.log: the stream's open (the program's name, its user)")
        check(log.range(of: #"agent-stream frame ended — exit 0 \(\d+ bytes out, 11 in"#, options: .regularExpression) != nil, "host.log: its end, with byte counts")
        check(!log.contains("zebra-7731"), "host.log never has the program's input or output")
    }

    if parts.contains("user") {
        print("agent-stream: the user")
        check(t.run(["exec", lab, "--", "sh", "-c", "id streamer >/dev/null 2>&1 || adduser -D streamer"]).code == 0, "a second guest user")
        let def = t.run(["agent-stream", lab, "--", "id", "-un"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        check(def == "root", "by default the image's user (the lab's is root): \(def)")
        let other = t.run(["agent-stream", lab, "--user", "streamer", "--", "id", "-un"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        check(other == "streamer", "--user streamer: \(other)")
        let root = t.run(["agent-stream", lab, "--user", "root", "--", "id", "-un"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        check(root == "root", "--user root: \(root)")
    }

    if parts.contains("lifecycle") {
        print("agent-stream: the lifecycle")
        if let s = open("life") {
            s.send("a")
            check(s.waitOut(10, "out:a"), "the stream answers")
            // Pause: it stalls (nothing is lost, the connection holds), then continues after resume.
            check(t.run(["pause", lab]).code == 0 && phase(lab) == "paused", "pause")
            usleep(2_000_000)
            check(s.process.isRunning && !s.out.text.contains("out:b"), "paused: the stream is held, connected")
            check(t.run(["resume", lab]).code == 0, "resume")
            s.send("b")
            check(s.waitOut(10, "out:b"), "…and continues on the same connection")
            // A line written to a paused sandbox wakes it.
            check(t.run(["pause", lab]).code == 0, "pause again")
            s.send("c")
            check(s.waitOut(20, "out:c") && phase(lab) == "running", "a line sent to the PAUSED sandbox woke it (\(phase(lab)))")
            // Sleep mid-turn: the turn stalls and finishes after the wake.
            s.send("slow 2")
            usleep(300_000)
            check(t.run(["sleep", lab], timeout: 180).code == 0 && phase(lab) == "asleep", "sleep, mid-turn")
            usleep(3_000_000)
            check(!s.out.text.contains("slow-done") && s.process.isRunning, "asleep: the turn is stalled, the stream connected")
            check(t.run(["wake", lab], timeout: 300).code == 0, "wake")
            check(s.waitOut(15, "slow-done"), "…the turn finishes on the same connection")
            // A line written to an asleep sandbox wakes it.
            check(t.run(["sleep", lab], timeout: 180).code == 0, "sleep again")
            s.send("d")
            check(s.waitOut(30, "out:d") && phase(lab) == "running", "a line sent to the ASLEEP sandbox woke it (\(phase(lab)))")
            // Hibernate severs it, within 1 s of the command.
            let r = t.run(["hibernate", lab], timeout: 300)
            let returned = Date()
            let code = s.exited(within: 10)
            check(r.code == 0 && code == 75, "hibernate: the stream exits 75 (\(code.map(String.init) ?? "still running"))")
            check(s.err.text.contains("doz agent-stream: severed (sleeping)"), "…saying `doz agent-stream: severed (sleeping)`")
            let lag = (s.exitedAt ?? .distantFuture).timeIntervalSince(returned)
            check(lag <= 1.0, String(format: "…within 1 s of the command (%.2f s after it returned)", lag))
        }
        check(t.run(["wake", lab], timeout: 300).code == 0, "wake")
        if let s = open("life") {
            check(t.run(["shutdown", lab, "--yes"], timeout: 300).code == 0, "shutdown")
            let code = s.exited(within: 10)
            check(code == 75 && s.err.text.contains("doz agent-stream: severed (stopped)"), "shutdown: exit 75, severed (stopped) (\(code.map(String.init) ?? "still running"))")
        }
        check(t.run(["start", lab], timeout: 600).code == 0, "start")
        _ = t.run(["exec", lab, "--", "sh", "-c", "echo \(Data(fakeAgent.utf8).base64EncodedString()) | base64 -d > /tmp/fake-agent.sh && chmod 755 /tmp/fake-agent.sh"])
        if let s = open("life") {
            let r = t.run(["host", "stop"], timeout: 300)
            let returned = Date()
            let code = s.exited(within: 10)
            let told = s.err.when("severed (host-stopping)")
            check(r.code == 0 && code == 75 && told != nil, "host stop: exit 75, severed (host-stopping) (\(code.map(String.init) ?? "still running"))")
            if let told { check(told <= returned, String(format: "…before `doz host stop` returned (%.2f s before)", returned.timeIntervalSince(told))) }
        }
        check(t.run(["wake", lab], timeout: 300).code == 0, "wake (a new host)")
    }

    if parts.contains("orphan") {
        print("agent-stream: orphans are ended before the next stream")
        if phase(lab) != "running" { _ = t.run(["wake", lab], timeout: 300) }
        let before = occurrences(hostLog(t), "agent-reap ")
        if let s = open("orph", "nohup-hold") {
            let m = marked()
            info("the stream's program in the guest: " + m.map { "pid \($0.pid) pgrp \($0.pgrp) sid \($0.sid)" }.joined(separator: "; "))
            check(m.count >= 1 && m[0].pid == m[0].pgrp && m[0].pid == m[0].sid, "it leads its own process group and session (vmexec's setsid)")
            check(t.run(["hibernate", lab], timeout: 300).code == 0 && s.exited(within: 10) == 75, "hibernate severs it (75)")
        }
        check(t.run(["wake", lab], timeout: 300).code == 0, "wake")
        if let s = open("orph") {
            let m = marked()
            check(m.count == 1, "a new stream opens beside exactly ONE fake-agent process — none of the orphan's, nor its children (\(m.count))")
            let log = hostLog(t)
            check(occurrences(log, "agent-reap ") > before && (log.contains("agent-reap terminate") || log.contains("agent-reap kill")),
                  "the orphan that ignores SIGHUP was ended (TERM or KILL): \(log.split(separator: "\n").filter { $0.contains("agent-reap ") }.suffix(1).joined())")
            s.close()
        }
        if let s = open("orph2", "nohup-hold") {
            check(t.run(["host", "stop"], timeout: 300).code == 0 && s.exited(within: 10) == 75, "host stop severs it (75)")
        }
        let reaps = occurrences(hostLog(t), "agent-reap terminate") + occurrences(hostLog(t), "agent-reap kill")
        // The next command starts a new host; the stream wakes the hibernated sandbox (an adoption) — the orphan goes first.
        if let s = open("orph2") {
            let m = marked()
            check(m.count == 1, "after a new host's adoption: exactly ONE fake-agent process (\(m.count))")
            check(occurrences(hostLog(t), "agent-reap terminate") + occurrences(hostLog(t), "agent-reap kill") > reaps,
                  "the new host ended the recorded orphan (TERM or KILL)")
            s.close()
        }
    }

    if parts.contains("hangup") {
        print("agent-stream: a client that hangs up")
        if phase(lab) != "running" { _ = t.run(["wake", lab], timeout: 300) }
        if let s = open("hang", "hold") {
            s.kill9()
            let t0 = Date()
            let gone = t.waitFor(6) { marked().isEmpty }
            check(gone, String(format: "killed mid-stream: no guest process of it left after %.1f s (within 6 s)", Date().timeIntervalSince(t0)))
            check(hostLog(t).contains("agent-stream hang ended — the client hung up"), "host.log: the client hung up")
        }
        if let s = open("hang2", "hold") {
            check(t.run(["pause", lab]).code == 0, "pause")
            s.kill9()
            usleep(6_500_000)
            check(phase(lab) == "paused", "the grace ran out: the sandbox is still paused (never woken to clean up)")
            check(hostLog(t).contains("is left to end at the next wake"), "host.log: its program is left to end at the next wake")
            check(t.run(["resume", lab]).code == 0, "resume")
            check(t.waitFor(6) { marked().isEmpty }, "…and the resume ended it")
        }
    }

    if parts.contains("env") || parts.contains("claude") {
        print("agent-stream: the agent's environment (claude-code)")
        let c = "asc"
        let r = t.run(["up", c, "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--detach"], timeout: 2400)
        check(r.code == 0, "up \(c) --image claude-code (prepares the image: exit \(r.code))")
        if parts.contains("env") {
            let key = "sk-ant-FAKE-doz-agentstream-0000"
            check(t.run(["key", "set", c, "--anthropic"], stdin: Data((key + "\n").utf8)).code == 0, "key set \(c) --anthropic (a FAKE key, stdin)")
            let id = t.run(["agent-stream", c, "--", "id", "-un"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            check(id == "agent", "by default it runs as the image's user: \(id)")
            let root = t.run(["agent-stream", c, "--user", "root", "--", "id", "-un"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            check(root == "root", "--user root: \(root)")
            let given = "sk-ant-FAKE-doz-agentstream-given-1111"
            let env = t.run(["agent-stream", c, "-e", "ANTHROPIC_API_KEY=\(given)", "--", "sh", "-c", "tr '\\0' '\\n' < /proc/$$/environ"]).out
            let line = env.split(separator: "\n").first { $0.hasPrefix("ANTHROPIC_API_KEY=") }.map(String.init) ?? "none"
            check(line.hasPrefix("ANTHROPIC_API_KEY=" + CredentialVault.placeholderPrefix),
                  "the stream's own environment, read as the agent: a placeholder (\(line.prefix(30))…)")
            check(!env.contains(key) && !env.contains(given) && !env.contains("sk-ant-"), "never the key — neither the bound one nor one given with -e")
            check(env.contains("HTTPS_PROXY=") && env.contains("\(AgentPipe.markerVariable)="), "the proxy's variables and the stream's marker are there")
        }
        if parts.contains("claude") { await claudeResumePart(t, c) }
    }
}

/// Owner-run: a real Claude Code chat over agent-stream, severed by hibernate, resumed with --resume.
private func claudeResumePart(_ t: CLIHarness, _ c: String) async {
    print("agent-stream: a real chat, severed and resumed (DOZ_TEST_CLAUDE_LOGIN=1 — this Mac's login, read-only)")
    guard ProcessInfo.processInfo.environment["DOZ_TEST_CLAUDE_LOGIN"] == "1", ProcessInfo.processInfo.environment["DOZ_TEST_NO_MAC_LOGIN"] != "1" else {
        print("  SKIP  a real chat (set DOZ_TEST_CLAUDE_LOGIN=1 and DOZ_TEST_REAL_MAC=1 to use this Mac's login)")
        return
    }
    check(t.run(["account", "use", c, "mac"]).code == 0, "account use \(c) mac")
    let argv = ["claude", "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", "haiku"]
    func user(_ text: String) -> String {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
    }
    func results(_ s: StreamClient) -> [[String: Any]] {
        s.out.text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["type"] as? String == "result" }
    }
    func waitResults(_ s: StreamClient, _ n: Int, _ seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if results(s).count >= n { return true }; usleep(100_000) }
        return false
    }
    guard let s1 = try? StreamClient(t, [c, "--stream", "chat", "--"] + argv) else { check(false, "agent-stream claude"); return }
    s1.send(user("Remember the codeword PLUM-42. Reply with just OK."))
    check(waitResults(s1, 1, 120), "turn 1: a result")
    s1.send(user("What is 2+2? Reply with just the number."))
    check(waitResults(s1, 2, 120), "turn 2: a result")
    let session = results(s1).last?["session_id"] as? String ?? ""
    check(!session.isEmpty, "the session id (\(session.prefix(8))…)")
    check(t.run(["hibernate", c], timeout: 300).code == 0 && s1.exited(within: 10) == 75, "hibernate severs the chat: exit 75")
    let t0 = Date()
    guard let s2 = try? StreamClient(t, [c, "--stream", "chat", "--"] + argv + ["--resume", session]) else { check(false, "agent-stream --resume"); return }
    s2.send(user("What was the codeword? Reply with just the codeword."))
    check(waitResults(s2, 1, 180), "resumed: a result")
    let answer = results(s2).last?["result"] as? String ?? ""
    check(answer.contains("PLUM-42"), "it remembers turn 1 (\(answer.prefix(40)))")
    info(String(format: "resume: %.2f s from the new stream to its result (the wake included)", Date().timeIntervalSince(t0)))
    let n = t.run(["exec", c, "--", "sh", "-c", "for p in /proc/[0-9]*; do tr '\\0' ' ' < $p/cmdline 2>/dev/null; echo; done | grep -c '[i]nput-format stream-json'"]).out
    check(n.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "one claude process is left (\(n.trimmingCharacters(in: .whitespacesAndNewlines)))")
    s2.close()
    _ = t.run(["account", "use", c, "none"])
}
