# The host protocol

The `doz` host serves one Unix socket per store, `<store>/host.sock`, and every client of a sandbox speaks to it: the
`doz` command, `doz ui`, and any app that drives sandboxes (the Swift client is
[DozableClient](https://github.com/dozable/DozableClient)). This page is the reference and the promise about how it
changes. The golden fixtures that pin it byte for byte are in [`schema/host-protocol-1/`](../schema/host-protocol-1/README.md);
the code is `Sources/DozableHost/HostProtocol.swift`.

**Protocol version: 1.** (`HostProtocol.version`; a test fails if this line and the code disagree.)

## Transport

- A Unix stream socket at `<store>/host.sock`, mode `0600`, in the user's own store directory. There is no other
  authentication: whoever can open the socket is the user.
- The path must be at most **103 bytes** (macOS `sun_path`). A client refuses a longer one before it connects; use a
  shorter store path.
- **One request per connection.** A client connects, writes one request line, reads, and the host closes (the streams
  below are the exceptions: the connection stays open as long as the stream does).
- Lines are UTF-8 JSON, one object per line, ended by `\n`; a request line is at most 1 MiB.
- No host running? A client may start one (`doz host start`), or for the read-only ops marked below, read the store
  itself. A host is never a child of its client (it lives under launchd), so a client quitting does not stop it.

## The envelope, and `v`

A request is one flat object:

```json
{"v":1,"op":"inspect","name":"box"}
```

`v` is the protocol version the client speaks, `op` is one of the operations below, and the rest are that op's fields
(the table lists them; all are optional unless the op needs them, and the host answers `invalid` when one is missing).
Keys are camelCase. An unknown field in a request is ignored.

The host answers with zero or more `event` lines, then exactly one line with `ok`:

```json
{"v":1,"event":{"kind":"phase","sandbox":"box","phase":"running","text":"running","time":"2026-01-01T00:00:00.000Z"}}
{"v":1,"ok":true,"result":{"…":"…"}}
{"v":1,"ok":false,"error":{"code":"not-found","message":"no sandbox named box"}}
```

The host checks `v` for **every** op before it reads the rest, streamed ops and an op it has never heard of included.
A request whose `v` is higher than the host speaks gets `error.code = "version"`. `ping` is the one exception: it
answers at any `v`, so a newer client can read `protocolVersion` and refuse cleanly.

## The handshake: `ping`

`ping` returns a `HostStatus`:

| Field | Meaning |
|---|---|
| `protocolVersion` | The protocol the host speaks (1). A client that speaks another stops here. |
| `version` | The `doz` release, for display and for a client that pins an exact build |
| `operations` | Every op the host serves (the `HostOp` raw values). **Feature-detect with this**, never by comparing versions. Absent on a host older than 0.37.42 |
| `pid`, `startedAt`, `store`, `idleTimeoutMinutes`, `liveSandboxes`, `connections`, `idleSeconds` | The host's own state |
| `executable`, `executableChange`, `executableNote` | The program file the host runs from, and whether it was changed underneath the host |
| `parentPid`, `sessionID`, `launchedDetached` | How the host was started |

A client that needs `agent-stream` checks `operations` for it and tells the person to update Dozable when it is absent.

## Errors

An `ok: false` line carries `error: {code, message}`. The message is for a person; the code is for a program.

| Code | Meaning |
|---|---|
| `failed` | The operation went wrong; the message says how |
| `not-found` | The sandbox, restore point, image, account or program does not exist |
| `invalid-phase` | The sandbox is in a phase that cannot do this (not running, for an op that needs it) |
| `exists` | The name or label is already taken |
| `invalid` | The request is malformed or missing a field |
| `not-implemented` | The host knows the op but not this form of it |
| `version` | The request's `v` is one the host does not speak |
| `unavailable` | The host cannot do it now (needs a host, a limit such as 8 agent streams, a resource missing) |

The set of codes only grows. **A client treats a code it does not know as `failed`.**

## Event kinds

`event` lines carry progress. `kind` is one of:

`phase`, `step`, `note`, `progress`, `connection`, `host`, `console`, `started`, `failed`, `output`, and
`session-status`.

`session-status` is **opt-in**: the host sends it only to an `events` request with `sessionStatus: true`, because an
older client could not decode a kind it did not know. A client skips an event kind it does not know. The kinds that
are not opt-in are sent to everyone, so a new one is only ever added behind a request field.

## The four connection modes

| Mode | Ops | After the `ok` line |
|---|---|---|
| answer | most | the host closes |
| events | `events`; `net-log` and `console` with `follow` | `event` lines until the client hangs up |
| raw attach | `attach` | the terminal, as raw bytes (below) |
| frames | `copy`, `agent-stream` | binary frames in both directions (below) |

### The attach wire

After the `ok` line (`result.state` is `attached`, or `held` when the sandbox is paused or asleep and the request said
`wake: false`) the connection is a terminal.

- **Host to client:** the session's VT bytes: a snapshot of the screen first, then the output. A held connection
  carries nothing until the sandbox runs.
- **Client to host:** keystrokes, with in-band frames that start with the byte `0xFF` (it never occurs in UTF-8, so
  typing cannot forge one):

  | Frame | Bytes | Meaning |
  |---|---|---|
  | HELLO | `FF 'H' cols rows` | the first thing a client sends; sizes are big-endian `u16` |
  | RESIZE | `FF 'R' cols rows` | the viewer changed size |
  | REPAINT | `FF 'S' 0 0 0 0` | send this viewer a fresh snapshot |

- **Notices** for the person arrive in the byte stream as `ESC ] 777 ; doz ; notice ; KIND ; TEXT BEL` and are never
  drawn (a clipboard copy, an opened page).
- **The end:** when the session is over the host writes the ended notice
  `ESC ] 777 ; doz ; ended ; WHY BEL` (`WHY` is the exit code, `stopped` or `none`) plus a line of text, then closes. A close
  with **no** ended notice means the sandbox sleeps or the host stops: reattach when it runs again, and be held until
  it does.

### The frame spec (`copy` and `agent-stream`)

After the `ok` line the connection carries frames: **one type byte, a 4-byte big-endian length, the payload**, at most
1 MiB. A client skips a host-to-client type it does not know, by its length.

`copy` (`CopyRequest` in the request, `CopyReady` in the answer):

| Direction | Type | Payload |
|---|---|---|
| host to client | `D` | tar bytes (a `get`) |
| host to client | `E` | `CopyDone`, always the last frame |
| client to host | `D` | tar bytes (a `put`) |
| client to host | `F` | the input is finished |

`agent-stream` is below.

## Agent streams

`agent-stream` runs an agent program (Claude Code's stream-json, an ACP agent, …) in a sandbox on a real pipe, with no
terminal. A terminal cannot carry it (`claude --print` refuses a terminal on stdin) and `exec` buffers its output and
has no stdin.

**Request:** `name`; `argv` (required, non-empty); `environment`, `user`, `workdir` as for `exec`; `wake` (default
true); `start` (default false: `doz agent-stream` sends true unless `--no-start`); `stream`, a label of 1 to 64
letters, digits and `.` `_` `-` `:` (the host makes one when absent); `force`, which ends an open stream with the
same label first.

**Answer:** the wake and start events, then one `ok` line, `AgentStreamReady`: `stream` (the label), `runAs` (absent
means root), `workdir`, `pid` (the guest pid, for diagnostics), `woke`, `started`.

**Errors:** `not-found` (no such sandbox, or the program is missing), `invalid-phase` (the sandbox cannot run),
`exists` (the label is open and `force` was not set), `unavailable` (the sandbox already has 8 streams), `invalid`
(empty `argv` or a bad label).

**Frames:**

| Direction | Type | Payload |
|---|---|---|
| host to client | `D` | the program's stdout bytes, opaque (NDJSON for stream-json) |
| host to client | `R` | the program's stderr bytes, live |
| host to client | `E` | `AgentStreamEnd`: `exitCode` or `severed`, `stdoutBytes`, `stdinBytes`, `milliseconds`. **Always the last frame**, with exactly one of `exitCode` and `severed` |
| client to host | `D` | stdin bytes. This wakes a paused or asleep sandbox, so send it only for deliberate input |
| client to host | `F` | the program's stdin is finished |

The host refuses a client-to-host type it does not know (it treats it as a hang-up). A client never half-closes the
socket: the host takes the end of the client's input as a hang-up (the program gets stdin EOF, and is ended after 5
seconds if it has not exited). To finish the program's input, send `F`.

**Lifecycle:**

| What happens to the sandbox | What the stream does |
|---|---|
| pause, sleep | stalls, then continues when the sandbox runs; a client `D` frame wakes it |
| hibernate | severed `sleeping` |
| shut down, reset, remove; or the stream replaced by `force` | severed `stopped` |
| `doz host stop`, a quit, SIGTERM | severed `host-stopping`; the `E` frame is written before the host exits |
| the pipe died with no reason | severed `transport-lost` |

`severed` is an open set: **any word means "resume"**. A stream is severed, never left hanging. An open stream keeps
the host from exiting when idle.

**Resume recipe.** The program may still be running in the guest when its pipe is cut; the host ends it (HUP, then
TERM, then KILL) before the next stream on that sandbox can open, so there is never a second copy. To continue a
conversation, open a new stream and start the agent with its own resume option from the session id it reported, for
example `claude --resume <session_id>`. `doz agent-stream` exits **75** after a severed stream (and after a connection
that ends without an `E` frame), with `doz agent-stream: severed (WHY)` on stderr; that is the cue to resume.

**Back-pressure:** the program's output is held in a bounded buffer (4 MiB across stdout and stderr). A client that
reads slowly makes the program wait, and nothing is lost. The same holds the other way: the host stops reading a
client that has more than 1 MiB of input the program has not taken.

**Inspecting:** `inspect` lists the open streams as `agentStreams` (label, `argv0`, `pid`, times, byte counts). The
program's arguments and text are never logged.

## Operations

Every op the host serves. *Tier 1* ops are what a client app drives: each has a request and an answer fixture and a
typed method in DozableClient. *Tier 2* ops are reached by name with the same request shape. *Read-only* ops answer
from the store when no host is running; *no host* ops (the Mac-side file operations and a UI layout) also answer with
no host. *Stream* is the connection mode above.

| Op | Tier | Request fields | Answer | Read-only | No host | Stream |
|---|---|---|---|---|---|---|
| `access` | 2 | `check`, `items`, `accessChoices` | `AccessReport` | no | no | answer |
| `access-github-key` | 2 | `secret`, `source`, … | `AccessReport` | no | no | answer |
| `account-add` | 2 | `account`, `accountKind`, `secret`, `secretSource`, `provider`, `custom`, `verify`, `force`, … | `[AccountRow]` | no | no | answer |
| `account-default` | 2 | `account`, `provider` | `[AccountRow]` | no | no | answer |
| `account-edit` | 2 | `account`, `newName`, `plan` | `[AccountRow]` | no | no | answer |
| `account-keepalive` | 2 | `enabled` | `AccountsFile` | no | no | answer |
| `account-ls` | 1 | (none) | `[AccountRow]` | yes | no | answer |
| `account-refresh` | 2 | `account` | `[AccountRow]` | no | no | answer |
| `account-rm` | 2 | `account` | `[AccountRow]` | no | no | answer |
| `account-use` | 2 | `name`, `account`, `extra`, `removeExtra` | `[CredentialRow]` | no | no | answer |
| `account-verify` | 2 | `account` | `[AccountRow]` | no | no | answer |
| `agent-prompt` | 2 | `name`, `prompt`, `promptMode`, `clearPrompt`, `agentSudo`, `clearAgentSudo` | `AgentPromptReport` | no | no | answer |
| `agent-stream` | 1 | `name`, `argv`, `environment`, `user`, `workdir`, `wake`, `start`, `stream`, `force` | `AgentStreamReady`, then frames | no | no | frames |
| `attach` | 1 | `name`, `session`, `cols`, `rows`, `wake`, `openDefault` | `ok` line (`state`: `attached` or `held`), then the terminal | no | no | attach |
| `bases` | 2 | (none) | `[BaseRow]` | yes | no | answer |
| `boot-log` | 2 | `name`, `boot`, `list` | boot log (JSON) | yes | no | answer |
| `build-log` | 2 | `image` or `name` | build log | yes | no | answer |
| `builder-install` | 2 | `requestedBy` | builder status | no | no | answer |
| `builder-start` | 2 | `requestedBy` | builder status | no | no | answer |
| `builder-status` | 2 | (none) | builder status | yes | no | answer |
| `console` | 2 | `name`, `follow` | `BootConsoleLines`; with `follow`, `console` events | no | no | events (with `follow`) |
| `copy` | 1 | `name`, `fileCopy` (`CopyRequest`), `wake`, `start` | `CopyReady`, then frames | no | no | frames |
| `create` | 1 | `name`, `create` (`CreateOptions`) | `SandboxInfo` | no | no | answer |
| `dotfiles` | 2 | `name` | dotfiles report | yes | no | answer |
| `dotfiles-resolve` | 2 | `dotfilesSource` | resolved source | no | no | answer |
| `dotfiles-update` | 2 | `name`, `dotfilesCommit` | update result | no | no | answer |
| `duplicate` | 2 | `name`, `newName`, `point`, `duplicate` (`DuplicateOptions`) | `SandboxInfo` | no | no | answer |
| `editors` | 2 | (none) | `[Editor]` | yes | no | answer |
| `events` | 1 | `name`, `sessionStatus` | `event` lines until the client hangs up | no | no | events |
| `exec` | 1 | `name`, `argv`, `environment`, `user`, `workdir`, `timeoutSeconds`, `wake`, `start` | `ExecOutput` | no | no | answer |
| `files-list` | 2 | `name`, `filePath` | `FileList` | yes | no | answer |
| `files-mkdir` | 2 | `name`, `filePath` | `FileChangeResult` | no | yes | answer |
| `files-move` | 2 | `name`, `filePath`, `fileTarget` | `FileChangeResult` | no | yes | answer |
| `files-new` | 2 | `name`, `filePath` | `FileChangeResult` | no | yes | answer |
| `files-open` | 2 | `name`, `filePath`, `reveal`, `app` | `FileChangeResult` | no | yes | answer |
| `files-rm` | 2 | `name`, `filePath`, `recursive` | `FileChangeResult` | no | yes | answer |
| `files-tree` | 2 | `name` | `FileTreeState` | yes | no | answer |
| `files-tree-set` | 2 | `name`, `fileTree` | `FileTreeState` | no | yes | answer |
| `hibernate` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `host-stop` | 1 | (none) | `ok` line, then the host exits | no | no | answer |
| `image-bake` | 2 | `image` | `ImageRow` | no | no | answer |
| `image-ls` | 2 | (none) | `[ImageRow]` | yes | no | answer |
| `image-rm` | 2 | `image` | `[ImageRow]` | no | no | answer |
| `image-tree` | 2 | (none) | `ImageTree` | yes | no | answer |
| `inspect` | 1 | `name` | `SandboxDetail` (incl. `agentStreams`) | yes | no | answer |
| `key-ls` | 2 | `name` | `[CredentialRow]` | yes | no | answer |
| `key-policy` | 2 | `name`, `policy` | `[CredentialRow]` | no | no | answer |
| `key-rm` | 2 | `name`, `binding` | `[CredentialRow]` | no | no | answer |
| `key-set` | 2 | `name`, `binding`, `secret`, `source` | `[CredentialRow]` | no | no | answer |
| `ls` | 1 | `withSessions` | `[SandboxInfo]` | yes | no | answer |
| `models` | 2 | `modelsSource`, `modelsRefresh` | `[ModelList]` | yes | no | answer |
| `net-log` | 2 | `name`, `deniedOnly`, `follow` | connection records; with `follow`, `connection` events | no | no | events (with `follow`) |
| `net-permissions` | 2 | `name` | `PermissionReport` | yes | no | answer |
| `net-policy` | 2 | `name`, `preset`, `allow`, `deny`, `removeHosts`, `grant`, `revoke` | `NetworkPolicy` (a change needs the host) | no | no | answer |
| `onboard` | 2 | `images`, `base`, `follow`, `requestedBy` | `PrepareResult` | no | no | answer |
| `open-session` | 1 | `name`, `session`, `argv`, `environment`, `user`, `workdir`, `wake`, `start`, `cols`, `rows` | `SessionOpened` | no | no | answer |
| `pause` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `ping` | 1 | (none; any `v`) | `HostStatus` | yes | no | answer |
| `plan` | 1 | `planRequest` | one plan | yes | no | answer |
| `plans` | 1 | `planRequests` (at most 128) | `[plan]` | yes | no | answer |
| `point-fork` | 2 | `name`, `point`, `newName` | `SandboxInfo` | no | no | answer |
| `point-ls` | 2 | `name` | `[restore point]` | yes | no | answer |
| `point-revert` | 2 | `name`, `point` | restore point | no | no | answer |
| `point-rm` | 2 | `name`, `point` | restore point | no | no | answer |
| `point-save-image` | 2 | `name`, `point`, `image`, `note` | custom image | no | no | answer |
| `point-take` | 2 | `name`, `pointName`, `note` | restore point | no | no | answer |
| `port-open` | 1 | `name`, `openPort` | `PortOpened` | no | no | answer |
| `ports` | 1 | `name`, `portAdd`, `portRemove` | `PortsAnswer` | no | no | answer |
| `prepare` | 1 | `images`, `base`, `follow`, `requestedBy` | `PrepareResult` | no | no | answer |
| `prepare-cancel` | 2 | `images` | `[PreparationInfo]` | no | no | answer |
| `prepare-status` | 1 | (none) | `PrepareStatus` | yes | no | answer |
| `rename` | 1 | `name`, `newName` | `SandboxInfo` | no | no | answer |
| `reset` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `resources` | 1 | (none) | `ResourceReport` | yes | no | answer |
| `resources-clean` | 2 | `dryRun` | `ResourcePlan` | no | no | answer |
| `resources-kernel` | 2 | `kernel` | `ResourceKernelChoice` | no | no | answer |
| `resources-rm` | 2 | `ids`, `dryRun` | `ResourcePlan` | no | no | answer |
| `resume` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `rm` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `sandbox-settings` | 2 | `name`, `setting`, `settingValue`, `clearSetting`, `settingFrom` | `SandboxSettingsReport` | no | no | answer |
| `session-end` | 1 | `name`, `session` | `SessionEnded` | no | no | answer |
| `session-grids` | 1 | `grids` (at most 64) | `[SessionGridAnswer]` | yes | no | answer |
| `session-restart` | 1 | `name`, `session`, `fresh` | `SessionRestarted` | no | no | answer |
| `session-screen` | 1 | `name`, `session` | `SessionScreen` | yes | no | answer |
| `sessions` | 1 | `name` | `[SessionRow]` | no | no | answer |
| `shutdown` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `sleep` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `start` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `template-create` | 2 | `name`, `point`, `image`, `note` | `CustomImage` | no | no | answer |
| `terminal-layout` | 2 | `name` | `TerminalLayout` or null | yes | no | answer |
| `terminal-layout-set` | 2 | `name`, `layout` | `TerminalLayout` or null | no | yes | answer |
| `tools` | 2 | `name` | `ToolsLayerReport` | no | no | answer |
| `tools-apply` | 2 | `name` | `ToolsLayerReport` | no | no | answer |
| `wake` | 1 | `name` | `LifecycleResult` | no | no | answer |
| `workspace-rules` | 2 | `name`, `paths`, `warnings` | `WorkspaceRulesReport` | yes | no | answer |

Answer types are the Swift types in `DozableHost` and `DozableKit`; their JSON is what the fixtures show for the tier 1
ops. A request field that an op does not list is ignored by it.

## The stability promise

The protocol is a public contract. Within **protocol 1** the host only adds:

- new ops;
- new **optional** request fields, whose absence keeps the old behaviour;
- new fields in results;
- new values in open string sets (phases, severed words, …);
- new event kinds and new host-to-client frame types, **only when the client asked** with a request field.

Within protocol 1 the host never:

- removes or renames an op or a field;
- changes a field's type, meaning or default;
- changes the framing or the line rules.

Any of those is **protocol 2**. A host keeps answering protocol 1 for at least one minor release series after protocol
2 exists **and** for at least six months, whichever is longer. A host that speaks protocol 2 still answers a protocol 1
request in protocol 1.

**A client must:**

- ignore unknown fields;
- tolerate unknown values in open sets;
- treat an unknown error code as `failed`;
- skip an unknown host-to-client frame type;
- feature-detect with `ping`'s `operations`, never by comparing versions.

**Deprecation.** An op or field to be removed in protocol 2 is marked deprecated in this reference and keeps working
until then.

**DozableClient** follows semantic versioning: a minor release is additive, a patch release is a fix, a major release
breaks its API. Its README states which Dozable version each of its features needs.

## Protocol changes

One row per Dozable release that changes the protocol. Everything here is additive within protocol 1.

| Dozable | Change |
|---|---|
| 0.37.42 | New op `agent-stream` (frames; the `stream` request field; `AgentStreamReady`, `AgentStreamEnd`). `ping` gains `operations`, the list of ops the host serves. `inspect` gains `agentStreams`. `v` is now checked for every op, streamed ones and unknown ops included, not only some. Golden fixtures published in `schema/host-protocol-1/` |

## The fixtures

[`schema/host-protocol-1/`](../schema/host-protocol-1/README.md) holds one request, one answer (the exact lines a
client reads) and the frames for each tier 1 op, every event kind and error code, and lines a client must still
tolerate. They are generated by the host's own encoder and a test fails on any drift, so after a change run
`make protocol-fixtures` and commit the diff. `make contract-check CLIENT=<path>` runs a client package's tests
against them.
