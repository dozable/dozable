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

It prints the workspace. A new one is **setting up · you**: it has no agent yet and has never started, and you drive
it. The work starts once the workspace is fully set up; a later version adds the command that checks the set-up and
starts it.

### Its room

With chat on (see [Chat](36-chat.md)), `new` makes a room in the chat server with the workspace's name, with you in it.
Nothing is posted there yet: the brief is posted when the work starts.

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

A workspace's state is one of: **setting up** (no agent yet, never started), **starting** (a sandbox is booting),
**waiting on you** (a program is blocked or stopped in an error, or a sandbox failed), **working**, **idle**, **asleep**
(every agent paused, asleep, hibernated or off — or it had agents and has none now), **finished** and **archived**.

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

Exit codes are as everywhere: 2 not found · 4 already exists (or already in a workspace) · 6 the daemon or chat is not
available · 64 usage.
