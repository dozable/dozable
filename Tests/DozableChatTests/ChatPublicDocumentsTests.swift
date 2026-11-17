import CryptoKit
import Foundation
import XCTest

/// docs/chat/: the chat protocol's public documents, copied unchanged, and Dozable's own files beside them.
///
/// `protocol.md` and `webhook.md` are another party's text: one header line (which source, which commit) above their bytes,
/// copied by `Scripts/chat-protocol-sync.sh SRC REF` and never edited here. Their SHA-256 is pinned below, so an edit by
/// hand fails; a new copy changes the pins in the same commit (the script prints them). Their example names and wording
/// are their owner's, so the word rule for Dozable's own text exempts exactly those two paths, nothing wider.
final class ChatPublicDocumentsTests: XCTestCase {
    static let pinned = [
        "protocol.md": "7796757822ffcf78a781324b3bba888195992a4dff395dfbd82cb55a64b95eb7",
        "webhook.md": "aad64a76fadb07ade8f96898a5385cab0397f4eadf71959ab2a56e2d433354e6",
    ]
    static let commit = "0f25511bfcee9e391b301ccd93c49acbab7b2c23"

    static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/chat")
    }

    func testTheCopiedDocumentsAreUnchanged() throws {
        for (name, sum) in Self.pinned {
            let data = try Data(contentsOf: Self.folder.appendingPathComponent(name))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, sum, "docs/chat/\(name) was changed by hand: copy it again with Scripts/chat-protocol-sync.sh and pin the new hash here")
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            XCTAssertTrue(lines[0].hasPrefix("<!-- Copied unchanged from the public source of the chat protocol"), "\(name): the header line")
            XCTAssertTrue(lines[0].contains("commit \(Self.commit)"), "\(name): the header names the commit")
            XCTAssertTrue(lines[1].hasPrefix("<!-- Generated."), "\(name): the copied bytes follow the header line")
        }
    }

    /// Words Dozable's own text does not use, by the SHA-256 of the lower-cased word (so this file does not use them
    /// either): the reference product's name, and the word for a central server that the chat server is never called.
    static let forbiddenWordHashes: Set<String> = [
        "487537935c922e003caf22a9e8b0108e8b13ff4b350a2a2e83e290c48314cd3c",
        "08d33503ee27d4c13055d0cefec5e730be4ef2e41cd6cfce434936ec1e7c9d4b",
        "600df5b5c588f6a920743e7a7d9ac6bc192522394bd4befef7ae15c3a08b28c1",
    ]

    /// Dozable's own files here (the client, the README, the skills) say "the chat server" and never one of those
    /// words. The two copies are exempt, by path.
    func testDozablesOwnFilesUseItsOwnWords() throws {
        let exempt: Set<String> = ["protocol.md", "webhook.md"]
        let root = Self.folder.resolvingSymlinksInPath()
        var checked = 0
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            if exempt.contains(rel) || url.pathExtension == "pyc" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for word in Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)) {
                let hex = SHA256.hash(data: Data(word.utf8)).map { String(format: "%02x", $0) }.joined()
                if Self.forbiddenWordHashes.contains(hex) { XCTFail("docs/chat/\(rel): \"\(word)\" — say \"the chat server\"") }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
