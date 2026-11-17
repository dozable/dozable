import Darwin
import Foundation

// Attachments (the protocol's 4.8 and 2.7): files and images on a message. The server keeps each one in its data folder,
// at `files/<id>/<name>`, and a message names it by id. Bytes never travel in a webhook or a receive item; a recipient
// fetches them (the line port's `file` control line, or `GET /files/<id>/<name>` on the page port).
//
// The rules that keep this safe:
// - The limits (20 MiB a file, 10 files a message, nothing empty) are checked before a byte is written: every file of
//   a message is decoded and checked first, and only then are they stored.
// - A name a caller gives is never a path: it is cleaned to its last part, in letters, digits and `._ ()+-` only, with
//   no leading dot or space (so never `..`, a separator, an absolute path or a NUL), at most 120 bytes; the file is kept
//   under a random 128-bit id, written with O_EXCL and O_NOFOLLOW in a folder made for it.
// - An id is looked up only when it is 16 or 32 lower-case hex digits; a folder holding anything but one file is no
//   attachment.
// - A download goes only to a caller that may read the room of a message that names the file (a file named by no
//   message yet — an upload — goes to whoever has its id, as the reference serves every file); it carries
//   `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, and anything but a PNG, JPEG, GIF or WebP
//   image is sent as an attachment (a download), never shown in the page.

/// One stored attachment.
struct ChatAttachment: Sendable, Equatable {
    var id: String
    var name: String
    var type: String
    var size: Int64

    /// The attachment object of the protocol (2.7): id, name, type, size, url, path — in that order.
    func json(filesDir: String) -> JValue {
        var o = JObject()
        o.add("id", .string(id)); o.add("name", .string(name)); o.omitEmpty("type", type)
        if size != 0 { o.add("size", .int(size)) }
        o.add("url", .string(url)); o.add("path", .string((filesDir as NSString).appendingPathComponent(id + "/" + name)))
        return o.value
    }

    var url: String { "/files/" + id + "/" + name }

    /// An attachment as a message keeps it (its JSON object).
    static func read(_ v: JValue) -> (id: String, name: String, type: String, size: Int64, path: String) {
        func s(_ k: String) -> String { v.field(k)?.stringValue ?? "" }
        let size: Int64 = ((try? v.field("size")?.goInt("size")) ?? nil).map(Int64.init) ?? 0
        return (s("id"), s("name"), s("type"), size, s("path"))
    }
}

enum ChatFileRules {
    static let maxSize = ChatProtocol.maxFileSize
    static let maxCount = ChatProtocol.maxAttachments

    /// `^([0-9a-f]{16}|[0-9a-f]{32})$`: a file id of this release (32) or of an earlier one (16).
    static func isFileID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return (u.count == 16 || u.count == 32) && u.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The stored name of what a caller called a file: its last part (a backslash counts as a separator), every
    /// character but `A-Za-z0-9._ ()+-` made `_`, leading dots and spaces dropped, `file` when nothing is left, and the
    /// last 120 bytes of a longer one.
    static func cleanName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        // filepath.Base: trailing slashes go; the last part; "" is ".", only slashes is "/".
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { s = "." } else if s != "/", let i = s.lastIndex(of: "/") { s = String(s[s.index(after: i)...]) }
        var out = ""
        for u in s.unicodeScalars {
            let ok = (u.value < 0x80) && (CharacterSet.alphanumerics.contains(u) || "._ ()+-".unicodeScalars.contains(u))
            out.unicodeScalars.append(ok ? u : "_")
        }
        while let f = out.first, f == "." || f == " " { out.removeFirst() }
        if out.isEmpty { out = "file" }
        let b = Array(out.utf8)
        if b.count > 120 { out = String(decoding: b[(b.count - 120)...], as: UTF8.self) }
        return out
    }

    /// The media type: from the name's extension, else from what the first 512 bytes look like.
    static func mediaType(name: String, head: [UInt8]) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, name.contains("."), let t = byExtension[ext] { return t }
        return sniff(Array(head.prefix(512)))
    }

    /// The types known by extension (the reference's table and the system's usual ones).
    static let byExtension: [String: String] = [
        "avif": "image/avif", "css": "text/css", "gif": "image/gif", "htm": "text/html", "html": "text/html",
        "jpeg": "image/jpeg", "jpg": "image/jpeg", "js": "text/javascript", "mjs": "text/javascript", "json": "application/json",
        "pdf": "application/pdf", "png": "image/png", "svg": "image/svg+xml", "wasm": "application/wasm", "webp": "image/webp",
        "xml": "text/xml", "txt": "text/plain", "text": "text/plain", "log": "text/plain", "conf": "text/plain",
        "csv": "text/csv", "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
        "bin": "application/octet-stream", "mp3": "audio/mpeg", "mp4": "video/mp4", "mov": "video/quicktime",
        "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "ico": "image/vnd.microsoft.icon",
    ]

    /// What bytes look like, as the web's sniffing rules say (a subset of them), without a charset.
    static func sniff(_ b: [UInt8]) -> String {
        func starts(_ p: [UInt8], at i: Int = 0) -> Bool { b.count >= i + p.count && Array(b[i..<(i + p.count)]) == p }
        func a(_ s: String) -> [UInt8] { Array(s.utf8) }
        var i = 0
        while i < b.count, [0x09, 0x0A, 0x0C, 0x0D, 0x20].contains(b[i]) { i += 1 }
        let tags = ["<!DOCTYPE HTML", "<HTML", "<HEAD", "<SCRIPT", "<IFRAME", "<H1", "<DIV", "<FONT", "<TABLE", "<A", "<STYLE",
                    "<TITLE", "<B", "<BODY", "<BR", "<P", "<!--"]
        for t in tags {
            let p = a(t)
            guard b.count > i + p.count else { continue }
            let got = b[i..<(i + p.count)].map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }
            if got == p, b[i + p.count] == 0x20 || b[i + p.count] == 0x3E { return "text/html" }
        }
        if starts(a("<?xml"), at: i) { return "text/xml" }
        if starts(a("%PDF-")) { return "application/pdf" }
        if starts(a("%!PS-Adobe-")) { return "application/postscript" }
        if starts([0xFE, 0xFF]) || starts([0xFF, 0xFE]) || starts([0xEF, 0xBB, 0xBF]) { return "text/plain" }
        if starts(a("GIF87a")) || starts(a("GIF89a")) { return "image/gif" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(a("BM")) { return "image/bmp" }
        if starts(a("RIFF")) && starts(a("WEBPVP"), at: 8) { return "image/webp" }
        if starts(a("RIFF")) && starts(a("WAVE"), at: 8) { return "audio/wave" }
        if starts(a("RIFF")) && starts(a("AVI "), at: 8) { return "video/avi" }
        if starts([0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if starts(a("OggS\u{0}")) { return "application/ogg" }
        if starts(a("ID3")) { return "audio/mpeg" }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "video/webm" }
        if starts(a("PK\u{3}\u{4}")) { return "application/zip" }
        if starts([0x1F, 0x8B, 0x08]) { return "application/x-gzip" }
        if starts(a("Rar!\u{1A}\u{7}\u{0}")) || starts(a("Rar!\u{1A}\u{7}\u{1}\u{0}")) { return "application/x-rar-compressed" }
        if starts([0x00, 0x61, 0x73, 0x6D]) { return "application/wasm" }
        if b.count >= 12, starts(a("ftyp"), at: 4) {
            let box = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            if box % 4 == 0, b.count >= box, box >= 12 { return "video/mp4" }
        }
        let binary = b.contains { $0 <= 0x08 || $0 == 0x0B || (0x0E...0x1A).contains($0) || (0x1C...0x1F).contains($0) }
        return binary ? "application/octet-stream" : "text/plain"
    }

    /// A message's images that are shown in the page; every other type is a download.
    static func isInlineImage(_ t: String) -> Bool { ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(t) }

    /// "5 bytes", "2 KB", "1.5 MB".
    static func humanSize(_ n: Int64) -> String {
        if n >= 1 << 20 { return String(format: "%.1f MB", Double(n) / Double(1 << 20)) }
        if n >= 1 << 10 { return String(format: "%.0f KB", Double(n) / Double(1 << 10)) }
        return "\(n) bytes"
    }

    /// base64 as the reference decodes it: the standard alphabet with padding; line breaks are ignored.
    static func decodeBase64(_ s: String) -> [UInt8]? {
        let t = s.contains("\n") || s.contains("\r") ? s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") : s
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }
}

extension ChatServerCore {
    var filesDir: String { file("files") }

    /// What a sender put on a message, checked and then stored: bytes sent inline are stored, ids uploaded earlier are
    /// looked up. Everything is checked before anything is written. The attachments as a message keeps them, or the
    /// refusal in the protocol's words.
    func attach(_ list: [JValue]) -> Result<[JValue], ChatAPIError> {
        func fail(_ s: String) -> Result<[JValue], ChatAPIError> { .failure(ChatAPIError(status: 422, description: s)) }
        if list.isEmpty { return .success([]) }
        if list.count > ChatFileRules.maxCount { return fail("at most \(ChatFileRules.maxCount) attachments on one message") }
        enum Item { case bytes(String, [UInt8]); case stored(ChatAttachment) }
        var items: [Item] = []
        for a in list {
            let data = a.field("data_base64")?.stringValue ?? "", id = a.field("id")?.stringValue ?? "", name = a.field("name")?.stringValue ?? ""
            if !data.isEmpty {
                guard let bytes = ChatFileRules.decodeBase64(data) else { return fail("attachment \(goQuote(name)): data_base64 is not base64") }
                if let why = Self.sizeRefusal(bytes.count) { return fail(why) }
                items.append(.bytes(name, bytes))
            } else if !id.isEmpty {
                guard let s = storedFile(id) else { return fail("attachment \(id): no such attachment") }
                items.append(.stored(s))
            } else {
                return fail("an attachment needs data_base64 with a name, or the id of an uploaded file")
            }
        }
        var out: [JValue] = []
        for it in items {
            switch it {
            case .stored(let s): out.append(s.json(filesDir: filesDir))
            case .bytes(let name, let bytes):
                switch saveFile(name: name, bytes) {
                case .success(let s): out.append(s.json(filesDir: filesDir))
                case .failure(let e): return .failure(e)
                }
            }
        }
        return .success(out)
    }

    static func sizeRefusal(_ n: Int) -> String? {
        if n == 0 { return "an attachment is empty" }
        if n > ChatFileRules.maxSize { return "an attachment is larger than \(ChatFileRules.maxSize >> 20) MB" }
        return nil
    }

    /// Stores bytes as a new attachment under a new random id. The size is checked before anything is written.
    func saveFile(name raw: String, _ bytes: [UInt8]) -> Result<ChatAttachment, ChatAPIError> {
        if let why = Self.sizeRefusal(bytes.count) { return .failure(ChatAPIError(status: 400, description: why)) }
        let name = ChatFileRules.cleanName(raw)
        var rng = SystemRandomNumberGenerator()
        let id = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        let dir = (filesDir as NSString).appendingPathComponent(id)
        do {
            try FileManager.default.createDirectory(atPath: filesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard mkdir(dir, 0o700) == 0 else { throw ChatStoreError(description: String(cString: strerror(errno))) }
            let path = (dir as NSString).appendingPathComponent(name)
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ChatStoreError(description: String(cString: strerror(errno))) }
            var ok = true
            bytes.withUnsafeBytes { p in
                var off = 0
                while off < p.count {
                    let n = write(fd, p.baseAddress! + off, p.count - off)
                    if n <= 0 { ok = false; break }
                    off += n
                }
            }
            Darwin.close(fd)
            guard ok else { unlink(path); rmdir(dir); throw ChatStoreError(description: "the file could not be written") }
        } catch {
            log("chat: storing an attachment: \(error)")
            return .failure(ChatAPIError(status: 500, description: "the file could not be stored"))
        }
        return .success(ChatAttachment(id: id, name: name, type: ChatFileRules.mediaType(name: name, head: Array(bytes.prefix(512))), size: Int64(bytes.count)))
    }

    /// A stored attachment by id: the one regular file in `files/<id>/`, or nil.
    func storedFile(_ id: String) -> ChatAttachment? {
        guard ChatFileRules.isFileID(id) else { return nil }
        let dir = (filesDir as NSString).appendingPathComponent(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir), names.count == 1 else { return nil }
        let path = (dir as NSString).appendingPathComponent(names[0])
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var head = [UInt8](repeating: 0, count: 512)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var n = 0
        if fd >= 0 { n = max(0, read(fd, &head, 512)); Darwin.close(fd) }
        return ChatAttachment(id: id, name: names[0], type: ChatFileRules.mediaType(name: names[0], head: Array(head.prefix(n))), size: Int64(st.st_size))
    }

    /// A stored attachment's bytes, read without following a link.
    func fileBytes(_ a: ChatAttachment) -> [UInt8]? {
        let path = (filesDir as NSString).appendingPathComponent(a.id + "/" + a.name)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            out += buf[0..<n]
            if out.count > ChatFileRules.maxSize + (1 << 20) { return nil }
        }
        return out
    }

    /// Where an attachment is on this Mac now: from the data folder and its id (so a moved data folder still works),
    /// else the path the message kept.
    func localPath(_ v: JValue) -> String {
        let a = ChatAttachment.read(v)
        if ChatFileRules.isFileID(a.id), !a.name.isEmpty, ChatFileRules.cleanName(a.name) == a.name {
            return (filesDir as NSString).appendingPathComponent(a.id + "/" + a.name)
        }
        return a.path
    }

    /// Whether who may fetch a stored file: a file named by no message yet (an upload, whose id only its uploader has)
    /// goes to whoever has its id; one a message names goes to those who may read one of the messages that name it —
    /// a member of its room that may see it (a direct message: its sender, those it is for, or anyone once revealed).
    func mayFetch(_ id: String, by who: String) -> Bool {
        var named = false
        for room in roomNames() {
            guard let st = try? store(room) else { continue }
            for u in st.namesFile(id) {
                named = true
                guard member(room, who) else { continue }
                var probe = ChatStored(msgID: "", from: u.from, to: u.to, at: 0)
                probe.isPrivate = u.isPrivate; probe.revealed = u.revealed
                if Self.canSee(probe, who) { return true }
            }
        }
        return !named
    }

    /// After a delete: a file no other message names any more is removed from the data folder.
    func dropFiles(_ m: ChatStored) {
        for v in m.attachments {
            let id = ChatAttachment.read(v).id
            guard ChatFileRules.isFileID(id) else { continue }
            var used = false
            for room in roomNames() {
                if let st = try? store(room), st.usesFile(id, except: m.msgID) { used = true; break }
            }
            if !used { try? FileManager.default.removeItem(atPath: (filesDir as NSString).appendingPathComponent(id)) }
        }
    }

    /// The line port's `file` control line: the file's bytes, base64, for a caller that may fetch it.
    func fileReply(_ id: String, for who: String) -> [JMember]? {
        guard let a = storedFile(id), mayFetch(id, by: who), let bytes = fileBytes(a) else { return nil }
        return [JMember("id", .string(a.id)), JMember("name", .string(a.name)), JMember("file_type", .string(a.type)),
                JMember("size", .int(a.size)), JMember("data_base64", .string(Data(bytes).base64EncodedString()))]
    }
}
