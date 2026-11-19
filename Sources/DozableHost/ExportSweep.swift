import CryptoKit
import Darwin
import DozableChat
import Foundation

// What every export doz writes passes through before a byte of it reaches its folder (a chat export, a transcript
// export): no chat token, ever. A live token is found WITHOUT its plaintext — every run of 16 to 256 characters that
// could be one is hashed and compared with the store's token hashes (`tokens.json`) — and replaced by
// "[a chat token of NAME, removed by doz]"; the manifest and the command's words name the participant and the fix
// (`doz chat token NAME --new`), never the value. Other secrets that look like one (an Authorization Bearer value, an
// `sk-` key, the credential vault's placeholder) are replaced the same way. `ExportSweepTests`.

public struct ExportSweep: Sendable {
    /// One thing found and removed: where, what kind, and for a chat token whose it is. Never the value.
    public struct Finding: Codable, Equatable, Sendable {
        public var file: String
        public var kind: String
        public var participant: String?
        public init(file: String, kind: String, participant: String? = nil) { self.file = file; self.kind = kind; self.participant = participant }

        /// What a person reads (stdout of the export): what was removed and what to do.
        public var sentence: String {
            switch kind {
            case "chat-token": return "\(file): a live chat token of \(participant ?? "?") was removed — doz chat token \(participant ?? "NAME") --new replaces it"
            case "bearer": return "\(file): an Authorization Bearer value was removed"
            case "api-key": return "\(file): something that looks like an API key (sk-…) was removed"
            case "placeholder": return "\(file): a credential placeholder (doz_cred_…) was removed"
            default: return "\(file): a secret was removed"
            }
        }
    }

    /// sha256 hex → the participant's name.
    let byHash: [String: String]

    public init(tokenHashes: [String: String]) {
        var m: [String: String] = [:]
        for (name, h) in tokenHashes { m[h] = name }
        byHash = m
    }

    /// The store's chat token hashes (none when chat was never on).
    public static func forStore(_ store: DozableStore) -> ExportSweep {
        ExportSweep(tokenHashes: (try? ChatTokenHashes.load(ChatPaths(store: store)))?.sha256 ?? [:])
    }

    public static func replacement(for name: String) -> String { "[a chat token of \(name), removed by doz]" }

    /// The bytes with every secret replaced, and what was found. `file`: the name the findings carry.
    public func clean(_ input: [UInt8], file: String) -> (bytes: [UInt8], findings: [Finding]) {
        var cuts: [(Range<Int>, [UInt8], Finding)] = []
        // Chat tokens, by their hashes: runs of the narrow alphabet (dzc_ tokens and most others), runs of anything but
        // white space and JSON's quote and backslash (a token someone chose), and the 47 characters from each "dzc_".
        if !byHash.isEmpty {
            func consider(_ r: Range<Int>) {
                guard (ChatSecrets.minimumTokenLength...256).contains(r.count), !cuts.contains(where: { $0.0.overlaps(r) }) else { return }
                let h = SHA256.hash(data: input[r]).map { String(format: "%02x", $0) }.joined()
                if let name = byHash[h] {
                    cuts.append((r, Array(Self.replacement(for: name).utf8), Finding(file: file, kind: "chat-token", participant: name)))
                }
            }
            for r in Self.runs(input, Self.isNarrow) { consider(r) }
            for r in Self.runs(input, Self.isWide) { consider(r) }
            let prefix = Array("dzc_".utf8)
            var i = 0
            while i + 47 <= input.count {
                if input[i] == prefix[0] && Array(input[i..<i + 4]) == prefix { consider(i..<i + 47) }
                i += 1
            }
        }
        // Other secrets, by their shape.
        let text = String(decoding: input, as: UTF8.self)
        if Array(text.utf8) == input {
            for (kind, pattern, group) in Self.patterns {
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                let ns = text as NSString
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let nr = m.range(at: group)
                    guard let sr = Range(nr, in: text) else { continue }
                    let start = text.utf8.distance(from: text.utf8.startIndex, to: sr.lowerBound)
                    let end = text.utf8.distance(from: text.utf8.startIndex, to: sr.upperBound)
                    let r = start..<end
                    if cuts.contains(where: { $0.0.overlaps(r) }) { continue }
                    cuts.append((r, Array("[a secret, removed by doz]".utf8), Finding(file: file, kind: kind)))
                }
            }
        }
        guard !cuts.isEmpty else { return (input, []) }
        cuts.sort { $0.0.lowerBound < $1.0.lowerBound }
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var at = 0
        for (r, with, _) in cuts {
            out += input[at..<r.lowerBound]
            out += with
            at = r.upperBound
        }
        out += input[at...]
        return (out, cuts.map(\.2))
    }

    static let patterns: [(String, String, Int)] = [
        ("bearer", #"[Bb]earer\s+([A-Za-z0-9._~+/=-]{16,})"#, 1),
        ("api-key", #"(?<![A-Za-z0-9])(sk-[A-Za-z0-9_-]{16,})"#, 1),
        ("placeholder", #"(doz_cred_[0-9a-f]{16,})"#, 1),
    ]

    static func isNarrow(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
    }

    static func isWide(_ b: UInt8) -> Bool { b > 0x20 && b != 0x22 && b != 0x5C && b != 0x7F }

    static func runs(_ bytes: [UInt8], _ inRun: (UInt8) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        for (i, b) in bytes.enumerated() {
            if inRun(b) { if start == nil { start = i } } else if let s = start { out.append(s..<i); start = nil }
        }
        if let s = start { out.append(s..<bytes.count) }
        return out
    }
}

/// A folder an export writes into: new or empty, never a link, never inside the store; made 0700; every file in it made
/// with `openat(O_CREAT|O_EXCL|O_NOFOLLOW)`, 0600, never written over; sub-folders 0700, never a link.
public final class ExportFolder {
    public let path: String
    let fd: Int32

    /// Opens (or makes) the folder. Refused: one that holds anything, a link, another user's, or one inside `store`.
    public init(_ raw: String, store: DozableStore) throws {
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        let realParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        let realStore = store.root.resolvingSymlinksInPath().path
        let whole = (realParent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        if whole == realStore || whole.hasPrefix(realStore + "/") || path.hasPrefix(store.root.path + "/") {
            throw HostError(.invalid, "\(DisplayPath.tilde(path)) is inside doz's store: export somewhere of your own")
        }
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw HostError(.failed, "\(DisplayPath.tilde(path)): \(String(cString: strerror(errno)))")
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HostError(.invalid, "\(DisplayPath.tilde(path)) is not a folder (a link is never followed)") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid() else {
            close(fd)
            throw HostError(.invalid, "\(DisplayPath.tilde(path)) is not your folder")
        }
        // Empty: nothing of an earlier export is ever mixed in or written over.
        if let d = fdopendir(dup(fd)) {
            defer { closedir(d) }
            while let e = readdir(d) {
                let n = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
                if n != "." && n != ".." {
                    close(fd)
                    throw HostError(.exists, "\(DisplayPath.tilde(path)) is not empty: export into a new or empty folder")
                }
            }
        }
        _ = fchmod(fd, 0o700)
        self.path = path
        self.fd = fd
    }

    deinit { close(fd) }

    /// Writes a new file at `relative` (its folders made 0700 as needed, never through a link). Answers its sha256 hex.
    @discardableResult
    public func write(_ relative: String, _ bytes: [UInt8]) throws -> String {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw HostError(.invalid, "not a name an export writes: \(relative)")
        }
        var dir = dup(fd)
        defer { close(dir) }
        for p in parts.dropLast() {
            if mkdirat(dir, p, 0o700) != 0 && errno != EEXIST { throw HostError(.failed, "\(relative): \(String(cString: strerror(errno)))") }
            let next = openat(dir, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HostError(.failed, "\(relative): a folder of the export is not one (a link is never followed)") }
            close(dir)
            dir = next
        }
        let f = openat(dir, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { throw HostError(.failed, "\(relative): \(String(cString: strerror(errno)))") }
        defer { close(f) }
        var at = 0
        while at < bytes.count {
            let w = bytes[at...].withUnsafeBytes { Darwin.write(f, $0.baseAddress!, $0.count) }
            if w < 0 && errno == EINTR { continue }
            guard w > 0 else { throw HostError(.failed, "\(relative): \(String(cString: strerror(errno)))") }
            at += w
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// When, as a person writes it on the command line (`--since`, `--until`): ISO 8601 (`2026-11-20T09:00:00Z`, with a
/// fraction or an offset, or a day `2026-11-20` meaning its start in UTC), Unix seconds, or a time ago (`30m`, `2h`,
/// `7d`). Pure (`ChatExportTests`).
public enum ChatTime {
    public static func parse(_ raw: String, now: Date = Date()) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let last = s.last, "mhd".contains(last), let n = Double(s.dropLast()), n >= 0, s.dropLast().allSatisfy({ $0.isNumber || $0 == "." }) {
            let unit: Double = last == "m" ? 60 : last == "h" ? 3600 : 86_400
            return now.timeIntervalSince1970 - n * unit
        }
        if !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." }), let n = Double(s) { return n }
        for opts in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = opts
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: s)?.timeIntervalSince1970
    }

    public static let help = "ISO 8601 (2026-11-20T09:00:00Z, or a day), Unix seconds, or a time ago (30m, 2h, 7d)"
}

/// What `doz chat export` leaves beside the messages (`manifest.json`, version 1). Never a token.
public struct ChatExportManifest: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable { public var since: Double?; public var until: Double? }
    public struct File: Codable, Equatable, Sendable { public var path: String; public var sha256: String; public var bytes: Int }
    public struct Missing: Codable, Equatable, Sendable { public var id: String; public var name: String; public var why: String }
    public struct Sweep: Codable, Equatable, Sendable { public var findings: [ExportSweep.Finding]; public var redacted: Int }
    public var version = 1
    public var room: String
    public var window: Window
    public var count: Int
    public var firstSeq: Int64?
    public var lastSeq: Int64?
    public var files: [File]
    public var missing: [Missing]?
    public var sweep: Sweep
    public var exportedAt: Date

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
    }()
    public func bytes() -> [UInt8] { Array(((try? Self.encoder.encode(self)) ?? Data()) + Data("\n".utf8)) }
}

/// A room's messages in a window, read through the owner's socket a page at a time, backwards, with no cap — and the
/// export: the JSONL, the attachments, the manifest, each swept (`doz chat read --since`, `doz chat export`).
public enum ChatExport {
    /// One request on the owner's socket: the status and the body.
    public typealias Fetch = (_ target: String) throws -> (status: Int, body: Data)

    /// Every message of the room with `since <= at <= until` (nil: no bound), oldest first. Pages of 500 backwards from
    /// the latest, until one starts before `since` or the room's start.
    public static func messages(room: String, since: Double?, until: Double?, fetch: Fetch) throws -> [JValue] {
        var all: [JValue] = []
        var before: Int64 = 0
        while true {
            let (status, body) = try fetch("/api/rooms/\(room)/messages?limit=500" + (before > 0 ? "&before=\(before)" : ""))
            guard status == 200, case .array(let page)? = try? ChatJSON.parse(body) else {
                let why = (try? ChatJSON.parse(body))?.field("error")?.stringValue
                throw HostError(status == 403 || status == 404 ? .notFound : .failed, why ?? "the chat server answered \(status)")
            }
            if page.isEmpty { break }
            all.insert(contentsOf: page, at: 0)
            let first = page[0]
            let seq = Int64(((try? first.field("seq")?.goInt("seq")) ?? nil) ?? 0)
            if let s = since, (first.field("at")?.doubleValue ?? 0) < s { break }
            if page.count < 500 || seq <= 1 { break }
            before = seq
        }
        return all.filter { m in
            let at = m.field("at")?.doubleValue ?? 0
            return (since.map { at >= $0 } ?? true) && (until.map { at <= $0 } ?? true)
        }
    }

    /// Writes the export into `folder`: `<room>.jsonl`, `attachments/<id>/<clean name>`, `manifest.json`. Every file swept.
    public static func write(room: String, since: Double?, until: Double?, into folder: ExportFolder, sweep: ExportSweep,
                             fetch: Fetch) throws -> ChatExportManifest {
        let ms = try messages(room: room, since: since, until: until, fetch: fetch)
        var findings: [ExportSweep.Finding] = []
        var files: [ChatExportManifest.File] = []
        var missing: [ChatExportManifest.Missing] = []
        var lines: [UInt8] = []
        for m in ms { lines += ChatJSON.encode(m) + [0x0A] }
        let jsonl = room + ".jsonl"
        let cleaned = sweep.clean(lines, file: jsonl)
        findings += cleaned.findings
        files.append(.init(path: jsonl, sha256: try folder.write(jsonl, cleaned.bytes), bytes: cleaned.bytes.count))
        var done = Set<String>()
        for m in ms {
            guard case .array(let atts)? = m.field("attachments") else { continue }
            for a in atts {
                guard let id = a.field("id")?.stringValue, let name = a.field("name")?.stringValue, !done.contains(id) else { continue }
                done.insert(id)
                // The server's own rules: an id of 16 or 32 lower-case hex, a name in its cleaned form (never a path).
                guard ChatFileRules.isFileID(id) else {
                    missing.append(.init(id: id, name: name, why: "not an attachment id")); continue
                }
                let clean = ChatFileRules.cleanName(name)
                let target = "/files/\(id)/" + (clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clean)
                let (status, body) = try fetch(target)
                guard status == 200 else { missing.append(.init(id: id, name: clean, why: status == 404 ? "gone (404)" : "the chat server answered \(status)")); continue }
                let rel = "attachments/\(id)/\(clean)"
                let c = sweep.clean(Array(body), file: rel)
                findings += c.findings
                files.append(.init(path: rel, sha256: try folder.write(rel, c.bytes), bytes: c.bytes.count))
            }
        }
        let seqs: [Int64] = ms.compactMap { m in ((try? m.field("seq")?.goInt("seq")) ?? nil).map(Int64.init) }
        let manifest = ChatExportManifest(room: room, window: .init(since: since, until: until), count: ms.count, firstSeq: seqs.first,
                                          lastSeq: seqs.last, files: files, missing: missing.isEmpty ? nil : missing,
                                          sweep: .init(findings: findings, redacted: findings.count), exportedAt: Date())
        try folder.write("manifest.json", manifest.bytes())
        return manifest
    }
}
