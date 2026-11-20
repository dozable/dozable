import DozableChat
import Foundation

/// `workspace-up-plan`: what `doz workspace up -f FILE` would do. The request carries the merged space (the CLI read the
/// files; this never opens one): it is checked against its limits, validated again — with the backstop that nothing which
/// starts or owns something came from a defaults file —, compiled (`SpaceIntent`) and planned (`SpaceUp`) against the
/// workspace's record and the facts gathered here. Only reads: a read-only core answers it with `factsKnown` false.
extension HostCore {
    func spaceUpPlan(_ q: SpaceRequest?) async throws -> SpacePlan {
        guard let q else { throw HostError(.invalid, "workspace-up-plan needs the merged space") }
        let doc = try q.check()
        let specSHA = SpaceDoc.sha256(q.spec)
        let loc = SpaceLocator(sources: q.sources, origins: q.origins)
        let checked = SpaceValidator.checkMerged(doc, loc, profiles: q.profiles ?? [])
        let space = SpaceDoc.string(SpaceDoc.member(doc, "space")) ?? ""
        var plan = SpacePlan(space: space, title: checked.model.title, specPath: q.specPath, specSHA: specSHA, sources: q.sources, factsKnown: !readOnly)
        plan.problems = checked.problems
        if checked.problems.contains(where: \.isError) {
            plan.refusals = ["the space file has \(checked.problems.filter(\.isError).count) error(s)"]
            plan.refusalCode = HostError.Code.invalid.rawValue
            return plan
        }
        let intent = SpaceIntent.compile(checked.model, doc, loc)
        var out = SpaceUp.plan(intent, facts: await spaceFacts(intent, brief: q.brief), specSHA: specSHA, sources: q.sources, specPath: q.specPath,
                               prompts: q.prompts ?? [:])
        out.problems = checked.problems
        return out
    }

    /// What the plan needs to know: read from the store (a read-only core too); what only a running daemon knows — a
    /// session or a manager running, the chat server's rooms — only from one.
    func spaceFacts(_ i: SpaceIntent, brief: SpaceBriefLook?) async -> SpaceFacts {
        let home = TestSafety.realHome.path
        let projects = (Workspace.defaultPath(name: "x") as NSString).deletingLastPathComponent
        let rec = (try? WorkspaceName.validate(i.space)) != nil ? (try? workspaces.read(i.space)) ?? nil : nil
        let (readiness, _) = await workspaceLookReadiness(look: true)
        var chatOn = true
        if case .off = readiness { chatOn = false }
        var f = SpaceFacts(known: !readOnly, home: home, projectsDir: projects,
                           owner: (try? ChatDirectory.load(ChatPaths(store: store)))?.human, chatOn: chatOn, record: rec)
        f.brief = brief
        let file = bots.readOrEmpty()
        for a in i.agents where a.external {
            guard let b = a.bot else { continue }
            let r = file.bot(b)
            var fact = SpaceFacts.Bot(exists: r != nil, retired: r?.retired ?? false, holdsToken: r?.holdsToken ?? false)
            if !readOnly, let e = await liveWorkspace(of: b, except: i.space) { fact.liveElsewhere = e.workspace }
            f.bots[b] = fact
        }
        let sessions = mac.records().sessions
        for a in i.agents where a.external {
            guard let s = a.session, sessions[s] != nil else { continue }
            f.sessions[s] = readOnly ? true : await mac.isRunning(s)
        }
        if let idx = try? ChatRoomIndex.load(ChatPaths(store: store)) {
            f.indexedRooms = Set(idx.rooms.keys)
            f.goneRooms = Set(idx.tombstones.map(\.name))
        }
        if !readOnly, case .ready = readiness { f.rooms = try? workspaceChat?.rooms() }
        var paths = i.folders.compactMap(\.path).map { f.expand($0) }
        paths += SpaceUp.keptFolderPaths(i, f).map(\.path)
        for p in paths {
            var d: ObjCBool = false
            f.folders[p] = FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        f.sandboxes = Set(managed.keys)
        return f
    }
}
