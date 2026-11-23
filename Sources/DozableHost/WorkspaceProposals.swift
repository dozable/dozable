import Foundation

// 766: the work description — a workspace's brief plus its ADDENDA — and PROPOSALS to change it (docs/engineering/
// workspace-model.md, "The unit of work"; workspaces.md, "The work description and proposals"). Bring your own process:
// Dozable keeps the primitives and the permissions (`description.propose`, `description.decide`, `description.edit` — off
// for an agent until granted; the owner is never gated) and enforces no process.
//
// - An addendum `{run?, at, by, text}` is appended to the work description without rewriting the brief (the record's
//   `addenda`; the document's `brief.addenda`). Each is a change of the description: one more revision (`addendum-added`
//   in the log — its size and hash, never its text).
// - A proposal `{id, origin, state, change: {addendum}, by, at, source: {run}}` changes nothing until it is decided:
//   applied (its addendum added, `{run: source.run, by: proposer}`) or declined — by the owner answering its Ask in the
//   workspace's main room (Dozable's own ask, ChatSystemAsks.swift), or `doz workspace decide`. Kept in the workspace's
//   record folder (`proposals.json`), so they outlive a daemon restart.
// - A run with no goal takes the brief AND its addenda (`WorkDescription.goal`).

/// One addendum of the work description.
public struct WorkspaceAddendum: Codable, Equatable, Sendable {
    /// The run it came from (a lesson's), when one is named.
    public var run: String?
    public var at: Date
    /// `owner`, or the agent's name.
    public var by: String
    public var text: String
    public init(run: String? = nil, at: Date = Date(), by: String, text: String) { self.run = run; self.at = at; self.by = by; self.text = text }
}

public enum WorkDescription {
    /// The longest addendum.
    public static let maximumAddendumBytes = 16 << 10

    /// An addendum as typed: not empty, at most `maximumAddendumBytes` (else `invalidValue`, 65).
    public static func checkAddendum(_ text: String?) throws -> String {
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostError(.invalidValue, "the addendum is empty — say the lesson or note to add (--addendum TEXT)")
        }
        guard t.utf8.count <= maximumAddendumBytes else {
            throw HostError(.invalidValue, "the addendum is \(t.utf8.count) bytes — at most \(maximumAddendumBytes)")
        }
        return t
    }

    /// What a run with no goal takes: the brief, then each addendum as a line of its own under one heading (none: the brief).
    public static func goal(brief: String, addenda: [WorkspaceAddendum]) -> String {
        guard !addenda.isEmpty else { return brief }
        var s = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "\n\nAddenda to the work description:\n"
        s += addenda.map { a in
            "- " + a.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n  ")
                + (a.run.map { " (from run \($0))" } ?? "")
        }.joined(separator: "\n")
        return s + "\n"
    }
}

/// A proposal to change the work description (kind `WorkspaceProposal` — the record kept and the `--json` answer).
public struct WorkspaceProposal: Codable, Equatable, Sendable {
    public static let kind = "WorkspaceProposal"
    public static let states = ["open", "applied", "declined"]

    public struct Change: Codable, Equatable, Sendable {
        public var addendum: String
        public init(addendum: String) { self.addendum = addendum }
    }

    public struct Source: Codable, Equatable, Sendable {
        public var run: String?
        public init(run: String?) { self.run = run }
    }

    public var kind = WorkspaceProposal.kind
    public var id: String
    public var workspace: String
    /// `retro` (`doz workspace retro W --propose`).
    public var origin: String
    /// `open`, `applied` or `declined`.
    public var state: String
    public var change: Change
    /// Who proposed it: `owner`, or the agent's name.
    public var by: String
    public var at: Date
    public var source: Source
    /// Its Ask in the main room: the ask's msg_id, its number and its room (nil: none was posted — chat not ready, or no room).
    public var askId: String?
    public var askNumber: Int?
    public var room: String?
    /// How it was decided: `ask` (answered in chat), `decide` (`doz workspace decide`), `expired` (its Ask expired: declined).
    public var decidedBy: String?
    public var decidedAt: Date?
    public var decidedHow: String?
    /// Said in the answer only (never kept).
    public var notes: [String]?

    public init(id: String, workspace: String, origin: String = "retro", by: String, text: String, run: String?, at: Date = Date()) {
        self.id = id; self.workspace = workspace; self.origin = origin; state = "open"; change = Change(addendum: text)
        self.by = by; self.at = at; source = Source(run: run)
    }

    public var isOpen: Bool { state == "open" }

    /// A new id: `pr-` and 8 hex digits, not one of `existing`.
    public static func newID(existing: [WorkspaceProposal]) -> String {
        while true {
            let id = String(format: "pr-%08x", UInt32.random(in: 0...UInt32.max))
            if !existing.contains(where: { $0.id == id }) { return id }
        }
    }

    /// An id as typed (checked before it is looked up).
    public static func isValidID(_ s: String) -> Bool { s.range(of: "^pr-[0-9a-f]{8}$", options: .regularExpression) != nil }

    /// The Ask's question: what is proposed, by whom, from which run.
    public func question(workspace: String) -> String {
        "Apply this lesson to the work description of \(workspace)?\n\n\(change.addendum.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            + "Proposed by \(by)" + (source.run.map { " after run \($0)" } ?? "") + " (\(id)). Apply adds it to the brief's addenda; decline changes nothing."
    }

    /// The line Dozable posts when the proposal is decided another way (its Ask closes with it).
    public func outcomeLine() -> String {
        "Proposal \(id) was \(state == "applied" ? "applied: the lesson is added to the work description" : "declined: the work description is unchanged")"
            + (decidedBy.map { " (decided by \($0) with doz workspace decide)" } ?? "") + "."
    }
}

/// `<store>/workspaces/<name>/proposals.json`: a workspace's proposals, oldest first. Versioned and additive.
public struct WorkspaceProposalsFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "proposals.json"
    public static let maximumBytes = 8 << 20
    public var version: Int
    public var proposals: [WorkspaceProposal]
    public init(proposals: [WorkspaceProposal] = []) { version = Self.currentVersion; self.proposals = proposals }

    /// The file of `name` (none: empty).
    public static func read(_ ws: WorkspaceStore, _ name: String) throws -> WorkspaceProposalsFile {
        try WorkspaceName.validate(name)
        let path = ws.folder(name) + "/" + fileName
        guard MacFenceHostFS.kind(path) != nil else { return WorkspaceProposalsFile() }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(path, maximum: maximumBytes) } catch {
            throw HostError(.failed, "the proposals of \(name) cannot be read: \(error)")
        }
        do { return try HostWire.decoder.decode(WorkspaceProposalsFile.self, from: d) } catch {
            throw HostError(.failed, "the proposals of \(name) cannot be read: \(error.localizedDescription)")
        }
    }

    /// Written atomically, 0600, beside the record.
    public func write(_ ws: WorkspaceStore, _ name: String) throws {
        try WorkspaceName.validate(name)
        var stripped = self
        stripped.version = max(version, Self.currentVersion)
        for i in stripped.proposals.indices { stripped.proposals[i].notes = nil }
        var d = try HostWire.prettyEncoder.encode(stripped)
        d.append(0x0A)
        try MacFenceHostFS.writeAtomically(d, dir: ws.folder(name), name: Self.fileName)
    }
}

/// `doz workspace proposals W --json` (kind `WorkspaceProposals`).
public struct WorkspaceProposals: Codable, Equatable, Sendable {
    public static let kind = "WorkspaceProposals"
    public var kind = WorkspaceProposals.kind
    public var workspace: String
    public var proposals: [WorkspaceProposal]
    public init(workspace: String, proposals: [WorkspaceProposal]) { self.workspace = workspace; self.proposals = proposals }
}

/// `doz workspace edit W --addendum TEXT --json` (kind `WorkspaceAddendum`): the addendum added and the description's
/// revision now.
public struct WorkspaceAddendumAdded: Codable, Equatable, Sendable {
    public static let kind = "WorkspaceAddendum"
    public var kind = WorkspaceAddendumAdded.kind
    public var workspace: String
    public var addendum: WorkspaceAddendum
    public var revision: Int
    public var addenda: Int
    public init(workspace: String, addendum: WorkspaceAddendum, revision: Int, addenda: Int) {
        self.workspace = workspace; self.addendum = addendum; self.revision = revision; self.addenda = addenda
    }
}
