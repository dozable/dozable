# The Dozable manual

> Dozable runs teams of AI coding agents on your Mac. A workspace holds the agents, their chat room, the folders they
> work in and a brief. Agents from any vendor (Claude Code, Codex, OpenCode and more) take on the work one unit of work at
> a time; each is recorded in a journal, and the lessons you approve carry into the next. You watch, talk to them and
> decide what matters. Each agent runs where you choose: in its own micro VM or held to its folder on your Mac, where
> your keys never go inside, or as you.

You drive it with the `doz` command or its dashboard in your browser (`doz ui`). Every page here shows both. New to
Dozable? Start with [Getting started](01-getting-started.md), then [Workspaces](37-workspaces.md).

## If you are an agent

**If you are an agent driving Dozable for a person:** run `doz --version` and read the manual of that version
(`doz docs` prints where it is; pages change between releases). Read [Workspaces](37-workspaces.md) first, for the model: a
workspace, its brief, its room, its units of work and their journal. Then [Letting another agent drive
Dozable](14-letting-another-agent-drive.md), for `--json`, the exit codes, `--yes` and what to ask the person before you
act; then [Chat](36-chat.md). Before you start: workers and a manager need chat on (`doz chat on`), and turning it on is
the person's call; `doz exec` stops a command after 120 s unless you pass `--timeout` (use `doz run -d` for a long job);
inside a sandbox a refused HTTPS site answers 403 with "refused by Dozable's network policy" to a program that uses the
proxy (curl, npm, pip, git), while one that ignores it (Node's own `https`, for one) still sees a name that does not
resolve — either way `doz net NAME` names what was refused and the command that allows it. `doz skill show doz` prints the skill for this version; `doz docs PAGE` reads a page with no network.

**If you are an agent working inside a workspace:** you have no `doz`. You reach Dozable through `dozchat`, with your
own token: your room, Asks, the journal of the unit of work, and proposing a lesson. Run `dozchat --help`, then read
[Runs, the journal and lessons](41-runs-the-journal-and-lessons.md).

## Contents

Every page, one line each: what it covers, so you can tell whether to read it. The same lines make `llms.txt`.

### Start here

- [Getting started](01-getting-started.md): what Dozable is, the three things that catch a newcomer (the account, chat, long commands), then install, set up this Mac and make a first workspace with an agent in it — about 15 minutes, most of it a one-off download.
- [Installing, upgrading and uninstalling](02-install-upgrade-uninstall.md): Homebrew or the release tarball, the stable, beta and canary channels, `doz upgrade`, and removing everything.
- [Setting up this Mac](03-setting-up.md): `doz onboard` — what it checks, the base image, the account your agents use (by default this Mac's own Claude Code login, which expires), what agents may use as you (GitHub, your SSH agent) and the settings it writes.
- [Letting another agent drive Dozable](14-letting-another-agent-drive.md): for an agent (Claude Code, Codex, Cursor) running doz for a person — a workspace first, then `--json`, the exit codes, `--yes`, the skill, this version's manual and what to ask the person before acting.
- [Prompts for your agent](22-prompts-for-your-agent.md): ready-made prompts to give your Mac's own agent so it installs Dozable, sets it up and runs work for you.

### Workspaces, rooms and agents

- [Workspaces](37-workspaces.md): where the work happens — its agents, rooms, brief and folders, made from a preset (`doz workspace new --preset …`; a table says what each sets up and what it does not); its lifecycle (new, start, stop, sleep, finish, archive, delete); adopting a sandbox or session you made; `reopen` opens a unit of work.
- [Chat](36-chat.md): rooms on your Mac where you and your agents talk; workers and managers need it (`doz chat on`); each store has its own ports and tokens; Asks; an agent on another machine needs this Mac's address, the port and its own token, and its replies go back to the server the message came from.
- [Agents / Bots](38-agents-and-bots.md): an agent's lasting identity — its name, agent program (Claude Code, Codex, …), model, account, where it runs and its token — made once and used as a workspace's manager or worker.
- [Agents and accounts](09-agents-and-accounts.md): Claude Code, Codex and pi and the account each uses, the secret never inside; this Mac's Claude login expires — `doz account keepalive` renews it, but not for a daemon started over SSH — and a setup-token account suits long unattended work.
- [Space files](39-space-files.md): a whole workspace as one YAML file (NAME.space.yaml) kept in git beside the work — `doz space plan -f FILE` shows what it would do, `doz space up -f FILE` sets it up, `doz space down` takes it down; plain `doz up` is a project's command and reads no space file.
- [History and retention](40-history-and-retention.md): `doz timeline` — what happened on this Mac, as one timeline (actions, sessions, network, key use, workspace and permission logs, units of work, Asks), how long it is kept, and that none of it leaves the Mac.
- [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md): a run is one unit of work — `doz workspace run` opens it, `finish` closes and archives it; its journal of typed entries (each kind's `--data`, evidence, follow, wait); retro, proposals and deciding; lessons that always carry into the next; what agents write with `dozchat`; times in UTC.
- [Bring your own process: a worked example](42-bring-your-own-process.md): draft, render a still, review, revise — three units of work with two agents, one room and an Ask, every command and journal kind exact — and how to map a workflow you already have (pull requests, tickets, reviews) onto a workspace and its room.
- [Tokens and identity](43-tokens-and-identity.md): who makes each chat token, where it is kept, rotating and revoking it, how an adopted agent gets its own, and what a machine on your tailnet without a token can and cannot do.
- Running work in an agent: [Terminals and sessions](07-terminals-and-sessions.md) (`doz exec`, its 120 s limit, `doz run -d`) and [the network](10-permissions-and-network.md) (`doz net NAME` when something is refused) are the two pages you use every day.

### Where agents run

- [Sandboxes and their lifecycle](05-sandboxes-and-lifecycle.md): the micro VM choice — a Linux virtual machine with its own disk; running, paused, asleep, hibernated and off; the daemon that runs them.
- [Sessions on this Mac](34-sessions-on-this-mac.md): the on-your-Mac choice — fenced (held by macOS's own sandbox to its project folder, no Keychain, the network only through Dozable's proxy, this Mac's ports only when given, the chat server's among them) or unfenced (no isolation: it acts as you); its first section compares the three places an agent runs (micro VM, fenced, as you: what each reaches, memory, start time, when to pick it); page 16 says exactly what the fence blocks.
- [What the agent can do: permissions and the network](10-permissions-and-network.md): a sandbox's network, and a fenced session's, goes only through a proxy that checks each connection against plain-language permissions; inside, a refused HTTPS site answers 403 "refused by Dozable's network policy" to a program that uses the proxy and looks like a DNS error (ENOTFOUND) to one that does not; `doz net NAME` names the host and the allow command; a browser's own background requests swell the refused count and are no reason to allow them.
- [Security model](16-security-model.md): what protects your Mac, credentials and data in each place an agent runs, what each boundary does and does not cover, and the deliberate ways in.
- [Terminals and sessions](07-terminals-and-sessions.md): programs running in a sandbox — attach, detach, watch read-only, type from a script, files, the clipboard and links; `doz exec` stops a command after 120 s unless `--timeout`, so a long job such as a render uses `--timeout` or `doz run -d`.
- [Folder rules: .dozignore and .dozreadonly](20-workspace-rules.md): keep paths of a shared folder hidden or read-only from the agent.
- [The folder view (dozview)](21-the-workspace-view.md): how a sandbox sees your folder live, and how to look inside that view.
- [Signing in from a sandbox](11-signing-in-from-a-sandbox.md): browser sign-ins (localhost callbacks) for tools inside a sandbox, and device-code sign-ins.
- [Web ports](29-web-ports.md): open a web page served inside a sandbox (a dev server, a playground) in your Mac's browser.

### Agents, tools and accounts

- [Trying agents, and what Dozable supports](26-try-and-search.md): `doz try` — from nothing to talking to an agent in one command; what is supported and how to search it; a plan before anything is made (`--dry-run`).
- [More agents](27-more-agents.md): the other agent programs Dozable can run (OpenCode now; Antigravity CLI, Grok Build, Gemini CLI and others unpublished in this version), what each needs and may reach.
- [Codex](24-codex.md): OpenAI's Codex in Dozable — no approval prompts, told where it runs, its credential kept on your Mac.
- [Claude Code with other models](32-claude-code-other-models.md): point Claude Code at a gateway (OpenRouter) or a model server on your Mac instead of Anthropic.
- [Other AI tools](28-ai-tools.md): command-line AI tools that are not coding agents (unpublished in this version) — prompt tools, toolkits, agent frameworks.
- [GitHub as you](18-github.md): let agents use git and gh as you — private clones, pull requests — read-only or with push, without the token entering the sandbox.
- [Managed tools](19-the-tools-layer.md): the tools Dozable installs inside a sandbox so its settings work (gh, the ssh client, tmux), and how they are kept up to date.

### Images, recipes and your own setup

- [Images and bases](08-images-and-bases.md): what a sandbox starts from — a baked disk with Linux, a toolkit and an agent — and making, listing and removing images, your own Dockerfile included.
- [Projects](04-projects.md): give a folder its own sandbox settings with `doz_project.yaml`, `doz init` and `doz up`.
- [Your own recipes, and community catalogues](30-your-own-recipes.md): a recipe is a YAML file saying how a tool installs, runs, which key it uses and what it may reach; write your own or add a catalogue.
- [Restore points, duplicates and saved disks](12-restore-points-duplicates-templates.md): instant copies of a sandbox's disk — roll back, branch off, or keep one to start others from.
- [Your dotfiles](31-dotfiles.md): bring your shell aliases, prompt and editor settings into new sandboxes.
- [Sound](23-sound.md): let programs in a sandbox play through your Mac's speakers and use its microphone (not in public releases yet).
- [Resources and disk space](13-resources-and-disk-space.md): where everything lives (the store), what uses disk and memory, how to get space back, and a second store with its own daemon, chat ports and tokens.

### The dashboard and apps

- [The dashboard (doz ui)](06-the-dashboard.md): Dozable in your browser — workspaces, rooms, live terminals, Asks that need you, restore points, permissions, accounts and settings.
- [The dashboard on your other devices](25-doz-serve.md): `doz ui --lan` and the Tailscale option — the same dashboard on your laptop, iPad or phone, signed in as you — and behind your own HTTPS reverse proxy.
- [The menu bar app](35-the-menu-bar-app.md): Dozable.app — the daemon's state, Start, Stop, Open Dashboard, and Start at Login, for the default store.

### Reference

- [Settings reference](15-settings-reference.md): every setting in ~/.config/doz/doz.toml — what it does, its default, when a change applies, and its environment variable.
- [Troubleshooting and FAQ](17-troubleshooting-and-faq.md): `doz doctor`, and the common failures by name — the login expired, connection refused on a chat port, an Ask nobody answered, a command timed out (exit 124), a refused host.
- [Bundling doz in an app](33-bundling-doz-in-an-app.md): for app developers only — carrying doz inside a Mac app (the helper build).

## Renamed in 0.51

> From 0.52, *workspace* names an environment set up for getting work done: its agents, its rooms, the brief that says
> what the work is for, and any folders it works on (usually projects) — see [Workspaces](37-workspaces.md),
> `doz workspace`. A sandbox's folder is still its folder.
>
> What a sandbox (or a session on this Mac) works on is its **folder** — never "workspace" or "workdir". The folder
> still appears inside the sandbox at `/workspace`; `doz get`, `put`, `cp` and `files` paths, `--isolated`,
> `--ignore-mode`, `defaults.projects_dir` and every environment variable are unchanged. The old names are not
> aliases: each fails, and says its new name.
>
> | before | from 0.51 |
> |---|---|
> | `--workspace DIR` (create, up, try, duplicate) | `--folder DIR` |
> | `--workspace-view on\|off` | `--folder-view on\|off` |
> | `--workdir DIR` on `doz run @mac` | `--folder DIR` |
> | `--workdir DIR` on `doz run NAME`, `doz exec NAME` | `--cwd DIR` |
> | the `doz ls` column `WORKSPACE` | `FOLDER` |
> | `--json` keys `workspace`, `workspaceCreated`, `workspaceRules`, `workspaceRulesView`, `workspaceView` | `folder`, `folderCreated`, `folderRules`, `folderRulesView`, `folderView` |
> | `doz sessions @mac --json`: `workdir` | `folder` |
> | settings `[workspace] ignore_mode` and `view` | `[folder] ignore_mode` and `view` (an old line is not read, and every command warns) |
> | `workspace_view:` in `doz_project.yaml` | `folder_view:` |
> | agent prompt variables `{{workspace.shared}}`, `.host_path`, `.guest_path`, `.description`, `.rules` | `{{folder.…}}` |
> | the dashboard's API: `workspace` and `workdir` fields, `/api/v1/workspace/check` and `/choose` | `folder`, `/api/v1/folder/check` and `/choose` |
> | "Workspace rules" | "Folder rules" |
>
> A doz of 0.51 and a daemon of an earlier version refuse each other: `doz daemon stop`, and the next command starts
> the new one. Also in 0.51: `daemon.idle_timeout_minutes` defaults to 5 again (it applies only when
> `daemon.always_on` is off).

## Conventions

- Commands are shown as you type them: `doz up`. `NAME` is a sandbox's name; `my-app` is an example.
- Every command takes `--json` (machine-readable output), `--store DIR`, `-v` (every step), `-q`
  (no progress) and `--no-color` (or `--color auto|always|never`; the lasting switch is the setting `ui.color`).
  `doz help COMMAND` shows a command's options.
- Settings are named `section.name`, like `sandbox.clipboard`; see the
  [Settings reference](15-settings-reference.md).
- Screenshots use the light theme; the dashboard follows your Mac's appearance.

This manual is checked against `doz` itself on every build: every command, flag and setting it names
exists, and the settings reference is generated from the program.

The command-line [user guide](../CLI-USER-GUIDE.md) and the [walkthrough](../CLI-WALKTHROUGH.md) cover
the same ground for command-line users, more tersely.
