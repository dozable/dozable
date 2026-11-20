import Darwin
import DozableChat
@testable import DozableHost
import Foundation
import XCTest

/// The one copier of `doz sessions @mac --transcripts S --export DIR`: no link, no hard link, no other folder's
/// conversation, nothing too large, nothing written over — and only the files the session's record names.
final class TranscriptCopyTests: XCTestCase {
    var root = ""
    let id1 = "11111111-2222-4333-8444-555555555555"
    let id2 = "66666666-7777-4888-9999-aaaaaaaaaaaa"
    let other = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"

    override func setUpWithError() throws {
        let made = "/tmp/dzc-tcopy-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        root = MacFencePaths.resolve(made)!
        try FileManager.default.createDirectory(atPath: root + "/work", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/store", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    var workdir: String { root + "/work" }
    var projects: String { root + "/projects" }
    var folder: String { projects + "/" + MacPlace.claudeProjectFolderName(workdir) }

    func conversation(_ id: String, cwd: String? = nil, extra: String = "") throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let text = #"{"type":"user","cwd":"\#(cwd ?? workdir)","message":"hello \#(extra)"}"# + "\n"
        try Data(text.utf8).write(to: URL(fileURLWithPath: folder + "/\(id).jsonl"))
    }

    func record(_ ids: [String]) -> MacSessionRecord {
        MacSessionRecord(argv: ["claude"], workdir: workdir, openedAt: Date(), claudeSessionIDs: ids)
    }

    func testOnlyTheRecordedConversationsAreListedNeverAFolder() throws {
        try conversation(id1)
        try conversation(id2)
        try conversation(other)               // another session's in the same folder
        let own = MacTranscriptExport.ownFiles(record([id1, id2]), carriedTo: nil, projects: projects)
        XCTAssertEqual(own.items.map(\.name), [id1 + ".jsonl", id2 + ".jsonl"])
        XCTAssertFalse(own.items.contains { $0.name.hasPrefix(other) }, "a sibling file is never found")
        let none = MacTranscriptExport.ownFiles(record([]), carriedTo: nil, projects: projects)
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertTrue(none.notes.first?.contains("no conversation of this session was recorded") == true)
    }

    func testTheExportCopiesExactlyThoseSweptWithAManifest() throws {
        let token = ChatTokens.make()
        try conversation(id1, extra: token)
        try conversation(other)
        var l = MacTranscripts.Listing(session: "s1", items: [], carriedTo: nil)
        l.workdir = workdir
        l.conversations = MacTranscriptExport.ownFiles(record([id1]), carriedTo: nil, projects: projects).items
        let store = DozableStore(root: URL(fileURLWithPath: root + "/store"))
        let out = root + "/out"
        let m = try MacTranscriptExport.export(l, into: try ExportFolder(out, store: store), sweep: ExportSweep(tokenHashes: ["bot1": ChatSecrets.hash(token)]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out).sorted(), [id1 + ".jsonl", "manifest.json"])
        XCTAssertEqual(m.files.count, 1)
        XCTAssertNotEqual(m.files[0].sourceSHA256, m.files[0].sha256, "the sweep changed the copy; both shas kept")
        XCTAssertEqual(m.sweep.findings.first?.participant, "bot1")
        XCTAssertFalse(try String(contentsOfFile: out + "/" + id1 + ".jsonl", encoding: .utf8).contains(token))
        XCTAssertEqual(try String(contentsOfFile: folder + "/" + id1 + ".jsonl", encoding: .utf8).contains(token), true, "the source is untouched")
    }

    func testEveryRefusal() throws {
        // A link.
        try conversation(id2)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/\(id1).jsonl", withDestinationPath: folder + "/\(id2).jsonl")
        guard case .failure = TranscriptCopy.read(folder + "/\(id1).jsonl", name: id1 + ".jsonl", workdir: workdir) else { return XCTFail("a link is refused") }
        try FileManager.default.removeItem(atPath: folder + "/\(id1).jsonl")
        // A hard link.
        XCTAssertEqual(link(folder + "/\(id2).jsonl", folder + "/\(id1).jsonl"), 0)
        guard case .failure(let hard) = TranscriptCopy.read(folder + "/\(id1).jsonl", name: id1 + ".jsonl", workdir: workdir) else { return XCTFail("a hard link is refused") }
        XCTAssertTrue(hard.why.contains("hard link"), hard.why)
        try FileManager.default.removeItem(atPath: folder + "/\(id1).jsonl")
        // Written in another folder.
        try conversation(id1, cwd: "/somewhere/else")
        guard case .failure(let foreign) = TranscriptCopy.read(folder + "/\(id1).jsonl", name: id1 + ".jsonl", workdir: workdir) else { return XCTFail("a foreign cwd") }
        XCTAssertTrue(foreign.why.contains("another folder"), foreign.why)
        // Too large.
        let big = folder + "/" + other + ".jsonl"
        FileManager.default.createFile(atPath: big, contents: nil)
        XCTAssertEqual(truncate(big, off_t(MacTranscripts.maximumFileBytes + 1)), 0)
        guard case .failure(let large) = TranscriptCopy.read(big, name: other + ".jsonl", workdir: workdir) else { return XCTFail("oversize") }
        XCTAssertTrue(large.why.contains("larger"), large.why)
        // Not a conversation's name.
        guard case .failure = TranscriptCopy.read(folder + "/\(id2).jsonl", name: "notes.jsonl", workdir: workdir) else { return XCTFail("a name") }
        // An existing destination is never written over.
        let store = DozableStore(root: URL(fileURLWithPath: root + "/store"))
        let f = try ExportFolder(root + "/out2", store: store)
        try f.write(id2 + ".jsonl", Array("x".utf8))
        XCTAssertThrowsError(try f.write(id2 + ".jsonl", Array("y".utf8)))
    }

    func testClearAddsASecondIDAndARestartKeepsThem() {
        var ids = MacSessionRecord.adding(id1, to: nil)
        ids = MacSessionRecord.adding(id2, to: ids)
        XCTAssertEqual(ids, [id1, id2], "/clear: two conversations recorded")
        XCTAssertEqual(MacSessionRecord.adding(id2, to: ids), [id1, id2], "the same one again: once")
        var many: [String]? = nil
        for i in 0..<70 { many = MacSessionRecord.adding(String(format: "00000000-0000-4000-8000-%012d", i), to: many) }
        XCTAssertEqual(many?.count, 64, "at most 64, the oldest dropped")
    }
}
