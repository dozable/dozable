import Foundation
import XCTest
@testable import DozableHost

/// Your Macs' addresses and records (`MacBookmarks`): every accepted address with its exact origin, every refusal — which
/// never contains what was typed — names, the record's keys (none can hold a secret), and the `macs-ls` operation.
final class MacBookmarkTests: XCTestCase {
    func testAcceptedAddressesAndTheirOrigins() throws {
        let cases: [(String, String)] = [
            ("mini.example.ts.net", "https://mini.example.ts.net"),
            ("mini.example.ts.net:7443", "https://mini.example.ts.net:7443"),
            ("Mini.Example.TS.net:7443", "https://mini.example.ts.net:7443"),
            ("mini.local", "http://mini.local:7443"),
            ("mini.local:7443", "http://mini.local:7443"),
            ("mini.local:443", "https://mini.local"),
            ("studio", "http://studio:7443"),
            ("192.168.1.20", "http://192.168.1.20:7443"),
            ("192.168.1.20:8443", "http://192.168.1.20:8443"),
            ("http://192.168.1.20:7443", "http://192.168.1.20:7443"),
            ("http://192.168.1.20:7443/", "http://192.168.1.20:7443"),
            ("http://mini.local", "http://mini.local"),
            ("https://mini.example.ts.net/", "https://mini.example.ts.net"),
            ("HTTPS://mini.example.ts.net:443", "https://mini.example.ts.net"),
            ("https://mini.local:8443", "https://mini.local:8443"),
            ("[fd7a:115c::1]:7443", "http://[fd7a:115c::1]:7443"),
            ("http://[FD7A:115C::1]", "http://[fd7a:115c::1]"),
            ("100.101.102.103:7443", "http://100.101.102.103:7443"),
            ("127.0.0.1:17606", "http://127.0.0.1:17606"),          // an ssh tunnel to another Mac
            ("localhost:9000", "http://localhost:9000"),
        ]
        for (input, want) in cases {
            XCTAssertEqual(try MacAddress.origin(input, thisMacPorts: [7443, 51000]).origin, want, input)
        }
        let o = try MacAddress.origin("[fd7a:115c::1]:7443")
        XCTAssertEqual(o.host, "[fd7a:115c::1]")
        XCTAssertEqual(o.displayHost, "fd7a:115c::1")
        XCTAssertEqual(o.link, "http://[fd7a:115c::1]:7443/")
        XCTAssertEqual(MacAddress.stored("https://mini.example.ts.net:7443"), MacOrigin(scheme: "https", host: "mini.example.ts.net", port: 7443))
        XCTAssertNil(MacAddress.stored("https://mini.example.ts.net:443"), "a stored origin must be exactly the canonical form")
    }

    func testRefusedAddressesNeverEchoTheInput() {
        let secret = "zq81secretxyz"
        let refused: [String] = [
            "http://mini.local:7443/#cap=\(secret)",
            "mini.local:7443/#cap=\(secret)",
            "http://mini.local:7443/?code=\(secret)",
            "https://mini.example.ts.net/?cap=\(secret)",
            "mini.example.ts.net:7443?x=\(secret)",
            "http://mini.local:7443/#\(secret)",
            "http://mini.local:7443/\(secret)",
            "http://mini.local:7443/api/\(secret)",
            "mini.local/\(secret)",
            "mini.local/",
            "http://user:\(secret)@mini.local:7443",
            "\(secret)@mini.local",
            "ftp://mini.local\(secret)",
            "javascript:\(secret)",
            "mini.local:0\(secret)",
            "mini.local:70000",
            "mini.local:",
            "-\(secret).local",
            "\(secret)-.local",
            "\(secret)..local",
            "\(secret)_x.local",
            "mïni\(secret).local",
            "mini \(secret).local",
            "fd7a::\(secret)",
            "[fd7a::zz\(secret)]",
            "999.1.1.1",
            "1.2.3",
            String(repeating: "a", count: 300) + secret,
            "http://" + String(repeating: "a.", count: 260) + secret,
            "",
        ]
        for input in refused {
            XCTAssertThrowsError(try MacAddress.origin(input), input) { e in
                let m = (e as? HostError)?.message ?? "\(e)"
                XCTAssertFalse(m.contains(secret), "the refusal repeats the input: \(m)")
                XCTAssertEqual((e as? HostError)?.code, .invalid, input)
            }
        }
        for input in ["http://mini.local:7443/#cap=\(secret)", "https://x.ts.net/?code=\(secret)", "x?CAP=\(secret)"] {
            XCTAssertThrowsError(try MacAddress.origin(input)) { e in
                XCTAssertEqual((e as? HostError)?.message, MacAddress.signInLinkRefusal)
            }
        }
    }

    func testThisMacsOwnDashboardIsRefused() {
        for input in ["127.0.0.1:51000", "localhost:51000", "http://[::1]:51000", "http://127.0.0.1:51000/"] {
            XCTAssertThrowsError(try MacAddress.origin(input, thisMacPorts: [51000])) { e in
                XCTAssertTrue(((e as? HostError)?.message ?? "").contains("that is this Mac"), input)
            }
        }
        XCTAssertNoThrow(try MacAddress.origin("127.0.0.1:51001", thisMacPorts: [51000]), "another loopback port: an ssh tunnel")
        XCTAssertNoThrow(try MacAddress.origin("mini.local:51000", thisMacPorts: [51000]))
    }

    func testNames() {
        for ok in ["mini", "m1", "0", "studio-2", String(repeating: "a", count: 32)] { XCTAssertTrue(MacBookmarkName.isValid(ok), ok) }
        for no in ["", "-mini", "Mini", "mini_2", "mini.local", "mïni", String(repeating: "a", count: 33)] {
            XCTAssertFalse(MacBookmarkName.isValid(no), no)
        }
        XCTAssertThrowsError(try MacBookmarkName.validate("Bad Name zz9")) { e in
            XCTAssertFalse(((e as? HostError)?.message ?? "").contains("zz9"))
        }
    }

    /// The record's keys are pinned: names, origins, dates, a fixed outcome and a cleaned name — never a token, cookie,
    /// code or link.
    func testTheRecordsKeysArePinned() throws {
        var b = MacBookmark(name: "mini", origin: "http://mini.local:7443", addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        b.record(MacReachability.Result(.reachable, reportedName: "m1mini"), at: Date(timeIntervalSince1970: 1_800_000_100))
        let d = try HostWire.encoder.encode(MacsFile(macs: [b]))
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(Set(top.keys), ["version", "macs"])
        let mac = try XCTUnwrap((top["macs"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(mac.keys), ["name", "origin", "addedAt", "lastCheckAt", "lastSeenAt", "lastResult", "reportedName"])
        XCTAssertEqual(MacBookmark.known, ["name", "origin", "addedAt", "lastCheckAt", "lastSeenAt", "lastResult", "reportedName"])
        for k in MacBookmark.known {
            for bad in ["token", "cookie", "secret", "password", "key", "cap", "code", "link", "url", "auth"] {
                XCTAssertFalse(k.lowercased().contains(bad), "\(k) looks like it could hold a secret")
            }
        }
        let row = try XCTUnwrap(MacRow(b))
        let rowKeys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: HostWire.encoder.encode(row)) as? [String: Any]).keys)
        XCTAssertEqual(rowKeys, ["name", "origin", "scheme", "host", "port", "addedAt", "lastCheckAt", "lastSeenAt", "lastResult", "reportedName"])
    }

    /// A failed check keeps when it was last seen and the name it gave; a reached one updates both.
    func testRecordingAResultKeepsLastSeen() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(60), t2 = t0.addingTimeInterval(120)
        var b = MacBookmark(name: "mini", origin: "http://mini.local:7443", addedAt: t0)
        b.record(MacReachability.Result(.reachable, reportedName: "mini"), at: t1)
        b.record(MacReachability.Result(.refused), at: t2)
        XCTAssertEqual(b.lastCheckAt, t2)
        XCTAssertEqual(b.lastSeenAt, t1)
        XCTAssertEqual(b.lastResult, "refused")
        XCTAssertEqual(b.reportedName, "mini")
    }

    /// A hand-edited file never reaches a reader with something this build would not have written.
    func testARowIsOnlyWhatThisBuildWouldWrite() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(MacRow(MacBookmark(name: "mini", origin: "http://mini.local:7443/#cap=x", addedAt: t)))
        XCTAssertNil(MacRow(MacBookmark(name: "Mini!", origin: "http://mini.local:7443", addedAt: t)))
        var b = MacBookmark(name: "mini", origin: "http://mini.local:7443", addedAt: t)
        b.lastResult = "<script>"
        b.reportedName = "a b<c>"
        let r = MacRow(b)
        XCTAssertNil(r?.lastResult)
        XCTAssertNil(r?.reportedName)
    }

    /// `macs-ls` is read-only: answered in-process from the store, no daemon.
    func testTheReadOperation() async throws {
        XCTAssertTrue(HostOp.macsList.isReadOnly)
        XCTAssertEqual(HostOp.macsList.rawValue, "macs-ls")
        let root = URL(fileURLWithPath: "/tmp/doz-macs-op-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DozableStore(root: root)
        try MacBookmarkStore(store: store).update { $0.macs.append(MacBookmark(name: "mini", origin: "http://mini.local:7443", addedAt: Date())) }
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        let m = await core.handle(HostRequest(.macsList))
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        let l = try XCTUnwrap(m.result).decode(MacListing.self)
        XCTAssertEqual(l.macs.map(\.name), ["mini"])
        XCTAssertEqual(l.macs.first?.host, "mini.local")
        XCTAssertEqual(l.macs.first?.scheme, "http")
        XCTAssertEqual(l.macs.first?.port, 7443)
    }
}

/// The list's file: atomic, 0600 in the 0700 store, unknown fields and a newer version kept, concurrent adds under the lock.
final class MacBookmarkStoreTests: XCTestCase {
    private var root: URL!
    private var store: MacBookmarkStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-macs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)
        store = MacBookmarkStore(store: DozableStore(root: root))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }

    func testNoFileIsAnEmptyListAndNothingIsWrittenByLooking() throws {
        XCTAssertEqual(try store.read(), MacsFile())
        XCTAssertEqual(try store.listing().macs, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file))
        try store.update { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file), "an update that changes nothing writes nothing")
    }

    func testWrittenAtomicallyAs0600() throws {
        try store.update { $0.macs.append(MacBookmark(name: "mini", origin: "http://mini.local:7443", addedAt: Date())) }
        XCTAssertEqual(mode(store.file), 0o600)
        XCTAssertEqual(mode(root.path), 0o700)
        XCTAssertEqual(try store.read().macs.map(\.name), ["mini"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".macs.json") }
        XCTAssertEqual(leftovers, [], "no temporary file left behind")
    }

    func testUnknownFieldsAndANewerVersionAreKept() throws {
        let text = """
        {"version": 3, "future": {"a": 1}, "macs": [{"name": "mini", "origin": "http://mini.local:7443", "addedAt": "2026-11-19T01:02:03.000Z", "color": "blue"}]}
        """
        try Data(text.utf8).write(to: URL(fileURLWithPath: store.file))
        try store.update { $0.macs.append(MacBookmark(name: "air", origin: "http://air.local:7443", addedAt: Date())) }
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.file))) as? [String: Any])
        XCTAssertEqual(back["version"] as? Int, 3)
        XCTAssertNotNil(back["future"])
        let macs = try XCTUnwrap(back["macs"] as? [[String: Any]])
        XCTAssertEqual(macs.first?["color"] as? String, "blue")
        XCTAssertEqual(macs.map { $0["name"] as? String }, ["mini", "air"])
    }

    func testALinkInPlaceOfTheFileIsRefused() throws {
        try Data("{}".utf8).write(to: root.appendingPathComponent("elsewhere.json"))
        symlink(root.appendingPathComponent("elsewhere.json").path, store.file)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.update { $0.macs.append(MacBookmark(name: "mini", origin: "http://mini.local:7443", addedAt: Date())) })
    }

    /// Two writers at once (as two `doz ui macs add`): each read-modify-write is whole under the lock — nothing is lost.
    func testConcurrentAddsUnderTheLock() throws {
        let s = store!
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            try? s.update { f in
                usleep(2000)
                f.macs.append(MacBookmark(name: "m\(i)", origin: "http://m\(i).local:7443", addedAt: Date()))
            }
        }
        XCTAssertEqual(Set(try store.read().macs.map(\.name)), Set((0..<16).map { "m\($0)" }))
    }
}
