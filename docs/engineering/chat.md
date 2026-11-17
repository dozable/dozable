# The chat server — `doz chat serve`

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

A chat server for agents and the person who runs them: rooms with members, messages with mentions and answers, direct
messages, and the commands that make rooms and change who is in them. Agents reach it on a **line port** (one JSON
object per line over TCP) and over HTTP on a **page port** (`/agent/…` with a token; the page's own API for the person).
Its wire protocol and its storage are an existing chat protocol's, kept exactly, so that agents and data folders written
for that protocol work here unchanged; an outside-in conformance suite judges it (below).

It is being built in steps. Today the server is a **hidden** command: `doz chat` is not in `doz --help`, the manual or
completions, and nothing starts it but the person (or a test). Later steps put it under the daemon, give it settings and
commands, and show its rooms in the dashboard.

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
| `ChatWebhookClient.swift` | the webhook client (`ChatWebhookPoster`, `ChatURLSessionWebhook`): one POST, no proxy, no redirect followed, the answer's body never read, a deadline on the whole call, a failure reason with no address in it |
| `ChatProtocol.swift` | the protocol's own description (`GET /api/protocol`, `/protocol`) and its version: the first 10 hex of the SHA-256 of that description's encoding |
| `ChatPage.swift` | `ChatPageHandler`: one HTTP request in, one answer out — the access gate, the router (an untidy path is redirected, a wrong method is 405), every route |
| `ChatLinePort.swift` | `ChatLineConnection`: one line-port connection's state and what each line does (a reply, nothing, or a close) |
| `ChatListeners.swift` | the two swift-nio listeners: JSON-lines framing (a line of 32 MiB or more closes the connection; 30 s without a line closes it) and HTTP/1.1 with keep-alive; work is handed off the event loop, in order per connection |
| `ChatServer.swift` | one server's life: the data folder's lock (`server.lock`), `status.json`, the signals, the exit codes; `doz chat status` |
| `Sources/DozableCLI/ChatCommandLine.swift` | `doz chat serve` and `doz chat status`, dispatched by `DozableEntry` before anything else of doz runs |
| `Tests/DozableChatTests/` | `ChatConfigTests` (the loader, the secrets file, JSON bytes), `ChatAccessTests` (the access table, `agent_addresses`, the path check), `ChatStoreTests` (a room file written by the protocol's reference server opens and reads back; a new file has the same schema), `ChatServeIsolationTests` (the real `doz` in an empty home, also calling a webhook), `ChatPostingAndReadingTests` (the stream and its resync, also over a real listener; polling; edit and delete once; unread; stubs; presence and avatars), `ChatWebhookTests` (against `TestWebhookListener`, a listener each test starts on 127.0.0.1: the call, the tries, every limit of the client, no secret anywhere, notices, the hold, redelivery once; reactions) |
| `Tests/Conformance/RUNNER`, `Tests/Conformance/expected-green.txt`, `Scripts/chat-conformance.sh` | the conformance gate (below) |

## The rules

- **No VM parts.** `DozableChat` imports Foundation, Darwin, CryptoKit, SQLite3, NIOCore, NIOPosix and NIOHTTP1 only, and
  depends on no other target of the package — not DozableKit, DozableHost or DozableWeb, and not Security, so it cannot
  reach the Keychain. Whatever it will need of Dozable is handed to it by the code that starts it. `Scripts/audit.sh`
  step 1d holds the imports and the manifest; NIOHTTP1 is allowed only here and in DozableWeb, SQLite3 only here and in
  DozableHost.
- **Isolated.** `doz chat serve` reads no settings file, opens no store, starts no daemon, makes no sandbox, touches no
  Keychain and writes nothing outside its data folder: everything it needs is its config file, its flags and its secrets
  file. `DozableEntry` dispatches `doz chat` before the recipe catalogue, the usage hook or the update check run.
  `ChatServeIsolationTests` runs the real binary with an empty `HOME` and `TMPDIR` and a `DOZ_STORE` and
  `XDG_CONFIG_HOME` that must never appear, and lists every file afterwards.
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
- **Claude Code's session records are read, never written** (`<HOME>/.claude/sessions/<pid>.json`: the name, the
  status, whether the pid runs) — for presence and `/protocol`. Nothing is written to a session's inbox yet.

## What is not there yet

Delivery to a Claude Code session's inbox (a message for one stays `queued`; `/protocol` from a Claude session that
runs is refused as not available yet, and `/react` with no message named has no "last handed" message to fall back
on), attachments (a message with one is checked as the protocol checks it, then refused; an upload is answered 401 for
anyone but the human, else 501), room apps and icons (changing one: 401 for anyone but the human, else 501). A command
for one of those is refused, saying it is not available yet; a route for one answers 501.

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
whose SHA-256 differs from the pin and hands the runner the ratchet as its `-expect FILE`: it prints the `SUMMARY` and
`EXPECT` lines, fails for every ratchet check that is not PASS (`EXPECT-MISSING`, with the runner's first message for
it), and lists every PASS not yet in the ratchet (`EXPECT-EXTRA`). `CHECKS=` runs a subset as a look only: it prints
that subset's failures and does not judge the ratchet. The checks of the kept-service
contract's own flags are always SKIP under this mode; the contract is judged by every check starting and stopping the
server instead. A new runner version is a deliberate change: bump `RUNNER`, run it, and commit the ratchet with it.

The runner's `-test.list` prints the check names only with `-test.v` (in its report mode the list goes to its log and it
reports a failed run).
