import CryptoKit
import Darwin
import DozableKit
import Foundation

/// 683 — a fenced session's conversations survive its teardown (owner, 2026-11-13: "transcript history … a valuable
/// artefact to leave behind"). For a PRIVATE agent folder, when the session ends, is forgotten, or the host first sees
/// its program ended or gone — idempotent by each file's content sha256 (`MacFenceRecord.carried`):
///
/// - **carried back** into the person's own config (`~/.claude/projects/<the folder>/`) — transcripts ONLY, never memory,
///   todos, snapshots or settings; nothing else there is created or touched (Claude Code loads a `memory/` by itself).
///   A file must be named `<uuid>.jsonl` (lower-case RFC 4122), hold one JSON object per line, every `cwd` field the
///   folder, be a regular one-link file of this user ≤ 64 MiB (≤ 1 GiB a session); anything else is skipped and named.
///   Read and written through `MacFenceHostFS` (no link in any component, the destination folder made 0700 and refused
///   when a component is a link), written to a temp name and renamed. A same-named file of the person's is REPLACED
///   when it is a byte-prefix of the new one (the same conversation, longer); otherwise it stays and the new one is
///   `<uuid>.doz-<tag>.jsonl`;
/// - **archived** under `keep`, in `<store>/mac-sessions/transcripts/<session>/<ended-at>/` (`doz sessions @mac
///   --transcripts S`, `--export DIR`); under `agent-default` not archived — the vendor's own rule applies to the
///   carried copies in its folder.
///
/// A carried conversation is text a fenced agent wrote: resumed in an UNFENCED agent, that context continues outside
/// the fence (said in the end message).
public enum MacTranscripts {
    public static let maximumFileBytes = 64 << 20
    public static let maximumSessionBytes = 1 << 30

    /// A transcript's name: `<uuid>.jsonl`, the uuid lower-case RFC 4122.
    public static func isTranscriptName(_ n: String) -> Bool {
        n.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.jsonl$", options: .regularExpression) != nil
    }

    /// Why `data` is not a transcript of `workdir` (nil: it is) — every non-empty line a JSON object, every `cwd` field
    /// present the folder.
    public static func contentProblem(_ data: Data, workdir: String) -> String? {
        var n = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            n += 1
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return "line \(n) is not a JSON object" }
            if let c = o["cwd"] {
                guard let cwd = c as? String, cwd == workdir else { return "line \(n) was written in another folder" }
            }
        }
        return nil
    }

    public struct Outcome: Sendable, Equatable {
        /// Carried into the person's folder (new, or a longer copy that replaced its prefix), and under another name.
        public var carried: [String] = []
        public var renamed: [String] = []
        /// Named with why.
        public var skipped: [String] = []
        public var archived: [String] = []
        /// `name:sha256` of every file now carried (the record's `carried`).
        public var done: [String] = []
        /// Where they went (the person's folder), and the archive folder (nil: none).
        public var destination: String?
        public var archive: String?
        public var refused: String?
    }

    /// Carry `agentDir`'s transcripts of `workdir` back into `personHome` (and, `archive` set, into the store's archive).
    /// `already`: `name:sha256` carried before (nothing is done twice).
    public static func carryBack(agentDir: String, personHome: String, folder rel: String, workdir: String, tag: String,
                                 archive: String?, already: Set<String>) -> Outcome {
        var out = Outcome()
        let from = agentDir + "/" + rel, to = personHome + "/" + rel
        out.destination = to
        guard MacFenceHostFS.kind(from) == S_IFDIR, let dfd = try? MacFenceHostFS.openDirectory(from) else { return out }
        let names = ((try? MacFenceHostFS.entries(dfd, path: from)) ?? []).sorted()
        close(dfd)
        var total = 0
        var destinationReady = false
        for n in names where !n.hasPrefix(".") {
            let path = from + "/" + n
            let kind = MacFenceHostFS.kind(path)
            if kind == S_IFDIR { out.skipped.append("\(n)/ (a folder — never carried)"); continue }
            guard n.hasSuffix(".jsonl") else { continue }
            guard isTranscriptName(n) else { out.skipped.append("\(n) (not a conversation's name)"); continue }
            let data: Data
            do { data = try MacFenceHostFS.readRegular(path, maximum: maximumFileBytes) } catch let r as MacFenceHostFS.Refusal {
                out.skipped.append("\(n) (\(r.why))"); continue
            } catch { out.skipped.append("\(n) (\(error))"); continue }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let key = n + ":" + sha
            if already.contains(key) { out.done.append(key); continue }
            total += data.count
            guard total <= maximumSessionBytes else { out.skipped.append("\(n) (over 1 GiB for one session)"); continue }
            if let why = contentProblem(data, workdir: workdir) { out.skipped.append("\(n) (\(why))"); continue }
            if !destinationReady {
                do { try MacFenceHostFS.ensureDirectory(to); destinationReady = true } catch let r as MacFenceHostFS.Refusal {
                    out.refused = "\(DisplayPath.tilde(to)): \(r.why)"
                    return out
                } catch { out.refused = "\(DisplayPath.tilde(to)): \(error)"; return out }
            }
            do {
                let wrote = try place(data, dir: to, name: n, tag: tag)
                if wrote == n { out.carried.append(n) } else if let w = wrote { out.renamed.append(w) }
                if let a = archive {
                    try MacFenceHostFS.ensureDirectory(a)
                    try MacFenceHostFS.writeAtomically(data, dir: a, name: n, mode: 0o600)
                    out.archived.append(n)
                }
                out.done.append(key)
            } catch let r as MacFenceHostFS.Refusal {
                out.skipped.append("\(n) (\(r.why))")
            } catch {
                out.skipped.append("\(n) (\(error))")
            }
        }
        if !out.archived.isEmpty { out.archive = archive }
        return out
    }

    /// Put `data` as `dir/name`: absent → written; the same bytes → nothing (nil); a byte-prefix of `data` → replaced;
    /// anything else → `<uuid>.doz-<tag>.jsonl` (by the same rules). Returns the name written (nil: nothing to do).
    static func place(_ data: Data, dir: String, name: String, tag: String) throws -> String? {
        let base = String(name.dropLast(".jsonl".count))
        for candidate in [name, "\(base).doz-\(tag).jsonl"] {
            let path = dir + "/" + candidate
            switch MacFenceHostFS.kind(path) {
            case nil:
                try MacFenceHostFS.writeAtomically(data, dir: dir, name: candidate, mode: 0o600)
                return candidate
            case S_IFREG?:
                let have = try MacFenceHostFS.readRegular(path, maximum: maximumFileBytes)
                if have == data { return nil }
                if data.starts(with: have) {
                    try MacFenceHostFS.writeAtomically(data, dir: dir, name: candidate, mode: 0o600)
                    return candidate
                }
                continue
            default:
                continue
            }
        }
        throw MacFenceHostFS.Refusal(path: dir + "/" + name, why: "a different conversation of that name is there twice — left")
    }

    // MARK: the archive

    /// One archived conversation (`doz sessions @mac --transcripts S`).
    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var endedAt: String
        public var bytes: Int
        /// Its file in the store (absolute).
        public var path: String
    }

    public struct Listing: Codable, Equatable, Sendable {
        public var session: String
        public var items: [Item]
        /// Where they were carried (the person's folder), when known.
        public var carriedTo: String?
    }

    /// `<store>/mac-sessions/transcripts/<session>`'s files, newest first — only regular `<uuid>.jsonl` files the host wrote.
    public static func list(_ root: String) -> [Item] {
        var out: [Item] = []
        for ended in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted(by: >) where !ended.hasPrefix(".") {
            let d = root + "/" + ended
            guard MacFenceHostFS.kind(d) == S_IFDIR else { continue }
            for n in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).sorted() where isTranscriptName(n) {
                var st = stat()
                guard lstat(d + "/" + n, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                out.append(Item(name: n, endedAt: ended, bytes: Int(st.st_size), path: d + "/" + n))
            }
        }
        return out
    }

    /// The archive folder's name for an end at `date` (UTC, sortable).
    public static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// The end message's words for an outcome (nil: nothing to say).
    public static func message(_ o: Outcome, setup: MacAgentSetup, session: String) -> String? {
        var parts: [String] = []
        if let r = o.refused { parts.append("its conversations were NOT copied back: \(r)") }
        let n = o.carried.count + o.renamed.count
        if n > 0, let to = o.destination {
            var t = "its conversations (written by a fenced session) are in \(DisplayPath.tilde(to))"
            if setup.history == AgentHistory.keep, !o.archived.isEmpty {
                t += " and Dozable's archive (doz sessions @mac --transcripts \(session))"
            } else if setup.history == AgentHistory.agentDefault, let d = setup.agentDefault {
                t += " — \(d)"
            }
            parts.append(t)
        }
        if !o.renamed.isEmpty { parts.append("kept beside yours under another name: " + o.renamed.joined(separator: ", ")) }
        if !o.skipped.isEmpty { parts.append("not copied back: " + o.skipped.prefix(8).joined(separator: "; ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
