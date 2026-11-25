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
    public static func make(id: String, name: String?, manager: String?, folder: String?, confirmed: Bool, store: DozableStore,
                            send: Send) async throws -> WorkspaceFromTemplate {
        let t: WorkspaceTemplate
        do { t = try WorkspaceTemplates.read(id) } catch { throw HostError(.notFound, "\(error)") }
        if t.needs.manager, manager == nil { throw HostError(.invalid, "\(t.title) needs a manager: --manager BOT (doz bot ls)") }
        var n = name ?? ""
        if n.isEmpty {
            let p = try (try await send(WebWorkspaceNewPlan.request(WorkspaceRequest()))).decode(WorkspacePlan.self)
            n = p.suggested?.name ?? p.name
        }
        try WorkspaceName.validate(n)
        let dir = WorkspaceStore.resolved(Workspace.defaultPath(name: n))
        let fm = FileManager.default
        let made = !fm.fileExists(atPath: dir)
        if !made {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { throw HostError(.exists, "\(DisplayPath.tilde(dir)) is a file, not a folder") }
            if folder == nil, let items = try? fm.contentsOfDirectory(atPath: dir), !items.isEmpty {
                throw HostError(.exists, "\(DisplayPath.tilde(dir)) is not empty — choose another name, or a folder of your own")
            }
        }
        let file = dir + "/\(n).space.yaml", desc = dir + "/DESCRIPTION.md"
        guard !fm.fileExists(atPath: file), !fm.fileExists(atPath: desc) else {
            throw HostError(.exists, "\(DisplayPath.tilde(dir)) already holds a space file — choose another name")
        }
        let work = folder ?? dir
        let (yaml, description) = try {
            // The owner is you as chat knows you (up checks it): the chat server's human, else the name chat on would give.
            let owner = (try? ChatDirectory.load(ChatPaths(store: store)))?.human ?? ChatNames.defaultHuman()
            do { return try WorkspaceTemplates.render(id, space: n, owner: owner, manager: manager, folder: work) } catch { throw HostError(.invalid, "\(error)") }
        }()
        TestSafety.checkMadeFolder(dir)
        if made {
            do { try MacFenceHostFS.ensureDirectory(dir, mode: 0o700) } catch { throw HostError(.failed, "cannot make \(DisplayPath.tilde(dir)): \(error)") }
        }
        func takeBack() {
            try? fm.removeItem(atPath: file)
            try? fm.removeItem(atPath: desc)
            if made { try? fm.removeItem(atPath: dir) }
        }
        guard fm.createFile(atPath: desc, contents: Data(description.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: file, contents: Data(("# Made from the workspace template \"\(t.title)\" (\(t.id), version \(t.version)).\n" + yaml).utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            takeBack()
            throw HostError(.failed, "cannot write the template's files in \(DisplayPath.tilde(dir))")
        }
        var upSent = false
        do {
            let r = SpaceResolver().resolve(file)
            let (problems, model) = r.check()
            if let e = problems.first(where: \.isError) ?? (model == nil ? problems.first : nil) {
                throw HostError(.invalid, "the template \(id) does not read: \(e.message)")
            }
            var space = r.request(profiles: [], brief: spaceBriefLook(model?.brief ?? "", file: r.file))
            space.prompts = try spacePrompts(r)
            var q = HostRequest(.workspaceUpPlan)
            q.space = space
            let plan = try (try await send(q)).decode(SpacePlan.self)
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
            return WorkspaceFromTemplate(workspace: n, template: t.id, version: t.version, file: file, acted: acted)
        } catch {
            // Refused before up: nothing was made, and the files go too. Once up was sent, the workspace may name them.
            if !upSent { takeBack() }
            throw error
        }
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
