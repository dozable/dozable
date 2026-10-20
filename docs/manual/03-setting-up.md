# Setting up this Mac

Setup — **onboarding** — is what you do once after installing: it checks your Mac, prepares the **base image**
every tool is added to, adds the **keys** your tools use, chooses and confirms what sandboxes may use as you
(**Access**: GitHub, your SSH agent), explains **workspace rules** and lets you choose what they do, writes your
settings, and makes your **first sandbox**. You can do it in the terminal (`doz onboard`) or in the browser (the
dashboard's setup wizard). Both are safe to run again.

## Concepts

- **The base image** is the Linux system every tool runs on: Node.js on Debian by default (`doz base ls` lists
  the others). It is downloaded and prepared **once**; each tool you try — Claude Code, pi, OpenCode … — is added
  to it as a layer, so a second tool downloads only itself. The store's base is the setting `defaults.base`. See
  [Images and bases](08-images-and-bases.md).
- **Preparation runs in the host**, not in your terminal. Setup starts the base's download at the Base image step
  and goes on asking; you can close the terminal or leave the wizard and it carries on. A tool prepared while the
  base is still being prepared waits for it instead of downloading it a second time.
- **An account** is how a tool pays for its AI model: your Mac's Claude Code or Codex login, a long-lived token, or
  a key of a provider (Anthropic, OpenAI, xAI, Google) or a gateway (OpenRouter). The secret stays on your Mac; a
  sandbox only ever sees a stand-in. See [Agents and accounts](09-agents-and-accounts.md).
- **Access** is every other credential a sandbox may use as you — **GitHub as you**
  ([GitHub](18-github.md)) and **SSH agent forwarding**. Each is a choice of yours (both are off until you choose
  them), and each is **confirmed live** when you choose it. A credential that can't be confirmed can be
  **skipped**: the choice is kept, marked *not confirmed*, and setup goes on. The choices are the defaults for new
  sandboxes; `doz access` and **Settings** › **Access** check them again later.
- **Workspace rules** are two small files you can put in a project folder: `.dozignore` (paths the agent
  must not use) and `.dozreadonly` (paths it may read but not change). Setup explains them and asks one
  question: should a `.dozignore` **lock** the paths it lists (still listed, but nothing can open them —
  the default) or **hide** them (not there at all)? See [Workspace rules](20-workspace-rules.md).

## In the terminal

```sh
doz onboard
```

On a terminal it asks; **Enter** always accepts the recommended answer. While the base downloads, a line between
two steps says how far it is — never under a question.

1. **Checks** — the same checks as `doz doctor`. The required ones stop setup when they fail: Apple
   silicon, macOS 26 or later, virtualization, the signed program, the store on an APFS disk with room
   for the base (about 2 GB with a first sandbox), and a store path short enough. The rest only warn: Claude
   Code missing or signed out (you can add a key instead), and the NAT network helper (only `--network nat`
   needs it).
2. **Base image** — `Use Node.js (node:22-bookworm, ↓ 381 MiB)? [Y/n/other]`. **Enter** starts its download and
   preparation in the host at once, and the next questions follow straight away; **other** lists the other bases;
   **n** prepares none now (each tool's first start prepares its own).
3. **Models & keys** — the sign-ins found on this Mac (Claude Code, Codex), then `Add a key?
   [anthropic/openai/xai/google/openrouter/No]`, each with the tools it serves, asked again until **no**. A key
   is pasted at a hidden prompt and added exactly as `doz account add` adds it: checked with one tiny request
   and stored in your login keychain. An OpenRouter key works for every tool that can use OpenRouter (pi,
   OpenCode). **setup-token** adds a Claude subscription's token (from `claude setup-token`); **chatgpt** signs
   Codex in with ChatGPT (official builds). An Anthropic key becomes the store's default only when Claude Code
   is not signed in on this Mac — it never quietly replaces your subscription.
4. **Access** — what sandboxes may use as you, each offered and never done behind your back:
   - **GitHub as you**: *Off* (the default), *Read-only* or *Read and push* — and where the token
     comes from: this Mac's `gh` login, or a token you paste (best: a fine-grained one).
   - **SSH agent forwarding**: *Off* (the default) or *On*.

   Each choice has a one-line consequence beside it. Then each is **confirmed**:

   ```
   ✓ Claude account        mac              confirmed — this Mac's Claude Code login (you@example.com), max
   ✓ GitHub as you         read (gh login)  confirmed — signed in as you — scopes: repo, read:org (from this Mac's gh login)
   ✗ SSH agent forwarding  on               not confirmed — this Mac has no ssh-agent to forward
   ```

   A failure says why, and offers **Skip** (keep the choice, not confirmed — `doz access` checks
   again later), **Turn it off**, or **Check again**. Setup is never blocked by it.
5. **Workspace rules** — what `.dozignore` and `.dozreadonly` do, in a few lines: the benefit (keep an
   agent out of your secrets, or stop it changing some files, without moving anything), and the
   consequences — **lock** keeps a path listed but unreadable, so the agent knows it exists; **hide**
   removes it altogether; only a folder with one of the files changes, and nothing costs anything without
   them; the first look through many files is a little slower when rules exist; and it is **not a security
   boundary** (root in the sandbox can get round it). Then: *Lock* (recommended) or *Hide* — the default
   for every sandbox (the setting `workspace.ignore_mode`; a sandbox can choose its own).
6. **Settings** — `doz.toml` (every setting at its default, plus your answers) and `agent-prompt.md`
   beside it, each written **only if it doesn't exist yet**. Your base (when it is not Node.js), Access and
   Workspace rules answers are then set in it — only the ones you chose.

Then, in an official build, two questions:

- **Usage statistics** — what is sent (counts and ranges about how Dozable is used, never names, paths,
  contents or anything inside a sandbox), `doz telemetry show` to see it exactly, and the privacy
  policy; then *Send anonymous usage statistics? [Y/n]*. **Enter** keeps them on and changes nothing;
  **n** sets `telemetry.send_anonymous_usage_stats = false`. When `DO_NOT_TRACK` or
  `$DOZ_SEND_ANONYMOUS_USAGE_STATS` already decides, it says so and does not ask. A build from the
  open-source repository sends nothing and skips the step.
- **Stay in touch** (optional) — release news, tool news, early access and tips and tricks by email; **Enter**
  skips it.

And last:

- **First sandbox** — `Make your first sandbox? [claude/pi/opencode/no]` (Codex too, once it has a sign-in or a
  key). Then `Name [claude]:` and `Folder [~/doz-workspaces/claude]:` — **Enter** keeps a new empty folder of its
  own; type a path to use a project folder of yours. It is made the quick way, like `doz try`: the tool on the
  store's base, **Locked** (it reaches only its own model), and files it opens from its folder open on this Mac
  (`sandbox.open_files`). Setup says the same in one command — `Same in Terminal: doz new claude --agent
  claude-code --network locked` — then waits for the base (its progress shown; **Ctrl-C** leaves it running),
  starts the sandbox and attaches you to the tool. When you leave it: `Leaving claude — [S]leep / [d]elete / [k]eep
  running`; **d** removes it, and its folder while that is still empty.

Without a first sandbox, setup waits for the base at the end. Press **Ctrl-C** to leave it running in the
background. Then:

```sh
doz onboard --status      # show the base and follow a preparation that is running
doz onboard --cancel      # stop the base being prepared
```

When the base is ready, the store is marked as set up — even if you'd detached.

### Without questions (scripts)

```sh
doz onboard --yes                                     # the Node.js base, no key, no sandbox
doz onboard --base python --yes
doz onboard --no-base --yes                           # prepare nothing now
doz onboard --key openrouter --key-name or-work --secret-stdin --yes < key.txt
doz onboard --key setup-token --key-name work --plan max --secret-stdin --yes < token.txt
doz onboard --first claude                            # the first sandbox without asking for it
doz onboard --github read --ssh-agent on --yes
doz onboard --ignore-mode hide --yes
doz onboard --github push --github-key-stdin --yes < github-token.txt
```

`--yes`, `--json`, or no terminal: nothing is asked and the defaults are taken — the Node.js base, no key, no
sandbox. A key or token is read from standard input only with `--secret-stdin` (`--github-key-stdin` for a GitHub
token); it is never a command-line argument. Each credential chosen is still confirmed; one that can't be is
**skipped with a note** and the exit code stays 0. Without `--github` / `--ssh-agent` / `--ignore-mode` /
`--usage-stats`, `--yes` leaves those settings exactly as they are.

| option | what it does |
|---|---|
| `--base ID` | The base image without asking: `node` (the default), `python`, `go` … (`doz base ls`). Sets `defaults.base`. |
| `--no-base` | Prepare no base now (each tool's first start prepares its own). |
| `--key PROVIDER` | Add a key without asking: `anthropic`, `openai`, `xai`, `google`, `openrouter`, or `setup-token` (the Claude Code checks are then skipped). |
| `--key-name NAME` · `--plan PLAN` · `--force` | For the key: its name (default: the provider's name), a setup token's plan (`max`, `pro`, `team`, `enterprise`), replace an existing account. |
| `--first AGENT\|none` | The first sandbox without asking: `claude`, `pi`, `opencode`, `codex` (any tool `doz try` takes), or `none`. |
| `--openai-account mac\|chatgpt\|openai-key\|later` | Codex's account without asking. |
| `--github off\|read\|push` | Answer "GitHub as you" (the setting `defaults.github`). |
| `--github-source gh\|key` · `--github-key-stdin` | Where the GitHub token comes from: this Mac's `gh` login, or a token read from standard input (kept in the login keychain as `doz-github`). |
| `--ssh-agent on\|off` | Answer "SSH agent forwarding" (the setting `sandbox.ssh_agent`). |
| `--ignore-mode lock\|hide` | Answer the Workspace rules step (the setting `workspace.ignore_mode`). |
| `--usage-stats on\|off` | Answer the Usage statistics step (official builds; the setting `telemetry.send_anonymous_usage_stats`, written only when it changes). |
| `--status` · `--cancel` | Follow · stop the preparation. |

## In the dashboard

```sh
doz ui
```

A store that was never set up opens on the **setup wizard**, in a window over the dashboard (its steps
across the top; **✕** or **Escape** closes it, asking first once you have chosen something). Each step's title is
centred over a column of the step's own width — narrow for a switch or a form, wide for two columns:

1. **Welcome** — what Dozable is, and **This Mac**: the doctor's checks, inline. A failing required check stops here,
   with what to fix and **Check again**; the others only say what will not work yet.
2. **Base image** — one card, **Node.js** (recommended), how each tool is added to it as a layer, and
   **Another base** folded (Python, Go, Rust, …). **Download and continue** starts its download and preparation in the
   host and moves on at once.
3. **Models & keys** — two columns. On the left the sign-ins found on this Mac (Claude Code, Codex) and **Tools you can
   use now**; on the right the keys by **Providers** (Anthropic, OpenAI, xAI, Google), **Gateways** (OpenRouter) and
   **No key** (OpenCode Zen's free models), each row naming the tools it serves. **Add a key** opens a masked field
   under its row; the key is checked once and kept in the login keychain, and the tools it serves turn ready.
   **Decide later** moves on.
4. **GitHub & SSH** — **GitHub as you** (off, read-only, read and push — from this Mac's `gh` login or a token in a
   masked field) and **SSH agent forwarding**, each with its consequence. **Next** confirms each one: *confirmed* with
   what was found, or *not confirmed* with the reason and **Skip** · **Turn it off** · **Check again**.
5. **Workspace rules** — the same description as in the terminal, and the same choice: **Lock** (recommended) or
   **Hide**. Its **Next** writes the settings (the base too, when it is not Node.js).
6. **Usage statistics** (official builds) — the same text as in the terminal and one switch, **Send anonymous usage
   statistics**, on. **Next** saves it only if you changed it.
7. **Stay in touch** (optional, official builds) — an email and what you'd like; **Skip** moves on.
8. **First sandbox** — the tools' cards (one you cannot use yet is dimmed, with what it needs) and its plan: a
   **Name** (the tool's: `claude`), its folder — **a new empty folder** (`~/doz-workspaces/claude`, the default) or
   **a project folder on this Mac** (typed, or **Choose…**) — then Model, Network (Locked), Image, what Delete does,
   and **Same in Terminal** (`doz new claude --agent claude-code --network locked`). **Open what it makes on this Mac**
   is on (the setting `sandbox.open_files`). **Create and start claude** makes it and opens its page; **Finish
   without a sandbox** goes to Sandboxes. **What setup wrote** (folded) says what went where.

From the step after Base image, the base's progress is a strip at the foot, just above the buttons: downloading (a
bar, the bytes, the time left) → preparing (step N of 4) → ready (green). **Details** opens a popover over the step —
the steps with their times, the last lines of output, **Operations** and **Cancel…**; **✕**, **Escape** or a click
outside closes it. If the download stops, the strip turns red with **Retry**, and the questions go on. Reach First
sandbox before the base is ready and its Image line says it *waits for the base*: Create and start does not wait —
the sandbox's page opens, and its build's first step is the wait.

![The wizard's checks](images/wizard-checks.png)

You can run the wizard again at any time: **Onboarding** under **Setup** in the sidebar (with a dot beside it until
the store is set up), or **Doctor** › **Run onboarding again**.

## Checking access again

```sh
doz access                       # each credential, confirmed now
doz access --no-check            # the last confirmation only
doz access set --github push     # change a choice (and confirm it)
doz access set --ssh-agent off
```

In the dashboard: **Settings** › **Access** shows each credential as last confirmed, with **Check
again**; the choices themselves are the settings `defaults.github`, `github.credentials` and
`sandbox.ssh_agent` further down the page.

## What was written where

| what | where |
|---|---|
| Your settings | `~/.config/doz/doz.toml` (under `$XDG_CONFIG_HOME` if set) — see [Settings reference](15-settings-reference.md) |
| Your agent prompt template | `agent-prompt.md` beside it — everything inside an HTML comment, so it changes nothing until you write your own text. See [Agents and accounts](09-agents-and-accounts.md#the-agents-environment-facts) |
| The store (images, sandboxes) | `~/Library/Application Support/doz` |
| Accounts with a secret | your login keychain, `doz-claude:NAME` (tokens) or `doz-anthropic:NAME` (API keys) |
| A GitHub token you gave | your login keychain, `doz-github` |
| The last access check | `access.json` in the store — states and reasons, never a secret |

## Settings

| key | default | what it does |
|---|---|---|
| `defaults.image` | `lab` | The image `doz up NAME`, `doz init` and the dashboard's New sandbox use when you don't name one. Onboarding sets it to `claude-code`. |
| `defaults.base` | `node` | The store's base: the base a quick-made sandbox's tool is added to (Quick try, `doz try`, the first sandbox). The Base image step's choice. |
| `defaults.projects_dir` | `~/doz-workspaces` | Your projects folder: Quick add, `doz new` and New sandbox make each new sandbox's folder in it. `doz onboard` says where it is; the dashboard's **Settings** › **Choose…** or `doz config set defaults.projects_dir DIR` moves it. |
| `defaults.account` | `mac` | The account of a store that hasn't chosen one. `doz account default` decides for a store once it has. |
| `defaults.github` | `off` | "GitHub as you" for new sandboxes: `off`, `read` or `push`. The Access step's choice. |
| `github.credentials` | `gh` | Where the GitHub token comes from: `gh` (this Mac's login), `key` (a token you gave), `off`. |
| `sandbox.ssh_agent` | `off` | Forward this Mac's ssh-agent into sandboxes (github.com only). |
| `workspace.ignore_mode` | `lock` | What a `.dozignore` does to the paths it lists: `lock` or `hide`. The Workspace rules step's choice. |
| `ui.allow_secret_entry` | `true` | The dashboard may take an API key or setup token in a masked field. `false`: it shows the `doz account add` command instead. The dashboard can turn this off, never on. |
| `images.claude_code_version` · `images.pi_version` | `latest` | Which agent version an image is prepared with. See [Agents and accounts](09-agents-and-accounts.md#agent-versions). |

## Limits and notes

- Setup never signs you in to Claude Code, and never touches Claude Code's own refresh token.
- Re-running `doz onboard` is safe: it re-checks, leaves existing settings files alone and prepares
  only what is missing.
- The first preparation needs the internet: it downloads the base (about 380 MB for Node.js; `doz base ls` lists
  each base's download), then each tool the first time it is used.

## Troubleshooting

| symptom | what to do |
|---|---|
| A required check fails | Read its message; `doz doctor` shows every check with what to do. |
| Preparation fails part way | `doz onboard --status` shows the failed step. Run `doz onboard` again: it continues with what's missing (a download resumes). |
| "latest" can't be resolved (offline) | Set an exact agent version: `doz config set images.claude_code_version 2.1.227`. |
| The wizard shows commands instead of a key field | `ui.allow_secret_entry` is off: use `doz account add NAME --api-key` in a terminal. |
| GitHub *not confirmed: gh is not logged in* | Run `gh auth login` on the Mac, then `doz access` — or give a token: `doz access set --github-key`. |
| SSH *not confirmed: no ssh-agent* or *no keys* | Start an agent and `ssh-add` your key on the Mac, then `doz access`. Or turn it off: `doz access set --ssh-agent off`. |
| You want to start over | [Uninstall](02-install-upgrade-uninstall.md#uninstall), then install and onboard again. |
