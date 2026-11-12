import Darwin
import Foundation
import XCTest
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
        XCTAssertEqual(q.warning("the host", pid: 7)?.hasPrefix("the host runs at background QoS — "), true)
        XCTAssertFalse(ProcessPriority(background: false, qos: "utility", pri: 20).clamped, "utility is ordinary")
        XCTAssertNil(ProcessPriority(background: false, qos: "user-initiated", pri: 31).warning("doz", pid: 1))
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
        let back = try HostWire.decoder.decode(HostStatus.self, from: HostWire.encoder.encode(s))
        XCTAssertEqual(back.priority, s.priority)
        XCTAssertEqual(back.priorityRestored, true)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: HostWire.encoder.encode(s)) as? [String: Any])
        old["priority"] = nil
        old["priorityRestored"] = nil
        let o = try HostWire.decoder.decode(HostStatus.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(o.priority)
    }
}
