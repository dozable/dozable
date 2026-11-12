# Accounts, GitHub and Access

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/ClaudeLogin.swift`, `Accounts.swift`, `LoginWatcher.swift`, `HostCore+Accounts.swift` | the Mac's Claude Code login (read-only), the keychain through `/usr/bin/security`, accounts (`<store>/accounts.json`, never a secret), ONE watcher per Mac login, the keep-alive, key policy |

## Rules that each cost a bug to learn here

- **The host reads the Mac's login in ITS session** (679 B6: `doz image bake claude-code` over ssh started a host in the
  ssh session, where the login keychain is locked; every sandbox after showed `mac (unreadable)` while doctor, in the
  logged-in session, said "ok claude login"). `HostSessionKind` (`SessionGetInfo`: no graphic access, remote, or
  `SSH_CONNECTION` without one) is read by the host at its start (`HostStatus.keychainLocked`, host.log);
  `HostLauncher.spawn` warns before it starts a host from such a session; `doz account ls|show`, `doz ls` (a mac
  account not ok) and doctor (`host login` — a FAILURE when doctor itself reads the login) name the host and say
  `doz host restart` from a logged-in session; `doz image bake` stops a host it had to start there once nothing runs.
  The guarded seam `DOZ_TEST_KEYCHAIN_LOCKED=1`; a guarded run's own session never warns. `HostSessionKindTests`,
  `make test-cli-keychainlocked`. A LaunchAgent host in the GUI domain is not done ("No launchd agent" — an owner
  question).

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

## Access — every credential a purposeful choice, each confirmed

- **One step, three places**: `doz onboard`'s "2. Access" (`AccessStep` in `AccessCommands.swift`, shared with
  `doz access` / `doz access set`), the wizard's GitHub & SSH step (634: Claude's sign-in is Models & keys') and **Settings › Access** — both drawn by ONE
  self-contained component, `renderAccessStep(container, {mode: 'onboarding'|'sandbox'|'settings', state,
  claude, choices, onChange})` in `components/access-step.js` (599f's New Sandbox wizard reuses it). It writes NOTHING but the default
  GitHub key; the caller writes the choices (onboarding: `POST onboarding/config {access}`; sandbox: its create).
- **The host's `access` op** (`Access.swift`): the report (choice, source, state confirmed|failed|off|unchecked,
  detail, consequence) and, with `check`, a LIVE check of `items`, of `accessChoices` when given (the onboarding
  confirms before it writes). Read-only (no `check`) is answered in-process; `check` needs the host. The record
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
- **Web**: `GET /api/v1/access` (never starts a host), `POST /api/v1/access/check` (CSRF, strict
  `WebAccessCheck`), `POST /api/v1/access/github-key` (`WebAccessGitHubKey`, redacted, `allow_secret_entry`).
- **Tests**: `AccessTests` (a scratch env passed to `access(_:environment:)` — never the process's XDG/agent),
  `AccessWebTests`, `make test-cli-access` (no VM: a fake GitHub API with its own CA, a fake gh, a throwaway
  agent; SSH_AUTH_SOCK removed), the workspace probe `probes/599e-*/run-access-probe.sh`.
