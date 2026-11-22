import ArgumentParser
import DozableChat
import DozableHost
import Foundation

// 755: `doz workspace doc W [--json] [--write FILE [--force]]` — a workspace's document, for EVERY workspace
// (`workspace-doc`; docs/engineering/workspace-model.md): one made with `new` or the wizard generated from its record, one a
// space file made from the spec its last up recorded with the record's extras. Read-only (looking never starts the daemon);
// `--write` is the read-only half of eject: the document as a space file the person keeps — never applied.

struct WorkspaceDocCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doc", abstract: "A workspace's document: what it is, as a space file.",
        discussion: """
        Every workspace has one document: the spec of what should exist — its brief, folders, agents, rooms and sandboxes, \
        and its lifetime (standing or runs). A workspace made with doz workspace new has it generated from its record; one \
        made from a space file has the file as its last up read it, with what was added or adopted since. The document \
        never holds a secret's value (references only), a grant (only requests) or the workspace's phase. Dozable's \
        additions to the format are written under x-dozable until the format carries them. Prints the document as YAML; \
        --json is {kind: Document, schema: 1, workspace, from, document, notes} with document.lifetime always present. \
        --write FILE writes it as a space file (under your home, never in Dozable's store, ~/.claude or ~/Library; an \
        existing file only with --force) — nothing is applied. Exit codes: 0 · 2 no such workspace · 4 FILE exists \
        (--force) · 65 FILE may not be written there.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .customLong("write"), help: "Write the document to FILE as a space file (nothing is applied).") var write: String?
    @Flag(name: .long, help: "With --write: replace FILE when it exists.") var force = false

    func run() async throws {
        let a = try decode(try await query(workspaceRequest(.workspaceDoc, WorkspaceRequest(name: name)), g), WorkspaceDocumentAnswer.self, g)
        let view: JValue
        do { view = try ChatJSON.parse(Data(a.document.utf8)) } catch { throw fail(HostError(.failed, "the document is not JSON"), g) }
        let text = WorkspaceDocYAML.text(a, view)
        if let w = write {
            let path = workspaceDocTarget(w)
            do {
                try SpaceRecordFile.writeNew(text, to: path, replace: force, store: WorkspaceStore.resolved(g.dozableStore.root.path))
            } catch { throw fail(HostError.from(error), g) }
            if g.json {
                var answer = try a.answer()
                if case .object(var m) = answer { m.append(JMember("written", .string(path))); answer = .object(m) }
                Out.stdout(String(decoding: ChatJSON.encodeIndented(answer, indent: "  "), as: UTF8.self) + "\n")
            } else {
                Out.stdout("wrote \(DisplayPath.tilde(path)) — the document of \(a.workspace), as a space file (nothing applied)\n")
            }
            return
        }
        if g.json {
            Out.stdout(String(decoding: ChatJSON.encodeIndented(try a.answer(), indent: "  "), as: UTF8.self) + "\n")
            return
        }
        Out.stdout(text)
    }
}

/// `--write`'s FILE as an absolute, plain path: `~` is the space file's home (`TestSafety.spaceHome`), a relative path is
/// this folder's. Only the home itself is resolved later (`SpaceRecordFile`): a link below it is refused when written.
func workspaceDocTarget(_ p: String) -> String {
    let expanded = TestSafety.expandSpaceTilde(p)
    let abs = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    return URL(fileURLWithPath: abs).standardizedFileURL.path
}

enum WorkspaceDocYAML {
    /// The document as a space file: a header, then the file form (the lifetime only under `x-dozable` — what space/3
    /// reads today), in the document's order. `SpaceYAML` is the one emitter (no Yams writes YAML); its text reads back as
    /// the same document (`WorkspaceDocumentTests`).
    static func text(_ a: WorkspaceDocumentAnswer, _ view: JValue) -> String {
        var s = "# The document of the workspace \(a.workspace) (doz workspace doc), from its \(a.from == "record" ? "record" : "space file and record").\n"
        s += "# Dozable's additions to space/3 are under x-dozable. Nothing here is applied until you up it.\n"
        for n in a.notes { s += "# note: \(n)\n" }
        return s + SpaceYAML.emit(RecordDocument.fileForm(view), origins: [:], sources: [])
    }
}
