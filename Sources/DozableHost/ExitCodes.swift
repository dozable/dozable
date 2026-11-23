import Foundation

/// One row of the published exit-code table.
public struct ExitCodeEntry: Codable, Equatable, Sendable {
    public var exit: Int32
    public var name: String
    public var meaning: String
    /// The `error.code`s a `--json` answer with this exit carries.
    public var errorCodes: [String]
    /// Codes doz still answers with beside the contract's names (kept from earlier versions; never removed).
    public var alsoErrorCodes: [String]?

    public init(_ exit: Int32, _ name: String, _ meaning: String, _ errorCodes: [HostError.Code], also: [HostError.Code] = []) {
        self.exit = exit; self.name = name; self.meaning = meaning
        self.errorCodes = errorCodes.map(\.rawValue)
        alsoErrorCodes = also.isEmpty ? nil : also.map(\.rawValue)
    }
}

/// `doz help exit-codes --json`.
public struct ExitCodesAnswer: Codable, Equatable, Sendable {
    public var kind = "ExitCodes"
    public var schema = 1
    public var codes: [ExitCodeEntry]
    public init(codes: [ExitCodeEntry] = ExitCodes.table) { self.codes = codes }
}

/// The ONE exit-code contract of `doz` — frozen: a code keeps its meaning, a new outcome gets a new code, and no command
/// overloads one locally. Every command's exit comes from here (`exit(for:)`), and `doz help exit-codes` prints it.
/// `ExitCodesTests` pins it.
public enum ExitCodes {
    public static let ok: Int32 = 0
    public static let failed: Int32 = 1
    public static let notFound: Int32 = 2
    public static let notPossibleNow: Int32 = 3
    public static let alreadyExists: Int32 = 4
    public static let notConfirmed: Int32 = 5
    public static let daemonUnavailable: Int32 = 6
    public static let notImplemented: Int32 = 7
    public static let limited: Int32 = 8
    public static let notPermitted: Int32 = 9
    public static let usage: Int32 = 64             // EX_USAGE
    public static let invalid: Int32 = 65           // EX_DATAERR
    public static let partial: Int32 = 75           // EX_TEMPFAIL
    public static let timedOut: Int32 = DozableExitCode.timedOut
    public static let dozableFailed: Int32 = 125

    public static let table: [ExitCodeEntry] = [
        ExitCodeEntry(ok, "ok", "done — or asked: a question was posted and the answer comes later (not an error)", []),
        ExitCodeEntry(failed, "failed", "failed", [.failed]),
        ExitCodeEntry(notFound, "not-found", "not found — only that: nothing by that name, or several that match", [.notFound, .ambiguous]),
        ExitCodeEntry(notPossibleNow, "not-possible-now",
                      "not possible now: not in this state, in use, changed since you looked, already answered or not yours",
                      [.invalidPhase, .conflict, .planChanged, .fileChanged, .alreadyAnswered, .notOwned, .requestIDReused, .runOpen]),
        ExitCodeEntry(alreadyExists, "already-exists", "already exists", [.alreadyExists], also: [.exists]),
        ExitCodeEntry(notConfirmed, "not-confirmed", "not confirmed: no terminal and no --yes, or the answer was no", [.needsConfirmation]),
        ExitCodeEntry(daemonUnavailable, "daemon-unavailable", "the daemon (or what it runs) is not available", [.needsDaemon],
                      also: [.unavailable, .version]),
        ExitCodeEntry(notImplemented, "not-implemented", "not implemented in this version", [.notImplemented]),
        ExitCodeEntry(limited, "limited", "supported, but not with what was asked (doz search)", [.limited]),
        ExitCodeEntry(notPermitted, "not-permitted", "not permitted: an agent's request its permissions do not allow", [.notPermitted]),
        ExitCodeEntry(usage, "usage", "usage: an unknown command or flag, a missing argument",
                      [.usage, .unclearRequest]),
        ExitCodeEntry(invalid, "invalid", "an invalid document or value: a space file, a name, a flag's or a setting's value, a refused combination",
                      [.invalidDocument, .invalidValue, .secretValueInDocument], also: [.invalid]),
        ExitCodeEntry(partial, "partial", "partly done: --json says what is done, what remains, and the command that retries the rest",
                      [.partial]),
        ExitCodeEntry(timedOut, "timed-out", "timed out: a --timeout or --wait passed (exec: a program's own 124 looks the same; --json says timedOut)",
                      [.timedOut]),
        ExitCodeEntry(dozableFailed, "doz-failed", "doz itself failed around a program (exec, run, attach — which otherwise exit with the program's own code)", []),
    ]

    /// The exit code of an error. Exhaustive on purpose: a new code does not compile until it is placed here.
    public static func exit(for code: HostError.Code) -> Int32 {
        switch code {
        case .failed: failed
        case .notFound, .ambiguous: notFound
        case .invalidPhase, .conflict, .planChanged, .fileChanged, .alreadyAnswered, .notOwned, .requestIDReused, .runOpen: notPossibleNow
        case .exists, .alreadyExists: alreadyExists
        case .needsConfirmation: notConfirmed
        case .version, .unavailable, .needsDaemon: daemonUnavailable
        case .notImplemented: notImplemented
        case .limited: limited
        case .notPermitted: notPermitted
        case .usage, .unclearRequest: usage
        case .invalid, .invalidDocument, .invalidValue, .secretValueInDocument: invalid
        case .partial: partial
        case .timedOut: timedOut
        }
    }

    public static func exit(for e: HostError) -> Int32 { exit(for: e.code) }

    /// A code as a refusal carries it (`refusalCode`): unknown → failed.
    public static func exit(forCode raw: String) -> Int32 { exit(for: HostError.Code(rawValue: raw) ?? .failed) }

    public static func entry(_ exit: Int32) -> ExitCodeEntry? { table.first { $0.exit == exit } }

    /// The table as a person reads it.
    public static var text: String {
        var s = "doz's exit codes (doz help exit-codes --json for the table as JSON):\n\n"
        for e in table {
            s += String(e.exit).padding(toLength: 5, withPad: " ", startingAt: 0) + e.meaning + "\n"
            let codes = e.errorCodes + (e.alsoErrorCodes ?? [])
            if !codes.isEmpty { s += "     error codes: " + codes.joined(separator: ", ") + "\n" }
        }
        s += """

        exec, run and attach exit with the program's own code. With --json an error is \
        {"error":{"code","message","exit"}} on stdout; a partial result also says done, remaining and retry (a command).

        """
        return s
    }
}

/// What a `--json` failure prints: `{"error":{"code","message","exit"}}` (`exit` added to the earlier shape).
public struct ErrorAnswer: Encodable, Sendable {
    public struct Body: Encodable, Sendable {
        public var code: String
        public var message: String
        public var exit: Int32
        /// The command that does it, as argv (a question nobody answered: the same command with `--yes`). Additive.
        public var fix: [String]?
    }
    public var error: Body
    public init(_ e: HostError, exit: Int32? = nil, fix: [String]? = nil) {
        error = Body(code: e.code.rawValue, message: e.message, exit: exit ?? ExitCodes.exit(for: e), fix: fix)
    }
}

/// A partial result's shape (exit 75): what is done, what remains, and the argv that retries the rest.
public struct PartialAnswer: Codable, Equatable, Sendable {
    public var code = HostError.Code.partial.rawValue
    public var done: [String]
    public var remaining: [String]
    public var retry: [String]
    public init(done: [String], remaining: [String], retry: [String]) { self.done = done; self.remaining = remaining; self.retry = retry }
}
