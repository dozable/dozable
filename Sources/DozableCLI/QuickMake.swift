import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost

// 634 — what `doz try` and `doz onboard`'s First sandbox share (one path, never two): from a plan to a running sandbox
// with its session open (its image prepared early, the key dealt with first), then the attach and the way out
// ("Leaving NAME — [S]leep / [d]elete / [k]eep running"). The plan is the host's (`try` or `first`).

/// A quick-made sandbox, made and started, its session open.
struct QuickMade {
    var name: String
    var image: String
    var phase: String
    var session: String
    var defaultSession: String?
    var notice: String?
    var attachLine: String
}

struct QuickMake {
    let g: GlobalOptions
    let recipe: AgentRecipe
    /// A terminal on both ends: the key is asked for, the session attached.
    let interactive: Bool
    /// Who asked for the early preparation (`doz try`, `doz onboard`).
    var requestedBy = "doz try"
    var rm = false
    var keep = false

    /// The plan's first lines (what it makes, where its files go), the early preparation, the key, then create, start
    /// and open its session.
    func make(_ planned: CreatePlan, rebuild: Bool) async throws -> QuickMade {
        var o = planned.create
        // 653: a recipe that is not Dozable's — said (yours) or asked once per version (a community one) BEFORE its image
        // is prepared below (the bake runs its install).
        try confirmRecipeTrust(image: planned.image, g)
        try confirmDotfilesTrust(&o, g)          // 657: the dotfiles it gets — said, or asked once per commit
        // --rebuild: an out-of-date image is rebuilt first (a quick make asks nothing, so without it the current image is used).
        if rebuild { o.rebuild = true }
        // 617 (owner, 2026-10-15): what the person meets at the first start that Dozable leaves to them — said first.
        if !g.json, let n = recipe.guide?.notice { Out.stdout("\(recipe.title): \(n)\n") }
        if !g.json {
            // Said plainly (owner), first: where its files go and what reaches the Mac.
            let said = planned.reach.filter { $0.kind == "folder" || $0.kind == "bridge" }.map { $0.text.prefix(1).lowercased() + $0.text.dropFirst() }
            var parts = [planned.name, planned.imageState.title ?? planned.image] + said
            // Isolated: nothing of the Mac is shared — the way files come out (owner).
            if planned.workspace == nil { parts.append("pull files with: doz get \(planned.name) /workspace/FILE") }
            Out.stdout(parts.joined(separator: " · ") + "\n")
            // 618: a family's major — which one, and how to get the other.
            if let l = planned.version?.familyLine() { Out.stdout(l + "\n") }
        }
        // The image prepares NOW, in the host, while the key is dealt with (joined by the start below).
        if planned.imageState.state == "unprepared" {
            var prep = HostRequest(.prepare)
            prep.images = [planned.image]
            prep.follow = false
            prep.requestedBy = requestedBy
            if (try? rawCall(prep, g))?.ok == true, !g.json, !g.quiet {
                Out.stderr("[doz] preparing the \(planned.imageState.title ?? planned.image) image now (once) — it goes on while you set up the key\n")
            }
        }
        // The key: the plan's account, else the card (a terminal), else the problem and how to fix it.
        if let p = planned.problems.first(where: { $0.code == "key" }) {
            guard interactive else { throw fail(HostError(.invalid, p.text), g) }
            // 660: a built-in agent through another source (Claude Code via OpenRouter) asks for that source's key too.
            if recipe.isBuiltin, o.modelSource.map({ $0 == recipe.provider || ModelSources.isKeyless($0) }) ?? true {
                try preflightAgentAccount(&o, g)
            } else if let s = o.modelSource, s != recipe.provider {
                // 617 (models@1): another provider or a gateway — a key of THAT source.
                o.account = try preflightSourceAccount(image: o.image, source: s, account: o.account, g)
            } else {
                o.account = try whatYouNeed()
            }
        }
        // Make it, start it, open its session.
        var r = HostRequest(.create, name: planned.name)
        r.create = o
        _ = try decode(try call(r, g), SandboxInfo.self, g)
        let started = try decode(try call(HostRequest(.start, name: planned.name), g), LifecycleResult.self, g)
        var open = HostRequest(.openSession, name: planned.name)
        let size = terminalSize()
        open.cols = size.cols
        open.rows = size.rows
        let opened = try decode(try call(open, g), SessionOpened.self, g)
        return QuickMade(name: planned.name, image: planned.image, phase: started.phase, session: opened.session,
                         defaultSession: opened.defaultSession, notice: opened.notice,
                         attachLine: reattachCommand(sandbox: planned.name, session: opened.session, defaultSession: opened.defaultSession))
    }

    /// Attach to its session (a tool whose session is a shell gets its "Start here" first), then the way out.
    func attachAndFinish(_ made: QuickMade) async throws {
        // 617.11 (owner: "i tried fabric and it just gave me a terminal"): a tool whose session is a shell gets its
        // "Start here" first — the guide's steps (doz guide NAME has it all).
        if recipe.launch.session == "shell", let guide = recipe.guide, !g.quiet {
            Out.stderr("\n" + TryCommand.startHere(recipe.title, guide, sandbox: made.name) + "\n")
        }
        let key = try parseDetachKey("ctrl-]")
        if !g.quiet {
            Out.stderr("[doz] \(made.name) started — attaching to \(made.session)\(key.map { " (\(describeKey($0)): the menu · twice: detach)" } ?? "")\n")
        }
        let end = AttachClient.attach(store: g.dozableStore, sandbox: made.name, session: made.session, wake: true, detachKey: key, quiet: g.quiet)
        try await finish(made.name, end: end)
    }

    /// "Leaving NAME — Sleep / delete / keep running" — or what --rm / --keep said.
    func finish(_ name: String, end: AttachEnd) async throws {
        let asker = Asker(yes: false, json: g.json)
        var choice = TryExitChoice.decided(rm: rm, keep: keep, interactive: asker.interactive)
        while choice == nil {
            choice = TryExitChoice.parse(asker.text(TryExitChoice.question(name), default: "S"))
        }
        switch choice! {
        // "Sleep" as a person means it (D14: "it then holds no memory"): Dozable's hibernate — a snapshot on disk, the
        // RAM returned; `doz wake` or `doz attach` brings it back where it was.
        case .sleep: _ = try lifecycle(.hibernate, name, g)
        case .delete:
            let folder = await createdFolder(name, g)
            _ = try lifecycle(.rm, name, g)
            cleanUpCreatedFolder(folder, g)
        case .keep: Out.stdout("\(name) keeps running — doz attach \(name) · doz rm \(name) when you are done\n")
        }
        if case .ended(let c) = end, c != 0 { throw ExitCode(c) }
    }

    /// "What you need" (no key of the agent's provider yet): the card, a choice, and the account it makes — or `none`
    /// for a sign-in inside the agent.
    func whatYouNeed() throws -> String {
        guard let card = TryCard.build(recipe, haveKey: nil), !card.options.isEmpty,
              let provider = recipe.provider.flatMap({ KeyProviders.provider($0) }) else {
            throw fail(HostError(.invalid, AgentCredentials.requirement(recipe.id)), g)
        }
        Out.stdout("\n" + card.lines.joined(separator: "\n") + "\n\n")
        let asker = Asker(yes: false, json: false)
        let pick = asker.text("Choose 1–\(card.options.count)", default: "1") { a in
            Int(a).map { (1...card.options.count).contains($0) } == true ? nil : "a number from 1 to \(card.options.count)"
        }
        let option = card.options[Int(pick)! - 1]
        if option.kind == "sign-in" {
            Out.stdout("Then sign in inside \(recipe.title) — the sign-in lives in this sandbox (doz rm deletes it)\n")
            return "none"
        }
        let taken = Set(((try? decode(try rawCall(HostRequest(.accountList), g).result ?? .null, [AccountRow].self, g)) ?? []).map(\.name))
        let name = asker.text("Account name", default: taken.contains(provider.id) ? "\(provider.id)-2" : provider.id) {
            (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : (taken.contains($0) ? "\($0) exists" : nil)
        }
        var add = HostRequest.keyAccountAdd(name: name, provider: provider.id, secret: nil)
        var secret: String?
        if option.kind == "paste" {
            let s = try readSecret("\(provider.title) \(provider.title.contains("API") ? "key" : "API key") (not echoed): ", g)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "nothing pasted"), g) }
            add.secret = s
            secret = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let ref = asker.text("Where is it? op://VAULT/ITEM/FIELD, aws:arn:aws:secretsmanager:…, or a command that prints it", default: "") {
                $0.isEmpty ? "a reference or a command" : nil
            }
            do {
                if ref.hasPrefix("op://") || ref.hasPrefix("aws:") { add.secretSource = try SecretSource.parse(from: ref) } else {
                    let src = try SecretSource.parseCommand(ref, resolve: SecretSources.locate)
                    if case .command(let p, let a) = src {
                        let shown = ([p] + a).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
                        guard asker.yesNo("The key will be read on this Mac by running: \(shown) (no shell; its output is the key). Save it?", default: true) else {
                            Out.stderr("[doz] nothing saved\n")
                            throw ExitCode(DozableExit.declined)
                        }
                    }
                    add.secretSource = src
                }
            } catch let e as HostError { throw fail(e, g) }
        }
        let m = try rawCall(add, g)
        guard m.ok == true else {
            let why = (m.error?.message ?? "no reason")
            throw fail(HostError(.invalid, "could not add \(name): " + (secret.map { why.replacingOccurrences(of: $0, with: "…") } ?? why)), g)
        }
        Out.stderr("[doz] account \(name) added (\(provider.title) key) — this sandbox uses it\n")
        return name
    }
}
