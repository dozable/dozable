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

Every problem is reported at once, as `file:line`, with what to write instead; an error stops everything (exit 65, an invalid
document; `--json` says `"error": {"code": "invalid-document", …}`) and nothing is done. A warning does not stop it.

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
  that fails (the rest are "not run"): exit 75 when steps before it were done (`--json`'s `partial` names what is done,
  what remains and the command that retries), exit 1 when nothing was; `up` again makes only what is missing.
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
  said and `down` carries on (exit 75); `down` again does what is left.
- **`--purge`** takes it down first, then removes what persists — its rooms (archived first), sandboxes and kept
  memory — and releases the folders it kept: they leave the workspace and stay on disk.

Exit codes: 0 ok · 1 a step failed before anything was done · 2 something external missing · 3 not in a state to go
on (chat off, a workspace archived), or changed since the plan · 4 a workspace of that name made without a space file ·
5 not confirmed · 7 not in this version · 64 usage · 65 a problem in the file · 75 partly done (a step failed after
others were done). `doz help exit-codes` lists them all.

## While it runs

- **`doz workspace state NAME`** shows the space as it is now beside its file: each agent (running, asleep, gone after
  down, missing — and whether it is working, idle or waiting for you), its chat member, every folder, sandbox and room,
  what the workspace holds named like the space but not in the file, and what waits for you (a permission prompt, a
  sandbox that failed, an up that stopped part way), and each agent's condition (running, asleep, stopped, crashed, not
  started). A chat message's text is never in it. `--json` is the document the dashboard reads, with `kind`
  `WorkspaceState`, `schema` 1 and each agent's condition (37, "Every agent's condition"). With no daemon running it
  starts none, and every state says "not known". A workspace made without a space file answers too, from its record.
- **`doz workspace show NAME --space`** names the file and, read now, its size and sha256. **`doz workspace edit NAME
  --space-file F --if-match SHA`** saves F over that same file — only while it is still the one whose sha256 you read
  (changed since: nothing is written, exit 3). A save is never applied: `doz workspace up -f FILE` applies it. From the
  dashboard the file is saved only in this Mac's own browser.
- **`doz workspace runs NAME --frames RUN`** shows a run as it went: its state each time it changed (recorded when
  something happens, never on a timer; at most 2,000 frames a run, then only the last state). Down keeps them in the run's
  archive and checks them.

## The workspace drawn

In the dashboard a workspace a space file made is drawn from its file and what is running now: its agents, rooms, folders
and sandboxes in the file's layout, each marked as it is — running, asleep, missing, gone after down — and what waits for
you. The picture is on the workspace's **Home** tab, across the page — on no other tab: click it to open the file in the
space editor (below). Home and the Workspaces page show each workspace small beside its
name, and the sidebar shows it at the top of an unfolded workspace (the setting `ui.nav_thumbnails` turns the sidebar's
pictures off; the sidebar keeps no empty box while a picture is on its way). The picture follows what happens — an up or down, a save, a
sleep or wake from the dashboard, a sandbox starting or stopping — and is never read on a timer; a change made only in a
terminal to agents on this Mac shows the next time you open a page.

A file that doesn't read is drawn as a small warning, and the page adds what Dozable itself found wrong with it and the
command that checks it, `doz workspace up -f FILE --dry-run`. A workspace made without a space file shows a small tile on
Home and the Workspaces page and, on its Home tab, "Made without a space file — `doz workspace up -f FILE` draws it". Another computer sees the picture
only while `serve.chat` lets it read; otherwise it sees the tile, "Shown to another computer only with serve.chat read".

## Editing a space in the dashboard

A workspace's picture (or **Edit the space** beside it) opens its space file in the space editor, the whole window, at
its own address — `#/w/NAME/space`, which you can bookmark, reload or open in a new tab. The bar above it leads back to
the workspace, names the file, says **Saved**, **Unsaved** or **Read-only here**, and has **Text**, **Watch** and **Open in
a new window**.

- **The canvas** draws the file; you change it there, and its problems are listed and marked as you go — a problem in a
  defaults file it extends is named with that file. **Live** draws what is running now over it (the agents, their rooms,
  what waits for you — a permission prompt, an open Ask, which you can answer there), following what happens; it is never
  read on a timer. The runs strip under it steps through a past run's states.
- **Text** adds the YAML beside the canvas; it is loaded only when you ask for it, and your changes, undo and selection
  carry over. The dashboard remembers that you use it.
- **Saving** (**⌘S**) writes the file only if it is still the version you opened. If it changed since — in your editor or
  with `doz workspace edit` — nothing is written and the editor says **Changed elsewhere**; **Reload** reads the file as it
  is now (your changes there are lost). A save is never applied: "Saved. Not applied: Up applies it." — `doz workspace up
  -f FILE` applies it. A file too long to send from the page is saved with the command the page shows.
- **Unsaved changes are never lost without asking**: leaving the page asks first (**Stay** or **Leave**), closing the tab
  asks too, and a restart of `doz ui` waits to reload the page until the file is saved.
- **Watch** (`#/w/NAME/space/watch`) shows the drawing with Live on and nothing else, read-only — for a second screen.
- **Another computer** sees the file only while `serve.chat` lets it read, read-only: "Changed only in this Mac's own
  browser", with the command that changes it on the Mac. Only this Mac's own browser saves a space file.
- **A phone** shows the drawing and Live, read-only ("Edit on a wider screen").
