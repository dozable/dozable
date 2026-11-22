import ArgumentParser
import Darwin
import DozableHost
import DozableKit
import Foundation

/// 749 (WS.02): `doz debug …` — test hooks, hidden from `doz --help` and the manual, each refused outside a guarded test run.
/// `stub-agent` is what the daemon starts in place of a workspace agent under `DOZ_TEST_STUB_AGENT=1` (taken before the
/// parser — `DozableEntry`; this entry only documents it); `crash W/AGENT` makes that agent's stub exit non-zero, posting
/// nothing, so the daemon sees a crash (`<name> crashed: exit 70` in the workspace's log).
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Test hooks (guarded test runs only).",
        shouldDisplay: false,
        subcommands: [DebugCrash.self, DebugStubAgent.self])
}

struct DebugStubAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stub-agent",
        abstract: "The stub agent the daemon starts in place of a workspace agent under DOZ_TEST_STUB_AGENT=1 (guarded test runs only).")

    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    func run() async throws {
        throw ExitCode(StubAgentRunner.run(arguments, environment: ProcessInfo.processInfo.environment))
    }
}

/// What `doz debug crash --json` answers.
struct DebugCrashed: Codable, Equatable {
    var workspace: String
    var agent: String
    var session: String
    var signal: Int32
    var exitCode: Int32
}

struct DebugCrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crash",
        abstract: "Make a workspace agent's stub agent exit non-zero without posting, so the daemon sees a crash (guarded test runs only).")

    @Argument(help: "W/AGENT: the workspace and its agent (a manager or a worker running the stub agent on this Mac).")
    var target: String

    @OptionGroup var g: GlobalOptions

    func run() async throws {
        if let why = TestSafety.debugCrashViolation() { throw fail(HostError(.notPermitted, why), g) }
        let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw fail(HostError(.usage, "doz debug crash W/AGENT — the workspace and its agent"), g)
        }
        let (w, name) = (parts[0], parts[1])
        let store = g.dozableStore
        let ws = WorkspaceStore(store: store)
        guard WorkspaceName.isValid(w), ws.exists(w), let rec = try? ws.read(w) else {
            throw fail(HostError(.notFound, "\(w) is not one of your workspaces (doz workspace ls)"), g)
        }
        guard let a = rec.agents.last(where: { $0.name == name && $0.endedAt == nil }) else {
            throw fail(HostError(.notFound, "\(name) is not an agent of \(w) (doz worker ls \(w))"), g)
        }
        guard a.place.mac == true, let session = a.place.session else {
            throw fail(HostError(.invalid, "\(name) does not run on this Mac — the stub agent runs only there"), g)
        }
        guard case .info(let line) = await MacSessions(store: store, readOnly: true).state(session),
              let pid = SessionInfo.parseList(line).first?.pid, pid > 1 else {
            throw fail(HostError(.invalidPhase, "\(name) is not running (doz worker ls \(w))"), g)
        }
        // Only the stub agent of that name is ever signalled — never another program.
        guard let argv = StubAgent.processArguments(pid_t(pid)), StubAgent.isStub(argv: argv, name: name) else {
            throw fail(HostError(.invalidPhase, "\(name)'s program is not the stub agent — start the workspace with \(StubAgent.variable)=1"), g)
        }
        guard kill(pid_t(pid), StubAgent.crashSignal) == 0 else {
            throw fail(HostError(.failed, "could not signal \(name)'s stub agent: \(String(cString: strerror(errno)))"), g)
        }
        let out = DebugCrashed(workspace: w, agent: name, session: session, signal: StubAgent.crashSignal, exitCode: StubAgent.crashExitCode)
        if g.json { Out.json(out) } else {
            Out.stdout("\(name)'s stub agent exits \(StubAgent.crashExitCode), posting nothing — doz workspace log \(w) says it crashed\n")
        }
    }
}
