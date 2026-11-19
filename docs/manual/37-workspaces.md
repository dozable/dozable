# Workspaces

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up.

A *project* is something else: a folder (usually a repository) with its sandbox settings in `doz_project.yaml` (see
[Projects](04-projects.md)). A workspace can work on several projects' folders, or on none.

Nothing you already have moves by itself. Your sandboxes and your sessions on this Mac are **loose agents** until you
adopt them into a workspace, and adopting one changes only the workspace's own record: the sandbox and the session stay
exactly as they were. The dashboard shows them (below, [In the dashboard](#in-the-dashboard)); everything that changes one
is the command line.

## Making one

```bash
doz workspace new demo --prompt-file brief.md --folder ~/code/demo
```

- `--prompt-file FILE` is the brief: what the work is for, in your words (at most 256 KiB; `-` reads it from standard
  input). `--ref PATH` or `--ref https://…` adds a reference to it (repeatable).
- `--folder DIR` adds a folder it works on (repeatable); the first is the main one. `DIR:ro` makes one read-only. Folders
  are optional: `doz workspace new notes --prompt-file brief.md` makes a workspace with none.
- `--adopt NAME` (or `--adopt @mac/SESSION`) adopts a sandbox or a session at once (repeatable).
- `--from-project` takes the network preset from the project file in the main folder (it needs a `--folder`).
- `--manager BOT` makes one of your Agents / Bots its manager (see [The manager](#the-manager) below). Nothing is
  started yet.

It prints the workspace. A new one is **setting up · you**: it has never started, and you drive it. The work starts
once the workspace is fully set up, with `doz workspace start`.

### Its room

With chat on (see [Chat](36-chat.md)), `new` makes a room in the chat server with the workspace's name, with you in it.
Nothing is posted there yet: the brief is posted when the work starts (`doz workspace start`).

- If a room of that name already exists, `new` is refused — pass `--room demo` to make that room the workspace's own
  instead (nothing is posted in it either), or choose another name.
- `--no-room` makes none. With chat off there is none either; `doz workspace edit demo --make-room` makes it later.
- If chat is on but its server is not ready, `new` is refused and nothing is made: try again, or pass `--no-room`.

## Looking

```bash
doz workspace ls                 # each workspace: its state, who drives it, its agents and room — then the loose agents
doz workspace ls --loose         # only the sandboxes and sessions on this Mac in no workspace yet
doz workspace show demo          # its brief, folders, room and agents
doz workspace show demo --brief  # …and the brief's text
doz workspace log demo --since 2h   # what happened, and who did it (a time like 2026-11-19T09:00:00Z, or 30m, 2h, 3d)
```

Looking never starts the daemon: these answer from the store when it is not running.

A workspace's state is one of: **setting up** (never started, and no running agent adopted yet), **starting** (being
started, or a sandbox is booting),
**waiting on you** (a program is blocked or stopped in an error, or a sandbox failed), **working**, **idle**, **asleep**
(its manager stopped, every agent paused, asleep, hibernated or off — or started with no agent), **finished** and
**archived**. Adopting an agent that is running marks the workspace started; adopting one that is not leaves it setting
up.

`doz ls --json` and `doz sessions NAME --json` (and `doz sessions @mac --json`) give each adopted sandbox or session a
`workspace` field; a loose one has none. While the daemon runs, `doz workspace ls --json` also says who is working in each
workspace (`working`) and `doz workspace show --json` what each agent's program is doing (`activity`: `working`, `idle`,
`blocked` or `error`); `ls --json` lists each workspace's `folders`.

### In the dashboard

**Home** (the page `doz ui` opens on) lists every workspace — its state (waiting on you first), its folders, who drives
it, its manager (an unfenced one says **acts as you**), who is working (for one waiting on you, why), its room and the
room's last line while the chat server runs — with one next action: **Open room**, or for one still setting up what it
lacks and `doz workspace start NAME` to copy. A workspace's name opens **its page** (`#/w/NAME`): the brief above its
room, its log among the room's messages, and beside them its agents, folders and network ([A workspace's
page](06-the-dashboard.md#a-workspaces-page)). With none, Home says what a workspace is and how many sandboxes and
sessions on this Mac are not in any workspace yet. In the sidebar, **Workspaces** lists them, each unfolding to its
rooms and agents; **This Mac › Loose agents** lists the sandboxes and sessions in none, each with the
`doz workspace adopt WORKSPACE NAME` that adopts it. From the dashboard you change one thing of a workspace: its brief
(**Edit** on its page — announced in the room once the work has started). Making, adopting, starting and stopping are the
commands on this page. It reads them when it opens, when something changes and when an action
ends — a workspace made from the command line shows there the next time the page reads them (open Home, or reload).

## Adopting and releasing agents

```bash
doz workspace adopt demo my-sandbox           # a sandbox, as a worker
doz workspace adopt demo @mac/build           # a session on this Mac (name the session)
doz workspace adopt demo other --as reviewer  # under another name in the workspace
doz workspace release demo my-sandbox         # loose again; it keeps running as it was
```

A sandbox or session is in one workspace at most: adopting one that is already in another is refused, with the command
that releases it. An agent of a workspace may be an Agent / Bot — a lasting identity in chat (see
[Agents / Bots](38-agents-and-bots.md)); a bot in a workspace is released from it before it can be retired. A sandbox you rename (`doz rename`) stays in its workspace under its new name; one you delete
(`doz rm`) leaves it.

## Starting and stopping the work

```bash
doz workspace start demo        # the set-up check, then the brief posted, then the manager started
doz workspace stop demo         # the manager stopped; its conversation, record and room are kept
```

`start` first runs **the set-up check**: the brief is there; with chat on, the room exists; every folder and every
adopted agent's sandbox or session is still there; and, when it has a manager, its bot is ready (chat on, its token kept
by Dozable, reached the way its manager can be, its agent program known and installed, no other session or sandbox of
the workspace's name). When anything is missing, `start` refuses, lists **every** gap with the command that fixes it,
and posts and starts nothing:

```
demo is not fully set up yet:
  - a manager needs chat — doz chat on
  - folder ~/code/old is gone — doz workspace edit demo --remove-folder ~/code/old
```

Then the bot is invited to the room, **your brief is posted as your first message** in it (with its references), and
the manager is started. The brief is posted once: a start after a stop never posts it again. Without a manager, `start`
posts the brief and you drive.

`stop` ends the manager's session (or stops its sandbox, keeping its disk) and keeps its conversation: the workspace is
**asleep**, and the next `start` wakes the manager where it left off. Nothing is posted in the room. With nothing
running, `stop` says so.

## The manager

A manager is one of your Agents / Bots playing the manager's role in a workspace: it reads the brief and talks in the
room with you.

```bash
doz workspace new demo --prompt-file brief.md --folder ~/code/demo --manager mira
doz workspace edit demo --manager otto --manager-isolation vm    # another, or another isolation
doz workspace edit demo --no-manager
```

Where it runs:

- **fenced** on this Mac — the default. Its session is named after the workspace (`@mac/demo`). It can talk in the room,
  but cannot start or stop agents yet: it asks you.
- **vm** — in a micro VM named after the workspace (`--manager-isolation vm`, or when the bot's own default is vm).
- **unfenced** on this Mac — **only when you name it** (`--manager-isolation unfenced`), even when the bot's default is
  unfenced. An unfenced manager **acts as you**: `doz` is on its PATH and what it does is done as you. `show`, `ls` and
  `--json` (`actsAsYou`) say so wherever it appears.

The manager starts with a short first prompt telling it to read its START file: who it is, its room, how to talk with
`dozchat`, its skills and instructions, and the brief. It says in the room that it is up. Its token never appears in a
command line, a record, a log or `--json`: a fenced or VM manager holds only a placeholder Dozable's proxy swaps; an
unfenced one reads its token from a file only you can read, in your temporary folder, deleted when it stops.

A fenced or VM manager collects its messages itself, so its bot must be reached by polling (`doz bot set mira --deliver
poll`); a manager is never reached by a webhook. A bot elsewhere runs on its own machine and is never started by
Dozable. **For now a bot runs in one live workspace at a time**, as a manager or a worker: starting a second workspace
with the same bot is refused — stop the first one, or end it as a worker there. A manager is not removed, replaced or released while it runs: stop it first.

## Workers

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up. Once it has started, you
(or its manager, through you) bring up **workers**: agents, each with one task, that join the workspace's room.

```bash
doz worker add demo --task "list the files"                 # an anonymous worker, bot1, fenced on this Mac
doz worker add demo --from-bot otto --task "review the PR"  # one of your Agents / Bots as a worker
doz worker add demo carl --isolation vm --cpus 2 --memory 2G --task "build it"   # in a micro VM of its own
doz worker ls demo                                          # every agent: where it runs, what isolates it, its state, its task
doz worker end demo bot1                                    # its session ends; an anonymous one leaves chat
```

A worker joins the workspace's room, is told its task in its START file, and says in the room that it is up — Dozable
posts nothing there itself. While the workspace is still setting up, `worker add` refuses and says to start it first;
nothing is made.

- **Its name.** Leave it out and it is the first free `bot1`, `bot2`, …: an anonymous worker, with a throwaway place in
  chat that goes when it ends. `--from-bot otto` makes it that Agent / Bot: its name, token, skills and instructions.
- **Where it runs** — the narrowest place unless you say otherwise: **fenced** on this Mac (the default; its session is
  `demo-bot1`), **vm** (a micro VM of its own, `demo-carl`, when you say so or the workspace's or the bot's default is
  vm), **in a running sandbox of the workspace** (`--sandbox X`: it is its own participant there, but it **shares X** —
  workers there can read each other's placeholders), or **unfenced** — acting as you — only when you name it
  (`--isolation unfenced`).
- **What it reaches.** It works in the workspace's main folder; its network is the workspace's default, else locked; it
  reaches only the chat server's port of this Mac, opens no URL and copies to no clipboard. A fenced Claude Code worker
  may use only the chat client without asking; `--allow-tool Edit` (repeatable) adds a tool.
- **Its token** never appears on a command line, in a record, a log or `--json`. A fenced or VM worker holds only a
  placeholder Dozable's proxy swaps; an unfenced one reads its token from a file only you can read, deleted when it ends.
- **`worker ls`** shows every agent of the workspace — its manager, the agents you adopted and its workers — with its
  place, its isolation, what isolates it (fenced: "proxy · placeholders · guard"; vm: "micro VM · proxy · placeholders";
  unfenced: "no proxy · no placeholders · no guard · acts as you"), its network, its state and its task. It answers with
  the daemon stopped. `--all` adds the ended workers.
- **Ending one.** `doz worker end demo bot1` ends its session (or stops its own micro VM, keeping its disk). An anonymous
  worker leaves every room and its token is refused from then on; its messages keep its name. A bot's token is kept and it
  stays in the room. `--rm` deletes its session's record or its micro VM too. Its name is free again.

`doz workspace stop` stops only the manager; workers go on until you end them.

## Changing one

```bash
doz workspace edit demo --prompt-file brief.md      # a new brief
doz workspace edit demo --add-ref https://example.com/spec --remove-ref ~/notes.md
doz workspace edit demo --add-folder ~/code/site:ro --remove-folder ~/code/old
doz workspace edit demo --make-room                 # its room, now that chat is on
doz workspace rename demo launch-video              # its room keeps its own name
```

## Where it is kept

Each workspace is a folder in the store, `workspaces/NAME/`: `workspace.json` (the record), `brief.md` (the brief) and
`log.jsonl` (what happened). They are readable by you alone. The log never holds the brief's text or a folder's path.

Exit codes are as everywhere: 2 not found · 3 not fully set up (or still setting up, for a worker), or its manager is
running · 4 already exists (or already in a workspace, a name taken, or the bot runs in another live workspace) · 6 the
daemon or chat is not available · 64 usage.
