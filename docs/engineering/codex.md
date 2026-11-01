# Codex

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableKit/OpenAIAccess.swift`; `Sources/DozableHost/ChatGPTAccounts.swift`, `ChatGPTSignIn.swift`; `Sources/doz-vmtest/CodexSuite.swift` | Codex — the proxy's OpenAI side (claims, the guest's auth.json, the renewal answer, `HTTPSOnce`, the sign-in's and refresh's requests); the host's sessions, `applyOpenAIAccount`, the guest auth.json; Dozable's own ChatGPT sign-in; `make test-cli-codex` |

## Codex as a first-class agent

- **The agent `codex`** (`AgentKind.codex`, added LAST to `allCases`): `codex` = Node · Codex, `<base>-codex` on every
  other base and a Dockerfile's. ONE recipe on every base (`ImageComposer`, `AgentImages.codexInstall`): the npm
  registry's `@openai/codex/-/codex-<v>-linux-arm64.tgz` (a STATIC musl binary — Debian and Alpine alike), its sha512
  checked against `AgentRelease.integrity`, unpacked to `/opt/codex`, `/usr/local/bin/codex` linked; on a musl base the
  bundled glibc `codex-path/rg` is removed (the baseline's ripgrep is used). `CODEX_HOME=~/.codex` (state disk). The
  release for codex is the MAIN package's version and the PLATFORM package's integrity (`AgentVersions.refreshPackage`
  looks up `latest`, then `<v>-linux-arm64`); the pin is 0.160.1 (`AgentImages.codexPinned`). Codex has no pre-596 Node
  image: `codex` is composed like any pair. **Claude Code's and pi's recipes are untouched** — `RecipePinTests` pins
  every catalogue base × claude-code/pi/none spec and bake key as they were before 599i; keep it green.
- **The launcher** (`AgentImages.codexLauncherScript`, `~/.local/bin/codex`): agent runs (no subcommand, a prompt,
  `exec`/`e`/`resume`/`fork`) get `--dangerously-bypass-approvals-and-sandbox` (+ `notice.hide_full_access_warning`)
  unless `DOZ_CODEX_PERMISSIONS=ask` (the setting `codex.permissions`, `HostCore.withClaudePermissions`) or root; every
  run gets `-c check_for_update_on_startup=false -c cli_auth_credentials_store=file`; the facts file as
  `-c developer_instructions=<TOML string>` (python3 `codex-setup.py prompt`; not when the caller gives
  `developer_instructions`); `codex-setup.py trust` appends `[projects."<cwd>"] trust_level = "trusted"` only when the
  folder has no entry. `review` gets no bypass flag (it has none); `login`, `mcp`, `--version` … run as they are. The
  launcher names no credential (`testTheLauncherSkipsApprovalsAndDeliversTheFacts`). Re-check the flags when the pin moves.
- **Accounts** (`AccountKind.openaiKey` = `openai-key`, `.chatgpt`): Codex accepts ONLY these; Claude Code and pi never
  get them, Codex never an Anthropic one (`AgentCredentials` — `provider`). The store has TWO defaults:
  `AccountsFile.defaultAccount` (Anthropic) and `openaiDefault` (Codex; nil = none — never the Anthropic one);
  `doz account default NAME` with an OpenAI account sets the latter; `resolvedAccount` and `createProblem(…openaiDefault:)`
  follow the sandbox's provider. `AccountRow.isDefault` is true for both defaults (callers pick by kind's provider).
- **Dozable's OWN ChatGPT sign-in** (`ChatGPTSignIn`, run in the CLI process by `doz account add NAME --chatgpt`, `doz
  onboard --openai-account chatgpt`, the create preflight): Codex's own browser flow (0.160.1 `login/src/server.rs`) —
  PKCE S256, Codex's public client id, its scopes and parameters, a loopback listener on **127.0.0.1:1455, else 1457**,
  `redirect_uri=http://127.0.0.1:PORT/auth/callback`, the browser opened by `BrowserBridge.open` — then the code is
  exchanged (FORM post) over `HTTPSOnce` (the proxy's `TLSUpstream` leg). NO token exchange for an API key. The tokens go
  to the host in `account-add` (`ChatGPTTokens.json`); the keychain keeps ONLY `ChatGPTRecord` (the refresh token, the
  account id, the id_token claims Codex reads — `OpenAIAccess.keptClaims`) in `doz-chatgpt:NAME`, through `KeychainChunks`
  (parts `NAME#1…#8` + a `doz-chunks:n:<sha256>` header written last, only when it does not fit one item); the ACCESS
  token lives in the host's memory only (a new host renews on first use). `accounts.json` gets plan/email/account
  id/fingerprint, never a token. **Dozable never reads or writes the Mac's `~/.codex`**
  (`testDozableNeverTouchesTheMacsCodexHome` scans DozableHost/CLI/Web).
- **The refresh is the host's** (`ChatGPTSession`, ONE per account in `HostCore.chatgptSessions`): the vault's provider
  (`setProvider(.chatgpt, ttl: 60, version: generation)`) reads the access token; it renews when its JWT `exp` is
  within 5 minutes or after an upstream 401 (`vault.onStale` → `markStale`, which bumps the generation so the vault re-reads
  at once); one refresh at a time; the ROTATED refresh token is written to the keychain BEFORE the new access token is
  used — a write that fails REMOVES the item (never a spent token left to try later): the sign-in then lives in that host's
  memory only, said in the log. A permanent refusal (401, `refresh_token_reused|expired|invalidated`, `invalid_grant`) = signed out → every read
  and renewal answer is a notice naming `doz account add NAME --chatgpt --force`. A network failure keeps an unexpired
  token working and retries after 30 s. **No silent fallback** — never another account's token or a key.
- **The proxy** (`OpenAIAccess`, `EgressProxy`): bindings `.openai` (Bearer, `api.openai.com`, `OPENAI_API_KEY`) and
  `.chatgpt` (Bearer, `chatgpt.com` + `auth.openai.com`, **swap-only**, no variable — its placeholder lives in auth.json).
  **Codex's own refresh** (`POST auth.openai.com/oauth/token`) is ANSWERED by the proxy (`EgressProxy.chatgptRenewal`,
  body held ≤ 64 KiB, Content-Length only): a placeholder of this sandbox's chatgpt binding → 200 with the SAME placeholder
  for both tokens and the guest id_token (the Mac renews first when due); another doz placeholder → 401; no placeholder →
  judged by the policy (auth.openai.com is NOT in any permission) and forwarded only if allowed. `connectionVerdict` makes
  auth.openai.com `.inspect` only while a renewal gate is set. Refusals on OpenAI hosts are OpenAI-shaped
  (`OpenAIAccess.refusal`). WebSockets (Codex dials `wss://chatgpt.com/…/responses` first) are swapped in the upgrade's
  head, then raw. Test seam: `DOZ_TEST_OPENAI_UPSTREAM` + `DOZ_TEST_OPENAI_CA` (`OpenAISeam`) — the proxy's OpenAI leg,
  the sign-in's exchange, the host's refresh and the key check go to a fake, trusting ONLY its CA.
- **The guest's `~/.codex/auth.json`** (`HostCore.codexAuthScript`, a root utility exec at every open-session of a Codex
  sandbox and before `doz exec … codex`): ChatGPT — `auth_mode: chatgpt`, `OPENAI_API_KEY: null`, ONE fresh placeholder
  (`vault.mintForFile`) for access and refresh token, the id_token with its real claims and the signature replaced by
  `doz-unsigned` (`OpenAIAccess.guestIDToken` — the real id_token is a credential: Codex trades it for an API key),
  `account_id`, `last_refresh = now`; API key — `auth_mode: apikey` + placeholder. 0600, the agent's. No OpenAI account →
  only a file holding a doz placeholder is removed; an account whose credential is unusable leaves the file (its
  placeholders get the proxy's reason).
- **`mac` for Codex (rc.3, `CodexMacLogin.swift`) — THIS Mac's own Codex login, 588's `mac` rules as the template.**
  `AccountKind.codexMac` (`codex-mac`, never in accounts.json; `AccountRecord.codexMac`): a Codex sandbox's account
  `mac` resolves to it (`resolvedAccount` by provider — Claude's `mac` is untouched). Dozable READS ONLY the access token
  and the kept claims/account id from `$CODEX_HOME/auth.json` (else `~/.codex`; `CodexMacLogin.read` takes those fields
  out of the parse — never the refresh token), NEVER writes CODEX_HOME (`testDozableNeverTouchesTheMacsCodexHome` allows
  only this file, read-only). Re-read on use: the vault provider's version is the file's inode/size/mtime
  (`CodexMacSession.version`). Expired / signed out / keyring store (`cli_auth_credentials_store` keyring|auto) /
  an API-key login → `problem()`: the proxy's 401, never another account. It is the DEFAULT Codex account while the
  Mac's Codex is signed in (`effectiveOpenAIDefault`: `openaiDefault` else mac-if-signed-in; compute it ONLY for an
  OpenAI agent — it reads the Mac's file); `doz account default NAME --codex` sets it by name. Keep-alive
  (`codex.keep_alive`, off): `codex doctor` (no model call — its websocket check asks for the auth, which refreshes)
  once per expiry when the token is within `keepaliveWindow` (270 s; Codex refreshes within 5 min) and a sandbox used
  it within 15 min. Freshness otherwise: the Codex app's server lists models every 4½ min (0.160.1
  `models_refresh_worker.rs`), which refreshes. **Tests never read the real ~/.codex**: `CredentialServices.codexHome`
  (memory seam: `DOZ_TEST_CODEX_HOME` or none; `CodexMacLogin.resolveHome` STOPS the process inside XCTest without it),
  `DOZ_TEST_CODEX_BIN` (a fake codex); CLIHarness sets both to scratch paths. `CodexMacLoginTests`, the suite's part 6b.
- **Permission `model:openai`** "Talk to OpenAI" (chatgpt.com, api.openai.com, ab.chatgpt.com): an AGENT permission
  (`AgentPermissions.agentPermissions(.codex)`) — added at create (`DozableImages.spec`), kept by every preset change and
  edit (`editedPolicy(…agent:)`, `PermissionPolicy.edited(…agent:)` refuses revoking it for Codex), never in a preset
  (Open included), never inferred, never suggested, and absent from another agent's checklist and facts.
- **The environment prompt**: `AgentPrompt.agent(of:)` = `codex`; the skill in `~/.agents/skills/doz` (Codex's user
  skills — never AGENTS.md); new variable `agent.state` (renders exactly as before for Claude Code/pi); the credentials
  sentence says OpenAI for Codex.
- **Tests**: `OpenAIAccessTests`, `EgressProxyTests` (renewal answered / refused / policy), `CodexHostTests`,
  `RecipePinTests`; `make test-cli-codex` — a python3 fake OpenAI over TLS (`probes/599i-*/fake_openai.py` is the same
  server), the real Codex in VMs (codex + alpine-codex): the sign-in through the browser seam, the swap, a renewal on the
  Mac, the guest's renewal answered, no token anywhere in the guest, no silent fallback, the API key. `CODEX_KEEP=1`
  keeps its store (`/tmp/dzo-codex-keep`) and the prepared images.
