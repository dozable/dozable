# The workspace model — four layers, one document, a record, one controller

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md), the workspace code in
[workspaces.md](workspaces.md), what a person reads in the manual ([Workspaces](../manual/37-workspaces.md),
[Space files](../manual/39-space-files.md)). This page is the model every workspace change is judged against: model v3,
accepted by the owner on 2026-11-23, with its review folded in.

**The model is ahead of the code.** Every section says what is **built** — what 0.52.43 does (0.52.45 for the conditions per layer, 0.52.46 for the run verb, 0.52.47 for the work description and proposals), with the code that does it —
and what is **coming**, by the stage that brings it. A sentence that does not say "coming" describes today. Never move a
line from coming to built without the code, and never describe coming behaviour in the manual.

## The stages still to build

| Stage | What it brings | After |
|---|---|---|
| **PLACE** | Place as an entity in the record (`isolation`, view, network, credentials, secret references); VMs as places; a fenced place a policy; `state` says the per-place fact | — |
| **IDSESS** | `WorkspaceAgent` split into Identity (L1) and Session (L2); declared workers become identities; named workers persist | PLACE |
| **SP32** | space/3.2: `lives: workspace \| run`, `places:`, `where: PLACE`, `brief.criteria`, `brief.addenda`, the migration notes | PLACE, IDSESS |
| **LC2** | `down` ≠ `finish` (D4 reversed): `finish` closes the run and removes the run's things; `down` releases allocations and keeps data; `--purge` for every workspace; `WorkspaceDown`; the dashboard's Finish and Down | LC1, SP32 |
| **UOW-MVP** | bring your own process: the run's primitives — part A, the work description's addenda, proposals and their permission ids, is built (0.52.47); part B, the run journal (journal/1) and evidence hashed when attached, is built (0.52.48) | LC1 |
| **PLAYBOOKS** | the four recommended processes as playbooks (permission presets, journal kinds, a way to apply one; the quality loop's gates opt-in) — supported and tested, never required | UOW-MVP |
| **HOOKS** (optional) | a workspace told of its run's events by a command or an address — a proposal only, to be reviewed again before any work | PLAYBOOKS |

COND, one condition per layer in `state`, is built (0.52.45): "One phase, and one condition per layer" below. LC1, the
`run` verb, is built (0.52.46): `doz workspace run W [GOAL]`, one run at a time, `reopen` its old name, `up` opening a run
each time none is open until LC2 (`--no-run` opens none) — L3 below and workspaces.md, "The run verb". UOW-MVP's part A,
the work description, is built (0.52.47): addenda, proposals through Dozable's own Ask, `description.*` and the `reviewer`
role — "The unit of work" below and workspaces.md, "The work description and proposals". UOW-MVP's part B, the run
journal, is built (0.52.48): journal/1 with its corrections, kinds, refs, evidence, follow (`wseq`) and wait, and the
`journal.*` and `evidence.attach` permissions gating — [journal.md](journal.md). Later,
only if a user asks: skills and playbooks a proposal may change, and comparing runs.

## The four layers

A workspace is a stack of four layers, each with one pair of verbs. A verb needs the layer below it to exist; taking a
layer down first undoes everything above it. Outside the stack are this Mac's shared services, which a workspace uses and
never owns.

```
 L3  A RUN            run → finish        a unit of work: goal, criteria, tasks, turns observed, the run's own
                                          resources, reviews, outcome, evidence
 L2  HOT              start / stop        sessions: an identity's program running in a place
                      sleep / wake
 L1  PROVISIONED      up → down           places (vm | fenced | unfenced), owned folders, the room, identities
                                          (managers, workers, reviewers) — their ALLOCATION
 L0  THE WORKSPACE    create → delete     id and name, the document and its revisions, the record, the archive, the
                                          log, the owner's grants, the brief — and the workspace's DATA
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
     THIS MAC         (their own)         accounts, the bot directory, images and bases, the chat server, the
                                          timeline, the dashboard, the credential vault, external folders, loose
                                          sessions and sandboxes
```

The stack is explanatory; the space editor draws the document (places holding identities, folders as mounts, externals
apart), not these slabs.

| Layer | Verbs in the model | Built in 0.52.43 | Coming |
|---|---|---|---|
| L0 | `create` · `delete`; `archive` · `restore` | `doz workspace new` (and the wizard, and `up -f` for a space file) · `delete` (finished or archived only); `archive` · `restore` (`WorkspaceVerb`, `WorkspaceLifecycle.swift`) | `create` as the word; a stable id; the revision store (today the document is generated, `RecordDocument.generate`) |
| L1 | `up` · `down` (`--purge`) | `up -f FILE` for a workspace a space file made only (one made without a file: exit 4, `SpaceUp.plan`); `down` **is** `finish` for every workspace (`runWorkspaceFinish`, `WorkspaceLifecycleCommands.swift`); `--purge` refused for one made without a space file | LC2: `down` releases L1 and keeps data, for every workspace; `up` for every workspace |
| L2 | `start` · `stop`; `sleep` · `wake` | all four (`workspaceStartOnce`, `wakeStoppedAgents` in `HostCore+WorkspaceManager.swift`; `lifecycleStop`, `lifecycleSleep` in `HostCore+WorkspaceLifecycle.swift`) | IDSESS: sessions as records of their own |
| L3 | `run` · `finish` | `doz workspace run W [GOAL]` (0.52.46, `workspaceRunOpen` in `HostCore+Runs.swift`): one run at a time (`run-open`, exit 3), a finished workspace reopened first, the goal (else the brief) posted as your message, then the sessions started unless `--no-start`; it records its goal, `goalFrom`, `source`, `follows`, `openedBy` and the work description's revision. A run also opens at the first `start` (`workspaceStartOnce`, only while `flags.startedAt` is nil), at the CLI's `reopen` (run's old name) and the dashboard's Reopen (`lifecycleReopen`), and at an `up` that finds none open (`SpaceUp`'s `workspace-reopen` / `workspace-start` steps; `--no-run` opens none); `finish` (and `down`) closes it | LC2: `up` opens the first run only, once; `start` starts sessions only |

### L2 today: start, stop, sleep, wake

| | Built in 0.52.43 |
|---|---|
| `start` | the set-up check, the brief posted once (the first run opened just before it), the manager started; then (762, F2) every other agent a `stop` **or a `sleep`** left down brought back exactly as `wake` does — under the workspace's gate, named in the answer's `woke` (`wakeStoppedAgents`) |
| `stop` | every running agent's process ends: a sandbox shut down with its disk kept, a session on this Mac ended with its record, conversation and launch secrets kept (an unfenced one's token file deleted); nothing removed; `stoppedAt` set, logged `stopped` (`lifecycleStop`) |
| `sleep` | a sandbox hibernated (the same programs and screens); a session on this Mac ended with its conversation kept (no snapshot on this Mac) |
| `wake` | the same sandboxes and conversations; one that was shut down boots and its agent continues |
| stopped ≠ asleep | with nothing running, a workspace whose last workspace-wide change was a stop reads **stopped**, else **asleep** (762, F3: `WorkspaceState.derive`'s `Input.stopped`, `HostCore.lastDownWasStop`; `WorkspaceConditionsBuilder.phase` in `WorkspaceRecordState.swift`) |

### The verbs that cross layers today

| Verb | Built in 0.52.43 | In the model | Stage |
|---|---|---|---|
| `finish` | closes the run (rooms closed to new messages, agents stopped, the archive written, the run closed, `finishedAt`); a workspace made without a space file removes nothing; the dashboard's Finish never removes what a space file made | L3 only: closes the run and removes what the run owns; leaves workspace-owned sessions hot (`--stop` to cool them) | LC2 |
| `down` | **the same as `finish`** (D4, since 0.52.36; one CLI path, `runWorkspaceFinish`, answer `WorkspaceFinish`); for a space file's workspace, then by its lifetime (above); `--purge` refused for one made without a space file | L1: releases the allocations, keeps the data, finishes an open run first and says so in the plan; answers `WorkspaceDown` | LC2 |
| `up` | a space file only: apply, make what is missing, then the run — **a new run each time none is open** (reopened when the space is down; 0.52.46), unless `--no-run` — and its agents | apply + provision + `start` + the first run, once only; then `run` | LC2 |
| `reopen` | the CLI's is `run`'s old name (0.52.46: a one-line note on a terminal; `--dry-run` and `--if-plan` keep the old plan and act); the dashboard's Reopen: finished → a new run, its rooms open again, asleep until woken | folded into `run` | — (built) |
| `start` | opens the first run (only while never started) and posts the brief | starts sessions only | LC2 |

`down`'s answer (762, F7) keeps three lists apart: **kept** (only what is the workspace's own), **untouched** (the
person's folders, never made by it — `WorkspaceFinishInventory.untouched`) and **released** (adopted agents let go loose);
the text prints each on its own line (`WorkspaceFinishInventory.lines`). The `--json` `kept` still lists the untouched
and released ones too, for its locked readers; `untouched` (both answers), `released` and `savedDisks` (a space's
`SpaceActed`) are additive fields.

One `sleep` verb for both places (model decision 6.2 A): its result is "nothing running, nothing spending, back in seconds
with the conversations". On this Mac `sleep` and `stop` differ only in what comes back (`wake` resumes the conversation).
**Coming (PLACE):** `state` says the per-place fact — `asleep: hibernated` or `asleep: ended, conversation kept`.

### One phase, and one condition per layer

`doz workspace state --json` carries ONE `phase` (`setting-up`, `running`, `asleep`, `stopped`, `finished`, `archived`),
each agent's condition and `conditions.ready`; a space's `SpaceState.run.phase` is literally `up` / `down`
(`SpaceState.swift`, `WorkspaceRecordState.swift`) — three verbs' words on three layers (D8). **Built in 0.52.45
(COND):** beside `ready`, never replacing it, `conditions` carries one condition per layer (`LayerConditionsBuilder`,
`WorkspaceRecordState.swift`; workspaces.md, "One condition per layer"):

| Layer | Condition | Derived from |
|---|---|---|
| L1 | `allocated {value, since, reason?}` | the record's lifecycle: true from new (or up) until archive or delete; a `runs` space is released by `down` (`reason: down`), a standing one keeps it (not through `--purge`); a finish ends the run, never the allocation |
| L2 | `hot {value: all\|some\|none, sessions: {NAME: {condition, since}}}` | each agent's condition: `starting`, `running`, `asleep`, `stopped`, `ended`, `unknown` |
| L3 | `run {open, id?, since?}` | `WorkspaceRecord.openRun`, else the last run |
| L0 | `archived {value, at?}` | `flags.archivedAt` |

`ls --json` rows carry `{allocated, hot: {value}, run}`. `phase` stays one release as the derived summary. **Built in
0.52.46 (LC1):** the run's own state, `conditions.run.state` — `open` or `closed` (absent before the first run).

## Data versus allocation

A workspace-owned resource is two things with two lifetimes:

- its **allocation** — a booted VM, a fence's proxy, an issued token, an open room — lives `up` → `down` (L1);
- its **data** — a VM's disk, an owned folder's contents, an identity's memory, the room's history — lives with the
  workspace (L0): `create` → `down --purge` or `delete`.

This is Compose's `down` (containers go, volumes stay) and `down -v`. "What survives a `down`?" — everything the workspace
owns, except what is running. Two exceptions, from the format author's review: the **room** is closed at `down` and
**re-opened** at `up` (the same id, the history continuous), removed only at `--purge`; an **owned folder** is
**released** at `--purge` (off the record, left on disk), never deleted. `plan` and `up` should show what `down` keeps on
disk (VM disk sizes), since kept data costs disk.

**Built in 0.52.43**, by what today calls the lifetime (below):
- **standing** (every workspace made without a space file, and a space file saying `x-dozable: {lifetime: standing}`):
  `down`/`finish` removes nothing it owns but what says `lifetime: run` itself; its scratch folders are kept; its rooms are
  closed and kept with their history and id (`SpaceUp`'s room step: "closed: kept with its history and id"), and `up`
  re-opens them (`lifecycleReopen` takes them out of the closed set). The nearest thing to the model today.
- **runs** (a space file's default): `down` removes what the space made for the run — its agents, scratch folders and
  rooms (a tombstone kept) — each only after its archived copy is hash-checked; the next `up` makes the main room again,
  as a new room. What `persist:` names is kept: its rooms closed and re-opened, its fenced agents' memory captured
  (`SpaceMemory`, `<store>/workspaces/W/memory/<agent>/`).
- **A sandbox's disk is never removed without a copy** (762, F5): wherever `down` removes a sandbox — a run-lifetime agent's
  own, or with `--purge` a persisted one — its disk is first saved as an image (`saveDiskBeforeRemoval`,
  `HostCore+SpaceAct.swift`), named in the answer's `savedDisks`; a save that fails removes nothing.
- `--purge` (a space file's workspace): its rooms, sandboxes (disk saved first) and kept memory removed; its folders
  released, never deleted.
- Tokens: `finish` keeps every token (so `reopen` then `wake` works); a run-lifetime anonymous worker's token goes with it.

**Coming (LC2):** the split for every workspace — `down` releases allocations (VMs stopped, tokens revoked, the room
closed) and keeps data; `finish` alone removes the run's things. **Coming (IDSESS):** a workspace-owned identity's token is
revoked at `down` and rotated at each `start` (a token that outlives its sessions is new exposure).

## Persistence by owner

One question per owned resource: **who owns it?**

| Owner | Made at | Allocation released at | Data removed at |
|---|---|---|---|
| the run | `run` | `finish` | `finish`, after its archive verifies |
| the workspace | `up` | `down` | `down --purge` or `delete`, after its archive verifies (owned folders: released, never deleted) |
| nobody (`external:`) | — | — | never: no verb makes or removes it |

A dependency rule: nothing that lives with the workspace may need something that lives with the run (a workspace identity
`where:` a run-owned place) — 65 with a fix; the reverse is fine.

**Built in 0.52.43 — three spellings for this one idea:** `x-dozable.lifetime: standing | runs` at the top, a per-resource
`x-dozable.lifetime: run` inside a standing file, and `persist:` inside a runs file ("Lifetime", below). The lifetime is
held under `x-dozable`, never required, and a top-level `lifetime:` in a 3.1 file is refused (`SpaceDozable.swift`).

**Coming (SP32):** `lives: workspace | run` on any owned folder, identity, place or room (65 on an `external:` one), plus an
optional top-level default; the default is per version — space/3 with nothing is `run`, space/3.2 with nothing is
`workspace`, so an old file never changes meaning. `doc` writes the top-level `lives:` always and a per-resource one only
where it differs. Migration, read for one release with a note: `lifetime: standing` → `lives: workspace`, `lifetime: runs`
→ `lives: run`, `persist: {…}` → `lives: workspace` on those resources, a resource's `lifetime: run` → `lives: run`.

## Place — a policy; the fence per session

A **place** is where an identity's session runs: an isolation (`vm`, `fenced`, `unfenced`), its filesystem view (mounts,
ro or rw), its network policy, its credentials (placeholders) and secret references; owned or external.

A fenced place is a **policy**; the daemon serves **one fence per session**, each built from the place (model decision
6.1 C). Two agents in one fenced place are two fences from one policy: no shared proxy state, no shared placeholders.
Grants attach to the identity or session, never to a place. An `isolation: unfenced` place enforces nothing and says so
("none: acts as you"): it may declare no view, network or credentials (65). A VM place holds several sessions behind one
proxy, as today. One shared VM place per workspace for its new workers, written by `doc` as an explicit `places:` entry.

**Built in 0.52.43:** no Place entity. A place is `AgentPlace {sandbox, mac, session, elsewhere}` on each agent
(`WorkspaceRecord.swift`); a session on this Mac is a set of constants (`MacPlace`); only a VM is an entity of its own.
Each worker gets its own place `W-NAME` (`WorkerLaunch.placeName`) — a session on this Mac, or a new sandbox — or shares
an existing sandbox (`doz worker add --sandbox`). The fence is already per session (`MacFence`; CLAUDE.md's `@mac` rule),
so 6.1 C needs no security change. An adopted sandbox is an agent's `external: {sandbox: NAME}` (space/3.1).

**Coming (PLACE):** `Place` in the record; VMs as places; fenced places as policies. **Coming (SP32):** `places:` in the
file (`sandboxes:` read as `places:` entries with `isolation: vm`), `where: PLACE` (today `mac`, `sandbox` or
`sandbox:NAME`, `SpaceValidator`), an adopted sandbox as an external place. Network precedence: the workspace's default <
the place's < the agent's, an agent's own only where enforcement is per session (fenced); in a VM it must equal its
place's (65) — the last rule is built for 3.1's agent `network:`.

## Identity and Session

- An **identity** (L1) is who an agent is: name, role (manager, worker, reviewer), kind (`claude-code`, …), a bot or its
  own participant, its token, its memory, its default place, its standing instructions (`prompt:`). Manager versus worker
  is a role, not a layer.
- A **session** (L2) is an identity's program running in a place: terminal, status, transcript, its chat token as a launch
  secret. `start`/`stop` and `sleep`/`wake` act on sessions.

**Built in 0.52.43:** both halves are one `WorkspaceAgent` (`WorkspaceRecord.swift`): the identity's fields (`name`,
`role`, `bot`, `anonymous`, `task`) beside the session's (`place.session`, `startedAt`, `stoppedAt`). A declared worker
(`WorkspaceDeclaredWorker`, `new --worker`) is already an identity with no session. An anonymous worker's participant is
a throwaway one, removed at `doz worker end`. Memory survives only for a persisted fenced agent of a space file
(`SpaceMemory`), reset by a switch between fenced and unfenced. `reviewer` is a space file's role (`SpaceFormat.roles`)
and, built in 0.52.47, a grant role too (`RoleTable`): `journal.write`, `evidence.attach` and `description.propose`, all
allow — `doz grant AGENT reviewer --in W`.

**Coming (IDSESS):** the split; named workers (`worker add W NAME`) persist, a nameless `--task` worker is run-owned; memory
kept `up` → `--purge` for every workspace-owned identity whatever its place, reset only by an explicit reset (a
fenced/unfenced switch warns instead); `WorkspaceAgent.task` becomes the identity's `prompt:`, freeing "task" for L3.

## The unit of work

A run is a unit of work, not a turn: **run → tasks → turns**. Dozable owns runs; turns belong to the agent, and Dozable
only observes them. **Bring your own process** (owner, 2026-11-23): how a run is planned, reviewed and accepted depends
on the user and the managing agent, so Dozable provides **primitives** and **permissions** and enforces no process. A
workspace's process lives in what its people and agents do with them, written down wherever they like: a brief, a
playbook skill, a template, the agent's own prompt. Built: the Run primitive, `run.open` and `run.finish` (0.52.46, LC1);
the work description, proposals, the `description.*` permissions and the `reviewer` role (0.52.47, UOW-MVP part A); the
journal, evidence and the close (0.52.48, UOW-MVP part B — [journal.md](journal.md)). The recommended processes are
**coming** (PLAYBOOKS).

**Two integrity rules**, the only fixed ones — they are about trust, not process:
1. evidence attached to a run is hashed when it is attached;
2. a closed run's record is immutable; anything later (a reflection, a finding) goes beside it, linked.

Who may change the work description is a permission like any other, not a rule.

**The primitives** (the run verb built in 0.52.46; the work description and proposals in 0.52.47; the journal, evidence and close in 0.52.48):

| Primitive | What it is |
|---|---|
| Run | **built (0.52.46)**: `run W [GOAL]` opens one, `finish` closes it; it records its goal (else "the brief"), what started it, the run it follows, usage (its length, `durationMs`), and the revision of the work description it read. One open at a time |
| Journal | **built (0.52.48)**: journal/1 ([journal.md](journal.md)) — append-only entries on a run, `{id, seq, at, by, kind, text?, refs?, data?, evidence?, supersedes?}`, the daemon setting `id`, `seq`, `at`, `by` and `evidence`; a correction is a new entry of the same kind (`--supersedes N`), `superseded_by` computed on reading; `kind` is any string (`journal-kinds/1`'s ten bare names have their `data` checked; `gate`, `hook` and `dozable.*` are Dozable's own). No kind is required, no order enforced. Read, followed (one cursor, `wseq`) and waited on |
| Evidence | **built (0.52.48)**: a file from the run's folders copied into the run and hashed when attached (`--attach`, rule 1), or hashed in place (`--attach-ref`, large media); commits and messages as refs (`commit:SHA` with `present`, `msg:SEQ` inside the run's slice) |
| Work description | **built (0.52.47)**: the brief plus `addenda [{run?, at, by, text}]` (the record's `addenda`; the document's `brief.addenda`, absent when empty), appended without rewriting the brief; each addendum is one more revision (`addendum-added`, counted by `WorkspaceRuns.descriptionRevision`). A run with no goal takes the brief and every addendum (`WorkDescription.goal`). `doz workspace edit W --addendum TEXT [--run RUN]` adds one directly. A lesson is one kind of addendum |
| Proposal | **built (0.52.47)**: a pending change, `{id, origin: retro, state, change: {addendum}, by, at, source: {run}}` (`doz workspace retro W [RUN] --propose --addendum TEXT`), kept in the record's folder (`proposals.json`), applied or declined through Dozable's own Ask in the main room or `doz workspace decide`. Optional: an identity holding `description.edit` changes things directly |
| Close | **built (0.52.48)**: `finish` freezes the run's journal and evidence into its archive (`journal.jsonl`, `evidence/`); a closed run takes no entry (`run-closed`, rule 2) |

**Permissions, opt-in.** Built: `run.open` and `run.finish` (0.52.46: `workspace-run` and `workspace-reopen` need
`run.open`, `workspace-finish` `run.finish`; an older `workspace.finish` grant, role answer or ceiling still answers for
both for one release, `GrantPermissions.olderIds`); `description.propose` (`workspace-retro`), `description.decide`
(`workspace-decide`) and `description.edit` (`workspace-addendum`), 0.52.47 (`GrantPermissions`, `ActionClasses`). The
journal's ids gate since 0.52.48: `journal.read` (reading, `--follow`, `wait` — the one **on by default**, for an agent in
its own workspace), `journal.write` or `journal.write:KIND` (a parameterised id: that kind only; `journal.write` answers
for every kind), `journal.supersede` (correcting another's entry, decided once the entry is read) and `evidence.attach`.
Every other one is **off for agents** until granted; the owner is never gated, as today:

| Permission | Lets an agent |
|---|---|
| `run.open`, `run.finish` | open and close runs |
| `journal.write` (`journal.write:KIND` for some kinds only) | append journal entries |
| `journal.read` | read, follow and wait on the journal (on by default in its own workspace; withdrawable) |
| `journal.supersede` | correct another's journal entry |
| `evidence.attach` | attach evidence |
| `description.propose` | propose a change to the work description |
| `description.decide` | apply or decline such a proposal (its own too, when granted) |
| `description.edit` | change the work description directly, with no proposal |

A workspace grants them **by role** (roles are grant bundles — built in 0.52.47: the `reviewer` role bundles
`journal.write`, `evidence.attach` and `description.propose`) or **by its own config**: the document's
`permissions: {IDENTITY: [ROLE or PERMISSION, …]}` — built in 0.52.47 as `x-dozable.permissions` in space/3.1 (held;
a bare `permissions:` comes with space/3.2), validated (an unknown name is a problem, 65, listing the known ones) and shown
in the plan as a request — never a grant the file makes by itself (`SpaceIntent` → `Requested, not granted`).

**Recommended processes, as playbooks** (coming, PLAYBOOKS) — supported and tested, never required. Each is only a
configuration of the primitives: a playbook (an editable skill the managing agent follows), a permission preset and the
journal kinds it uses. A workspace applies one (`doz workspace process apply W NAME`), changes it, or uses none.

| Process | The loop | Preset |
|---|---|---|
| Just do it | run → work → finish; an outcome entry if anyone cares | manager: `run.open`, `run.finish`, `journal.write` |
| Review before accept | a worker does it, a reviewer checks it against the goal, the owner accepts | workers: `journal.write` for their kinds; reviewer: the `reviewer` role |
| Quality loop (ISO 9000-style plan, do, check, act) | criteria written at Plan; tasks delegated and claimed; each criterion reviewed against evidence, never a claim; a retrospective proposes a lesson, decided, and the next run's goal includes it | manager: `run.open`, `run.finish`, `journal.write`, `description.propose`; reviewer: `reviewer`; the owner decides. Its gates ("an outcome needs a review per criterion", "a failing review blocks `accepted`") only when the workspace turns them on |
| Autonomous improvement | the quality loop with the manager deciding its own lessons | the quality loop's + manager: `description.decide` |

**Hooks** are an optional, unreviewed proposal for the very end (HOOKS): a workspace told of its run's events by a
command or an address, so a process can live outside Dozable. Nothing of it is planned until it is reviewed again.

**Built in 0.52.43:** the run as a record (`WorkspaceRun {id, startedAt, endedAt, rooms, archive, archiveSHA256, closedBy,
…}`, `WorkspaceRecord.swift`; at most one open, `WorkspaceRecord.openRun`); its room slice (`WorkspaceRunRoom {fromSeq,
toSeq}`); its archive written at `finish`, swept, hashed and verified (`RunArchive`: manifest, the brief, chat, transcripts,
screens, usage, timesheet — workspaces.md, "Runs", "The archive"); what changed in its folders (`WorkspaceChangedFiles`);
`doz workspace runs W [--archive RUN]`. The archives outlive `delete`. **Built in 0.52.46 (LC1):** the Run row of the
table — the run verb, its goal, source, follows, opener, revision and `usage.durationMs` (workspaces.md, "The run verb").
Nothing else of the table above is built: no criteria, tasks, reviews, outcome, `unit.json` or retrospective; a worker's
`--task` is its one instruction for its life.

## What a workspace is

**A workspace is one document plus what is true now.**

| | is | lives in | written by |
|---|---|---|---|
| the **document** (spec) | what should exist: name, brief, the lifetime, defaults, folders, agents, rooms, sandboxes, secret *references*, *requests* | generated today (`RecordDocument`); a revision store later | the daemon only, through one pipeline (later stages) |
| the **record** (status) | runtime facts: places, the phase, runs, the log, the brief's hash | `<store>/workspaces/W/` (`workspace.json`, `log.jsonl`, `brief.md`) | the daemon only |
| the **controller** | turns document + phase + facts into a plan, the plan into actions | the daemon (`HostCore`) | — |

There is **one kind of workspace**. Store-held or kept in a file, standing or run-based: values, never kinds. (Today a
workspace made without a space file has no `up` and no `--purge`; LC2 closes that gap.)

## The nouns

| noun | layer | is | in the document? |
|---|---|---|---|
| workspace | L0 | the project: name, title, brief, the lifetime, defaults, labels, `about` | yes |
| brief | L0 | the purpose: text and references; each run's default goal (and, coming, its default criteria and addenda) | yes |
| grant | L0 | a role or permission in a scope (`<store>/grants/`, a workspace's `permissions`) | **never** — the document only *requests* |
| archive, log | L0 | each run's evidence; the log's lines (counts, hashes, names — never the brief or a token) | never |
| agent | L1 + L2 | a manager, worker or reviewer — **owned** (Dozable starts it) or **external** (`{bot}`, `{session}`, `{sandbox}`); coming: an identity (L1) and its session (L2) | yes (the identity) |
| room | L1 | owned, or external (`doz://HOST/OWNER/room/NAME`, `_` for no owner) | yes |
| folder | outside, L1, L3 | an external path (`rw`/`ro`, at most one **main**), or an owned scratch folder | yes |
| sandbox | L1 | an owned micro VM, or one that exists already; coming: a place with `isolation: vm` | yes |
| secret | — | a **reference** (`{keychain: ITEM}`, `{file: PATH}`) and where it may go (`to:`) | the reference only |
| phase | — | setting up, running, asleep, stopped, finished, archived; coming: one condition per layer | **never** |
| run | L3 | a unit of work: `run` (or the first start, or an up with none open) to its finish, with its goal, its journal and evidence (0.52.48); coming: its criteria | never (the record's, read-only) |

## Invariants

1. One kind of workspace.
2. One writer: only the daemon writes the record (and, later, the document), only through its own operations.
3. Spec, status and phase apart: a sleep is never a change of the document.
4. The file asks, the owner grants: a document never holds a grant, only requests.
5. Nothing moves by itself: the controller acts on a change or a verb; drift is shown, never fixed by itself.
6. Only what it owns: externals are never made or removed; owned things go only after their evidence is archived (a
   sandbox's disk only after it is saved as an image).
7. Idempotent: `--if-plan`, `--request-id`; the same plan twice does nothing the second time.
8. Secrets by reference only: no value in a document, an answer or a log — ever.

## What a document holds, and never holds

Holds: the space/3 keys (`doz`, `space`, `owner`, `brief`, `agent_defaults`, `folders`, `agents`, `sandboxes`, `secrets`,
`chat.rooms`, `persist`, `archive`, …), space/3.1's first-class keys and the held ones under `x-dozable` (below). Always a
**lifetime**: every document Dozable writes is `doz: space/3.1` and carries `x-dozable.lifetime` (the lifetime is not a
3.1 key — below).

Never: a secret's value (a reference only), a token or a fingerprint, a grant (a record's `permissions` stay out), the
phase or any time (`flags`, runs, "running"), a run's scratch path. `doz workspace doc` and its `--write` follow this;
`WorkspaceDocumentTests.testNoSecretValueOrTokenInADocument` and `make test-cli-workspace` D3–D4 pin it. A run's goal is
per run and never in the document (it would make every run a revision); coming (SP32): the brief's standing
`criteria` and `addenda`, and a template-only `run:` default refused in a stored document.

## Lifetime — today's spelling of persistence

`standing | runs` — the default lifetime of what a workspace owns. **standing**: everything owned persists, scratch
folders included; finish removes nothing. **runs**: the space file's run model (owned things last one run unless
`persist:` keeps them). A record workspace (`new`, the wizard) is `standing`. A space file with no lifetime is read as
`runs` (today's meaning); `doc` prints and writes `x-dozable: { lifetime: runs }` for it. A written document always says
it, under `x-dozable` in either version; no file needs it. A top-level `lifetime:` is not a key of space/3 or 3.1 (in a
3.1 file it is refused with the fix: write it under `x-dozable`). It is replaced by `lives:` in space/3.2 (SP32, above).

The lifetime is recorded at `up` and acted on since 0.52.36 (756): `down` ≡ `finish`, a standing workspace's finish
removes nothing it owns but what says `lifetime: run` itself, and its scratch folders are kept (workspaces.md, "The
lifecycle"). Since 0.52.43 (762) `plan -f` / `up` read it too — a standing file's plan says what `down` keeps, never
that it removes everything — and `show --json` / `ls --json` carry it as `lifetime` (`runs` or `standing`; a workspace
made without a space file is `standing`). Not yet (model fixes, LC2): `up` of a standing space still makes a new
scratch folder per run, and `--purge` leaves them on disk, recorded.

## The record → document mapping (`RecordDocument.generate`)

Pure, in DozableHost; it produces the ordered merged JSON the daemon already handles (no YAML in the daemon — the CLI's
`SpaceYAML` renders the text for `--write`).

| record | document |
|---|---|
| the name | `space:` (and the main room's key) |
| the person in chat | `owner:` (`you` while chat has no one) |
| — | `doz: space/3.1`, `x-dozable.lifetime: standing` |
| `brief.md` + `brief.refs` | `brief: {text, refs}` |
| `defaults.network` (a preset) | `network:` |
| `defaults.isolation` fenced / vm | `agent_defaults.isolation: fenced` / `agent_defaults.x-dozable.isolation: vm` (held) |
| each folder | `folders.NAME: {external: PATH, access: ro?}`; the main one `main: true` |
| the manager (a bot) | `agents.NAME: {external: {bot: B}, role: manager}` (its isolation: a note — not carried yet) |
| a worker from a bot | `agents.NAME: {external: {bot: B}, role: worker}` (its task: a note) |
| an anonymous worker | owned: `{kind: claude-code, role: worker, isolation: fenced/unfenced, folder: MAIN, prompt: TASK}` |
| a worker in a micro VM | owned: `{…, where: sandbox:S}` and `sandboxes.S: {}` |
| a declared worker (`new --worker`) | owned: `{kind, role: worker, prompt: TASK, folder: MAIN}` |
| an adopted `@mac` session | `agents.NAME: {external: {session: S}}` |
| an adopted sandbox | `agents.NAME: {external: {sandbox: S}}` |
| an agent elsewhere, an ended worker | left out (elsewhere: a note) |
| the main room, owned | `chat.rooms.W: {main: true}` |
| a room it linked | `chat.rooms.NAME: {external: doz://HOST/OWNER/room/R, main?}` — OWNER the workspace whose log says it made the room, else `_` (the shared-room rule) |
| a room gone for good; no room | left out; no `chat:` at all (a workspace with no room is valid) |
| grants, the phase, runs, times, fingerprints | never |

Names follow the format's rule (`[a-z][a-z0-9-]*`), one namespace across every section; a clash takes `-<kind>`, then a
number (a folder `~/work/app` in workspace `app` is `app-folder`: the main room holds `app`); a renamed one is a note.

A **space-file workspace**'s document is the spec its last `up` recorded (`space.json`: the file as the resolver merged it
— `extends:`, the override, `${VAR}`), in its 3.1 form (`SpaceDozable.lift`: the version line `space/3.1`, each
`x-dozable` spelling of a first-class key lifted to its place, a top-level `title:` moved into `about.title`; the rest —
the lifetime among them — as they are), with the record's **extras** merged in: each agent the
record holds (not ended) that the file names nowhere — by its name, bot, session or sandbox — mapped as above and added
under `agents` (a note each). Its lifetime is the file's, `runs` when it says none. A space recorded by an older doz
(no `space.json`) is generated from its record, with a note.

`generate` → validate passes for every record shape (`WorkspaceDocumentTests.testEveryRecordFixtureGeneratesAValidDocument`).
That the plan of a generated document against its own record is EMPTY — the zero-change gate — is a later stage. Coming
(SP32, IDSESS): the generated document carries `places:` and identities, and `lives:`.

## The space/3.1 keys

`doz: space/3.1` (the owner's go, 2026-11-23, cut to the model-neutral keys by model v3's option A the same day) is
space/3 with Dozable's model-neutral keys first-class; persistence (the lifetime) is not in 3.1. 755 accepted them only under
`x-dozable`, one rule for all: **the 3.1 key, unchanged in name and shape, one level down inside an `x-dozable` map at the
place 3.1 puts it** — so the 3.1 form is the key lifted out of its map. ONE table says which are first-class at each place
(`SpaceDozable.Place.firstClass`); the others are **held** (their design is open with the format's author) and stay
`x-dozable`-only, in either version, until it is settled. Moving a held key first-class is moving it in that table: the
validator checks a key by place and name whichever form it is in (`Schema.dozValue`), every reader asks
`SpaceDozable.member(_:_:at:)`, and `SpaceDozable.lift` writes the 3.1 form.

| where | first-class in 3.1 | held: `x-dozable` only |
|---|---|---|
| top level | `brief:` a path, `{text}` or `{file}` with `refs:` (and `addenda: [{run, at, by, text}]`, written by the document — up keeps the record's own), `about: {title, summary, description, icon, tags, category, needs}` (`about.title` in place of the top-level `title:`), `layout: {…}` (never acted on), `network: locked\|standard\|open` or `{preset, allow: [HOST…]}` | `lifetime: standing\|runs` (never required), `permissions: {IDENTITY: [ROLE or PERMISSION, …]}` (requests only) |
| a folder | `main: true` (at most one) | `lifetime: run` |
| an agent | `restart: no\|on-failure`, `network:`, `external: {sandbox: NAME}` | `lifetime: run` |
| a room, a sandbox | — | `lifetime: run` |
| `agent_defaults` | `where: sandbox` (the workspace's own VM: `mac` and `sandbox` are the keywords, `sandbox:NAME` a declared sandbox) | `isolation: fenced\|vm` (where a record's new workers run; `vm` gets a note naming `where: sandbox`) |

Rules (`SpaceValidator` + `SpaceDozable.swift`):

- The version line: `space/3` or `space/3.1` (a defaults file: `space-defaults/3` or `space-defaults/3.1`, which holds what a
  space-defaults/3 one does — never `lifetime`, `brief`, `about` or `layout`, which describe the space itself).
- No file needs a lifetime. A top-level `lifetime:` in a 3.1 file → 65 `"lifetime" is not a space/3.1 key: it stays under
  x-dozable`, the fix as the hint; in a space/3 file it is "unknown key" with its old hint, as before.
- A top-level `title:` in a 3.1 file still reads, with a note naming `about.title`; with `about.title` too → 65.
- A first-class key in a `doz: space/3` file whose value 3.1 would take is refused (65) with the fix in its message:
  `"brief" is a space/3.1 key: change the version line to doz: space/3.1` (an agent's `external: {sandbox}` likewise). A
  value 3.1 would refuse too stays "unknown key" with its old hint. A plain space/3 file reads exactly as before.
- The `x-dozable` form of a first-class key is still read for one release, in either version; each use is a note naming the
  3.1 key (`SpaceDozable.deprecatedUses`, in the plan's and up's notes and `--json` `notes`). `x-dozable.lifetime` is no
  such use and gets no note: the lifetime is not a 3.1 key. Both forms of one key → 65 (`"main" is written twice: …`; the brief
  keeps its own words: `the brief is written twice: brief: and x-dozable.brief`; an agent's external its own).
- `x-dozable` is checked strictly: an unknown key in it is an error with a suggestion. Every other `x-` key is still
  ignored, as space/3 says.
- A brief held in the document (`brief: {text}`, or `x-dozable.brief`): the workspace's brief: `up` keeps it in the store's
  `brief.md` (a brief FILE is still never copied) and posts it; `show --brief` reads it; an up after the text changed
  updates it. `brief: {text, file}` or neither → 65.
- `about` is strict; `params:` belongs to a template's envelope and is refused in a stored document.
- `external: {sandbox: NAME}` (or `x-dozable.external.sandbox`): the agent is external (adopted at `up`, never started,
  never stopped by `down`); it may not say what an external agent may not (`kind`, `where`, …), may not be written in both
  forms, and may not name a sandbox the file declares under `sandboxes:`.
- `agent_defaults.where: sandbox` (3.1 only; in space/3 → 65 `"where" is a space/3.1 key: …`, on an agent → `"sandbox" is
  not a place`): every owned agent that does not say where runs in the workspace's own VM, an owned sandbox of the run named
  `<space>-vm` (`SpaceModel.workspaceVM`, unique among the file's names), made by the first agent in it (`isolation: vm`).
- An agent's own `network`: an unfenced agent has none (65 at `/agents/NAME/network`); an agent in a VM — the workspace's or
  an owned sandbox — may only repeat the workspace's network (standard when the file says none; a name and its
  `{preset}` map are the same), else 65 at `/agents/NAME/network`. An existing sandbox (`external:`) keeps its own.
- `external: {sandbox}` with `restart` → 65 at `/agents/NAME/restart`. An empty `brief.refs`, `about.tags` or
  `network.allow` → 65 (`… can't be empty`). A per-resource `lifetime:` in a 3.1 file gets the lifetime's own words.
- A space/3 file extends only `space-defaults/3` files: a `space-defaults/3.1` one → 65 at its `/doz`.
- At most one folder with `main` (either form).
- `restart` is recorded and noted, not applied yet; `network`, `about`, `layout` and the per-resource `lifetime: run` are
  checked and kept, not acted on yet. The meaning of no space/3 key changes.
- Vectors: the reference's rows (vendored, read-only) and Dozable's own `Fixtures/space31/validation-errors-3.1.json`,
  through the same harness (`SpaceValidationTableTests`); `Space31Tests`.

## `doz workspace doc`

`workspace-doc` (read-only, `workspace.read` for an agent; in-process with no daemon) answers `WorkspaceDocumentAnswer
{workspace, from: record|space-file, document (ordered JSON text), notes}`; the CLI prints `{kind: "Document", schema: 1,
workspace, from, document, notes?}`. In the `--json` view `document.x-dozable.lifetime` is ALWAYS present (never a
top-level `document.lifetime`) and
`document.doz` is `space/3.1`; the YAML text and `--write` hold the same document (`RecordDocument.fileForm`), which
validates as space/3.1. `--write FILE` (`SpaceRecordFile.writeNew`): `~` is the
space file's home (`TestSafety.spaceHome`), the place rules of a recorded file (under the home, never the store,
`~/.claude` or `~/Library`; no link in the path), temp-and-rename, never over an existing file without `--force`
(`RENAME_EXCL`). Exits: 2 no workspace, 4 `already-exists`, 65 `invalid-value`.

## Test homes

In a guarded run (`DOZ_TEST_GUARD=1`) `DOZ_TEST_HOME` stands for `~` in a space file (its folders, brief, `extends:`,
`prompt_file`), in `--folder ~/…`, in `doc --write ~/…`, and as the home the recorded files must be under (after the older
`DOZ_TEST_BRIEF_HOME`). Unguarded it is always the real home. `TestSafetyTests.testASpaceFilesHome`, `make
test-cli-workspace` D1–D2.
