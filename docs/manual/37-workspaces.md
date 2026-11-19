# Workspaces

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up.

A *project* is something else: a folder (usually a repository) with its sandbox settings in `doz_project.yaml` (see
[Projects](04-projects.md)). A workspace can work on several projects' folders, or on none.

Nothing you already have moves by itself. Your sandboxes and your sessions on this Mac are **loose agents** until you
adopt them into a workspace, and adopting one changes only the workspace's own record: the sandbox and the session stay
exactly as they were. The dashboard does not show workspaces yet; this page is the command line.

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
`workspace` field; a loose one has none.

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
Dozable. **For now a bot runs in one live workspace at a time**: starting a second workspace with the same bot is
refused — stop the first one. A manager is not removed, replaced or released while it runs: stop it first.

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

Exit codes are as everywhere: 2 not found · 3 not fully set up, or its manager is running · 4 already exists (or already
in a workspace, or the bot runs in another live workspace) · 6 the daemon or chat is not available · 64 usage.
