# Workspaces — `doz workspace`

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up. A *project* is a folder
(usually a repository) with its sandbox settings (`doz_project.yaml`); a workspace may work on several, or none.

Nothing moves by itself: today's sandboxes and sessions on this Mac are **loose agents** until a person adopts them, and
adopting writes only the workspace's own record — never a sandbox's `doz.json` nor `mac-sessions/sessions.json`. The
dashboard shows them (below, "In the dashboard"), changes a brief, files loose agents, and — this Mac's own browser only —
makes and starts a workspace (the New workspace wizard), adds and ends its workers (Add a worker) and runs its lifecycle
(sleep, wake, finish, reopen, archive, restore, delete — "The lifecycle", below); everything else is the CLI's. The manual's page is
`docs/manual/37-workspaces.md`.

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/WorkspaceRecord.swift` | `WorkspaceRecord` (`workspace.json`, version 1) and its parts — `WorkspaceBrief`, `WorkspaceFolder`, `WorkspaceRoom`, `WorkspaceAgent`, `AgentPlace`, `WorkspaceDefaults`, `WorkspaceFlags`, `WorkspaceOrigin`; `WorkspaceLogEntry` (one line of `log.jsonl`); `WorkspaceName` (the name rule); `UnknownFields` + `DynamicKey` (fields this build does not know, kept) |
| `Sources/DozableHost/WorkspaceStore.swift` | `WorkspaceStore`: the folder per workspace, atomic 0600 files in 0700 folders with no link in the path, create-by-rename, the membership read from the records, the log appended and read (a torn line skipped), `--since` |
| `Sources/DozableHost/WorkspaceState.swift` | `WorkspaceState` and `WorkspaceState.derive`, one pure function; how a sandbox and a session on this Mac look to it |
| `Sources/DozableHost/WorkspacePlan.swift` | `workspace-plan`'s answer `WorkspacePlan`; `WorkspacePresets.builtIn` (the wizard's "Start from", ONE table); `WorkspaceNetworks`; `WorkspaceNewCommand` (the ONE command source: `argv`, `text` — the brief as a heredoc, its delimiter absent from the text — `startText`); `WorkspaceProjectFill` (doz_project.yaml used to fill in choices, the CLI's and the dashboard's, never written); the plan's lines |
| `Sources/DozableHost/WorkspaceSetupCheck.swift` | the set-up check: pure `gaps(_:)` (each `Gap {item, why, fix}`), the one-live-workspace rule (`liveElsewhere`, its refusal) |
| `Sources/DozableHost/ManagerLaunch.swift` | pure: `ManagerIsolation.resolve`, the session name, the program, `plan(...)` (argv, environment, START's path, ports, the bot-held secret) |
| `Sources/DozableHost/ManagerKickoff.swift` | pure: START's text and the brief's post |
| `Sources/DozableHost/HostCore+WorkspaceManager.swift` | `workspace-start` / `-stop`, the `ManagerLauncher` seam and `DaemonManagerLauncher`, `botLaunchSecret`, `liveWorkspace`, `liveWorkers`; the role-aware launch paths (`AgentMacLaunch`, `AgentVMLaunch` — a manager's and a worker's); the unfenced token file (separable) and its sweep |
| `Sources/DozableHost/WorkerLaunch.swift` | pure: `WorkerIsolation.resolve`, `WorkerLaunch` (`placeName`, `tokenVariables`, `nextAnonymousName`, `flagProblems`, `plan`, `control`; the default allow-list, ONE constant) |
| `Sources/DozableHost/WorkerKickoff.swift` | pure: a worker's START |
| `Sources/DozableHost/WorkerPlan.swift` | `worker-plan`'s answer `WorkerPlan` (and `WorkerPlanProblem`); `WorkerFieldRefusal` (an add's refusal tagged with its field); `WorkerAddCommand` (the ONE command source: `argv`, `text`, a long task in `task.txt`); the plan's lines |
| `Sources/DozableHost/HostCore+Workers.swift` | `worker-add` / `-ls` / `-end` / `-plan` (`workerBasics`, `workerPrepare` — the add's checks, shared with the plan), the `WorkerLauncher` seam and `DaemonWorkerLauncher`, `sweepPendingWorkers` |
| `Sources/DozableHost/WorkspaceLifecycle.swift` | pure: `WorkspaceVerb` (its HostOp, how it is confirmed), `WorkspaceLifecycle.plan(verb:record:state:facts:options:)` — the ONE builder of a verb's plan (each agent's row, kept and goes, every refusal, the queue, the commands, the sha) —, `binRefusal`, `WorkspaceLifecyclePlan` / `Row` / `Item` / `Queue` |
| `Sources/DozableHost/HostCore+WorkspaceLifecycle.swift` | the `WorkspaceAgentLifecycle` seam (`DaemonAgentLifecycle`: hibernate, wake, start, shut down, template, rm, a session's end, restart and forgetting), the facts (`agentFacts`, `workspaceLifecycleFacts`), `workspace-lifecycle-plan`, the seven verbs (`workspaceLifecycle`: the gate, `ifPlan`, the queue), `workerWake`, `retireWorker`, `removeOwnSandboxes`, `WorkspaceBin` |
| `Sources/DozableCLI/WorkspaceLifecycleCommands.swift` | `doz workspace sleep | wake | finish | reopen | archive | restore | delete` (the plan's text, the questions, `--dry-run`, `--if-plan`) |
| `Tests/DozableCLITests/WorkspaceLifecycleTests.swift`, `WorkspaceLifecycleHostTests.swift`; `Sources/doz-vmtest/CLIWorkspaceLifecycleRows.swift` | the builder over every kind of agent; the verbs in an in-process core with fakes (the order, `ifPlan`, a partial failure, archive and restore, delete, the Bin's seam, the dashboard's confirmations); `make test-cli-workspace` rows L1–L14 |
| `Sources/DozableHost/WorkspaceReach.swift` | `workspace-reach`'s answer — `WorkspaceReach`, `AgentReach`, `AgentNetworkReach`, `ReachRefusal`, `HeldSecret` (`held`: never a value; a chat token's fingerprint never carried), `ReachFolder` — and `AgentCapabilities.rows` (pure: "what it can do" for any agent; an `@mac` agent's `MacFence.capabilities` unchanged, then its control and its room) |
| `Sources/DozableHost/WorkspaceChangedFiles.swift` | the changed-files walk (never a program: files.md), `WorkspaceFolders` (`workspace-folders`' answer), `WorkspaceLogPage` |
| `Sources/DozableHost/HostCore+WorkspaceViews.swift` | `workspace-reach`, `workspace-folders`, the log in pages (`workspaceLogAnswer`) |
| `Sources/DozableCLI/WorkspaceViewCommands.swift` | `show --can-do | --network | --folders` as text, `--json` with `reach` or `folders` |
| `Tests/DozableCLITests/WorkspaceViewsTests.swift`; `Sources/doz-vmtest/CLIWorkspaceViewRows.swift` | `WorkspaceReachTests`, `WorkspaceChangedFilesTests`, `WorkspaceLogPageTests`; `make test-cli-workspace` rows V1–V5 |
| `Sources/DozableHost/HostCore+Workspaces.swift` | the `workspace-*` operations in the daemon (and the read-only core for ls/show/log); the `WorkspaceChat` seam and `OwnerWorkspaceChat`; the hooks of `doz rename` and `doz rm` |
| `Sources/DozableHost/ChatOwnerRooms.swift` | making a room AS YOU over the owner's socket — the one implementation `doz chat room` and the workspaces use; `ChatStateView` |
| `Sources/DozableHost/HostProtocol.swift` | `HostOp.workspace*`, `WorkspaceRequest`, `WorkspaceListing`/`WorkspaceRow`/`WorkspaceManagerRow`/`LooseAgent`, `WorkspaceDetail`/`WorkspaceAgentRow`, `WorkspaceStarted`, `WorkspaceStopped`; `HostOp.worker*`, `WorkerRequest`, `WorkerListing`/`WorkerRow`, `WorkerAdded`, `WorkerEnded`; `SandboxInfo.workspace`, `SessionRow.workspace` |
| `Sources/DozableCLI/WorkspaceCommands.swift`, `WorkerCommands.swift` | `doz workspace new | ls | show | start | stop | adopt | release | edit | log | rename`; `doz worker add | ls | end` |
| `Tests/DozableCLITests/WorkspacePlanTests.swift` | the plan and new agree over a table of requests, the plan writes nothing, gaps, a look never reads the keychain, chat from its setting with no daemon, presets, `newFolder`, the commands parsed back into the same request, the project's fill |
| `Tests/DozableCLITests/WorkspaceRecordTests.swift`, `WorkspaceStateTests.swift`, `WorkspaceAdoptTests.swift`, `WorkspaceSetupCheckTests.swift`, `ManagerLaunchTests.swift`, `WorkspaceManagerTests.swift`, `BotLaunchSecretTests.swift`, `WorkerLaunchTests.swift`, `WorkerKickoffTests.swift`, `WorkspaceWorkerTests.swift` | the unit tests (scratch roots, a fake chat, fake launchers, a memory keychain) |
| `Tests/DozableCLITests/WorkerPlanTests.swift` | the worker plan and the add agree over a table of requests (each refusal's sentence, code and field), the plan writes nothing, never unfenced from a default, no daemon; `WorkerAddCommandTests` (the argv parses back, the text is the argv to `/bin/sh`, a long task from a file) |
| `Sources/doz-vmtest/CLIWorkspaceSuite.swift`, `CLIWorkspaceManagerRows.swift`, `CLIWorkspaceWorkerRows.swift`, `CLIWorkspaceBriefRows.swift`, `CLIWorkspacePlanRows.swift`, `CLIWorkerPlanRows.swift`, `CLIWorkspaceVMSuite.swift` | `make test-cli-workspace`: the real doz, its daemon and chat server, a FAKE claude, no VM; `make test-cli-workspace-vm`: scratch lab VMs |
| `Sources/DozableHost/BotRecord.swift` | Agents / Bots: `BotsFile` (`bots.json`, version 1), `BotRecord`, `BotIsolation`, `BotInstructions`, `BotTokenState`; `BotName` (the name rule), `BotKinds`, `BotFields` |
| `Sources/DozableHost/BotStore.swift` | `BotStore`: `bots/bots.json` rewritten whole, `bots/<name>/instructions.md` and `notes.md`, 0600 in 0700 |
| `Sources/DozableHost/BotTokens.swift` | a held bot's keychain item (`doz-bot-<store's 8 hex>-<name>`), the fingerprint, the sweep's orphans |
| `Sources/DozableHost/HostCore+Bots.swift` | the `bot-*` operations; the `BotChat` seam (the daemon's `SupervisorBotChat` in HostServer.swift); `BotGuards`; `sweepBotTokens` |
| `Sources/DozableCLI/BotCommands.swift` | `doz bot new | ls | show | set | retire | adopt | token` |
| `Tests/DozableCLITests/BotRecordTests.swift`, `BotTokenTests.swift`, `BotAdoptTests.swift`, `BotGuardsTests.swift`; `Sources/doz-vmtest/CLIBotsSuite.swift` | the unit tests (scratch roots, a memory keychain, a fake chat hashing like the supervisor); `make test-cli-bots` |

## The record

`<store>/workspaces/<name>/`:

- `workspace.json` — `{version, name, createdAt, brief: {refs, sha256, bytes, updatedAt}, folders: [{path, mode: rw|ro,
  main}], rooms: [{label, chatRoom, main}], agents: [{name, role: worker|manager, place: {sandbox?, mac?, session?,
  elsewhere?}, startedBy, startedAt, bot?, isolation?, stoppedAt?, task?, anonymous?, pendingAt?, endedAt?}],
  defaults: {isolation?, network?}, flags: {finishedAt?,
  archivedAt?, firstAgentAt?, startedAt?}, driver:
  "you", origin: {kind: new|adopted|project, project?}}`.
- `brief.md` — the brief's text (at most 256 KiB). The record keeps only its references, hash and size.
- `log.jsonl` — one JSON object per line: `{"v":1,"at":…,"by":"you"|"doz","action":…,…}`.

Rules (keep them, and their tests):

- **Additive only.** Every field this build does not know is kept — at the top level and in every element of `folders`,
  `rooms` and `agents` (`UnknownFields`) — and a higher `version` is kept, never lowered. An older doz rewriting a newer
  one's record loses nothing. `WorkspaceRecordTests.testUnknownFieldsAndAHigherVersionSurviveARewrite`.
- **The name is checked before any path is built from it**: 1–40 of `a-z 0-9 -`, not starting with `-` — the sandbox
  rule, so it is also a valid room name.
- **0600 files in 0700 folders, no link anywhere in the path, owned by this user** (`MacFenceHostFS.ensureDirectory`,
  `writeAtomically`, `readRegular`, `O_NOFOLLOW_ANY`). The store's own path is resolved first (`/tmp` and `/var` are
  links). A new workspace is assembled in `workspaces/.new-<name>-<random>/` and renamed into place with `RENAME_EXCL`:
  it is there whole or not at all, and an existing one is never replaced.
- **Membership has no second index**: `WorkspaceStore.membership()` reads every `workspace.json` into
  `[sandbox:NAME | mac:SESSION → workspace]`. It runs on every `doz ls`, so it stays a directory listing and a few small
  reads (`make test-cli-startup`'s budget).
- **The log never holds the brief's text, a token, or a path outside the store** — names, hashes and counts only
  (`folders-edited` and `refs-edited` say how many). The daemon's log names a workspace and its counts, nothing more.
  Each entry is ONE `write` of one line (`O_APPEND`); a line cut short is skipped when read, and the next entry starts on
  a line of its own. Actions: `created`, `room-made`, `room-linked`, `adopted`, `released`, `brief-edited`,
  `folders-edited`, `refs-edited`, `renamed`, `agent-renamed`, `agent-removed`, `manager-set`, `manager-removed`,
  `bot-invited`, `kicked-off` (the post's sha256 and size — never its text), `manager-started` (isolation, place, the
  token's fingerprint — never the token), `manager-stopped`, `worker-added` (isolation, place, the task's sha256 and size,
  the token's fingerprint — never the task's text or the token), `worker-ended`, `worker-add-undone` (by `doz`),
  `brief-announced` (the room an edit after the start was announced in), `bot-changed` (a running bot's instructions, model
  or account changed, told in `room`; `reason` says which). Each reads as a sentence
  (`WorkspaceLogEntry.sentence`: "started the work: posted the brief in demo (512 bytes)", "edited the work (120 bytes)")
  — the ONE set of words `doz workspace log`, `doz chat read --with-log` and the dashboard's system lines share
  (`WorkspaceLogSentenceTests`).
- **Folders are optional.** A workspace with none records `folders: []` and has no main folder; `--from-project` needs a
  main folder (it reads the project file there) and is refused without one. `newFolder` (`--new-folder`) makes exactly
  `<projects_dir>/NAME`, 0700, when it is missing, and records it first as the main folder (taken back if the rest of
  `new` fails); offered, never forced.
- **New fields of `new`** (additive): `workerIsolation` (`--worker-isolation fenced|vm`) → `defaults.isolation`, which
  `WorkerIsolation.resolve` reads (never unfenced by default: `unfenced` is refused, a worker is unfenced only when
  `worker add --isolation unfenced` names it); `network` (`--network locked|standard|open`, or the project's preset) →
  `defaults.network`.

## Making one: the plan and the dry run

`workspace-new` is ONE draft: `workspaceNewDraft(w, look:)` builds the record, the brief, the log, the notes and EVERY
refusal in the order `new` checks them, writing nothing and making no room or folder. `new` takes it, throws the FIRST
refusal exactly as before (its code and message), else makes the folder, the room and the files. The read-only HostOp
**`workspace-plan`** (`isReadOnly`: in-process with no daemon) takes the same `WorkspaceRequest` and answers
`WorkspacePlan {name, refusals (all), refusalCode, gaps, notes, lines, commands, startCommand, presets}` — the gaps from
the same `WorkspaceSetupCheck.gaps` on the in-memory record (`workspaceSetupInput(rec, look: true, brief:, roomWillBeMade:,
foldersMadeNow:)`). `WorkspacePlanTests.testThePlanAndNewAgree` holds the two together: `refusals` is empty exactly when
`new` succeeds, the made record is the draft apart from its times.

- **A look never reads the keychain**: `Manager.keychainReadable` is `Bool?`; nil (a look — the plan, `show`) is no gap,
  so a locked keychain shows only at the start, which still reads it.
- **With no daemon** chat is judged from its setting (`chat.enabled`: on is taken as "starts with Dozable" — the room
  will be made) and whether a room of that name exists becomes a note ("checked when it is made"); nothing starts the
  daemon. With one, the daemon asks the chat server as `new` does (`workspaceLookReadiness`).
- **`show` carries `gaps`** while the workspace is setting up (the same builder, a look); the CLI prints them as "to start".
- **The one command source**: `WorkspaceNewCommand.argv`/`text` — `doz workspace new NAME --prompt-file - … <<'DOZ_BRIEF_…'`
  (the delimiter 8 hex of the brief's sha256, made longer while it occurs in the text; exact when the brief ends with a
  line break, which the dashboard sees to), `--from-project` instead of `--network` when a project filled it in, and
  `doz workspace start NAME`. The plan answer, `--dry-run` and the wizard's Copy all print it;
  `WorkspacePlanTests.testTheCommandsParseBackIntoTheSameRequest` parses each argv with `WorkspaceNew.parse` back into the
  same request (odd paths, quotes, a `:rw` written out where a path ends like a mode).
- **The CLI**: `doz workspace new … --dry-run` sends `workspace-plan` (`query()`: in-process with no daemon) and prints the
  lines, "It cannot be made yet:", "Before it can start:" and the commands; it exits 0 with no refusal, else with `new`'s
  code for the first one; `--json` prints the plan. `--start` is new, then `workspace-start` — two requests, as the
  dashboard's Create and start. `WorkspaceProjectFill.apply` (the CLI's Yams parser, or the dashboard's installed one)
  fills `project` and `network` from the main folder's doz_project.yaml; a `--network` that differs is refused.
- **`confirmRequired`** (additive on `workspace-start`, the dashboard's; the CLI never sets it): an unfenced manager is
  refused — under the gate, after the set-up check, before anything is posted or started — unless `unfencedConfirmed`:
  "otto acts as you — confirm it" (`WorkspaceManagerTests.testConfirmRequiredRefusesAnUnconfirmedUnfencedManager`).
- `make test-cli-workspace` rows 38–44: the dry run with the daemon stopped writes nothing and starts none; a refused one
  exits as `new`; the printed commands, run by `/bin/sh` in a fresh store, make the same workspace (`show --json` equal
  apart from times); the new fields recorded; `--worker-isolation unfenced` refused; `--start` posts the kick-off once;
  `--json`.

## Who answers what

| Op | Path | Why |
|---|---|---|
| `workspace-ls`, `-show`, `-log`, `-plan` | `query()`: an in-process `HostCore(readOnly: true)` when no daemon runs, else the daemon | looking never starts the daemon; phases from the store, `@mac` rows from `macRows()` |
| `workspace-new`, `-adopt`, `-release`, `-edit`, `-rename` | `call()`: the daemon | ONE writer — each holds the `KeyedGate` key `workspaces`; rooms need the chat server the daemon runs; a read-only core refuses "needs the daemon" |
| `workspace-start`, `-stop` | `call()`: the daemon | the check under `workspaces`, the launch under `workspace:NAME` (each record change takes `workspaces` again); never read-only |
| `workspace-lifecycle-plan` | `query()`: the read-only core when no daemon runs, else the daemon | looking never starts the daemon nor reads the keychain |
| `workspace-sleep`, `-wake`, `-finish`, `-reopen`, `-archive`, `-restore`, `-delete` | `call()`: the daemon | the plan again and `ifPlan` under `workspaces`, the run under `workspace:NAME` (each record change takes `workspaces` again); never read-only |
| `workspace-reach`, `workspace-folders` | `query()`: the read-only core when no daemon runs, else the daemon | looking never starts the daemon; refusals only a daemon's proxies hold ("not known" otherwise) |
| `worker-ls`, `worker-plan` | `query()`: the read-only core when no daemon runs, else the daemon | looking never starts the daemon |
| `worker-add`, `-end` | `call()`: the daemon | the check and the pending entry under `workspaces`, the participant under `bots`, then the launch; never read-only |

The workspace's name never travels in `HostRequest.name` (a sandbox's, which `perform` uses to apply a sandbox's
settings and to route `@mac`); it goes in `WorkspaceRequest.name`, the agent in `WorkspaceRequest.agent`.

**Check, then write.** Every change resolves and checks everything first — the workspace, the target (a sandbox in the
store; an `@mac/SESSION` record in `MacSessions.records()`; bare `@mac` refused: "name the session: @mac/SESSION"), that
no workspace already holds that place ("wsa is already in demo — doz workspace release demo wsa first."), that the agent
name is free (`--as NAME`), the folders, references and brief — and only then writes. A refusal leaves every byte as it
was (`WorkspaceAdoptTests.testRefusalsWriteNothing`).

**The hooks.** `doz rename` of a sandbox moves its agent's place (and its name, when it had the sandbox's) and logs
`agent-renamed` by `doz`; `doz rm` lets the agent go and logs `agent-removed` by `doz`. Both are best effort: a failure is
a note, never a failed rename or rm. A session on this Mac whose record was pruned shows as `gone`.

## Rooms (`new` with chat)

The main room takes the workspace's name. Nothing is posted in it when it is made — the work starts later, when the
workspace is fully set up: `doz workspace start` runs the set-up check and posts the brief (below).

| Case | What happens |
|---|---|
| chat on, no `--room` | the server is waited for (≤ 15 s); a room of that name exists → refused, nothing written ("pass --room NAME …"); else `/room NAME` is sent AS YOU with every other human, the room recorded, `room-made` logged |
| chat on, `--room EXISTING` | it must exist and be no other workspace's room; recorded, `room-linked` logged; nothing posted |
| chat on, not ready | refused, nothing written |
| chat off, or `--no-room` | no room; the note says `doz workspace edit NAME --make-room` |

`workspace rename` keeps the room's name (the chat server cannot rename rooms) and says so. The seam is `WorkspaceChat`:
the daemon's `OwnerWorkspaceChat` asks `ChatSupervisor.sync(waitReady:)` whether the server is ready and makes rooms
through `ChatOwnerRooms`; the unit tests give a fake.

## State

`WorkspaceState.derive` (pure, `WorkspaceStateTests`): archived → finished → starting (`Input.starting`: a
`doz workspace start` under way, `startingWorkspaces`) → **setting up** (`flags.startedAt == nil && flags.firstAgentAt ==
nil`: never started and no running agent adopted — a recorded manager is `Agent.notStarted`) → starting (a sandbox
booting) → waiting on you (a session `blocked` or in `error`, a sandbox `failed`, an open Ask for you — none until Asks
exist) → working → idle → asleep (a manager stopped or its sandbox off, every agent asleep, or started with none). Only
adopting a RUNNING agent sets `firstAgentAt`. The JSON value is the raw value (`setting-up`, `waiting-on-you`); the CLI
shows the words (`setting up · you`). The driver is always `you` in this version and sits beside the state;
`ls` adds the manager: `idle · you · manager mira (fenced)`.

## The manager

`--manager BOT [--manager-isolation fenced|vm|unfenced]` on `new` and `edit` adds, replaces or removes (`--no-manager`)
ONE agent entry `{name: BOT, role: manager, bot: BOT, isolation, place: {mac: true, session: S} | {sandbox: S},
startedBy: you}`, `S` = `ManagerLaunch.sessionName(W)` (the workspace's name; over 32 characters its first 27, `-` and 4
hex of its SHA-256). Checks: the bot exists, is not retired, is not `elsewhere`; no other agent holds the place.
Isolation (`ManagerIsolation.resolve`): fenced by default, vm when asked or the bot's default is vm, **unfenced only when
named** — shown "unfenced · acts as you" in `show`, `ls`, `--json` (`actsAsYou`) and the log. Refused while the manager
runs ("stop it first"); so is `release` of a running manager. Nothing is posted or started; `manager-set` is logged.

**The set-up check** (`WorkspaceSetupCheck.gaps`, pure; the daemon reads its input in `workspaceSetupInput`). Every gap
is returned at once, each with its fix; a refusal writes, posts and starts nothing:

| Gap | Fix |
|---|---|
| the brief is empty | `doz workspace edit W --prompt-file F` |
| chat off and a manager | `doz chat on` |
| chat on, not ready | `doz chat status` |
| no main room / the room gone | `doz workspace edit W --make-room` / `doz chat room R` |
| a folder gone | `doz workspace edit W --remove-folder DIR` |
| an adopted agent's sandbox or session gone | `doz workspace release W AGENT` |
| the bot unknown, retired or elsewhere | `--manager BOT` / `--no-manager` |
| its token not held, or not readable (the fingerprint differs) | `doz bot token BOT --new` |
| inbox and fenced or VM; any webhook | `doz bot set BOT --deliver poll` |
| an agent program with no known first-prompt form (only Claude Code and Codex for now) | another bot |
| the program not on this Mac's PATH (not for VM) | install it, or `--manager-isolation vm` |
| a session or sandbox of its name that is not this manager's (its record carries no bot-held secret of this bot) | `doz sessions end @mac S` / `doz rm S`, or rename the workspace |

**The one-live rule** is apart: "mira already manages launch-video, which is running. For now a bot runs in one live
workspace at a time — doz workspace stop launch-video first." Live = another workspace's manager entry for that bot is
running, or its start is under way (`startingWorkspaces`, marked under the gate, so two concurrent starts cannot both pass).

**The start's order** (`workspaceStart`): the check and the mark under `workspaces`; then, under `workspace:W`: (1) the bot
invited to the main room as you (`ChatOwnerRooms.invite`, `/invite @BOT`, nothing when a member; `bot-invited`); (2) the
kick-off, only while `flags.startedAt == nil`: `ManagerKickoff.briefPost` (the brief, then its references) posted as you
(`ChatOwnerRooms.post`), then `startedAt` and `kicked-off` — a post that fails starts nothing and leaves `startedAt` nil;
(3) the token; (4) the session or sandbox (`ManagerLauncher.launch`); (5) the entry's place, `stoppedAt` cleared,
`manager-started`. A launch failure after the kick-off leaves it started with the manager down and says "doz workspace
start W again (the brief is not posted twice)". No manager: the start ends after the kick-off (you drive).

**Each isolation.** The first prompt is `Read START and do what it says.` (START's path in it); START
(`ManagerKickoff.startText`) says who it is and its room, how to use `dozchat` with `CHAT_TOKEN_FILE`, the
`chat-room-member` skill and the bot's skills by name, its instructions, what it can do, to say it is up, and the brief.

- **Fenced** (`macOpen` with `botSecrets:` and `managerStart:` → `macOpenFenced`): permissions the workspace's network
  default else `locked`; the chat page port as a host port; `CHAT_URL=http://host.dozable.internal:PORT`; the account the
  bot's else `mac.account`; START at `<session>/etc/manager/start.md` (host-owned, read-only to the program); argv
  `claude [--model M] "<prompt>" --permission-mode dontAsk --allowedTools "Bash(dozchat:*)"` (the allow-list last).
- **VM** (`launchManagerInVM`): the sandbox made once with what `doz create S --agent A --approvals skip --permissions P
  --host-port PORT --folder MAIN [--account] [--model]` sends, the bot-held secret put in its record, started, START copied
  to `~/.doz-workspace/start.md` by one exec, then the session `manager` with `CHAT_URL`. Guarded seams for the VM suite:
  `DOZ_TEST_MANAGER_IMAGE`, `DOZ_TEST_MANAGER_ARGV`.
- **Unfenced** (separable — one function block, `unfencedManagerRefusal` turns it off): `macOpen` with
  `CHAT_TOKEN_FILE=<temp>/doz-<store's 8 hex>/manager-S/chat-token` — the REAL token, 0600 in a 0700 folder, written just
  before the open and deleted when it fails, at stop, and by the sweep at a daemon's start (`sweepManagerTokenFiles`: every
  folder of a session not running); START beside it; `CHAT_URL=http://127.0.0.1:PORT` only off 8790; no dontAsk (anything
  beyond dozchat asks: "waiting on you"). An inbox bot whose inbox names another session is pointed at S
  (`BotChat.set`), said and logged. `TestSafety.managerTokenViolation` stops a test writing one for the default store.
- **A start after a stop** re-opens the same session (`macReopen` with the environment, a fresh bot-held secret and START:
  Claude Code resumes the conversation recorded at the stop — `MacPlace.restartArgv`) or starts the same sandbox
  (`claude --continue`); no kick-off.

**The token** never travels: a fenced or VM manager's is a **bot-held launch secret** — `LaunchSecret {variable:
CHAT_TOKEN, fileVariable: CHAT_TOKEN_FILE, bot, fingerprint, keychainService: nil}` (`botLaunchSecret`: the item read to
check it is there and is the one recorded, the reach check with the page port, no source file) — whose value the proxy
reads from the bot's own item, only while the fingerprint matches (a rotated token: a 401 notice saying to start again).
It has no item of its own and no ledger line, so nothing that revokes, forgets or sweeps launch secrets deletes the bot's
token (`BotLaunchSecretTests`); `checkedLaunchSecrets` clears a client-sent `bot`. See network.md.

**Stop** (`workspaceStop`): fenced/unfenced — `macEnd` only while it runs (it learns `claudeSessionID` and keeps the
record), the proxy and placeholders go with it, the unfenced token folder is deleted; VM — the sandbox shut down (its disk
and conversations kept). The bot stays in the room and its token in its item. `stoppedAt`, `manager-stopped`. Nothing
running: said, exit 0. Nothing is posted in the room.

`doz bot ls` and `bot show` carry `running` (the workspace where its manager runs now): "manages: demo (running)".

**An edit of the brief after the start**: `workspaceEdit` writes the brief, the record and `brief-edited` as before;
then, only when `flags.startedAt` is set and the main room is recorded, it posts ONE message as you
(`ManagerKickoff.briefEdited`: "I edited the work:" and `briefPost`'s text) through the same `WorkspaceChat.post` the
kick-off uses, and logs `brief-announced {room}`. While setting up nothing is posted (the start posts the brief). Chat off,
not ready, or a post that fails: the edit is kept and the answer's note says "not announced: …" — never a failed edit.
**`ifBrief`** (`WorkspaceRequest.ifBrief`, additive; the CLI's `--if-brief SHA`, the dashboard's Save): checked FIRST,
against the record's `brief.sha256` — a mismatch is `invalid-phase` "the brief of W changed since you opened it",
nothing written or posted. `WorkspaceManagerTests` (`testAnEditWhileSettingUpPostsNothing`,
`testEachEditAfterTheStartIsAnnouncedOnceAsYou`, `testChatOffKeepsTheEditAndSaysItWasNotAnnounced`,
`testIfBriefMismatchWritesNothing`), `make test-cli-workspace` rows 34–35.

## Workers

`doz worker add W [NAME] --task "…"` brings up a worker in a STARTED workspace: an agent with one task, a participant of
its own in the main room (and each `--room LABEL` of the workspace). Its entry is `{name, role: worker, place, bot?,
isolation, task, anonymous?, pendingAt?, endedAt?}`; `isWorker` is a `worker` entry with a task (an adopted agent has
none). Refused: setting up ("W is still setting up — doz workspace start W first (a workspace with no manager starts
with you driving)"), finished or archived, a start under way, chat off or not ready, no main room. `doz workspace stop`
stops only the manager. Dozable posts nothing in the room: the worker says it is up itself.

**Names.** A worker's NAME is its participant's name — one flat namespace with the participants and the bots. None given:
the first free `botN` (`WorkerLaunch.nextAnonymousName`) skipping every participant, every bot (retired included), you and
every live worker of any workspace. `--from-bot BOT`: NAME is the bot's (another NAME refused, `--agent` refused). A NAME
that is a bot's ("doz worker add W --from-bot X"), a participant's, a retired bot's or a live worker's is refused. An
ended worker's entry is replaced by a new one of its name (the log keeps the history).

**Isolation and place** (`WorkerIsolation.resolve`, `flagProblems`) — the narrowest unless asked: fenced; vm when asked,
or the workspace's `defaults.isolation` or (from a bot) the bot's default is vm; **unfenced never unless
`--isolation unfenced`** — and `unfencedManagerRefusal()` is the ONE switch that refuses unfenced managers and workers
alike. Fenced or unfenced: the session `W-NAME` (`WorkerLaunch.placeName`: over 32 characters its first 27, `-` and 4
hex; `--session` overrides). VM: a sandbox of its own, `W-NAME`, made as `doz create … --agent A --approvals skip
--permissions P --host-port PORT --folder MAIN [--cpus N --memory M]` would, plus `sandbox.clipboard off` and
`sandbox.browser_bridge off`; its session inside is NAME (its place has no `session`). `--sandbox X`: X runs, is an
adopted agent's or another worker's sandbox of this workspace (never the manager's), proxied, reaches the page port
already (else "doz net allow X host:PORT") and holds fewer than four secrets; the place is `{sandbox: X, session: NAME}`
— membership stays by sandbox, a worker is told apart by its name. Refused together: `--cpus`/`--memory` without vm,
`--sandbox` with `--isolation`, `--cpus`, `--memory` or `--session`; `--allow-tool` other than for a fenced Claude Code
worker. Its folder is the workspace's main one, else `<projects_dir>/W/NAME` (0700). Its network is the workspace's
default, else `locked`; fenced, its `MacFenceRequest` has `openURL` and `clipboard` off and the page port as its one
host port. Agent: `claude-code` by default; only Claude Code and Codex (`ManagerLaunch.program`).

**Its launch** (`WorkerLaunch.plan` on `AgentLaunch.plan`, the manager's builders): the first prompt `Read START and do
what it says.`; START (`WorkerKickoff.startText`) begins `You are NAME, a worker in the workspace W. Your task: <its first
line>` / `Your room in chat: ROOM` (the manager's shape, which the tests' FAKE claude reads), then who directs it (the
manager while one runs, else the person), `dozchat` with `CHAT_TOKEN_FILE`, the skills `chat-worker`,
`chat-room-member` and a bot's own, a bot's instructions, what it can do where it runs, to say it is up with its task in
a few words, and the task in full. Fenced: START at `etc/worker/start.md`; argv `claude "<prompt>" --permission-mode
dontAsk --allowedTools "Bash(dozchat:*)" [--allow-tool …]` — `WorkerLaunch.defaultAllowedTools` is the ONE constant of
the default list (the allow-list last). Unfenced: no dontAsk. VM: START at `~/.doz-workspace/NAME/start.md`, approvals
skipped, no list. The paths are the manager's, made role-aware: `launchAgentOnMac` (`AgentMacLaunch`) and
`launchAgentInVM` (`AgentVMLaunch`); the manager's own launch is unchanged.

**The token kinds.** From a bot: its bot-held launch secret (`botLaunchSecret`, never deleted). Anonymous: a throwaway
participant made by the daemon (`BotChat.add`, polls) and its token as a **daemon-made launch secret** of its place
(`daemonWorkerSecret`: `checkedLaunchSecrets(daemon: true)` — no source file, the reach check kept — then
`keepLaunchSecrets(owner:)`: its own keychain item and a ledger line, so revoking and the sweep delete it; until its
place exists the sweep leaves it alone, `pendingLaunchSecrets`). Owner `mac.W-NAME` fenced, the sandbox's name in a VM.
Unfenced (either kind): the real token in a 0600 file in a 0700 folder at the unfenced manager's path for its session
(`workerTokenFolder` — one line, open with the owner), deleted at end and by the daemon's sweep. Never in argv, a record,
a log or `--json`.

**A shared sandbox.** Every session of a sandbox gets every secret's placeholder (`deliverLaunchSecretFiles`), so a worker
in `--sandbox X` gets its own pair, `CHAT_TOKEN_<NAME>` / `CHAT_TOKEN_FILE_<NAME>` (`tokenVariables`), and the daemon sets
`CHAT_TOKEN` / `CHAT_TOKEN_FILE` to them for ITS session only (`sessionSecretAliases["X/NAME"]`, set just before the
open and read by `openSession` — never a client's to set). Workers sharing X can read each other's placeholders: accepted,
and said ("shares X: workers there can read each other's placeholders" in `add`, `ls` and the docs).

**The order** (`workerAdd`): under `workspaces` every check (nothing written on a refusal) and the entry with `pendingAt`;
then the throwaway participant (under `bots`, the name checked again), the invites (`bot-invited`), the token (the secret
kept, or the token file), the launch (`WorkerLauncher.launch`); then `pendingAt` cleared and `worker-added`. A failing
step undoes the earlier ones (the token file, the secret — forgotten and swept —, the participant, the entry) and says
"NAME did not start: …". At a daemon's start `sweepPendingWorkers` undoes an entry left pending whose place does not run
(its participant, its secret in a sandbox's record, its token file, the entry; `worker-add-undone` by `doz`) and clears the
mark of one whose place runs.

**End** (`workerEnd`): fenced/unfenced — `macEnd` while it runs, its secret dropped from the session's record, the token
file deleted; the record kept unless `--rm`. Its own VM — its session ended and the sandbox shut down (which revokes its
secrets); the disk kept unless `--rm`. A shared sandbox — only its session ends; its secret leaves `config.secrets` and
the vault (`applyLaunchSecrets`); `--rm` refused. Anonymous: its item forgotten and `BotChat.remove` (out of every room,
its token refused, its old messages keep its name). From a bot: nothing of the bot revoked; it stays a member of the room.
The entry gets `endedAt` (`worker-ended`); its name is free again. `end --rm` of a worker already ended deletes the place
it kept. `release` of a live worker is refused ("doz worker end W NAME"), and `doz rm` of a worker's sandbox leaves its
entry (the hook skips workers).

**The one-live rule counts workers.** `liveWorkspace(of:except:)` counts another workspace's running manager AND every
worker entry not ended for that bot (`WorkspaceSetupCheck.Entry.role`); the refusal names the role: "otto already works in
wk, which is running. For now a bot runs in one live workspace at a time — doz worker end wk otto first." Both
`workspace start` and `worker add --from-bot` refuse. A bot is never a worker of the workspace it manages. `doz bot ls`
and `bot show` carry `worksIn` ("works in: wk").

**State.** `WorkspaceState.derive` stays pure; `WorkspaceState.worker(pending:ended:place:)` maps an entry: pending →
starting, ended → no agent, else its place — a session's row, or its sandbox counting ONLY its own session's status. A
started workspace with no manager and one working worker reads `working · you`; every worker ended and no manager:
`asleep`. Ended workers are left out of `show`, `ls` and the count (`worker ls --all` shows them).

**Adding one: the plan and the dry run.** `worker-plan` (`isReadOnly`: in-process with no daemon) takes the same
`WorkerRequest` as `worker-add` and runs the add's own checks — `workerBasics` (the name, the task, the workspace), chat as
a look sees it (`workspaceLookReadiness`: with no daemon, its setting), then `workerPrepare(look: true)`, the add's checks
unchanged in order and words — and returns before the pending entry: nothing written, no participant made (the names
come from `botDirectory()`, the daemon's chat or the store's `directory.json`), no keychain item read, nothing started.
Each refusal is a `WorkerFieldRefusal {field, error}` — `workspace`, `task`, `name`, `agent`, `fromBot`, `isolation`,
`sandbox`, `session`, `cpus`, `memory`, `rooms`, `allowTools` (`WorkerLaunch.flagProblem` names the field of a flag that
does not go together) — and `HostError.from` gives the add its own error back, so the add answers exactly as before. The
answer `WorkerPlan {workspace, name, agent, account (a name only; nil unfenced), isolation, place, session, sandbox,
folder, network, control, rooms, allowTools, actsAsYou, shares, director, command, problem? {field, text, code}, notes,
lines}`. With no daemon the checks that ask the daemon about a running place (whether `W-NAME` exists, whether `--sandbox
X` runs and reaches the page port) are skipped and noted "checked again when you add"; the add re-checks everything under
the gate anyway. **The one command source** is `WorkerAddCommand` (`argv`: the parser's order, a task starting with `-` as
`--task=…`; `text`: quoted for a POSIX shell; a task over 1 KiB as `--task="$(cat task.txt)"` with a note) — the plan's
`command`, `--dry-run` and the dashboard's Show the command. `doz worker add … --dry-run` prints the lines, "It cannot be
added: …", the notes and the command exactly; it exits 0, else with the add's code; `--json` is the plan.
`WorkerPlanTests`, `WorkerAddCommandTests`; `make test-cli-workspace` rows 45–47.

**`doz worker ls W`** shows every agent — manager, adopted, workers — with CONTROL (`WorkerLaunch.control`: fenced
`proxy · placeholders · guard`, vm `micro VM · proxy · placeholders`, unfenced `no proxy · no placeholders · no guard ·
acts as you`, `· shares X` in a shared sandbox), NETWORK (a session's preset, a sandbox's network, unfenced "not
limited"), STATE and the task shortened; `--json` is `WorkerListing`; it answers in-process with the daemon stopped.

## The lifecycle

`doz workspace sleep | wake | finish | reopen | archive | restore | delete W` beside `start | stop` (stop is unchanged: the
manager only). Reversible: sleep ↔ wake; stop ↔ start; finish → reopen, then wake; archive → restore (the rooms opened
again, the result finished; retired anonymous workers and removed sandboxes are not undone); delete: none.

**Check, then ask: one plan, three surfaces.** The read-only HostOp `workspace-lifecycle-plan` (`isReadOnly`: in-process with no
daemon — the store's records and the sessions' holders read, `factsKnown: false`, "checked again when you act"; never the
keychain) takes `WorkspaceRequest {name, verb, removeSandboxes?, keepTemplates?, binFolders?}` and answers
`WorkspaceLifecyclePlan {rows (one per agent not ended: name, role, place, isolation, now, activity, after, back, changes),
keeps, goes (sizes: the memory given back, a sandbox's disk and restore points; folder paths), refusals (all at once),
refusalCode, queue {width, changes, note}, confirm (none | yes | typed, `confirmName`), command, commands (today's per-agent
equivalents), notes, templates, sha}` from ONE pure builder, `WorkspaceLifecycle.plan`, over the record and the facts
(`WorkspaceAgentLifecycle.facts`). The daemon builds the same plan again before it acts: a request whose `ifPlan` is not its
sha is refused "W changed since you looked" (`invalid-phase`, exit 3), nothing done. The sha covers what is done to whom,
the flags and the refusals — never sizes, activity or order (`WorkspaceLifecycleTests.testTheShaIsStableAndOrderIndependent`).
The CLI prints the plan and `--dry-run` stops there (0, or the refusal's code; `--json` the plan); the dashboard draws it as
its confirmation (web.md, "Lifecycle actions").

**One gate per verb.** The verb holds `workspace:W` for its whole run and marks `lifecycleWorkspaces` (a `worker add` and a
`start` are refused "busy" meanwhile); its agents change at most `ui.batch_concurrency` at once, the rest "queued — N
ahead" (the daemon's log); two workers sharing a sandbox are one change. A flag (`finishedAt`, `archivedAt`) is set only
once every agent reached its target; a partial failure answers which did not and why (`failed`, exit 1) and keeps what did —
a retry plans only what is left (`WorkspaceLifecycleHostTests.testAPartialFailureSetsNoFlagAndARetryFinishes`).

| Verb | A sandbox | A session on this Mac (fenced) | Unfenced | Elsewhere | Record |
|---|---|---|---|---|---|
| sleep | hibernated (memory back, the same programs and screens; a shared sandbox once) | ended (`macEnd`: HUP→TERM→KILL, its `claudeSessionID` learned), the record and its launch secrets kept | the same; a manager's or worker's token file deleted | untouched | every agent's `stoppedAt`; `slept`, `agent-slept` |
| wake | woken; one shut down boots and its agent continues (`claude --continue`) | the manager through its start's restart branch; a worker in place (`WorkerLaunchOrder.restart` → `macReopen`: its conversation resumed, its kept secret; a bot's given again); an adopted session restarted (a program with no conversation starts fresh) | the token file written again (a bot's from its item; an anonymous worker's is a NEW token — its participant's replaced: the old one lived only in the file) | untouched | `stoppedAt` cleared; `woke`, `agent-woke` |
| finish | shut down, its disk kept | ended, its conversation kept | ended, its token file deleted | untouched, in the room | `finishedAt`; rooms writable, tokens kept |
| reopen | — | — | — | — | `finishedAt` cleared, `reopenedAt`: asleep until woken |
| archive | finish's steps; with `removeSandboxes` a template of each sandbox Dozable made for it (`S-tpl`, unless `keepTemplates` is false), then `rm` | finish's steps | finish's steps | untouched | rooms `/archive`d as you; anonymous workers retired (participant removed, launch secret forgotten, `endedAt`); a bot keeps its token and membership; `archivedAt`, `archive {rooms, removed, templates}` |
| restore | not made again (listed with its template) | — | — | — | exactly `archive.rooms` opened again as you; `archivedAt` cleared; finished |
| delete | released loose; `rm` only with `removeSandboxes` | a manager's or worker's record forgotten | the same; its token folder swept | untouched | refused unless finished or archived and while anything runs; rooms archived (the chat server deletes none); anonymous workers retired; folders to the Bin only with `binFolders`; `<store>/workspaces/W/` removed, one `daemon.log` line |

**The launch secret survives a sleep.** An anonymous fenced worker's daemon-made secret is a launch secret of its session:
its keychain item, its ledger line and the session's record (`fence.secrets`). `macEnd` of a RUNNING session keeps the record
(only ending one already ended forgets it), so the sweep keeps the item, and `macReopen` reopens with the record's secrets and
a fresh placeholder — the same token (`make test-cli-workspace` L2–L3). A sandbox shut down (a finish) revokes its secrets:
an anonymous worker in it gets a new token on its next wake, and the plan says so ("with a new token").

**Safety.** Nothing on disk goes without its flag: a sandbox's disk only with `removeSandboxes`, and only one Dozable made for
this workspace (a manager's or a worker's own — never an adopted one, never one a worker shares; `doz rm`'s hook leaves its
entry while the lifecycle removes it, `lifecycleRemoving`); folders only with `binFolders`, moved to the Bin
(`WorkspaceBin.move`: `FileManager.trashItem`), never deleted, and refused — in the plan and again before the move — for the
disk's root, your home or a folder above it, the store or a folder around or in it, and a folder another workspace or a
sandbox uses (`WorkspaceLifecycle.binRefusal`). A guarded test run moves into `DOZ_TEST_TRASH_DIR` and only a scratch folder
(`TestSafety.trashViolation`): never the real Bin. Archive and delete need the name typed (the CLI asks on `/dev/tty`; the
dashboard's `confirm` is checked by the daemon under `confirmRequired`); an unfenced manager's wake from a browser needs
`unfencedConfirmed`, as its start does.

**The log** gains `slept`, `woke`, `agent-slept`, `agent-woke`, `finished`, `reopened`, `archived`, `room-archived`,
`room-unarchived`, `worker-retired`, `sandbox-removed`, `template-kept`, `restored`, each a sentence. **The record** gains,
additively: `WorkspaceAgent.template`, `WorkspaceFlags.reopenedAt` and `.archive`; `WorkspaceFlags` keeps the fields it does not
know. `WorkspaceState.derive` is unchanged (slept agents read asleep; finished outranks a session still running after a
partial failure).

## Runs

A run is one start (the kick-off) or reopen to its finish (or archive); sleep, wake, stop and start never close it
(`WorkspaceRuns`, `HostCore+Runs`). `WorkspaceRecord.runs` (additive) holds `{id, startedAt, endedAt?, archive?, rooms:
[{room, id, fromSeq, toSeq?}], archiveSHA256?, archiveProblem?, closedBy?, legacy?, noArchive?}`; ids are `YYYY-MM-DD-N`, N
unique in the record. The markers are data, never posts: `fromSeq` is each room's last seq when the run opened, `toSeq` the
last seq the chat server answered when finish closed the room (under its close gate), and the run's messages are exactly
`fromSeq < seq <= toSeq`. A record started before runs gets an implicit run (`legacy`) at its next finish; one finished
before runs is never closed after the fact. A room's id and owner live in `<store>/chat/room-index.json`
(`ChatRoomIndex`: ids `rm_<16 hex>`, an archive reference, tombstones `{name, id, deletedAt, run, archive, owner}`);
`WorkspaceRoom` gains `id`, `owned` (nil: read from the log — `room-made` owns, `room-linked` does not) and `goneAt`.
`doz workspace runs W` (`workspace-runs`) answers from the store with no daemon started.

Finish's order: (1) its own rooms closed — the whole closed set handed to the chat server (chat.md, "The control
channel"), the answer each room's `toSeq`; (2) the agents stopped — a sandbox agent's conversations and screen copied out
first, while its VM runs (`SandboxTranscriptExport`, through an exec to list and a one-member tar to read, never woken);
(3) the archive written; (4) the run closed; (5) `finishedAt`. A failed archive removes only its own partial, records
`archiveProblem`, and finish still completes (the CLI exits 1 and names `doz workspace runs W --archive RUN`). The finish
plan shows each room's row (an owned one closed, a linked one not), "finish closes the room to new messages until you
reopen", the archive section (estimate, refusals: chat not ready, not enough free space) and `--no-archive`; the sha covers
the rows and the archive's shape, never its counts. Reopen opens the rooms again and a new run.

## The archive

`<store>/archives/<workspace>/runs/<run>/` (outside `workspaces/W/`, so delete keeps it), written by `RunArchive` into
`<run>.partial/` through `RunArchiveFolder` (0700 folders, 0600 files, `O_CREAT|O_EXCL|O_NOFOLLOW`, never through a link,
only under `<store>/archives/`): `manifest.json` (`run, workspace, window, versions, rooms {name: id}, labels, notes, sweep,
files [{path, sha256, sourceSHA256?, bytes, agent?, source?, session?}], messages`), `run.json` (the run and the confirmed
plan), `brief.md`, `chat/<room>.jsonl` and `attachments/<room>/…` (no cap), `transcripts/<agent>/…` (a session on this
Mac's — Dozable's kept copies since the run began, its carried copies and recorded conversations, by `TranscriptCopy`'s
rules; a sandbox's), `screens/<agent>.txt`, `usage.json` (`TranscriptUsage` over the archived copies) and `timesheet.md`
(`Timesheet`; commits "not collected": Dozable never runs git in an agent's folder). Every file is swept as written
(`ExportSweep`), then the whole archive is swept again — a finding fails it —, then the manifest is written and every file
re-hashed through the folder's descriptor, then the partial is renamed into place. No program is run.

## Workspace-wide views

What a workspace can reach, hold and change, in one place — the CLI's `doz workspace show W --can-do | --network | --folders`,
`doz workspace log W --limit N --before I`, and the dashboard's Network & secrets, Folders & points, Activity and each agent's
Can do (web.md, "Workspace-wide views"). Two read-only HostOps beside `workspace-show`, both in-process with no daemon:

- **`workspace-reach`** (`WorkspaceRequest.agent`: one agent only, additive) answers `WorkspaceReach {workspace, agents:
  [AgentReach], defaults: {isolation, network}, refusalsKnown, notes}`; `AgentReach {name, role, isolation, place, kind, control,
  actsAsYou, state, capabilities, network {proxied, live, preset, sites, hostPorts, forwarded: [{port, local}], refused: [{host,
  port?, count, lastAt, grant}]}, held: [{name, to, header, fingerprint?, kind: given|chat-bot|chat-worker}], folders: [{path,
  mode}], account, rooms}` — from the records of its place (a sandbox's `doz.json`, a session's record), the live proxies and
  their logs (the daemon's only: in-process `refusalsKnown` is false and the notes say "not known: no daemon is running").
  NEVER a value: the field is `held`, a given secret's fingerprint (12 hex) is all of it there is, a chat token's fingerprint is
  never carried. `capabilities` is ONE pure function, `AgentCapabilities.rows`: an `@mac` agent's `MacFence.capabilities`
  unchanged; a VM's isolation, folders, network (live where proxied), this Mac's ports, forwarded ports, secrets by name and
  destination (next start), the Claude account by name, keys as state; elsewhere "not isolated by Dozable"; then the control row —
  a fenced or VM manager "talks in the room only — it cannot drive Dozable", unfenced "acts as you — runs doz and anything else as
  you", elsewhere "not run by Dozable — token only", a worker `WorkerLaunch.control`'s words — and the chat row ("its chat token is
  held by Dozable"). The later rows (Permissions: allow · ask · never; the ceiling) are never data.
- **`workspace-folders`** answers `WorkspaceFolders {workspace, since, folders: [{path, mode, main, workspace, exists, rules:
  {ignore, readonly}, agents, changes: [{kind, path}], count, truncated, scanned}], points: [{agent, sandbox, rows}]}`: the
  workspace's folders, then each agent's own working folder not among them; `since` = `flags.startedAt ?? firstAgentAt ??
  createdAt`; the changes by the bounded walk (files.md — never a program in an agent's folder), attributed by folder (`agents`:
  who works in it — never who changed a file); each VM agent's restore points (`Sandbox.restorePoints`).
- **The log in pages**: `workspace-log` with `before` or `limit` (additive; 1–500, 200 by default) answers `WorkspaceLogPage
  {entries (newest first), first, more}` — `WorkspaceStore.logPage` reads `log.jsonl` BACKWARDS in 64 KiB blocks (a page costs
  its own lines), skips a torn line and a last line with no line break the same way every time; `first` is the oldest line's
  byte offset (stable: the log is only appended to, an append after a torn line starts on its own line), `before: first` the
  page before. Without them the answer is the entries, as before. An older daemon ignores them: the CLI says "needs the daemon
  of this version", the dashboard takes its answer as the newest page.
- **The CLI**: `show W --can-do` (each agent's rows, "live" or "at the next start", the two later rows), `--network` (the
  permissions per agent and new workers, Refused lately with each `doz net allow` command, this Mac's ports, Held for agents,
  Accounts used here, "Nothing here shows a secret…"), `--folders` (each folder, `A`/`M` paths, the honest line, the restore
  points); `--agent A` with `--can-do`/`--network`; `--json` is `show`'s detail plus `reach` or `folders`. `log W --limit N
  [--before I]` prints a page oldest first and the command for the page before; `--json` is the page (`first`, `more`).
- `WorkspaceReachTests`, `WorkspaceChangedFilesTests`, `WorkspaceLogPageTests`; `make test-cli-workspace` rows V1–V5.

## `--json`

`doz ls --json` and `doz sessions NAME|@mac --json` carry `workspace` (a string) on an adopted sandbox or session and
leave it out on a loose one; their text output is unchanged. It is the ONE key containing "workspace" allowed in what a
sandbox or session is shown as (`FolderRenameTests`); `workspaceCreated`, `workspaceRules`, `workspaceView` and any
`workdir` are still refused. `doz workspace ls --json` is `WorkspaceListing {workspaces, loose}`; `show` and every change
answer `WorkspaceDetail`; `log` is the entries.

Additive, never persisted (an older doz ignores them; the text output prints none): `WorkspaceRow.folders` (the
paths, the main one first), `WorkspaceRow.places` (the places of its agents that have not ended, each once, as a person
types them — `HostCore.workspacePlaces`; so a sandbox's or a session's page in the dashboard knows its workspace; another
computer that may not see this Mac's sessions gets none of `@mac/…`), `WorkspaceAgentRow.startedBy` (`you`, `doz`) and
`.session` (a sandbox place's session — a worker sharing a sandbox; `place` names only the sandbox) and
`WorkspaceRow.working` (the agents whose program is working now, by name);
`WorkspaceAgentRow.activity` — `WorkspaceState.activity` of the `WorkspaceState.Agent` that `workspaceAgents` already
computes (`blocked` or `error` before `working`, else `idle`; a failed sandbox `error`; nil when it does not run). Both
come from what the daemon holds (its statuses), never a guest call; answered in-process (no daemon) `working` and
`activity` are absent. `workspace-ls` reads the sessions on this Mac through `macRows()`, which asks each holder's socket
for its INFO line — so the dashboard reads it on events only, never on a timer (`WorkspaceStateTests.testActivity`,
`WorkspaceWorkerTests.testTheDashboardFields`).

## In the dashboard

Six reads, each exactly one read-only HostOp the CLI also sends (`WebWorkspaceReads.request(for:)`; web.md,
"Workspaces in the dashboard"): `GET /api/v1/workspaces` (`workspace-ls`), `GET /api/v1/workspaces/{w}`
(`workspace-show`, never the brief's text; additive `startedAt`, `network`, each agent's `control`),
`GET /api/v1/workspaces/{w}/brief` (`workspace-show --brief`: `{text, refs, bytes, updatedAt, sha256}` — another computer
only with `serve.chat` read or write, else 403 `brief-remote`), `GET /api/v1/workspaces/{w}/log[?since=EPOCH]`
(`workspace-log --since`: `{lines: [{at, by, action, room?, agent?, text}], more, hidden}` — the sentences; never a hash,
fingerprint, place key or size field; the newest 500; another computer while `serve.mac_sessions` is off gets no line
about a session on this Mac, counted in `hidden`), `GET /api/v1/loose` (`workspace-ls --loose`), `GET /api/v1/bots`
(`bot-ls`; and `?retired=1`, and `GET /api/v1/bots/{name}` — `bot-show` with the instructions' text: web.md, "Agents / Bots
in the dashboard"). The New workspace wizard's plan route `POST /api/v1/workspace-plan` is `workspace-plan` (this Mac's own
browser only). The workspace actions: `workspace-brief` = exactly `workspace-edit` with the name, the
brief and `ifBrief` (another computer only with `serve.chat = write`), and FILING — `workspace-adopt`, `workspace-new` ("Put in a
workspace…" sends exactly one agent) and `workspace-release`, each exactly the CLI's HostOp, this
Mac's own browser only (another computer: 403 `mac-only`, whatever its serve settings; web.md, "Filing agents"); the New
workspace wizard's `workspace-new` carries every field the CLI takes (never a project path or `noManager`) and
`workspace-start` (with `confirmRequired`) is this Mac's own browser's too (web.md, "The New workspace wizard"). The two
worker actions `worker-add` (every field the CLI takes; unfenced only with `confirm: "unfenced"`) and `worker-end`
`{workspace, name, confirm}` are this Mac's own browser's, and so is the Add a worker page's plan route `POST
/api/v1/worker-plan` (`worker-plan`, `mac-screen`) — web.md, "Adding a worker". The eight lifecycle actions
(`workspace-stop` … `workspace-delete`, each with the plan's `ifPlan`) and their plan route `POST /api/v1/workspace-lifecycle-plan`
are this Mac's own browser's too — web.md, "Lifecycle actions". No other `workspace-*` or `worker-*` HostOp is an action
(CLAUDE.md's rule). The five `bot-*` changes are actions of this Mac's own browser, each `heldOnly` (below).
Filing a RUNNING agent into a workspace that is setting up marks it started (`firstAgentAt`; nothing posted, nothing
started), and the page says so ("NAME is started: AGENT was already running. The brief was not posted."); the title pill and
the setting-up banner follow. Releasing the last agent of a started workspace leaves `firstAgentAt` set — the rule governs
the start only.
The sidebar lists the workspaces and unfolds one into its rooms and agents; Home is the table of them, or the definition
with the loose count when there are none; This Mac › Loose agents lists what is in no workspace with "Put in a
workspace…"; Agents / Bots lists the bots. A workspace's page (`#/w/NAME[/room/LABEL]`, web.md "A workspace's page") puts
its room first: the brief above it, the log's sentences among its messages (the same words as `doz chat read
--with-log`), the agents, folders and network beside it; its Agents tab (`#/w/NAME/agents`) is one table of every agent, and
an agent's screen (`#/w/NAME/agent/AGENT`) is its sandbox's or its session's page framed by the workspace (the additive
`startedBy`, `session` and `places` above feed them).

## Agents / Bots — `doz bot`

An Agent / Bot is a lasting identity: a participant in chat with its agent program, model, account, avatar, isolation
(`vm`, `fenced` — the default —, `unfenced` — only when named, "acts as you" wherever it shows — or `elsewhere`), delivery
(`poll` by default, `inbox` for a Claude Code bot, `webhook`), skills, instructions and a token of its own. Its kind in
chat comes from its agent: Claude Code is a `claude-session`, every other agent an `agent`. A bot is started as a
workspace's manager ("The manager", above) or one of its workers ("Workers"); a workspace's agent names the bot it is with `WorkspaceAgent.bot` (additive). The manual's page is
`docs/manual/38-agents-and-bots.md`.

**The record.** `<store>/bots/bots.json` `{version, bots: [{name, createdAt, origin: new|adopted, agent, model?,
account?, avatar?, isolation: {default, ceiling?}, kind, deliver, webhookEntry?, session?, skills, instructions: {sha256,
bytes, updatedAt}?, token: {keeper: dozable|elsewhere|none, fingerprint, at}, retiredAt?}]}`, and `bots/<name>/` with
`instructions.md` (≤ 256 KiB, UTF-8) and an empty `notes.md`. Additive like the workspace record (unknown fields kept top
level, per bot and in `isolation`; a higher version kept); 0600 files in 0700 folders, no link, rewritten whole and
atomically under the `bots` gate. `directory.json` gains no field. `BotRecordTests`.

**The token** (keep these, and their tests):

- A **held** bot's (vm, fenced, unfenced) is made by the daemon (`ChatTokens.make`) and lives in ONE login-keychain item,
  `doz-bot-<store's 8 hex>-<name>`, through `services.keychain` (the memory one under `DOZ_TEST_CREDENTIALS=memory`;
  `TestSafety.keychainViolation` stops a test that would reach the real one); the supervisor writes only its hash. A
  change checks everything first, refuses where the login keychain is locked (no memory fallback), writes the item, then
  the participant, then `bots.json` — deleting the new item (or restoring the old value, for a rotation) when a later step
  fails. The item is read back only by the sweep and by a manager's start and proxy (a bot-held launch secret).
- A bot **elsewhere**'s is never kept: it travels once, in `BotChange.oneTimeToken` over the daemon's socket; the CLI
  writes it with `TokenDestination` (a terminal, or a new 0600 file with `--to-file`) and drops it before any `--json`.
- **Never in argv, a record, a log or `--json`**: no option takes a token, `BotRequest` carries none, `daemon.log` says
  "bot mira: made (fenced, poll), token fp …" (12 hex of its SHA-256), `bot show` reports the record's state and never
  reads the keychain. Moving a bot to or from `elsewhere` replaces its token.
- Bot tokens stay **out of `secrets.json`**: the launch secrets' sweep treats an owner that is not `mac.…` as a sandbox,
  and an older doz would delete a bot's item. The daemon's start sweeps the bots' own prefix (`sweepBotTokens`: this
  store's prefix only, never the read-only core, only when `bots/` exists) and deletes every item of no held, unretired bot.
- `BotTokenTests`, `BotAdoptTests`, `make test-cli-bots` (the leak sweep: no `dzc_` under the store or the settings, in
  `daemon.log`, `server.log`, any `--json`, or `ps`).

**Retiring** is removal plus reservation: the participant and its hash go (`BotChat.remove` — its token is refused), the
item is deleted, the record keeps `retiredAt` and `keeper: none`. Old messages keep `from` as a plain string, so the name
stays reserved: `bot new`, `bot adopt`, `chat add` (and naming yourself with `chat on --name`) refuse it. A bot that is an
agent of a workspace is refused ("mira is in demo — doz workspace release demo mira first"; a live worker: "otto works in
wk — doz worker end wk otto first"). There is no un-retire.

**Adopting** an existing participant replaces its token (Dozable never had the old one — an agent still using it stops
working at once); its kind, rooms and history are kept, `origin: adopted`. The CLI says so and asks (`--yes` with
`--json` or with no terminal; nothing changes otherwise).

| Op | Path | What |
|---|---|---|
| `bot-ls`, `bot-show` | `query()`: the read-only core when no daemon runs, else the daemon | `bots.json`, `directory.json`, the workspaces; looking never starts the daemon |
| `bot-new`, `-set`, `-retire`, `-adopt`, `-token` | `call()`: the daemon, `KeyedGate` key `bots` | one writer; the participant through `BotChat` (the supervisor's own add / set / token / remove); a read-only core refuses "needs the daemon" |

**The instructions' text**: `bot-show` with `BotRequest.withInstructions` (additive) answers `BotDetail.instructionsText` (the
file `bots/<name>/instructions.md`, UTF-8, ≤ 256 KiB; only when asked, also in-process) — `doz bot show NAME --instructions`
and the dashboard's bot screen. `BotRow` gains `avatar`, `account` and `tokenKeeper` (additive; never a fingerprint).

**`heldOnly`** (`BotRequest.heldOnly`, additive; the dashboard sets it on every change, the CLI never does): under the `bots`
gate and before the keychain or the chat server is touched, `BotGuards.heldOnlyRefusal` refuses whatever would make a token to
show once — new or adopt `elsewhere`, `bot-token` of a bot elsewhere, `set` to or from `elsewhere` — naming the terminal's
command ("a bot elsewhere gets its token in a terminal on this Mac: doz bot token far --new --to-file F"); every byte stays as
it was (`BotTokenTests.testHeldOnlyRefusesEveryTokenToShowOnce`, `BotAdoptTests.testHeldOnlyRefusesAnAdoptionElsewhereAndKeepsTheHeldOne`).
An older daemon ignores it; the dashboard then drops the one-time token unread (web.md).

**A running bot is told** (`botTellRunningSessions`): when `bot-set` changes the instructions (their sha256), the model or the
account of a bot that runs — the manager of a workspace now running, or a worker not ended — in a started workspace with a main
room, the daemon posts ONE line as you there ("mira's instructions changed; they apply from mira's next session";
`BotGuards.changedLine`) through `workspaceAnnounce` — the brief's announcement's path — logs `bot-changed` and says so in the
answer's notes ("mira runs in demo: … demo's room is told", or "not announced: …"). A name or an avatar posts nothing; the change
is kept whatever the chat server says (`WorkspaceManagerTests.testARunningBotsChangeIsToldInItsRoomOnce`).

`doz bot token NAME` without `--new` is answered by `bot-show`; `bot-token` always rotates. **The guards**:
`HostServer.chatRequest` asks `BotGuards.chatRefusal` first — `chat add` of a bot's or a retired name, `chat remove` /
`token` / `set` of a bot (each naming the `doz bot` command); every other participant is unchanged (`BotGuardsTests`).

## Tests

- `make test FILTER=WorkspaceRecordTests|WorkspaceStateTests|WorkspaceAdoptTests` — scratch roots, an in-process daemon
  core, a fake chat.
- `make test-cli-workspace` — the real doz: ls with no daemon starts none; loose agents; new with the room (nothing
  posted, the brief's text in no log); an existing room refused and `--room` linked; adopt a sandbox and `@mac/wsu`
  (`doz.json` unchanged, `workspace` in `--json`, state working), the refusals; release and the log; show and log with
  the daemon stopped; an unknown field kept, the modes; names, rename, the hooks; chat off; no folders. Rows 12–22, the
  manager (a FAKE claude that reads START and says it is up with dozchat; a scratch fence home; `mac.account none`):
  recorded not started; every gap listed, nothing written; start (the invite, your brief first, then "is up"; fenced, in
  the workspace); the leak sweep (no `dzc_` in `ps`, the store's files, the fence home or any `--json`; a placeholder in
  `etc/secrets/CHAT_TOKEN`); one live workspace per bot; stop and start again (the brief once); unfenced only when named
  (its 0600 token file the only holder, gone at stop); a VM manager's gap with nothing booted; the refusals; ls/show with
  the daemon stopped.
  Rows 23–33, the workers (the same FAKE claude): refused while setting up, nothing made; `worker add` (an anonymous
  `bot1`, fenced, in `chat who`; the invite, then "bot1 is up: … list the files"; fenced in the workspace); the leak sweep
  (no `dzc_` in `ps`, the store's files, the fence home or any `--json`; a placeholder; one ledger line); `worker ls`;
  unfenced only when named (its 0600 token file; `defaults.isolation unfenced` alone still fenced); its token refused
  after end (`dozchat rooms` exits 4); a bot as a worker and the one-live rule both ways; end keeps a bot's token; end
  (kept, out of chat, the ledger line gone, the name free again); the refusals; `worker ls` with the daemon stopped.
- `make test-cli-workspace-vm` — scratch lab VMs through the seams (`DOZ_TEST_MANAGER_*`, `DOZ_TEST_WORKER_IMAGE` /
  `DOZ_TEST_WORKER_ARGV` — `TestSafety.workerSeams`, a FAKE script with its first prompt appended): the manager's order,
  only the placeholder in the guest, stop keeps the disk, a restart posts nothing; a VM worker of its own (`--cpus`,
  `--memory`), a second sharing its sandbox as its own participant (its own variables, aliased; "is up" as itself), end
  keeps the other talking, end stops and keeps the sandbox, `--rm` deletes it.
- `make test FILTER=WorkspaceSetupCheckTests|ManagerLaunchTests|WorkspaceManagerTests|BotLaunchSecretTests`;
  `make test FILTER=WorkerLaunchTests|WorkerKickoffTests|WorkspaceWorkerTests` (the order, each failure undone, the
  refusals, end, the sweep, the one-live rule both ways).
- `make test FILTER=BotRecordTests|BotTokenTests|BotAdoptTests|BotGuardsTests` and `make test-cli-bots` — Agents / Bots
  (above).
