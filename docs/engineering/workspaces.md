# Workspaces — `doz workspace`

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is
for, and any folders it works on (usually projects). Work starts only once it is fully set up. A *project* is a folder
(usually a repository) with its sandbox settings (`doz_project.yaml`); a workspace may work on several, or none.

Nothing moves by itself: today's sandboxes and sessions on this Mac are **loose agents** until a person adopts them, and
adopting writes only the workspace's own record — never a sandbox's `doz.json` nor `mac-sessions/sessions.json`. The
dashboard shows nothing of workspaces yet; the CLI is the only way in. The manual's page is `docs/manual/37-workspaces.md`.

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/WorkspaceRecord.swift` | `WorkspaceRecord` (`workspace.json`, version 1) and its parts — `WorkspaceBrief`, `WorkspaceFolder`, `WorkspaceRoom`, `WorkspaceAgent`, `AgentPlace`, `WorkspaceDefaults`, `WorkspaceFlags`, `WorkspaceOrigin`; `WorkspaceLogEntry` (one line of `log.jsonl`); `WorkspaceName` (the name rule); `UnknownFields` + `DynamicKey` (fields this build does not know, kept) |
| `Sources/DozableHost/WorkspaceStore.swift` | `WorkspaceStore`: the folder per workspace, atomic 0600 files in 0700 folders with no link in the path, create-by-rename, the membership read from the records, the log appended and read (a torn line skipped), `--since` |
| `Sources/DozableHost/WorkspaceState.swift` | `WorkspaceState` and `WorkspaceState.derive`, one pure function; how a sandbox and a session on this Mac look to it |
| `Sources/DozableHost/WorkspaceSetupCheck.swift` | the set-up check: pure `gaps(_:)` (each `Gap {item, why, fix}`), the one-live-workspace rule (`liveElsewhere`, its refusal) |
| `Sources/DozableHost/ManagerLaunch.swift` | pure: `ManagerIsolation.resolve`, the session name, the program, `plan(...)` (argv, environment, START's path, ports, the bot-held secret) |
| `Sources/DozableHost/ManagerKickoff.swift` | pure: START's text and the brief's post |
| `Sources/DozableHost/HostCore+WorkspaceManager.swift` | `workspace-start` / `-stop`, the `ManagerLauncher` seam and `DaemonManagerLauncher`, `botLaunchSecret`, `liveWorkspace`; the unfenced token file (separable) and its sweep |
| `Sources/DozableHost/HostCore+Workspaces.swift` | the `workspace-*` operations in the daemon (and the read-only core for ls/show/log); the `WorkspaceChat` seam and `OwnerWorkspaceChat`; the hooks of `doz rename` and `doz rm` |
| `Sources/DozableHost/ChatOwnerRooms.swift` | making a room AS YOU over the owner's socket — the one implementation `doz chat room` and the workspaces use; `ChatStateView` |
| `Sources/DozableHost/HostProtocol.swift` | `HostOp.workspace*`, `WorkspaceRequest`, `WorkspaceListing`/`WorkspaceRow`/`WorkspaceManagerRow`/`LooseAgent`, `WorkspaceDetail`/`WorkspaceAgentRow`, `WorkspaceStarted`, `WorkspaceStopped`; `SandboxInfo.workspace`, `SessionRow.workspace` |
| `Sources/DozableCLI/WorkspaceCommands.swift` | `doz workspace new | ls | show | start | stop | adopt | release | edit | log | rename` |
| `Tests/DozableCLITests/WorkspaceRecordTests.swift`, `WorkspaceStateTests.swift`, `WorkspaceAdoptTests.swift`, `WorkspaceSetupCheckTests.swift`, `ManagerLaunchTests.swift`, `WorkspaceManagerTests.swift`, `BotLaunchSecretTests.swift` | the unit tests (scratch roots, a fake chat, a fake launcher, a memory keychain) |
| `Sources/doz-vmtest/CLIWorkspaceSuite.swift`, `CLIWorkspaceManagerRows.swift`, `CLIWorkspaceVMSuite.swift` | `make test-cli-workspace`: the real doz, its daemon and chat server, a FAKE claude, no VM; `make test-cli-workspace-vm`: one scratch lab VM |
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
  elsewhere?}, startedBy, startedAt, bot?, isolation?, stoppedAt?}], defaults: {isolation?, network?}, flags: {finishedAt?,
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
  token's fingerprint — never the token), `manager-stopped`.
- **Folders are optional.** A workspace with none records `folders: []` and has no main folder; `--from-project` needs a
  main folder (it reads the project file there) and is refused without one.

## Who answers what

| Op | Path | Why |
|---|---|---|
| `workspace-ls`, `-show`, `-log` | `query()`: an in-process `HostCore(readOnly: true)` when no daemon runs, else the daemon | looking never starts the daemon; phases from the store, `@mac` rows from `macRows()` |
| `workspace-new`, `-adopt`, `-release`, `-edit`, `-rename` | `call()`: the daemon | ONE writer — each holds the `KeyedGate` key `workspaces`; rooms need the chat server the daemon runs; a read-only core refuses "needs the daemon" |
| `workspace-start`, `-stop` | `call()`: the daemon | the check under `workspaces`, the launch under `workspace:NAME` (each record change takes `workspaces` again); never read-only |

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

## `--json`

`doz ls --json` and `doz sessions NAME|@mac --json` carry `workspace` (a string) on an adopted sandbox or session and
leave it out on a loose one; their text output is unchanged. It is the ONE key containing "workspace" allowed in what a
sandbox or session is shown as (`FolderRenameTests`); `workspaceCreated`, `workspaceRules`, `workspaceView` and any
`workdir` are still refused. `doz workspace ls --json` is `WorkspaceListing {workspaces, loose}`; `show` and every change
answer `WorkspaceDetail`; `log` is the entries.

## Agents / Bots — `doz bot`

An Agent / Bot is a lasting identity: a participant in chat with its agent program, model, account, avatar, isolation
(`vm`, `fenced` — the default —, `unfenced` — only when named, "acts as you" wherever it shows — or `elsewhere`), delivery
(`poll` by default, `inbox` for a Claude Code bot, `webhook`), skills, instructions and a token of its own. Its kind in
chat comes from its agent: Claude Code is a `claude-session`, every other agent an `agent`. A bot is started as a
workspace's manager ("The manager", above); a workspace's agent names the bot it is with `WorkspaceAgent.bot` (additive). The manual's page is
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
agent of a workspace is refused ("mira is in demo — doz workspace release demo mira first"). There is no un-retire.

**Adopting** an existing participant replaces its token (Dozable never had the old one — an agent still using it stops
working at once); its kind, rooms and history are kept, `origin: adopted`. The CLI says so and asks (`--yes` with
`--json` or with no terminal; nothing changes otherwise).

| Op | Path | What |
|---|---|---|
| `bot-ls`, `bot-show` | `query()`: the read-only core when no daemon runs, else the daemon | `bots.json`, `directory.json`, the workspaces; looking never starts the daemon |
| `bot-new`, `-set`, `-retire`, `-adopt`, `-token` | `call()`: the daemon, `KeyedGate` key `bots` | one writer; the participant through `BotChat` (the supervisor's own add / set / token / remove); a read-only core refuses "needs the daemon" |

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
- `make test-cli-workspace-vm` — one scratch lab VM through the seams: the order, only the placeholder in the guest, stop
  keeps the disk, a restart posts nothing.
- `make test FILTER=WorkspaceSetupCheckTests|ManagerLaunchTests|WorkspaceManagerTests|BotLaunchSecretTests`.
- `make test FILTER=BotRecordTests|BotTokenTests|BotAdoptTests|BotGuardsTests` and `make test-cli-bots` — Agents / Bots
  (above).
