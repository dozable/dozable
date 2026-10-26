import CryptoKit
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableKit

/// 653: recipes that are not Dozable's — the community requirements item by item, adopting them (whole or not at all,
/// Dozable's ids never taken), pinned-only, never counted, the community manifest, the snapshot a host start chooses, and
/// the stand-in provider of the full check. Scratch folders and THROWAWAY keys only.
final class CommunityRecipesTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        RecipeCatalogue.resetForTests()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("doz-community-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        RecipeCatalogue.resetForTests()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - fixtures

    typealias Doc = [String: Any]

    /// A recipe of one's own: OpenCode's compiled document as `product`, what makes it Dozable's left out.
    static func good(_ product: String = "mytest", vendor: String = "local") throws -> Doc {
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: RecipeCatalogueTests.recipesDir.appendingPathComponent("compiled/opencode.json"))) as? Doc)
        o["id"] = "\(vendor)/\(product)"
        o["displayName"] = "My \(product)"
        o["provides"] = ["com.dozable/\(product)@${{ kit.args.version }}"]
        o["author"] = "Me"
        o["sourceUrl"] = "https://example.com/\(product)"
        var caps = (o["capabilities"] as! [Doc]).filter { $0["type"] as? String != "com.dozable/family@1" }
        for i in caps.indices {
            var c = caps[i]["config"] as? Doc ?? [:]
            switch caps[i]["type"] as? String {
            case "com.docker.sandbox/network-policy@1":
                var dz = c["dozable"] as! Doc, m = dz["model"] as! Doc
                m["id"] = "model:\(product)"
                dz["model"] = m; c["dozable"] = dz
            case "com.dozable/directory@1":
                c["icon"] = nil; c["published"] = nil; c["aliases"] = nil
            default: break
            }
            caps[i]["config"] = c
        }
        o["capabilities"] = caps
        return o
    }

    static func data(_ o: Doc) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    static func edit(_ o: inout Doc, _ type: String, _ f: (inout Doc) -> Void) {
        var caps = o["capabilities"] as! [Doc]
        for i in caps.indices where caps[i]["type"] as? String == type {
            var c = caps[i]["config"] as! Doc
            f(&c)
            caps[i]["config"] = c
        }
        o["capabilities"] = caps
    }

    func results(_ o: Doc) throws -> [String: CommunityRequirements.Result] {
        let (rs, _) = CommunityRequirements.check(try Self.data(o), others: AgentRecipes.all, dozableIDs: RecipeCatalogue.dozableNames)
        return Dictionary(uniqueKeysWithValues: rs.map { ($0.id, $0) })
    }

    // MARK: - the requirements

    func testAGoodRecipeMeetsEveryRequirement() throws {
        let r = try results(try Self.good())
        XCTAssertEqual(r.count, CommunityRequirements.items.count)
        for (id, x) in r { XCTAssertTrue(x.passed, "\(id): \(x.detail ?? "")") }
        XCTAssertEqual(CommunityRequirements.verdict(Array(r.values)), "meets the minimum requirements for a community recipe")
    }

    func testATodoToolsOwnWordsAreNotAPlaceholder() throws {
        var o = try Self.good()
        o["description"] = "A todo list your agent keeps — Todoist-style, in the terminal."
        XCTAssertEqual(try results(o)["about"]?.passed, true)
    }

    func testEachRequirementFailsForTheRecipeThatBreaksIt() throws {
        func failing(_ item: String, only: Bool = true, _ mutate: (inout Doc) -> Void) throws {
            var o = try Self.good()
            mutate(&o)
            let r = try results(o)
            XCTAssertEqual(r[item]?.passed, false, "\(item) should fail")
            XCTAssertNotNil(r[item]?.detail)
            if only { XCTAssertEqual(r.values.filter { !$0.passed }.map(\.id), [item], "only \(item) should fail") }
        }
        try failing("document", only: false) { $0["surprise"] = true }
        try failing("validators") { Self.edit(&$0, "com.dozable/install@1") { $0["bake_hosts"] = ["not a host"] } }
        try failing("not-dozable") { Self.edit(&$0, "com.dozable/directory@1") { $0["aliases"] = ["grok"] } }
        try failing("not-builtin", only: false) { Self.edit(&$0, "com.dozable/install@1") { $0["builtin"] = true } }
        try failing("about") { $0["author"] = "TODO who" }
        try failing("about") { $0["sourceUrl"] = "https://example.com/TODO" }
        try failing("plain-text") { $0["description"] = "A tool \u{1B}[31mred\u{1B}[0m." }
        try failing("plain-text") { $0["displayName"] = "Safe \u{202E}txt.exe" }
        try failing("plain-text") { $0["description"] = String(repeating: "long ", count: 70) }
        try failing("pinned", only: false) { Self.edit(&$0, "com.dozable/install@1") { $0["integrity"] = nil } }
        try failing("guide") { $0["capabilities"] = ($0["capabilities"] as! [Doc]).filter { $0["type"] as? String != "com.dozable/guide@1" } }
        try failing("no-credential") { Self.edit(&$0, "com.dozable/guide@1") { $0["tips"] = ["try sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"] } }
        try failing("no-credential", only: false) { Self.edit(&$0, "com.dozable/launch@1") { var e = $0["env"] as! Doc; e["MY_API_KEY"] = "x"; $0["env"] = e } }
        try failing("no-quiet") {
            Self.edit(&$0, "com.docker.sandbox/network-policy@1") {
                var dz = $0["dozable"] as! Doc
                dz["quiet"] = [["host": "telemetry.example.com", "reason": "its usage log"]]
                $0["dozable"] = dz
                var rt = $0["runtime"] as! Doc
                rt["deny"] = ["telemetry.example.com:443"]
                $0["runtime"] = rt
            }
        }
        try failing("reach-shown") {
            Self.edit(&$0, "com.docker.sandbox/network-policy@1") {
                var dz = $0["dozable"] as! Doc
                dz["vendor"] = [["host": "news.example.com", "reason": "its release notes"]]
                $0["dozable"] = dz
                var rt = $0["runtime"] as! Doc
                rt["allow"] = (rt["allow"] as! [String]) + ["news.example.com:443"]
                $0["runtime"] = rt
            }
        }
        try failing("no-mark") { Self.edit(&$0, "com.dozable/directory@1") { $0["icon"] = "opencode" } }
        try failing("no-family") {
            $0["capabilities"] = ($0["capabilities"] as! [Doc]) + [["type": "com.dozable/family@1",
                                                                     "config": ["family": "mytest", "major": 1, "title": "My 1", "recommended": true]]]
        }
    }

    func testEveryDozableRecipeIsFreeOfKeyShapedValues() throws {
        // The no-credential scan never mistakes Dozable's own data for a key (a copy with --from starts from it).
        for name in AgentRecipes.compiledFiles {
            let d = try Data(contentsOf: RecipeCatalogueTests.recipesDir.appendingPathComponent("compiled/\(name)"))
            XCTAssertNil(CommunityRequirements.keyShaped(d), name)
        }
    }

    // MARK: - adopting

    func source(_ origin: RecipeOrigin, _ docs: [Doc], published: Bool = true) throws -> RecipeCatalogue.ExtraSource {
        RecipeCatalogue.ExtraSource(origin: origin, name: origin.label ?? "?", documents: try docs.map { ("\(($0["id"] as! String)).json", try Self.data($0)) },
                                    published: published)
    }

    func testYoursIsAdoptedWithItsOriginAndPinnedOnly() throws {
        let out = RecipeCatalogue.adoptExtras([try source(.mine, [try Self.good()])])
        XCTAssertEqual(out.map(\.refused), [nil])
        let r = try XCTUnwrap(AgentRecipes.recipe("mytest"))
        XCTAssertEqual(r.origin, .mine)
        XCTAssertTrue(r.isPinnedOnly, "a recipe that is not Dozable's installs exactly its pin")
        XCTAssertFalse(try XCTUnwrap(AgentRecipes.recipe("opencode")).isPinnedOnly, "Dozable's npm recipe still follows latest")
        XCTAssertEqual(AgentIcons.resolve(r).kind, "generated", "a lettermark, never a maker's mark")
        XCTAssertEqual(DirectoryIndex.entry(for: r).origin?.label, "yours")
        XCTAssertNil(DirectoryIndex.entry(for: AgentRecipes.recipe("opencode")!).origin)
        XCTAssertNil(UsageSchema.agent(image: "mytest"), "never counted")
        XCTAssertTrue(UsageSchema.isNotDozable(image: "mytest"))
        XCTAssertFalse(UsageSchema.isNotDozable(image: "opencode"))
        XCTAssertEqual(PlanRecipe.of(r)?.label, "yours")
    }

    func testDozablesIDsAreNeverTaken() throws {
        var o = try Self.good("grok", vendor: "xai")
        Self.edit(&o, "com.docker.sandbox/network-policy@1") { _ in }
        let out = RecipeCatalogue.adoptExtras([try source(.mine, [o])])
        XCTAssertNotNil(out[0].refused)
        XCTAssertTrue(AgentRecipes.recipe("grok")?.origin.isDozable == true)
    }

    func testASecondSourceWithATakenIDIsRefusedWholeAndTheFirstStays() throws {
        let a = try source(.community("first"), [try Self.good("shared")])
        let b = try source(.community("second"), [try Self.good("other1"), try Self.good("shared")])
        let out = RecipeCatalogue.adoptExtras([a, b])
        XCTAssertNil(out[0].refused)
        XCTAssertNotNil(out[1].refused)
        XCTAssertTrue(out[1].refused!.contains("community · first"), out[1].refused!)
        XCTAssertEqual(AgentRecipes.recipe("shared")?.origin, .community("first"))
        XCTAssertNil(AgentRecipes.recipe("other1"), "the whole source is refused, not just the clash")
    }

    func testARefusedSourceCostsNoOther() throws {
        var bad = try Self.good("broken")
        bad["surprise"] = 1
        let out = RecipeCatalogue.adoptExtras([try source(.community("bad"), [bad]), try source(.mine, [try Self.good("fine")])])
        XCTAssertNotNil(out[0].refused)
        XCTAssertNil(out[1].refused)
        XCTAssertNotNil(AgentRecipes.recipe("fine"))
        XCTAssertNil(AgentRecipes.recipe("broken"))
    }

    func testAKeptRecipeIsUnpublishedButResolves() throws {
        _ = RecipeCatalogue.adoptExtras([try source(.community("gone"), [try Self.good("kept1")], published: false)])
        let r = try XCTUnwrap(AgentRecipes.recipe("kept1"))
        XCTAssertFalse(r.isPublished)
        XCTAssertFalse(AgentRecipes.published.contains { $0.id == "kept1" })
        XCTAssertEqual(ImageChoice.parse("kept1")?.agent.rawValue, "kept1", "a stored name still resolves")
    }

    // MARK: - the community manifest

    func testTheCommunityManifestIsItsOwnProductWithRecipesOnly() throws {
        let key = Curve25519.Signing.PrivateKey()
        let doc = try Self.data(try Self.good("cm"))
        var m = RecipeCatalogueManifest(product: RecipeCatalogueManifest.communityProductName, serial: 1, date: "2026-10-26T12:00:00Z",
                                        minimumDoz: "0.37.0", sourceVersion: "0.37.25",
                                        files: [.init(path: "agents/cm.json", sha256: RecipeCatalogueManifest.sha256(doc), size: doc.count)])
        m.signature = try key.signature(for: m.message).base64EncodedString()
        XCTAssertTrue(m.verify(publicKey: key.publicKey.rawRepresentation, community: true))
        XCTAssertFalse(m.verify(publicKey: key.publicKey.rawRepresentation), "never read as a Dozable catalogue")
        XCTAssertFalse(m.verify(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, community: true), "another key")
        var withData = m
        withData.files.append(.init(path: "providers.json", sha256: String(repeating: "0", count: 64), size: 2))
        XCTAssertThrowsError(try withData.check(community: true), "a community catalogue carries recipes only")
        var dozables = m
        dozables.product = RecipeCatalogueManifest.productName
        XCTAssertThrowsError(try dozables.check(community: true))
    }

    func testTheSourceKeyAndURLRules() {
        let k = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let fp = RecipeExtras.fingerprint(k)
        XCTAssertEqual(fp?.hasPrefix("SHA256:"), true)
        XCTAssertEqual(fp?.contains("="), false)
        XCTAssertNil(RecipeExtras.fingerprint("not a key"))
        XCTAssertNil(RecipeExtras.urlProblem("https://example.com/v1/recipes.json", guarded: false))
        XCTAssertNotNil(RecipeExtras.urlProblem("http://example.com/v1/recipes.json", guarded: false))
        XCTAssertNotNil(RecipeExtras.urlProblem("http://127.0.0.1:9/v1/recipes.json", guarded: false), "http only in a guarded run")
        XCTAssertNil(RecipeExtras.urlProblem("http://127.0.0.1:9/v1/recipes.json", guarded: true))
        XCTAssertEqual(RecipeExtras.defaultName("https://recipes.example.com/v1/recipes.json"), "recipes-example-com")
    }

    // MARK: - the snapshot

    func paths() -> RecipeExtrasPaths { RecipeExtrasPaths(dir: scratch.appendingPathComponent("recipes")) }

    /// The CLI's compiler stands in: the fixture files are JSON (JSON is YAML).
    let compile: (String) throws -> Data = { try RecipeSource.compile(yaml: $0) }

    func testTheSnapshotHoldsYoursAndRefusesAFileThatIsNotItsName() throws {
        let p = paths()
        try FileManager.default.createDirectory(at: p.mine, withIntermediateDirectories: true)
        try Self.data(try Self.good("snap1")).write(to: p.mine("snap1"))
        try Self.data(try Self.good("other2")).write(to: p.mine("wrongname"))
        let rb = RecipeExtras.rebuild(p, compile: compile, version: "0.37.25", promote: true, env: [:])
        XCTAssertEqual(rb.inUse.sources.map(\.name), ["yours: snap1.yaml"])
        XCTAssertEqual(rb.inUse.refused.map(\.name), ["yours: wrongname.yaml"])
        XCTAssertFalse(RecipeExtras.pending(p))
        let out = RecipeExtras.adopt(p)
        XCTAssertEqual(out.first?.ids, ["snap1"])
        // A change on disk waits for the next choice.
        try Self.data(try Self.good("snap3")).write(to: p.mine("snap3"))
        XCTAssertTrue(RecipeExtras.pending(p))
    }

    func testAKeptRecipeHoldsItsIDAgainstAnotherSource() throws {
        let p = paths()
        let doc = try Self.data(try Self.good("held"))
        RecipeExtras.keep(id: "held", origin: .community("gone"), document: doc, sha256: RecipeExtras.sha256(doc), p)
        // Another source offering "held" comes after the kept one, so it is refused at adoption.
        try writeCommunity(p, name: "newcomer", docs: ["held": doc])
        let rb = RecipeExtras.rebuild(p, compile: compile, version: "0.37.25", promote: true, env: [:])
        XCTAssertEqual(rb.inUse.sources.map(\.name), ["kept held", "community newcomer"])
        let out = RecipeExtras.adopt(p)
        XCTAssertNil(out[0].refused)
        XCTAssertNotNil(out[1].refused)
        XCTAssertEqual(AgentRecipes.recipe("held")?.origin, .community("gone"))
    }

    func testTheSameSourceBackTakesItsKeptRecipeAgain() throws {
        let p = paths()
        let doc = try Self.data(try Self.good("back"))
        RecipeExtras.keep(id: "back", origin: .community("src"), document: doc, sha256: RecipeExtras.sha256(doc), p)
        try writeCommunity(p, name: "src", docs: ["back": doc])
        let rb = RecipeExtras.rebuild(p, compile: compile, version: "0.37.25", promote: true, env: [:])
        XCTAssertEqual(rb.inUse.sources.map(\.name), ["community src"])
    }

    /// A confirmed source with a verified catalogue in its cache (as a refresh leaves it).
    func writeCommunity(_ p: RecipeExtrasPaths, name: String, docs: [String: Data]) throws {
        let key = Curve25519.Signing.PrivateKey()
        var files: [String: Data] = [:]
        for (id, d) in docs { files["agents/\(id).json"] = d }
        var m = RecipeCatalogueManifest(product: RecipeCatalogueManifest.communityProductName, serial: 1, date: "2026-10-26T12:00:00Z",
                                        minimumDoz: "0.37.0", sourceVersion: "0.37.25",
                                        files: files.keys.sorted().map { .init(path: $0, sha256: RecipeCatalogueManifest.sha256(files[$0]!), size: files[$0]!.count) })
        m.signature = try key.signature(for: m.message).base64EncodedString()
        let cache = p.community(name)
        for (path, d) in files {
            let u = cache.filesDir(serial: 1).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
        }
        try FileManager.default.createDirectory(at: cache.dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: cache.currentURL)
        var all = CommunitySources.load(p)
        let k = key.publicKey.rawRepresentation.base64EncodedString()
        all.sources.append(CommunitySource(name: name, url: "https://\(name).example.com/v1/recipes.json", key: k,
                                           fingerprint: RecipeExtras.fingerprint(k)!, confirmed: "2026-10-26T00:00:00Z", added: "2026-10-26T00:00:00Z"))
        XCTAssertTrue(all.save(p))
    }

    func testATamperedCommunityFileIsRefusedWhole() throws {
        let p = paths()
        try writeCommunity(p, name: "tamper", docs: ["t1": try Self.data(try Self.good("t1"))])
        let f = p.community("tamper").filesDir(serial: 1).appendingPathComponent("agents/t1.json")
        try (try Data(contentsOf: f) + Data(" ".utf8)).write(to: f)
        let rb = RecipeExtras.rebuild(p, compile: compile, version: "0.37.25", promote: true, env: [:])
        XCTAssertTrue(rb.inUse.sources.isEmpty)
        XCTAssertEqual(rb.inUse.refused.first?.name, "community tamper")
    }

    // MARK: - the trust record, the check record

    func testTrustIsByIDAndVersion() {
        let p = paths()
        XCTAssertFalse(RecipeExtras.isTrusted(id: "x", sha256: "a", p))
        XCTAssertTrue(RecipeExtras.trust(id: "x", sha256: "a", p))
        XCTAssertTrue(RecipeExtras.isTrusted(id: "x", sha256: "a", p))
        XCTAssertFalse(RecipeExtras.isTrusted(id: "x", sha256: "b", p), "another version is asked again")
        XCTAssertTrue(RecipeExtras.recordCheck(RecipeCheckRecord(id: "x", sha256: "a", level: "full", doz: "0.37.25", date: "d"), p))
        XCTAssertEqual(RecipeExtras.checks(p).map(\.level), ["full"])
    }

    // MARK: - doz recipe new --from

    func testACopyFromOpenCodeFailsOnlyOnWhatIsYoursToFillIn() throws {
        let yaml = try RecipeNew.copy(try XCTUnwrap(AgentRecipes.recipe("opencode")), as: "copytest")
        let data = try RecipeSource.compile(yaml: yaml)
        let (rs, r) = CommunityRequirements.check(data, others: AgentRecipes.all, dozableIDs: RecipeCatalogue.dozableNames)
        XCTAssertEqual(rs.filter { !$0.passed }.map(\.id), ["about"])
        XCTAssertEqual(r?.network.model.id, "model:copytest")
        let scaffold = try RecipeSource.compile(yaml: RecipeNew.scaffold("scaff"))
        let (s, _) = CommunityRequirements.check(scaffold, others: AgentRecipes.all, dozableIDs: RecipeCatalogue.dozableNames)
        XCTAssertTrue(s.first { $0.id == "document" }!.passed, "the scaffold reads")
        XCTAssertFalse(s.allSatisfy(\.passed), "and fails until it is filled in")
    }

    // MARK: - the stand-in provider

    func testTheStandInAnswersOnlyTheFakeKeyOverTLS() throws {
        let s = try StandInProvider()
        defer { s.stop() }
        let ca = scratch.appendingPathComponent("ca.pem")
        try s.caPEM.write(to: ca, atomically: true, encoding: .utf8)
        func curl(_ host: String, _ path: String, _ header: String, _ body: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "--cacert", ca.path, "--resolve", "\(host):\(s.port):127.0.0.1", "-H", header, "-H", "content-type: application/json",
                           "-d", body, "-w", " %{http_code}", "https://\(host):\(s.port)\(path)"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let xai = StandInProvider.fakeKeys["xai"]!, anth = StandInProvider.fakeKeys["anthropic"]!
        let chat = try curl("api.x.ai", "/v1/chat/completions", "Authorization: Bearer \(xai)", #"{"model":"m","messages":[]}"#)
        XCTAssertTrue(chat.contains("DOZ_FAKE_OK") && chat.hasSuffix(" 200"), chat)
        let stream = try curl("api.x.ai", "/v1/responses", "Authorization: Bearer \(xai)", #"{"model":"m","stream":true}"#)
        XCTAssertTrue(stream.contains("response.completed") && stream.contains("DOZ_FAKE_OK"), stream)
        let msg = try curl("api.anthropic.com", "/v1/messages", "x-api-key: \(anth)", #"{"model":"c","stream":true}"#)
        XCTAssertTrue(msg.contains("message_stop") && msg.contains("DOZ_FAKE_OK"), msg)
        let refused = try curl("api.x.ai", "/v1/chat/completions", "Authorization: Bearer doz_cred_placeholder", #"{"model":"m"}"#)
        XCTAssertTrue(refused.hasSuffix(" 401") && !refused.contains("DOZ_FAKE_OK"), refused)
        XCTAssertEqual(s.requests.count, 4)
        XCTAssertEqual(s.requests.last?.auth["authorization"], "Bearer doz_cred_placeholder")
    }
}
