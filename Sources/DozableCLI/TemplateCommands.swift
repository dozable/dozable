import ArgumentParser
import Foundation
import DozableKit
import DozableHost

// 593 — saved disks and duplicates (owner: "a way to turn a disk image into a template and/or to
// create a new Sandbox from an existing one (provide a new workspace dir etc)"). A saved disk is a
// custom image: the sandbox's ROOT disk only — never its state disk (the agent's logins and
// history). Duplicate makes a new sandbox from an existing one's disk with overrides; its state disk
// starts fresh unless --copy-state. Both are APFS clones.
//
// 757 (VOC2, owner ruling D5): sandbox disks are `doz image save | ls | rm`. `doz template` is freed for workspace
// templates (TPL1); for ONE release `doz template create | ls | rm` forward to the image commands, each printing one
// notice on stderr and, with --json, the same answer plus a `deprecated` field naming the command to use. No new
// `doz template` subcommand is added here — TPL1 gives the word its workspace meaning.

/// 757: what `doz image save` and the forwarding `doz template` commands share — one daemon op, one answer, one notice.
enum SavedDisks {
    /// The one line `doz template create | ls | rm` print on stderr while they forward.
    static let notice = "`doz template` now means workspace templates; sandbox disks are `doz image save|ls|rm`"

    /// The `deprecated` field's value for each forwarded command.
    static let saveCommand = "doz image save", listCommand = "doz image ls", removeCommand = "doz image rm"

    /// The notice, on stderr (never stdout: scripts read it), once per command.
    static func printNotice() { Out.stderr("[doz] \(notice)\n") }

    /// `value` as JSON with `"deprecated": replacement` added: to the object itself, or to every object of an array (so an
    /// array stays an array and every existing reader keeps working). Anything else is returned unchanged.
    static func withDeprecated<T: Encodable>(_ value: T, _ replacement: String) throws -> JSONValue {
        let v = try JSONValue(encoding: value)
        switch v {
        case .object(var o):
            o["deprecated"] = .string(replacement)
            return .object(o)
        case .array(let a):
            return .array(a.map { e in
                guard case .object(var o) = e else { return e }
                o["deprecated"] = .string(replacement)
                return .object(o)
            })
        default:
            return v
        }
    }

    /// The daemon's `template-create`: the sandbox's root disk (now, or a restore point's) saved as an image.
    static func saveRequest(sandbox: String, name: String, point: String?, note: String?) -> HostRequest {
        var r = HostRequest(.templateCreate, name: sandbox)
        r.image = name
        r.point = point
        r.note = note
        return r
    }

    static func save(sandbox: String, name: String, point: String?, note: String?, _ g: GlobalOptions) throws -> CustomImage {
        try decode(try call(saveRequest(sandbox: sandbox, name: name, point: point, note: note), g), CustomImage.self, g)
    }

    static func savedLine(sandbox: String, point: String?, _ img: CustomImage) -> String {
        "saved \(sandbox)'s root disk\(point.map { " (restore point \($0))" } ?? "") as the image \(img.name) (\(DozableImages.formatBytes(img.allocatedBytes)); no state disk) — doz create NEW --image \(img.name)\n"
    }

    /// The saved disks among the images (`kind` `custom`).
    static func rows(_ all: [ImageRow]) -> [ImageRow] { all.filter { $0.kind == "custom" } }

    /// Whether `image ls`'s row is a saved disk (a sandbox's disk saved with `doz image save`), not a built-in or baked image.
    static func isSaved(_ r: ImageRow) -> Bool { r.kind == "custom" }

    /// The question `doz image rm` asks: a saved disk is gone for good, a baked image is baked again when next needed.
    static func removeQuestion(_ image: String, saved: Bool) -> String {
        saved ? "Remove the saved disk \(image)? Sandboxes created from it keep working; it cannot be made again."
              : "Remove the image \(image)? (It is baked again when next needed.)"
    }
}

struct TemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template",
        abstract: "Moved: sandbox disks are doz image save | ls | rm (these forward there for one release).",
        discussion: """
        A sandbox's saved disk is an image now: doz image save SANDBOX NAME, doz image ls, doz image rm NAME. \
        `doz template` will mean workspace templates; until then create, ls and rm forward to the image commands \
        and say so on stderr (with --json, the same answer plus "deprecated").
        """,
        subcommands: [TemplateCreate.self, TemplateList.self, TemplateRemove.self],
        defaultSubcommand: TemplateList.self)
}

struct TemplateCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create",
        abstract: "Moved to doz image save SANDBOX NAME (forwards there for one release).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Option(name: .customLong("as"), help: "The saved disk's name (1–40 of a-z 0-9 -).") var template: String
    @Option(name: .customLong("from-point"), help: "A restore point (name or id) instead of the current disk.") var point: String?
    @Option(name: .long) var note: String?
    func run() async throws {
        SavedDisks.printNotice()
        let img = try SavedDisks.save(sandbox: name, name: template, point: point, note: note, g)
        if g.json { Out.json(try SavedDisks.withDeprecated(img, SavedDisks.saveCommand)); return }
        Out.stdout(SavedDisks.savedLine(sandbox: name, point: point, img))
    }
}

struct TemplateList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Moved to doz image ls (forwards there for one release: the saved disks).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        SavedDisks.printNotice()
        let rows = SavedDisks.rows(try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g))
        if g.json { Out.json(try SavedDisks.withDeprecated(rows, SavedDisks.listCommand)); return }
        if rows.isEmpty { Out.stdout("no saved disks — doz image save SANDBOX NAME\n"); return }
        var t = [["SAVED DISK", "SAVED", "SIZE", "FROM", "NOTE"]]
        for r in rows {
            t.append([r.name, r.bakedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—",
                      r.allocatedBytes.map(DozableImages.formatBytes) ?? "—", r.fromSandbox ?? "—", r.note ?? ""])
        }
        Out.stdout(Out.table(t))
    }
}

struct TemplateRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Moved to doz image rm NAME (forwards there for one release; a saved disk only).")
    @OptionGroup var g: GlobalOptions
    @Argument var template: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        SavedDisks.printNotice()
        let rows = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)
        // As before: only a saved disk — a built-in or baked image is never removed through here.
        guard rows.contains(where: { SavedDisks.isSaved($0) && $0.name == template }) else {
            throw fail(HostError(.notFound, "no saved disk \(template) (doz image ls)\(rows.contains { $0.name == template } ? " — \(template) is a built-in image: doz image rm" : "")"), g)
        }
        try confirm(SavedDisks.removeQuestion(template, saved: true), yes: yes, g)
        var r = HostRequest(.imageRm)
        r.image = template
        let left = try decode(try call(r, g), [ImageRow].self, g)
        if g.json { Out.json(try SavedDisks.withDeprecated(left, SavedDisks.removeCommand)) } else { Out.stdout("removed the saved disk \(template)\n") }
    }
}

struct Duplicate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "duplicate",
        abstract: "A new sandbox from an existing one's disk (or a restore point), with a new folder, CPUs, memory, network or account.",
        discussion: """
        The root disk is an APFS clone. The state disk (the agent's logins and history) starts FRESH unless --copy-state. \
        Keys are not copied. A live sandbox pauses for the clone (milliseconds). The new sandbox is off: doz start NEW.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox to duplicate.") var name: String
    @Argument(help: "The new sandbox's name.") var newName: String
    @Option(name: .customLong("from-point"), help: "A restore point (name or id) instead of the current disk.") var point: String?
    @Option(name: .long, help: "A folder on this Mac shared at /workspace (made when it does not exist).") var folder: String?
    @Flag(name: .long, help: "Share no folder (drop the source's folder): the new sandbox is isolated.") var isolated = false
    @Option(name: .long) var cpus: Int?
    @Option(name: .long, help: "e.g. 2G, 1536M.") var memory: String?
    @Option(name: .long, help: "agent, bake, locked, open (proxied), nat or none (default: the source's, its policy included).") var network: String?
    @Option(name: .long, help: "An account, none or default (proxied networks).") var account: String?
    @Flag(name: .customLong("copy-state"), help: "Copy the agent's state disk too (its logins and history). Default: a fresh one.") var copyState = false

    func run() async throws {
        if isolated && folder != nil { throw fail(HostError(.invalid, "--isolated or --folder, not both"), g) }
        let ws = folder.map { w -> String in
            let e = (w as NSString).expandingTildeInPath
            return e.hasPrefix("/") ? e : URL(fileURLWithPath: e, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
        }
        var o = DuplicateOptions(folder: ws, cpus: cpus, network: network, account: account, copyState: copyState ? true : nil)
        o.isolated = isolated ? true : nil
        if let m = memory {
            guard let mib = DozableImages.parseMemory(m) else { throw fail(HostError(.invalid, "--memory: say e.g. 2G or 1536M"), g) }
            o.memoryMiB = mib
        }
        var r = HostRequest(.duplicate, name: name)
        r.newName = newName
        r.point = point
        r.duplicate = o
        let i = try decode(try call(r, g), SandboxInfo.self, g)
        if g.json { Out.json(i); return }
        Out.stdout("duplicated \(name)\(point.map { " (restore point \($0))" } ?? "") as \(i.name) — state disk \(copyState ? "copied" : "fresh")"
                   + (i.folder == nil ? " — isolated" : "") + " — doz start \(i.name)\n")
        noteFolder(i, isolatedAsked: isolated, g)
    }
}
