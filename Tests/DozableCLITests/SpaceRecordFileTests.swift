import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// A space workspace's file, read and saved by the daemon (`SpaceRecordFile`, kind `space`): never a link anywhere in its
/// path, never a FIFO or anything but a regular file, under the home folder and never in the store, `~/.claude` or
/// `~/Library`, at most 256 KiB of UTF-8 that starts with its format line; written by temp-and-rename with its mode kept,
/// only when the file is still the one read (`ifMatch`). Through the daemon (`workspace-space`, `workspace-space-save`): the
/// path is the record's, a read starts no daemon, a save never runs up and logs only its sha256.
final class SpaceRecordFileTests: XCTestCase {
    var home: String!
    var store: String!
    let good = "# a comment first is fine\ndoz: space/3\nspace: sp\n"

    override func setUpWithError() throws {
        home = WorkspaceStore.resolved("/tmp") + "/doz-srf-\(UUID().uuidString.prefix(8))"
        store = home + "/store"
        try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func file(_ text: String, _ name: String = "sp.space.yaml") throws -> String {
        let dir = home + "/work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = dir + "/" + name
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testTheRules() throws {
        let p = try file(good)
        chmod(p, 0o640)
        let r = try SpaceRecordFile.read(.space, p, store: store, home: home)
        XCTAssertEqual(r.text, good)
        // A stale ifMatch: refused, nothing written.
        XCTAssertThrowsError(try SpaceRecordFile.write(.space, good + "x: 1\n", to: p, ifSHA: String(repeating: "0", count: 64), store: store, home: home)) { e in
            XCTAssertEqual((e as? HostError)?.code, .fileChanged)
            XCTAssertTrue((e as? HostError)?.message.hasPrefix("the space file changed since you opened it") == true)
        }
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), good)
        // A save: written, its mode kept.
        let w = try SpaceRecordFile.write(.space, good + "title: t\n", to: p, ifSHA: r.sha256, store: store, home: home)
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), good + "title: t\n")
        XCTAssertEqual(w.sha256, WorkspaceStore.sha256(Data((good + "title: t\n").utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        // A text that is not a space file: never written.
        XCTAssertThrowsError(try SpaceRecordFile.write(.space, "space: sp\n", to: p, ifSHA: w.sha256, store: store, home: home))
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), good + "title: t\n")
        // A file that is not one: refused to read.
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, try file("space: sp\n", "nohead.space.yaml"), store: store, home: home))
        XCTAssertNoThrow(try SpaceRecordFile.read(.space, try file("doz: space-defaults/3\n", "d.yaml"), store: store, home: home))
        // Too large, and not UTF-8.
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, try file("doz: space/3\n" + String(repeating: "#", count: 257 << 10), "big.space.yaml"), store: store, home: home))
        XCTAssertThrowsError(try SpaceRecordFile.write(.space, "doz: space/3\n" + String(repeating: "#", count: 257 << 10), to: p, ifSHA: nil, store: store, home: home))
        let bad = home + "/work/bad.space.yaml"
        FileManager.default.createFile(atPath: bad, contents: Data([0x64, 0x6F, 0x7A, 0x3A, 0xFF, 0xFE, 0x0A]))
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, bad, store: store, home: home))
    }

    func testNoLinkNoFIFOAndOnlyUnderTheHome() throws {
        let p = try file(good)
        // A link to the file, and a link in its path: refused, never followed or written through.
        let link = home + "/work/link.space.yaml"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: p)
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, link, store: store, home: home))
        XCTAssertThrowsError(try SpaceRecordFile.write(.space, good, to: link, ifSHA: nil, store: store, home: home))
        try FileManager.default.createSymbolicLink(atPath: home + "/linked", withDestinationPath: home + "/work")
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, home + "/linked/sp.space.yaml", store: store, home: home))
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), good)
        // A FIFO: never opened as a file (nothing blocks on it).
        let fifo = home + "/work/fifo.space.yaml"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, fifo, store: store, home: home))
        // Outside the home, in the store, in ~/.claude or ~/Library: refused by its place alone.
        XCTAssertNotNil(SpaceRecordFile.placeRefusal("/etc/sp.space.yaml", home: home, store: store))
        XCTAssertNotNil(SpaceRecordFile.placeRefusal(store + "/sp.space.yaml", home: home, store: store))
        XCTAssertNotNil(SpaceRecordFile.placeRefusal(home + "/.claude/sp.space.yaml", home: home, store: store))
        XCTAssertNotNil(SpaceRecordFile.placeRefusal(home + "/Library/sp.space.yaml", home: home, store: store))
        let inStore = store + "/sp.space.yaml"
        try good.write(toFile: inStore, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SpaceRecordFile.read(.space, inStore, store: store, home: home))
        XCTAssertThrowsError(try SpaceRecordFile.write(.space, good, to: inStore, ifSHA: nil, store: store, home: home))
    }

    func testTheFormatLine() {
        XCTAssertNil(SpaceRecordFile.formatRefusal("doz: space/3\n"))
        XCTAssertNil(SpaceRecordFile.formatRefusal("\n# x\n---\ndoz: space-defaults/3\n"))
        XCTAssertNotNil(SpaceRecordFile.formatRefusal("doz: space/2\n"))
        XCTAssertNotNil(SpaceRecordFile.formatRefusal("space: x\ndoz: space/3\n"))
        XCTAssertNotNil(SpaceRecordFile.formatRefusal(""))
    }
}

/// Through an in-process daemon core: the file read from the record's path (in-process with no daemon), saved only with a
/// current `ifMatch` and never applied; `workspace-state` with no daemon not known, with one known.
extension WorkspaceLifecycleHostTests {
    func testTheSpaceFileIsReadAndSavedThroughTheRecord() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              w1: { kind: claude-code, prompt: one }
            """)
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let ro = await lcore(readOnly: true)
            // Read with no daemon: the record's file.
            var m = await ws(ro, .workspaceSpace, "sp")
            XCTAssertNil(m.error, m.error?.message ?? "")
            let f = try XCTUnwrap(m.result).decode(WorkspaceSpaceFile.self)
            let text = try String(contentsOfFile: s.file, encoding: .utf8)
            XCTAssertEqual(f.text, text)
            XCTAssertEqual(f.file, "sp.space.yaml")
            XCTAssertEqual(f.sha256, WorkspaceStore.sha256(Data(text.utf8)))
            // A save needs the daemon.
            m = await ws(ro, .workspaceSpaceSave, "sp") { $0.text = text; $0.ifMatch = f.sha256 }
            XCTAssertEqual(m.error?.code, .unavailable)
            let recBefore = try XCTUnwrap(record("sp"))
            let ordersBefore = workers.orders.count
            // A stale ifMatch: refused, nothing written.
            m = await ws(c, .workspaceSpaceSave, "sp") { $0.text = text + "title: x\n"; $0.ifMatch = String(repeating: "0", count: 64) }
            XCTAssertEqual(m.error?.code, .fileChanged)
            XCTAssertEqual(try String(contentsOfFile: s.file, encoding: .utf8), text)
            // Without ifMatch: refused.
            m = await ws(c, .workspaceSpaceSave, "sp") { $0.text = text }
            XCTAssertEqual(m.error?.code, .invalid)
            // Saved: written, never applied — the record and its space reference as they were, no worker started.
            m = await ws(c, .workspaceSpaceSave, "sp") { $0.text = text + "title: x\n"; $0.ifMatch = f.sha256 }
            XCTAssertNil(m.error, m.error?.message ?? "")
            let saved = try XCTUnwrap(m.result).decode(WorkspaceSpaceSaved.self)
            XCTAssertFalse(saved.applied)
            XCTAssertEqual(try String(contentsOfFile: s.file, encoding: .utf8), text + "title: x\n")
            let recAfter = try XCTUnwrap(record("sp"))
            XCTAssertEqual(SpaceRecordRef.of(recAfter), SpaceRecordRef.of(recBefore), "saving never runs up")
            XCTAssertEqual(recAfter.agents, recBefore.agents)
            XCTAssertEqual(workers.orders.count, ordersBefore)
            let entry = try XCTUnwrap(try WorkspaceStore(store: store).log("sp").last)
            XCTAssertEqual(entry.action, "space-saved")
            XCTAssertEqual(entry.sha256, saved.sha256)
            XCTAssertNil(entry.reason)
            // Not a space file's text: refused.
            m = await ws(c, .workspaceSpaceSave, "sp") { $0.text = "space: sp\n"; $0.ifMatch = saved.sha256 }
            XCTAssertEqual(m.error?.code, .invalid)
            // A workspace made without a space file has none.
            _ = await ws(c, .workspaceNew, "plain") { $0.brief = "b\n"; $0.noRoom = true }
            m = await ws(ro, .workspaceSpace, "plain")
            XCTAssertEqual(m.error?.code, .notFound)
            // 751: but its state answers, from its record — with no daemon not known; a workspace that does not exist is not found.
            m = await ws(ro, .workspaceState, "plain")
            XCTAssertNil(m.error, m.error?.message ?? "")
            let plain = try XCTUnwrap(m.result).decode(SpaceState.self)
            XCTAssertEqual(plain.space, "plain")
            XCTAssertFalse(plain.factsKnown)
            m = await ws(c, .workspaceState, "plain") { $0.withConditions = true }
            XCTAssertNil(m.error, m.error?.message ?? "")
            XCTAssertEqual(try XCTUnwrap(m.result).decode(SpaceState.self).agentConditions?.from, "record")
            m = await ws(c, .workspaceState, "sp") { $0.withConditions = true }
            XCTAssertEqual(try XCTUnwrap(m.result).decode(SpaceState.self).agentConditions?.from, "space-file")
            m = await ws(c, .workspaceState, "sp")
            XCTAssertNil(try XCTUnwrap(m.result).decode(SpaceState.self).agentConditions, "only when asked: the dashboard's document is the editor's")
            m = await ws(ro, .workspaceState, "nosuch")
            XCTAssertEqual(m.error?.code, .notFound)
            m = await ws(c, .workspaceState, "nosuch")
            XCTAssertEqual(m.error?.code, .notFound)
            // Its state: with no daemon not known; with one, known.
            m = await ws(ro, .workspaceState, "sp")
            XCTAssertNil(m.error, m.error?.message ?? "")
            let unknown = try XCTUnwrap(m.result).decode(SpaceState.self)
            XCTAssertFalse(unknown.factsKnown)
            XCTAssertTrue(unknown.items.allSatisfy { $0.state == "unknown" })
            XCTAssertEqual(unknown.run?.phase, "up")
            m = await ws(c, .workspaceState, "sp")
            let known = try XCTUnwrap(m.result).decode(SpaceState.self)
            XCTAssertTrue(known.factsKnown)
            XCTAssertEqual(known.items.map { "\($0.type) \($0.subject)" }, unknown.items.map { "\($0.type) \($0.subject)" }, "stable keys")
            XCTAssertEqual(known.sha, known.computedSHA)
        }
    }
}

/// The space view's plan (`SpaceDashboardPlan`, doz ui's): the page's open text planned at the record's path with the
/// existing `workspace-up-plan` — `${VAR}` only from the `.env` beside the file (never doz ui's environment: not found is a
/// warning, "set in your terminal, not known here"), the defaults file it extends read under the same rules, nothing
/// written.
extension WorkspaceLifecycleHostTests {
    func testTheDashboardsPlanReadsTheOpenTextAndOnlyTheEnvBesideIt() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              w1: { kind: claude-code, prompt: one }
            """)
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let ro = await lcore(readOnly: true)
            let send: @Sendable (HostRequest) async throws -> JSONValue = { r in
                let m = await ro.handle(r)
                if let e = m.error { throw e }
                return m.result ?? .null
            }
            let fileBefore = try Data(contentsOf: URL(fileURLWithPath: s.file))
            setenv("DOZ_DASH_PLAN_TITLE", "from the environment", 1)
            defer { unsetenv("DOZ_DASH_PLAN_TITLE") }
            let text = try String(contentsOfFile: s.file, encoding: .utf8) + "title: ${DOZ_DASH_PLAN_TITLE}\n"
            var p = try await SpaceDashboardPlan.plan(store: store.root.path, workspace: "sp", text: text, send: send)
            let warn = try XCTUnwrap(p.problems.first { $0.message.contains("DOZ_DASH_PLAN_TITLE") })
            XCTAssertEqual(warn.severity, "warning")
            XCTAssertEqual(warn.hint, SpaceDashboardPlan.notKnownHere)
            XCTAssertNotEqual(p.title, "from the environment", "never doz ui's environment")
            XCTAssertEqual(p.specPath, s.file, "the record's path")
            XCTAssertFalse(p.factsKnown)
            // The .env beside the file: used.
            try "DOZ_DASH_PLAN_TITLE=from the env file\n".write(toFile: (s.file as NSString).deletingLastPathComponent + "/.env", atomically: true, encoding: .utf8)
            p = try await SpaceDashboardPlan.plan(store: store.root.path, workspace: "sp", text: text, send: send)
            XCTAssertEqual(p.title, "from the env file")
            XCTAssertFalse(p.problems.contains { $0.message.contains("DOZ_DASH_PLAN_TITLE") })
            // A typo in the open text: a problem, nothing sent to plan.
            p = try await SpaceDashboardPlan.plan(store: store.root.path, workspace: "sp", text: text + "agentz: {}\n", send: send)
            XCTAssertTrue(p.problems.contains { $0.isError }, p.problems.map(\.text).joined(separator: "\n"))
            XCTAssertEqual(p.refusalCode, "invalid")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.file)), fileBefore, "planning writes nothing")
        }
    }
}
