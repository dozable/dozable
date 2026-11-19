// The dashboard's — not in a build without it (the helper; DOZ_NO_WEB), like UICommand.swift, which registers UIMacs.
#if !DOZ_NO_WEB
import ArgumentParser
import DozableHost
import DozableWeb
import Foundation

// `doz ui macs` — Your Macs: the other Macs' dashboards this one keeps a bookmark of (`MacBookmarks`). The dashboard's
// machine picker lists them; picking one opens a plain link to its origin, where that Mac's own sign-in applies.
//
// `ls` is the read-only `macs-ls` (in-process when no daemon runs — it never starts one). `add`, `rm` and `check` write
// `<store>/macs.json` here, in-process, under its lock: the daemon never writes it. Reachability is checked only by `add`
// (unless --no-check) and `check` — never by the page, the daemon or a timer.

struct UIMacs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "macs",
        abstract: "Your Macs: the other Macs' dashboards the machine picker lists (names and addresses only).",
        discussion: """
        The list is yours: nothing is discovered. Add another Mac by its Tailscale name or LAN address — on that Mac, run \
        doz ui --lan or doz ui publish tailscale. Picking it in the dashboard opens that address in a new tab, where you \
        sign in to that Mac with doz ui share on it: no key, cookie or link of this Mac's is ever passed, kept or shown. \
        Whether a Mac answers is checked only when you add or check it. Example: doz ui macs add mini mini.example.ts.net
        """,
        subcommands: [UIMacsList.self, UIMacsAdd.self, UIMacsRemove.self, UIMacsCheck.self],
        defaultSubcommand: UIMacsList.self)
}

struct UIMacsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Your Macs: name, address, when each was last seen and what the last check found.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let l = try decode(try await query(HostRequest(.macsList), g), MacListing.self, g)
        if g.json { Out.json(l); return }
        guard !l.macs.isEmpty else {
            Out.stdout("Your Macs: none yet — doz ui macs add NAME ADDRESS\n")
            return
        }
        var t = [["NAME", "ADDRESS", "LAST SEEN", "LAST CHECK"]]
        for m in l.macs {
            t.append([macLabel(m.name, m.reportedName), m.origin + (m.scheme == "http" ? " (plain HTTP)" : ""),
                      m.lastSeenAt.map { Out.ago($0) } ?? "never",
                      m.lastCheckAt.map { (m.lastResult.flatMap(MacReachability.Outcome.init).map(MacReachability.words) ?? "?") + " · " + Out.ago($0) }
                        ?? "never checked"])
        }
        Out.stdout(Out.table(t))
    }
}

struct UIMacsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add one of your Macs by its dashboard's address; it is checked once.",
        discussion: """
        ADDRESS is its Tailscale name or LAN address, perhaps with a port: mini.example.ts.net, mini.local:7443, \
        http://192.168.1.20:7443. Never a sign-in link: it is refused, and nothing is kept. Without a port: 7443 over HTTP, \
        or https for a .ts.net name.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its name here: 1–32 characters of a-z, 0-9 and -.") var name: String
    @Argument(help: "Its dashboard's address: host[:port] or http(s)://host[:port].") var address: String
    @Flag(name: .customLong("no-check"), help: "Do not check whether it answers now.") var noCheck = false

    func run() async throws {
        do { try MacBookmarkName.validate(name) } catch let e as HostError { throw fail(e, g) }
        let origin: MacOrigin
        do { origin = try MacAddress.origin(address, thisMacPorts: thisMacPorts(g)) } catch let e as HostError { throw fail(e, g) }
        let store = MacBookmarkStore(store: g.dozableStore)
        func refusal(_ f: MacsFile) -> HostError? {
            if f.mac(name) != nil { return HostError(.exists, "there is already a Mac named \(name) in your list (doz ui macs rm \(name) first)") }
            if let other = f.macs.first(where: { $0.origin == origin.origin }) { return HostError(.exists, "that address is already in your list as \(other.name)") }
            return nil
        }
        do {
            if let e = refusal(try store.read()) { throw fail(e, g) }
        } catch let e as HostError { throw fail(e, g) }
        let result = noCheck ? nil : await MacReachability.check(origin)
        let now = Date()
        let row: MacRow?
        do {
            row = try store.update { f -> MacRow? in
                if let e = refusal(f) { throw e }
                var b = MacBookmark(name: name, origin: origin.origin, addedAt: now)
                if let result { b.record(result, at: now) }
                f.macs.append(b)
                return MacRow(b)
            }
        } catch let e as HostError { throw fail(e, g) }
        if g.json { if let row { Out.json(row) }; return }
        Out.stdout("Added \(name): \(origin.origin)\(origin.scheme == "http" ? " (plain HTTP)" : "")\n")
        if let result {
            let says = result.reportedName.map { $0 == name ? "" : " (it says it is \($0))" } ?? ""
            Out.stdout(result.outcome == .reachable ? "Checked: it answered\(says).\n"
                       : "Checked: \(MacReachability.words(result.outcome)) — kept; check again with doz ui macs check \(name)\n")
        } else {
            Out.stdout("Not checked (--no-check): doz ui macs check \(name)\n")
        }
        Out.stdout("Open it, and sign in there: run `doz ui share` on that Mac.\n")
    }
}

struct UIMacsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one of your Macs from the list (nothing on that Mac changes).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its name here.") var name: String

    func run() async throws {
        do {
            try MacBookmarkName.validate(name)
            try MacBookmarkStore(store: g.dozableStore).update { f in
                guard let i = f.macs.firstIndex(where: { $0.name == name }) else {
                    throw HostError(.notFound, "there is no Mac named \(name) in your list (doz ui macs ls)")
                }
                f.macs.remove(at: i)
            }
        } catch let e as HostError { throw fail(e, g) }
        if !g.json { Out.stdout("Removed \(name) from your Macs (nothing on that Mac changes).\n") }
        else { Out.json(["removed": name]) }
    }
}

struct UIMacsCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Check whether your Macs' dashboards answer now (one request each, to its address).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "One Mac (default: every one).") var name: String?

    func run() async throws {
        let store = MacBookmarkStore(store: g.dozableStore)
        let file: MacsFile
        do {
            if let name { try MacBookmarkName.validate(name) }
            file = try store.read()
        } catch let e as HostError { throw fail(e, g) }
        var targets: [(String, MacOrigin)] = []
        for b in file.macs where name == nil || b.name == name {
            if let o = MacAddress.stored(b.origin) { targets.append((b.name, o)) }
        }
        if let name, targets.isEmpty { throw fail(HostError(.notFound, "there is no Mac named \(name) in your list (doz ui macs ls)"), g) }
        if targets.isEmpty { if g.json { Out.json(MacListing(macs: [])) } else { Out.stdout("Your Macs: none yet — doz ui macs add NAME ADDRESS\n") }; return }
        let results = await withTaskGroup(of: (String, String, MacReachability.Result).self) { group in
            for (n, o) in targets { group.addTask { (n, o.origin, await MacReachability.check(o)) } }
            var out: [String: (String, MacReachability.Result)] = [:]
            for await (n, origin, r) in group { out[n] = (origin, r) }
            return out
        }
        let now = Date()
        let rows: [MacRow]
        do {
            rows = try store.update { f -> [MacRow] in
                var out: [MacRow] = []
                for i in f.macs.indices {
                    // Recorded only for the Mac as it was checked (removed or re-added meanwhile: left alone).
                    guard let (origin, r) = results[f.macs[i].name], f.macs[i].origin == origin else { continue }
                    f.macs[i].record(r, at: now)
                    if let row = MacRow(f.macs[i]) { out.append(row) }
                }
                return out
            }
        } catch let e as HostError { throw fail(e, g) }
        if g.json { Out.json(MacListing(macs: rows)); return }
        for row in rows {
            let r = row.lastResult.flatMap(MacReachability.Outcome.init) ?? .refused
            let seen = r == .reachable ? "" : row.lastSeenAt.map { " — last seen " + Out.ago($0, now: now) } ?? " — never seen"
            Out.stdout("\(macLabel(row.name, row.reportedName))  \(row.origin)  \(MacReachability.words(r))\(seen)\n")
        }
    }
}

/// "mini", or "mini (says: m1mini)" when its dashboard gave itself another name.
func macLabel(_ name: String, _ reported: String?) -> String {
    guard let r = reported, r.lowercased() != name else { return name }
    return "\(name) (says: \(r))"
}

/// The ports of THIS Mac's own dashboard — a loopback address on one of them is this Mac (`ui.port` when fixed, and the
/// port this store's last `doz ui` had).
func thisMacPorts(_ g: GlobalOptions) -> Set<Int> {
    let store = g.dozableStore
    var ports = Set<Int>()
    if case .fixed(let p) = UIRunner.portChoice(WebSettingsStore(environment: ProcessInfo.processInfo.environment)) { ports.insert(p) }
    if let p = WebControl.rememberedPort(store) { ports.insert(p) }
    return ports
}
#endif
