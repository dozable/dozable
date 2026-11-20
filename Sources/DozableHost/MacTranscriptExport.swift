import CryptoKit
import Darwin
import DozableKit
import Foundation

/// `doz sessions @mac --transcripts S --export DIR`: a session's conversations copied out — the ONE copier for sessions on
/// this Mac, fenced and unfenced (`TranscriptCopy`).
///
/// - **Which files:** a fenced session's archive (Dozable's, in the store) and its own carried copies in the person's
///   folder — exactly the `name:sha256` its record says were carried, and only while that sha256 still matches; an
///   unfenced session's recorded conversations — exactly `<projects>/<the folder's name>/<id>.jsonl` for each id its
///   record holds (`claudeSessionIDs`). A folder is never listed to find a file: another session's conversation in the
///   same folder is never copied. No recorded id: nothing, and it is said.
/// - **How:** each file read with no link in any component of its path (`O_NOFOLLOW_ANY`), then `fstat`: a regular
///   file, one link, this user's, at most 64 MiB; a conversation's name is `<uuid>.jsonl` and every line's `cwd` the
///   session's folder; then the leak sweep (`ExportSweep`); then written into an `ExportFolder` (`openat`, `O_CREAT |
///   O_EXCL | O_NOFOLLOW`, 0600 — never over a file). `manifest.json` names each file, where it came from, the sha256
///   of the source and of the copy (they differ only when the sweep removed something) and its size.
public enum MacTranscriptExport {
    /// The session's own files outside the archive, and what to say. Pure apart from looking whether each named file is
    /// there (never a listing).
    public static func ownFiles(_ rec: MacSessionRecord, carriedTo: String?, projects: String) -> (items: [MacTranscripts.Item], notes: [String]) {
        var items: [MacTranscripts.Item] = []
        var notes: [String] = []
        if let f = rec.fence {
            guard let to = carriedTo, let dir = MacFencePaths.resolve(to) else { return (items, notes) }
            for key in f.carried ?? [] {
                guard let colon = key.lastIndex(of: ":") else { continue }
                let name = String(key[..<colon]), sha = String(key[key.index(after: colon)...])
                guard MacTranscripts.isTranscriptName(name) else { continue }
                let base = String(name.dropLast(".jsonl".count))
                let found = [name, "\(base).doz-\(f.tag).jsonl"].first { MacFenceHostFS.kind(dir + "/" + $0) == S_IFREG }
                if let n = found {
                    items.append(.init(name: name, endedAt: "", bytes: 0, path: dir + "/" + n, source: "carried", sha256: sha))
                } else {
                    notes.append("\(name) was carried back to \(DisplayPath.tilde(to)) and is no longer there")
                }
            }
            return (items, notes)
        }
        let ids = rec.claudeSessionIDs ?? rec.claudeSessionID.map { [$0] } ?? []
        guard !ids.isEmpty else {
            notes.append("no conversation of this session was recorded (only a Claude Code session's is, once it has started one)")
            return (items, notes)
        }
        guard let root = MacFencePaths.resolve(projects) else {
            notes.append("no Claude Code conversations folder on this Mac")
            return (items, notes)
        }
        var dirs = [rec.workdir]
        if let r = MacFencePaths.resolve(rec.workdir), r != rec.workdir { dirs.append(r) }
        for id in ids {
            let name = id.lowercased() + ".jsonl"
            guard MacTranscripts.isTranscriptName(name) else { continue }
            let found = dirs.map { root + "/" + MacPlace.claudeProjectFolderName($0) + "/" + name }.first { MacFenceHostFS.kind($0) != nil }
            if let p = found {
                items.append(.init(name: name, endedAt: "", bytes: 0, path: p, source: "conversation"))
            } else {
                notes.append("conversation \(id) is not in Claude Code's folder for \(DisplayPath.tilde(rec.workdir))")
            }
        }
        return (items, notes)
    }

    /// What `manifest.json` holds (version 1). Never a token.
    public struct Manifest: Codable, Equatable, Sendable {
        public struct File: Codable, Equatable, Sendable {
            public var name: String
            public var source: String
            public var sourceSHA256: String
            public var sha256: String
            public var bytes: Int
        }
        public struct Skipped: Codable, Equatable, Sendable { public var name: String; public var why: String }
        public var version = 1
        public var session: String
        public var files: [File] = []
        public var skipped: [Skipped]?
        public var notes: [String]?
        public var sweep: ChatExportManifest.Sweep = .init(findings: [], redacted: 0)
        public var exportedAt = Date()

        public func bytes() -> [UInt8] { Array(((try? ChatExportManifest.encoder.encode(self)) ?? Data()) + Data("\n".utf8)) }
    }

    /// Copies every file of `listing` into `folder` (archive, carried and recorded conversations), swept; writes
    /// `manifest.json`.
    public static func export(_ listing: MacTranscripts.Listing, into folder: ExportFolder, sweep: ExportSweep) throws -> Manifest {
        var m = Manifest(session: listing.session)
        var skipped: [Manifest.Skipped] = []
        let all = listing.items.map { ($0, "\($0.endedAt)-\($0.name)", "archive") }
            + (listing.conversations ?? []).map { ($0, $0.source == "carried" ? "carried-\($0.name)" : $0.name, $0.source ?? "conversation") }
        for (item, out, source) in all {
            switch TranscriptCopy.read(item.path, name: item.name, workdir: source == "archive" ? nil : listing.workdir) {
            case .failure(let r):
                skipped.append(.init(name: out, why: r.why))
            case .success(let data):
                let sourceSHA = TranscriptCopy.sha256(data)
                if let want = item.sha256, want != sourceSHA {
                    skipped.append(.init(name: out, why: "it changed since it was carried back (not this session's copy any more)"))
                    continue
                }
                let c = sweep.clean(Array(data), file: out)
                m.sweep.findings += c.findings
                let sha = try folder.write(out, c.bytes)
                m.files.append(.init(name: out, source: source, sourceSHA256: sourceSHA, sha256: sha, bytes: c.bytes.count))
            }
        }
        m.sweep.redacted = m.sweep.findings.count
        m.skipped = skipped.isEmpty ? nil : skipped
        m.notes = listing.notes
        try folder.write("manifest.json", m.bytes())
        return m
    }
}

/// One transcript read for a copy: no link anywhere in its path, `fstat` a regular one-link file of this user, at most
/// 64 MiB; with `workdir`, a conversation (`<uuid>.jsonl`, every line's `cwd` that folder or its resolved form).
public enum TranscriptCopy {
    public struct Refused: Error, Equatable, Sendable { public var why: String }

    public static func read(_ path: String, name: String, workdir: String?) -> Result<Data, Refused> {
        let data: Data
        do { data = try MacFenceHostFS.readRegular(path, maximum: MacTranscripts.maximumFileBytes) } catch let r as MacFenceHostFS.Refusal {
            return .failure(Refused(why: r.why))
        } catch { return .failure(Refused(why: "\(error)")) }
        if let w = workdir {
            guard MacTranscripts.isTranscriptName(name) else { return .failure(Refused(why: "not a conversation's name")) }
            var problem = MacTranscripts.contentProblem(data, workdir: w)
            if problem != nil, let r = MacFencePaths.resolve(w), r != w { problem = MacTranscripts.contentProblem(data, workdir: r) }
            if let p = problem { return .failure(Refused(why: p)) }
        }
        return .success(data)
    }

    public static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
