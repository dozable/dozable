import Darwin
import Foundation
import DozableKit

// 666 (618.B1, owner: "sign in from the Open button"): a recipe's web port may declare a sign-in command (`ports@1
// sign_in`, e.g. `opencode pair`). Open runs it in the sandbox as the session's user, takes the first link it prints to
// that port, keeps the link's path, query and fragment, and opens them at the Mac's forward —
// `http://127.0.0.1:<the Mac's port><path>` — so the browser lands signed in even when the Mac's port moved.
//
// The link is a SECRET (a one-time sign-in). It lives only in this process's memory, for the moment between the
// command's output and the opener: never in a log, a note, an event, the store, telemetry, an answer or an error.
// Every sentence here is built from the recipe's own words (its title, its command) and numbers — never from the
// command's output. The Mac's browser is opened through LaunchServices (`MacDefaultApp.openURL`), never
// `/usr/bin/open URL`, so the link is not a process argument either. `PortSignInTests` holds all of it.

public enum PortSignIn {
    /// At most this much of the command's output is read for the link.
    static let maximumOutput = 65_536
    /// A link's path, query and fragment, at most.
    static let maximumLinkBytes = 4096

    /// What an Open did — the answer's fields and the one line said to the sandbox's viewers and the host log.
    public struct Outcome: Equatable, Sendable {
        /// The address opened without the link — the forward's plain URL.
        public var url: String
        public var signedIn: Bool
        public var problem: String?
        /// Whether this Mac's browser was asked to open anything.
        public var opened: Bool
        public var line: String
    }

    /// The link to `guestPort` in the command's output: the first http(s) URL whose host is a loopback name and whose
    /// port is `guestPort` (`linkPath`: and whose path starts with it). Answers its path, query and fragment as printed
    /// (percent-encoding kept). nil: none — a URL to anywhere else (a vendor's page, another port) is never taken.
    static func link(in output: String, guestPort: Int, linkPath: String?) -> String? {
        let text = plain(output)
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s"'<>`\\]+"#) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: m.range)
            while let last = raw.last, ".,;:!?)]}".contains(last) { raw.removeLast() }       // prose around a link
            guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = c.host, isLoopback(host), c.user == nil, c.password == nil,
                  (c.port ?? (scheme == "https" ? 443 : 80)) == guestPort else { continue }
            var rest = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
            if let q = c.percentEncodedQuery { rest += "?" + q }
            if let f = c.percentEncodedFragment { rest += "#" + f }
            guard rest.hasPrefix("/"), !rest.hasPrefix("//"), rest.utf8.count <= maximumLinkBytes,
                  !rest.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else { continue }
            if let p = linkPath, !rest.hasPrefix(p) { continue }
            return rest
        }
        return nil
    }

    /// Terminal escapes out (a colouring program's CSI and OSC sequences), so a link is read as a person sees it.
    static func plain(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return out
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasPrefix("127.") || h == "0.0.0.0" || h == "::1" || h == "::"
    }

    /// What may be shown of a sign-in URL: scheme, host, port and the path with its last part elided — never the query
    /// or the fragment (`http://127.0.0.1:49374/auth/connect/…`).
    public static func shown(_ url: URL) -> String {
        var s = "\(url.scheme ?? "http")://\(url.host ?? "")"
        if let p = url.port { s += ":\(p)" }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if !parts.isEmpty { parts[parts.count - 1] = "…" }
        s += "/" + parts.joined(separator: "/")
        if url.query != nil { s += "?…" }
        if url.fragment != nil { s += "#…" }
        return s
    }

    /// Run the sign-in and open what it gives — or, when it fails, the plain address — and say which. `exec` runs an argv
    /// in the sandbox (as the session's user) within the seconds given; `open` opens a URL in this Mac's browser
    /// (`signedIn`: the URL carries a sign-in — the opener must never write it anywhere).
    static func run(_ s: AgentRecipe.SignIn, title: String, guestPort: Int, macPort: Int, path: String?,
                    exec: (_ argv: [String], _ seconds: Int) async throws -> ExecResult,
                    open: (_ url: URL, _ signedIn: Bool) -> Bool) async -> Outcome {
        let plainURL = PortForwarding.url(macPort: macPort, path: path)
        let cmd = "`\(s.command)`"
        var problem: String
        do {
            let r = try await exec(s.argv, s.seconds)
            if r.exitCode != 0 {
                problem = "\(cmd) exited with \(r.exitCode)"
            } else {
                let out = String(decoding: r.stdout.prefix(maximumOutput), as: UTF8.self) + "\n"
                    + String(decoding: r.stderr.prefix(maximumOutput), as: UTF8.self)
                // The guest's words only ever choose the PATH: the address is this Mac's forward, checked again.
                if let rest = link(in: out, guestPort: guestPort, linkPath: s.linkPath),
                   let url = URL(string: "http://127.0.0.1:\(macPort)" + rest), url.host == "127.0.0.1", url.port == macPort {
                    if open(url, true) {
                        return Outcome(url: plainURL, signedIn: true, problem: nil, opened: true,
                                       line: "\(title): opened on this Mac, signed in with a one-time link from \(cmd)")
                    }
                    problem = "this Mac could not open the sign-in link"
                } else {
                    problem = "\(cmd) printed no link to port \(guestPort)"
                }
            }
        } catch {
            problem = why(error, cmd: cmd, program: s.argv[0], seconds: s.seconds)
        }
        // The fallback: the page as it is (the person signs in as the recipe's hint says).
        let opened = URL(string: plainURL).map { open($0, false) } ?? false
        return Outcome(url: plainURL, signedIn: false, problem: problem, opened: opened,
                       line: "\(title): could not sign in — \(problem); " + (opened ? "opened \(plainURL) without signing in" : "this Mac could not open \(plainURL) either"))
    }

    /// Why the command could not be run, in words — from the error's KIND only (never its text: nothing the command
    /// printed may reach a message).
    static func why(_ error: Error, cmd: String, program: String, seconds: Int) -> String {
        let text = (String(describing: error) + " " + error.localizedDescription).lowercased()
        if text.contains("failed to find target executable") { return "`\(program)` is not installed in this sandbox" }
        if text.contains("timeout") || text.contains("timed out") || text.contains("deadline") { return "\(cmd) did not finish within \(seconds) s" }
        if let e = error as? SandboxError, case .notRunning = e { return "the sandbox is not running" }
        return "\(cmd) could not be run in the sandbox"
    }

    // MARK: opening on this Mac

    /// Open `url` in this Mac's default browser through LaunchServices (no process argument). In tests
    /// (`DOZ_TEST_OPEN_URL=<file>`, the browser bridge's seam) nothing opens: a plain URL is recorded as `open URL`; a
    /// sign-in is recorded as `open-signed-in` + `shown(url)` — never the link — and then PLAYED as a browser would
    /// (`SeamBrowser`), its result recorded as `signed-in-browser …` (status codes and cookie NAMES only).
    public static func openOnMac(_ url: URL, signedIn: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let seam = environment["DOZ_TEST_OPEN_URL"], !seam.isEmpty {
            guard signedIn else {
                BrowserBridge.append(seam, "open \(url.absoluteString)\n")
                return true
            }
            BrowserBridge.append(seam, "open-signed-in \(shown(url))\n")
            let check = environment["DOZ_TEST_SIGNED_IN_CHECK"].flatMap { PortForwarding.isPath($0) ? $0 : nil }
            Thread.detachNewThread {
                usleep(300_000)
                BrowserBridge.append(seam, "signed-in-browser \(SeamBrowser.visit(url, check: check))\n")
            }
            return true
        }
        return MacDefaultApp.openURL(url)
    }
}

/// 666: the opener seam's browser for a sign-in link (tests only): GET the link as a browser does (Accept: text/html),
/// keep its cookies IN MEMORY, follow one redirect, GET `check` with them, and GET the link again (a one-time link is
/// spent). Describes what happened by status codes and cookie names — never a value.
enum SeamBrowser {
    static func visit(_ url: URL, check: String?) -> String {
        guard let port = url.port else { return "no port" }
        var rest = url.path.isEmpty ? "/" : url.path
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            rest = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
            if let q = c.percentEncodedQuery { rest += "?" + q }
        }
        var jar: [String: String] = [:]
        var said: [String] = []
        let first = get(port: port, path: rest, cookies: jar)
        for (n, v) in first.cookies { jar[n] = v }
        said.append("link \(first.status)" + (first.cookies.isEmpty ? "" : " cookies " + first.cookies.map(\.0).sorted().joined(separator: ",")))
        if let loc = first.location, loc.hasPrefix("/"), !loc.hasPrefix("//") {
            let next = get(port: port, path: loc, cookies: jar)
            for (n, v) in next.cookies { jar[n] = v }
            let where_ = String(loc.prefix { $0 != "?" && $0 != "#" })                       // a redirect's query is never said
            said.append("then \(where_.count <= 40 ? where_ : "…") \(next.status)")
        }
        if let check {
            said.append("\(check) \(get(port: port, path: check, cookies: jar).status)")
            said.append("without the cookies \(get(port: port, path: check, cookies: [:]).status)")
        }
        said.append("the link again \(get(port: port, path: rest, cookies: [:]).status)")
        return said.joined(separator: " · ")
    }

    struct Answer { var status: Int; var location: String?; var cookies: [(String, String)] }

    /// One HTTP/1.1 GET on 127.0.0.1:port (Connection: close); the status, Location and Set-Cookie name=value pairs.
    static func get(port: Int, path: String, cookies: [String: String]) -> Answer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return Answer(status: 0, location: nil, cookies: []) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                            sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return Answer(status: 0, location: nil, cookies: []) }
        var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept: text/html,application/xhtml+xml\r\nConnection: close\r\n"
        if !cookies.isEmpty { head += "Cookie: " + cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") + "\r\n" }
        _ = UnixSocket.writeAll(fd, Data((head + "\r\n").utf8))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 262_144 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let r = data.range(of: Data("\r\n\r\n".utf8)), r.lowerBound > 0 { break }      // the head is enough
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { l in l.split(separator: " ").dropFirst().first.flatMap { Int($0) } } ?? 0
        var location: String?
        var got: [(String, String)] = []
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { if l.isEmpty { break } else { continue } }
            let name = l[..<colon].lowercased()
            let value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "location" { location = value }
            if name == "set-cookie", let pair = value.split(separator: ";").first, let eq = pair.firstIndex(of: "=") {
                got.append((String(pair[..<eq]).trimmingCharacters(in: .whitespaces), String(pair[pair.index(after: eq)...])))
            }
        }
        return Answer(status: status, location: location, cookies: got)
    }
}
