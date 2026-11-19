import Foundation
import XCTest
import DozableHost
@testable import DozableWeb

/// Your Macs in the dashboard: the one read route is exactly the read-only HostOp `doz ui macs ls` sends; the answer is a
/// projection with no secret-shaped field; and the page's picker opens a plain link to an origin — never anything more.
/// (The HTTP side: `WebHTTPIntegrationTests.testYourMacs`; who sees it: `ServeExposureTests`.)
final class WebMacsTests: XCTestCase {
    func testTheReadIsExactlyOneReadOnlyHostOp() throws {
        let r = try XCTUnwrap(WebMacReads.request(for: .macs))
        XCTAssertEqual(r, HostRequest(.macsList), "exactly what doz ui macs ls sends")
        XCTAssertTrue(r.op.isReadOnly, "answered in-process with no daemon — looking never starts one")
        XCTAssertNil(r.name)
        XCTAssertNil(r.secret)
        XCTAssertNil(WebMacReads.request(for: .bots))
    }

    func testTheRouteParses() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/macs"), .macs)
        for m: WebHTTPMethod in [.post, .delete] { XCTAssertNil(WebRoute.parse(method: m, target: "/api/v1/macs"), "a read only") }
        for bad in ["/api/v1/macs/", "/api/v1/macs/mini", "/api/v1/macs/mini/check"] { XCTAssertNil(WebRoute.parse(method: .get, target: bad), bad) }
    }

    func testTheAnswerIsAProjectionWithNoSecretShapedField() throws {
        var b = MacBookmark(name: "mini", origin: "https://mini.example.ts.net:7443", addedAt: Date(timeIntervalSince1970: 0))
        b.record(MacReachability.Result(.reachable, reportedName: "m1mini"), at: Date(timeIntervalSince1970: 60))
        b.unknown = UnknownFields(["future": .string("a value only a newer doz knows")])
        let l = WebMacList(MacListing(MacsFile(macs: [b])), thisMac: "studio")
        XCTAssertEqual(l.thisMac.name, "studio")
        XCTAssertEqual(l.macs.map(\.origin), ["https://mini.example.ts.net:7443"])
        XCTAssertEqual(l.macs.first?.host, "mini.example.ts.net")
        XCTAssertEqual(l.macs.first?.scheme, "https")
        let data = try WebJSON.encoder.encode(l)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for word in ["token", "secret", "password", "cookie", "cap=", "code=", "key\"", "hash", "future"] {
            XCTAssertFalse(text.contains(word), "\(word) in \(text)")
        }
        let mac = try XCTUnwrap(((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["macs"] as? [[String: Any]]).first
        XCTAssertEqual(Set(mac?.keys ?? [:].keys), ["name", "origin", "host", "scheme", "lastSeenAt", "lastCheckAt", "lastResult", "reportedName"])
    }

    /// The page: a Mac is an <a> to its origin and `/` in a new tab, never with this page as opener or referrer; the
    /// picker module reads only /api/v1/macs and calls no other Mac.
    func testThePickerIsAPlainLink() throws {
        let src = WebModulesTests.root.appendingPathComponent("Sources/DozableWeb/WebSource/app")
        let picker = try String(contentsOf: src.appendingPathComponent("components/mac-picker.js"), encoding: .utf8)
        let menus = try String(contentsOf: src.appendingPathComponent("components/menus.js"), encoding: .utf8)
        XCTAssertTrue(picker.contains("href: m.origin + '/', target: '_blank'"), "the link is the origin and / — nothing added")
        XCTAssertTrue(menus.contains("attrs.rel = it.rel || 'noopener noreferrer'; attrs.referrerpolicy = 'no-referrer';"))
        XCTAssertTrue(picker.contains("api('macs')"))
        for never in ["fetch(", "window.open", "location.href =", "cap=", "csrf", "document.cookie", "sessionStorage", "localStorage"] {
            XCTAssertFalse(picker.contains(never), "mac-picker.js: \(never)")
        }
        XCTAssertFalse(picker.contains("+ '?") || picker.contains("+ '#"), "nothing is appended to a Mac's address")
    }
}
