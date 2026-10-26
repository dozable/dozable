import ArgumentParser
import Foundation
import DozableKit
import DozableHost

// 617 (RP-1, owner: "web port forwarding first") — `doz ports` and `doz open`: a sandbox's web ports on this Mac's
// loopback. A recipe's own ports are forwarded while the sandbox runs; `doz ports add` adds any other (a dev server).

struct PortsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ports",
        abstract: "A sandbox's web ports on this Mac: list them, add one, remove one.",
        discussion: """
        A forward makes a port a program listens on inside the sandbox (its own localhost) reachable on this Mac \
        at 127.0.0.1 — never on the network. It listens while the sandbox runs and closes when it stops, sleeps or \
        hibernates; it comes back by itself at the next start or wake. The Mac port is the sandbox's when it is free \
        (and 1024 or above); otherwise another is picked, and said. The forward is inbound only: it lets this Mac \
        reach the program, never the program reach anything, and no key passes through it. An image's recipe can \
        declare its own ports (its Open buttons); `doz ports add` adds any other, kept until removed.
        """,
        subcommands: [PortsList.self, PortsAdd.self, PortsRemove.self],
        defaultSubcommand: PortsList.self)
}

enum PortsText {
    static func wakeHint(_ a: PortsAnswer) -> String {
        ["asleep", "hibernated", "paused"].contains(a.phase) ? "doz wake \(a.sandbox)" : "doz start \(a.sandbox)"
    }

    static func print(_ a: PortsAnswer) {
        if let n = a.note { Out.stdout(n + "\n") }
        guard !a.ports.isEmpty else {
            Out.stdout("\(a.sandbox) forwards no ports. Add one with doz ports add \(a.sandbox) PORT.\n")
            return
        }
        var rows: [[String]] = [["PORT", "TITLE", "ON THIS MAC", "STATE", "FROM"]]
        for p in a.ports {
            let mac = p.url ?? p.macPort.map { "127.0.0.1:\($0)" } ?? "—"
            var state = p.state
            if p.state == "failed", let why = p.why { state += ": \(why)" }
            if p.moved == true, p.state == "listening" { state += " (moved: \(p.port) was taken)" }
            rows.append([String(p.port), p.title, mac, state, p.origin == "recipe" ? "recipe" : "added"])
        }
        Out.stdout(Out.table(rows))
        if a.phase != "running" { Out.stdout("\n\(a.sandbox) is \(a.phase) — its ports listen while it runs (\(PortsText.wakeHint(a))).\n") }
        for p in a.ports where p.auth == "token" {
            if let s = p.signIn {
                Out.stdout("\n\(p.title) asks for a sign-in: doz open \(a.sandbox) \(p.port) signs this Mac's browser in (it runs \(s) in the sandbox).\n")
            } else {
                Out.stdout("\n\(p.title) asks for a token: \(p.tokenHint ?? "see its output").\n")
            }
        }
    }
}

struct PortsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls",
        abstract: "The sandbox's forwarded ports: the guest port, its URL on this Mac, and whether it listens.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String

    func run() async throws {
        let a = try decode(try await query(HostRequest(.ports, name: name), g), PortsAnswer.self, g)
        if g.json { Out.json(a); return }
        PortsText.print(a)
    }
}

struct PortsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Forward another port of the sandbox to this Mac (a dev server, a web UI you started) — kept until removed.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The port the program listens on inside the sandbox.") var port: Int
    @Option(name: .long, help: "What to call it (default: port N).") var title: String?
    @Option(name: .long, help: "The path doz open opens (default /).") var path: String?

    func run() async throws {
        var r = HostRequest(.ports, name: name)
        r.portAdd = PortForwardEntry(port: port, title: title, path: path)
        let a = try decode(try await query(r, g), PortsAnswer.self, g)
        if g.json { Out.json(a); return }
        PortsText.print(a)
    }
}

struct PortsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm",
        abstract: "Stop forwarding a port you added (a recipe's own ports stay).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The port inside the sandbox.") var port: Int

    func run() async throws {
        var r = HostRequest(.ports, name: name)
        r.portRemove = port
        let a = try decode(try await query(r, g), PortsAnswer.self, g)
        if g.json { Out.json(a); return }
        PortsText.print(a)
    }
}

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open",
        abstract: "Open a sandbox's web port in this Mac's browser (its first web port, or PORT).",
        discussion: """
        Opens the forward's URL (http://127.0.0.1:MACPORT/PATH). It starts nothing: a sandbox that is not running \
        says so (its ports listen while it runs). When the image's recipe says how to sign in to the page (OpenCode \
        web: opencode pair), it signs this Mac's browser in: the sign-in command runs in the sandbox and its one-time \
        link is opened at this Mac's port — the link is never printed, logged or kept. If that fails, the page opens \
        as it is and doz says why. --print prints the plain URL instead (it does not sign in).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The port inside the sandbox (default: its first web port).") var port: Int?
    @Flag(name: .long, help: "Print the URL instead of opening it.") var print = false

    func run() async throws {
        let a = try decode(try await query(HostRequest(.ports, name: name), g), PortsAnswer.self, g)
        let web = a.ports.filter { $0.protocol == "http" }
        guard !web.isEmpty else { throw HostError(.notFound, "\(name) forwards no web port — doz ports add \(name) PORT") }
        let row: PortForwardRow
        if let port {
            guard let r = web.first(where: { $0.port == port }) else {
                throw HostError(.notFound, "\(name) forwards no web port \(port) (\(web.map { String($0.port) }.joined(separator: ", ")))")
            }
            row = r
        } else {
            row = web[0]
        }
        guard a.phase == "running" else { throw HostError(.invalidPhase, "\(name) is \(a.phase) — its ports listen while it runs (\(PortsText.wakeHint(a)))") }
        guard let s = row.url, let url = URL(string: s) else {
            throw HostError(.unavailable, "\(row.title) (port \(row.port)) is not listening: \(row.why ?? row.state)")
        }
        if print {
            if g.json { Out.json(row) } else { Out.stdout(s + "\n") }
            if row.signIn != nil, !g.quiet { Out.stderr("(the page as it is — doz open \(name) \(row.port) opens it signed in)\n") }
            return
        }
        // 666: a port whose recipe says how to sign in — the HOST runs the sign-in and opens the link (it never comes here).
        if let command = row.signIn {
            var r = HostRequest(.portOpen, name: name)
            r.openPort = row.port
            let m = try rawCall(r, g, autostart: false)
            if m.ok == true {
                let o = try decode(m.result ?? .null, PortOpened.self, g)
                if g.json { Out.json(o); return }
                if o.signedIn {
                    Out.stdout("opened \(o.title) — \(o.url), signed in (a one-time link from \(command))\n")
                } else {
                    Out.stdout("opened \(o.title) — \(o.url), without signing in\n")
                    if !g.quiet { Out.stderr("could not sign in: \(o.problem ?? "no link") — \(row.tokenHint ?? "sign in on the page")\n") }
                }
                return
            }
            let e = m.error ?? HostError(.failed, "the host gave no reason")
            // An older host cannot read the request: open the page as before.
            guard e.code == .invalid, e.message.contains("cannot read") else { throw fail(e, g) }
            if !g.quiet { Out.stderr("the running host cannot sign in (an older build) — opening the page as it is\n") }
        }
        if g.json { Out.json(row); _ = BrowserBridge.open(url, callback: nil); return }
        guard BrowserBridge.open(url, callback: nil) else { throw HostError(.failed, "this Mac could not open \(s)") }
        Out.stdout("opened \(row.title) — \(s)\n")
        if row.auth == "token" { Out.stdout("it asks for a token: \(row.tokenHint ?? "see its output")\n") }
    }
}
