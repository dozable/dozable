# Letting another agent drive Dozable

So far *you* have run `doz`. But the agent you already use on your Mac — Claude Code, Codex, Cursor —
can run it too. Its job is to orchestrate a **workspace** for you: make it with a brief and your folders, start its
agents, follow the room and the journal of each unit of work, and bring you what needs your decision. A sandbox is one
place an agent of the workspace can run (a Sandbox), beside a fenced session on this Mac or, only when you say, a
session that acts as you.

Before anything else, it should run `doz --version` and read the manual of that version (`doz docs`, below): commands
and flags change between releases. Then [Workspaces](37-workspaces.md) for the model, and the rules on this page for
driving: `--json`, the exit codes, `--yes`, and what to ask you first. Four things it must know before it acts:

- **Chat on is your call.** Workers and a manager talk in the workspace's room, so they need chat (`doz chat on`); the
  agent should ask you before it turns chat on, not do it unasked.
- **`doz exec` stops after 120 s** unless it passes `--timeout`; a long job (a build, a render) goes in the background
  with `doz run NAME -d`.
- **A refused connection looks like a DNS error** inside a sandbox (`ENOTFOUND`). `doz net NAME` names what was refused
  and the command that allows it — which it asks you to run.
- **The agents inside have no `doz`.** They reach Dozable with `dozchat` and their own token ([Runs, the journal and
  lessons](41-runs-the-journal-and-lessons.md)); it never hands them its own.

## Workspaces

To get agents working on something — a brief, your folders, a helper with a task — make a **workspace**, in one
command:

```sh
doz workspace new app --brief "Fix the build" --folder ~/code/app --worker "Fix the failing test" --json
doz workspace start app --json
```

- **Create.** `--brief TEXT` (or `--brief -` for standard input, or `--prompt-file FILE`), `--folder DIR` (repeatable;
  the first is the main one), `--worker "TASK"` (repeatable: declared now, started by `doz workspace start`), `--preset
  NAME` (`blank` or `remotion-video`; a flag given wins) and `--start` to start it
  at once. `--dry-run --json` shows what would be made and makes nothing. `doz workspace create` is the same command.
  An unknown preset exits `65` (`invalid-value`), naming the real ones. Workers need chat on (`doz chat on`).
- **State.** `doz workspace state app --json` gives each agent's `condition` — `running`, `asleep`, `stopped`,
  `crashed`, `not-started` or `unknown` — with its `reason`, `role`, `place` and `since`, and `conditions.ready` (every
  agent running). With no daemon running none is started and every condition is `unknown`.
- **Add a worker.** `doz worker add app --task "Review the fix" --json` brings up a helper in a started workspace
  (refused, exit `3`, while it is still setting up); `doz worker ls app --json` lists them; `doz worker end app NAME`
  ends one. Workers run fenced on this Mac unless you say otherwise: `--isolation unfenced` acts as you, so an agent
  should never choose it for you.
- **Retry safely.** An agent that loses an answer (a timeout, a dropped connection) cannot tell whether the command
  worked, and running it again could make a second worker. So pass `--request-id ID` — an id the agent makes up once
  per request, a UUID say — to `doz workspace new`, `doz worker add`, `doz workspace adopt` and `doz permissions grant`.
  Run again with the same id and arguments, the command answers its first answer with `"replayed": true` and does
  nothing again; with other arguments it exits `3` (`request-id-reused`, naming what differs). A failed first try is not
  kept, so the retry runs for real. Ids are kept 24 hours, per command.
- **The skill.** `doz skill show doz` prints the `doz` skill — a `SKILL.md` for an agent that drives doz: workspaces,
  the exit codes, the error JSON, `--yes`, and what not to do. `doz skill show doz --json` gives its path
  (`{"kind":"Skill","schema":1,"name":"doz","path":"…/SKILL.md"}`); point your agent at it. It ships inside doz, which
  installs it nowhere.
- **This manual, of this version.** Every `doz` carries its own manual: `doz docs` says where it is (offline — no
  network, no daemon), `doz docs PAGE` prints a page by name or number (`doz docs workspaces`, `doz docs 37`; an unknown
  page exits `65` and lists them), and `doz docs --json` gives
  `{"kind":"DozDocs","schema":1,"version","local","llms","url"}`: `llms` is its index, `llms.txt` (every page, one
  line each, linked relatively), and `url` the same manual online for this version only,
  `https://dozable.com/v/VERSION/llms.txt`. `doz docs --path` prints only the folder. An agent should read this one,
  never another version's: a canary or beta has commands and flags the stable manual doesn't.

`doz create` makes a single sandbox, not a workspace: an agent asked for a workspace should use `doz workspace new`.

## Concepts

- **Every command works without a terminal to type into**, and **`--json`** gives machine-readable
  output on stdout (errors as `{"error":{"code","message","exit"}}`; fields are only ever added). A usage error is
  one too: with `--json` anywhere on the line, an unknown option or a missing argument prints
  `{"error":{"code":"usage","message":"Unknown option '--no-such-flag'","exit":64}}` on stdout and exits `64` — never
  the plain-text usage (`--help` still prints help).
- **Exit codes** say what happened, the same for every command, and they keep their meaning:

  | exit | meaning | `error.code` |
  |---|---|---|
  | `0` | done (or asked: a question was posted, the answer comes later) | — |
  | `1` | failed | `failed` |
  | `2` | not found — only that | `not-found`, `ambiguous` (several match: the message lists them) |
  | `3` | not possible now | `invalid-phase`, `conflict`, `plan-changed`, `file-changed`, `already-answered`, `not-owned`, `request-id-reused` |
  | `4` | already exists | `already-exists` (also `exists`) |
  | `5` | not confirmed (no terminal and no `--yes`) | `needs-confirmation` |
  | `6` | the daemon is unavailable | `needs-daemon` (also `unavailable`, `version`) |
  | `7` | not implemented yet | `not-implemented` |
  | `8` | supported, but not with what was asked (`doz search`) | `limited` |
  | `9` | not permitted (an agent's request) | `not-permitted` |
  | `64` | usage: an unknown command or flag, a missing argument | `usage`, `unclear-request` |
  | `65` | an invalid document or value (a space file, a name, a flag's or a setting's value) | `invalid-document`, `invalid-value`, `secret-value-in-document` (also `invalid`) |
  | `75` | partly done: `--json`'s `partial` says `done`, `remaining` and `retry` (the command that does the rest) | `partial` |
  | `124` | timed out | `timed-out` |
  | `125` | `doz` itself failed around a program (`exec`, `run`, `attach`) | — |

  `doz help exit-codes --json` prints this table (`{"kind":"ExitCodes","schema":1,"codes":[…]}`). `exec`,
  `run` and `attach` exit with the program's own code (`125` when `doz` itself failed). `exec` exits `124` when its `--timeout` passed (default 120 s, counted from when `doz`
  started — a wake or a start included); the command is killed (and anything it left running is reaped, never left
  `<defunct>`), a wake or a start goes on, and stderr says so with what to do instead: `--timeout SECONDS`, or `doz run
  -d` for a long job. A program's own `124` looks the same: `--json` says `"timedOut": true` only for the deadline.
- **Destructive commands refuse without `--yes`** when there's no terminal, so a script can't delete
  something by accident.
- **Two agents, two sets of rules.** The agent on your Mac has *your* permissions: it can run `doz`, so
  treat it as you would at the keyboard. An agent inside a sandbox or a fenced session is held by
  the proxy: it reaches Dozable only through its room and the journal, with `dozchat`, by the permissions you grant it.

## The briefing

Paste this into your project's `CLAUDE.md` (or `AGENTS.md` for other agents):

````markdown
## Sandboxes (Dozable)

This Mac has Dozable (`doz`): Linux VMs for running agents and risky commands in isolation.
Use a sandbox for anything that installs packages, runs untrusted code, or should not touch this
Mac. Always pass `--json` and read the result; never use `doz attach` or `doz up` without `--detach`
(they are interactive).

- Create one for this project: `doz create NAME --image claude-code --folder "$PWD" --json`
  (images: `claude-code`, `pi`, `lab`, or `--agent claude-code --base python|go|rust|…`; `doz base ls`).
  `/workspace` in the sandbox IS this folder, live.
  For throwaway work that must not touch this folder: `doz create NAME --isolated --json`.
- Run a command and get its output and exit code: `doz exec NAME --json -- sh -c '…'`
  (add `--timeout SECONDS` for long ones; the default is 120). It starts or wakes the sandbox if needed.
- Start a long-running agent or program and come back later:
  `doz run NAME --detach -- claude -p "…"`, then `doz sessions NAME --json` and
  `doz sessions NAME --screen SESSION` to see its terminal.
- Before anything risky: `doz point take NAME before-X`; undo with `doz point revert NAME before-X --yes`.
- Refused network: `doz net NAME --json` shows what the agent was refused and the permission that
  would allow it. Do NOT widen permissions yourself: tell me what and why, and I will run
  `doz net allow NAME …`.
- When done: `doz hibernate NAME` (keeps everything, frees memory; `doz wake NAME` brings it back).
  Ask me before `doz reset`, `doz rm` or `doz shutdown`.
- `doz ls --json` lists sandboxes; `doz doctor --json` diagnoses problems.
````

## Then ask for what you want

For example, to Claude Code on your Mac:

> Upgrade this project to React 19 in a sandbox. Take a restore point first, let a Claude in the
> sandbox do the upgrade and get the tests passing, check on it every few minutes, and show me the
> diff when it's done. Don't touch my Mac's node_modules.

Your agent will then typically run:

```sh
doz create react19 --image claude-code --folder ~/code/my-app --json
doz point take react19 before-upgrade
doz run react19 --detach -- claude -p "Upgrade to React 19 and make npm test pass"
doz sessions react19 --screen claude          # every few minutes, to see how it's going
doz exec react19 --json -- sh -c 'cd /workspace && npm test'
doz hibernate react19
```

Because `/workspace` is your project folder, the changes are already on your Mac when it finishes:
review them with `git diff`. If they're not what you wanted, `git checkout .` puts your files back
and `doz point revert` resets the sandbox.

You can watch it all in the dashboard (`doz ui`): the sandbox appears under **Sandboxes**, and
**All sessions** shows the agent working, read-only.

## Guardrails

- **Keep permission changes and deletion for yourself.** The briefing asks for that; you can make it a
  rule in your agent's own settings too (for example, only allow it `doz` subcommands that don't
  change permissions or delete).
- **Prefer `--isolated`** for work that shouldn't touch your folder at all.
- **Use restore points** before each risky step; they cost almost nothing.
- **Watch the clipboard, browser and file notices.** A sandboxed agent can put text on your clipboard,
  open a page in your browser or open a document of its folder on your Mac, and each time you're told.
  Turn any of them off for a sandbox with `doz config set --sandbox NAME sandbox.clipboard off`,
  `… sandbox.browser_bridge off` or `… sandbox.open_files off`.
- **Scripts on a schedule** should use exact agent versions (`recipes.anthropic.claude-code.version`) so an image
  never needs the internet to prepare.

## Useful JSON

| command | gives |
|---|---|
| `doz ls --json` | every sandbox: name, image, phase, RAM, disk, network, isolated, … |
| `doz inspect NAME --json` | everything about one |
| `doz exec NAME --json -- CMD` | `exitCode`, `stdout`, `stderr`, and whether it had to start or wake the sandbox |
| `doz sessions NAME --json` | its sessions, running or saved |
| `doz net NAME --json` | its permissions and recent refusals, with the suggestion for each |
| `doz resources --json` | the whole disk account |
| `doz config show --json` | every setting, value and source |

## Troubleshooting

| symptom | what to do |
|---|---|
| The agent's `doz` command hangs | It used an interactive command (`attach`, `up` without `--detach`); use `exec`, `run --detach`, `sessions --screen`. |
| Exit code 5 | A destructive command without `--yes` and without a terminal: intended. Decide yourself, or add `--yes`. |
| Exit code 6 | The daemon couldn't be reached or started: `doz doctor --json`. |
| The sandboxed agent is refused a site | Expected: it tells your Mac's agent, which tells you. `doz net NAME` shows the suggestion. |
