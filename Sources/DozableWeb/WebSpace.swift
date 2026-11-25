import DozableHost
import Foundation

/// A space workspace in the dashboard — its file, its plan and its state. Three payload-less read routes (the workspace in
/// the body, strictly decoded, its name by the store's rule before any call — never a path: the file is always the record's),
/// each EXACTLY ONE read-only HostOp the CLI also sends:
///   `POST /api/v1/workspace-space` → `workspace-space` (`doz workspace show W --space --json`), the text with its sha256 and
///     `canSave` (this Mac's own browser only — another computer reads it with serve.chat read or write, never saves);
///   `POST /api/v1/workspace-space-plan` `{workspace, text}` → the page's open text planned: `DozableWebData.spacePlan` reads
///     the record's path and the files beside it (extends, override, `.env` — `${VAR}` from that `.env` only, never doz ui's
///     environment), then sends the existing `workspace-up-plan` (in-process with no daemon); the same exposure;
///   `POST /api/v1/workspace-state` → `workspace-state` (`doz workspace state W --json`; this Mac's sessions as
///     serve.mac_sessions allows);
///   `POST /api/v1/workspace-run-frames` `{workspace, run}` → `workspace-run-frames` (`doz workspace runs W --frames RUN
///     --json`): a run's frames, each projected the same way, and its archive checked now.
/// The one change, `workspace-space-save` (a `WebAction`), is this Mac's own browser's only (`WebExposure.decideSpaceAction`).
public enum WebSpace {
    static let readFields: Set<String> = ["workspace"]
    static let planFields: Set<String> = ["workspace", "text"]
    static let framesFields: Set<String> = ["workspace", "run"]
    /// The plan route's body: a space file of at most 256 KiB, as JSON text (its escapes) and its name.
    public static let maximumPlanBody = 400 << 10

    public static func decodeRead(_ body: Data) throws -> WorkspaceRequest {
        WorkspaceRequest(name: try WebWorkspaceViews.object(body, readFields).workspaceName("workspace"))
    }

    public static func decodeFrames(_ body: Data) throws -> WorkspaceRequest {
        let f = try WebWorkspaceViews.object(body, framesFields)
        var w = WorkspaceRequest(name: try f.workspaceName("workspace"))
        w.run = try f.required(f.matching("run", "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{1,6}$", "a run's id"), "run")
        return w
    }

    public static func decodePlan(_ body: Data) throws -> (workspace: String, text: String) {
        let f = try WebWorkspaceViews.object(body, planFields)
        let w = try f.workspaceName("workspace")
        return (w, try spaceText(f, "text"))
    }

    /// A space file's text from a browser: at most 256 KiB of UTF-8, no control characters but line breaks and tabs.
    static func spaceText(_ f: WebAction.Fields, _ key: String) throws -> String {
        guard let s = f.d[key] as? String else { throw WebAction.Invalid("\(key) is required: the space file's text") }
        guard s.utf8.count <= SpaceRecordFile.maximumBytes else { throw WebAction.Invalid("\(key): at most 256 KiB") }
        guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0) }) else {
            throw WebAction.Invalid("\(key): no control characters but line breaks and tabs")
        }
        return s
    }

    /// The workspace drawn: a space file's text in the words the vendored renderer reads (`SpacePicture` — Dozable's places
    /// and feeds translated), nil when the text already is. The CLI's reader parses it (Yams is the CLI's alone): `doz ui`
    /// installs it before serving, as it does the project files' parser; with none installed the picture is the file's text.
    public typealias PictureReader = @Sendable (String) -> String?
    private static let pictureLock = NSLock()
    nonisolated(unsafe) private static var pictureReader: PictureReader?
    public static func installPictureReader(_ r: @escaping PictureReader) { pictureLock.withLock { pictureReader = r } }
    public static func picture(_ text: String) -> String? { pictureLock.withLock({ pictureReader })?(text) }

    /// The request each read sends — the CLI's own.
    public static func request(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return r
    }
}

/// `POST /api/v1/workspace-space`'s answer: the file as it is now (its path shown with `~`, never the absolute one) and
/// whether this browser may save it; `picture`, when the renderer needs other words for it (`WebSpace.picture`): what the
/// workspace's pictures draw (the editor and the plan always take `text`).
public struct WebSpaceFile: Codable, Equatable, Sendable {
    public var workspace: String
    public var file: String
    public var shownPath: String
    public var text: String
    public var sha256: String
    public var bytes: Int
    public var canSave: Bool
    /// When it may not: what to do instead.
    public var command: String?
    public var picture: String?
    public init(_ f: WorkspaceSpaceFile, canSave: Bool, picture: String? = nil) {
        workspace = f.workspace; file = f.file; shownPath = f.shownPath; text = f.text; sha256 = f.sha256; bytes = f.bytes
        self.canSave = canSave
        command = canSave ? nil : "doz workspace edit \(f.workspace) --space-file \(f.shownPath) --if-match \(f.sha256)"
        self.picture = picture
    }
}
