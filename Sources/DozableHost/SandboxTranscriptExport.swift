import Foundation

// A sandbox agent's conversations copied out for a run's archive — while its VM still runs, before finish shuts it down.
// Only `<uuid>.jsonl` files directly in the guest's `~/.claude/projects/<the slug of the agent's folder>/`, modified at or
// after the run's start, each read as a one-member tar (a link or anything but a regular file refused) and then checked on
// the Mac by `TranscriptCopy`'s rules (every line a JSON object written in that folder, at most 64 MiB). A sandbox that is
// not running is never woken: "not running: its conversations stay on its disk". Nothing in a VM is ever discarded.
// `SandboxTranscriptExportTests`; `docs/engineering/engine.md` ("A sandbox's conversations for a run's archive").

/// How the guest is asked (the daemon's: an exec to list, a tar on the guest stream to read — the `copy` operation's way).
public protocol SandboxTranscriptSource: Sendable {
    /// nil: the sandbox does not run (nothing is woken).
    func list(sandbox: String, script: [String]) async throws -> String?
    /// One file as a tar stream's bytes (`tar -C DIR -cf - NAME`), at most `maximum` bytes read.
    func tar(sandbox: String, argv: [String], maximum: Int) async throws -> Data
}

public enum SandboxTranscriptExport {
    /// The agent's folder in its VM.
    public static let guestFolder = "/workspace"

    public static func projectsFolder(_ workdir: String = guestFolder) -> String {
        "$HOME/.claude/projects/" + MacPlace.claudeProjectFolderName(workdir)
    }

    /// Lists `NAME MTIME` for each regular file of the folder, and `NAME link` for a link (never followed), one per line.
    public static func listScript(_ workdir: String = guestFolder) -> [String] {
        ["sh", "-c", "d=\"\(projectsFolder(workdir))\"; [ -d \"$d\" ] && [ ! -L \"$d\" ] || exit 0; cd \"$d\" || exit 0; "
            + "for f in *.jsonl; do if [ -L \"$f\" ]; then echo \"$f link\"; elif [ -f \"$f\" ]; then echo \"$f $(stat -c %Y \"$f\" 2>/dev/null || echo 0)\"; fi; done; exit 0"]
    }

    /// The conversation names that are links (never copied: refused, and said).
    public static func parseLinks(_ out: String) -> [String] {
        out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[1] == "link" && MacTranscripts.isTranscriptName(String(parts[0])) ? String(parts[0]) : nil
        }.sorted()
    }

    /// The names worth copying: a conversation's name (`<uuid>.jsonl`, lower case), modified at or after `since`.
    public static func parseList(_ out: String, since: Date) -> [String] {
        var names: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let t = Double(parts[1]) else { continue }
            let n = String(parts[0])
            guard MacTranscripts.isTranscriptName(n), t + 1 >= since.timeIntervalSince1970 else { continue }
            names.append(n)
        }
        return names.sorted()
    }

    public static func tarArgv(_ name: String, workdir: String = guestFolder) -> [String] {
        ["sh", "-c", "cd \"\(projectsFolder(workdir))\" && exec tar -cf - -- \"\(name)\""]
    }

    public struct Refused: Error, Equatable { public var why: String }

    /// The one member of a ustar stream: a regular file named `name`, at most `maximum` bytes. A link, a folder or a
    /// second member is refused.
    public static func untarOne(_ d: Data, name: String, maximum: Int = MacTranscripts.maximumFileBytes) throws -> Data {
        let b = [UInt8](d)
        guard b.count >= 512 else { throw Refused(why: "no file came back") }
        func field(_ at: Int, _ len: Int) -> String {
            String(decoding: b[at..<at + len].prefix { $0 != 0 }, as: UTF8.self)
        }
        let member = field(0, 100)
        let type = b[156]
        guard type == UInt8(ascii: "0") || type == 0 else {
            throw Refused(why: type == UInt8(ascii: "2") || type == UInt8(ascii: "1") ? "a link — refused" : "not a regular file — refused")
        }
        guard member == name || member == "./" + name else { throw Refused(why: "another file came back") }
        guard let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8), size <= maximum else {
            throw Refused(why: "larger than \(maximum) bytes")
        }
        guard b.count >= 512 + size else { throw Refused(why: "cut short") }
        let next = 512 + ((size + 511) / 512) * 512
        if b.count >= next + 512, b[next..<next + 512].contains(where: { $0 != 0 }) { throw Refused(why: "more than one file came back") }
        return Data(b[512..<512 + size])
    }

    /// The agent's conversations from its running sandbox: what was copied, and what to say (never woken; a refusal named).
    public static func collect(_ source: SandboxTranscriptSource, sandbox: String, agent: String, since: Date,
                               workdir: String = guestFolder) async -> (files: [RunTranscript], notes: [String]) {
        let out: String?
        do { out = try await source.list(sandbox: sandbox, script: listScript(workdir)) } catch {
            return ([], ["\(agent): its conversations could not be listed in \(sandbox): \(HostError.from(error).message)"])
        }
        guard let out else { return ([], ["\(agent): \(sandbox) is not running: its conversations stay on its disk"]) }
        var files: [RunTranscript] = []
        var notes: [String] = parseLinks(out).map { "\(agent): \($0) not copied (a link — refused)" }
        for n in parseList(out, since: since) {
            do {
                let raw = try await source.tar(sandbox: sandbox, argv: tarArgv(n, workdir: workdir), maximum: MacTranscripts.maximumFileBytes + 4096)
                let data = try untarOne(raw, name: n)
                if let p = MacTranscripts.contentProblem(data, workdir: workdir) { notes.append("\(agent): \(n) not copied (\(p))"); continue }
                files.append(RunTranscript(agent: agent, name: n, source: "sandbox", data: data, session: nil, sourcePath: nil))
            } catch let r as Refused {
                notes.append("\(agent): \(n) not copied (\(r.why))")
            } catch {
                notes.append("\(agent): \(n) not copied (\(HostError.from(error).message))")
            }
        }
        return (files, notes)
    }
}
