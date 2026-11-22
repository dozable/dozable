import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, a document for every workspace (WS.07): `doz workspace doc`, black-box through the signed doz,
// its daemon and the chat server it runs; a scratch home stands for `~` (`DOZ_TEST_HOME`, this guarded run); no VM, no
// agent started.
//
//  D1. (X9, record-made) workspace new app --preset blank --brief x --folder ~/work/app --json, then doc app --json → exit 0,
//      kind Document, schema 1, document.lifetime present (standing), the brief under x-dozable, the folder main
//  D2. (X9, file-made, x-dozable) up -f ~/work/appf/appf.space.yaml --json with x-dozable: {lifetime: standing, brief: {text}}
//      and the folder's x-dozable main → exit 0 (its ~/work/appf found under the scratch home); show --brief reads the brief
//      held in the file; doc appf --json → kind Document, from space-file, document.lifetime standing
//  D3. (X7) a space with secrets: {api-key: {external: {keychain: doz-test-api-key}, to: api.example.com}} upped →
//      doc --json exit 0, the reference kept, nothing token-shaped
//  D4. (X7) doc --write ~/work/out.space.yaml → exit 0, a space file that reads back (space config), nothing token-shaped
//  D5. --write again → 4 already-exists, nothing written; --force → 0; into the store or ~/Library → 65 invalid-value
//  D6. doc nosuch → 2; doc with the daemon stopped → answered, none started; a file with no lifetime → doc prints runs
func cliWorkspaceDocRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: a document for every workspace — doz workspace doc")
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsd-home")
    try? fm.removeItem(at: home)
    for d in ["work/app", "work/appf", "work/sec", "work/plain"] { try? fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true) }
    let savedHome = h.env["DOZ_TEST_HOME"], savedBrief = h.env["DOZ_TEST_BRIEF_HOME"]
    defer {
        h.env["DOZ_TEST_HOME"] = savedHome
        h.env["DOZ_TEST_BRIEF_HOME"] = savedBrief
        try? fm.removeItem(at: home)
    }
    func object(_ r: CLIRun) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]) ?? [:] }
    func document(_ r: CLIRun) -> [String: Any] { (object(r)["document"] as? [String: Any]) ?? [:] }
    /// Nothing token-shaped: no chat token, no API key form, no fingerprint field, no long secret-looking run.
    func tokenFree(_ s: String) -> Bool {
        s.range(of: #"dzc_[A-Za-z0-9]|sk-[A-Za-z0-9]|gh[pousr]_[A-Za-z0-9]|"fingerprint"|CHAT_TOKEN|[A-Za-z0-9+_-]{40,}"#, options: .regularExpression) == nil
    }

    // The daemon again with the scratch home in its environment (`~` in a space file, and the recorded files' home).
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_HOME"] = home.path
    h.env["DOZ_TEST_BRIEF_HOME"] = nil
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "D0 chat on (\(r.code) \(r.err.prefix(160)))")

    // D1. a record-made workspace's document.
    r = h.run(["workspace", "new", "docapp", "--preset", "blank", "--brief", "x", "--folder", "~/work/app", "--json"], timeout: 60)
    check(r.code == 0, "D1 workspace new docapp (the locked row's app, named apart from the suite's other rows) --preset blank --brief x --folder ~/work/app --json: exit 0 (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    r = h.run(["workspace", "doc", "docapp", "--json"], timeout: 60)
    var o = object(r), d = document(r)
    check(r.code == 0 && o["kind"] as? String == "Document" && o["schema"] as? Int == 1 && o["from"] as? String == "record",
          "D1 doc docapp --json: exit 0, kind Document, schema 1, from record (\(r.code) \(r.out.prefix(300)))")
    check(d["lifetime"] as? String == "standing", "D1 …document.lifetime present: standing (\(d["lifetime"] ?? "nil"))")
    let x = d["x-dozable"] as? [String: Any]
    check(x?["lifetime"] as? String == "standing" && (x?["brief"] as? [String: Any])?["text"] as? String == "x", "D1 …x-dozable: the lifetime and the brief held (\(x ?? [:]))")
    let folders = (d["folders"] as? [String: [String: Any]]) ?? [:]
    let main = folders.values.first { ($0["x-dozable"] as? [String: Any])?["main"] as? Bool == true }
    check(main?["external"] as? String == WorkspaceStore.resolved(home.appendingPathComponent("work/app").path),
          "D1 …the folder, external and main: ~/work/app under the scratch home (\(folders))")
    r = h.run(["workspace", "doc", "docapp"], timeout: 60)
    check(r.code == 0 && r.out.contains("doz: space/3") && r.out.contains("x-dozable:") && r.out.contains("lifetime: standing"), "D1 …doc docapp as YAML (\(r.code))")

    // D2. a file-made workspace in the x-dozable form, `~` under the scratch home.
    let filePath = home.appendingPathComponent("work/appf/appf.space.yaml")
    try? """
    doz: space/3
    space: appf
    owner: ada
    x-dozable:
      lifetime: standing
      brief: { text: Fix the build }
    folders:
      app: { external: ~/work/appf, x-dozable: { main: true } }
    chat:
      rooms:
        appf: { main: true, members: [owner] }

    """.write(to: filePath, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", "~/work/appf/appf.space.yaml", "--json"], timeout: 120)
    check(r.code == 0, "D2 up -f ~/work/appf/appf.space.yaml --json (x-dozable lifetime, brief, main): exit 0, ~/work/appf found under the scratch home (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(300)))")
    r = h.run(["workspace", "show", "appf", "--brief", "--json"], timeout: 60)
    check(object(r)["briefText"] as? String == "Fix the build", "D2 …show --brief reads the brief held in the file (\(object(r)["briefText"] ?? "nil"))")
    let posted = h.run(["chat", "read", "appf"], timeout: 60).out
    check(posted.contains("Fix the build"), "D2 …up posted it in its room")
    r = h.run(["workspace", "doc", "appf", "--json"], timeout: 60)
    o = object(r); d = document(r)
    check(r.code == 0 && o["kind"] as? String == "Document" && o["from"] as? String == "space-file" && d["lifetime"] as? String == "standing",
          "D2 doc appf --json: kind Document, from space-file, document.lifetime standing (\(r.code) \(r.out.prefix(300)))")
    check(((d["folders"] as? [String: Any])?["app"] as? [String: Any]).flatMap { $0["x-dozable"] as? [String: Any] }?["main"] as? Bool == true,
          "D2 …the folder's x-dozable main kept")

    // D3. a space with a secret (a reference): doc keeps the reference and holds nothing token-shaped.
    try? """
    doz: space/3
    space: sec
    owner: ada
    x-dozable:
      lifetime: standing
      brief: { text: Use the API }
    folders:
      work: { external: ~/work/sec, x-dozable: { main: true } }
    secrets:
      api-key: { external: { keychain: doz-test-api-key }, to: api.example.com }
    chat:
      rooms:
        sec: { main: true, members: [owner] }

    """.write(to: home.appendingPathComponent("work/sec/sec.space.yaml"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", home.appendingPathComponent("work/sec/sec.space.yaml").path, "--json"], timeout: 120)
    check(r.code == 0, "D3 up the space with secrets: {api-key: {external: {keychain: doz-test-api-key}, to: api.example.com}} (\(r.code) \(r.err.prefix(300)))")
    r = h.run(["workspace", "doc", "sec", "--json"], timeout: 60)
    let secrets = document(r)["secrets"] as? [String: Any]
    check(r.code == 0 && ((secrets?["api-key"] as? [String: Any])?["external"] as? [String: Any])?["keychain"] as? String == "doz-test-api-key",
          "D3 doc sec --json: exit 0, the secret a reference (\(r.code) \(secrets ?? [:]))")
    check(tokenFree(r.out), "D3 …nothing token-shaped in it")

    // D4. --write: a space file that reads back, nothing token-shaped.
    let out = home.appendingPathComponent("work/out.space.yaml")
    r = h.run(["workspace", "doc", "sec", "--write", "~/work/out.space.yaml"], timeout: 60)
    let written = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    check(r.code == 0 && written.contains("doz: space/3") && written.contains("doz-test-api-key"), "D4 doc sec --write ~/work/out.space.yaml: exit 0, written (\(r.code) \(r.err.prefix(200)))")
    check(tokenFree(written), "D4 …nothing token-shaped in the file")
    r = h.run(["workspace", "config", out.path, "--json"], timeout: 60)
    check(r.code == 0, "D4 …it reads back as a valid space file (space config: \(r.code) \(r.err.prefix(300)))")
    r = h.run(["workspace", "doc", "docapp", "--write", home.appendingPathComponent("work/app.space.yaml").path], timeout: 60)
    check(r.code == 0 && h.run(["workspace", "config", home.appendingPathComponent("work/app.space.yaml").path]).code == 0,
          "D4 …a record-made workspace's document reads back as a valid space file too")

    // D5. the refusals.
    r = h.run(["workspace", "doc", "sec", "--write", out.path, "--json"], timeout: 60)
    let e = object(r)["error"] as? [String: Any]
    check(r.code == 4 && e?["code"] as? String == "already-exists" && ((try? String(contentsOf: out, encoding: .utf8)) ?? "") == written,
          "D5 --write over an existing file: 4 already-exists, nothing written (\(r.code) \(r.out.prefix(200)))")
    r = h.run(["workspace", "doc", "docapp", "--write", out.path, "--force"], timeout: 60)
    check(r.code == 0 && ((try? String(contentsOf: out, encoding: .utf8)) ?? "").contains("space: docapp"), "D5 …--force replaces it (\(r.code))")
    r = h.run(["workspace", "doc", "docapp", "--write", store.root.appendingPathComponent("x.space.yaml").path, "--json"], timeout: 60)
    check(r.code == 65 && (object(r)["error"] as? [String: Any])?["code"] as? String == "invalid-value" && !fm.fileExists(atPath: store.root.appendingPathComponent("x.space.yaml").path),
          "D5 --write into Dozable's store: 65 invalid-value, nothing written (\(r.code))")
    try? fm.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
    r = h.run(["workspace", "doc", "docapp", "--write", "~/Library/x.space.yaml"], timeout: 60)
    check(r.code == 65 && !fm.fileExists(atPath: home.appendingPathComponent("Library/x.space.yaml").path), "D5 --write into ~/Library: 65 (\(r.code))")

    // D6. not found; no daemon; a file with no lifetime is read as runs.
    r = h.run(["workspace", "doc", "nosuch", "--json"], timeout: 60)
    check(r.code == 2 && (object(r)["error"] as? [String: Any])?["code"] as? String == "not-found", "D6 doc nosuch: exit 2 not-found (\(r.code))")
    try? """
    doz: space/3
    space: plainf
    owner: ada
    brief: BRIEF.md
    folders:
      work: { external: ~/work/plain }
    chat:
      rooms:
        plainf: { main: true, members: [owner] }

    """.write(to: home.appendingPathComponent("work/plain/plainf.space.yaml"), atomically: true, encoding: .utf8)
    try? "Plain.\n".write(to: home.appendingPathComponent("work/plain/BRIEF.md"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", home.appendingPathComponent("work/plain/plainf.space.yaml").path, "--json"], timeout: 120)
    check(r.code == 0, "D6 up a space file with no lifetime (\(r.code) \(r.err.prefix(300)))")
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    r = h.run(["workspace", "doc", "plainf", "--json"], timeout: 60)
    d = document(r)
    check(r.code == 0 && d["lifetime"] as? String == "runs" && (d["x-dozable"] as? [String: Any])?["lifetime"] as? String == "runs",
          "D6 with the daemon stopped: doc plainf --json answers, lifetime runs written (\(r.code) \(r.out.prefix(300)))")
    r = h.run(["workspace", "doc", "docapp", "--json"], timeout: 60)
    check(r.code == 0 && document(r)["lifetime"] as? String == "standing", "D6 …and a record workspace's (\(r.code))")
    check(!h.hostRunning, "D6 …and no daemon started")
}
