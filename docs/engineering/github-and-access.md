# Accounts, GitHub and Access

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/ClaudeLogin.swift`, `Accounts.swift`, `LoginWatcher.swift`, `HostCore+Accounts.swift` | the Mac's Claude Code login (read-only), the keychain through `/usr/bin/security`, accounts (`<store>/accounts.json`, never a secret), ONE watcher per Mac login, the keep-alive, key policy |
| `Sources/DozableHost/Keepalive.swift` | the login keep-alive's modes (`KeepaliveMode`), who holds the login (`ClaudeHolders`), its record `<store>/keepalive.json` (`KeepaliveRecord`) and what is shown (`KeepaliveStatus`) |

## Rules that each cost a bug to learn here

- **The daemon reads the Mac's login in ITS session** (679 B6: `doz image bake claude-code` over ssh started a daemon in the
  ssh session, where the login keychain is locked; every sandbox after showed `mac (unreadable)` while doctor, in the
  logged-in session, said "ok claude login"). `HostSessionKind` (`SessionGetInfo`: no graphic access, remote, or
  `SSH_CONNECTION` without one) is read by the daemon at its start (`HostStatus.keychainLocked`, daemon.log);
  `HostLauncher.spawn` warns before it starts a daemon from such a session; `doz account ls|show`, `doz ls` (a mac
  account not ok) and doctor (`daemon login` — a FAILURE when doctor itself reads the login) name the daemon and say
  `doz daemon restart` from a logged-in session; `doz image bake` stops a daemon it had to start there once nothing runs.
  The guarded seam `DOZ_TEST_KEYCHAIN_LOCKED=1`; a guarded run's own session never warns. `HostSessionKindTests`,
  `make test-cli-keychainlocked`. 694: with the login item (`doz daemon login-item on`) a client in such a session kickstarts the item instead, so the
  daemon starts in the desktop session and reads the keychain; `daemon restart` from there never replaces a desktop daemon
  (engine.md, "The login item").

- **The Mac login has two stores, read-only** (687): Claude Code keeps a login in the Keychain item `Claude
  Code-credentials[-<8 hex>]` and, where it cannot write the Keychain (a `claude` login over ssh: the login keychain is
  locked there), refreshes ONLY `<claude config>/.credentials.json` — doz read only the Keychain and said "expired". Now
  `ClaudeMacLogin.choose(keychain:file:now:)` (pure, `ClaudeMacLoginTests`' table) decides: an unexpired login wins; both
  unexpired → the later expiry (a tie keeps the Keychain's); the file is used ONLY unexpired — otherwise the Keychain's
  answer stands (its expired login, absent, locked, unreadable). `ClaudeCredentialsFile.read`: `O_NOFOLLOW`, a regular
  file owned by the user, ≤ 64 KiB, parsed by `ClaudeLogin.parse` (the access token and its dates; the refresh token is
  dropped with the bytes). The same account (its identity is still `.claude.json`'s, pinned and followed as before — no
  fallback between ACCOUNTS). Used by `LoginWatcher.readNow` (what every proxy swaps in; `store`, a daemon note when the
  store changes), `ClaudeLoginStatus.check` (doctor's "claude login … · from ~/.claude/.credentials.json", onboarding,
  Access), `doz account ls|show` ("key from: this Mac's Claude Code login, from the Keychain" / "…from
  ~/.claude/.credentials.json") and `account verify`. Never written. Guarded runs: `ClaudeCredentialsFile.path` gives
  only `DOZ_TEST_CLAUDE_CREDENTIALS_FILE` (none without it, and none under `DOZ_TEST_NO_MAC_LOGIN`/`memory`); a read of
  a `.credentials.json` in the real home is a `TestSafety` stop.

- **The login keep-alive changes only WHEN the Mac's own `claude -p` runs** (695). Renewal is the Mac's: the keep-alive
  runs this Mac's Claude Code once and Claude Code renews its own login as it starts — Dozable never reads, holds, writes or
  logs the refresh token, and writes no `Claude Code-credentials*` item. Modes (`doz account keepalive off|on|always`;
  `AccountsFile.keepalive` stays true for on and always so an older doz reads it as on, `keepaliveMode` "always" refines it,
  `KeepaliveMode.of`): **on** — at the expiry (see the timing below), while a subscriber used the login in
  the last 15 min (a sandbox, and a fenced session: `MacFenceProxy` is a `CredentialTarget`, so it counts by construction —
  `LoginWatcherTests` pins it); **always** — no use needed: the daemon keeps a STANDING watcher on each `mac`-kind account
  (`HostCore.ensureStandingWatchers`, at its start and on a mode change; `LoginWatcher.standing` keeps it when its last
  subscriber goes). With the always-on daemon a renewal can happen on a Mac where nothing runs.
  - **What blocks a renewal (each a skip, recorded with its reason, retried at the next look — never using up the
    expiry):** a daemon whose login keychain is locked (`HostServer.keychainLocked`: started over ssh — it never runs it);
    Claude Code not installed; and an UNFENCED Claude Code running — it holds its own copy of the login, which a renewal by
    anyone else cancels (the reported fact; the skip holds either way). `ClaudeLogin.claudePids` (command line `claude …` or
    Claude Code's versioned binary, minus Dozable's own `deckhold-mac`/`doz` that only NAME it in their argv) →
    `ClaudeHolders.find`: a member of a FENCED session (its sentinel, `MacFenceStop`'s test) holds only a placeholder and is
    left out — named in the daemon's log; the keep-alive's own run (`KeepaliveRuns`) too; any other is a holder, named by
    the unfenced session whose program it is or descends from ("Claude Code (pid N, session admin on this Mac)", or "not
    Dozable's"). The kept-session restart after a renewal is not this rule's.
  - **The run, the minimum:** a fixed argv (`KeepaliveConfig.arguments`: `-p ok --model haiku --max-turns 1
    --no-session-persistence --tools "" --strict-mcp-config --settings '{"disableAllHooks":true}'` — the last three kept
    because `claude --help` lists them; never `--bare`, which reads no OAuth login), the env allowlist
    (`scrubbedEnvironment`: PATH, HOME, USER, LOGNAME, LANG, TMPDIR, SHELL, CLAUDE_CONFIG_DIR — never `ANTHROPIC_*`,
    `CLAUDE_CODE_*`, `CLAUDECODE`), a fresh EMPTY `<store>/keepalive/run` (0700, made again for each run), 120 s then
    TERM, KILL. Nothing from a sandbox reaches its argv, env or folder.
  - **When: AT the expiry, not before** (`KeepaliveSchedule`). Claude Code renews only a token that has EXPIRED — seen on a
    real Mac (Claude Code 2.1.325): this exact command run 7 min 46 s before the expiry exited 0 and left the login as it
    was; after the expiry the login showed a new expiry 8 h on. So the first run for an expiry is due at the expiry (the
    watcher sets a timer for it — a renewal follows within seconds, not at the next 2-minute poll — and a proxy that finds
    the token expired asks for a look at once). A run that exits 0 and leaves the expiry as it was is `unchanged` ("Claude
    Code did not renew the login (the token had not expired yet)") and NOT final: again 1, 5 and 15 min after the expiry,
    then every 30 min, 6 runs at most, then `failed`. A renewal, or a run that exits non-zero, ends the tries for that
    expiry. One run in flight at a time; a skip never uses a run up. A sandbox asking while the token is expired gets the
    proxy's 401 as before, unless the renewal came first. `ClaudeMacLogin.choose` offers the credentials FILE's login
    expired when there is no Keychain item at all (a login made only over ssh) — otherwise an expired file-only login read
    as signed out and could never be renewed. Seam: `DOZ_TEST_KEEPALIVE_SCHEDULE` (guarded).
  - **The record** `<store>/keepalive.json` (0600; `KeepaliveRecord`): `account`, `mode`, `lastAttemptAt`, `outcome`
    (`renewed|unchanged|skipped|failed`), `reason`, `exit`, `expiresBefore`, `expiresAfter`, `nextTryAt` (the new expiry,
    or the next retry), and the last
    renewal kept across later tries. The reason holds only the exit code and Claude's last stderr line, at most 200
    characters, token-shaped runs replaced by `…` (`KeepaliveRecord.clean`). It is read without a daemon: `doz account ls`
    ("keep-alive always · last renewed 09:02 (until 17:02) · next try 16:52"; `--json`: the Mac row's `keepalive`), `doz
    daemon status` (`HostStatus.keepalive`; with no daemon from the store) and doctor's "Claude login keep-alive" row (a
    warning on a failure, a locked daemon, or `on` with nothing using the login). One daemon log line per try; metrics
    action `keepalive`.
  - **Asked once, after "start at login":** onboarding and `doz daemon login-item on` ask "Also keep this Mac's Claude login
    renewed when no sandbox uses it? [y/N]" — only on a terminal, never `--json` or in a guarded run (`KeepaliveOffer`);
    off a terminal the command is printed.
  - **Tests never run the real `claude -p`:** a guarded run's only claude is the fake `DOZ_TEST_CLAUDE_BIN` (resolved,
    run and counted as a running Claude Code by file name), and `TestSafety.keepaliveClaudeViolation` stops the guarded
    runner (`ProcessKeepaliveRunner(claude: true)`) that would run anything else; `DOZ_TEST_LOGIN_WATCH_SECONDS` sets the
    watch interval. `LoginWatcherTests`, `KeepaliveStatusTests`, `TestSafetyTests`, `make test-cli-host` row K,
    `make test-cli-fence` (a fenced fake Claude Code does not block it), `make test-cli-keychainlocked` row 9.

- **Agent credentials (`AgentCredentials.swift`; the table is `AgentImages.credentials`):**
  Claude Code: `mac`, `setup-token`, `api-key` (660: and through models@1 a gateway's `key` — OpenRouter — or the
  key-less `local`; its Anthropic source keeps those three, `AgentCredentials.source(of:provider:image:)`); pi: `api-key` ONLY (it reads `ANTHROPIC_API_KEY`;
  never hand it a Claude subscription — `applyAccount` clears both bindings, with a notice, for an
  account the agent cannot use). `createProblem` runs in `HostCore.create` and `duplicate` (proxied
  networks only; an explicit `none` is allowed, the default resolving to none is not for pi), in the
  CLI's `preflightAgentAccount` (create/up/init; on a TTY it offers a fitting account or the hidden
  paste of a key) and, through `WebAccounts.agents`, in the web forms (`accountChooser`).
  `useAccount` refuses an incompatible account. `SandboxInfo.credentialProblem` is the page's
  banner and switches the facts block to "no credential you can use is attached". Room for other
  providers: `AgentCredentialSupport(provider:accountKinds:)`.

- **One account wiring for a sandbox and a fenced session on this Mac** (683): an Anthropic account (this Mac's login, a
  setup token, an API key) is put into a `CredentialTarget`'s vault by `HostCore.bindAnthropicAccount` — a `Sandbox`
  (`applyMainAccount`), or a fenced `@mac` session's own proxy (`MacFenceProxy`, `bindFenceAccount`, before it accepts
  a connection). `LoginWatcher` subscribes targets, not sandboxes (`@mac S` for a session); `applyKeySecret` takes a
  target. The rules stay the sandboxes': access token only, never the refresh token or a `Claude Code-credentials*` item,
  never injected beside the program's own credential (a fenced session's vault is strict), a foreign one a fingerprint,
  no fallback between accounts. A fenced session's placeholder is minted at open (its hash in the record, honoured by a
  later daemon — `restorePlaceholderHashes`).

## GitHub as the user

- **Proxy insertion, like the Anthropic credential — and nothing more.** `CredentialBinding.github`
  (hosts `GitHubAccess.credentialHosts`: github.com, api.github.com, uploads.github.com, codeload.github.com)
  is **swap-only** (`swapOnly`: never injected into a request without its placeholder) and puts ONE placeholder
  in `GH_TOKEN` and `GITHUB_TOKEN` (`alsoEnvironmentVariables`). The vault finds a placeholder inside an
  `Authorization: Basic` login too (`basicDecoded`/`searchable`/`placeholders(inHead:)` — the leak guard and
  the plain-HTTP guard see it) and swaps it there by decode → swap → re-encode. "strict" pins the
  ANTHROPIC credential only: a guest's own GitHub token is flagged, never refused by it.
- **The token is READ ON USE** (`CredentialVault.setProvider`): `gh auth token` (or the sandbox's own key —
  memory `HostCore.githubKeys`, or a keychain item re-read), cached `GitHubLogin.cacheSeconds` in the vault's
  memory only; the provider's `version` (the `github.credentials` value) drops the cache the moment the source
  changes. Never in `doz.json` (only `credentialSources["github"] = stdin|keychain:…`), a log, an event or the
  guest. Turning the permission off = `vault.remove("github")`: every placeholder issued is refused at once.
- **Read-only is the PROXY's** (`GitHubAccess.classify`, in `EgressProxy.intercept` for requests whose decision
  swapped the github binding): receive-pack anywhere (decoded, case-folded) refused; api.github.com only
  GET/HEAD, plus `POST /graphql` whose BODY is held (≤ 256 KiB, Content-Length only — chunked refused) and
  parsed by `graphQLIsQuery` (top-level definitions only; anything unsure → refused); LFS batch only
  `"operation": "download"`. The 403 is `text/plain` so git shows it as `remote: …`. Keep the parser
  conservative: a new GraphQL construct is refused until a test says it is a read.
- **The state is the policy's permissions** — `github:as-you`, `github:push` (`AgentPermissions.gitHubMode`;
  push needs as-you; never in a preset, Open included; a preset choice keeps them; never inferred from a
  pre-597 policy, never suggested for a denied host). `--github`/`github:` are sugar for them. `HostCore.applyGitHub`
  applies everything (vault provider, `EgressProxy.github` gate, identity, SSH agent) — at load/create, on a
  `net-policy` change, `sandbox.ssh_agent`, `key set --github`.
- **The guest half is in `guestFixes`** (boot AND wake): `git-credential-doz` (stamp `doz:git-credential:vN` — bump
  on any change; it answers ONLY a `doz_cred_` placeholder, ONLY for https://github.com), `/etc/doz/gitconfig`
  (helper + the Mac's identity, or a comment when off) included once from `/etc/gitconfig`, and the SSH agent.
  `Sandbox.applyGitHubToGuest` applies them to a running guest. 635 (owner: push turned on mid-session, the agent's
  push still asked for a username — its session had no `GH_TOKEN`): `GitGuestSetup.placeholder` is the sandbox's own
  placeholder (minted once, kept while `vault.holds` it), written to `/etc/doz/github-placeholder` while on (removed
  when off); helper v3 reads it first, then `$GH_TOKEN`. `gh` in an older session still lacks `GH_TOKEN` (a new
  session has it).
- **SSH agent (G4)**: `SSHAgentRelay` (host vsock 5801 → the Mac's agent socket) only while `sandbox.ssh_agent`
  is on; it FILTERS the guest's requests (`allowed`: list 11, sign 13, the session-bind extension 27 — anything
  else, e.g. add/remove/lock, is answered SSH_AGENT_FAILURE and never reaches the Mac's agent); `doznet agent` (guest, `/run/doz/ssh-agent.sock`) — started after doznet is copied at a fresh boot,
  by guestFixes at a wake; `EgressProxy.sshToGitHub` allows github.com:22 (and its DNS) and nothing else; port
  22 is never decrypted. Off = no listener (the agent-sudo suite's "no vsock listener but 5800" holds).
- **Notices** that come from the proxy (not a session's output) go through `BridgeState.notifyViewers`: the
  attach relay registers every attached terminal per sandbox. First use per apply (`firstUse`/`resetFirstUse`).
- **Tests never use the user's GitHub, gh, ssh-agent or git identity**: `DOZ_TEST_GH` (a fake gh),
  `DOZ_TEST_GITHUB_UPSTREAM` + `DOZ_TEST_GITHUB_CA` (the upstream leg goes to a fake GitHub, trusting ONLY that
  CA), `DOZ_TEST_SSH_AUTH_SOCK` (a throwaway agent), `GIT_CONFIG_GLOBAL` (a scratch identity).
  `make test-cli-github` runs a python3 `git http-backend` over TLS as the fake GitHub.

- **A fenced session on this Mac** (`doz run @mac --github read|push`, `--ssh-agent`; fenced by default) uses the same machinery
  through its own proxy (`HostCore.bindFenceGitHub`, `MacFenceDoors.swift`): the provider, the gate, the placeholder
  (minted at open into `GH_TOKEN`; git's helper from `GIT_CONFIG_*`), the filtered agent relay on a unix socket in the
  store's socket folder instead of vsock; `gh` reaches the proxy through its own door (`http_unix_socket`). A guarded run
  reads only `DOZ_TEST_GH` and `DOZ_TEST_SSH_AUTH_SOCK`. Details in sessions.md.

## Access — every credential a purposeful choice, each confirmed

- **One step, three places**: `doz onboard`'s "2. Access" (`AccessStep` in `AccessCommands.swift`, shared with
  `doz access` / `doz access set`), the wizard's GitHub & SSH step (634: Claude's sign-in is Models & keys') and **Settings › Access** — both drawn by ONE
  self-contained component, `renderAccessStep(container, {mode: 'onboarding'|'sandbox'|'settings', state,
  claude, choices, onChange})` in `components/access-step.js` (599f's New Sandbox wizard reuses it). It writes NOTHING but the default
  GitHub key; the caller writes the choices (onboarding: `POST onboarding/config {access}`; sandbox: its create).
- **The daemon's `access` op** (`Access.swift`): the report (choice, source, state confirmed|failed|off|unchecked,
  detail, consequence) and, with `check`, a LIVE check of `items`, of `accessChoices` when given (the onboarding
  confirms before it writes). Read-only (no `check`) is answered in-process; `check` needs the daemon. The record
  is `<store>/access.json` — states and reasons, NEVER a secret; an answer counts only for the choice (and
  source) it was given for. `access-github-key` sets/removes the default key (keychain `doz-github`), which
  `applyGitHub`'s provider reads after a sandbox's own key when `github.credentials = key`.
- **The checks**: GitHub — the token as a sandbox gets it (`Access.githubToken`), then `GitHubAccess.confirm`:
  `GET /user` over `TLSUpstream` (the proxy's leg; the test upstream seam), login + `X-OAuth-Scopes`, or for a
  scope-less token `GET /user/repos?per_page=100`'s count. SSH — `SSHAgentRelay.listKeys` (REQUEST_IDENTITIES,
  nothing signed). Claude — the store default: `ClaudeLoginStatus` for `mac`, `services.verifier` for a key.
- **Never blocks, never silent**: a failure KEEPS the choice (Skip; "not confirmed") — turning it off is the
  person's. `--yes`/no TTY skips with a note, exit 0. The onboarding writes `defaults.github` /
  `github.credentials` / `sandbox.ssh_agent` only when CHOSEN (a flag or a TTY answer) — `--yes` alone changes
  nothing. `defaults.github` (off|read|push, default off) joins the permissions only where `defaults.permissions`
  applies (no `--network`, not the form's exact list); `WebBases.github` seeds New Sandbox's switches.
- **Web**: `GET /api/v1/access` (never starts a daemon), `POST /api/v1/access/check` (CSRF, strict
  `WebAccessCheck`), `POST /api/v1/access/github-key` (`WebAccessGitHubKey`, redacted, `allow_secret_entry`).
- **Tests**: `AccessTests` (a scratch env passed to `access(_:environment:)` — never the process's XDG/agent),
  `AccessWebTests`, `make test-cli-access` (no VM: a fake GitHub API with its own CA, a fake gh, a throwaway
  agent; SSH_AUTH_SOCK removed), the workspace probe `probes/599e-*/run-access-probe.sh`.
