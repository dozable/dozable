import ArgumentParser
import Foundation
import DozableHost

// `doz workspace …`: workspaces — each an environment set up for getting work done: its agents, its rooms, the brief and
// any folders it works on. Looking (ls, show, log) answers from the store when no daemon runs and never starts one;
// changes go through the daemon (the store's one writer; rooms need the chat server it runs). Exit codes as everywhere:
// 2 not found · 3 not in this state · 4 already exists or already in a workspace · 6 the daemon or chat unavailable · 64 usage.

struct WorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Workspaces: environments set up for getting work done — agents, rooms, a brief and any folders.",
        discussion: """
        A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the \
        work is for, and any folders it works on (usually projects). Work starts only once it is fully set up.

        Today's sandboxes and sessions on this Mac are loose agents until you adopt them; adopting writes only the \
        workspace's own record. With chat on, a new workspace gets a room of its own name (nothing is posted in it yet).
        """,
        subcommands: [WorkspaceNew.self, WorkspaceList.self, WorkspaceShow.self, WorkspaceAdopt.self, WorkspaceRelease.self,
                      WorkspaceEdit.self, WorkspaceLog.self, WorkspaceRename.self])
}

// MARK: helpers

/// `DIR[:ro|:rw]` → an absolute, resolved folder and its mode.
func workspaceFolder(_ s: String, _ g: GlobalOptions) throws -> WorkspaceFolder {
    var path = s, mode = "rw"
    for m in WorkspaceFolder.modes where s.hasSuffix(":" + m) { path = String(s.dropLast(m.count + 1)); mode = m }
    guard !path.isEmpty else { throw fail(HostError(.invalid, "\(s): which folder?"), g) }
    return WorkspaceFolder(path: workspaceAbsolute(path), mode: mode)
}

func workspaceAbsolute(_ p: String) -> String {
    let expanded = (p as NSString).expandingTildeInPath
    let abs = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    return WorkspaceStore.resolved(URL(fileURLWithPath: abs).standardizedFileURL.path)
}

/// A reference: an http(s) address as it is, else an absolute path.
func workspaceRef(_ s: String) -> String {
    s.hasPrefix("http://") || s.hasPrefix("https://") ? s : workspaceAbsolute(s)
}

/// The brief from a file, or standard input with `-`.
func workspaceBrief(_ file: String, _ g: GlobalOptions) throws -> String {
    let d: Data
    if file == "-" {
        d = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        guard let x = FileManager.default.contents(atPath: workspaceAbsolute(file)) else {
            throw fail(HostError(.notFound, "cannot read \(file)"), g)
        }
        d = x
    }
    guard d.count <= WorkspaceStore.maximumBriefBytes else {
        throw fail(HostError(.invalid, "the brief is \(d.count) bytes — at most \(WorkspaceStore.maximumBriefBytes >> 10) KiB"), g)
    }
    guard let text = String(data: d, encoding: .utf8) else { throw fail(HostError(.invalid, "the brief is not UTF-8 text"), g) }
    return text
}

func workspaceRequest(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
    var r = HostRequest(op)
    r.workspaceRequest = w
    return r
}

func stateWords(_ raw: String) -> String { WorkspaceState(rawValue: raw)?.words ?? raw }

/// The workspace as a person reads it.
func printWorkspace(_ d: WorkspaceDetail) {
    var s = "\(d.name) — \(stateWords(d.state)) · \(d.driver)\n"
    let refs = d.brief.refs.count
    s += "  brief    \(d.brief.bytes) bytes" + (refs == 0 ? "" : ", \(refs) reference\(refs == 1 ? "" : "s")") + "\n"
    for r in d.brief.refs { s += "             \(r.hasPrefix("/") ? DisplayPath.tilde(r) : r)\n" }
    if d.folders.isEmpty { s += "  folders  none\n" }
    for (i, f) in d.folders.enumerated() {
        s += (i == 0 ? "  folders  " : "           ") + DisplayPath.tilde(f.path) + " (" + (f.main ? "main, " : "") + (f.mode == "ro" ? "read-only" : "read-write") + ")\n"
    }
    s += "  room     " + (d.rooms.first { $0.main }.map { "#" + $0.chatRoom } ?? "none") + "\n"
    if d.agents.isEmpty { s += "  agents   none yet — doz workspace adopt \(d.name) SANDBOX|@mac/SESSION\n" }
    for (i, a) in d.agents.enumerated() {
        let place = a.place == a.name ? "" : " in \(a.place)"
        s += (i == 0 ? "  agents   " : "           ") + "\(a.name) (\(a.role)\(place), \(Out.phaseLabel(a.state)))\n"
    }
    if let o = d.origin.project { s += "  from     \(DisplayPath.tilde(o))\n" }
    for n in d.notes ?? [] { s += "note: \(n)\n" }
    Out.stdout(s)
}

// MARK: commands

struct WorkspaceNew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Make a workspace: its brief, any folders, its room and agents to adopt.",
        discussion: "The first --folder is the main one. With chat on, the room is named after the workspace (it must not exist yet — or link one with --room). Example: doz workspace new demo --prompt-file brief.md --folder ~/code/demo")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its name: 1–40 characters of a-z, 0-9 and -.") var name: String
    @Option(name: .customLong("prompt-file"), help: "The brief: a file (at most 256 KiB), or - for standard input.") var promptFile: String
    @Option(name: .customLong("ref"), help: "A reference for the brief: a path or an http(s) address (repeatable).") var refs: [String] = []
    @Option(name: .customLong("folder"), help: "A folder it works on, DIR or DIR:ro (repeatable; the first is the main one).") var folders: [String] = []
    @Option(name: .long, help: "Link this existing room in the chat server as its room, instead of making one (nothing is posted).") var room: String?
    @Flag(name: .customLong("no-room"), help: "No room, even with chat on.") var noRoom = false
    @Flag(name: .customLong("from-project"), help: "Take the network preset from the project file (doz_project.yaml) in the main folder.") var fromProject = false
    @Option(name: .customLong("adopt"), help: "Adopt this sandbox or @mac/SESSION at once (repeatable).") var adopt: [String] = []

    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.brief = try workspaceBrief(promptFile, g)
        w.folders = try folders.map { try workspaceFolder($0, g) }
        w.refs = refs.map(workspaceRef)
        w.room = room
        w.noRoom = noRoom ? true : nil
        w.adopt = adopt.isEmpty ? nil : adopt
        if fromProject {
            guard let main = w.folders?.first else {
                throw fail(HostError(.invalid, "--from-project reads the project file in the main folder — give it with --folder DIR"), g)
            }
            let file: URL?
            do { file = try DozableProject.find(in: URL(fileURLWithPath: main.path)) } catch { throw fail(HostError(.invalid, "\(error)"), g) }
            guard let file else { throw fail(HostError(.notFound, "no \(DozableProject.fileName) in \(DisplayPath.tilde(main.path))"), g) }
            let p: DozableProject
            do { p = try DozableProject.load(file) } catch { throw fail(HostError(.invalid, "\(error)"), g) }
            w.project = file.path
            w.network = p.network
        }
        let d = try decode(try call(workspaceRequest(.workspaceNew, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The workspaces — state, who drives, agents, room — and the loose agents.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Only the loose agents: the sandboxes and sessions on this Mac not adopted into any workspace.") var loose = false
    func run() async throws {
        var w = WorkspaceRequest()
        w.loose = loose ? true : nil
        let l = try decode(try await query(workspaceRequest(.workspaceList, w), g), WorkspaceListing.self, g)
        if g.json { Out.json(l); return }
        var s = ""
        if !loose {
            if l.workspaces.isEmpty { s += "Workspaces: none yet — doz workspace new NAME --prompt-file FILE\n" } else {
                s += Out.table([["NAME", "STATE", "AGENTS", "ROOM"]] + l.workspaces.map {
                    [$0.name, "\(stateWords($0.state)) · \($0.driver)", String($0.agents), $0.room.map { "#" + $0 } ?? "—"]
                }, rightAligned: [2])
            }
            s += "\n"
        }
        if l.loose.isEmpty { s += "Loose agents: none\n" } else {
            s += "Loose agents\n" + Out.table([["NAME", "KIND", "STATE"]] + l.loose.map {
                [$0.name, $0.kind == "mac" ? "session on this Mac" : "sandbox", Out.phaseLabel($0.state)]
            })
        }
        Out.stdout(s)
    }
}

struct WorkspaceShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "A workspace: its state, brief, folders, room and agents.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Flag(name: .long, help: "Print the brief's text too.") var brief = false
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.withBrief = brief ? true : nil
        let d = try decode(try await query(workspaceRequest(.workspaceShow, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
        if let t = d.briefText { Out.stdout("\n" + t + (t.hasSuffix("\n") ? "" : "\n")) }
    }
}

struct WorkspaceAdopt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "adopt", abstract: "Adopt a sandbox or a session on this Mac into a workspace, as a worker.",
        discussion: "Only the workspace's record changes: the sandbox and the session are left as they are. Each is in one workspace at most.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "A sandbox's name, or @mac/SESSION.") var agent: String
    @Option(name: .customLong("as"), help: "Its name in the workspace (default: the sandbox's or the session's).") var asName: String?
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.agent = agent
        w.asName = asName
        let d = try decode(try call(workspaceRequest(.workspaceAdopt, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release", abstract: "Let an agent go: it is loose again (it keeps running as it was).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "The agent: its name in the workspace, its sandbox, or @mac/SESSION.") var agent: String
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.agent = agent
        let d = try decode(try call(workspaceRequest(.workspaceRelease, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a workspace's brief, references or folders, or make its room.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .customLong("prompt-file"), help: "A new brief: a file, or - for standard input.") var promptFile: String?
    @Option(name: .customLong("add-ref"), help: "Add a reference: a path or an http(s) address (repeatable).") var addRefs: [String] = []
    @Option(name: .customLong("remove-ref"), help: "Remove a reference (repeatable).") var removeRefs: [String] = []
    @Option(name: .customLong("add-folder"), help: "Add a folder, DIR or DIR:ro (repeatable).") var addFolders: [String] = []
    @Option(name: .customLong("remove-folder"), help: "Remove a folder (repeatable).") var removeFolders: [String] = []
    @Flag(name: .customLong("make-room"), help: "Make its room in the chat server now (chat on), named after the workspace.") var makeRoom = false
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        if let f = promptFile { w.brief = try workspaceBrief(f, g) }
        w.addRefs = addRefs.isEmpty ? nil : addRefs.map(workspaceRef)
        w.removeRefs = removeRefs.isEmpty ? nil : removeRefs.map(workspaceRef)
        w.addFolders = addFolders.isEmpty ? nil : try addFolders.map { try workspaceFolder($0, g) }
        w.removeFolders = removeFolders.isEmpty ? nil : removeFolders.map(workspaceAbsolute)
        w.makeRoom = makeRoom ? true : nil
        let d = try decode(try call(workspaceRequest(.workspaceEdit, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceLog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "What happened to a workspace, and who did it.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .long, help: "Only since then: a time (2026-11-19T09:00:00Z) or an age (30m, 2h, 3d).") var since: String?
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        if let since {
            guard let d = WorkspaceStore.since(since) else { throw fail(HostError(.invalid, "--since \(since): a time (ISO 8601) or an age like 30m, 2h, 3d"), g) }
            w.since = d
        }
        let entries = try decode(try await query(workspaceRequest(.workspaceLog, w), g), [WorkspaceLogEntry].self, g)
        if g.json { Out.json(entries); return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var s = ""
        for e in entries { s += "\(f.string(from: e.at))  \(e.by.padding(toLength: 3, withPad: " ", startingAt: 0))  \(e.sentence)\n" }
        Out.stdout(s.isEmpty ? "nothing logged\(since == nil ? "" : " since then")\n" : s)
    }
}

struct WorkspaceRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Give a workspace another name (its room keeps its own).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "Its new name: 1–40 characters of a-z, 0-9 and -.") var newName: String
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.newName = newName
        let d = try decode(try call(workspaceRequest(.workspaceRename, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}
