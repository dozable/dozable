# The chat server — `doz chat serve`

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

A chat server for agents and the person who runs them: rooms with members, messages with mentions and answers, direct
messages, and the commands that make rooms and change who is in them. Agents reach it on a **line port** (one JSON
object per line over TCP) and over HTTP on a **page port** (`/agent/…` with a token; the page's own API for the person).
Its wire protocol and its storage are an existing chat protocol's, kept exactly, so that agents and data folders written
for that protocol work here unchanged; an outside-in conformance suite judges it (below).

The daemon runs it while the setting `chat.enabled` is on; the `doz chat` group turns it on and off and takes part in it
from the terminal (listed in `doz --help` and the completions; the manual's page is `docs/manual/36-chat.md`); the
dashboard shows its rooms to the person and acts as them — posting, reacting, editing, deleting, revealing, uploading —
and another browser of the LAN option gets what `serve.chat` allows (below, "In the dashboard").

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
| `ChatWebhookAddress.swift` | a webhook entry's address rule (`ChatWebhookAddress.refusal`: https anywhere but unspecified, multicast, broadcast and link-local; http only to this Mac or 100.64.0.0/10; no user, fragment, space or control character; the header one line) and the pipe the daemon hands the entries on (`ChatWebhookPipe`: `--webhooks-fd`, a FIFO read to its end in 5 s, at most 16 KiB, `{"version":1,"webhooks":{…}}`, a `tokens` member refused) |
| `ChatWebhookClient.swift` | the webhook client (`ChatWebhookPoster`, `ChatURLSessionWebhook`): one POST, no proxy, no redirect followed, the answer's body never read, a deadline on the whole call, a failure reason with no address in it |
| `ChatProtocol.swift` | the protocol's own description (`GET /api/protocol`, `/protocol`) and its version: the first 10 hex of the SHA-256 of that description's encoding |
| `ChatPage.swift` | `ChatPageHandler`: one HTTP request in, one answer out — the access gate, the router (an untidy path is redirected, a wrong method is 405), every route |
| `ChatLinePort.swift` | `ChatLineConnection`: one line-port connection's state and what each line does (a reply, nothing, or a close) |
| `ChatListeners.swift` | the two swift-nio listeners: JSON-lines framing (a line of 32 MiB or more closes the connection; 30 s without a line closes it) and HTTP/1.1 with keep-alive; work is handed off the event loop, in order per connection |
| `ChatServer.swift` | one server's life: the data folder's lock (`server.lock`), `status.json`, the signals, the exit codes; `doz chat status` |
| `ChatOwnerSocket.swift` | the owner's private socket: who may serve it (a 0700 folder of this user, the socket 0600) and who may connect (`admit`: this user only) |
| `Sources/DozableCLI/ChatCommandLine.swift` | `doz chat serve` and `doz chat status --data-dir`, dispatched by `DozableEntry` before anything else of doz runs (`isServerCommand`) |
| `Sources/DozableHost/ChatDirectory.swift` | under the daemon: the store's chat folder (`ChatPaths`), Dozable's records (`ChatDirectory`, `ChatTokenHashes`), names, tokens, the generated `config.json` (`ChatConfigFile`), `ChatRestartPolicy` |
| `Sources/DozableHost/ChatRemote.swift` | agents on other machines: the two settings' rule (`ChatRemoteSettings`) and what the supervisor says of the remote listener (`ChatRemoteState`) |
| `Sources/DozableHost/ChatWebhookEntries.swift` | a webhook bot's entry: its keychain item (`doz-chat-webhook-<store id>-<entry>`, JSON `{"authorization","set","url"}`, at most 1800 bytes), the fingerprint, what `webhook status` may show (`ChatWebhookInfo`), the pipe's bytes, the two-line input |
| `Sources/DozableHost/ChatSupervisor.swift` | `ChatSupervisor`: the server as the daemon's child — the generated files, posix_spawn, readiness, restarts, stops; `ChatServerState` (`supervisor.json`, `daemon status`); `ChatProcesses`, the seam the tests fake |
| `Sources/DozableHost/ChatOwnerClient.swift` | the person's HTTP client on the owner's socket (the `doz chat` commands and the dashboard): request headers, the answer's headers, a cap per call, a stream another thread can cancel (`StreamHandle`) |
| `Sources/DozableWeb/WebChat.swift`, `WebSource/app/*/chat*.js` | the dashboard's Chat page: its closed routes on the owner's socket and the page (web.md, "Chat") |
| `Sources/DozableCLI/ChatCommands.swift` | the `doz chat` group: on, off, status, add, remove, who, token, rooms, room, send, read |
| `Sources/DozableChat/ChatImport.swift` | reading a copy made for import without trusting it, and staging it in this server's format (`ChatImport`); `ImportDB`, the read-only, immutable, `trusted_schema`-off connection |
| `Sources/DozableHost/ChatImporter.swift`, `Sources/DozableCLI/ChatImportCommand.swift` | `doz chat import`: the names against the directory, the data folder put aside, `imported.json` (`ChatImporter`); the command and its dry run |
| `Tests/DozableChatTests/` | `ChatConfigTests` (the loader, the secrets file, JSON bytes), `ChatAccessTests` (the access table, `agent_addresses`, the path check), `ChatStoreTests` (a room file written by the protocol's reference server opens and reads back; a new file has the same schema), `ChatServeIsolationTests` (the real `doz` in an empty home, also calling a webhook), `ChatPostingAndReadingTests` (the stream and its resync, also over a real listener; polling; edit and delete once; unread; stubs; presence and avatars), `ChatWebhookTests` (against `TestWebhookListener`, a listener each test starts on 127.0.0.1: the call, the tries, every limit of the client, no secret anywhere, notices, the hold, redelivery once; reactions), `ChatSessionsAndFilesTests` (against `TestClaudeSession`, a record and key file in a scratch sessions folder and a socket the test listens on: the inbox text, failed, `/protocol`, `/react`'s fallback, notices, started, the announcement; names never paths, the limits before a byte is kept, the human's token, download headers, who may fetch, a delete's files; the msg_id start rule) |
| `Tests/Conformance/RUNNER`, `Tests/Conformance/expected-green.txt`, `Scripts/chat-conformance.sh` | the conformance gate (below) |
| `Guest/dozchat/` (`dozchat.c`, `build.sh`, `build-mac.sh`, `PROVENANCE.md`, `test/`), `Sources/DozableHost/MacDozchat.swift` | `dozchat`, the chat-room member every sandbox and fenced session carries (below, "dozchat"); `Tests/DozableChatTests/DozchatUnitTests.swift` (the C unit check under ASan + UBSan, the escaper against JSONSerialization, the name vectors shared with `ChatFileRules.cleanName`) and `ChatDozchatClientTests` (against the real `doz chat serve`, direct and through a stub proxy) |
| `docs/chat/` | what is published for agents (below, "The protocol, published"): `protocol.md` and `webhook.md` copied unchanged (`Scripts/chat-protocol-sync.sh`), the Python client `client/chat_client.py`, the skills `skills/*/SKILL.md`, a README; tests `ChatPublicDocumentsTests` (the two copies' pinned SHA-256; Dozable's own files there never name the reference or use the word for a central server the chat server is never called, checked by the words' hashes — the two copies exempt by path) and `ChatPythonClientTests` (the client as `/usr/bin/python3 -I`, a scrubbed environment, against the real `doz chat serve`: send, receive, ack, a file both ways, a wrong token, a restart under `listen`; no python3 fails) |

## The protocol, published

An agent that can install nothing must still be able to be a room member. So `docs/chat/` carries the protocol's
public document and its webhook companion, copied UNCHANGED from the protocol's public source at a named tag and commit
(their first line says which; `Scripts/chat-protocol-sync.sh SRC REF` copies them again from REF as committed, never from
a working tree, and prints the new hashes to pin). They are another party's text: their example names and wording stay.
Beside them, Dozable's own: `client/chat_client.py` — one file, Python 3's standard library, a participant that polls
(`send`, `receive`, `ack`, `listen`, `file get|send`, `rooms`, `protocol`); the token from a file of the user's alone or
the environment, never argv or output; no redirects; a timeout on every call; it runs inside a sandbox or a fenced
session through `--host-port` and `--secret … file=CHAT_TOKEN_FILE` (its header) — and the skills an agent loads
(`chat-room-member`, `chat-lead`, `chat-worker`), which name `dozchat` inside a Dozable workspace, the Python client and
`curl` outside, and, for the person, `doz chat …`.
The client was written from the document alone and only then run against this server; where the document did not say
enough is recorded with the feature that published it.

## dozchat — the member every workspace carries

`dozchat` is a small client of this protocol, written in C (`Guest/dozchat/dozchat.c`, libc and POSIX only), so that an
agent in a Dozable sandbox or fenced session is a room member with nothing to install. Its commands and exit codes are
the Python client's (`rooms`, `send`, `receive`, `ack`, `listen`, `file get|send`, `protocol`), plus `send ROOM -` (the
text on stdin, at most 1 MiB) and `react ROOM MSG_ID REACTION`. Its default `CHAT_URL` is
`http://host.dozable.internal:8790`; https is refused ("plain http only; outside Dozable use chat_client.py"). It goes
through the session's own proxy (`http_proxy`, then `HTTP_PROXY`; the request in absolute form, the proxy URL's password
as `Proxy-Authorization: Basic`; `NO_PROXY` exact names or `*`) — inside a sandbox a direct connection to a port with a
secret bound is refused, and a fence has no DNS. stdout carries one compact JSON line per item or answer (the server's
own bytes, whitespace outside strings removed); words for a person go to stderr as `dozchat: …`.

**Where it is.** In a sandbox: the tools layer copies the committed static ELF (`Resources/dozchat`, aarch64-linux-musl,
built with the pinned Zig, PROVENANCE.md, `make dozchat-verify`) to `/usr/local/lib/doz/bin/dozchat` and links
`/usr/local/bin/dozchat` when that name is free — always, with no setting (tools-and-dotfiles.md). In a fenced session:
`dozchat-mac` beside doz (built per release by `Guest/dozchat/build-mac.sh`, never committed; signed and notarised with
doz, CLI flavour only — updates-and-release.md), readable as that ONE file (a `literal` in the profile, like doz itself),
run through the host-owned shim `<session>/etc/bin/dozchat` (`MacFenceSessionFolder.dozchatShim`). An unfenced session
and the helper build have none. Neither path reaches anything the session could not already reach with curl.

**Its rules** (each tested — `make dozchat-check`, `make test`):
- No JSON parser. A request body is literal text plus `json_str` (a strict UTF-8 check: overlong forms, surrogates and
  anything above U+10FFFF refused); an answer is printed as it came; a bounded scanner (depth 64) finds only the
  `messages` array, the ids an acknowledgement gives back (printable ASCII, at most 256 bytes) and `error`/`detail`.
- Every buffer has a hard maximum (an answer 32 MiB + 64 KiB, a head 64 KiB, a header line 8 KiB, a file 20 MiB, text on
  stdin 1 MiB); every size computation is checked; no strcpy/sprintf/strcat/gets; every format string a literal;
  `-Wall -Wextra -Wformat=2 -Wshadow -Wvla -Werror`.
- The token comes from `CHAT_TOKEN_FILE` (O_NOFOLLOW, a regular file of this uid, mode & 077 == 0, at most 4 KiB) or
  `CHAT_TOKEN`; it is never taken on the command line (`--token` and `--url` are refused by name), never printed, never
  in an error, and zeroed before the program ends. Every word on stderr is scrubbed of it and of the proxy's password.
- Plain HTTP/1.1, one connection per call, `Connection: close`: no TLS, no redirect followed (a 3xx is exit 1), any
  `Transfer-Encoding` refused, exactly one Content-Length or none, a deadline on every call (connect 10 s, a call 30 s,
  `receive` its wait + 15 s, a file 120 s).
- `send` is tried three times on "no answer" or a 5xx with the SAME msg_id (a repeat is a duplicate) and says so;
  `listen` retries for ever (1 → 30 s) and acknowledges an item only after its line was written and flushed.
- `file get` checks a full URL is this server's (scheme, host, port), cleans the name by the server's rule
  (`test/clean-name.tsv`, shared with `ChatFileRules.cleanName` and the Python client), reads the whole file into memory
  first, then writes only `openat(the folder, the name, O_CREAT|O_EXCL|O_NOFOLLOW, 0600)`, and removes a partial file.

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
  **78**. It listens on a loopback address (`--bind`; anything else is refused before the data folder is touched) and,
  besides, only on this Mac's own Tailscale addresses the config lists (`remote_bind`, below) — one that is not on an up
  `utun*` interface now exits **75** (not now: tried again with backoff), before any port is bound.
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
  served the token-checked `/agent/` calls and nothing else (403 otherwise: "this machine must use a token: only /agent/
  calls are served to it", or, when `Authorization` carries a token no participant holds, "that token is no one's here:
  an agent machine must send its own participant's token" — `ChatPageHandler.agentRefusal`, the reference's words; the
  same for a `require_tokens_from` machine and a remote listener's caller; `/agent/` answers such a token 401); they are never owned (the list beats
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
- **`/rooms` and `/protocol` from outside a room.** They ask about the sender and the server, not the room: a
  participant is answered them whatever existing room the message names, also one it is not in (or the default room
  when it names none), so that one that was handed a token and nothing else can find out where it is. Everything else
  sent to a room one is not in is refused as before (`ChatServerCore.post`; the runner's
  `TestS3_4_RoomsAndProtocolFromOutsideTheRoom`).
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
- **Delivery by webhook.** The address and the Authorization value come from the bot's webhook entry — in the secrets
  file (its own entry, else the shared `default`; an `Authorization:` prefix is dropped), or, for a server the daemon
  runs, ONLY from the daemon's pipe (`--webhooks-fd`, below; a `secrets.json` in its data folder stays unread) — and
  nowhere else. Each message
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
  are not read), no redirect followed (the 3xx is the answer, and a failure), no cookies, cache or stored credentials; an
  https certificate is judged by the system's roots (no delegate overrides it: "tls: the webhook's certificate is not
  trusted", "…has expired", "…is not yet valid" — `ChatWebhookTLSTests`). It
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
  note from a peer, never the user typing. The line names its sender as the reference does (its wire text, kept); the answer it
  suggests is Dozable's own, `dozchat send <room> --re <msg_id> "…"` (no `--as`: the token decides who sends), and an
  unknown name in `/invite` or `/remove` ends with `doz chat add NAME` — the conformance runner is told both
  (`-answer-cmd`, `-add-cmd` in `Scripts/chat-conformance.sh`). An edit or delete
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
  that is a participant's (`ChatPath.isFilePath`, `ChatPageHandler.isTokenFileFetch`); without one it is the agent-only
  403 (the address rule comes first), and the human's token fetches nothing (404) — an agent address is never the human. From an owned caller a Bearer token that is no one's is the plain 404. The line port's `file` line is the token's
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
| `directory.json` | Dozable's record — the human and the participants (name, kind — `agent`, `claude-session` or `grok-bot` —, when added, and for a webhook bot `deliver: "webhook"` and its entry's name when it is not its own). Still version 1: an older doz ignores the new fields and treats a webhook bot as one that polls. Owned by the daemon, never edited by hand |
| `tokens.json` | `{"version":1,"sha256":{name: hex}}` — the participants' tokens as SHA-256 only; the server reads it with `--token-hashes` |
| `config.json` | generated (`ChatConfigFile`) from the settings and `directory.json`, judged by `ChatConfig.parse` before it is written |
| `chat.sock` | the owner's socket (`--owner-socket`) |
| `server.log` | the server's standard error, appended; kept to one older copy at 2 MiB |
| `supervisor.json` | the supervisor's state (`ChatServerState`) — `doz chat status` and `doz doctor` read it with no daemon |
| `data/` | the server's data folder, in the protocol's format; rooms after the first are the server's own (`rooms.json`) |
| `imported.json`, `data.before-import-<UTC>/` | the last `doz chat import`'s record (counts, room files' SHA-256 — nothing secret) and each earlier data folder it put aside (never deleted by doz) |

A store whose `chat.sock` path would be longer than 103 bytes cannot have chat (`on` and `doctor` say so).

**The generated config** is one profile: `bind` and `allow` loopback only, `require_tokens` true, `agent_addresses`
127.0.0.0/8 and ::1, `secrets_file_only`, no `test_owned_addresses`, the human `deliver: web`, each participant with no
`deliver` value (so it polls with its own token — a `poll` value is a registered session's and is never checked against
the token hashes) — or, for a webhook bot, `deliver: "webhook"` and `webhook: ENTRY` (never an address) —, one room
(`general`, the human). The generator asserts the profile (no `inbox-socket`, every `deliver` empty or `webhook`, no entry
named `default`); `ChatServer` refuses a
non-loopback bind anyway. With it, **no TCP caller is ever the human**: the page port answers 403 outside `/agent/…` (every
loopback caller is an agent address), and the line port always asks for a token. The human comes in through the owner's
socket only. No `inbox-socket` participant is generated in this step.

**The owner's socket** (`ChatOwnerSocket`, `ChatListeners`). The server serves the page's whole API (its stream too) on
`<store>/chat/chat.sock` to `ChatCaller.owner`: the human, no token, posts marked checked. It refuses to start unless the
socket's folder is 0700 and the user's own; the socket is made 0600; each connection's peer must run as this user
(LOCAL_PEERCRED; an unknown peer is refused). A fenced session runs as the same user: Seatbelt keeps it out (the fence
closes the store and every Unix socket but its own doors — `make test-cli-fence` row 1.7c). Any other program the same
person runs may use it (a terminal client reads its path from `doz chat status --json`'s `ownerSocket`).

**Webhook bots and their entries.** `doz chat add NAME --webhook [--webhook-entry E]` adds a bot the server calls with
each message for it, at its entry (E, by default its own name; one entry may serve several bots; `default` is refused, so
no bot ever falls back to an entry nobody chose). The bot still SENDS with its own token. The entry — the address and the
Authorization value, sent verbatim (empty: no header) — is `doz chat webhook set E`: two lines on standard input (never a
terminal: nothing is echoed) or `--from-file F` (a regular 0600 file of this user, never a link). The daemon judges it
again (`ChatWebhookAddress`), refuses it while the login keychain is locked here ("run it in the Mac's own session" — no
memory-only fallback that would vanish at the next start), and keeps it in ONE login keychain item through the keychain
seam (`CredentialServices.forHost().keychain`; `DOZ_TEST_CREDENTIALS=memory` in every test — `TestSafety` stops a guarded
run that would touch a real `doz-chat-webhook-*` item). The supervisor reads each entry in use once (not at every look),
again a minute after it could not be read, and after a set or remove; it hands the readable ones to the server on a pipe:
posix_spawn makes the read end the child's descriptor 3 (`--webhooks-fd 3`, accepted only with `--supervised` and
`--token-hashes`), the bytes are written whole and the write end closed before the child starts, and nothing else is
inherited. A change of an entry restarts the server (under a second). The entry is the truth at each try: messages still
waiting for the bot (queued, not yet accepted) go to the NEW address with the new value when the restarted server hands
them over, never to the old one; after `webhook remove` they fail at once with the protocol's words ("no webhook address
for bot1 in the file store or the Keychain") and go nowhere (`ChatWebhookTests`). The call's `User-Agent` is
`doz/<release> chat` — the release number only. An entry that is missing or cannot be read is
withheld and said (`supervisor.json`'s `webhooks`: `set` / `not set` / `unreadable` — never a value — and `warnings`,
shown by `chat status`, `chat who` and `doctor`); a message for that bot fails at once. `doz chat webhook status [E]`
shows set or not, the scheme, host and port, a 12-hex fingerprint of sha256(address, header) and when it was set — never
the path, query or header (a path can carry a secret); `webhook remove E` deletes the item and names the bots that now
get nothing. These are `chat-webhook-set|remove|status`, answered only on the daemon's socket: no web action names a
`chat-*` operation (`ChatWebhookAddressTests`), no setting or environment value holds an entry, nothing of the request is
logged. Tests: `ChatWebhookAddressTests`, `ChatWebhookSupervisorTests` (descriptor 3 only, never argv, the environment or
a file; read once; restart on a change; locked and unreadable entries), `ChatWebhookTLSTests`, `make test-cli-chat` rows
15–20 (a planted `data/secrets.json` ignored, the refusals, delivery to the suite's listener, the leak sweep over every
log, file, `--json` and sampled `ps` output, nothing open to others, exactly two listeners).

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
- the server sets its umask to 077 at start, so SQLite's `-wal` and `-shm` files are the user's alone too;
- `--supervised` makes the server exit 0 the moment its parent is gone (a kqueue watch, and a look at the parent pid each
  second), so a daemon killed with SIGKILL leaves no server behind.

Ports must differ and never be a dashboard's (`ui.port`, `serve.port`): a clash is a `stopped` problem. Chat on keeps the
daemon running even with `daemon.always_on` off (`IdleDecision.chatOn`), and its program replaced by rename restarts it in
place (a person's `--foreground` daemon still exits); the login item counts it as one keeper.

**The settings** (`ui: false`, no environment variable — consent is never one; the dashboard's settings route refuses
every `chat.*` key, `ServeRulesTests`): `chat.enabled` (false), `chat.page_port` (8790), `chat.line_port` (8791),
`chat.remote_listen` and `chat.remote_agents` ("", below).

## Agents on other machines

Turning the remote listener on opens both chat ports on this Mac's Tailscale address to the machines named in
`chat.remote_agents` — as agents with their own token only, never as you.

- **The settings** (`ChatRemoteSettings`, type `tailnetAddresses`): `chat.remote_listen` — this Mac's own Tailscale
  addresses to listen on too; `chat.remote_agents` — the other machines let in. Each value is exact IPv4 addresses in
  100.64.0.0/10, comma-separated, at most 16: no range (100.64.0.0/10 would let in every tailnet device up to the token
  check), no LAN, loopback, link-local, wildcard or IPv6 address. Applied at once; set only with `doz config set` on this
  Mac.
- **The generated config** gains Dozable's own key `remote_bind` (the conformance runner never uses it): the addresses of
  `chat.remote_listen` the daemon sees on an UP `utun*` interface now (it looks with the settings, every 5 s; an address of
  100.64.0.0/10 on a LAN or WAN interface — carrier-grade NAT — is not one). `allow` is 127.0.0.1, ::1 and the remote
  agents; `agent_addresses` 127.0.0.0/8, ::1 and the remote agents. The generator asserts every non-loopback `allow` entry
  is a Tailscale address AND an agent address; `ChatConfig.remoteBindRefusal` refuses in `remote_bind` anything outside
  100.64.0.0/10 (so loopback, unspecified, multicast, link-local, a LAN address) and any use without `require_tokens`.
  An address that is missing leaves chat on loopback with a standing problem ("not listening on 100.x.y.z: not an
  address of this Mac now (is Tailscale up?)"); when it appears the files change and the server restarts on it.
- **The server** binds both ports on 127.0.0.1 and on each `remote_bind` address (`ChatListeners`), nothing else. Every
  connection accepted on a remote listener is `ChatCaller.remote`, whatever its address or the config says: on the page
  port only an exact `/agent/` call or `GET`/`HEAD` of an exact `/files/<id>/<name>` with a participant's Bearer token
  (403 `agentOnly` otherwise; a caller not in `allow` 403 `notOwned`; `X-Chat-Token` is not a way in; the human's token is
  no one's there); on the line port a token always, and only for an address in `allow`. One remote address holds at
  most 32 connections at once (the 33rd is closed). Already present: the 32 MiB line, 30 s idle, the body caps.
- **What doz says** — one line per address of `chat.remote_listen` whenever it is set, the same words in `chat status`
  and `doctor` (`ChatRemoteAddressStatus`), each true at that moment: "Also listening on 100.x.y.z (page port 8790, line
  port 8791) for 100.a.b.c — agents with a token only." once the server runs with it; "Remote listening on 100.x.y.z:
  starting…" while the daemon has not looked at the new setting yet or its server is (re)starting with it; "Not
  listening on 100.x.y.z: not an address of this Mac now (is Tailscale up?)" ONLY when the daemon's own look at the
  interfaces did not find it (`--json`: `remote: {listen, agents, missing}` as the daemon last wrote it, and
  `remoteListener: [{address, state, text}]`); `doz daemon status` "chat: also on
  100.x.y.z"; `doz doctor` the same line per address (WARN only for a missing one), WARN for a listener with no remote
  agents, and
  the application firewall read only (`socketfilterfw --getglobalstate`, `--getblockall`, `--getappblocked <doz>`: WARN
  when everything inbound is blocked or doz is).
- **macOS**: accepting connections needs no Local Network permission; the application firewall lets a signed doz in when
  "automatically allow signed software" is on (a daemon's child cannot show its prompt, so doctor reports instead).
- **Tests**: `ChatRemoteAccessTests` — the listeners' internal seam marks a 127.0.0.1 listener remote and reports its
  callers as 100.100.1.2 (neither config nor a flag reaches it; no test binds a tailnet or LAN address): every route of
  `ChatPageHandler` 403 but `/agent/` and a file with a token, the bot's day-one use over the line port (text, an inline
  attachment, the `file` line; closed without a token, with the human's, and for an address not in `allow`), the cap;
  `remote_bind`'s refusals and the `utun` rule; `ChatRemoteDaemonTests` (the settings, the generated config, an injected
  interface list); `ChatServeIsolationTests` (exit 75 for an address this Mac does not have, 78 for a bad one);
  `make test-cli-chat` row 21 (the refusals, the missing address said, still exactly two loopback listeners — `lsof`).

**The commands** (hidden). Only `chat serve` and `chat status … --data-dir` are the server's own (`isServerCommand`); the
rest is `ChatCommand`. Writes go through the daemon (`chat-sync`, `chat-add`, `chat-remove`, `chat-token`, `chat-import`); `rooms`,
`room`, `send`, `read` and `who` go to the owner's socket; looking never starts the daemon. Exit codes: 0, 1 failed, 2 no
such participant or room, 4 already exists, 6 chat is off or not ready, 64 usage.

```bash
doz chat on --name ada          # Chat is on: 127.0.0.1, page port 8790, line port 8791. You are ada.
doz chat add bot1               # its token, once (or --to-file F)
doz chat add bot2 --kind grok-bot --webhook --to-file ~/bot2.token
printf '%s\n%s\n' "$URL" "$AUTH" | doz chat webhook set bot2   # or --from-file F (mode 600)
doz chat webhook status         # bot2: set — https://bot.example:443, fingerprint …, set … (for bot2)
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

## In the dashboard

The dashboard (`doz ui`) shows chat to the person: the rooms, a room's messages (Markdown, a safe subset), live updates, a
composer that posts and attaches, reactions, edits, deletes, Reveal, typing, the hold and the avatar, presence and unread.
It is a CLIENT of the owner's socket, exactly like the `doz chat` commands — no daemon operation, no TCP port, no token:
`DozableWeb` opens `<store>/chat/chat.sock` itself (`ChatOwnerClient`) as the person. Only a closed set of routes reaches
it, each a fixed call built from checked values (web.md, "Chat"); a browser of another computer gets what `serve.chat`
(off | read | write, off by default, set on this Mac only) allows. The page never turns chat on (`chat.enabled` is not
settable from the dashboard): while it is off the page shows `doz chat on --name YOUR-NAME`.

The person is "here" exactly while the Chat page's own stream is open (it closes 5 s after the page is left) — never just
because the dashboard is open — and messages to the person are marked `delivered` then. The sidebar's badge counts what is
unread elsewhere by asking `/api/unread` every minute (no stream). Tests: `WebChatRouteTests`, `WebChatHTTPTests` (a stand-in
owner's socket), `WebChatRealServerTests` (the real `doz chat serve`), `ServeHTTPTests.testChatIsNeverServedToAnotherComputer`,
`WebChatActRouteTests`, `WebChatActHTTPTests`, `WebChatServeTests` (serve.chat's three values and the audit lines),
`WebChatActRealServerTests` (upload, post, react, edit, delete through the dashboard on the real server),
`make chat-markdown-check`.

**What doz says about ports** (`ChatStatusReport.make`): a port or a remote address is said to be listened on only when
the RUNNING server's own status file says so. Just after `doz config set chat.line_port N` the settings name N while the old
server still holds the old port (until the daemon's next look, up to 5 s): `doz chat status` and `doctor` then say
`restarting` with the ports it has and "moving to … (not listening there yet)" (`--json`: `movingTo`), and `doz daemon
status` says "starting on ADDRESS too" until the server runs ready with a new remote address. `ChatStatusMoveTests`.

## Importing a chat's history

`doz chat import PATH [--dry-run] [--add-missing] [--replace] [--json]` brings another chat server's history — rooms,
messages, delivery states, reactions, attachments, member lists, archived rooms, holds, avatars and session links — into
this store's chat, so a conversation moved here resumes instead of starting empty. PATH is a copy made by that server's
own copy script (one plain SQLite file per room in journal mode delete, the data folder's JSON files, `files/<id>/<name>`);
`archived.json`, `holds.json`, `avatars.json` and `sessions.json` are optional.

- **Nothing in the copy is trusted** (`ChatImport.read`). Every path is looked at with lstat: a link anywhere in what is
  imported refuses the copy; a room file's name follows the room rule, an attachment folder's the id rule (16 or 32
  lower-case hex), an attachment's name must be its own cleaned form, one regular file of 1 byte to 20 MiB per folder.
  `secrets.json`, `secrets.lock`, `agents.json` or `tls/` refuse the copy whole — tokens, webhook entries, registered
  sessions and keys never come across. A `server.lock` a running process holds, or a non-empty `-wal`, refuses it. The
  JSON files are at most 4 MiB, parsed with `ChatJSON` (a key twice is refused) and written again by it, never copied;
  `apps.json`, `appicons/` and anything unknown are ignored and listed, never opened.
- **A room file** is checked before it is copied: its first bytes are SQLite's; it is opened `file:…?mode=ro&immutable=1`
  with `trusted_schema` off; its schema is exactly the protocol's six tables (`messages` may lack trailing columns),
  `sqlite_sequence` and the automatic indexes — a trigger, a view, a virtual table, another index, table or column, a
  hidden or generated column refuses it; `PRAGMA integrity_check` must answer ok; every message's text columns are text,
  its recipients and mentions lists of names, its attachments objects with a good id and a clean name, its kind `''` or
  `change`. Then it is copied with `VACUUM INTO` the staging folder (re-hashed: a file that changed meanwhile refuses).
- **Names are never rewritten.** The person is the sender of the history's human messages (more than one person
  refuses): it becomes the store's human ("You are ada in chat — the name the history has."), or must be the store's
  ("names are never rewritten; this store's chat is yours as …" otherwise). Every other name the history uses — members,
  senders, recipients, states, reactions, avatars, session links; not the senders of change lines, which are shown as
  they are — must follow the name rule and be a participant already: the import refuses and prints the `doz chat add`
  commands (the kind from the identity its messages carry, `claude-session` also when it was delivered into a Claude
  session, `--webhook` when the other server called it by webhook), or `--add-missing` adds them as tokenless
  participants of that kind with no `deliver` (they keep their rooms, and cannot connect until `doz chat token NAME
  --new`). A room file with no member list comes across with the person alone in it (listed).
- **Waking nobody** (on the staged copy, `ChatRoomStore.quietForImport`): every (message, recipient) still waiting
  (`pending`: queued, or released from the hold) and every unconfirmed hand-over, for anyone but the person, gets a
  `cancelled` state, "imported: not handed over again"; hand-overs and notices are dropped; held messages stay held (the
  person's next post releases them, as always). `protocol-version` is this build's, so the first start announces nothing,
  calls no webhook and hands nothing over. `ChatImportTests` starts a real core on the staged folder: no webhook call to a
  listener, an empty receive, no change line.
- **Mechanics.** The daemon does it (`chat-import`, on the daemon's socket only), on the supervisor's queue, refused while
  chat is on (the setting, a child, or any server holding the data folder: "doz chat off first"). The copy is staged in
  `<store>/chat/.import-<random>` (0700, files 0600). The store's data folder is never merged, overwritten or deleted: one
  that holds history (a message not from `chat`, or a file) refuses the import unless `--replace`; then — or when it holds
  only the first start's own lines — it is renamed to `data.before-import-<UTC>`, and the staged folder renamed into its
  place. `imported.json` in the chat folder records when, the counts, each room file's SHA-256 and the folder kept aside.
  Importing the same copy again is refused (history), or with `--replace` gives the same result.
- **`--dry-run`** runs in-process and writes and starts nothing: rooms with their counts, members, archive and hold, the
  person, the names missing with the commands to add them, what would be cancelled, what is dropped and ignored, the
  store's own history, and every problem — exit 0 when the import would go ahead, else the first problem's code (1 the
  person, 2 missing names, 4 history, 6 chat on). A refused copy is exit 1. `--json` gives the same report; no report
  holds a token or a secret.
- **Before importing a real copy:** chat off; the participants the dry run names added first (or `--add-missing`); the
  person the history names is you (a store that has another name for you is refused).
- **Tests**: `ChatImportTests` (the reference-built `Fixtures/import1` — made by the workspace's probe
  `make-import-fixture.py` with the reference server and finished by its own copy script — every row intact, nobody woken,
  a 16-hex id, the older `room1.db`, and every hostile copy refused with the copy unchanged), `ChatImporterTests` (names,
  the person, history kept aside, refused while on, a dry run writes nothing), `make test-cli-chat` rows 22–27.

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
