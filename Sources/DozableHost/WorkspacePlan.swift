import CryptoKit
import Foundation

// Making a workspace, looked at before it is made: `workspace-plan` (the New workspace wizard, `doz workspace new …
// --dry-run`) answers what `workspace-new` would do with the same request — everything it would refuse, all at once, the
// set-up check's gaps the start would refuse once it is made, a few lines a person reads, and the commands that make it.
// ONE source for each: the draft (`HostCore.workspaceNewDraft`) is what `new` writes, `WorkspaceNewCommand` the commands
// every surface prints, `WorkspacePresets.builtIn` the wizard's "Start from", `WorkspaceProjectFill` what a
// doz_project.yaml fills in. `docs/engineering/workspaces.md` ("Making one: the plan and the dry run").

/// `workspace-plan`'s answer. Nothing was written, no room made, the keychain not read.
public struct WorkspacePlan: Codable, Equatable, Sendable {
    public var name: String
    /// Everything `workspace-new` would refuse (empty: it would be made). The first is the one `new` answers with.
    public var refusals: [String]
    /// The first refusal's code (`HostError.Code`), so a dry run exits as `new` would. nil: no refusal.
    public var refusalCode: String?
    /// What `workspace-start` would refuse once it is made (the set-up check), each with its fix.
    public var gaps: [WorkspaceSetupCheck.Gap]
    public var notes: [String]
    /// The plan as a person reads it, one line each.
    public var lines: [String]
    /// The commands that make the same workspace (`WorkspaceNewCommand.text`), and the one that starts it.
    public var commands: String
    public var startCommand: String
    /// The wizard's "Start from" (`WorkspacePresets.builtIn`).
    public var presets: [WorkspacePreset]
    public init(name: String, refusals: [String], refusalCode: String?, gaps: [WorkspaceSetupCheck.Gap], notes: [String], lines: [String],
                commands: String, startCommand: String, presets: [WorkspacePreset] = WorkspacePresets.builtIn) {
        self.name = name; self.refusals = refusals; self.refusalCode = refusalCode; self.gaps = gaps; self.notes = notes
        self.lines = lines; self.commands = commands; self.startCommand = startCommand; self.presets = presets
    }
}

/// A built-in choice for "Start from": a preset of today's fields (nil: left as it is).
public struct WorkspacePreset: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var managerIsolation: String?
    public var workerIsolation: String?
    public var network: String?
    /// Folders added read-only.
    public var foldersReadOnly: Bool?
    public init(id: String, title: String, summary: String, managerIsolation: String? = nil, workerIsolation: String? = nil,
                network: String? = nil, foldersReadOnly: Bool? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.managerIsolation = managerIsolation
        self.workerIsolation = workerIsolation; self.network = network; self.foldersReadOnly = foldersReadOnly
    }
}

public enum WorkspacePresets {
    /// The ONE table. Templates you make come later.
    public static let builtIn: [WorkspacePreset] = [
        WorkspacePreset(id: "remotion-video", title: "Remotion video", summary: "the manager and new workers in micro VMs · standard network",
                        managerIsolation: "vm", workerIsolation: "vm", network: "standard"),
        WorkspacePreset(id: "swift-tests", title: "Swift tests", summary: "fenced on this Mac · standard network (packages from GitHub)",
                        managerIsolation: "fenced", workerIsolation: "fenced", network: "standard"),
        WorkspacePreset(id: "mac-admin", title: "Mac admin", summary: "fenced on this Mac · locked network",
                        managerIsolation: "fenced", workerIsolation: "fenced", network: "locked"),
        WorkspacePreset(id: "research", title: "Research", summary: "fenced · locked network · folders added read-only",
                        managerIsolation: "fenced", workerIsolation: "fenced", network: "locked", foldersReadOnly: true),
        WorkspacePreset(id: "blank", title: "Blank", summary: "choose everything yourself"),
    ]
}

/// The workspace network presets a request may name (`defaults.network`).
public enum WorkspaceNetworks {
    public static let presets = ["locked", "standard", "open"]
    /// What an older doz_project.yaml's `network:` may also say (kept as given).
    public static let projectWords = ["agent", "bake", "nat", "none"]
    /// New workers' default isolation: never unfenced by default.
    public static let workerIsolations = ["fenced", "vm"]
}

/// The commands that make a workspace from a request — the ONE source the plan answer, `--dry-run` and the wizard's Copy
/// share. The brief goes on standard input as a heredoc whose delimiter is absent from the text.
public enum WorkspaceNewCommand {
    /// The argument vector (`doz workspace new NAME --prompt-file - …`); the brief is read from standard input.
    public static func argv(_ w: WorkspaceRequest) -> [String] {
        var a = ["doz", "workspace", "new", w.name ?? "NAME", "--prompt-file", "-"]
        for r in w.refs ?? [] { a += ["--ref", r] }
        if w.newFolder == true { a.append("--new-folder") }
        for f in w.folders ?? [] { a += ["--folder", folderArgument(f)] }
        if w.project != nil { a.append("--from-project") } else if let n = w.network { a += ["--network", n] }
        if let r = w.room { a += ["--room", r] }
        if w.noRoom == true { a.append("--no-room") }
        if let m = w.manager { a += ["--manager", m] }
        if let i = w.managerIsolation { a += ["--manager-isolation", i] }
        if let i = w.workerIsolation { a += ["--worker-isolation", i] }
        for x in w.adopt ?? [] { a += ["--adopt", x] }
        return a
    }

    /// `DIR`, or `DIR:ro` — and `:rw` written out only where the path itself ends like a mode.
    static func folderArgument(_ f: WorkspaceFolder) -> String {
        if f.mode == "ro" { return f.path + ":ro" }
        return WorkspaceFolder.modes.contains { f.path.hasSuffix(":" + $0) } ? f.path + ":rw" : f.path
    }

    /// A heredoc delimiter absent from `brief`.
    public static func delimiter(_ brief: String) -> String {
        let hex = SHA256.hash(data: Data(brief.utf8)).map { String(format: "%02x", $0) }.joined()
        var d = "DOZ_BRIEF_" + hex.prefix(8)
        var n = 1
        while brief.contains(d) { d = "DOZ_BRIEF_" + hex.prefix(8) + "_\(n)"; n += 1 }
        return d
    }

    /// The command as a person pastes it: the argv quoted for a POSIX shell, the brief as a heredoc. Exact when the brief
    /// ends with a line break (a heredoc always ends with one).
    public static func text(_ w: WorkspaceRequest) -> String {
        let brief = w.brief ?? ""
        let d = delimiter(brief)
        return argv(w).map(quote).joined(separator: " ") + " <<'\(d)'\n" + brief + (brief.hasSuffix("\n") || brief.isEmpty ? "" : "\n") + d + "\n"
    }

    public static func startText(_ name: String) -> String { "doz workspace start \(quote(name))" }

    /// A word for a POSIX shell: as it is when it needs no quoting, else in single quotes.
    public static func quote(_ s: String) -> String {
        let plain = !s.isEmpty && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "_./:@%+=,-".unicodeScalars.contains($0)
        }
        return plain ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// `doz_project.yaml` in the main folder used to fill in choices — never written back. The CLI's `--from-project` and the
/// dashboard's `fromProject` share it; the YAML is read by the parser the caller hands in (Yams stays in the CLI).
public enum WorkspaceProjectFill {
    public typealias Parser = (_ text: String, _ file: String) throws -> DozableProject

    /// The folder it reads: `<projects_dir>/NAME` when that is made as the main folder, else the first folder.
    public static func mainFolder(_ w: WorkspaceRequest) -> String? {
        if w.newFolder == true, let n = w.name, WorkspaceName.isValid(n) { return WorkspaceStore.resolved(Workspace.defaultPath(name: n)) }
        return w.folders?.first?.path
    }

    /// A project's network preset (`locked`, `standard` or `open`; nil: none it says).
    public static func preset(_ p: DozableProject) -> String? {
        if let first = p.permissions?.first, p.permissions?.count == 1, WorkspaceNetworks.presets.contains(first) { return first }
        if let n = p.network, WorkspaceNetworks.presets.contains(n) { return n }
        return nil
    }

    /// Fills `project` and `network` from the project file in the main folder. A `network` already given that differs is
    /// refused, as are no main folder and no project file there.
    public static func apply(_ w: inout WorkspaceRequest, parse: Parser) throws {
        guard let main = mainFolder(w) else {
            throw HostError(.invalid, "--from-project reads the project file in the main folder — give it with --folder DIR")
        }
        let file: URL?
        do { file = try DozableProject.find(in: URL(fileURLWithPath: main)) } catch { throw HostError(.invalid, "\(error)") }
        guard let file else { throw HostError(.notFound, "no \(DozableProject.fileName) in \(DisplayPath.tilde(main))") }
        guard let data = FileManager.default.contents(atPath: file.path), data.count <= DozableProject.maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw HostError(.invalid, "\(DisplayPath.tilde(file.path)) cannot be read (UTF-8, at most 64 KiB)")
        }
        let p: DozableProject
        do { p = try parse(text, file.lastPathComponent) } catch { throw HostError(.invalid, "\(error)") }
        let preset = preset(p)
        if let given = w.network, let preset, given != preset {
            throw HostError(.invalid, "--network \(given) differs from the project's \(preset) (\(file.lastPathComponent)) — leave one out")
        }
        w.project = file.path
        w.network = w.network ?? preset
    }
}

/// The plan's lines, from the draft record (display only: paths with `~`).
enum WorkspacePlanLines {
    static func lines(_ rec: WorkspaceRecord, roomMade: Bool, roomLinked: Bool, newFolder: String?, workerIsolation: String?) -> [String] {
        var out: [String] = []
        let n = rec.name
        out.append("workspace \(n) — setting up until it starts")
        let refs = rec.brief.refs.count
        out.append("brief: \(rec.brief.bytes) bytes" + (refs == 0 ? "" : ", \(refs) reference\(refs == 1 ? "" : "s")"))
        if rec.folders.isEmpty {
            out.append("folders: none — the manager works in \(DisplayPath.tilde(Workspace.defaultPath(name: n)))")
        } else {
            let ro = rec.folders.filter { $0.mode == "ro" }.count
            out.append("folders: \(rec.folders.count)" + (ro == 0 ? "" : " (\(ro) read-only)") + ", main "
                       + DisplayPath.tilde(rec.folders[0].path) + (newFolder != nil ? " (made now)" : ""))
        }
        if let r = rec.mainRoom?.chatRoom {
            out.append(roomLinked ? "room: #\(r), linked; nothing is posted until it starts"
                       : roomMade ? "room: #\(r) is made; nothing is posted until it starts" : "room: #\(r)")
        } else {
            out.append("room: none")
        }
        if let m = rec.manager {
            out.append("manager: \(m.bot ?? m.name) · \(m.isolation ?? "fenced")" + (m.actsAsYou ? " · acts as you" : ""))
        } else {
            out.append("manager: none — you drive")
        }
        out.append("new workers: " + (workerIsolation.map { $0 == "vm" ? "micro VM" : $0 } ?? "fenced (the default)"))
        out.append("network: \(rec.defaults.network ?? "locked (the default)") + the room")
        let adopted = rec.agents.filter { !$0.isManager }.map(\.name)
        if !adopted.isEmpty { out.append("adopted: " + adopted.joined(separator: ", ")) }
        if let p = rec.origin.project { out.append("choices filled in from \(DisplayPath.tilde(p)) (never written)") }
        return out
    }
}
