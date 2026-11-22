import ArgumentParser
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 757 (VOC2): sandbox disks are `doz image save | ls | rm`; `doz template create | ls | rm` forward there for one release
/// with one stderr notice and, in --json, the same answer plus `deprecated`. No host, no VM (`make test-vm-templates`
/// proves the disk itself).
final class SavedDisksTests: XCTestCase {
    private func parse(_ args: [String]) throws -> ParsableCommand { try DozableCommand.parseAsRoot(args) }

    private func firstLines(_ help: String, _ n: Int) -> String { help.split(separator: "\n", omittingEmptySubsequences: false).prefix(n).joined(separator: "\n") }

    /// The definition of done's two help rows (750.08 VOC2).
    func testTheHelpNamesTheNewHome() {
        XCTAssertTrue(firstLines(ImageCommand.helpMessage(), 40).contains("save"), "doz image --help names save within 40 lines")
        XCTAssertTrue(firstLines(TemplateCommand.helpMessage(), 15).contains("doz image"), "doz template --help names doz image within 15 lines")
        XCTAssertTrue(TemplateCommand.configuration.abstract.contains("doz image save"), "doz --help's list says where the disks went")
        XCTAssertTrue(ImageCommand.configuration.abstract.contains("saved disks"))
        XCTAssertFalse(TemplateCommand.configuration.subcommands.contains { $0 != TemplateCreate.self && $0 != TemplateList.self && $0 != TemplateRemove.self },
                       "no new template subcommand — TPL1 gives the word its workspace meaning")
    }

    func testImageSaveParsesAndMakesTheSameRequestAsTemplateCreate() throws {
        let s = try XCTUnwrap(parse(["image", "save", "box", "node-tools", "--from-point", "p1", "--note", "n", "--json"]) as? ImageSave)
        XCTAssertEqual(s.sandbox, "box")
        XCTAssertEqual(s.name, "node-tools")
        XCTAssertEqual(s.point, "p1")
        XCTAssertEqual(s.note, "n")
        XCTAssertTrue(s.g.json)
        XCTAssertThrowsError(try parse(["image", "save", "box"]), "the disk's name is required")
        let t = try XCTUnwrap(parse(["template", "create", "box", "--as", "node-tools", "--from-point", "p1", "--note", "n"]) as? TemplateCreate)
        XCTAssertEqual(t.name, "box")
        XCTAssertEqual(t.template, "node-tools")
        // The same daemon op, the same fields, whichever command asked.
        let r = SavedDisks.saveRequest(sandbox: s.sandbox, name: s.name, point: s.point, note: s.note)
        XCTAssertEqual(r, SavedDisks.saveRequest(sandbox: t.name, name: t.template, point: t.point, note: t.note))
        XCTAssertEqual(r.op, .templateCreate)
        XCTAssertEqual(r.name, "box")
        XCTAssertEqual(r.image, "node-tools")
        XCTAssertEqual(r.point, "p1")
        XCTAssertEqual(r.note, "n")
        XCTAssertTrue(try parse(["template"]) is TemplateList, "doz template still lists (its default)")
        XCTAssertTrue(try parse(["template", "rm", "x", "--yes"]) is TemplateRemove)
        XCTAssertTrue(try parse(["image", "rm", "x", "--yes"]) is ImageRemove)
    }

    func testTheNotice() {
        XCTAssertEqual(SavedDisks.notice, "`doz template` now means workspace templates; sandbox disks are `doz image save|ls|rm`")
        XCTAssertEqual([SavedDisks.saveCommand, SavedDisks.listCommand, SavedDisks.removeCommand], ["doz image save", "doz image ls", "doz image rm"])
    }

    private struct Thing: Codable, Equatable { var name: String; var allocatedBytes: Int64 }

    /// `deprecated` is ADDED: an object gains the field, an array's rows each gain it — nothing else changes, so an
    /// existing reader decodes the answer as before.
    func testDeprecatedIsAddedAndNothingElseChanges() throws {
        let o = try SavedDisks.withDeprecated(Thing(name: "node-tools", allocatedBytes: 36 << 20), SavedDisks.saveCommand)
        guard case .object(let fields) = o else { return XCTFail("an object stays an object: \(o)") }
        XCTAssertEqual(Set(fields.keys), ["name", "allocatedBytes", "deprecated"])
        XCTAssertEqual(fields["deprecated"], .string("doz image save"))
        XCTAssertEqual(try o.decode(Thing.self), Thing(name: "node-tools", allocatedBytes: 36 << 20))

        var a = ImageRow(name: "node-tools", kind: "custom", baked: true)
        a.fromSandbox = "box"
        a.note = "node 22"
        let b = ImageRow(name: "base-2", kind: "custom", baked: true)
        let rows = try SavedDisks.withDeprecated([a, b], SavedDisks.listCommand)
        guard case .array(let items) = rows else { return XCTFail("an array stays an array: \(rows)") }
        XCTAssertEqual(items.count, 2)
        for item in items { XCTAssertEqual(item["deprecated"], .string("doz image ls")) }
        XCTAssertEqual(try rows.decode([ImageRow].self), [a, b], "readers of [ImageRow] read the same rows")
        let plain = try JSONValue(encoding: [a, b])
        guard case .array(let before) = plain else { return XCTFail() }
        for (x, y) in zip(before, items) {
            guard case .object(var ox) = x, case .object(var oy) = y else { return XCTFail() }
            oy.removeValue(forKey: "deprecated")
            ox.removeValue(forKey: "deprecated")
            XCTAssertEqual(ox, oy, "apart from deprecated, each row is exactly image ls's")
        }
        XCTAssertEqual(try SavedDisks.withDeprecated([ImageRow](), SavedDisks.listCommand), .array([]))
        XCTAssertEqual(try SavedDisks.withDeprecated("x", SavedDisks.listCommand), .string("x"), "anything else is unchanged")
    }

    /// image ls / rm on a saved disk: told apart from a built-in or baked image; the question says which.
    func testASavedDiskIsToldApart() {
        let saved = ImageRow(name: "node-tools", kind: "custom", baked: true), builtIn = ImageRow(name: "pi", kind: "builtin", baked: true)
        XCTAssertTrue(SavedDisks.isSaved(saved))
        XCTAssertFalse(SavedDisks.isSaved(builtIn))
        XCTAssertEqual(SavedDisks.rows([builtIn, saved]), [saved], "doz template ls is image ls's saved disks")
        XCTAssertTrue(SavedDisks.removeQuestion("node-tools", saved: true).hasPrefix("Remove the saved disk node-tools?"))
        XCTAssertEqual(SavedDisks.removeQuestion("pi", saved: false), "Remove the image pi? (It is baked again when next needed.)", "a baked image's question is as before")
        let tree = ImageTree(disks: [
            .init(path: "/s/images/pi/bf/root.ext4", kind: .image, name: "pi@bf46815674ce", allocatedBytes: 900 << 20, uniqueBytes: 600 << 20),
            .init(path: "/s/images/custom/tpl/x/root.ext4", kind: .customImage, name: "custom:tpl/disk-1", parentPath: "/s/images/pi/bf/root.ext4",
                  allocatedBytes: 950 << 20, uniqueBytes: 40 << 20, sharedWithParentBytes: 900 << 20),
        ], customNames: ["tpl/disk-1": "tpl"])
        XCTAssertEqual(tree.nodes.last?.kind, "template", "the lineage's JSON keeps the node kind")
        XCTAssertTrue(renderImageTree(tree).split(separator: "\n").contains { $0.contains("tpl") && $0.contains("saved disk") }, "the table says saved disk")
    }
}
