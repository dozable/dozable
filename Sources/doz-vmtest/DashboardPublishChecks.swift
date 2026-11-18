// 715 — `make test-cli-alwayson` part 5: the dashboard published on Tailscale, end to end through SEAMS only — a FAKE
// tailscale/tailscaled (Scripts/fake-tailscale.py) in a scratch Homebrew-shaped prefix (DOZ_TEST_BREW_PREFIX), a scratch
// LaunchAgents folder and the FAKE launchctl (Scripts/fake-launchctl.py: it runs the plist's program at load, as launchd
// would), the suite's scratch store and settings, a port the OS picked, no browser (`--no-open` and the browser seam).
// Never the real tailscale, launchctl, ~/Library/LaunchAgents or the owner's settings.
//
//   a. without Homebrew's tailscale: refused, naming brew install tailscale; nothing written;
//   b. publish: the LaunchAgent (KeepAlive, RunAtLoad, tailscaled's userspace argv under the store), the sign-in link shown
//      and approved, the node named dozable-<mac>, serve 443 → the dashboard's port and 80 → the redirect's socket, the
//      settings written, the dashboard restarted on the same port with the LAN option, port 80's redirect answering 308;
//   c. doctor's rows: node, login, https, http all ok; a node serving another port → the https row fails, naming the port;
//   d. publish again: no link, the name re-applied (set), 443 pointed at the dashboard again; publish status --json;
//   e. unpublish --logout: serve reset, logout, the LaunchAgent booted out and removed, the state removed, the settings
//      back to this Mac only (ui.port kept), the dashboard restarted without the LAN option;
//   f. a sign-in never approved: the link shown, then "run the same command again"; unpublish cleans up.
import Darwin
import Foundation
import DozableKit
import DozableHost

func dashboardPublishChecks(_ h: CLIHarness, root: URL) {
    print("cli: the dashboard published on Tailscale (a fake tailscale)")
    let fm = FileManager.default
    let brew = root.appendingPathComponent("tsbrew")
    let bin = brew.appendingPathComponent("opt/tailscale/bin")
    let agents = root.appendingPathComponent("ts-launchagents")
    let tsLog = root.appendingPathComponent("ts.log"), tsState = root.appendingPathComponent("ts.json")
    let lcLog = root.appendingPathComponent("lc.log"), lcState = root.appendingPathComponent("lc.json")
    let store = DozableStore(root: root)
    let paths = TailscalePublish.paths(store)
    let fake = URL(fileURLWithPath: "Scripts/fake-tailscale.py").standardizedFileURL.path
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try? fm.createDirectory(at: agents, withIntermediateDirectories: true)
    for n in ["tailscale", "tailscaled"] {
        let t = bin.appendingPathComponent(n).path
        try? fm.removeItem(atPath: t)
        try? fm.copyItem(atPath: fake, toPath: t)
        chmod(t, 0o755)
    }
    try? "{\"login\": \"approve\"}".write(to: tsState, atomically: true, encoding: .utf8)
    try? "{}".write(to: lcState, atomically: true, encoding: .utf8)

    let b = CLIHarness(binary: h.binary, store: root)
    b.env = h.env
    b.env["DOZ_TEST_BROWSER_LOG"] = root.appendingPathComponent("browser.log").path
    b.env["DOZ_TEST_LAUNCH_AGENTS_DIR"] = agents.path
    b.env["DOZ_TEST_LAUNCHCTL"] = URL(fileURLWithPath: "Scripts/fake-launchctl.py").standardizedFileURL.path
    b.env["FAKE_LAUNCHCTL_LOG"] = lcLog.path
    b.env["FAKE_LAUNCHCTL_STATE"] = lcState.path
    b.env["FAKE_LAUNCHCTL_RUN_AT_LOAD"] = "1"
    b.env["FAKE_TAILSCALE_LOG"] = tsLog.path
    b.env["FAKE_TAILSCALE_STATE"] = tsState.path
    b.env["DOZ_TEST_MAC_NAME"] = "Test-Mac"
    b.env.removeValue(forKey: "DOZ_TEST_BREW_PREFIX")
    b.env.removeValue(forKey: "DOZ_UI_PORT")
    b.env.removeValue(forKey: "DOZ_UI_LAN")
    let plist = TailscalePublish.plistURL(store, folder: agents)
    let origin = "https://dozable-test-mac.tail-fake.ts.net"
    func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
    func get(_ key: String) -> String { b.run(["config", "get", key]).out.trimmingCharacters(in: .whitespacesAndNewlines) }
    func uiStatus() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(b.run(["ui", "status", "--json"]).out.utf8))) as? [String: Any] ?? [:]
    }
    func doctorRows() -> [String: (String, String)] {
        let out = b.run(["doctor", "--json"], timeout: 120).out
        let rows = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
        var d: [String: (String, String)] = [:]
        for r in rows { if let c = r["check"] as? String { d[c] = ((r["status"] as? String) ?? "", (r["detail"] as? String) ?? "") } }
        return d
    }
    func editState(_ change: (inout [String: Any]) -> Void) {
        var s = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tsState))) as? [String: Any] ?? [:]
        change(&s)
        if let d = try? JSONSerialization.data(withJSONObject: s) { try? d.write(to: tsState) }
    }
    defer {
        b.run(["ui", "unpublish", "tailscale", "--logout"], timeout: 120)
        b.run(["ui", "stop"], timeout: 30)
        check(WebControlPid.of(root) == nil && !fm.fileExists(atPath: plist.path), "publish: no doz ui and no LaunchAgent of this suite left")
    }

    // a. no Homebrew tailscale.
    var r = b.run(["ui", "publish", "tailscale"], timeout: 60)
    check(r.code != 0 && r.err.contains("brew install tailscale") && !fm.fileExists(atPath: plist.path) && text(lcLog).isEmpty,
          "publish a: without Homebrew's tailscale it is refused, naming brew install tailscale; nothing written, launchctl never run")
    b.env["DOZ_TEST_BREW_PREFIX"] = brew.path

    // b. publish, on the running dashboard's port (the OS's pick).
    r = b.run(["ui", "--detach", "--no-open"], timeout: 60)
    let port0 = (uiStatus()["origin"] as? String).flatMap { Int($0.split(separator: ":").last ?? "") }
    guard r.code == 0, let port = port0 else { check(false, "publish b: doz ui --detach --no-open (\(r.code))"); return }
    r = b.run(["ui", "publish", "tailscale", "--wait", "20"], timeout: 180)
    check(r.code == 0 && r.out.contains("https://login.tailscale.com/a/fake0123") && r.out.contains(origin) && r.out.contains("doz ui share"),
          "publish b: the sign-in link shown, the address and the next step said (\(r.code): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))")
    check(!r.out.contains("#cap=") && !r.err.contains("#cap="), "publish b: no dashboard link or invite printed")
    let p = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]
    let argv = p["ProgramArguments"] as? [String] ?? []
    check(p["KeepAlive"] as? Bool == true && p["RunAtLoad"] as? Bool == true && p["Label"] as? String == TailscalePublish.label(store)
          && argv == [bin.appendingPathComponent("tailscaled").path, "--tun=userspace-networking", "--statedir=\(paths.stateDir.path)",
                      "--socket=\(paths.socket.path)", "--port=0"],
          "publish b: one LaunchAgent in the scratch folder — KeepAlive, RunAtLoad, tailscaled userspace under the store (\(argv))")
    check(text(lcLog).contains("bootstrap gui/"), "publish b: loaded through the (fake) launchctl")
    let ts = text(tsLog).split(separator: "\n").map(String.init)
    let calls = ts.filter { $0.hasPrefix("tailscale ") }
    check(!calls.isEmpty && calls.allSatisfy { $0.hasPrefix("tailscale --socket=\(paths.socket.path) ") },
          "publish b: every tailscale command names Dozable's node's socket")
    check(calls.contains { $0.contains(" up --hostname=dozable-test-mac ") },
          "publish b: the node signed in as dozable-test-mac (the Mac's local hostname, lower case)")
    check(calls.contains { $0.hasSuffix("serve --bg --yes --https=443 http://127.0.0.1:\(port)") }
          && calls.contains { $0.hasSuffix("serve --bg --yes --http=80 unix:\(paths.redirectSocket.path)") },
          "publish b: serve 443 → 127.0.0.1:\(port) (the dashboard's port) and 80 → the redirect's socket")
    check(get("ui.port") == "\(port)" && get("ui.lan") == "true" && get("serve.bind") == "loopback" && get("serve.public_origins") == origin
          && get("serve.trusted_proxies") == "127.0.0.1,::1" && get("serve.chat") == "off",
          "publish b: the settings — ui.port \(port), ui.lan, serve.bind loopback, public origin, trusted proxies; serve.chat untouched")
    let st = uiStatus()
    check((st["origin"] as? String)?.hasSuffix(":\(port)") == true && st["lan"] != nil,
          "publish b: the dashboard restarted on the same port with the LAN option (\(st["origin"] ?? "none"))")
    let red = TailscalePublish.askRedirect(paths.redirectSocket.path)
    check(red?.status == 308 && red?.location == origin + "/doctor",
          "publish b: port 80's redirect answers 308 → \(origin)/doctor (\(red.map { "\($0.status) \($0.location ?? "")" } ?? "no answer"))")
    check(!text(root.appendingPathComponent("browser.log")).contains("open"), "publish b: no browser tab opened")

    // c. doctor.
    var d = doctorRows()
    check(d["tailscale node"]?.0 == "ok" && d["tailscale login"]?.0 == "ok" && d["tailscale https"]?.0 == "ok" && d["tailscale http"]?.0 == "ok",
          "publish c: doctor's node, login, https and http rows are ok (\(d.filter { $0.key.hasPrefix("tailscale") }.map { "\($0.key)=\($0.value.0)" }.sorted()))")
    editState { s in var w = s["web"] as? [String: Any] ?? [:]; w["443"] = "http://127.0.0.1:1"; s["web"] = w }
    d = doctorRows()
    check(d["tailscale https"]?.0 == "fail" && d["tailscale https"]?.1.contains("the dashboard's port is \(port)") == true,
          "publish c: a node serving another port → the https row fails, naming the dashboard's port (\(d["tailscale https"]?.1 ?? "no row"))")

    // d. again: idempotent, no sign-in.
    r = b.run(["ui", "publish", "tailscale"], timeout: 180)
    let again = text(tsLog).split(separator: "\n").map(String.init).dropFirst(ts.count)
    check(r.code == 0 && !r.out.contains("login.tailscale.com") && again.contains { $0.contains(" set --hostname=dozable-test-mac") }
          && !again.contains { $0.contains(" up ") },
          "publish d: run again on a signed-in node — no link, the name re-applied (set), no up")
    d = doctorRows()
    check(d["tailscale https"]?.0 == "ok", "publish d: 443 points at the dashboard again")
    let js = (try? JSONSerialization.jsonObject(with: Data(b.run(["ui", "publish", "status", "--json"]).out.utf8))) as? [String: Any] ?? [:]
    let node = js["node"] as? [String: Any] ?? [:]
    check(js["published"] as? Bool == true && js["address"] as? String == origin && node["signedIn"] as? Bool == true
          && (js["serve"] as? [String: Any])?["https"] as? String == "http://127.0.0.1:\(port)",
          "publish d: publish status --json — published, the address, signed in, serving the dashboard's port")

    // e. unpublish --logout.
    let before = text(tsLog).split(separator: "\n").count
    r = b.run(["ui", "unpublish", "tailscale", "--logout"], timeout: 120)
    let un = text(tsLog).split(separator: "\n").map(String.init).dropFirst(before)
    check(r.code == 0 && un.contains { $0.hasSuffix(" serve reset") } && un.contains { $0.hasSuffix(" logout") },
          "publish e: unpublish --logout — serve reset, logout (\(r.code))")
    check(!fm.fileExists(atPath: plist.path) && text(lcLog).contains("bootout gui/") && !fm.fileExists(atPath: paths.stateDir.path)
          && TailscalePublish.readMarker(store) == nil,
          "publish e: the LaunchAgent booted out and removed, the node's state and the marker removed")
    check(get("ui.lan") == "false" && get("serve.public_origins").isEmpty && get("serve.trusted_proxies").isEmpty && get("serve.bind") == "lan"
          && get("ui.port") == "\(port)",
          "publish e: the settings back to this Mac only (ui.port \(get("ui.port")) kept)")
    let after = uiStatus()
    check((after["origin"] as? String)?.hasSuffix(":\(port)") == true && after["lan"] == nil,
          "publish e: the dashboard restarted without the LAN option")
    check(doctorRows().keys.allSatisfy { !$0.hasPrefix("tailscale") }, "publish e: doctor has no Tailscale rows once unpublished")

    // f. a sign-in never approved.
    editState { s in s["login"] = "never" }
    r = b.run(["ui", "publish", "tailscale", "--wait", "5"], timeout: 120)
    check(r.code != 0 && r.out.contains("https://login.tailscale.com/a/fake0123") && r.err.contains("run the same command again"),
          "publish f: not approved in time → the link was shown, then \"run the same command again\" (\(r.code))")
}

/// The running doz ui's pid for a store (its lock records it), or nil.
enum WebControlPid {
    static func of(_ root: URL) -> Int32? {
        (try? String(contentsOf: root.appendingPathComponent("ui.lock"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 0 && kill($0, 0) == 0 ? $0 : nil }
    }
}
