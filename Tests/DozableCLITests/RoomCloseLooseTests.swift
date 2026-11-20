import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// `doz chat room close|open R --loose`: a loose room closed to new messages and opened again, only through the closed
/// set the daemon hands the chat server (its control channel); refused without `--loose`, for a workspace's own or linked
/// room, and for a room that is not there. Its mark is the room index's `closedAt`, so a restarted server gets it again.
extension WorkspaceLifecycleHostTests {
    func roomOp(_ c: HostCore, _ op: HostOp, _ room: String, loose: Bool = true) async -> HostMessage {
        var q = ChatRoomRequest(room: room)
        q.loose = loose ? true : nil
        var r = HostRequest(op)
        r.chatRoom = q
        return await c.handle(r)
    }

    func testALooseRoomIsClosedAndOpenedThroughTheClosedSet() async throws {
        let c = await lcore()
        try rooms.makeRoom("hall")
        // Without --loose: refused, nothing handed over.
        var m = await roomOp(c, .chatRoomClose, "hall", loose: false)
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(rooms.closedSets.isEmpty)
        m = await roomOp(c, .chatRoomClose, "hall")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(rooms.closedSets.last?["hall"], ChatRoomControl.looseOwner)
        XCTAssertNotNil(try ChatRoomIndex.load(ChatPaths(store: store)).rooms["hall"]?.closedAt, "kept in the room index")
        XCTAssertTrue(ChatRoomControl.closedText(room: "hall", workspace: ChatRoomControl.looseOwner).contains("doz chat room open hall --loose"))
        // Every later push carries it (a restarted server gets it again).
        await c.pushClosedSet()
        XCTAssertEqual(rooms.closedSets.last?["hall"], ChatRoomControl.looseOwner)
        m = await roomOp(c, .chatRoomOpen, "hall")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertNil(rooms.closedSets.last?["hall"])
        XCTAssertNil(try ChatRoomIndex.load(ChatPaths(store: store)).rooms["hall"]?.closedAt)
        // A room that is not there; a workspace's own room.
        m = await roomOp(c, .chatRoomClose, "nowhere")
        XCTAssertEqual(m.error?.code, .notFound)
        try await started(c)
        m = await roomOp(c, .chatRoomClose, "demo")
        XCTAssertEqual(m.error?.code, .invalidPhase, m.error?.message ?? "")
        // A read-only core never does it.
        let ro = await lcore(readOnly: true)
        m = await roomOp(ro, .chatRoomClose, "hall")
        XCTAssertEqual(m.error?.code, .unavailable)
    }
}
