import Foundation
@testable import DozableMenuBarCore

/// `doz daemon status --json` as the real doz prints it — captured from a 0.50.6 build in a scratch store (no daemon;
/// a running daemon), then edited for the other states. Paths are the scratch ones.
enum Fixture {
    static let noDaemon = """
    {
      "alwaysOn" : true,
      "held" : false,
      "keepalive" : { "account" : "mac", "mode" : "off" },
      "loginItem" : {
        "installed" : false, "label" : "com.dozable.daemon.fc0fae41", "loaded" : false,
        "note" : "daemon.login_item is ask: not set up (doz daemon login-item on)", "owner" : "none",
        "path" : "/tmp/dzo-cap/la/com.dozable.daemon.fc0fae41.plist", "setting" : "ask", "stale" : false, "wanted" : false
      },
      "running" : false,
      "store" : "/tmp/dzo-cap/store"
    }
    """

    static let running = """
    {
      "alwaysOn" : false, "connections" : 1,
      "executable" : "/Users/someone/dozable/.build/arm64-apple-macosx/debug/doz",
      "fencedSessions" : [], "flavour" : "cli", "held" : false, "idleTimeoutMinutes" : 1,
      "keepalive" : { "account" : "mac", "mode" : "off" }, "keepers" : 0, "launchedDetached" : true,
      "liveSandboxes" : [],
      "loginItem" : {
        "installed" : false, "label" : "com.dozable.daemon.b72b55d0", "loaded" : false,
        "note" : "daemon.login_item is ask: not set up (doz daemon login-item on)", "owner" : "none",
        "path" : "/tmp/dzo-cap2/la/com.dozable.daemon.b72b55d0.plist", "setting" : "ask", "stale" : false, "wanted" : false
      },
      "microphoneApp" : "doz", "parentPid" : 1, "pid" : 16586, "preparations" : [],
      "priority" : { "background" : false, "pri" : 31, "qos" : "default" },
      "protocolVersion" : 1, "sessionID" : 16586, "startedAt" : "2026-11-16T19:48:37.153Z",
      "store" : "/tmp/dzo-cap2/store", "version" : "0.50.6"
    }
    """

    /// What 0.50.0–0.50.4 print with no daemon.
    static let oldNoDaemon = #"{"running":false}"#

    /// A running daemon, edited: `edit` changes the decoded JSON object before it is decoded as a status.
    static func runningWith(_ edit: (inout [String: Any]) -> Void) -> DozStatus {
        var o = (try! JSONSerialization.jsonObject(with: Data(running.utf8))) as! [String: Any]
        edit(&o)
        return DozStatus.decode(try! JSONSerialization.data(withJSONObject: o))!
    }

    static func noDaemonWith(_ edit: (inout [String: Any]) -> Void) -> DozStatus {
        var o = (try! JSONSerialization.jsonObject(with: Data(noDaemon.utf8))) as! [String: Any]
        edit(&o)
        return DozStatus.decode(try! JSONSerialization.data(withJSONObject: o))!
    }

    static func status(_ json: String) -> DozStatus { DozStatus.decode(Data(json.utf8))! }
}

/// A runner that runs nothing: it answers from a table and records every command.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    var answers: [String: CommandResult] = [:]
    private(set) var calls: [(label: String, doz: String)] = []

    func run(_ command: DozCommand, doz: String) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        calls.append((command.label, doz))
        return answers[command.label] ?? CommandResult(exit: 1)
    }

    func answer(_ command: DozCommand, _ stdout: String, exit: Int32 = 0) {
        answers[command.label] = CommandResult(exit: exit, stdout: Data(stdout.utf8))
    }

    var labels: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.label) }
}
