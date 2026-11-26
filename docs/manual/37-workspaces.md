# Workspaces

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up, and then goes one **unit
of work** (a run) at a time: each has a goal, a journal of what was done, and the lessons you approved from the ones
before ([Runs, the journal and lessons](41-runs-the-journal-and-lessons.md)). Where each agent runs — a Sandbox, fenced
on this Mac, or unfenced as you — is one setting of the workspace, not the first thing you decide.

```bash
doz workspace new demo --brief "Fix the failing test" --folder ~/code/demo --dry-run   # what it would make
doz workspace new demo --brief "Fix the failing test" --folder ~/code/demo
doz workspace start demo                                   # the set-up check, the brief posted, the first unit of work open
doz workspace finish demo                                  # the unit of work closed and archived (asks first)
doz workspace run demo "Now the flaky one"                 # the next unit of work, with the lessons so far
```

A *project* is something else: a folder (usually a repository) with its sandbox settings in `doz_project.yaml` (see
[Projects](04-projects.md)). A workspace can work on several projects' folders, or on none.

Nothing you already have moves by itself. Your sandboxes and your sessions on this Mac are **loose agents** until you
adopt them into a workspace, and adopting one changes only the workspace's own record: the sandbox and the session stay
exactly as they were. The dashboard shows them (below, [In the dashboard](#in-the-dashboard)), makes and starts a
workspace in this Mac's own browser ([The New workspace wizard](#the-new-workspace-wizard)), and leaves the rest of what
changes one to the command line.

## Making one

```bash
doz workspace new demo --brief "Fix the build" --folder ~/code/demo
doz workspace new app --preset blank --brief "Fix the build" --folder ~/code/app --worker "Fix the failing test" --start
```

`doz workspace create` is the same command (an alias of `new`): the same flags, the same answer.

- `--brief TEXT` is the brief: what the work is for, in your words (at most 256 KiB). `--brief -` reads it from standard
  input, its last line break dropped (`echo "Fix the build" | doz workspace new demo --brief -` gives the brief "Fix the
  build"). `--prompt-file FILE` reads it from a file instead, exactly as it is (`-` for standard input). Give one of them:
  `--brief` and `--prompt-file` together are refused. `--ref PATH` or `--ref https://…` adds a reference to it
  (repeatable).
- `--preset NAME` starts from one of the presets ([Presets](#presets), below); the dry run's `--json` lists them
  (`presets`). A flag you give wins over the preset (`--network open`, a folder's `:rw`). Another name is refused (exit
  65, `invalid-value`, naming the presets) and nothing is made.
- `--worker "TASK"` declares a worker (repeatable): it is recorded on the workspace now — `doz worker ls` lists it
  with its task, **not started** — and `doz workspace start` starts it, as `doz worker add NAME --task "TASK"` would, where
  the workspace's new workers run (fenced on this Mac unless `--worker-isolation sandbox`; `vm` is the same). Each is named when it is declared,
  the first free `bot1`, `bot2`, …. Declaring needs nothing else — chat may be off — but a worker talks in the
  workspace's room, so the start refuses (exit 3, saying the declared worker needs chat) until chat is on and the
  workspace has its room (`doz workspace edit NAME --make-room`); `--no-room` with `--worker` is refused at once. One that
  still does not start is said in the start's answer and stays declared; the next start tries it again.
- `--folder DIR` adds a folder it works on (repeatable); the first is the main one. `DIR:ro` makes one read-only. Folders
  are optional: `doz workspace new notes --brief "Take notes"` makes a workspace with none.
- `--adopt NAME` (or `--adopt @mac/SESSION`) adopts a sandbox or a session at once (repeatable).
- `--new-folder` makes an empty folder `~/doz-workspaces/NAME` (in your projects folder, `defaults.projects_dir`) and
  makes it the main folder. It is offered, never forced: with no folder the manager works there anyway.
- `--from-project` fills in the network preset from the project file in the main folder (it needs a `--folder`); the
  file is only read, never written. A `--network` that differs from it is refused.
- `--manager BOT` makes one of your Agents / Bots its manager (see [The manager](#the-manager) below). Nothing is
  started yet.
- `--worker-isolation fenced|sandbox` (`vm` is the same) is where its new workers run unless `doz worker add` says otherwise (fenced by default;
  never unfenced by default — a worker is unfenced only when you name it).
- `--network locked|standard|open` is the network its agents get (locked by default); the room is always added.
- `--dry-run` shows what would be made and makes nothing: a few lines, everything that would be refused, what the start
  would still need once it is made (each with its fix), and the commands that make it — the brief as a heredoc you can
  paste. It never starts the daemon; it exits 0 when nothing is refused, else as `new` would.
- `--start` starts it as soon as it is made (`doz workspace start NAME`). If the start is refused, the workspace stays
  made and setting up, and the refusal says what is missing.
- `--request-id ID` makes it safe to run again: see [Retrying safely](#retrying-safely) below.

It prints the workspace. A new one is **setting up · you**: it has never started, and you drive it. The work starts
once the workspace is fully set up, with `doz workspace start`.

### Presets

A preset fills in three choices for you — where the manager and new workers run, the network and whether folders are
added read-only — and nothing else. It installs no tool, makes no agent and allows no site beyond its network preset.

| preset | the manager and new workers | network | folders | what it does not cover |
|---|---|---|---|---|
| `blank` | as you choose (fenced unless you say) | as you choose (locked unless you say) | as you give them | — |
| `remotion-video` | Sandboxes | standard, and `remotion.media` (where a render downloads Remotion's own browser) | as you give them | any other site — fonts or media a composition fetches, a browser's own background requests: allow what the work needs (`doz workspace show W --network` shows each refusal and the command) |

`--worker-isolation`, `--manager-isolation`, `--network` and a folder's `:ro` or `:rw` each win over the preset.
`--site HOST` (repeatable) adds a site every agent the workspace starts may reach on top of its network; a preset's own
sites join yours, and the dry run's `network:` line names them all.

### Retrying safely

`doz workspace new`, `doz worker add`, `doz workspace adopt` and `doz permissions grant` take `--request-id ID`: an id of
your own for this one request (1–128 letters, digits, `.`, `_`, `:` or `-` — a UUID is a good one). Run the same command
again with the same id and arguments and you get the first answer again, with `"replayed": true` in `--json`, and nothing
is made, added or granted a second time. It is for a script or an agent that did not see the answer — a timeout, a
dropped connection, a daemon restart — and cannot tell whether the first try worked: it simply runs the same command
again.

- The same id with different arguments is refused (exit 3, `request-id-reused`): the message names what differs (such
  as `--brief`), never its value. Use a new id for a new request.
- A first try that failed is not kept, so a retry runs for real.
- An id is kept for 24 hours from its first answer, in the store, so a daemon restart does not lose it. Each command has
  ids of its own: `r-1` for a `workspace new` and `r-1` for a `worker add` are two ids.
- Two runs with the same id at the same moment never both run: the second waits and gets the first answer.

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
doz workspace state demo         # what is true now: each agent's condition, its sandboxes, folders and room, what waits for you
```

Looking never starts the daemon: these answer from the store when it is not running.

### Every agent's condition: `doz workspace state`

`doz workspace state NAME` answers for every workspace, however it was made — with `new`, the dashboard's wizard or a
space file (39). It lists each agent with its **condition** — **running**, **asleep** (put to sleep, or its sandbox
hibernated: `wake` brings it back), **stopped** (`doz workspace stop`, its manager stopped, its program ended, the workspace finished),
**crashed** (its program exited with an error nobody asked for — the code is the reason — or its sandbox failed) or **not
started** (a manager before the first `start`, a worker being added) — and why; then its chat members, the sandboxes its
agents run in, its folders and rooms, and what waits for you (a permission prompt, a crash, an open ask). With no daemon
running it starts none and every condition is "not known". A workspace that does not exist is exit 2, `not-found`.

`--json` is typed for a script: `kind` `WorkspaceState`, `schema` 1, the document the dashboard's space view reads (its
`items`, `attention` and `sha`), then `from` (`record` or `space-file`), `agents` — each agent by its name, with
`condition`, `reason`, `role` (`manager`, `worker`, `adopted`), `place` and `since` (an ISO 8601 time) —, `conditions`
`{ready, allocated, hot, run, archived}`, `places` and `revision`. `ready` is true when every agent runs. The others are one per
layer: `allocated` (what the workspace holds — true from `new` until it is archived or deleted; a space file whose
lifetime is `runs` gives it up at `down`; `reason` says `down` or `archived`), `hot` (`all`, `some` or `none` of its
sessions running, and each session's condition: `starting`, `running`, `asleep`, `stopped`, `ended` or `unknown`), `run`
(whether a run is open, its id and since when) and `archived` (and when). Each `since` and `at` is an ISO 8601 time.
`doz workspace ls --json` carries `allocated`, `hot` (its value) and `run` on each workspace:

```bash
doz workspace state demo --json | jq -r '.agents.mira.condition'    # running
```

`places` lists where the agents run, each with its `isolation` (`vm`, `fenced` or `unfenced`; `vm` is a Sandbox), its `view`, `network`
and `credentials` (an unfenced place says "none: acts as you" for each), `external` for a sandbox the workspace only
references, and its `sessions` — each `{identity, session, state, fence}`. A fenced place is a policy: every session in
it has its own fence, so two agents in one fenced place show two different `fence` values. A workspace made from a space
file lists the places the file declares (39); any other workspace, the places of its agents — a sandbox, or a session
on this Mac.

### Its document: `doz workspace doc`

Every workspace has one **document**: what should exist — its brief, folders, agents, rooms and sandboxes, and its
**lifetime** — written as a space file (39). `state` says what is true now; the document says what the workspace is for.
A workspace made with `new` or the wizard has its document made from what it holds, and it is **standing**: what it
owns stays until you remove it. One made from a space file has the file (as its last `up` read it) and anything you added
or adopted since; a file that says no lifetime is read as **runs** — the file's own run model.

```bash
doz workspace doc demo                          # the document, as YAML
doz workspace doc demo --json | jq -r '.document["x-dozable"].lifetime'   # standing
doz workspace doc demo --write ~/work/demo/demo.workspace.yaml          # keep it as a space file (nothing is applied)
```

The document never holds a secret's value (a secret is a reference: a keychain item or a file), never a grant (a file
only asks for one) and never the workspace's state. It is a `doz: space/3.1` file (39): a brief written in the file
itself, the main folder, the network default and an agent in a sandbox that already exists are keys of the format; what it
cannot say yet — the lifetime — is written under `x-dozable`, Dozable's part of the file. `--write` writes under your home, never into Dozable's store, `~/.claude` or `~/Library`, and never over a file
that is there unless you add `--force` (exit 4 otherwise; 65 for a place it may not write). Looking starts no daemon.

### What it can reach, hold and change

```bash
doz workspace show demo --can-do            # each agent: what it can do — isolation and control, folders, network, secrets by name, its room
doz workspace show demo --can-do --agent mira
doz workspace show demo --network           # each agent's network and what it was refused lately; this Mac's ports; secrets held; accounts
doz workspace show demo --folders           # its folders, what changed in them since the start, the restore points
doz workspace log demo --limit 50           # the newest 50 lines; it prints the command for the page before
```

**Can do** says, for each agent, only what is true today, each row live (it changes now) or at the next start: where it runs
and what holds it there, the folders it reads and writes, its network, the secrets it holds as placeholders (by name and
where each goes), the Claude account by name, and what it can drive. A fenced or Sandbox manager talks in the room only — it
cannot drive Dozable; an unfenced one **acts as you**: it runs doz and anything else as you. Last, its **permissions** — how
many answer allow, ask and never, by its role and your grants — and its **ceiling**, each cap and whose it is ("What agents
may do", below). They are read only there and in the dashboard, and none is enforced yet.

**Network** gathers what the workspace can reach in one place. What an agent was refused lately is known while the daemon
runs; `doz net allow` with the command shown allows it for that agent. Nothing it prints is a secret: a held secret is a name,
where it goes and a fingerprint; the values stay in your keychain.

**Folders** lists the files changed in each folder since the work started — `A` new, `M` changed — by their file times.
Dozable never runs a program, git included, in a folder an agent writes in order to look at it (git would run that folder's
own settings as you), so it says which folder changed, never which agent changed a file, and a deleted file is not seen. A big
folder is looked at only up to its limits (the list says when it was cut short). Restore points are a Sandbox agent's: one
per disk.

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

### The New workspace wizard

**New workspace** on Home (or the **+** beside **Workspaces** in the sidebar, or **⋯ › New workspace with this bot**
on an Agent / Bot) opens over the page, `#/new-workspace`. It always opens fresh, on a gallery of templates.

**The gallery.** Five templates — **One agent**, **One agent in a Sandbox**, **Build & review**, **Fix-it team** and
**Remotion video** — each a card with a drawing of the workspace it makes, and a sixth card, **Custom**. **⤢** on a
template's card expands it to a full page: the drawing, labelled; its agents and where each runs; its room; its network
in one line; and **Use this template**. Escape, **✕** or a click outside closes it.

**A template is one screen.**

- **Name** — already filled in: the next free `workspaceN`.
- **A new empty folder `~/doz-workspaces/NAME`** — ticked. Untick it to choose a folder of your own: the agents work
  there, and nothing is written into it.
- **The manager** — only when the template has one: your bots that can manage it, each with where it runs, or **A new
  bot, bossN**, made when you create the workspace.
- **Create and start.**

The template's files, `NAME.workspace.yaml` and `DESCRIPTION.md`, are written to `~/doz-workspaces/NAME/` (your
`defaults.projects_dir`; when that is not under your home folder, the files go in `~/doz-workspaces/NAME/` and the agents
still work in `defaults.projects_dir`), and the workspace is set up and started from them. It opens on its room. No built-in template runs an agent unfenced.

**Custom** has five short steps — **Name · Manager · Workers · How they chat · Confirm**. Every step's header draws the
workspace as chosen so far, with **⤢** for the full view.

1. **Name.** The name, and a new empty folder filled in. **+ Add a description** is optional: it is posted in the room as
   your first message when the workspace starts. With none, the manager asks in the room what to work on. When the main
   folder holds a `doz_project.yaml`, it is read (never written) to preselect the network.
2. **Manager.** Only the bots that can manage it now, each with a chip saying where it runs — a fact of the bot, never
   asked again. The others are folded under **N more bots cannot manage it now**, each with its reason and its one fix
   (for example **Reach it by poll**). **No manager — I drive** makes none. **+ New bot** makes one inline — **Bot name**,
   the program, and **Runs in**: **Sandbox**, **Fenced on this Mac** or **Unfenced — acts as you** — made when you
   create the workspace.
3. **Workers.** Where new workers run — **Fenced on this Mac** (the default) or **Sandbox** — and what they may reach:
   **Locked**, **Standard** or **Open**. A main folder's `doz_project.yaml` preset is preselected, marked **from
   doz_project.yaml**.
4. **How they chat.** The room's name (or **Use a room I have**), who is in it and how each gets messages, and **Also
   invite** (optional). With chat off, the step offers only **Turn chat on**.
5. **Confirm.** Only the check's findings, each with a **Change** link to its step — or **Everything checks out**. A
   manager that runs unfenced asks one tick, **Yes, NAME acts as me**. **Start it now** (ticked) makes the one button
   **Create and start**; unticked, it is **Create**.

Every change asks Dozable what it would make, and nothing is written and no daemon is started until you create it. If
the start is refused after the workspace is made, its page opens anyway, still setting up, saying what is missing. A
description too long for the page (over 15 KiB) is made with `--prompt-file` instead. Only this Mac's own browser makes
or starts a workspace; another computer sees the command to run in a terminal on the Mac.

**The same in a terminal.** `doz workspace templates` lists the templates. `doz workspace new [NAME] --template ID
[--manager BOT] [--folder DIR]` makes one; with no `NAME` it takes the next free `workspaceN`. `--brief` and
`--prompt-file` are optional. `--room-name R` names the room that is made, and `--invite NAME` (repeatable) says who is
invited. `--worker-isolation sandbox` (`vm` is the same) puts new workers in Sandboxes. The presets `swift-tests`,
`mac-admin` and `research` are retired; `blank` and `remotion-video` remain for `--preset`.

### In the dashboard

**Home** (the page `doz ui` opens on) lists every workspace — its state (waiting on you first), its folders, who drives
it, its manager (an unfenced one says **acts as you**), who is working (for one waiting on you, why), its room and the
room's last line while the chat server runs — with one next action: **Open room**, or for one still setting up what it
lacks and `doz workspace start NAME` to copy. A workspace's name opens **its page** (`#/w/NAME`): the brief above its
room, its log among the room's messages, and beside them its agents, folders and network ([A workspace's
page](06-the-dashboard.md#a-workspaces-page)). With none, Home says what a workspace is and how many sandboxes and
sessions on this Mac are not in any workspace yet. In the sidebar, **Workspaces** lists them, each unfolding to its
rooms and agents; **This Mac › Loose agents** lists the sandboxes and sessions in none, each with **Put in a
workspace…**. From the dashboard you change two things of a workspace: its brief (**Edit** on its page — announced in the
room once the work has started) and which agents it holds — putting a loose one in and taking one out (below); in this
Mac's own browser you also make one (the wizard above), start one that is setting up (**Start** in its setting-up
banner, which lists what is still missing and is disabled until nothing is), and add and end its workers (below).
Stopping is the command on this page. It reads them when it opens, when something changes and when an action
ends — a workspace made from the command line shows there the next time the page reads them (open Home, or reload).

## Adopting and releasing agents

```bash
doz workspace adopt demo my-sandbox           # a sandbox, as a worker
doz workspace adopt demo @mac/build           # a session on this Mac (name the session)
doz workspace adopt demo other --as reviewer  # under another name in the workspace
doz workspace release demo my-sandbox         # loose again; it keeps running as it was
```

A sandbox or session is in one workspace at most: adopting one that is already in another is refused, with the command
that releases it.

**Adopting a sandbox you made.** A sandbox you made with `doz create` or `doz new`, or a session you started with
`doz run @mac`, is a loose agent: adopt it to make it part of the work. That is the way when chat is off (a declared worker
needs chat) or when the agent needs a folder the workspace's own workers would not get. A folder cannot be added to a
running sandbox, so a new project folder means a new sandbox — make it with the folder, then adopt it.

With chat on and a room, an adopted agent is given **its own participant** in the room, under its name in the workspace,
and its own token. From the adoption on, every session Dozable starts in its place carries that token and this store's
chat address (`CHAT_URL`), as a worker's does — a launch secret, never written into the sandbox or its settings. A session
already running when you adopt it gets them when it restarts; `adopt` says so and prints the one command that hands the
token over now (`doz chat token NAME --to-file F`, then `CHAT_TOKEN_FILE=F` in its environment). `--no-token` keeps it off chat (no participant is made). It then reads the room's messages (each run's
opening message among them) and reaches the journal with `dozchat` — but nobody tells it to: an adopted agent has no
START file, so tell it in its own prompt to run `dozchat receive` and follow the room. Releasing it revokes the token and
removes the participant ([Tokens and identity](43-tokens-and-identity.md)).

**In the dashboard**, a loose sandbox or session is put in a workspace with **Put in a workspace…** — on **This Mac › Loose
agents**, or in the **⋯** of its own page. Choose an existing workspace (and, if you like, another name for it there), or
make a new one: its name starts as the agent's, its brief starts as "The work in AGENT." (change it to say what the work
is for), and with chat on its room is made (nothing is posted). Only the workspace's record changes; the agent keeps
running as it is. Putting a **running** agent in a workspace that is still setting up marks the work started — nothing is
posted and nothing is started, and `doz workspace start` is not needed; one that is not running leaves it setting up.
**Take out of the workspace…** (in a workspace's **Agents** tab, or on the agent's own page) makes it loose again, still
running; a live worker is ended instead (`doz worker end`) and a running manager stopped first (`doz workspace stop`).
**Move to another workspace…** is the two in turn. Only the Mac's own browser does this; another browser sees the
buttons disabled and the command to copy.

A workspace's **Agents** tab (`#/w/NAME/agents`) lists every agent — in a Sandbox, fenced or unfenced on this Mac, or
elsewhere — side by side, and each opens its screen in the workspace (`#/w/NAME/agent/AGENT`): its sandbox's or session's
page with the workspace around it ([The dashboard](06-the-dashboard.md#a-workspaces-page)). An agent of a workspace may be an Agent / Bot — a lasting identity in chat (see
[Agents / Bots](38-agents-and-bots.md)); a bot in a workspace is released from it before it can be retired. A sandbox you rename (`doz rename`) stays in its workspace under its new name; one you delete
(`doz rm`) leaves it.

## Starting and stopping the work

```bash
doz workspace start demo           # the set-up check, then the brief posted, then the manager started
doz workspace stop demo            # every agent stopped; conversations, disks, rooms and folders are kept (asks first)
doz workspace manager stop demo    # the manager alone; its workers run on
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
posts the brief and you drive — and the workers declared with `--worker` still start, each with its task, as they do
with one.

`stop` stops **everything**: every agent's process ends — a session on this Mac ended, a Sandbox shut down with its disk
kept — and every conversation, record, room and folder is kept. Nothing is removed. Unlike `sleep` nothing is held: each
agent is **stopped**, not asleep, and `doz workspace start demo` (or `doz workspace wake demo`) brings each back in its
conversation. It shows its plan and
asks first (`--yes` skips the question; with no terminal and no `--yes` it does nothing and exits 5, naming the command
with `--yes`). What is asleep or stopped already is left as it is, so a stop of a stopped or asleep workspace does nothing
and exits 0. Nothing is posted in the room.

`stop` used to stop only the manager; that is now `doz workspace manager stop demo`, which ends the manager's session (or
stops its sandbox, keeping its disk) and keeps its conversation; the next `start` wakes it where it left off. `doz
workspace stop` says so in a one-line note.

## Sleep, wake, finish, archive and delete

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up. Once it has started, the
whole workspace — every agent at once — can be put to sleep, woken, finished, archived and deleted:

```bash
doz workspace stop demo         # every agent stopped (their processes end); nothing removed (asks first)
doz workspace sleep demo        # every agent asleep: memory given back, conversations kept
doz workspace wake demo         # back in the same sandboxes and conversations
doz workspace finish demo       # the work is done: everything stops; says what it removed and kept (asks first)
doz workspace down demo         # the same as finish
doz workspace run demo "Fix the failing test"   # a new run: its goal posted, its agents started (below)
doz workspace archive demo      # put away: its rooms read-only, its workers (not bots) retired (type its name)
doz workspace restore demo      # archived → finished, its rooms writable again
doz workspace delete demo       # its record gone; finished or archived only (type its name)
```

**Check, then ask.** Each shows first what it would do to each agent — where it runs, what it is now, what it becomes,
how it comes back — what is kept and what goes (with sizes), how many agents change at once, and what would stop it. With
`--dry-run` it stops there: nothing changes and no daemon starts. Then it asks: nothing for sleep, wake, reopen and restore,
a yes for stop and finish, and the workspace's name typed for archive and delete. `--yes` skips the question (a script needs it).
It acts only on what it showed you: if the workspace changed in between, it is refused and says so.

| | A Sandbox | Fenced on this Mac | Unfenced on this Mac | Elsewhere |
|---|---|---|---|---|
| **start** (after a stop or a sleep) | woken, or booted again, as wake does — the manager first, then every other agent | the same conversation | the same conversation; its token file written again | untouched |
| **stop** | shut down, its disk kept | stopped, its conversation kept | stopped; its token file deleted | untouched |
| **sleep** | hibernated: its memory given back, the same programs and screens | ended, its conversation kept | ended; its token file deleted | untouched — it runs on its own machine |
| **wake** | woken (one shut down boots and its agent continues) | the same conversation | the same conversation; its token file written again | untouched |
| **finish** | shut down, its disk kept | ended, its conversation kept | ended | untouched; it stays in the room |
| **down** | as finish; for a workspace a space file made, a sandbox that lasts only the run is then removed, its disk saved as an image first | as finish | as finish | untouched; for a workspace a space file made, an adopted agent is released, loose again |

**Stopped is not asleep.** After `stop` the workspace and each agent read **stopped**; after `sleep` they read
**asleep**. On this Mac both end the session and keep its conversation; a Sandbox is shut down by a stop and hibernated
by a sleep. Either way `doz workspace start demo` or `doz workspace wake demo` brings every agent back: a start after a
stop (or a sleep) wakes the manager and every worker in its own conversation, and its answer names who came back.

A program that has no conversation to resume (one that is not an agent) starts fresh when it wakes. A workspace stays
asleep (or stopped) until you start or wake it; messages wait in the room meanwhile.

**Finish** is "the work is done": nothing runs afterwards, and no worker can be added — but its lasting workers are kept,
with their memory, so `doz workspace run`, below, picks it up again (each one with a new token: see
[Identities and sessions](#identities-and-sessions)). `doz workspace down W` is the same command, for every workspace.

**Finish always says what it removed and what it kept**, by the workspace's lifetime. A workspace made without a space
file — and one whose space file says `x-dozable: { lifetime: standing }` — is **standing**: finish removes nothing, its scratch
folders included, and says "finished; nothing removed (standing)"; only what says `x-dozable.lifetime: run` itself goes,
after its archived copy is hash-checked. A space file with lifetime **runs** (the default for one that says none) removes
what it made for the run, each only after its archived copy verifies, and nothing that holds work when the archive
failed. A folder you named is never touched. A sandbox is never removed without a copy: down (and `--purge`) saves its
disk as an image first (`doz image ls`), names it on a "saved:" line, and removes nothing when the save fails.

What it says keeps four things apart, each on its own line: **removed**; **kept** — only the workspace's own things
(its rooms, its agents, the folders it made); **released** — adopted agents let go, loose again; and **untouched** — your
folders, which were never the workspace's own, so its lifecycle does not touch them. `--json` answers
`{"kind": "WorkspaceFinish", "schema": 1, "removed": […], "kept": […], "untouched": […], "archive": "…"}`, and for a
workspace a space file made also `"released": […]` and `"savedDisks": {sandbox: image}`: folders by their absolute path,
rooms `room/NAME`, agents `agent/NAME`, sandboxes `sandbox/NAME`. A worker added with no name belonged to the run: it is
in `removed` (its place is kept; nothing on disk goes). `doz workspace down W --purge` also retires the lasting workers
and removes their kept memory — each memory copied into the store's archive and checked first — and answers
`"purged": ["agent/NAME", …]`. Its `kept` still lists what is untouched and released
as well, for scripts written before those fields. `doz workspace state W --json` then says `"phase": "finished"` (the
phases: `setting-up`, `running`, `asleep`, `stopped`, `finished`, `archived`). **Archive** finishes it, makes its rooms read-only (their
history stays readable) and retires its workers that are not bots — their tokens are refused from then on; a bot keeps its token
and its place in the rooms. `restore` opens the rooms again and leaves it finished; a retired worker stays ended.

**Delete** works only on a finished or archived workspace (`doz workspace finish demo` first), and never while any of its
agents still runs. It removes the workspace's record, brief and log, forgets its sessions on this Mac, and lets its
adopted sandboxes and sessions go loose again. Its rooms stay, archived with their history — the chat server cannot delete a
room — and so do its bots and their tokens, its saved disks and every folder. It cannot be undone.

**Nothing on disk goes unless you say so.** `--remove-sandboxes` (archive, delete) also removes the sandboxes Dozable made for
this workspace — never one you adopted, or one a worker shares — saving each one's disk as an image first (`doz image ls`;
`--no-keep-templates` to skip it); `doz workspace restore` then names that image rather than making the sandbox again. `--bin-folders` (delete)
moves the workspace's folders to the Bin, never deletes them, and refuses your home folder, Dozable's store and a folder
another workspace or sandbox uses, naming it.

## The manager

A manager is one of your Agents / Bots playing the manager's role in a workspace: it reads the brief and talks in the
room with you.

```bash
doz workspace new demo --prompt-file brief.md --folder ~/code/demo --manager mira
doz workspace edit demo --manager otto --manager-isolation sandbox    # another, or another isolation
doz workspace edit demo --no-manager
```

Where it runs:

- **fenced** on this Mac — the default. Its session is named after the workspace (`@mac/demo`). It can talk in the room,
  but cannot start or stop agents yet: it asks you.
- **sandbox** (`vm` is the same) — in a Sandbox named after the workspace (`--manager-isolation sandbox`, or when the bot's own default is a Sandbox).
- **unfenced** on this Mac — **only when you name it** (`--manager-isolation unfenced`), even when the bot's default is
  unfenced. An unfenced manager **acts as you**: `doz` is on its PATH and what it does is done as you. `show`, `ls` and
  `--json` (`actsAsYou`) say so wherever it appears.

The manager starts with a short first prompt telling it to read its START file: who it is, its room, how to talk with
`dozchat`, its skills and instructions, and the brief. It says in the room that it is up. Its token never appears in a
command line, a record, a log or `--json`: a fenced or Sandbox manager holds only a placeholder Dozable's proxy swaps; an
unfenced one reads its token from a file only you can read, in your temporary folder, deleted when it stops.

A fenced or Sandbox manager collects its messages itself, so its bot must be reached by polling (`doz bot set mira --deliver
poll`); a manager is never reached by a webhook. A bot elsewhere runs on its own machine and is never started by
Dozable. **For now a bot runs in one live workspace at a time**, as a manager or a worker: starting a second workspace
with the same bot is refused — stop the first one, or end it as a worker there. A manager is not removed, replaced or released while it runs: stop it first.

## Workers

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up. Once it has started, you
(or its manager, through you) bring up **workers**: agents, each with one task, that join the workspace's room.

```bash
doz worker add demo --task "list the files"                 # bot1, the run's: fenced on this Mac, gone when the run ends
doz worker add demo helper --task "work on the project"     # helper, a lasting identity of the workspace
doz worker add demo --from-bot otto --task "review the PR"  # one of your Agents / Bots as a worker
doz worker add demo carl --isolation sandbox --cpus 2 --memory 2G --task "build it"   # in a Sandbox of its own
doz worker ls demo                                          # every agent: where it runs, what isolates it, its state, its task
doz worker end demo bot1                                    # its session ends; the run's leaves chat, a lasting one is kept
doz worker reset demo helper --yes                          # clear what Dozable keeps of helper's memory
doz worker add demo --task "list the files" --dry-run       # what it would be, or what would be refused — nothing added
```

`doz worker add demo reviewer --task "Review the fix" --request-id r-2` can be run again safely: the same id and
arguments give the first answer again and add no second reviewer ([Retrying safely](#retrying-safely)).

A worker joins the workspace's room, is told its task in its START file, and says in the room that it is up — Dozable
posts nothing there itself. While the workspace is still setting up, `worker add` refuses and says to start it first;
nothing is made. To have workers from the start, declare them when you make it: `doz workspace new demo --brief … --worker
"list the files"` records the worker, and `doz workspace start demo` starts it.

- **Its name — and how long it lasts.** Give it one (`doz worker add demo helper …`) and it is a **lasting** identity of
  the workspace: when its session ends it is kept, with its memory, and comes back as itself. Leave it out and it is the
  first free `bot1`, `bot2`, …: it belongs to the **run**, and goes when its session ends or its run finishes. A worker
  declared at `new` belongs to the run too. `--from-bot otto` makes it that Agent / Bot: its name, token, skills and
  instructions.
- **Where it runs** — the narrowest place unless you say otherwise: **fenced** on this Mac (the default; its session is
  `demo-bot1`), **sandbox** (a Sandbox of its own, `demo-carl`, when you say so or the workspace's or the bot's default is
  a Sandbox; `vm` is the same), **in a running sandbox of the workspace** (`--sandbox X`: it is its own participant there, but it **shares X** —
  workers there can read each other's placeholders), or **unfenced** — acting as you — only when you name it
  (`--isolation unfenced`).
- **What it reaches.** It works in the workspace's main folder; its network is the workspace's default, else locked; it
  reaches only the chat server's port of this Mac, opens no URL and copies to no clipboard. A fenced Claude Code worker
  may use only the chat client without asking; `--allow-tool Edit` (repeatable) adds a tool.
- **Its token** never appears on a command line, in a record, a log or `--json`. A fenced or Sandbox worker holds only a
  placeholder Dozable's proxy swaps; an unfenced one reads its token from a file only you can read, deleted when it ends.
- **`worker ls`** shows every agent of the workspace — its manager, the agents you adopted and its workers — with its
  place, its isolation, what isolates it (fenced: "proxy · placeholders · guard"; Sandbox: "Sandbox · proxy · placeholders";
  unfenced: "no proxy · no placeholders · no guard · acts as you"), its network, its state and its task. It answers with
  the daemon stopped. `--all` adds the ended workers.
- **Ending one.** `doz worker end demo bot1` ends its session (or stops its own Sandbox, keeping its disk). A worker of
  the run leaves every room and its token is refused from then on; its messages keep its name, and its name is free
  again. A lasting one stays an identity of the workspace and a member of its rooms, with its memory; its token is
  refused, and `doz worker add demo helper --task …` brings it back as itself with a new one. A bot's token is kept and it
  stays in the room. `--rm` deletes its session's record or its Sandbox too.

`doz workspace manager stop` stops only the manager; workers go on until you end them. `doz workspace stop` stops every
agent, workers included.

### Identities and sessions

Every agent of a workspace is an **identity** — who it is: its name, its role, its kind (Claude Code, Codex), its place
in chat and its memory — and, while it runs, a **session**: its program in a place. The two come and go apart:

| | An identity of the workspace (lasting) | An identity of the run |
|---|---|---|
| Which | a worker added with a name, a bot, the manager, an adopted agent | a worker added with no name (`bot1`), one declared at `new` |
| `doz worker end` | its session ends; it is kept, with its memory | it goes with its session |
| `doz workspace down` (finish) | kept, with its memory; its token refused until its next start | it goes with the run |
| `down --purge` | retired: its memory removed, its token refused for good | — |

- **Its token** is new at every start — `doz workspace start`, `run`, or a wake of a stopped session — and the one before
  is refused from then on; `doz workspace state W --json` shows when it was issued, never the token. If you take an
  identity's token yourself (`doz chat token NAME --new`), it is yours: Dozable no longer replaces it at a start or at
  `down` (taking it again does).
- **Its memory.** A fenced session's agent folder is cleared each time it opens (its conversations kept), so Dozable
  keeps a lasting identity's memory when its session stops, sleeps or ends, and gives it back to its next fenced session.
  An unfenced one uses your own agent folder, and a Sandbox keeps its memory on its disk: Dozable neither copies nor
  removes either. Only `doz worker reset W NAME --yes` (refused while it runs) or `down --purge` removes what Dozable
  kept — `--purge` only after copying it into the store's archive and checking the copy. Switching an agent between
  fenced and unfenced in a space file keeps it, and says so.
- **What shows it.** `doz workspace state W` lists the identities (role, kind, lasting or the run's, memory, when the
  token was issued) and the sessions (whose, where, its state, since when); with `--json`, `identities: [{name, id, role,
  kind, lifetime: "workspace" | "run", memory: {present, files, bytes, path}, token: {issuedAt}}]` and `sessions:
  [{identity, place, state, since}]` beside the `agents` it always had. `doz worker ls` and `doz workspace show` add each
  agent's lifetime and the lasting identities kept with no session; `doz worker add --json` answers its `identity`.

**A look first.** `doz worker add … --dry-run` runs the add's own checks and says what it would do — the worker's name, its
program and account (by name: `mac` is this Mac's own login), where it runs and what isolates it, its folder, network and
rooms — or the first thing it would refuse, in the add's own words, and prints the command that adds the same worker.
Nothing is added and no daemon is started (with none running, whether its place is free is checked again when you add).
A task over 1 KiB goes in a file: the command reads it with `--task="$(cat task.txt)"`.

**In the dashboard.** On a workspace's **Agents** tab (or the side panel's **+ Worker**, or an agent's ⋯), **Add a worker**
opens its page (`#/w/NAME/agents/new`): the agent program (Claude Code or Codex), its name (the next `botN` shown), the
account it would use (shown, not chosen), its one task, the rooms (the main one always), who it is (anonymous, or one of
your Agents / Bots that is not live in another workspace) and where — a place of its own, or a new session in a running
sandbox of the workspace — and **where it runs**: a table of Sandbox, fenced, unfenced and cloud (later) side by side —
what each reaches of your files, network and keys, what controls it, what it costs, whether it has the Mac's tools,
sleeps with its programs kept or asks for approvals. Fenced is chosen for you unless the workspace's or the bot's default
is Sandbox; **unfenced is never chosen for you**, and adding one needs the tick "It acts as you: your files, Keychain and
network". Each field is checked as you type — the same check as `--dry-run` — and a refusal shows beside its field;
**Show the command** is the command `--dry-run` prints. **Add and start** adds it; it then appears in the room and on the
panel, and says it is up. **End…** in a worker's ⋯ ends it (ticked; its place is kept). Adding and ending are this Mac's
own browser only — another computer sees the commands.

**Where an agent runs.** Every isolation chip in the dashboard (Sandbox, fenced, unfenced, elsewhere) opens **the
isolation guide** (`#/guide/isolation`) at that choice: the four choices in order of isolation, what each is for and not
for, and the commands of today. Whatever the choice, your keys never go inside a Sandbox or a fenced session; an
unfenced agent is the one exception, and the reason it always asks. An agent elsewhere is not isolated by Dozable.

## Units of work: runs, the journal and lessons

A **run** is one unit of work, from its start to its finish. The first `doz workspace start` opens the first one, with
the brief as its goal; after a finish, `doz workspace run W "goal"` opens the next, and `doz workspace finish W` closes it
and archives it. One is open at a time. `doz workspace reopen W` is the old name of `run`, so it opens one too: a `run`
straight after it is refused (exit 3, `run-open`).

Each run has a **journal** — typed entries you and the agents write as the work goes (a task, a review against a
criterion, a finding, the outcome) — and from a finished run you can propose a **lesson**; once you approve it, every
later run carries it. All of it is on its own page: [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md),
with a worked example in [Bring your own process](42-bring-your-own-process.md).

## What agents may do

What an agent may do in Dozable — start a worker, sleep the workspace, reach a folder beyond its own — is one list of
**permissions**, each answered **allow**, **ask** or **never**. (What a sandbox's *network* may reach is a different list,
`doz net permissions` — [permissions and the network](10-permissions-and-network.md).)

- A **role** bundles answers: `manager`, `worker`, `member`, `decider`, `admin`, and the presets `cautious-manager` and
  `trusted-manager`. An agent's role in a workspace is the one the workspace gives it — its manager is `manager`, its workers
  and adopted agents `worker` — shown "worker (from the workspace)"; nothing is written for it.
- A **grant** gives a role, or one permission's answer, in exactly one scope — `--everywhere`, `--in W`, or one room
  `--room W/R` — optionally `--until` a date. A grant is for an agent or a bot, never for a place: `doz grant desk …`,
  where `desk` is one of the workspace's places, is refused (exit 2) — grant the agents in it.
- A **ceiling** is the most an agent may ever get: this Mac's (`--mac`), a workspace's (`--in W`), a bot's (`--bot B` —
  [Agents / Bots](38-agents-and-bots.md)), and above them all Dozable's own, which nothing can grant: another workspace,
  Dozable's settings, a new account, key or token, the ceilings themselves.

```bash
doz permissions show --roles                     # the role table: ✓ allow · ? ask · ✕ never · · says nothing
doz permissions show demo                        # each agent's answers (✎ a grant · ▲ a ceiling), the grants and ceilings
doz permissions show demo --agent bot1           # every permission: its answer, where it comes from, where it is enforced
doz grant mira keychain.use=never --in demo      # one answer, for mira in demo (the same as doz permissions grant)
doz grant otto worker --room demo/review --until 3d
doz permissions revoke otto worker --room demo/review
doz permissions ceiling --mac sudo=never         # this Mac's ceiling, for every agent
doz why bot1 folder.read --in demo               # which of the five steps decided
```

`doz why` prints the five steps an answer is found in, and what decided:

```text
bot2 · folder.read · in myapp-tests
1 any never               none (no ceiling, no never in any scope)
2 permission grants        none (room, workspace, everywhere)
3 roles here               worker (myapp-tests): ask
4 —
5 bot2's ceiling           none set: no cap
→ ask · an Ask to ada (owner); mira is not a decider here
```

1. **Any never wins** — any ceiling's, or your explicit never in any scope that applies.
2. A **permission grant**, the most specific scope first: a room beats its workspace, which beats everywhere (and within one
   scope, the agent beats its bot, which beats a role).
3. The **roles** in the most specific scope that has any, combined to the more permissive answer.
4. **Nothing says anything**: ask. `sudo` and `isolation.unfenced` fail closed: never.
5. The strictest **ceiling caps** it: an ask ceiling turns allow into ask.

**Permissions constrain agents, never you.** Nothing you do — in a terminal or in the dashboard — is checked against them,
not even your own nevers and ceilings. An agent reaches Dozable only through the run journal and the work description
(with `dozchat` — [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md#what-agents-may-write)), and there they are enforced: `show` says "yes — through dozchat" for those permissions and "not
yet — an agent reaches only the journal and the work description" for every other (an unfenced agent's: "promise — acts
as you"). Asks come later; until then, an answer of ask is
a refusal for an agent. Opening a run needs `run.open` (`run` and `reopen`) and finishing one `run.finish`, both off for
an agent until you grant them (`doz grant mira run.open=allow --in demo`); an older grant of `workspace.finish` (its
old name) still answers for both in this release, a never on it included. The owner role is yours and is never granted; `admin` is given everywhere only; deciders are made
in chat, by you only. Every change is recorded, by you, in the store's `grants/log.jsonl` (and a workspace's grant in its
log).

## Changing one

```bash
doz workspace edit demo --prompt-file brief.md      # a new brief
doz workspace edit demo --add-ref https://example.com/spec --remove-ref ~/notes.md
doz workspace edit demo --add-folder ~/code/site:ro --remove-folder ~/code/old
doz workspace edit demo --make-room                 # its room, now that chat is on
doz workspace rename demo launch-video              # its room keeps its own name
```

## From a file

A workspace can be described in one file kept beside the work, `NAME.workspace.yaml`: `doz space plan -f FILE` shows what
setting it up would do, and `doz space config FILE` the file merged with what it extends. See
[Space files](39-space-files.md).

## Where it is kept

Each workspace is a folder in the store, `workspaces/NAME/`: `workspace.json` (the record), `brief.md` (the brief) and
`log.jsonl` (what happened). They are readable by you alone. The log never holds the brief's text or a folder's path.

Exit codes are as everywhere: 2 not found · 3 not fully set up (or still setting up, for a worker), or its manager is
running · 4 already exists (or already in a workspace, a name taken, or the bot runs in another live workspace) · 6 the
daemon or chat is not available · 64 usage · 65 an invalid file or value. `doz help exit-codes` lists them all.
