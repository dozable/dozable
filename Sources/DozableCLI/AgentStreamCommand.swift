import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost

// 676: `doz agent-stream NAME -- argv…` — this process's stdin, stdout and stderr relayed to a program in the sandbox over a
// real pipe (no terminal), so an app runs `doz agent-stream NAME -- claude --print --input-format stream-json …` exactly as it
// runs `claude` on the Mac. Exits with the program's code; 75 (EX_TEMPFAIL) when the pipe was severed (hibernate, shut down,
// host stop) or the connection ended without the host's last frame — the caller resumes the conversation on a new stream.

struct AgentStreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent-stream",
        abstract: "Run an agent program in the sandbox on a pipe: stdin, stdout and stderr relayed, no terminal.",
        discussion: """
        doz agent-stream NAME -- claude --print --input-format stream-json --output-format stream-json --verbose. \
        The environment, user and folder are exec's (the image's user, its folder, the proxy and key placeholders). A paused \
        or asleep sandbox stalls the stream, and a line written to it wakes the sandbox; hibernate, shut down and host stop \
        sever it: exit 75 and one line on stderr — resume the agent's own session on a new stream. One stream per label \
        (--stream) per sandbox; --force ends an open one of the same label first.
        """)
    static let severedExit: Int32 = 75

    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .customLong("stream"), help: "A label for this stream (default: one the host makes). One open stream per label.") var label: String?
    @Flag(name: .long, help: "End an open stream with the same label first.") var force = false
    @Option(name: .long, help: "Working directory in the guest (default: the session's).") var workdir: String?
    @Option(name: .long, help: "Run as this guest user (agent images default to their user; `root` for root).") var user: String?
    @Option(name: [.short, .customLong("env")], help: "KEY=VALUE (repeatable).") var env: [String] = []
    @Flag(name: .long, help: "Fail instead of waking a sleeping sandbox.") var noWake = false
    @Flag(name: .long, help: "Fail instead of starting (cold-booting) a sandbox that is off.") var noStart = false
    @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

    func validate() throws {
        if command.isEmpty { throw ValidationError("which command? doz agent-stream NAME -- CMD…") }
    }

    func request() throws -> HostRequest {
        var r = HostRequest(.agentStream, name: name)
        r.argv = command
        r.stream = label
        r.force = force ? true : nil
        r.workdir = workdir
        r.user = user
        r.environment = try parseEnv(env)
        r.wake = !noWake
        r.start = !noStart
        return r
    }

    /// How this command ends for the stream's end (nil: the connection ended without one): the exit code, and the line for
    /// stderr when it was severed.
    static func outcome(_ end: AgentStreamEnd?) -> (code: Int32, line: String?) {
        guard let end else { return (severedExit, "doz agent-stream: severed (transport-lost)") }
        if let s = end.severed { return (severedExit, "doz agent-stream: severed (\(s))") }
        guard let c = end.exitCode else { return (severedExit, "doz agent-stream: severed (transport-lost)") }
        return (c < 0 || c > 255 ? DozableExit.dozableFailed : c, nil)
    }

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)            // a reader of our stdout that went away is a failed write, not a kill
        noteHostBuild(g)
        let r = try request()
        let client: HostClient
        do { client = try HostClient.connect(store: g.dozableStore, autostart: true) } catch let e as HostError {
            throw fail(e, g, code: DozableExit.dozableFailed)
        }
        do {
            let m = try client.call(r) { e in if !g.quiet { FileHandle.standardError.write(Data((e.line + "\n").utf8)) } }
            guard m.ok == true else {
                let e = m.error ?? HostError(.failed, "the host gave no reason")
                throw fail(e, g, code: DozableExit.dozableFailed)
            }
            if ProcessInfo.processInfo.environment["DOZ_AGENT_STREAM_READY"] == "1", let v = m.result, let d = try? HostWire.encoder.encode(v) {
                FileHandle.standardError.write(Data("doz-agent-stream ready ".utf8) + d + Data("\n".utf8))
            }
        } catch let e as HostError { throw fail(e, g, code: DozableExit.dozableFailed) }
        let fd = client.fd
        // stdin → D frames, its EOF → F (a thread: a blocking read). The socket is never half-closed: F ends the input.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                if !UnixSocket.writeAll(fd, AgentFrame.encode(AgentFrame.data, Data(buf[0..<n]))) { return }
            }
            _ = UnixSocket.writeAll(fd, AgentFrame.encode(AgentFrame.finish))
        }
        let (code, line) = Self.outcome(Self.relay(client))
        if let line { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        if code != 0 { throw ExitCode(code) }
    }

    /// The host's frames until `E` (nil: the connection ended without one). An unknown frame type is skipped.
    static func relay(_ client: HostClient) -> AgentStreamEnd? {
        let parser = AgentFrame.clientParser()
        var pending = client.reader.takeRemainder()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            if !pending.isEmpty {
                guard let frames = try? parser.feed(pending) else { return nil }
                pending = Data()
                for f in frames {
                    switch f.type {
                    case AgentFrame.data: UnixSocket.writeAll(STDOUT_FILENO, f.payload)
                    case AgentFrame.stderr: UnixSocket.writeAll(STDERR_FILENO, f.payload)
                    case AgentFrame.end: return try? HostWire.decoder.decode(AgentStreamEnd.self, from: f.payload)
                    default: break
                    }
                }
            }
            let n = read(client.fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            pending = Data(buf[0..<n])
        }
    }
}
