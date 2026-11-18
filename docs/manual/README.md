# The Dozable manual

Dozable runs AI coding agents in small Linux virtual machines on your Mac: each agent gets its
own disk, a network that only reaches what you allow, and your project folder if you share it. A
sandbox pauses in a millisecond and wakes from disk in a third of a second, with everything where you
left it.

You drive it with the `doz` command or its dashboard in your browser (`doz ui`). Every page here shows
both.

## Reading order

**New to Dozable?** Read these first, in order:

1. [Getting started](01-getting-started.md) — install, set up, and talk to Claude in a sandbox in 15 minutes.
2. [Sandboxes and their lifecycle](05-sandboxes-and-lifecycle.md) — pause, sleep, hibernate, wake; what's kept where.
3. [Terminals and sessions](07-terminals-and-sessions.md) — attaching, the Ctrl-] menu, what the agent is doing, the clipboard, tmux.
4. [What the agent can do](10-permissions-and-network.md) — permissions and the network.

**Then, as you need them:**

| page | read it when you want to… |
|---|---|
| [Installing, upgrading and uninstalling](02-install-upgrade-uninstall.md) | install with Homebrew, upgrade safely, remove Dozable |
| [Setting up](03-setting-up.md) | (re)run onboarding in the terminal or the wizard |
| [Projects](04-projects.md) | give a folder its own sandbox with `doz_project.yaml` and `doz up` |
| [The dashboard](06-the-dashboard.md) | use `doz ui`: its pages, banners, sign-in links |
| [The dashboard on your other devices](25-doz-serve.md) | use the dashboard from another computer, a tablet or a phone on your network (`doz ui --lan`) — and behind your own HTTPS reverse proxy |
| [Images and bases](08-images-and-bases.md) | pick a language base, use your own Dockerfile, rebuild an out-of-date image |
| [Agents and accounts](09-agents-and-accounts.md) | use Claude Code or pi, add accounts, change what the agent is told |
| [Claude Code with other models](32-claude-code-other-models.md) | run Claude Code through a gateway (OpenRouter) or a model server on your Mac (Ollama, LM Studio, llama-server …) — `--gateway`, `--provider local --local-port` — and what a sandbox can reach on your Mac |
| [Trying agents, and what Dozable supports](26-try-and-search.md) | try an agent in one command (`doz try`), check what Dozable runs (`doz search`), see a plan before anything is made (`--dry-run`) |
| [More agents](27-more-agents.md) | run Antigravity CLI, Grok Build or Gemini CLI with an API key — what each may reach, what is kept out, whether it is current |
| [Other AI tools](28-ai-tools.md) | AI tools that are not coding agents (Fabric, …) — tried like an agent, each on an API key |
| [Your own recipes, and community catalogues](30-your-own-recipes.md) | write a recipe of your own (`doz recipe new`), check it against the minimum requirements for a community recipe — for real with `--full` — and add catalogues others publish, by their URL and key |
| [Codex](24-codex.md) | run OpenAI's Codex on your ChatGPT plan (Dozable's own sign-in) or an OpenAI key — the token never enters the sandbox |
| [Web ports](29-web-ports.md) | open a web page a tool serves in a sandbox (a playground, your dev server) in your Mac's browser — `doz ports`, `doz open` |
| [Signing in from a sandbox](11-signing-in-from-a-sandbox.md) | let a tool in a sandbox sign in through your Mac's browser |
| [GitHub as you](18-github.md) | let git and gh in a sandbox use your GitHub login — read-only or with push — without the token entering it |
| [Managed tools](19-the-tools-layer.md) | know which tools Dozable manages in a sandbox for its settings (gh, the ssh client, tmux …) and check them |
| [Your dotfiles](31-dotfiles.md) | have your shell setup (your dotfiles repository, or a folder on your Mac) in every sandbox — what runs, what is never touched, trust, `doz dotfiles` |
| [Folder rules](20-workspace-rules.md) | keep the agent out of some files in your shared folder (`.dozignore`), or let it read but not change them (`.dozreadonly`) |
| [The folder view](21-the-workspace-view.md) | `dozview`, the small program in the sandbox every shared folder goes through: why (programs keep their folder across a wake), what it costs, `folder.view`, the rules it enforces, its two processes, sleep and wake, how to look inside. |
| [Prompts for your agent](22-prompts-for-your-agent.md) | prompts to paste into Claude Code, Codex or Cursor on your Mac: install, set up, and three uses — a risky change, jailing an untrusted agent, a project with secrets |
| [Restore points, duplicates and templates](12-restore-points-duplicates-templates.md) | undo, copy a sandbox, make your own starting image |
| [Resources and disk space](13-resources-and-disk-space.md) | see where the disk went and free some |
| [Letting another agent drive Dozable](14-letting-another-agent-drive.md) | have the agent on your Mac run sandboxes for you |
| [Settings reference](15-settings-reference.md) | look up any setting, its default and when it applies |
| [Security model](16-security-model.md) | understand what protects your Mac, and what doesn't |
| [Troubleshooting and FAQ](17-troubleshooting-and-faq.md) | fix something, or find a quick answer |
| [Sound](23-sound.md) | give a sandbox your Mac's speakers, and its microphone |
| [Sessions on this Mac](34-sessions-on-this-mac.md) | run a program on the Mac itself (an agent on a project, Xcode, the Simulator) held like a sandbox's session — `doz run @mac`, fenced to its folder and a proxy by default, `--unfenced` for no isolation — and know what the fence is and is not |
| [The menu bar app](35-the-menu-bar-app.md) | see the daemon's state in the menu bar, start, stop or restart it and open the dashboard with a click — `doz app install` |
| [Chat](36-chat.md) | talk with your agents in rooms on your Mac — `doz chat on`, tokens for agents, webhook bots, agents on your other machines, the dashboard's Chat page, and what other browsers may do (`serve.chat`) |
| [Workspaces](37-workspaces.md) | set up an environment for getting work done — its agents, its room in chat, the brief and any folders — and adopt the sandboxes and sessions you already have into it (`doz workspace`) |
| [Bundling doz in an app](33-bundling-doz-in-an-app.md) | (app authors only) carry the helper build of `doz` inside your Mac app and drive it over `daemon.sock` |

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
