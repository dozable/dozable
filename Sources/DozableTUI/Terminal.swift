import Darwin
import Foundation

// DozableTUI (637; owner: "a library of reusable tui components that the colour effects are based on; colour should be
// able to be turned off with a flag and setting") — what `doz` draws on a terminal, in one place:
//
//   - `Terminal`: the facts every component reads, decided ONCE per process — colour on or off, whether the session is
//     interactive, the width.
//   - `Style`: semantic styles only (heading, ok, warn, dim, code …); the SGR codes live in Style.swift and nowhere else.
//   - Components that render to a String (testable without a terminal): `StepHeader`, `Rule`, `Section`, `StatusLine`,
//     `KeyValues`, `Note`, `Command`.
//   - `Prompter`: the questions — arrow-key `Choice`, `YesNo`, `TextField`, `Checklist` on a terminal (raw mode, always
//     restored), and the typed fallback (numbered options, typed answers) everywhere else.
//
// Foundation and Darwin only: no dependency on the host, the web layer or the argument parser, so anything may use it.

/// `--color auto|always|never` (`ui.color`, `$DOZ_COLOR`).
public enum ColourMode: String, CaseIterable, Sendable {
    case auto, always, never
}

/// The terminal facts of this process. `configure` decides them once (the CLI's global options do it); a component
/// reads `Terminal.current`. Tests replace `current` (it is the seam).
public struct Terminal: Sendable {
    /// The colour mode as given (after the flag > env > setting precedence, which the caller resolved).
    public var mode: ColourMode
    /// `--json` or `-q`: no colour, whatever the mode but `always`.
    public var suppressed: Bool
    /// `NO_COLOR` is set (any value): `auto` is off.
    public var noColorEnv: Bool
    /// `TERM=dumb`: `auto` is off.
    public var dumb: Bool
    /// Colour on stdout.
    public var colour: Bool
    /// stdin AND stdout are terminals.
    public var interactive: Bool
    /// A fixed width (tests); nil: measured at each use (the terminal may be resized).
    public var fixedWidth: Int?

    /// The width in columns: stdout's, else stderr's, else 80.
    public var width: Int { fixedWidth ?? Terminal.measureWidth() }

    /// A terminal with these facts (tests; and the default before `configure`).
    public init(colour: Bool, interactive: Bool, width: Int? = nil) {
        mode = colour ? .always : .never
        suppressed = false
        noColorEnv = false
        dumb = false
        self.colour = colour
        self.interactive = interactive
        fixedWidth = width
    }

    /// The rules, in order: `never` → off; `always` → on (even off a terminal); `--json` or `-q` → off; `NO_COLOR` set →
    /// off; `auto` → on only when the output is a terminal and `TERM` is not `dumb`.
    public static func decide(_ mode: ColourMode, suppressed: Bool, noColor: Bool, dumb: Bool, isTTY: Bool) -> Bool {
        switch mode {
        case .never: return false
        case .always: return true
        case .auto: return !suppressed && !noColor && !dumb && isTTY
        }
    }

    /// Colour on another descriptor (stderr: the progress view, attach's notices) — the same rules, its own tty.
    public func colour(fd: Int32) -> Bool {
        if fd == STDOUT_FILENO { return colour }
        return Terminal.decide(mode, suppressed: suppressed, noColor: noColorEnv, dumb: dumb, isTTY: isatty(fd) == 1)
    }

    /// Decide this process's facts. `environment` gives `NO_COLOR` and `TERM`; `stdoutTTY`/`stdinTTY` are the
    /// descriptors' (passed in by tests).
    public static func make(colour mode: ColourMode, json: Bool, quiet: Bool,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            stdinTTY: Bool = isatty(STDIN_FILENO) == 1, stdoutTTY: Bool = isatty(STDOUT_FILENO) == 1) -> Terminal {
        var t = Terminal(colour: false, interactive: stdinTTY && stdoutTTY)
        t.mode = mode
        t.suppressed = json || quiet
        t.noColorEnv = environment["NO_COLOR"] != nil
        t.dumb = environment["TERM"] == "dumb"
        t.colour = decide(mode, suppressed: t.suppressed, noColor: t.noColorEnv, dumb: t.dumb, isTTY: stdoutTTY)
        return t
    }

    /// Decide once, for the whole process (the CLI's global options call it before a command runs).
    public static func configure(colour mode: ColourMode, json: Bool, quiet: Bool) {
        current = make(colour: mode, json: json, quiet: quiet)
    }

    nonisolated(unsafe) private static var stored: Terminal?
    private static let lock = NSLock()

    /// This process's facts — `auto`, not `--json`, not `-q` until `configure` says otherwise.
    public static var current: Terminal {
        get {
            lock.lock(); defer { lock.unlock() }
            if let s = stored { return s }
            let t = make(colour: .auto, json: false, quiet: false)
            stored = t
            return t
        }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = newValue
        }
    }

    /// The width of stdout (else stderr) in columns; 80 when neither is a terminal or says.
    public static func measureWidth() -> Int {
        var w = winsize()
        for fd in [STDOUT_FILENO, STDERR_FILENO] where ioctl(fd, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 {
            return Int(w.ws_col)
        }
        return 80
    }
}
