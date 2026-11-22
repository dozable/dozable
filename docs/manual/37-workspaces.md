# Workspaces

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up.

A *project* is something else: a folder (usually a repository) with its sandbox settings in `doz_project.yaml` (see
[Projects](04-projects.md)). A workspace can work on several projects' folders, or on none.

Nothing you already have moves by itself. Your sandboxes and your sessions on this Mac are **loose agents** until you
adopt them into a workspace, and adopting one changes only the workspace's own record: the sandbox and the session stay
exactly as they were. The dashboard shows them (below, [In the dashboard](#in-the-dashboard)), makes and starts a
workspace in this Mac's own browser ([The New workspace wizard](#the-new-workspace-wizard)), and leaves the rest of what
changes one to the command line.

## Making one

```bash
doz workspace new demo --prompt-file brief.md --folder ~/code/demo
```

- `--prompt-file FILE` is the brief: what the work is for, in your words (at most 256 KiB; `-` reads it from standard
  input). `--ref PATH` or `--ref https://…` adds a reference to it (repeatable).
- `--folder DIR` adds a folder it works on (repeatable); the first is the main one. `DIR:ro` makes one read-only. Folders
  are optional: `doz workspace new notes --prompt-file brief.md` makes a workspace with none.
- `--adopt NAME` (or `--adopt @mac/SESSION`) adopts a sandbox or a session at once (repeatable).
- `--new-folder` makes an empty folder `~/doz-workspaces/NAME` (in your projects folder, `defaults.projects_dir`) and
  makes it the main folder. It is offered, never forced: with no folder the manager works there anyway.
- `--from-project` fills in the network preset from the project file in the main folder (it needs a `--folder`); the
  file is only read, never written. A `--network` that differs from it is refused.
- `--manager BOT` makes one of your Agents / Bots its manager (see [The manager](#the-manager) below). Nothing is
  started yet.
- `--worker-isolation fenced|vm` is where its new workers run unless `doz worker add` says otherwise (fenced by default;
  never unfenced by default — a worker is unfenced only when you name it).
- `--network locked|standard|open` is the network its agents get (locked by default); the room is always added.
- `--dry-run` shows what would be made and makes nothing: a few lines, everything that would be refused, what the start
  would still need once it is made (each with its fix), and the commands that make it — the brief as a heredoc you can
  paste. It never starts the daemon; it exits 0 when nothing is refused, else as `new` would.
- `--start` starts it as soon as it is made (`doz workspace start NAME`). If the start is refused, the workspace stays
  made and setting up, and the refusal says what is missing.

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
where each goes), the Claude account by name, and what it can drive. A fenced or micro VM manager talks in the room only — it
cannot drive Dozable; an unfenced one **acts as you**: it runs doz and anything else as you. Last, its **permissions** — how
many answer allow, ask and never, by its role and your grants — and its **ceiling**, each cap and whose it is ("What agents
may do", below). They are read only there and in the dashboard, and none is enforced yet.

**Network** gathers what the workspace can reach in one place. What an agent was refused lately is known while the daemon
runs; `doz net allow` with the command shown allows it for that agent. Nothing it prints is a secret: a held secret is a name,
where it goes and a fingerprint; the values stay in your keychain.

**Folders** lists the files changed in each folder since the work started — `A` new, `M` changed — by their file times.
Dozable never runs a program, git included, in a folder an agent writes in order to look at it (git would run that folder's
own settings as you), so it says which folder changed, never which agent changed a file, and a deleted file is not seen. A big
folder is looked at only up to its limits (the list says when it was cut short). Restore points are a micro VM agent's: one
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

**New workspace** on Home (or the **+** beside **Workspaces** in the sidebar, or **New workspace with this bot** on an
Agent / Bot) opens a wizard over the page, `#/new-workspace`. It asks in four steps:

1. **The work.** The prompt becomes the brief; references (paths or links, typed or chosen with **Choose…**) are added
   to it. The name is suggested from the prompt's first words. Folders are optional — each read-write or read-only, the
   first the main one — and **A new empty folder** makes `~/doz-workspaces/NAME`. When the main folder holds a
   `doz_project.yaml`, its network preset is used to fill in choices (the file is never written). **Start from** offers
   a few built-in starting points (Remotion video, Swift tests, Mac admin, Research, Blank); templates you make come
   later.
2. **Who manages.** One of your Agents / Bots, or **No manager — I manage** (you drive). **A new agent / bot…** opens the
   Agent / Bot editor and brings you back with the new one chosen; the wizard keeps everything you chose. **Change here**
   opens that bot's own page — a change there changes it everywhere.
3. **Where it runs.** This Mac (the cloud comes later). The manager runs fenced by default, or in a micro VM; **unfenced**
   only when you pick it and confirm that it acts as you — then **acts as you** shows on the choice, in the review and in
   the plan. New workers run in a micro VM or fenced, never unfenced by default. The network preset: Locked, Standard or
   Open, with the room always added.
4. **Grants & when.** It says plainly what limits apply today (none yet: an unfenced manager acts as you; a fenced or VM
   one can only talk in the room). The room it gets — made, an existing room of no workspace, or none — and when it
   starts: **Right now** (Create and start) or **Later — keep it setting up** (Create, keep setting up). The plan lists
   what will be made, what is still missing for the start (each linking to its step, its command under **Show the
   command**), and **Copy as doz commands** gives the same workspace in a terminal.

Every change asks Dozable what it would make, so what is missing is shown as you go — each step shows how many things it
still has to set up — and nothing is written and no daemon is started until you create it. **Create and start** is
disabled while anything is missing. If the start is refused after the workspace is made, its page opens anyway, still
setting up, saying what is missing. A brief too long for the page (over 15 KiB) is made with the copied commands
instead. Only this Mac's own browser makes or starts a workspace; another computer sees the command to run in a terminal
on the Mac.

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

A workspace's **Agents** tab (`#/w/NAME/agents`) lists every agent — in a micro VM, fenced or unfenced on this Mac, or
elsewhere — side by side, and each opens its screen in the workspace (`#/w/NAME/agent/AGENT`): its sandbox's or session's
page with the workspace around it ([The dashboard](06-the-dashboard.md#a-workspaces-page)). An agent of a workspace may be an Agent / Bot — a lasting identity in chat (see
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

## Sleep, wake, finish, archive and delete

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up. Once it has started, the
whole workspace — every agent at once — can be put to sleep, woken, finished, archived and deleted:

```bash
doz workspace sleep demo        # every agent asleep: memory given back, conversations kept
doz workspace wake demo         # back in the same sandboxes and conversations
doz workspace finish demo       # the work is done: everything stops; the room and tokens are kept (asks first)
doz workspace reopen demo       # finished → asleep until you wake it
doz workspace archive demo      # put away: its rooms read-only, its anonymous workers retired (type its name)
doz workspace restore demo      # archived → finished, its rooms writable again
doz workspace delete demo       # its record gone; finished or archived only (type its name)
```

**Check, then ask.** Each shows first what it would do to each agent — where it runs, what it is now, what it becomes,
how it comes back — what is kept and what goes (with sizes), how many agents change at once, and what would stop it. With
`--dry-run` it stops there: nothing changes and no daemon starts. Then it asks: nothing for sleep, wake, reopen and restore,
a yes for finish, and the workspace's name typed for archive and delete. `--yes` skips the question (a script needs it).
It acts only on what it showed you: if the workspace changed in between, it is refused and says so.

| | A micro VM | Fenced on this Mac | Unfenced on this Mac | Elsewhere |
|---|---|---|---|---|
| **sleep** | hibernated: its memory given back, the same programs and screens | ended, its conversation kept | ended; its token file deleted | untouched — it runs on its own machine |
| **wake** | woken (one shut down boots and its agent continues) | the same conversation | the same conversation; its token file written again | untouched |
| **finish** | shut down, its disk kept | ended, its conversation kept | ended | untouched; it stays in the room |

A program that has no conversation to resume (one that is not an agent) starts fresh when it wakes. A workspace stays
asleep until you wake it; messages wait in the room meanwhile.

**Finish** is "the work is done": nothing runs afterwards, and no worker can be added — but the rooms stay writable and
every token is kept, so `reopen`, then `wake`, picks it up again. **Archive** finishes it, makes its rooms read-only (their
history stays readable) and retires its anonymous workers — their tokens are refused from then on; a bot keeps its token
and its place in the rooms. `restore` opens the rooms again and leaves it finished; a retired worker stays ended.

**Delete** works only on a finished or archived workspace (`doz workspace finish demo` first), and never while any of its
agents still runs. It removes the workspace's record, brief and log, forgets its sessions on this Mac, and lets its
adopted sandboxes and sessions go loose again. Its rooms stay, archived with their history — the chat server cannot delete a
room — and so do its bots and their tokens, its templates and every folder. It cannot be undone.

**Nothing on disk goes unless you say so.** `--remove-sandboxes` (archive, delete) also removes the sandboxes Dozable made for
this workspace — never one you adopted, or one a worker shares — keeping a template of each first (`--no-keep-templates` to
skip it); `doz workspace restore` then names the template rather than making the sandbox again. `--bin-folders` (delete)
moves the workspace's folders to the Bin, never deletes them, and refuses your home folder, Dozable's store and a folder
another workspace or sandbox uses, naming it.

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
doz worker add demo --task "list the files" --dry-run       # what it would be, or what would be refused — nothing added
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

**A look first.** `doz worker add … --dry-run` runs the add's own checks and says what it would do — the worker's name, its
program and account (by name: `mac` is this Mac's own login), where it runs and what isolates it, its folder, network and
rooms — or the first thing it would refuse, in the add's own words, and prints the command that adds the same worker.
Nothing is added and no daemon is started (with none running, whether its place is free is checked again when you add).
A task over 1 KiB goes in a file: the command reads it with `--task="$(cat task.txt)"`.

**In the dashboard.** On a workspace's **Agents** tab (or the side panel's **+ Worker**, or an agent's ⋯), **Add a worker**
opens its page (`#/w/NAME/agents/new`): the agent program (Claude Code or Codex), its name (the next `botN` shown), the
account it would use (shown, not chosen), its one task, the rooms (the main one always), who it is (anonymous, or one of
your Agents / Bots that is not live in another workspace) and where — a place of its own, or a new session in a running
sandbox of the workspace — and **where it runs**: a table of micro VM, fenced, unfenced and cloud (later) side by side —
what each reaches of your files, network and keys, what controls it, what it costs, whether it has the Mac's tools,
sleeps with its programs kept or asks for approvals. Fenced is chosen for you unless the workspace's or the bot's default
is micro VM; **unfenced is never chosen for you**, and adding one needs the tick "It acts as you: your files, Keychain and
network". Each field is checked as you type — the same check as `--dry-run` — and a refusal shows beside its field;
**Show the command** is the command `--dry-run` prints. **Add and start** adds it; it then appears in the room and on the
panel, and says it is up. **End…** in a worker's ⋯ ends it (ticked; its place is kept). Adding and ending are this Mac's
own browser only — another computer sees the commands.

**Where an agent runs.** Every isolation chip in the dashboard (micro VM, fenced, unfenced, elsewhere) opens **the
isolation guide** (`#/guide/isolation`) at that choice: the four choices in order of isolation, what each is for and not
for, and the commands of today. Whatever the choice, your keys never go inside a micro VM or a fenced session; an
unfenced agent is the one exception, and the reason it always asks. An agent elsewhere is not isolated by Dozable.

## Runs and their archive

Each start (or reopen) to its finish is a **run**. `doz workspace finish W` closes the workspace's own rooms to new
messages — members can still read them; `doz workspace reopen W` opens them again — and writes the run's evidence into
Dozable's store: its messages, each agent's conversations and last screen, the usage and a timesheet. Nothing is removed,
and no program is run in your folders (commits are not collected). `--no-archive` writes none.

```bash
doz workspace runs W                 # each run, its archive and its totals
doz workspace runs W --archive RUN   # write a run's archive again
```

## What agents may do

What an agent may do in Dozable — start a worker, sleep the workspace, reach a folder beyond its own — is one list of
**permissions**, each answered **allow**, **ask** or **never**. (What a sandbox's *network* may reach is a different list,
`doz net permissions` — [permissions and the network](10-permissions-and-network.md).)

- A **role** bundles answers: `manager`, `worker`, `member`, `decider`, `admin`, and the presets `cautious-manager` and
  `trusted-manager`. An agent's role in a workspace is the one the workspace gives it — its manager is `manager`, its workers
  and adopted agents `worker` — shown "worker (from the workspace)"; nothing is written for it.
- A **grant** gives a role, or one permission's answer, in exactly one scope — `--everywhere`, `--in W`, or one room
  `--room W/R` — optionally `--until` a date.
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
not even your own nevers and ceilings. And none is enforced yet: no agent can drive Dozable, so `show` says "not yet — no
agent can drive Dozable" (an unfenced agent's: "promise — acts as you"). Asks come later; until then, an answer of ask is
a refusal for an agent. The owner role is yours and is never granted; `admin` is given everywhere only; deciders are made
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

A workspace can be described in one file kept beside the work, `NAME.space.yaml`: `doz space plan -f FILE` shows what
setting it up would do, and `doz space config FILE` the file merged with what it extends. See
[Space files](39-space-files.md).

## Where it is kept

Each workspace is a folder in the store, `workspaces/NAME/`: `workspace.json` (the record), `brief.md` (the brief) and
`log.jsonl` (what happened). They are readable by you alone. The log never holds the brief's text or a folder's path.

Exit codes are as everywhere: 2 not found · 3 not fully set up (or still setting up, for a worker), or its manager is
running · 4 already exists (or already in a workspace, a name taken, or the bot runs in another live workspace) · 6 the
daemon or chat is not available · 64 usage · 65 an invalid file or value. `doz help exit-codes` lists them all.
