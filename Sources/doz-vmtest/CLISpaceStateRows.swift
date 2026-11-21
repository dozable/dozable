import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, a space's state, its file and its frames (after the space-file rows, in the same scratch store;
// chat on with the human ada). The real doz, a scratch fence home, and a FAKE claude first on the sessions' PATH: it says it
// is up in its room, reports `working` (OSC 7501), and once a `block` file appears in its agent folder reports a permission
// prompt with a message (and `working` again once an `unblock` file appears). Never the real claude.
//
//  F1. up; doz workspace state --json: the facts known, one item per thing the file declares, a sha; the worker working
//  F1b. ls --json: the row's space (the file, up); none on a workspace made without one (F5: not up after down)
//  F1c. ls --json: each row's lastAt is its log's last line (workspace log --json's newest)
//  F2. the frames of the open run: written while it runs (doz workspace runs --frames)
//  F3. a permission prompt: the agent waiting, attention `permission` (the program's message for this Mac's owner); no frame
//      holds the message
//  D14. an open ask in the space's room: workspace state --json has its item with the question and canAnswer; a frame
//      written after it has neither (test-cli-chat's D rows, here where a space runs)
//  F4. show --space --json: the file's text and sha256; edit --space-file with a stale --if-match: exit 3, nothing written;
//      with the current one: written, never applied (the record's plan unchanged), logged as space-saved
//  F5. down: the final frame, the archive holds frames/ and verifies, the run's folder of frames gone
//  F6. with the daemon stopped: state (every state not known), show --space and runs --frames answer; none is started
func cliSpaceStateRows(_ h: CLIHarness, root: URL, store: DozableStore) {
    print("cli: a space's state, its file and its frames")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let pid = getpid()
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-sf-home")
    let dir = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-sf-files")
    for d in [home, dir] { try? fm.removeItem(at: d); try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    defer {
        h.run(["sessions", "end", "@mac", "sf-w1", "--yes"]); h.run(["sessions", "end", "@mac", "sf-w1", "--yes"])
        for d in [home, dir] { try? fm.removeItem(at: d) }
    }
    let bin = home.appendingPathComponent(".local/bin")
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let fake = #"""
    #!/bin/sh
    start=""
    for a in "$@"; do
      case "$a" in "Read "*" and do what it says.") start="${a#Read }"; start="${start% and do what it says.}" ;; esac
    done
    [ -n "$start" ] || exec sleep 600
    first=$(head -n 1 "$start")
    room=$(sed -n 's/^Your room in chat: //p' "$start")
    bot=$(printf '%s' "$first" | sed -n 's/^You are \([^,]*\),.*/\1/p')
    dozchat send "$room" "$bot is up" > /dev/null 2>&1
    printf '\033]7501;?\033\\'
    sleep 1
    printf '\033]7501;state=working:app=fake\033\\'
    while [ ! -e "$CLAUDE_CONFIG_DIR/block" ]; do sleep 0.3; done
    printf '\033]7501;state=blocked:kind=permission:app=fake:msg=%s\033\\' "$(printf 'Allow FAKE-SECRET-WORDS?' | base64)"
    while [ ! -e "$CLAUDE_CONFIG_DIR/unblock" ]; do sleep 0.3; done
    printf '\033]7501;state=working:app=fake\033\\'
    exec sleep 600

    """#
    try? fake.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(bin.appendingPathComponent("claude").path, 0o755)
    let dozchat = (h.binary as NSString).deletingLastPathComponent + "/dozchat-mac"
    try? fm.createSymbolicLink(atPath: bin.appendingPathComponent("dozchat").path, withDestinationPath: dozchat)
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func state() -> SpaceState? { h.json(["workspace", "state", "sf"], SpaceState.self) }
    func agentDir(_ s: String) -> String? { MacSessions(store: store, readOnly: true).records().sessions[s]?.fence.map { $0.sessionFolder + "/agent" } }
    func allText(_ folder: String) -> String {
        (fm.enumerator(atPath: folder)?.allObjects as? [String] ?? []).map { text(folder + "/" + $0) }.joined(separator: "\n")
    }

    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    h.env["DOZ_TEST_BRIEF_HOME"] = "/tmp"
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "F chat on again (\(r.code) \(r.err.prefix(120)))")
    try? "Watch the thing.\n".write(to: dir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
    let file = dir.appendingPathComponent("sf.space.yaml")
    let spaceText = """
    doz: space/3
    space: sf
    brief: BRIEF.md
    owner: ada
    folders:
      scratch: {}
    agents:
      w1: { kind: claude-code, isolation: fenced, prompt: watch }
    chat:
      rooms:
        sf: { main: true, members: [owner, w1] }

    """
    try? spaceText.write(to: file, atomically: true, encoding: .utf8)

    // F1. up, then its state
    r = h.run(["workspace", "up", "-f", file.path, "--yes"], timeout: 240)
    check(r.code == 0, "F1 up (\(r.code) \(r.err.prefix(200)))")
    let s1 = state()
    check(s1?.factsKnown == true && s1?.sha.count == 64 && s1?.sha == s1?.computedSHA && s1?.run?.phase == "up",
          "F1 workspace state --json: facts known, a sha, the run up (\(s1.map { "\($0.factsKnown) \($0.run?.phase ?? "-")" } ?? "none"))")
    check(s1.map { $0.items.map { "\($0.type) \($0.subject)" } } == ["agent w1", "member w1", "folder scratch", "room sf"],
          "F1 …one item per thing the file declares (\(s1?.items.map { "\($0.type) \($0.subject)" } ?? []))")
    check(h.waitFor(30) { state()?.items.first { $0.type == "agent" && $0.subject == "w1" }?.activity == "working" },
          "F1 …w1 running, working (the FAKE claude's status)")
    let t1 = h.run(["workspace", "state", "sf"])
    check(t1.code == 0 && t1.out.contains("agent") && t1.out.contains("w1") && t1.out.contains("sha "), "F1 …and as text")
    let runID = h.json(["workspace", "runs", "sf"], WorkspaceRunsListing.self)?.runs.last?.id ?? "?"
    // F1b. ls --json: the row says which space file made it and that it is up; a workspace made without one says nothing
    let l1 = h.json(["workspace", "ls"], WorkspaceListing.self)
    check(l1?.workspaces.first { $0.name == "sf" }?.space == WorkspaceRowSpace(file: "sf.space.yaml", up: true),
          "F1b ls --json: sf made by sf.space.yaml, up (\(String(describing: l1?.workspaces.first { $0.name == "sf" }?.space)))")
    let plain = l1?.workspaces.filter { (try? ws.read($0.name)).flatMap { $0 }.flatMap(SpaceRecordRef.of) == nil } ?? []
    check(!plain.isEmpty && plain.allSatisfy { $0.space == nil } && l1?.workspaces.filter { $0.space != nil }.allSatisfy { $0.space!.file.hasSuffix(".space.yaml") } == true,
          "F1b …a workspace made without a space file carries none (\(plain.count) such)")
    // F1c. ls --json: when each workspace's log last moved — the newest line `workspace log` prints
    // (read after the listing: a line written in between is newer, so lastAt is one of its lines)
    let lastAt = l1?.workspaces.first { $0.name == "sf" }?.lastAt
    let lines = h.json(["workspace", "log", "sf"], [WorkspaceLogEntry].self)?.map(\.at) ?? []
    check(lastAt != nil && lines.contains { abs($0.timeIntervalSince(lastAt!)) < 0.001 },
          "F1c ls --json: sf's lastAt is its log's last line (\(String(describing: lastAt)) · newest \(String(describing: lines.max())))")

    // F2. frames of the open run
    let framesFolder = WorkspaceStore.resolved(ws.folder("sf")) + "/runs/\(runID)/frames"
    check(h.waitFor(20) { (h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self)?.frames.count ?? 0) >= 1 },
          "F2 runs --frames: frames written while the run is open")
    let modes = ((try? fm.attributesOfItem(atPath: framesFolder))?[.posixPermissions] as? NSNumber)?.intValue
    check(modes == 0o700, "F2 …0700 (\(modes.map { String($0, radix: 8) } ?? "none"))")

    // F3. a permission prompt
    let before = h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self)?.frames.count ?? 0
    if let d = agentDir("sf-w1") { fm.createFile(atPath: d + "/block", contents: Data()) }
    check(h.waitFor(30) { state()?.attention.first?.kind == "permission" }, "F3 a permission prompt: attention permission")
    let s3 = state()
    check(s3?.items.first { $0.type == "agent" && $0.subject == "w1" }?.activity == "waiting", "F3 …the agent waiting")
    check(s3?.attention.first?.text.contains("blocked: needs permission") == true, "F3 …its words (\(s3?.attention.first?.text ?? "-"))")
    check(h.waitFor(20) { (h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self)?.frames.count ?? 0) > before },
          "F3 …a new frame for it, moved by the event")
    check(!allText(framesFolder).contains("FAKE-SECRET-WORDS"), "F3 …no frame holds the program's message")

    // D14. an open ask: the live state carries its question and canAnswer; a frame neither
    let tokenFile = root.appendingPathComponent("d14bot.token").path
    h.run(["chat", "add", "d14bot", "--to-file", tokenFile], timeout: 60)
    h.run(["chat", "send", "sf", "/invite @d14bot"], timeout: 60)
    let st = (try? JSONSerialization.jsonObject(with: h.run(["chat", "status", "--json"]).outData)) as? [String: Any]
    let page = (st?["pagePort"] as? Int) ?? 0
    let ask = Process()
    ask.executableURL = URL(fileURLWithPath: dozchat)
    ask.arguments = ["ask", "sf", "Ship the space today?", "--option", "yes=Yes"]
    ask.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": tokenFile]
    let askOut = Pipe()
    ask.standardOutput = askOut
    ask.standardError = FileHandle.nullDevice
    try? ask.run()
    let askID = ((try? JSONSerialization.jsonObject(with: askOut.fileHandleForReading.readDataToEndOfFile())) as? [String: Any])?["msg_id"] as? String ?? "?"
    ask.waitUntilExit()
    check(h.waitFor(20) { state()?.attention.contains { $0.kind == "ask" && $0.askId == askID } == true }, "D14 workspace state --json has the ask's item (\(ask.terminationStatus))")
    let item = state()?.attention.first { $0.kind == "ask" && $0.askId == askID }
    check(item?.question == "Ship the space today?" && item?.canAnswer == true && item?.options == ["Yes", "Decline"] && item?.answerers == ["ada"]
          && item?.text == "d14bot asks a question", "D14 …with its question, options and canAnswer for you (\(item.map { "\($0.question ?? "-") \($0.canAnswer ?? false)" } ?? "none"))")
    let framesBefore = h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self)?.frames.count ?? 0
    if let d = agentDir("sf-w1") { fm.createFile(atPath: d + "/unblock", contents: Data()) }
    check(h.waitFor(30) { (h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self)?.frames.count ?? 0) > framesBefore },
          "D14 …a new frame after it (moved by the program's status)")
    let framed = allText(framesFolder)
    check(framed.contains(askID) && !framed.contains("Ship the space today") && !framed.contains("\"canAnswer\":true"),
          "D14 …the frame has the ask's item, never its question nor anything answerable")
    let wd = Process()
    wd.executableURL = URL(fileURLWithPath: dozchat)
    wd.arguments = ["withdraw", "sf", askID]
    wd.environment = ask.environment
    wd.standardOutput = FileHandle.nullDevice
    wd.standardError = FileHandle.nullDevice
    try? wd.run()
    wd.waitUntilExit()

    // F4. the file through the daemon's operations
    let shown = h.run(["workspace", "show", "sf", "--space", "--json"])
    let shownSHA = ((try? JSONSerialization.jsonObject(with: shown.outData)) as? [String: Any])?["sha256"] as? String
    check(shown.code == 0 && shownSHA == WorkspaceStore.sha256(Data(spaceText.utf8)), "F4 show --space --json: the file's sha256 (\(shown.code))")
    let planBefore = ((try? ws.read("sf")) ?? nil).flatMap { SpaceRecordRef.of($0)?.planSHA }
    let edited = dir.appendingPathComponent("edited.yaml")
    try? (spaceText + "# saved from the terminal\n").write(to: edited, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "edit", "sf", "--space-file", edited.path, "--if-match", String(repeating: "0", count: 64)], timeout: 60)
    check(r.code == 3 && text(file.path) == spaceText, "F4 a stale --if-match: exit 3, nothing written (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "edit", "sf", "--space-file", edited.path, "--if-match", shownSHA ?? "-"], timeout: 60)
    check(r.code == 0 && text(file.path) == spaceText + "# saved from the terminal\n" && r.out.contains("not applied"),
          "F4 the current --if-match: written, not applied (\(r.code) \(r.err.prefix(160)))")
    check(((try? ws.read("sf")) ?? nil).flatMap { SpaceRecordRef.of($0)?.planSHA } == planBefore, "F4 …up was not run: the record's plan unchanged")
    check(((try? ws.log("sf")) ?? []).last?.action == "space-saved", "F4 …logged as space-saved")

    // F5. down: the final frame, the archive, the folder gone
    r = h.run(["workspace", "down", "sf", "--yes"], timeout: 300)
    check(r.code == 0, "F5 down (\(r.code) \(r.err.prefix(200)))")
    let d5 = h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self)
    check(d5?.archive?.verified == true && (d5?.archive?.files.filter { $0.path.hasPrefix("frames/") }.count ?? 0) >= 3,
          "F5 …the archive holds frames/ and verifies (\(d5?.archive?.files.filter { $0.path.hasPrefix("frames/") }.count ?? -1))")
    check(d5?.frames.last?.state.run?.phase == "down", "F5 …the final frame: the run down")
    check(!fm.fileExists(atPath: (framesFolder as NSString).deletingLastPathComponent), "F5 …the run's folder of frames removed once it verified")
    let archive = WorkspaceStore.resolved(store.root.path) + "/archives/sf/runs/\(runID)/frames"
    check(!allText(archive).contains("FAKE-SECRET-WORDS"), "F5 …no archived frame holds the program's message")
    check((h.json(["workspace", "runs", "sf"], WorkspaceRunsListing.self)?.runs.last?.frames ?? 0) >= 3, "F5 …runs --json counts the frames")
    check(h.json(["workspace", "ls"], WorkspaceListing.self)?.workspaces.first { $0.name == "sf" }?.space == WorkspaceRowSpace(file: "sf.space.yaml", up: false),
          "F5 …ls --json: sf still made by sf.space.yaml, not up")

    // F6. looking with the daemon stopped starts none
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    let s6 = state()
    check(s6?.factsKnown == false && s6?.items.allSatisfy({ $0.state == "unknown" }) == true && s6?.run?.phase == "down",
          "F6 state with no daemon: every state not known (\(s6?.items.map(\.state) ?? []))")
    check(h.run(["workspace", "show", "sf", "--space", "--json"]).code == 0 && h.json(["workspace", "runs", "sf", "--frames", runID], SpaceRunDetail.self) != nil,
          "F6 show --space and runs --frames answer")
    check(!h.hostRunning, "F6 …and no daemon was started")
}
