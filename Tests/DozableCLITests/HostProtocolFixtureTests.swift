import CryptoKit
import Foundation
import DozableKit
import XCTest
@testable import DozableHost

/// 676: the host protocol's contract — `schema/host-protocol-1/`, golden fixtures a client is tested against. Every
/// file is GENERATED here: by the host's own encoder (`HostWire.encoder`) from its own types, and for `ping`, `ls`,
/// `inspect`, `create`, `rename` and the `not-found` / `version` / `unavailable` errors from a real in-process `HostCore`
/// over a scratch store, with paths, times, pids and ids normalised to fixed values (the repository is public).
///
/// A normal run regenerates them in memory and FAILS on any difference from the committed files, so the fixtures cannot
/// drift from the host. `make protocol-fixtures` (DOZ_WRITE_PROTOCOL_FIXTURES=1) writes them. `README.md` is written by
/// hand and is not generated; `MANIFEST.json`'s `dozable` field records the version that last wrote them and is the one
/// value the drift check does not compare.
final class HostProtocolFixtureTests: XCTestCase {
    static let directory = Pins.packageRoot.appendingPathComponent("schema/host-protocol-1")
    static let fixedTime = Date(timeIntervalSince1970: 1_767_225_600)
    static let fixedTimeText = "2026-01-01T00:00:00.000Z"
    static let fixedStore = "/Users/example/doz-store"
    static let fixedHome = "/Users/example"
    static let fixedPid = 4242
    static let fixtureVersion = "0.0.0-fixture"

    // MARK: the tiers

    /// Tier 1: what a client app drives — the ops a typed client method exists for. Every one has a request and an
    /// answer fixture. Tier 2: everything else, reached by name (`call`); its shape is the request struct and `ops.json`.
    static let tier1: Set<HostOp> = [
        .ping, .ls, .inspect, .sessions, .plan, .plans, .create, .prepare, .prepareStatus,
        .start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm,
        .openSession, .sessionEnd, .sessionRestart, .exec, .rename, .hostStop, .accountList, .resources,
        .ports, .portOpen, .sessionScreen, .sessionGrids,
        .attach, .events, .copy,
    ]

    /// How the connection carries the answer: `none` — zero or more `event` lines, then ONE `ok` line, then the host
    /// closes; `events` — `event` lines until the client hangs up; `attach` — the `ok` line, then raw VT and the attach
    /// wire (`attach/`); `frames` — the `ok` line, then `CopyFrame`s (`copy/`). `when`: the request field that makes it
    /// a stream (otherwise `none`).
    static func stream(_ op: HostOp) -> (mode: String, when: String?) {
        switch op {
        case .attach: ("attach", nil)
        case .copy: ("frames", nil)
        case .events: ("events", nil)
        case .netLog, .console: ("events", "follow")
        default: ("none", nil)
        }
    }

    struct OpEntry: Codable, Equatable {
        var name: String
        var tier: Int
        var stream: String
        var streamWhen: String?
        var readOnly: Bool
        var answeredWithoutHost: Bool
    }

    struct EventKindEntry: Codable, Equatable {
        var kind: String
        /// Sent only to a request that asked (`request` names the field).
        var optIn: Bool
        var request: String?
    }

    struct Catalogue: Codable, Equatable {
        var protocolVersion: Int
        var ops: [OpEntry]
        var eventKinds: [EventKindEntry]
        var errorCodes: [String]
    }

    static func catalogue() -> Catalogue {
        let ops = HostOp.allCases.sorted { $0.rawValue < $1.rawValue }.map { op in
            let s = stream(op)
            return OpEntry(name: op.rawValue, tier: tier1.contains(op) ? 1 : 2, stream: s.mode, streamWhen: s.when,
                           readOnly: op.isReadOnly, answeredWithoutHost: op.isAnsweredWithoutHost)
        }
        let kinds = HostEvent.Kind.allCases.map { k in
            EventKindEntry(kind: k.rawValue, optIn: k == .sessionStatus, request: k == .sessionStatus ? "sessionStatus" : nil)
        }.sorted { $0.kind < $1.kind }
        return Catalogue(protocolVersion: HostProtocol.version, ops: ops, eventKinds: kinds,
                         errorCodes: HostError.Code.allCases.map(\.rawValue).sorted())
    }

    // MARK: the tests

    func testTheFixturesAreWhatTheHostWrites() async throws {
        let write = ProcessInfo.processInfo.environment["DOZ_WRITE_PROTOCOL_FIXTURES"] == "1"
        let committedManifest = try? Data(contentsOf: Self.directory.appendingPathComponent("MANIFEST.json"))
        let recordedVersion = committedManifest.flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }?.dozable
        let version = write ? Self.packageVersion() : (recordedVersion ?? Self.packageVersion())
        let generated = try await Self.generate(dozableVersion: version)
        let present = Set(try Self.committedFiles()).subtracting(Self.handWritten)
        if write {
            for stale in present.subtracting(generated.keys) {
                try FileManager.default.removeItem(at: Self.directory.appendingPathComponent(stale))
            }
            for (path, data) in generated {
                let u = Self.directory.appendingPathComponent(path)
                if (try? Data(contentsOf: u)) == data { continue }
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: u, options: .atomic)
            }
            return
        }
        XCTAssertEqual(present.subtracting(generated.keys).sorted(), [], "files the host no longer writes — run make protocol-fixtures")
        XCTAssertEqual(Set(generated.keys).subtracting(present).sorted(), [], "fixtures not committed — run make protocol-fixtures")
        for (path, data) in generated.sorted(by: { $0.key < $1.key }) where present.contains(path) {
            let have = try Data(contentsOf: Self.directory.appendingPathComponent(path))
            if have != data {
                XCTFail("schema/host-protocol-1/\(path) is not what the host writes — run make protocol-fixtures and review the diff\n"
                        + "committed: \(String(decoding: have.prefix(400), as: UTF8.self))\nhost:      \(String(decoding: data.prefix(400), as: UTF8.self))")
            }
        }
    }

    func testEveryOpHasATierAndEveryTierOneOpIsPinned() throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("ops.json"))
        let cat = try JSONDecoder().decode(Catalogue.self, from: data)
        XCTAssertEqual(cat.ops.map(\.name), HostOp.allCases.map(\.rawValue).sorted(), "ops.json lists exactly HostOp.allCases")
        for e in cat.ops {
            XCTAssertTrue([1, 2].contains(e.tier), e.name)
            XCTAssertTrue(["none", "events", "attach", "frames"].contains(e.stream), e.name)
        }
        let files = try Self.committedFiles()
        for op in Self.tier1 {
            XCTAssertTrue(files.contains { $0.hasPrefix("requests/\(op.rawValue).") && $0.hasSuffix(".json") }, "tier 1 \(op.rawValue): no request fixture")
            XCTAssertTrue(files.contains { $0.hasPrefix("answers/\(op.rawValue).") && $0.hasSuffix(".jsonl") }, "tier 1 \(op.rawValue): no answer fixture")
        }
        for c in HostError.Code.allCases {
            XCTAssertTrue(files.contains("errors/\(c.rawValue).json"), "error code \(c.rawValue): no fixture")
        }
        for k in HostEvent.Kind.allCases {
            XCTAssertTrue(files.contains("events/\(k.rawValue).json"), "event kind \(k.rawValue): no fixture")
        }
        XCTAssertEqual(cat.eventKinds.map(\.kind), HostEvent.Kind.allCases.map(\.rawValue).sorted())
        XCTAssertEqual(cat.errorCodes, HostError.Code.allCases.map(\.rawValue).sorted())
        XCTAssertTrue(files.contains("README.md"))
    }

    /// The repository is public: no fixture carries this Mac — its home, its user, a real path, pid or time.
    func testNoFixtureCarriesThisMac() throws {
        let home = TestSafety.realHome.path
        let user = NSUserName()
        let pid = String(getpid())
        let iso = try NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"#)
        let users = try NSRegularExpression(pattern: #"/Users/([A-Za-z0-9._-]*)"#)
        let pids = try NSRegularExpression(pattern: #""pid":(-?\d+)"#)
        for path in try Self.committedFiles() {
            let text = try String(contentsOf: Self.directory.appendingPathComponent(path), encoding: .utf8)
            let all = NSRange(text.startIndex..., in: text)
            if home.count > 1 { XCTAssertFalse(text.contains(home), "\(path) has this Mac's home") }
            if user.count >= 3, user != "example" {
                XCTAssertNil(text.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: user))\b"#, options: .regularExpression), "\(path) has this Mac's user name")
            }
            for m in users.matches(in: text, range: all) {
                XCTAssertEqual((text as NSString).substring(with: m.range(at: 1)), "example", "\(path): only /Users/example")
            }
            for bad in ["/private/", "/var/folders", "/tmp/dzp-", "/Volumes/"] { XCTAssertFalse(text.contains(bad), "\(path) has \(bad)") }
            for m in pids.matches(in: text, range: all) {
                XCTAssertEqual((text as NSString).substring(with: m.range(at: 1)), String(Self.fixedPid), "\(path): a pid is \(Self.fixedPid)")
            }
            XCTAssertNil(text.range(of: #"[":,\[]\#(pid)[,}\]]"#, options: .regularExpression), "\(path) has this process's pid")
            for m in iso.matches(in: text, range: all) {
                let s = (text as NSString).substring(with: m.range)
                XCTAssertTrue(s.hasPrefix("2026-01-0"), "\(path): a time is fixed (2026-01-01…), not \(s)")
            }
        }
    }

    /// The tolerance fixtures this host's own types already read: a field it does not know, a phase word it does not
    /// know (phases are strings). An unknown event kind or error code is a client's to tolerate — this host's own
    /// client is strict about both (why `session-status` is opt-in) — and the README says so.
    func testThisHostsTypesReadTheToleranceFixturesTheyCan() throws {
        for name in ["unknown-field", "unknown-phase"] {
            let text = try String(contentsOf: Self.directory.appendingPathComponent("tolerance/\(name).jsonl"), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let m = try HostWire.decoder.decode(HostMessage.self, from: Data(line.utf8))
                if m.ok == true { XCTAssertNoThrow(try XCTUnwrap(m.result).decode([SandboxInfo].self), name) }
            }
        }
    }

    // MARK: generation

    struct Manifest: Codable {
        var `protocol`: Int
        var dozable: String
        var files: [String: String]
    }

    struct FixtureError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func packageVersion() -> String {
        ((try? String(contentsOf: Pins.packageRoot.appendingPathComponent("VERSION"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Written by hand, never generated (nor removed by the writing mode).
    static let handWritten: Set<String> = ["README.md"]

    /// Every committed file but none hidden, by its path relative to the directory.
    static func committedFiles() throws -> [String] {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(u.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))
            if !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { out.append(rel) }
        }
        return out.sorted()
    }

    /// The whole directory but README.md, by relative path.
    static func generate(dozableVersion: String) async throws -> [String: Data] {
        var f = Files()
        try catalogueFile(&f)
        try requests(&f)
        try constructedAnswers(&f)
        try await realAnswers(&f)
        try events(&f)
        try constructedErrors(&f)
        try tolerance(&f)
        try attachVectors(&f)
        try copyFrames(&f)
        var hashes: [String: String] = [:]
        for (p, d) in f.map { hashes[p] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        f.map["MANIFEST.json"] = try pretty(Manifest(protocol: HostProtocol.version, dozable: dozableVersion, files: hashes))
        return f.map
    }

    struct Files {
        var map: [String: Data] = [:]
        mutating func lines(_ path: String, _ messages: [HostMessage]) throws {
            precondition(map[path] == nil, path)
            map[path] = Data((try messages.map(HostProtocolFixtureTests.line)).joined(separator: "\n").utf8 + [10])
        }
        mutating func request(_ name: String, _ r: HostRequest) throws {
            precondition(map["requests/\(name).json"] == nil, name)
            map["requests/\(name).json"] = try HostWire.encoder.encode(r) + [10]
        }
        mutating func answer(_ name: String, _ messages: [HostMessage]) throws { try lines("answers/\(name).jsonl", messages) }
        mutating func pretty<T: Encodable>(_ path: String, _ v: T) throws {
            precondition(map[path] == nil, path)
            map[path] = try HostProtocolFixtureTests.pretty(v)
        }
    }

    static func pretty<T: Encodable>(_ v: T) throws -> Data { try HostWire.prettyEncoder.encode(v) + [10] }

    static func line(_ m: HostMessage) throws -> String { String(decoding: try HostWire.encoder.encode(m), as: UTF8.self) }

    static func ok<T: Encodable>(_ v: T) throws -> HostMessage { .success(try JSONValue(encoding: v)) }

    static func event(_ kind: HostEvent.Kind, _ text: String? = nil, sandbox: String? = "box", phase: String? = nil,
                      milliseconds: Double? = nil, _ edit: (inout HostEvent) -> Void = { _ in }) -> HostMessage {
        var e = HostEvent(kind: kind, sandbox: sandbox, text: text, phase: phase, milliseconds: milliseconds, time: fixedTime)
        edit(&e)
        return HostMessage(event: e)
    }

    /// A value of a real type from a JSON literal: decoded by the host's decoder (its required fields must be there),
    /// and every key of the literal must survive the type's own encoding — a misspelt or dropped key fails.
    static func typed<T: Codable>(_ type: T.Type, _ json: String) throws -> T {
        let literal = try HostWire.decoder.decode(JSONValue.self, from: Data(json.utf8))
        let v: T
        do { v = try HostWire.decoder.decode(T.self, from: Data(json.utf8)) } catch { throw FixtureError("\(T.self): \(error)") }
        if let lost = lostKey(literal, try JSONValue(encoding: v), at: "") { throw FixtureError("\(T.self): the literal's \(lost) is not in its encoding") }
        return v
    }

    static func lostKey(_ a: JSONValue, _ b: JSONValue, at path: String) -> String? {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for k in x.keys.sorted() {
                guard let yv = y[k] else { if x[k] == .null { continue }; return path + "." + k }
                if let l = lostKey(x[k]!, yv, at: path + "." + k) { return l }
            }
        case (.array(let x), .array(let y)):
            for (i, xv) in x.enumerated() where i < y.count { if let l = lostKey(xv, y[i], at: path + "[\(i)]") { return l } }
        default: break
        }
        return nil
    }

    static func request(_ op: HostOp, _ name: String? = "box", _ edit: (inout HostRequest) -> Void = { _ in }) -> HostRequest {
        var r = HostRequest(op, name: name)
        edit(&r)
        return r
    }

    static func catalogueFile(_ f: inout Files) throws { try f.pretty("ops.json", catalogue()) }

    // MARK: requests

    static func requests(_ f: inout Files) throws {
        try f.request("ping.default", request(.ping, nil))
        try f.request("ping.v2", request(.ping, nil) { $0.v = 2 })
        try f.request("ls.default", request(.ls, nil))
        try f.request("ls.without-sessions", request(.ls, nil) { $0.withSessions = false })
        try f.request("inspect.default", request(.inspect))
        try f.request("inspect.not-found", request(.inspect, "nope"))
        try f.request("sessions.default", request(.sessions))
        try f.request("plan.try", request(.plan, nil) { $0.planRequest = planRequest() })
        try f.request("plans.two", request(.plans, nil) {
            $0.planRequests = [planRequest(), PlanRequest(purpose: "create", name: "box", create: CreateOptions(image: "lab"))]
        })
        try f.request("create.lab", request(.create) { $0.create = CreateOptions(image: "lab") })
        try f.request("create.full", request(.create) {
            var o = CreateOptions(image: "claude-code", cpus: 4, memoryMiB: 4096, workspace: fixedHome + "/project", network: "agent", account: "mac")
            o.allow = ["site:api.example.com"]
            o.agentSudo = true
            o.settings = ["sandbox.clipboard": .string("off")]
            o.keys = ["example-key"]
            $0.create = o
            $0.start = true
        })
        try f.request("prepare.claude-code", request(.prepare, nil) {
            $0.images = ["claude-code"]
            $0.requestedBy = "example-app"
            $0.follow = true
        })
        try f.request("prepare-status.default", request(.prepareStatus, nil))
        for op: HostOp in [.start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm] {
            try f.request("\(op.rawValue).default", request(op))
        }
        try f.request("open-session.default", request(.openSession) {
            $0.session = "shell"
            $0.argv = ["bash", "-l"]
            $0.cols = 120
            $0.rows = 40
            $0.wake = true
            $0.start = true
        })
        try f.request("session-end.default", request(.sessionEnd) { $0.session = "shell" })
        try f.request("session-restart.default", request(.sessionRestart) { $0.session = "claude"; $0.fresh = false })
        try f.request("exec.default", request(.exec) {
            $0.argv = ["sh", "-c", "echo hello"]
            $0.environment = ["EXAMPLE": "1"]
            $0.user = "root"
            $0.workdir = "/workspace"
            $0.timeoutSeconds = 30
            $0.wake = true
            $0.start = true
        })
        try f.request("rename.default", request(.rename) { $0.newName = "renamed" })
        try f.request("host-stop.default", request(.hostStop, nil))
        try f.request("account-ls.default", request(.accountList, nil))
        try f.request("resources.default", request(.resources, nil))
        try f.request("ports.list", request(.ports))
        try f.request("ports.add", request(.ports) { $0.portAdd = PortForwardEntry(port: 8080, title: "web", path: "/") })
        try f.request("ports.remove", request(.ports) { $0.portRemove = 8080 })
        try f.request("port-open.default", request(.portOpen) { $0.openPort = 3000 })
        try f.request("session-screen.default", request(.sessionScreen) { $0.session = "shell" })
        try f.request("session-grids.default", request(.sessionGrids, nil) {
            $0.grids = [SessionGridRequest(sandbox: "box", session: "shell"), SessionGridRequest(sandbox: "box", session: "claude", gen: 7),
                        SessionGridRequest(sandbox: "asleep", session: "shell")]
        })
        try f.request("attach.default", request(.attach) {
            $0.session = "shell"
            $0.cols = 120
            $0.rows = 40
            $0.wake = true
            $0.openDefault = true
        })
        try f.request("attach.v2", request(.attach) { $0.v = 2; $0.session = "shell" })
        try f.request("events.default", request(.events, nil))
        try f.request("events.session-status", request(.events) { $0.sessionStatus = true })
        try f.request("copy.get", request(.copy) { $0.fileCopy = CopyRequest(direction: .get, path: "notes.txt") })
        try f.request("copy.put", request(.copy) {
            $0.fileCopy = CopyRequest(direction: .put, path: "/workspace/in", kind: .folder, name: "in", force: true)
        })
    }

    static func planRequest() -> PlanRequest {
        PlanRequest(purpose: "try", create: CreateOptions(image: "claude-code", workspace: fixedHome + "/project"), tryFlags: ["--rm"])
    }

    // MARK: answers made from constructed values

    static let sandboxInfoJSON = """
    {"account":"mac","base":"node","busy":false,"cpus":2,"createdAt":"2026-01-01T00:00:00.000Z","credentialPolicy":"allow",
     "credentialState":"ok","deniedConnections":0,"diskBytes":1073741824,"image":"claude-code","imageTitle":"Node.js · Claude Code",
     "memoryMiB":2048,"memoryReturnedMiB":0,"name":"box","network":"agent","phase":"running","ramHeldMiB":2048,"sessions":1,
     "workspace":"/Users/example/project","agent":"claude-code","agentWorking":true}
    """

    static func info(_ phase: String) throws -> SandboxInfo {
        var i = try typed(SandboxInfo.self, sandboxInfoJSON)
        i.phase = phase
        return i
    }

    static func lifecycle(_ op: HostOp, _ before: String, _ after: String, changed: Bool = true, ms: Double, info: SandboxInfo?) -> LifecycleResult {
        LifecycleResult(name: "box", operation: op.rawValue, phaseBefore: before, phase: after, changed: changed, milliseconds: ms, info: info)
    }

    static func constructedAnswers(_ f: inout Files) throws {
        try f.answer("sessions.default", [ok(try typed([SessionRow].self, """
        [{"name":"shell","pid":4242,"cols":120,"rows":40,"clients":1,"screen":"main","command":"bash -l","ended":false,
          "openedAt":"2026-01-01T00:00:00.000Z"},
         {"name":"claude","pid":4242,"cols":120,"rows":40,"clients":0,"command":"claude","ended":false,
          "status":{"session":"claude","state":"working","app":"claude-code","message":"editing files","updatedAt":"2026-01-01T00:00:00.000Z"}},
         {"name":"build","cols":80,"rows":24,"clients":0,"command":"make","exitCode":2,"ended":true}]
        """))])
        let plan = """
        {"purpose":"try","name":"claude-code-1","image":"claude-code","workspace":"/Users/example/project",
         "command":"doz try claude-code --rm","argv":["doz","try","claude-code","--rm"],"yaml":"image: claude-code\\n",
         "reach":[{"kind":"model","text":"Anthropic's API"},{"kind":"folder","text":"/Users/example/project at /workspace"}],
         "imageState":{"name":"claude-code","title":"Node.js · Claude Code","state":"unprepared"},
         "account":{"name":"mac","kind":"mac","provider":"anthropic","sourceLabel":"this Mac's Claude Code login"},
         "problems":[],"version":{"version":"2.1.0","ref":"claude-code","title":"Claude Code","majors":[]},
         "create":{"image":"claude-code","workspace":"/Users/example/project"}}
        """
        let problem = """
        {"purpose":"create","name":"box","image":"lab","command":"doz create box --image lab","argv":["doz","create","box","--image","lab"],
         "yaml":"image: lab\\n","reach":[],"imageState":{"name":"lab","title":"Alpine · none","state":"prepared"},
         "problems":[{"code":"name","text":"a sandbox named box exists","fix":"doz create box-2"}],"create":{"image":"lab"}}
        """
        try f.answer("plan.try", [ok(try typed(CreatePlan.self, plan))])
        try f.answer("plans.two", [ok([try typed(CreatePlan.self, plan), try typed(CreatePlan.self, problem)])])

        let preparation = """
        {"id":"claude-code","image":"claude-code","state":"done","requestedBy":["example-app"],"startedAt":"2026-01-01T00:00:00.000Z",
         "finishedAt":"2026-01-01T00:00:00.000Z","seconds":151.5,"output":[],"lines":["pulled the base image node","baked claude-code"],
         "stepIndex":4,"plannedSteps":4,
         "steps":[{"label":"pulled the base image node","kind":"step","seconds":61.2,"usualSeconds":58},{"label":"baked claude-code","kind":"step","seconds":90.3}]}
        """
        try f.answer("prepare.claude-code", [
            event(.started, "pulling the base image node", sandbox: nil),
            event(.progress, "pulling the base image node", sandbox: nil) {
                $0.completedBytes = 104_857_600; $0.totalBytes = 399_778_410; $0.completedItems = 2; $0.totalItems = 6
            },
            event(.step, "pulled the base image node", sandbox: nil, milliseconds: 61_200),
            event(.output, "added 3 packages", sandbox: nil),
            event(.step, "baked claude-code", sandbox: nil, milliseconds: 90_300),
            ok(PrepareResult(preparations: [try typed(PreparationInfo.self, preparation)], onboarded: nil)),
        ])
        try f.answer("prepare-status.default", [ok(try typed(PrepareStatus.self, """
        {"preparations":[\(preparation)],"hostRunning":true,
         "onboarded":{"version":1,"dozVersion":"0.0.0-fixture","date":"2026-01-01T00:00:00.000Z","images":["claude-code"],"base":"node"},
         "images":[{"name":"claude-code","kind":"builtin","baked":true,"base":"node","agent":"claude-code","current":true,"title":"Node.js · Claude Code",
                    "version":"2.1.0","versionSetting":"latest","status":"prepared","bakedAt":"2026-01-01T00:00:00.000Z","allocatedBytes":734003200}],
         "base":{"id":"node","title":"Node.js","reference":"node:22-bookworm","useCase":"JavaScript and TypeScript","downloadBytes":399778410,
                 "prepareSeconds":150,"prepared":true}}
        """))])

        // Lifecycle: each op once, the phases it moves between.
        try f.answer("start.default", [
            event(.phase, "booting", phase: "booting"),
            event(.started, "booting box"),
            event(.step, "booted box", milliseconds: 812.5),
            event(.phase, "running", phase: "running"),
            ok(lifecycle(.start, "off", "running", ms: 812.5, info: try info("running"))),
        ])
        try f.answer("wake.default", [
            event(.phase, "running", phase: "running"),
            ok(lifecycle(.wake, "asleep", "running", ms: 240, info: try info("running"))),
        ])
        try f.answer("pause.default", [ok(lifecycle(.pause, "running", "paused", ms: 12.5, info: try info("paused")))])
        try f.answer("resume.default", [ok(lifecycle(.resume, "paused", "running", ms: 8, info: try info("running")))])
        try f.answer("sleep.default", [ok(lifecycle(.sleep, "running", "asleep", ms: 310, info: try info("asleep")))])
        try f.answer("hibernate.default", [
            event(.started, "hibernating box"),
            event(.step, "hibernated box", milliseconds: 2100) { $0.startedAs = "hibernating box" },
            event(.phase, "hibernated", phase: "hibernated"),
            ok(lifecycle(.hibernate, "running", "hibernated", ms: 2100, info: try info("hibernated"))),
        ])
        try f.answer("shutdown.default", [ok(lifecycle(.shutdown, "running", "off", ms: 1500, info: try info("off")))])
        try f.answer("shutdown.unchanged", [ok(lifecycle(.shutdown, "off", "off", changed: false, ms: 0, info: try info("off")))])
        try f.answer("reset.default", [ok(lifecycle(.reset, "off", "off", ms: 30, info: try info("off")))])
        try f.answer("rm.default", [ok(lifecycle(.rm, "off", "off", ms: 25, info: nil))])

        var opened = SessionOpened(name: "box", session: "shell", created: true)
        opened.defaultSession = "shell"
        opened.woke = true
        opened.bootMilliseconds = 240
        opened.tmux = false
        try f.answer("open-session.default", [event(.phase, "running", phase: "running"), ok(opened)])
        try f.answer("session-end.default", [ok(SessionEnded(name: "box", session: "shell", how: "hangup"))])
        try f.answer("session-restart.default", [ok(SessionRestarted(name: "box", session: "claude", ended: "hangup", resumed: true,
                                                                     command: "claude --continue"))])
        try f.answer("exec.default", [ok(ExecOutput(exitCode: 0, stdout: Data("hello\n".utf8), stderr: Data(), milliseconds: 42.5))])
        var started = ExecOutput(exitCode: 3, stdout: Data(), stderr: Data("no such file\n".utf8), milliseconds: 15)
        started.started = true
        started.bootMilliseconds = 812.5
        try f.answer("exec.started-and-failed", [event(.phase, "booting", phase: "booting"), event(.phase, "running", phase: "running"), ok(started)])
        try f.answer("host-stop.default", [
            event(.started, "hibernating box"),
            event(.step, "hibernated box", milliseconds: 2100) { $0.startedAs = "hibernating box" },
            ok(HostStopResult(sandboxes: [HostStopRow(name: "box", phaseBefore: "running", phase: "hibernated", outcome: "hibernated",
                                                      milliseconds: 2100, snapshotBytes: 536_870_912)],
                              milliseconds: 2150, version: fixtureVersion)),
        ])
        try f.answer("account-ls.default", [ok(try typed([AccountRow].self, """
        [{"name":"mac","kind":"mac","isDefault":true,"usedBy":["box"],"state":"ok","provider":"anthropic","identity":"person@example.com",
          "keychainService":"Claude Code-credentials","expiresAt":"2026-01-01T00:00:00.000Z"},
         {"name":"example-key","kind":"key","isDefault":false,"usedBy":[],"state":"unchecked","provider":"xai","fingerprint":"0123456789ab",
          "sourceLabel":"keychain","sourceState":"unchecked"}]
        """))])
        try f.answer("resources.default", [ok(try typed(ResourceReport.self, """
        {"store":"/Users/example/doz-store","measuredAt":"2026-01-01T00:00:00.000Z","milliseconds":120.5,"totalBytes":2147483648,
         "attributedBytes":2147483648,"unattributedBytes":0,"occupiedBytes":1610612736,"cleanableBytes":536870912,
         "volumeFreeBytes":107374182400,"volumeTotalBytes":494384795648,
         "items":[{"id":"sandbox:box","group":"sandboxes","name":"box","detail":"claude-code","sizeBytes":1073741824,"usedBy":[],"deletable":false,
                   "refusal":"it is running","recreatable":false,"cleanable":false,"path":"/Users/example/doz-store/sandboxes/box"}],
         "memory":[{"kind":"sandbox","name":"box","phase":"running","heldBytes":2147483648,"allocationBytes":2147483648,"cpus":2}],
         "machineCPUs":10,"allocatedCPUs":2,
         "network":[{"sandbox":"box","upToday":1024,"downToday":4096,"upTotal":2048,"downTotal":8192,"connectionsTotal":12}],
         "kernels":[{"id":"kernel:6.12.28","version":"6.12.28","sizeBytes":15728640,"current":true,"pinned":true,"inStore":true,"usedBy":["box"]}],
         "unusedDays":30}
        """))])
        let row = try typed(PortForwardRow.self, """
        {"port":3000,"title":"web","path":"/","protocol":"http","origin":"recipe","state":"listening","mac_port":3000,
         "url":"http://127.0.0.1:3000/","serving":true}
        """)
        try f.answer("ports.list", [ok(PortsAnswer(sandbox: "box", phase: "running", ports: [row]))])
        var added = row
        added.port = 8080; added.macPort = 8081; added.moved = true; added.origin = "added"; added.url = "http://127.0.0.1:8081/"; added.serving = false
        try f.answer("ports.add", [ok(PortsAnswer(sandbox: "box", phase: "running", ports: [row, added], note: "added 8080 (at 8081 on this Mac: 8080 was taken)"))])
        try f.answer("ports.remove", [ok(PortsAnswer(sandbox: "box", phase: "running", ports: [row], note: "stopped forwarding 8080"))])
        try f.answer("port-open.default", [ok(try typed(PortOpened.self, """
        {"sandbox":"box","port":3000,"title":"web","url":"http://127.0.0.1:3000/","signed_in":true}
        """))])
        try f.answer("session-screen.default", [ok(try typed(SessionScreen.self, """
        {"name":"box","session":"shell","savedAt":"2026-01-01T00:00:00.000Z","reason":"sleep","cols":80,"rows":24,"screen":"main",
         "command":"bash -l","truncated":false,"text":"$ echo hello\\nhello\\n$","vt":"\(Data("\u{1B}[H\u{1B}[2J$ echo hello\r\nhello\r\n$ ".utf8).base64EncodedString())"}
        """))])
        let grid = ScreenGrid(cols: 80, rows: 2, gen: 9, fg: "#d0d0d0", bg: "#101010", cursor: .init(x: 2, y: 1),
                              lines: [[ScreenGrid.Run(col: 0, text: "hello", fg: "#00ff00", flags: 1, cells: 5)], [ScreenGrid.Run(col: 0, text: "$ ", cells: 2)]])
        try f.answer("session-grids.default", [ok([
            SessionGridAnswer(sandbox: "box", session: "shell", state: .grid, gen: 9, grid: grid),
            SessionGridAnswer(sandbox: "box", session: "claude", state: .unchanged, gen: 7),
            SessionGridAnswer(sandbox: "asleep", session: "shell", state: .unavailable, reason: .notRunning),
        ])])
        // The attach answer (then the terminal: `attach/`). HostServer writes these objects itself.
        try f.answer("attach.attached", [.success(.object(["state": .string("attached"), "session": .string("shell"), "sandbox": .string("box"),
                                                           "defaultSession": .string("shell"), "image": .string("claude-code"), "opened": .bool(false)]))])
        try f.answer("attach.held", [.success(.object(["state": .string("held"), "session": .string("shell"), "sandbox": .string("box"),
                                                       "defaultSession": .string("shell"), "image": .string("claude-code"), "phase": .string("asleep")]))])
        try f.answer("attach.v2", [try XCTUnwrap(HostServer.versionRefusal(try HostWire.encoder.encode(request(.attach) { $0.v = 2; $0.session = "shell" })))])
        try f.answer("events.default", [
            event(.phase, "asleep", phase: "asleep"),
            event(.note, "box: the clipboard bridge copied 12 characters"),
            event(.host, "a newer doz is installed — it is used once this host exits", sandbox: nil),
        ])
        try f.answer("events.session-status", [
            event(.sessionStatus, "working") {
                $0.session = "claude"
                $0.sessionStatus = SessionStatus(session: "claude", state: .working, app: "claude-code", message: "editing files", updatedAt: fixedTime)
            },
        ])
        try f.answer("copy.get", [ok(try typed(CopyReady.self, #"{"kind":"file","path":"/workspace/notes.txt","bytes":12,"files":1}"#))])
        try f.answer("copy.put", [ok(try typed(CopyReady.self, #"{"kind":"folder","path":"/workspace/in","runAs":"node","replaces":"folder"}"#))])
    }

    // MARK: answers from a real host core

    /// A real in-process `HostCore` over a scratch store: what it answers, with the store's path, times, pids and ids
    /// normalised.
    static func realAnswers(_ f: inout Files) async throws {
        let root = URL(fileURLWithPath: "/tmp/dzp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = CredentialServices(keychain: FakeKeychain(), verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                          keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        var n = Normaliser(roots: [root.path, "/private" + root.path])
        func reader() async -> HostCore {
            let c = HostCore(store: DozableStore(root: root), readOnly: true, version: fixtureVersion, services: services)
            await c.load()
            return c
        }
        func ask(_ c: HostCore, _ r: HostRequest) async throws -> HostMessage {
            let m = await c.handle(r)
            return try n.apply(m)
        }

        let empty = await reader()
        try f.answer("ping.default", [try await ask(empty, request(.ping, nil))])
        try f.answer("ping.v2", [try await ask(empty, request(.ping, nil) { $0.v = 2 })])
        try f.answer("ls.empty", [try await ask(empty, request(.ls, nil))])
        f.map["errors/version.json"] = Data(try line(try await ask(empty, request(.ls, nil) { $0.v = 2 })).utf8 + [10])
        f.map["errors/unavailable.json"] = Data(try line(try await ask(empty, request(.ports))).utf8 + [10])

        let writer = HostCore(store: DozableStore(root: root), readOnly: false, version: fixtureVersion, services: services)
        await writer.load()
        try f.answer("create.lab", [try await ask(writer, request(.create) { $0.create = CreateOptions(image: "lab") })])

        let one = await reader()
        try f.answer("ls.one", [try await ask(one, request(.ls, nil))])
        try f.answer("inspect.default", [try await ask(one, request(.inspect))])
        let notFound = try await ask(one, request(.inspect, "nope"))
        try f.answer("inspect.not-found", [notFound])
        f.map["errors/not-found.json"] = Data(try line(notFound).utf8 + [10])
        try f.answer("sessions.off", [try await ask(one, request(.sessions))])

        try f.answer("rename.default", [try await ask(writer, request(.rename) { $0.newName = "renamed" })])
    }

    /// Paths of the scratch store → `/Users/example/doz-store`; every time → the fixed one; every `pid` → 4242; every
    /// UUID → 00000000-0000-0000-0000-00000000000N in the order first seen (keys walked sorted).
    struct Normaliser {
        let roots: [String]
        var uuids: [String: String] = [:]

        mutating func apply(_ m: HostMessage) throws -> HostMessage {
            let v = walk(try JSONValue(encoding: m), key: nil)
            return try v.decode(HostMessage.self)
        }

        mutating func walk(_ v: JSONValue, key: String?) -> JSONValue {
            switch v {
            case .string(let s):
                if HostWire.isoFormatter().date(from: s) != nil { return .string(HostProtocolFixtureTests.fixedTimeText) }
                if UUID(uuidString: s) != nil {
                    if let u = uuids[s] { return .string(u) }
                    let u = String(format: "00000000-0000-0000-0000-%012d", uuids.count + 1)
                    uuids[s] = u
                    return .string(u)
                }
                var out = s
                for r in roots.sorted(by: { $0.count > $1.count }) { out = out.replacingOccurrences(of: r, with: HostProtocolFixtureTests.fixedStore) }
                return .string(out)
            case .number where key == "pid":
                return .number(Double(HostProtocolFixtureTests.fixedPid))
            case .array(let a):
                return .array(a.map { walk($0, key: key) })
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for k in o.keys.sorted() { out[k] = walk(o[k]!, key: k) }
                return .object(out)
            default:
                return v
            }
        }
    }

    // MARK: events and errors

    static func events(_ f: inout Files) throws {
        let connection = try typed(ConnectionRecord.self, """
        {"id":"00000000-0000-0000-0000-000000000001","time":"2026-01-01T00:00:00.000Z","kind":"http","host":"api.anthropic.com","port":443,
         "method":"POST","path":"/v1/messages","verdict":"allowed","rule":"allow api.anthropic.com","decrypted":true,"credential":"claude-oauth",
         "bytesUp":2048,"bytesDown":8192,"latencyMs":120.5,"durationMs":900,"open":false}
        """)
        let one: [HostEvent.Kind: HostMessage] = [
            .phase: event(.phase, "running", phase: "running"),
            .step: event(.step, "booted box", milliseconds: 812.5),
            .note: event(.note, "the clipboard bridge copied 12 characters"),
            .progress: event(.progress, "pulling the base image node", sandbox: nil) {
                $0.completedBytes = 104_857_600; $0.totalBytes = 399_778_410; $0.completedItems = 2; $0.totalItems = 6
            },
            .connection: event(.connection) { $0.connection = connection },
            .host: event(.host, "host started", sandbox: nil),
            .console: event(.console, "[    0.000000] Linux version 6.12.28"),
            .started: event(.started, "booting box"),
            .failed: event(.failed, "booting box", milliseconds: 120) { $0.error = "the kernel did not start" },
            .output: event(.output, "added 3 packages", sandbox: nil),
            .sessionStatus: event(.sessionStatus, "working") {
                $0.session = "claude"
                $0.sessionStatus = SessionStatus(session: "claude", state: .blocked, app: "claude-code", kind: .permission,
                                                 message: "allow editing files?", updatedAt: fixedTime)
            },
        ]
        for k in HostEvent.Kind.allCases {
            guard let m = one[k] else { throw FixtureError("no event fixture for \(k.rawValue)") }
            f.map["events/\(k.rawValue).json"] = Data(try line(m).utf8 + [10])
        }
    }

    static func constructedErrors(_ f: inout Files) throws {
        let made: [HostError.Code: String] = [
            .failed: "box: the guest did not answer",
            .invalidPhase: "box is asleep — `doz wake box` first",
            .exists: "a sandbox named box exists",
            .invalid: "which session? (doz sessions box --screen SESSION)",
            .notImplemented: "not implemented yet",
        ]
        for (code, text) in made { f.map["errors/\(code.rawValue).json"] = Data(try line(.failure(HostError(code, text))).utf8 + [10]) }
        for c in HostError.Code.allCases where f.map["errors/\(c.rawValue).json"] == nil { throw FixtureError("no error fixture for \(c.rawValue)") }
    }

    // MARK: tolerance

    /// What a client must still read: lines with a field it does not know, an event kind, a phase word or an error
    /// code it does not know. Made from real lines with something added.
    static func tolerance(_ f: inout Files) throws {
        func edited(_ m: HostMessage, _ edit: (inout [String: JSONValue]) -> Void) throws -> String {
            guard case .object(var o) = try JSONValue(encoding: m) else { throw FixtureError("not an object") }
            edit(&o)
            return String(decoding: try HostWire.encoder.encode(JSONValue.object(o)), as: UTF8.self)
        }
        func add(_ path: String, _ lines: [String]) { f.map["tolerance/\(path).jsonl"] = Data(lines.joined(separator: "\n").utf8 + [10]) }
        let row = try JSONValue(encoding: info("running"))
        func rowWith(_ k: String, _ v: JSONValue) -> JSONValue {
            guard case .object(var o) = row else { return row }
            o[k] = v
            return .object(o)
        }
        add("unknown-field", [
            try edited(event(.step, "booted box", milliseconds: 812.5)) { o in
                if case .object(var e)? = o["event"] { e["somethingNew"] = .object(["x": .number(1)]); o["event"] = .object(e) }
            },
            try edited(.success(.array([rowWith("somethingNew", .array([.string("a")]))]))) { $0["trace"] = .string("abc") },
        ])
        add("unknown-phase", [
            try line(event(.phase, "dreaming", phase: "dreaming")),
            try line(.success(.array([rowWith("phase", .string("dreaming"))]))),
        ])
        add("unknown-event-kind", [
            try edited(event(.note, "a kind from a newer host")) { o in
                if case .object(var e)? = o["event"] { e["kind"] = .string("future-kind"); o["event"] = .object(e) }
            },
            try line(ok(LifecycleResult(name: "box", operation: "wake", phaseBefore: "asleep", phase: "running", changed: true, milliseconds: 240, info: nil))),
        ])
        add("unknown-error-code", [
            try edited(.failure(HostError(.failed, "a code from a newer host"))) { o in
                o["error"] = .object(["code": .string("future-code"), "message": .string("a code from a newer host")])
            },
        ])
    }

    // MARK: the attach wire and the copy frames

    struct WireVector: Codable {
        struct Expect: Codable {
            var screen_hex: String
            var notices: [[String: String]]
            var ending: String?
            var endingText: String?
        }
        var description: String
        var bytes_hex: String
        var expect: Expect?
    }

    static func hex<S: Sequence>(_ b: S) -> String where S.Element == UInt8 { b.map { String(format: "%02x", $0) }.joined() }

    static func ending(_ e: ClientWire.Ending?) -> String? {
        switch e {
        case .exited(let c)?: "exited:\(c)"
        case .noSession?: "none"
        case .stopped?: "stopped"
        case nil: nil
        }
    }

    static func attachVectors(_ f: inout Files) throws {
        func frame(_ name: String, _ d: String, _ b: [UInt8]) throws { try f.pretty("attach/\(name).json", WireVector(description: d, bytes_hex: hex(b))) }
        try frame("client-hello", "client → host: HELLO, 120 columns × 40 rows (0xFF 'H' cols rows, big-endian u16) — the first thing a client sends",
                  ClientWire.hello(TermSize(cols: 120, rows: 40)))
        try frame("client-resize", "client → host: RESIZE to 80 × 24 (0xFF 'R' cols rows)", ClientWire.resize(TermSize(cols: 80, rows: 24)))
        try frame("client-repaint", "client → host: REPAINT (0xFF 'S' 0 0 0 0) — send this viewer a fresh snapshot of the screen", ClientWire.repaint)
        try frame("client-keys-and-frames", "client → host: keystrokes with frames between them; 0xFF never occurs in UTF-8, so typing cannot forge a frame",
                  Array("ls".utf8) + ClientWire.resize(TermSize(cols: 100, rows: 30)) + Array("\r".utf8))

        // Host → client: what every viewer does with the stream (`ClientWire.ViewerStream`), cut anywhere.
        func vector(_ name: String, _ d: String, _ bytes: [UInt8]) throws {
            var whole = ClientWire.ViewerStream()
            let s = whole.feed(bytes)
            let screen = s.ending != nil ? s.screen : s.screen + whole.flush()
            // The same bytes fed one at a time give the same result (a client may read them cut anywhere).
            var cut = ClientWire.ViewerStream()
            var cutScreen: [UInt8] = []
            var cutNotices: [BridgeNotice] = []
            var cutEnding: ClientWire.Ending?
            for b in bytes where cutEnding == nil {
                let step = cut.feed([b])
                cutScreen += step.screen
                cutNotices += step.notices
                cutEnding = step.ending
            }
            if cutEnding == nil { cutScreen += cut.flush() }
            guard cutScreen == screen, cutNotices == s.notices, cutEnding == s.ending else { throw FixtureError("\(name): cut byte by byte differs") }
            try f.pretty("attach/\(name).json", WireVector(description: d, bytes_hex: hex(bytes), expect: .init(
                screen_hex: hex(screen), notices: s.notices.map { ["kind": $0.kind, "text": $0.text] },
                ending: ending(s.ending), endingText: s.ending == nil ? nil : s.endingText)))
        }
        try vector("ended-exited-0", "host → client: the session's program exited 0 — the ended notice, then the host closes",
                   Array(ClientWire.endedNotice(.exited(0), text: "the shell session has ended (exit 0)")))
        try vector("ended-exited-42", "host → client: screen bytes, then the program exited 42",
                   Array("bye\r\n".utf8) + Array(ClientWire.endedNotice(.exited(42), text: "the shell session has ended (exit 42)")))
        try vector("ended-no-session", "host → client: there is no such session",
                   Array(ClientWire.endedNotice(.noSession, text: "no session shell in box")))
        try vector("ended-stopped", "host → client: the sandbox shut down (or was removed) — the session is gone",
                   Array(ClientWire.endedNotice(.stopped, text: "box is off — the session is gone")))
        try vector("notice-clipboard", "host → client: a bridge's notice for the person (never drawn) between screen bytes",
                   Array("ab".utf8) + Array(ClientWire.notice(BridgeNotice("clipboard", "box copied 12 characters"))) + Array("cd".utf8))
        try vector("stream-mixed", "host → client: screen, a notice, more screen and the end — the same result however the bytes are cut",
                   Array("\u{1B}[1mhello\u{1B}[0m ".utf8) + Array(ClientWire.notice(BridgeNotice("open", "opened https://example.com")))
                   + Array("world\r\n".utf8) + Array(ClientWire.endedNotice(.exited(3), text: "the shell session has ended (exit 3)")))
        try vector("stream-no-end", "host → client: the connection closes without an end — reattach when it runs again (a held SGR reset is screen)",
                   Array("partial\u{1B}[0m".utf8))
    }

    static func copyFrames(_ f: inout Files) throws {
        func frame(_ name: String, _ d: String, _ b: Data) throws { try f.pretty("copy/\(name).json", WireVector(description: d, bytes_hex: hex(b))) }
        try frame("data", "either way: D (0x44), a 4-byte big-endian length, the payload — a piece of the tar stream (at most 1 MiB)",
                  CopyFrame.encode(CopyFrame.data, Data("hello".utf8)))
        try frame("finish", "client → host (put): F (0x46), length 0 — the input is done", CopyFrame.encode(CopyFrame.finish))
        let done = try typed(CopyDone.self, #"{"ok":true,"bytes":10240,"milliseconds":35.5}"#)
        try frame("end", "host → client: E (0x45) and a CopyDone (JSON) — the last frame", CopyFrame.encode(CopyFrame.end, try HostWire.encoder.encode(done)))
        let failed = try typed(CopyDone.self, #"{"ok":false,"error":"tar: notes.txt: Cannot open: Permission denied","bytes":0,"milliseconds":5}"#)
        try frame("end-failed", "host → client: E with a failed CopyDone", CopyFrame.encode(CopyFrame.end, try HostWire.encoder.encode(failed)))
    }
}
