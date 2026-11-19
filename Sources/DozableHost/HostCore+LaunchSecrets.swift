import DozableKit
import Foundation

/// 692: secrets given at launch (`--secret`) in the daemon — checked again (never trusting the client), kept (a keychain
/// item of their own, else this daemon's memory), bound into the proxy's vault as `secret:VAR` (swap-only, one host and
/// port), handed to the session as a placeholder (and a 0600 file), revoked with their owner. Nothing here ever writes,
/// logs or answers a value.
extension HostCore {
    // MARK: checking what the client sent

    /// The grants of one launch, checked by the daemon: the form again (variables, header, destination), the value again
    /// (printable ASCII, no space, ≤ 1800 bytes), at most four and each variable once — with `existing` (a sandbox's
    /// secrets it keeps) — the source file outside everything the session could read (`readable`: resolved roots), and
    /// the destination reachable now (`hostPorts`: this Mac's ports it was given; `reach`: the policy's verdict for any
    /// other host). `allowFlag`: what to add for a site (`--allow` for a sandbox, `--permissions` for a fenced session).
    func checkedLaunchSecrets(_ grants: [LaunchSecretGrant], existing: [LaunchSecret] = [], readable: [String], readableWhat: String,
                              hostPorts: [UInt16], reach: (String, UInt16) -> Bool, allowFlag: String) throws -> [LaunchSecretGrant] {
        guard !grants.isEmpty else { return [] }
        var out: [LaunchSecretGrant] = []
        for g in grants {
            var s = g.secret
            let v = s.variable
            if let p = LaunchSecrets.variableProblem(v) { throw HostError(.invalid, "--secret: \(p)") }
            if let f = s.fileVariable {
                if let p = LaunchSecrets.variableProblem(f, what: "file=") { throw HostError(.invalid, "--secret \(v): \(p)") }
                if f == v { throw HostError(.invalid, "--secret \(v): file= names another variable than the secret's own") }
            }
            let (host, port) = try LaunchSecrets.destination("\(s.host):\(s.port)", variable: v)
            s.host = host
            s.port = port
            guard CustomKey.isHeaderName(s.header), !["proxy-authorization", HostRoute.sessionHeader.lowercased()].contains(s.header) else {
                throw HostError(.invalid, "--secret \(v): header=\(s.header) — a header name like x-api-key")
            }
            s.bearer = s.header == "authorization"
            let value = try LaunchSecrets.checkedValue(Array(g.value.utf8), variable: v)
            s.fingerprint = CredentialFingerprint.of(value)
            s.keychainService = nil
            s.bot = nil                         // a bot-held secret is the daemon's to make, never a client's
            // The file: never one the session could read (its folder, its workspace, a root of its fence).
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            let src = realpath(g.source, &resolved).map { String(cString: $0) } ?? g.source
            guard src.hasPrefix("/") else { throw HostError(.invalid, "--secret \(v): src= must be an absolute path") }
            for root in readable where LaunchSecrets.isWithin(src, root) {
                throw HostError(.invalid, "--secret \(v): src=\(DisplayPath.tilde(src)) is inside \(readableWhat) (\(DisplayPath.tilde(root))) — the session could read the secret itself; keep the file outside it")
            }
            // Reachable now — a secret never widens what the session reaches.
            if host == HostRoute.hostName {
                guard hostPorts.contains(port) else {
                    throw HostError(.invalid, "--secret \(v): to=\(host):\(port) needs that port of this Mac open to it — add --host-port \(port)")
                }
            } else if !reach(host, port) {
                throw HostError(.invalid, "--secret \(v): \(host):\(port) is not reachable from it — add \(allowFlag) site:\(host):\(port)")
            }
            out.append(LaunchSecretGrant(secret: s, value: value, source: src))
        }
        // Each variable once, across what it keeps (a secret given again for the same VAR replaces it).
        let kept = existing.filter { e in !out.contains { $0.secret.variable == e.variable } }
        try LaunchSecrets.check((kept + out.map(\.secret)).map { ($0.variable, $0.fileVariable) })
        return out
    }

    /// `-e VAR=…` (or `-e FILEVAR=…`) for a variable a launch secret owns — refused at launch and on every later run or
    /// exec: the secret's placeholder is the only value it ever has.
    static func refuseSecretVariables(_ secrets: [LaunchSecret], _ env: [String: String]?) throws {
        for s in secrets {
            for k in [s.variable] + (s.fileVariable.map { [$0] } ?? []) where env?[k] != nil {
                throw HostError(.invalid, "-e \(k): \(k) carries a secret's placeholder — give it with --secret")
            }
        }
    }

    // MARK: keeping the value

    /// Keep each grant's value: in its own keychain item (`doz-secret-<store>-<owner>-<VAR>`, on `security -i`'s stdin)
    /// and this daemon's memory; when the keychain refuses (locked), in memory only — said. The ledger records the item.
    /// Returns the records and the lines to say.
    func keepLaunchSecrets(owner: String, _ grants: [LaunchSecretGrant]) -> (records: [LaunchSecret], lines: [String]) {
        var out: [LaunchSecret] = []
        var lines: [String] = []
        var ledger = LaunchSecretLedger.load(store)
        for g in grants {
            var s = g.secret
            let service = LaunchSecrets.service(store: store.root, owner: owner, variable: s.variable)
            launchSecretMemory[service] = g.value
            var kept = true
            if readOnly {
                kept = false
            } else {
                do { try services.keychain.write(service: service, account: Keychain.user, secret: g.value) } catch { kept = false }
            }
            if kept {
                s.keychainService = service
                ledger.items[service] = owner
            } else {
                // Never a stale item beside a value only in memory.
                try? services.keychain.delete(service: service, account: Keychain.user)
                ledger.items[service] = nil
            }
            out.append(s)
            lines.append(s.line + (kept ? "" : " — kept until the daemon stops (the login keychain is locked)"))
        }
        if !readOnly { ledger.save(store) }
        return (out, lines)
    }

    /// The value of `s` (owned by `owner`): this daemon's memory, else its keychain item (read again by a new daemon), else
    /// nil.
    func launchSecretValue(owner: String, _ s: LaunchSecret) -> String? {
        // A bot-held secret: the bot's own item, read each time, only while it is the token recorded (a rotated one is not).
        if let bot = s.bot {
            guard let v = services.keychain.read(service: BotTokens.service(store: store.root, name: bot), account: Keychain.user).value,
                  CredentialFingerprint.of(v) == s.fingerprint else { return nil }
            return v
        }
        let service = LaunchSecrets.service(store: store.root, owner: owner, variable: s.variable)
        if let v = launchSecretMemory[service] { return v }
        guard let k = s.keychainService, let v = services.keychain.read(service: k, account: Keychain.user).value else { return nil }
        // Only the value whose fingerprint was recorded (an item changed underneath is not this secret).
        guard CredentialFingerprint.of(v) == s.fingerprint else { return nil }
        launchSecretMemory[service] = v
        return v
    }

    /// Revoke `s`: its value forgotten, its keychain item deleted, its ledger line removed. (Its vault binding is the
    /// caller's to remove — with it every placeholder of it.)
    func forgetLaunchSecret(owner: String, _ s: LaunchSecret) {
        let service = LaunchSecrets.service(store: store.root, owner: owner, variable: s.variable)
        launchSecretMemory[service] = nil
        // A bot-held secret has no item of its own: the bot's token stays in the bot's item, never deleted here.
        guard !readOnly, s.bot == nil else { return }
        if let k = s.keychainService { try? services.keychain.delete(service: k, account: Keychain.user) }
        var ledger = LaunchSecretLedger.load(store)
        if ledger.items.removeValue(forKey: s.keychainService ?? service) != nil { ledger.save(store) }
    }

    // MARK: the vault

    /// Bind `secrets` into `vault` (at launch, at a restart, when a new daemon loads a sandbox or adopts a session): each
    /// `secret:VAR` binding with its value — or none, and the 401 that says so — and `network.placeholders_plain_http` as
    /// it is now. A `secret:` binding no longer in `secrets` is removed (and with it its placeholders).
    func bindLaunchSecrets(_ vault: CredentialVault, _ secrets: [LaunchSecret], owner: String, who: String) {
        let plain = DozableSettings.load().bool(SettingKey.placeholdersPlainHTTP)
        let wanted = Set(secrets.map(\.bindingID))
        for b in vault.allBindings where b.isLaunchSecret && !wanted.contains(b.id) { vault.remove(b.id) }
        for s in secrets {
            let value = launchSecretValue(owner: owner, s)
            let missing = s.bot.map { "\(who) has no token behind \(s.variable)'s placeholder now (\($0)'s token was replaced, or cannot be read from the login keychain) — start the workspace again: doz workspace start" }
                ?? "\(who) has no secret behind \(s.variable)'s placeholder now (the daemon restarted and its keychain item could not be read) — give it again: --secret \(s.variable),src=…"
            vault.set(s.binding(plainHTTP: plain), secret: value, expiresAt: nil, environment: [:], notice: value == nil ? missing : nil)
        }
    }

    /// A sandbox's launch secrets into its proxy (`applyAccount`): nothing for one without any.
    func applyLaunchSecrets(_ m: Managed) {
        guard let vault = m.sandbox.egress?.vault else { return }
        let secrets = m.config.secrets ?? []
        if secrets.isEmpty, !vault.allBindings.contains(where: \.isLaunchSecret) { return }
        bindLaunchSecrets(vault, secrets, owner: m.name, who: m.name)
    }

    /// `doz run NAME --secret …`: the secrets join the sandbox's (one given again for the same VAR replaces it — its
    /// placeholders stay valid for the new value), checked against what it reaches now; kept in its record.
    func addLaunchSecrets(_ m: Managed, _ given: [LaunchSecretGrant]) throws -> [String] {
        guard !readOnly else { throw HostError(.unavailable, "--secret needs the daemon") }
        guard let egress = m.sandbox.egress else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — a secret is held by Dozable's proxy")
        }
        let policy = egress.policy
        let checked = try checkedLaunchSecrets(given, existing: m.config.secrets ?? [], readable: [m.config.workspace].compactMap { $0 }.map(Self.resolvedRoot),
                                               readableWhat: "its folder", hostPorts: egress.hostPorts.map(\.port),
                                               reach: { policy.evaluateConnection(host: $0, port: $1).kind != .deny }, allowFlag: "--allow")
        let (records, lines) = keepLaunchSecrets(owner: m.name, checked)
        var list = (m.config.secrets ?? []).filter { e in !records.contains { $0.variable == e.variable } }
        list += records
        m.config.secrets = list.isEmpty ? nil : list
        try m.config.write(store.configFile(m.name))
        applyLaunchSecrets(m)
        for l in lines { note(m.name, l) }
        return lines
    }

    /// A sandbox's secrets revoked — at shutdown, reset and rm (and when it died with its daemon): every binding and
    /// placeholder gone (a request with one answers 403 "unknown or revoked"), every keychain item deleted.
    func revokeSandboxSecrets(_ m: Managed) {
        let secrets = m.config.secrets ?? []
        let vault = m.sandbox.egress?.vault
        for b in vault?.allBindings ?? [] where b.isLaunchSecret { vault?.remove(b.id) }
        guard !secrets.isEmpty else { return }
        for s in secrets { forgetLaunchSecret(owner: m.name, s) }
        m.config.secrets = nil
        if !readOnly, FileManager.default.fileExists(atPath: store.layout(m.name).sandboxDirectory.path) {
            try? m.config.write(store.configFile(m.name))
        }
        note(m.name, "its secrets (\(secrets.map(\.variable).joined(separator: ", "))) are revoked — give them again with --secret")
    }

    /// The session's own variables for a sandbox's secrets: VAR = a fresh placeholder (one per session, as every
    /// placeholder), and with `file=` FILEVAR = `$HOME/.doz-secrets/VAR`, a 0600 file holding the same placeholder —
    /// written now as the session's user (as Codex's auth.json is). Nothing when it has none.
    func deliverLaunchSecretFiles(_ m: Managed, user: String?) async -> [String: String] {
        guard let secrets = m.config.secrets, !secrets.isEmpty, let vault = m.sandbox.egress?.vault else { return [:] }
        let image = m.config.spec.imageSpec
        let home = image?.home ?? "/root"
        let owner = user ?? image?.user ?? "root"
        let dir = home + "/" + LaunchSecrets.sandboxFolder
        var env: [String: String] = [:]
        var script = ""
        for s in secrets where vault.issuesPlaceholder(s.bindingID) {
            guard let t = vault.mint(s.bindingID) else { continue }
            env[s.variable] = t
            guard let fv = s.fileVariable else { continue }
            let file = dir + "/" + s.variable
            env[fv] = file
            let b = Data(t.utf8).base64EncodedString()
            script += "printf %s '\(b)' | base64 -d > '\(file).doz-tmp'; chown '\(owner)' '\(file).doz-tmp'; chmod 0600 '\(file).doz-tmp'; mv -f '\(file).doz-tmp' '\(file)'; "
        }
        if !script.isEmpty {
            let all = "set -e; umask 077; mkdir -p '\(dir)'; chown '\(owner)' '\(dir)'; chmod 0700 '\(dir)'; " + script
            do {
                let r = try await m.sandbox.exec(["sh", "-c", all], timeoutSeconds: 30)
                if r.exitCode != 0 { note(m.name, "could not write the secrets' placeholder files (exit \(r.exitCode))") }
            } catch {
                note(m.name, "could not write the secrets' placeholder files: \(error.localizedDescription)")
            }
        }
        return env
    }

    // MARK: fenced sessions

    /// A fenced session's secrets into its proxy's vault (at open, restart and adoption): the record's, their values from
    /// memory or the keychain, and the placeholders its program was given (by hash).
    func bindFenceSecrets(_ s: String, _ p: MacFenceProxy, _ f: MacFenceRecord) {
        let secrets = f.secrets ?? []
        let vault = p.proxy.vault
        if secrets.isEmpty, !vault.allBindings.contains(where: \.isLaunchSecret) { return }
        bindLaunchSecrets(vault, secrets, owner: LaunchSecrets.macOwner(s), who: "@mac \(s)")
        vault.restorePlaceholderHashes((f.placeholderHashes ?? [:]).filter { $0.value.hasPrefix(CredentialBinding.launchSecretPrefix) })
    }

    /// Every root a fenced session could read (resolved) — its folder, its `--read`/`--write` folders, the home's
    /// allowlist (`mac.fence_read` among it), the system's, its agent's folders, its session folder.
    static func fenceReadableRoots(_ f: MacFence) -> [String] {
        var out = [f.workdir, f.sessionFolder] + f.readable + f.writable + f.gitCommon + f.homeReads.folders + f.homeReads.files
            + MacFenceProfile.systemReadRoots
        if let a = f.agent {
            out += a.readFolders + a.readFiles
            if !a.isPrivate { out.append(a.personHome) }
        }
        return out.map(resolvedRoot)
    }

    /// A root as the file system resolves it (`/tmp` → `/private/tmp`); itself when it cannot be.
    static func resolvedRoot(_ p: String) -> String {
        var b = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(p, &b).map { String(cString: $0) } ?? p
    }

    /// Write a fenced session's placeholder files (`<session>/etc/secrets/VAR`, 0600 in a 0700 folder — `etc` is
    /// host-owned: the program reads, never writes it) and return FILEVAR → path.
    static func writeFenceSecretFiles(_ f: MacFence) throws -> [String: String] {
        var out: [String: String] = [:]
        let withFiles = f.secrets.filter { $0.fileVariable != nil }
        guard !withFiles.isEmpty else { return [:] }
        try MacFenceHostFS.ensureDirectory(f.secretsFolder)
        for s in withFiles {
            guard let fv = s.fileVariable, let t = f.placeholders[s.variable] else { continue }
            try MacFenceHostFS.writeAtomically(Data(t.utf8), dir: f.secretsFolder, name: s.variable, mode: 0o600)
            out[fv] = f.secretsFolder + "/" + s.variable
        }
        return out
    }

    /// A fresh placeholder for a fenced session (the vault honours it by its hash, from the record).
    static func newPlaceholder() -> String {
        CredentialVault.placeholderPrefix + (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: the sweep

    /// Delete every launch secret's keychain item whose owner is gone (`<store>/secrets.json`): a sandbox that no longer
    /// has it, a session on this Mac whose record no longer has it. At a daemon's start, and after a session's record goes.
    func sweepLaunchSecrets() {
        guard !readOnly else { return }
        var ledger = LaunchSecretLedger.load(store)
        guard !ledger.items.isEmpty else { return }
        let sessions = mac.records().sessions
        var removed: [String] = []
        for (service, owner) in ledger.items {
            let live: Bool
            if owner.hasPrefix("mac.") {
                live = sessions[String(owner.dropFirst(4))]?.fence?.secrets?.contains { $0.keychainService == service } == true
            } else {
                live = managed[owner]?.config.secrets?.contains { $0.keychainService == service } == true
            }
            guard !live else { continue }
            try? services.keychain.delete(service: service, account: Keychain.user)
            launchSecretMemory[service] = nil
            removed.append(service)
        }
        guard !removed.isEmpty else { return }
        for s in removed { ledger.items[s] = nil }
        ledger.save(store)
        HostLog.line("launch secrets: \(removed.count) keychain item\(removed.count == 1 ? "" : "s") of owners that are gone deleted")
    }

    /// The memory copies of a fenced session's secrets whose record is gone (the sweep deletes their items).
    func dropFenceSecretMemory(_ s: String, _ secrets: [LaunchSecret]) {
        for x in secrets { launchSecretMemory[LaunchSecrets.service(store: store.root, owner: LaunchSecrets.macOwner(s), variable: x.variable)] = nil }
    }

    /// `doz net show`'s rows of `secrets` (nil: none).
    static func secretRows(_ secrets: [LaunchSecret]?, vault: CredentialVault?) -> [LaunchSecretRow]? {
        guard let secrets, !secrets.isEmpty else { return nil }
        return secrets.map { s in LaunchSecretRow(s, plainHTTP: vault?.binding(s.bindingID)?.plainHTTP ?? DozableSettings.load().bool(SettingKey.placeholdersPlainHTTP)) }
    }
}
