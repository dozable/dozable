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
    /// 782, the New workspace wizard: the next free name, each bot's fitness as its manager, and the refusals and gaps in
    /// the wizard's words (`WorkspaceWizard`). Additive.
    public var suggested: WorkspaceSuggestion?
    public var managers: [WorkspaceManagerFit]?
    public var findings: [WorkspaceFinding]?
    public init(name: String, refusals: [String], refusalCode: String?, gaps: [WorkspaceSetupCheck.Gap], notes: [String], lines: [String],
                commands: String, startCommand: String) {
        self.name = name; self.refusals = refusals; self.refusalCode = refusalCode; self.gaps = gaps; self.notes = notes
        self.lines = lines; self.commands = commands; self.startCommand = startCommand
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
    /// 775: sites its tool needs on top of the network preset (host names), for every agent the workspace starts.
    public var sites: [String]?
    public init(id: String, title: String, summary: String, managerIsolation: String? = nil, workerIsolation: String? = nil,
                network: String? = nil, foldersReadOnly: Bool? = nil, sites: [String]? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.managerIsolation = managerIsolation
        self.workerIsolation = workerIsolation; self.network = network; self.foldersReadOnly = foldersReadOnly; self.sites = sites
    }
}

public enum WorkspacePresets {
    /// The ONE table. 782: the wizard starts from workspace templates (`WorkspaceTemplates`); the CLI's `--preset` keeps
    /// these two — `blank`, and `remotion-video` (its template is `video`).
    public static let builtIn: [WorkspacePreset] = [
        // 775: a render first downloads Remotion's own browser (Chrome Headless Shell) from remotion.media — refused under
        // Standard, it failed as a name that does not resolve. Its npm packages are Standard's (Install: Node).
        WorkspacePreset(id: "remotion-video", title: "Remotion video",
                        summary: "the manager and new workers in Sandboxes · standard network + remotion.media (Remotion's browser)",
                        managerIsolation: "vm", workerIsolation: "vm", network: "standard", sites: ["remotion.media"]),
        WorkspacePreset(id: "blank", title: "Blank", summary: "choose everything yourself"),
    ]
    /// 782 (D7): retired presets — refused, naming what to use instead.
    public static let retired: [String: String] = [
        "swift-tests": "--template solo, or choose the flags yourself",
        "mac-admin": "choose the flags yourself",
        "research": "--template build-review, or --folder DIR:ro",
    ]

    /// The preset called `id` (`doz workspace new --preset ID`); a retired one and another name are refused.
    public static func named(_ id: String) throws -> WorkspacePreset {
        if let instead = retired[id] {
            throw HostError(.invalidValue, "the preset \(id) was retired — \(instead) (doz workspace templates lists the templates)")
        }
        guard let p = builtIn.first(where: { $0.id == id }) else {
            throw HostError(.invalidValue, "no preset \(id.prefix(40)) — the presets are " + builtIn.map(\.id).joined(separator: ", "))
        }
        return p
    }

    /// A preset's values put into a request where it leaves them unset — a flag given wins: the manager's isolation (only with
    /// a manager), new workers' isolation, the network, and read-only for each folder whose mode was not given
    /// (`folderModeGiven`, by index).
    public static func apply(_ p: WorkspacePreset, to w: inout WorkspaceRequest, folderModeGiven: [Bool]) {
        if w.manager != nil, w.managerIsolation == nil { w.managerIsolation = p.managerIsolation }
        if w.workerIsolation == nil { w.workerIsolation = p.workerIsolation }
        if w.network == nil { w.network = p.network }
        // 775: its sites join any given (once each).
        if let s = p.sites, !s.isEmpty { w.sites = (w.sites ?? []) + s.filter { !(w.sites ?? []).contains($0) } }
        if p.foldersReadOnly == true, var folders = w.folders {
            for i in folders.indices where !(i < folderModeGiven.count && folderModeGiven[i]) { folders[i].mode = "ro" }
            w.folders = folders
        }
    }
}

/// 782 (D1): `sandbox` is the word a person types and reads for the isolation stored as `vm`; `vm` stays its alias for good.
/// Every input normalises with `stored` (the CLI's flags, the web actions, the daemon's requests); records, `--json` and
/// space files keep `vm` until the next format version.
public enum IsolationWord {
    public static func stored(_ s: String) -> String { s == "sandbox" ? "vm" : s }
    public static func stored(_ s: String?) -> String? { s.map { stored($0) } }
}

/// The workspace network presets a request may name (`defaults.network`).
public enum WorkspaceNetworks {
    public static let presets = ["locked", "standard", "open"]
    /// What an older doz_project.yaml's `network:` may also say (kept as given).
    public static let projectWords = ["agent", "bake", "nat", "none"]
    /// New workers' default isolation: never unfenced by default.
    public static let workerIsolations = ["fenced", "vm"]
    public static let maximumSites = 16

    /// 775: a request's sites checked — each a host name or `*.domain` (`PermissionPolicy.site`'s rule, no port; a leading
    /// `site:` taken off), lower-cased, once each, at most 16. nil: none.
    public static func checkedSites(_ sites: [String]?) throws -> [String]? {
        guard let sites, !sites.isEmpty else { return nil }
        guard sites.count <= maximumSites else { throw HostError(.invalid, "--site: at most \(maximumSites) sites") }
        var out: [String] = []
        for s in sites {
            let (host, ports) = try PermissionPolicy.site(s)
            guard ports == nil else { throw HostError(.invalid, "--site \(s.prefix(80)): a host name, no port (api.example.com, *.example.com)") }
            if !out.contains(host) { out.append(host) }
        }
        return out
    }
}

/// The commands that make a workspace from a request — the ONE source the plan answer, `--dry-run` and the wizard's Copy
/// share. The brief goes on standard input as a heredoc whose delimiter is absent from the text.
public enum WorkspaceNewCommand {
    /// The argument vector (`doz workspace new NAME --prompt-file - …`); the brief is read from standard input.
    public static func argv(_ w: WorkspaceRequest) -> [String] {
        var a = ["doz", "workspace", "new", w.name ?? "NAME"]
        if !(w.brief ?? "").isEmpty { a += ["--prompt-file", "-"] }
        for r in w.refs ?? [] { a += ["--ref", r] }
        if w.newFolder == true { a.append("--new-folder") }
        for f in w.folders ?? [] { a += ["--folder", folderArgument(f)] }
        if w.project != nil { a.append("--from-project") } else if let n = w.network { a += ["--network", n] }
        for s in w.sites ?? [] { a += ["--site", s] }
        if let r = w.room { a += ["--room", r] }
        if let r = w.roomName { a += ["--room-name", r] }
        for i in w.invite ?? [] { a += ["--invite", i] }
        if w.noRoom == true { a.append("--no-room") }
        if let m = w.manager { a += ["--manager", m] }
        if let i = w.managerIsolation { a += ["--manager-isolation", i] }
        if let i = w.workerIsolation { a += ["--worker-isolation", i] }
        for x in w.adopt ?? [] { a += ["--adopt", x] }
        for t in w.workers ?? [] { a += ["--worker", t] }
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
        // 782: no description — no heredoc.
        if brief.isEmpty { return argv(w).map(quote).joined(separator: " ") + "\n" }
        let d = delimiter(brief)
        return argv(w).map(quote).joined(separator: " ") + " <<'\(d)'\n" + brief + (brief.hasSuffix("\n") ? "" : "\n") + d + "\n"
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
        out.append(rec.brief.bytes == 0 && refs == 0 ? "description: none yet — the manager asks in the room"
                   : "description: \(rec.brief.bytes) bytes" + (refs == 0 ? "" : ", \(refs) reference\(refs == 1 ? "" : "s")"))
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
        out.append("new workers: " + (workerIsolation.map { $0 == "vm" ? "Sandbox" : $0 } ?? "fenced (the default)"))
        out.append("network: \(rec.defaults.networkWords ?? "locked (the default)") + the room")
        let adopted = rec.agents.filter { !$0.isManager }.map(\.name)
        if !adopted.isEmpty { out.append("adopted: " + adopted.joined(separator: ", ")) }
        for d in rec.declaredWorkers {
            out.append("worker \(d.name): \(WorkerLaunch.shortTask(d.task)) — declared now, started by the start")
        }
        if let p = rec.origin.project { out.append("choices filled in from \(DisplayPath.tilde(p)) (never written)") }
        return out
    }
}
