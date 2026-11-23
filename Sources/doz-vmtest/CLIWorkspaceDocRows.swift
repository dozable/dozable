import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, a document for every workspace (WS.07): `doz workspace doc`, black-box through the signed doz,
// its daemon and the chat server it runs; a scratch home stands for `~` (`DOZ_TEST_HOME`, this guarded run); no VM, no
// agent started.
//
//  D1. (X9, record-made) workspace new app --preset blank --brief x --folder ~/work/app --json, then doc app --json → exit 0,
//      kind Document, schema 1, document.doz space/3.1, document.x-dozable.lifetime present (standing) and no top-level
//      document.lifetime (not a 3.1 key), the brief held first-class, the folder main
//  D2. (X9, file-made, x-dozable) up -f ~/work/appf/appf.space.yaml --json with x-dozable: {lifetime: standing, brief: {text}}
//      and the folder's x-dozable main → exit 0 (its ~/work/appf found under the scratch home), each x-dozable use a note in
//      --json's notes; show --brief reads the brief held in the file; doc appf --json → kind Document, from space-file,
//      x-dozable.lifetime standing, the 3.1 form (doz space/3.1, the folder's main first-class)
//  D3. (X7) a space with secrets: {api-key: {external: {keychain: doz-test-api-key}, to: api.example.com}} upped →
//      doc --json exit 0, the reference kept, nothing token-shaped
//  D4. (X7) doc --write ~/work/out.space.yaml → exit 0, a space file that reads back (space config), nothing token-shaped
//  D5. --write again → 4 already-exists, nothing written; --force → 0; into the store or ~/Library → 65 invalid-value
//  D6. doc nosuch → 2; doc with the daemon stopped → answered, none started; a file with no lifetime → doc says runs;
//      a plain space/3 file's up has no x-dozable note
//  D7. (X9 first-class) a doz: space/3.1 file with about: {title}, brief: {text: Fix the build}, a folder main: true and
//      x-dozable: {lifetime: standing}, up -f → doc app31 --json exit 0, kind Document, the lifetime standing under
//      x-dozable, document.doz space/3.1
//  D8. a 3.1 key under doz: space/3 → up -f exits 65, the problem names the fix (change the version line to doz: space/3.1),
//      nothing made; a top-level lifetime: in a space/3.1 file → 65 naming lifetime; a top-level title: → a note naming
//      about.title
//  D9. doc app31 --write → a space/3.1 file that plan -f accepts (exit 0) against that workspace; the plan's run steps
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
    let x = (d["x-dozable"] as? [String: Any]) ?? [:]
    check(x["lifetime"] as? String == "standing" && d["lifetime"] == nil,
          "D1 …document.x-dozable.lifetime standing, no top-level document.lifetime (\(x["lifetime"] ?? "nil") \(d["lifetime"] ?? "nil"))")
    check(d["doz"] as? String == "space/3.1" && (d["brief"] as? [String: Any])?["text"] as? String == "x" && x["brief"] == nil,
          "D1 …space/3.1: the brief held first-class, not under x-dozable (\(d["doz"] ?? "nil") \(d["brief"] ?? "nil"))")
    let folders = (d["folders"] as? [String: [String: Any]]) ?? [:]
    let main = folders.values.first { $0["main"] as? Bool == true }
    check(main?["external"] as? String == WorkspaceStore.resolved(home.appendingPathComponent("work/app").path),
          "D1 …the folder, external and main: ~/work/app under the scratch home (\(folders))")
    r = h.run(["workspace", "doc", "docapp"], timeout: 60)
    check(r.code == 0 && r.out.contains("\ndoz: space/3.1\n") && r.out.contains("\nx-dozable:\n  lifetime: standing\n") && !r.out.contains("\nlifetime:"),
          "D1 …doc docapp as YAML: doz: space/3.1, the lifetime under x-dozable (\(r.code))")

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
    let upNotes = (object(r)["notes"] as? [String]) ?? []
    check(upNotes.contains("x-dozable.brief is read for this release only: write brief: at the top level, with the version line doz: space/3.1")
          && upNotes.contains { $0.hasPrefix("folder \"app\": x-dozable.main is read for this release only") }
          && !upNotes.contains { $0.contains("lifetime") },
          "D2 …--json's notes name each x-dozable use's 3.1 key (\(upNotes))")
    r = h.run(["workspace", "show", "appf", "--brief", "--json"], timeout: 60)
    check(object(r)["briefText"] as? String == "Fix the build", "D2 …show --brief reads the brief held in the file (\(object(r)["briefText"] ?? "nil"))")
    let posted = h.run(["chat", "read", "appf"], timeout: 60).out
    check(posted.contains("Fix the build"), "D2 …up posted it in its room")
    r = h.run(["workspace", "doc", "appf", "--json"], timeout: 60)
    o = object(r); d = document(r)
    check(r.code == 0 && o["kind"] as? String == "Document" && o["from"] as? String == "space-file"
          && (d["x-dozable"] as? [String: Any])?["lifetime"] as? String == "standing" && d["lifetime"] == nil,
          "D2 doc appf --json: kind Document, from space-file, x-dozable.lifetime standing (\(r.code) \(r.out.prefix(300)))")
    check(((d["folders"] as? [String: Any])?["app"] as? [String: Any])?["main"] as? Bool == true && d["doz"] as? String == "space/3.1"
          && ((d["x-dozable"] as? [String: Any]) ?? [:]).keys.sorted() == ["lifetime"],
          "D2 …the document is the 3.1 form: the folder's main first-class, doz space/3.1 (\(d["folders"] ?? "nil"))")

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
    check(!r.out.contains("x-dozable"), "D6 …a plain space/3 file: no x-dozable note")
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    r = h.run(["workspace", "doc", "plainf", "--json"], timeout: 60)
    d = document(r)
    check(r.code == 0 && (d["x-dozable"] as? [String: Any])?["lifetime"] as? String == "runs" && d["lifetime"] == nil && d["doz"] as? String == "space/3.1",
          "D6 with the daemon stopped: doc plainf --json answers, lifetime runs written (\(r.code) \(r.out.prefix(300)))")
    r = h.run(["workspace", "doc", "docapp", "--json"], timeout: 60)
    check(r.code == 0 && (document(r)["x-dozable"] as? [String: Any])?["lifetime"] as? String == "standing", "D6 …and a record workspace's (\(r.code))")
    check(!h.hostRunning, "D6 …and no daemon started")

    // D7. (X9 first-class) a space/3.1 file: its keys first-class.
    try? fm.createDirectory(at: home.appendingPathComponent("work/app31"), withIntermediateDirectories: true)
    try? """
    doz: space/3.1
    space: app31
    about: { title: App }
    owner: ada
    brief: { text: Fix the build }
    x-dozable: { lifetime: standing }
    folders:
      app: { external: ~/work/app31, main: true }
    chat:
      rooms:
        app31: { main: true, members: [owner] }

    """.write(to: home.appendingPathComponent("work/app31/app31.space.yaml"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", "~/work/app31/app31.space.yaml", "--json"], timeout: 120)
    check(r.code == 0, "D7 up -f ~/work/app31/app31.space.yaml --json (doz: space/3.1, about: {title}, brief: {text}, main: true, x-dozable: {lifetime: standing}): exit 0 (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(300)))")
    check(!r.out.contains("read for this release only"), "D7 …no x-dozable note")
    r = h.run(["workspace", "doc", "app31", "--json"], timeout: 60)
    o = object(r); d = document(r)
    check(r.code == 0 && o["kind"] as? String == "Document" && (d["x-dozable"] as? [String: Any])?["lifetime"] as? String == "standing"
          && d["lifetime"] == nil && d["doz"] as? String == "space/3.1" && (d["about"] as? [String: Any])?["title"] as? String == "App",
          "D7 doc app31 --json: exit 0, kind Document, x-dozable.lifetime standing, document.doz space/3.1, about.title (\(r.code) \(r.out.prefix(300)))")
    check(((d["folders"] as? [String: Any])?["app"] as? [String: Any])?["main"] as? Bool == true && (d["brief"] as? [String: Any])?["text"] as? String == "Fix the build",
          "D7 …the folder main, the brief held")
    r = h.run(["workspace", "show", "app31", "--brief", "--json"], timeout: 60)
    check(object(r)["briefText"] as? String == "Fix the build", "D7 …show --brief reads it (\(object(r)["briefText"] ?? "nil"))")

    // D8. a 3.1 key under doz: space/3 → 65 naming the fix; a top-level lifetime in a 3.1 file → 65; a top-level title → a note.
    try? fm.createDirectory(at: home.appendingPathComponent("work/old31"), withIntermediateDirectories: true)
    try? "doz: space/3\nspace: old31\nowner: ada\nbrief: { text: Fix the build }\nnetwork: standard\n"
        .write(to: home.appendingPathComponent("work/old31/old31.space.yaml"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", "~/work/old31/old31.space.yaml", "--json"], timeout: 120)
    let fixes = ((object(r)["problems"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
    check(r.code == 65 && fixes.contains("\"network\" is a space/3.1 key: change the version line to doz: space/3.1")
          && fixes.contains("\"brief\" is a space/3.1 key: change the version line to doz: space/3.1"),
          "D8 up -f a space/3 file with network: and brief: {text}: 65, each naming the fix (\(r.code) \(fixes) \(r.out.prefix(400)))")
    r = h.run(["workspace", "up", "-f", "~/work/old31/old31.space.yaml"], timeout: 120)
    check(r.code == 65 && r.err.contains("old31.space.yaml:5") && r.err.contains("change the version line to doz: space/3.1"),
          "D8 …as text: file:line and the fix (\(r.code) \(r.err.prefix(400)))")
    check(h.run(["workspace", "show", "old31", "--json"], timeout: 60).code == 2, "D8 …nothing made")
    try? "doz: space/3.1\nspace: old31\nowner: ada\nbrief: { text: Fix the build }\nlifetime: standing\n"
        .write(to: home.appendingPathComponent("work/old31/old31.space.yaml"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", "~/work/old31/old31.space.yaml"], timeout: 120)
    check(r.code == 65 && r.err.contains("\"lifetime\" is not a space/3.1 key") && r.err.contains("old31.space.yaml:5") && r.err.contains("x-dozable: { lifetime: standing }"),
          "D8 a top-level lifetime: in a space/3.1 file: 65, file:line, the fix (\(r.code) \(r.err.prefix(400)))")
    check(h.run(["workspace", "show", "old31", "--json"], timeout: 60).code == 2, "D8 …nothing made")
    try? "doz: space/3.1\nspace: old31\ntitle: Old\nowner: ada\nbrief: { text: Fix the build }\n"
        .write(to: home.appendingPathComponent("work/old31/old31.space.yaml"), atomically: true, encoding: .utf8)
    r = h.run(["workspace", "plan", "-f", "~/work/old31/old31.space.yaml", "--json"], timeout: 120)
    let titleNotes = (object(r)["notes"] as? [String]) ?? []
    check(r.code == 0 && titleNotes.contains { $0.contains("about.title") }, "D8 a top-level title: in a space/3.1 file: plan exit 0, a note naming about.title (\(r.code) \(titleNotes))")

    // D9. doc --write writes 3.1, which plan -f accepts against that workspace.
    let out31 = home.appendingPathComponent("work/app31/written.space.yaml")
    r = h.run(["workspace", "doc", "app31", "--write", out31.path], timeout: 60)
    let w31 = (try? String(contentsOf: out31, encoding: .utf8)) ?? ""
    check(r.code == 0 && w31.contains("\ndoz: space/3.1\n") && w31.contains("\nx-dozable:\n  lifetime: standing\n") && !w31.contains("\nlifetime:"),
          "D9 doc app31 --write: a space/3.1 file, its lifetime under x-dozable (\(r.code) \(w31.prefix(300)))")
    r = h.run(["workspace", "config", out31.path, "--json"], timeout: 60)
    check(r.code == 0, "D9 …it validates as 3.1 (config: \(r.code) \(r.err.prefix(300)))")
    r = h.run(["workspace", "plan", "-f", out31.path, "--json"], timeout: 120)
    let steps = (object(r)["steps"] as? [[String: Any]]) ?? []
    let runs = steps.filter { $0["action"] as? String == "run" && $0["kind"] as? String != "check" }
    check(r.code == 0, "D9 …plan -f it against app31: exit 0 (\(r.code) \(r.err.prefix(300)))")
    print("note: D9 the written file's plan against app31: \(runs.count) run step(s) of \(steps.count): \(runs.map { "\($0["kind"] ?? "")/\($0["subject"] ?? "")" })")
}
