import Darwin
import Foundation
import DozableHost

// `make test-cli-skill` (`doz-vmtest cli-skill --doz PATH`): the agent briefing through the real signed doz — no VM, no
// daemon, a scratch store that is never written. `doz create` is never run.
//
//  B1. doz --help → 0, "doz workspace new" within its first 25 lines (and state, worker add, the skill's command)
//  B2. doz skill show doz --json → 0, {kind: Skill, schema: 1, name: doz, path}: the path absolute, existing, in the
//      resource bundle beside the signed doz
//  B3. doz skill show doz → 0, exactly that file's bytes; it starts with the skill's frontmatter
//  B4. doz skill show nosuch [--json] → 2, not-found, the message naming doz; a path as a name → 2
//  B5. an installed layout (a scratch prefix: bin/doz → ../libexec/doz/doz, the bundle beside it, as Homebrew and the
//      tarball lay it out) → its own bundle's SKILL.md, through the link
//  B6. nothing of it starts a daemon
func cliSkillSuite(binary: String) async {
    print("cli: the agent briefing — doz --help, doz skill show (no VM, no daemon)")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-skill")
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let h = CLIHarness(binary: binary, store: root.appendingPathComponent("store"))
    h.env["DO_NOT_TRACK"] = "1"
    func object(_ r: CLIRun) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]) ?? [:] }

    // B1. the first screen names how to make a workspace.
    var r = h.run(["--help"])
    let first25 = r.out.split(separator: "\n", omittingEmptySubsequences: false).prefix(25).joined(separator: "\n")
    check(r.code == 0 && first25.contains("doz workspace new"), "B1 doz --help: exit 0, \"doz workspace new\" within its first 25 lines (\(r.code) \(first25.prefix(400)))")
    check(first25.contains("doz workspace state") && first25.contains("doz worker add") && first25.contains("doz skill show doz"),
          "B1 …and doz workspace state, doz worker add and doz skill show doz there too")
    check(r.out.contains("SUBCOMMANDS:") && r.out.contains("\n  skill ") && r.out.contains("\n  workspace "), "B1 …the full list follows, skill in it")

    // B2. the JSON answer and its path.
    r = h.run(["skill", "show", "doz", "--json"])
    let o = object(r)
    let path = o["path"] as? String ?? ""
    check(r.code == 0 && o["kind"] as? String == "Skill" && o["schema"] as? Int == 1 && o["name"] as? String == "doz" && Set(o.keys) == ["kind", "schema", "name", "path"],
          "B2 skill show doz --json: exit 0, {kind: Skill, schema: 1, name: doz, path} (\(r.code) \(r.out.prefix(300)))")
    let beside = URL(fileURLWithPath: binary).resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("DozableKit_DozableKit.bundle/skills/doz/SKILL.md").standardizedFileURL.path
    check(path.hasPrefix("/") && fm.fileExists(atPath: path) && URL(fileURLWithPath: path).resolvingSymlinksInPath().path
          == URL(fileURLWithPath: beside).resolvingSymlinksInPath().path,
          "B2 …the path is absolute, exists, and is the bundle's beside the signed doz (\(path))")

    // B3. the text.
    r = h.run(["skill", "show", "doz"])
    let file = fm.contents(atPath: path) ?? Data()
    check(r.code == 0 && !file.isEmpty && r.outData == file && r.out.hasPrefix("---\nname: doz\n"),
          "B3 skill show doz: exit 0, exactly its SKILL.md, the frontmatter first (\(r.code) \(r.outData.count) of \(file.count) bytes)")

    // B4. an unknown skill.
    r = h.run(["skill", "show", "nosuch", "--json"])
    let e = object(r)["error"] as? [String: Any]
    check(r.code == 2 && e?["code"] as? String == "not-found" && e?["exit"] as? Int == 2 && (e?["message"] as? String)?.contains("doz") == true,
          "B4 skill show nosuch --json: exit 2, not-found, naming doz (\(r.code) \(r.out.prefix(300)))")
    r = h.run(["skill", "show", "nosuch"])
    check(r.code == 2 && r.err.contains("doz"), "B4 …and without --json: exit 2, said on stderr (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["skill", "show", "../skills/doz", "--json"])
    check(r.code == 2, "B4 …a path as a name is not found (\(r.code))")

    // B5. the installed layout: bin/doz is a link to libexec/doz/doz, its bundle beside it.
    let prefix = root.appendingPathComponent("prefix")
    let libexec = prefix.appendingPathComponent("libexec/doz")
    try? fm.createDirectory(at: libexec, withIntermediateDirectories: true)
    try? fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let builtBundle = URL(fileURLWithPath: binary).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("DozableKit_DozableKit.bundle")
    do {
        try fm.copyItem(at: URL(fileURLWithPath: binary).resolvingSymlinksInPath(), to: libexec.appendingPathComponent("doz"))
        try fm.copyItem(at: builtBundle, to: libexec.appendingPathComponent("DozableKit_DozableKit.bundle"))
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/doz").path, withDestinationPath: "../libexec/doz/doz")
    } catch { check(false, "B5 the scratch installed layout: \(error)") }
    let installed = CLIHarness(binary: prefix.appendingPathComponent("bin/doz").path, store: root.appendingPathComponent("store"))
    installed.env["DO_NOT_TRACK"] = "1"
    r = installed.run(["skill", "show", "doz", "--json"])
    let ip = object(r)["path"] as? String ?? ""
    check(r.code == 0 && ip.hasSuffix("/prefix/libexec/doz/DozableKit_DozableKit.bundle/skills/doz/SKILL.md") && fm.fileExists(atPath: ip),
          "B5 an installed layout through bin/doz → its own libexec/doz bundle's SKILL.md (\(r.code) \(ip))")

    // B6. looking never starts the daemon.
    check(!h.hostRunning, "B6 no daemon was started")
}
