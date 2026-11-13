import Foundation
import XCTest
import DozableKit
import DozableHost
@testable import DozableWeb

/// 683 M5 — the dashboard side of fenced sessions on this Mac: the capability rows reach the page as the host computed them
/// (one source), the tile's chips are picked from them (≤ 4, in §2.7's order, then "+N"), nothing secret-shaped is in any
/// new projection, the wizard's plan is decoded strictly and builds a command `/bin/sh -n` accepts, Open in Terminal only
/// for the plainly fenced shapes, the new routes parse exactly, and the two new actions are one HostOp each.
final class WebMacCapabilitiesTests: XCTestCase {
    // MARK: fixtures

    /// A row of `doz sessions @mac` as the host makes it: the capabilities from `MacFence.capabilities`, a fence when fenced.
    static func row(_ name: String, _ shape: MacCapabilityShape, profile: String = "agent", stopped: String? = nil,
                    bridges: (Bool, Bool, Bool) = (true, true, true)) throws -> SessionRow {
        var r = SessionRow(SessionInfo(name: name, pid: 9, command: "claude"))
        r.workdir = shape.workdir
        r.capabilities = MacFence.capabilities(shape)
        guard shape.fenced else { return r }
        r.fenced = true
        var f: [String: Any] = ["profile": profile, "keychain": shape.keychain, "readable": shape.readable, "writable": shape.writable,
                                "sessionFolder": "/s/mac-sessions/fence/\(name)", "templateVersion": 1, "profileSHA256": String(repeating: "a", count: 64),
                                "proxyPort": 51000, "network": "proxy", "preset": "agent", "agentConfig": shape.agentConfig ?? "private",
                                "bridges": ["openURL": bridges.0, "openFiles": bridges.1, "clipboard": bridges.2], "denialsSeen": 3, "denialLog": "on",
                                "lastCopyAt": "2026-11-13T10:00:00Z"]
        if let stopped { f["stoppedForGit"] = stopped }
        if let g = shape.github { f["github"] = g }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        r.fence = try dec.decode(MacFenceRow.self, from: JSONSerialization.data(withJSONObject: f))
        return r
    }

    static func fenced(_ change: (inout MacCapabilityShape) -> Void = { _ in }) -> MacCapabilityShape {
        var s = MacCapabilityShape(session: "s", workdir: "/Users/x/src/app", fenced: true)
        s.claude = true
        s.agent = "Claude Code"
        s.agentConfig = "private"
        s.personHome = "/Users/x/.claude"
        s.history = "keep"
        s.account = "mac"
        s.preset = "agent"
        s.network = "proxy"
        s.bridges = MacFenceBridges()
        change(&s)
        return s
    }

    /// The matrix §4 M5 names: unfenced; fenced default; --xcode; --simulator; --keychain; shared; --github push; --ssh-agent;
    /// locked; ports; --write/--read; bridges off.
    static var matrix: [(String, MacCapabilityShape)] {
        var unfenced = MacCapabilityShape(session: "u", workdir: "/Users/x", fenced: false)
        unfenced.claude = true
        return [
            ("unfenced", unfenced),
            ("fenced", fenced()),
            ("xcode", fenced { $0.profile = "xcode" }),
            ("simulator", fenced { $0.profile = "simulator" }),
            ("keychain", fenced { $0.keychain = true }),
            ("shared", fenced { $0.agentConfig = "shared" }),
            ("push", fenced { $0.github = "push" }),
            ("ssh", fenced { $0.sshAgent = true }),
            ("locked", fenced { $0.preset = "locked" }),
            ("ports", fenced { $0.localPorts = [3000, 8765] }),
            ("folders", fenced { $0.writable = ["/Users/x/src/lib"]; $0.readable = ["/Users/x/notes"] }),
            ("bridges-off", fenced { $0.bridges = MacFenceBridges(openURL: false, openFiles: false, clipboard: false) }),
        ]
    }

    // MARK: one source

    func testThePageGetsTheHostsRowsAsTheyAre() throws {
        for (label, shape) in Self.matrix {
            let host = MacFence.capabilities(shape)
            let web = WebMacSession(try Self.row(label, shape)).capabilities
            XCTAssertEqual(web.count, host.count, label)
            // Byte-identical in content: the page's JSON of each row is the host's JSON of it.
            let a = try WebJSON.encoder.encode(web), b = try WebJSON.encoder.encode(host)
            XCTAssertEqual(String(decoding: a, as: UTF8.self), String(decoding: b, as: UTF8.self), label)
            XCTAssertEqual(web.map(\.id), ["fence", "keychain", "network", "agent-config", "history", "claude-login", "github", "ssh-agent",
                                           "open-url", "open-files", "clipboard", "writable", "readable"], "every session has every row — \(label)")
        }
    }

    /// Each matrix row's own state and its live / restart mark (§2.7's table), fenced and unfenced side by side.
    func testEveryRowSaysItsStateAndWhenItChanges() throws {
        func cap(_ shape: MacCapabilityShape, _ id: String) -> MacCapability { MacFence.capabilities(shape).first { $0.id == id }! }
        let m = Dictionary(uniqueKeysWithValues: Self.matrix)
        XCTAssertEqual(cap(m["unfenced"]!, "fence").state, "no isolation")
        XCTAssertEqual(cap(m["unfenced"]!, "keychain").state, "open")
        XCTAssertEqual(cap(m["unfenced"]!, "network").state, "direct")
        XCTAssertEqual(cap(m["fenced"]!, "fence").state, "fenced")
        XCTAssertEqual(cap(m["fenced"]!, "keychain").state, "closed")
        XCTAssertEqual(cap(m["fenced"]!, "network").state, "through Dozable's proxy (standard)", "the preset by the name a person reads")
        XCTAssertEqual(cap(m["fenced"]!, "network").editable, "live")
        XCTAssertEqual(cap(m["fenced"]!, "network").link, "doz net log @mac --session s")
        XCTAssertEqual(cap(m["xcode"]!, "fence").state, "fenced (Xcode)")
        XCTAssertEqual(cap(m["simulator"]!, "fence").state, "guard rail (Simulator)")
        XCTAssertTrue(cap(m["simulator"]!, "fence").sentence.contains("a guard rail, not a boundary"))
        XCTAssertEqual(cap(m["keychain"]!, "keychain").state, "open")
        XCTAssertEqual(cap(m["shared"]!, "agent-config").state, "shared (less isolated)")
        XCTAssertEqual(cap(m["push"]!, "github").state, "push")
        XCTAssertEqual(cap(m["ssh"]!, "ssh-agent").state, "on (list + sign only)")
        XCTAssertEqual(cap(m["locked"]!, "network").state, "none beyond its model (locked)")
        XCTAssertTrue(cap(m["ports"]!, "network").state.hasSuffix("local ports opened: 3000, 8765"))
        XCTAssertTrue(cap(m["folders"]!, "writable").sentence.contains("~/src/lib") || cap(m["folders"]!, "writable").sentence.contains("/Users/x/src/lib"))
        XCTAssertNotEqual(cap(m["folders"]!, "readable").state, "none")
        for id in ["open-url", "open-files", "clipboard"] {
            XCTAssertEqual(cap(m["bridges-off"]!, id).state, "off", id)
            XCTAssertEqual(cap(m["bridges-off"]!, id).editable, "live", id)
        }
        for id in ["fence", "keychain", "agent-config", "history", "claude-login", "github", "ssh-agent", "writable", "readable"] {
            XCTAssertEqual(cap(m["fenced"]!, id).editable, "restart", "\(id): only at the next start — no control on the page")
        }
        // The record's "waiting for a host" is said only while no host serves it.
        XCTAssertTrue(cap(Self.fenced { $0.network = "waiting (no host)" }, "network").state.hasSuffix("— waiting for a host"))
        XCTAssertFalse(cap(m["fenced"]!, "network").state.contains("waiting"))
    }

    /// `doz run @mac … --dry-run` and the wizard compute from ONE shape builder: the plan's rows are `MacFence.capabilities` of
    /// `MacCapabilityShape.planned` for the request the command sends.
    func testThePlanSaysWhatTheDryRunSays() throws {
        var r = WebMacPlanRequest(kind: .web, program: .claude, workdir: "/Users/x/src/app")
        r.ports = [3000]
        r.github = "read"
        let settings = DozableSettings(text: nil)
        let plan = Self.plan(r, settings: settings)
        var q = MacFenceRequest(permissions: ["standard"], localPorts: [3000])
        q.github = "read"
        let shape = MacCapabilityShape.planned(session: "claude", workdir: r.workdir, argv: ["claude"], fenced: true, request: q, settings: settings, home: "/Users/x")
        XCTAssertEqual(plan.capabilities, MacFence.capabilities(shape).map(WebMacCapability.init))
        XCTAssertEqual(plan.describe, MacFence.capabilitiesText(MacFence.capabilities(shape)))
        XCTAssertEqual(plan.agentConfig, "private")
        XCTAssertEqual(plan.history, "keep")
    }

    // MARK: the tile's chips

    func testTheChipsArePickedInOrderAtMostFourThenPlusN() throws {
        let all = Self.fenced { $0.profile = "simulator"; $0.keychain = true; $0.agentConfig = "shared"; $0.github = "push" }
        let s = WebMacSession(try Self.row("all", all, profile: "simulator"))
        XCTAssertEqual(s.chips.map(\.word), ["Guard rail (Simulator)", "Keychain open", "Shared config", "GitHub: push"])
        XCTAssertEqual(s.chips.map(\.tone), ["warn", "warn", "warn", "info"])
        XCTAssertEqual(s.moreCapabilities, s.capabilities.count - 4)
        let plain = WebMacSession(try Self.row("p", Self.fenced()))
        XCTAssertEqual(plain.chips.map(\.word), ["Fenced"])
        XCTAssertEqual(plain.chips.first?.tone, "ok")
        XCTAssertEqual(plain.moreCapabilities, plain.capabilities.count - 1)
        let x = WebMacSession(try Self.row("x", Self.fenced { $0.profile = "xcode" }, profile: "xcode"))
        XCTAssertEqual(x.chips.first?.word, "Fenced (Xcode)")
        // An unfenced session has the Keychain open too — its one chip, No isolation, says all of that.
        let u = WebMacSession(try Self.row("u", Self.matrix[0].1))
        XCTAssertEqual(u.chips.map(\.word), ["No isolation"])
        XCTAssertFalse(u.fenced)
        XCTAssertNil(u.fence)
        XCTAssertEqual(WebMacChips.pick([], fenced: true).0, [])
    }

    func testTheFenceProjection() throws {
        let s = WebMacSession(try Self.row("st", Self.fenced(), stopped: "core.fsmonitor", bridges: (false, true, true)))
        let f = try XCTUnwrap(s.fence)
        XCTAssertEqual(f.stoppedForGit, "core.fsmonitor")
        XCTAssertEqual(f.preset, "standard")
        XCTAssertEqual(f.bridges, try JSONDecoder().decode(WebMacBridges.self, from: Data(#"{"openURL":false,"openFiles":true,"clipboard":true}"#.utf8)))
        XCTAssertEqual(f.denialsSeen, 3)
        XCTAssertNotNil(f.lastCopyAt)
        let json = String(decoding: try WebJSON.encoder.encode(s), as: UTF8.self)
        for never in ["proxyPort", "51000", "sessionFolder", "profileSHA256", "aaaaaaaa"] { XCTAssertFalse(json.contains(never), never) }
    }

    /// No secret-shaped field anywhere in what M5 added, and the conversations' list carries no path and no content.
    func testNoSecretShapedFieldInTheNewProjections() throws {
        let listing = MacTranscripts.Listing(session: "s", items: [.init(name: "1b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl", endedAt: "20261113T101500Z", bytes: 9,
                                                                         path: "/s/mac-sessions/transcripts/s/20261113T101500Z/1b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl"),
                                                                   .init(name: "../x.jsonl", endedAt: "20261113T101500Z", bytes: 1, path: "/x")],
                                             carriedTo: "/Users/x/.claude/projects/-Users-x-src-app")
        let t = WebMacTranscripts(listing)
        XCTAssertEqual(t.items.map(\.name), ["1b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl"], "only an archived <uuid>.jsonl")
        var r = WebMacPlanRequest(kind: .plain, program: .claude, workdir: "/Users/x/src/app")
        r.account = "work"
        let values: [any Encodable] = [
            WebMacSessions(sessions: [WebMacSession(try Self.row("a", Self.fenced()))], access: "interactive", plan: true),
            t, WebMacQuarantine(SessionQuarantine(session: "s", items: [.init(name: "1.txt", text: "core.pager = x")])),
            WebMacNetwork(session: "s", network: WebNetwork(name: "@mac s", proxied: true, mode: "fenced", policy: nil, log: [], logTotal: 0, denied: 0,
                                                            logAvailable: false, note: nil),
                          denialLog: "on", denials: [WebFenceDenial(FenceDenial(time: Date(), process: "cat(1)", pid: 1, operation: "file-read-data", target: "/x"))],
                          commands: []),
            Self.plan(r),
        ]
        let forbidden = ["secret", "token", "password", "apikey", "api_key", "bearer", "authorization", "cookie", "csrf", "credentialvalue", "placeholder", "path"]
        for v in values {
            let obj = try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(v))
            for key in Self.keys(obj) where key != "carriedTo" {
                XCTAssertFalse(forbidden.contains { key.lowercased().contains($0) }, "secret-shaped field \(key) in \(type(of: v))")
            }
        }
        let planJSON = String(decoding: try WebJSON.encoder.encode(Self.plan(r)), as: UTF8.self)
        XCTAssertFalse(planJSON.contains("terminalCommand") || planJSON.contains("exec "), "the .command file's text stays on the Mac")
    }

    static func keys(_ o: Any) -> [String] {
        if let d = o as? [String: Any] { return d.keys + d.values.flatMap(keys) }
        if let a = o as? [Any] { return a.flatMap(keys) }
        return []
    }

    // MARK: the wizard's plan

    static func plan(_ r: WebMacPlanRequest, settings: DozableSettings = DozableSettings(text: nil),
                     store: String = "/tmp/doz-plan-store", defaultStore: String = "/tmp/doz-plan-store") -> WebMacPlan {
        WebMacPlan.make(r, settings: settings, home: "/Users/x", shell: "/bin/zsh", executable: "/opt/doz it/bin/doz",
                        store: DozableStore(root: URL(fileURLWithPath: store)), defaultStore: DozableStore(root: URL(fileURLWithPath: defaultStore)))
    }
    func decode(_ s: String) throws -> WebMacPlanRequest { try WebMacPlanRequest.decode(Data(s.utf8)) }

    func testThePlanBodyIsStrict() throws {
        let ok = try decode(#"{"case":"web","program":"claude","workdir":"/Users/x/src/app","ports":[3000,3000,8765],"github":"push","agentConfig":"private","session":"web-1"}"#)
        XCTAssertEqual(ok.kind, .web)
        XCTAssertEqual(ok.ports, [3000, 8765])
        XCTAssertEqual(ok.github, "push")
        XCTAssertFalse(ok.open)
        XCTAssertTrue(try decode(#"{"case":"xcode","program":"shell","workdir":"/a/b","simulator":true,"keychain":false,"open":true}"#).simulator)
        XCTAssertEqual(try decode(#"{"case":"plain","program":"claude","workdir":"/private/tmp/work"}"#).workdir, "/private/tmp/work",
                       "a /private folder is taken as given (found by the screenshot probe)")
        let w = #""workdir":"/Users/x/app""#
        for bad in [
            "[]", "{}", #"{"case":"plain","program":"claude"}"#,                                         // workdir required
            #"{"case":"sandbox","program":"claude",\#(w)}"#, #"{"case":"plain","program":"codex",\#(w)}"#,
            #"{"case":"plain","program":"claude","workdir":"relative/dir"}"#, #"{"case":"plain","program":"claude","workdir":"/"}"#,
            #"{"case":"plain","program":"claude","workdir":"/Users/x/../y"}"#, #"{"case":"plain","program":"claude","workdir":"/Users/./y"}"#, #"{"case":"plain","program":"claude","workdir":"/Users//x"}"#,
            #"{"case":"plain","program":"claude","workdir":"/Users/x/"}"#, #"{"case":"plain","program":"claude","workdir":"/a\u0001b"}"#,
            #"{"case":"plain","program":"claude","workdir":"/\#(String(repeating: "a", count: 1030))"}"#,
            #"{"case":"plain","program":"claude",\#(w),"argv":["sh"]}"#,                               // never a program of the page's
            #"{"case":"plain","program":"claude",\#(w),"command":"rm -rf ~"}"#,
            #"{"case":"plain","program":"claude",\#(w),"session":"../x"}"#, #"{"case":"plain","program":"claude",\#(w),"session":"\#(String(repeating: "a", count: 33))"}"#,
            #"{"case":"plain","program":"claude",\#(w),"preset":"custom"}"#, #"{"case":"plain","program":"claude",\#(w),"github":"admin"}"#,
            #"{"case":"plain","program":"claude",\#(w),"agentConfig":"mine"}"#, #"{"case":"plain","program":"claude",\#(w),"account":"Bad Name"}"#,
            #"{"case":"plain","program":"claude",\#(w),"keychain":true}"#,                             // a Swift toggle on another case
            #"{"case":"plain","program":"claude",\#(w),"ports":[3000]}"#, #"{"case":"web","program":"claude",\#(w)}"#,
            #"{"case":"web","program":"claude",\#(w),"ports":[80]}"#, #"{"case":"web","program":"claude",\#(w),"ports":[true]}"#,
            #"{"case":"web","program":"claude",\#(w),"ports":[1,2,3,4,5,6,7,8,9]}"#, #"{"case":"web","program":"claude",\#(w),"ports":"3000"}"#,
            #"{"case":"signing","program":"claude",\#(w),"github":"read"}"#, #"{"case":"unfenced","program":"claude",\#(w),"agentConfig":"private"}"#,
            #"{"case":"plain","program":"shell",\#(w),"account":"work"}"#, #"{"case":"plain","program":"claude",\#(w),"open":"yes"}"#,
            #"{"case":"xcode","program":"claude",\#(w),"simulator":1}"#,
        ] {
            XCTAssertThrowsError(try decode(bad), bad) { XCTAssertTrue($0 is WebAction.Invalid, "\($0)") }
        }
    }

    /// Each case's command: the flags it should carry, accepted by `/bin/sh -n`, and the `.command` file's form too.
    func testThePlansCommandsAndWhichMayOpenInTerminal() throws {
        func plan(_ json: String, store: String = "/tmp/doz-plan-store") throws -> WebMacPlan { Self.plan(try decode(json), store: store) }
        let wd = #""workdir":"/Users/x/My App's folder""#
        let cases: [(String, [String], Bool)] = [
            (#"{"case":"plain","program":"claude",\#(wd)}"#, ["doz run @mac --fenced --workdir", "-- claude"], true),
            (#"{"case":"plain","program":"shell",\#(wd),"github":"read","session":"sh-1"}"#, ["--fenced", "--github read", "--session sh-1"], true),
            (#"{"case":"web","program":"claude",\#(wd),"ports":[3000,5173]}"#, ["--local-port 3000 --local-port 5173"], true),
            (#"{"case":"xcode","program":"claude",\#(wd)}"#, ["--fenced --xcode"], true),
            (#"{"case":"xcode","program":"claude",\#(wd),"simulator":true}"#, ["--fenced --simulator"], false),
            (#"{"case":"xcode","program":"claude",\#(wd),"keychain":true}"#, ["--xcode --keychain"], false),
            (#"{"case":"plain","program":"claude",\#(wd),"agentConfig":"shared"}"#, ["--agent-config shared"], false),
            (#"{"case":"plain","program":"claude",\#(wd),"preset":"locked","account":"work"}"#, ["--permissions locked", "--account work"], true),
            (#"{"case":"signing","program":"claude",\#(wd)}"#, ["doz run @mac --unfenced"], false),
            (#"{"case":"unfenced","program":"shell",\#(wd)}"#, ["doz run @mac --unfenced"], false),
        ]
        for (json, want, openable) in cases {
            let p = try plan(json)
            for w in want { XCTAssertTrue(p.command.contains(w), "\(w) in \(p.command)") }
            XCTAssertEqual(p.openable, openable, json)
            XCTAssertEqual(p.copyOnly == nil, openable, json)
            XCTAssertFalse(p.command.contains("--store"), "the default store: no --store in what is copied")
            XCTAssertTrue(p.terminalCommand.hasPrefix("exec '/opt/doz it/bin/doz' run @mac "), p.terminalCommand)
            XCTAssertTrue(p.terminalCommand.contains("--store /tmp/doz-plan-store"), "the .command file names its store")
            for c in [p.command, p.terminalCommand] { XCTAssertEqual(Self.shSyntax(c), 0, c) }
        }
        XCTAssertTrue(try plan(#"{"case":"plain","program":"claude",\#(wd)}"#, store: "/tmp/other store").command.contains("--store '/tmp/other store'"))
        // A Keychain the settings open makes the plain case copy-only too (it would open it).
        let kc = Self.plan(try decode(#"{"case":"plain","program":"claude",\#(wd)}"#), settings: DozableSettings(text: "[mac]\nkeychain = \"on\"\n"))
        XCTAssertFalse(kc.openable)
        // A shared default (the setting) is copy-only, as an explicit Shared is.
        let sh = Self.plan(try decode(#"{"case":"plain","program":"claude",\#(wd)}"#), settings: DozableSettings(text: "[mac]\nagent_config = \"shared\"\n"))
        XCTAssertEqual(sh.agentConfig, "shared")
        XCTAssertFalse(sh.openable)
    }

    static func shSyntax(_ command: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The real data source: `open: true` writes the one-shot hand-off only for an Open-in-Terminal shape; any other is
    /// refused before anything is written or opened.
    func testOpenInTerminalOnlyForThePlainlyFencedShapes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = Locked<[String]>([])
        let data = HostWebData(store: DozableStore(root: dir), version: "test", executable: "/opt/doz/bin/doz",
                               terminal: { c in opened.mutate { $0.append(c) } }, doctor: { [] })
        var r = WebMacPlanRequest(kind: .xcode, program: .claude, workdir: "/Users/x/src/app")
        r.simulator = true
        r.open = true
        do { _ = try await data.macSessionPlan(r); XCTFail("the Simulator's shape is copy-only") } catch {}
        r = WebMacPlanRequest(kind: .unfenced, program: .claude, workdir: "/Users/x/src/app")
        r.open = true
        do { _ = try await data.macSessionPlan(r); XCTFail("an unfenced one is copy-only") } catch {}
        XCTAssertEqual(opened.value, [], "nothing was opened for them")
        r = WebMacPlanRequest(kind: .plain, program: .claude, workdir: "/Users/x/src/app")
        let look = try await data.macSessionPlan(r)
        XCTAssertNil(look.opened)
        XCTAssertEqual(opened.value, [], "a plan without open writes nothing")
        r.open = true
        let p = try await data.macSessionPlan(r)
        XCTAssertNotNil(p.opened)
        XCTAssertEqual(opened.value.count, 1)
        XCTAssertTrue(opened.value[0].hasPrefix("exec /opt/doz/bin/doz run @mac --fenced "), opened.value[0])
        XCTAssertEqual(Self.shSyntax(TerminalHandoff.commandFile(opened.value[0])), 0)
        XCTAssertFalse(opened.value[0].contains("--unfenced"))
    }

    // MARK: routes, exposure, actions

    func testTheNewRoutesParseExactly() {
        let stamp = "20261113T101500Z", uuid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl"
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/agent/network"), .macSessionNetwork("agent"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/agent/transcripts"), .macSessionTranscripts("agent"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/agent/transcripts/\(stamp)/\(uuid)"), .macSessionTranscript("agent", stamp, uuid))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/agent/quarantine"), .macSessionQuarantine("agent"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/mac/session-plan"), .macSessionPlan)
        for bad in ["/api/v1/mac/sessions/agent/transcripts/\(stamp)/x.jsonl", "/api/v1/mac/sessions/agent/transcripts/2026/\(uuid)",
                    "/api/v1/mac/sessions/agent/transcripts/\(stamp)/../\(uuid)", "/api/v1/mac/sessions/agent/transcripts/\(stamp)/\(uuid).txt",
                    "/api/v1/mac/sessions/agent/files", "/api/v1/mac/sessions/.x/network", "/api/v1/mac/session-plan"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: bad), bad)
        }
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/mac/sessions/agent/network"))
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/mac/sessions/agent/open"), "still no route opens one")
        XCTAssertEqual(WebExposure.kind(.macSessionPlan), .macScreen, "the Mac's own browser only")
        for s in WebExposure.MacSessions.allCases {
            XCTAssertEqual(WebExposure.decide(.macSessionPlan, .remote(secure: true), macSessions: s), .macScreen)
            XCTAssertEqual(WebExposure.decide(.macSessionPlan, .remote(secure: false), macSessions: s), .macScreen)
        }
        XCTAssertEqual(WebExposure.decideMacExport(.remote(secure: true), .watch), .macSession, "watching never exports a conversation")
        XCTAssertNil(WebExposure.decideMacExport(.remote(secure: true), .interactive))
        XCTAssertNil(WebExposure.decideMacExport(.mac, .off))
    }

    func testResumeAndBridgesAreOneHostOpEach() throws {
        let r = try WebAction.decode(Data(#"{"action":"mac-session-resume","session":"agent"}"#.utf8))
        XCTAssertEqual(r, .macSessionResume(session: "agent"))
        XCTAssertEqual(r.hostRequest.op, .sessionResume)
        XCTAssertEqual(r.hostRequest.name, MacPlace.name)
        XCTAssertEqual(r.hostRequest.session, "agent")
        XCTAssertTrue(r.isMacSession)
        XCTAssertNil(r.confirmationTarget)
        XCTAssertNil(r.sandbox)
        let b = try WebAction.decode(Data(#"{"action":"mac-session-bridges","session":"agent","openURL":false,"clipboard":true}"#.utf8))
        XCTAssertEqual(b, .macSessionBridges(session: "agent", openURL: false, openFiles: nil, clipboard: true))
        XCTAssertEqual(b.hostRequest.op, .sessionBridges)
        XCTAssertEqual(b.hostRequest.macBridges?.openURL, false, "off stays off (never read as 'as it is')")
        XCTAssertNil(b.hostRequest.macBridges?.openFiles)
        XCTAssertEqual(b.hostRequest.macBridges?.clipboard, true)
        XCTAssertNil(b.hostRequest.macBridges?.keychain, "a bridge switch widens nothing made at the start")
        XCTAssertNil(b.hostRequest.macFence)
        XCTAssertTrue(b.isMacSession)
        for bad in [#"{"action":"mac-session-bridges","session":"agent"}"#, #"{"action":"mac-session-bridges","session":"agent","openURL":"on"}"#,
                    #"{"action":"mac-session-bridges","session":"agent","keychain":true}"#, #"{"action":"mac-session-bridges","session":"agent","permissions":["open"]}"#,
                    #"{"action":"mac-session-resume"}"#, #"{"action":"mac-session-resume","session":"a","sandbox":"web"}"#,
                    #"{"action":"mac-session-resume","session":"\#(String(repeating: "x", count: 33))"}"#] {
            XCTAssertThrowsError(try WebAction.decode(Data(bad.utf8)), bad)
        }
    }
}

/// A value shared with a `@Sendable` closure in a test.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

// MARK: over HTTP — the same listener the LAN tests drive (the Mac's own browser and a device)

extension ServeHTTPTests {
    func testTheWizardsPlanIsTheMacsOwnBrowsersAlone() async throws {
        let body = #"{"case":"plain","program":"claude","workdir":"/Users/someone/src/app"}"#
        var last = ""
        for setting in ["off", "watch", "interactive"] {
            if server != nil { await server.close(); _ = try? await serveTask.value; server = nil }
            try await start(macSessions: setting)
            let (macCookie, macCSRF) = try macSignIn()
            let (devCookie, devCSRF) = try await admit()
            let mine = try macJSON(macCookie, macCSRF, "/api/v1/mac/session-plan", body, remote: false)
            XCTAssertEqual(mine.status, 200, mine.text)
            XCTAssertTrue(mine.text.contains("doz run @mac --fenced"), mine.text)
            XCTAssertFalse(mine.text.contains("exec "), "the .command text stays on the Mac")
            let theirs = try macJSON(devCookie, devCSRF, "/api/v1/mac/session-plan", body, remote: true)
            XCTAssertEqual(theirs.status, 403, "serve.mac_sessions = \(setting): \(theirs.text)")
            let list = try macReq("/api/v1/mac/sessions", ["Cookie": macCookie])
            XCTAssertTrue(list.text.contains("\"plan\":true"), list.text)
            if setting != "off" { XCTAssertTrue(try req("/api/v1/mac/sessions", ["Cookie": devCookie]).text.contains("\"plan\":false")) }
            last = macCookie
        }
        XCTAssertEqual(try macReq("/api/v1/mac/session-plan", ["Cookie": last, "Origin": mac, "Content-Type": "application/json"],
                                  method: "POST", body: body).status, 403, "CSRF-checked")
    }

    func testOpenInTerminalIsRefusedForTheNearUnfencedShapes() async throws {
        try await start()
        let (c, x) = try macSignIn()
        for bad in [#"{"case":"xcode","program":"claude","workdir":"/a/b","simulator":true,"open":true}"#,
                    #"{"case":"xcode","program":"claude","workdir":"/a/b","keychain":true,"open":true}"#,
                    #"{"case":"plain","program":"claude","workdir":"/a/b","agentConfig":"shared","open":true}"#,
                    #"{"case":"signing","program":"claude","workdir":"/a/b","open":true}"#,
                    #"{"case":"unfenced","program":"shell","workdir":"/a/b","open":true}"#] {
            XCTAssertEqual(try macJSON(c, x, "/api/v1/mac/session-plan", bad, remote: false).status, 400, bad)
        }
        XCTAssertEqual(fake.planTerminal, [], "nothing was opened")
        let ok = try macJSON(c, x, "/api/v1/mac/session-plan", #"{"case":"web","program":"claude","workdir":"/a/b","ports":[3000],"open":true}"#, remote: false)
        XCTAssertEqual(ok.status, 200, ok.text)
        XCTAssertEqual(fake.planTerminal.count, 1)
        XCTAssertEqual(try macJSON(c, x, "/api/v1/mac/session-plan", #"{"case":"plain","program":"claude","workdir":"/a/b","argv":["sh"]}"#, remote: false).status, 400)
    }

    func testTheFencedTabsAndTheExportFollowTheSetting() async throws {
        try await start(macSessions: "watch")
        let (macCookie, macCSRF) = try macSignIn()
        let (devCookie, devCSRF) = try await admit()
        let file = "/api/v1/mac/sessions/build/transcripts/20261113T101500Z/1b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl"
        let mine = try macReq(file, ["Cookie": macCookie])
        XCTAssertEqual(mine.status, 200, mine.text)
        XCTAssertEqual(mine.body, FakeData.transcript)
        XCTAssertTrue(mine.header("content-disposition")?.contains("attachment; filename=\"20261113T101500Z-1b4e28ba-2fa1-11d2-883f-0016d3cca427.jsonl\"") == true)
        XCTAssertEqual(try req(file, ["Cookie": devCookie]).status, 403, "watch: no conversation leaves")
        for path in ["/api/v1/mac/sessions/build/transcripts", "/api/v1/mac/sessions/build/network", "/api/v1/mac/sessions/build/quarantine"] {
            XCTAssertEqual(try macReq(path, ["Cookie": macCookie]).status, 200, path)
            XCTAssertEqual(try req(path, ["Cookie": devCookie]).status, 200, "watch may look: \(path)")
        }
        XCTAssertFalse(try macReq("/api/v1/mac/sessions/build/transcripts", ["Cookie": macCookie]).text.contains("/tmp/fake-store"), "no archive path")
        // The bridges and a resume: the Mac's browser, never a watching one.
        let sw = #"{"action":"mac-session-bridges","session":"build","openURL":false}"#
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/actions", sw, remote: true).status, 403)
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/actions", #"{"action":"mac-session-resume","session":"build"}"#, remote: true).status, 403)
        XCTAssertEqual(try macJSON(macCookie, macCSRF, "/api/v1/actions", sw, remote: false).status, 202)
        try await Task.sleep(for: .milliseconds(300))
        let sent = fake.performed.filter { $0.op == .sessionBridges }
        XCTAssertEqual(sent.count, 1, "one host operation")
        XCTAssertEqual(sent.first?.macBridges?.openURL, false)
        XCTAssertEqual(sent.first?.name, MacPlace.name)
        if server != nil { await server.close(); _ = try? await serveTask.value; server = nil }
        try await start(macSessions: "interactive")
        let (dc, _) = try await admit()
        XCTAssertEqual(try req(file, ["Cookie": dc]).status, 200, "interactive: the person chose to share everything")
    }
}
