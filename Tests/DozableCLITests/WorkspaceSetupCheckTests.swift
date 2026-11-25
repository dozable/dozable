import Foundation
import XCTest
@testable import DozableHost

/// The set-up check (`WorkspaceSetupCheck.gaps`): one row per gap with its fix, several at once, ready → none, and the
/// one-live-workspace rule apart.
final class WorkspaceSetupCheckTests: XCTestCase {
    typealias C = WorkspaceSetupCheck

    func ready(_ edit: (inout C.Input) -> Void = { _ in }) -> C.Input {
        var i = C.Input(workspace: "demo", briefBytes: 20, chat: .ready, mainRoom: "demo", mainRoomExists: true,
                        folders: [C.Folder(path: "/tmp/x", exists: true)],
                        agents: [C.Agent(name: "wsa", place: "wsa", kind: "sandbox", exists: true)],
                        manager: C.Manager(bot: "mira", placeName: "demo"))
        edit(&i)
        return i
    }

    func lines(_ i: C.Input) -> [String] { C.gaps(i).map(\.line) }

    func testReadyHasNoGap() {
        XCTAssertEqual(C.gaps(ready()), [])
        XCTAssertEqual(C.gaps(ready { $0.manager = nil; $0.chat = .off; $0.mainRoom = nil }), [], "no manager, chat off: you drive")
    }

    /// A look (the plan, `show`) never reads the keychain: not looked is no gap — a locked one shows only at the start.
    func testAKeychainNotLookedAtIsNoGap() {
        XCTAssertEqual(C.gaps(ready { $0.manager?.keychainReadable = nil }), [])
        XCTAssertEqual(C.gaps(ready { $0.manager?.keychainReadable = false }).map(\.item), ["manager"])
    }

    func testOneRowPerGap() {
        let rows: [((inout C.Input) -> Void, String)] = [
            ({ $0.chat = .off }, "a manager needs chat — doz chat on"),
            ({ $0.chat = .notReady("starting") }, "chat is on but its server is not ready (starting) — doz chat status"),
            ({ $0.mainRoom = nil }, "no main room — doz workspace edit demo --make-room"),
            ({ $0.mainRoomExists = false }, "the room demo is gone from the chat server — doz chat room demo, then start again"),
            ({ $0.folders = [C.Folder(path: "/tmp/x", exists: false)] }, "folder /tmp/x is gone — doz workspace edit demo --remove-folder /tmp/x"),
            ({ $0.agents = [C.Agent(name: "wsa", place: "wsa", kind: "sandbox", exists: false)] }, "agent wsa: sandbox wsa is gone — doz workspace release demo wsa"),
            ({ $0.manager?.deliver = "inbox" }, "mira is reached by inbox, which only an unfenced session gets; a fenced or sandboxed manager polls — doz bot set mira --deliver poll"),
            ({ $0.manager?.deliver = "inbox"; $0.manager?.isolation = "vm"; $0.manager?.programOnPath = nil },
             "mira is reached by inbox, which only an unfenced session gets; a fenced or sandboxed manager polls — doz bot set mira --deliver poll"),
            ({ $0.manager?.deliver = "webhook" }, "mira is reached by webhook; a manager Dozable starts collects its own messages — doz bot set mira --deliver poll"),
            ({ $0.manager?.keeper = "elsewhere" }, "mira's token is not held by Dozable — doz bot token mira --new"),
            ({ $0.manager?.keychainReadable = false }, "mira's token cannot be read from the login keychain (locked, or changed underneath) — unlock it, or doz bot token mira --new"),
            ({ $0.manager?.agent = "pi" }, "Dozable does not start a manager running pi yet — make a Claude Code or Codex bot its manager: doz workspace edit demo --manager BOT"),
            ({ $0.manager?.programOnPath = false }, "claude is not on this Mac's PATH — install it, or doz workspace edit demo --manager mira --manager-isolation sandbox"),
            ({ $0.manager?.placeTaken = true }, "a session called demo already exists on this Mac — doz sessions end @mac demo, or rename the workspace"),
            ({ $0.manager?.placeTaken = true; $0.manager?.isolation = "vm" }, "a sandbox called demo already exists — doz rm demo, or rename the workspace"),
            ({ $0.manager?.known = false }, "mira is not a bot — doz workspace edit demo --manager BOT (doz bot ls)"),
            ({ $0.manager?.retired = true }, "mira was retired — doz workspace edit demo --manager BOT, or --no-manager"),
            ({ $0.manager?.botIsolation = "elsewhere" }, "a bot elsewhere runs on its own machine; Dozable never starts it — doz workspace edit demo --no-manager"),
        ]
        for (edit, want) in rows { XCTAssertEqual(lines(ready(edit)), [want]) }
    }

    /// 782: an empty description is no gap.
    func testAnEmptyDescriptionIsNoGap() {
        XCTAssertEqual(C.gaps(ready { $0.briefBytes = 0 }), [])
    }

    func testAnUnfencedInboxManagerIsFine() {
        XCTAssertEqual(C.gaps(ready { $0.manager?.deliver = "inbox"; $0.manager?.isolation = "unfenced" }), [])
    }

    func testEveryGapAtOnce() {
        let g = C.gaps(ready {
            $0.briefBytes = 0
            $0.chat = .off
            $0.folders = [C.Folder(path: "/tmp/x", exists: false), C.Folder(path: "/tmp/y", exists: false)]
            $0.manager?.deliver = "inbox"
        })
        XCTAssertEqual(g.map(\.item), ["chat", "folder", "folder", "manager"], "782: an empty description is no gap")
        XCTAssertTrue(g.allSatisfy { !$0.fix.isEmpty })
    }

    func testOneLiveWorkspaceIsApart() {
        let entries = [C.Entry(workspace: "launch-video", bot: "mira", running: true),
                       C.Entry(workspace: "quiet", bot: "mira", running: false),
                       C.Entry(workspace: "other", bot: "otto", running: true),
                       C.Entry(workspace: "demo", bot: "mira", running: true)]
        XCTAssertEqual(C.liveElsewhere(bot: "mira", workspace: "demo", entries: entries, starting: []), "launch-video")
        XCTAssertNil(C.liveElsewhere(bot: "mira", workspace: "demo", entries: Array(entries.dropFirst()), starting: []),
                     "an entry that does not run, another bot, or this workspace: none")
        XCTAssertEqual(C.liveElsewhere(bot: "mira", workspace: "demo", entries: Array(entries.dropFirst()), starting: ["quiet"]), "quiet",
                       "a start under way counts")
        XCTAssertNil(C.liveElsewhere(bot: "ada", workspace: "demo", entries: entries, starting: []),
                     "a participant that is no workspace's agent (an admin in the room) does not count")
        XCTAssertEqual(C.liveElsewhereRefusal(bot: "mira", other: "launch-video"),
                       "mira already manages launch-video, which is running. For now a bot runs in one live workspace at a time — doz workspace stop launch-video first.")
    }
}
