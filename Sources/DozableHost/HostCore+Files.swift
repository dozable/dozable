import Foundation
import DozableKit

// 643: `files-list` — one folder of a sandbox's /workspace (WorkspaceFileList.swift has the model and the rules). Looking
// never wakes: a shared workspace is read on the Mac in any phase; an isolated one only while it RUNS — an exec in a
// sleeping guest would mean waking it, so that is refused, and nothing is started either.

extension HostCore {
    func filesList(_ r: HostRequest) async throws -> FileList {
        let m = try get(r.name)
        guard let (guest, rel) = FileListPaths.folder(r.filePath) else {
            throw HostError(.invalid, "not a folder in /workspace: \(FileListPaths.shown(r.filePath)) (a path relative to /workspace, or /workspace/…)")
        }
        if let w = m.config.workspace {
            let rules = MacFolderListing.rules(workspace: w, mode: Self.ruleMode(m.config).mode, viewOn: Self.workspaceViewOn(m.config))
            // The folder is read off the actor (a large one takes a moment; nothing else waits on it).
            let listed = try await Task.detached { try MacFolderListing.list(workspace: w, rel: rel, rules: rules) }.value
            return FileList(sandbox: m.name, path: guest, source: "mac", watch: "mac", rules: rules != nil, state: listed.state,
                            entries: listed.entries, truncated: listed.truncated)
        }
        let phase = await effectivePhase(m)
        guard phase == .running else {
            throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — an isolated sandbox's files are on its own disk: "
                                           + "they are listed while it runs (listing never wakes or starts it)")
        }
        guard !readOnly else { throw HostError(.unavailable, "listing an isolated sandbox's files needs the host") }
        guard await !m.sandbox.status.busy else { throw HostError(.invalidPhase, "\(m.name) is busy — list again in a moment") }
        let user = m.config.spec.imageSpec?.user
        let res = try await m.sandbox.exec(["sh", "-c", GuestFolderListing.script(guest)], user: user, timeoutSeconds: 15)
        switch GuestFolderListing.parse(res.output) {
        case .missing: throw HostError(.notFound, "no such folder in \(m.name): \(guest)")
        case .notDirectory: throw HostError(.invalid, "\(guest) in \(m.name) is not a folder")
        case .denied: throw HostError(.failed, "\(guest) in \(m.name) cannot be read by \(user ?? "root")")
        case .unreadable:
            let why = CopyPaths.tarError(res.errorOutput) ?? "no answer"
            throw HostError(.failed, "could not list \(guest) in \(m.name): \(why)")
        case .ok(let entries, let total, let unlisted):
            return FileList(sandbox: m.name, path: guest, source: "guest", watch: "none", rules: false, entries: entries,
                            truncated: total > entries.count, unlisted: unlisted > 0 ? unlisted : nil)
        }
    }

    // MARK: 644 — the panel's changes

    /// `files-mkdir` / `files-new` / `files-move` / `files-rm` (WorkspaceFileChange.swift). A shared workspace: on the Mac,
    /// in any phase (in-process too — this never starts a host or wakes anything); an isolated one: inside, while it runs.
    func fileChange(_ r: HostRequest) async throws -> FileChangeResult {
        let m = try get(r.name)
        guard let item = FileItemPath.parse(r.filePath) else {
            throw HostError(.invalid, "not a file or folder in /workspace: \(FileListPaths.shown(r.filePath)) (/workspace itself is never changed)")
        }
        let action: String = switch r.op { case .filesMkdir: "mkdir"; case .filesNew: "new"; case .filesMove: "move"; default: "rm" }
        var to: FileItemPath?
        if r.op == .filesMove {
            guard let t = FileItemPath.parse(r.fileTarget) else {
                throw HostError(.invalid, "where to? a path in /workspace, the new name included: \(FileListPaths.shown(r.fileTarget))")
            }
            to = t
        }
        let recursive = r.recursive == true
        let folders = Array(Set([item.parentGuest] + (to.map { [$0.parentGuest] } ?? []))).sorted()
        if let w = m.config.workspace {
            let rules = MacFolderListing.rules(workspace: w, mode: Self.ruleMode(m.config).mode, viewOn: Self.workspaceViewOn(m.config))
            let dest = to
            let done = try await Task.detached { () throws -> (String, Int?) in
                switch action {
                case "mkdir": return (try MacFileChange.mkdir(workspace: w, item: item, rules: rules), nil)
                case "new": return (try MacFileChange.create(workspace: w, item: item, rules: rules), nil)
                case "move": return (try MacFileChange.move(workspace: w, item: item, to: dest!, rules: rules), nil)
                default:
                    let x = try MacFileChange.remove(workspace: w, item: item, recursive: recursive, rules: rules)
                    return (x.kind, x.items)
                }
            }.value
            return FileChangeResult(sandbox: m.name, action: action, path: item.guest, to: to?.guest, kind: done.0, items: done.1,
                                    folders: folders, source: "mac")
        }
        let phase = await effectivePhase(m)
        guard phase == .running else {
            throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — an isolated sandbox's files are on its own disk: "
                                           + "they are changed while it runs (this never wakes or starts it)")
        }
        guard !readOnly else { throw HostError(.unavailable, "changing an isolated sandbox's files needs the host") }
        guard await !m.sandbox.status.busy else { throw HostError(.invalidPhase, "\(m.name) is busy — try again in a moment") }
        let user = m.config.spec.imageSpec?.user
        let res = try await m.sandbox.exec(["sh", "-c", GuestFileChange.script(action, item: item, to: to, recursive: recursive)],
                                           user: user, timeoutSeconds: 30)
        switch GuestFileChange.parse(res.output) {
        case .ok(let kind, let count):
            return FileChangeResult(sandbox: m.name, action: action, path: item.guest, to: to?.guest, kind: kind,
                                    items: action == "rm" ? (count ?? 1) : nil, folders: folders, source: "guest")
        case .refused(let why):
            throw GuestFileChange.explain(why, item: item, to: to, sandbox: m.name, user: user)
        case .unreadable:
            let why = CopyPaths.tarError(res.errorOutput) ?? "no answer"
            throw HostError(.failed, "could not change \(item.guest) in \(m.name): \(why)")
        }
    }

    /// `files-open`: a file of a shared workspace in its default app, a folder in the Finder, or `reveal` — the open-files
    /// bridge's decision (and its test seam), the rules on top. Runs in the asking process (it is the Mac's screen).
    func fileOpen(_ r: HostRequest) async throws -> FileChangeResult {
        let m = try get(r.name)
        guard let (guest, _) = FileListPaths.folder(r.filePath) else {
            throw HostError(.invalid, "not a path in /workspace: \(FileListPaths.shown(r.filePath))")
        }
        guard let w = m.config.workspace else {
            throw HostError(.invalid, "\(m.name) is isolated — its files are inside it; copy one out with doz get \(m.name) \(guest)")
        }
        let enabled = Self.sandboxValue(m.config, SettingKey.openFiles) != .string("off")
        let rules = MacFolderListing.rules(workspace: w, mode: Self.ruleMode(m.config).mode, viewOn: Self.workspaceViewOn(m.config))
        let reveal = r.reveal == true
        // 646: an editor (`--app`) — a known one installed here, or a `bridges.open_apps` name (read now, like the bridge).
        let app = r.app
        let openApps = app == nil ? [] : (WorkspaceFiles.appNames(DozableSettings.load().string(SettingKey.openApps) ?? "") ?? [])
        let said = try await Task.detached {
            try MacFileChange.open(workspace: w, guestPath: guest, reveal: reveal, enabled: enabled, rules: rules, app: app, openApps: openApps)
        }.value
        return FileChangeResult(sandbox: m.name, action: reveal ? "reveal" : "open", path: guest, folders: [], source: "mac", message: said)
    }

    /// 646 `editors`: what `files-open`'s `app` takes on this Mac. LaunchServices is asked off the actor (read-only).
    func editors() async -> [EditorApps.Editor] {
        let openApps = WorkspaceFiles.appNames(DozableSettings.load().string(SettingKey.openApps) ?? "") ?? []
        return await Task.detached { EditorApps.installed(openApps: openApps) }.value
    }
}
