# Space files

A **space file** describes a workspace in one YAML file, `NAME.space.yaml`, kept in git beside the work: its agents,
its rooms, the brief, any folders and sandboxes. Each thing in it is either **owned** — the space makes it — or
**external**: it exists already and is only referenced (`external:`). The file asks; Dozable decides: it holds the
workspace's record (see [Workspaces](37-workspaces.md)), and every rule the daemon keeps holds for a file too.

Dozable reads, checks and plans a space file, sets the workspace up from it (`doz space up`) and takes it down again
(`doz space down`, and `--purge` for what persists).

```yaml
doz: space/3
extends: ./my_doz_workspace_defaults.yaml   # settings every space shares (optional)
space: launch-video
brief: BRIEF.md
owner: ada

folders:
  repo: { external: ~/code/launch-video }
  scratch: {}                               # owned: made for each run, removed at down

agents:
  mira: { external: { bot: mira }, role: manager }
  writer:
    kind: claude-code
    isolation: fenced
    folder: repo
    prompt: Read BRIEF.md and draft the script.

chat:
  rooms:
    launch-video: { members: [owner, mira, writer] }

persist:
  team-chat: { room: launch-video }         # the room and its history carry over from one run to the next
```

## Looking at one

```bash
doz space config launch-video.space.yaml     # the file merged with what it extends, each value with its file and line
doz space plan -f launch-video.space.yaml    # what up would do: every step, the summary, what down will do
doz space up -f launch-video.space.yaml --dry-run   # the same plan, as up shows it
```

`doz space` is `doz workspace` under a shorter name: `doz workspace plan -f FILE` and `doz workspace config FILE` are the
same commands. Without `-f`, the one `*.space.yaml` in the current folder is used; with two or more there, name one.
`--profile NAME` (repeatable) includes the things the file marks `profiles: [NAME]`.

Looking never starts the daemon and changes nothing. With no daemon running, what only a running daemon knows — whether a
session or a bot runs now, the chat server's rooms — is marked "not known", and nothing is refused for it.

## What is read

- **The file**, then each **defaults file** it `extends:` (a list is applied in order, each after the files it extends;
  a loop is an error naming the chain). A defaults file (`doz: space-defaults/3`) holds only `persist`, `archive`,
  `approvals` and `agent_defaults`: never agents, rooms, sandboxes, services, folders, secrets or the owner, so
  inheriting never starts anything the space file did not write.
- **`NAME.space.override.yaml`** beside the file, when there is one: good for paths that differ from Mac to Mac.
- **`${VAR}`** in values, from the environment or the `.env` beside the file (`${VAR:-default}`; `$$` is a `$`). Never in
  keys and never under `secrets:`.
- Maps merge by key; lists replace; `null` removes an inherited value (`persist: { memory: null }`).

Every problem is reported at once, as `file:line`, with what to write instead; an error stops everything (exit 2) and
nothing is done. A warning does not stop it.

## The plan

The plan lists the steps `up` will run, in order: the external things it checks (each must exist, or up stops before
changing anything — "nothing was changed"); the workspace it makes (its folders, its room, its manager); its other
rooms and scratch folders; the start, which opens a run; each owned agent, in the order written. Each step says what
`down` will do to it.

Its summary names **every risky setting with the file and line that set it**: an agent that is unfenced (it acts as
you, with full access to your user), one that bypasses permissions, what persists, `archive: off`, transcripts
discarded. A setting inherited from a defaults file is named as such: inheriting never approves anything.

- **Unfenced is never inherited.** `agent_defaults` cannot make an agent unfenced; each unfenced agent writes
  `isolation: unfenced` itself. An agent that bypasses permissions on this Mac must write its own isolation.
- **Unfenced is confirmed at every up**, wherever the setting came from (`--yes` answers on a terminal only).
- **A file asks; the owner grants.** `requests:` on an agent are recorded and shown ("requested, not granted"); you grant
  them with `doz permissions grant`. A file never grants anything.
- **The owner** must be you, as the chat server knows you.
- **A workspace made without a space file** is not taken over: `up` refuses a name already used by one (exit 4).

Not in this version, and said so in the plan: owned services (refused), a manager that is not an Agent / Bot (refused),
secrets for an agent Dozable starts (refused), a preset other than `standard` or `bypass` (refused), and `model`,
Remote Control, chat delivery, `resume: summary` and folder trust (noted, not applied).

## Up and down

```sh
doz space up -f launch-video.space.yaml            # the plan, then it is set up
doz space down launch-video                        # end the run; archive it; remove what the run made
doz space down launch-video --purge                # and what persists
doz workspace show launch-video --space            # "Defined by launch-video.space.yaml": up or down
```

- **`up`** shows the plan and makes what is missing: the folders it keeps, the workspace (or the changes the plan
  shows), its rooms, the run (started — the brief posted as your first message the first time only — or reopened when
  the space is down, its kept agents woken), the run's scratch folders, each agent. An agent that runs **unfenced**
  acts with full access to your user: `up` asks you about it on the terminal at every up, whatever set it — `--yes`
  answers that question on a terminal; with no terminal, `up` does nothing and exits 5. What the file **requests** for
  an agent (a role, grants) is recorded, never granted: `doz permissions grant` does that. `up` stops at the first step
  that fails (the rest are "not run", exit 1); `up` again makes only what is missing.
- **The brief is the file.** The kick-off, `doz workspace show --brief` and the run's archive read `BRIEF.md` beside
  the space file; an edit on the workspace's page or with `doz workspace edit --prompt-file` is saved into it. `up`
  never writes it. The file must be yours, under your home, and no link.
- **`down`** asks first (`--yes`; no terminal and no `--yes`: exit 5). It archives the run — chat, transcripts, screens,
  usage — into the store and checks it, then removes what the run made, each only after its copy verifies: agents
  ended and forgotten (transcripts deleted only with `transcripts: discard`, and only files unchanged since), the run's
  scratch folders and rooms (a room leaves a tombstone). If the archive could not be written, nothing that holds work
  is removed. What `persist:` names is kept for the next run: a room closed with its history, a sandbox's disk, an
  agent's memory (a fenced agent's comes back in its next fenced session only). External things are never touched.
  With **`archive: off`** nothing is copied: what goes with no copy is listed before you confirm. A step that fails is
  said and `down` carries on; `down` again does what is left.
- **`--purge`** takes it down first, then removes what persists — its rooms (archived first), sandboxes and kept
  memory — and releases the folders it kept: they leave the workspace and stay on disk.

Exit codes: 0 ok · 1 a step failed · 2 a problem in the file, or something external missing · 3 not in a state to go
on (chat off, a workspace archived), or changed since the plan · 4 a workspace of that name made without a space file ·
5 not confirmed · 7 not in this version · 64 usage.
