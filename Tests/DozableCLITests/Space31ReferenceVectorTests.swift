import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// The space format's own space/3.1 vectors (`Fixtures/space31-reference/`, vendored read-only with its PIN): 15 valid
/// files and 36 refused ones, each run through the CLI's entry for a space file (`SpaceResolver().resolve(path).check()`,
/// what `doz space config` and `plan` do first; then, for a file that passes, the plan's own refusals of kind `invalid`,
/// which `plan` also answers with 65, and its notes). The match is EXACT: a valid vector has no problem at all and exactly
/// its notes, in order (the plan's own "not applied in this version" notes aside); a refused one exits 65 with exactly one
/// problem — its severity (error), path, line, message and hint. The three examples as space/3.1 files are checked against
/// their recorded `config` and `plan` as `SpaceResolverTests` and `SpaceUpPlanTests` check the space/3 ones.
///
/// Where Dozable and a vector disagree, the vector's id and what differs are in `knownDisagreements` — the ONE list —
/// and nothing else: each is settled with the format's author (which side changes) before either side changes. The
/// suite passes while every disagreement is listed and fails on any that is not, or that has gone.
final class Space31ReferenceVectorTests: XCTestCase {
    struct Problem: Decodable {
        var path: String
        var line: Int?
        var message: String
        var hint: String?
    }
    struct DefaultsFile: Decodable {
        var name: String
        var text: String
    }
    struct Vector: Decodable {
        var id: String
        var area: String
        var what: String
        var ok: Bool
        var yaml: String
        var notes: [Problem]
        var problem: Problem?
        var defaults: [DefaultsFile]?
    }

    /// What can differ between a vector and Dozable.
    enum Difference: String, CaseIterable {
        /// A valid vector refused, or a refused one accepted.
        case verdict
        /// Refused, but not at the vector's path.
        case path
        /// Refused at the path, with other words.
        case message
        case hint
        case line
        /// Refused with a severity other than error, or with more problems than the vector's one (a valid vector: any).
        case problems
        /// A valid vector's notes are not exactly Dozable's.
        case notes
    }

    /// THE list: every vector (by id) and example (`example:NAME`) Dozable disagrees with, and how. Empty when the two
    /// agree on everything.
    static let knownDisagreements: [String: Set<Difference>] = [:]

    /// A vector or example the list says Dozable reaches another verdict on.
    static func verdictDiffers(_ id: String) -> Bool { knownDisagreements[id]?.contains(.verdict) == true }

    static let fixtures = Pins.packageRoot.appendingPathComponent("Tests/DozableCLITests/Fixtures/space31-reference")

    static func vectors() throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: Data(contentsOf: fixtures.appendingPathComponent("vectors-3.1.json")))
    }

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-space31-ref-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// What Dozable says of one vector: every problem (errors and warnings), the plan's refusals and notes when the file
    /// passes, and the exit code the CLI gives it.
    struct Verdict {
        var problems: [SpaceProblem]
        var refusals: [SpaceIntent.Refusal] = []
        var notes: [String] = []
        var exit: Int32
        var errors: [(pointer: String, message: String, hint: String?, line: Int?)] {
            problems.filter(\.isError).map { (pointer: $0.pointer, message: $0.message, hint: $0.hint, line: Optional($0.line)) }
                + refusals.filter { $0.code == "invalid" }.map { (pointer: $0.pointer, message: $0.message, hint: nil, line: nil) }
        }
    }

    func verdict(_ v: Vector) throws -> Verdict {
        let d = dir.appendingPathComponent(v.id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for f in v.defaults ?? [] { try Data(f.text.utf8).write(to: d.appendingPathComponent(f.name)) }
        try Data(v.yaml.utf8).write(to: d.appendingPathComponent("t.space.yaml"))
        var resolver = SpaceResolver()
        resolver.environment = [:]
        let r = resolver.resolve(d.appendingPathComponent("t.space.yaml").path)
        let (problems, model) = r.check()
        if problems.contains(where: \.isError) {
            return Verdict(problems: problems, exit: DozableExit.code(for: spaceDocumentError(problems)))
        }
        let model_ = try XCTUnwrap(model, v.id)
        let i = SpaceIntent.compile(model_, r.filled, r.locator)
        let invalid = i.refusals.filter { $0.code == "invalid" }
        let exit: Int32 = invalid.isEmpty ? 0 : DozableExit.code(for: HostError(.invalidDocument, invalid[0].message))
        return Verdict(problems: problems, refusals: i.refusals, notes: i.notes, exit: exit)
    }

    /// The plan's own notes of what this version does not apply yet: not the format's, never compared.
    static func isPlansOwn(_ note: String) -> Bool { note.hasSuffix("not applied in this version") }

    /// How Dozable differs from one vector (empty: they agree).
    func differences(_ v: Vector, _ got: Verdict) -> (Set<Difference>, String) {
        var diff = Set<Difference>()
        var said: [String] = []
        let errors = got.errors
        if v.ok {
            if got.exit != 0 || !errors.isEmpty {
                diff.insert(.verdict)
                said += errors.map { "refused \($0.pointer): \($0.message)" }
            } else if !got.problems.isEmpty {
                diff.insert(.problems)
                said += got.problems.map { "\($0.severity) \($0.pointer): \($0.message) | \($0.hint ?? "-")" }
            }
            let ours = got.notes.filter { !Self.isPlansOwn($0) }
            if ours != v.notes.map(\.message) {
                diff.insert(.notes)
                said += v.notes.map { "vector note: \($0.message)" } + ours.map { "our note: \($0)" }
            }
            return (diff, said.joined(separator: "\n"))
        }
        let want = v.problem!
        guard got.exit == DozableExit.invalid, !errors.isEmpty else {
            diff.insert(.verdict)
            said.append("accepted (exit \(got.exit)); notes: \(got.notes)")
            return (diff, said.joined(separator: "\n"))
        }
        let all = got.problems.map { (severity: $0.severity, pointer: $0.pointer, message: $0.message, hint: $0.hint, line: Optional($0.line)) }
            + got.refusals.filter { $0.code == "invalid" }.map { (severity: "error", pointer: $0.pointer, message: $0.message, hint: String?.none, line: Int?.none) }
        if all.count != 1 || all[0].severity != "error" {
            diff.insert(.problems)
            said += all.map { "\($0.severity) \($0.pointer): \($0.message) | \($0.hint ?? "-")" }
        }
        guard let p = all.first(where: { $0.pointer == want.path && $0.severity == "error" }) else {
            diff.insert(.path)
            said += all.map { "refused at \($0.pointer): \($0.message) | \($0.hint ?? "-")" }
            return (diff, said.joined(separator: "\n"))
        }
        if p.message != want.message { diff.insert(.message); said.append("message: \(p.message)") }
        if p.hint != want.hint { diff.insert(.hint); said.append("hint: \(p.hint ?? "-")") }
        if let l = want.line, p.line != l { diff.insert(.line); said.append("line: \(p.line.map(String.init) ?? "-")") }
        return (diff, said.joined(separator: "\n"))
    }

    func testEveryVectorThroughTheValidator() throws {
        let vs = try Self.vectors()
        XCTAssertEqual(vs.count, 51)
        XCTAssertEqual(vs.filter(\.ok).count, 15)
        XCTAssertEqual(Set(vs.map(\.id)).count, 51, "ids are unique")
        var found: [String: Set<Difference>] = [:]
        var report = ""
        for v in vs {
            let got = try verdict(v)
            let (d, said) = differences(v, got)
            if !d.isEmpty {
                found[v.id] = d
                report += "\(v.id) [\(d.map(\.rawValue).sorted().joined(separator: ","))] \(v.what)\n"
                if let p = v.problem { report += "  vector: \(p.path) line \(p.line.map(String.init) ?? "-"): \(p.message) | \(p.hint ?? "-")\n" }
                report += said.split(separator: "\n").map { "  dozable: \($0)\n" }.joined()
            }
        }
        let listed = Self.knownDisagreements.filter { !$0.key.hasPrefix("example:") }
        for id in listed.keys { XCTAssertTrue(vs.contains { $0.id == id }, "\(id) is no vector") }
        XCTAssertEqual(found, listed, "the disagreements are not the listed ones:\n" + report)
        // The agreeing vectors, counted.
        let agreed = vs.filter { found[$0.id] == nil }
        print("space/3.1 vectors: \(agreed.count) of \(vs.count) agree (\(agreed.filter(\.ok).count) valid, \(agreed.filter { !$0.ok }.count) refused)")
        if !report.isEmpty { print(report) }
    }

    /// Dozable's own answer to every vector, verbatim (the vectors are re-cut from it): with `DOZ_VECTOR_OUTPUTS=/tmp/FILE`
    /// it is written there as JSON; without it the test only checks it can be made.
    func testDozablesOutputsForEveryVector() throws {
        var rows: [JValue] = []
        for v in try Self.vectors() {
            let got = try verdict(v)
            func s(_ x: String?) -> JValue { x.map { .string($0) } ?? .null }
            let problems: [JValue] = got.problems.map { p in
                .object([JMember("severity", .string(p.severity)), JMember("path", .string(p.pointer)), JMember("message", .string(p.message)),
                         JMember("hint", s(p.hint)), JMember("file", .string(p.file)), JMember("line", .int(Int64(p.line)))])
            }
            let refusals: [JValue] = got.refusals.map { r in
                .object([JMember("path", .string(r.pointer)), JMember("message", .string(r.message)), JMember("code", .string(r.code))])
            }
            rows.append(.object([
                JMember("id", .string(v.id)), JMember("what", .string(v.what)), JMember("vectorOK", .bool(v.ok)),
                JMember("exit", .int(Int64(got.exit))), JMember("ok", .bool(got.exit == 0)),
                JMember("problems", .array(problems)), JMember("planRefusals", .array(refusals)),
                JMember("notes", .array(got.notes.map { .string($0) })),
            ]))
        }
        XCTAssertEqual(rows.count, 51)
        let doc: JValue = .object([JMember("about", .string("Dozable's answer to each space/3.1 vector: doz space config's check, then (for a file that passes) the plan's refusals and notes. exit 65 = an invalid document. problems are errors and warnings, each with its JSON path, file and line.")),
                                   JMember("vectors", .array(rows))])
        let out = String(decoding: ChatJSON.encodeIndented(doc, indent: "  "), as: UTF8.self) + "\n"
        if let path = ProcessInfo.processInfo.environment["DOZ_VECTOR_OUTPUTS"], path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") {
            try Data(out.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// The two rules the format's author asked about by name: an agent in a VM only repeats the VM's network (the
    /// workspace's, standard by default), and an adopted sandbox's agent takes neither `where` nor `restart`.
    func testTheTwoNamedRules() throws {
        let vs = try Self.vectors()
        func v(_ id: String) -> Vector { vs.first { $0.id == id }! }
        for id in ["V06", "V15", "E28", "E29", "E33", "E34"] {
            let want: Int32 = v(id).ok == Self.verdictDiffers(id) ? 65 : 0
            XCTAssertEqual(try verdict(v(id)).exit, want, "\(id) (listed: \(Self.knownDisagreements[id].map { "\($0)" } ?? "no"))")
        }
    }

    // MARK: the examples as space/3.1 files

    static let spaces = ["example-space", "sandbox-team", "clean-room"]

    /// A recorded output's stdout, and its exit code.
    static func recordedOutput(_ space: String, _ command: String) throws -> (stdout: String, exit: Int) {
        let t = try String(contentsOf: fixtures.appendingPathComponent("\(space)/\(command).txt"), encoding: .utf8)
        let stdout = t.components(separatedBy: "--- stdout\n")[1].components(separatedBy: "\n--- ")[0]
        let exit = Int(t.components(separatedBy: "--- exit ").last!.trimmingCharacters(in: .whitespacesAndNewlines))!
        return (stdout, exit)
    }

    func testTheMergedValuesAreTheRecordedConfig() throws {
        for s in Self.spaces {
            let (out, exit) = try Self.recordedOutput(s, "config")
            XCTAssertEqual(exit, 0)
            let body = out.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            let (want, _, problems) = SpaceResolver.parse(body, name: "config.txt")
            XCTAssertEqual(problems, [])
            let r = SpaceResolver().resolve(Self.fixtures.appendingPathComponent("spaces/\(s).space.yaml").path)
            XCTAssertEqual(r.merged, want, s)
            XCTAssertEqual(r.check().problems.contains(where: \.isError), Self.verdictDiffers("example:\(s)"),
                           "\(s) (listed: \(Self.verdictDiffers("example:\(s)"))): \(r.check().problems.map(\.text))")
            let wantRisky = out.split(separator: "\n").filter { $0.hasPrefix("#   ") && $0.contains(": ") && !$0.contains("sha256") }
                .map { String($0.dropFirst(4)) }
            XCTAssertEqual(r.check().model?.risks.map(\.line), wantRisky, s)
            let shas = out.split(separator: "\n").filter { $0.contains("sha256 ") }.map { String($0.split(separator: " ").last!.dropLast()) }
            XCTAssertEqual(r.sources.map { String($0.sha256.prefix(16)) }, shas, s)
        }
    }

    /// The plan's facts against the recorded plan: the same resources, external or owned, and their lifetimes; every
    /// FILE:LINE its summary names. Compared as facts, never bytes: the wording is Dozable's.
    func testThePlansHaveTheRecordedResourcesAndSources() throws {
        let home = NSHomeDirectory()
        for s in Self.spaces {
            let (out, exit) = try Self.recordedOutput(s, "plan")
            XCTAssertEqual(exit, 0, s)
            let r = SpaceResolver().resolve(Self.fixtures.appendingPathComponent("spaces/\(s).space.yaml").path)
            let (problems, model) = r.check()
            XCTAssertEqual(problems.contains(where: \.isError), Self.verdictDiffers("example:\(s)"), "\(s): \(problems.map(\.text))")
            if Self.verdictDiffers("example:\(s)") { continue }
            let doc = r.filled
            let intent = SpaceIntent.compile(try XCTUnwrap(model), doc, r.locator)
            var theirs = Set<String>()
            let re = try NSRegularExpression(pattern: "\\[(check|agent|room|sandbox|folder):([a-z0-9-]+) · (external|run|space)\\]")
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
                let g = { (i: Int) in String(out[Range(m.range(at: i), in: out)!]) }
                theirs.insert("\(g(1)):\(g(2)) \(g(3) == "space" ? "persisted" : g(3))")
            }
            var ours = Set<String>()
            for x in intent.folders { ours.insert(x.path != nil ? "check:\(x.name) external" : "folder:\(x.name) \(x.persisted == nil ? "run" : "persisted")") }
            for a in intent.agents { ours.insert(a.external ? "check:\(a.name) external" : "agent:\(a.name) run") }
            for x in intent.rooms { ours.insert(x.external ? "check:\(x.name) external" : "room:\(x.name) \(x.persisted == nil ? "run" : "persisted")") }
            for x in intent.sandboxes { ours.insert(x.external ? "check:\(x.name) external" : "sandbox:\(x.name) \(x.persisted == nil ? "run" : "persisted")") }
            XCTAssertEqual(ours, theirs, s)
            var f = SpaceFacts(known: true, home: home, projectsDir: home + "/doz-workspaces", owner: "ada", chatOn: true)
            f.bots["manager"] = .init(exists: true)
            f.rooms = ["general"]
            f.folders[home + "/work/example-repo"] = true
            let plan = SpaceUp.plan(intent, facts: f, specSHA: SpaceDoc.sha256(SpaceDoc.text(doc)), sources: r.sources)
            let summary = plan.summary.joined(separator: "\n")
            let lre = try NSRegularExpression(pattern: "[a-z_.-]+\\.yaml:[0-9]+")
            let theirLines = Set(lre.matches(in: out, range: NSRange(out.startIndex..., in: out)).map { String(out[Range($0.range, in: out)!]) })
            let ourLines = Set(lre.matches(in: summary, range: NSRange(summary.startIndex..., in: summary)).map { String(summary[Range($0.range, in: summary)!]) })
            XCTAssertTrue(theirLines.isSubset(of: ourLines), "\(s): \(theirLines.subtracting(ourLines)) missing from\n\(summary)")
        }
    }

    /// The PIN names the reference's commit and every vendored file's sha256.
    func testThePinCoversEveryVendoredFile() throws {
        let root = Self.fixtures
        let pin = try String(contentsOf: root.appendingPathComponent("PIN"), encoding: .utf8)
        XCTAssertTrue(pin.contains("peer-commit 87848a9943d89e950a00ce3a9ee2eb94dd8ca195"))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent != "PIN" }
        XCTAssertEqual(files.count, 11)
        for f in files {
            let rel = "./" + f.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
            let sha = SpaceDoc.sha256(try String(contentsOf: f, encoding: .utf8))
            XCTAssertTrue(pin.contains("\(sha)  \(rel)"), "\(rel) changed since it was pinned")
        }
    }
}
