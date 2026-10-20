import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost

// 594 — `doz onboard` (this Mac, once) and `doz init` (a project folder). Design: workspace
// changes/594-*/594.01-DESIGN.md, D1–D10. 634 (owner: "focus a single base image"; the setup v2): the steps are
// Checks → Base image → Models & keys → Access → Workspace rules → Settings → (Usage statistics → Stay in touch) →
// First sandbox. The base downloads in the host from the Base image step on, while the questions go on; its
// progress is said only between steps, never under a question.

/// What `doz onboard --json` prints.
struct OnboardReport: Encodable {
    var store: String
    var checks: [OnboardingCheck]
    /// 634: the store's base prepared by this onboarding (nil: none now — `--no-base`, or "n").
    var base: String?
    /// The sign-ins found on this Mac (`claude`, `codex`).
    var signIns: [String]
    /// The accounts the Models & keys step added (names; never a secret).
    var keysAdded: [String]
    /// 599i: the OpenAI account Codex's sign-in step added (and made the OpenAI default).
    var openaiAccountAdded: String? = nil
    var settings: String
    var settingsPath: String?
    var promptTemplate: String
    var promptTemplatePath: String?
    /// 599e: the Access step — each credential's choice and whether it was confirmed.
    var access: [AccessItem]
    /// 599g: the Workspace rules step — the default `workspace.ignore_mode` chosen (nil: not chosen, unchanged).
    var ignoreMode: String?
    var result: PrepareResult?
    /// The Usage statistics step: on or off after it (nil: not shown — a build from the open-source repository).
    var usageStats: String? = nil
    /// 634: the First sandbox made (nil: none).
    var first: String? = nil
}

/// The onboarding itself, shared by `doz onboard` and `doz init` (which onboards first when this
/// store never was — with no First sandbox: it makes its own project's).
struct OnboardingFlow {
    let g: GlobalOptions
    let asker: Asker
    /// Print human output (false: `--json`, or `init` doing it quietly).
    let talk: Bool
    /// 634: `--base ID` (nil: asked on a terminal; else the store's — Node.js unless set). `--no-base`: none now.
    var baseFlag: String? = nil
    var noBase = false
    /// 634: `--key PROVIDER` (anthropic, openai, xai, google, openrouter, setup-token) with its name, a setup token's
    /// plan, the secret from stdin, replace.
    var keyFlag: String? = nil
    var keyName: String? = nil
    var plan: String? = nil
    var secretStdin = false
    var force = false
    /// 634: `--first AGENT|none` (nil: asked on a terminal; else none).
    var firstFlag: String? = nil
    /// 599e: the Access step's flags (nil: asked on a terminal, else left as the settings are).
    var githubFlag: String? = nil
    var githubSourceFlag: String? = nil
    var sshFlag: String? = nil
    var githubKeyStdin = false
    /// 599g: the Workspace rules step's flag (nil: asked on a terminal, else the settings are left as they are).
    var ignoreModeFlag: String? = nil
    /// `--usage-stats on|off`: the Usage statistics step's answer without asking.
    var usageStatsFlag: Bool? = nil
    /// 599i: Codex's OpenAI account — mac, chatgpt, openai-key or later (nil: offered in Models & keys on a terminal).
    var openaiFlag: String? = nil

    /// 634: the words the First sandbox step offers, and the tools they name (`doz try`'s names).
    static let firstWords: [(word: String, ref: String)] = [("claude", "claude-code"), ("pi", "pi"), ("opencode", "opencode"), ("codex", "codex")]

    /// 634: a First sandbox's tool from what was typed (`claude`, `opencode@1`, `claude-code` …); nil: none such.
    static func firstTool(_ typed: String) -> AgentRecipe? {
        let ref = firstWords.first { $0.word == typed.lowercased() }?.ref ?? typed
        return (try? AgentRef.resolve(ref))?.recipe
    }

    /// Usage statistics (official builds only), just before Stay in touch: what is sent, where to see it, and the
    /// question — default Yes; the answer is written only when it changes the setting. Once shown, the one-line
    /// first-run notice is not printed as well. Returns on/off (nil: not shown).
    private func usageStatistics() -> String? {
        let env = ProcessInfo.processInfo.environment
        let step = UsageStatsStep.make(official: Usage.isOfficial, settings: DozableSettings.load(environment: env), env: env)
        guard step != nil else { return nil }
        if talk {
            say("\n\(UsageStatsStep.title)")
            say("  " + UsageStatsStep.summary)
            say("  To see exactly what is sent: \(UsageStatsStep.showCommand) · the privacy policy: \(Usage.privacyPage)")
            // Shown here: the first-run notice would only repeat it.
            UsageStatsPrompt.markNoticeShown(UsageFiles.current(env))
        }
        let d = UsageStatsPrompt.decide(step, flag: usageStatsFlag, interactive: asker.interactive && talk) {
            asker.yesNo("  " + UsageStatsStep.question, default: $0)
        }
        var saved = false, problem: String?
        if let v = d.write, let step {
            do { saved = !(try step.save(v, environment: env)).isEmpty } catch let e as SettingsError { problem = e.message } catch { problem = "\(error)" }
        }
        say(UsageStatsPrompt.outcome(d, flag: usageStatsFlag, saved: saved, error: problem))
        return (d.on ?? true) ? "on" : "off"
    }

    /// The optional sign-up — release news, early access, tips and tricks. Never blocks the onboarding: skipped by default,
    /// and a failure is one line.
    private func stayInTouch() async {
        guard talk else { return }
        guard Usage.isOfficial else {
            say("\nStay in touch (optional): release news, early access and tips and tricks — sign up at \(Usage.signupPage)")
            return
        }
        guard asker.interactive else { return }
        say("\nStay in touch (optional) — release news, early access, tips and tricks; your email is confirmed first and never linked to the usage statistics")
        guard asker.yesNo("  Sign up?", default: false) else { say("  skipped — doz signup any time"); return }
        do {
            guard let r = try SignupCommand.ask(asker, email: nil, interests: [], source: "onboarding-cli", g) else { return }
            let result = try await Usage.signup(r)
            say("  " + SignupCommand.answerLine(result, email: r.email))
        } catch {
            say("  the sign-up did not go through — doz signup tries again, or \(Usage.signupPage)")
        }
    }

    func say(_ s: String) { if talk { Out.stdout(s + "\n") } }

    func run() async throws -> OnboardReport {
        let store = g.dozableStore
        say("Dozable — setting up this Mac (once). Store: \(DisplayPath.tilde(store.root.path))\n")
        let storeBase = DozableSettings.load().string(SettingKey.defaultBase) ?? "node"
        var baseID: String? = noBase ? nil : (baseFlag ?? storeBase)
        func title(_ id: String) -> String { BaseCatalogue.base(id)?.title ?? id }

        // 1. Checks (D5): the doctor's, hard ones stop here; the disk line is the base's need.
        let status = try decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g)
        let doctor = Doctor.checks(store: store, claude: keyFlag == nil).map { (check: $0.check, status: $0.status.rawValue, detail: $0.detail) }
        func basePrepared(_ id: String) -> Bool { status.base?.id == id && status.base?.prepared == true }
        let checkBase = BaseCatalogue.base(baseID ?? storeBase) ?? BaseCatalogue.all[0]
        var checks = Onboarding.checks(doctor: doctor, store: store, base: checkBase, prepared: baseID == nil || basePrepared(checkBase.id))
        say("1. Checks")
        for c in checks { say(Self.checkLine(c)) }
        if keyFlag != nil { say("  —     claude          not checked (--key given)") }
        if let stop = checks.first(where: \.blocks) {
            say("")
            throw fail(HostError(.failed, "onboarding stopped: \(stop.check) — \(stop.detail)"), g)
        }

        // 2. Base image: every tool is added to it as a layer — downloaded and prepared in the host from now on.
        say("\n2. Base image — every tool you try is added to it as a layer, so it is downloaded once")
        if baseFlag == nil, !noBase, asker.interactive, let b = BaseCatalogue.base(storeBase) {
            var answer = asker.pick("  Use \(b.title) (\(Self.shortReference(b.reference)), ↓ \(DozableImages.formatBytes(b.downloadBytes)))?", ["y", "n", "other"], default: "y")
            if answer == "other" {
                for o in BaseCatalogue.all { say("    \(o.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(o.title) — \(o.useCase) (↓ \(DozableImages.formatBytes(o.downloadBytes)))") }
                answer = asker.text("  Which base", default: storeBase) { BaseCatalogue.base($0) == nil ? "one of: " + BaseCatalogue.ids.joined(separator: ", ") : nil }
            }
            baseID = answer == "n" ? nil : (answer == "y" ? storeBase : answer)
            if let id = baseID, let b = BaseCatalogue.base(id) {
                let disk = Onboarding.checks(doctor: [], store: store, base: b, prepared: basePrepared(id))
                if let stop = disk.first(where: \.blocks) { throw fail(HostError(.failed, "onboarding stopped: \(stop.check) — \(stop.detail)"), g) }
                checks = checks.filter { $0.check != "disk" } + disk.filter { $0.check == "disk" }
            }
        }
        if let id = baseID {
            var r = HostRequest(.onboard)
            r.base = id
            r.follow = false
            r.requestedBy = "doz onboard"
            let started = try decode(try call(r, g), PrepareResult.self, g)
            say(started.preparations.isEmpty ? "  \(title(id)) — ready in this store"
                                              : "  \(title(id)) — downloading and preparing in the host now; the questions go on (doz onboard --status watches it)")
        } else {
            say("  none now — each tool's first start prepares its own base")
        }
        // Its progress, said only between steps (once per change).
        var lastBaseLine: String?
        func baseProgress() async {
            guard talk, let id = baseID,
                  let st = try? decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g) else { return }
            guard let line = Self.baseLine(st, base: id), line != lastBaseLine else { return }
            lastBaseLine = line
            say("  · " + line)
        }

        // 3. Models & keys (634, owner: "the Open Router key was not accepted"): the sign-ins found on this Mac, then a
        //    key of any published provider or gateway — added exactly as `doz account add` adds one.
        await baseProgress()
        say("\n3. Models & keys — what the tools talk to")
        let claudeSignedIn = keyFlag == nil && ClaudeLoginStatus.check(configDir: nil, keychain: macLoginKeychain(), probeBinary: false).state == .signedIn
        let codexState = CodexMacLogin.read(CodexMacLogin.resolveHome()).state
        let codexSignedIn = codexState == .ok || codexState == .expired
        let chatgpt = BuildFlavor.current.chatgptSignIn
        say(claudeSignedIn ? "  Claude Code: signed in on this Mac — Claude Code sandboxes use that login (nothing is copied; the Mac renews it)"
                           : "  Claude Code: not signed in on this Mac — an Anthropic key below, or setup-token for a Claude subscription")
        say(codexSignedIn ? "  Codex: signed in on this Mac — Codex sandboxes use that login (read-only; the Mac's Codex renews it)"
                          : "  Codex: not signed in on this Mac — an OpenAI key below" + (chatgpt ? ", or chatgpt to sign in with ChatGPT" : ""))
        let rows = (try? decode(try await query(HostRequest(.accountList), g), [AccountRow].self, g)) ?? []
        let kept = rows.filter { $0.kind != AccountKind.mac.rawValue && $0.kind != AccountKind.codexMac.rawValue }
        if !kept.isEmpty { say("  accounts you have: " + kept.map { "\($0.name) (\(Self.kindTitle($0)))" }.joined(separator: ", ")) }
        var added: [String] = [], addedKinds: [AccountKind] = []
        var openaiAdded: String?
        if let k = keyFlag {
            if let n = try addKey(k, name: keyName, claudeSignedIn: claudeSignedIn, taken: Set(rows.map(\.name))) { added.append(n); addedKinds += [Self.keyKind(k)].compactMap { $0 } }
        } else if asker.interactive {
            let choices = Onboarding.keyChoices().filter { !$0.keyless }
            for c in choices {
                say("    \(c.id.padding(toLength: 11, withPad: " ", startingAt: 0)) \(c.title)\(c.gateway ? " (a gateway)" : "") — \(c.tools.joined(separator: ", "))")
            }
            var also = ["setup-token"]
            if chatgpt { also.append("chatgpt") }
            while true {
                let w = asker.pick("  Add a key?", choices.map(\.id) + ["no"], default: "no", also: also)
                if w == "no" { break }
                if w == "chatgpt" {
                    openaiAdded = try openAIAccountStep(pick: "chatgpt") ?? openaiAdded
                    continue
                }
                let taken = Set(rows.map(\.name)).union(added)
                if let n = try addKey(w, name: nil, claudeSignedIn: claudeSignedIn, taken: taken) { added.append(n); addedKinds += [Self.keyKind(w)].compactMap { $0 } }
            }
        }
        if openaiFlag != nil { openaiAdded = try openAIAccountStep(pick: openaiFlag) }

        // 4. Access (599e): GitHub as you, the SSH agent — each a purposeful choice, then each CONFIRMED live; a failure
        //    is skipped (kept, not confirmed), never blocking.
        await baseProgress()
        say("\n4. Access — what sandboxes may use as you (each is confirmed; nothing is on unless you choose it)")
        let haveClaudeKey = rows.contains { $0.kind == AccountKind.apiKey.rawValue || $0.kind == AccountKind.setupToken.rawValue }
            || addedKinds.contains(.apiKey) || addedKinds.contains(.setupToken)
        var step = AccessStep(g: g, asker: asker, talk: talk, githubFlag: githubFlag, sourceFlag: githubSourceFlag, sshFlag: sshFlag)
        step.checkClaude = claudeSignedIn || haveClaudeKey
        if githubKeyStdin { step.githubKey = readGitHubToken(fromStdin: true) }
        let chosenAccess = step.choose()
        say("  Confirming")
        let (access, accessReport) = try step.confirm(AccessChoices(github: chosenAccess.github,
                                                                    githubSource: step.githubKey != nil ? "key" : chosenAccess.githubSource,
                                                                    ssh: chosenAccess.ssh))
        // Written only when CHOSEN (a flag, or answered on a terminal): `--yes` alone changes nothing.
        let accessChosen = asker.interactive || githubFlag != nil || sshFlag != nil || githubSourceFlag != nil || step.githubKey != nil

        // 5. Workspace rules (599g, owner A1): what .dozignore / .dozreadonly do, and the default mode — written
        //    only when CHOSEN (a flag or an answer), as the Access choices are.
        await baseProgress()
        say("\n5. \(WorkspaceRulesGuide.title) — .dozignore and .dozreadonly")
        let ignoreMode = RulesStep(asker: asker, talk: talk, flag: ignoreModeFlag,
                                   current: DozableSettings.load().string(SettingKey.ignoreMode) ?? "lock", folder: nil).run()

        // 6. Settings (D7): written only when missing; the user's prompt template beside them (D16). 634: the base too.
        await baseProgress()
        say("\n6. Settings")
        let (settings, settingsPath) = try settingsOutcome {
            try Onboarding.writeSettingsIfMissing(defaultImage: "claude-code", account: nil, base: baseID)
        }
        switch settings {
        case .written: say("  wrote \(settingsPath.map { DisplayPath.tilde($0) } ?? "doz.toml") — every setting listed at its default; set: defaults.image\(baseID.map { $0 == "node" ? "" : ", defaults.base" } ?? "")")
        case .kept: say("  \(settingsPath.map { DisplayPath.tilde($0) } ?? "doz.toml") exists — left as it is")
        case .unavailable: say("  no settings file (neither XDG_CONFIG_HOME nor HOME is set)")
        }
        // 634: the store's base into a file that was kept (as the Access choices are).
        if settings == .kept, let id = baseID {
            let set: [String]
            do { set = try Onboarding.writeBase(id) } catch { throw fail(HostError(.failed, "\(error)"), g) }
            if !set.isEmpty { say("  Base: set " + set.joined(separator: ", ") + " — quick-made sandboxes' tools go on it") }
        }
        // 599e: the Access choices are the defaults for new sandboxes (written even into a file that was kept).
        if accessChosen, settings != .unavailable {
            let set: [String]
            do {
                set = try Access.write(github: access.github, githubSource: access.github == "off" && githubSourceFlag == nil ? nil : access.githubSource,
                                       ssh: access.ssh)
            } catch { throw fail(HostError(.failed, "\(error)"), g) }
            say(set.isEmpty ? "  Access: the settings already say so (defaults.github = \(access.github), sandbox.ssh_agent = \(access.ssh))"
                            : "  Access: set " + set.joined(separator: ", ") + " — new sandboxes follow them (doz access set changes them)")
        }
        // 599g: the rules' default mode, when chosen (into a file that was kept too).
        if let m = ignoreMode, settings != .unavailable {
            let set: [String]
            do { set = try Onboarding.writeIgnoreMode(m) } catch { throw fail(HostError(.failed, "\(error)"), g) }
            say(set.isEmpty ? "  Workspace rules: the settings already say so (workspace.ignore_mode = \(m))"
                            : "  Workspace rules: set " + set.joined(separator: ", ") + " — doz config set workspace.ignore_mode changes it")
        }
        let (template, templatePath) = try settingsOutcome { try Onboarding.writePromptTemplateIfMissing() }
        switch template {
        case .written: say("  wrote \(templatePath.map { DisplayPath.tilde($0) } ?? AgentPrompt.userTemplateName) — your own environment prompt for agents (all commented out: the built-in one applies)")
        case .kept: say("  \(templatePath.map { DisplayPath.tilde($0) } ?? AgentPrompt.userTemplateName) exists — left as it is")
        case .unavailable: break
        }
        // 599c: where doz new and the UI's Quick add / New sandbox put each new sandbox's workspace folder.
        let projects = (Workspace.defaultPath(name: "x") as NSString).deletingLastPathComponent
        say("  new sandboxes' workspace folders: \(DisplayPath.tilde(projects))/<name> (defaults.projects_dir — doz config set defaults.projects_dir DIR moves it)")

        // Usage statistics (official builds only; owner, 2026-10-11) and Stay in touch (optional; default No; --yes and
        // --json skip it) — 634: BEFORE the First sandbox, which ends in the tool's own screen.
        await baseProgress()
        let usage = usageStatistics()
        await stayInTouch()

        // The First sandbox (634, orchestrator's ruling B): a tool on the store's base, named after it, in a new empty
        // folder (or a project folder of yours) — the quick path `doz try` takes, with its name and folder.
        await baseProgress()
        let codexUsable = codexSignedIn || openaiAdded != nil || rows.contains { $0.kind == AccountKind.openaiKey.rawValue || $0.kind == AccountKind.chatgpt.rawValue }
        var firstTool: AgentRecipe?
        if let f = firstFlag {
            if f != "none" { firstTool = Self.firstTool(f) }
        } else if asker.interactive && talk {
            say("\n\(Usage.isOfficial ? 9 : 7). First sandbox — a tool on the \(baseID.map(title) ?? "its own") base, in a new empty folder; files it opens from its folder open on this Mac (sandbox.open_files)")
            if !codexUsable { say("  (codex: no Codex sign-in or OpenAI key yet — codex login on this Mac, or doz account add NAME --openai-key)") }
            let words = Self.firstWords.map(\.word).filter { $0 != "codex" || codexUsable } + ["no"]
            let claudeUsable = claudeSignedIn || haveClaudeKey
            let w = asker.pick("  Make your first sandbox?", words, default: claudeUsable ? "claude" : "no")
            if w != "no" { firstTool = Self.firstTool(w) }
        }

        // The base, followed to the end here (its progress view; Ctrl-C detaches — it goes on), then the record.
        var result: PrepareResult?
        var r = HostRequest(.onboard)
        r.base = baseID
        r.requestedBy = "doz onboard"
        if let id = baseID {
            if talk, Self.baseLine(try decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g), base: id)?.hasSuffix("ready") != true {
                say("\nWaiting for the \(title(id)) base — Ctrl-C detaches (it goes on): doz onboard --status watches it, --cancel stops it")
            }
            result = try decode(try followingCall(r, g), PrepareResult.self, g)
        } else {
            result = try decode(try call(r, g), PrepareResult.self, g)
        }
        if let rec = result?.onboarded {
            say("\nDone — this Mac is onboarded (\(rec.base.map { "the \(title($0)) base ready" } ?? "no base prepared yet")).")
            if firstTool == nil {
                say("Next: doz try (a tool, the quick way) · doz new (a sandbox with every default, attached) · doz init in a project folder · the UI: doz ui")
            }
        }

        var first: String?
        if let recipe = firstTool {
            first = try await firstSandbox(recipe)
        }
        return OnboardReport(store: store.root.path, checks: checks, base: baseID, signIns: (claudeSignedIn ? ["claude"] : []) + (codexSignedIn ? ["codex"] : []),
                             keysAdded: added, openaiAccountAdded: openaiAdded,
                             settings: settings.rawValue, settingsPath: settingsPath, promptTemplate: template.rawValue,
                             promptTemplatePath: templatePath, access: accessReport.items, ignoreMode: ignoreMode, result: result,
                             usageStats: usage, first: first)
    }

    /// The First sandbox: its name and folder (asked on a terminal), the plan's `doz new` command, then made, started and
    /// attached exactly as `doz try` does (QuickMake). A plan problem is said and the onboarding still ends well.
    private func firstSandbox(_ recipe: AgentRecipe) async throws -> String? {
        func plan(name: String?, folder: String?) async throws -> CreatePlan {
            var c = try ChoiceOptions.parse(["--agent", AgentRef.typed(recipe)] + (folder.map { ["--workspace", $0] } ?? []))
            c.agent = AgentRef.typed(recipe)
            return try await requestPlan(PlanRequest(purpose: "first", name: name, create: try c.planChoices()), g)
        }
        var planned = try await plan(name: nil, folder: nil)
        if asker.interactive && talk {
            say("\nFirst sandbox: \(recipe.title)")
            let name = asker.text("  Name", default: planned.name) { WebNameRule.isSandboxName($0) ? nil : "1–40 of a-z 0-9 - (not starting with -)" }
            let projects = planned.workspace.map { ($0 as NSString).deletingLastPathComponent } ?? (Workspace.defaultPath(name: "x") as NSString).deletingLastPathComponent
            let newFolder = DisplayPath.tilde((projects as NSString).appendingPathComponent(name))
            let typed = asker.text("  Folder (a new empty one, or a project folder of yours)", default: newFolder)
            let folder = typed == newFolder ? nil : typed
            if name != planned.name || folder != nil { planned = try await plan(name: name, folder: folder) }
        }
        if let p = planned.problems.first(where: { $0.code != "key" }) {
            say("  the first sandbox was not made: \(p.text)\(p.fix.map { " — \($0)" } ?? "") · later: doz try \(AgentRef.typed(recipe))")
            return nil
        }
        say("  Same in Terminal: \(planned.command)")
        let interactive = asker.interactive && talk && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        let quick = QuickMake(g: g, recipe: recipe, interactive: interactive, requestedBy: "doz onboard")
        let made = try await quick.make(planned, rebuild: false)
        if talk, let n = made.notice { Out.stderr("[doz] \(n)\n") }
        if interactive {
            try await quick.attachAndFinish(made)
        } else {
            say("\(made.name) is \(Out.phaseLabel(made.phase)) and kept — \(made.attachLine) · doz rm \(made.name) when you are done")
        }
        return made.name
    }

    /// What a key word is added as (`setup-token`: a Claude subscription's token).
    static func keyKind(_ id: String) -> AccountKind? {
        switch id {
        case "setup-token": .setupToken
        case "anthropic": .apiKey
        case "openai": .openaiKey
        case "": nil
        default: KeyProviders.provider(id) != nil ? .key : nil
        }
    }

    /// "xAI key", "Anthropic API key", "Claude setup token" — an account row for people.
    static func kindTitle(_ row: AccountRow) -> String {
        switch row.kind {
        case AccountKind.apiKey.rawValue: "Anthropic key"
        case AccountKind.setupToken.rawValue: "Claude setup token"
        case AccountKind.openaiKey.rawValue: "OpenAI key"
        case AccountKind.chatgpt.rawValue: "ChatGPT sign-in"
        case AccountKind.key.rawValue: "\(row.provider.map { ModelSources.title($0) } ?? "provider") key"
        default: row.kind
        }
    }

    /// `docker.io/library/node:22-bookworm` → `node:22-bookworm`.
    static func shortReference(_ r: String) -> String {
        r.hasPrefix("docker.io/library/") ? String(r.dropFirst("docker.io/library/".count)) : r
    }

    /// The base's state in one line for between the steps (nil: nothing to say).
    static func baseLine(_ st: PrepareStatus, base id: String) -> String? {
        let t = BaseCatalogue.base(id)?.title ?? id
        if let p = st.preparations.first(where: { $0.image == PreparationInfo.baseName(id) }) {
            if p.running {
                var s = "the \(t) base: " + (p.stepIndex.flatMap { i in p.plannedSteps.map { "step \(i) of \($0)" } } ?? "preparing")
                if let step = p.step { s += " — \(step)" }
                if let tr = p.transfer, let total = tr.totalBytes, total > 0 {
                    s += " (\(DozableImages.formatBytes(tr.completedBytes)) of \(DozableImages.formatBytes(total)))"
                }
                return s
            }
            if p.state == "done" { return "the \(t) base is ready" }
            return "the \(t) base: \(p.state)" + (p.error.map { " — \($0)" } ?? "") + " (a tool's first start prepares it again)"
        }
        if st.base?.id == id, st.base?.prepared == true { return "the \(t) base is ready" }
        return nil
    }

    /// 634: a key of a provider or gateway (or a Claude setup token), added exactly as `doz account add` adds it. On a
    /// terminal it is pasted at a no-echo prompt; off one only with `--secret-stdin` (stdin); otherwise nothing is added
    /// and the command is shown. An Anthropic key or a setup token becomes the store's default only when Claude Code is
    /// not signed in on this Mac (a key must never quietly replace the subscription); an OpenAI key becomes the OpenAI
    /// default; a provider's first key is its default by itself. Returns the account's name when one was added.
    private func addKey(_ id: String, name given: String?, claudeSignedIn: Bool, taken: Set<String>) throws -> String? {
        guard let kind = Self.keyKind(id) else { throw fail(HostError(.invalid, "--key: \(Self.keyWords.joined(separator: ", ")) (not \(id))"), g) }
        let what = kind == .setupToken ? "Claude setup token" : "\(ModelSources.title(id)) key"
        let suggested = taken.contains(id) ? "\(id)-2" : id
        let name = given ?? asker.text("  Account name", default: suggested) {
            (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : (taken.contains($0) && !force ? "\($0) exists" : nil)
        }
        do { try AccountStore.validateName(name) } catch { throw fail(HostError.from(error), g) }
        let plan = kind == .setupToken ? (plan ?? asker.text("  Plan (max, pro, team, enterprise)", default: "max") {
            ["max", "pro", "team", "enterprise"].contains($0.lowercased()) ? nil : "max, pro, team or enterprise"
        }) : nil
        let later = "doz account add \(name) " + (kind == .setupToken ? "--setup-token" : kind == .apiKey ? "--api-key" : kind == .openaiKey ? "--openai-key" : "--provider \(id)")
        var secret: String?
        if asker.interactive && isatty(STDIN_FILENO) == 1 {
            if kind == .setupToken { say("  run `claude setup-token` in another terminal, then paste the token here") }
            secret = try readSecret("  \(what) (not echoed): ", g)
        } else if secretStdin {
            secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        guard let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("  no \(what) given now (off a terminal, --secret-stdin reads one from stdin) — later: \(later)")
            return nil
        }
        let request = kind == .key ? HostRequest.keyAccountAdd(name: name, provider: id, secret: secret, force: force)
                                   : HostRequest.accountAdd(name: name, kind: kind, plan: plan, secret: secret, force: force)
        let m = try rawCall(request, g)
        guard m.ok == true else {
            // The host's message names the account, never the secret; it is scrubbed anyway.
            let why = (m.error?.message ?? "no reason").replacingOccurrences(of: secret.trimmingCharacters(in: .whitespacesAndNewlines), with: "…")
            say("  could not add \(name): \(why) — onboarding goes on without it; later: \(later)")
            return nil
        }
        let row = ((try? m.result?.decode([AccountRow].self)) ?? []).first { $0.name == name }
        var note = ""
        if kind == .openaiKey || ((kind == .apiKey || kind == .setupToken) && !claudeSignedIn) {
            var r = HostRequest(.accountDefault)
            r.account = name
            _ = try call(r, g)
            note = kind == .openaiKey ? " — the store's default OpenAI account (Codex)" : " — the store's default account (Claude Code)"
        } else if kind == .apiKey || kind == .setupToken {
            note = " — Claude Code keeps this Mac's login (doz account default \(name) changes that)"
        }
        let tools = Onboarding.keyChoices().first { $0.id == id }?.tools ?? []
        say("  \(name) added (\(what)\(row?.verification.map { ", \($0)" } ?? ""))\(note)" + (tools.isEmpty || kind == .setupToken ? "" : " · for " + tools.joined(separator: ", ")))
        return name
    }

    /// The words `--key` takes.
    static var keyWords: [String] { Onboarding.keyChoices().filter { !$0.keyless }.map(\.id) + ["setup-token"] }

    /// 599i: Codex's OpenAI account — a ChatGPT sign-in (the browser opens; Dozable's own sign-in, the Mac's
    /// ~/.codex is never touched) or an OpenAI key (a no-echo prompt), added as `doz account add` adds it and
    /// made the store's OpenAI default; or later; or (rc.3) this Mac's own Codex login. `pick` is what was chosen.
    private func openAIAccountStep(pick given: String?) throws -> String? {
        say("  Codex account (OpenAI)")
        let macState = CodexMacLogin.read(CodexMacLogin.resolveHome()).state
        let macSignedIn = macState == .ok || macState == .expired
        let pick = given ?? "later"
        if pick == "mac" {
            guard macSignedIn else {
                say("  this Mac's Codex is not signed in (\(macState.label)) — run codex login on the Mac, or add an account later")
                return nil
            }
            var r = HostRequest(.accountDefault)
            r.account = "mac"
            r.accountKind = "codex"
            _ = try call(r, g)
            say("  Codex sandboxes use this Mac's Codex login (mac) — the store's default OpenAI account")
            return "mac"
        }
        guard pick != "later" else {
            say("  decide later — a codex sandbox says what it needs; then: " + OpenAIChoices.laterHint(flavor: .current))
            return nil
        }
        let name = asker.interactive ? asker.text("  Account name", default: pick == "chatgpt" ? "chatgpt" : "openai") {
            (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : nil
        } : (pick == "chatgpt" ? "chatgpt" : "openai")
        var secret: String?
        if pick == "chatgpt" {
            do { secret = try ChatGPTSignIn.run { say("  " + $0) }.json } catch {
                say("  could not sign in: \(error.localizedDescription) — later: doz account add \(name) --chatgpt")
                return nil
            }
        } else if asker.interactive && isatty(STDIN_FILENO) == 1 {
            secret = try readSecret("  OpenAI API key (not echoed): ", g)
        }
        guard let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("  no key given now — later: doz account add \(name) --openai-key")
            return nil
        }
        let kind: AccountKind = pick == "chatgpt" ? .chatgpt : .openaiKey
        let m = try rawCall(HostRequest.accountAdd(name: name, kind: kind, plan: nil, secret: secret, force: force), g)
        guard m.ok == true else {
            let why = (m.error?.message ?? "no reason").replacingOccurrences(of: secret.trimmingCharacters(in: .whitespacesAndNewlines), with: "…")
            say("  could not add \(name): \(why) — onboarding goes on without it")
            return nil
        }
        var r = HostRequest(.accountDefault)
        r.account = name
        _ = try call(r, g)
        let row = ((try? m.result?.decode([AccountRow].self)) ?? []).first { $0.name == name }
        say("  account \(name) added (\(kind.rawValue)\(row?.identity.map { ", \($0)" } ?? "")\(row?.plan.map { ", \($0)" } ?? "")) — the store's default OpenAI account (Codex)")
        return name
    }

    private func settingsOutcome(_ body: () throws -> (Onboarding.ConfigOutcome, String?)) throws -> (Onboarding.ConfigOutcome, String?) {
        do { return try body() } catch let e as SettingsError {
            throw fail(HostError(.failed, e.message), g)
        }
    }

    static func checkLine(_ c: OnboardingCheck) -> String {
        let mark = switch c.status { case "ok": "ok  "; case "warn": "warn"; default: c.hard ? "FAIL" : "warn" }
        return "  \(mark)  \(c.check.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.detail)"
    }
}

/// A request whose progress is shown while it runs (593's view), from which Ctrl-C DETACHES — the
/// host goes on — saying how to watch again.
func followingCall(_ r: HostRequest, _ g: GlobalOptions,
                   detached: String = "the preparation goes on in the host — doz onboard --status watches it, doz onboard --cancel stops it") throws -> JSONValue {
    var gv = g
    gv.verbose = true                              // show it from the first second: this is the waiting part
    let progress = Progress(gv)
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    src.setEventHandler {
        progress.finish()
        if g.json { Out.json(["detached": true]) } else { Out.stderr("\n[doz] detached — \(detached)\n") }
        exit(130)
    }
    src.resume()
    defer {
        src.cancel()
        signal(SIGINT, SIG_DFL)
    }
    let m: HostMessage
    do {
        m = try HostClient.request(r, store: g.dozableStore, autostart: true) { progress.handle($0) }
    } catch let e as HostError {
        progress.finish()
        throw fail(e, g)
    } catch {
        progress.finish()
        throw fail(HostError(.unavailable, error.localizedDescription), g)
    }
    progress.finish()
    if m.ok == true { return m.result ?? .null }
    throw fail(m.error ?? HostError(.failed, "the host gave no reason"), g)
}

struct Onboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up this Mac for Dozable (once): check it, prepare the base image every tool is added to, add keys, choose Access and workspace rules, write the settings, and make a first sandbox.",
        discussion: """
        Re-running is safe: it checks again, leaves existing settings alone and prepares only what is \
        missing. The base image is downloaded and prepared by the host from the Base image step on, while \
        the questions go on: Ctrl-C detaches (the preparation goes on), --status re-attaches, --cancel \
        stops it. On a terminal it asks (Enter accepts the recommended answer); --yes, --json or no \
        terminal ask nothing — --yes takes the Node.js base and makes no sandbox.
        """)

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Show the onboarding record and the base; follow a preparation that is running.") var status = false
    @Flag(name: .long, help: "Cancel what is being prepared (the base).") var cancel = false
    @Option(name: .long, help: "The base image without asking: node (Node.js, the default), python, go … (doz base ls). Quick-made sandboxes' tools go on it (the setting defaults.base).") var base: String?
    @Flag(name: .long, help: "Prepare no base now (each tool's first start prepares its own).") var noBase = false
    @Option(name: .long, help: "Add a key without asking: anthropic, openai, xai, google, openrouter, or setup-token (a Claude subscription's token). Given, the Claude Code checks are not run.") var key: String?
    @Option(name: .long, help: "With --key: the account's name (default: the provider's name).") var keyName: String?
    @Option(name: .long, help: "With --key setup-token: the plan (max, pro, team, enterprise).") var plan: String?
    @Flag(name: .long, help: "With --key off a terminal: read the key or token from stdin (as doz account add does). On a terminal it is pasted at a no-echo prompt.") var secretStdin = false
    @Flag(name: .long, help: "With --key: replace an account of that name.") var force = false
    @Option(name: .long, help: "The First sandbox without asking: claude, pi, opencode, codex (any tool doz try takes), or none.") var first: String?
    @Option(name: .long, help: "The Access step's GitHub choice without asking: off, read or push (new sandboxes signed in to GitHub as you).") var github: String?
    @Option(name: .long, help: "Where the GitHub token comes from: gh (this Mac's gh login) or key (--github-key-stdin).") var githubSource: String?
    @Flag(name: .long, help: "Read a GitHub token from stdin as the default key (implies --github-source key).") var githubKeyStdin = false
    @Option(name: .long, help: "The Access step's SSH choice without asking: on or off (forward this Mac's ssh-agent, github.com only).") var sshAgent: String?
    @Option(name: .long, help: "The Workspace rules step without asking: lock or hide — what a .dozignore in a sandbox's folder does to the paths it lists, by default (the setting workspace.ignore_mode). Lock: listed but unreadable; hide: not there.") var ignoreMode: String?
    @Option(name: .long, help: "Codex's OpenAI account without asking: mac (this Mac's own Codex login, read-only), chatgpt (sign in with ChatGPT in your browser — Dozable's own sign-in), openai-key (pasted at a no-echo prompt) or later.") var openaiAccount: String?
    @Option(name: .long, help: "The Usage statistics step without asking (official builds): on or off — off sets telemetry.send_anonymous_usage_stats = false. Without it, --yes and no terminal leave the setting as it is.") var usageStats: String?
    @Flag(name: [.short, .long], help: "Accept every default; ask nothing: the Node.js base, no key, no sandbox. A credential that cannot be confirmed is skipped with a note (exit 0).") var yes = false

    func validate() throws {
        if let v = github, !["off", "read", "push"].contains(v) { throw ValidationError("--github: off, read or push") }
        if let v = githubSource, !["gh", "key"].contains(v) { throw ValidationError("--github-source: gh or key") }
        if let v = sshAgent, !["on", "off"].contains(v) { throw ValidationError("--ssh-agent: on or off") }
        if let v = ignoreMode, !["lock", "hide"].contains(v) { throw ValidationError("--ignore-mode: lock or hide") }
        if let v = usageStats, !["on", "off"].contains(v) { throw ValidationError("--usage-stats: on or off") }
        if let v = openaiAccount, !["mac", "chatgpt", "openai-key", "later"].contains(v) { throw ValidationError("--openai-account: mac, chatgpt, openai-key or later") }
        if openaiAccount == "chatgpt", !BuildFlavor.current.chatgptSignIn { throw ValidationError("--openai-account chatgpt: " + BuildFlavor.chatgptSignInMissing) }
        if githubKeyStdin && secretStdin { throw ValidationError("--github-key-stdin and --secret-stdin both read stdin — add one later (doz access set --github-key / doz account add)") }
        if githubKeyStdin && githubSource == "gh" { throw ValidationError("--github-key-stdin goes with --github-source key") }
        if [status, cancel].filter({ $0 }).count + ((base != nil || noBase || key != nil || first != nil || ignoreMode != nil) ? 1 : 0) > 1 {
            throw ValidationError("--status and --cancel stand alone")
        }
        if base != nil && noBase { throw ValidationError("--base or --no-base, not both") }
        if let b = base, BaseCatalogue.base(b) == nil { throw ValidationError("--base: \(BaseCatalogue.ids.joined(separator: ", ")) (not \(b))") }
        if let k = key, !OnboardingFlow.keyWords.contains(k) { throw ValidationError("--key: \(OnboardingFlow.keyWords.joined(separator: ", ")) (not \(k))") }
        if key == nil && (keyName != nil || secretStdin || force) { throw ValidationError("--key-name, --secret-stdin and --force go with --key") }
        if plan != nil && key != "setup-token" { throw ValidationError("--plan goes with --key setup-token") }
        if let p = plan, !["max", "pro", "team", "enterprise"].contains(p.lowercased()) { throw ValidationError("--plan: max, pro, team or enterprise") }
        if let f = first, f != "none", OnboardingFlow.firstTool(f) == nil {
            throw ValidationError("--first: claude, pi, opencode, codex (any tool doz try takes — doz search lists them) or none (not \(f))")
        }
    }

    func run() async throws {
        if status { try await showStatus(); return }
        if cancel { try cancelPreparations(); return }
        var flow = OnboardingFlow(g: g, asker: Asker(yes: yes, json: g.json), talk: !g.json)
        flow.baseFlag = base
        flow.noBase = noBase
        flow.keyFlag = key
        flow.keyName = keyName
        flow.plan = plan?.lowercased()
        flow.secretStdin = secretStdin
        flow.force = force
        flow.firstFlag = first
        flow.githubFlag = github
        flow.githubSourceFlag = githubKeyStdin ? "key" : githubSource
        flow.sshFlag = sshAgent
        flow.githubKeyStdin = githubKeyStdin
        flow.ignoreModeFlag = ignoreMode
        flow.openaiFlag = openaiAccount
        flow.usageStatsFlag = usageStats.map { $0 == "on" }
        let report = try await flow.run()
        if g.json { Out.json(report) }
    }

    func showStatus() async throws {
        var st = try decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g)
        let running = st.preparations.filter(\.running)
        if !running.isEmpty {
            if !g.json {
                for p in running { Out.stdout("joining the preparation of \(Self.what(p)) (asked by \(p.requestedBy.joined(separator: ", ")); \(Int(p.seconds)) s so far)\n") }
            }
            var r = HostRequest(.prepare)
            r.follow = true
            _ = try? followingCall(r, g)
            st = try decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g)
        }
        if g.json { Out.json(st); return }
        Out.stdout(Self.render(st))
    }

    /// "the Node.js base", or the image's name.
    static func what(_ p: PreparationInfo) -> String {
        PreparationInfo.baseID(p.image).map { "the \(BaseCatalogue.base($0)?.title ?? $0) base" } ?? p.image
    }

    static func render(_ st: PrepareStatus) -> String {
        var s = ""
        if let o = st.onboarded {
            s += "onboarded: yes — doz \(o.dozVersion), \(o.date.formatted(date: .abbreviated, time: .shortened))"
                + (o.base.map { " (base: \($0))" } ?? "") + (o.images.isEmpty ? "" : " (images: \(o.images.joined(separator: ", ")))") + "\n"
        } else {
            s += "onboarded: no — doz onboard sets up this Mac\n"
        }
        // 634: the store's one base.
        if let b = st.base {
            s += "base \(b.id) \(b.prepared ? "ready" : "not prepared — doz onboard prepares it (or a tool's first start)") — \(b.title), \(OnboardingFlow.shortReference(b.reference))\n"
        }
        var t = [["IMAGE", "STATE"]]
        for r in st.images where r.kind == "builtin" {
            t.append([r.name, (r.current ?? false) ? "ready" : r.baked ? "baked by an older build — prepared again when next needed" : "not prepared (its first start does it)"])
        }
        s += "\n" + Out.table(t)
        if !st.preparations.isEmpty {
            s += "\nrecent preparations:\n"
            for p in st.preparations {
                s += "  \(what(p).padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.state) — \(ProgressFormat.duration(p.seconds))"
                    + (p.error.map { ": \($0)" } ?? "") + " (asked by \(p.requestedBy.joined(separator: ", ")))\n"
            }
        }
        return s
    }

    func cancelPreparations() throws {
        guard g.dozableStore.hostIsRunning() else {
            if g.json { Out.json([PreparationInfo]()) } else { Out.stdout("nothing is being prepared (no host is running)\n") }
            return
        }
        let m = try rawCall(HostRequest(.prepareCancel), g, autostart: false)
        if m.ok == true, let v = m.result {
            let ps = try decode(v, [PreparationInfo].self, g)
            if g.json { Out.json(ps) } else { for p in ps { Out.stdout("cancelling the preparation of \(Self.what(p))\n") } }
        } else if let e = m.error, e.code == .notFound {
            if g.json { Out.json([PreparationInfo]()) } else { Out.stdout("nothing is being prepared\n") }
        } else {
            throw fail(m.error ?? HostError(.failed, "no reason"), g)
        }
    }
}

// 599f: `doz init` is InitCommand.swift (the New Sandbox wizard's steps on a terminal).

func shellQuoted(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@".contains($0)) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
