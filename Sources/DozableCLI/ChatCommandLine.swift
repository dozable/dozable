import Darwin
import DozableChat
import Foundation

/// `doz chat …` — the chat server (hidden: not in `doz --help`, the manual or completions until it is a feature people
/// use). It is dispatched before anything else of doz runs, so a chat server reads no settings file, opens no store,
/// starts no daemon and touches no Keychain: `doz chat serve` needs only its config, its flags and its secrets file.
///
///   doz chat serve --config FILE --bind ADDR [--data-dir DIR] [--secrets-file FILE] [--line-port N] [--page-port N]
///                  [--claude-sessions DIR] [--supervised]
///
/// `--claude-sessions DIR` is where Claude Code's session records are read (default `$HOME/.claude/sessions`).
///   doz chat status [--json] --data-dir DIR
///
/// A flag is written `--name value`, `--name=value`, `-name value` or `-name=value`. A bad flag or setting exits 78.
public enum ChatCommandLine {
    static let usage = """
        usage: doz chat serve --config FILE --bind ADDR [--data-dir DIR] [--secrets-file FILE] [--line-port N] [--page-port N]
                              [--claude-sessions DIR] [--supervised]
               doz chat status [--json] --data-dir DIR

        """

    public static func run(_ args: [String], release: String) async -> Int32 {
        guard let sub = args.first else { FileHandle.standardError.write(Data(usage.utf8)); return 64 }
        switch sub {
        case "serve": return await serve(Array(args.dropFirst()), release: release)
        case "status": return status(Array(args.dropFirst()), release: release)
        case "-h", "--help", "help": FileHandle.standardOutput.write(Data(usage.utf8)); return 0
        default:
            FileHandle.standardError.write(Data("doz chat: unknown command \(sub)\n\(usage)".utf8))
            return 64
        }
    }

    /// Flags as Go's flag package reads them: the value flags given, and the bool flags that were set.
    struct Flags {
        var values: [String: String] = [:]
        var bools: Set<String> = []
    }

    static func parse(_ args: [String], values: Set<String>, bools: Set<String>) throws -> Flags {
        var f = Flags()
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("-"), a != "-", a != "--" else { throw ChatConfigError("serve takes no argument \"\(a)\"") }
            var name = String(a.drop(while: { $0 == "-" }))
            var value: String?
            if let eq = name.firstIndex(of: "=") { value = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
            if bools.contains(name) {
                if let v = value, v != "true" && v != "false" { throw ChatConfigError("invalid boolean value \"\(v)\" for -\(name)") }
                if value != "false" { f.bools.insert(name) }
            } else if values.contains(name) {
                if value == nil {
                    i += 1
                    guard i < args.count else { throw ChatConfigError("flag needs an argument: -\(name)") }
                    value = args[i]
                }
                f.values[name] = value
            } else {
                throw ChatConfigError("flag provided but not defined: -\(name)")
            }
            i += 1
        }
        return f
    }

    static func serve(_ args: [String], release: String) async -> Int32 {
        if args.contains("-h") || args.contains("--help") { FileHandle.standardOutput.write(Data(usage.utf8)); return 0 }
        func bad(_ why: String) -> Int32 {
            FileHandle.standardError.write(Data("chat: \(why)\n".utf8))
            return ChatExit.badSetting
        }
        let f: Flags
        do {
            f = try parse(args, values: ["config", "bind", "data-dir", "secrets-file", "line-port", "page-port", "claude-sessions"], bools: ["supervised"])
        } catch { return bad("\(error) (doz chat serve -h lists the settings)") }
        guard let config = f.values["config"], !config.isEmpty else { return bad("--config FILE is required") }
        var o = ChatServeOptions(configPath: absolute(config), release: release)
        o.supervised = f.bools.contains("supervised")
        o.overrides.bind = f.values["bind"]
        o.overrides.dataDir = f.values["data-dir"].map(absolute)
        o.secretsFile = f.values["secrets-file"].map(absolute)
        o.claudeSessions = f.values["claude-sessions"].map(absolute)
        for flag in ["line-port", "page-port"] {
            guard let v = f.values[flag] else { continue }
            guard let n = Int(v), (0...65535).contains(n) else { return bad("--\(flag): \"\(v)\" is not a port (0 to 65535)") }
            if flag == "line-port" { o.overrides.linePort = n } else { o.overrides.pagePort = n }
        }
        await ChatServer.run(o)
    }

    static func status(_ args: [String], release: String) -> Int32 {
        let f: Flags
        do { f = try parse(args, values: ["data-dir"], bools: ["json"]) } catch {
            FileHandle.standardError.write(Data("doz chat status: \(error)\n".utf8))
            return 64
        }
        guard let dir = f.values["data-dir"], !dir.isEmpty else {
            FileHandle.standardError.write(Data("doz chat status: --data-dir DIR is required\n".utf8))
            return 64
        }
        let st = ChatServer.status(dataDir: absolute(dir), release: release)
        if f.bools.contains("json") {
            FileHandle.standardOutput.write(Data(st.text.utf8))
        } else {
            var t = st.running ? (st.ready ? "chat server: running and ready\n" : "chat server: running, not ready yet\n") : "chat server: not running\n"
            t += "  data folder: \(st.dataDir)\n"
            if let p = st.ports { t += "  line port \(p.line), page port \(p.page)\n" }
            for p in st.problems { t += "  problem: \(p.what)\n" }
            FileHandle.standardOutput.write(Data(t.utf8))
        }
        return 0
    }

    static func absolute(_ p: String) -> String {
        var s = p
        if s.hasPrefix("~/") { s = NSHomeDirectory() + String(s.dropFirst()) }
        return URL(fileURLWithPath: s).standardizedFileURL.path
    }
}
