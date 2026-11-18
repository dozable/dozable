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
| `Sources/DozableHost/HostCore+Workspaces.swift` | the `workspace-*` operations in the daemon (and the read-only core for ls/show/log); the `WorkspaceChat` seam and `OwnerWorkspaceChat`; the hooks of `doz rename` and `doz rm` |
| `Sources/DozableHost/ChatOwnerRooms.swift` | making a room AS YOU over the owner's socket — the one implementation `doz chat room` and the workspaces use; `ChatStateView` |
| `Sources/DozableHost/HostProtocol.swift` | `HostOp.workspace*`, `WorkspaceRequest`, `WorkspaceListing`/`WorkspaceRow`/`LooseAgent`, `WorkspaceDetail`/`WorkspaceAgentRow`; `SandboxInfo.workspace`, `SessionRow.workspace` |
| `Sources/DozableCLI/WorkspaceCommands.swift` | `doz workspace new | ls | show | adopt | release | edit | log | rename` |
| `Tests/DozableCLITests/WorkspaceRecordTests.swift`, `WorkspaceStateTests.swift`, `WorkspaceAdoptTests.swift` | the unit tests (scratch roots, a fake chat) |
| `Sources/doz-vmtest/CLIWorkspaceSuite.swift` | `make test-cli-workspace`: the real doz, its daemon and chat server, no VM |

## The record

`<store>/workspaces/<name>/`:

- `workspace.json` — `{version, name, createdAt, brief: {refs, sha256, bytes, updatedAt}, folders: [{path, mode: rw|ro,
  main}], rooms: [{label, chatRoom, main}], agents: [{name, role, place: {sandbox?, mac?, session?, elsewhere?},
  startedBy, startedAt}], defaults: {isolation?, network?}, flags: {finishedAt?, archivedAt?, firstAgentAt?}, driver:
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
  `folders-edited`, `refs-edited`, `renamed`, `agent-renamed`, `agent-removed`.
- **Folders are optional.** A workspace with none records `folders: []` and has no main folder; `--from-project` needs a
  main folder (it reads the project file there) and is refused without one.

## Who answers what

| Op | Path | Why |
|---|---|---|
| `workspace-ls`, `-show`, `-log` | `query()`: an in-process `HostCore(readOnly: true)` when no daemon runs, else the daemon | looking never starts the daemon; phases from the store, `@mac` rows from `macRows()` |
| `workspace-new`, `-adopt`, `-release`, `-edit`, `-rename` | `call()`: the daemon | ONE writer — each holds the `KeyedGate` key `workspaces`; rooms need the chat server the daemon runs; a read-only core refuses "needs the daemon" |

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
workspace is fully set up (a later step adds `doz workspace start`, which runs the set-up check and posts the brief).

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

`WorkspaceState.derive` (pure, `WorkspaceStateTests`): archived → finished → **setting up** (no agent yet, never
started: no agents and `firstAgentAt == nil`) → starting (a sandbox booting) → waiting on you (a session `blocked` or in
`error`, a sandbox `failed`, an open Ask for you — none until Asks exist) → working → idle → asleep. An empty workspace
that once had agents is asleep. The JSON value is the raw value (`setting-up`, `waiting-on-you`); the CLI shows the words
(`setting up · you`). The driver is always `you` in this version and sits beside the state. A later step adds the set-up
check, which `doz workspace start` runs before the work starts.

## `--json`

`doz ls --json` and `doz sessions NAME|@mac --json` carry `workspace` (a string) on an adopted sandbox or session and
leave it out on a loose one; their text output is unchanged. It is the ONE key containing "workspace" allowed in what a
sandbox or session is shown as (`FolderRenameTests`); `workspaceCreated`, `workspaceRules`, `workspaceView` and any
`workdir` are still refused. `doz workspace ls --json` is `WorkspaceListing {workspaces, loose}`; `show` and every change
answer `WorkspaceDetail`; `log` is the entries.

## Tests

- `make test FILTER=WorkspaceRecordTests|WorkspaceStateTests|WorkspaceAdoptTests` — scratch roots, an in-process daemon
  core, a fake chat.
- `make test-cli-workspace` — the real doz: ls with no daemon starts none; loose agents; new with the room (nothing
  posted, the brief's text in no log); an existing room refused and `--room` linked; adopt a sandbox and `@mac/wsu`
  (`doz.json` unchanged, `workspace` in `--json`, state working), the refusals; release and the log; show and log with
  the daemon stopped; an unknown field kept, the modes; names, rename, the hooks; chat off; no folders.
