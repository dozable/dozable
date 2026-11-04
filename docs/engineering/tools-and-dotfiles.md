# The tools layer and dotfiles

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Guest/tmux/` (`build.sh`, `PROVENANCE.md`, `LICENCES/`), `Resources/tmux`, `Scripts/tmux-provenance.sh`; `Sources/doz-vmtest/Tmux38Suite.swift` | the guest tmux 3.8 (static, from sha256-pinned sources with the pinned Zig) the tools layer copies in for `sessions.tmux`; `make tmux` / `tmux-verify`; `make test-cli-tmux38` |
| `Sources/DozableKit/Dotfiles.swift`; `Sources/DozableHost/Dotfiles+Host.swift`; `Sources/DozableCLI/DotfilesCommand.swift`; `Sources/DozableWeb/WebDotfiles.swift`; `Sources/doz-vmtest/DotfilesSuite.swift` | 657: the person's dotfiles — the source, the pin, the plan (the install script or the links, Dozable's protected paths), the guest scripts and a run's result; the Mac's git cache (`<store>/dotfiles`), the trust record, the ops `dotfiles` / `dotfiles-resolve` / `dotfiles-update`; `doz dotfiles` and the create's trust question; the dashboard's projection and `POST /api/v1/dotfiles/resolve`; `make test-cli-dotfiles` |

## The tools layer — tools follow settings, on every base, no rebuild

- **One model** (`ToolsLayer.swift`): `ToolInputs` (github, ssh, tmux — from the settings) → `ToolPlan`
  (`ToolItem`: id, title, reason, kind binary|package|file, source; plus `removals`) → a guest check script →
  `applyScript` (one `doz-tool ID STATE DETAIL` line per tool) → `ToolsReport`. Pins: gh 2.102.0 + its tarball
  sha256; GitHub's three published SSH host keys (`ToolsLayerTests` checks them against the published
  fingerprints).
- **gh** comes from `ToolsCache` (`<store>/tools/gh/<ver>/gh`, one download per store, sha256 or refused;
  seam `DOZ_TEST_TOOLS_URL=http://127.0.0.1:PORT`) and is COPIED in (`copyIn`, no guest network) to
  `/usr/local/lib/doz/bin/gh`, linked `/usr/local/bin/gh` only when free; REMOVED when off (only Dozable's copy
  and link). **tmux 3.8** (658) is a `binary` item too, but from the package's own resources (`TmuxBinary`, no
  download): copied to `/usr/local/lib/doz/bin/tmux` when `tmux.version` differs, `tmux -V` must say the pin, linked
  `/usr/local/bin/tmux` when free; never removed (see tmux B3). Packages (openssh-client, git, curl,
  ca-certificates) — apt/apk through the proxy, only when missing. github.com's keys — a managed block in
  `/etc/ssh/ssh_known_hosts`.
- **When**: `Sandbox.start()` after the boot, and `applyGuestFixes` (wakes — after the wake is reported done); the FIRST apply in a sandbox (no
  `/var/lib/doz/tools`) is loud (`tools: …` steps), later ones quiet (a note; the host tells viewers on a
  change/failure). Never fatal. `toolInputs == nil` (the default) = no layer: preparation VMs and helpers
  never run it — the host sets inputs for every managed sandbox (`applyToolInputs`, beside `applyGitHub`;
  a live change on a running sandbox applies at once). Recipes untouched (`ToolsLayerTests` pins bake keys).
- **Surfaces**: `doz tools NAME [--apply]` (host ops `tools`, `tools-apply`), `GET /api/v1/sandboxes/{n}/tools`,
  the web action `tools-apply`, the New Sandbox wizard's last step "Setting up tools" (`nwToolsNode`: start →
  ✓/✗ → Retry · Continue anyway → Open the sandbox), doctor's "tools layer" line, Resources' `cache:tools`.
  The facts' GitHub line says "(installed by Dozable)" / why gh is not there, and that the ssh client + host
  keys are in place.
- **Tests**: `ToolsLayerTests`, `ToolsHostTests`, `make test-cli-tools` (needs `make tools-fixture` once: the
  real tarball in the vmtest store; a local server serves it — tests never reach github.com), the workspace
  probe `probes/599h-*/run-wizard-probe.sh`; tmux: `make test-cli-tmux38`, `make tmux-verify`.

## Dotfiles — the person's own shell setup in every sandbox

- **One setting, a pin per sandbox** (657): `sandbox.dotfiles` (`SettingType.dotfiles`: an https git URL — no
  credentials, query or fragment — or a folder on the Mac, absolute or `~/…`; `""` = none, the default; NOT in
  `perSandbox`). A sandbox's own: `CreateOptions.dotfiles` (`--dotfiles URL|PATH|none` on create/new/try/up,
  `dotfiles:` in doz_project.yaml — YAML's `no` reads as none). `HostCore.create` resolves it (own, else the setting)
  and records `SandboxConfig.dotfiles` (`DotfilesPin`: normalised source + commit) — the commit the CLI had the person
  trust (`dotfilesCommit`), else the head. A fetch that fails fails the create, naming `--dotfiles none`. The pin is
  the truth afterwards: changing the setting moves no sandbox; `doz dotfiles NAME --update` does (the pin's source,
  else the setting).
- **Fetched on the Mac, never in the guest**: `DotfilesCache` runs `/usr/bin/git` (no prompt, `GIT_ASKPASS=false`; in
  a guarded run never this Mac's git config) into `<store>/dotfiles/<16 hex>/repo.git` — `fetch --depth=1 SOURCE HEAD`
  (a folder through `file://`; a non-git folder refused with what to do), a pinned commit fetched by id or the whole
  history, `refs/doz/<commit>` keeps it. The files enter as `git archive <commit>^{tree}` (a tree: no pax header naming
  the commit — busybox tar reads it) on an exec's STDIN (≤ 64 MiB) — `copyIn` would not work in a VM a new host adopted.
- **Applied per sandbox, as the image's user** (`Sandbox.applyDotfiles`, after the tools layer in `start()` and in
  `.applyGuestFixes`): one cheap check exec (`~/.local/share/doz/dotfiles.commit`); only when it differs from the pin
  (or `--update`: `applyDotfilesNow` on a running one, forced; on one that does not run, the pin's `resolvedAt` is newer
  than the last run recorded in its folder — applied again at its next start or wake, even at the same commit) are the
  files sent, unpacked to `~/.local/share/doz/dotfiles` (staged,
  swapped), OUR links whose file is gone dropped, then the plan: the first of Codespaces' scripts
  (`DotfilesLayer.scriptNames`, `timeout 300`, stdin /dev/null, cwd the files, output to `dotfiles.log`, its last 40 lines
  as `dotfiles │` NOTES — the boot log renders notes as lines, an `.output` is only the boot view's tail), else the link
  pass. The marker is written either way (a failing script is not re-run at every wake; `--update` re-runs). The run is
  `<sandbox>/dotfiles-run.json` (`DotfilesRun`) → `SandboxInfo.dotfiles` (`DotfilesState`: applied | failed | pending).
  Never fatal. Images and bake keys are untouched (`RecipePinTests`).
- **Agent settings run in the same place** (`Sandbox.applyAgentSettings`, `AgentSettings.swift`; the recipe's `launch@1 history`,
  see recipes.md): the host hands the sandbox `AgentSettingsInputs` (script + fingerprint; a preparation VM or helper gets
  none), a marker `~/.local/share/doz/history.applied` holds the fingerprint applied (written either way), and the record is
  `<sandbox>/agent-history-run.json`. Once per mapping and value (the setting `history`, resolved for that sandbox by the
  host before each start or wake), never at a session open.
- **The link pass never overwrites, never touches Dozable's** (`DotfilesLayer.plan`, pure): top-level dot entries only;
  `.git`/`.github`/`.gitignore`… skipped, submodules skipped, odd names skipped; `protectedPaths` (`.claude*`, `.codex`,
  `.pi`, `.config/opencode`, `.agents`, `.local/state/doz`, `.local/share/doz`, the launchers `.local/bin/<claude, codex,
  pi, every recipe's install.binary>`, every recipe's `state.persist` under `~`, and a share under the home) — a folder
  that HOLDS one (`.config`, `.local`, `.local/bin`) is descended into and its entries linked one by one. In the guest an
  existing file is KEPT — except one byte-identical to `/etc/skel/NAME` (Debian's stock `.bashrc`), which is moved to
  `NAME.doz-stock` and replaced (a departure from the brief's "never overwrite", owner to confirm: without it `.bashrc`
  never applies on a Debian base). Every name single-quoted. An install script is NOT policed — trust is the guard.
- **Trust, like 653's community recipes**: `confirmDotfilesTrust` (in `preflightAgentAccount(&o)` and QuickMake) asks
  the host to `dotfiles-resolve` (fetches; the head, its subject, the plan, a dirty folder), says what will run, and asks
  once per source + commit (`DotfilesTrust`, `<settings dir>/dotfiles-trusted.json`, 0600); no terminal: exit 5 naming
  `doz dotfiles trust SOURCE --commit C`. `--update` asks again for a new commit. The dashboard asks nothing: New
  Sandbox's review SHOWS the repository, its commit and what runs (`POST /api/v1/dotfiles/resolve`, a change: `{}` = the
  setting, or `{source}` — https only; a Mac folder is never named by a page), the Settings route refuses a Mac folder.
- **Surfaces**: `doz dotfiles NAME [--update] [--json]`, `doz dotfiles trust [SOURCE] [--commit C]`, `doz ls --json`'s
  `dotfiles`, the sandbox Home's Folder facts, the agent's facts (`dotfiles.facts`, a closed variable; no line without
  dotfiles), the plan (`CreatePlan.dotfiles`, `--dotfiles` in its command and `dotfiles:` in its yaml).
- **Tests**: `DotfilesTests` (the rules, the plan, the parsers — and the apply script run by this Mac's `/bin/sh` on a
  scratch home), `DotfilesHostTests` (a LOCAL scratch repository; never the owner's), `WebDotfilesTests`,
  `ServeExposureTests`; `make test-cli-dotfiles` (local scratch repositories, a scratch git config; prepares
  claude-code).
