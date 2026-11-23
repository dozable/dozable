import ArgumentParser
import Foundation
import DozableHost

// `doz docs [PAGE] [--path] [--json]`: the manual THIS build carries (`EmbeddedManual`: `manual/` beside the resolved
// executable), and this version's URL. No network, no store, no daemon — it works on a plane. A canary or development
// build never names the version-less manual (dozable.com/llms.txt is the stable release's).

/// `doz docs --json`.
struct DocsAnswer: Codable, Equatable, Sendable {
    var kind = "DozDocs"
    var schema = 1
    /// This doz's version (`doz --version`).
    var version: String
    /// The manual's folder (absolute), or nil when this build carries none.
    var local: String?
    /// Its index, `llms.txt` (absolute), or nil.
    var llms: String?
    /// This version's manual online: https://dozable.com/v/VERSION/llms.txt.
    var url: String
}

/// `doz docs PAGE --json`.
struct DocsPageAnswer: Codable, Equatable, Sendable {
    var kind = "DozDocsPage"
    var schema = 1
    var version: String
    var number: Int
    var name: String
    /// The page's file (absolute).
    var path: String
    /// Its Markdown.
    var markdown: String
}

struct DocsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "docs",
        abstract: "This version's manual, carried inside doz: where it is, its URL, or one page (doz docs workspaces).",
        discussion: """
        Read offline: no network, no daemon. With no PAGE: this doz's version, the manual's folder, its index (llms.txt: \
        every page, one line each, linked relatively) and this version's manual online (https://dozable.com/v/VERSION/llms.txt). \
        PAGE is a page's name or number (doz docs workspaces, doz docs 37): its Markdown is printed. An unknown page exits 65 \
        and lists the pages. --path prints only the folder. --json prints {"kind":"DozDocs","schema":1,"version","local",\
        "llms","url"} (with PAGE: {"kind":"DozDocsPage","schema":1,"version","number","name","path","markdown"}).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "A page: its name (workspaces) or number (37).") var page: String?
    @Flag(name: .long, help: "Print only the manual's folder, on one line.") var path = false

    func validate() throws {
        if path && page != nil { throw ValidationError("--path or PAGE: one of them") }
    }

    /// The answer for this build (`dir`: the manual's folder, nil when it carries none).
    static func answer(version: String, dir: URL?) -> DocsAnswer {
        DocsAnswer(version: version, local: dir?.path, llms: dir?.appendingPathComponent(EmbeddedManual.index).path,
                   url: EmbeddedManual.url(version: version))
    }

    static let missing = "this build of doz carries no manual (no \(EmbeddedManual.folderName)/ folder beside it — `make cli` makes one)"

    /// A page, or the error to fail with (65 with the list of pages for one this manual does not have).
    static func page(_ query: String, version: String, dir: URL?) -> Result<DocsPageAnswer, HostError> {
        guard let dir else { return .failure(HostError(.failed, missing + " — online: " + EmbeddedManual.url(version: version))) }
        let pages = EmbeddedManual.pages(in: dir)
        guard let p = EmbeddedManual.lookup(query, in: pages) else {
            return .failure(HostError(.invalidValue, "no page \"\(query.prefix(80))\" in this manual — its pages: \(EmbeddedManual.listing(pages))"))
        }
        let file = dir.appendingPathComponent(p.file)
        guard let d = FileManager.default.contents(atPath: file.path) else { return .failure(HostError(.failed, "cannot read \(file.path)")) }
        return .success(DocsPageAnswer(version: version, number: p.number, name: p.name, path: file.path, markdown: String(decoding: d, as: UTF8.self)))
    }

    /// The text `doz docs` prints.
    static func text(_ a: DocsAnswer, pages: [EmbeddedManual.Page]) -> String {
        var s = "doz \(a.version) — the manual of this version\n"
        if let local = a.local, let llms = a.llms {
            s += "  here, offline:  \(DisplayPath.tilde(local))\n"
            s += "  its index:      \(DisplayPath.tilde(llms))\n"
        } else {
            s += "  here, offline:  — \(missing)\n"
        }
        s += "  online:         \(a.url)   (this version's)\n"
        if !pages.isEmpty {
            s += "\nRead a page: doz docs PAGE (its name or number). The pages:\n"
            for p in pages { s += "  " + String(format: "%02d", p.number) + "  " + p.name + "\n" }
        }
        return s
    }

    func run() throws {
        let version = DozableCommand.version
        let dir = EmbeddedManual.directory()
        if let q = page {
            switch Self.page(q, version: version, dir: dir) {
            case .failure(let e): throw fail(e, g)
            case .success(let a):
                if g.json { Out.json(a) } else { Out.stdout(a.markdown.hasSuffix("\n") ? a.markdown : a.markdown + "\n") }
            }
            return
        }
        if path {
            guard let dir else { throw fail(HostError(.failed, Self.missing), g) }
            if g.json { Out.json(Self.answer(version: version, dir: dir)) } else { Out.stdout(dir.path + "\n") }
            return
        }
        let a = Self.answer(version: version, dir: dir)
        if g.json { Out.json(a); return }
        Out.stdout(Self.text(a, pages: dir.map(EmbeddedManual.pages(in:)) ?? []))
    }
}
