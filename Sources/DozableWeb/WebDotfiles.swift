import Foundation
import DozableHost
import DozableKit

// 657 — the dashboard's view of the person's dotfiles: a sandbox's (its Home's Folder facts) and what New Sandbox's review
// shows before anything is made (`POST /api/v1/dotfiles/resolve` → the host's `dotfiles-resolve`: the commit, what runs).

/// A sandbox's dotfiles, field by field.
public struct WebDotfiles: Codable, Equatable, Sendable {
    /// The repository's URL, or the folder with `~`.
    public var source: String
    /// 12 hex.
    public var commit: String
    /// `applied` | `failed` | `pending`.
    public var state: String
    /// "install.sh ran (exit 0)", "12 linked, 2 kept (yours: …)".
    public var summary: String?
    public var at: Date?

    public init(_ d: DotfilesState) {
        source = d.display
        commit = String(d.commit.prefix(12))
        state = d.state
        summary = d.summary
        at = d.at
    }
}

/// `POST /api/v1/dotfiles/resolve`, decoded strictly: `{}` (the setting's dotfiles) or `{source}` — a repository's
/// https:// URL only (a folder on the Mac is named on the Mac, never by a page).
public struct WebDotfilesResolve: Equatable, Sendable {
    public var source: String?

    public static func decode(_ body: Data) throws -> WebDotfilesResolve {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["source"]) else { throw WebAction.Invalid("source only") }
        guard let v = d["source"], !(v is NSNull) else { return WebDotfilesResolve(source: nil) }
        guard let s = v as? String else { throw WebAction.Invalid("source: a repository's https:// URL") }
        let t = s.trimmingCharacters(in: .whitespaces)
        if DotfilesSource.isLocal(t) { throw WebAction.Invalid("source: a folder on the Mac is named on the Mac — here a repository's https:// URL") }
        if let why = DotfilesSource.problem(t) { throw WebAction.Invalid("source: \(why)") }
        guard !DotfilesSource.isNone(t) else { throw WebAction.Invalid("source: none — nothing to resolve") }
        return WebDotfilesResolve(source: t)
    }
}

/// What the review shows: the source, its head, its subject, what applying it does.
public struct WebDotfilesResolved: Codable, Equatable, Sendable {
    public var source: String
    public var commit: String
    public var subject: String?
    /// "install.sh runs as the sandbox's user", "12 dotfiles linked into ~ (never over a file that is there)".
    public var applies: String
    public var script: String?
    public var links: [String]
    public var local: Bool
    public var dirty: Bool?

    public init(_ r: DotfilesResolved) {
        source = r.display
        commit = String(r.commit.prefix(12))
        subject = r.subject
        applies = r.plan.summary
        script = r.plan.script
        links = Array(r.plan.links.prefix(24))
        local = r.local
        dirty = r.dirty
    }
}
