import Foundation
import XCTest
@testable import DozableHost

/// The ONE decision (`GrantDecision.decide`), table-driven over the design's examples: the mockups' five lines verbatim,
/// refinements (a)–(f) one case each, each of the four ceilings (an ask ceiling turning allow into ask), agent > bot > role,
/// room > workspace > everywhere, `--until`, an unknown permission, what fails closed, the isolation ceiling, the admin role.
final class GrantDecisionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    func q(_ perm: String, name: String = "bot2", home: String? = "myapp-tests", bot: String? = nil, in w: String? = "myapp-tests",
           room: String? = nil, roles: [String] = ["worker"]) -> GrantQuery {
        GrantQuery(name: name, home: home, bot: bot, perm: perm, workspace: w, room: room,
                   recordRoles: home.map { h in roles.map { HeldRole(role: $0, workspace: h) } } ?? [])
    }

    func grant(_ s: GrantSubject, _ what: String, _ scope: GrantScope, until: Date? = nil) -> Grant {
        if let (p, a) = try? GrantWords.parse(what) { return Grant(subject: s, perm: p, answer: a, scope: scope, until: until, at: now) }
        return Grant(subject: s, role: what, scope: scope, until: until, at: now)
    }

    /// The mockups' "Why did that Ask come to me?" — the five steps exactly, and → ask.
    func testTheMockupsFiveLines() {
        var query = q("folder.read")
        query.resource = "~/src/SharedKit"
        let d = GrantDecision.decide(query, GrantFacts(now: now, owner: "ada", manager: "mira"))
        XCTAssertEqual(d.answer, .ask)
        XCTAssertEqual(Array(d.lines.prefix(7)), [
            "bot2 · folder.read ~/src/SharedKit · in myapp-tests",
            "1 any never               none (no ceiling, no never in any scope)",
            "2 permission grants        none (room, workspace, everywhere)",
            "3 roles here               worker (myapp-tests): ask",
            "4 —",
            "5 bot2's ceiling           none set: no cap",
            "→ ask · an Ask to ada (owner); mira is not a decider here",
        ])
        XCTAssertEqual(d.decidedAt, 3)
        XCTAssertEqual(d.source, "role")
        XCTAssertTrue(d.fromRecord)
    }

    /// (a) The ceiling caps every answer, not only never: a bot's spend=ask turns a grant of allow into ask.
    func testA_TheCeilingCapsEveryAnswer() {
        let f = GrantFacts(grants: [grant(.bot("otto"), "spend=allow", .workspace("w"))], botCeiling: ["spend": .ask], now: now)
        let d = GrantDecision.decide(q("spend", name: "otto", home: "w", bot: "otto", in: "w"), f)
        XCTAssertEqual(d.answer, .ask)
        XCTAssertEqual(d.decidedAt, 5)
        XCTAssertEqual(d.source, "ceiling")
        XCTAssertTrue(d.lines[5].hasPrefix("5 otto's ceiling           ask (otto's ceiling): allow → ask"), d.lines[5])
    }

    /// (b) Two roles in one scope combine to the more permissive answer; a single permission grant beats any role there.
    func testB_TwoRolesCombineAndAGrantBeatsThem() {
        let f = GrantFacts(grants: [grant(.bot("otto"), "decider", .room("w", "review"))], now: now)
        // member (from a grant in the room) + decider: chat.decide → allow.
        var f2 = f
        f2.grants.append(grant(.bot("otto"), "member", .room("w", "review")))
        var d = GrantDecision.decide(q("chat.decide", name: "otto", home: "w", bot: "otto", in: "w", room: "review", roles: []), f2)
        XCTAssertEqual(d.answer, .allow)
        XCTAssertTrue(d.lines[3].contains("decider + member (w/review): allow") || d.lines[3].contains("member + decider (w/review): allow"), d.lines[3])
        f2.grants.append(grant(.bot("otto"), "chat.decide=ask", .room("w", "review")))
        d = GrantDecision.decide(q("chat.decide", name: "otto", home: "w", bot: "otto", in: "w", room: "review", roles: []), f2)
        XCTAssertEqual(d.answer, .ask, "the permission grant beats the roles in its scope")
        XCTAssertEqual(d.decidedAt, 2)
    }

    /// (c) A manager passes on what it holds (grant.give is the manager's, never a worker's), and never above a ceiling.
    func testC_GrantGiveAndTheCeilingAboveIt() {
        XCTAssertEqual(GrantDecision.decide(q("grant.give", name: "mira", roles: ["manager"]), GrantFacts(now: now)).answer, .allow)
        XCTAssertEqual(GrantDecision.decide(q("grant.give", name: "bot2"), GrantFacts(now: now)).answer, .never)
        let f = GrantFacts(grants: [grant(.agent("myapp-tests", "bot2"), "net.allow=allow", .workspace("myapp-tests"))],
                           workspaceCeiling: ["net.allow": .never], now: now)
        XCTAssertEqual(GrantDecision.decide(q("net.allow"), f).answer, .never, "a grant never reaches above a ceiling")
    }

    /// (d) sudo defaults to never; only an explicit grant raises it, and only up to the ceiling.
    func testD_SudoDefaultsToNever() {
        XCTAssertEqual(GrantDecision.decide(q("sudo", name: "x", home: nil, in: nil, roles: []), GrantFacts(now: now)).answer, .never)
        XCTAssertEqual(GrantDecision.decide(q("sudo"), GrantFacts(now: now)).answer, .never, "the worker role says never")
        let g = grant(.agent("myapp-tests", "bot2"), "sudo=allow", .workspace("myapp-tests"))
        XCTAssertEqual(GrantDecision.decide(q("sudo"), GrantFacts(grants: [g], now: now)).answer, .allow)
        XCTAssertEqual(GrantDecision.decide(q("sudo"), GrantFacts(grants: [g], macCeiling: ["sudo": .ask], now: now)).answer, .ask)
    }

    /// (e) Your explicit never in any scope beats an allow from a role or from a more specific scope.
    func testE_NeverWinsEverywhere() {
        let f = GrantFacts(grants: [grant(.agent("myapp-tests", "bot2"), "folder.read=allow", .room("myapp-tests", "review")),
                                    grant(.role("worker"), "folder.read=never", .everywhere)], now: now)
        let d = GrantDecision.decide(q("folder.read", room: "review"), f)
        XCTAssertEqual(d.answer, .never)
        XCTAssertEqual(d.decidedAt, 1)
        XCTAssertEqual(d.source, "grant")
        XCTAssertTrue(d.lines[1].contains("your never ✎ (every worker, everywhere)"), d.lines[1])
    }

    /// (f) Only the owner makes deciders: the role is never granted, chat.decide is outside every grant.
    func testF_OnlyTheOwnerMakesDeciders() {
        XCTAssertNotNil(RoleTable.grantRefusal("decider", scope: .workspace("w"), subject: .bot("otto")))
        XCTAssertTrue(GrantPermissions.ownerOnly.contains("chat.decide"))
        XCTAssertEqual(GrantDecision.decide(q("chat.decide", name: "mira", roles: ["manager"]), GrantFacts(now: now)).answer, .never)
        XCTAssertNotNil(RoleTable.grantRefusal("owner", scope: .everywhere, subject: .bot("otto")))
    }

    /// Each of the four ceilings, as a never and (but Dozable's own) as an ask that turns allow into ask.
    func testTheFourCeilings() {
        let allow = grant(.agent("myapp-tests", "bot2"), "net.allow=allow", .workspace("myapp-tests"))
        // Dozable's own: another workspace.
        var d = GrantDecision.decide(q("net.allow", in: "other"), GrantFacts(grants: [grant(.agent("myapp-tests", "bot2"), "net.allow=allow", .workspace("other"))], now: now))
        XCTAssertEqual(d.answer, .never)
        XCTAssertEqual(d.source, "dozable")
        XCTAssertTrue(d.lines[1].contains("Dozable's own: another workspace"), d.lines[1])
        for (name, f) in [("this Mac's", GrantFacts(grants: [allow], macCeiling: ["net.allow": .never], now: now)),
                          ("the bot's", GrantFacts(grants: [allow], botCeiling: ["net.allow": .never], now: now)),
                          ("the workspace's", GrantFacts(grants: [allow], workspaceCeiling: ["net.allow": .never], now: now))] {
            d = GrantDecision.decide(q("net.allow", bot: "bot2"), f)
            XCTAssertEqual(d.answer, .never, name)
            XCTAssertEqual(d.source, "ceiling", name)
        }
        for (name, f) in [("this Mac's", GrantFacts(grants: [allow], macCeiling: ["net.allow": .ask], now: now)),
                          ("the bot's", GrantFacts(grants: [allow], botCeiling: ["net.allow": .ask], now: now)),
                          ("the workspace's", GrantFacts(grants: [allow], workspaceCeiling: ["net.allow": .ask], now: now))] {
            d = GrantDecision.decide(q("net.allow", bot: "bot2"), f)
            XCTAssertEqual(d.answer, .ask, name)
            XCTAssertEqual(d.decidedAt, 5, name)
        }
    }

    /// Another workspace is never — unless an everywhere grant reaches it.
    func testAnotherWorkspaceUnlessAnEverywhereGrant() {
        XCTAssertEqual(GrantDecision.decide(q("workspace.read", in: "other"), GrantFacts(now: now)).answer, .never)
        let g = grant(.agent("myapp-tests", "bot2"), "workspace.read=allow", .everywhere)
        XCTAssertEqual(GrantDecision.decide(q("workspace.read", in: "other"), GrantFacts(grants: [g], now: now)).answer, .allow)
        XCTAssertEqual(GrantDecision.decide(q("workspace.read", in: nil), GrantFacts(now: now)).answer, .never, "outside every workspace")
    }

    /// Within one scope agent > bot > role; across scopes room > workspace > everywhere.
    func testSpecificity() {
        let w = GrantScope.workspace("myapp-tests")
        var f = GrantFacts(grants: [grant(.role("worker"), "net.allow=allow", w), grant(.bot("b"), "net.allow=ask", w)], now: now)
        XCTAssertEqual(GrantDecision.decide(q("net.allow", bot: "b"), f).answer, .ask, "bot > role")
        f.grants.append(grant(.agent("myapp-tests", "bot2"), "net.allow=allow", w))
        XCTAssertEqual(GrantDecision.decide(q("net.allow", bot: "b"), f).answer, .allow, "agent > bot")
        f = GrantFacts(grants: [grant(.agent("myapp-tests", "bot2"), "net.allow=allow", .everywhere),
                                grant(.agent("myapp-tests", "bot2"), "net.allow=ask", w)], now: now)
        XCTAssertEqual(GrantDecision.decide(q("net.allow"), f).answer, .ask, "workspace > everywhere")
        f.grants.append(grant(.role("worker"), "net.allow=allow", .room("myapp-tests", "review")))
        XCTAssertEqual(GrantDecision.decide(q("net.allow", room: "review"), f).answer, .allow, "room > workspace, even a role's")
        // Roles: the most specific scope that has any.
        f = GrantFacts(grants: [grant(.agent("myapp-tests", "bot2"), "member", .room("myapp-tests", "review"))], now: now)
        XCTAssertEqual(GrantDecision.decide(q("folder.read", room: "review"), f).answer, .never, "the room's member, not the workspace's worker")
    }

    /// `--until`: an ended grant never answers again; the next rung down answers.
    func testUntil() {
        let g = grant(.agent("myapp-tests", "bot2"), "folder.read=allow", .workspace("myapp-tests"), until: now.addingTimeInterval(60))
        XCTAssertEqual(GrantDecision.decide(q("folder.read"), GrantFacts(grants: [g], now: now)).answer, .allow)
        XCTAssertEqual(GrantDecision.decide(q("folder.read"), GrantFacts(grants: [g], now: now.addingTimeInterval(61))).answer, .ask, "ended: the role answers")
    }

    func testUnknownAndFailClosed() {
        let none = GrantFacts(now: now)
        var d = GrantDecision.decide(q("teleport", name: "x", home: nil, in: nil, roles: []), none)
        XCTAssertEqual(d.answer, .ask)
        XCTAssertTrue(d.lines.contains { $0.contains("not a known permission") })
        d = GrantDecision.decide(q("isolation.unfenced", name: "x", home: nil, in: nil, roles: []), none)
        XCTAssertEqual(d.answer, .never)
        XCTAssertEqual(d.decidedAt, 4)
        d = GrantDecision.decide(q("worker.start", name: "x", home: nil, in: nil, roles: []), none)
        XCTAssertEqual(d.answer, .ask)
    }

    /// A bot whose isolation ceiling is fenced (or vm) may never run unfenced, whatever it is granted.
    func testTheIsolationCeiling() {
        let g = grant(.bot("otto"), "isolation.unfenced=allow", .everywhere)
        var f = GrantFacts(grants: [g], botIsolationCeiling: "fenced", now: now)
        XCTAssertEqual(GrantDecision.decide(q("isolation.unfenced", name: "otto", home: "w", bot: "otto", in: "w"), f).answer, .never)
        f.botIsolationCeiling = nil
        XCTAssertEqual(GrantDecision.decide(q("isolation.unfenced", name: "otto", home: "w", bot: "otto", in: "w"), f).answer, .allow)
    }

    /// The admin role: everywhere only; capped by a bot's ceiling; its own nevers.
    func testTheAdminRole() {
        XCTAssertNotNil(RoleTable.grantRefusal("admin", scope: .workspace("w"), subject: .bot("ops")))
        XCTAssertNil(RoleTable.grantRefusal("admin", scope: .everywhere, subject: .bot("ops")))
        let g = grant(.bot("ops"), "admin", .everywhere)
        let ops = q("agent.start", name: "ops", home: nil, bot: "ops", in: "w", roles: [])
        XCTAssertEqual(GrantDecision.decide(ops, GrantFacts(grants: [g], now: now)).answer, .allow)
        XCTAssertEqual(GrantDecision.decide(ops, GrantFacts(grants: [g], botCeiling: ["agent.start": .ask], now: now)).answer, .ask)
        var k = ops
        k.perm = "keychain.use"
        XCTAssertEqual(GrantDecision.decide(k, GrantFacts(grants: [g], now: now)).answer, .never)
        k.perm = "workspace.archive"
        XCTAssertEqual(GrantDecision.decide(k, GrantFacts(grants: [g], now: now)).answer, .ask)
    }

    /// `bot ceiling otto sudo=never`, then `grant otto sudo=allow --in X`: never.
    func testABotCeilingNeverBeatsAGrant() {
        let f = GrantFacts(grants: [grant(.bot("otto"), "sudo=allow", .workspace("x"))], botCeiling: ["sudo": .never], now: now)
        let d = GrantDecision.decide(q("sudo", name: "otto", home: "x", bot: "otto", in: "x"), f)
        XCTAssertEqual(d.answer, .never)
        XCTAssertTrue(d.outcome.hasPrefix("→ never · refused: otto's ceiling: sudo=never"), d.outcome)
    }

    func testTheStoredWords() {
        for s in [GrantScope.everywhere, .workspace("w"), .room("w", "review")] { XCTAssertEqual(GrantScope(stored: s.stored), s) }
        for s in [GrantSubject.bot("otto"), .agent("w", "bot1"), .role("worker")] { XCTAssertEqual(GrantSubject(stored: s.stored), s) }
        XCTAssertNil(GrantScope(stored: "workspace:Bad Name"))
        XCTAssertNil(GrantSubject(stored: "role:king"))
        XCTAssertThrowsError(try GrantWords.parse("teleport=allow"))
        XCTAssertThrowsError(try GrantWords.parse("sudo=maybe"))
        XCTAssertThrowsError(try GrantCeiling.parse("sudo=allow"))
        XCTAssertEqual(GrantCeiling.caps(["sudo": "never", "spend": "allow", "net.allow": "later"]), ["sudo": .never])
        XCTAssertEqual(GrantPermissions.ids.count, Set(GrantPermissions.ids).count)
        for r in RoleTable.roles { for p in r.answers.keys { XCTAssertTrue(GrantPermissions.isKnown(p), "\(r.name): \(p)") } }
    }

    /// 765: an older `workspace.finish` grant still answers for `run.open` and `run.finish` for one release (it meant finish
    /// and reopen); a never on it still refuses them; and `run.open` / `run.finish` alone are asks (refused) for an agent.
    func testAnOlderWorkspaceFinishGrantStillAnswersForRuns() {
        let allow = GrantFacts(grants: [grant(.bot("otto"), "workspace.finish=allow", .workspace("w"))], now: now)
        XCTAssertEqual(GrantDecision.decide(q("run.finish", name: "otto", home: "w", bot: "otto", in: "w", roles: []), allow).answer, .allow)
        XCTAssertEqual(GrantDecision.decide(q("run.open", name: "otto", home: "w", bot: "otto", in: "w", roles: []), allow).answer, .allow)
        let never = GrantFacts(grants: [grant(.bot("otto"), "run.finish=allow", .workspace("w")),
                                        grant(.bot("otto"), "workspace.finish=never", .workspace("w"))], now: now)
        XCTAssertEqual(GrantDecision.decide(q("run.finish", name: "otto", home: "w", bot: "otto", in: "w", roles: []), never).answer, .never)
        let none = GrantFacts(now: now)
        XCTAssertEqual(GrantDecision.decide(q("run.open", name: "otto", home: "w", bot: "otto", in: "w", roles: []), none).answer, .ask)
        // A role that names only the older id answers too.
        XCTAssertNotNil(GrantDecision.roleAnswer("trusted-manager", "run.open"))
    }
}
