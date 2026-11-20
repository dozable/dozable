import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, a space file acted on (after the lifecycle rows, in the same scratch store; chat on with the
// human ada). The real doz, a scratch fence home, and a FAKE claude first on the sessions' PATH: in a fenced session it
// writes `memory/notes.md` in its agent folder (one line more each start), echoes its argv into `argv.txt` there, says it is
// records the conversation it holds (as Claude Code does), says it is up in its room with dozchat, then sleeps. Never the
// real claude.
//
//  S2. up of a space with an unfenced agent and no terminal: exit 5, nothing made
//  S3/S5. up --yes: a step fails (its session's name taken) → exit 1, the rest not run, the run open; freed, up again
//      makes only what is missing; the record's space reference, the requests recorded, grants.json byte-identical; no
//      chat token in ps or any --json
//  S4. a third up makes nothing
//  S6. the brief: a stale --if-brief refused; an edit writes BRIEF.md (the store's copy stays empty); the next up keeps it
//  S7. down --yes: the archive written; the run-lifetime agent's session record gone and it is out of chat; the run room
//      gone with a tombstone; the persisted room closed (a post refused); the scratch folder removed; the kept memory in
//      the store
//  S9. up #2: the persisted room keeps its id; the persisted fenced agent's memory seeded back, its conversation resumed
//  S10. down --purge --yes: the persisted room gone (archived first), the kept memory gone, the kept folder still on disk
//  S11. a clean room (archive: off): down --dry-run names what goes with no copy
//  S13. a session whose name only starts like an agent's survives down
//  S14. --json: up and down answer SpaceActed
func cliSpaceActRows(_ h: CLIHarness, root: URL, store: DozableStore) {
    print("cli: space files — up, down, --purge")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let pid = getpid()
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-sp-home")
    let dir = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-sp-files")
    for d in [home, dir] { try? fm.removeItem(at: d); try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    var extra: [String] = []
    defer {
        for s in extra + ["sa-w1", "sa-w2", "sa-w3"] { h.run(["sessions", "end", "@mac", s, "--yes"]); h.run(["sessions", "end", "@mac", s, "--yes"]) }
        for d in [home, dir] { try? fm.removeItem(at: d) }
    }
    let bin = home.appendingPathComponent(".local/bin")
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let fake = """
    #!/bin/sh
    start=""; res=""; prev=""
    for a in "$@"; do
      case "$prev" in --resume|-r) res="$a" ;; esac
      case "$a" in "Read "*" and do what it says.") start="${a#Read }"; start="${start% and do what it says.}" ;; esac
      prev="$a"
    done
    if [ -n "$CLAUDE_CONFIG_DIR" ]; then
      printf '%s\\n' "$@" > "$CLAUDE_CONFIG_DIR/argv.txt"
      # The conversation it holds — a new one, or the one it was resumed with — as Claude Code records it.
      id="${res:-$(/usr/bin/uuidgen | tr 'A-Z' 'a-z')}"
      mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
      printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\\n' "$$" "$id" "$(pwd -P)" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
      folder="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
      mkdir -p "$folder"; [ -f "$folder/$id.jsonl" ] || echo '{}' > "$folder/$id.jsonl"
      m="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')/memory"
      mkdir -p "$m"; echo "a start" >> "$m/notes.md"
    fi
    [ -n "$start" ] || exec sleep 600
    first=$(head -n 1 "$start")
    room=$(sed -n 's/^Your room in chat: //p' "$start")
    bot=$(printf '%s' "$first" | sed -n 's/^You are \\([^,]*\\),.*/\\1/p')
    dozchat send "$room" "$bot is up: $first" > /dev/null 2>&1
    exec sleep 600

    """
    try? fake.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(bin.appendingPathComponent("claude").path, 0o755)
    let dozchat = (h.binary as NSString).deletingLastPathComponent + "/dozchat-mac"
    try? fm.createSymbolicLink(atPath: bin.appendingPathComponent("dozchat").path, withDestinationPath: dozchat)
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func sha(_ p: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: p))).map(WorkspaceStore.sha256) ?? "none" }
    func records() -> [String: MacSessionRecord] { MacSessions(store: store, readOnly: true).records().sessions }
    func psText() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "command="]
        let o = Pipe()
        p.standardOutput = o
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
    func acted(_ r: CLIRun) -> SpaceActed? { try? HostWire.decoder.decode(SpaceActed.self, from: r.outData) }
    func agentDir(_ s: String) -> String? { records()[s]?.fence.map { $0.sessionFolder + "/agent" } }

    // The daemon again with this file's seams: its fence home and PATH, the brief's home.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    h.env["DOZ_TEST_BRIEF_HOME"] = "/tmp"
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "S chat on again (\(r.code) \(r.err.prefix(120)))")
    try? "Make the thing.\n".write(to: dir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)

    // S2. unfenced, no terminal
    let unf = dir.appendingPathComponent("su.space.yaml")
    try? "doz: space/3\nspace: su\nbrief: BRIEF.md\nowner: ada\nagents:\n  u1: { kind: claude-code, isolation: unfenced, prompt: hi }\nchat:\n  rooms:\n    su: { members: [owner, u1] }\n"
        .write(to: unf, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", unf.path, "--yes"], timeout: 120)
    check(r.code == 5 && r.err.contains("u1") && !ws.exists("su"), "S2 an unfenced agent and no terminal: exit 5, nothing made (\(r.code) \(r.err.prefix(200)))")

    // S3/S5. up, a step failing, then up again
    let file = dir.appendingPathComponent("sa.space.yaml")
    try? """
    doz: space/3
    space: sa
    brief: BRIEF.md
    owner: ada
    folders:
      scratch: {}
      data: {}
    persist:
      keep-data: { folder: data }
      team: { room: sa }
      mem: { agent: w1 }
    agents:
      w1: { kind: claude-code, isolation: fenced, prompt: remember things }
      w2:
        kind: claude-code
        isolation: fenced
        prompt: list the files
        transcripts: discard
        requests: { grants: [net.allow], reason: fetch the docs }
      w3: { kind: claude-code, isolation: fenced, prompt: three }
    chat:
      rooms:
        sa: { main: true, members: [owner, w1, w2, w3] }
        run: { members: [owner] }

    """.write(to: file, atomically: true, encoding: .utf8)
    let grants = WorkspaceStore.resolved(store.root.path) + "/grants/grants.json"
    let grantsBefore = sha(grants)
    // w3's place is taken: its add fails.
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "sa-w3", "--", "/bin/sh", "-c", "exec sleep 600"], timeout: 60)
    r = h.run(["workspace", "up", "-f", file.path, "--yes", "--json"], timeout: 240)
    let a1 = acted(r)
    check(r.code == 1 && a1?.ok == false && a1?.results.first { $0.subject == "agent w3" }?.status == "failed",
          "S5 up: w3's add fails, exit 1 (\(r.code) \(r.err.prefix(200)) \(a1?.results.map { "\($0.subject) \($0.status)" }.joined(separator: ", ") ?? r.out.prefix(300).description))")
    check(ws.exists("sa") && (try? ws.read("sa"))??.openRun != nil, "S5 …the run stays open")
    h.run(["sessions", "end", "@mac", "sa-w3", "--yes"]); h.run(["sessions", "end", "@mac", "sa-w3", "--yes"])
    r = h.run(["workspace", "up", "-f", file.path, "--yes", "--json"], timeout: 240)
    let a2 = acted(r)
    // (the requests step came after the failure: it runs now)
    check(r.code == 0 && a2?.results.filter { $0.status == "done" }.map(\.subject) == ["agent w3", "requests"],
          "S5 up again makes only what is missing (\(r.code) \(a2?.results.filter { $0.status == "done" }.map(\.subject) ?? []) \(r.err.prefix(200)))")
    let rec = (try? ws.read("sa")) ?? nil
    let ref = rec.flatMap { SpaceRecordRef.of($0) }
    check(ref?.file == "sa.space.yaml" && ref?.owned?.agents["w1"] == "persisted" && fm.fileExists(atPath: ws.folder("sa") + "/space.json"),
          "S3 the record keeps the space's reference and space.json")
    check(rec?.permissions?.requests.count == 1 && (rec?.permissions?.grants ?? []).isEmpty, "S3 …the request recorded, none granted")
    check(sha(grants) == grantsBefore, "S3 …grants.json byte-identical")
    check(!psText().contains("dzc_") && !r.out.contains("dzc_"), "S3 …no chat token in ps or the --json")
    check(h.waitFor(30) { ["sa-w1", "sa-w2", "sa-w3"].allSatisfy { s in h.sessions("@mac").contains { $0.name == s && !$0.ended } } },
          "S3 …the three agents run (fenced, the FAKE claude)")

    // S4. nothing left to make
    r = h.run(["workspace", "up", "-f", file.path, "--yes", "--json"], timeout: 120)
    check(r.code == 0 && acted(r)?.results.allSatisfy { $0.status == "skipped" } == true, "S4 a third up makes nothing (\(r.code))")

    // S6. the brief is the file
    let briefPath = dir.appendingPathComponent("BRIEF.md").path
    let edit = dir.appendingPathComponent("edit.md")
    try? "Make the better thing.\n".write(to: edit, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "edit", "sa", "--prompt-file", edit.path, "--if-brief", String(repeating: "0", count: 64)], timeout: 60)
    check(r.code == 3 && text(briefPath) == "Make the thing.\n", "S6 a stale --if-brief: refused, BRIEF.md unchanged (\(r.code))")
    r = h.run(["workspace", "edit", "sa", "--prompt-file", edit.path], timeout: 60)
    check(r.code == 0 && text(briefPath) == "Make the better thing.\n" && text(ws.folder("sa") + "/brief.md") == "",
          "S6 an edit writes BRIEF.md; the store's copy stays empty (\(r.code) \(r.err.prefix(160)))")
    let shown = h.run(["workspace", "show", "sa", "--space"])
    check(shown.out.contains("Defined by sa.space.yaml") && shown.out.contains("up"), "S6 show --space: Defined by sa.space.yaml, up")
    r = h.run(["workspace", "up", "-f", file.path, "--yes"], timeout: 120)
    check(r.code == 0 && text(briefPath) == "Make the better thing.\n", "S6 …the next up keeps it (\(r.code))")

    // S13. a similarly named session
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "sa-w2x", "--", "/bin/sh", "-c", "exec sleep 600"], timeout: 60)
    extra.append("sa-w2x")

    // S7. down
    let scratch = ref?.scratch?.first?.path ?? "/nonexistent"
    try? "notes\n".write(toFile: scratch + "/n.txt", atomically: true, encoding: .utf8)
    let dry = h.run(["workspace", "down", "sa", "--dry-run"], timeout: 60)
    check(dry.code == 0 && dry.out.contains("archived") && !dry.out.contains("Deleted with no copy"), "S7 down --dry-run: archived first, nothing with no copy")
    let roomID = (try? ChatRoomIndex.load(ChatPaths(store: store)))?.rooms["sa"]?.id
    r = h.run(["workspace", "down", "sa", "--yes", "--json"], timeout: 300)
    let d1 = acted(r)
    check(r.code == 0 && d1?.ok == true, "S7 down --yes (\(r.code) \(r.err.prefix(200)) \(d1?.results.filter { $0.status != "done" }.map { "\($0.subject) \($0.status) \($0.text)" }.joined(separator: "; ") ?? ""))")
    let runs = h.json(["workspace", "runs", "sa"], WorkspaceRunsListing.self)
    check(runs?.runs.first?.archiveStatus == "written", "S7 …the run's archive written")
    check(records()["sa-w2"] == nil && !h.run(["chat", "who"]).out.contains("w2 "), "S7 …w2 (this run only): no session record, out of chat")
    let idx = try? ChatRoomIndex.load(ChatPaths(store: store))
    check(idx?.tombstone("sa-run") != nil && !(h.run(["chat", "rooms"]).out.contains("sa-run")), "S7 …the run room gone, a tombstone kept")
    let post = h.run(["chat", "send", "sa", "after the run"])
    check(post.code != 0, "S7 …the persisted room closed: a post refused (\(post.code))")
    check(!fm.fileExists(atPath: scratch), "S7 …the scratch folder removed")
    check(fm.fileExists(atPath: WorkspaceStore.resolved(ws.folder("sa")) + "/memory/w1/memory.json"), "S7 …w1's memory kept in the store")
    check(h.sessions("@mac").contains { $0.name == "sa-w2x" }, "S13 a session named sa-w2x survives down")

    // S9. up #2
    r = h.run(["workspace", "up", "-f", file.path, "--yes"], timeout: 240)
    check(r.code == 0, "S9 up again (\(r.code) \(r.err.prefix(200)))")
    check((try? ChatRoomIndex.load(ChatPaths(store: store)))?.rooms["sa"]?.id == roomID, "S9 …the persisted room keeps its id")
    let w1 = agentDir("sa-w1") ?? "/nonexistent"
    check(h.waitFor(30) { text(w1 + "/argv.txt").contains("--resume") || text(w1 + "/argv.txt").contains("--continue") },
          "S9 …w1 resumes its conversation (\(text(w1 + "/argv.txt").replacingOccurrences(of: "\n", with: " ").prefix(200)))")
    let notes = (fm.enumerator(atPath: w1 + "/projects")?.allObjects as? [String] ?? []).filter { $0.hasSuffix("memory/notes.md") }
    check(notes.contains { text(w1 + "/projects/" + $0).components(separatedBy: "a start").count - 1 >= 2 }, "S9 …its memory was seeded back (two starts in notes.md)")
    let w2 = agentDir("sa-w2") ?? "/nonexistent"
    let w2notes = (fm.enumerator(atPath: w2 + "/projects")?.allObjects as? [String] ?? []).filter { $0.hasSuffix("memory/notes.md") }
    check(w2notes.allSatisfy { text(w2 + "/projects/" + $0) == "a start\n" }, "S9 …w2 (not persisted) starts with none of it")

    // S10. --purge
    let kept = ref?.persistedPaths?.first ?? "/nonexistent"
    try? "data\n".write(toFile: kept + "/d.txt", atomically: true, encoding: .utf8)
    r = h.run(["workspace", "down", "sa", "--purge", "--yes", "--json"], timeout: 300)
    check(r.code == 0 && acted(r)?.verb == "purge", "S10 down --purge --yes (\(r.code) \(r.err.prefix(200)))")
    check((try? ChatRoomIndex.load(ChatPaths(store: store)))?.tombstone("sa") != nil, "S10 …the persisted room gone, a tombstone kept")
    check(!fm.fileExists(atPath: WorkspaceStore.resolved(ws.folder("sa")) + "/memory/w1"), "S10 …the kept memory gone")
    check(text(kept + "/d.txt") == "data\n" && !(((try? ws.read("sa")) ?? nil)?.folders.contains { $0.path == kept } ?? true),
          "S10 …the kept folder released: off the record, still on disk")

    // S11. a clean room
    let clean = dir.appendingPathComponent("sc.space.yaml")
    try? "doz: space/3\nspace: sc\nbrief: BRIEF.md\nowner: ada\narchive: off\nfolders:\n  scratch: {}\nchat:\n  rooms:\n    sc: { members: [owner] }\n"
        .write(to: clean, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", clean.path, "--yes"], timeout: 120)
    let cdry = h.run(["workspace", "down", "sc", "--dry-run"], timeout: 60)
    check(r.code == 0 && cdry.out.contains("Deleted with no copy (archive: off)"), "S11 a clean room: down --dry-run names what goes with no copy (\(cdry.out.prefix(300)))")
    r = h.run(["workspace", "down", "sc", "--yes"], timeout: 120)
    check(r.code == 0 && (try? ChatRoomIndex.load(ChatPaths(store: store)))?.tombstone("sc")?.archive == "", "S11 …down removes it with no copy, said (\(r.code))")
    check(acted(h.run(["workspace", "down", "sc", "--dry-run", "--json"])) == nil, "S14 down --dry-run --json is the plan (not an answer)")
}
