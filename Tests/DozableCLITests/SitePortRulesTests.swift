import XCTest
@testable import DozableKit
@testable import DozableHost

/// 690 — `site:HOST:PORT`: the one parser, the edit semantics, the ordering invariant, DNS, display, old policies.
final class SitePortRulesTests: XCTestCase {
    let standardPy = AgentPermissions.preset("agent", base: "python")!
    func custom() -> NetworkPolicy { NetworkPolicy.permissions(standardPy, preset: "agent") }
    func edit(_ p: NetworkPolicy, grant: [String] = [], revoke: [String] = []) throws -> NetworkPolicy {
        try PermissionPolicy.edited(p, grant: grant, revoke: revoke, base: "python")
    }
    func kind(_ p: NetworkPolicy, _ host: String, _ port: UInt16) -> NetworkPolicy.ConnectionVerdict.Kind { p.evaluateConnection(host: host, port: port).kind }

    // MARK: the parser

    func testParserTable() throws {
        func parse(_ s: String) throws -> (String, [UInt16]?) { let r = try PermissionPolicy.site(s); return (r.host, r.ports) }
        var r = try parse("site:api.example.com"); XCTAssertEqual(r.0, "api.example.com"); XCTAssertNil(r.1)
        r = try parse("site:API.example.com:443"); XCTAssertEqual(r.0, "api.example.com"); XCTAssertEqual(r.1, [443])
        r = try parse("site:*.example.com:8080,80,8080"); XCTAssertEqual(r.0, "*.example.com"); XCTAssertEqual(r.1, [80, 8080], "sorted, each once")
        r = try parse("site:100.64.0.5:8780"); XCTAssertEqual(r.0, "100.64.0.5"); XCTAssertEqual(r.1, [8780], "an IPv4 address")
        r = try parse("site:10.1.2.3"); XCTAssertEqual(r.0, "10.1.2.3"); XCTAssertNil(r.1)
        XCTAssertEqual(try parse("site:h.example:65535").1, [65535])
        let sixteen = (1...16).map(String.init).joined(separator: ",")
        XCTAssertEqual(try parse("site:a.example.com:\(sixteen)").1?.count, 16)
        for bad in ["site:a.example.com:", "site:a.example.com:0", "site:a.example.com:65536", "site:a.example.com:80,", "site:a.example.com:,80",
                    "site:a.example.com:http", "site:a.example.com:-1", "site:a.example.com:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17",
                    "site:a.example.com:80:90", "site:[::1]:80", "site:::1", "site:fe80::1", "site:localhost", "site:not a host", "site:",
                    "site:a.example.com:80 90", "site:a.example.com:+80"] {
            XCTAssertThrowsError(try PermissionPolicy.site(bad), bad) { XCTAssertTrue(HostError.from($0).message.contains("site:"), bad) }
        }
        XCTAssertThrowsError(try PermissionPolicy.site("site:[::1]:80")) { XCTAssertTrue(HostError.from($0).message.contains("IPv6")) }
        XCTAssertThrowsError(try PermissionPolicy.site("site:a.example.com:99999")) {
            XCTAssertTrue(HostError.from($0).message.contains("HOST or HOST:PORT — api.example.com, *.example.com:443, 100.64.0.5:8780"), "the exact form is in the message")
        }
    }

    func testWordsKeepAPortListTogether() {
        XCTAssertEqual(PermissionPolicy.splitWords(["site:h.example.com:80,443,web,-error-reports"]), ["site:h.example.com:80,443", "web", "-error-reports"])
        XCTAssertEqual(PermissionPolicy.splitWords(["web", "site:h.example.com:80", "443"]), ["web", "site:h.example.com:80,443"])
        XCTAssertEqual(PermissionPolicy.splitWords(["site:h.example.com,443"]), ["site:h.example.com", "443"], "a host with no port list takes none")
        XCTAssertEqual(PermissionPolicy.splitWords(["standard, site:a.example.com:1, site:b.example.com"]), ["standard", "site:a.example.com:1", "site:b.example.com"])
    }

    // MARK: grant / revoke

    func testGrantAPortOpensOnlyThatPort() throws {
        let e = try edit(custom(), grant: ["site:hub.example.com:8780"])
        XCTAssertEqual(kind(e, "hub.example.com", 8780), .allow)
        XCTAssertEqual(kind(e, "hub.example.com", 8765), .deny)
        XCTAssertEqual(kind(e, "hub.example.com", 443), .deny)
        XCTAssertEqual(e.sites, ["hub.example.com:8780"])
        XCTAssertNil(e.preset)
        let two = try edit(e, grant: ["site:hub.example.com:9000"])
        XCTAssertEqual(two.rules.filter { $0.host == "hub.example.com" }.count, 1, "ports of one host merge into one rule")
        XCTAssertEqual(two.sites, ["hub.example.com:8780,9000"])
        XCTAssertEqual(try edit(two, grant: ["site:hub.example.com:9000"]).rules, two.rules, "granting again changes nothing")
    }

    func testOldWholeHostRuleStillOpensEveryPort() throws {
        let old = NetworkPolicy.permissions(standardPy, preset: nil)
        var p = old; p.rules = [EgressRule(host: "hub.example.com", note: "site you allowed")]
        for port in [UInt16(80), 443, 8765, 8780, 65535] { XCTAssertEqual(kind(p, "hub.example.com", port), .allow) }
        XCTAssertEqual(p.sites, ["hub.example.com"])
        let e = try edit(p, grant: [], revoke: ["site:hub.example.com:8765"])
        XCTAssertEqual(kind(e, "hub.example.com", 8765), .deny)
        XCTAssertEqual(kind(e, "hub.example.com", 8780), .allow)
    }

    func testPortDenyUnderWholeHostAllow() throws {
        var e = try edit(custom(), grant: ["site:hub.example.com"])
        e = try edit(e, revoke: ["site:hub.example.com:8765"])
        XCTAssertEqual(kind(e, "hub.example.com", 8765), .deny)
        XCTAssertEqual(kind(e, "hub.example.com", 8780), .allow)
        XCTAssertEqual(e.rules.first?.label, "deny hub.example.com:8765", "the deny sits first")
        XCTAssertEqual(e.evaluateConnection(host: "hub.example.com", port: 8765).rule, "deny hub.example.com:8765")
        // …and allowing that port again lifts it.
        e = try edit(e, grant: ["site:hub.example.com:8765"])
        XCTAssertEqual(kind(e, "hub.example.com", 8765), .allow)
        XCTAssertFalse(e.rules.contains { $0.action == .deny }, "the port deny is gone")
    }

    func testRevokingAPortOfAPortAllowOnlyRemovesIt() throws {
        var e = try edit(custom(), grant: ["site:hub.example.com:8780,9000"])
        e = try edit(e, revoke: ["site:hub.example.com:9000"])
        XCTAssertEqual(e.sites, ["hub.example.com:8780"])
        XCTAssertEqual(kind(e, "hub.example.com", 9000), .deny)
        XCTAssertFalse(e.rules.contains { $0.action == .deny }, "nothing else lets 9000 through: no deny rule needed")
        e = try edit(e, revoke: ["site:hub.example.com:8780"])
        XCTAssertTrue(e.sites.isEmpty)
        XCTAssertTrue(e.rules.isEmpty)
    }

    func testRevokeAPortAPermissionAllows() throws {
        // github.com:443 is allowed by the Standard permissions: a port deny is what blocks it.
        let e = try edit(custom(), revoke: ["site:github.com:443"])
        XCTAssertEqual(kind(e, "github.com", 443), .deny)
        XCTAssertEqual(e.rules.first?.label, "deny github.com:443")
        // web = every host: the deny is inserted too.
        let web = try edit(custom(), grant: ["web"], revoke: ["site:anything.example.com:25"])
        XCTAssertEqual(kind(web, "anything.example.com", 25), .deny)
        XCTAssertEqual(kind(web, "anything.example.com", 443), .allow)
    }

    func testGrantingAPortLiftsAWholeHostDenyAndSaysSo() throws {
        let denied = try edit(custom(), revoke: ["site:hub.example.com"])
        XCTAssertEqual(kind(denied, "hub.example.com", 8780), .deny)
        let g = try edit(denied, grant: ["site:hub.example.com:8780"])
        XCTAssertEqual(kind(g, "hub.example.com", 8780), .allow)
        XCTAssertEqual(kind(g, "hub.example.com", 8765), .deny, "just that port is open, the rest of the host stays closed? it is no longer denied outright, but nothing allows it")
        XCTAssertFalse(g.rules.contains { $0.action == .deny })
        XCTAssertEqual(PermissionPolicy.lifted(before: denied, after: g, grant: ["site:hub.example.com:8780"]), ["deny hub.example.com"])
        XCTAssertEqual(PermissionPolicy.lifted(before: custom(), after: g, grant: ["site:hub.example.com:8780"]), [])
        XCTAssertEqual(PermissionPolicy.lifted(before: denied, after: try edit(denied, grant: ["site:hub.example.com"]), grant: ["site:hub.example.com"]), [],
                       "a whole-host grant lifting a whole-host deny is not news")
    }

    func testWholeHostGrantFoldsPortAllowsAndKeepsPortDenies() throws {
        var e = try edit(custom(), grant: ["site:hub.example.com:8780"])
        e = try edit(e, grant: ["site:hub.example.com"])
        XCTAssertEqual(e.rules.filter { $0.host == "hub.example.com" }.map(\.label), ["allow hub.example.com"], "the port allow is folded into it")
        XCTAssertEqual(kind(e, "hub.example.com", 1), .allow)
        e = try edit(e, revoke: ["site:hub.example.com:25"])
        e = try edit(e, grant: ["site:hub.example.com"])
        XCTAssertEqual(kind(e, "hub.example.com", 25), .deny, "a whole-host grant leaves a narrower deny alone")
        // whole-host revoke removes every rule of the host, port rules included.
        e = try edit(e, revoke: ["site:hub.example.com"])
        XCTAssertEqual(e.rules.filter { $0.host == "hub.example.com" }.map(\.label), ["deny hub.example.com"])
    }

    func testGrantPartlyOverlappingAPortDeny() throws {
        var e = try edit(custom(), grant: ["web"], revoke: ["site:x.example.com:80,443"])
        e = try edit(e, grant: ["site:x.example.com:443"])
        XCTAssertEqual(kind(e, "x.example.com", 443), .allow)
        XCTAssertEqual(kind(e, "x.example.com", 80), .deny)
    }

    // MARK: the ordering invariant — the truth table

    /// Every pair of {allow h, allow h:p, deny h, deny h:p}, in both orders, after `normalizedSiteRules`: a deny wins.
    func testOrderingTruthTable() {
        let p: UInt16 = 8780, q: UInt16 = 9000
        let host = "hub.example.com"
        let specs: [(String, EgressRule)] = [
            ("allow h", EgressRule(host: host)), ("allow h:p", EgressRule(host: host, ports: [p])),
            ("deny h", EgressRule(.deny, host: host)), ("deny h:p", EgressRule(.deny, host: host, ports: [p])),
        ]
        func verdict(_ rules: [EgressRule], _ port: UInt16) -> NetworkPolicy.Action {
            NetworkPolicy(defaultAction: .deny, rules: rules).evaluate(host: host, port: port).action
        }
        // expected for (a, b) regardless of order: [port p, port q]
        func expected(_ a: String, _ b: String) -> [NetworkPolicy.Action] {
            let set = Set([a, b])
            let denyAll = set.contains("deny h"), denyP = set.contains("deny h:p")
            let allowAll = set.contains("allow h"), allowP = set.contains("allow h:p")
            func at(_ port: UInt16) -> NetworkPolicy.Action {
                if denyAll { return .deny }
                if denyP && port == p { return .deny }
                if allowAll || (allowP && port == p) { return .allow }
                return .deny
            }
            return [at(p), at(q)]
        }
        for (an, a) in specs { for (bn, b) in specs {
            for order in [[a, b], [b, a]] {
                let n = PermissionPolicy.normalizedSiteRules(order)
                XCTAssertEqual([verdict(n, p), verdict(n, q)], expected(an, bn), "\(an) + \(bn) in order \(order.map(\.label))")
                if let firstAllow = n.firstIndex(where: { $0.action == .allow }) {
                    XCTAssertTrue(n[..<firstAllow].allSatisfy { $0.action == .deny }, "denies sit ahead of allows: \(n.map(\.label))")
                }
                XCTAssertEqual(PermissionPolicy.normalizedSiteRules(n), n, "idempotent")
            }
        } }
    }

    func testNormaliserLeavesOtherHostsAndHTTPRulesAlone() {
        let cond = EgressRule(.deny, host: "hub.example.com", methods: ["POST"])
        let rules = [EgressRule(host: "hub.example.com"), EgressRule(host: "other.example.com"), cond, EgressRule(.deny, host: "hub.example.com")]
        let n = PermissionPolicy.normalizedSiteRules(rules)
        XCTAssertEqual(n.map(\.label), ["deny hub.example.com", "allow other.example.com", "deny hub.example.com POST", "allow hub.example.com"])
        XCTAssertEqual(PermissionPolicy.normalizedSiteRules(rules, hosts: ["other.example.com"]), rules, "only the named hosts are touched")
    }

    // MARK: DNS

    func testAllowsNameWithPortRules() {
        var p = NetworkPolicy(rules: [EgressRule(host: "hub.example.com", ports: [8780])])
        XCTAssertTrue(p.allowsName("hub.example.com"), "a name allowed on some port resolves")
        p.rules.insert(EgressRule(.deny, host: "hub.example.com", ports: [8780]), at: 0)
        XCTAssertFalse(p.allowsName("hub.example.com"), "…not when its only rule is a port deny and nothing else allows it")
        p.rules.append(EgressRule(host: "*.example.com"))
        XCTAssertTrue(p.allowsName("hub.example.com"), "…and again when another rule allows it on any port")
        let web = NetworkPolicy(defaultAction: .allow, rules: [EgressRule(.deny, host: "hub.example.com", ports: [8780])])
        XCTAssertTrue(web.allowsName("hub.example.com"), "a port deny does not stop a name an allowing default resolves")
        let whole = NetworkPolicy(defaultAction: .allow, rules: [EgressRule(.deny, host: "hub.example.com")])
        XCTAssertFalse(whole.allowsName("hub.example.com"))
    }

    // MARK: stored policies

    func testOldPoliciesDecodeAndMeanWhatTheyDid() throws {
        let json = """
        {"defaultAction":"deny","rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","action":"allow","host":"hub.example.com","note":"site you allowed"}],"permissions":["model"]}
        """
        let p = try JSONDecoder().decode(NetworkPolicy.self, from: Data(json.utf8))
        XCTAssertNil(p.rules[0].ports)
        XCTAssertEqual(p.evaluate(host: "hub.example.com", port: 8765).action, .allow)
        XCTAssertEqual(p.sites, ["hub.example.com"])
        let q = try edit(p, grant: ["site:hub.example.com:8780"])
        XCTAssertEqual(kind(q, "hub.example.com", 8765), .allow, "a port grant on top of a whole-host allow changes nothing")
        let back = try JSONDecoder().decode(NetworkPolicy.self, from: JSONEncoder().encode(try edit(custom(), grant: ["site:h.example.com:1,2"])))
        XCTAssertEqual(back.rules.first?.ports, [1, 2])
    }

    // MARK: the report

    func testReportShowsPortsAndSuggestsNarrowGrantsForUnusualPorts() throws {
        let e = try edit(custom(), grant: ["site:hub.example.com:8780", "site:api.example.com"])
        func rec(_ host: String, _ port: UInt16) -> ConnectionRecord {
            ConnectionRecord(kind: .connect, host: host, port: port, verdict: .denied, rule: "default deny", open: false)
        }
        let rep = PermissionPolicy.report(name: "t", policy: e, base: "python",
                                          log: [rec("hub.example.com", 8765), rec("db.example.org", 5432), rec("www.example.net", 443), rec("www.example.net", 80)])
        XCTAssertEqual(Set(rep.sites), ["hub.example.com:8780", "api.example.com"])
        let grants = rep.suggestions.map(\.grant)
        XCTAssertTrue(grants.contains("site:hub.example.com:8765"), "an unusual port: that host and port — \(grants)")
        XCTAssertTrue(grants.contains("site:db.example.org:5432"), "\(grants)")
        XCTAssertTrue(grants.contains("site:*.example.net"), "80 and 443 stay a whole-site grant (a domain, as ever) — \(grants)")
        XCTAssertTrue(PermissionPolicy.facts(e, sandbox: "t").contains("hub.example.com:8780"))
    }
}
