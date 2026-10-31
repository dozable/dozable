import XCTest
@testable import DozableKit

/// 654 (617.B5): `[SOURCE/]VENDOR/PRODUCT[@MAJOR|@VERSION]` — a tool named with its vendor and, optionally, whose recipe it
/// is (AgentRef.swift). Every accepted form, every refusal in its own words, and the old forms unchanged.
final class QualifiedNameTests: XCTestCase {
    override func setUp() { super.setUp(); AgentRecipes.publishEverythingForTests(true) }
    override func tearDown() { AgentRecipes.publishEverythingForTests(false); super.tearDown() }
    func ref(_ s: String, in recipes: [AgentRecipe] = AgentRecipes.all) throws -> AgentRef { try XCTUnwrap(try AgentRef.resolveAny(s, in: recipes)) }

    /// The refusal's words (fails the test when `s` resolves).
    func refusal(_ s: String, in recipes: [AgentRecipe] = AgentRecipes.all, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            let r = try AgentRef.resolveAny(s, in: recipes)
            XCTFail("\(s) resolved to \(r?.recipe.id ?? "nothing") — expected a refusal", file: file, line: line)
            return ""
        } catch let p as AgentRef.Problem {
            return p.description
        } catch {
            XCTFail("\(s): \(error)", file: file, line: line)
            return ""
        }
    }

    /// Dozable's recipes plus one of yours (`acme/tool`) and one of a community source's (`hub/acme/tool2`).
    func withExtras() throws -> [AgentRecipe] {
        var mine = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        mine.id = "tool"; mine.aliases = nil; mine.origin = .mine; mine.vendor = "acme"; mine.family = nil
        var community = mine
        community.id = "tool2"; community.origin = .community("hub")
        return AgentRecipes.all + [mine, community]
    }

    // MARK: the data

    func testEveryRecipeHasItsFilesVendor() throws {
        XCTAssertEqual(AgentRecipes.recipe("claude-code")?.vendor, "anthropic")
        XCTAssertEqual(AgentRecipes.recipe("pi")?.vendor, "earendil-works")
        XCTAssertEqual(AgentRecipes.recipe("codex")?.vendor, "openai")
        XCTAssertEqual(AgentRecipes.recipe("opencode")?.vendor, "anomalyco")
        XCTAssertEqual(AgentRecipes.recipe("opencode2")?.vendor, "anomalyco")
        for r in AgentRecipes.all {
            let v = try XCTUnwrap(r.vendor, "\(r.id) has no vendor")
            XCTAssertTrue(AgentRef.isVendor(v), "\(r.id): \(v)")
        }
    }

    func testTheVendorIsNotACodingKey() throws {
        // The recipe's JSON (and so every bake key built from it) is what it was: no `vendor` key.
        let r = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(r)) as? [String: Any]
        XCTAssertNil(json?["vendor"])
        XCTAssertEqual(RecipeDocument(r, vendor: "anthropic", licenses: ["MIT"]).vendor, "anthropic")
    }

    func testEveryQualifiedNameMeansItsRecipe() throws {
        for r in AgentRecipes.all {
            let q = AgentRef.qualifiedName(r)
            XCTAssertEqual(try ref(q).recipe.id, r.id, q)
            XCTAssertEqual(try ref("dozable/" + q).recipe.id, r.id, "dozable/" + q)
        }
        XCTAssertEqual(AgentRef.qualifiedName(try XCTUnwrap(AgentRecipes.recipe("claude-code"))), "anthropic/claude-code")
        XCTAssertEqual(AgentRef.qualifiedName(try XCTUnwrap(AgentRecipes.recipe("opencode"))).hasPrefix("anomalyco/opencode"), true)
    }

    // MARK: accepted

    func testVendorProductIsThePlainNameConfirmed() throws {
        let plain = try ref("claude-code"), q = try ref("anthropic/claude-code"), full = try ref("dozable/anthropic/claude-code")
        XCTAssertEqual(q.recipe.id, plain.recipe.id)
        XCTAssertEqual(full.recipe.id, plain.recipe.id)
        XCTAssertEqual(try ref("claude").recipe.id, "claude-code", "the short name, unchanged")
        XCTAssertEqual(q.text, "anthropic/claude-code")
        XCTAssertEqual(q.bare, "claude-code")
        XCTAssertEqual(q.prefix, "anthropic")
        XCTAssertEqual(full.text, "dozable/anthropic/claude-code")
        XCTAssertEqual(try ref("  Anthropic/Claude-Code ").recipe.id, "claude-code", "case and spaces do not matter")
        XCTAssertEqual(try ref("earendil-works/pi").recipe.id, "pi")
        XCTAssertEqual(try ref("openai/codex").recipe.id, "codex")
        XCTAssertNil(plain.prefix)
        XCTAssertEqual(plain.text, "claude-code", "a plain name's text, byte for byte")
    }

    func testAFamilyWithItsVendor() throws {
        let rec = try XCTUnwrap(AgentRef.recommended("opencode"))
        let f = try ref("anomalyco/opencode")
        XCTAssertEqual(f.recipe.id, rec.id, "the family's name: its recommended major")
        XCTAssertEqual(f.text, "anomalyco/opencode")
        XCTAssertEqual(f.pinned, "anomalyco/opencode@\(rec.family!.major)", "a file keeps the major AND the qualification")
        XCTAssertEqual(try ref("anomalyco/opencode@1").recipe.id, "opencode")
        let two = try ref("anomalyco/opencode2")
        XCTAssertEqual(two.recipe.id, "opencode2", "a member by its own id is that major")
        XCTAssertEqual(two.text, "anomalyco/opencode@2")
        let exact = try ref("anomalyco/opencode@2.0.28")
        XCTAssertEqual(exact.recipe.id, "opencode2")
        XCTAssertEqual(exact.exact, "2.0.28")
        XCTAssertEqual(exact.text, "anomalyco/opencode@2.0.28")
        XCTAssertEqual(try ref("dozable/anomalyco/opencode@1").recipe.id, "opencode")
        // The same refusal as the plain form, for a major it does not have.
        XCTAssertTrue(refusal("anomalyco/opencode@9").contains("opencode@1"))
    }

    // 670: `doz.sh/VENDOR/PRODUCT[@…]` — Dozable's directory: the same recipe as `dozable/VENDOR/PRODUCT` and `VENDOR/PRODUCT`,
    // keeping what was typed. Nothing is fetched: resolution is a lookup in the recipes this doz has.
    func testTheRecipeDirectoryIsDozablesOwn() throws {
        XCTAssertEqual(RecipeOrigin.directoryHost, "doz.sh")
        let plain = try ref("anthropic/claude-code"), d = try ref("doz.sh/anthropic/claude-code")
        XCTAssertEqual(d.recipe.id, plain.recipe.id)
        XCTAssertEqual(d.text, "doz.sh/anthropic/claude-code", "the typed text is kept")
        XCTAssertEqual(d.bare, "claude-code")
        XCTAssertEqual(d.prefix, "doz.sh/anthropic")
        XCTAssertEqual(try ref("  DOZ.SH/Anthropic/Claude-Code ").recipe.id, "claude-code", "case and spaces do not matter")
        XCTAssertEqual(try ref("doz.sh/earendil-works/pi").recipe.id, "pi")
        XCTAssertEqual(try ref("doz.sh/openai/codex").recipe.id, "codex")
        // The grammar's parts: Dozable's source, the host kept.
        let q = try AgentRef.parseQualified("doz.sh/anthropic/claude-code@2")
        XCTAssertEqual(q.source, "dozable")
        XCTAssertEqual(q.host, "doz.sh")
        XCTAssertEqual(q.prefix, "doz.sh/anthropic")
        XCTAssertNil(try AgentRef.parseQualified("anthropic/claude-code").host)
        XCTAssertNil(try AgentRef.parseQualified("dozable/anthropic/claude-code").host)
        // A family: the recommended major, a major, an exact release; a file keeps the major AND the qualification.
        let rec = try XCTUnwrap(AgentRef.recommended("opencode"))
        let f = try ref("doz.sh/anomalyco/opencode")
        XCTAssertEqual(f.recipe.id, rec.id)
        XCTAssertEqual(f.text, "doz.sh/anomalyco/opencode")
        XCTAssertEqual(f.pinned, "doz.sh/anomalyco/opencode@\(rec.family!.major)")
        XCTAssertEqual(try ref("doz.sh/anomalyco/opencode@1").recipe.id, "opencode")
        let exact = try ref("doz.sh/anomalyco/opencode@2.0.28")
        XCTAssertEqual(exact.recipe.id, "opencode2")
        XCTAssertEqual(exact.exact, "2.0.28")
        XCTAssertEqual(exact.text, "doz.sh/anomalyco/opencode@2.0.28")
        XCTAssertTrue(refusal("doz.sh/anomalyco/opencode@9").contains("opencode@1"), "the plain form's refusal for a major it does not have")
        // What the displays say is unchanged: the recipe's own name, never a host.
        let cc = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        XCTAssertEqual(AgentRef.qualifiedName(cc), "anthropic/claude-code")
        XCTAssertEqual(AgentRef.fullyQualified(cc), "dozable/anthropic/claude-code")
        // Yours and a community's are not in Dozable's directory: the existing origin refusal, with the name that is right.
        let set = try withExtras()
        let m = refusal("doz.sh/acme/tool", in: set)
        XCTAssertTrue(m.contains("yours") && m.contains("mine/acme/tool"), m)
        let c = refusal("doz.sh/acme/tool2", in: set)
        XCTAssertTrue(c.contains("community · hub") && c.contains("hub/acme/tool2"), c)
        // The old words are nowhere: the directory is served, and a digest is simply not a way to name a tool.
        for s in ["doz.sh/claude-code", "example.com/x/y", "doz.sh/anthropic/claude-code@sha256:00", "doz.sh/a/b/c"] {
            XCTAssertFalse(refusal(s).contains("not served yet"), s)
            XCTAssertFalse(refusal(s).contains("not yet"), s)
        }
    }

    func testYoursAndACommunitySourcesWithTheirSource() throws {
        let set = try withExtras()
        XCTAssertEqual(try ref("mine/acme/tool", in: set).recipe.id, "tool")
        XCTAssertEqual(try ref("tool", in: set).recipe.id, "tool", "the plain id, unchanged")
        XCTAssertEqual(try ref("hub/acme/tool2", in: set).recipe.id, "tool2")
        XCTAssertEqual(AgentRef.qualifiedName(set.first { $0.id == "tool" }!), "mine/acme/tool")
        XCTAssertEqual(AgentRef.qualifiedName(set.first { $0.id == "tool2" }!), "hub/acme/tool2")
        // No source typed means Dozable's: never yours or a community's — said with the name that means it.
        let m = refusal("acme/tool", in: set)
        XCTAssertTrue(m.contains("yours") && m.contains("mine/acme/tool"), m)
        let c = refusal("mine/acme/tool2", in: set)
        XCTAssertTrue(c.contains("community · hub") && c.contains("hub/acme/tool2"), c)
        let d = refusal("dozable/acme/tool", in: set)
        XCTAssertTrue(d.contains("mine/acme/tool"), d)
    }

    func testWhatASandboxRecords() throws {
        let cc = try XCTUnwrap(AgentRecipes.recipe("claude-code")), o2 = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        XCTAssertEqual(AgentRef.fullyQualified(cc), "dozable/anthropic/claude-code")
        XCTAssertEqual(AgentRef.fullyQualified(cc, version: "2.1.299"), "dozable/anthropic/claude-code@2.1.299")
        XCTAssertEqual(AgentRef.fullyQualified(o2, version: "2.0.29+b1"), "dozable/anomalyco/opencode@2.0.29")
        let mine = try withExtras().first { $0.id == "tool" }!
        XCTAssertEqual(AgentRef.fullyQualified(mine, version: "1.0.0"), "mine/acme/tool@1.0.0")
        // What it records resolves to the same recipe and release.
        let back = try ref(AgentRef.fullyQualified(o2, version: "2.0.29"))
        XCTAssertEqual(back.recipe.id, "opencode2")
        XCTAssertEqual(back.exact, "2.0.29")
    }

    // MARK: refused, each in its own words

    func testRefusals() {
        let cases: [(String, [String])] = [
            ("registry.example.com/claude-code", ["only doz.sh is a recipe directory", "doz recipe source add"]),
            ("registry.example.com/anthropic/claude-code", ["only doz.sh is a recipe directory"]),
            ("example.com/x/y", ["only doz.sh is a recipe directory"]),
            ("doz.sh/claude-code", ["doz.sh/VENDOR/PRODUCT"]),
            ("doz.sh/a/b/c", ["doz.sh/VENDOR/PRODUCT"]),
            ("doz.sh/anthropic/claude-code:2", ["never :", "anthropic/claude-code@2"]),
            ("doz.sh/anthropic/claude-code@sha256:0123abcd", ["digest", "after @ comes a major or a release"]),
            ("doz.sh/openai/claude-code", ["not openai's", "anthropic/claude-code"]),
            ("doz.sh/nosuchvendor/thing", ["no tool here is nosuchvendor's"]),
            ("doz.sh/anthropic/nosuchtool", ["anthropic has no tool called nosuchtool"]),
            ("doz.sh/anthropic/claude-code@latest", ["after @ comes a major"]),
            ("doz.sh/anthropic/claude-code@", ["nothing after @"]),
            ("doz.sh/-x/claude-code", ["not a vendor's name"]),
            ("DOZ.SH.evil.com/anthropic/claude-code", ["only doz.sh is a recipe directory"]),
            ("doz.sh.evil.com/anthropic/claude-code", ["only doz.sh is a recipe directory"]),
            ("mine/doz.sh/claude-code", ["not a vendor's name"]),
            ("openai/claude-code", ["not openai's", "anthropic/claude-code"]),
            ("anthropic/claude", ["short name", "anthropic/claude-code"]),
            ("mine/anthropic/claude-code", ["Dozable's", "anthropic/claude-code"]),
            ("anthropic/claude-code:2", ["never :", "anthropic/claude-code@2"]),
            ("anthropic/claude-code@sha256:0123abcd", ["digest"]),
            ("a/b/c/d", ["not a tool's name"]),
            ("nosuchvendor/thing", ["no tool here is nosuchvendor's"]),
            ("anthropic/nosuchtool", ["anthropic has no tool called nosuchtool", "anthropic/claude-code"]),
            ("/claude-code", ["an empty vendor"]),
            ("anthropic/", ["no product"]),
            ("anthropic/claude-code@", ["nothing after @"]),
            ("bad_src/anthropic/claude-code", ["not a recipe source"]),
            ("-x/claude-code", ["not a vendor's name"]),
            ("anthropic/claude-code@latest", ["after @ comes a major"]),
            ("anthropic/claude-code@1.2.3'; rm -rf /", ["after @ comes a major"]),
            ("anthropic/claude-code@1.2.3'; rm -rf", ["after @ comes a major"]),
            ("anthropic/claude-code@1@2", ["after @ comes a major"]),
            (String(repeating: "a", count: 100) + "/" + String(repeating: "b", count: 70), ["longer than a tool's name"]),
        ]
        for (s, words) in cases {
            let m = refusal(s)
            for w in words { XCTAssertTrue(m.contains(w), "\(s): '\(m)' lacks '\(w)'") }
        }
    }

    func testAnUnpublishedToolIsRefusedByItsQualifiedNameToo() throws {
        AgentRecipes.publishEverythingForTests(false)
        guard let r = AgentRecipes.all.first(where: { !$0.isPublished }) else { throw XCTSkip("every recipe is published") }
        XCTAssertThrowsError(try AgentRef.resolve(AgentRef.qualifiedName(r))) { XCTAssertTrue("\($0)".contains("unpublished"), "\($0)") }
        XCTAssertNotNil(try AgentRef.resolveAny(AgentRef.qualifiedName(r), in: AgentRecipes.all), "only to say why")
    }

    // MARK: the old forms, byte for byte

    func testTheOldFormsAreUnchanged() throws {
        XCTAssertNil(try AgentRef.resolve("python"), "a base: the caller's")
        XCTAssertNil(try AgentRef.resolve("none"))
        XCTAssertNil(try AgentRef.resolve("my-template"))
        XCTAssertNil(try AgentRef.resolve("node-claude-code"), "an image name: the caller's")
        for s in ["claude-code", "claude", "opencode", "opencode@1", "opencode@2", "opencode@2.0.28", "opencode2"] {
            let r = try ref(s)
            XCTAssertNil(r.prefix, s)
            XCTAssertEqual(r.text, r.bare, s)
        }
        XCTAssertEqual(try ref("opencode@2.0.28").text, "opencode@2.0.28")
        XCTAssertEqual(try ref("opencode2").pinned, "opencode@2")
        XCTAssertThrowsError(try AgentRef.resolve("nosuchtool@1"))
    }

    // MARK: the rules beside the grammar

    func testAFamilysMajorsShareOneVendor() throws {
        let o1 = try XCTUnwrap(AgentRecipes.recipe("opencode")), o2 = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        var other = o2
        other.vendor = "someone-else"
        XCTAssertThrowsError(try AgentRecipes.validateFamilies([o1, other])) { XCTAssertTrue("\($0)".contains("one vendor"), "\($0)") }
    }

    func testTheSourceWords() {
        XCTAssertEqual(RecipeOrigin.dozable.sourceWord, "dozable")
        XCTAssertEqual(RecipeOrigin.mine.sourceWord, "mine")
        XCTAssertEqual(RecipeOrigin.community("hub").sourceWord, "hub")
        XCTAssertEqual(RecipeOrigin.reservedSourceNames, ["dozable", "mine"])
    }

    func testTheIndexCarriesTheQualifiedName() throws {
        let cc = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        XCTAssertEqual(DirectoryIndex.entry(for: cc).qualified, "anthropic/claude-code")
        let index = DirectoryIndex.build(version: "0.0.0")
        let bytes = try index.encoded()
        XCTAssertEqual(try DirectoryIndex.decode(bytes), index, "additive and read back strictly")
    }
}
