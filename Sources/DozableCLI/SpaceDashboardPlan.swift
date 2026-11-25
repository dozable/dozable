// The dashboard's — not in a build without it (the helper; DOZ_NO_WEB), like UICommand.swift, which sets it up.
#if !DOZ_NO_WEB
import DozableChat
import DozableHost
import Foundation

/// The space view's plan (`POST /api/v1/workspace-space-plan`): the page's open text, planned as `doz workspace plan -f` plans
/// the file — in doz ui's process, where the CLI's resolver (and Yams) live — then the existing read-only `workspace-up-plan`
/// (in-process with no daemon; nothing written, none started). The file's path is the record's (`workspace-space`), never a
/// request's; the files beside it — `extends:` defaults files, `NAME.space.override.yaml`, `.env`, the brief, the
/// `prompt_file`s — are read under the space file's own rules (`SpaceRecordFile`: no link, a regular file of yours under your
/// home, never the store, `~/.claude` or `~/Library`). `${VAR}` comes from the `.env` beside the file only, never doz ui's
/// environment: a variable not found there is a warning, "set in your terminal, not known here". docs/engineering/web.md.
enum SpaceDashboardPlan {
    static let notKnownHere = "set in your terminal, not known here: the dashboard reads ${VAR} only from the .env beside the space file"

    static func plan(store: String, workspace: String, text: String,
                     send: @escaping @Sendable (HostRequest) async throws -> JSONValue) async throws -> SpacePlan {
        var read = HostRequest(.workspaceSpace)
        read.workspaceRequest = WorkspaceRequest(name: workspace)
        let file = try (try await send(read)).decode(WorkspaceSpaceFile.self)
        let path = file.path
        func underRules(_ p: String) -> String? {
            if p == path { return text }
            return try? SpaceRecordFile.read(.brief, p, store: store).text
        }
        var resolver = SpaceResolver()
        resolver.environment = [:]
        resolver.read = underRules
        var r = resolver.resolve(path)
        // A ${VAR} the .env does not set: the terminal may; this page cannot know — a warning, never a refusal of its own.
        for i in r.problems.indices where r.problems[i].message.hasPrefix("${") && r.problems[i].message.contains(" is not set") {
            r.problems[i].severity = "warning"
            r.problems[i].hint = notKnownHere
        }
        let (problems, model) = r.check()
        guard let model, !problems.contains(where: \.isError) else {
            var p = SpacePlan(space: r.spaceName.isEmpty ? workspace : r.spaceName, title: "", specPath: path, specSHA: "", sources: r.sources, factsKnown: false)
            p.problems = problems
            let errors = problems.filter(\.isError).count
            p.refusals = ["the space file has \(errors) error\(errors == 1 ? "" : "s")"]
            p.refusalCode = HostError.Code.invalid.rawValue
            return p
        }
        var q = HostRequest(.workspaceUpPlan)
        var space = r.request(profiles: [], brief: briefLook(model.brief, file: path, store: store))
        space.prompts = prompts(r, store: store)
        q.space = space
        var plan = try (try await send(q)).decode(SpacePlan.self)
        // Every problem at once, as the CLI prints them: each source's and the merged document's.
        plan.problems = problems + plan.problems.filter { p in !problems.contains(p) }
        return plan
    }

    /// The workspace drawn (`workspace-space`'s `picture`): the file's own text read with the CLI's reader and put in the
    /// renderer's words (`SpacePicture`); nil when it needs none, or does not read (the renderer then says why, from the text).
    static func picture(_ text: String) -> String? {
        guard let doc = SpaceResolver.parse(text, name: "").0, let d = SpacePicture.document(doc) else { return nil }
        return SpacePicture.text(d)
    }

    /// The brief beside the file, as a look (its sha256 and size, or why not) — read under the same rules; never its text.
    static func briefLook(_ brief: String, file: String, store: String) -> SpaceBriefLook? {
        guard !brief.isEmpty else { return nil }
        let dir = (file as NSString).deletingLastPathComponent
        let home = SpaceRecordFile.home()
        let expanded = brief == "~" ? home : brief.hasPrefix("~/") ? home + String(brief.dropFirst(1)) : brief
        let path = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL.path
        do {
            let r = try SpaceRecordFile.read(.brief, path, store: store)
            return SpaceBriefLook(path: path, sha256: r.sha256, bytes: r.bytes)
        } catch {
            return SpaceBriefLook(path: path, problem: HostError.from(error).message)
        }
    }

    /// The owned agents' `prompt_file`s beside the file (each read under the same rules; one that cannot be read is left out).
    static func prompts(_ r: SpaceResolver.Resolved, store: String) -> [String: String]? {
        var out: [String: String] = [:]
        let dir = (r.file as NSString).deletingLastPathComponent
        for m in SpaceDoc.members(SpaceDoc.member(r.filled, "agents")) {
            guard let pf = SpaceDoc.string(SpaceDoc.member(m.value, "prompt_file")) else { continue }
            let expanded = pf.hasPrefix("~/") ? SpaceRecordFile.home() + String(pf.dropFirst(1)) : pf
            let path = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL.path
            if let t = try? SpaceRecordFile.read(.brief, path, store: store).text, t.utf8.count <= WorkerLaunch.maximumTaskBytes { out[m.key] = t }
        }
        return out.isEmpty ? nil : out
    }
}
#endif
