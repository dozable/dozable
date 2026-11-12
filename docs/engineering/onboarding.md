# Onboarding and projects

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/Preparations.swift`, `Onboarding.swift`, `AgentPrompt.swift`; `Sources/DozableCLI/OnboardCommands.swift`, `ProjectFile.swift`, `Prompting.swift`, `UninstallCommand.swift`; `Sources/doz-vmtest/OnboardingSuite.swift`, `PullBench.swift` | image preparation in the host (single-flight, joined, cancelled) + `onboarded.json`; onboarding's checks / account step / settings-only-when-missing; the agent's environment prompt + the `doz` skill; `doz onboard`/`init`/`uninstall`, `doz_project.yaml` (Yams), TTY questions; `make test-cli`'s onboarding part (`make test-cli-onboarding`); `make pullbench` (D12) |

## Onboarding, projects, the agent's environment prompt

- **Image preparation is the HOST's** (`Preparations.swift`): kernel + guest init (`Sandbox.prepareAssets`)
  + base pull + bake (the lab: its prepared disk). ONE per image name at a time (`HostCore.preparations`);
  `onboard`, `prepare`, `image bake`, the UI and a cold `start` needing the image all JOIN the running one
  (`follow` subscribes; the bounded event buffer is replayed to a joiner). A client going away never
  cancels it; `prepare-cancel` does (checked between bake steps; the VM is stopped in a task of its own
  so cancellation cannot skip the clean stop). A running preparation keeps the host up (`idleLoop`);
  quitting the host cancels it. "Prepared" means THIS build's bake key (`HostCore.isPrepared`,
  `ImageRow.current`) — a re-run prepares nothing. Tests substitute the work: `setPreparationRunner`.
  **Its progress as data** (`PreparationInfo`): `stepIndex`/`plannedSteps` (N of M — M from the last
  run's step count, else `HostCore.plannedSteps(image)`), `steps` (finished: step · failed with its last
  output · transfer), the 593 `ProgressBoard` tail (6 lines), and estimates ONLY from
  `<store>/preparations.json` (`PreparationRecord`, saved on success; steps keyed so a digest or a
  size in the label does not break the match). The UI's `prepCard` renders it; the probe
  `probes/594-*/progress.mjs` pins it. A bake step's output is the tail, so keep steps' output visible
  (the dev baseline's apt is not silenced).
- **`<store>/onboarded.json`, never `state.json`** — that name at the store's root is Containerization's
  image-store index. The HOST writes the record once every chosen image is ready, so a detached CLI
  (Ctrl-C = detach, exit 130) or a closed wizard still completes the onboarding. 634: `doz onboard` prepares the
  store's ONE base (`HostRequest.base` → the preparation `base:<id>`, recorded as `OnboardingRecord.base`), started at
  its Base image step with `follow: false` while the questions go on, followed at the end; its First sandbox is the
  planner's `first` purpose (a try's defaults, named after the tool, its command `doz new NAME --agent TOOL …`) made by
  `QuickMake` — the ONE path `doz try` takes too.
- **Settings and the prompt template are written ONLY when missing** (`Onboarding.write…IfMissing`) — an
  existing file is never touched, by the CLI or the UI's `POST /api/v1/onboarding/config` (634: strictly `{base?,
  access?, ignoreMode?}` — the base written into a kept file too, `Onboarding.writeBase`).
- **The setup wizard v2** (634; the owner's chosen mockup onboarding-v2; `views/onboarding.js`, `core/wizards.js`):
  `WIZ` = welcome, base, keys, access, rules, usage, signup, first; each step returns `{title, lead, body, foot}`, drawn as
  a centred `.w2-head` over a `.w2-col` of `WIZ_SIZE` (narrow 480 · medium 680 · wide 1080). Base image's "Download and
  continue" sends `onboard {base}` and moves on; from then on `components/base-strip.js` draws the base at the foot
  (`[data-base-slot]`, above `.w-foot`) — a poll or a `preparations` event repaints ONLY the strip and the First sandbox's
  image line (`renderWizard()` unforced), never a step, so nothing typed is redrawn; its bar never goes back (per
  preparation); Details is a popover (its own capture-phase Esc runs before the modal's). Models & keys: the sign-ins
  (`WebOnboarding.macSignedIn`/`codexMac`), the keys by Providers / Gateways / No key (`model-source.js` `haveList`,
  `WebOnboarding.keyChoices`, pasted through `POST /api/v1/accounts`), and what can be tried (`GET try`, read again after a
  key). Workspace rules' Next writes the settings. First sandbox plans with the planner's `first` purpose (`POST plan
  {purpose:'first', agent, name?, workspace?, account?|source?}` — `readiness()` picks a usable key, else a key-less
  source) and makes it through `views/quick-make.js` `startQuickMade` (the Quick try's own path; `back: 'onboarding'`
  returns to the wizard on a failed create); the switch saves `sandbox.open_files` only when changed. Workspace probe
  `probes/594-*/run-wizard-probe.sh` (allow · deny · basefail — `DOZ_TEST_BASE_FAIL`, guarded runs only).
- **The account step never logs in and never reads a refresh token for use.** Options: `mac`, `api-key`,
  `setup-token`, `later` ("Decide later": one option for none/skip). A key or a token goes
  ONLY through `HostRequest.accountAdd` — the request `doz account add` sends (the login keychain, the one
  check request, `--plan`) — from `doz onboard`'s no-echo prompt (off a TTY only with `--secret-stdin`) or
  the web UI's masked field. `doz onboard --key …` skips the Claude Code checks entirely (634: `--key` takes any published provider or gateway — OpenRouter too — and `setup-token`); `doz ui`
  under `DOZ_TEST_NO_MAC_LOGIN=1` (a test seam, the probes') never looks at the Mac's login.
- **Secret entry in the browser**: `ui.allow_secret_entry` (default on; the UI can turn
  it off, never on — a reset would turn it on, so that is refused too). On: `POST /api/v1/accounts` — a
  typed route, deliberately NOT a `WebAction` (an action is an operation: a title, progress, SSE); strict
  body `{name, kind, secret, plan?}`; the page empties the masked field before the request; refusals never
  echo; a failure's message is scrubbed (`WebAccountAdd.scrub`); `WebAccountAdd`'s description is redacted.
  Off: 403 `secret-entry-off` and the page shows the command. `account-add` stays OUT of the action set.
  A sandbox's own key: `POST /api/v1/sandboxes/NAME/key`, strict `{secret}` (the binding — anthropic —
  and the sandbox are not the body's), `HostRequest.keySet` (source `browser`) — `doz key set`'s own
  request; `WebKeySet` redacted, errors scrubbed (`WebSecretText`); `key-set` stays OUT of the action set.
- **Unattended tests never touch the login keychain**: a real host under `DOZ_TEST_CREDENTIALS=memory`
  keeps accounts' secrets in its memory and verifies nothing (`CredentialServices.forHost`, said in
  host.log). `make test-cli`'s onboarding part and the wizard probe use it.
- **The environment prompt** (`AgentPrompt.swift`) is rendered from the sandbox's CURRENT facts at every
  `open-session` of a claude-code/pi sandbox and written by a root utility exec (contents base64 in the
  script): `/run/doz/agent-prompt.md` and ONLY the skill dir `~/.claude/skills/doz` (pi:
  `~/.pi/agent/skills/doz`) — never CLAUDE.md/AGENTS.md. Claude Code gets it through its launcher
  (`--append-system-prompt "$(cat …)"`, not for subcommands nor when the caller gives a system prompt —
  a bake-key change). 678 (#386): the baked launcher skipped the facts when the caller gave ANY
  `--append-system-prompt` (Claude Code keeps only the last, so a person's flag lost them). The host now
  refreshes the launcher at every agent session start (`AgentImages.launcherRefreshScript`, in the same root
  exec, before the program starts — so `doz run x -- claude --append-system-prompt …` is right on its first
  session): it COMBINES every `--append-system-prompt` / `=` / `-file` value with the facts into ONE flag, adds
  nothing to a value that already holds the facts' first line (a caller passing `$(cat /run/doz/agent-prompt.md)`),
  and leaves `--system-prompt` and the subcommands alone. It replaces `~agent/.local/bin/claude` only when its
  second line is the doz marker and its third (`# doz-launcher: <hash>`) is not this build's; staged root-owned
  in `/usr/local/lib/doz`, renamed over it, never through a link. The baked `launcherScript` is untouched (the
  bake key — `test_nodeImagesAreByteIdentical`); folding the change into the bake waits for the next deliberate
  image change (owner). `LauncherScriptTests` runs it under /bin/sh with a stub claude; pi's own session gets `--append-system-prompt FILE` (pi reads an existing path).
  Variables are a CLOSED list; an unknown one refuses the session with its name and file. `agent.prompt
  = false` removes both at the next session.
- **`doz_project.yaml`** is parsed by hand on Yams's node tree with the parser kept alive (anchors are
  weak): a closed key set, errors with the line, anchors/aliases refused top-down (no alias expansion
  is ever walked), one document, 64 KiB. Yams only in `Sources/DozableCLI` (audit).
- **The New Sandbox wizard and `doz init` share ONE model** — `DozableHost/Project.swift`: `DozableProject`
  (every key, `render`, `createOptions`, `problem(effectiveNetwork:)` the whole-project check, `dropDefaults`
  — a pre-filled value equal to the setting's is left commented unless `explicit`, `lineDiff`, `find(in:)`
  which reads `doz_project.yml` too and throws when BOTH exist) and `ProjectWizard.steps` (the 10 steps both
  walk). READING stays in the CLI (`ProjectFile.swift`, `extension DozableProject { parse/load }`); `doz ui`
  installs that parser into `WebProjectFiles` so the dashboard never imports Yams. The dashboard
  (`WebProject.swift`): `POST /api/v1/project/open|preview|write` (CSRF, strict bodies) and the action
  `project-create {folder}` → `.create` with `DozableProject.createOptions` (exactly `doz up`'s). The review is
  `render()` READ BACK by the parser; a write replaces an existing file only when `replace` = SHA-256 of what
  is there (the page showed the diff and the person confirmed), else 409. Key `permissions`: the
  `defaults.permissions` words, given to the host as `allow = ["standard"] + words` (a preset alone as is);
  `permissions`/`github` with a network of bake/nat/none is refused. `agent_prompt` renders `|-` when it has
  no final newline (exact round-trip). The page: `#/new` (`viewNew`, `nw*` in `views/new-sandbox.js`; never re-rendered
  by a live refresh); only `explicit` keys are sent. Its Access step IS 599e's `renderAccessStep` (mode
  'sandbox', state `nw.access`, pre-filled from the file else `defaults.github`/`sandbox.ssh_agent`; Next
  confirms, Back does not) — the choices become the file's `github`/`ssh_agent`; `doz init` uses 599e's
  `AccessStep` (`subject` "this sandbox", no source question — the token source is the Mac's). A file with
  `permissions` but no `github` keeps `defaults.github` (`createOptions(…settings:)`). `make test-cli-projectwizard` drives an interactive
  `doz init` through `script(1)` (the Asker needs a controlling terminal).
- **`doz uninstall`** removes a store only if it looks like one, the settings dir only if named
  `doz`, and the installed doz only when THIS executable is `<prefix>/libexec/doz/doz` (the
  `bin/doz` link only if it resolves to it). Never the keychain; a running `doz ui` refuses it.
- **`doz nuke` / `doz inventory`** (`NukeCommand.swift`, `Nuke.plan` — pure, `NukeTests`): back to a fresh install with
  doz kept — uninstall's store and settings rules, plus `~/Library/Caches/doz` and the keychain items Dozable
  made (`AccountStore.isDozItem`, `doz-github`; never another `doz-*` item, never Claude Code's). Each item with its
  place and allocated size; asks once (`--yes`, `--dry-run`); a running `doz ui` (or an earlier `doz serve`) refuses it.
  `inventory` prints the same list and changes nothing. **A guarded test run never sees this Mac's keychain or cache**:
  an in-memory keychain, and the cache only from `DOZ_TEST_CACHE_DIR` (else none).
- **Tests on throwaway paths only**: `make test-cli`'s onboarding part uses `/tmp/dzo-<pid>-*` stores (a
  socket path under 104 bytes) seeded from the vmtest store, each with its own XDG_CONFIG_HOME; the
  wizard probe (`probes/594-*/run-wizard-probe.sh`) a fresh `/tmp/dzw-*` store.
