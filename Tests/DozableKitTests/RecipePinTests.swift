import CryptoKit
import Foundation
import XCTest
@testable import DozableKit

/// 599i: Codex joined the agents WITHOUT changing any other image. Every catalogue base × Claude Code /
/// pi / none composes to exactly the spec (and so the bake key) it did before 599i — the digest below was
/// computed from the tree at 0a02301 (before any 599i change) with the same inputs.
/// 0.37 (the Dozable rename, no migration — owner ruling) re-pinned every value here on purpose: the guest paths moved
/// (/run/dozer → /run/doz, /usr/local/lib/dozer → /usr/local/lib/doz, `dozer.local` → `doz.local`), so every Claude
/// Code and Codex image is baked anew. pi's and the agent-less images keep their keys.
final class RecipePinTests: XCTestCase {
    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func pre599iRecipes() throws -> String {
        let release = AgentRelease(version: "2.1.285", integrity: "sha512-AAAA")
        let native = NativeClaudeBuild(version: "2.1.285", sha256: ["linux-arm64": String(repeating: "a", count: 64),
                                                                    "linux-arm64-musl": String(repeating: "b", count: 64)])
        var lines: [String] = []
        for b in BaseCatalogue.all {
            for a in [AgentKind.claudeCode, .pi, .none] {
                let name = ImageChoice(base: b.id, agent: a).name
                let s = try ImageComposer.spec(name: name, base: b.source(), agent: a, release: a == .none ? nil : release, native: native)
                lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(s.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))")
            }
        }
        // A Dockerfile's base, and the recipe check (W28) on every one of them.
        let df = BaseSource(reference: "doz.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                            hasNode: false, musl: nil, rootfsMiB: 4096, environment: ["X": "1"], path: ["/opt/x/bin"])
        for a in [AgentKind.claudeCode, .pi, .none] {
            let name = ImageChoice(base: "df-0123456789ab", agent: a).name
            let s = try ImageComposer.spec(name: name, base: df, agent: a, release: a == .none ? nil : release, native: native)
            lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(ImageComposer.recompose(s) == s)")
        }
        return lines.joined(separator: "\n")
    }

    func test_everyPre599iImageIsUnchanged() throws {
        XCTAssertEqual(Self.sha(try Self.pre599iRecipes()), "481f37b61467b5750532e241484afc69d6e6367631bf0a8006cea220ec1d52f2")
    }

    /// 617 step 0: Codex's images, pinned BEFORE the agent-recipe refactor (computed at 4b5e9ac + the 617 claim,
    /// VERSION 0.34.0, before any 617 change). Every catalogue base and a Dockerfile's × Codex at its pin: the
    /// canonical JSON's sha256 and the bake key (and the W28 recipe check on the Dockerfile's). The recipe
    /// refactor must leave every byte of these unchanged — a change here re-bakes every Codex image in every store.
    static func codexRecipes() throws -> String {
        let release = AgentImages.codexPinned
        var lines: [String] = []
        for b in BaseCatalogue.all {
            let name = ImageChoice(base: b.id, agent: .codex).name
            let s = try ImageComposer.spec(name: name, base: b.source(), agent: .codex, release: release, native: nil)
            lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(s.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")) \(ImageComposer.recompose(s) == s)")
        }
        let df = BaseSource(reference: "doz.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                            hasNode: false, musl: nil, rootfsMiB: 4096, environment: ["X": "1"], path: ["/opt/x/bin"])
        let name = ImageChoice(base: "df-0123456789ab", agent: .codex).name
        let s = try ImageComposer.spec(name: name, base: df, agent: .codex, release: release, native: nil)
        lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(s.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")) \(ImageComposer.recompose(s) == s)")
        // AgentImages.spec("codex") is the Node pair at the pin.
        let node = try XCTUnwrap(AgentImages.spec("codex", release: release))
        lines.append("AgentImages.spec(codex) \(node.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))")
        return lines.joined(separator: "\n")
    }

    func test_everyCodexImageIsUnchanged() throws {
        // name · sha256 of the canonical JSON · bake key · recompose(spec) == spec
        XCTAssertEqual(try Self.codexRecipes(), """
            codex fb0e7cd900b4df50f9da0f3a15797dfb01a6bfd2af39b638bd9a5903eb5a6cbb 675e491c941e36ab03e4df7cfa9adcc4f7e8f08723fd98ca04c42249b51df694 true
            python-codex fbd9b709c083eb7278617afa3284c2ad9f07ba92fd0319aa668cb785a60c7bb2 963f1d41b094c8e40b6aead4844e2be08aa017aee4594a4fcc8752a26a8e077b true
            go-codex 966bfbcdfede1a7cd25a1e6c23c411be1f5ff02320b82f3ea136f451dfe5dd9f 7e92dbda0cdb521b3401a509629befa37f9f87f762de09076533e323197ea177 true
            rust-codex 7b48ac1ff922ccda3cdafd62c25fdcc10a21d2efc603f33fef4bbeda6fe0cd6a f3a5f308b4b84f6384c59ee06bfb3e88284fc42e4e0b3591c7a26a52def53bae true
            java-codex 2075b365a5250919ed74ac64cd6107a4ecfb45f32c7ed069b95c535ec7953155 030e147f1fdc64b5efbabe00d1743d954a5a49bbd946637b95c5d732bb70f658 true
            ruby-codex 5b04a583d979f33e349a84cf4b0c4658a4f655cea5d023c14a9634bc62c864c1 43104cc8d3fe7a5f6dd7c299382032f9704674411afe9f2ae1b6b6c94f51bedf true
            dotnet-codex 96ca6f20c1e14c949969d4e6654fcbc967312e05bf4159355229be0734048c34 e677f7e1ffc870afc68cb2883ae2c726cdb6a01c28a1f815e4345c74531d684f true
            debian-codex 311d17d1aa05f99325de23a4f986ea33c641f87601e2b7b55810dce76ed55e65 024a87cafc63b62df09840a4214fe03c7d618e06d65a9832aa8c722d9ed641ff true
            ubuntu-codex 1f43c497a6f0f6abfdce52705ed74742633645d17ebf285afca3e3f4800f23c2 ad01fc99066f6c6f35b2f5a456d2215a575448d461ebea579b3c021f61c00590 true
            alpine-codex 52e6e2d40e268e220398d2f40568a02c8614fea2f7ffc02a6b3bb2a9e71d0733 37dbdefcd7f8599c77ba072a74ef937ac1600c51b1fe9affa173caa78e2f8418 true
            df-0123456789ab-codex 77be5e791d085dab2af1cf96a084253e3366ef8aebaf582681dcd91f516d1a83 4697834559ffaa71534d43c2b5ba3654503f68f5fd860de00a7fe1967f663414 true
            AgentImages.spec(codex) 675e491c941e36ab03e4df7cfa9adcc4f7e8f08723fd98ca04c42249b51df694
            """)
        XCTAssertEqual(Self.sha(try Self.codexRecipes()), "658950cb4fe4775bb9b4ec497b9dbc80de5fda270e93d9b690e2eb9e17157e67")
    }

    /// The two Node agent images at their pins, and their bake keys.
    func test_nodeAgentImagesKeepTheirKeys() {
        XCTAssertEqual(AgentImages.claudeCode.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "7c9b0e39f68860c5e9bbf3677790e43d75a40314c3e1199a62f44f055f201ae2")
        XCTAssertEqual(AgentImages.pi.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "77448e7252340a2243c5ae4224ea7664e9f36fea22f4ebd54a0f7e47f8e1d2cb")
        // 617 step 0: and Codex's Node image at its pin.
        XCTAssertEqual(AgentImages.spec("codex", release: AgentImages.codexPinned)?.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "675e491c941e36ab03e4df7cfa9adcc4f7e8f08723fd98ca04c42249b51df694")
    }
}
