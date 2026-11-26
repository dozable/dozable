import ArgumentParser
import DozableHost
import DozableKit
import Foundation

// 782 — workspace templates (`WorkspaceTemplates`, the files doz carries): `doz workspace templates [ID]` lists them or shows
// one, and `doz workspace new [NAME] --template ID` makes a workspace from one. The making is shared with the dashboard's
// `workspace-from-template` (doz ui holds this module, the space resolver with it): `WorkspaceTemplateMaker`. The files go in
// `~/doz-workspaces/NAME/` (defaults.projects_dir) — NAME.space.yaml and DESCRIPTION.md — never into a folder of your own;
// then the space is planned and set up through the daemon (`workspace-up-plan`, then `workspace-up` on that plan).

/// What a template made: the workspace, the template and its version, the space file, and what `up` did.
public struct WorkspaceFromTemplate: Codable, Equatable, Sendable {
    public var workspace: String
    public var template: String
    public var version: Int
    public var file: String
    public var acted: SpaceActed
}

public enum WorkspaceTemplateMaker {
    public typealias Send = @Sendable (HostRequest) async throws -> JSONValue

    /// Make workspace `name` (nil: the next free `workspaceN`) from template `id`: the files written into
    /// `<projects_dir>/NAME/` (made now, 0700; with `folder` nil that is also the work folder, else `folder` is and nothing
    /// is written into it), then planned and set up. `confirmed`: the person said yes to an agent acting as them (a manager
    /// bot that runs unfenced) — otherwise such a plan is refused. A failure before `up` takes back what was written.
    /// `brief`: the workspace's description in place of the template's (its DESCRIPTION.md); nil or empty: the template's.
    public static func make(id: String, name: String?, manager: String?, folder: String?, confirmed: Bool, store: DozableStore,
                            brief: String? = nil, send: Send) async throws -> WorkspaceFromTemplate {
        let p = try await prepare(id: id, name: name, manager: manager, folder: folder, store: store, brief: brief, send: send)
        let fm = FileManager.default
        // Made now (0700), and taken back when a step before up fails: the agents' folder and the files' folder.
        var madeNow: [String] = []
        for d in Set(folder == nil ? [p.work, p.dir] : [p.dir]).sorted() where !fm.fileExists(atPath: d) {
            TestSafety.checkMadeFolder(d)
            do { try MacFenceHostFS.ensureDirectory(d, mode: 0o700) } catch { throw HostError(.failed, "cannot make \(DisplayPath.tilde(d)): \(error)") }
            madeNow.append(d)
        }
        func takeBack() {
            try? fm.removeItem(atPath: p.file)
            try? fm.removeItem(atPath: p.desc)
            for d in madeNow.reversed() { try? fm.removeItem(atPath: d) }
        }
        guard fm.createFile(atPath: p.desc, contents: Data(p.description.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: p.file, contents: Data(p.fileText.utf8), attributes: [.posixPermissions: 0o600]) else {
            takeBack()
            throw HostError(.failed, "cannot write the template's files in \(DisplayPath.tilde(p.dir))")
        }
        var upSent = false
        do {
            var (space, plan) = try await spaceAndPlan(SpaceResolver(), p, send: send)
            if let e = spacePlanError(plan) { throw e }
            if !plan.confirm.isEmpty, !confirmed {
                throw HostError(.needsConfirmation, "\(plan.confirm.joined(separator: ", ")) would run unfenced and act as you — confirm it (--yes)")
            }
            var up = HostRequest(.workspaceUp)
            space.ifPlan = plan.sha
            space.confirmed = plan.confirm.isEmpty ? [] : plan.confirm
            up.space = space
            upSent = true
            let acted = try (try await send(up)).decode(SpaceActed.self)
            return WorkspaceFromTemplate(workspace: p.name, template: p.template.id, version: p.template.version, file: p.file, acted: acted)
        } catch {
            // Refused before up: nothing was made, and the files go too. Once up was sent, the workspace may name them.
            if !upSent { takeBack() }
            throw error
        }
    }

    /// What `make` would do, as `doz workspace up --dry-run` shows a space file: the same checks and the plan, from the
    /// files rendered in memory — nothing is written and (through `send` = the CLI's look) no daemon is started.
    public static func plan(id: String, name: String?, manager: String?, folder: String?, store: DozableStore,
                            brief: String? = nil, send: Send) async throws -> (workspace: String, file: String, plan: SpacePlan) {
        let p = try await prepare(id: id, name: name, manager: manager, folder: folder, store: store, brief: brief, send: send)
        var r = SpaceResolver()
        let file = URL(fileURLWithPath: p.file).standardizedFileURL.path
        r.read = { path in path == file ? p.fileText : nil }
        let look = SpaceBriefLook(path: p.desc, sha256: SpaceDoc.sha256(p.description), bytes: p.description.utf8.count)
        var plan = try await spaceAndPlan(r, p, dryBrief: look, send: send).plan
        // With no --folder the agents' folder is <projects_dir>/NAME, which make creates empty before up: its check is
        // what up will find, not a missing folder.
        if folder == nil, !FileManager.default.fileExists(atPath: p.work) {
            let shown = DisplayPath.tilde(p.work)
            for i in plan.steps.indices where plan.steps[i].action == "refuse" && plan.steps[i].subject.hasPrefix("folder ")
                && plan.steps[i].text.contains(shown) {
                plan.steps[i].action = "run"
                plan.steps[i].why = "made empty by the template first"
                plan.refusals.removeAll { $0.hasPrefix(plan.steps[i].subject + ": ") }
            }
            if plan.refusals.isEmpty { plan.refusalCode = nil }
        }
        return (p.name, p.file, plan)
    }

    /// The space document `up` is sent and its plan (`workspace-up-plan`). `dryBrief`: a dry run's look at the brief it did
    /// not write (and no prompt file is read: none is on disk; the templates write their prompts inline); nil: read beside
    /// the file.
    static func spaceAndPlan(_ resolver: SpaceResolver, _ p: Prepared, dryBrief: SpaceBriefLook? = nil,
                             send: Send) async throws -> (space: SpaceRequest, plan: SpacePlan) {
        let r = resolver.resolve(p.file)
        let (problems, model) = r.check()
        if let e = problems.first(where: \.isError) ?? (model == nil ? problems.first : nil) {
            throw HostError(.invalid, "the template \(p.template.id) does not read: \(e.message)")
        }
        let ref = model?.brief ?? ""
        var space = r.request(profiles: [], brief: ref.isEmpty ? nil : dryBrief ?? spaceBriefLook(ref, file: r.file))
        if dryBrief == nil { space.prompts = try spacePrompts(r) }
        var q = HostRequest(.workspaceUpPlan)
        q.space = space
        return (space, try (try await send(q)).decode(SpacePlan.self))
    }

    /// What `make` and `plan` share: the template read, the name chosen, every place decided and both files rendered.
    struct Prepared {
        var template: WorkspaceTemplate
        var name, work, dir, file, desc, yaml, description: String
        var fileText: String { "# Made from the workspace template \"\(template.title)\" (\(template.id), version \(template.version)).\n" + yaml }
    }

    /// Everything decided before a file is written — nothing is written here.
    static func prepare(id: String, name: String?, manager: String?, folder: String?, store: DozableStore, brief: String?,
                        send: Send) async throws -> Prepared {
        let t: WorkspaceTemplate
        do { t = try WorkspaceTemplates.read(id) } catch { throw HostError(.notFound, "\(error)") }
        if t.needs.manager, manager == nil { throw HostError(.invalid, "\(t.title) needs a manager: --manager BOT (doz bot ls)") }
        if let b = brief, b.utf8.count > WorkspaceStore.maximumBriefBytes {
            throw HostError(.invalid, "the brief is \(b.utf8.count) bytes — at most \(WorkspaceStore.maximumBriefBytes >> 10) KiB")
        }
        var n = name ?? ""
        if n.isEmpty {
            let p = try (try await send(WebWorkspaceNewPlan.request(WorkspaceRequest()))).decode(WorkspacePlan.self)
            n = p.suggested?.name ?? p.name
        }
        try WorkspaceName.validate(n)
        let fm = FileManager.default
        // The agents' folder: a folder of your own (nothing is written there), else <projects_dir>/NAME, made empty now.
        let projectFolder = WorkspaceStore.resolved(Workspace.defaultPath(name: n))
        func folderState(_ p: String) throws -> (exists: Bool, empty: Bool) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return (false, true) }
            guard isDir.boolValue else { throw HostError(.exists, "\(DisplayPath.tilde(p)) is a file, not a folder") }
            return (true, ((try? fm.contentsOfDirectory(atPath: p)) ?? []).isEmpty)
        }
        let work = folder ?? projectFolder
        if folder == nil, !(try folderState(work)).empty {
            throw HostError(.exists, "\(DisplayPath.tilde(work)) is not empty — choose another name, or a folder of your own")
        }
        // The template's two files: in <projects_dir>/NAME — unless that is not where a space file may be (it must be under
        // your home, never the store, ~/.claude or ~/Library: SpaceRecordFile), then in ~/doz-workspaces/NAME. Decided before
        // anything is written; when neither may hold them, refused with what to change.
        let home = SpaceRecordFile.home()
        let fallback = WorkspaceStore.resolved(URL(fileURLWithPath: home).appendingPathComponent("doz-workspaces").appendingPathComponent(n).path)
        let mayHold = { (d: String) in SpaceRecordFile.placeRefusal(d + "/\(n).space.yaml", home: home, store: store.root.path) == nil }
        guard let dir = [projectFolder, fallback].first(where: mayHold) else {
            throw HostError(.invalid, "a workspace template's files are kept in a folder under your home, and \(DisplayPath.tilde(projectFolder)) is not one — set defaults.projects_dir to a folder under your home (doz config set defaults.projects_dir ~/doz-workspaces)")
        }
        let file = dir + "/\(n).space.yaml", desc = dir + "/DESCRIPTION.md"
        guard !fm.fileExists(atPath: file), !fm.fileExists(atPath: desc) else {
            throw HostError(.exists, "\(DisplayPath.tilde(dir)) already holds a space file — choose another name")
        }
        _ = try folderState(dir)
        let (yaml, templateDescription) = try {
            // The owner is you as chat knows you (up checks it): the chat server's human, else the name chat on would give.
            let owner = (try? ChatDirectory.load(ChatPaths(store: store)))?.human ?? ChatNames.defaultHuman()
            do { return try WorkspaceTemplates.render(id, space: n, owner: owner, manager: manager, folder: work) } catch { throw HostError(.invalid, "\(error)") }
        }()
        var description = templateDescription
        if let b = brief, !b.isEmpty { description = b.hasSuffix("\n") ? b : b + "\n" }
        return Prepared(template: t, name: n, work: work, dir: dir, file: file, desc: desc, yaml: yaml, description: description)
    }
}

/// The plan request the maker asks for the next free name (an empty request).
enum WebWorkspaceNewPlan {
    static func request(_ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(.workspacePlan)
        r.workspaceRequest = w
        return r
    }
}

/// `doz workspace templates [ID]`: the workspace templates doz carries, or one of them.
struct WorkspaceTemplatesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "templates", abstract: "The workspace templates doz carries, or one of them.",
        discussion: """
        Each template is a whole team: its agents, where each runs (fenced on this Mac or in a Sandbox — never unfenced), \
        the room and the network. With ID, the template and (--files) its space file and description. Make one with doz \
        workspace new [NAME] --template ID [--manager BOT] [--folder DIR].
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "A template's id (doz workspace templates lists them).") var id: String?
    @Flag(name: .long, help: "With ID: print its space file and its description too.") var files = false

    func run() throws {
        guard let id else {
            let all = WorkspaceTemplates.list()
            if g.json { Out.json(all); return }
            if all.isEmpty { Out.stdout("This build carries none of the workspace templates.\n"); return }
            Out.stdout(Out.table([["ID", "TEMPLATE", "MANAGER", "AGENTS"]] + all.map {
                [$0.id, $0.title, $0.needs.manager ? "your bot" : "—", $0.agents.filter { $0.where != "manager" }.map(\.name).joined(separator: ", ")]
            }) + "\nMake one: doz workspace new [NAME] --template ID\n")
            return
        }
        let t: WorkspaceTemplate
        do { t = try WorkspaceTemplates.read(id) } catch { throw fail(HostError(.notFound, "\(error)"), g) }
        if g.json { Out.json(t); return }
        var s = "\(t.title) (\(t.id), version \(t.version)) — \(t.summary)\n"
        for a in t.agents {
            let place = a.where == "manager" ? "your bot, where it runs" : a.where == "sandbox" ? "Sandbox" : "fenced on this Mac"
            s += "  \(a.name): \(a.role) · \(place)" + (a.readOnly == true ? " · reads only" : "") + "\n"
        }
        s += "  room: #NAME · \(t.room)\n  network: \(t.network)\n"
        if files, let dir = WorkspaceTemplates.directory() {
            for f in ["space.yaml", "DESCRIPTION.md"] {
                s += "\n── \(f)\n" + ((try? String(contentsOf: dir.appendingPathComponent(t.id).appendingPathComponent(f), encoding: .utf8)) ?? "")
            }
        }
        Out.stdout(s)
    }
}
