import Foundation
import XCTest
@testable import DozableHost

/// What an agent's request needs, by its HostOp (`ActionClasses.classify`): every HostOp is classified — the table below is
/// the whole map, so a new HostOp fails here until it is placed — each need a known permission, several needs for one request
/// (a worker added unfenced), and the targets.
final class ActionClassTests: XCTestCase {
    /// The permissions each operation needs; every operation not here is Dozable's own (never for an agent).
    static let table: [HostOp: [String]] = [
        .workspaceShow: ["workspace.read"], .workspaceLog: ["workspace.read"], .workspaceReach: ["workspace.read"],
        .workspaceFolders: ["workspace.read"], .workspaceRuns: ["workspace.read"], .workspaceRunChat: ["workspace.read"],
        .workspaceDoc: ["workspace.read"],
        .workerList: ["workspace.read"], .permissionsShow: ["workspace.read"], .permissionsWhy: ["workspace.read"], .sessionScreen: ["workspace.read"],
        .workspaceStart: ["agent.start"], .start: ["agent.start"], .wake: ["agent.start"], .resume: ["agent.start"],
        .sessionResume: ["agent.start"], .sessionRestart: ["agent.start"], .openSession: ["agent.start"],
        .workspaceStop: ["agent.stop"], .pause: ["agent.stop"], .sleep: ["agent.stop"], .hibernate: ["agent.stop"], .shutdown: ["agent.stop"],
        .sessionEnd: ["agent.stop"],
        .workerAdd: ["worker.start"], .workerEnd: ["worker.stop"],
        .workspaceNew: ["room.manage"],
        .netPolicy: ["net.allow"], .portOpen: ["net.allow"], .ports: ["net.allow"],
        .accountUse: ["keychain.use"], .accessGithubKey: ["keychain.use"],
        .filesMkdir: ["folder.write"], .filesNew: ["folder.write"], .filesMove: ["folder.write"],
        .filesRm: ["delete"], .pointRm: ["delete"], .rm: ["delete"], .imageRm: ["delete"],
        .chatRoomArchive: ["room.manage"], .chatRoomRm: ["room.manage"], .chatAdd: ["room.manage"], .chatRemove: ["room.manage"], .chatSet: ["room.manage"],
        .chatAsk: ["chat.post"], .chatWithdraw: ["chat.post"], .chatDecide: ["chat.decide"], .chatAsks: ["chat.read"],
        .workspaceSleep: ["workspace.sleep"], .workspaceWake: ["workspace.sleep"],
        .workspaceRun: ["run.open"], .workspaceReopen: ["run.open"], .workspaceFinish: ["run.finish"],
        .workspaceArchive: ["workspace.archive"], .workspaceRestore: ["workspace.archive"], .workspaceRunArchive: ["workspace.archive"],
        .workspaceDelete: ["workspace.delete"],
        .botNew: ["bot.manage"], .botSet: ["bot.manage"], .botRetire: ["bot.manage"], .botAdopt: ["bot.manage"],
        .permissionsGrant: ["grant.give"], .permissionsRevoke: ["grant.give"],
    ]

    /// Every HostOp has its class, and it is the table's: what the table does not name is Dozable's own. A new HostOp
    /// lands here — and in the switch, which has no default — before an agent can ever reach it.
    func testEveryHostOpIsClassified() {
        var own: [HostOp] = []
        for op in HostOp.allCases {
            let c = ActionClasses.classify(HostRequest(op))
            switch c {
            case .dozableOwn:
                XCTAssertNil(Self.table[op], "\(op.rawValue) is in the table but classified Dozable's own")
                own.append(op)
            case .needs(let perms, _):
                XCTAssertEqual(perms, Self.table[op], op.rawValue)
                XCTAssertFalse(perms.isEmpty, op.rawValue)
                for p in perms { XCTAssertTrue(GrantPermissions.isKnown(p), "\(op.rawValue): \(p)") }
            }
        }
        XCTAssertEqual(own.count + Self.table.count, HostOp.allCases.count)
        for op in [HostOp.attach, .exec, .keySet, .accountAdd, .chatToken, .botToken, .hostStop, .permissionsCeiling, .sandboxSettings, .ping, .workspaceList] {
            XCTAssertEqual(ActionClasses.classify(HostRequest(op)), .dozableOwn, op.rawValue)
        }
        // The read-only plans and the editing of a workspace with nothing named are Dozable's own too.
        XCTAssertEqual(ActionClasses.classify(HostRequest(.workspaceEdit)), .dozableOwn)
    }

    func testSeveralNeeds() {
        var r = HostRequest(.workerAdd)
        r.workerRequest = WorkerRequest(workspace: "demo")
        r.workerRequest?.isolation = "unfenced"
        XCTAssertEqual(ActionClasses.classify(r), .needs(["worker.start", "isolation.unfenced"], .workspace("demo")))
        r.secrets = [LaunchSecretGrant.sample]
        XCTAssertEqual(ActionClasses.classify(r), .needs(["worker.start", "isolation.unfenced", "secret.use"], .workspace("demo")))

        var o = HostRequest(.openSession, name: MacPlace.name)
        o.session = "s1"
        XCTAssertEqual(ActionClasses.classify(o), .needs(["agent.start", "isolation.unfenced"], .place("mac:s1")), "no fence: unfenced")
        o.macFence = MacFenceRequest(read: ["/tmp/a"], write: ["/tmp/b"])
        XCTAssertEqual(ActionClasses.classify(o), .needs(["agent.start", "folder.read", "folder.write"], .place("mac:s1")))
        XCTAssertEqual(ActionClasses.classify(HostRequest(.openSession, name: "box")), .needs(["agent.start"], .place("sandbox:box")),
                       "a sandbox's session is never unfenced")

        var n = HostRequest(.workspaceNew)
        n.workspaceRequest = WorkspaceRequest(name: "w2")
        n.workspaceRequest?.managerIsolation = "unfenced"
        n.workspaceRequest?.folders = [WorkspaceFolder(path: "/tmp/a", mode: "ro"), WorkspaceFolder(path: "/tmp/b", mode: "rw", main: true)]
        XCTAssertEqual(ActionClasses.classify(n), .needs(["room.manage", "isolation.unfenced", "folder.read", "folder.write"], .workspace("w2")))
        var e = HostRequest(.workspaceEdit)
        e.workspaceRequest = WorkspaceRequest(name: "w")
        e.workspaceRequest?.addFolders = [WorkspaceFolder(path: "/tmp/a", mode: "rw")]
        XCTAssertEqual(ActionClasses.classify(e), .needs(["folder.write"], .workspace("w")))
        var room = HostRequest(.chatRoomRm)
        room.chatRoom = ChatRoomRequest(room: "demo-review")
        XCTAssertEqual(ActionClasses.classify(room), .needs(["room.manage"], .room("demo-review")))
        var decide = HostRequest(.chatDecide)
        decide.chatAsk = ChatAskRequest(room: "demo-review", ask: "#3")
        XCTAssertEqual(ActionClasses.classify(decide), .needs(["chat.decide"], .room("demo-review")))
        XCTAssertEqual(ActionClasses.classify(HostRequest(.chatAsks)), .needs(["chat.read"], .nowhere))
    }
}

extension LaunchSecretGrant {
    /// A grant's shape only — never a real value.
    static var sample: LaunchSecretGrant {
        LaunchSecretGrant(secret: LaunchSecret(variable: "X", host: "api.example.com", port: 443, fingerprint: "000000000000"), value: "fake", source: "/tmp/x")
    }
}
