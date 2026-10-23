import Darwin
import Foundation
import DozableKit
import DozableHost

// 643 (624.B1 part 1): `doz files` — a folder of a sandbox's /workspace, and `--watch`. A SHARED workspace is read and
// watched on the Mac: listed while the sandbox is off with no host started, the workspace rules as the guest's view
// applies them (compared with the guest's own `ls`), a link out refused; `--watch` gets ONE batch for a file written on
// the Mac and for one written in the guest, starts no host, and leaves a sleeping sandbox asleep. An ISOLATED sandbox is
// listed from inside it while it runs, refused while it sleeps (still asleep after), and `--watch` is refused.
// Lab sandboxes, a scratch store (`/tmp/dzo-PID-fl`), a scratch workspace (`/tmp/dzo-PID-flw`), `defaults.projects_dir`
// a scratch path. Never the owner's store, settings or files.

func cliFilesSuite(binary: String) async {
    let t = onboardingHarness(binary, "fl", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let pid = getpid()
    let ws = URL(fileURLWithPath: "/tmp/dzo-\(pid)-flw")
    let projects = URL(fileURLWithPath: "/tmp/dzo-\(pid)-flp")
    defer {
        t.run(["host", "stop"])
        for u in [t.store, ws, projects] { try? FileManager.default.removeItem(at: u) }
    }
    let fm = FileManager.default
    try? fm.removeItem(at: ws)
    func put(_ rel: String, _ text: String = "x\n") {
        let u = ws.appendingPathComponent(rel)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: u.path, contents: Data(text.utf8))
    }
    put("README.md", "# hi\n")
    put("src/main.c", "int main(void) { return 0; }\n")
    put("secret.env", "S=1\n")
    put("private/x", "p\n")
    put("logs/keep.txt", "k\n")
    put("logs/other.log", "o\n")
    put(".dozignore", "secret.env\nprivate\nlogs\n!logs/keep.txt\n")
    put(".dozreadonly", "README.md\n")
    try? fm.createSymbolicLink(atPath: ws.appendingPathComponent("out").path, withDestinationPath: "/etc")
    func list(_ args: [String]) -> FileList? {
        let r = t.run(["files"] + args + ["--json"])
        guard r.code == 0 else { return nil }
        return try? HostWire.decoder.decode(FileList.self, from: r.outData)
    }
    func names(_ l: FileList?) -> [String] { (l?.entries ?? []).map(\.name) }
    func state(_ l: FileList?, _ n: String) -> String? { l?.entries.first { $0.name == n }?.state }

    print("cli: doz files — list and watch (643)")
    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "defaults.projects_dir", projects.path]).code == 0, "defaults.projects_dir is a scratch path")

    // 1. Created, never started: listed on the Mac, no host.
    check(t.run(["create", "fl", "--image", "lab", "--workspace", ws.path, "--memory", "512M", "--network", "none"], timeout: 300).code == 0,
          "create fl --workspace (shared)")
    t.run(["host", "stop"])
    check(t.waitFor(30) { !t.hostRunning }, "no host runs")
    var l = list(["fl"])
    check(l?.source == "mac" && l?.watch == "mac" && l?.rules == true && l?.path == "/workspace", "doz files fl: the Mac's folder, rules applied (\(String(describing: l?.path)))")
    check(names(l) == ["logs", "private", "src", ".dozignore", ".dozreadonly", "out", "README.md", "secret.env"], "folders first, then by name (\(names(l)))")
    check(state(l, "secret.env") == "locked" && l?.entries.first { $0.name == "secret.env" }?.size == nil, "lock: secret.env listed as locked, no size")
    check(state(l, "private") == "locked", "lock: a locked folder is listed locked")
    check(state(l, "README.md") == "read-only" && state(l, ".dozignore") == "read-only", "read-only: .dozreadonly's and the rule files")
    check(l?.entries.first { $0.name == "out" }.map { $0.kind == "link" && $0.target == "/etc" } == true, "a link: its target, never followed")
    check(!t.hostRunning, "looking started no host")
    l = list(["fl", "logs"])
    check(names(l) == ["keep.txt", "other.log"] && state(l, "other.log") == "locked" && state(l, "keep.txt") == nil, "logs/: the ! line's file visible, the rest locked")
    var r = t.run(["files", "fl", "out"])
    check(r.code != 0 && r.err.contains("leads outside the shared folder"), "a link out of the share is refused (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = t.run(["files", "fl", "../etc"])
    check(r.code != 0 && r.err.contains("not a folder in /workspace"), "../etc is refused")
    r = t.run(["files", "fl", "private"])
    check(r.code != 0 && r.err.contains("locked by the workspace rules"), "a locked folder cannot be listed")
    check(t.run(["config", "set", "--sandbox", "fl", "workspace.ignore_mode", "hide"]).code == 0, "workspace.ignore_mode hide for fl")
    t.run(["host", "stop"])                                   // a sandbox's own setting is written through the host
    check(t.waitFor(30) { !t.hostRunning }, "no host runs again")
    l = list(["fl"])
    check(!names(l).contains("secret.env") && !names(l).contains("private") && names(l).contains("logs"), "hide: the hidden names are absent (\(names(l)))")
    check(names(list(["fl", "logs"])) == ["keep.txt"], "hide: logs/ holds only what the ! line re-includes")
    r = t.run(["files", "fl", "private"])
    check(r.code != 0 && r.err.contains("no such folder"), "hide: a hidden folder is not there")
    check(!t.hostRunning, "still no host")

    // 2. Watched while off: a change on the Mac → one batch; a hidden one → none; no host.
    do {
        let w = try AttachedClient(t, ["files", "fl", "src", "--watch", "--json"])
        defer { w.close() }
        check(w.wait(15) { $0.err.text.contains("watching /workspace/src in fl") }, "doz files fl src --watch: watching")
        usleep(400_000)
        put("src/new.c", "n\n")
        check(w.wait(10) { $0.text.contains(#""folders":["\/workspace\/src"]"#) || $0.text.contains(#""folders":["/workspace/src"]"#) },
              "a file written on the Mac → a batch naming /workspace/src (\(w.text.debugDescription))")
        let lines = w.text.split(separator: "\n").count
        put("secret.env", "S=2\n")
        put("README.md", "# changed outside the watched folder\n")
        usleep(1_200_000)
        check(w.text.split(separator: "\n").count == lines, "nothing for a hidden file or an unwatched folder")
        check(!t.hostRunning, "watching started no host")
    } catch { check(false, "watch: \(error)") }

    // 2b. 644: the panel's changes while OFF — on the Mac, no host started, nothing woken; the rules (hide mode now) and
    // the confinement refuse what the guest's view would.
    print("cli: doz files mkdir|new|mv|rename|rm|open — the file explorer panel's changes (644)")
    func ok(_ args: [String], _ what: String) { let r = t.run(["files"] + args); check(r.code == 0, what + (r.code == 0 ? "" : " (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")) }
    func refused(_ args: [String], _ says: String, _ what: String) {
        let r = t.run(["files"] + args)
        check(r.code != 0 && r.err.contains(says), what + " (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
    let has = { (rel: String) in fm.fileExists(atPath: ws.appendingPathComponent(rel).path) }
    ok(["mkdir", "fl", "made"], "files mkdir fl made (off)")
    ok(["new", "fl", "made/a.txt"], "files new fl made/a.txt")
    ok(["rename", "fl", "made/a.txt", "b.txt"], "files rename … b.txt")
    ok(["mv", "fl", "made/b.txt", "/workspace/src/b.txt"], "files mv … into src")
    check(has("made") && !has("made/a.txt") && has("src/b.txt"), "the Mac folder shows each change")
    refused(["mkdir", "fl", "src"], "is there already", "never replaces: mkdir of an existing folder")
    refused(["new", "fl", "src/b.txt"], "is there already", "never replaces: new over a file")
    refused(["new", "fl", "out/x"], "leads outside the shared folder", "a link out is never written through")
    refused(["new", "fl", "secret.env"], "hide that name", "a name the rules hide is refused (hide mode)")
    refused(["rm", "fl", "README.md", "--yes"], "read-only", "a read-only file is not deleted")
    refused(["rm", "fl", "/workspace", "--yes"], "never deleted", "/workspace itself is never deleted")
    refused(["rm", "fl", "src", "--yes"], "not empty", "a folder with contents needs -r")
    ok(["rm", "fl", "made", "--yes"], "files rm fl made (an empty folder)")
    ok(["mkdir", "fl", "tmpdir"], "files mkdir fl tmpdir")
    ok(["new", "fl", "tmpdir/x"], "files new fl tmpdir/x")
    ok(["rm", "fl", "tmpdir", "-r", "--yes"], "files rm -r (a folder with contents)")
    check(!has("tmpdir") && fm.fileExists(atPath: "/etc/hosts"), "deleted on the Mac; nothing outside touched")
    let seam = t.store.appendingPathComponent("opened.log")
    t.env["DOZ_TEST_OPEN_URL"] = seam.path
    put("docs/page.html", "<p>hi</p>\n")
    ok(["open", "fl", "docs/page.html"], "files open (through the opener seam)")
    ok(["open", "fl", "src/main.c", "--reveal"], "files open --reveal (a file, shown in its folder)")
    refused(["open", "fl", "secret.env"], "no such file", "a hidden file is not opened")
    let opened = (try? String(contentsOf: seam, encoding: .utf8)) ?? ""
    check(opened.contains("open-file default ") && opened.contains("page.html") && opened.contains("reveal "), "the seam saw the open and the reveal (\(opened))")
    t.env["DOZ_TEST_OPEN_URL"] = nil
    let j = t.run(["files", "new", "fl", "j.txt", "--json"])
    let jr = try? HostWire.decoder.decode(FileChangeResult.self, from: j.outData)
    check(jr?.folders == ["/workspace"] && jr?.source == "mac", "--json: the folders that changed")
    check(!t.hostRunning, "no change started a host")
    check(t.row("fl")?.phase == "off", "and fl is still off")

    // 3. Running: the listing is what the guest sees; a change made in the guest arrives; asleep stays asleep.
    check(t.run(["start", "fl"], timeout: 300).code == 0, "start fl")
    r = t.run(["exec", "fl", "--", "sh", "-c", "ls -A /workspace | sort"])
    let guest = Set(r.out.split(separator: "\n").map(String.init))
    check(r.code == 0 && guest == Set(names(list(["fl"]))), "the listing is exactly what the guest sees (\(guest.sorted()) vs \(names(list(["fl"]))))")
    do {
        let w = try AttachedClient(t, ["files", "fl", "src", "--watch", "--json"])
        defer { w.close() }
        check(w.wait(15) { $0.err.text.contains("watching") }, "watching again (host running)")
        usleep(400_000)
        // 644: a change made on the Mac through doz files is what the guest sees
        check(t.run(["files", "mkdir", "fl", "from-mac-\(pid)"]).code == 0
              && t.run(["exec", "fl", "--", "test", "-d", "/workspace/from-mac-\(pid)"]).code == 0, "files mkdir while running: the guest sees it")
        check(t.run(["exec", "fl", "--", "sh", "-c", "echo g > /workspace/src/from-guest-\(pid).c"]).code == 0, "a file written in the guest")
        check(w.wait(10) { $0.text.contains("/workspace/src") }, "→ a batch (the share's change reaches the Mac's FSEvents)")
        check(t.run(["sleep", "fl"], timeout: 300).code == 0, "sleep fl")
        let before = w.text.split(separator: "\n").count
        put("src/while-asleep-\(pid).c", "z\n")
        check(w.wait(10) { $0.text.split(separator: "\n").count > before }, "a change while it sleeps still arrives")
        sleep(2)
        check(t.row("fl")?.phase == "asleep", "and fl is still asleep — watching never wakes it (\(t.row("fl")?.phase ?? "?"))")
        check(list(["fl", "src"]).map { names($0).contains("while-asleep-\(pid).c") } == true, "listing it asleep: no wake either")
        check(t.row("fl")?.phase == "asleep", "still asleep")
        // 644: a change while it sleeps — on the Mac, no wake
        check(t.run(["files", "new", "fl", "src/made-asleep-\(pid).c"]).code == 0, "files new while asleep")
        sleep(1)
        check(t.row("fl")?.phase == "asleep", "and fl is still asleep — a change never wakes it")
    } catch { check(false, "watch: \(error)") }

    // 4. Isolated: listed from inside while it runs; refused asleep (still asleep); not watched.
    check(t.run(["up", "fl2", "--image", "lab", "--isolated", "--memory", "512M", "--network", "none", "--detach"], timeout: 600).code == 0,
          "up fl2 --isolated --detach")
    check(t.run(["exec", "fl2", "--", "sh", "-c", "mkdir -p /workspace/d && printf abc > /workspace/d/a.txt && ln -sf /etc /workspace/ln"]).code == 0,
          "files made in the isolated guest")
    l = list(["fl2"])
    check(l?.source == "guest" && l?.watch == "none" && names(l).contains("d") && names(l).contains("ln"), "isolated: listed from the guest (\(names(l)))")
    check(l?.entries.first { $0.name == "ln" }.map { $0.kind == "link" && $0.target == "/etc" } == true, "isolated: a link with its target")
    l = list(["fl2", "/workspace/d"])
    check(l?.entries.first.map { $0.name == "a.txt" && $0.kind == "file" && $0.size == 3 } == true, "isolated: a file with its size")
    r = t.run(["files", "fl2", "--watch"])
    check(r.code != 0 && r.err.contains("list them again to refresh"), "isolated: --watch is refused with why")
    r = t.run(["files", "fl2", "nope"])
    check(r.code != 0 && r.err.contains("no such folder"), "isolated: a missing folder")
    // 644: the changes, inside, as the image's user, while it runs
    check(t.run(["files", "mkdir", "fl2", "d/sub"]).code == 0 && t.run(["files", "new", "fl2", "d/sub/n.txt"]).code == 0, "isolated: files mkdir + new inside")
    check(t.run(["files", "mv", "fl2", "d/sub/n.txt", "d/m.txt"]).code == 0, "isolated: files mv inside")
    r = t.run(["exec", "fl2", "--", "sh", "-c", "test -f /workspace/d/m.txt && test ! -e /workspace/d/sub/n.txt && echo yes"])
    check(r.out.contains("yes"), "isolated: the guest shows the changes")
    r = t.run(["files", "new", "fl2", "d/m.txt"])
    check(r.code != 0 && r.err.contains("is there already"), "isolated: never replaces")
    r = t.run(["files", "mkdir", "fl2", "ln/x"])
    check(r.code != 0 && r.err.contains("outside /workspace"), "isolated: a link out of /workspace is refused (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = t.run(["files", "rm", "fl2", "d", "--yes"])
    check(r.code != 0 && r.err.contains("not empty"), "isolated: a folder with contents needs -r")
    check(t.run(["files", "rm", "fl2", "d", "-r", "--yes"]).code == 0
          && t.run(["exec", "fl2", "--", "test", "!", "-e", "/workspace/d"]).code == 0, "isolated: files rm -r inside")
    r = t.run(["files", "open", "fl2", "x"])
    check(r.code != 0 && r.err.contains("doz get"), "isolated: no open on the Mac — the copy command instead")
    check(t.run(["sleep", "fl2"], timeout: 300).code == 0, "sleep fl2")
    r = t.run(["files", "fl2"])
    check(r.code != 0 && r.err.contains("never wakes or starts it"), "isolated and asleep: refused with why (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(t.row("fl2")?.phase == "asleep", "and still asleep")
    r = t.run(["files", "mkdir", "fl2", "z"])
    check(r.code != 0 && r.err.contains("never wakes or starts it"), "isolated and asleep: a change is refused with why")
    check(t.row("fl2")?.phase == "asleep", "and still asleep after it")

    check(t.run(["rm", "fl2", "--yes"], timeout: 120).code == 0, "rm fl2")
    check(t.run(["rm", "fl", "--yes"], timeout: 120).code == 0, "rm fl")
}
