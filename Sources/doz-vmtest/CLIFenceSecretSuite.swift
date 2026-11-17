import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence`, rows 692: a secret given at launch (`--secret`) to a fenced session — the session sees only a
// placeholder (its variable and its file), the proxy swaps it on exactly HOST:PORT (plain HTTP to this Mac's route, and to
// a Tailscale literal through the guarded seam), refuses it everywhere else, follows the setting at a restart, answers 401
// "no secret" after a new daemon under the memory keychain, and the record's removal takes the item with it. Listeners of
// the suite's own on 127.0.0.1 (ephemeral ports) record the Authorization header they receive; all are stopped here.

func cliFenceSecretChecks(_ t: CLIHarness, root: String, home: String, store: String, net: String, helpers: String,
                          started: inout Set<String>) async {
    print("cli: 692 a secret given at launch — a placeholder in the fenced session, swapped only on its host and port")
    func put(_ p: String, _ s: String) { FileManager.default.createFile(atPath: p, contents: Data(s.utf8)) }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func code(_ n: String) -> String { get(net + "/res/" + n + ".code") }
    func body(_ n: String) -> String { get(net + "/res/" + n + ".body") }
    func done(_ n: String, _ seconds: Double = 60) -> Bool { t.waitFor(seconds) { FileManager.default.fileExists(atPath: net + "/res/" + n) } }
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func ledgerOwners() -> [String] { Array(LaunchSecretLedger.load(DozableStore(root: URL(fileURLWithPath: store))).items.values) }

    // The listeners: P1 (the secret's port), P2 (another port opened to it), and the seam's (a Tailscale literal and a
    // plain site the host's guarded seam routes here).
    let s1 = FenceUpstream(), s2 = FenceUpstream(), s3 = FenceUpstream()
    let p1 = s1.port, p2 = s2.port
    defer { s1.stop(); s2.stop(); s3.stop() }
    // A daemon with the seams (it reads them at its start): the Tailscale literal and a plain site → s3; this Mac counts
    // as on Tailscale (guarded runs only).
    t.run(["daemon", "stop"], timeout: 60)
    let savedUp = t.env["DOZ_TEST_FENCE_UPSTREAMS"]
    t.env["DOZ_TEST_FENCE_UPSTREAMS"] = (savedUp.map { $0 + "," } ?? "") + "100.64.0.9=127.0.0.1:\(s3.port),plain.doz.test=127.0.0.1:\(s3.port)"
    t.env["DOZ_TEST_TAILSCALE_UP"] = "1"
    defer {
        t.run(["daemon", "stop"], timeout: 60)
        t.env["DOZ_TEST_FENCE_UPSTREAMS"] = savedUp
        t.env["DOZ_TEST_TAILSCALE_UP"] = nil
    }
    // The secrets' files: outside everything the session reads, 0600, one line each. Obviously fake values.
    let value = "FAKE-FENCE-SECRET-692-0123456789", tsValue = "FAKE-TS-SECRET-692", plainValue = "FAKE-PLAIN-SECRET-692"
    let src = root + "/secret-src"
    try? FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for (n, v, mode) in [("token", value, 0o600), ("ts", tsValue, 0o600), ("plain", plainValue, 0o600), ("open", value, 0o644)] {
        FileManager.default.createFile(atPath: src + "/" + n, contents: Data((v + "\n").utf8), attributes: [.posixPermissions: mode])
    }
    let perms = "standard,site:allowed.doz.test,site:100.64.0.9:8080,site:plain.doz.test:8080"
    func run(_ s: String, _ script: String, _ extra: [String]) -> CLIRun {
        let r = t.run(["run", "@mac", "-d", "--fenced", "--session", s, "--folder", net] + extra + ["--", "/bin/sh", script], timeout: 90)
        if r.code == 0 { started.insert(s) }
        return r
    }
    let secretFlags = ["--host-port", String(p1), "--host-port", String(p2), "--permissions", perms,
                       "--secret", "SVC_TOKEN,src=\(src)/token,to=host.dozable.internal:\(p1),file=SVC_TOKEN_FILE",
                       "--secret", "TS_TOKEN,src=\(src)/ts,to=100.64.0.9:8080",
                       "--secret", "PLAIN_TOKEN,src=\(src)/plain,to=plain.doz.test:8080"]

    // MARK: S1–S4, S6, S7, then S9 (after a new daemon)
    put(net + "/sec.sh", helpers + """
    w() { while [ ! -e "go-$1" ]; do sleep 0.2; done; }
    printf '%s' "$SVC_TOKEN" > res/sec-var; printf '%s' "$SVC_TOKEN_FILE" > res/sec-filevar; cat "$SVC_TOKEN_FILE" > res/sec-file
    env > res/sec-env
    c s2 -m 10 -H "Authorization: Bearer $SVC_TOKEN" http://host.dozable.internal:\(p1)/s2
    c s3 -m 10 -H "Authorization: Bearer $SVC_TOKEN" http://host.dozable.internal:\(p2)/s3
    c s3m -m 10 -H "Authorization: Bearer $SVC_TOKEN" http://mac.dozable.internal:\(p1)/s3m
    c s4 -m 10 -H "Authorization: Bearer $SVC_TOKEN" http://allowed.doz.test/s4
    c s6 -m 10 -H "Authorization: Bearer $PLAIN_TOKEN" http://plain.doz.test:8080/s6
    c s7 -m 10 -H "Authorization: Bearer $TS_TOKEN" http://100.64.0.9:8080/s7
    c s4o -m 10 -H "Authorization: Bearer $SVC_TOKEN" -H "x-api-key: $SVC_TOKEN" http://host.dozable.internal:\(p1)/own
    echo done > res/SEC0
    w s9; c s9 -m 40 -H "Authorization: Bearer $SVC_TOKEN" http://host.dozable.internal:\(p1)/s9; echo done > res/SEC9
    sleep 600
    """)
    var r = run("sec", "sec.sh", secretFlags)
    check(r.code == 0 && r.err.contains("secret SVC_TOKEN → host.dozable.internal:\(p1) (fp \(CredentialFingerprint.of(value))"),
          "692 S1 a fenced session with --secret: its launch line names the destination and the fingerprint (\(r.code) \(r.err.suffix(240)))")
    check(done("SEC0"), "692 the secret probes ran")
    let placeholder = get(net + "/res/sec-var")
    check(placeholder.hasPrefix("doz_cred_") && placeholder != value, "692 S1 the variable holds a placeholder")
    check(get(net + "/res/sec-file") == placeholder && get(net + "/res/sec-filevar").hasSuffix("/etc/secrets/SVC_TOKEN"),
          "692 S1 FILEVAR names a file holding the same placeholder (\(get(net + "/res/sec-filevar")))")
    check(!get(net + "/res/sec-env").contains(value) && !get(net + "/res/sec-env").contains(tsValue), "692 S1 the session's environment has no secret")
    // The store, the daemon's log and every session folder: no value anywhere.
    var leaked: [String] = []
    for base in [store, home] {
        for f in (FileManager.default.enumerator(atPath: base)?.allObjects as? [String]) ?? [] {
            let p = base + "/" + f
            guard let a = try? FileManager.default.attributesOfItem(atPath: p), a[.type] as? FileAttributeType == .typeRegular,
                  (a[.size] as? Int ?? 0) < 8 << 20, let d = FileManager.default.contents(atPath: p) else { continue }
            let s = String(decoding: d, as: UTF8.self)
            if s.contains(value) || s.contains(tsValue) || s.contains(plainValue) { leaked.append(f) }
        }
    }
    check(leaked.isEmpty, "692 S1 the store, its log and the session folders hold no secret (\(leaked.prefix(5)))")
    check(code("s2").hasPrefix("200") && body("s2").contains("Authorization: Bearer \(value)\r\n") && !body("s2").contains(placeholder),
          "692 S2 plain HTTP to host.dozable.internal:\(p1): the service receives the real value (\(code("s2")))")
    check(code("s3").hasPrefix("403") && body("s3").contains("sent to host.dozable.internal:\(p2)"), "692 S3 the same to another open port: 403 (\(code("s3")) \(body("s3").prefix(160)))")
    check(code("s3m").hasPrefix("403"), "692 S3 …to the route's alias: 403 (\(code("s3m")))")
    check(code("s4").hasPrefix("403") && body("s4").contains("never sent over plain HTTP"), "692 S4 to a seam site on plain HTTP: 403 (\(code("s4")) \(body("s4").prefix(160)))")
    check(code("s6").hasPrefix("403") && body("s6").contains("never sent over plain HTTP to plain.doz.test:8080"),
          "692 S6 a secret for a non-Tailscale site, over plain HTTP: 403 (\(code("s6")))")
    check(code("s7").hasPrefix("200") && body("s7").contains("Authorization: Bearer \(tsValue)\r\n"), "692 S7 a Tailscale literal (through the seam): swapped (\(code("s7")))")
    check(code("s4o").hasPrefix("200") && body("s4o").contains("Authorization: Bearer \(value)") && body("s4o").contains("x-api-key: \(value)") == false,
          "692 S2 a placeholder in a second header is never answered with the secret beside it (\(code("s4o")))")
    // Shown: net show (text and --json), the capabilities.
    let rep = t.json(["net", "show", "@mac", "--session", "sec"], PermissionReport.self)
    check(rep?.secrets?.map(\.variable).sorted() == ["PLAIN_TOKEN", "SVC_TOKEN", "TS_TOKEN"]
          && rep?.secrets?.first { $0.variable == "SVC_TOKEN" }?.to == "host.dozable.internal:\(p1)"
          && rep?.secrets?.allSatisfy { $0.plainHTTP } == true, "692 doz net show @mac --json: secrets (where, never a value)")
    let shown = t.run(["net", "show", "@mac", "--session", "sec"]).out
    check(shown.contains("Secret SVC_TOKEN → host.dozable.internal:\(p1)") && !shown.contains(value), "692 doz net show @mac prints the secrets")
    check(rows().first { $0.name == "sec" }?.capabilities?.contains { $0.id == "secrets" && $0.sentence.contains("SVC_TOKEN holds a placeholder") } == true,
          "692 its capabilities say where each secret goes")
    check(ledgerOwners().filter { $0 == "mac.sec" }.count == 3, "692 the ledger names its three keychain items (\(ledgerOwners()))")

    // MARK: S9 a new daemon: the placeholder is honoured (by its hash) — under the memory keychain the new daemon has no
    // value, so the answer is the proxy's own 401 "no secret behind it now" (the unit test proves the keychain re-read).
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "692 S9 daemon stop")
    _ = t.run(["sessions", "send", "@mac", "sec", "--text", "x"], timeout: 30)          // starts a daemon, which adopts
    FileManager.default.createFile(atPath: net + "/go-s9", contents: nil)
    check(done("SEC9") && code("s9").hasPrefix("401") && body("s9").contains("no secret behind SVC_TOKEN's placeholder now"),
          "692 S9 after a new daemon (memory keychain): 401 no secret behind it now (\(code("s9")) \(body("s9").prefix(200)))")
    check(ledgerOwners().filter { $0 == "mac.sec" }.count == 3, "692 S9 the new daemon's sweep keeps a live session's items")
    // Its removal (end, then end again: forgotten) takes the items with it.
    t.run(["sessions", "end", "@mac", "sec", "--yes"], timeout: 60)
    t.run(["sessions", "end", "@mac", "sec", "--yes"], timeout: 60)
    started.remove("sec")
    check(!ledgerOwners().contains("mac.sec"), "692 S9 the session removed: its keychain items are deleted (\(ledgerOwners()))")

    // MARK: S5 network.placeholders_plain_http off + a restart → 403 with the message
    put(net + "/sec5.sh", helpers + """
    if [ -e res/S5A ]; then
      c s5b -m 10 -H "Authorization: Bearer $SVC_TOKEN" http://host.dozable.internal:\(p1)/s5b; echo done > res/S5B
    else
      c s5a -m 10 -H "Authorization: Bearer $SVC_TOKEN" http://host.dozable.internal:\(p1)/s5a; echo done > res/S5A
    fi
    sleep 600
    """)
    r = run("sec5", "sec5.sh", ["--host-port", String(p1), "--secret", "SVC_TOKEN,src=\(src)/token,to=host.dozable.internal:\(p1)"])
    check(r.code == 0 && done("S5A") && code("s5a").hasPrefix("200"), "692 S5 with the setting on: swapped (\(code("s5a")))")
    check(t.run(["config", "set", "network.placeholders_plain_http", "false"]).code == 0, "692 S5 doz config set network.placeholders_plain_http false")
    r = t.run(["sessions", "restart", "@mac", "sec5", "--yes"], timeout: 90)
    check(r.code == 0 && done("S5B") && code("s5b").hasPrefix("403") && body("s5b").contains("network.placeholders_plain_http is on; use https"),
          "692 S5 …off, after a restart (the secret kept): 403 with the message (\(r.code) \(code("s5b")) \(body("s5b").prefix(200)))")
    check(t.run(["config", "set", "network.placeholders_plain_http", "true"]).code == 0, "692 S5 the setting back on")
    t.run(["sessions", "end", "@mac", "sec5", "--yes"], timeout: 60)
    t.run(["sessions", "end", "@mac", "sec5", "--yes"], timeout: 60)
    started.remove("sec5")

    // MARK: S8 the refusals — nothing is started
    put(net + "/inside", value + "\n")
    chmod(net + "/inside", 0o600)
    for (what, args, fragment) in [
        ("-e for the secret's variable", ["--host-port", String(p1), "-e", "SVC_TOKEN=x", "--secret", "SVC_TOKEN,src=\(src)/token,to=host.dozable.internal:\(p1)"],
         "SVC_TOKEN carries a secret's placeholder — give it with --secret"),
        ("a world-readable file", ["--host-port", String(p1), "--secret", "SVC_TOKEN,src=\(src)/open,to=host.dozable.internal:\(p1)"], "chmod go-rwx"),
        ("a file inside its folder", ["--host-port", String(p1), "--secret", "SVC_TOKEN,src=\(net)/inside,to=host.dozable.internal:\(p1)"], "the session could read the secret itself"),
        ("a port not opened to it", ["--secret", "SVC_TOKEN,src=\(src)/token,to=host.dozable.internal:\(p1)"], "add --host-port \(p1)"),
        ("a site it cannot reach", ["--secret", "SVC_TOKEN,src=\(src)/token,to=other.doz.test:8080"], "add --permissions site:other.doz.test:8080"),
    ] {
        r = run("secbad", "sec.sh", args)
        check(r.code != 0 && r.err.contains(fragment) && !r.err.contains(value), "692 S8 refused: \(what) (\(r.err.suffix(200)))")
        if r.code == 0 { t.run(["sessions", "end", "@mac", "secbad", "--yes"], timeout: 60) }
    }
    r = t.run(["run", "@mac", "-d", "--unfenced", "--secret", "SVC_TOKEN,src=\(src)/token,to=host.dozable.internal:\(p1)", "--session", "secun",
               "--folder", net, "--", "/bin/sh", "-c", "true"])
    check(r.code != 0 && r.err.contains("an unfenced session has no proxy to hold a secret"), "692 S8 --unfenced --secret refused (\(r.err.prefix(160)))")
    check(!ledgerOwners().contains("mac.secbad"), "692 S8 a refused launch keeps no keychain item (\(ledgerOwners()))")
}
