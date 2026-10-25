import Foundation
import XCTest
@testable import DozableKit
import DozableHost
@testable import DozableWeb

/// 648: `POST /api/v1/grids` — the route (closed table, a read in WebExposure), its strict body and caps, the
/// projection (field by field: the contract's shape, sentences for reasons), never starting a host, CSRF, and the
/// saved screen's grid.
final class WebGridsTests: XCTestCase {
    static let grid = ScreenGrid(cols: 4, rows: 2, gen: 9, fg: "#ffffff", bg: "#000000", cursor: .init(x: 2, y: 0),
                                 lines: [[.init(col: 0, text: "hi", fg: "#cd0000", flags: 1, cells: 2)], []])

    func testTheRoute() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/grids"), .grids)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/grids"), "a POST only (it carries the pictures asked)")
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/grids/x"))
        XCTAssertEqual(WebExposure.kind(.grids), .read)
        XCTAssertNil(WebExposure.decide(.grids, .mac))
        XCTAssertNil(WebExposure.decide(.grids, .remote(secure: false)), "a LAN device's dashboard paints its tiles too")
    }

    func testTheBodyIsStrict() throws {
        let ok = try WebGridsRequest.decode(Data(#"{"items":[{"sandbox":"box","session":"main","gen":0},{"sandbox":"b-2","session":"claude-2","gen":4294967295}]}"#.utf8))
        XCTAssertEqual(ok, [SessionGridRequest(sandbox: "box", session: "main", gen: 0), SessionGridRequest(sandbox: "b-2", session: "claude-2", gen: .max)])
        XCTAssertEqual(try WebGridsRequest.decode(Data(#"{"items":[]}"#.utf8)), [])
        let many = "[" + Array(repeating: #"{"sandbox":"a","session":"s","gen":0}"#, count: 65).joined(separator: ",") + "]"
        for bad in [#"[]"#, #"{}"#, #"{"items":{}}"#, #"{"items":[],"x":1}"#, #"{"items":\#(many)}"#,
                    #"{"items":[{"sandbox":"box","session":"main"}]}"#, #"{"items":[{"sandbox":"box","session":"main","gen":0,"x":1}]}"#,
                    #"{"items":[{"sandbox":"Box","session":"main","gen":0}]}"#, #"{"items":[{"sandbox":"box","session":".x","gen":0}]}"#,
                    #"{"items":[{"sandbox":"box","session":"a/b","gen":0}]}"#, #"{"items":[{"sandbox":"box","session":"main","gen":-1}]}"#,
                    #"{"items":[{"sandbox":"box","session":"main","gen":1.5}]}"#, #"{"items":[{"sandbox":"box","session":"main","gen":true}]}"#,
                    #"{"items":[{"sandbox":"box","session":"main","gen":"1"}]}"#, #"{"items":[{"sandbox":"box","session":"main","gen":4294967296}]}"#,
                    #"{"items":["box"]}"#, "not json"] {
            XCTAssertThrowsError(try WebGridsRequest.decode(Data(bad.utf8)), bad) { e in
                let message = (e as? WebAction.Invalid)?.message ?? ""
                XCTAssertFalse(message.contains("Box") || message.contains("a/b") || message.contains("4294967296"), "a refusal never echoes: \(message)")
            }
        }
    }

    func testTheAnswerIsTheContract() throws {
        let answers = [
            SessionGridAnswer(sandbox: "box", session: "main", state: .grid, gen: 9, grid: Self.grid),
            SessionGridAnswer(sandbox: "box", session: "other", state: .unchanged, gen: 3),
            SessionGridAnswer.unavailable(SessionGridRequest(sandbox: "off", session: "main"), .notRunning),
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(WebGrids(answers)), as: UTF8.self)
        XCTAssertEqual(json, ##"{"items":[{"grid":{"bg":"#000000","cols":4,"cursor":{"x":2,"y":0},"fg":"#ffffff","gen":9,"lines":[[[0,"hi","#cd0000",null,1,2]],[]],"rows":2},"sandbox":"box","session":"main","state":"grid"},{"sandbox":"box","session":"other","state":"unchanged"},{"reason":"the sandbox is not running","sandbox":"off","session":"main","state":"unavailable"}]}"##)
        // A hidden cursor is null, never absent.
        var g = Self.grid
        g.cursor = nil
        XCTAssertTrue(String(decoding: try enc.encode(try XCTUnwrap(WebGrid(g))), as: UTF8.self).contains(#""cursor":null"#))
        // A grid the contract does not allow never reaches the page.
        var bad = Self.grid
        bad.lines = [[]]
        let refused = WebGrids([SessionGridAnswer(sandbox: "box", session: "main", state: .grid, gen: 1, grid: bad)])
        XCTAssertEqual(refused.items.first?.state, "unavailable")
        XCTAssertNil(refused.items.first?.grid)
    }

    func testEveryReasonIsPlainWords() {
        for r in SessionGridAnswer.Reason.allCases.map(Optional.some) + [nil] {
            let s = WebGrids.sentence(r)
            XCTAssertLessThanOrEqual(s.count, 120, s)
            XCTAssertFalse(s.contains(where: { $0.isNumber }), "no internal number: \(s)")
            XCTAssertFalse(s.contains("-") && !s.contains(" — "), "not a code word: \(s)")
            XCTAssertNotEqual(s, r?.rawValue, "a sentence, never the code")
        }
    }

    func testWithNoHostEveryItemIsUnavailableAndNoneIsStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-webgrids-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DozableStore(root: root)
        let data = HostWebData(store: store, version: "test", doctor: { [] })
        let items = [SessionGridRequest(sandbox: "box", session: "main"), SessionGridRequest(sandbox: "box", session: "two", gen: 5)]
        let a = await data.grids(items)
        XCTAssertEqual(a.items.map(\.state), ["unavailable", "unavailable"])
        XCTAssertEqual(a.items.map(\.reason), Array(repeating: WebGrids.sentence(.noHost), count: 2))
        XCTAssertEqual(a.items.map(\.session), ["main", "two"])
        XCTAssertFalse(store.hostIsRunning(), "never a host started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socket.path))
    }

    func testTheSavedScreenCarriesItsGrid() throws {
        let saved = SavedScreen(info: SavedScreenInfo(session: "main", savedAt: Date(), reason: "sleep", grid: true), vt: Data(), text: "hi",
                                grid: Self.grid)
        let w = WebSavedScreen(SessionScreen(name: "box", saved))
        XCTAssertEqual(w.grid, WebGrid(Self.grid))
        let none = WebSavedScreen(SessionScreen(name: "box", SavedScreen(info: SavedScreenInfo(session: "main", savedAt: Date(), reason: "sleep"), vt: Data(), text: "")))
        XCTAssertNil(none.grid)
        XCTAssertFalse(String(decoding: try WebJSON.encoder.encode(none), as: UTF8.self).contains("grid"), "absent when there is none")
    }

    // MARK: a real listener

    var server: DozableWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
    }

    func testTheRouteThroughARealListener() async throws {
        server = try await DozableWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", limits: .standard,
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
        let host = ["Host": s.origin.authority]
        let boot = try RawHTTP.request(port: s.origin.port, method: "POST", path: "/api/v1/session",
                                       headers: host.merging(["Origin": s.origin.value, "Authorization": "Bearer \(capability.value)"]) { $1 })
        XCTAssertEqual(boot.status, 200, boot.text)
        let cookie = String(try XCTUnwrap(boot.header("set-cookie")).split(separator: ";")[0])
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: boot.body) as? [String: Any])?["csrf"] as? String)
        func post(_ body: String, csrf token: String?) throws -> RawResponse {
            var h = host.merging(["Cookie": cookie, "Origin": s.origin.value, "Content-Type": "application/json", "Sec-Fetch-Site": "same-origin"]) { $1 }
            if let token { h["X-Doz-CSRF"] = token }
            return try RawHTTP.request(port: s.origin.port, method: "POST", path: "/api/v1/grids", headers: h, body: body)
        }
        let r = try post(#"{"items":[{"sandbox":"box","session":"main","gen":0}]}"#, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        let a = try WebJSON.decoder.decode(WebGrids.self, from: r.body)
        XCTAssertEqual(a.items.first?.state, "unavailable", "the fake has no host: unavailable, nothing started")
        XCTAssertEqual(try post(#"{"items":[]}"#, csrf: nil).status, 403, "CSRF-checked")
        XCTAssertEqual(try post(#"{"items":[{"sandbox":"box"}]}"#, csrf: csrf).status, 400, "strict")
    }
}
