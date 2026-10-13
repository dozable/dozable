import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 617: an image's build log — every line of each bake step, kept per image in the store, rendered inert.
final class BuildLogsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-blog-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAStepsWholeOutputKeepsEveryLineInOrderInert() {
        let w = StepOutputLines()
        w.add(Data("Get:1 http://deb\nGet:2 ht".utf8))
        w.add(Data("tp://deb\n\u{1B}[31mred\u{1B}[0m\nprogress 10%\rprogress 100%\n".utf8))
        w.add(Data("no newline at the end".utf8))
        XCTAssertEqual(w.finish(), ["Get:1 http://deb", "Get:2 http://deb", "red", "progress 100%", "no newline at the end"])
        XCTAssertEqual(w.finish(), [], "finish empties it")
    }

    func testAStepsOutputIsCappedHeadAndTailWithTheCountSaid() {
        let w = StepOutputLines(head: 2, tail: 3)
        w.add(Data((1...10).map { "l\($0)" }.joined(separator: "\n").appending("\n").utf8))
        XCTAssertEqual(w.finish(), ["l1", "l2", "… 5 lines not kept …", "l8", "l9", "l10"])
    }

    func testTheLogIsKeptPerImageRoundTripsAndIsPrivate() throws {
        let store = DozerStore(root: root)
        let log = BuildLog(image: "node-codex", state: "done", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                           finishedAt: Date(timeIntervalSince1970: 1_800_000_090), seconds: 90, error: nil,
                           steps: [PreparationStep(label: "step: install codex", kind: "step", seconds: 42)],
                           sections: [.init(label: "step: install codex", lines: ["added 1 package"])])
        BuildLogs.save(log, store: store)
        XCTAssertEqual(BuildLogs.read("node-codex", store: store), log)
        let u = try XCTUnwrap(BuildLogs.url("node-codex", store: store))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(Resources.classify(["build-logs", "node-codex.json"], currentLabKey: nil), "store", "Dozer's own records")
        XCTAssertNil(BuildLogs.read("pi", store: store))
        for bad in ["../x", "a/b", "", ".hidden", "UPPER", String(repeating: "a", count: 65)] {
            XCTAssertNil(BuildLogs.url(bad, store: store), bad)
        }
    }

    func testTheLogIsCappedNewestSectionsFirst() {
        let big = BuildLog.Section(label: "step: old", lines: Array(repeating: "x", count: BuildLogs.maximumLines))
        let new = BuildLog.Section(label: "step: new", lines: ["a", "b"])
        let l = BuildLogs.capped(BuildLog(image: "pi", state: "done", startedAt: Date(), finishedAt: Date(), seconds: 1, error: nil,
                                          steps: [], sections: [big, new]))
        XCTAssertEqual(l.sections.last, new, "the newest section whole")
        XCTAssertEqual(l.sections.first?.lines.first, "… 2 lines not kept …")
        XCTAssertEqual(l.sections.reduce(0) { $0 + $1.lines.count }, BuildLogs.maximumLines + 1)
    }

    func testTheRenderingIsTheStepsThenTheOutputAndNothingInIsASequence() {
        let l = BuildLog(image: "pi", state: "failed", startedAt: Date(), finishedAt: Date(), seconds: 75, error: "exit 1",
                         steps: [PreparationStep(label: "pulled node", kind: "transfer", seconds: 3),
                                 PreparationStep(label: "step: baseline", kind: "step", seconds: 12.5),
                                 PreparationStep(label: "step: install pi", kind: "failed", seconds: 2, error: "exit \u{1B}]52;c;eA==\u{07}1")],
                         sections: [.init(label: "step: install pi", lines: ["evil \u{1B}]52;c;eA==\u{07}line", "\u{1B}[2Jclear"])])
        let text = BuildLogs.render(l)
        XCTAssertTrue(text.contains("Build of pi"))
        XCTAssertTrue(text.contains("1:15"))
        XCTAssertTrue(text.contains("✓ \u{1B}[0mstep: baseline") || text.contains("step: baseline"))
        XCTAssertTrue(text.contains("── step: install pi ──"))
        XCTAssertTrue(text.contains("evil line"))
        XCTAssertFalse(text.contains("]52;"), "no OSC from the guest")
        XCTAssertFalse(text.contains("\u{1B}[2J"), "no screen control from the guest")
        XCTAssertFalse(text.contains("\u{07}"))
        XCTAssertTrue(text.contains("\r\n"))
    }

    /// The whole flow without a VM: a preparation's runner hands each step's output to the sink; the log is kept when
    /// it ends — and the output is never an event a client sees.
    func testAPreparationKeepsItsBuildLogWhenItEnds() async throws {
        let store = DozerStore(root: root)
        let c = HostCore(store: store, readOnly: false, version: "t", newStoreDefaultAccount: "mac")
        await c.setPreparationRunner({ image, _, emit in
            emit(HostEvent(kind: .started, sandbox: image, text: "step: install"))
            HostCore.buildOutputSink?("step: install", ["line 1", "line 2"])
            emit(HostEvent(kind: .step, sandbox: image, text: "step: install", milliseconds: 1500))
        }, prepared: { _, _ in false })
        var r = HostRequest(.onboard)
        r.images = ["claude-code"]
        r.requestedBy = "test"
        r.follow = false
        _ = await c.handle(r)
        var log: BuildLog?
        for _ in 0..<100 where log == nil {
            log = BuildLogs.read("claude-code", store: store)
            if log == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let l = try XCTUnwrap(log, "the build log is kept")
        XCTAssertEqual(l.state, "done")
        XCTAssertEqual(l.sections, [.init(label: "step: install", lines: ["line 1", "line 2"])])
        XCTAssertEqual(l.steps.map(\.label), ["step: install"])
    }
}
