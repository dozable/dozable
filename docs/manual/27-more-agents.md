# More agents: Antigravity CLI, Grok Build, OpenCode, GitHub Copilot CLI, Qwen Code, Goose, Kilo Code CLI, Mistral Vibe, Factory Droid, Dirac, Kimi Code, Every Code, Cline CLI, OpenHands CLI, CodeBuddy Code, Gemini CLI

Beside Claude Code, pi and Codex, Dozer runs agents from other makers. Each uses an **API key** of its
maker's; the key stays on your Mac and the sandbox only ever gets a placeholder, which Dozer's proxy swaps for the key
on the way out — and only to that maker's own API.

```sh
doz try antigravity      # Google's agent (alias: agy)
doz try grok             # xAI's agent
doz try opencode         # OpenCode, the open-source agent, on an xAI key
doz try copilot          # GitHub Copilot CLI with your own xAI key (no Copilot plan)
doz try qwen-code        # Qwen Code (alias qwen), on an xAI key
doz try goose            # Goose, on an xAI key
doz try kilo             # Kilo Code CLI (alias kilocode), on an xAI key
doz try mistral-vibe     # Mistral Vibe (alias vibe), on an xAI key
doz try droid            # Factory Droid (alias factory), on an xAI key, no Factory account
doz try dirac            # Dirac, a Cline-derived agent, on an xAI key
doz try kimi-code        # Kimi Code (alias kimi), on an xAI key
doz try every-code       # Every Code, a Codex CLI fork, on an xAI key
doz try cline            # Cline CLI, on an xAI key, no Cline account
doz try openhands        # OpenHands CLI, on an xAI key
doz try codebuddy        # CodeBuddy Code (Tencent), on an xAI key, no CodeBuddy account
doz try gemini           # Google's earlier agent (superseded by Antigravity CLI)
doz search google        # what Dozer runs with a Google key, each with its latest release
```

The first `doz try` of each asks for the key (a paste, or where you keep it: 1Password, AWS, a command — see
[Keys from 1Password, AWS or a command](09-agents-and-accounts.md#keys-from-1password-aws-or-a-command)), prepares the
agent's image once (a minute or so) and starts it. A try is Locked: the agent reaches its model and, below, the few
hosts its maker's program calls when it starts — nothing else. [Trying agents](26-try-and-search.md) has the rest.

## Antigravity CLI (Google)

Google's terminal agent and **the one to use with a Google key** (`doz try antigravity`, or `agy`).

- **Installed** from Google's own release for linux-arm64, checked against the SHA-512 Google publishes with it.
  Debian-based bases only for now (not Alpine). It is closed source; Dozer installs it from Google, it does not
  redistribute it.
- **Key:** a Gemini API key (`doz account add google --provider google`; get one at https://aistudio.google.com/apikey).
  Dozer never offers the Google sign-in: it keeps its token in a keyring inside the machine.
- **Set up for you:** approval prompts off (`antigravity.permissions = ask` keeps them), its updater off, its
  telemetry setting off.
- **May reach:** the Gemini API (its model); Google's feature switches for it (`antigravity-unleash.goog`) when it
  starts; its usage log to `play.googleapis.com`, every few seconds. Its own telemetry setting does not stop that log,
  and Dozer allows it rather than blocking it.

## Grok Build (xAI)

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian, Node and Alpine bases.
- **Key:** an xAI API key (`doz account add xai --provider xai`).
- **Set up for you:** approval prompts off, its auto-updater off, its telemetry and feedback off; copying to your
  Mac's clipboard works (Dozer tells it the terminal takes OSC 52).
- **May reach:** xAI's API (the paths Grok Build uses, and its key-less start-up check of `api.x.ai/`), and its release
  notes on `x.ai` when it starts.
- **Kept out, whatever you choose:** xAI's sign-in hosts (Dozer never offers the sign-in).

## OpenCode (open source)

An open-source terminal agent that works with many model providers (`doz try opencode`). Dozer offers it on an
**xAI API key** for now, with xAI's coding model (`xai/grok-build-0.1`); its other providers come later.

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
- **Key:** an xAI API key, as Grok Build (`doz account add xai --provider xai`). Never its own sign-ins.
- **Set up for you:** its auto-update, session sharing, language-server downloads and the online model list off; the
  model set in `~/.config/opencode/opencode.json` (written only when it is not there yet). Its plugin kit is not
  downloaded into `~/.config/opencode` when it first starts (it is only for plugins you write; `cd ~/.config/opencode
  && npm install @opencode-ai/plugin` adds it). OpenCode asks no approval questions by default.
- **May reach:** xAI's API (the paths OpenCode uses).
- **Use:** `opencode` (its TUI), or `opencode run "…"` for one answer.

## GitHub Copilot CLI (GitHub)

GitHub's terminal agent, run in its own **bring-your-own-key** mode (`doz try copilot`): it talks to your model with
your key and never signs in to GitHub, so no Copilot plan is needed. Dozer offers it on an **xAI API key** for now
(xAI's OpenAI-compatible API, model `grok-code-fast-1`).

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
  It is GitHub's software under its own licence; Dozer installs it from npm, it does not redistribute it.
- **Key:** an xAI API key (`doz account add xai --provider xai`); the sandbox gets a placeholder in `XAI_API_KEY` and
  `COPILOT_PROVIDER_API_KEY`.
- **Set up for you:** approval prompts off (`--allow-all`; `copilot.permissions = ask` keeps them), its offline mode
  (no GitHub sign-in, no calls to GitHub) and its auto-update off.
- **May reach:** xAI's API only.

## Qwen Code (Alibaba Qwen)

Alibaba Qwen's open-source agent, a Gemini CLI fork (`doz try qwen-code`, or `qwen`). Its free Qwen sign-in ended in
April 2026; Dozer runs it in its **OpenAI-compatible mode on an xAI API key** (`OPENAI_BASE_URL` at xAI's API, model
`grok-code-fast-1`).

- **Installed** from the npm registry, integrity-checked; it needs Node 22 (the Node and Debian bases; not Alpine).
- **Key:** an xAI API key; the sandbox gets a placeholder in `XAI_API_KEY` and `OPENAI_API_KEY`.
- **Set up for you:** approval prompts off (`--approval-mode=yolo`; `qwen-code.permissions = ask` keeps them), its
  auto-update and usage statistics off, and its download of the public model catalogue (models.dev) off — it uses the
  catalogue it ships with.
- **May reach:** xAI's API only.

## Goose (Agentic AI Foundation)

The open-source agent from Block, now an Agentic AI Foundation project (`doz try goose`), on an **xAI API key** (its xAI
provider, model `grok-code-fast-1`).

- **Installed** from its GitHub release (the static linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Every base, Alpine included.
- **Key:** an xAI API key, read from `XAI_API_KEY` (a placeholder in the sandbox).
- **Set up for you:** it runs without asking (`GOOSE_MODE=auto`, its default), its keyring off (it would keep secrets in
  the sandbox), its telemetry off.
- **May reach:** xAI's API only.
- **Use:** `goose` (a session), or `goose run -t "…"` for one task.

## Kilo Code CLI (Kilo Code)

Kilo Code's terminal agent, an OpenCode derivative (`doz try kilo`), on an **xAI API key** (model
`xai/grok-build-0.1`).

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine yet).
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox). Kilo's own gateway and sign-in are not offered.
- **Set up for you:** its auto-update, sharing and online model list off; its usage telemetry off
  (`experimental.openTelemetry: false` — Kilo sends it by default); its Kilo Gateway provider off, so it does not call
  Kilo's servers. In its TUI, Kilo asks before running commands (its own default); `kilo run --auto` does not.
- **May reach:** xAI's API only.

## Mistral Vibe (Mistral AI)

Mistral AI's terminal agent (`doz try mistral-vibe`, or `vibe`), on an **xAI API key**: Vibe takes any
OpenAI-compatible provider, and Dozer names xAI's API as one (model `grok-build-0.1`). Mistral's own models need a
Mistral key, which Dozer does not hold yet.

- **Installed** from PyPI with every dependency hash-pinned, into its own Python (Debian base; not Alpine).
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox). Vibe's Mistral key and sign-in
  (`vibe --setup`) are not offered.
- **Set up for you:** its telemetry, update checks and auto-update off (`VIBE_ENABLE_*`); the provider and model are
  set the same way (`VIBE_PROVIDERS`, `VIBE_MODELS`, `VIBE_ACTIVE_MODEL`), not in its settings file.
- **May reach:** xAI's API only.
- **Use:** `vibe` (a session), or `vibe --trust --auto-approve -p "…"` for one task.

## Factory Droid (Factory)

Factory's terminal agent (`doz try droid`) in its **airgap mode**, on an **xAI API key**: no Factory account, and
none of Factory's servers — Droid takes the key as a custom model on xAI's API (`grok-build-0.1`).

- **Installed** from Factory's download server (its linux-arm64 build), checked against the SHA-512 Dozer recorded.
  Debian and Node bases (not Alpine: Factory publishes a glibc build only).
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox). Droid reads it each time it starts
  (`apiKeyHelper: printenv XAI_API_KEY` in `~/.factory/settings.json`), so it is never written into Droid's settings.
- **Set up for you:** airgap mode (`FACTORY_AIRGAP_ENABLED=1`): without it Droid calls Factory's API (sessions, usage,
  feature flags) and its telemetry even with your own model; with it, only the model. Its first start in a folder asks
  whether to trust it.
- **May reach:** xAI's API only.
- **Use:** `droid` (a session; with approvals off, `--auto high`), or `droid exec -m custom:grok-build-0.1 "…"` for one
  task.

## Dirac (dirac-run)

A Cline-derived terminal agent aimed at lower API cost (`doz try dirac`), on an **xAI API key** (Dirac picks its own
xAI model).

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases (not Alpine: Dirac needs
  Node 22.13 to 24).
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox), with xAI set as its provider.
- **Set up for you:** its telemetry off (`telemetrySetting: disabled` — Dirac sends events to dirac.run by default)
  and its self-update off (`DIRAC_NO_AUTO_UPDATE=1`).
- **May reach:** xAI's API only.
- **Use:** `dirac` (a session; with approvals off, `--auto-approve-all`), or `dirac --yolo "…"` for one task.

## Kimi Code (Moonshot AI)

Moonshot AI's terminal agent, the successor to kimi-cli (`doz try kimi-code`, or `kimi`), on an **xAI API key**: Kimi
Code takes any OpenAI-compatible provider in its settings, and Dozer names xAI's API as one (model `grok-build-0.1`).
Kimi's own models need a Kimi account or a Moonshot key, which Dozer does not hold yet.

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases (not Alpine: it needs
  Node 22.19 or later).
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox). Its settings name the variable
  (`api_key_env`), so the key is read on each request and never written into `~/.kimi-code/config.toml`.
- **Set up for you:** its telemetry and self-update off (`KIMI_DISABLE_TELEMETRY`, `KIMI_CODE_NO_AUTO_UPDATE`). At each
  start it asks Moonshot for its public client settings; Dozer keeps that request out quietly, and Kimi Code does
  without them. Its first start in a folder asks whether to trust it.
- **May reach:** xAI's API only.
- **Use:** `kimi` (a session; with approvals off, `--auto`), or `kimi -p "…"` for one task.

## Every Code (just-every)

A Codex CLI fork with multi-agent orchestration (`doz try every-code`; its command is `coder`), on an **xAI API key**
through a Codex-style `model_providers` entry (model `grok-build-0.1`).

- **Installed** from the npm registry's linux-arm64 package (a static build), integrity-checked. Every base, Alpine
  included.
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox), named by `env_key` in `~/.code/config.toml`.
  Its ChatGPT sign-in is not offered.
- **May reach:** xAI's API, and GitHub's API for one read: its latest release, which it asks for when its TUI starts
  (no setting turns it off; Dozer installs the pinned release).
- **Use:** `coder` (a session; with approvals off, `--dangerously-bypass-approvals-and-sandbox`), or
  `coder exec --skip-git-repo-check "…"` for one task.

## Cline CLI (Cline)

Cline's terminal agent (`doz try cline`), on an **xAI API key** — no Cline account (`cline -P xai -m grok-build-0.1`).

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian and Node bases (not Alpine).
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox); Cline reads it each run and saves only the
  provider and model.
- **Set up for you:** its telemetry and self-update off (`telemetryOptOut`, `autoUpdateEnabled: false`,
  `CLINE_NO_AUTO_UPDATE`), and its ClinePass notice. When it starts it asks for feature flags (its PostHog host), its
  recommended models (api.cline.bot) and the models.dev catalogue; Dozer keeps those requests out quietly, and Cline
  does without them. Cline approves its own tool calls by default (its
  `--auto-approve` is on unless you pass `--auto-approve false`).
- **May reach:** xAI's API only.
- **Use:** `cline` (a session), or `cline -P xai -m grok-build-0.1 "…"` for one task.

## OpenHands CLI (OpenHands)

OpenHands' terminal agent (`doz try openhands`), on an **xAI API key**: its LLM settings come from the environment
(`--override-with-envs`, in Dozer's command), with xAI's API as an OpenAI-compatible endpoint (model `grok-build-0.1`).
Nothing is written to its settings.

- **Installed** from its GitHub release (the linux-arm64 build), checked against the SHA-512 Dozer recorded. Debian and
  Node bases (not Alpine: OpenHands publishes a glibc build only).
- **Key:** an xAI API key (`LLM_API_KEY` and `XAI_API_KEY`, the same placeholder in the sandbox). OpenHands Cloud's
  sign-in is not offered.
- **Set up for you:** its model price list read locally (`LITELLM_LOCAL_MODEL_COST_MAP`, not fetched from GitHub) and
  its banner off.
- **May reach:** xAI's API, and two reads no setting turns off: its public skills (a git clone of
  github.com/OpenHands/extensions at each start) and its latest release on PyPI (a notice only; Dozer installs the
  pinned release).
- **Use:** `openhands` (a session; with approvals off, `--always-approve`), or
  `openhands --override-with-envs --headless -t "…"` for one task.

## CodeBuddy Code (Tencent)

Tencent's terminal agent (`doz try codebuddy`), with a **custom model on an xAI API key** (`grok-build-0.1`) and its
built-in models — which need a CodeBuddy account — off.

- **Installed** from the npm registry, integrity-checked. Node 22 on the Node and Debian bases.
- **Key:** an xAI API key (`XAI_API_KEY`, a placeholder in the sandbox). `~/.codebuddy/models.json` names it as
  `${XAI_API_KEY}`, which CodeBuddy reads each run, so the key is never written there.
- **Set up for you:** its telemetry, trace collector, remote settings, plugin marketplace downloads and self-update off.
  Its TUI offers CodeBuddy's sign-in when it starts; Esc skips it, and it answers on your xAI key.
- **May reach:** xAI's API only.
- **Use:** `codebuddy` (a session; with approvals off, `--dangerously-skip-permissions`), or
  `codebuddy --model grok-build -p "…"` for one task.

## Gemini CLI (Google) — superseded

Superseded by Antigravity CLI: Google retired Gemini CLI for personal accounts; it still works with a **paid** Gemini
API key. Dozer keeps it, listed after the current agents; `doz try gemini` says so first.

- **Installed** from the npm registry, integrity-checked. Node, Debian and Alpine (on Alpine its shell tool runs
  without a terminal).
- **Key:** a Gemini API key, as Antigravity CLI. Never the Google sign-in (Google's terms forbid third-party tools from
  using it).
- **Set up for you:** approval prompts off, usage statistics off, auto-update off.

## What each one calls — the network profiles

Dozer keeps a **network profile** of every agent: a fresh try with the network open and every request logged, its
first start and a short task, and for each host and path it called, a decision — allowed (and why), allowed by its
path only, turned off by the agent's own setting, or refused. The recipes are checked against these profiles on every
build, so an agent never meets a refusal on a normal first run, and a new release is profiled again before anything
new is allowed (`make profile-agents` in the source tree; `make agent-currency` says which agents moved).

## Is it current?

`doz search`, `doz try` and the Quick try show each agent's **latest release** as your Mac last saw it — the version,
the day it came out, how long ago, and **active** (a release in the last 3 months), **quiet** (none for 3),
**stale** (none for 6) or **deprecated** by its maker — and its **standing**: current, or superseded by another
agent. See [Is it current?](26-try-and-search.md#is-it-supported-doz-search).
