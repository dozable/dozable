import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 623 — `doz nuke` / `doz inventory`: what a fresh install does not have, listed with places and sizes; never a
/// folder that is not Dozable's, never a keychain item Dozable did not make. Scratch paths and an in-memory keychain.
final class NukeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-nuke-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func dir(_ path: String, file: String? = nil, bytes: Int = 0) throws -> URL {
        let u = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        if let file { FileManager.default.createFile(atPath: u.appendingPathComponent(file).path, contents: Data(count: bytes)) }
        return u
    }

    func testItListsTheStoreSettingsCacheAndDozablesOwnKeychainItemsWithSizes() throws {
        let store = try dir("store/sandboxes", file: "x", bytes: 100_000).deletingLastPathComponent()
        let config = try dir("config/dozer-sandbox", file: "doz.toml", bytes: 10)
        let cache = try dir("caches/dozer-sandbox", file: "container.pkg", bytes: 5_000)
        let k = MemoryKeychain()
        try k.write(service: "doz-anthropic:work", account: Keychain.user, secret: "x")
        try k.write(service: "doz-chatgpt:me#1", account: Keychain.user, secret: "x")
        try k.write(service: Access.githubKeyService, account: Keychain.user, secret: "x")
        try k.write(service: "doz-something-else", account: Keychain.user, secret: "x")   // not one Dozable makes

        let p = try Nuke.plan(store: DozerStore(root: store), configDir: config, cacheDir: cache, keychain: k)
        XCTAssertEqual(p.items.filter { $0.kind == .folder }.map(\.location), [store.path, config.path, cache.path].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        XCTAssertGreaterThanOrEqual(p.items[0].bytes ?? 0, 100_000, "the store's size is what its files take")
        XCTAssertEqual(Set(p.items.filter { $0.kind == .keychain }.map(\.location)),
                       ["login keychain: doz-anthropic:work", "login keychain: doz-chatgpt:me#1", "login keychain: doz-github"])
        XCTAssertTrue(p.kept.contains { $0.hasPrefix("doz itself") }, "doz stays installed")
        XCTAssertTrue(p.kept.contains { $0.hasPrefix("your workspace folders") })
    }

    func testItNeverListsAFolderThatIsNotDozables() throws {
        let notAStore = try dir("thesis", file: "thesis.pdf", bytes: 10)
        XCTAssertThrowsError(try Nuke.plan(store: DozerStore(root: notAStore), configDir: nil, cacheDir: root.appendingPathComponent("none"), keychain: MemoryKeychain()))
        let wrongConfig = try dir("config/something", file: "a")
        XCTAssertThrowsError(try Nuke.plan(store: DozerStore(root: root.appendingPathComponent("absent")), configDir: wrongConfig,
                                           cacheDir: root.appendingPathComponent("none"), keychain: MemoryKeychain()))
        let otherCache = try dir("caches/other", file: "a")
        let p = try Nuke.plan(store: DozerStore(root: root.appendingPathComponent("absent")), configDir: nil, cacheDir: otherCache, keychain: MemoryKeychain())
        XCTAssertTrue(p.items.isEmpty, "a cache folder not named dozer-sandbox is never Dozable's")
    }

    func testAFreshMacHasNothingToRemove() throws {
        let p = try Nuke.plan(store: DozerStore(root: root.appendingPathComponent("absent")), configDir: root.appendingPathComponent("nope/dozer-sandbox"),
                              cacheDir: root.appendingPathComponent("none"), keychain: MemoryKeychain())
        XCTAssertTrue(p.items.isEmpty)
    }
}
