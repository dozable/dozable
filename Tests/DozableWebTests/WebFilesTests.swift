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
