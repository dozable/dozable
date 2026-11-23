// `make test-cli-workspace`, rows R1–R13: runs and their evidence archive, with the lifecycle rows' FAKE claude (fenced
// sessions on this Mac: each writes its conversation in its own agent folder; a `plant.txt` in the folder adds a line), the
// scratch fence home (where a fenced session's conversations are carried back), never the real `claude` or `~/.claude`.
//
//  R1.  start opens run 1 (its rooms' start markers as data; nothing posted)
//  R3.  finish writes its archive: 0700/0600, the manifest re-hashed clean, the fixture's files; the slice holds the run's
//       messages and not one from before the start; the session's carried conversation is archived with its source's sha
//  R6.  a token planted in a message and in the conversation is redacted: the whole archive holds no copy of it
//  R5.  reopen opens run 2; posts taken; a second finish: two runs on one day, each its own id and its own slice
//  R12. discard: refused while a run is open, and for a session no archive holds; an unchanged carried file removed, one
//       appended since its archive kept ("changed since it was archived"), the other files untouched
//  R7.  an archive that cannot be written: finish exits 1 with the reason and the command, removes nothing; once the folder
//       can be written again, runs --archive writes it
//  R13. a deleted workspace's run archives stay in the store
//  R11. a record started before runs were kept: its finish records a legacy run
//  R10. runs --json with the daemon stopped: every run answered, no daemon started
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliWorkspaceRunRows(_ h: CLIHarness, root: URL, store: DozableStore, home: URL, brief: String, started: inout Set<String>) {
    print("cli: runs and their archive")
    let fm = FileManager.default
    let pid = getpid()
    let sroot = WorkspaceStore.resolved(store.root.path)
    let rwork = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsr-work")
    try? fm.removeItem(at: rwork)
    try? fm.createDirectory(at: rwork, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: rwork) }
    func runsOf(_ n: String) -> WorkspaceRunsListing? { h.json(["workspace", "runs", n], WorkspaceRunsListing.self) }
    func records() -> [String: MacSessionRecord] { MacSessions(store: store, readOnly: true).records().sessions }
    func archiveText(_ rel: String) -> String {
        var all = ""
        let dir = sroot + "/" + rel
        for f in (try? fm.subpathsOfDirectory(atPath: dir)) ?? [] { all += (fm.contents(atPath: dir + "/" + f)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        return all
    }
    /// The carried copies of session `s` in the fence home, by the record's `carried` names.
    func carried(_ s: String) -> [String] {
        let names = Set((records()[s]?.fence?.carried ?? []).compactMap { $0.split(separator: ":").first.map(String.init) })
        guard let e = fm.enumerator(atPath: home.path + "/.claude/projects") else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            if names.contains((rel as NSString).lastPathComponent) { out.append(home.path + "/.claude/projects/" + rel) }
        }
        return out
    }
    // rw1 works in rwork; rw2 and rw3 in a folder of their own (sessions of one folder share its agent folder, and each carries
    // back every conversation there).
    let rwork2 = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsr-work2")
    try? fm.removeItem(at: rwork2)
    try? fm.createDirectory(at: rwork2, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: rwork2) }
    func fenced(_ s: String, _ folder: URL? = nil) -> Bool {
        let r = h.run(["run", "@mac", "-d", "--fenced", "--session", s, "--folder", (folder ?? rwork).path, "--", "claude"], timeout: 90)
        if r.code == 0 { started.insert(s) }
        return r.code == 0
    }

    // A live token to plant (a participant's — known to the store by its hash only).
    let tokenFile = root.appendingPathComponent("plant.token").path
    h.run(["chat", "add", "plant", "--to-file", tokenFile], timeout: 60)
    let token = ((try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try? token.write(toFile: rwork.path + "/plant.txt", atomically: true, encoding: .utf8)

    // R1. start opens run 1
    var r = h.run(["workspace", "new", "rw", "--prompt-file", brief, "--folder", rwork.path], timeout: 60)
    h.run(["chat", "send", "rw", "said before the start"])
    r = h.run(["workspace", "start", "rw"], timeout: 60)
    var l = runsOf("rw")
    check(r.code == 0 && l?.runs.count == 1 && l?.runs.first?.archiveStatus == "open" && (l?.runs.first?.rooms.first?.fromSeq ?? 0) >= 1,
          "R1 start opens run 1, its room's start marker as data (\(r.code), \(l?.runs.map(\.archiveStatus) ?? []))")
    let s1 = fenced("rw1")
    r = h.run(["workspace", "adopt", "rw", "@mac/rw1"], timeout: 60)
    h.run(["chat", "send", "rw", "said in run 1"])
    h.run(["chat", "send", "rw", "pasted by mistake: \(token)"])
    check(s1 && r.code == 0, "R1 …a fenced session adopted into it (\(r.code) \(r.err.prefix(160)))")

    // R3 and R6. finish writes the archive
    r = h.run(["workspace", "finish", "rw", "--yes", "--json"], timeout: 180)
    let c1 = try? HostWire.decoder.decode(WorkspaceChanged.self, from: r.outData)
    let a1 = c1?.archive ?? "?"
    let v1 = RunArchive.verify(root: sroot + "/" + a1)
    var st = stat()
    check(r.code == 0 && v1.ok && lstat(sroot + "/" + a1, &st) == 0 && st.st_mode & 0o777 == 0o700, "R3 finish writes the run's archive, 0700, re-hashed clean (\(r.code) \(c1?.archiveProblem ?? ""))")
    let paths = Set(v1.manifest?.files.map(\.path) ?? [])
    check(["run.json", "brief.md", "chat/rw.jsonl", "usage.json", "timesheet.md"].allSatisfy(paths.contains) && !paths.contains("git.json"),
          "R3 …its files: run.json, brief.md, chat/rw.jsonl, usage.json, timesheet.md, and no git.json (\(paths.sorted()))")
    check((v1.manifest?.files ?? []).allSatisfy { f in lstat(sroot + "/" + a1 + "/" + f.path, &st) == 0 && st.st_mode & 0o777 == 0o600 }, "R3 …every file 0600")
    let chat1 = (try? String(contentsOfFile: sroot + "/" + a1 + "/chat/rw.jsonl", encoding: .utf8)) ?? ""
    check(chat1.contains("said in run 1") && !chat1.contains("said before the start"), "R3 the slice holds the run's messages, not one from before its start")
    let tr = (v1.manifest?.files ?? []).filter { $0.path.hasPrefix("transcripts/rw1/") }
    check(!tr.isEmpty && tr.allSatisfy { $0.sourceSHA256 != nil && $0.session == "rw1" }, "R3 rw1's conversation archived with its source's sha256 (\(tr.map(\.path)))")
    let all1 = archiveText(a1)
    check(!token.isEmpty && !all1.contains(token) && all1.contains("[a chat token of plant, removed by doz]"),
          "R6 the planted token is in no file of the archive, replaced and named")
    check((v1.manifest?.sweep.redacted ?? 0) >= 2, "R6 …found in the message and in the conversation (\(v1.manifest?.sweep.redacted ?? -1))")
    check(((try? String(contentsOfFile: sroot + "/" + a1 + "/timesheet.md", encoding: .utf8)) ?? "").contains(Timesheet.commitsNotCollected), "R3 the timesheet: commits not collected")

    // R12 (first part): discard refused while a run is open, and for a session no archive holds.
    r = h.run(["workspace", "reopen", "rw", "--no-start"], timeout: 60)
    h.run(["chat", "send", "rw", "said in run 2"])
    let s2 = fenced("rw2", rwork2)
    h.run(["workspace", "adopt", "rw", "@mac/rw2"], timeout: 60)
    let s3 = fenced("rw3", rwork2)
    _ = h.waitFor(10) { records()["rw2"] != nil && records()["rw3"] != nil }
    // (rw1 ended at the finish: ending it again would forget its record.)
    r = h.run(["sessions", "@mac", "--forget", "rw1", "--discard-transcripts", "--yes"], timeout: 60)
    check(s2 && s3 && r.out.contains("kept rw1") && r.out.contains("is open"), "R12 discard refused while its workspace's run is open (\(r.out.prefix(200)))")
    h.run(["sessions", "end", "@mac", "rw3", "--yes"], timeout: 60)
    r = h.run(["sessions", "@mac", "--forget", "rw3", "--discard-transcripts", "--yes"], timeout: 60)
    check(r.out.contains("kept rw3") && r.out.contains("no closed run's verified archive"), "R12 …and for a session no archive holds (\(r.out.prefix(200)))")

    // R5. a second finish: two runs on one day, each its own slice
    r = h.run(["workspace", "finish", "rw", "--yes", "--json"], timeout: 180)
    let c2 = try? HostWire.decoder.decode(WorkspaceChanged.self, from: r.outData)
    let chat2 = (try? String(contentsOfFile: sroot + "/" + (c2?.archive ?? "?") + "/chat/rw.jsonl", encoding: .utf8)) ?? ""
    l = runsOf("rw")
    check(r.code == 0 && l?.runs.count == 2 && Set(l?.runs.map(\.id) ?? []).count == 2 && l?.runs.allSatisfy { $0.archiveStatus == "written" } == true,
          "R5 reopen and a second finish: two runs, two ids, both archived (\(l?.runs.map(\.id) ?? []))")
    check(chat2.contains("said in run 2") && !chat2.contains("said in run 1"), "R5 …each its own slice")

    // R12. discard: an unchanged carried file removed; one appended since its archive kept.
    let rw1Files = carried("rw1"), rw2Files = carried("rw2")
    for f in rw1Files { if let fh = FileHandle(forWritingAtPath: f) { fh.seekToEndOfFile(); fh.write(Data("{}\n".utf8)); fh.closeFile() } }
    r = h.run(["sessions", "@mac", "--forget", "rw2", "--discard-transcripts", "--yes"], timeout: 60)
    check(!rw2Files.isEmpty && rw2Files.allSatisfy { !fm.fileExists(atPath: $0) } && r.out.contains("discarded"),
          "R12 rw2's unchanged carried conversation removed (\(rw2Files.count) file(s); \(r.out.prefix(160)))")
    r = h.run(["sessions", "@mac", "--forget", "rw1", "--discard-transcripts", "--yes"], timeout: 60)
    check(!rw1Files.isEmpty && rw1Files.allSatisfy { fm.fileExists(atPath: $0) } && r.out.contains("changed since it was archived"),
          "R12 rw1's conversation appended since its archive is kept, with why (\(r.out.prefix(200)))")
    check(fm.fileExists(atPath: rwork.path + "/plant.txt") && RunArchive.verify(root: sroot + "/" + a1).ok, "R12 …nothing else touched; the archives still verify")

    // R7. an archive that cannot be written
    r = h.run(["workspace", "reopen", "rw", "--no-start"], timeout: 60)
    // Something of the person's stands where the next run's archive would go: it is never removed or written over.
    let runsDir = sroot + "/archives/rw/runs"
    let blocker = runsDir + "/" + (runsOf("rw")?.runs.last?.id ?? "?")   // the open run 3
    try? "the person's\n".write(toFile: blocker, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "finish", "rw", "--yes"], timeout: 180)
    check((try? String(contentsOfFile: blocker, encoding: .utf8)) == "the person's\n", "R7 …what stood there is untouched")
    try? fm.removeItem(atPath: blocker)
    l = runsOf("rw")
    let third = l?.runs.last
    check(r.code == 1 && r.err.contains("--archive \(third?.id ?? "?")") && h.json(["workspace", "show", "rw"], WorkspaceDetail.self)?.state == "finished"
          && third?.archiveStatus == "problem", "R7 an unwritable archive: finish exits 1 naming runs --archive, finished anyway (\(r.code) \(r.err.prefix(200)))")
    check(RunArchive.verify(root: sroot + "/" + a1).ok && fm.fileExists(atPath: sroot + "/" + (c2?.archive ?? "?")), "R7 …nothing removed")
    r = h.run(["workspace", "runs", "rw", "--archive", third?.id ?? "?"], timeout: 120)
    check(r.code == 0 && runsOf("rw")?.runs.last?.archiveStatus == "written", "R7 …once it can be written, runs --archive writes it (\(r.code) \(r.err.prefix(160)))")

    // R13. delete keeps the run archives
    r = h.run(["workspace", "delete", "rw", "--yes"], timeout: 120)
    check(r.code == 0 && RunArchive.verify(root: sroot + "/" + a1).ok && ((try? fm.contentsOfDirectory(atPath: runsDir)) ?? []).count == 3,
          "R13 delete keeps its run archives in the store (\(r.code))")
    for s in ["rw1", "rw2", "rw3"] { started.remove(s) }
    check(fm.fileExists(atPath: sroot + "/archives/life/runs"), "R13 …and so does the deleted workspace life's")

    // R11. a record started before runs: a legacy run at its finish
    h.run(["workspace", "new", "leg", "--prompt-file", brief], timeout: 60)
    h.run(["workspace", "start", "leg"], timeout: 60)
    let recFile = sroot + "/workspaces/leg/workspace.json"
    if let d = fm.contents(atPath: recFile), var rec = try? HostWire.decoder.decode(WorkspaceRecord.self, from: d) {
        rec.runs = []   // as a build before runs wrote it (an empty list is not written)
        try? HostWire.prettyEncoder.encode(rec).write(to: URL(fileURLWithPath: recFile))
    }
    let before = runsOf("leg")
    r = h.run(["workspace", "finish", "leg", "--yes"], timeout: 120)
    l = runsOf("leg")
    check(before?.runs.isEmpty == true && r.code == 0 && l?.runs.count == 1 && l?.runs.first?.legacy == true,
          "R11 a record with no runs: its finish records a legacy run (\(r.code) \(l?.runs.map { "\($0.id) \($0.legacy == true)" } ?? []))")

    // R10. runs --json with the daemon stopped
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    let dl = h.json(["workspace", "runs", "leg"], WorkspaceRunsListing.self)
    check(dl?.runs.count == 1 && !h.hostRunning, "R10 runs --json with the daemon stopped: answered, no daemon started")
    h.run(["workspace", "delete", "leg", "--yes"], timeout: 120)
    try? fm.removeItem(atPath: tokenFile)
}
