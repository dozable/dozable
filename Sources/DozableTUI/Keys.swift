import Darwin
import Foundation

/// Where questions are asked and answers read: the terminal (`TTYChannel`, /dev/tty — never stdin, which may carry
/// data) or a script of bytes (`ScriptedChannel`, the tests'). The typed fallback and the key-driven components read
/// through the same seam.
public protocol PromptChannel: AnyObject {
    func write(_ s: String)
    /// The next byte; nil at the end of input — or, with `timeout` (milliseconds), when none came in time.
    func read(timeout: Int?) -> UInt8?
    /// Raw keys: no echo, no line editing, Ctrl-C as a byte. False: not possible here (the typed fallback is used).
    func beginKeys() -> Bool
    /// Back to the mode before `beginKeys` (every exit path).
    func endKeys()
}

/// The controlling terminal.
public final class TTYChannel: PromptChannel {
    public let fd: Int32

    /// /dev/tty, or nil when there is none.
    public init?() {
        let f = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard f >= 0 else { return nil }
        fd = f
    }

    public func write(_ s: String) { _ = s.withCString { Darwin.write(fd, $0, strlen($0)) } }

    public func read(timeout: Int?) -> UInt8? {
        if let timeout {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(timeout)) > 0 else { return nil }
        }
        var c: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &c, 1)
            if n == 1 { return c }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    public func beginKeys() -> Bool { RawMode.enter(fd) }
    public func endKeys() { RawMode.leave() }
}

/// A script of input bytes and a record of what was written (tests).
public final class ScriptedChannel: PromptChannel {
    private var input: [UInt8]
    public private(set) var output = ""
    /// False: raw keys are refused (the typed fallback is exercised).
    public let keys: Bool

    public init(_ input: String, keys: Bool = true) {
        self.input = Array(input.utf8)
        self.keys = keys
    }

    public func write(_ s: String) { output += s }
    public func read(timeout: Int?) -> UInt8? { input.isEmpty ? nil : input.removeFirst() }
    public func beginKeys() -> Bool { keys }
    public func endKeys() {}
    /// What is left unread.
    public var remaining: Int { input.count }
}

/// The terminal's mode while keys are read raw — saved once, put back on every way out: `leave()`, an exit, and the
/// signals that end the process (TERM, HUP, QUIT; Ctrl-C arrives as a byte while raw and is handled by the reader).
enum RawMode {
    nonisolated(unsafe) static var saved = termios()
    nonisolated(unsafe) static var savedFD: Int32 = -1
    nonisolated(unsafe) static var handlersInstalled = false

    static func enter(_ fd: Int32) -> Bool {
        guard savedFD < 0 else { return true }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        saved = t
        // No echo, no line editing, no signals from keys (Ctrl-C is read as 0x03), no flow control, CR stays CR. OPOST
        // stays on: "\n" still goes out as CR LF.
        t.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        t.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { return false }
        savedFD = fd
        if !handlersInstalled {
            handlersInstalled = true
            atexit { RawMode.leave() }
            for s in [SIGTERM, SIGHUP, SIGQUIT] {
                signal(s) { sig in
                    RawMode.leave()
                    signal(sig, SIG_DFL)
                    raise(sig)
                }
            }
        }
        return true
    }

    static func leave() {
        guard savedFD >= 0 else { return }
        tcsetattr(savedFD, TCSANOW, &saved)
        savedFD = -1
    }
}

/// A key, decoded from the bytes a terminal sends.
public enum Key: Equatable, Sendable {
    case up, down, left, right, home, end
    case enter, space, tab, backspace, escape
    /// Ctrl-C.
    case interrupt
    /// Ctrl-D.
    case endOfInput
    /// Ctrl-U: clear the line.
    case clearLine
    case char(Character)
    /// A sequence or control byte nothing here uses.
    case other

    /// The next key from `channel`; nil at the end of input.
    public static func read(_ channel: PromptChannel) -> Key? {
        guard let b = channel.read(timeout: nil) else { return nil }
        switch b {
        case 0x0D, 0x0A: return .enter
        case 0x20: return .space
        case 0x09: return .tab
        case 0x7F, 0x08: return .backspace
        case 0x03: return .interrupt
        case 0x04: return .endOfInput
        case 0x15: return .clearLine
        case 0x1B: return escape(channel)
        case 0x00..<0x20: return .other
        default: return utf8(b, channel)
        }
    }

    /// After ESC: a lone Escape (nothing follows within 50 ms), or a CSI/SS3 sequence.
    private static func escape(_ channel: PromptChannel) -> Key {
        guard let b = channel.read(timeout: 50) else { return .escape }
        guard b == 0x5B || b == 0x4F else { return .other }          // [ or O
        var params = ""
        while let c = channel.read(timeout: 50) {
            if (0x40...0x7E).contains(c) {
                switch c {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                case 0x48: return .home
                case 0x46: return .end
                case 0x7E: return params == "1" || params == "7" ? .home : params == "4" || params == "8" ? .end : .other
                default: return .other
                }
            }
            params.append(Character(UnicodeScalar(c)))
            if params.count > 16 { return .other }
        }
        return .other
    }

    /// A character of one to four UTF-8 bytes.
    private static func utf8(_ lead: UInt8, _ channel: PromptChannel) -> Key {
        let more = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
        var bytes = [lead]
        for _ in 0..<more {
            guard let c = channel.read(timeout: 50), c & 0xC0 == 0x80 else { return .other }
            bytes.append(c)
        }
        guard let s = String(bytes: bytes, encoding: .utf8), let ch = s.first else { return .other }
        return .char(ch)
    }
}
