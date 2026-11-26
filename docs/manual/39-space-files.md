# Space files

A **space file** describes a workspace in one YAML file, `NAME.workspace.yaml`, kept in git beside the work: its agents,
its rooms, the brief, any folders and sandboxes. Each thing in it is either **owned** — the space makes it — or
**external**: it exists already and is only referenced (`external:`). The file asks; Dozable decides: it holds the
workspace's record (see [Workspaces](37-workspaces.md)), and every rule the daemon keeps holds for a file too.

Dozable writes space files as `NAME.workspace.yaml`. A file called `NAME.space.yaml` — the name Dozable used before —
is read just the same, and always will be; you never need to rename one. When both are in one folder for the same NAME,
`NAME.workspace.yaml` is read and `NAME.space.yaml` is ignored, and Dozable says so with a warning. The line inside,
`doz: space/3.1`, is the same either way.

Dozable reads, checks and plans a space file, sets the workspace up from it and takes it down again. Exactly what
applies one in this version:

| command | what it does with the file |
|---|---|
| `doz space plan -f FILE` | reads and checks it, and shows what `up` would do; changes nothing |
| `doz space up -f FILE` | applies it: shows the plan, then makes what is missing and opens a unit of work |
| `doz space down NAME` | takes it down at the end of the unit of work (`--purge` also removes what persists) |
| `doz space config FILE` | prints it merged with what it extends; changes nothing |

`doz space` is `doz workspace` under a shorter name: `doz workspace up -f FILE` is the same command as
`doz space up -f FILE`. **Plain `doz up` is something else** — a project's command ([Projects](04-projects.md)): it reads
`doz_project.yaml` and never a space file. Saving a space file in the dashboard's editor never applies it either: `up`
does. Not in this version, and refused by the plan with exit 7 when a file asks for them: an owned **service**, a
**secret** for an agent Dozable starts, and an agent `permissions:` preset other than `standard` or `bypass`.

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
doz space config launch-video.workspace.yaml     # the file merged with what it extends, each value with its file and line
doz space plan -f launch-video.workspace.yaml    # what up would do: every step, the summary, what down will do
doz space up -f launch-video.workspace.yaml --dry-run   # the same plan, as up shows it
```

`doz space` is `doz workspace` under a shorter name: `doz workspace plan -f FILE` and `doz workspace config FILE` are the
same commands. Without `-f`, the one `*.workspace.yaml` (or `*.space.yaml`) in the current folder is used; with two or more there, name one.
`--profile NAME` (repeatable) includes the things the file marks `profiles: [NAME]`.

Looking never starts the daemon and changes nothing. With no daemon running, what only a running daemon knows — whether a
session or a bot runs now, the chat server's rooms — is marked "not known", and nothing is refused for it.

## What is read

- **The file**, then each **defaults file** it `extends:` (a list is applied in order, each after the files it extends;
  a loop is an error naming the chain). A defaults file (`doz: space-defaults/3`, or `space-defaults/3.1`, which holds the same) holds only `persist`, `archive`,
  `approvals` and `agent_defaults`: never agents, rooms, sandboxes, services, folders, secrets or the owner, so
  inheriting never starts anything the space file did not write.
- **`NAME.workspace.override.yaml`** beside the file, when there is one: good for paths that differ from Mac to Mac. (A
  `NAME.space.yaml` has its override as `NAME.space.override.yaml`: an override goes with the file of its own name.)
- **`${VAR}`** in values, from the environment or the `.env` beside the file (`${VAR:-default}`; `$$` is a `$`). Never in
  keys and never under `secrets:`.
- Maps merge by key; lists replace; `null` removes an inherited value (`persist: { memory: null }`).

Every problem is reported at once, as `file:line`, with what to write instead; an error stops everything (exit 65, an invalid
document; `--json` says `"error": {"code": "invalid-document", …}`) and nothing is done. A warning does not stop it.

### The version line: space/3.1

A file starts with its version line. **`doz: space/3.1`** is space/3 with a few keys of Dozable's own; everything else
reads the same. A file that says `doz: space/3` is read exactly as before.

```yaml
doz: space/3.1
space: app
owner: ada
brief: { text: Fix the build }  # the brief written here; or brief: BRIEF.md, or { file: BRIEF.md }; refs: [...] beside it
about: { title: Work on a project, summary: A manager and a helper. }   # title, summary, description, icon, tags, category, needs
layout: { … }                   # where the editor draws things; a plan never acts on it
network: standard               # locked, standard or open, or { preset, allow: [HOST…] }
x-dozable: { lifetime: standing }   # not a 3.1 key: standing (what the space owns stays) or runs (it lasts one run)
folders:
  repo: { external: ~/work/app, main: true }   # the main folder (one at most)
agents:
  helper: { kind: claude-code, isolation: fenced, folder: repo, prompt: Fix the failing test., restart: on-failure }
  old: { external: { sandbox: my-sandbox } }   # an agent in a sandbox that exists: adopted, never started
```

- **`brief`** is a path, `{ text }` or `{ file }` — one of them — with optional `refs:`: files or folders the agents
  should read, or `http(s)://` addresses. A relative path is the space file's folder's (as the brief's file is) and `~/…`
  is your home; `up` records each one as an absolute path (the plan shows them so), and refuses one that is not there.
- **`about.title`** is the workspace's title. A top-level `title:` still reads in a 3.1 file, with a note; both is an error.
- **The top-level `network`** is the workspace's network: `up` records it as the workspace's default, which every agent
  it starts gets — the manager, workers, and an agent in a place that declares no network of its own (below) — and the
  workspace's Network card shows. `allow:` holds host names (no port). A file that says none is `locked`. A later `up`
  of a changed `network:` changes the workspace's default (the plan names the change); an agent already running keeps
  the network it started with until it starts again.
- An agent's own `network` outside a place, and **`restart`** (`no` or `on-failure`), are recorded and noted, not applied
  in this version.
- **The lifetime is not a 3.1 key**: it stays under `x-dozable` in either version and is never required (a file that says
  none is read as `runs`). A top-level `lifetime:` in a 3.1 file is refused (65) with the fix.
- **`agent_defaults: { where: sandbox }`** runs every agent that does not say where in the workspace's own Sandbox, a sandbox
  the run makes (named `SPACE-vm`). On an agent, a place is `mac` or `sandbox:NAME`.
- **An agent's own `network`**: an unfenced agent has none (it acts as you), and an agent in a Sandbox — the workspace's or
  a sandbox the space makes — shares the Sandbox's, which is the workspace's (standard when the file says none). Either
  written otherwise is refused (65).
- An empty `refs`, `tags` or `allow` list is refused; leave the key out instead.
- A 3.1 key in a file that says `doz: space/3` is refused (65): change the version line to `doz: space/3.1`. A space/3
  file extends only `space-defaults/3` files.

A brief written in the file is kept with the workspace and posted at the first up; `doz workspace show W --brief` reads
it. `doz workspace doc W` (37) prints any workspace as a space/3.1 file.

### Dozable's other keys: `x-dozable`

A few things the format cannot say yet are written under `x-dozable`, at the place they belong; any other `x-` key is
ignored.

```yaml
x-dozable: { lifetime: standing }                             # the space's lifetime: standing or runs
folders:
  notes: { x-dozable: { lifetime: run } }                     # in a standing space: this one lasts one run
agent_defaults: { x-dozable: { isolation: vm } }              # where a workspace's new workers run (3.1: where: sandbox)
```

### Places: `x-dozable.places` and `where:`

A **place** is where an agent runs: a Sandbox, a fenced session on this Mac, or an unfenced one that acts as you. Declare your
places under `x-dozable.places` and put each agent in one with `where:`:

```yaml
doz: space/3.1
agents:
  helper:   { kind: claude-code, role: worker, where: desk, folder: repo }
  reviewer: { kind: claude-code, role: reviewer, where: build, access: ro }
x-dozable:
  places:
    desk:    { isolation: fenced }                                  # on this Mac, behind Dozable's fence
    build:   { isolation: vm, image: claude-code, cpus: 4, memory: 8G }  # a sandbox of the space
    old-box: { external: { sandbox: old-review } }                  # a sandbox that already exists: only referenced
```

- **`isolation`** is `vm`, `fenced` or `unfenced`. Only a `vm` place has an `image`, `cpus` and `memory`; it is made by
  `up` as the space's sandbox (`app-build`), and every agent in it shares it.
- **A fenced place is a policy, not a shared box.** Each agent in it gets a fence of its own: its own proxy, its own
  placeholders, nothing shared with the other agents of the place — and each fence is built from the place:
  - **`view`** (`{ notes: ro, out: rw }`): more folders of the space, read-only or read-write. The agent's own folder
    (the workspace's main one) is always read-write; a view cannot make it read-only.
  - **`network`** (as the top-level `network:`: `locked`, `standard`, `open` or `{ preset, allow: [HOST…] }`): the
    fence's network; a place that declares none has the workspace's (the top-level `network:`, else `locked`). An agent
    in the place may write its own `network:` only to narrow it — a preset no wider and only hosts the place allows (otherwise 65); it narrows that agent's fence alone.
  - **`credentials`**: `github:read` (or `github`), `github:push` — GitHub as you, through a placeholder — and
    `ssh-agent`. A fence holds no key accounts (65).
- **A vm place** takes its `network` (none: the workspace's) and `credentials` (`github:read`, `github:push`, or a key
  account's name) when its sandbox is made; every agent in it shares them, so an agent's own `network:` must equal the place's (65). Its `view` can
  name only the workspace's main folder, read-write: a sandbox shares one folder, at `/workspace`.
- **An unfenced place enforces nothing**, so it declares no view, network or credentials (the plan refuses them, 65) and
  says so: the plan shows each as "none: acts as you". An agent is never put in an unfenced place by `agent_defaults`:
  it writes `where:` itself, and `up` asks you to confirm it, as for `isolation: unfenced`.
- **An external place** is `external: { sandbox: NAME }` and nothing else: an existing sandbox, never made or removed.
- **`where:`** names a place, or `mac`, or `sandbox:NAME` for a sandbox under `sandboxes:` — those two words are never a
  place's name. A name that is no place is refused, listing the places there are. `sandboxes:` entries are still read,
  as places with isolation `vm`.
- **A grant is never a place's.** `doz grant desk …` is refused: grant the agents in it (`doz grant helper …`).

`doz workspace plan -f FILE --json` lists the `places` (name, isolation, view, network, credentials) and each agent's
`where`; `doz workspace state W --json` lists each place with its sessions — in a fenced place, each with its own fence.

The keys space/3.1 now has were written under `x-dozable` too (`x-dozable: { brief: { text: … }, network: … }`, a folder's
`x-dozable: { main: true }`, an agent's `x-dozable: { restart: …, external: { sandbox: … } }`). That form is
**deprecated**: it is still read in this release, in either version, and the plan says, for each use, the key to write
instead. Writing a key both ways is an error.

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
doz space up -f launch-video.workspace.yaml            # the plan, then it is set up
doz space down launch-video                        # end the run; archive it; remove what the run made
doz space down launch-video --purge                # and what persists
doz workspace show launch-video --space            # "Defined by launch-video.workspace.yaml": up or down
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

In the dashboard every workspace is drawn with what is running now: its agents, rooms, folders and sandboxes, each marked
as it is — running, asleep, missing, gone after down — and what waits for you. One a space file made is drawn from its
file, in the file's layout; one made without a space file (with the wizard, `doz workspace new`, by adopting agents) from
its record — the document `doz workspace doc NAME` prints. The picture is on the workspace's **Home** tab, across the page
— on no other tab: for a space file, click it to open the file in the space editor (below); one made without has no file
to edit, and shows `doz workspace doc NAME` beside its picture instead. Home and the Workspaces page show each workspace small beside its
name, and the sidebar shows it at the top of an unfolded workspace (the setting `ui.nav_thumbnails` turns the sidebar's
pictures off; the sidebar keeps no empty box while a picture is on its way). The picture follows what happens — an up or down, a save, a
sleep or wake from the dashboard, a sandbox starting or stopping, a worker added or ended — and is never read on a timer; a change made only in a
terminal to agents on this Mac shows the next time you open a page.

A file that doesn't read is drawn as a small warning, and the page adds what Dozable itself found wrong with it and the
command that checks it, `doz workspace up -f FILE --dry-run`. Another computer sees the picture only while `serve.chat` lets
it read; otherwise it sees a tile, "Shown to another computer only with serve.chat read" — and, while `serve.mac_sessions`
is off, a workspace made without a space file is drawn without its agents on this Mac.

## Editing a space in the dashboard

A workspace's picture (or **Edit the space** beside it) opens its space file in the space editor, the whole window, at
its own address — `#/w/NAME/space`, which you can bookmark, reload or open in a new tab. The bar above it leads back to
the workspace, names the file, says **Saved**, **Unsaved** or **Read-only here**, and has **Text**, **Watch**, **Export**
and **Open in a new window**.

- **The canvas** draws the file; you change it there, and its problems are listed and marked as you go — a problem in a
  defaults file it extends is named with that file. **Live** draws what is running now over it (the agents, their rooms,
  what waits for you — a permission prompt, an open Ask, which you can answer there), following what happens; it is never
  read on a timer. The runs strip under it steps through a past run's states.
- **Moving things** on the canvas pins them where you put them: the file keeps each position under `x-editor.layout`
  (a plan never acts on it), by name — and the parts with no name of their own by the keys `"@space"`, `"@chat"`,
  `"@archive"`, `"@owner"` and `"@fence/AGENT"` (an agent's fence, which follows the agent's name). What is drawn as part
  of something else can't be dragged on its own, and says what to drag instead: the dashboard moves with the owner, a
  proxy or a disk with its sandbox or fence, and the Mac has no place of its own to move to. A move is an edit like any
  other: **Unsaved** until you save it.
- **Text** adds the YAML beside the canvas; it is loaded only when you ask for it, and your changes, undo and selection
  carry over. The dashboard remembers that you use it.
- **Export** downloads the space as a file named after the workspace: **The file (YAML)** — the space file as saved,
  byte for byte (it holds the agents' prompts, the members and the folders' paths) —, **The drawing (SVG)** and **The
  drawing (PNG)**, in the dashboard's light or dark theme. A drawing shows what is happening now only when you tick
  **Drawings show what is happening now** (who is working, waiting or stuck). Exports are of the file as saved: save
  first to include your changes. They are made in your browser from what the page already shows you, so another computer
  that may read the file exports it too, and nothing else.
- **Saving** (**⌘S**) writes the file only if it is still the version you opened. If it changed since — in your editor or
  with `doz workspace edit` — nothing is written and the editor says **Changed elsewhere**; **Reload** reads the file as it
  is now (your changes there are lost). A save is never applied: "Saved. Not applied: Up applies it." — `doz workspace up
  -f FILE` applies it. A file too long to send from the page is saved with the command the page shows.
- **Unsaved changes are never lost without asking**: leaving the page asks first (**Stay** or **Leave**), closing the tab
  asks too, and a restart of `doz ui` waits to reload the page until the file is saved.
- **Watch** (`#/w/NAME/space/watch`) shows the drawing with Live on and nothing else, read-only — for a second screen.
- **Another computer** sees the file only while `serve.chat` lets it read, read-only: "Changed only in this Mac's own
  browser", with the command that changes it on the Mac — nothing moves there, and Export works as here. Only this Mac's
  own browser saves a space file.
- **A phone** shows the drawing and Live, read-only ("Edit on a wider screen").
