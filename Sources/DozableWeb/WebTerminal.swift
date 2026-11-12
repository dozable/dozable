import Foundation
import DozableHost

/// "Open in Terminal" (590 phase 2). The page asks (`POST /api/v1/sandboxes/{name}/terminal`,
/// CSRF-checked); this process writes a one-shot `.command` file and hands it to LaunchServices
/// (`/usr/bin/open`), which opens it in the user's DEFAULT app for `.command` files — Terminal, or
/// iTerm2 / Ghostty when they are the handler (owner, 2026-09-28: "instead of applescript, cant we
/// use a URL to open the default terminal?"). No AppleScript, so no Automation permission, and a
/// document open never adds Terminal's default window (the AppleScript path opened TWO windows
/// when Terminal was not running). The file runs
///
///     rm -f -- "$0"
///     exec '<this doz>' attach NAME [SESSION] --store '<store>'
///
/// No ticket (unlike DeckStack 503's `terminal attach`): `doz attach` redeems nothing — the
/// terminal runs as the same user, whose host.sock it already may open. The file holds no
/// capability and no secret: a fixed verb, a name and a session that passed their allowlists, and
/// single-quoted paths. It is 0700 in a 0700 per-user directory and deletes itself as it starts.
public enum TerminalHandoff {
    /// The file's text for `command`.
    public static func commandFile(_ command: String) -> String {
        "#!/bin/sh\n# doz: open a session in this terminal (this file deletes itself)\nrm -f -- \"$0\"\n\(command)\n"
    }

    public static func command(executable: String, store: DozableStore, sandbox: String, session: String?) -> String {
        var c = "exec \(shellQuote(executable)) attach \(sandbox)"
        if let session { c += " \(session)" }
        return c + " --store \(shellQuote(store.root.path))"
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The 0700 folder for the one-shot files: `<store>/ui-terminal` — in the store, which no fenced session can reach
    /// (it used to be the per-user temporary folder, which a fenced program could have planted a `.command` in). A
    /// link, another user's folder or a folder others can open is refused.
    static func handoffDirectory(store: DozableStore) throws -> URL {
        let dir = store.root.appendingPathComponent("ui-terminal", isDirectory: true)
        if mkdir(dir.path, 0o700) != 0, errno != EEXIST {
            throw Failure(message: "could not make the terminal hand-off folder \(dir.path): \(String(cString: strerror(errno)))")
        }
        if let why = MacPlace.folderProblem(dir.path) { throw Failure(message: "the terminal hand-off folder: \(why)") }
        return dir
    }

    /// The launcher for `store`: write the one-shot `.command` file and open it with the user's default app for it.
    public static func launcher(store: DozableStore) -> @Sendable (String) throws -> Void {
        { command in try openInTerminalApp(command, store: store) }
    }

    /// Write the one-shot `.command` file (0700, created new — `O_EXCL|O_NOFOLLOW`) and open it with the user's default
    /// app for it.
    public static func openInTerminalApp(_ command: String, store: DozableStore) throws {
        let dir = try handoffDirectory(store: store)
        let file = dir.appendingPathComponent("doz-attach-\(UUID().uuidString.prefix(8)).command")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard fd >= 0 else { throw Failure(message: "could not write the terminal hand-off file in \(dir.path)") }
        let body = Data(commandFile(command).utf8)
        let ok = body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == body.count
        fchmod(fd, 0o700)
        close(fd)
        guard ok else {
            unlink(file.path)
            throw Failure(message: "could not write the terminal hand-off file in \(dir.path)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [file.path]
        let errors = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        try p.run()
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: file)
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "no app opened the terminal hand-off (open: \(err.isEmpty ? "exit \(p.terminationStatus)" : err)) — is a terminal app set to open .command files?")
        }
        // A handler that never runs the file must not leave it behind for long.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: file) }
    }
}

/// CSV for a spreadsheet: a cell that begins with = + - @ (or a tab / CR) is run as a formula by
/// Excel, Numbers and Sheets, and metric rows hold names and error text a sandbox influenced — so
/// such cells get a leading apostrophe (OWASP's CSV-injection defence). Numbers are left alone.
enum WebCSV {
    static func cell(_ s: String?) -> String? {
        guard let s, let f = s.first, "=+-@\t\r".contains(f), Double(s) == nil else { return s }
        return "'" + s
    }

    static func defuse(_ e: MetricsEvent) -> MetricsEvent {
        var e = e
        e.appVersion = cell(e.appVersion)
        e.machine = cell(e.machine)
        e.macOS = cell(e.macOS)
        e.sandbox = cell(e.sandbox)
        e.image = cell(e.image)
        e.action = cell(e.action) ?? e.action
        e.phaseBefore = cell(e.phaseBefore)
        e.phaseAfter = cell(e.phaseAfter)
        e.error = cell(e.error)
        e.detailJSON = cell(e.detailJSON)
        return e
    }
}
