import Darwin
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 678: how macOS schedules doz and its host — what doctor warns about, and what `host status` carries.
final class ProcessPriorityTests: XCTestCase {
    func testClampedAndItsWords() {
        let bg = ProcessPriority(background: true, qos: "default", pri: 4)
        XCTAssertTrue(bg.clamped)
        XCTAssertEqual(bg.warning("doz", pid: 42),
                       "doz runs at background priority (pri 4) — it and everything it starts run slowly; start it from a normal terminal, or move it out: taskpolicy -B -p 42")
        let q = ProcessPriority(background: false, qos: "background", pri: nil)
        XCTAssertTrue(q.clamped)
        XCTAssertEqual(q.warning("the daemon", pid: 7)?.hasPrefix("the daemon runs at background QoS — "), true)
        XCTAssertFalse(ProcessPriority(background: false, qos: "utility", pri: 20).clamped, "utility is ordinary")
        XCTAssertNil(ProcessPriority(background: false, qos: "user-initiated", pri: 31).warning("doz", pid: 1))
    }

    /// 788: utility is its own warning — never `clamped` — for the daemon and the sessions it holds.
    func testUtilityIsBelowNormalButNotClamped() {
        let u = ProcessPriority(background: false, qos: "utility", pri: 20)
        XCTAssertFalse(u.clamped)
        XCTAssertTrue(u.belowNormal)
        XCTAssertEqual(u.utilityWarning("the daemon"),
                       "the daemon runs at utility QoS (pri 20) — mostly the efficiency cores, so it and everything it starts run slower than from a terminal")
        // The reading thread may say user-initiated while the task's priority is utility's.
        XCTAssertTrue(ProcessPriority(background: false, qos: "user-initiated", pri: 20).belowNormal)
        XCTAssertFalse(ProcessPriority(background: false, qos: "user-initiated", pri: 31).belowNormal)
        XCTAssertNil(ProcessPriority(background: false, qos: "default", pri: 31).utilityWarning("the daemon"))
        XCTAssertFalse(ProcessPriority(background: true, qos: "default", pri: 4).belowNormal, "background is clamped, said by warning()")
    }

    func testTheHeldSessionsWarning() {
        XCTAssertNil(ProcessPriority.heldSessionsWarning([:]))
        XCTAssertNil(ProcessPriority.heldSessionsWarning(["a": 31, "b": 37]))
        XCTAssertEqual(ProcessPriority.heldSessionsWarning(["a": 31, "build": 20]),
                       "a session on this Mac (build) runs at utility QoS or below (pri 20) — mostly the efficiency cores, so the agent's builds and tests run slower than from a terminal; restart the daemon from a normal terminal (doz daemon stop, then any doz command), then the session")
        let many = ProcessPriority.heldSessionsWarning(["a": 20, "b": 20, "c": 4, "d": 20, "e": 20])
        XCTAssertEqual(many?.hasPrefix("5 sessions on this Mac (a, b, c and 2 more) run at utility QoS or below (pri 4) — "), true)
    }

    func testDoctorsDaemonPriorityRow() {
        let bg = Doctor.daemonPriorityCheck(ProcessPriority(background: true, qos: "default", pri: 4), pid: 9, restored: false)
        XCTAssertEqual(bg.status, .warn)
        XCTAssertTrue(bg.detail.hasPrefix("the daemon runs at background priority (pri 4)"))
        let u = Doctor.daemonPriorityCheck(ProcessPriority(background: false, qos: "utility", pri: 20), pid: 9, restored: false)
        XCTAssertEqual(u.status, .warn)
        XCTAssertEqual(u.detail, "the daemon runs at utility QoS (pri 20) — mostly the efficiency cores, so it and everything it starts run slower than from a terminal; restart it from a normal terminal: doz daemon stop, then any doz command")
        let ok = Doctor.daemonPriorityCheck(ProcessPriority(background: false, qos: "user-initiated", pri: 31), pid: 9, restored: true)
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(ok.detail, "normal (QoS user-initiated, pri 31) — moved out of the background priority it inherited from the command that started it")
    }

    func testLiftingUtilityOnAThread() throws {
        var lifted = false, after = QOS_CLASS_UNSPECIFIED
        let t = Thread {
            _ = pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
            lifted = ProcessPriority.liftInheritedUtility()
            after = qos_class_self()
        }
        t.start()
        while !t.isFinished { usleep(1000) }
        // Unclamped (a test run), a utility thread asks for user-initiated and gets it.
        XCTAssertTrue(lifted)
        XCTAssertEqual(ProcessPriority.name(after), "user-initiated")
        // Already above utility: nothing to do.
        XCTAssertFalse(ProcessPriority.liftInheritedUtility() && qos_class_self() == QOS_CLASS_UTILITY)
    }

    func testTheQoSNames() {
        XCTAssertEqual(ProcessPriority.name(QOS_CLASS_USER_INTERACTIVE), "user-interactive")
        XCTAssertEqual(ProcessPriority.name(QOS_CLASS_USER_INITIATED), "user-initiated")
        XCTAssertEqual(ProcessPriority.name(QOS_CLASS_DEFAULT), "default")
        XCTAssertEqual(ProcessPriority.name(QOS_CLASS_UTILITY), "utility")
        XCTAssertEqual(ProcessPriority.name(QOS_CLASS_BACKGROUND), "background")
        XCTAssertEqual(ProcessPriority.name(QOS_CLASS_UNSPECIFIED), "unspecified")
    }

    func testThisProcessIsRead() {
        let p = ProcessPriority.current()
        XCTAssertNotNil(p.pri, "proc_pidinfo answers for this process")
        XCTAssertNil(ProcessPriority.pri(of: -1))
        // Not in the background state now (a launchd-run CI agent may be: then lifting is what the host would do).
        XCTAssertEqual(ProcessPriority.liftInheritedBackground(), p.background)
        XCTAssertFalse(ProcessPriority.current().background)
    }

    func testTheStatusCarriesItAndAnOlderAnswerDecodes() throws {
        var s = HostStatus(version: "x", protocolVersion: 1, pid: 3, startedAt: Date(timeIntervalSince1970: 0), store: "/s",
                           idleTimeoutMinutes: 5, liveSandboxes: [], connections: 0, idleSeconds: nil)
        s.priority = ProcessPriority(background: false, qos: "user-initiated", pri: 31)
        s.priorityRestored = true
        s.heldSessionPri = ["build": 20]
        let back = try HostWire.decoder.decode(HostStatus.self, from: HostWire.encoder.encode(s))
        XCTAssertEqual(back.priority, s.priority)
        XCTAssertEqual(back.priorityRestored, true)
        XCTAssertEqual(back.heldSessionPri, ["build": 20])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: HostWire.encoder.encode(s)) as? [String: Any])
        old["priority"] = nil
        old["priorityRestored"] = nil
        old["heldSessionPri"] = nil
        let o = try HostWire.decoder.decode(HostStatus.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(o.priority)
        XCTAssertNil(o.heldSessionPri)
    }
}
