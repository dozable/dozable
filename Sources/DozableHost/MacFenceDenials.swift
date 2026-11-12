import Darwin
import DozableKit
import Foundation

/// One refusal of a fenced session's fence, as the kernel reported it (never a `ConnectionRecord`).
public struct FenceDenial: Codable, Equatable, Sendable {
    public var time: Date
    /// The program refused and its pid (`cat(123)`).
    public var process: String
    public var pid: Int?
    /// The operation (`file-read-data`, `network-outbound`, `mach-lookup`, …).
    public var operation: String
    /// What it was refused (a path, an address, a service) — as the kernel wrote it.
    public var target: String
}

/// What `doz net log @mac --session S --fence` answers.
public struct FenceDenials: Codable, Equatable, Sendable {
    public var session: String
    /// `on`, `unavailable` (this account may not read the system log — nothing else is affected) or `off` (no host).
    public var denialLog: String
    /// The refusals seen (macOS folds repeats of one refusal: these are what reached the log), oldest first.
    public var denials: [FenceDenial]
}

/// The fence's refusals: while at least one fenced session lives, ONE `log stream --style ndjson --predicate
/// 'sender == "Sandbox"'` child of the host. Only KERNEL lines count (`processID` 0, `/kernel`), and a line belongs to a
/// session ONLY when its message ends with `\ndoz-fence:<that session's tag>` — the text every rule of the session's
/// profile appends (`(with message …)`), always last; never a substring found elsewhere in the message, so a path a
/// program chooses cannot put a line in another session's ring. Each session keeps the last 256.
///
/// An account that cannot read the system log (`log stream` needs an administrator): said once, `unavailable`, and
/// nothing else changes. TEST SEAM (guarded runs only): `DOZ_TEST_FENCE_LOG=unavailable`.
final class MacFenceDenials: @unchecked Sendable {
    static let ringSize = 256
    private let lock = NSLock()
    private var rings: [String: [FenceDenial]] = [:]
    /// tag → session
    private var tags: [String: String] = [:]
    private var process: Process?
    private var state = "off"
    private var saidUnavailable = false
    private let environment: [String: String]

    init(environment: [String: String]) { self.environment = environment }

    /// `on`, `unavailable` or `off`.
    var status: String { lock.withLock { state } }

    /// A fenced session's tag to watch for (the stream starts with the first).
    func watch(session: String, tag: String) {
        lock.withLock {
            tags = tags.filter { $0.value != session }
            tags[tag] = session
        }
        ensureRunning()
    }

    /// A session ended: its tag is no longer watched (its ring is kept until it is forgotten), and the stream stops
    /// with the last one.
    func unwatch(session: String) {
        let none: Bool = lock.withLock {
            tags = tags.filter { $0.value != session }
            return tags.isEmpty
        }
        if none { stop() }
    }

    func forget(session: String) { lock.withLock { rings[session] = nil } }

    func denials(_ session: String) -> [FenceDenial] { lock.withLock { rings[session] ?? [] } }

    private func ensureRunning() {
        lock.lock()
        if process != nil || state == "unavailable" { lock.unlock(); return }
        if TestSafety.guarded(environment), environment["DOZ_TEST_FENCE_LOG"] == "unavailable" {
            state = "unavailable"
            lock.unlock()
            sayUnavailable("the test seam says so")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", "sender == \"Sandbox\""]
        p.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        process = p
        state = "on"
        lock.unlock()
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let e = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
            let mine: Bool = self.lock.withLock {
                guard self.process === proc else { return false }
                self.process = nil
                // It ended by itself (we did not stop it): this account may not read the log.
                if self.state == "on", !self.tags.isEmpty { self.state = "unavailable" }
                return self.state == "unavailable"
            }
            if mine { self.sayUnavailable(e.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        do { try p.run() } catch {
            lock.withLock { process = nil; state = "unavailable" }
            sayUnavailable("\(error)")
            return
        }
        Thread.detachNewThread { [weak self] in
            var acc = Data()
            let h = out.fileHandleForReading
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                acc.append(d)
                while let nl = acc.firstIndex(of: 10) {
                    let line = acc[acc.startIndex..<nl]
                    acc = Data(acc[(nl + 1)...])
                    self?.take(Data(line))
                }
                if acc.count > 1 << 20 { acc.removeAll() }
            }
        }
    }

    private func sayUnavailable(_ why: String) {
        let first: Bool = lock.withLock { defer { saidUnavailable = true }; return !saidUnavailable }
        if first {
            HostLog.line("@mac: the fence's refusals cannot be read from the system log by this account (\(why.isEmpty ? "log stream ended" : String(why.prefix(160))))"
                         + " — fenced sessions work as before; only their refusals are not listed")
        }
    }

    private func stop() {
        let p: Process? = lock.withLock {
            let p = process
            process = nil
            if state == "on" { state = "off" }
            return p
        }
        if let p, p.isRunning { p.terminate() }
    }

    /// One ndjson line.
    func take(_ line: Data) {
        guard let (tag, d) = Self.parse(line) else { return }
        lock.withLock {
            guard let s = tags[tag] else { return }
            var r = rings[s] ?? []
            r.append(d)
            if r.count > Self.ringSize { r.removeFirst(r.count - Self.ringSize) }
            rings[s] = r
        }
    }

    /// A kernel Sandbox line → (tag, denial); nil for anything else (a user process's line, no tag, not a refusal).
    static func parse(_ line: Data, now: Date = Date()) -> (String, FenceDenial)? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        // Only the kernel's own lines: a user process cannot log as pid 0 from /kernel.
        guard (o["processID"] as? NSNumber)?.intValue == 0, (o["processImagePath"] as? String) == "/kernel",
              let msg = o["eventMessage"] as? String, let nl = msg.lastIndex(of: "\n") else { return nil }
        let last = msg[msg.index(after: nl)...]
        guard last.hasPrefix("doz-fence:") else { return nil }
        let tag = String(last.dropFirst("doz-fence:".count))
        guard tag.count == 16, tag.allSatisfy({ $0.isHexDigit }) else { return nil }
        // "Sandbox: cat(123) deny(1) file-read-data /path…" (the path may itself hold newlines: everything up to the last).
        let body = String(msg[..<nl])
        guard body.hasPrefix("Sandbox: ") else { return nil }
        let rest = body.dropFirst("Sandbox: ".count)
        guard let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") else { return nil }
        let process = String(rest[..<open])
        let pid = Int(rest[rest.index(after: open)..<close])
        let after = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard after.hasPrefix("deny") else { return nil }
        var words = after.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else { return nil }
        words.removeFirst()              // deny(1)
        let operation = words[0]
        let target = words.count > 1 ? words[1] : ""
        var time = now
        if let ts = o["timestamp"] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
            time = f.date(from: ts) ?? now
        }
        return (tag, FenceDenial(time: time, process: process, pid: pid, operation: operation, target: target))
    }
}
