import CryptoKit
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableKit

/// The recipe catalogue: its format and signature, what a build may use, the merge, the built-in three, a catalogue
/// refused whole, the statistics filter, the choice at a process's start and the host's refresh — with a THROWAWAY key
/// and scratch folders only.
final class RecipeCatalogueTests: XCTestCase {
    static let dozVersion = "0.37.24"
    let key = Curve25519.Signing.PrivateKey()
    var pub: Data { key.publicKey.rawRepresentation }
    var scratch: URL!

    override func setUpWithError() throws {
        RecipeCatalogue.resetForTests()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("doz-recipe-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        RecipeCatalogue.resetForTests()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - fixtures

    static var recipesDir: URL {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { break }
        }
        return u.appendingPathComponent("Sources/DozableKit/Recipes")
    }

    /// A catalogue's files as the publisher writes them: the tree's compiled data, less the built-in three.
    static func treeFiles() throws -> [String: Data] {
        let d = recipesDir
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent("compiled").path) where name.hasSuffix(".json") {
            if ["claude-code.json", "pi.json", "codex.json"].contains(name) { continue }
            out["agents/" + name] = try Data(contentsOf: d.appendingPathComponent("compiled/" + name))
        }
        for name in ["providers.json", "gateways.json", "tags.json", "known.json"] { out[name] = try Data(contentsOf: d.appendingPathComponent(name)) }
        for name in try FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent("icons").path) where name.hasSuffix(".json") || name.hasSuffix(".svg") {
            out["icons/" + name] = try Data(contentsOf: d.appendingPathComponent("icons/" + name))
        }
        return out
    }

    static func edit(_ files: inout [String: Data], _ path: String, _ f: (inout [String: Any]) -> Void) throws {
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files[path])) as? [String: Any])
        f(&o)
        files[path] = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// A recipe document copied from the tree's `from`, as a NEW recipe `product` (its own model permission).
    static func newRecipe(from: String, product: String, title: String) throws -> Data {
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recipesDir.appendingPathComponent("compiled/\(from).json"))) as? [String: Any])
        let vendor = (o["id"] as! String).split(separator: "/")[0]
        o["id"] = "\(vendor)/\(product)"
        o["displayName"] = title
        o["provides"] = ["com.dozable/\(product)@${{ kit.args.version }}"]
        var caps = o["capabilities"] as! [[String: Any]]
        for i in caps.indices where caps[i]["type"] as? String == "com.docker.sandbox/network-policy@1" {
            var c = caps[i]["config"] as! [String: Any], dz = c["dozable"] as! [String: Any], m = dz["model"] as! [String: Any]
            m["id"] = "model:\(product)"
            dz["model"] = m; c["dozable"] = dz; caps[i]["config"] = c
        }
        o["capabilities"] = caps
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    func manifest(_ files: [String: Data], serial: Int = 1, minimumDoz: String = "0.37.0", sourceVersion: String = dozVersion,
                  signWith: Curve25519.Signing.PrivateKey? = nil) throws -> RecipeCatalogueManifest {
        var m = RecipeCatalogueManifest(serial: serial, date: "2026-10-26T12:00:00Z", minimumDoz: minimumDoz, sourceVersion: sourceVersion,
                                        files: files.keys.sorted().map { RecipeCatalogueManifest.File(path: $0, sha256: RecipeCatalogueManifest.sha256(files[$0]!), size: files[$0]!.count) })
        m.signature = try (signWith ?? key).signature(for: m.message).base64EncodedString()
        return m
    }

    // MARK: - format and signature

    func testTheMessageIsDomainSeparatedByteForByte() throws {
        let m = RecipeCatalogueManifest(serial: 3, date: "2026-10-26T12:00:00Z", minimumDoz: "0.37.24", sourceVersion: "0.37.25",
                                        files: [.init(path: "agents/grok.json", sha256: String(repeating: "a", count: 64), size: 10)])
        XCTAssertEqual(String(decoding: m.message, as: UTF8.self), """
        dozable-recipe-catalogue-v1
        format: 1
        product: doz-recipes
        serial: 3
        date: 2026-10-26T12:00:00Z
        minimum_doz: 0.37.24
        source_version: 0.37.25
        base: recipes/3/
        file: agents/grok.json \(String(repeating: "a", count: 64)) 10

        """)
        // The manifest round-trips through its strict decoder; an unknown field is refused (a newer doz reads it).
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        XCTAssertEqual(try RecipeCatalogueManifest.decode(JSONSerialization.data(withJSONObject: o)), m)
        o["future"] = 1
        XCTAssertThrowsError(try RecipeCatalogueManifest.decode(JSONSerialization.data(withJSONObject: o)))
    }

    func testTheSignature() throws {
        let files = try Self.treeFiles()
        let m = try manifest(files)
        XCTAssertTrue(m.verify(publicKey: pub), "signed with the key")
        XCTAssertNil(m.filesProblem(files))
        XCTAssertFalse(m.verify(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation), "another key")
        var t = m
        t.minimumDoz = "0.1.0"
        XCTAssertFalse(t.verify(publicKey: pub), "a manifest field changed after signing")
        t = m
        t.files[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertFalse(t.verify(publicKey: pub), "a file's digest changed after signing")
        var tampered = files
        tampered["agents/grok.json"]!.append(contentsOf: Data(" ".utf8))
        XCTAssertNotNil(m.filesProblem(tampered), "a file changed")
        XCTAssertThrowsError(try RecipeCatalogue.adopt(m, files: tampered))
        XCTAssertTrue(RecipeCatalogue.source.isEmbedded)

        // A feed entry's signature never verifies as a catalogue's, and the other way round (domain separation).
        var entry = UpdateEntry(version: "0.37.24", build: 1, channel: "stable", archive: "https://example.com/doz.tar.gz",
                                size: 10, sha256: String(repeating: "b", count: 64), signature: "")
        entry.signature = try key.signature(for: UpdateSignature.message(entry)).base64EncodedString()
        XCTAssertTrue(UpdateSignature.verify(entry, publicKey: pub))
        var replay = m
        replay.signature = entry.signature
        XCTAssertFalse(replay.verify(publicKey: pub), "a feed entry's signature replayed as a catalogue's")
        var back = entry
        back.signature = m.signature
        XCTAssertFalse(UpdateSignature.verify(back, publicKey: pub), "a catalogue's signature replayed as a feed entry's")
    }

    func testWhatThisBuildMayUse() throws {
        let files = try Self.treeFiles()
        XCTAssertNil(RecipeCatalogueSelection.problem(try manifest(files), key: pub, version: Self.dozVersion))
        XCTAssertEqual(RecipeCatalogueSelection.problem(try manifest(files, minimumDoz: "0.38.0"), key: pub, version: Self.dozVersion),
                       "it needs doz 0.38.0 or later (this is 0.37.24)")
        XCTAssertNotNil(RecipeCatalogueSelection.problem(try manifest(files, sourceVersion: "0.37.23"), key: pub, version: Self.dozVersion),
                        "made from an older tree than this build: its own recipes are newer (the floor)")
        XCTAssertNil(RecipeCatalogueSelection.problem(try manifest(files, sourceVersion: "0.37.30"), key: pub, version: Self.dozVersion))
        XCTAssertEqual(RecipeCatalogueSelection.problem(try manifest(files, signWith: Curve25519.Signing.PrivateKey()), key: pub, version: Self.dozVersion),
                       "its signature does not verify")
        XCTAssertNotNil(RecipeCatalogueSelection.problem(try manifest(files), key: nil, version: Self.dozVersion))
        var shape = try manifest(files)
        shape.format = 2
        XCTAssertNotNil(RecipeCatalogueSelection.problem(shape, key: pub, version: Self.dozVersion), "a format this doz does not read")
    }

    // MARK: - the merge

    func testACopyOfTheEmbeddedSetIsUsedAndChangesNothing() throws {
        let embeddedIDs = AgentRecipes.all.map(\.id)
        let files = try Self.treeFiles()
        let src = try RecipeCatalogue.adopt(try manifest(files), files: files)
        XCTAssertEqual(src.kind, "catalogue")
        XCTAssertEqual(src.serial, 1)
        XCTAssertEqual(RecipeCatalogue.source, src)
        XCTAssertEqual(AgentRecipes.all.map(\.id), embeddedIDs)
        XCTAssertEqual(KeyProviders.all.map(\.id), RecipeSet.embedded.providers.providers.map(\.id))
        XCTAssertNoThrow(try RecipeCatalogue.validateActive())
        XCTAssertThrowsError(try RecipeCatalogue.adopt(try manifest(files), files: files), "chosen once")
    }

    func testACatalogueAddsAndUpdatesAndNeverRemoves() throws {
        var files = try Self.treeFiles()
        try Self.edit(&files, "agents/grok.json") { $0["description"] = "Grok, from the catalogue." }
        files["agents/llm2.json"] = try Self.newRecipe(from: "llm", product: "llm2", title: "LLM Two")
        files["agents/tgpt.json"] = nil                                   // left out: this build's stays
        try Self.edit(&files, "known.json") { o in
            var k = o["known"] as! [[String: Any]]
            k.append(["id": "llm2", "title": "LLM Two", "status": "coming", "reason": "a recipe has it now", "kind": "ai-tool", "categories": ["terminal-tool"]])
            o["known"] = k
        }
        try RecipeCatalogue.adopt(try manifest(files), files: files)
        XCTAssertEqual(AgentRecipes.recipe("grok")?.description, "Grok, from the catalogue.")
        XCTAssertEqual(AgentRecipes.recipe("llm2")?.title, "LLM Two")
        XCTAssertNotNil(AgentRecipes.recipe("tgpt"), "a recipe the catalogue leaves out is still this build's")
        XCTAssertEqual(AgentRecipes.all.last?.id, "llm2", "a new recipe comes after this build's, in path order")
        XCTAssertNotNil(AgentKind(rawValue: "llm2"))
        XCTAssertFalse(KnownThings.all.contains { $0.id == "llm2" }, "a known entry whose id a recipe has is dropped — the recipe wins")
        // Statistics: only ids THIS build lists — a catalogue-only recipe is counted nowhere.
        XCTAssertNil(UsageSchema.agent(image: "llm2"))
        XCTAssertEqual(UsageSchema.agent(image: "grok"), "grok")
        XCTAssertFalse(UsageSchema.agents.contains("llm2"))
    }

    func testTheBuiltInThreeAreNeverReplaced() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let before = try enc.encode(AgentRecipes.all.filter(\.isBuiltin))
        var files = try Self.treeFiles()
        for b in ["claude-code", "pi", "codex"] {
            var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.recipesDir.appendingPathComponent("compiled/\(b).json"))) as? [String: Any])
            doc["description"] = "replaced"
            files["agents/\(b).json"] = try JSONSerialization.data(withJSONObject: doc)
        }
        try RecipeCatalogue.adopt(try manifest(files), files: files)
        XCTAssertEqual(try enc.encode(AgentRecipes.all.filter(\.isBuiltin)), before, "a catalogue's copy of a built-in is ignored")
        XCTAssertEqual(AgentRecipes.all.filter(\.isBuiltin).map(\.id), ["claude-code", "pi", "codex"])

        // A catalogue that would ADD a built-in is refused whole.
        RecipeCatalogue.resetForTests()
        var more = try Self.treeFiles()
        more["agents/pi2.json"] = try Self.newRecipe(from: "pi", product: "pi2", title: "pi two")
        XCTAssertThrowsError(try RecipeCatalogue.adopt(try manifest(more), files: more))
        XCTAssertTrue(RecipeCatalogue.source.isEmbedded)
    }

    func testACatalogueFailingAnyCheckIsIgnoredWhole() throws {
        let grok = AgentRecipes.recipe("grok")?.description
        var files = try Self.treeFiles()
        try Self.edit(&files, "agents/grok.json") { $0["description"] = "not applied" }
        try Self.edit(&files, "gateways.json") { o in
            var g = o["gateways"] as! [[String: Any]]
            g[0]["keys_page"] = "http://insecure.example"                // Gateways.validate refuses it
            o["gateways"] = g
        }
        XCTAssertThrowsError(try RecipeCatalogue.adopt(try manifest(files), files: files)) { e in
            XCTAssertTrue(RecipeCatalogue.reason(e).contains("https"), RecipeCatalogue.reason(e))
        }
        XCTAssertTrue(RecipeCatalogue.source.isEmbedded)
        XCTAssertEqual(AgentRecipes.recipe("grok")?.description, grok, "nothing of it applied")
        XCTAssertNoThrow(try RecipeCatalogue.validateActive())

        // A field this build does not know: refused (a newer doz reads it), never guessed at.
        var future = try Self.treeFiles()
        try Self.edit(&future, "providers.json") { $0["future"] = true }
        XCTAssertThrowsError(try RecipeCatalogue.adopt(try manifest(future), files: future)) { e in
            XCTAssertTrue(RecipeCatalogue.reason(e).contains("newer doz"), RecipeCatalogue.reason(e))
        }
        // A recipe that does not decode refuses it whole too.
        var broken = try Self.treeFiles()
        try Self.edit(&broken, "agents/grok.json") { $0["schema"] = 99 }
        XCTAssertThrowsError(try RecipeCatalogue.adopt(try manifest(broken), files: broken))
        XCTAssertTrue(RecipeCatalogue.source.isEmbedded)
    }

    // MARK: - the choice at a process's start

    func env(seam: String? = "offline") -> [String: String] {
        var e = ["XDG_CONFIG_HOME": scratch.appendingPathComponent("xdg").path, "DOZ_TEST_UPDATE_KEY": pub.base64EncodedString()]
        if let seam { e["DOZ_TEST_RECIPE_CATALOGUE"] = seam }
        return e
    }

    /// Put a catalogue in the cache as `current.json` or `next.json`.
    func cache(_ files: [String: Data], _ m: RecipeCatalogueManifest, as name: String) throws {
        let c = try XCTUnwrap(RecipeCatalogueCache.at(env()))
        for (p, d) in files {
            let u = c.filesDir(serial: m.serial).appendingPathComponent(p)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
        }
        try FileManager.default.createDirectory(at: c.dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: c.dir.appendingPathComponent(name))
    }

    func testAGuardedRunWithoutItsSeamAndADevelopmentBuildUseTheirOwnRecipes() throws {
        let files = try Self.treeFiles()
        try cache(files, try manifest(files), as: "current.json")
        let a = RecipeCatalogueSelection.choose(args: ["ls"], version: Self.dozVersion, executable: "/x/doz", env: env(seam: nil), guarded: true)
        XCTAssertTrue(a.source.isEmbedded)
        XCTAssertEqual(a.notLooked, "a test run (no DOZ_TEST_RECIPE_CATALOGUE)")
        let b = RecipeCatalogueSelection.choose(args: ["ls"], version: Self.dozVersion, executable: "/x/doz", env: env(seam: nil), guarded: false)
        XCTAssertTrue(b.source.isEmbedded)
        XCTAssertEqual(b.notLooked, "a development build (its own recipes)")
        XCTAssertTrue(RecipeCatalogue.source.isEmbedded)
    }

    func testACommandUsesTheCurrentCatalogueAndOnlyTheHostsStartPromotesTheNext() throws {
        var files = try Self.treeFiles()
        try cache(files, try manifest(files, serial: 1), as: "current.json")
        try Self.edit(&files, "agents/grok.json") { $0["description"] = "two" }
        try cache(files, try manifest(files, serial: 2), as: "next.json")
        let c = try XCTUnwrap(RecipeCatalogueCache.at(env()))

        let cli = RecipeCatalogueSelection.choose(args: ["search", "grok"], version: Self.dozVersion, executable: "/x/doz", env: env(), guarded: true)
        XCTAssertEqual(cli.source.serial, 1, "a command uses what the running host uses")
        XCTAssertNotEqual(AgentRecipes.recipe("grok")?.description, "two")
        XCTAssertNotNil(c.next, "a command never promotes")

        RecipeCatalogue.resetForTests()
        let host = RecipeCatalogueSelection.choose(args: ["host", "start", "--foreground", "--launched"], version: Self.dozVersion,
                                                   executable: "/x/doz", env: env(), guarded: true)
        XCTAssertEqual(host.source.serial, 2)
        XCTAssertTrue(host.promoted)
        XCTAssertEqual(AgentRecipes.recipe("grok")?.description, "two")
        XCTAssertNil(c.next)
        XCTAssertEqual(c.current?.serial, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.filesDir(serial: 1).path), "the older files are pruned")
    }

    func testARefusedNextIsSaidOnceAndTheCurrentStays() throws {
        var files = try Self.treeFiles()
        try cache(files, try manifest(files, serial: 1), as: "current.json")
        try Self.edit(&files, "gateways.json") { o in
            var g = o["gateways"] as! [[String: Any]]
            g[0]["keys_page"] = "http://insecure.example"
            o["gateways"] = g
        }
        let bad = try manifest(files, serial: 2)
        try cache(files, bad, as: "next.json")
        let host = RecipeCatalogueSelection.choose(args: ["host", "--foreground"], version: Self.dozVersion, executable: "/x/doz", env: env(), guarded: true)
        XCTAssertEqual(host.source.serial, 1, "the refused next leaves the current in use")
        XCTAssertTrue(host.reportNow)
        XCTAssertTrue(host.problem?.hasPrefix("the recipe catalogue 2 was ignored:") == true, host.problem ?? "")
        let c = try XCTUnwrap(RecipeCatalogueCache.at(env()))
        XCTAssertNil(c.next)
        XCTAssertEqual(c.state.refusedSerials, [2])
        XCTAssertTrue(RecipeCatalogueSelection.describe(version: Self.dozVersion, env: env()).contains("last problem: the recipe catalogue 2 was ignored"))

        // The same one again: not tried, not said again.
        RecipeCatalogue.resetForTests()
        try cache(files, bad, as: "next.json")
        let same = RecipeCatalogueSelection.choose(args: ["host", "--foreground"], version: Self.dozVersion, executable: "/x/doz", env: env(), guarded: true)
        XCTAssertEqual(same.source.serial, 1)
        XCTAssertFalse(same.reportNow, "the same catalogue is not said twice")
        XCTAssertNil(same.problem)

        // A lower serial than the one in use never becomes current.
        RecipeCatalogue.resetForTests()
        let ok = try Self.treeFiles()
        try cache(ok, try manifest(ok, serial: 1), as: "next.json")
        let again = RecipeCatalogueSelection.choose(args: ["host", "--foreground"], version: Self.dozVersion, executable: "/x/doz", env: env(), guarded: true)
        XCTAssertEqual(again.source.serial, 1)
        XCTAssertFalse(again.promoted)
        XCTAssertTrue(again.problem?.contains("is not newer than 1") == true, again.problem ?? "")
    }

    func testAfterAnUpgradeAnOlderCatalogueIsPassedOverQuietly() throws {
        let files = try Self.treeFiles()
        try cache(files, try manifest(files, serial: 1, minimumDoz: "0.37.24", sourceVersion: "0.37.24"), as: "current.json")
        let newer = RecipeCatalogueSelection.choose(args: ["ls"], version: "0.37.25", executable: "/x/doz", env: env(), guarded: true)
        XCTAssertTrue(newer.source.isEmbedded, "a build never uses recipes older than its own")
        XCTAssertNil(newer.problem, "nothing wrong to say")
        XCTAssertFalse(newer.reportNow)
        RecipeCatalogue.resetForTests()
        let older = RecipeCatalogueSelection.choose(args: ["ls"], version: "0.37.20", executable: "/x/doz", env: env(), guarded: true)
        XCTAssertTrue(older.source.isEmbedded, "a doz older than its minimum keeps its own")
        XCTAssertNil(older.problem)
    }

    func testTheSeamsOwnFileIsUsedDirectly() throws {
        var files = try Self.treeFiles()
        try Self.edit(&files, "agents/grok.json") { $0["description"] = "from a site" }
        let m = try manifest(files, serial: 7)
        let site = scratch.appendingPathComponent("site/v1")
        for (p, d) in files {
            let u = site.appendingPathComponent("recipes/7/" + p)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
        }
        try JSONEncoder().encode(m).write(to: site.appendingPathComponent("recipes.json"))
        let c = RecipeCatalogueSelection.choose(args: ["ls"], version: Self.dozVersion, executable: "/x/doz",
                                                env: env(seam: site.appendingPathComponent("recipes.json").path), guarded: true)
        XCTAssertEqual(c.source.serial, 7)
        XCTAssertEqual(AgentRecipes.recipe("grok")?.description, "from a site")
    }

    // MARK: - the host's refresh

    final class FakeSite: @unchecked Sendable {
        var files: [String: Data] = [:]
        var status = 200
        var requests: [URLRequest] = []
        var down = false
        let lock = NSLock()
        func fetch(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try lock.withLock {
                requests.append(r)
                if down { throw URLError(.notConnectedToInternet) }
                let path = r.url!.path
                let st = path.hasSuffix("/recipes.json") ? status : (files[path] == nil ? 404 : 200)
                return (files[path] ?? Data(), HTTPURLResponse(url: r.url!, statusCode: st, httpVersion: nil, headerFields: ["ETag": "\"e1\""])!)
            }
        }
    }

    func site(_ files: [String: Data], _ m: RecipeCatalogueManifest) throws -> FakeSite {
        let s = FakeSite()
        s.files["/v1/recipes.json"] = try JSONEncoder().encode(m)
        for (p, d) in files { s.files["/v1/recipes/\(m.serial)/\(p)"] = d }
        return s
    }

    func testTheRefresh() async throws {
        let files = try Self.treeFiles()
        let s = try site(files, try manifest(files, serial: 4))
        let e = env(seam: "http://127.0.0.1:9/v1/recipes.json")
        let c = try XCTUnwrap(RecipeCatalogueCache.at(e))
        let now = Date()

        s.status = 404
        var out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: e, guarded: true, now: now, fetch: s.fetch)
        XCTAssertEqual(out, .unchanged, "nothing published: the embedded set stays")
        XCTAssertNil(c.next)
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: e, guarded: true, now: now.addingTimeInterval(60), fetch: s.fetch)
        XCTAssertEqual(out, .notDue, "at most hourly")

        s.status = 200
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: e, guarded: true, now: now.addingTimeInterval(3601), fetch: s.fetch)
        XCTAssertEqual(out, .downloaded(serial: 4))
        XCTAssertEqual(c.next?.serial, 4)
        XCTAssertNotNil(RecipeCatalogueCache.readFiles(try XCTUnwrap(c.next), from: c.filesDir(serial: 4)))
        XCTAssertEqual(c.state.etag, "\"e1\"")

        // The next look is conditional; the same serial again is nothing new.
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: e, guarded: true, now: now.addingTimeInterval(7300), fetch: s.fetch)
        XCTAssertEqual(out, .unchanged)
        XCTAssertEqual(s.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"e1\"")

        // Offline: silent.
        s.down = true
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: e, guarded: true, now: now.addingTimeInterval(11000), fetch: s.fetch)
        XCTAssertEqual(out, .offline)
    }

    func testARefreshNeverKeepsATamperedFile() async throws {
        let files = try Self.treeFiles()
        let s = try site(files, try manifest(files, serial: 5))
        s.files["/v1/recipes/5/agents/grok.json"]!.append(contentsOf: Data(" ".utf8))
        let e = env(seam: "http://127.0.0.1:9/v1/recipes.json")
        let out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: e, guarded: true, fetch: s.fetch)
        guard case .refused(let why, let reportNow) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(why.contains("does not match its sha256"), why)
        XCTAssertTrue(reportNow)
        let c = try XCTUnwrap(RecipeCatalogueCache.at(e))
        XCTAssertNil(c.next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.filesDir(serial: 5).path))
    }

    func testARefreshIsNeverMadeWithoutItsSeamInATestRunOrByADevelopmentBuild() async {
        let s = FakeSite()
        var out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: env(seam: nil), guarded: true, fetch: s.fetch)
        XCTAssertEqual(out, .disabled("not in a test run (no DOZ_TEST_RECIPE_CATALOGUE)"))
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: env(seam: nil), guarded: false, fetch: s.fetch)
        XCTAssertEqual(out, .disabled("a development build uses its own recipes"))
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: env(seam: "offline"), guarded: true, fetch: s.fetch)
        XCTAssertEqual(out, .disabled("DOZ_TEST_RECIPE_CATALOGUE=offline"))
        out = await RecipeCatalogueRefresh.refresh(version: Self.dozVersion, executable: "/x/doz", env: env(seam: "http://example.com/v1/recipes.json"), guarded: true, fetch: s.fetch)
        XCTAssertEqual(out, .disabled("a test catalogue over http only from 127.0.0.1"))
        XCTAssertTrue(s.requests.isEmpty, "nothing asked")
        XCTAssertEqual(URL(string: Distribution.recipeCatalogueURL)?.deletingLastPathComponent().absoluteString,
                       URL(string: Distribution.feedURL)?.deletingLastPathComponent().absoluteString, "beside the update feed")
    }
}
