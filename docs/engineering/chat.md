# The chat server — `doz chat serve`

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

A chat server for agents and the person who runs them: rooms with members, messages with mentions and answers, direct
messages, and the commands that make rooms and change who is in them. Agents reach it on a **line port** (one JSON
object per line over TCP) and over HTTP on a **page port** (`/agent/…` with a token; the page's own API for the person).
Its wire protocol and its storage are an existing chat protocol's, kept exactly, so that agents and data folders written
for that protocol work here unchanged; an outside-in conformance suite judges it (below).

It is being built in steps. Today the daemon runs it while the setting `chat.enabled` is on, and the `doz chat` group
turns it on and off and takes part in it from the terminal — still **hidden**: `doz chat` is not in `doz --help`, the
manual or completions (`doz chat --help` is complete). A later step shows its rooms in the dashboard and unhides it.

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableChat/ChatJSON.swift` | `JValue`, a JSON value whose objects keep their member order; the writer that produces the protocol's exact bytes (map keys sorted, `<` `>` `&` U+2028 U+2029 escaped, `/` not escaped, floats in shortest plain form, the one-space indent of the data folder's files) and the reader (a key matches a field ignoring case, the last one wins, invalid UTF-8 becomes U+FFFD, a field of the wrong type is an error) |
| `ChatConfig.swift` | `ChatConfig`: the strict loader of `config.json` and the flags that beat it; `ChatAddress` / `ChatAddressPrefix`; `ChatAccess`, who may call what on each port as two pure functions; `ChatPath`, the exact `/agent/` path check |
| `ChatSecrets.swift` | `secrets.json` version 1: tokens hashed (SHA-256) as they are read, webhook entries; compared in constant time |
| `ChatStore.swift` | `ChatRoomStore`: one room's SQLite file (`rooms/<room>.db`), the system SQLite, WAL, `busy_timeout` 5000, one connection on its own serial queue; the protocol's schema statement for statement, then its tolerant `ALTER TABLE`s |
| `ChatTypes.swift` | participants, messages as stored and returned, delivery states, reactions, the sender; the name and id rules |
| `ChatServerCore.swift` | `ChatServerCore`: the directory, rooms and members, posting (duplicates, membership, archive, direct messages, mentions outside code, answers, the hold), the room commands, registered sessions, the data folder's JSON files, the first-start announcement |
| `ChatEvents.swift` | the live stream's events (`ChatEvent`, one `data:` line each), one open page's bounded queue (`ChatSubscriber`) and every page's (`ChatEventBus`) |
| `ChatLive.swift` | after a message is recorded: the stream (the human's view of each event), delivery to an open page and to a participant that polls, presence, `/avatar` and `/session`, the read-only look at Claude Code's session records |
| `ChatPolling.swift` | `GET /agent/receive` (a wait the listener finishes, `ChatLongPoll`) and `POST /agent/ack`: hand-overs, notices, redelivery |
| `ChatEdits.swift` | `/edit`, `/delete` and the page's edit and delete, once per msg_id or `X-Chat-Id`; reveal; `/api/unread` |
| `ChatReact.swift` | reactions: the reaction line (once per its own msg_id), `/react` (once per the message's), the page's call (once per `X-Chat-Id`); toggled, refused in the protocol's words and order, waking nobody |
| `ChatWebhooks.swift` | delivery by webhook: the `chan-message` body, the tries and their schedule, the states, edit and delete notices, the announcement, redelivery at start |
| `ChatInbox.swift` | delivery into a Claude Code session on this Mac: its records read (`sessionStatusAt`, `claudeSession`), the text it is handed (`inboxText`), edit and delete notices, `/protocol` and the announcement (`note`), `started` when it goes busy (`noticeStarts`), the message last handed to it; `UnixLine`, the one client write to its socket |
| `ChatAttachments.swift` | attachments: `ChatFileRules` (the id rule, the name cleaning, the media type from the extension else the bytes, the limits), `attach` (check every file, then store), `saveFile`, `storedFile`, who may fetch a file (`mayFetch`), the files a delete removes, the line port's `file` reply |
| `ChatWebhookClient.swift` | the webhook client (`ChatWebhookPoster`, `ChatURLSessionWebhook`): one POST, no proxy, no redirect followed, the answer's body never read, a deadline on the whole call, a failure reason with no address in it |
| `ChatProtocol.swift` | the protocol's own description (`GET /api/protocol`, `/protocol`) and its version: the first 10 hex of the SHA-256 of that description's encoding |
| `ChatPage.swift` | `ChatPageHandler`: one HTTP request in, one answer out — the access gate, the router (an untidy path is redirected, a wrong method is 405), every route |
| `ChatLinePort.swift` | `ChatLineConnection`: one line-port connection's state and what each line does (a reply, nothing, or a close) |
| `ChatListeners.swift` | the two swift-nio listeners: JSON-lines framing (a line of 32 MiB or more closes the connection; 30 s without a line closes it) and HTTP/1.1 with keep-alive; work is handed off the event loop, in order per connection |
| `ChatServer.swift` | one server's life: the data folder's lock (`server.lock`), `status.json`, the signals, the exit codes; `doz chat status` |
| `ChatOwnerSocket.swift` | the owner's private socket: who may serve it (a 0700 folder of this user, the socket 0600) and who may connect (`admit`: this user only) |
| `Sources/DozableCLI/ChatCommandLine.swift` | `doz chat serve` and `doz chat status --data-dir`, dispatched by `DozableEntry` before anything else of doz runs (`isServerCommand`) |
| `Sources/DozableHost/ChatDirectory.swift` | under the daemon: the store's chat folder (`ChatPaths`), Dozable's records (`ChatDirectory`, `ChatTokenHashes`), names, tokens, the generated `config.json` (`ChatConfigFile`), `ChatRestartPolicy` |
| `Sources/DozableHost/ChatSupervisor.swift` | `ChatSupervisor`: the server as the daemon's child — the generated files, posix_spawn, readiness, restarts, stops; `ChatServerState` (`supervisor.json`, `daemon status`); `ChatProcesses`, the seam the tests fake |
| `Sources/DozableHost/ChatOwnerClient.swift` | the person's HTTP client on the owner's socket (the `doz chat` commands; the dashboard later) |
| `Sources/DozableCLI/ChatCommands.swift` | the `doz chat` group (hidden): on, off, status, add, remove, who, token, rooms, room, send, read |
| `Tests/DozableChatTests/` | `ChatConfigTests` (the loader, the secrets file, JSON bytes), `ChatAccessTests` (the access table, `agent_addresses`, the path check), `ChatStoreTests` (a room file written by the protocol's reference server opens and reads back; a new file has the same schema), `ChatServeIsolationTests` (the real `doz` in an empty home, also calling a webhook), `ChatPostingAndReadingTests` (the stream and its resync, also over a real listener; polling; edit and delete once; unread; stubs; presence and avatars), `ChatWebhookTests` (against `TestWebhookListener`, a listener each test starts on 127.0.0.1: the call, the tries, every limit of the client, no secret anywhere, notices, the hold, redelivery once; reactions), `ChatSessionsAndFilesTests` (against `TestClaudeSession`, a record and key file in a scratch sessions folder and a socket the test listens on: the inbox text, failed, `/protocol`, `/react`'s fallback, notices, started, the announcement; names never paths, the limits before a byte is kept, the human's token, download headers, who may fetch, a delete's files; the msg_id start rule) |
| `Tests/Conformance/RUNNER`, `Tests/Conformance/expected-green.txt`, `Scripts/chat-conformance.sh` | the conformance gate (below) |

## The rules

- **No VM parts.** `DozableChat` imports Foundation, Darwin, CryptoKit, SQLite3, NIOCore, NIOPosix and NIOHTTP1 only, and
  depends on no other target of the package — not DozableKit, DozableHost or DozableWeb, and not Security, so it cannot
  reach the Keychain. Whatever it will need of Dozable is handed to it by the code that starts it. `Scripts/audit.sh`
  step 1d holds the imports and the manifest; NIOHTTP1 is allowed only here and in DozableWeb, SQLite3 only here and in
  DozableHost.
- **Isolated.** `doz chat serve` reads no settings file, opens no store, starts no daemon, makes no sandbox, touches no
  Keychain and writes no file outside its data folder: everything it needs is its config file, its flags and its secrets
  file. `DozableEntry` dispatches `doz chat` before the recipe catalogue, the usage hook or the update check run.
  `ChatServeIsolationTests` runs the real binary with an empty `HOME` and `TMPDIR` and a `DOZ_STORE` and
  `XDG_CONFIG_HOME` that must never appear, and lists every file afterwards.
- **What it touches outside its data folder — exactly this, and only to deliver to a Claude Code session on this Mac
  (a participant whose `deliver` is `inbox-socket`), as the reference does:**
  - it READS Claude Code's session records: every `<pid>.json` in the sessions folder (a session's `name`, `status`,
    `statusUpdatedAt`, `messagingSocketPath`; a record whose pid does not run is passed over) and, for the session it
    delivers to, its `<pid>.*.key` (`peerToken`). The folder is a value handed to the server — `--claude-sessions DIR`,
    by default `$HOME/.claude/sessions` as in the reference. Nothing there is ever written, made or removed.
  - it CONNECTS, as a client, to the Unix socket the running session's record names, and WRITES one auth line (with
    that token, when there is one) and one message line — 5 s to connect and to write; nothing is read back.
  - It makes no socket of its own, writes no session record and is not a Claude Code peer (the reference's `peer_name`
    is refused by the config, and `/tmp/cc-socks` is never used). Every test keeps both in scratch: `TestClaudeSession`
    writes its record and key in a sessions folder the test made and listens on a socket in a folder it made under
    `/tmp` (it refuses a real `~/.claude` or `/tmp/cc-socks`); the conformance runner fakes its session in the home it
    makes for each check. `ChatServeIsolationTests` checks the real binary leaves the records untouched and the home
    empty.
- **Strict config.** An unknown key, a value of the wrong type, an address or range that is not one, a
  `test_owned_addresses` entry that is not loopback, a peer name or an HTTPS port (this server has neither), or
  `secrets_file_only` off is a fault. Ports given as 0 are picked by the system (`status.json` says which).
- **The kept-service contract.** It runs in the foreground and logs to standard error. It takes a POSIX lock on
  `<data>/server.lock` for its whole life and writes `<data>/status.json` (`running`, `ready`, the ports, counts,
  problems; refreshed every 5 s; removed on a clean stop). SIGTERM, SIGHUP and SIGINT stop it with **0**. A fault a
  restart cannot fix — a bad flag or config, a port in use, a data folder it cannot make or write, a second server on
  the same folder (the first is left alone), a secrets file it may not read — is ONE line on standard error and exit
  **78**. It listens on a loopback address only, for now (anything else is refused before the data folder is touched).
- **Tokens are hashes.** A token is hashed as the secrets file is read and the value dropped; a presented token is hashed
  and compared in constant time; a token shorter than 16 characters is never one. No token is logged, put in
  `status.json`, or written anywhere. A registered session's token is made here, shown once in the answer, and kept as its
  hash in `agents.json`.
- **Who may call what** (`ChatAccess`). The owner's own machines are exactly the loopback addresses the config lists
  (`test_owned_addresses`); with none, nothing is owned. The page port serves only owned callers (403 with the protocol's
  text otherwise); a caller on `require_tokens_from` gets only `/agent/` calls. The line port admits owned and `allow`
  addresses and asks for a token unless the caller is owned and not listed. `/agent/` calls always need a Bearer token.
  Every answer of the page port carries `Strict-Transport-Security: max-age=0`. The `/agent/` path check is exact: what a
  router would tidy (`..`, `.`, `//`, another case) is refused, not followed.
- **`agent_addresses`.** A list of addresses or CIDR ranges whose callers are never the person: on the page port they are
  served the token-checked `/agent/` calls and nothing else (403 otherwise); they are never owned (the list beats
  `test_owned_addresses`), so the line port admits them only through `allow`, and always with a token. Absent or empty
  changes nothing. It is how a fenced session reaching the server through `host.dozable.internal` (which arrives from
  127.0.0.1) is kept from acting as the person.
- **The protocol's bytes.** Everything a client reads is written with `ChatJSON` (never `JSONEncoder` or
  `JSONSerialization`), field order as the protocol shapes list it, maps sorted, empty optional fields left out. The data
  folder's JSON files are written as the protocol writes them (one-space indent, mode 0600), here atomically.
- **The store keeps the protocol's format.** A room file the reference server wrote opens here, and one written here opens
  there: the same `CREATE TABLE IF NOT EXISTS` statements in the same order, then the same `ALTER TABLE`s, so the
  resulting schema is identical (`ChatStoreTests` compares it statement for statement with the fixture's).
- **The server's own name is `chat`.** Its change lines and notices are from `chat`, and no participant may be called
  that (a config that has one is a fault; registering it is 409). Lines an older data folder keeps from its earlier
  name are shown as they are. A participant with no `deliver` value that is not the person collects its messages by
  polling, as a registered session does (`ChatParticipant.route`); one delivered to by webhook is refused there (409).
- **Neutral names.** Tests, docs and examples use `ada` (the person), `bot1`, `bot2`, `room1`. The wire strings the
  conformance suite asserts (403 texts, the protocol's own wording) stay as they are.

- **The live stream** (`GET /api/stream`) is the human's view: `data:` lines only, the hello first; nothing of a room
  the human is not in, a direct message between others as a stub, and no state of one. Each open page has a queue of 64
  events; a page that falls that far behind is dropped, gets what was queued, then `resync`, and the stream ends. The
  page listener keeps reading while a stream or a receive is open (no pipelining assistance), so a caller that closes
  ends it at once — that is how the human's presence goes back to away.
- **Delivery.** An open page is shown a message (`delivered`; a page that opens marks what waited). A participant that
  polls is woken and collects it (`/agent/receive`, with `ack=1` and `/agent/ack` the confirmation; unconfirmed after
  60 s, after a restart or with `redeliver=1`, it is handed over again, marked redelivered; never twice at once, whatever
  receives are open). Edit and delete notices for it are kept in the room's file. A receive that waits does not hold a
  thread: the listener finishes it (`ChatLongPoll`). A bot whose `deliver` is `webhook` is called (below).
- **Delivery by webhook.** The address and the Authorization value come from the bot's webhook entry in the secrets
  file (its own entry, else the shared `default`; an `Authorization:` prefix is dropped), and nowhere else. Each message
  to each bot is one background task (`background`, counted), so posting and every other recipient go on while a webhook
  is slow or dead; what one recipient is handed together (held messages, then the new one) goes out in order. Tries: at
  once, 5 s later, 20 s after that (`webhookBackoff`), each with a 30 s deadline on the whole call (`webhookTimeout`); a
  2xx answer marks it `woken` and `delivered` ("its webhook accepted it (200) in N ms"), three failures `failed` with the
  last reason ("webhook try 3: status 500", "… could not reach the webhook (connection refused)"); no entry fails at
  once. The body is the protocol's `chan-message` (the `[switchboard] ` prefix of `message_text` is the reference's wire
  text, kept). An edit or delete of a message a bot was handed (and that addresses it) is a `chan-message-edited` or
  `-deleted` call; a new protocol version is one `protocol-updated` call, tried once. Reactions, commands and heartbeats
  call nothing.
- **The webhook client** (`ChatURLSessionWebhook`) connects only to the entry's address: no proxy (the system's settings
  are not read), no redirect followed (the 3xx is the answer, and a failure), no cookies, cache or stored credentials. It
  never reads an answer's body: the call ends at the status line and headers. Its failure reasons name no address and no
  header, so neither reaches a log, a state's detail or the stream. `ChatWebhookTests` holds each of these against a
  listener the test starts.
- **At start, before the ports answer:** what was recorded for a webhook and never handed over (still only `queued`, or
  released from the hold) is handed over again, in order per recipient, unless it was queued more than a day ago
  (`redeliverAfter`); held messages stay held; then a new protocol version is announced, and the start waits up to 2 s
  for the announcement's calls. A stop abandons a call waiting between tries and gives a call in flight up to 2.5 s
  (`stopDeliveryMax`); an abandoned message stays `queued` and goes out at the next start. A message a webhook accepted
  is `delivered` and is never handed over again; one cut off mid-call may be (at least once, as the protocol says: a bot
  tells a repeat by its msg_id).
- **Reactions** toggle (the same reaction again takes it off), are stored by name for the standard ones, are refused in
  the protocol's order (no room, not a member, archived, not a reaction, no such message — also for a direct message the
  reactor may not read —, deleted), mark the reactor heard, and are one `reaction` event on the stream (`removed` when
  taken off); a delete erases them.
- **Delivery into a Claude Code session.** Each message is handed over in the background, in order per recipient: the
  session found by its name (above), one line on its socket; `delivered` ("in the session's inbox in N ms"), or `failed`
  with why ("no running Claude session with that name", the socket's refusal). The text is the reference's: a header
  (room, sender with how it was checked, the msg_id's start, what it answers, `mentions you`, to whom or `direct`), every
  line of the sender's text marked `  │ `, the attachments as paths in the data folder, how to take it, and that it is a
  note from a peer, never the user typing. The line is from `switchboard` and the answer it suggests is
  `switchboard send …` — the reference's wire text, kept (Dozable's own command for it comes later). An edit or delete
  of a message the session was handed is a notice there; `/protocol` from the session goes to its inbox ("queued");
  a new protocol version is a note there at start; a message is `started` when the session's record turns busy after
  the hand-over (looked at once a second); `/react` with no message named takes the one last handed to it (kept in
  memory, as the reference). What waited for a session when the server stopped is handed over at the next start.
- **Attachments.** Kept in the data folder at `files/<id>/<name>` — the id 128 random bits in hex, the folder 0700, the
  file 0600, written with `O_EXCL | O_NOFOLLOW` — in the reference's layout. A caller's name is never a path: its last
  part only (a backslash is a separator too), every character but `A-Za-z0-9._ ()+-` made `_` (a NUL, a separator, any
  other byte), leading dots and spaces dropped, `file` when nothing is left, at most 120 bytes. The limits — 10 files on a
  message, 20 MiB a file, nothing empty — are checked for every file of a message before any is written; an upload's body
  is kept up to one file and one byte (`ChatPageHandler.bodyLimit`) and more is 413 unread. Uploading
  (`POST /api/files?name=`) needs the human (its token where tokens are required). The media type is the extension's,
  else what the first 512 bytes look like. An id is looked up only when it is 16 or 32 lower-case hex digits, and a
  folder holding anything but one regular file is no attachment. A webhook body and a receive item list a message's
  files, never their bytes; a Claude session is told where they are on this Mac. A delete removes the files no other
  message names.
- **Who may fetch a file** (`mayFetch`) — stricter than the reference, which serves any id to any caller: a file a
  message names goes only to a member of that message's room who may read it (a direct message: its sender, those it is
  for, anyone once revealed); a file no message names yet (an upload) goes to whoever has its id. On the page's
  `GET /files/<id>/<name>` the caller is the participant whose token comes as `Authorization: Bearer` (from one of the
  owner's own callers `X-Chat-Token` too); with no token, the owner's socket or an owned caller is the human. An agent
  address — loopback under the daemon, where a fenced session or a polling client calls from — is served this one path
  besides `/agent/`: `GET` or `HEAD` of an exact `/files/<id>/<name>` (nothing a router would tidy) with a Bearer token
  (`ChatPath.isFilePath`, `ChatPageHandler.isTokenFileFetch`); without one it is 403, and a token that is no one's, or
  the human's, fetches nothing (404) — an agent address is never the human. The line port's `file` line is the token's
  participant, else the name the line gives, else (an owned connection) the human. Anything else is the plain 404 or
  "no such attachment", the same as an unknown id. A download carries `Accept-Ranges: bytes`,
  `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, and anything but a PNG, JPEG, GIF or WebP is
  `Content-Disposition: attachment` (HTML and SVG included). One byte range (`a-b`, `a-`, `-n`) is 206 with
  `Content-Range` and the same headers; a start past the end is 416 (`Content-Range: bytes */size`); several ranges, or
  one that cannot be read, get the whole file. `HEAD` gets GET's headers and length. `ChatFileFetchTests`.
- **The start of a msg_id** (`/edit ^…`, `/react ^…`, `re_msg_id`, reveal) must be `^[0-9A-Fa-f-]+$` to find a message;
  anything else (empty, `%`, `_`) matches nothing and is returned as given.

## Under the daemon

**The folder.** `<store>/chat/`, 0700, every file in it 0600 and written atomically:

| File | What |
|---|---|
| `directory.json` | Dozable's record — the human and the participants (name, kind, when added). Owned by the daemon, never edited by hand |
| `tokens.json` | `{"version":1,"sha256":{name: hex}}` — the participants' tokens as SHA-256 only; the server reads it with `--token-hashes` |
| `config.json` | generated (`ChatConfigFile`) from the settings and `directory.json`, judged by `ChatConfig.parse` before it is written |
| `chat.sock` | the owner's socket (`--owner-socket`) |
| `server.log` | the server's standard error, appended; kept to one older copy at 2 MiB |
| `supervisor.json` | the supervisor's state (`ChatServerState`) — `doz chat status` and `doz doctor` read it with no daemon |
| `data/` | the server's data folder, in the protocol's format; rooms after the first are the server's own (`rooms.json`) |

A store whose `chat.sock` path would be longer than 103 bytes cannot have chat (`on` and `doctor` say so).

**The generated config** is one profile: `bind` and `allow` loopback only, `require_tokens` true, `agent_addresses`
127.0.0.0/8 and ::1, `secrets_file_only`, no `test_owned_addresses`, the human `deliver: web`, each participant with no
`deliver` value (so it polls with its own token — a `poll` value is a registered session's and is never checked against
the token hashes), one room (`general`, the human). The generator asserts the profile; `ChatServer` refuses a
non-loopback bind anyway. With it, **no TCP caller is ever the human**: the page port answers 403 outside `/agent/…` (every
loopback caller is an agent address), and the line port always asks for a token. The human comes in through the owner's
socket only. No `inbox-socket` participant is generated in this step.

**The owner's socket** (`ChatOwnerSocket`, `ChatListeners`). The server serves the page's whole API (its stream too) on
`<store>/chat/chat.sock` to `ChatCaller.owner`: the human, no token, posts marked checked. It refuses to start unless the
socket's folder is 0700 and the user's own; the socket is made 0600; each connection's peer must run as this user
(LOCAL_PEERCRED; an unknown peer is refused). A fenced session runs as the same user: Seatbelt keeps it out (the fence
closes the store and every Unix socket but its own doors — `make test-cli-fence` row 1.7c). Any other program the same
person runs may use it (a terminal client reads its path from `doz chat status --json`'s `ownerSocket`).

**Tokens.** The daemon makes one (`dzc_` and 32 random bytes, base64url) or takes one given on standard input
(`--from-stdin`, 16 to 256 characters); hashes it at once; writes only the hash. The value travels once, in the daemon's
answer to the command that asked (nothing of a request is logged), and the CLI prints it once on a terminal, or writes
it to a new 0600 file (`--to-file`, never over an existing one) — never into a pipe, a log, `--json` or argv.

**The supervisor** (`ChatSupervisor`, owned by `HostServer`; one serial queue). Wanted: `chat.enabled` while the daemon is
not stopping and its program has not been replaced. The daemon looks every second (the settings every 5 s; a `doz chat`
change at once):
- the files are brought up to date; a server started with other bytes (a participant, a token, a port) is restarted;
- the child is the daemon's own program: `doz chat serve --config … --bind 127.0.0.1 --token-hashes … --owner-socket …
  --supervised`, by posix_spawn (no shell), an environment allowlist (HOME, PATH, LANG, TMPDIR, and DOZ_TEST_* in a
  guarded run), stdin /dev/null, stdout and stderr to `server.log`, no other descriptor, its own process group;
- ready means its `status.json` says so for the pid holding `server.lock`, within 15 s;
- `ChatRestartPolicy`: exit 78 is `stopped` with its last line (a port in use names the setting to change) and is tried
  again only when the files change or on `doz chat on`; anything else backs off 1, 2, 4, 8, 16, 32, 60 s (reset after 10
  minutes up), and 5 failures in 10 minutes is `failing` until `doz chat on`;
- before spawning, a server already holding the data folder is ours from before (its argv names our config:
  KERN_PROCARGS2) and is stopped, or anyone else's and refused — two servers never share a data folder;
- a stop is SIGTERM, 5 s, then SIGKILL, and happens before the daemon lets go of the store's lock in `shutdown`,
  `restartInPlace` and `handOver`;
- `--supervised` makes the server exit 0 the moment its parent is gone (a kqueue watch, and a look at the parent pid each
  second), so a daemon killed with SIGKILL leaves no server behind.

Ports must differ and never be a dashboard's (`ui.port`, `serve.port`): a clash is a `stopped` problem. Chat on keeps the
daemon running even with `daemon.always_on` off (`IdleDecision.chatOn`), and its program replaced by rename restarts it in
place (a person's `--foreground` daemon still exits); the login item counts it as one keeper.

**The settings** (`ui: false`, no environment variable — consent is never one): `chat.enabled` (false), `chat.page_port`
(8790), `chat.line_port` (8791).

**The commands** (hidden). Only `chat serve` and `chat status … --data-dir` are the server's own (`isServerCommand`); the
rest is `ChatCommand`. Writes go through the daemon (`chat-sync`, `chat-add`, `chat-remove`, `chat-token`); `rooms`,
`room`, `send`, `read` and `who` go to the owner's socket; looking never starts the daemon. Exit codes: 0, 1 failed, 2 no
such participant or room, 4 already exists, 6 chat is off or not ready, 64 usage.

```bash
doz chat on --name ada          # Chat is on: 127.0.0.1, page port 8790, line port 8791. You are ada.
doz chat add bot1               # its token, once (or --to-file F)
doz chat room room1 @bot1       # Made room1 with ada, bot1.
doz chat send room1 "hello @bot1"
doz chat read room1 --follow
curl -s -H "Authorization: Bearer $T" "http://127.0.0.1:8790/agent/receive?wait=10"
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
     -d '{"room":"room1","message":{"content":"hi ada"}}' http://127.0.0.1:8790/agent/send
```

Tests: `ChatDirectoryTests`, `ChatRestartPolicyTests`, `ChatSupervisorTests` (a fake process table), `ChatIdleAndSettingsTests`,
`ChatTokenHashesTests`, `ChatOwnerSocketTests`, `ChatProfileTests`, `ChatDaemonProfileServeTests` (a plain HTTP/1.1 client
on the socket, TCP never the human, the parent watch), and `make test-cli-chat` (the whole of it end to end, no VM).

## What is not there yet

Room apps, their manifests, pages and icons (changing one: 401 for anyone but the human, else 501; their routes answer
501), the service worker, and the reference's "local links": a Claude session attaching a file by naming its path on
this Mac in a Markdown link. That one is left out on purpose: it would let whoever speaks as that session copy any file
the server can read into a room, which is beyond what this server may touch outside its data folder (above); a link
there stays text.

## The conformance gate

The reference implementation's own outside-in suite judges this server over its ports only: it writes a config, a data
folder and a home for every check, starts `doz chat serve --config {config} --bind {bind}` on 127.0.0.1 with two ports it
picked, waits until the line port accepts and `GET /api/state` answers, runs the check, and stops it with SIGTERM.

The runner is a program of a private repository, so it is not here. `Tests/Conformance/RUNNER` pins its version and
SHA-256; `Tests/Conformance/expected-green.txt` is the ratchet — the checks that must PASS, by the names the runner prints.
A check that was green may never turn red; a new green check is added in the same change.

```bash
make test-chat-conformance             # cli, then Scripts/chat-conformance.sh against .build/debug/doz
CHECKS='TestS1_|TestS9_' make test-chat-conformance   # a subset (the runner's -test.run)
```

The script finds the runner at `$DOZ_CHAT_CONFORMANCE`, else `~/.cache/doz/switchboard-conformance`. Without one it
prints `conformance: not run (private runner)` and passes, which is what CI and contributors see. It refuses a runner
whose SHA-256 differs from the pin, and a ratchet that names a check twice or has fewer names than the pin's `minimum`
(`ConformanceRatchetTests` holds the same in `make test`). It runs the runner with `-no-room-apps` (room apps are not
here; their calls answer 501, and a change without the human's token is 401 first) and hands it the ratchet as its
`-expect FILE`: it prints the `SUMMARY` and
`EXPECT` lines, fails for every ratchet check that is not PASS (`EXPECT-MISSING`, with the runner's first message for
it), and lists every PASS not yet in the ratchet (`EXPECT-EXTRA`). `CHECKS=` runs a subset as a look only: it prints
that subset's failures and does not judge the ratchet. The checks of the kept-service
contract's own flags are always SKIP under this mode; the contract is judged by every check starting and stopping the
server instead. A new runner version is a deliberate change: bump `RUNNER`, run it, and commit the ratchet with it.

The runner's `-test.list` prints the check names only with `-test.v` (in its report mode the list goes to its log and it
reports a failed run).
