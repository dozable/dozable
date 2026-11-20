import Foundation

// A space workspace's file, read and saved by the daemon — the dashboard's space view and `doz workspace show W --space`,
// `doz workspace edit W --space-file F --if-match SHA`. The path is the record's (`space.path`), never a request's; every
// read and write is `SpaceRecordFile`'s (no link, a regular file of yours under your home, never the store, `~/.claude` or
// `~/Library`, at most 256 KiB of UTF-8 starting with its format line). A save is checked against the file as it is now
// (`ifMatch`, hashed through the descriptor it is read by): changed since → refused, nothing written. Saving never runs up —
// up applies it. docs/engineering/workspaces.md ("Space files").

/// `workspace-space`'s answer: the space file as it is now. `path` is absolute (every JSON field is); `shownPath` with `~`.
public struct WorkspaceSpaceFile: Codable, Equatable, Sendable {
    public var workspace: String
    public var file: String
    public var path: String
    public var shownPath: String
    public var text: String
    public var sha256: String
    public var bytes: Int
    public init(workspace: String, file: String, path: String, shownPath: String, text: String, sha256: String, bytes: Int) {
        self.workspace = workspace; self.file = file; self.path = path; self.shownPath = shownPath; self.text = text; self.sha256 = sha256
        self.bytes = bytes
    }
}

/// `workspace-space-save`'s answer: what was written — never applied.
public struct WorkspaceSpaceSaved: Codable, Equatable, Sendable {
    public var workspace: String
    public var file: String
    public var shownPath: String
    public var sha256: String
    public var bytes: Int
    /// Always false: saving never runs up.
    public var applied: Bool
    public var note: String
}

extension HostCore {
    /// The record's space file: its path, from the record alone.
    func spaceFilePath(_ n: String) throws -> (WorkspaceRecord, String) {
        let rec = try workspaceRecord(n)
        guard let ref = SpaceRecordRef.of(rec), let p = ref.path, !p.isEmpty else { throw HostError(.notFound, "\(n) was not made from a space file") }
        return (rec, p)
    }

    /// `workspace-space`: read-only, in-process with no daemon.
    func workspaceSpaceFile(_ w: WorkspaceRequest) throws -> WorkspaceSpaceFile {
        let n = try workspaceName(w)
        let (_, path) = try spaceFilePath(n)
        let r = try SpaceRecordFile.read(.space, path, store: storeRoot)
        return WorkspaceSpaceFile(workspace: n, file: (path as NSString).lastPathComponent, path: path, shownPath: DisplayPath.tilde(path),
                                  text: r.text, sha256: r.sha256, bytes: r.bytes)
    }

    /// `workspace-space-save`: the daemon's, under the space's gate (never beside an up of it).
    func workspaceSpaceSave(_ w: WorkspaceRequest) async throws -> WorkspaceSpaceSaved {
        guard !readOnly else { throw HostError(.unavailable, "workspace-space-save needs the daemon") }
        let n = try workspaceName(w)
        guard let text = w.text else { throw HostError(.invalid, "workspace-space-save needs the file's new text") }
        guard let want = w.ifMatch, want.count == 64, want.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw HostError(.invalid, "workspace-space-save needs the sha256 of the file as you read it (ifMatch, 64 lower-case hex digits)")
        }
        await workspaceGate.lock("space:" + n)
        defer { workspaceGate.unlock("space:" + n) }
        let (_, path) = try spaceFilePath(n)
        let wrote = try SpaceRecordFile.write(.space, text, to: path, ifSHA: want, store: storeRoot)
        try? workspaces.append(n, WorkspaceLogEntry(action: "space-saved", sha256: wrote.sha256, bytes: wrote.bytes))
        note(nil, "workspace \(n): its space file saved (\(wrote.bytes) bytes; not applied)")
        return WorkspaceSpaceSaved(workspace: n, file: (path as NSString).lastPathComponent, shownPath: DisplayPath.tilde(path), sha256: wrote.sha256,
                                   bytes: wrote.bytes, applied: false,
                                   note: "Saved. Not applied: doz workspace up -f \(DisplayPath.tilde(path)) applies it.")
    }
}
