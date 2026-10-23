import Darwin
import Foundation
import DozableKit
import DozableHost
import XCTest
@testable import DozableWeb

/// 643 — the file watcher's typed routes: the closed query (404 otherwise), the projections (field by field, no
/// secret-shaped field), the exposure table, and a real listener — the list through the session's rules, a watch stream
/// that delivers what the watch says, refuses an isolated sandbox, and ends with the session.
final class WebFilesTests: XCTestCase {
    // MARK: routes

    func testTheRoutesAndTheirStrictQuery() {
        let base = "/api/v1/sandboxes/demo/files"
        XCTAssertEqual(WebRoute.parse(method: .get, target: base), .files("demo", nil))
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "?path=src"), .files("demo", "src"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "?path=%2Fworkspace%2Fmy%20dir"), .files("demo", "/workspace/my dir"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "?path=/workspace/a"), .files("demo", "/workspace/a"), "a raw / is fine")
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "?path=caf%C3%A9"), .files("demo", "café"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "?path="), .files("demo", ""))
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "/watch"), .filesWatch("demo", []))
        XCTAssertEqual(WebRoute.parse(method: .get, target: base + "/watch?path=src&path=%2Fworkspace"), .filesWatch("demo", ["src", "/workspace"]))
        for bad in [base + "?path=a&path=b",                // the list route takes one folder
                    base + "?dir=src", base + "?path", base + "?path=a&x=1",
                    base + "?path=%2", base + "?path=%zz", base + "?path=a+b", base + "?path=%0Aetc", base + "?path=%1B",
                    base + "?path=%C2%9B", base + "?path=%FF", base + "?path=a b",
                    base + "?path=" + String(repeating: "a", count: FileListPaths.maximumPathBytes + 1),
                    "/api/v1/sandboxes/DEMO/files", "/api/v1/sandboxes/demo/files/", "/api/v1/sandboxes/demo/files/x",
                    "/api/v1/sandboxes/demo/files/watch/x", base + "/watch?evil=1"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: bad), bad)
        }
        let many = (0...WebFilesQuery.maximumPaths).map { "path=d\($0)" }.joined(separator: "&")
        XCTAssertNil(WebRoute.parse(method: .get, target: base + "/watch?" + many), "at most 64 folders")
        XCTAssertNotNil(WebRoute.parse(method: .get, target: base + "/watch?" + many.split(separator: "&").dropLast().joined(separator: "&")))
        XCTAssertNil(WebRoute.parse(method: .post, target: base), "GET only — nothing here changes a file")
        XCTAssertNil(WebRoute.parse(method: .post, target: base + "/watch"))
        XCTAssertEqual(WebExposure.kind(.files("s", nil)), .read)
        XCTAssertEqual(WebExposure.kind(.filesWatch("s", [])), .read)
    }

    // MARK: projections

    func testTheProjectionsAreFieldByFieldWithNoSecretShapedField() throws {
        let l = FileList(sandbox: "s", path: "/workspace", source: "mac", watch: "mac", rules: true, state: "read-only",
                         entries: [FileEntry(name: "a", kind: "link", size: nil, modified: Date(timeIntervalSince1970: 0), target: "b", state: "read-only", altered: true)],
                         truncated: true, unlisted: 2)
        let w = WebFileList(l)
        XCTAssertEqual(w.entries.first?.target, "b")
        XCTAssertEqual(w.unlisted, 2)
        let values: [any Encodable] = [w, WebFileBatch(FileChangeBatch(sandbox: "s", folders: ["/workspace"], resync: false)),
                                       WebFilesReady(sandbox: "s", folders: ["/workspace"])]
        let forbidden = ["secret", "token", "password", "apikey", "api_key", "bearer", "authorization", "cookie", "csrf", "credentialvalue", "content", "data"]
        for v in values {
            let obj = try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(v))
            for key in keys(obj) { XCTAssertFalse(forbidden.contains { key.lowercased().contains($0) }, "\(key) in \(type(of: v))") }
        }
        // Every field of the host's types is there on purpose (a new host field must be added to the projection by hand).
        let hostKeys = Set(try (JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any] ?? [:]).keys)
        let webKeys = Set(try (JSONSerialization.jsonObject(with: WebJSON.encoder.encode(w)) as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(hostKeys, webKeys)
    }

    private func keys(_ obj: Any) -> [String] {
        if let d = obj as? [String: Any] { return d.keys + d.values.flatMap(keys) }
        if let a = obj as? [Any] { return a.flatMap(keys) }
        return []
    }

    // MARK: a real listener

    var server: DozableWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()

    func start() async throws {
        server = try await DozableWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", limits: .standard,
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
    }

    func get(_ path: String, _ headers: [String: String] = [:], method: String = "GET") throws -> RawResponse {
        var h = ["Host": server.origin.authority]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: server.origin.port, method: method, path: path, headers: h)
    }

    func signIn() throws -> (String, String) {
        let r = try get("/api/v1/session", ["Origin": server.origin.value, "Authorization": "Bearer \(capability.value)"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let set = try XCTUnwrap(r.header("set-cookie"))
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["csrf"] as? String)
        return (String(set.split(separator: ";")[0]), csrf)
    }

    func testTheListRouteIsBehindTheSessionAndAProjection() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/files").status, 401, "no session: nothing")
        let (cookie, _) = try signIn()
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/files", ["Cookie": cookie, "Sec-Fetch-Site": "cross-site"]).status, 403)
        let r = try get("/api/v1/sandboxes/demo/files?path=src", ["Cookie": cookie])
        XCTAssertEqual(r.status, 200, r.text)
        let l = try WebJSON.decoder.decode(WebFileList.self, from: r.body)
        XCTAssertEqual(l.path, "/workspace/src")
        XCTAssertEqual(l.entries.map(\.kind), ["folder", "file", "file"])
        XCTAssertEqual(l.entries[2].state, "locked")
        XCTAssertFalse(r.text.contains("\u{1B}"), "no control character reaches the page")
        XCTAssertEqual(fake.filePaths, ["src"])
        XCTAssertEqual(try get("/api/v1/sandboxes/nope/files", ["Cookie": cookie]).status, 404)
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/files?path=a&path=b", ["Cookie": cookie]).status, 404, "not a route")
    }

    // MARK: 644 — the panel's open folders and the open

    func testThePanelRoutesAndTheirStrictBodies() throws {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/files/tree"), .filesTree("demo"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/files/tree"), .filesTreeSet("demo"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/files/open"), .filesOpen("demo"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/files/open"), "opening is never a GET")
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/files/write"), "no generic file write")
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/files/read"), "no file read")
        XCTAssertEqual(WebExposure.kind(.filesTree("s")), .read)
        XCTAssertEqual(WebExposure.kind(.filesTreeSet("s")), .change)
        XCTAssertEqual(WebExposure.kind(.filesOpen("s")), .macScreen, "it opens a window on the Mac's screen")
        XCTAssertEqual(WebExposure.decide(.filesOpen("s"), .remote(secure: true)), .macScreen)
        // the open folders, strictly
        XCTAssertEqual(try WebFileTree.decode(Data(#"{"expanded":["src","src/lib"]}"#.utf8)).expanded, ["src", "src/lib"])
        XCTAssertEqual(try WebFileTree.decode(Data(#"{"expanded":[]}"#.utf8)).expanded, [])
        let tooMany = "[" + (0...FileTreeState.maximumExpanded).map { "\"d\($0)\"" }.joined(separator: ",") + "]"
        for bad in [#"[]"#, #"{}"#, #"{"expanded":"src"}"#, #"{"expanded":[1]}"#, #"{"expanded":["src"],"x":1}"#, #"{"expanded":["../etc"]}"#,
                    #"{"expanded":["/workspace/src"]}"#, #"{"expanded":["src","src"]}"#, #"{"expanded":[""]}"#, #"{"expanded":\#(tooMany)}"#] {
            XCTAssertThrowsError(try WebFileTree.decode(Data(bad.utf8)), bad)
        }
        // the open, strictly
        XCTAssertEqual(try WebFileOpen.decode(Data(#"{"path":"docs/a.md"}"#.utf8)), WebFileOpen(path: "/workspace/docs/a.md", reveal: false))
        XCTAssertEqual(try WebFileOpen.decode(Data(#"{"path":"/workspace","reveal":true}"#.utf8)).reveal, true)
        for bad in [#"{}"#, #"{"path":"/etc/passwd"}"#, #"{"path":"../x"}"#, #"{"path":"a","reveal":"yes"}"#, #"{"path":"a","x":1}"#] {
            XCTAssertThrowsError(try WebFileOpen.decode(Data(bad.utf8)), bad)
        }
        // 646: an editor — only an app NAME here (the host decides which are accepted); never with reveal
        XCTAssertEqual(try WebFileOpen.decode(Data(#"{"path":"/workspace","app":"cursor"}"#.utf8)),
                       WebFileOpen(path: "/workspace", reveal: false, app: "cursor"))
        XCTAssertNil(try WebFileOpen.decode(Data(#"{"path":"a","app":null}"#.utf8)).app)
        for bad in [#"{"path":"a","app":1}"#, #"{"path":"a","app":"-a"}"#, #"{"path":"a","app":"/Applications/Evil.app"}"#,
                    #"{"path":"a","app":""}"#, #"{"path":"a","app":"cursor","reveal":true}"#] {
            XCTAssertThrowsError(try WebFileOpen.decode(Data(bad.utf8)), bad)
        }
        // 646: the editor list — a GET, mac-screen like the open it serves
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/editors"), .editors)
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/editors"))
        XCTAssertEqual(WebExposure.kind(.editors), .macScreen)
        XCTAssertNil(WebExposure.decide(.editors, .mac))
        XCTAssertEqual(WebExposure.decide(.editors, .remote(secure: true)), .macScreen, "a LAN device's browser never gets it")
        // the projection has no secret-shaped field
        let obj = try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(WebFileTree(FileTreeState(expanded: ["a"], updatedAt: Date()))))
        XCTAssertEqual(Set((obj as? [String: Any] ?? [:]).keys), ["expanded", "updatedAt"])
    }

    func testThePanelRoutesThroughARealListener() async throws {
        try await start()
        let (cookie, csrf) = try signIn()
        let post = { (path: String, body: String) throws -> RawResponse in
            var h = ["Host": self.server.origin.authority, "Cookie": cookie, "Origin": self.server.origin.value, "X-Doz-CSRF": csrf,
                     "Content-Type": "application/json"]
            h["Sec-Fetch-Site"] = "same-origin"
            return try RawHTTP.request(port: self.server.origin.port, method: "POST", path: path, headers: h, body: body)
        }
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/files/tree", ["Cookie": cookie]).text.contains(#""expanded":[]"#), true)
        var r = try post("/api/v1/sandboxes/demo/files/tree", #"{"expanded":["src"]}"#)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertTrue(try get("/api/v1/sandboxes/demo/files/tree", ["Cookie": cookie]).text.contains(#""expanded":["src"]"#))
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/files/tree", #"{"expanded":["../x"]}"#).status, 400)
        // CSRF: without the token, nothing
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/files/tree", ["Cookie": cookie, "Origin": server.origin.value, "Content-Type": "application/json"],
                               method: "POST").status, 403)
        r = try post("/api/v1/sandboxes/demo/files/open", #"{"path":"docs/a.md","reveal":true}"#)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertTrue(r.text.contains("showed /workspace/docs/a.md"))
        XCTAssertEqual(fake.opened, [WebFileOpen(path: "/workspace/docs/a.md", reveal: true)])
        // 646: the editors, and the workspace opened in one
        let ed = try get("/api/v1/editors", ["Cookie": cookie])
        XCTAssertEqual(ed.status, 200, ed.text)
        XCTAssertEqual(try WebJSON.decoder.decode([WebEditor].self, from: ed.body).map(\.id), ["cursor", "Typora"])
        r = try post("/api/v1/sandboxes/demo/files/open", #"{"path":"/workspace","app":"cursor"}"#)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertTrue(r.text.contains("opened /workspace in cursor"), r.text)
        XCTAssertEqual(fake.opened.last, WebFileOpen(path: "/workspace", reveal: false, app: "cursor"))
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/files/open", #"{"path":"/workspace","app":"-a x"}"#).status, 400)
    }

    func testTheWatchStreamDeliversBatchesAndEndsWithTheSession() async throws {
        try await start()
        let (cookie, csrf) = try signIn()
        let iso = try get("/api/v1/sandboxes/iso/files/watch", ["Cookie": cookie])
        XCTAssertEqual(iso.status, 400, "an isolated sandbox is refused with why, never an empty stream")
        XCTAssertTrue(iso.text.contains("list them again to refresh"))
        let s = try RawStream(port: server.origin.port, path: "/api/v1/sandboxes/demo/files/watch?path=src&path=%2Fworkspace",
                              headers: ["Host": server.origin.authority, "Cookie": cookie])
        defer { s.close() }
        let head = try s.read(until: "event: files-ready", seconds: 5)
        XCTAssertTrue(head.contains("text/event-stream"))
        XCTAssertTrue(head.contains(#""folders":["/workspace/src","/workspace"]"#), head)
        XCTAssertEqual(fake.fileWatchers, 1)
        fake.fileChange(FileChangeBatch(sandbox: "demo", folders: ["/workspace/src"], resync: false, time: Date(timeIntervalSince1970: 0)))
        let one = try s.read(until: "event: files\n", seconds: 5)
        XCTAssertTrue(one.contains(#"{"folders":["/workspace/src"],"resync":false,"sandbox":"demo","time":"1970-01-01T00:00:00Z"}"#), one)
        fake.fileChange(FileChangeBatch(sandbox: "demo", folders: [], resync: true))
        XCTAssertTrue(try s.read(until: #""resync":true"#, seconds: 5).contains(#""resync":true"#))
        // the page's live-update stream is a different hub: a watch never takes its place
        XCTAssertEqual(server.hub.count, 0)
        XCTAssertEqual(server.filesHub.count, 1)
        // signing out ends it, and the watch is stopped
        XCTAssertEqual(try get("/api/v1/session", ["Cookie": cookie, "Origin": server.origin.value, "X-Doz-CSRF": csrf], method: "DELETE").status, 204)
        XCTAssertTrue(try s.read(until: "session-ended", seconds: 5).contains("session-ended"))
        XCTAssertTrue(s.waitForClose(seconds: 5))
        for _ in 0..<50 where fake.fileWatchesCancelled == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(fake.fileWatchesCancelled, 1, "the watch stops with its stream")
    }
}
