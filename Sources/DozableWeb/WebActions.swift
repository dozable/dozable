import Foundation
import DozableKit
import DozableHost

/// 590 phase 2 — everything the UI can DO, as a closed enum. Each case maps to exactly ONE `HostOp`
/// (the same operation the CLI sends; the web layer adds none of its own), with every field
/// validated here before the host sees it. The body of `POST /api/v1/actions` is decoded STRICTLY:
/// an unknown action, an unknown field, a wrong type or a value outside its rule is a 400 — nothing
/// is passed through.
///
/// Not here, on purpose: `exec` and `attach` (a terminal is Terminal.app, `WebTerminal`), `key set`
/// and `account add` (no ACTION carries a secret — 590's D3; since 594 an account's key or token has
/// its own typed route, `POST /api/v1/accounts`, gated by `ui.allow_secret_entry`), `host stop`.
public enum WebAction: Equatable, Sendable {
    case create(name: String, options: CreateOptions)
    /// start, wake, pause, resume, sleep, hibernate, shutdown, reset, rm.
    case lifecycle(HostOp, name: String)
    /// A session: the image's own when `argv` is nil, else a new one running `argv` (detached — no
    /// shell in front, inside the sandbox only).
    case openSession(name: String, session: String?, argv: [String]?)
    case pointTake(name: String, point: String?, note: String?)
    case pointRevert(name: String, point: String)
    case pointFork(name: String, point: String, newName: String)
    case pointRemove(name: String, point: String)
    case pointSaveImage(name: String, point: String?, image: String, note: String?)
    /// 593: a template (root disk only) from the current disk (any phase) or a restore point.
    case templateCreate(name: String, point: String?, image: String, note: String?)
    /// 593: a new sandbox from this one's disk, with overrides; the state disk fresh unless copied.
    case duplicate(name: String, newName: String, point: String?, options: DuplicateOptions)
    case imageBake(String)
    case imageRemove(String)
    case netPolicy(name: String, edit: WebPolicyEdit)
    case keyPolicy(name: String, policy: String)
    case keyRemove(name: String, binding: String)
    case accountUse(name: String, account: String)
    case accountDefault(String)
    case accountKeepalive(Bool)
    case accountVerify(String)
    /// 617: read a key kept in 1Password, AWS or a command again (never adds or changes a source — D7).
    case accountRefresh(String)
    /// 641: edit a key's details — rename it (everything that names it goes with it) and/or a setup token's plan. Never
    /// its value: that is `POST /api/v1/accounts` with replace.
    case accountEdit(String, newName: String?, plan: String?)
    case accountRemove(String)
    /// 594: onboard — prepare these built-in images in the host (in the background: the action ends
    /// at once; the preparation shows in the wizard and in Operations) and record the onboarding.
    case onboard([String], base: String? = nil)
    /// 594: cancel the preparation of these images (all running ones when empty).
    case prepareCancel([String], base: String? = nil)
    /// 595 (R3): delete these resources (ids as the Resources page lists them) — one host operation,
    /// serialised with the lifecycle. A plain confirmation on the page (owner: no typed names).
    case resourcesRemove([String])
    /// 595 (R4): Clean up — the re-creatable, unused set.
    case resourcesClean
    /// 595 (R5): the kernel NEW sandboxes boot (`kernel:<version>` or `pinned`).
    case resourcesKernel(String)
    /// 594 W18: "Start host" — the host's `ping`, sent with autostart as every action is: a host
    /// starts the normal detached way (`HostLauncher`), exactly as the CLI's first command starts one.
    /// Starting is all it does (`host stop` stays out of the browser).
    case hostStart
    /// 594 W20: "Restart host" — the CLI's `host stop`, then a host of this UI's build (`HostLauncher`);
    /// 647: any running host (`HostWebData.restartHost` refuses only when none runs). The one way
    /// `host-stop` is reachable from the browser.
    case hostRestart
    /// 596 (B7): start Apple's container services (`builder-start`) — the page has said what it does
    /// (launchd services, its kernel) and the person pressed the button; that is the consent.
    case builderStart
    /// 596 (B7): install Apple's container tool on demand (`builder-install`: its signed package,
    /// pinned and sha256-checked, opened in macOS Installer — the person approves it there; never sudo).
    case builderInstall
    /// 599h: set the sandbox's tools layer up again now (the New Sandbox wizard's Retry) — `tools-apply`.
    case toolsApply(String)
    /// 608: End session / Restart session (a terminal tab's menu, the inspector's Sessions tab) — the CLI's
    /// `doz sessions end|restart`; lifecycle-class, so a remote (doz serve) browser may use them too.
    case sessionEnd(name: String, session: String)
    case sessionRestart(name: String, session: String, fresh: Bool)
    /// End / Restart a session on THIS Mac (`@mac`, no isolation) — the CLI's `doz sessions end|restart @mac S`. Their own
    /// actions, never the sandbox ones with a made-up name; both carry `confirm` = the session (the program stops); for
    /// another computer only with `serve.mac_sessions = interactive` (`WebExposure.decideMacAction`). No action OPENS one.
    case macSessionEnd(session: String)
    case macSessionRestart(session: String, fresh: Bool)
    /// Remove (forget) an ended or gone session on this Mac — exactly `session-forget` with that one session (`doz sessions
    /// @mac --forget S`); and Remove all ended — exactly `session-forget` with the names the page showed (`doz sessions @mac
    /// --forget-ended`, acting on what was shown). Each is carried back first; never a running or a workspace's session.
    /// This Mac's own browser only (`isMacForget`, `WebExposure.decideMacForgetAction`), whatever `serve.mac_sessions` says:
    /// a forgotten session can no longer be restarted.
    case macSessionForget(session: String)
    case macSessionsForgetEnded(sessions: [String])
    /// 683 M5: a fenced session stopped for a git config change continues (`doz sessions resume @mac S` — the host refuses
    /// while a change outside the allowlist is there again); its bridges switched live (`doz sessions bridges @mac S …`,
    /// each nil: as it is — the next open-URL, open-file or copy follows). Neither OPENS anything nor widens a grant made
    /// at the start: the bridges are host-side decisions taken per event.
    case macSessionResume(session: String)
    case macSessionBridges(session: String, openURL: Bool?, openFiles: Bool?, clipboard: Bool?)
    /// A refused site allowed for a fenced session on this Mac — exactly `net-policy` with `@mac` and the session (`doz net
    /// allow @mac --session S site:HOST[:PORT]`): `site:` grants only — never a revoke, a deny, a preset or a `host:` port.
    /// This Mac's own browser only (`isMacNet`, `WebExposure.decideMacNetAction`): a fenced session's network is what holds an
    /// agent working as you on this Mac to its folder, whatever `serve.mac_sessions` says.
    case macNetPolicy(session: String, grant: [String])
    /// 644: the Files panel's changes to /workspace — one HostOp each (the CLI's `doz files mkdir|new|mv|rm`). Paths are
    /// guest paths (`/workspace/…`), checked by the item rule here and again by the host. A delete is destructive: it
    /// carries `confirm` = the path.
    case filesMkdir(name: String, path: String)
    case filesNew(name: String, path: String)
    case filesMove(name: String, path: String, to: String)
    case filesRemove(name: String, path: String, recursive: Bool)
    /// Owner, 2026-10-23: Rename… (the sidebar's ⋯ on a sandbox's line, the sandbox page's ⋯) — the CLI's `doz rename`. Nothing
    /// is lost, so no `confirm`; the host refuses unless the sandbox is shut down.
    case rename(name: String, newName: String)
    /// 669 (659 item 13): one per-sandbox setting of a sandbox — its own value, or (nil) "Follow the Mac": it follows
    /// the layers below again (`doz config set|unset --sandbox NAME KEY`).
    case sandboxSetting(name: String, key: String, value: String?)
    /// A workspace's brief replaced from its page — exactly `doz workspace edit W --prompt-file F --if-brief SHA` (the
    /// HostOp `workspace-edit` with only the name, the brief and `ifBrief`: never its references, folders, manager or
    /// room). `ifBrief` is the sha256 the page read: a brief changed since is refused, nothing written. After the start
    /// the daemon announces it in the main room as you. Another computer only with `serve.chat = write`
    /// (`WebExposure.decideWorkspaceAction`). The one workspace action another computer may have (with `serve.chat = write`).
    case workspaceBrief(workspace: String, brief: String, ifBrief: String)
    /// Filing a loose agent — this Mac's own browser only (`isFiling`, `WebExposure.decideFilingAction`), whatever the serve
    /// settings: what a workspace holds decides what it (and later its manager) may reach. Each is exactly the CLI's:
    /// `doz workspace adopt W AGENT [--as NAME]` — the agent a sandbox's name or `@mac/SESSION`;
    case workspaceAdopt(workspace: String, agent: String, asName: String?)
    /// `doz workspace new W --prompt-file F [--ref …] [--new-folder] [--folder DIR[:ro]] [--room R | --no-room] [--from-project]
    /// [--manager BOT [--manager-isolation …]] [--worker-isolation fenced|vm] [--network …] [--adopt AGENT]…` — the New
    /// workspace wizard's, and "Put in a workspace…"'s with one agent. Never a project path or `noManager` from a browser:
    /// `fromProject` is the flag, and the web layer on the Mac fills `project` and `network` (`WorkspaceProjectFill`). The
    /// room is made as with the CLI when chat is on;
    case workspaceNew(WorkspaceRequest, fromProject: Bool)
    /// `doz workspace start W` — this Mac's own browser only (`isStarting`, `WebExposure.decideStartAction`): it posts the
    /// brief as you and starts a program holding a bot's token, maybe an unfenced manager acting as you. It sets
    /// `confirmRequired`, so the daemon refuses an unfenced manager unless `actsAsYou` confirms it.
    case workspaceStart(workspace: String, actsAsYou: Bool)
    /// `doz workspace release W AGENT` — the agent's name in the workspace, or `@mac/SESSION`. A live worker or a running
    /// manager is refused by the daemon, as for the CLI.
    case workspaceRelease(workspace: String, agent: String)
    /// Agents / Bots — this Mac's own browser only (`isBot`, `WebExposure.decideBotAction`), whatever the serve settings: each
    /// makes, replaces or revokes a token and writes the login keychain. Each is exactly the CLI's HostOp, with `heldOnly` set
    /// (`BotRequest.heldOnly`): nothing it asks may make a token to show once, so no token ever reaches a browser — a bot
    /// elsewhere is made and re-keyed in a terminal. `doz bot new NAME --agent A [--isolation vm|fenced|unfenced] …`;
    case botNew(BotRequest)
    /// `doz bot set NAME …` (never to or from elsewhere);
    case botSet(BotRequest)
    /// `doz bot retire NAME --yes` (confirmed with the name);
    case botRetire(name: String)
    /// `doz bot adopt NAME --agent A [--isolation vm|fenced|unfenced] --yes` (confirmed: its token is replaced);
    case botAdopt(BotRequest)
    /// `doz bot token NAME --new` for a held bot (confirmed: the old one is refused at once).
    case botToken(name: String)
    /// A workspace's worker — this Mac's own browser only (`isWorker`, `WebExposure.decideWorkerAction`), whatever the serve
    /// settings: an add makes a participant and a token and starts a program (maybe unfenced, acting as you); an end revokes
    /// one. Each is exactly the CLI's HostOp. `doz worker add W [NAME] --task "…" […]` — an unfenced one only with `confirm`
    /// = `unfenced` (the person ticked "It acts as you"); never preselected by the page;
    case workerAdd(WorkerRequest)
    /// `doz worker end W NAME` (confirmed with its name; never `--rm` from a browser).
    case workerEnd(workspace: String, name: String)
    /// A workspace's lifecycle — this Mac's own browser only (`isLifecycle`, `WebExposure.decideLifecycleAction`), whatever the
    /// serve settings: each stops, starts or removes what the workspace holds, posts as you (an archive's rooms) or hands a
    /// bot's token to a program again. Each is exactly the CLI's HostOp — `workspace-stop`, `-sleep`, `-wake`, `-finish`,
    /// `-reopen`, `-archive`, `-restore`, `-delete` — with the plan's sha the page showed (`ifPlan`: a workspace changed since
    /// is refused, nothing done) and `confirmRequired`: the daemon checks an archive's or a delete's typed name (`confirm`)
    /// and the "acts as you" confirmation of an unfenced manager's wake (`actsAsYou`). Archive: `removeSandboxes?`,
    /// `keepTemplates?`; delete: `removeSandboxes?`, `binFolders?` — nothing on disk goes without them.
    case workspaceLifecycle(WorkspaceVerb, WorkspaceRequest)

    public static let lifecycleOps: [String: HostOp] = [
        "start": .start, "wake": .wake, "pause": .pause, "resume": .resume, "sleep": .sleep, "hibernate": .hibernate,
        "shutdown": .shutdown, "reset": .reset, "rm": .rm,
    ]

    /// The one host operation this action is.
    public var hostOp: HostOp { hostRequest.op }

    /// The sandbox it acts on (progress is shown in its row).
    public var sandbox: String? {
        switch self {
        case .create(let n, _), .lifecycle(_, let n), .openSession(let n, _, _), .pointTake(let n, _, _), .pointRevert(let n, _),
             .pointFork(let n, _, _), .pointRemove(let n, _), .pointSaveImage(let n, _, _, _), .netPolicy(let n, _), .keyPolicy(let n, _),
             .keyRemove(let n, _), .accountUse(let n, _), .templateCreate(let n, _, _, _), .duplicate(let n, _, _, _), .toolsApply(let n),
             .sessionEnd(let n, _), .sessionRestart(let n, _, _), .filesMkdir(let n, _), .filesNew(let n, _), .filesMove(let n, _, _),
             .filesRemove(let n, _, _), .rename(let n, _), .sandboxSetting(let n, _, _):
            return n
        case .imageBake, .imageRemove, .accountDefault, .accountKeepalive, .accountVerify, .accountRefresh, .accountEdit, .accountRemove, .onboard, .prepareCancel,
             .resourcesRemove, .resourcesClean, .resourcesKernel, .hostStart, .hostRestart, .builderStart, .builderInstall,
             .macSessionEnd, .macSessionRestart, .macSessionResume, .macSessionBridges, .macNetPolicy,   // this Mac is no sandbox
             .macSessionForget, .macSessionsForgetEnded,
             .workspaceBrief, .workspaceAdopt, .workspaceNew, .workspaceRelease, .workspaceStart,   // nor is a workspace
             .botNew, .botSet, .botRetire, .botAdopt, .botToken,                          // nor is a bot
             .workerAdd, .workerEnd,                                                      // nor a worker (its place is the daemon's)
             .workspaceLifecycle:
            return nil
        }
    }

    /// An action on the sessions on this Mac (decided by `serve.mac_sessions` for another computer).
    public var isMacSession: Bool {
        switch self { case .macSessionEnd, .macSessionRestart, .macSessionResume, .macSessionBridges: true; default: false }
    }

    /// An action on a workspace (decided by `serve.chat` for another computer: it speaks as you in its room).
    public var isWorkspace: Bool {
        if case .workspaceBrief = self { true } else { false }
    }

    /// Filing an agent into a workspace or out of one: this Mac's own browser only (`WebExposure.decideFilingAction`).
    public var isFiling: Bool {
        switch self { case .workspaceAdopt, .workspaceNew, .workspaceRelease: true; default: false }
    }

    /// A workspace started: this Mac's own browser only (`WebExposure.decideStartAction`).
    public var isStarting: Bool {
        if case .workspaceStart = self { true } else { false }
    }

    /// An Agent / Bot changed: this Mac's own browser only (`WebExposure.decideBotAction`).
    public var isBot: Bool {
        switch self { case .botNew, .botSet, .botRetire, .botAdopt, .botToken: true; default: false }
    }

    /// An ended or gone session on this Mac forgotten: this Mac's own browser only (`WebExposure.decideMacForgetAction`).
    public var isMacForget: Bool {
        switch self { case .macSessionForget, .macSessionsForgetEnded: true; default: false }
    }

    /// A fenced session's site allowed: this Mac's own browser only (`WebExposure.decideMacNetAction`).
    public var isMacNet: Bool {
        if case .macNetPolicy = self { true } else { false }
    }

    /// A workspace's lifecycle verb: this Mac's own browser only (`WebExposure.decideLifecycleAction`).
    public var isLifecycle: Bool {
        if case .workspaceLifecycle = self { true } else { false }
    }

    /// A worker added or ended: this Mac's own browser only (`WebExposure.decideWorkerAction`).
    public var isWorker: Bool {
        switch self { case .workerAdd, .workerEnd: true; default: false }
    }

    /// Destructive actions carry `confirm`, which must equal this (the page fills it only from a
    /// name the person typed).
    public var confirmationTarget: String? {
        switch self {
        // Shut Down keeps the disk (owner, 591: a plain confirmation, not a typed name).
        case .lifecycle(let op, let n) where [.reset, .rm].contains(op): n
        case .pointRevert(let n, _), .pointRemove(let n, _): n
        case .imageRemove(let i): i
        case .accountRemove(let a): a
        case .filesRemove(_, let p, _): p
        case .macSessionEnd(let s), .macSessionRestart(let s, _): s
        // A bot retired, adopted (its token replaced) or given a new token: the name, ticked in the page's dialog.
        case .botRetire(let n), .botToken(let n): n
        case .botAdopt(let b): b.name
        // A worker ended: its name, ticked. An unfenced worker added: the word `unfenced` — it acts as you, ticked.
        case .workerEnd(_, let n): n
        case .workerAdd(let q) where q.isolation == "unfenced": WebWorkerAdd.unfencedConfirmation
        // An archive or a delete: the workspace's name as the person typed it (the daemon checks it too).
        case .workspaceLifecycle(let v, let w) where v.confirm == .typed: w.name
        default: nil
        }
    }

    /// Two actions with the same key must not run at once: the same operation on the same sandbox
    /// (and session, point, image or account). A double-clicked "open session" is one operation.
    public var dedupeKey: String {
        let r = hostRequest
        if let w = r.workspaceRequest?.name {
            // A workspace is made or started once at a time: its name is the key.
            if r.op == .workspaceNew || r.op == .workspaceStart { return [r.op.rawValue, "workspace:" + w].joined(separator: "|") }
            // Filing names its agent: two agents put in one workspace at once are two operations.
            let agent = r.workspaceRequest?.agent ?? r.workspaceRequest?.adopt?.joined(separator: ",") ?? ""
            return [r.op.rawValue, "workspace:" + w, agent].joined(separator: "|")
        }
        // A worker's: its workspace and its name (or its bot's) — two workers added at once are two operations.
        if let q = r.workerRequest {
            return [r.op.rawValue, "workspace:" + (q.workspace ?? ""), "worker:" + (q.name ?? q.fromBot ?? "")].joined(separator: "|")
        }
        // A fenced session's site: the session and the site — two sites allowed at once are two operations.
        if case .macNetPolicy(let s, let g) = self { return [r.op.rawValue, MacPlace.name, s, g.joined(separator: ",")].joined(separator: "|") }
        // A bot's request leaves `name` empty: its own key, so two bots changed at once are two operations.
        if let b = r.botRequest?.name { return [r.op.rawValue, "bot:" + b].joined(separator: "|") }
        return [r.op.rawValue, r.name ?? "", r.session ?? "", r.point ?? r.pointName ?? "", r.image ?? "", r.account ?? "", r.newName ?? "",
                r.ids?.joined(separator: ",") ?? "", r.kernel ?? "", r.filePath ?? ""].joined(separator: "|")
    }

    /// A short label for the progress line ("hibernate lab1").
    public var label: String {
        switch self {
        case .resourcesRemove(let ids): return ids.count == 1 ? "delete \(ids[0])" : "delete \(ids.count) resources"
        case .resourcesClean: return "clean up"
        case .resourcesKernel(let k): return "use \(k) for new sandboxes"
        case .hostStart: return "daemon-start"
        case .hostRestart: return "daemon-restart"
        case .builderStart: return "start Apple's container services"
        case .builderInstall: return "install Apple's container tool"
        case .toolsApply(let n): return "set up the tools of \(n)"
        case .sessionEnd(let n, let s): return "end session \(s) in \(n)"
        case .sessionRestart(let n, let s, _): return "restart session \(s) in \(n)"
        case .macSessionEnd(let s): return "end session \(s) on this Mac"
        case .macSessionForget(let s): return "remove session \(s) on this Mac"
        case .macSessionsForgetEnded(let ss): return "remove \(ss.count) ended session\(ss.count == 1 ? "" : "s") on this Mac"
        case .macSessionRestart(let s, _): return "restart session \(s) on this Mac"
        case .macSessionResume(let s): return "resume session \(s) on this Mac"
        case .macSessionBridges(let s, _, _, _): return "bridges of session \(s) on this Mac"
        case .macNetPolicy(let s, let g): return "allow \(g.map { String($0.dropFirst(5)) }.joined(separator: ", ")) for session \(s) on this Mac"
        case .filesMkdir(let n, let p): return "files-mkdir \(n) \(p)"
        case .filesNew(let n, let p): return "files-new \(n) \(p)"
        case .filesMove(let n, let p, _): return "files-move \(n) \(p)"
        case .filesRemove(let n, let p, _): return "files-rm \(n) \(p)"
        case .rename(let n, let new): return "rename \(n) to \(new)"
        case .sandboxSetting(let n, let k, let v): return v.map { "\(k) = \($0) for \(n)" } ?? "\(n) follows the Mac's \(k)"
        case .workspaceBrief(let w, _, _): return "edit the brief of \(w)"
        case .workspaceAdopt(let w, let a, _): return "put \(a) in \(w)"
        case .workspaceNew(let w, _):
            let n = w.name ?? "?"
            return w.adopt?.count == 1 ? "make \(n) with \(w.adopt![0])" : "make \(n)"
        case .workspaceStart(let w, _): return "start \(w)"
        case .workspaceRelease(let w, let a): return "take \(a) out of \(w)"
        case .botNew(let b): return "make Agent / Bot \(b.name ?? "?")"
        case .botSet(let b): return "change \(b.name ?? "?")"
        case .botRetire(let n): return "retire \(n)"
        case .botAdopt(let b): return "make \(b.name ?? "?") an Agent / Bot"
        case .botToken(let n): return "a new token for \(n)"
        case .workerAdd(let q): return "add \(q.name ?? q.fromBot ?? "a worker") to \(q.workspace ?? "?")"
        case .workerEnd(let w, let n): return "end \(n) in \(w)"
        case .workspaceLifecycle(let v, let w): return "\(v.rawValue) \(w.name ?? "?")"
        default: break
        }
        let r = hostRequest
        return [r.op.rawValue, r.name ?? r.image ?? r.account].compactMap { $0 }.joined(separator: " ")
    }

    public var hostRequest: HostRequest {
        switch self {
        case .create(let n, let o):
            var r = HostRequest(.create, name: n)
            r.create = o
            return r
        case .lifecycle(let op, let n):
            return HostRequest(op, name: n)
        case .openSession(let n, let s, let argv):
            var r = HostRequest(.openSession, name: n)
            r.session = s
            r.argv = argv
            r.wake = true
            return r
        case .pointTake(let n, let p, let note):
            var r = HostRequest(.pointTake, name: n)
            r.pointName = p
            r.note = note
            return r
        case .pointRevert(let n, let p):
            var r = HostRequest(.pointRevert, name: n)
            r.point = p
            return r
        case .pointFork(let n, let p, let new):
            var r = HostRequest(.pointFork, name: n)
            r.point = p
            r.newName = new
            return r
        case .pointRemove(let n, let p):
            var r = HostRequest(.pointRm, name: n)
            r.point = p
            return r
        case .pointSaveImage(let n, let p, let image, let note):
            var r = HostRequest(.pointSaveImage, name: n)
            r.point = p
            r.image = image
            r.note = note
            return r
        case .templateCreate(let n, let p, let image, let note):
            var r = HostRequest(.templateCreate, name: n)
            r.point = p
            r.image = image
            r.note = note
            return r
        case .duplicate(let n, let new, let p, let o):
            var r = HostRequest(.duplicate, name: n)
            r.newName = new
            r.point = p
            r.duplicate = o
            return r
        case .imageBake(let i):
            var r = HostRequest(.imageBake)
            r.image = i
            return r
        case .imageRemove(let i):
            var r = HostRequest(.imageRm)
            r.image = i
            return r
        case .netPolicy(let n, let e):
            return e.request(n)
        case .keyPolicy(let n, let p):
            var r = HostRequest(.keyPolicy, name: n)
            r.policy = p
            return r
        case .keyRemove(let n, let b):
            var r = HostRequest(.keyRm, name: n)
            r.binding = b
            return r
        case .accountUse(let n, let a):
            var r = HostRequest(.accountUse, name: n)
            r.account = a
            return r
        case .accountDefault(let a):
            var r = HostRequest(.accountDefault)
            r.account = a
            return r
        case .accountKeepalive(let on):
            var r = HostRequest(.accountKeepalive)
            r.enabled = on
            return r
        case .accountVerify(let a):
            var r = HostRequest(.accountVerify)
            r.account = a
            r.verify = true
            return r
        case .accountRefresh(let a):
            var r = HostRequest(.accountRefresh)
            r.account = a
            return r
        case .accountEdit(let a, let new, let plan):
            var r = HostRequest(.accountEdit)
            r.account = a
            r.newName = new
            r.plan = plan
            return r
        case .accountRemove(let a):
            var r = HostRequest(.accountRemove)
            r.account = a
            return r
        case .onboard(let images, let base):
            var r = HostRequest(.onboard)
            r.images = images
            r.base = base                     // 634: the store's one base, prepared first
            r.follow = false
            r.requestedBy = "doz ui"
            return r
        case .prepareCancel(let images, let base):
            var r = HostRequest(.prepareCancel)
            let all = (base.map { [PreparationInfo.baseName($0)] } ?? []) + images
            r.images = all.isEmpty ? nil : all
            return r
        case .resourcesRemove(let ids):
            var r = HostRequest(.resourcesRemove)
            r.ids = ids
            return r
        case .resourcesClean:
            return HostRequest(.resourcesClean)
        case .resourcesKernel(let k):
            var r = HostRequest(.resourcesKernel)
            r.kernel = k
            return r
        case .hostStart:
            return HostRequest(.ping)
        case .hostRestart:
            return HostRequest(.hostStop)
        case .builderStart:
            var r = HostRequest(.builderStart)
            r.requestedBy = "doz ui"
            return r
        case .builderInstall:
            var r = HostRequest(.builderInstall)
            r.requestedBy = "doz ui"
            return r
        case .toolsApply(let n):
            return HostRequest(.toolsApply, name: n)
        case .sessionEnd(let n, let s):
            var r = HostRequest(.sessionEnd, name: n)
            r.session = s
            return r
        case .sessionRestart(let n, let s, let fresh):
            var r = HostRequest(.sessionRestart, name: n)
            r.session = s
            r.fresh = fresh ? true : nil
            return r
        case .macSessionEnd(let s):
            var r = HostRequest(.sessionEnd, name: MacPlace.name)
            r.session = s
            // A running session only: the dashboard never forgets one by ending it again (that is Remove, this Mac's own).
            r.onlyRunning = true
            return r
        case .macSessionForget(let s):
            var r = HostRequest(.sessionForget, name: MacPlace.name)
            r.session = s
            return r
        case .macSessionsForgetEnded(let ss):
            var r = HostRequest(.sessionForget, name: MacPlace.name)
            r.sessions = ss
            return r
        case .macSessionRestart(let s, let fresh):
            var r = HostRequest(.sessionRestart, name: MacPlace.name)
            r.session = s
            r.fresh = fresh ? true : nil
            return r
        case .macSessionResume(let s):
            var r = HostRequest(.sessionResume, name: MacPlace.name)
            r.session = s
            return r
        case .macNetPolicy(let s, let g):
            // Exactly what `doz net allow @mac --session S site:HOST` sends.
            var r = HostRequest(.netPolicy, name: MacPlace.name)
            r.session = s
            r.grant = g
            return r
        case .macSessionBridges(let s, let url, let files, let clip):
            var r = HostRequest(.sessionBridges, name: MacPlace.name)
            r.session = s
            var b = MacFenceRequest()
            b.openURL = url
            b.openFiles = files
            b.clipboard = clip
            r.macBridges = b
            return r
        case .filesMkdir(let n, let p):
            var r = HostRequest(.filesMkdir, name: n)
            r.filePath = p
            return r
        case .filesNew(let n, let p):
            var r = HostRequest(.filesNew, name: n)
            r.filePath = p
            return r
        case .filesMove(let n, let p, let to):
            var r = HostRequest(.filesMove, name: n)
            r.filePath = p
            r.fileTarget = to
            return r
        case .filesRemove(let n, let p, let rec):
            var r = HostRequest(.filesRm, name: n)
            r.filePath = p
            r.recursive = rec ? true : nil
            return r
        case .rename(let n, let new):
            var r = HostRequest(.rename, name: n)
            r.newName = new
            return r
        case .sandboxSetting(let n, let k, let v):
            var r = HostRequest(.sandboxSettings, name: n)
            r.setting = k
            if let v { r.settingValue = .string(v) } else { r.clearSetting = true }
            return r
        case .workspaceBrief(let w, let brief, let ifBrief):
            var e = WorkspaceRequest(name: w)
            e.brief = brief
            e.ifBrief = ifBrief
            var r = HostRequest(.workspaceEdit)
            r.workspaceRequest = e
            return r
        case .workspaceAdopt(let w, let agent, let asName):
            var e = WorkspaceRequest(name: w)
            e.agent = agent
            e.asName = asName
            var r = HostRequest(.workspaceAdopt)
            r.workspaceRequest = e
            return r
        case .workspaceNew(let w, _):
            // What `doz workspace new …` sends (the project's fill, when asked, is the web layer's on the Mac).
            var r = HostRequest(.workspaceNew)
            r.workspaceRequest = w
            return r
        case .workspaceStart(let w, let actsAsYou):
            // What `doz workspace start W` sends, plus the confirmation the daemon then requires of an unfenced manager.
            var e = WorkspaceRequest(name: w)
            e.confirmRequired = true
            e.unfencedConfirmed = actsAsYou ? true : nil
            var r = HostRequest(.workspaceStart)
            r.workspaceRequest = e
            return r
        case .workspaceRelease(let w, let agent):
            var e = WorkspaceRequest(name: w)
            e.agent = agent
            var r = HostRequest(.workspaceRelease)
            r.workspaceRequest = e
            return r
        case .botNew(let b): return Self.botRequest(.botNew, b)
        case .botSet(let b): return Self.botRequest(.botSet, b)
        case .botRetire(let n): return Self.botRequest(.botRetire, BotRequest(name: n))
        case .botAdopt(let b): return Self.botRequest(.botAdopt, b)
        case .botToken(let n): return Self.botRequest(.botToken, BotRequest(name: n))
        case .workerAdd(let q):
            // What `doz worker add …` sends.
            var r = HostRequest(.workerAdd)
            r.workerRequest = q
            return r
        case .workerEnd(let w, let n):
            // What `doz worker end W NAME` sends (never --rm from a browser).
            var r = HostRequest(.workerEnd)
            r.workerRequest = WorkerRequest(workspace: w, name: n)
            return r
        case .workspaceLifecycle(let v, let w):
            // What `doz workspace VERB W --if-plan SHA [flags]` sends, plus the confirmations the daemon then requires.
            var e = w
            e.confirmRequired = true
            var r = HostRequest(v.hostOp)
            r.workspaceRequest = e
            return r
        }
    }

    /// What `doz bot …` sends, with `heldOnly`: the daemon refuses, before anything is touched, whatever would make a token
    /// to show once (the CLI never sets it).
    static func botRequest(_ op: HostOp, _ b: BotRequest) -> HostRequest {
        var b = b
        b.heldOnly = true
        var r = HostRequest(op)
        r.botRequest = b
        return r
    }

    // MARK: strict decoding

    public struct Invalid: Error, Equatable, Sendable {
        public let message: String
        init(_ m: String) { message = m }
    }

    /// Fields each action may carry (besides `action`).
    static let fields: [String: Set<String>] = {
        var f: [String: Set<String>] = [
            "create": ["sandbox", "image", "cpus", "memoryMiB", "folder", "isolated", "network", "subnet", "account", "rebuild", "dockerfile", "permissions", "sites",
                       "modelSource", "model", "localPort"],
            "open-session": ["sandbox", "session", "argv"],
            "point-take": ["sandbox", "point", "note"],
            "point-revert": ["sandbox", "point", "confirm"],
            "point-fork": ["sandbox", "point", "newName"],
            "point-rm": ["sandbox", "point", "confirm"],
            "point-save-image": ["sandbox", "point", "image", "note"],
            "template-create": ["sandbox", "point", "image", "note"],
            "duplicate": ["sandbox", "newName", "point", "folder", "isolated", "cpus", "memoryMiB", "network", "account", "copyState"],
            "image-bake": ["image"],
            "image-rm": ["image", "confirm"],
            "net-policy": ["sandbox", "preset", "allow", "deny", "remove", "grant", "revoke"],
            "key-policy": ["sandbox", "policy"],
            "key-rm": ["sandbox", "binding"],
            "account-use": ["sandbox", "account"],
            "account-default": ["account"],
            "account-keepalive": ["enabled"],
            "account-verify": ["account"],
            "account-refresh": ["account"],
            "account-edit": ["account", "newName", "plan"],
            "account-rm": ["account", "confirm"],
            "onboard": ["images", "base"],
            "prepare-cancel": ["images", "base"],
            "resources-rm": ["ids"],
            "resources-clean": [],
            "resources-kernel": ["kernel"],
            "daemon-start": [],
            "daemon-restart": [],
            "builder-start": [],
            "builder-install": [],
            "tools-apply": ["sandbox"],
            "session-end": ["sandbox", "session"],
            "session-restart": ["sandbox", "session", "fresh"],
            "mac-session-end": ["session", "confirm"],
            "mac-session-forget": ["session"],
            "mac-sessions-forget-ended": ["sessions"],
            "mac-session-restart": ["session", "fresh", "confirm"],
            "mac-session-resume": ["session"],
            "mac-session-bridges": ["session", "openURL", "openFiles", "clipboard"],
            "mac-net-policy": ["session", "grant"],
            "files-mkdir": ["sandbox", "path"],
            "files-new": ["sandbox", "path"],
            "files-move": ["sandbox", "path", "to"],
            "files-rm": ["sandbox", "path", "recursive", "confirm"],
            "rename": ["sandbox", "newName"],
            "sandbox-setting": ["sandbox", "key", "value", "clear"],
            "workspace-brief": ["workspace", "brief", "ifBrief"],
            "workspace-adopt": ["workspace", "agent", "as"],
            "workspace-new": WebWorkspaceNew.fields,
            "workspace-start": ["workspace", "actsAsYou"],
            "workspace-release": ["workspace", "agent"],
            "bot-new": ["name", "agent", "model", "account", "avatar", "isolation", "deliver", "webhookEntry", "session", "skills", "instructions"],
            "bot-set": ["name", "model", "account", "avatar", "skills", "instructions", "isolation", "deliver", "webhookEntry", "session"],
            "bot-retire": ["name", "confirm"],
            "bot-adopt": ["name", "agent", "model", "isolation", "deliver", "confirm"],
            "bot-token": ["name", "confirm"],
            "worker-add": WebWorkerAdd.fields,
            "worker-end": ["workspace", "name", "confirm"],
            "workspace-stop": ["workspace", "ifPlan"],
            "workspace-sleep": ["workspace", "ifPlan"],
            "workspace-wake": ["workspace", "ifPlan", "actsAsYou"],
            "workspace-finish": ["workspace", "ifPlan"],
            "workspace-reopen": ["workspace", "ifPlan"],
            "workspace-archive": ["workspace", "ifPlan", "removeSandboxes", "keepTemplates", "confirm"],
            "workspace-restore": ["workspace", "ifPlan"],
            "workspace-delete": ["workspace", "ifPlan", "removeSandboxes", "binFolders", "confirm"],
        ]
        for (verb, op) in lifecycleOps { f[verb] = [.reset, .rm].contains(op) ? ["sandbox", "confirm"] : ["sandbox"] }
        return f
    }()

    public static var actionNames: [String] { fields.keys.sorted() }

    /// 650: `POST /api/v1/actions`'s body — the action, and the envelope's `batch` (true from the page's bulk controls:
    /// such an operation waits behind a person's own; any action may carry it, and it is the only field beside the
    /// action's own).
    public struct Request: Equatable, Sendable {
        public var action: WebAction
        public var batch: Bool
    }

    public static func decodeRequest(_ body: Data) throws -> Request { try decode(body, allowBatch: true) }

    /// Decode a request body. Throws `Invalid` with a fixed message (the value is never echoed).
    public static func decode(_ body: Data) throws -> WebAction { try decode(body, allowBatch: false).action }

    private static func decode(_ body: Data, allowBatch: Bool) throws -> Request {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw Invalid("the body must be a JSON object")
        }
        guard let verb = d["action"] as? String, let allowed = fields[verb] else { throw Invalid("unknown action") }
        var batch = false
        if allowBatch, let v = d["batch"] {
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("batch: true or false") }
            batch = b
        }
        let extra = Set(d.keys).subtracting(allowed).subtracting(allowBatch ? ["action", "batch"] : ["action"])
        guard extra.isEmpty else { throw Invalid("unexpected field(s) for \(verb): \(extra.sorted().joined(separator: ", "))") }
        let f = Fields(d)
        let a: WebAction
        switch verb {
        case "create":
            var o = CreateOptions(image: try f.image("image"), cpus: try f.int("cpus", 1...64), memoryMiB: try f.int("memoryMiB", 256...262_144).map(UInt64.init),
                                  folder: try f.workspace("folder"), network: try f.oneOf("network", ["agent", "bake", "locked", "open", "nat", "none"]),
                                  subnet: try f.subnet("subnet"), account: try f.accountRef("account", allowDefault: true))
            o.isolated = try f.flag("isolated")
            // 594 W28: the New Sandbox form's "Rebuild first" (an out-of-date image is otherwise used as it is).
            o.rebuild = try f.flag("rebuild")
            // 617 (models@1): the model source (a provider or gateway of this build) and the model — the host checks
            // that the agent is offered it and picks that source's key.
            o.modelSource = try f.oneOf("modelSource", ModelSources.publishedIds)   // 629: a NEW sandbox — published only
            o.model = try f.string("model", max: 128).map { m in
                guard ModelSelection.isModelID(m) else { throw Invalid("model: a model id (letters, digits and . _ : / @ + -)") }
                return m
            }
            // 660: a model server on this Mac — its port (the host refuses it for any other source).
            o.localPort = try f.int("localPort", MacModelServer.ports)
            // 597 (P4): the form's switches — exactly these permissions; its sites on top.
            if d["permissions"] != nil, !(d["permissions"] is NSNull) {
                let p = try f.permissionWords("permissions")
                guard !p.contains(where: { $0.hasPrefix("site:") || $0 == "install" }) else { throw Invalid("permissions: permission ids (sites go in sites)") }
                o.permissions = p
            }
            let sites = try f.permissionWords("sites")
            guard sites.allSatisfy({ $0.hasPrefix("site:") }) else { throw Invalid("sites: site:HOST or site:HOST:PORT each") }
            if !sites.isEmpty { o.allow = sites }
            // 596 (B6): a Dockerfile base — an absolute path (the host checks the file); the image then
            // only carries the agent (claude-code, pi or lab = none).
            if let df = try f.dockerfile("dockerfile") {
                guard ["claude-code", "pi", "codex", "lab"].contains(o.image) else { throw Invalid("dockerfile: goes with image claude-code, pi, codex or lab (the agent)") }
                o.dockerfile = df
            }
            guard !(o.isolated == true && o.folder != nil) else { throw Invalid("isolated: or a folder, not both") }
            a = .create(name: try f.sandbox("sandbox"), options: o)
        case "open-session":
            a = .openSession(name: try f.sandbox("sandbox"), session: try f.session("session"), argv: try f.argv("argv"))
        case "point-take":
            a = .pointTake(name: try f.sandbox("sandbox"), point: try f.pointRef("point"), note: try f.note("note"))
        case "point-revert":
            a = .pointRevert(name: try f.sandbox("sandbox"), point: try f.required(f.pointRef("point"), "point"))
        case "point-fork":
            a = .pointFork(name: try f.sandbox("sandbox"), point: try f.required(f.pointRef("point"), "point"), newName: try f.sandbox("newName"))
        case "point-rm":
            a = .pointRemove(name: try f.sandbox("sandbox"), point: try f.required(f.pointRef("point"), "point"))
        case "point-save-image":
            a = .pointSaveImage(name: try f.sandbox("sandbox"), point: try f.pointRef("point"), image: try f.customImage("image"), note: try f.note("note"))
        case "template-create":
            let image = try f.customImage("image")
            guard !DozableImages.builtIn.contains(image) else { throw Invalid("image: a built-in image's name is taken") }
            a = .templateCreate(name: try f.sandbox("sandbox"), point: try f.pointRef("point"), image: image, note: try f.note("note"))
        case "duplicate":
            var copy: Bool?
            if let v = d["copyState"], !(v is NSNull) {
                guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("copyState: true or false") }
                copy = b ? true : nil
            }
            var o = DuplicateOptions(folder: try f.workspace("folder"), cpus: try f.int("cpus", 1...64),
                                     memoryMiB: try f.int("memoryMiB", 256...262_144).map(UInt64.init),
                                     network: try f.oneOf("network", ["agent", "bake", "locked", "open", "nat", "none"]),
                                     account: try f.accountRef("account", allowDefault: true), copyState: copy)
            o.isolated = try f.flag("isolated")
            guard !(o.isolated == true && o.folder != nil) else { throw Invalid("isolated: or a folder, not both") }
            let name = try f.sandbox("sandbox"), new = try f.sandbox("newName")
            guard name != new else { throw Invalid("newName: a different name") }
            a = .duplicate(name: name, newName: new, point: try f.pointRef("point"), options: o)
        case "image-bake":
            // 596: any base × agent image (python-claude-code, go, df-…-pi) — by its canonical name.
            let i = try f.image("image")
            guard ["lab", "claude-code", "pi", "codex"].contains(i) || ImageChoice.parse(i)?.name == i else {
                throw Invalid("image: lab, claude-code, pi or a base × agent image")
            }
            a = .imageBake(i)
        case "image-rm":
            a = .imageRemove(try f.image("image"))
        case "net-policy":
            var e = WebPolicyEdit(preset: try f.oneOf("preset", ["locked", "bake", "agent", "open"]), allow: try f.hosts("allow"),
                                  deny: try f.hosts("deny"), remove: try f.hosts("remove"))
            e.grant = try f.permissionWords("grant")
            e.revoke = try f.permissionWords("revoke")
            guard !e.isEmpty else { throw Invalid("net-policy: nothing to change") }
            a = .netPolicy(name: try f.sandbox("sandbox"), edit: e)
        case "key-policy":
            a = .keyPolicy(name: try f.sandbox("sandbox"), policy: try f.required(f.oneOf("policy", ["allow", "strict", "auto"]), "policy"))
        case "key-rm":
            a = .keyRemove(name: try f.sandbox("sandbox"),
                           binding: try f.required(f.oneOf("binding", [CredentialBinding.anthropic.id, CredentialBinding.claudeOAuth.id]), "binding"))
        case "account-use":
            a = .accountUse(name: try f.sandbox("sandbox"), account: try f.required(f.accountRef("account", allowDefault: true), "account"))
        case "account-default":
            a = .accountDefault(try f.required(f.accountRef("account", allowDefault: false), "account"))
        case "account-keepalive":
            guard let on = d["enabled"] as? Bool, CFGetTypeID(d["enabled"] as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("enabled: true or false") }
            a = .accountKeepalive(on)
        case "account-verify":
            a = .accountVerify(try f.account("account"))
        case "account-refresh":
            a = .accountRefresh(try f.account("account"))
        case "account-edit":
            let acc = try f.account("account")
            guard acc != "mac" else { throw Invalid("account: the Mac login keeps its name and has no plan to set") }
            var new: String?
            if let n = try f.string("newName", max: 40) {
                guard (try? AccountStore.validateName(n)) != nil, n != "mac" else { throw Invalid("newName: an account name, 1–40 of a-z 0-9 - (not mac, default or none)") }
                new = n == acc ? nil : n
            }
            let plan = try f.oneOf("plan", ["max", "pro", "team", "enterprise"])
            guard new != nil || plan != nil else { throw Invalid("account-edit: nothing to change — newName or plan") }
            a = .accountEdit(acc, newName: new, plan: plan)
        case "account-rm":
            a = .accountRemove(try f.account("account"))
        case "onboard":
            a = .onboard(try f.builtInImages("images"), base: try f.oneOf("base", BaseCatalogue.ids))
        case "prepare-cancel":
            a = .prepareCancel(try f.builtInImages("images"), base: try f.oneOf("base", BaseCatalogue.ids))
        case "resources-rm":
            a = .resourcesRemove(try f.resourceIDs("ids"))
        case "resources-clean":
            a = .resourcesClean
        case "resources-kernel":
            let k = try f.required(f.string("kernel", max: 120), "kernel")
            guard k == "pinned" || (k.hasPrefix("kernel:") && Resources.isValidID(k)) else { throw Invalid("kernel: kernel:<version> or pinned") }
            a = .resourcesKernel(k)
        case "daemon-start":
            a = .hostStart
        case "daemon-restart":
            a = .hostRestart
        case "builder-start":
            a = .builderStart
        case "builder-install":
            a = .builderInstall
        case "tools-apply":
            a = .toolsApply(try f.sandbox("sandbox"))
        case "session-end":
            a = .sessionEnd(name: try f.sandbox("sandbox"), session: try f.required(f.session("session"), "session"))
        case "session-restart":
            a = .sessionRestart(name: try f.sandbox("sandbox"), session: try f.required(f.session("session"), "session"), fresh: try f.flag("fresh") == true)
        case "mac-session-end", "mac-session-restart":
            guard let s = try f.session("session"), WebRoute.isMacSessionName(s) else {
                throw Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)")
            }
            a = verb == "mac-session-end" ? .macSessionEnd(session: s) : .macSessionRestart(session: s, fresh: try f.flag("fresh") == true)
        case "mac-session-forget":
            guard let s = try f.session("session"), WebRoute.isMacSessionName(s) else {
                throw Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)")
            }
            a = .macSessionForget(session: s)
        case "mac-sessions-forget-ended":
            guard let v = d["sessions"] as? [Any], (1...64).contains(v.count) else { throw Invalid("sessions: the 1–64 ended sessions the page showed") }
            var ss: [String] = []
            for x in v {
                guard let s = x as? String, WebRoute.isMacSessionName(s), !ss.contains(s) else {
                    throw Invalid("sessions: sessions on this Mac, each once — 1–32 of letters, digits . _ - (not starting with .)")
                }
                ss.append(s)
            }
            a = .macSessionsForgetEnded(sessions: ss)
        case "mac-session-resume", "mac-session-bridges":
            guard let s = try f.session("session"), WebRoute.isMacSessionName(s) else {
                throw Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)")
            }
            if verb == "mac-session-resume" {
                a = .macSessionResume(session: s)
            } else {
                let url = try f.bool("openURL"), files = try f.bool("openFiles"), clip = try f.bool("clipboard")
                guard url != nil || files != nil || clip != nil else { throw Invalid("mac-session-bridges: nothing to change — openURL, openFiles or clipboard") }
                a = .macSessionBridges(session: s, openURL: url, openFiles: files, clipboard: clip)
            }
        case "mac-net-policy":
            guard let s = try f.session("session"), WebRoute.isMacSessionName(s) else {
                throw Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)")
            }
            let g = try f.permissionWords("grant")
            guard !g.isEmpty, g.count <= 8 else { throw Invalid("grant: 1–8 sites, each site:HOST[:PORT]") }
            guard g.allSatisfy({ $0.hasPrefix("site:") }) else { throw Invalid("grant: only site:HOST[:PORT] — a permission is changed in a terminal on this Mac") }
            a = .macNetPolicy(session: s, grant: g)
        case "files-mkdir":
            a = .filesMkdir(name: try f.sandbox("sandbox"), path: try f.fileItem("path"))
        case "files-new":
            a = .filesNew(name: try f.sandbox("sandbox"), path: try f.fileItem("path"))
        case "files-move":
            let p = try f.fileItem("path"), to = try f.fileItem("to")
            guard p != to else { throw Invalid("to: a different path") }
            a = .filesMove(name: try f.sandbox("sandbox"), path: p, to: to)
        case "files-rm":
            a = .filesRemove(name: try f.sandbox("sandbox"), path: try f.fileItem("path"), recursive: try f.flag("recursive") == true)
        case "rename":
            let name = try f.sandbox("sandbox"), new = try f.sandbox("newName")
            guard name != new else { throw Invalid("newName: a different name") }
            a = .rename(name: name, newName: new)
        case "sandbox-setting":
            // 669: a per-sandbox key (closed list) and a plain word — the host checks the value against the setting's type.
            guard let key = try f.string("key", max: 64), DozableSettings.sandboxKeys.contains(key) else {
                throw Invalid("key: a per-sandbox setting (\(DozableSettings.sandboxKeys.joined(separator: ", ")))")
            }
            let value = try f.matching("value", "^[a-z0-9_-]{1,32}$", "a setting's word, 1–32 of a-z 0-9 _ -")
            let clear = try f.flag("clear") == true
            guard (value != nil) != clear else { throw Invalid("value, or clear: true — one of them") }
            a = .sandboxSetting(name: try f.sandbox("sandbox"), key: key, value: value)
        case "workspace-brief":
            guard let w = try f.string("workspace", max: 40), WorkspaceName.isValid(w) else {
                throw Invalid("workspace: 1–40 characters of a-z, 0-9 and -, not starting with -")
            }
            let sha = try f.required(f.matching("ifBrief", "^[0-9a-f]{64}$", "the brief's sha256 as read, 64 lower-case hex digits"), "ifBrief")
            a = .workspaceBrief(workspace: w, brief: try f.brief("brief"), ifBrief: sha)
        case "workspace-adopt":
            let asName = try f.string("as", max: 64)
            if let n = asName, !WorkspaceName.isValidAgent(n) {
                throw Invalid("as: an agent name, 1–64 of letters, digits . _ - (not starting with - or .)")
            }
            a = .workspaceAdopt(workspace: try f.workspaceName("workspace"), agent: try f.agentPlace("agent"), asName: asName)
        case "workspace-new":
            let (w, fromProject) = try WebWorkspaceNew.decode(f, forPlan: false)
            a = .workspaceNew(w, fromProject: fromProject)
        case "workspace-start":
            a = .workspaceStart(workspace: try f.workspaceName("workspace"), actsAsYou: try f.flag("actsAsYou") == true)
        case "workspace-release":
            guard let s = try f.string("agent", max: 64 + 5), WorkspaceName.isValidAgent(s) || Fields.isMacPlace(s) else {
                throw Invalid("agent: its name in the workspace, or @mac/SESSION")
            }
            a = .workspaceRelease(workspace: try f.workspaceName("workspace"), agent: s)
        case "bot-new":
            let n = try f.botName("name")
            var b = try f.botFields(n)
            b.agent = try f.botAgent("agent")
            // The isolation is chosen in the form, never assumed (unfenced only when picked: it acts as you).
            b.isolation = try f.required(try f.botIsolation("isolation", n, verb: "new", agent: b.agent), "isolation")
            a = .botNew(b)
        case "bot-set":
            let n = try f.botName("name")
            var b = try f.botFields(n)
            b.isolation = try f.botIsolation("isolation", n, verb: "set", agent: nil)
            guard b.model != nil || b.account != nil || b.avatar != nil || b.skills != nil || b.instructions != nil || b.isolation != nil
                    || b.deliver != nil else { throw Invalid("bot-set: nothing to change") }
            a = .botSet(b)
        case "bot-retire":
            a = .botRetire(name: try f.botName("name"))
        case "bot-adopt":
            let n = try f.botName("name")
            var b = BotRequest(name: n)
            b.agent = try f.botAgent("agent")
            b.model = try f.botModel("model")
            b.isolation = try f.botIsolation("isolation", n, verb: "adopt", agent: b.agent)
            b.deliver = try f.oneOf("deliver", ChatDirectory.deliveries)
            a = .botAdopt(b)
        case "bot-token":
            a = .botToken(name: try f.botName("name"))
        case "worker-add":
            a = .workerAdd(try WebWorkerAdd.decode(f, forPlan: false))
        case "worker-end":
            a = .workerEnd(workspace: try f.workspaceName("workspace"), name: try f.botName("name"))
        case "workspace-stop", "workspace-sleep", "workspace-wake", "workspace-finish", "workspace-reopen", "workspace-archive",
             "workspace-restore", "workspace-delete":
            guard let v = WorkspaceVerb(rawValue: String(verb.dropFirst("workspace-".count))) else { throw Invalid("unknown action") }
            var w = WorkspaceRequest(name: try f.workspaceName("workspace"))
            w.ifPlan = try f.required(f.matching("ifPlan", "^[0-9a-f]{16}$", "the plan's sha as shown, 16 lower-case hex digits"), "ifPlan")
            w.removeSandboxes = try f.bool("removeSandboxes") == true ? true : nil
            w.keepTemplates = try f.bool("keepTemplates") == false ? false : nil
            w.binFolders = try f.bool("binFolders") == true ? true : nil
            w.unfencedConfirmed = try f.flag("actsAsYou") == true ? true : nil
            w.confirm = try f.string("confirm", max: 40)
            a = .workspaceLifecycle(v, w)
        default:
            guard let op = lifecycleOps[verb] else { throw Invalid("unknown action") }
            a = .lifecycle(op, name: try f.sandbox("sandbox"))
        }
        if let target = a.confirmationTarget {
            guard let c = d["confirm"] as? String, c == target else {
                if case .workerAdd = a { throw Invalid("worker-add: an unfenced worker acts as you — confirm it (confirm: unfenced)") }
                throw Invalid("\(verb) is destructive: confirm it (the name)")
            }
        } else if case .workerAdd = a, d["confirm"] != nil, !(d["confirm"] is NSNull) {
            throw Invalid("confirm goes with an unfenced worker only")
        }
        return Request(action: a, batch: batch)
    }

    /// Typed field readers — each enforces the rule the CLI or the library would.
    struct Fields {
        let d: [String: Any]
        init(_ d: [String: Any]) { self.d = d }

        func required<T>(_ v: T?, _ key: String) throws -> T {
            guard let v else { throw Invalid("\(key) is required") }
            return v
        }

        func string(_ key: String, max: Int = 256) throws -> String? {
            guard let v = d[key] else { return nil }
            if v is NSNull { return nil }
            guard let s = v as? String else { throw Invalid("\(key) must be a string") }
            guard !s.isEmpty, s.count <= max, !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw Invalid("\(key): 1–\(max) characters, no control characters")
            }
            return s
        }

        func matching(_ key: String, _ pattern: String, _ rule: String) throws -> String? {
            guard let s = try string(key) else { return nil }
            guard s.range(of: pattern, options: .regularExpression) != nil else { throw Invalid("\(key): \(rule)") }
            return s
        }

        // MARK: Agents / Bots — the CLI's rules (BotName, AgentRef, the account, ModelSelection, BotFields)

        /// A bot's name by the chat rule (`ChatNames`); never echoed.
        func botName(_ key: String) throws -> String {
            guard let n = try string(key, max: 40), ChatNames.refusal(n) == nil else {
                throw Invalid("\(key): a lower-case letter, then lower-case letters, digits and -, at most 40")
            }
            return n
        }

        /// An agent program as `doz bot new --agent` takes it (`AgentRef.resolve`: claude-code, codex, …).
        func botAgent(_ key: String) throws -> String {
            guard let s = try string(key, max: 80), (try? AgentRef.resolve(s)) != nil else {
                throw Invalid("\(key): an agent program (claude-code, codex, … — doz search)")
            }
            return s
        }

        func botModel(_ key: String) throws -> String? {
            try string(key, max: 120).map { m in
                guard ModelSelection.isModelID(m), (try? BotFields.checkModel(m)) != nil else {
                    throw Invalid("\(key): a model id (letters, digits and . _ : / @ + -)")
                }
                return m
            }
        }

        /// Where it runs: vm, fenced or unfenced. A bot elsewhere gets its token in a terminal only — refused here with its
        /// command (the name is already checked; the value is never echoed).
        func botIsolation(_ key: String, _ name: String, verb: String, agent: String?) throws -> String? {
            guard let s = try string(key, max: 16) else { return nil }
            if s == "elsewhere" {
                let plain = agent.flatMap { $0.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil ? $0 : nil }
                let rest = verb == "set" ? "" : " --agent \(plain ?? "AGENT")"
                throw Invalid("\(key): a bot elsewhere gets its token in a terminal on this Mac: doz bot \(verb) \(name)\(rest) --isolation elsewhere --to-file F")
            }
            guard ["vm", "fenced", "unfenced"].contains(s) else { throw Invalid("\(key): vm, fenced or unfenced") }
            return s
        }

        /// The fields `new` and `set` share: model, account, avatar, delivery (and its entry or session), skills, instructions.
        func botFields(_ name: String) throws -> BotRequest {
            var b = BotRequest(name: name)
            b.model = try botModel("model")
            b.account = try string("account", max: 40).map { a in
                guard (try? AccountStore.validateName(a)) != nil || a == "mac" else { throw Invalid("account: an account's name (doz account ls), or mac") }
                return a
            }
            b.avatar = try string("avatar", max: 64).map { v in
                guard (try? BotFields.checkAvatar(v)) != nil else { throw Invalid("avatar: 1–64 characters, no line breaks") }
                return v
            }
            b.deliver = try oneOf("deliver", ChatDirectory.deliveries)
            b.webhookEntry = try string("webhookEntry", max: 40).map { e in
                guard ChatWebhookEntries.nameRefusal(e) == nil else { throw Invalid("webhookEntry: an entry's name, as doz chat webhook set takes it") }
                return e
            }
            b.session = try string("session", max: MacPlace.maximumSessionName).map { s in
                guard WebRoute.isMacSessionName(s) else { throw Invalid("session: a session's name on this Mac") }
                return s
            }
            if let v = d["skills"], !(v is NSNull) {
                guard let list = v as? [Any], let skills = list as? [String], (try? BotFields.checkSkills(skills)) != nil else {
                    throw Invalid("skills: a list of skills' names (a-z, 0-9, - and _), at most \(BotFields.maximumSkills), none twice")
                }
                b.skills = skills
            }
            b.instructions = try botInstructions("instructions")
            return b
        }

        /// The instructions: text (line breaks and tabs, no other control character), UTF-8 within the store's 256 KiB — the
        /// actions' 16 KiB body is the real limit from a browser (beyond it: `doz bot set NAME --instructions-file F`). Empty
        /// clears them.
        func botInstructions(_ key: String) throws -> String? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let s = v as? String else { throw Invalid("\(key) must be a string") }
            guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0) }) else {
                throw Invalid("\(key): no control characters but line breaks and tabs")
            }
            guard (try? BotFields.checkInstructions(Data(s.utf8))) != nil else { throw Invalid("\(key): at most 256 KiB of text") }
            return s
        }

        /// A workspace's name by the store's rule.
        func workspaceName(_ key: String) throws -> String {
            guard let w = try string(key, max: 40), WorkspaceName.isValid(w) else {
                throw Invalid("\(key): 1–40 characters of a-z, 0-9 and -, not starting with -")
            }
            return w
        }

        /// An agent as a person types it to file it: a sandbox's name, or `@mac/SESSION` (never a bare `@mac`).
        func agentPlace(_ key: String) throws -> String {
            guard let s = try string(key, max: 64), WebRoute.isSandboxName(s) || Self.isMacPlace(s) else {
                throw Invalid("\(key): a sandbox's name, or @mac/SESSION")
            }
            return s
        }

        static func isMacPlace(_ s: String) -> Bool {
            s.hasPrefix(MacPlace.name + "/") && WebRoute.isMacSessionName(String(s.dropFirst(MacPlace.name.count + 1)))
        }

        func sandbox(_ key: String) throws -> String {
            guard let s = try string(key), WebRoute.isSandboxName(s) else { throw Invalid("\(key): a sandbox name, 1–40 of a-z 0-9 -") }
            return s
        }

        func session(_ key: String) throws -> String? {
            guard let s = try string(key, max: 64) else { return nil }
            do { try GuestCommand.validateSessionName(s) } catch { throw Invalid("\(key): 1–64 of letters, digits . _ - (not starting with .)") }
            return s
        }

        func image(_ key: String) throws -> String {
            try required(matching(key, "^[a-z0-9][a-z0-9-]{0,39}$", "an image name (lab, claude-code, pi or a custom image)"), key)
        }

        func customImage(_ key: String) throws -> String {
            try required(matching(key, "^[a-z0-9][a-z0-9-]{0,39}$", "an image name: 1–40 of a-z 0-9 -"), key)
        }

        func pointRef(_ key: String) throws -> String? {
            try matching(key, "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", "a restore point's name or id")
        }

        func note(_ key: String) throws -> String? { try string(key, max: 200) }

        func oneOf(_ key: String, _ values: [String]) throws -> String? {
            guard let s = try string(key) else { return nil }
            guard values.contains(s) else { throw Invalid("\(key): one of \(values.joined(separator: ", "))") }
            return s
        }

        func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
                  range.contains(n.intValue) else { throw Invalid("\(key): a whole number \(range.lowerBound)–\(range.upperBound)") }
            return n.intValue
        }

        func account(_ key: String) throws -> String {
            guard let s = try string(key, max: 40), (try? AccountStore.validateName(s)) != nil || s == "mac" else {
                throw Invalid("\(key): an account name, 1–40 of a-z 0-9 -")
            }
            return s
        }

        func accountRef(_ key: String, allowDefault: Bool) throws -> String? {
            guard let s = try string(key, max: 40) else { return nil }
            if s == "none" || (allowDefault && s == "default") { return s }
            guard s.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil, s != "default" else {
                throw Invalid("\(key): an account name\(allowDefault ? ", default" : "") or none")
            }
            return s
        }

        /// 594: a list of built-in images (lab, claude-code, pi), each at most once; absent = empty.
        func builtInImages(_ key: String) throws -> [String] {
            guard let v = d[key], !(v is NSNull) else { return [] }
            guard let a = v as? [Any], a.count <= 3 else { throw Invalid("\(key): a list of lab, claude-code, pi") }
            var out: [String] = []
            for x in a {
                guard let s = x as? String, DozableImages.builtIn.contains(s), !out.contains(s) else { throw Invalid("\(key): lab, claude-code, pi — each once") }
                out.append(s)
            }
            return out
        }

        /// 595: resource ids (`Resources.isValidID`), 1–500, each once.
        func resourceIDs(_ key: String) throws -> [String] {
            guard let a = d[key] as? [Any], (1...500).contains(a.count) else { throw Invalid("\(key): a list of 1–500 resource ids") }
            var out: [String] = []
            for x in a {
                guard let s = x as? String, Resources.isValidID(s), !out.contains(s) else { throw Invalid("\(key): resource ids as the Resources page lists them, each once") }
                out.append(s)
            }
            return out
        }

        func subnet(_ key: String) throws -> String? {
            try matching(key, #"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$"#, "an IPv4 CIDR, like 192.168.120.0/24")
        }

        /// A host folder shared at /workspace: an absolute path (or ~/…), one line. 594: it need not
        /// exist — the host makes it (`Workspace.prepare`), and refuses a file, the store, a system
        /// location, / and the home folder itself.
        func workspace(_ key: String) throws -> String? {
            guard let s = try string(key, max: 1024) else { return nil }
            guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Invalid("\(key): one line, no control characters") }
            guard s.hasPrefix("/") || s.hasPrefix("~/") else { throw Invalid("\(key): an absolute path (or ~/…)") }
            do { return try Workspace.normalize(s) } catch { throw Invalid("\(key): an absolute path (or ~/…)") }
        }

        /// 596: a Dockerfile — an absolute path (or ~/…) of one line, not a folder's trailing slash.
        func dockerfile(_ key: String) throws -> String? {
            guard let p = try workspace(key) else { return nil }
            guard !p.hasSuffix("/") else { throw Invalid("\(key): a file, not a folder") }
            return p
        }

        /// 594: true, or absent.
        func flag(_ key: String) throws -> Bool? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("\(key): true or false") }
            return b ? true : nil
        }

        /// A switch's value as given (false stays false; absent or null: nil).
        func bool(_ key: String) throws -> Bool? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("\(key): true or false") }
            return b
        }

        /// Hosts for the policy: exact, `*.domain`, `host:port`, or an IPv4 CIDR; ≤ 32.
        func hosts(_ key: String) throws -> [String] {
            guard let v = d[key], !(v is NSNull) else { return [] }
            guard let a = v as? [Any], a.count <= 32 else { throw Invalid("\(key): a list of at most 32 hosts") }
            return try a.map { x in
                guard let s = x as? String, s.count <= 253,
                      s.range(of: #"^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:\d{1,5}(,\d{1,5})*)?$|^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$"#,
                              options: .regularExpression) != nil else {
                    throw Invalid("\(key): a host (example.com, *.example.com, host:443) or an IPv4 CIDR")
                }
                return s
            }
        }

        /// 597: permission ids (`install:python`, `web`, `install`) or `site:HOST`; ≤ 32, each once.
        func permissionWords(_ key: String) throws -> [String] {
            guard let v = d[key], !(v is NSNull) else { return [] }
            guard let a = v as? [Any], a.count <= 32 else { throw Invalid("\(key): a list of at most 32 permissions") }
            var out: [String] = []
            for x in a {
                guard let s = x as? String, s.count <= 260 else { throw Invalid("\(key): a permission id or site:HOST") }
                if s.hasPrefix("site:") {
                    do { _ = try PermissionPolicy.site(s) } catch { throw Invalid("\(key): " + HostError.from(error).message) }
                } else {
                    guard s == "install" || AgentPermissions.isValid(s) else { throw Invalid("\(key): a permission id (doz net permissions) or site:HOST") }
                }
                guard !out.contains(s) else { throw Invalid("\(key): each once") }
                out.append(s)
            }
            return out
        }

        /// 644: a file or folder of /workspace (never /workspace itself) → its guest path, `/workspace/…`.
        func fileItem(_ key: String) throws -> String {
            guard let s = try string(key, max: FileListPaths.maximumPathBytes), let item = FileItemPath.parse(s) else {
                throw Invalid("\(key): a file or folder in /workspace (not /workspace itself)")
            }
            return item.guest
        }

        /// A workspace's brief: text (lines and tabs allowed, no other control character), not blank, at most what the store
        /// keeps (the request body's 16 KiB is the real limit from a browser — the CLI takes up to 256 KiB).
        func brief(_ key: String) throws -> String {
            guard let v = d[key], let s = v as? String else { throw Invalid("\(key) is required: the brief's text") }
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid("\(key): the brief is empty") }
            guard s.utf8.count <= WorkspaceStore.maximumBriefBytes else { throw Invalid("\(key): at most 256 KiB") }
            guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0) }) else {
                throw Invalid("\(key): no control characters but line breaks and tabs")
            }
            return s
        }

        /// A detached session's program: 1–64 arguments, no NUL, ≤ 4 KiB each, 16 KiB in all.
        func argv(_ key: String) throws -> [String]? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let a = v as? [Any], (1...64).contains(a.count) else { throw Invalid("\(key): 1–64 arguments") }
            let out = try a.map { x -> String in
                guard let s = x as? String, !s.isEmpty, s.utf8.count <= 4096, !s.contains("\0") else {
                    throw Invalid("\(key): each argument a non-empty string of at most 4 KiB")
                }
                return s
            }
            guard out.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { throw Invalid("\(key): at most 16 KiB in all") }
            return out
        }
    }
}

/// A network-policy change, as `doz net policy` takes it.
public struct WebPolicyEdit: Equatable, Sendable {
    public var preset: String?
    public var allow: [String]
    public var deny: [String]
    public var remove: [String]
    /// 597 (P6): permissions switched on / off, or `site:HOST`.
    public var grant: [String] = []
    public var revoke: [String] = []

    public var isEmpty: Bool { preset == nil && allow.isEmpty && deny.isEmpty && remove.isEmpty && grant.isEmpty && revoke.isEmpty }

    public func request(_ name: String) -> HostRequest {
        var r = HostRequest(.netPolicy, name: name)
        r.preset = preset
        r.allow = allow
        r.deny = deny
        r.removeHosts = remove
        r.grant = grant.isEmpty ? nil : grant
        r.revoke = revoke.isEmpty ? nil : revoke
        return r
    }
}

/// `POST /api/v1/sandboxes/{name}/network/preview` — what the edit would make of the policy.
public struct WebPolicyPreview: Codable, Equatable, Sendable {
    public var before: WebPolicy
    public var after: WebPolicy
    public var added: [String]
    public var removed: [String]
    public var changed: Bool

    public init(before b: NetworkPolicy, after a: NetworkPolicy) {
        before = WebPolicy(b)
        after = WebPolicy(a)
        let bl = before.rules.map(\.label), al = after.rules.map(\.label)
        added = al.filter { !bl.contains($0) }
        removed = bl.filter { !al.contains($0) }
        changed = before != after
    }
}

/// One operation the UI started, as the page sees it (SSE `op`, `GET /api/v1/operations`).
public struct WebOperation: Codable, Equatable, Sendable {
    public var id: String
    public var action: String
    public var label: String
    public var sandbox: String?
    /// running, done, failed — or (605) interrupted: `doz ui` restarted while it ran and its outcome was
    /// not seen (an ended state, never a failure).
    public var state: String
    /// The latest progress line while running; the outcome after.
    public var text: String
    public var startedAt: Date
    public var milliseconds: Double?
    /// 594 W22: finished lines, for an operation that does several things at once (Restart host: each
    /// sandbox's hibernation — "✓ hibernated w1 (snapshot 40 MB) — 0.4 s").
    public var lines: [String]? = nil
    /// 605: started by an earlier `doz ui` that restarted while it ran (loaded from `ui.operations.json`).
    public var interrupted: Bool? = nil
    /// 617 (owner: "while the build completes, we should show the progress in that area"): the steps in plain words
    /// (StepWording), the one under way with when it began, and a short live tail of its output — what the sandbox
    /// page's progress panel draws in the terminal area until the session is there.
    public var progress: WebOpProgress? = nil
    /// 650: accepted and waiting its turn (`state` stays "running" — under way, to every page): nothing was sent to the
    /// host yet. `position`: its place in its lane, 1 = next.
    public var queued: Bool? = nil
    public var position: Int? = nil
}

/// 650: `POST /api/v1/operations/cancel` — strictly `{ids: [String]}`, 1–256 operation ids, each once. Not an action:
/// it sends nothing to the host (it withdraws what was not sent yet).
public struct WebOperationsCancel: Equatable, Sendable {
    public var ids: [String]

    public static func decode(_ body: Data) throws -> WebOperationsCancel {
        guard let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], Set(d.keys) == ["ids"] else {
            throw WebAction.Invalid("the body is {ids}")
        }
        guard let a = d["ids"] as? [Any], (1...WebOperations.maxQueued).contains(a.count) else {
            throw WebAction.Invalid("ids: a list of 1–\(WebOperations.maxQueued) operation ids")
        }
        var out: [String] = []
        for x in a {
            guard let s = x as? String, (1...64).contains(s.count),
                  s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), !out.contains(s) else {
                throw WebAction.Invalid("ids: operation ids as Operations lists them, each once")
            }
            out.append(s)
        }
        return WebOperationsCancel(ids: out)
    }
}

/// 650: what a cancel did — the ids withdrawn, and those that were not waiting (running, ended or unknown: unchanged).
public struct WebOperationsCancelled: Codable, Equatable, Sendable {
    public var cancelled: [String]
    public var notQueued: [String]
}

public struct WebOpProgress: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var text: String
        public var seconds: Double?
        public var failed: Bool?
    }
    /// Finished steps, in order (at most the last 40).
    public var steps: [Step] = []
    /// The step under way, in present-tense words, and when it began.
    public var current: String?
    public var since: Date?
    /// A download's progress, said plainly ("312 MiB of 640 MiB").
    public var transfer: String?
    /// The last lines of a build's output (inert text, at most 3).
    public var tail: [String] = []

    public init() {}

    /// One host event folded in.
    public mutating func apply(_ e: HostEvent) {
        let label = e.text ?? ""
        switch e.kind {
        case .started:
            current = StepWording.of(label).running
            since = e.time
            transfer = nil
            tail = []
        case .step:
            steps.append(Step(text: StepWording.of(label).done, seconds: e.milliseconds.map { $0 / 1000 }))
            current = nil; since = nil; transfer = nil
        case .failed:
            steps.append(Step(text: StepWording.of(e.startedAs ?? label).running.replacingOccurrences(of: "…", with: "") + (e.error.map { " — \($0)" } ?? ""),
                              seconds: e.milliseconds.map { $0 / 1000 }, failed: true))
            current = nil; since = nil; transfer = nil
        case .output:
            let line = InertText.line(Substring(label))
            if !line.isEmpty { tail = Array((tail + [line]).suffix(3)) }
        case .progress:
            if let c = e.completedBytes, let t = e.totalBytes, t > 0 {
                transfer = "\(ProgressFormat.bytes(c)) of \(ProgressFormat.bytes(t))"
            }
        default:
            break
        }
        if steps.count > 40 { steps.removeFirst(steps.count - 40) }
    }
}
