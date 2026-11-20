import Foundation
import DozableKit
import DozableHost
import XCTest
@testable import DozableWeb

/// 590 phase 2 — the typed actions: each is exactly one HostOp, decoded strictly, destructive ones
/// confirmed; the policy preview, the Terminal hand-off, the CSV defence, the metrics query.
final class WebActionTests: XCTestCase {
    func decode(_ json: String) throws -> WebAction { try WebAction.decode(Data(json.utf8)) }

    func invalid(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), json, file: file, line: line) { XCTAssertTrue($0 is WebAction.Invalid, "\($0)", file: file, line: line) }
    }

    func invalid(_ json: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), why, file: file, line: line) { XCTAssertTrue($0 is WebAction.Invalid, "\(why): \($0)", file: file, line: line) }
    }

    /// A valid body for every action name.
    static let samples: [String: String] = [
        "create": #"{"action":"create","sandbox":"new1","image":"lab","cpus":2,"memoryMiB":1024,"network":"bake","account":"default"}"#,
        "start": #"{"action":"start","sandbox":"a"}"#, "wake": #"{"action":"wake","sandbox":"a"}"#,
        "pause": #"{"action":"pause","sandbox":"a"}"#, "resume": #"{"action":"resume","sandbox":"a"}"#,
        "sleep": #"{"action":"sleep","sandbox":"a"}"#, "hibernate": #"{"action":"hibernate","sandbox":"a"}"#,
        "shutdown": #"{"action":"shutdown","sandbox":"a"}"#, "reset": #"{"action":"reset","sandbox":"a","confirm":"a"}"#,
        "rm": #"{"action":"rm","sandbox":"a","confirm":"a"}"#,
        "open-session": #"{"action":"open-session","sandbox":"a","session":"worker","argv":["sleep","60"]}"#,
        "point-take": #"{"action":"point-take","sandbox":"a","point":"p1","note":"before"}"#,
        "point-revert": #"{"action":"point-revert","sandbox":"a","point":"rp-20260927-094949-330-bc2e","confirm":"a"}"#,
        "point-fork": #"{"action":"point-fork","sandbox":"a","point":"p1","newName":"b"}"#,
        "point-rm": #"{"action":"point-rm","sandbox":"a","point":"p1","confirm":"a"}"#,
        "point-save-image": #"{"action":"point-save-image","sandbox":"a","image":"mine"}"#,
        "template-create": #"{"action":"template-create","sandbox":"a","image":"my-tpl","note":"node + tools"}"#,
        "duplicate": #"{"action":"duplicate","sandbox":"a","newName":"a2","folder":"/tmp","cpus":4,"memoryMiB":2048,"network":"locked","account":"none","copyState":true}"#,
        "image-bake": #"{"action":"image-bake","image":"claude-code"}"#,
        "image-rm": #"{"action":"image-rm","image":"mine","confirm":"mine"}"#,
        "net-policy": #"{"action":"net-policy","sandbox":"a","allow":["example.com","*.example.org"],"deny":["evil.example"]}"#,
        "key-policy": #"{"action":"key-policy","sandbox":"a","policy":"strict"}"#,
        "key-rm": #"{"action":"key-rm","sandbox":"a","binding":"anthropic"}"#,
        "account-use": #"{"action":"account-use","sandbox":"a","account":"work"}"#,
        "account-default": #"{"action":"account-default","account":"none"}"#,
        "account-keepalive": #"{"action":"account-keepalive","enabled":true}"#,
        "account-verify": #"{"action":"account-verify","account":"work"}"#,
        // 617: read a key kept in 1Password, AWS or a command again (adding a source stays the CLI's).
        "account-refresh": #"{"action":"account-refresh","account":"work"}"#,
        "account-rm": #"{"action":"account-rm","account":"work","confirm":"work"}"#,
        // 641: rename a key and/or a setup token's plan (never its value).
        "account-edit": #"{"action":"account-edit","account":"work","newName":"team","plan":"pro"}"#,
        "onboard": #"{"action":"onboard","images":["claude-code","lab"]}"#,
        "prepare-cancel": #"{"action":"prepare-cancel","images":["pi"]}"#,
        "resources-rm": #"{"action":"resources-rm","ids":["cache:downloads","kernel:6.12.1-1","point:web/rp-1"]}"#,
        "resources-clean": #"{"action":"resources-clean"}"#,
        "resources-kernel": #"{"action":"resources-kernel","kernel":"kernel:6.12.1-1"}"#,
        "daemon-start": #"{"action":"daemon-start"}"#,
        "daemon-restart": #"{"action":"daemon-restart"}"#,
        // 596 (B7): Apple's container tool — start its services, install it (the page said what each does).
        "builder-start": #"{"action":"builder-start"}"#,
        "builder-install": #"{"action":"builder-install"}"#,
        // 599h: the tools layer again (the wizard's Retry).
        "tools-apply": #"{"action":"tools-apply","sandbox":"web"}"#,
        "session-end": #"{"action":"session-end","sandbox":"web","session":"codex"}"#,
        "session-restart": #"{"action":"session-restart","sandbox":"web","session":"codex","fresh":false}"#,
        "mac-session-end": #"{"action":"mac-session-end","session":"build","confirm":"build"}"#,
        "mac-session-restart": #"{"action":"mac-session-restart","session":"agent","confirm":"agent"}"#,
        // 683 M5: a fenced session's resume after a git stop, and its bridges switched live.
        "mac-session-resume": #"{"action":"mac-session-resume","session":"agent"}"#,
        "mac-session-bridges": #"{"action":"mac-session-bridges","session":"agent","openURL":false}"#,
        "mac-net-policy": #"{"action":"mac-net-policy","session":"agent","grant":["site:fonts.example-cdn.com"]}"#,
        // Remove an ended session on this Mac, and Remove all ended (the names the page showed) — this Mac's own browser only.
        "mac-session-forget": #"{"action":"mac-session-forget","session":"old"}"#,
        "mac-sessions-forget-ended": #"{"action":"mac-sessions-forget-ended","sessions":["old","older"]}"#,
        // 644: the Files panel's changes.
        "files-mkdir": #"{"action":"files-mkdir","sandbox":"web","path":"/workspace/src/new"}"#,
        "files-new": #"{"action":"files-new","sandbox":"web","path":"notes.md"}"#,
        "files-move": #"{"action":"files-move","sandbox":"web","path":"/workspace/a.md","to":"/workspace/docs/a.md"}"#,
        "files-rm": #"{"action":"files-rm","sandbox":"web","path":"/workspace/old","recursive":true,"confirm":"/workspace/old"}"#,
        "workspace-brief": #"{"action":"workspace-brief","workspace":"launch-video","brief":"Make it 45 seconds.\nKeep the logo.","ifBrief":"\#(String(repeating: "a", count: 64))"}"#,
        "workspace-adopt": #"{"action":"workspace-adopt","workspace":"launch-video","agent":"@mac/build","as":"builder"}"#,
        "workspace-new": #"{"action":"workspace-new","workspace":"gamma","brief":"The work in gamma.","adopt":["gamma"]}"#,
        "workspace-release": #"{"action":"workspace-release","workspace":"launch-video","agent":"builder"}"#,
        // The New workspace wizard's start — this Mac's own browser only; the daemon then requires the unfenced confirmation.
        "workspace-start": #"{"action":"workspace-start","workspace":"launch-video","actsAsYou":true}"#,
        // Agents / Bots — this Mac's own browser only, every one heldOnly (no token ever reaches a browser).
        "bot-new": #"{"action":"bot-new","name":"mira","agent":"claude-code","isolation":"fenced","deliver":"inbox","skills":["chat-manager"],"instructions":"Be brief.\nAnswer in the room."}"#,
        "bot-set": #"{"action":"bot-set","name":"mira","model":"sonnet","avatar":"🦊"}"#,
        "bot-retire": #"{"action":"bot-retire","name":"tmp1","confirm":"tmp1"}"#,
        "bot-adopt": #"{"action":"bot-adopt","name":"olda","agent":"codex","confirm":"olda"}"#,
        "bot-token": #"{"action":"bot-token","name":"mira","confirm":"mira"}"#,
        "worker-add": #"{"action":"worker-add","workspace":"launch-video","task":"Make the 15-second cut.","isolation":"vm","cpus":4,"memory":"4G","rooms":["review"]}"#,
        "worker-end": #"{"action":"worker-end","workspace":"launch-video","name":"bot4","confirm":"bot4"}"#,
        "workspace-stop": #"{"action":"workspace-stop","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#,
        "workspace-sleep": #"{"action":"workspace-sleep","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#,
        "workspace-wake": #"{"action":"workspace-wake","workspace":"launch-video","ifPlan":"0123456789abcdef","actsAsYou":true}"#,
        "workspace-finish": #"{"action":"workspace-finish","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#,
        "workspace-reopen": #"{"action":"workspace-reopen","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#,
        "workspace-archive": #"{"action":"workspace-archive","workspace":"launch-video","ifPlan":"0123456789abcdef","removeSandboxes":true,"keepTemplates":false,"confirm":"launch-video"}"#,
        "workspace-restore": #"{"action":"workspace-restore","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#,
        "workspace-delete": #"{"action":"workspace-delete","workspace":"launch-video","ifPlan":"0123456789abcdef","binFolders":true,"confirm":"launch-video"}"#,
        // Owner, 2026-10-23: Rename… (the sidebar's ⋯, the page's ⋯).
        "rename": #"{"action":"rename","sandbox":"web","newName":"website"}"#,
        // 669: a sandbox's own value of a per-sandbox setting, or "Follow the Mac" (clear).
        "sandbox-setting": #"{"action":"sandbox-setting","sandbox":"web","key":"approvals","value":"ask"}"#,
    ]

    /// 669: `sandbox-setting` — a per-sandbox key (closed list), a plain word or clear, nothing else; one sandbox-settings op.
    func testSandboxSetting() throws {
        let a = try decode(Self.samples["sandbox-setting"]!)
        XCTAssertEqual(a, .sandboxSetting(name: "web", key: "approvals", value: "ask"))
        XCTAssertEqual(a.hostRequest.op, .sandboxSettings)
        XCTAssertEqual(a.hostRequest.setting, "approvals")
        XCTAssertEqual(a.hostRequest.settingValue, .string("ask"))
        XCTAssertEqual(a.sandbox, "web")
        let clear = try decode(#"{"action":"sandbox-setting","sandbox":"web","key":"sandbox.clipboard","clear":true}"#)
        XCTAssertEqual(clear.hostRequest.clearSetting, true)
        XCTAssertNil(clear.hostRequest.settingValue)
        invalid(#"{"action":"sandbox-setting","sandbox":"web","key":"ui.theme","value":"dark"}"#)              // not per sandbox
        invalid(#"{"action":"sandbox-setting","sandbox":"web","key":"approvals"}"#)                          // a value or clear
        invalid(#"{"action":"sandbox-setting","sandbox":"web","key":"approvals","value":"ask","clear":true}"#)
        invalid(#"{"action":"sandbox-setting","sandbox":"web","key":"approvals","value":"a b"}"#)
        invalid(#"{"action":"sandbox-setting","sandbox":"web","key":"approvals","value":"ask","confirm":"web"}"#)
    }

    /// Owner, 2026-10-23: `rename` — two sandbox names by the rule, different, nothing else; no confirm (nothing is lost).
    func testRename() throws {
        let a = try decode(Self.samples["rename"]!)
        XCTAssertEqual(a, .rename(name: "web", newName: "website"))
        XCTAssertEqual(a.hostRequest.op, .rename)
        XCTAssertEqual(a.hostRequest.name, "web")
        XCTAssertEqual(a.hostRequest.newName, "website")
        XCTAssertEqual(a.sandbox, "web")
        XCTAssertNil(a.confirmationTarget)
        XCTAssertEqual(a.label, "rename web to website", "the page reads the new name from this label (core/operations.js)")
        XCTAssertNotEqual(a.dedupeKey, try decode(#"{"action":"rename","sandbox":"web","newName":"site"}"#).dedupeKey)
        invalid(#"{"action":"rename","sandbox":"web"}"#)                                       // the new name is required
        invalid(#"{"action":"rename","sandbox":"web","newName":"web"}"#)                       // a different name
        for bad in ["Web", "-web", "a b", "a_b", "", String(repeating: "a", count: 41)] {
            invalid(#"{"action":"rename","sandbox":"web","newName":"\#(bad)"}"#)
        }
        invalid(#"{"action":"rename","sandbox":"web","newName":5}"#)
        invalid(#"{"action":"rename","sandbox":"web","newName":"site","confirm":"web"}"#)      // not a field of rename
        invalid(#"{"action":"rename","sandbox":"web","newName":"site","folder":"/tmp"}"#)
    }

    /// 644: the file actions' fields, strictly.
    func testTheFileActions() throws {
        let mk = try decode(Self.samples["files-mkdir"]!)
        XCTAssertEqual(mk.hostRequest.filePath, "/workspace/src/new")
        XCTAssertEqual(mk.sandbox, "web")
        XCTAssertEqual(try decode(Self.samples["files-new"]!).hostRequest.filePath, "/workspace/notes.md", "relative: under /workspace")
        let mv = try decode(Self.samples["files-move"]!)
        XCTAssertEqual(mv.hostRequest.fileTarget, "/workspace/docs/a.md")
        let rm = try decode(Self.samples["files-rm"]!)
        XCTAssertEqual(rm.hostRequest.recursive, true)
        XCTAssertEqual(rm.confirmationTarget, "/workspace/old")
        XCTAssertNil(try decode(#"{"action":"files-rm","sandbox":"web","path":"/workspace/f","confirm":"/workspace/f"}"#).hostRequest.recursive)
        XCTAssertNotEqual(try decode(#"{"action":"files-mkdir","sandbox":"web","path":"a"}"#).dedupeKey,
                          try decode(#"{"action":"files-mkdir","sandbox":"web","path":"b"}"#).dedupeKey, "two folders made at once are two operations")
        invalid(#"{"action":"files-rm","sandbox":"web","path":"/workspace/old"}"#)                                  // destructive: confirm
        invalid(#"{"action":"files-rm","sandbox":"web","path":"/workspace/old","confirm":"/workspace/other"}"#)
        invalid(#"{"action":"files-mkdir","sandbox":"web","path":"/workspace"}"#)                                   // never the root
        invalid(#"{"action":"files-mkdir","sandbox":"web","path":"../etc/x"}"#)
        invalid(#"{"action":"files-mkdir","sandbox":"web","path":"/etc/x"}"#)
        invalid(#"{"action":"files-new","sandbox":"web","path":"a\u0001b"}"#)
        invalid(#"{"action":"files-move","sandbox":"web","path":"a"}"#)                                             // to is required
        invalid(#"{"action":"files-move","sandbox":"web","path":"a","to":"/workspace/a"}"#)
        invalid(#"{"action":"files-mkdir","sandbox":"web","path":"a","content":"x"}"#)                             // never a file's content
        invalid(#"{"action":"files-rm","sandbox":"web","path":"a","recursive":"yes","confirm":"/workspace/a"}"#)
    }

    /// Everything the web layer may send to the host — and, as important, what it may never.
    static let allowedOps: Set<HostOp> = [
        .filesMkdir, .filesNew, .filesMove, .filesRm,
        // Owner, 2026-10-23: a shut-down sandbox's new name (nothing is lost).
        .rename,
        // 669: a sandbox's own value of a per-sandbox setting, or Follow the Mac (doz config set|unset --sandbox).
        .sandboxSettings,
        // A workspace's brief from its page — exactly `doz workspace edit W --prompt-file F --if-brief SHA`.
        .workspaceEdit,
        // Filing a loose agent from This Mac's own browser — exactly `doz workspace adopt | new --adopt | release`.
        .workspaceAdopt, .workspaceNew, .workspaceRelease,
        // The New workspace wizard's Create and start, this Mac's own browser only — exactly `doz workspace start W` (+ the
        // confirmation an unfenced manager needs).
        .workspaceStart,
        // Agents / Bots from this Mac's own browser — exactly `doz bot new | set | retire | adopt | token --new`, each heldOnly.
        .botNew, .botSet, .botRetire, .botAdopt, .botToken,
        // A workspace's workers from this Mac's own browser — exactly `doz worker add | end`.
        .workerAdd, .workerEnd,
        // A workspace's lifecycle from this Mac's own browser — exactly `doz workspace stop | sleep | wake | finish | reopen |
        // archive | restore | delete`, each with the plan's sha the page showed.
        .workspaceStop, .workspaceSleep, .workspaceWake, .workspaceFinish, .workspaceReopen, .workspaceArchive, .workspaceRestore, .workspaceDelete,
        .create, .start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm, .openSession,
        .pointTake, .pointRevert, .pointFork, .pointRm, .pointSaveImage, .imageBake, .imageRm, .netPolicy,
        .keyPolicy, .keyRm, .accountUse, .accountDefault, .accountKeepalive, .accountVerify, .accountRefresh, .accountRemove,
        // 641: a key's name and plan (no secret in it).
        .accountEdit,
        .templateCreate, .duplicate, .onboard, .prepareCancel, .resourcesRemove, .resourcesClean, .resourcesKernel, .ping,
        // 596 (B7): consented by the person's click on a button that said what it does.
        .builderStart, .builderInstall,
        // 599h: set a sandbox's tools layer up again (it installs only what its settings already call for).
        .toolsApply,
        // 608: End session / Restart session (a running sandbox only; never a wake).
        .sessionEnd, .sessionRestart,
        // 683 M5: @mac only — a fenced session's resume after a git stop, its bridges (host-side switches, per event).
        .sessionResume, .sessionBridges,
        // @mac only, this Mac's own browser only: Remove / Remove all ended — exactly `doz sessions @mac --forget S | --forget-ended`.
        .sessionForget,
        // 594 W20: only as Restart host, which the data source refuses unless the host is OLDER.
        .hostStop,
    ]

    /// 641: Edit… — `account-edit` carries a new name and/or a setup token's plan, each by its rule; never a secret, never
    /// the Mac login, never nothing to change.
    func testAccountEditDecodesStrictly() throws {
        let a = try decode(Self.samples["account-edit"]!)
        XCTAssertEqual(a, .accountEdit("work", newName: "team", plan: "pro"))
        XCTAssertEqual(a.hostRequest.op, .accountEdit)
        XCTAssertEqual(a.hostRequest.account, "work")
        XCTAssertEqual(a.hostRequest.newName, "team")
        XCTAssertEqual(a.hostRequest.plan, "pro")
        XCTAssertNil(a.hostRequest.secret)
        XCTAssertNil(a.confirmationTarget, "nothing is lost: no confirmation")
        XCTAssertEqual(try decode(#"{"action":"account-edit","account":"work","plan":"max"}"#), .accountEdit("work", newName: nil, plan: "max"))
        XCTAssertEqual(try decode(#"{"action":"account-edit","account":"work","newName":"w2"}"#), .accountEdit("work", newName: "w2", plan: nil))
        XCTAssertNotEqual(a.dedupeKey, try decode(#"{"action":"account-edit","account":"work","newName":"w3"}"#).dedupeKey)
        invalid(#"{"action":"account-edit","account":"work"}"#)
        invalid(#"{"action":"account-edit","account":"work","newName":"work"}"#)
        invalid(#"{"action":"account-edit","account":"mac","newName":"mine"}"#)
        for bad in ["default", "none", "mac", "Bad", "-x", "a b", String(repeating: "a", count: 41)] {
            invalid(#"{"action":"account-edit","account":"work","newName":"\#(bad)"}"#)
        }
        invalid(#"{"action":"account-edit","account":"work","plan":"gold"}"#)
        invalid(#"{"action":"account-edit","account":"work","newName":"x2","secret":"sk-ant-api03-NOPE"}"#)
        invalid(#"{"action":"account-edit","account":"work","newName":5}"#)
    }

    /// 595: resources — ids by their rule, each once; no typed name (a plain confirmation: owner);
    /// never a dry-run flag or a path from the browser.
    func testResourceActionsDecodeStrictly() throws {
        let r = try decode(Self.samples["resources-rm"]!)
        XCTAssertEqual(r.hostRequest.op, .resourcesRemove)
        XCTAssertEqual(r.hostRequest.ids, ["cache:downloads", "kernel:6.12.1-1", "point:web/rp-1"])
        XCTAssertNil(r.hostRequest.dryRun, "an action deletes; the preview route is the dry run")
        XCTAssertNil(r.confirmationTarget)
        XCTAssertNil(r.sandbox)
        XCTAssertEqual(r.label, "delete 3 resources")
        XCTAssertNotEqual(r.dedupeKey, try decode(#"{"action":"resources-rm","ids":["logs"]}"#).dedupeKey)
        XCTAssertEqual(try decode(Self.samples["resources-clean"]!).hostRequest.op, .resourcesClean)
        XCTAssertEqual(try decode(Self.samples["resources-kernel"]!).hostRequest.kernel, "kernel:6.12.1-1")
        XCTAssertEqual(try decode(#"{"action":"resources-kernel","kernel":"pinned"}"#).hostRequest.kernel, "pinned")
        invalid(#"{"action":"resources-rm"}"#)
        invalid(#"{"action":"resources-rm","ids":[]}"#)
        invalid(#"{"action":"resources-rm","ids":"logs"}"#)
        invalid(#"{"action":"resources-rm","ids":["logs","logs"]}"#)
        invalid(#"{"action":"resources-rm","ids":["image:../../etc"]}"#)
        invalid(#"{"action":"resources-rm","ids":["/etc/passwd"]}"#)
        invalid(#"{"action":"resources-rm","ids":["stray:a b"]}"#)
        invalid(#"{"action":"resources-rm","ids":[1]}"#)
        invalid(#"{"action":"resources-rm","ids":["logs"],"dryRun":false}"#)
        invalid(#"{"action":"resources-rm","ids":["logs"],"confirm":"logs"}"#)
        let many = "[" + (0..<501).map { "\"stray:f\($0)\"" }.joined(separator: ",") + "]"
        invalid(#"{"action":"resources-rm","ids":"# + many + "}")
        invalid(#"{"action":"resources-clean","ids":["logs"]}"#)
        invalid(#"{"action":"resources-kernel"}"#)
        invalid(#"{"action":"resources-kernel","kernel":"/tmp/vmlinux"}"#)
        invalid(#"{"action":"resources-kernel","kernel":"image:pi"}"#)
        invalid(#"{"action":"resources-kernel","kernel":"kernel:../x"}"#)
    }

    /// 595: the preview's body — exactly {ids} or {clean: true}.
    func testResourcePreviewDecodesStrictly() throws {
        XCTAssertEqual(try WebResourcePreview.decode(Data(#"{"ids":["logs","initfs"]}"#.utf8)).hostRequest.ids, ["logs", "initfs"])
        let c = try WebResourcePreview.decode(Data(#"{"clean":true}"#.utf8))
        XCTAssertEqual(c.hostRequest.op, .resourcesClean)
        XCTAssertEqual(c.hostRequest.dryRun, true)
        XCTAssertEqual(try WebResourcePreview.decode(Data(#"{"ids":["logs"]}"#.utf8)).hostRequest.dryRun, true)
        for bad in [#"{}"#, #"[]"#, #"{"ids":[]}"#, #"{"clean":false}"#, #"{"clean":1}"#, #"{"clean":true,"ids":["logs"]}"#,
                    #"{"ids":["logs"],"dryRun":false}"#, #"{"ids":["../x"]}"#] {
            XCTAssertThrowsError(try WebResourcePreview.decode(Data(bad.utf8)), bad)
        }
    }

    /// 594 W20: "Restart host" — no fields; `host stop` + a start of this UI's build, refused by the
    /// data source when no host runs (647: any running host, not only an older one).
    func testRestartHostIsTheOnlyHostStopAndItIsGuarded() async throws {
        let a = try decode(Self.samples["daemon-restart"]!)
        XCTAssertEqual(a, .hostRestart)
        XCTAssertEqual(a.hostOp, .hostStop)
        XCTAssertNil(a.sandbox)
        XCTAssertEqual(a.label, "daemon-restart")
        invalid(#"{"action":"daemon-restart","sandbox":"a"}"#)
        invalid(#"{"action":"host-stop"}"#)
        XCTAssertTrue(WebOperations.summary(.hostRestart, .null).contains("hibernated"))
        // 594 W22: the stop's rows in the outcome, and each sandbox's line on the operation.
        let rows = [HostStopRow(name: "w1", phaseBefore: "running", phase: "hibernated", outcome: "hibernated", milliseconds: 400),
                    HostStopRow(name: "w2", phaseBefore: "running", phase: "off", outcome: "failed", milliseconds: 90, error: "boom")]
        let v = try JSONValue(encoding: WebHostRestart(stop: HostStopResult(sandboxes: rows, milliseconds: 500, version: "a"), host: nil))
        XCTAssertEqual(WebOperations.summary(.hostRestart, v),
                       "the daemon restarted — hibernated w1; they wake when used (w2: could not hibernate — shut down)")
        XCTAssertEqual(WebOperations.finishedLine(HostStopView.finished(rows[0])), "✓ hibernated w1 — 400 ms")
        XCTAssertEqual(WebOperations.finishedLine(HostStopView.finished(rows[1])),
                       "✗ hibernating w2 — boom — it was shut down instead (its disk is kept; start it again) (90 ms)")
        XCTAssertNil(WebOperations.finishedLine(HostStopView.started("w1")))
        // A store with no host: nothing to restart (and nothing is started).
        let dir = URL(fileURLWithPath: "/tmp/doz-hr-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozableStore(root: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = HostWebData(store: store, version: "0.12.0") { [] }
        do { _ = try await data.restartHost { _ in }; XCTFail("no daemon") } catch {
            XCTAssertTrue(HostError.from(error).message.contains("no daemon is running"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socket.path), "nothing started")
    }

    /// 594 W18: "Start host" — the host's `ping` (sent with autostart like every action), nothing more.
    func testStartHostIsAPingWithNoFields() throws {
        let a = try decode(Self.samples["daemon-start"]!)
        XCTAssertEqual(a, .hostStart)
        XCTAssertEqual(a.hostRequest.op, .ping)
        XCTAssertNil(a.sandbox)
        XCTAssertNil(a.confirmationTarget)
        XCTAssertEqual(a.label, "daemon-start")
        invalid(#"{"action":"daemon-start","sandbox":"a"}"#)
        invalid(#"{"action":"host-stop"}"#)
        XCTAssertEqual(WebOperations.summary(.hostStart, .null), "the daemon is running")
    }

    /// 594: onboard and prepare-cancel — built-in images only, each once; onboard never waits.
    func testOnboardingActionsDecodeStrictly() throws {
        let o = try decode(Self.samples["onboard"]!)
        XCTAssertEqual(o.hostRequest.op, .onboard)
        XCTAssertEqual(o.hostRequest.images, ["claude-code", "lab"])
        XCTAssertEqual(o.hostRequest.follow, false, "the preparation runs in the daemon; the action ends at once")
        XCTAssertEqual(o.hostRequest.requestedBy, "doz ui")
        XCTAssertEqual(try decode(#"{"action":"onboard"}"#).hostRequest.images, [], "no images: onboarding is recorded at once")
        XCTAssertNil(try decode(#"{"action":"prepare-cancel"}"#).hostRequest.images, "none named: every running one")
        XCTAssertEqual(try decode(Self.samples["prepare-cancel"]!).hostRequest.images, ["pi"])
        invalid(#"{"action":"onboard","images":["ubuntu"]}"#)
        invalid(#"{"action":"onboard","images":["pi","pi"]}"#)
        invalid(#"{"action":"onboard","images":"pi"}"#)
        invalid(#"{"action":"onboard","images":["pi"],"follow":true}"#)
        invalid(#"{"action":"onboard","images":["lab","pi","claude-code","lab"]}"#)
        invalid(#"{"action":"prepare-cancel","images":[1]}"#)
    }

    /// 593: templates and duplicates — strict, and each field mapped to the host's request.
    func testTemplatesAndDuplicatesDecodeStrictly() throws {
        let t = try decode(Self.samples["template-create"]!)
        XCTAssertEqual(t.hostRequest.op, .templateCreate)
        XCTAssertEqual(t.hostRequest.image, "my-tpl")
        XCTAssertNil(t.hostRequest.point, "no point: the current disk")
        XCTAssertNil(t.confirmationTarget)
        let d = try decode(Self.samples["duplicate"]!)
        XCTAssertEqual(d.hostRequest.newName, "a2")
        let tmp = "/private/tmp"                                        // 594: realpath (the link /tmp resolved)
        XCTAssertEqual(d.hostRequest.duplicate, DuplicateOptions(folder: tmp, cpus: 4, memoryMiB: 2048, network: "locked", account: "none", copyState: true))
        XCTAssertEqual(try decode(#"{"action":"duplicate","sandbox":"a","newName":"b"}"#).hostRequest.duplicate, DuplicateOptions(),
                       "nothing given: the source's everything, a fresh state disk")
        XCTAssertNil(try decode(#"{"action":"duplicate","sandbox":"a","newName":"b","copyState":false}"#).hostRequest.duplicate?.copyState)
        XCTAssertNotEqual(try decode(#"{"action":"duplicate","sandbox":"a","newName":"b"}"#).dedupeKey,
                          try decode(#"{"action":"duplicate","sandbox":"a","newName":"c"}"#).dedupeKey, "two duplicates to two names may run together")
        invalid(#"{"action":"template-create","sandbox":"a"}"#)                                  // no name
        invalid(#"{"action":"template-create","sandbox":"a","image":"Bad Name"}"#)
        invalid(#"{"action":"template-create","sandbox":"a","image":"lab"}"#)                    // a built-in's name
        invalid(#"{"action":"template-create","sandbox":"a","image":"t","state":true}"#)         // never the state disk
        invalid(#"{"action":"duplicate","sandbox":"a"}"#)                                        // no new name
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"a"}"#)                          // onto itself
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"B"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","folder":"relative"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","folder":"/w","isolated":true}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","copyState":"yes"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","copyState":1}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","cpus":0}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","network":"host"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","image":"lab"}"#)           // not a field of duplicate
    }

    func testEveryActionIsExactlyOneAllowedHostOp() throws {
        XCTAssertEqual(Set(Self.samples.keys), Set(WebAction.actionNames), "a sample for every action, and no action without one")
        var ops: [HostOp] = []
        var places: [String] = []
        for (name, json) in Self.samples {
            let a = try decode(json)
            XCTAssertTrue(Self.allowedOps.contains(a.hostOp), "\(name) → \(a.hostOp)")
            XCTAssertEqual(a.hostRequest.op, a.hostOp)
            XCTAssertEqual(a.hostRequest.v, HostProtocol.version)
            XCTAssertNil(a.hostRequest.secret, "no action ever carries a secret")
            ops.append(a.hostOp)
            // The sessions on this Mac have their own two actions: the same HostOp, on the place @mac.
            // Remove and Remove all ended are both `session-forget`: one names a session, the other the list the page showed.
            places.append(a.hostOp.rawValue + (a.isMacSession || a.isMacNet || a.isMacForget ? " @mac" : "") + (a.hostRequest.sessions != nil ? " (the list)" : ""))
            XCTAssertEqual(a.isMacSession || a.isMacNet || a.isMacForget, a.hostRequest.name == "@mac", "\(name): @mac only through its own actions")
        }
        XCTAssertEqual(places.count, Set(places).count, "one action per HostOp (and place)")
        XCTAssertEqual(Set(Self.samples.compactMap { (try? decode($0.value))?.isMacSession == true ? (try? decode($0.value))?.hostOp : nil }),
                       [.sessionEnd, .sessionRestart, .sessionResume, .sessionBridges],
                       "this Mac: end, restart, resume after a git stop, the bridges (683 M5) — never an open")
        // 594 W18: `ping` is reachable — as "Start host" (a status read that starts a host the way
        // every action does); `host stop` only as W20's guarded Restart host.
        XCTAssertEqual(Self.samples.filter { (try? decode($0.value).hostOp) == .hostStop }.map(\.key), ["daemon-restart"])
        for forbidden: HostOp in [.exec, .attach, .keySet, .accountAdd, .events] {
            XCTAssertFalse(ops.contains(forbidden), "\(forbidden) must never be reachable from the browser")
        }
        XCTAssertEqual(WebAction.lifecycleOps["hibernate"], .hibernate)
        // Workspaces, Agents / Bots and workers are read in the dashboard (WebWorkspaceReads, WebBotReads). Four workspace
        // operations are actions: `workspace-edit` only through `workspace-brief` (the brief, nothing else), and filing —
        // adopt, new with one agent, release (this Mac's own browser only); the start; the eight lifecycle verbs (this Mac's
        // own browser only); and the five bot changes below.
        XCTAssertEqual(Set(Self.samples.filter { (try? decode($0.value).hostOp)?.rawValue.hasPrefix("workspace-") == true }.map(\.key)),
                       ["workspace-brief", "workspace-adopt", "workspace-new", "workspace-release", "workspace-start", "workspace-stop", "workspace-sleep",
                        "workspace-wake", "workspace-finish", "workspace-reopen", "workspace-archive", "workspace-restore", "workspace-delete"])
        XCTAssertEqual(Set(ops.filter { ["workspace-", "worker-"].contains(where: $0.rawValue.hasPrefix) }),
                       [.workspaceEdit, .workspaceAdopt, .workspaceNew, .workspaceRelease, .workspaceStart, .workerAdd, .workerEnd, .workspaceStop,
                        .workspaceSleep, .workspaceWake, .workspaceFinish, .workspaceReopen, .workspaceArchive, .workspaceRestore, .workspaceDelete])
        XCTAssertEqual(Set(Self.samples.compactMap { (try? decode($0.value))?.isLifecycle == true ? $0.key : nil }),
                       Set(WorkspaceVerb.allCases.map { "workspace-" + $0.rawValue }))
        XCTAssertEqual(Set(Self.samples.compactMap { (try? decode($0.value))?.isWorker == true ? $0.key : nil }), ["worker-add", "worker-end"])
        // The bot- actions are exactly new, set, retire, adopt and token — never bot-ls or bot-show (those are reads); every
        // one heldOnly, this Mac's own browser only.
        XCTAssertEqual(Set(ops.filter { $0.rawValue.hasPrefix("bot-") }), [.botNew, .botSet, .botRetire, .botAdopt, .botToken])
        XCTAssertFalse(ops.contains(.botList) || ops.contains(.botShow))
        for (name, json) in Self.samples where name.hasPrefix("bot-") {
            let a = try decode(json)
            XCTAssertTrue(a.isBot, name)
            XCTAssertEqual(a.hostRequest.botRequest?.heldOnly, true, "\(name): heldOnly")
            XCTAssertNil(a.hostRequest.secret)
            XCTAssertNil(a.sandbox)
        }
        XCTAssertEqual(Set(Self.samples.compactMap { (try? decode($0.value))?.isBot == true ? $0.key : nil }),
                       ["bot-new", "bot-set", "bot-retire", "bot-adopt", "bot-token"])
        XCTAssertEqual(Set(Self.samples.compactMap { (try? decode($0.value))?.isFiling == true ? $0.key : nil }),
                       ["workspace-adopt", "workspace-new", "workspace-release"])
        XCTAssertEqual(Set(Self.samples.compactMap { (try? decode($0.value))?.isStarting == true ? $0.key : nil }), ["workspace-start"])
        // No rename for any browser; the plans and worker-ls are reads.
        for op: HostOp in [.workspaceRename, .workspacePlan, .workerPlan, .workspaceLifecyclePlan, .workerList] {
            XCTAssertFalse(ops.contains(op), "\(op.rawValue) is not an action")
        }
        // Your Macs are read (WebMacReads) and changed only from the CLI: no macs-* operation is an action.
        XCTAssertFalse(ops.contains { $0.rawValue.hasPrefix("macs-") }, "Your Macs are not changed from the browser")
        XCTAssertFalse(WebAction.actionNames.contains { $0.hasPrefix("mac-") && !$0.hasPrefix("mac-session-") && $0 != "mac-net-policy" && $0 != "mac-sessions-forget-ended" }, "no action for Your Macs")
    }

    /// The eight lifecycle actions: each exactly the CLI's HostOp, its fields strict (`ifPlan` required, 16 hex), the flags
    /// only where the CLI has them, archive and delete confirmed with the typed name (and the daemon checks it again —
    /// `confirmRequired`), a wake's "acts as you" carried as `unfencedConfirmed`.
    /// `mac-net-policy` is exactly `net-policy` with `@mac` and the session — `doz net allow @mac --session S site:HOST` —
    /// `site:` grants only (never a permission, a revoke, a deny, a preset or a `host:` port), this Mac's own browser only.
    /// Remove / Remove all ended: each exactly `session-forget` on @mac — one session, or the names shown (never "every ended
    /// one": the daemon acts on what the page showed); strictly decoded. And `mac-session-end` ends a RUNNING session only.
    func testTheForgetActions() throws {
        let one = try decode(Self.samples["mac-session-forget"]!)
        var want = HostRequest(.sessionForget, name: "@mac")
        want.session = "old"
        XCTAssertEqual(one.hostRequest, want)
        XCTAssertTrue(one.isMacForget)
        XCTAssertFalse(one.isMacSession, "decided as this Mac's own, never by serve.mac_sessions")
        XCTAssertNil(one.sandbox)
        let all = try decode(Self.samples["mac-sessions-forget-ended"]!)
        want = HostRequest(.sessionForget, name: "@mac")
        want.sessions = ["old", "older"]
        XCTAssertEqual(all.hostRequest, want)
        XCTAssertNil(all.hostRequest.forgetEnded, "never every ended one: only the names shown")
        XCTAssertTrue(all.isMacForget)
        for bad in [#"{"action":"mac-session-forget"}"#,
                    #"{"action":"mac-session-forget","session":"../x"}"#,
                    #"{"action":"mac-session-forget","session":"old","sessions":["a"]}"#,
                    #"{"action":"mac-sessions-forget-ended","sessions":[]}"#,
                    #"{"action":"mac-sessions-forget-ended","sessions":["a","a"]}"#,
                    #"{"action":"mac-sessions-forget-ended","sessions":["a"],"ended":true}"#,
                    #"{"action":"mac-sessions-forget-ended","sessions":["a"],"forgetEnded":true}"#,
                    #"{"action":"mac-sessions-forget-ended","sessions":"a"}"#,
                    #"{"action":"mac-sessions-forget-ended","sandbox":"web","sessions":["a"]}"#] {
            XCTAssertThrowsError(try decode(bad), bad)
        }
        let end = try decode(Self.samples["mac-session-end"]!)
        XCTAssertEqual(end.hostRequest.onlyRunning, true, "the dashboard's End never forgets an ended session")
    }

    func testTheMacNetPolicyIsExactlyNetPolicyWithSitesOnly() throws {
        let a = try decode(Self.samples["mac-net-policy"]!)
        guard case .macNetPolicy(let s, let g) = a else { return XCTFail("mac-net-policy") }
        XCTAssertEqual(s, "agent")
        XCTAssertEqual(g, ["site:fonts.example-cdn.com"])
        XCTAssertTrue(a.isMacNet)
        XCTAssertFalse(a.isMacSession, "decided as this Mac's own, never by serve.mac_sessions")
        var want = HostRequest(.netPolicy, name: "@mac")
        want.session = "agent"
        want.grant = ["site:fonts.example-cdn.com"]
        XCTAssertEqual(a.hostRequest, want)
        XCTAssertNil(a.sandbox)
        XCTAssertNil(a.confirmationTarget)
        XCTAssertEqual(try decode(#"{"action":"mac-net-policy","session":"agent","grant":["site:api.example.com:8443"]}"#).hostRequest.grant, ["site:api.example.com:8443"])
        // Two sites at once are two operations; the same twice is one.
        XCTAssertNotEqual(a.dedupeKey, try decode(#"{"action":"mac-net-policy","session":"agent","grant":["site:b.example"]}"#).dedupeKey)
        for bad in [#"{"action":"mac-net-policy","session":"agent"}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":[]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["web"]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["install:python"]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["host:8780"]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["site:x.example"],"revoke":["site:y.example"]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["site:x.example"],"deny":["y.example"]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["site:x.example"],"preset":"open"}"#,
                    #"{"action":"mac-net-policy","sandbox":"a","grant":["site:x.example"]}"#,
                    #"{"action":"mac-net-policy","session":"../x","grant":["site:x.example"]}"#,
                    #"{"action":"mac-net-policy","session":"agent","grant":["site:a","site:b","site:c","site:d","site:e","site:f","site:g","site:h","site:i"]}"#] {
            XCTAssertThrowsError(try decode(bad), bad)
        }
    }

    func testTheLifecycleActions() throws {
        let archive = try decode(Self.samples["workspace-archive"]!)
        guard case .workspaceLifecycle(.archive, let w) = archive else { return XCTFail("archive") }
        XCTAssertEqual(w.name, "launch-video")
        XCTAssertEqual(w.removeSandboxes, true)
        XCTAssertEqual(w.keepTemplates, false)
        XCTAssertEqual(w.confirm, "launch-video")
        let r = archive.hostRequest
        XCTAssertEqual(r.op, .workspaceArchive)
        XCTAssertEqual(r.workspaceRequest?.confirmRequired, true, "the daemon checks the typed name")
        XCTAssertEqual(r.workspaceRequest?.ifPlan, "0123456789abcdef")
        XCTAssertEqual(archive.confirmationTarget, "launch-video")
        XCTAssertNil(archive.sandbox)
        let wake = try decode(Self.samples["workspace-wake"]!)
        XCTAssertEqual(wake.hostRequest.workspaceRequest?.unfencedConfirmed, true)
        XCTAssertEqual(wake.hostRequest.workspaceRequest?.confirmRequired, true)
        XCTAssertNil(wake.confirmationTarget)
        // The typed name: missing or wrong → 400 before anything; the plan's sha required.
        for bad in [#"{"action":"workspace-delete","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#,
                    #"{"action":"workspace-delete","workspace":"launch-video","ifPlan":"0123456789abcdef","confirm":"launch"}"#,
                    #"{"action":"workspace-sleep","workspace":"launch-video"}"#,
                    #"{"action":"workspace-sleep","workspace":"launch-video","ifPlan":"XYZ"}"#,
                    #"{"action":"workspace-sleep","workspace":"Launch","ifPlan":"0123456789abcdef"}"#,
                    // Flags only where the CLI has them.
                    #"{"action":"workspace-sleep","workspace":"launch-video","ifPlan":"0123456789abcdef","removeSandboxes":true}"#,
                    #"{"action":"workspace-finish","workspace":"launch-video","ifPlan":"0123456789abcdef","binFolders":true}"#,
                    #"{"action":"workspace-archive","workspace":"launch-video","ifPlan":"0123456789abcdef","binFolders":true,"confirm":"launch-video"}"#,
                    #"{"action":"workspace-wake","workspace":"launch-video","ifPlan":"0123456789abcdef","confirm":"launch-video"}"#,
                    #"{"action":"workspace-rename","workspace":"launch-video","ifPlan":"0123456789abcdef"}"#] {
            XCTAssertThrowsError(try decode(bad), bad)
        }
        // Two verbs of one workspace at once are two operations; one verb twice is one.
        XCTAssertNotEqual(try decode(Self.samples["workspace-sleep"]!).dedupeKey, try decode(Self.samples["workspace-wake"]!).dedupeKey)
        XCTAssertEqual(try decode(Self.samples["workspace-sleep"]!).label, "sleep launch-video")
    }

    /// The five bot actions: each exactly the CLI's HostOp with heldOnly, strictly decoded by the CLI's rules; elsewhere refused
    /// with its command; retire, adopt and token confirmed with the name; two bots are two operations.
    func testTheBotActions() throws {
        let new = try decode(Self.samples["bot-new"]!)
        var want = BotRequest(name: "mira")
        want.agent = "claude-code"; want.isolation = "fenced"; want.deliver = "inbox"; want.skills = ["chat-manager"]
        want.instructions = "Be brief.\nAnswer in the room."
        XCTAssertEqual(new, .botNew(want))
        want.heldOnly = true
        XCTAssertEqual(new.hostRequest.botRequest, want, "exactly doz bot new's request, with heldOnly")
        XCTAssertEqual(new.hostRequest.op, .botNew)
        XCTAssertNil(new.hostRequest.name, "the bot travels in its own request")
        XCTAssertEqual(new.label, "make Agent / Bot mira")
        XCTAssertNil(new.confirmationTarget, "a new bot: no confirmation")
        let set = try decode(Self.samples["bot-set"]!)
        XCTAssertEqual(set.hostRequest.botRequest?.model, "sonnet")
        XCTAssertEqual(set.hostRequest.botRequest?.avatar, "🦊")
        XCTAssertNil(set.hostRequest.botRequest?.isolation)
        XCTAssertEqual(try decode(Self.samples["bot-retire"]!), .botRetire(name: "tmp1"))
        XCTAssertEqual(try decode(Self.samples["bot-token"]!).hostRequest.op, .botToken)
        let adopt = try decode(Self.samples["bot-adopt"]!)
        XCTAssertEqual(adopt.hostRequest.botRequest?.agent, "codex")
        XCTAssertEqual(adopt.confirmationTarget, "olda")
        // Unfenced only as an explicit choice; the isolation of a new bot is required (never assumed by the page).
        XCTAssertEqual(try decode(#"{"action":"bot-new","name":"otto","agent":"codex","isolation":"unfenced"}"#).hostRequest.botRequest?.isolation, "unfenced")
        invalid(#"{"action":"bot-new","name":"otto","agent":"codex"}"#)
        // Elsewhere: refused at decode, with the terminal's command (the token is shown once, in a terminal only).
        for (json, cmd) in [(#"{"action":"bot-new","name":"far","agent":"codex","isolation":"elsewhere"}"#,
                             "doz bot new far --agent codex --isolation elsewhere --to-file F"),
                            (#"{"action":"bot-set","name":"mira","isolation":"elsewhere"}"#, "doz bot set mira --isolation elsewhere --to-file F"),
                            (#"{"action":"bot-adopt","name":"olda","agent":"codex","isolation":"elsewhere","confirm":"olda"}"#,
                             "doz bot adopt olda --agent codex --isolation elsewhere --to-file F")] {
            XCTAssertThrowsError(try decode(json)) { e in
                XCTAssertTrue((e as? WebAction.Invalid)?.message.hasSuffix(cmd) == true, "\(e)")
            }
        }
        // Confirmation: required, and the name exactly.
        for verb in ["bot-retire", "bot-token"] {
            invalid(#"{"action":"\#(verb)","name":"mira"}"#)
            invalid(#"{"action":"\#(verb)","name":"mira","confirm":"otto"}"#)
        }
        invalid(#"{"action":"bot-adopt","name":"olda","agent":"codex"}"#)
        // Unknown fields, a token, a bad name, an unknown agent, a bad model, skills, control characters, oversized text.
        for extra in [#""token":"dzc_x""#, #""secret":"x""#, #""oneTimeToken":"x""#, #""toFile":"/tmp/f""#, #""ceiling":"vm""#, #""retired":true"#] {
            invalid(#"{"action":"bot-new","name":"otto","agent":"codex","isolation":"fenced",\#(extra)}"#)
            invalid(#"{"action":"bot-set","name":"otto","model":"m",\#(extra)}"#)
        }
        invalid(#"{"action":"bot-set","name":"otto"}"#)                                                     // nothing to change
        for bad in ["Mira", "chat", "-x", "a_b", "~new", String(repeating: "a", count: 41)] {
            invalid(#"{"action":"bot-new","name":"\#(bad)","agent":"codex","isolation":"fenced"}"#)
            invalid(#"{"action":"bot-retire","name":"\#(bad)","confirm":"\#(bad)"}"#)
        }
        invalid(#"{"action":"bot-new","name":"otto","agent":"no-such-agent-x","isolation":"fenced"}"#)
        invalid(#"{"action":"bot-new","name":"otto","agent":"codex","isolation":"cloud"}"#)
        invalid(#"{"action":"bot-set","name":"otto","model":"two words"}"#)
        invalid(#"{"action":"bot-set","name":"otto","skills":["Bad Skill"]}"#)
        invalid(#"{"action":"bot-set","name":"otto","skills":"chat-manager"}"#)
        invalid(#"{"action":"bot-set","name":"otto","avatar":"a\nb"}"#)
        invalid(#"{"action":"bot-set","name":"otto","deliver":"email"}"#)
        invalid(#"{"action":"bot-set","name":"otto","session":"../x"}"#)
        invalid(#"{"action":"bot-set","name":"otto","account":"Bad Account"}"#)
        invalid(#"{"action":"bot-set","name":"otto","instructions":"a\u0000b"}"#)
        invalid(#"{"action":"bot-set","name":"otto","instructions":"\#(String(repeating: "x", count: (256 << 10) + 1))"}"#)
        XCTAssertEqual(try decode(#"{"action":"bot-set","name":"otto","instructions":"a\tb\r\nc"}"#).hostRequest.botRequest?.instructions, "a\tb\r\nc")
        XCTAssertEqual(try decode(#"{"action":"bot-set","name":"otto","account":"mac"}"#).hostRequest.botRequest?.account, "mac")
        // Two bots at once are two operations; the same bot twice is one.
        let k1 = try decode(#"{"action":"bot-token","name":"mira","confirm":"mira"}"#).dedupeKey
        XCTAssertNotEqual(k1, try decode(#"{"action":"bot-token","name":"otto","confirm":"otto"}"#).dedupeKey)
        XCTAssertEqual(k1, "bot-token|bot:mira")
        XCTAssertNotEqual(try decode(Self.samples["bot-set"]!).dedupeKey, try decode(#"{"action":"bot-set","name":"otto","model":"m"}"#).dedupeKey)
    }

    /// A bot change's line never carries a token: only the fingerprint; a one-time token from an older daemon is dropped
    /// unread, and the line says to make another in a terminal.
    func testABotChangesLineNeverCarriesAToken() throws {
        let t = Date(timeIntervalSince1970: 0)
        let rec = BotRecord(name: "far", createdAt: t, agent: "codex", isolation: BotIsolation(default: "elsewhere"), kind: "agent",
                            token: BotTokenState(keeper: "elsewhere", fingerprint: "0123456789ab", at: t))
        let token = "dzc_" + String(repeating: "Z", count: 40)
        let v = try JSONValue(encoding: BotChange(bot: BotDetail(rec, inChat: true, workspaces: [], manages: []), oneTimeToken: token))
        let line = WebOperations.summary(.botToken(name: "far"), v)
        XCTAssertFalse(line.contains(token) || line.contains("dzc_") || line.contains("ZZZZ"), line)
        XCTAssertTrue(line.contains("fp 0123456789ab"), line)
        XCTAssertTrue(line.contains("a new token was made but is never shown here; make another in a terminal"), line)
        let held = BotRecord(name: "mira", createdAt: t, agent: "claude-code", isolation: BotIsolation(default: "fenced"), kind: "claude-session",
                             token: BotTokenState(keeper: "dozable", fingerprint: "3f9a01b2c3c2", at: t))
        var d = BotDetail(held, inChat: true, workspaces: ["demo"], manages: ["demo"],
                          notes: ["mira runs in demo: its instructions apply from its next session; demo's room is told"])
        d.running = "demo"
        let made = WebOperations.summary(.botSet(BotRequest(name: "mira")), try JSONValue(encoding: BotChange(bot: d)))
        XCTAssertEqual(made, "changed mira — mira runs in demo: its instructions apply from its next session; demo's room is told")
        XCTAssertEqual(WebOperations.summary(.botNew(BotRequest(name: "mira")), try JSONValue(encoding: BotChange(bot: d))),
                       "made the Agent / Bot mira — held by Dozable · fp 3f9a01b2c3c2")
    }

    /// `workspace-brief` is exactly `workspace-edit` with the name, the brief and `ifBrief` — strictly decoded: nothing
    /// else of an edit (references, folders, manager, room) is taken; the sha256 is required and well-formed.
    func testTheWorkspaceBrief() throws {
        let a = try decode(Self.samples["workspace-brief"]!)
        let r = a.hostRequest
        XCTAssertEqual(r.op, .workspaceEdit)
        XCTAssertNil(r.name, "the workspace travels in its own request, as the CLI sends it")
        var want = WorkspaceRequest(name: "launch-video")
        want.brief = "Make it 45 seconds.\nKeep the logo."
        want.ifBrief = String(repeating: "a", count: 64)
        XCTAssertEqual(r.workspaceRequest, want, "exactly the CLI's doz workspace edit W --prompt-file F --if-brief SHA")
        XCTAssertNil(a.sandbox)
        XCTAssertTrue(a.isWorkspace)
        XCTAssertFalse(a.isMacSession)
        XCTAssertNil(a.confirmationTarget)
        XCTAssertEqual(a.label, "edit the brief of launch-video")
        XCTAssertNotEqual(a.dedupeKey, try decode(Self.samples["workspace-brief"]!.replacingOccurrences(of: "launch-video", with: "other")).dedupeKey,
                          "two workspaces' edits are two operations")
        let sha = String(repeating: "a", count: 64)
        for extra in [#""addRefs":["https://x.example"]"#, #""refs":[]"#, #""folders":[]"#, #""manager":"mira""#, #""makeRoom":true"#,
                      #""noManager":true"#, #""sandbox":"a""#, #""name":"launch-video""#] {
            invalid(#"{"action":"workspace-brief","workspace":"w","brief":"x",\#(extra),"ifBrief":"\#(sha)"}"#)
        }
        invalid(#"{"action":"workspace-brief","workspace":"w","brief":"x"}"#)                                  // ifBrief required
        invalid(#"{"action":"workspace-brief","workspace":"w","brief":"x","ifBrief":"ABC"}"#)
        invalid(#"{"action":"workspace-brief","workspace":"w","brief":"x","ifBrief":"\#(sha.uppercased())"}"#)
        invalid(#"{"action":"workspace-brief","workspace":"W_x","brief":"x","ifBrief":"\#(sha)"}"#)
        invalid(#"{"action":"workspace-brief","brief":"x","ifBrief":"\#(sha)"}"#)
        invalid(#"{"action":"workspace-brief","workspace":"w","brief":"  \n ","ifBrief":"\#(sha)"}"#)            // blank
        invalid(#"{"action":"workspace-brief","workspace":"w","brief":"a\u0000b","ifBrief":"\#(sha)"}"#)         // a control character
        invalid(#"{"action":"workspace-brief","workspace":"w","brief":7,"ifBrief":"\#(sha)"}"#)
        XCTAssertEqual(try decode(#"{"action":"workspace-brief","workspace":"w","brief":"a\tb\r\nc","ifBrief":"\#(sha)"}"#).hostRequest.workspaceRequest?.brief,
                       "a\tb\r\nc", "lines and tabs are text")
        // Another computer: only with serve.chat = write; the Mac's own browser always.
        XCTAssertNil(WebExposure.decideWorkspaceAction(.mac, .off))
        XCTAssertEqual(WebExposure.decideWorkspaceAction(.remote(secure: true), .off), .briefRemote)
        XCTAssertEqual(WebExposure.decideWorkspaceAction(.remote(secure: true), .read), .chatReadOnly)
        XCTAssertNil(WebExposure.decideWorkspaceAction(.remote(secure: false), .write))
        // Its line for the page.
        var flags = WorkspaceFlags()
        flags.startedAt = Date()
        let t = Date(timeIntervalSince1970: 0)
        let detail = { (f: WorkspaceFlags, notes: [String]?) in
            try JSONValue(encoding: WorkspaceDetail(name: "launch-video", state: "idle", driver: "you", createdAt: t,
                                                    brief: WorkspaceBrief(sha256: sha, bytes: 1, updatedAt: t), folders: [], rooms: [], agents: [],
                                                    defaults: WorkspaceDefaults(), flags: f, origin: WorkspaceOrigin(), notes: notes))
        }
        XCTAssertEqual(WebOperations.summary(a, try detail(flags, nil)), "edited the brief of launch-video — announced in its room")
        XCTAssertEqual(WebOperations.summary(a, try detail(WorkspaceFlags(), nil)), "edited the brief of launch-video")
        XCTAssertEqual(WebOperations.summary(a, try detail(flags, ["not announced: chat is off"])), "edited the brief of launch-video — not announced: chat is off")
    }

    /// Filing: each exactly the CLI's request, strictly decoded — `new` takes exactly one agent and nothing of a folder,
    /// reference, room or manager; an agent is a sandbox's name or `@mac/SESSION` (never a bare `@mac`); `as` by the agent
    /// rule; the dedupe key names the agent. Another computer gets none of them, whatever its serve settings.
    /// The New workspace wizard's two actions: `workspace-new` with every field the CLI takes (exactly its request), and
    /// `workspace-start` (exactly `doz workspace start W`, plus the confirmation an unfenced manager needs). Strict.
    /// The two worker actions: each exactly the CLI's HostOp, strictly decoded by the CLI's rules; an unfenced worker only with
    /// `confirm: "unfenced"` (never otherwise), an end confirmed with its name and never `--rm`; a task over 15 KiB refused;
    /// two workers added at once are two operations, the same one twice is one.
    func testTheWorkerActions() throws {
        let a = try decode(Self.samples["worker-add"]!)
        var want = WorkerRequest(workspace: "launch-video")
        want.task = "Make the 15-second cut."
        want.isolation = "vm"
        want.cpus = 4
        want.memory = "4G"
        want.rooms = ["review"]
        XCTAssertEqual(a.hostRequest.op, .workerAdd)
        XCTAssertEqual(a.hostRequest.workerRequest, want, "exactly what doz worker add sends")
        XCTAssertTrue(a.isWorker)
        XCTAssertNil(a.sandbox)
        XCTAssertNil(a.confirmationTarget)
        XCTAssertEqual(a.label, "add a worker to launch-video")
        let e = try decode(Self.samples["worker-end"]!)
        XCTAssertEqual(e.hostRequest.op, .workerEnd)
        XCTAssertEqual(e.hostRequest.workerRequest, WorkerRequest(workspace: "launch-video", name: "bot4"), "never --rm")
        XCTAssertEqual(e.confirmationTarget, "bot4")
        XCTAssertEqual(e.label, "end bot4 in launch-video")
        // Every field the CLI takes, by its rules.
        let full = try decode(#"{"action":"worker-add","workspace":"w","name":"carl","task":"one\ntwo\tthree","agent":"codex","isolation":"fenced","session":"w-carl","allowTools":["Edit","Bash(git status:*)"]}"#)
        XCTAssertEqual(full.hostRequest.workerRequest?.allowTools, ["Edit", "Bash(git status:*)"])
        XCTAssertEqual(full.hostRequest.workerRequest?.task, "one\ntwo\tthree")
        XCTAssertEqual(try decode(#"{"action":"worker-add","workspace":"w","task":"x","fromBot":"otto"}"#).hostRequest.workerRequest?.fromBot, "otto")
        XCTAssertEqual(try decode(#"{"action":"worker-add","workspace":"w","task":"x","sandbox":"wsa"}"#).hostRequest.workerRequest?.sandbox, "wsa")
        // Unfenced: only with the tick, and the tick only with unfenced.
        invalid(#"{"action":"worker-add","workspace":"w","task":"x","isolation":"unfenced"}"#, "unfenced without the tick")
        invalid(#"{"action":"worker-add","workspace":"w","task":"x","isolation":"unfenced","confirm":"yes"}"#, "the wrong word")
        invalid(#"{"action":"worker-add","workspace":"w","task":"x","confirm":"unfenced"}"#, "the tick without unfenced")
        let u = try decode(#"{"action":"worker-add","workspace":"w","task":"x","isolation":"unfenced","confirm":"unfenced"}"#)
        XCTAssertEqual(u.hostRequest.workerRequest?.isolation, "unfenced")
        XCTAssertEqual(u.confirmationTarget, "unfenced")
        // An end: its name, ticked; never --rm.
        invalid(#"{"action":"worker-end","workspace":"w","name":"bot1"}"#, "no confirmation")
        invalid(#"{"action":"worker-end","workspace":"w","name":"bot1","confirm":"bot2"}"#, "another name")
        invalid(#"{"action":"worker-end","workspace":"w","name":"bot1","confirm":"bot1","rm":true}"#, "--rm")
        // The strict field table.
        let base = #"{"action":"worker-add","workspace":"w","task":"x""#
        let manyRooms = (0..<9).map { "\"r\($0)\"" }.joined(separator: ",")
        for (extra, why) in [
            (#""unknown":1"#, "an unknown field"), (#""token":"dzc_x""#, "a token"), (#""all":true"#, "ls's field"), (#""rm":true"#, "end's field"),
            (#""agent":"pi""#, "another program"), (#""isolation":"elsewhere""#, "elsewhere"), (#""name":"Carl""#, "a name off the rule"),
            (#""fromBot":"Otto""#, "a bot off the rule"), (#""sandbox":"Bad Box""#, "a bad sandbox"), (#""session":".x""#, "a bad session"),
            (#""cpus":0"#, "no CPUs"), (#""cpus":65"#, "65 CPUs"), (#""memory":"lots""#, "a bad size"), (#""rooms":["Bad Room"]"#, "a bad room"),
            (#""rooms":["# + manyRooms + "]", "9 rooms"), (#""allowTools":["-x"]"#, "a tool like an option"), (#""allowTools":[""]"#, "an empty tool"),
        ] {
            invalid(base + "," + extra + "}", why)
        }
        invalid(#"{"action":"worker-add","workspace":"w"}"#, "no task")
        invalid(#"{"action":"worker-add","workspace":"w","task":"  \n"}"#, "a blank task")
        invalid(#"{"action":"worker-add","workspace":"w","task":"a\u0007b"}"#, "a control character")
        invalid(#"{"action":"worker-add","workspace":"W","task":"x"}"#, "a workspace off the rule")
        let long = String(repeating: "x", count: WebWorkerAdd.maximumTaskBytes + 1)
        invalid(#"{"action":"worker-add","workspace":"w","task":""# + long + #""}"#, "a task over 15 KiB")
        XCTAssertNoThrow(try decode(#"{"action":"worker-add","workspace":"w","task":""# + String(long.dropLast()) + #""}"#))
        // Dedupe: per workspace and worker.
        let one = try decode(#"{"action":"worker-add","workspace":"w","name":"carl","task":"x"}"#)
        let again = try decode(#"{"action":"worker-add","workspace":"w","name":"carl","task":"y"}"#)
        let other = try decode(#"{"action":"worker-add","workspace":"w","name":"dora","task":"x"}"#)
        let elsewhere = try decode(#"{"action":"worker-add","workspace":"v","name":"carl","task":"x"}"#)
        XCTAssertEqual(one.dedupeKey, again.dedupeKey)
        XCTAssertNotEqual(one.dedupeKey, other.dedupeKey)
        XCTAssertNotEqual(one.dedupeKey, elsewhere.dedupeKey)
        XCTAssertNotEqual(try decode(#"{"action":"worker-end","workspace":"w","name":"carl","confirm":"carl"}"#).dedupeKey, one.dedupeKey)
        // The plan route's body: the action's fields but confirm; empty while typing; the workspace always, by its rule.
        let q = try WebWorkerAdd.decodePlan(Data(#"{"workspace":"w","name":"","task":"","fromBot":""}"#.utf8))
        var typing = WorkerRequest(workspace: "w")
        typing.task = ""
        XCTAssertEqual(q, typing, "an empty task goes to the daemon, whose refusal is the add's")
        XCTAssertThrowsError(try WebWorkerAdd.decodePlan(Data(#"{"task":"x"}"#.utf8)))
        XCTAssertThrowsError(try WebWorkerAdd.decodePlan(Data(#"{"workspace":"W","task":"x"}"#.utf8)))
        XCTAssertThrowsError(try WebWorkerAdd.decodePlan(Data(#"{"workspace":"w","confirm":"unfenced"}"#.utf8)))
    }

    func testTheNewWorkspaceWizardsActions() throws {
        let body = #"{"action":"workspace-new","workspace":"launch-video","brief":"Make it.\n","refs":["https://example.com/a","/tmp"],"#
            + #""folders":[{"path":"/tmp","mode":"rw"},{"path":"/usr/share","mode":"ro"}],"newFolder":true,"room":"general","#
            + #""manager":"mira","managerIsolation":"unfenced","workerIsolation":"vm","network":"standard","adopt":["lab","@mac/build"]}"#
        let a = try decode(body)
        var want = WorkspaceRequest(name: "launch-video")
        want.brief = "Make it.\n"
        want.refs = ["https://example.com/a", "/private/tmp"]
        want.folders = [WorkspaceFolder(path: "/private/tmp"), WorkspaceFolder(path: "/usr/share", mode: "ro")]
        want.newFolder = true
        want.room = "general"
        want.manager = "mira"
        want.managerIsolation = "unfenced"
        want.workerIsolation = "vm"
        want.network = "standard"
        want.adopt = ["lab", "@mac/build"]
        XCTAssertEqual(a.hostRequest.op, .workspaceNew)
        XCTAssertEqual(a.hostRequest.workspaceRequest, want, "exactly what doz workspace new sends (paths resolved as the CLI resolves them)")
        XCTAssertTrue(a.isFiling)
        XCTAssertFalse(a.isStarting)
        XCTAssertEqual(a.label, "make launch-video")
        if case .workspaceNew(_, let fp) = a { XCTAssertFalse(fp) } else { XCTFail("not new") }
        if case .workspaceNew(let w, let fp) = try decode(#"{"action":"workspace-new","workspace":"w","brief":"b","folders":[{"path":"/tmp","mode":"rw"}],"fromProject":true}"#) {
            XCTAssertTrue(fp)
            XCTAssertNil(w.project, "a browser never names a project path: the web layer fills it on the Mac")
        } else { XCTFail("not new") }
        // The strict field table.
        let manyRefs = (0..<17).map { "\"/tmp/r\($0)\"" }.joined(separator: ",")
        let manyFolders = Array(repeating: #"{"path":"/tmp","mode":"rw"}"#, count: 9).joined(separator: ",")
        let base = #"{"action":"workspace-new","workspace":"w","brief":"b""#
        for (extra, why) in [
            (#""unknown":1"#, "an unknown field"), (#""project":"/x""#, "a project path"), (#""noManager":true"#, "noManager"),
            (#""folders":[{"path":"/tmp","mode":"rx"}]"#, "a bad mode"), (#""folders":[{"path":"/tmp"}]"#, "no mode"),
            (#""folders":[{"path":"tmp","mode":"rw"}]"#, "a relative folder"), (#""folders":[{"path":"/tmp","mode":"rw","main":true}]"#, "an extra key"),
            (#""workerIsolation":"unfenced""#, "an unfenced worker by default"), (#""workerIsolation":"elsewhere""#, "a bad isolation"),
            (#""managerIsolation":"vm""#, "an isolation without a manager"), (#""manager":"Mira""#, "a bad bot name"),
            (#""network":"agent""#, "not a preset"), (#""room":"general","noRoom":true"#, "room and noRoom"), (#""room":"Bad Room""#, "a bad room"),
            (#""refs":["# + manyRefs + "]", "17 references"),
            (#""folders":["# + manyFolders + "]", "9 folders"),
            (#""adopt":["a","b","c","d","e"]"#, "5 agents"), (#""refs":["ftp://x"]"#, "not http(s) or a path"),
            (#""refs":["/\#(String(repeating: "a", count: 1025))"]"#, "a path over 1024 bytes"),
        ] {
            invalid(base + "," + extra + "}", why)
        }
        invalid(#"{"action":"workspace-new","workspace":"w","brief":""}"#, "the action's brief is required")

        let start = try decode(Self.samples["workspace-start"]!)
        var wantStart = WorkspaceRequest(name: "launch-video")
        wantStart.confirmRequired = true
        wantStart.unfencedConfirmed = true
        XCTAssertEqual(start.hostRequest.op, .workspaceStart)
        XCTAssertEqual(start.hostRequest.workspaceRequest, wantStart)
        XCTAssertTrue(start.isStarting)
        XCTAssertFalse(start.isFiling)
        XCTAssertNil(start.sandbox)
        XCTAssertEqual(start.label, "start launch-video")
        let plain = try decode(#"{"action":"workspace-start","workspace":"w"}"#)
        XCTAssertEqual(plain.hostRequest.workspaceRequest?.confirmRequired, true, "the daemon always requires the confirmation from a browser")
        XCTAssertNil(plain.hostRequest.workspaceRequest?.unfencedConfirmed)
        XCTAssertEqual(plain.dedupeKey, try decode(#"{"action":"workspace-start","workspace":"w","actsAsYou":true}"#).dedupeKey)
        invalid(#"{"action":"workspace-start","workspace":"W"}"#, "off the name rule")
        invalid(#"{"action":"workspace-start","workspace":"w","confirmRequired":false}"#, "a browser never turns the confirmation off")
        invalid(#"{"action":"workspace-start"}"#, "the workspace is required")
    }

    func testFilingALooseAgent() throws {
        let adopt = try decode(Self.samples["workspace-adopt"]!)
        var want = WorkspaceRequest(name: "launch-video")
        want.agent = "@mac/build"
        want.asName = "builder"
        XCTAssertEqual(adopt.hostRequest.op, .workspaceAdopt)
        XCTAssertEqual(adopt.hostRequest.workspaceRequest, want, "exactly doz workspace adopt launch-video @mac/build --as builder")
        XCTAssertNil(adopt.hostRequest.name, "the workspace travels in its own request")
        XCTAssertEqual(adopt.label, "put @mac/build in launch-video")

        let new = try decode(Self.samples["workspace-new"]!)
        var wantNew = WorkspaceRequest(name: "gamma")
        wantNew.brief = "The work in gamma."
        wantNew.folders = []
        wantNew.refs = []
        wantNew.adopt = ["gamma"]
        XCTAssertEqual(new.label, "make gamma with gamma")
        XCTAssertEqual(new.hostRequest.op, .workspaceNew)
        XCTAssertEqual(new.hostRequest.workspaceRequest, wantNew, "exactly doz workspace new gamma --prompt-file F --adopt gamma")

        let release = try decode(Self.samples["workspace-release"]!)
        var wantRelease = WorkspaceRequest(name: "launch-video")
        wantRelease.agent = "builder"
        XCTAssertEqual(release.hostRequest.workspaceRequest, wantRelease)
        XCTAssertEqual(try decode(#"{"action":"workspace-release","workspace":"w","agent":"@mac/build"}"#).hostRequest.workspaceRequest?.agent, "@mac/build")

        for a in [adopt, new, release] {
            XCTAssertTrue(a.isFiling)
            XCTAssertFalse(a.isWorkspace, "not decided by serve.chat")
            XCTAssertFalse(a.isMacSession)
            XCTAssertNil(a.sandbox)
            XCTAssertNil(a.confirmationTarget, "not destructive: the agent keeps running")
        }
        XCTAssertNil(try decode(#"{"action":"workspace-adopt","workspace":"w","agent":"lab"}"#).hostRequest.workspaceRequest?.asName)
        // The dedupe key names the agent.
        let a1 = try decode(#"{"action":"workspace-adopt","workspace":"w","agent":"lab"}"#)
        let a2 = try decode(#"{"action":"workspace-adopt","workspace":"w","agent":"lab2"}"#)
        XCTAssertNotEqual(a1.dedupeKey, a2.dedupeKey, "two agents put in one workspace are two operations")
        XCTAssertEqual(a1.dedupeKey, try decode(#"{"action":"workspace-adopt","workspace":"w","agent":"lab","as":"x"}"#).dedupeKey)
        // A workspace is made once: its name is new's key.
        XCTAssertEqual(try decode(#"{"action":"workspace-new","workspace":"w","brief":"b","adopt":["a"]}"#).dedupeKey,
                       try decode(#"{"action":"workspace-new","workspace":"w","brief":"b"}"#).dedupeKey)
        XCTAssertNotEqual(try decode(#"{"action":"workspace-release","workspace":"w","agent":"a"}"#).dedupeKey,
                          try decode(#"{"action":"workspace-release","workspace":"w","agent":"b"}"#).dedupeKey)

        // Strict (the wizard's fields: testTheNewWorkspaceWizardsActions): 0–4 agents, never a project path or noManager.
        invalid(#"{"action":"workspace-new","workspace":"w","brief":"b","adopt":"a"}"#)
        invalid(#"{"action":"workspace-new","workspace":"w","brief":"b","adopt":[7]}"#)
        for extra in [#""project":"/x""#, #""noManager":true"#, #""managerIsolation":"vm""#] {
            invalid(#"{"action":"workspace-new","workspace":"w","brief":"b","adopt":["a"],\#(extra)}"#)
        }
        invalid(#"{"action":"workspace-new","workspace":"w","brief":" ","adopt":["a"]}"#)           // a blank brief
        invalid(#"{"action":"workspace-new","workspace":"W","brief":"b","adopt":["a"]}"#)           // off the name rule
        invalid(#"{"action":"workspace-new","workspace":"w","adopt":["a"]}"#)                       // the brief is required
        // The agent: a sandbox's name or @mac/SESSION — never a bare @mac.
        for bad in ["@mac", "@mac/", "@mac/a b", "Lab", "-x", "a/b", "@other/x", String(repeating: "a", count: 41)] {
            invalid(#"{"action":"workspace-adopt","workspace":"w","agent":"\#(bad)"}"#)
            invalid(#"{"action":"workspace-new","workspace":"w","brief":"b","adopt":["\#(bad)"]}"#)
        }
        invalid(#"{"action":"workspace-release","workspace":"w","agent":"@mac"}"#)
        invalid(#"{"action":"workspace-release","workspace":"w","agent":"-x"}"#)
        invalid(#"{"action":"workspace-adopt","workspace":"w"}"#)
        // `as` by the agent rule.
        for bad in ["-x", ".x", "a b", "a/b", String(repeating: "a", count: 65)] {
            invalid(#"{"action":"workspace-adopt","workspace":"w","agent":"lab","as":"\#(bad)"}"#)
        }
        XCTAssertEqual(try decode(#"{"action":"workspace-adopt","workspace":"w","agent":"lab","as":"Bot_1.a"}"#).hostRequest.workspaceRequest?.asName, "Bot_1.a")
        invalid(#"{"action":"workspace-adopt","workspace":"w","agent":"lab","name":"x"}"#)
        invalid(#"{"action":"workspace-release","workspace":"w","agent":"a","rm":true}"#)

        // This Mac's own browser only — whatever serve.chat or serve.mac_sessions say.
        XCTAssertNil(WebExposure.decideFilingAction(.mac))
        XCTAssertEqual(WebExposure.decideFilingAction(.remote(secure: true)), .macOnlyFiling)
        XCTAssertEqual(WebExposure.decideFilingAction(.remote(secure: false)), .macOnlyFiling)
        XCTAssertEqual(WebRejection.macOnlyFiling.code, "mac-only")
        XCTAssertEqual(WebRejection.macOnlyFiling.status, 403)
        XCTAssertTrue(WebRejection.macOnlyFiling.message.contains("this Mac's own browser"))
        XCTAssertTrue(WebRejection.macOnlyFiling.message.contains("doz workspace adopt"))

        // Its line for the page: a running agent marks the workspace started, nothing posted; else still setting up.
        let t = Date(timeIntervalSince1970: 0)
        let detail = { (state: String, f: WorkspaceFlags, agentState: String) in
            try JSONValue(encoding: WorkspaceDetail(name: "launch-video", state: state, driver: "you", createdAt: t,
                                                    brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t), folders: [],
                                                    rooms: [WorkspaceRoom(label: "main", chatRoom: "launch-video", main: true)],
                                                    agents: [WorkspaceAgentRow(name: "builder", role: "worker", place: "@mac/build", state: agentState, startedAt: t)],
                                                    defaults: WorkspaceDefaults(), flags: f, origin: WorkspaceOrigin()))
        }
        XCTAssertEqual(WebOperations.summary(adopt, try detail("working", WorkspaceFlags(firstAgentAt: t), "running")),
                       "launch-video is started: builder was already running. The brief was not posted. doz workspace start is not needed.")
        XCTAssertEqual(WebOperations.summary(adopt, try detail("setting-up", WorkspaceFlags(), "ended")),
                       "builder is in launch-video, which is still setting up")
        XCTAssertEqual(WebOperations.summary(release, try detail("idle", WorkspaceFlags(firstAgentAt: t), "running")),
                       "builder is loose again (it keeps running as it was) — taken out of launch-video")
        XCTAssertTrue(WebOperations.summary(new, try detail("setting-up", WorkspaceFlags(), "off")).hasPrefix("made gamma with its room #launch-video"))
    }

    func testFieldsMapToTheRequest() throws {
        let c = try decode(Self.samples["create"]!)
        XCTAssertEqual(c.hostRequest.name, "new1")
        XCTAssertEqual(c.hostRequest.create, CreateOptions(image: "lab", cpus: 2, memoryMiB: 1024, network: "bake", account: "default"))
        let s = try decode(Self.samples["open-session"]!)
        XCTAssertEqual(s.hostRequest.argv, ["sleep", "60"])
        XCTAssertEqual(s.hostRequest.session, "worker")
        XCTAssertEqual(s.hostRequest.wake, true)
        let n = try decode(Self.samples["net-policy"]!)
        XCTAssertEqual(n.hostRequest.allow, ["example.com", "*.example.org"])
        XCTAssertEqual(n.hostRequest.deny, ["evil.example"])
        XCTAssertEqual(try decode(Self.samples["account-keepalive"]!).hostRequest.enabled, true)
        XCTAssertEqual(try decode(Self.samples["point-revert"]!).hostRequest.point, "rp-20260927-094949-330-bc2e")
        XCTAssertEqual(try decode(Self.samples["hibernate"]!).sandbox, "a")
        XCTAssertNil(try decode(Self.samples["image-bake"]!).sandbox)
        let restart = try decode(Self.samples["session-restart"]!)
        XCTAssertEqual(restart.hostRequest.session, "codex")
        XCTAssertNil(restart.hostRequest.fresh, "fresh: false is not sent")
        XCTAssertEqual(try decode(#"{"action":"session-restart","sandbox":"web","session":"codex","fresh":true}"#).hostRequest.fresh, true)
        XCTAssertEqual(try decode(Self.samples["session-end"]!).hostRequest.op, .sessionEnd)
        XCTAssertEqual(try decode(Self.samples["session-end"]!).sandbox, "web")
        // 608: the session is required and a valid name; nothing else is taken.
        invalid(#"{"action":"session-end","sandbox":"web"}"#)
        invalid(#"{"action":"session-restart","sandbox":"web","session":"../x"}"#)
        invalid(#"{"action":"session-restart","sandbox":"web","session":"codex","argv":["sh"]}"#)
        // This Mac: its own actions, confirmed by the session's name; never a sandbox action naming @mac.
        let me = try decode(Self.samples["mac-session-end"]!)
        XCTAssertEqual(me.hostRequest.name, "@mac")
        XCTAssertEqual(me.hostRequest.session, "build")
        XCTAssertNil(me.sandbox, "this Mac is no sandbox")
        XCTAssertEqual(me.label, "end session build on this Mac")
        let mr = try decode(#"{"action":"mac-session-restart","session":"agent","fresh":true,"confirm":"agent"}"#)
        XCTAssertEqual(mr.hostRequest.op, .sessionRestart)
        XCTAssertEqual(mr.hostRequest.fresh, true)
        invalid(#"{"action":"mac-session-end","session":"build"}"#)                          // not confirmed
        invalid(#"{"action":"mac-session-end","session":"build","confirm":"other"}"#)
        invalid(#"{"action":"mac-session-end","session":"\#(String(repeating: "x", count: 33))","confirm":"x"}"#)
        invalid(#"{"action":"mac-session-end","sandbox":"web","session":"build","confirm":"build"}"#)
        invalid(#"{"action":"mac-session-restart","session":"a","confirm":"a","argv":["sh"]}"#)
        invalid(#"{"action":"session-end","sandbox":"@mac","session":"build"}"#)            // @mac is not a sandbox name
        invalid(#"{"action":"open-session","sandbox":"@mac","session":"x"}"#)                // no new sessions from the page
    }

    func testDecodingIsStrict() throws {
        invalid("[]")
        invalid("not json")
        invalid(#"{"sandbox":"a"}"#)                                   // no action
        invalid(#"{"action":"exec","sandbox":"a","argv":["id"]}"#)     // not an action
        invalid(#"{"action":"key-set","sandbox":"a","secret":"x"}"#)   // never
        invalid(#"{"action":"account-add","account":"x"}"#)
        invalid(#"{"action":"start","sandbox":"a","extra":1}"#)        // unknown field
        invalid(#"{"action":"start","sandbox":"a","argv":["id"]}"#)    // a field of another action
        invalid(#"{"action":"start","sandbox":"A"}"#)
        invalid(#"{"action":"start","sandbox":"../x"}"#)
        invalid(#"{"action":"start","sandbox":5}"#)
        invalid(#"{"action":"start"}"#)
        // 596 (B1, B6): a base × agent image; a Dockerfile (absolute, a file) carried with the agent's image.
        XCTAssertEqual(try decode(#"{"action":"create","sandbox":"a","image":"python-claude-code"}"#).hostRequest.create?.image, "python-claude-code")
        let df = try decode(#"{"action":"create","sandbox":"a","image":"pi","dockerfile":"/private/tmp/app/Dockerfile"}"#)
        XCTAssertEqual(df.hostRequest.create?.dockerfile, "/private/tmp/app/Dockerfile")
        invalid(#"{"action":"create","sandbox":"a","image":"python-pi","dockerfile":"/private/tmp/app/Dockerfile"}"#)   // the base is the Dockerfile's
        invalid(#"{"action":"create","sandbox":"a","image":"pi","dockerfile":"Dockerfile"}"#)                          // relative
        invalid(#"{"action":"create","sandbox":"a","image":"pi","dockerfile":"/a\nb"}"#)
        XCTAssertEqual(try decode(#"{"action":"image-bake","image":"go-claude-code"}"#).hostRequest.image, "go-claude-code")
        invalid(#"{"action":"image-bake","image":"cobol-pi"}"#)
        invalid(#"{"action":"builder-start","yes":true}"#)
        XCTAssertEqual(try decode(Self.samples["builder-start"]!).hostRequest.requestedBy, "doz ui")
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":"2"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":2.5}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":true}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","memoryMiB":64}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","network":"host"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","subnet":"10.0.0.0"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","folder":"relative/path"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","folder":"/w\nx"}"#)                // one line
        invalid(#"{"action":"create","sandbox":"a","image":"lab","folder":"/w","isolated":true}"#)   // not both
        invalid(#"{"action":"create","sandbox":"a","image":"lab","isolated":"yes"}"#)
        invalid(#"{"action":"open-session","sandbox":"a","session":".hidden"}"#)
        invalid(#"{"action":"open-session","sandbox":"a","argv":[]}"#)
        invalid(#"{"action":"open-session","sandbox":"a","argv":["a\u0000b"]}"#)
        invalid(#"{"action":"open-session","sandbox":"a","argv":[1]}"#)
        invalid(#"{"action":"point-take","sandbox":"a","note":"line\nbreak"}"#)
        invalid(#"{"action":"image-bake","image":"mine"}"#)            // only built-ins bake
        invalid(#"{"action":"net-policy","sandbox":"a"}"#)             // nothing to change
        invalid(#"{"action":"net-policy","sandbox":"a","allow":["http://x.com/"]}"#)
        invalid(#"{"action":"net-policy","sandbox":"a","allow":"x.com"}"#)
        invalid(#"{"action":"net-policy","sandbox":"a","preset":"wide"}"#)
        invalid(#"{"action":"key-policy","sandbox":"a","policy":"loose"}"#)
        invalid(#"{"action":"key-rm","sandbox":"a","binding":"github"}"#)
        invalid(#"{"action":"account-default","account":"default"}"#)
        invalid(#"{"action":"account-keepalive","enabled":1}"#)
        let many = "[" + (0..<33).map { "\"h\($0).com\"" }.joined(separator: ",") + "]"
        invalid(#"{"action":"net-policy","sandbox":"a","allow":"# + many + "}")
        let big = String(repeating: "x", count: 4097)
        invalid(#"{"action":"open-session","sandbox":"a","argv":[""# + big + #""]}"#)
    }

    func testTheInvalidMessageNeverEchoesTheValue() {
        do {
            _ = try decode(#"{"action":"start","sandbox":"<script>alert(1)</script>"}"#)
            XCTFail()
        } catch let e as WebAction.Invalid {
            XCTAssertFalse(e.message.contains("script"))
        } catch { XCTFail("\(error)") }
    }

    func testDestructiveActionsNeedTheTypedName() throws {
        // 591: Shut Down keeps the disk — a plain confirmation in the page, no typed name.
        XCTAssertNil(try decode(#"{"action":"shutdown","sandbox":"a"}"#).confirmationTarget)
        for verb in ["reset", "rm"] {
            invalid(#"{"action":"\#(verb)","sandbox":"a"}"#)
            invalid(#"{"action":"\#(verb)","sandbox":"a","confirm":"b"}"#)
            invalid(#"{"action":"\#(verb)","sandbox":"a","confirm":"A"}"#)
            XCTAssertNotNil(try decode(#"{"action":"\#(verb)","sandbox":"a","confirm":"a"}"#).confirmationTarget)
        }
        invalid(#"{"action":"point-rm","sandbox":"a","point":"p1"}"#)
        invalid(#"{"action":"point-revert","sandbox":"a","point":"p1","confirm":"p1"}"#)   // the sandbox's name
        invalid(#"{"action":"image-rm","image":"mine","confirm":"lab"}"#)
        invalid(#"{"action":"account-rm","account":"work"}"#)
        // Not destructive: a confirm field is not even allowed.
        invalid(#"{"action":"pause","sandbox":"a","confirm":"a"}"#)
        XCTAssertNil(try decode(Self.samples["pause"]!).confirmationTarget)
        XCTAssertNil(try decode(Self.samples["hibernate"]!).confirmationTarget)
    }

    /// 594: a workspace is an absolute path (or ~/…), resolved; it need not exist — the HOST makes it
    /// (and refuses a file, the store, a system location). Isolated is its own field.
    func testAWorkspaceIsResolvedAndNeedNotExist() throws {
        let dir = "/private/tmp/ws-590-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = try decode(#"{"action":"create","sandbox":"a","image":"lab","folder":"\#(dir.replacingOccurrences(of: "/private/tmp", with: "/tmp"))"}"#)
        XCTAssertEqual(a.hostRequest.create?.folder, dir, "links resolved")
        let missing = try decode(#"{"action":"create","sandbox":"a","image":"lab","folder":"\#(dir)/new/deep"}"#)
        XCTAssertEqual(missing.hostRequest.create?.folder, dir + "/new/deep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/new"), "decoding makes nothing")
        let home = try decode(#"{"action":"create","sandbox":"a","image":"lab","folder":"~/proj-x"}"#)
        XCTAssertEqual(home.hostRequest.create?.folder, Workspace.home() + "/proj-x")
        let iso = try decode(#"{"action":"duplicate","sandbox":"a","newName":"b","isolated":true}"#)
        XCTAssertEqual(iso.hostRequest.duplicate?.isolated, true)
        XCTAssertNil(iso.hostRequest.duplicate?.folder)
    }

    // MARK: policy preview

    func testThePreviewIsExactlyWhatTheHostWillApply() throws {
        let live = NetworkPolicy.presets["bake"]!
        let edit = WebPolicyEdit(preset: nil, allow: ["example.com"], deny: ["dl-cdn.alpinelinux.org"], remove: ["pypi.org"])
        let after = try HostCore.editedPolicy(live, edit.request("a"))
        let p = WebPolicyPreview(before: try HostCore.editedPolicy(live, HostRequest(.netPolicy, name: "a")), after: after)
        XCTAssertTrue(p.changed)
        XCTAssertNil(p.after.preset, "an edit leaves the preset")
        XCTAssertTrue(p.added.contains { $0.contains("example.com") })
        XCTAssertTrue(p.added.contains { $0.contains("deny dl-cdn.alpinelinux.org") })
        XCTAssertTrue(p.removed.contains { $0.contains("pypi.org") })
        XCTAssertTrue(p.removed.contains { $0.contains("allow dl-cdn.alpinelinux.org") })
        XCTAssertEqual(p.after.rules.first?.label, after.rules.first?.label)
        let same = WebPolicyPreview(before: live, after: try HostCore.editedPolicy(live, WebPolicyEdit(preset: "bake", allow: [], deny: [], remove: []).request("a")))
        XCTAssertFalse(same.changed)
        XCTAssertThrowsError(try HostCore.editedPolicy(live, WebPolicyEdit(preset: "wide", allow: [], deny: [], remove: []).request("a")))
    }

    /// Nit 4: the account column is "n/a" unless the sandbox's policy can reach the API.
    func testTheAccountMattersOnlyWhenThePolicyReachesTheAPI() throws {
        XCTAssertTrue(HostWebData.reachesAccountAPI(NetworkPolicy.presets["agent"]!))
        XCTAssertTrue(HostWebData.reachesAccountAPI(NetworkPolicy.presets["open"]!))
        XCTAssertFalse(HostWebData.reachesAccountAPI(NetworkPolicy.presets["bake"]!))
        XCTAssertFalse(HostWebData.reachesAccountAPI(NetworkPolicy.presets["locked"]!))
        let custom = try HostCore.editedPolicy(NetworkPolicy.presets["bake"]!, WebPolicyEdit(preset: nil, allow: ["api.anthropic.com"], deny: [], remove: []).request("a"))
        XCTAssertTrue(HostWebData.reachesAccountAPI(custom))
    }

    // MARK: Terminal

    func testTheTerminalCommandIsFixedAndQuoted() {
        let c = TerminalHandoff.command(executable: "/Users/me/.local/libexec/doz/doz", store: DozableStore(root: URL(fileURLWithPath: "/Users/me/My Store")),
                                        sandbox: "demo", session: "worker")
        XCTAssertEqual(c, "exec /Users/me/.local/libexec/doz/doz attach demo worker --store '/Users/me/My Store'")
        let q = TerminalHandoff.command(executable: "/tmp/it's/doz", store: DozableStore(root: URL(fileURLWithPath: "/s;rm -rf ~")), sandbox: "d", session: nil)
        XCTAssertEqual(q, "exec '/tmp/it'\\''s/doz' attach d --store '/s;rm -rf ~'")
        // The one-shot .command file deletes itself first, then runs exactly the command.
        let f = TerminalHandoff.commandFile(q)
        XCTAssertTrue(f.hasPrefix("#!/bin/sh\n"))
        XCTAssertEqual(f.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") },
                       ["rm -f -- \"$0\"", q])
    }

    /// The hand-off folder is in the STORE (no fenced session reaches it — the user's temporary folder was writable by
    /// one), private (0700), and a link or an open folder there is refused, never used.
    func testTheTerminalHandoffDirectoryIsInTheStoreAndPrivate() throws {
        let root = URL(fileURLWithPath: "/private/tmp/dzwt-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DozableStore(root: root)
        let dir = try TerminalHandoff.handoffDirectory(store: store)
        XCTAssertEqual(dir.path, store.root.appendingPathComponent("ui-terminal").path)
        XCTAssertFalse(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path), "never the user's temporary folder")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o700)
        chmod(dir.path, 0o755)
        XCTAssertThrowsError(try TerminalHandoff.handoffDirectory(store: store), "a folder others can open is refused")
        try FileManager.default.removeItem(at: dir)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        symlink(elsewhere.path, dir.path)
        XCTAssertThrowsError(try TerminalHandoff.handoffDirectory(store: store), "a link is refused")
    }

    // MARK: metrics

    func testTheMetricsQueryIsClosed() {
        XCTAssertEqual(WebMetricsQuery.parse(nil), WebMetricsQuery())
        XCTAssertEqual(WebMetricsQuery.parse("image=lab&days=7&steps=1"), WebMetricsQuery(image: "lab", days: 7, steps: true))
        XCTAssertEqual(WebMetricsQuery.parse("image=custom%3Amine&steps=0")?.image, "custom:mine")
        XCTAssertEqual(WebMetricsQuery.parse("image=&days="), WebMetricsQuery())
        for bad in ["image=LAB", "days=-1", "days=abc", "days=99999", "steps=yes", "sort=name", "image", "image=a%20b"] {
            XCTAssertNil(WebMetricsQuery.parse(bad), bad)
        }
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/metrics?days=1"), .metrics(WebMetricsQuery(days: 1)))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/metrics.csv"), .metricsCSV(WebMetricsQuery()))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/metrics?evil=1"))
    }

    func testCSVCellsCannotBecomeFormulas() {
        XCTAssertEqual(WebCSV.cell("=HYPERLINK(\"x\")"), "'=HYPERLINK(\"x\")")
        XCTAssertEqual(WebCSV.cell("+1+2"), "'+1+2")
        XCTAssertEqual(WebCSV.cell("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(WebCSV.cell("-12.5"), "-12.5", "a number stays a number")
        XCTAssertEqual(WebCSV.cell("start"), "start")
        XCTAssertNil(WebCSV.cell(nil))
    }

    /// 650: `batch` rides on the action request's envelope (any action may carry it, as a Bool) and nowhere else — the
    /// action itself is unchanged, and the sub-routes that reuse the decoder (the preview, Terminal) refuse it.
    func testTheBatchMarkIsTheEnvelopesOnly() throws {
        let r = try WebAction.decodeRequest(Data(#"{"action":"wake","sandbox":"demo","batch":true}"#.utf8))
        XCTAssertEqual(r.action, .lifecycle(.wake, name: "demo"))
        XCTAssertTrue(r.batch)
        XCTAssertFalse(try WebAction.decodeRequest(Data(#"{"action":"wake","sandbox":"demo"}"#.utf8)).batch)
        XCTAssertFalse(try WebAction.decodeRequest(Data(#"{"action":"wake","sandbox":"demo","batch":false}"#.utf8)).batch)
        XCTAssertTrue(try WebAction.decodeRequest(Data(#"{"action":"rm","sandbox":"demo","confirm":"demo","batch":true}"#.utf8)).batch)
        for bad in [#"{"action":"wake","sandbox":"demo","batch":"yes"}"#, #"{"action":"wake","sandbox":"demo","batch":1}"#,
                    #"{"action":"wake","sandbox":"demo","batch":null}"#, #"{"action":"wake","sandbox":"demo","priority":true}"#] {
            XCTAssertThrowsError(try WebAction.decodeRequest(Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"wake","sandbox":"demo","batch":true}"#.utf8)), "not beside a sub-route's action")
    }

    // MARK: routes

    func testThePhase2RoutesAreTypedToo() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/actions"), .actions)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/operations"), .operations)
        // 650: cancel is a typed POST of its own (no HostOp); nothing near it is a route.
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/operations/cancel"), .operationsCancel)
        XCTAssertEqual(WebExposure.kind(.operationsCancel), .change)
        for (m, t) in [(WebHTTPMethod.get, "/api/v1/operations/cancel"), (.post, "/api/v1/operations"), (.post, "/api/v1/operations/x"),
                       (.delete, "/api/v1/operations/cancel"), (.post, "/api/v1/operations/cancel/x")] {
            XCTAssertNil(WebRoute.parse(method: m, target: t), t)
        }
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/network/preview"), .policyPreview("demo"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/terminal"), .terminal("demo"))
        for t in ["/api/v1/actions/start", "/api/v1/sandboxes/demo/start", "/api/v1/sandboxes/demo/exec", "/api/v1/sandboxes/Demo/terminal",
                  "/api/v1/sandboxes/demo/network/apply", "/api/v1/command", "/api/v1/sandboxes/demo/attach"] {
            XCTAssertNil(WebRoute.parse(method: .post, target: t), t)
        }
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/actions"))
        XCTAssertNil(WebRoute.parse(method: .delete, target: "/api/v1/actions"))
        // 593: the lineage is a GET of its own; nothing near it is a route.
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/images/tree"), .imageTree)
        for (m, t) in [(WebHTTPMethod.post, "/api/v1/images/tree"), (.get, "/api/v1/images/tree/"), (.get, "/api/v1/images/tree/x"),
                       (.get, "/api/v1/images/Tree"), (.delete, "/api/v1/images/tree"), (.get, "/api/v1/images/lab")] {
            XCTAssertNil(WebRoute.parse(method: m, target: t), t)
        }
        // 595: the account (GET) and the preview (POST); deleting is an action, never a route.
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/resources"), .resources)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/resources/preview"), .resourcesPreview)
        for (m, t) in [(WebHTTPMethod.post, "/api/v1/resources"), (.delete, "/api/v1/resources"), (.get, "/api/v1/resources/preview"),
                       (.post, "/api/v1/resources/delete"), (.post, "/api/v1/resources/clean"), (.get, "/api/v1/resources/logs"),
                       (.get, "/api/v1/resources/")] {
            XCTAssertNil(WebRoute.parse(method: m, target: t), t)
        }
    }

    func testOperationSummariesComeFromTheResultNotThroughIt() throws {
        let r = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","operation":"hibernate","phaseBefore":"running","phase":"hibernated","changed":true,"milliseconds":510}"#.utf8))
        XCTAssertEqual(WebOperations.summary(.lifecycle(.hibernate, name: "a"), r), "a: running → hibernated in 510 ms")
        let same = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","operation":"pause","phaseBefore":"paused","phase":"paused","changed":false,"milliseconds":0}"#.utf8))
        XCTAssertEqual(WebOperations.summary(.lifecycle(.pause, name: "a"), same), "a is already paused")
        XCTAssertEqual(WebOperations.summary(.imageBake("lab"), .null), "lab baked")
    }

    /// 634: the setup's base — `onboard {base}` prepares the store's one base (still one HostOp); `prepare-cancel {base}`
    /// cancels it by its name; a base the catalogue does not have is refused.
    func testOnboardTakesTheStoresBase() throws {
        let a = try WebAction.decode(Data(#"{"action":"onboard","base":"node"}"#.utf8))
        XCTAssertEqual(a.hostOp, .onboard)
        XCTAssertEqual(a.hostRequest.base, "node")
        XCTAssertEqual(a.hostRequest.images, [])
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"onboard","base":"cobol"}"#.utf8)))
        let c = try WebAction.decode(Data(#"{"action":"prepare-cancel","base":"node"}"#.utf8))
        XCTAssertEqual(c.hostRequest.images, ["base:node"])
        XCTAssertEqual(WebOperations.summary(.onboard([], base: "node"), .null), "onboarded — the Node.js base ready")
    }
}
