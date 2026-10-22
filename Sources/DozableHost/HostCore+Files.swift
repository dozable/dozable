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
}
