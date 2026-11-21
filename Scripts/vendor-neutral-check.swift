#!/usr/bin/env swift
// vendor-neutral-check.swift — code vendored by peer commit (WebSource/vendor/<package>/ with "provenance": "peer-commit")
// carries nothing of the machine or the people it was built by: no home path, email, tailnet address or `*.ts.net` name,
// and — when a word list is given — none of its words, in any file's name or text, in the source folder and in the copy
// that ships (Resources/Web/assets/<publicName>-*). Licence files are skipped (a copyright line names its holder on purpose).
//
//   DOZ_NEUTRAL_DENYLIST=FILE swift Scripts/vendor-neutral-check.swift   (Scripts/audit.sh runs it when the variable is set)
//
// The word list is a file OUTSIDE this repository — one word per line, `#` comments and blank lines ignored, matched
// without regard to case. Its words are never printed: a match names the file and the list's line number. This source
// holds only the generic patterns. (`.local` names are left out: minified code says `t.local`.)
import Foundation

let package = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let vendor = package.appendingPathComponent("Sources/DozableWeb/WebSource/vendor")
let assets = package.appendingPathComponent("Sources/DozableWeb/Resources/Web/assets")
let fm = FileManager.default

var words: [(line: Int, word: String)] = []
if let list = ProcessInfo.processInfo.environment["DOZ_NEUTRAL_DENYLIST"], !list.isEmpty {
    guard let text = try? String(contentsOfFile: list, encoding: .utf8) else {
        FileHandle.standardError.write(Data("x vendor-neutral-check: the word list (DOZ_NEUTRAL_DENYLIST) could not be read\n".utf8))
        exit(1)
    }
    for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let w = raw.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty, !w.hasPrefix("#") { words.append((i + 1, w.lowercased())) }
    }
}
let generic: [(String, String)] = [
    (#"/Users/"#, "a home path"),
    (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, "an email address"),
    (#"\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b"#, "a tailnet address"),
    (#"[A-Za-z0-9-]\.ts\.net\b"#, "a tailnet name"),
]

struct PeerVendor: Decodable {
    struct File: Decodable { let file: String; let serve: String; let publicName: String? }
    let provenance: String?
    let files: [File]?
}

var scanned = 0
var findings: [String] = []
func scan(_ name: String, _ data: Data) {
    scanned += 1
    let text = String(decoding: data, as: UTF8.self)
    for (subject, what) in [(name, "name"), (text, "text")] {
        let lower = subject.lowercased()
        for w in words where lower.contains(w.word) { findings.append("\(name): its \(what) holds the word list's line \(w.line)") }
        for (pattern, kind) in generic where subject.range(of: pattern, options: .regularExpression) != nil {
            findings.append("\(name): its \(what) holds \(kind)")
        }
    }
}

var packages = 0
for pkg in ((try? fm.contentsOfDirectory(atPath: vendor.path)) ?? []).sorted() {
    let dir = vendor.appendingPathComponent(pkg)
    guard let vd = try? Data(contentsOf: dir.appendingPathComponent("VENDOR.json")),
          let v = try? JSONDecoder().decode(PeerVendor.self, from: vd), v.provenance == "peer-commit" else { continue }
    packages += 1
    let licences = Set((v.files ?? []).filter { $0.serve == "licence" }.map(\.file))
    let base = dir.resolvingSymlinksInPath().path + "/"
    if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
        while let u = e.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = String(u.resolvingSymlinksInPath().path.dropFirst(base.count))
            if licences.contains(rel) || rel.hasSuffix(".DS_Store") { continue }
            scan("vendor/\(pkg)/\(rel)", (try? Data(contentsOf: u)) ?? Data())
        }
    }
    // The copies that ship.
    for f in v.files ?? [] where f.serve == "module" {
        guard let name = f.publicName else { continue }
        for served in ((try? fm.contentsOfDirectory(atPath: assets.path)) ?? []).sorted() where served.hasPrefix(name + "-") {
            scan("Resources/Web/assets/\(served)", (try? Data(contentsOf: assets.appendingPathComponent(served))) ?? Data())
        }
    }
}

let list = words.isEmpty ? "the generic patterns only (no word list)" : "the generic patterns and \(words.count) listed words"
guard findings.isEmpty else {
    FileHandle.standardError.write(Data(("x vendor-neutral-check: \(findings.count) match(es) — \(list):\n  " + findings.joined(separator: "\n  ") + "\n").utf8))
    exit(1)
}
print("ok vendor-neutral-check: \(scanned) file(s) of \(packages) peer-commit package(s), 0 matches — \(list)")
