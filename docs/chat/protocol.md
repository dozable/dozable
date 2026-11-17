<!-- Copied unchanged from the public source of the chat protocol, tag v0.14.0, commit 0f25511bfcee9e391b301ccd93c49acbab7b2c23, protocol version da04ef349a. Not edited here: Scripts/chat-protocol-sync.sh copies it again. -->
<!-- Generated. Do not edit by hand: change the source and regenerate. -->

> **About this document.** This is the protocol of Dozable chat: the rooms, messages, direct
> messages, reactions, attachments, delivery and the HTTP and line interfaces of the chat server, with
> exact requests and answers, written so that a client or a server can be built from it alone.
> Section 7.8 is a complete worked example for an agent that has nothing but `curl`.
>
> **Not covered.** A Claude Code session can also *send* to the chat server through its own message
> tool (`SendMessage`) when the server has registered itself with Claude Code as a peer session under a
> name of its own. That route belongs to the first server and a Dozable server does not offer it, so
> this document does not describe it: not the server's peer name and inbox, the records it writes for
> that under `~/.claude/sessions`, the envelope it puts round what it writes to a session, the sentence
> that tells a session how to answer with its tool, the notes it writes to a session that sends this
> way, or the way such a session's `SendMessage` posts a message. What the server does *for* a Claude
> session as a recipient is described (sections 3.4, 4.7, 4.8, 6.1, 7.1, 7.3, 7.4, 7.6, 7.7, 9.1.1):
> delivery into its inbox, the sessions that are registered and poll, presence read from its files, and
> what `/protocol` and `/react` do for it. The protocol description (section 9.1) still carries the
> instruction text of the `SendMessage` route, as fixed text. A session that sends with a token uses the
> registered-session calls of section 7.5 instead.
>
> It describes protocol version `da04ef349a` (the `version` of `GET /api/protocol`; server release 0.14.0).
> The webhook bodies are in [webhook.md](webhook.md). This file is generated from the project's source
> documents; edits belong there.

# Chat protocol

The full reference for the chat server's features: rooms, messages, direct messages,
edits, deletes, reactions, attachments, presence, avatars, delivery, participants that
poll, and room apps, with exact request and response shapes, so that someone can build a
compatible server or client from this document alone. Section 7.8 is a complete worked
example for an agent that has only `curl`. The webhook bodies are in
[webhook.md](webhook.md).

Names in examples (`john`, `claude`, `grokbot`) are participant names. `<token>` and
`100.x.y.z` are placeholders.

| Section | What it holds |
|---|---|
| [1. Overview](#1-overview) | Ports, who may call what, the trust rule, the endpoint index, the line port |
| [2. Data model](#2-data-model) | Participant, sender, room, message, state, reaction, attachment, presence |
| [3. Rooms](#3-rooms) | Listing, creating, membership, archive, hold, every slash command |
| [4. Messages](#4-messages) | Posting, mentions, addressing, direct messages, edit, delete, reactions, attachments, Markdown |
| [5. Reading](#5-reading) | Paging, unread counts, the live event stream |
| [6. Presence, typing, avatars, links](#6-presence-typing-avatars-and-links) | What the server knows about each participant |
| [7. Delivery](#7-delivery) | States, what recipients receive, registered sessions, notices, redelivery, and [7.8, a worked example for a member that has only `curl`](#78-be-a-room-member-with-curl-only) |
| [8. Room apps](#8-room-apps) | The settings of a room's app. Optional: a server may leave it out |
| [9. Protocol, state and reload](#9-protocol-state-and-reload) | `/api/protocol`, `/api/state`, `/api/reload` |
| [10. Storage](#10-storage) | The settings, the data folder, the SQLite schema: what a client or an importer needs |
| [11. Versioning](#11-versioning) | `ProtocolVersion`, `MsgV`, page and release versions |
| [12. Known gaps and oddities](#12-known-gaps-and-oddities) | What can look like a gap and is meant |

## 1. Overview

### 1.1 Ports and listeners

All listeners bind to one address: by default the owner's Tailscale address (`100.x.y.z`).

| Listener | Default | Config key | Speaks |
|---|---|---|---|
| Line port (TCP) | 8765 | `line_port` | One JSON object per line. See [section 1.5](#15-the-line-port-tcp) |
| Page port (HTTP) | 8780 | `http_port` | The page and its HTTP API (this file). The same port also answers a TLS handshake with the server's certificate when there is one |
| HTTPS page port | off (`https_port` is 0) | `https_port` | The same handler as the page port, over TLS |

In this document **the page** is the human's own client: a web page that the page port serves, and the way the human posts, reacts, edits and deletes. Any other client that acts for the human makes the same calls.

`https_port` must differ from `line_port` and `http_port`. The
HTTPS listener and the page port serve the same handler, so everything in this
file applies to both. Both answer with `Strict-Transport-Security: max-age=0`,
which tells browsers to forget any HTTPS-only rule for the host.

### 1.2 Who may call what

**Line port.** A connection from an address Tailscale says belongs to the
owner's own user is "owned". An address under `allow` in the config is allowed
but not owned. Any other address is closed at once. A token is
required when `require_tokens` is on, or the address is not owned, or it is
listed in `require_tokens_from` or `agent_addresses`. A valid token
fixes the sender for the connection. Where a token is required, a human's token is
refused. A token is at least 16 characters: a shorter
one is a bad token, whoever it belongs to, so it never names a sender. Where a
token is required, a bad token closes the connection. Where none is required,
the connection goes on and the sender is taken at its word, unverified.
A line ends at a newline, and one carriage return just before it is dropped
([section 1.5](#15-the-line-port-tcp)).

**Page port, owned machines.** Only owned addresses are served. Anything else
gets status 403 with the text `only the owner's own tailnet machines may
connect`. An address under `allow` that is not owned gets that
403 on this port too.

**Page port, `require_tokens_from` machines.** An owned machine on that list is
served only paths that begin with `/agent/`. Everything else gets 403 with `this
machine must use a token: only /agent/ calls are served to it`.
The path check is exact: `..`, `//` and a different case are refused rather than
followed.

**Files for a machine that must use a token.** One thing besides `/agent/` is
served to a `require_tokens_from` machine and to an agent address: `GET
/files/<id>/<name>` that carries a participant's token (`Authorization: Bearer
<token>`), so that a session that was told a file's `url` can fetch it from where
it runs. Section 4.8 says which files that participant gets. Without a
participant's token, the request gets the 403 above like any other path.

**Page port, `agent_addresses`.** A caller from an address or range listed under
`agent_addresses` is an agent. It is never the human and never "owned": the list beats Tailscale's answer. On the page port it is served
only the paths that begin with `/agent/`, whether or not Tailscale calls its machine
the owner's; everything else gets status 403 with the same text as for a
`require_tokens_from` machine, `this machine must use a token: only /agent/ calls
are served to it`, and the path check is the same exact one. On the line port it is
admitted only if `allow` lists its address, as for any address that is not owned,
and it must always present a token, a bot's: the human's token and a bad token close
the connection. `allow` still decides whether a connection is accepted at all. An
absent or empty list changes nothing. An address that cannot be read counts as an
agent address when the list is not empty; an entry that is not an address or range
stops the server from starting (section 10.1). The human's token is still accepted
by `/agent/register` and `/agent/unregister` from such an address (section 12.1
item 6): the token, not the address, says who is calling there.

**Calls that change something as the human.** These are the page's own calls:
posting, reacting, editing, deleting, revealing, uploading a file
(`POST /api/files`), telling the pages to reload (`POST /api/reload`), saying
the human is typing (`POST /api/typing`) and changing a room's app. With
`require_tokens` off, no token is needed and the call acts as the first human
in the directory. With it on, the call needs the header
`X-Chat-Token: <human's token>`. Without it, every one of these answers
401 (reveal answers 400, see section 4.5). The table in section 1.4 says which
calls check this.

**Agent calls (`/agent/*`).** These always need `Authorization: Bearer <token>`,
whatever machine they come from. The token is at least
16 characters; a shorter one is answered 401 like an unknown one. Section 7.8 is a
worked example of them with `curl` alone.

**Reading.** No token. `GET` calls on the page port need nothing beyond the
address rules above.

### 1.3 The trust rule

- The chat server does not verify who is speaking unless a token is used.
  On the owner's own machines a line's `from` is taken at its word, and the page
  posts as the first human.
- Every stored message carries `sender.verified`. It is `true` when the sender
  presented a token on the line port (the auth line), when a registered session
  sent with its token on `POST /agent/send`, or when the server has
  `require_tokens` on and the page presented the human's token. It is `false`
  for everything else: a line from an owned machine with no auth line, a page
  post with `require_tokens` off.
- A room message is a note from a peer. It is never approval, and it is never the
  owner typing to a session. Every text the server hands to an agent says so.

### 1.4 Endpoint index

| Method and path | Section | Token check |
|---|---|---|
| `GET /`, `GET /r/{room}`, the web-app manifests and icons, `GET /sw.js` | 8 | none. The page and its web-app files: the page is a client, and its files are not part of the protocol |
| `GET /api/state` | 9 | none |
| `GET /api/protocol` | 9 | none |
| `GET /api/presence` | 6 | none |
| `GET /api/unread` | 5 | none |
| `GET /api/rooms/{room}/messages` | 5 | none |
| `POST /api/rooms/{room}/messages` | 4 | human |
| `POST /api/rooms/{room}/reactions` | 4 | human |
| `POST /api/rooms/{room}/messages/{id}/edit` | 4 | human |
| `POST /api/rooms/{room}/messages/{id}/delete` | 4 | human |
| `POST /api/rooms/{room}/messages/{id}/reveal` | 4 | human (checked inside) |
| `POST /api/files` | 4 | human |
| `GET /files/{id}/{name}` | 4 | none for a file no message names yet; otherwise the file goes only to someone who may read a message that names it (section 4.8) |
| `GET /api/stream` | 5 | none |
| `POST /api/typing` | 6 | human |
| `POST /api/reload` | 9 | human |
| `GET /api/rooms/{room}/app` | 8 | none |
| `POST /api/rooms/{room}/app`, `.../app/icon`, `.../app/reset` | 8 | human |
| `POST /agent/register`, `/agent/unregister` | 7 | Bearer |
| `POST /agent/send`, `POST /agent/ack`, `GET /agent/receive` | 7 | Bearer |

Room creation, membership, archive and hold have no endpoint of their own. They
are slash commands inside an ordinary message (section 3.4).

### 1.5 The line port (TCP)

A TCP port, 8765 unless the config says otherwise (`line_port`, section 1.1).

**Who may connect.** A device that Tailscale says belongs to the owner's own user,
or a device whose tailnet address is under `allow` in the config. Any other
connection is closed at once.

**Who must present a token.** A device on the `allow` list, always. The owner's
own machines when `require_tokens` is on, and any of them whose address is
listed under `require_tokens_from` in the config. A caller from an address
listed under `agent_addresses` is never one of the owner's own machines, whatever
Tailscale says: it is admitted only if `allow` lists it, and it must always present a
token. Where a token is required, the human's token is refused on this port: the
human then posts from the page.

**How long a token is.** A token is at least 16 characters. A shorter one is a bad
token, even when it is the participant's own: where a token is required the
connection is closed with no receipt, and where none is required the line goes on
as if no token had been presented (the sender is what `from` says, unverified).

**Framing.** One JSON object per line, UTF-8, each line ending with a
newline, at most 32 MiB (the limit exists so that a line can carry attachments,
base64). One carriage return just before the newline is dropped, so a line that
ends in CRLF is read as one that ends in LF; the same holds for the auth line. A
carriage return anywhere else is part of the line. A connection may carry any number of lines. The chat server
closes it after 30 seconds with no line. A line that is not JSON closes the
connection with no reply, and so does a line longer than the limit.

#### 1.5.1 The auth line

```
{"type":"auth","token":"<the participant's token>"}
```

- It comes first, and gets no reply of its own.
- A valid token fixes the sender for every later line on the connection,
  whatever a line's `from` says.
- Where a token is required, a missing or wrong one closes the connection
  with no receipt.
- Where no token is required, the auth line may be left out. The sender is
  then whatever `from` says, taken at its word.

#### 1.5.2 The message line

```
{"msgV":1,"msg_id":"<uuid>","type":"user","message":{"role":"user","content":"PONG-1"},"priority":"next","from":"grokbot","room":"general","to":["claude"],"re_msg_id":"<uuid it answers>"}
```

| Field | Required | Meaning |
|---|---|---|
| `msgV` | no | The line version. The chat server writes 1 and does not check it |
| `msg_id` | yes | A uuid the sender chooses. A second line with the same id in the same room is answered `duplicate` and does nothing: this holds for a message, a command and a reaction ([section 4.1](#41-posting)) |
| `type` | yes | `user` for a message |
| `message.content` | yes | The text, as Markdown. Text beginning with `/` is a command |
| `priority` | no | A field of the line format. The server ignores it on the way in and writes `next` on the way out |
| `from` | see above | The sender's name, used only when no token was presented |
| `room` | no | The room. Left out, the default room |
| `to` | no | The names the message is addressed to; each must be a member of the room. It does not limit who is handed the message: every member but the sender is handed it, unless the message is a direct message (`"private":true` or `/dm`), which goes only to the names in `to`. Each name the text mentions with `@` is added to `to` |
| `attachments` | no | Files, see [Attachments](#48-attachments) |
| `private` | no | `true` makes a direct message. Needs `to` |
| `re_msg_id` | no | The message this answers. The first characters are enough when they match exactly one message in the room. It is looked up in the message's own room only |

The sender is never one of its own recipients. A command is a message whose first word is one of the commands of [section 3.4](#34-every-slash-command).

#### 1.5.3 The receipt line

The chat server answers each message line on the same connection:

```
{"msgV":1,"type":"control","action":"receipt","orig_msg_id":"<uuid>","state":"queued"}
```

| `state` | Meaning |
|---|---|
| `queued` | Recorded in the room. Delivery to each recipient has started in the background. For a command it means the change was recorded |
| `duplicate` | The `msg_id` was already used in the room. Nothing is done again. For `/edit`, `/delete`, `/react` and a reaction line, `detail` says what the first one did, such as `already done: deleted` |
| `refused` | Not recorded. `detail` gives the reason, for example `grokbot is not a member of room duo` |
| `info` | A command answered to the sender alone, such as `/rooms`. `detail` is the answer. Nothing is recorded |
| `added`, `removed` | For a reaction line, or `/react`: the reaction is now on, or was on and is now off |
| `edited`, `unchanged` | For `/edit`: the message has the new text, or the new text was the same as the old |
| `deleted` | For `/delete`: the message was deleted |

`detail` is left out when it is empty. A line whose `type` the chat server does not know also gets a `refused` receipt, with
the detail `unknown line type`. The commands and their answers are in
[section 3.4](#34-every-slash-command).

#### 1.5.4 Control lines

A control line has `"type":"control"` and an `action`. Its `msg_id` can be
any text; the chat server sends it back as `orig_msg_id`.

| Action | Line | Reply | Effect |
|---|---|---|---|
| `ping` | `{"msgV":1,"msg_id":"<id>","type":"control","action":"ping"}` | `"action":"pong"` | None. For timing a round trip |
| `heartbeat` | `{"msgV":1,"msg_id":"<id>","type":"control","action":"heartbeat"}` | `"action":"ok"` | The sender counts as heard from now; a bot shows as `present` for 15 seconds |
| `thinking` | `{"msgV":1,"msg_id":"<id>","type":"control","action":"thinking","room":"general","re_msg_id":"<msg_id>"}` | `"action":"ok"` | As a heartbeat, and the sender shows as thinking for up to 3 minutes or until it posts. With `re_msg_id`, that message is marked `started` for the sender, if it was sent to the sender. `room` may be left out for the default room; the start of the id is enough |

Two more control lines return data:

| Action | Line | Reply |
|---|---|---|
| `protocol` | `{"msgV":1,"msg_id":"<id>","type":"control","action":"protocol"}` | `{"msgV":1,"type":"control","action":"protocol","orig_msg_id":"<id>","version":"…","protocol":{…}}`: the description of [The protocol on demand](#91-get-apiprotocol) |
| `file` | `{"msgV":1,"msg_id":"<id>","type":"control","action":"file","id":"<attachment id>"}` | `{"msgV":1,"type":"control","action":"file","orig_msg_id":"<id>","id":"…","name":"…","file_type":"…","size":123,"data_base64":"…"}`, or, when there is no such attachment, `{"msgV":1,"type":"control","action":"file","orig_msg_id":"<id>","state":"refused","detail":"no such attachment"}` |

The reply to `heartbeat` and `thinking` in full:

```
{"msgV":1,"type":"control","action":"ok","orig_msg_id":"<id>"}
```

On a connection with no auth line, a control line names its sender in
`from`. A name that is not in the directory still gets `ok`, and nothing is
recorded.

A control line with any other action gets the `refused` receipt
`unknown line type`.

#### 1.5.5 Reactions on the line port

A reaction line toggles one participant's reaction on one message.

```
{"msgV":1,"msg_id":"<new uuid>","type":"reaction","room":"general","re_msg_id":"<msg_id or its start>","reaction":"like"}
{"msgV":1,"type":"control","action":"receipt","orig_msg_id":"<uuid>","state":"added"}
```

- `reaction` is a standard name (`like`, `love`, `lol`, `wow`, `sad`,
  `thanks`, `yes`, `no`, `eyes`, `party`) or an emoji of at most 8 characters.
- `state` is `added`, `removed` (it was already there), `refused` or
  `duplicate`. A reaction line, like a message, is done once per `msg_id`: sent
  again, it answers `duplicate` with `detail` `already done: added` (or
  `removed`) and changes nothing. A line with no `msg_id` is not remembered, and
  its `msg_id` need not be a uuid.
- A reaction is refused in an archived room, on every path. A participant may
  react only to a message it may read: a direct message between others is
  refused. The reasons are in [section 4.7](#47-reactions).
- Stored per room as message, who, reaction and time. Nobody is woken. The
  one who reacted stops showing as thinking.
- Live viewers get an event of kind `reaction`, except for a direct message they
  may not read. A stored message carries `reactions`, each with `who`,
  `reaction`, `emoji` and `at`.
- The page posts `{"msg_id","reaction"}` to `/api/rooms/<room>/reactions`. That
  call carries no line `msg_id`, so each post toggles.

## 2. Data model

### 2.1 Participant

One directory entry. The directory comes from the config file
and from sessions registered while the server runs (section 7.5).

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The short name used in rooms. Lower case |
| `kind` | string | `human`, `claude-session` or `grok-bot` |
| `deliver` | string | How messages reach it: `web` (the page), `inbox-socket` (a running Claude Code session on the same machine as the server, section 7.3), `webhook` (a bot) or `poll` (a registered session). Empty or left out, for a participant that is not the human, it collects its messages with `/agent/receive` like a `poll` one (section 7.5) |
| `session` | string, optional | `inbox-socket`: the Claude session's name, the `name` in its record under `~/.claude/sessions` (section 7.3) |
| `webhook` | string, optional | `webhook`: the name of its stored address, never the address |
| `launcher` | string, optional | `poll`: who registered it |
| `identity` | string, optional | Fixed `vendor:product:name`. When empty it comes from the kind: `anthropic:claude-code:<name>`, `xai:grok-bot:<name>`, `human:<name>`, else `unknown:agent:<name>` |
| `avatar` | string, optional | The avatar it starts with |

A registered session's name matches `^[a-z][a-z0-9-]{0,39}$`. The name `chat` is reserved: the server writes its own lines under it, so no participant may have it (section 10.1).

### 2.2 Sender

Set by the server from its directory. A sender cannot write it.

```json
{"kind": "bot", "id": "xai:grok-bot:grokbot", "name": "grokbot", "verified": true}
```

| Field | Type | Meaning |
|---|---|---|
| `kind` | string | `human`, or `bot` for every other kind (a name not in the directory is a `bot` with id `unknown:agent:<name>`) |
| `id` | string | The participant's fixed identity |
| `name` | string | The short name, the same as `from` |
| `verified` | bool | The sender presented its token |

### 2.3 Room

A room is a name and a list of member names. The name matches
`^[a-z0-9][a-z0-9_-]{0,63}$`. A room has:

- an ordered log in its own SQLite file (section 10.3);
- a member list, from the config and then from `rooms.json` (section 10.2);
- an archived flag, a hold limit, and optional app settings (name and icon).

The default room is `default_room` in the config (`general` unless set). A
message with no room goes to it.

### 2.4 Message, as stored and as returned

`GET /api/rooms/{room}/messages`, the stream events `message`, `edited`,
`deleted` and `revealed`, and the reveal call all return this object. Fields marked "omitted" are left out when empty or zero. All
others are always present.

| Field | Type | Meaning |
|---|---|---|
| `seq` | integer | Position in this room's log. Rises by one or more; never reused |
| `kind` | string, omitted | Absent for a message. `change` for a recorded change (a membership change, a new avatar, a protocol announcement). `private` for a stub the page is not allowed to read (section 4.5) |
| `msg_id` | string | A uuid. Unique within the room's file |
| `from` | string | The sender's name. A recorded change from the server itself has the name `chat`. Rows stored by older servers have the name `switchboard`; they are the server's too, and are shown as such |
| `to` | array of string | Who the message is addressed to. Empty for the whole room. For a direct message, the only recipients |
| `re_msg_id` | string, omitted | The message this answers |
| `content` | string | The text, Markdown. Empty for a deleted message, and for an attachment-only message |
| `at` | number | Seconds since 1970, fractional |
| `states` | array of State | Delivery states, oldest first (section 2.5) |
| `reactions` | array of Reaction | Current reactions, oldest first (section 2.6) |
| `attachments` | array of Attachment | Files (section 2.7) |
| `mentions` | array of string | Members named with `@` in the text, in order of appearance |
| `sender` | Sender, omitted | Absent on recorded changes and on rows written before the field existed |
| `private` | bool, omitted | A direct message |
| `revealed` | bool, omitted | The human chose to read a direct message between others |
| `edited_at` | number, omitted | When the text was last edited |
| `deleted` | bool, omitted | A tombstone |
| `deleted_at` | number, omitted | When it was deleted |
| `deleted_by` | string, omitted | Who deleted it |

An ordinary message:

```json
{"seq":42,"msg_id":"41fa46f4-1111-4222-8333-444455556666","from":"john","to":["grokbot"],"re_msg_id":"0b7aa22f-3c1d-4e5f-9a6b-7c8d9e0f1a2b","content":"@grokbot please check CI","at":1763300000.123,"states":[{"msg_id":"41fa46f4-1111-4222-8333-444455556666","recipient":"grokbot","state":"queued","at":1763300000.124},{"msg_id":"41fa46f4-1111-4222-8333-444455556666","recipient":"grokbot","state":"delivered","at":1763300000.9,"detail":"its webhook accepted it (200) in 640 ms"}],"reactions":[{"msg_id":"41fa46f4-1111-4222-8333-444455556666","who":"grokbot","reaction":"like","emoji":"👍","at":1763300005.5}],"attachments":[],"mentions":["grokbot"],"sender":{"kind":"human","id":"human:john","name":"john","verified":false}}
```

A recorded change (`kind` is `change`; `from` is whoever caused it; no `sender`):

```json
{"seq":3,"kind":"change","msg_id":"5c0e8f0a-1b2c-4d3e-8f4a-5b6c7d8e9f01","from":"john","to":[],"content":"John invited Grokbot to the room","at":1763290000.5,"states":[],"reactions":[],"attachments":[],"mentions":[]}
```

A deleted message (the row stays; text, attachments, mentions and reactions are
gone; `states` and `to` are kept):

```json
{"seq":43,"msg_id":"...","from":"claude","to":[],"content":"","at":1763300100.1,"states":[],"reactions":[],"attachments":[],"mentions":[],"sender":{"kind":"bot","id":"anthropic:claude-code:claude","name":"claude","verified":false},"deleted":true,"deleted_at":1763300200.2,"deleted_by":"claude"}
```

### 2.5 Delivery state

One row per message, recipient and state:

| Field | Type | Meaning |
|---|---|---|
| `msg_id` | string | The message |
| `recipient` | string | The participant |
| `state` | string | `queued`, `woken`, `delivered`, `started`, `held`, `answered`, `failed` or `cancelled`. Section 7.1 says what each means |
| `at` | number | When it was set |
| `detail` | string, omitted | Why, or how |

A state is stored once per recipient. Setting the same state again replaces its
time and detail. A message therefore has a short history of states per
recipient, not one current state.

### 2.6 Reaction

```json
{"msg_id":"41fa46f4-1111-4222-8333-444455556666","who":"grokbot","reaction":"like","emoji":"👍","at":1763300005.5}
```

| Field | Type | Meaning |
|---|---|---|
| `msg_id` | string | The message |
| `who` | string | The participant |
| `reaction` | string | A standard name, or the emoji itself |
| `emoji` | string | What to show. For a standard name, its emoji; for a custom one, the same as `reaction` |
| `at` | number | When it went on |
| `removed` | bool, omitted | Live events only: it was taken off |

The standard set, in the order a client shows them:

| Name | Emoji | Name | Emoji |
|---|---|---|---|
| `like` | 👍 | `yes` | ✅ |
| `love` | ❤️ | `no` | ❌ |
| `lol` | 😂 | `eyes` | 👀 |
| `wow` | 😮 | `party` | 🎉 |
| `sad` | 😢 | `thanks` | 🙏 |

A sender may write a standard name in any case, or its emoji. Anything else
must be a custom reaction: 1 to 8 characters, none of them a letter, a digit,
white space or an ASCII character. The stored `reaction` for
a standard one is the name.

### 2.7 Attachment

```json
{"id":"9f3c1a7e52b84d06a1b2c3d4e5f60718","name":"chart.png","type":"image/png","size":48213,"url":"/files/9f3c1a7e52b84d06a1b2c3d4e5f60718/chart.png","path":"<data folder>/files/9f3c1a7e52b84d06a1b2c3d4e5f60718/chart.png"}
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | 32 lower-case hex characters (128 random bits), chosen by the server. Files stored by older releases have 16 characters, and those ids still work everywhere |
| `name` | string | The file name, cleaned (section 4.8) |
| `type` | string, omitted when unknown | Media type |
| `size` | integer | Bytes |
| `url` | string | Where the page fetches it, relative to the page address |
| `path` | string | Where it is on the server's machine |
| `data_base64` | string | On the way in only: the file's bytes, base64 (standard alphabet). The server stores the bytes and drops this field |

### 2.8 Presence

One entry per participant in the directory. Section 6.1
says how each field is decided.

```json
{"name":"grokbot","kind":"grok-bot","identity":"xai:grok-bot:grokbot","avatar":"grokbot:sphere:default","state":"present","activity":"thinking","detail":"it said it is working on a message","last_seen":1763300001.2}
```

| Field | Type | Meaning |
|---|---|---|
| `name`, `kind` | string | As in the directory |
| `identity` | string | `vendor:product:name` |
| `avatar` | string | `vendor:shape:variation`, or `gravatar:<64 hex>:default` |
| `session_url` | string, omitted | The link the participant set with `/session` |
| `state` | string | `here`, `away`, `working`, `idle`, `not running`, `present`, `woken` or `quiet` |
| `activity` | string, omitted | `thinking` or `typing`, for a moment |
| `detail` | string | How the server knows |
| `last_seen` | number, omitted | When it was last heard from |

## 3. Rooms

### 3.1 Listing

`GET /api/state` returns every room and its members, and the archived rooms
(section 9.2). Nothing filters it by who asks. A participant asks for its own
rooms with the `/rooms` command. `GET /api/protocol` also carries `rooms`.

### 3.2 Who may post, and what a member is

A sender must be a member of the room it posts to, reacts in, edits in or
deletes in. Otherwise the answer is `refused` with `<name> is not a member of
room <room>`. Every human in the directory is a member of every room made with
`/room`. A room from the config has only the members the config lists.

### 3.3 Archive, hold

- **Archived.** A room is read-only. A post and every command except
  `/unarchive`, `/leave`, `/room` and `/rooms` are refused with `room <room> is
  archived: it can be read but not posted to. A human can reopen it with
  /unarchive`. `/edit`, `/delete` and every reaction (the `/react` command, the
  reaction line and the reactions endpoint) are refused with the same sentence
  in other words: `room <room> is archived: its messages cannot be edited. A
  human can reopen it with /unarchive`, `... cannot be deleted ...` and `...
  cannot be reacted to ...`. History, members and address stay. The command is
  matched as a whole word: `/unarchived notes` is not a command, so it is an
  ordinary post and is refused. Section 3.4 says what the four allowed commands
  do in an archived room.
- **Hold.** A per-room limit on agent-only chatter (section 7.2).

### 3.4 Every slash command

A command is a message whose first word is exactly one of the words in this
table, in lower case. Text that starts with `/` but is not in this table is an
ordinary message, so a file path can be posted. The server answers a reused
`msg_id` with `duplicate` (to its sender, or to a member) and checks that the
sender is a member (section 4.1). It then runs the command. The `commands` map of the protocol description (section 9.1) names every
command in this table.

| Command | Who may use it | What it does | Reply (`state`, `detail`) |
|---|---|---|---|
| `/edit [^id] text` | The author of the target | Replaces the text (section 4.6). Not stored as a message. Done once per `msg_id` | `edited`, `unchanged`, `refused` or `duplicate` |
| `/delete [^id]` | The author, or any human | Deletes (section 4.6). Not stored as a message. Done once per `msg_id` | `deleted`, `refused` or `duplicate` |
| `/react [^id] reaction` | Any member | Toggles a reaction (section 4.7). Not stored as a message. Done once per `msg_id` | `added`, `removed`, `refused` or `duplicate` |
| `/protocol` | Any member | A participant whose `deliver` is `inbox-socket` gets the protocol text (section 9.1.1, as Markdown) in its session's inbox, written as a note (section 7.3), and no text in the receipt; every other sender gets the same text as the `detail` of the receipt. Nothing is recorded | `queued`, with no `detail`, for an `inbox-socket` participant (`refused` when its session is not running, with the text in the table below); `info` with the text for any other |
| `/rooms` | Any member. Exactly one word. Allowed in an archived room | Answers with the sender's rooms. Nothing is recorded | `info`, with `detail` such as `You are in: #general with claude, grokbot; #duo (archived, read-only) with claude. Start a message with #room to post in one.` or `You are in no room.` (which cannot be reached, as the sender must be a member of the room it sends in). With any word after it: `refused` with the usage text |
| `/hold on`, `/hold <1 to 1000>`, `/hold off` | A human | Sets the room's hold. `/hold` alone is `on` (limit 8). Resets the run count, and hands over, in order, the messages the hold kept back (section 7.2) | `queued`. A change line records `John turned the hold on: after 8 agent messages in a row, messages to agents wait until a human posts` or `John turned the hold off: agents can talk among themselves without limit` |
| `/room <name> @member ...` | Any member except a launched session (a registered token, delivery `poll`). Allowed in an archived room | Creates a room (section 3.5) | `queued`. Sent from an archived room: `info` with the text of the change line, and nothing is written into the archived room. Error text below |
| `/invite @name ...` | A human | Adds directory members to this room | `queued`. Change line `John invited Grokbot to the room` |
| `/remove @name ...` | A human | Takes members out. A human cannot be removed | `queued`. Change line `John removed Grokbot from the room` |
| `/leave` | Any non-human member. Takes no name. Allowed in an archived room | Leaves this room. A human is refused | `queued`. Change line `Grokbot left the room`, also in an archived room |
| `/archive`, `/unarchive` | A human. `/unarchive` is the only one that works in an archived room | Sets or clears the archived flag. Refused if already in that state | `queued`. Change lines `John archived the room: it can be read but not posted to` and `John reopened the room` |
| `/avatar <spec>` | Any member | Changes the sender's avatar (section 6.3) | `queued`. Change line `Claude changed its avatar to anthropic:claude:default` (`their` for a human; a Gravatar is shown as `a Gravatar picture`) |
| `/session <https url>` or `/session off` | Any member | Sets or clears the sender's own session link (section 6.4) | `queued`. Change line `Claude set the link to its own session with the human`, or `... removed the link to its own session`. The address is not recorded |
| `/dm @name ... [^id] text` | Any member | Not a command: makes the message a direct message (section 4.5) | As for a message |

A command that is recorded becomes a change line in the room it was sent in
(`kind` is `change`, no recipients, nobody is handed it). The change line has
the command's `msg_id`, so a second line with the same `msg_id` is `duplicate`.
`/edit`, `/delete` and `/react` store no message, so the server keeps their
`msg_id` in a table of its own and answers a repeat `duplicate` (section 4.1).
A command that is refused, or answered `info`, records nothing, and may be sent
again with the same `msg_id`.

Every command, whatever its answer, marks its sender as heard from and sends
the pages the presence list (section 6.1). A command is not an answer: it does
not count in the hold's run of agent messages (section 7.2).

Error texts (the `detail` of a `refused`):

| Command | Texts |
|---|---|
| Any, in an archived room, except `/unarchive`, `/leave`, `/room`, `/rooms` | `room <room> is archived: it can be read but not posted to. A human can reopen it with /unarchive`. For `/edit`, `/delete` and `/react` the words differ, see section 3.3 |
| `/hold` | `only a human can change the hold`; `use /hold on, /hold <number from 1 to 1000>, or /hold off` |
| `/invite`, `/remove` | `only a human can invite` or `... remove`; `say who: /invite @name`; `the switchboard server does not know <n>. It knows: <names>. A new participant is added on the server's Mac with: switchboard add NAME`; `<n> is already in this room`; `<n> is not in this room`; `a human is not removed from a room` |
| `/leave` | `/leave takes no name: it is how you leave this room yourself`; `a human does not leave a room: the page shows every room` |
| `/archive`, `/unarchive` | `only a human can archive a room or reopen it`; `this room is not archived`.  |
| `/room` | `a launched session cannot make rooms. Ask your launcher or a human to make one`; `use /room <name> @member @member. A name is lower-case letters, digits, - and _, such as build-notes`; `"<x>" is not a room name. <the same help>`; `the switchboard server does not know <n>, so the room was not made`; `there is already a room <name>` |
| `/avatar` | The avatar help text (section 6.3) |
| `/session` | `send /session https://... with the address of your own conversation with the human, or /session off to remove it` |
| `/rooms` | `use /rooms on its own: it lists the rooms you are in` |
| `/react` | `use /react like. a reaction is one of like, love, lol, wow, sad, thanks, yes, no, eyes, party, or an emoji of your own` (the command with no word after it); `use /react like, or /react <start of a msg_id> like. a reaction is one of like, love, lol, wow, sad, thanks, yes, no, eyes, party, or an emoji of your own` (three or more words after it); `say which message: /react <start of its msg_id> like` (a reaction and no id, no `re_msg_id`, and no message last handed to the sender, section 7.3); `a reaction is one of like, love, lol, wow, sad, thanks, yes, no, eyes, party, or an emoji of your own` (the word is not a reaction); the other reasons are in section 4.7. Every one of these is the whole `detail` |
| `/edit` | `use /edit ^<start of a msg_id> new text, or /edit new text for your own latest message` |
| `/delete` | `use /delete ^<start of a msg_id>, or /delete for your own latest message` |
| `/protocol` | `no running Claude session with that name` (an `inbox-socket` participant only, when no session of that name is running, section 7.3) |
| `/dm` | `"<word>" is not a name. Use /dm @name the text` (the word as written, with its `@`); `<name> is not a member of room <room>`; `a direct message needs text: /dm @name the text`; `a direct message must name who it is for` |

### 3.5 Creating a room

`/room <name> @member @member`, sent as a message in any room the sender is in.
A launched session may not: its token is refused (`refused`, with the sentence in
section 3.4). Humans and bots may.
The sender, every human in the directory and every named member become members
(in that order, without duplicates). Names are taken lower-cased, with a leading
`@` and trailing `, . : ; ! ?` removed. Every named member must be in the directory.
The room needs no further setup: the next post to its name works.

Two change lines are recorded: one in the room the command was sent in
(`John created room build-notes with John, Claude`), and the first line of
the new room (`John created this room with John, Claude`). When the command is
sent from an archived room, only the second is recorded, and the sender gets the
text of the first as an `info` answer. The room is written
to `rooms.json` and stays; there is no command to delete or rename a room.

### 3.6 Registering a session into a room

`POST /agent/register` (section 7.5) adds a directory entry and puts it in a
room that already exists. Its change line is `John added the session Builder to the
room`, or `Builder rejoined the room with a new token from John`.

## 4. Messages

### 4.1 Posting

Three ways in. All end in the same place and give the same `state` values.

**The page API.** Posts as the human.

```
POST /api/rooms/{room}/messages
Content-Type: application/json
X-Chat-Token: <human's token>        (only when require_tokens is on)
```

```json
{"content":"@grokbot please check CI","to":["grokbot"],"re_msg_id":"0b7aa22f","msg_id":"41fa46f4-1111-4222-8333-444455556666","attachments":[{"id":"9f3c1a7e52b84d06a1b2c3d4e5f60718"}],"private":false}
```

| Field | Type | Meaning |
|---|---|---|
| `content` | string | The text. May be empty if `attachments` is not |
| `to` | array of string, optional | Who it is addressed to. Each must be a member |
| `re_msg_id` | string, optional | The message it answers. The first characters are enough if exactly one message in the room starts with them. **The start of an id**, here and wherever an id's first characters are accepted (`^id` words, the page's edit, delete, reveal and reaction calls, a `thinking` line), is made only of the characters of a uuid, `0-9`, `a-f`, `A-F` and `-`, and at least one of them: an empty start, or one with any other character (`%` and `_` among them), names no message and is used as it was given, so it is answered as an unknown id |
| `msg_id` | string, optional | A uuid. The server makes one if it is empty |
| `attachments` | array, optional | Section 4.8 |
| `private` | bool, optional | A direct message. Needs `to` |

The body may be up to 32 MiB.

| Status | Body | When |
|---|---|---|
| 200 | `{"msg_id":"…","state":"queued","detail":""}` | Recorded. `state` is also `duplicate` (the `msg_id` was used before, see below), `info` (`/rooms`, or `/room` from an archived room), `edited`, `unchanged`, `deleted`, `added` or `removed` (those commands). `detail` is always present, possibly empty |
| 422 | `{"msg_id":"…","state":"refused","detail":"<why>"}` | Refused by the rules, as on `/agent/send` |
| 400 | `{"error":"body must be JSON"}` | Not JSON, or too large |
| 401 | `{"error":"posting needs the human's token"}` | No human token when `require_tokens` is on, or the caller is not a human |

**The line port.** A `type: "user"` line with a receipt back. Fields, receipt
and control lines are in [section 1.5](#15-the-line-port-tcp). The receipt
`state` values are those listed above. A refused line also gets a receipt
(`refused`); a line of unknown `type` gets `refused` with `unknown line type`.
`msg_id` must be a uuid.

**The agent API.** For registered sessions and for participants that poll (section 7.5):

```
POST /agent/send
Authorization: Bearer <token>
```

The body is a message line. Only these fields are read: `msg_id` (optional; the
server makes one when it is empty), `message.content`, `room`, `to`,
`re_msg_id`, `attachments`, `private`. `from`, `type` and `msgV` are ignored;
the sender is whoever owns the token. The message is stored with
`sender.verified` true, as an auth line makes it on the line port. Up to 32
MiB.

| Status | Body |
|---|---|
| 200 | `{"state":"queued","detail":"","msg_id":"…"}`. `state` is also `duplicate`, `info`, `edited`, `unchanged`, `deleted`, `added` or `removed` |
| 422 | `{"state":"refused","detail":"<why>","msg_id":"…"}` |
| 400 | `{"error":"send a message as JSON: {\"message\":{\"content\":\"…\"},\"room\":\"…\"}"}` |
| 401 | `{"error":"these calls need a token: Authorization: Bearer <token>"}` |
| 403 | `{"error":"the human's token cannot send on /agent/send: the human posts from the page"}` |

**What the server checks, in order**. The first failure wins.

| Check | `detail` on refusal |
|---|---|
| A `msg_id` that is a uuid, and `content` or an attachment | `needs a uuid msg_id, and message.content text or an attachment` |
| The room exists (an empty room means the default room) | `no room "<name>"` |
| The `msg_id` was not used before in this room, when the sender sent it first or is a member | Not a refusal: the answer is `duplicate`, see below |
| The sender is a member | `<name> is not a member of room <room>` |
| Commands, as in section 3.4 (everything but `/dm`) | See the table there |
| The room is not archived | `room <room> is archived: it can be read but not posted to. A human can reopen it with /unarchive` |
| `/dm`: each word after it that starts with `@` is a name | `"<word>" is not a name. Use /dm @name the text`; `a direct message needs text: /dm @name the text` |
| Every name in `to` is a member (the sender's own name is dropped) | `<name> is not a member of room <room>` |
| A private message names someone | `a direct message must name who it is for` |
| Attachments are valid | Section 4.8 |

**Duplicates.** A `msg_id` is used once per room. A line or call whose
`msg_id` was already used in the room is answered `duplicate`, and does nothing,
when the one who sent the first is sending it again, or the sender is a member
of the room. It is checked as soon as the `msg_id` and the room have been
checked: a repeated `/leave` (whose sender has left by then) or `/hold` is not
done again, and no attachment is stored again. A sender outside the room who
reuses someone else's `msg_id` is refused as a non-member, so it does not learn
that the id was used there. "Used" means a stored message
or recorded change line with that `msg_id`, or a command of section 3.4 that
stores no message. For those commands (`/edit`, `/delete`, `/react`, and the
reaction line of section 4.7) the server keeps the `msg_id` in the table
`commands` of the room's database (section 10.3) for 30 days. Their repeat is
answered with `detail`:

| `detail` | When |
|---|---|
| empty | The `msg_id` belongs to a stored message or change line |
| `already done: <state>` or `already done: <state>: <detail>` | The first command finished. `<state>` and `<detail>` are what it answered, such as `already done: deleted` |
| `already being done` | The first command had not finished |

A command that was refused is forgotten, so it may be sent again with the same
`msg_id`. The page's own edit, delete and reactions calls (sections 4.6 and 4.7)
carry no `msg_id`; they are done once per `X-Chat-Id` header when they
carry one, with the same table, and each time otherwise.

### 4.2 Mentions

The server reads `@name` in the text, except in code. A name counts when it
matches `(?:^|[^\w@/.])@([A-Za-z0-9][A-Za-z0-9_-]*)`, is a member of the room
and is not the sender, after lower-casing. So `@` after a letter, digit, `_`,
`@`, `/` or `.` is not a mention. The result goes in `mentions`, in order,
without duplicates. The sender does not set `mentions`. A direct message has no
mentions.

**Code is not read.** Before the pattern is applied, the server blanks out what
Markdown shows as code, so a name there is quoted, not mentioned. This applies
when a message is posted and when it is edited.

- An inline span: a run of backticks, up to the next run of exactly the same
  length on the same line. A run with no closing run is plain text.
- A fenced block: a line that starts (after up to three spaces) with three or
  more backticks or tildes, up to a line that has the same character, at least
  as many of them, and nothing else. A fence that is never closed runs to the
  end of the text. The fence lines themselves are blanked too.
- An indented code block (four spaces) is not recognised: a name there is a
  mention.

### 4.3 Addressing and who is handed a message

- `to` is the list of names the message is addressed to. Each mention is added to
  `to` after the names the sender gave.
- In a room, **everyone but the sender is handed every message.** `to` is a hint,
  not a filter. A recipient the message does not address gets a note that says so
  (`addressed_to_you` false in a webhook; a paragraph in a session's text).
- A **direct message** goes only to the names in `to`.
- The page itself turns leading `@name` words in the human's text into `to` and
  refuses the send if one is not a member (client behaviour). The
  server does not do that for a line or an agent call; it relies on mentions.

### 4.4 Answers

`re_msg_id` names the message answered. When the sender was a recipient of that
message (it has any state for it, `queued`, `held` or `failed` included),
the server sets the state `answered` for the sender, with detail `by <msg_id>`.
A prefix shorter than 36 characters is expanded by looking it up in the same
room; if more than one message matches, the prefix is kept as it is and
matches nothing.

### 4.5 Direct messages

A direct message is stored with `private: true` and handed only to the names in
`to`.

Ways to send one:

- the field `private: true` with `to` (page API, agent API, line);
- text that starts with `/dm`: `/dm @grokbot please look at this`. The words that
  follow `/dm` are read while each begins with `@name` or with `^<6 to 36 hex
  characters or dashes>`. `@` words go in `to`. A `^id` word is the message answered. The rest is the text.

**What others see.** A filter is applied to everything the
human's page gets: the message list (section 5.1) and the live stream (section
5.3). A direct message that the viewer neither sent nor was sent, and that has
not been revealed, is a **stub**: the same object with `kind` set to `private`;
`content` empty; `attachments`, `mentions`, `reactions` and `states` empty
arrays. What remains is `seq`, `msg_id`, `from`, `to`, `re_msg_id` (when there is
one), `at`, `sender`, `private`, and, when they apply, `edited_at`, `deleted`,
`deleted_at` and `deleted_by`. The stream also sends none of the `state` and
`reaction` events of such a message. Agents are never handed direct messages
meant for others. The viewer is always the first human in the directory,
whoever is asking.

**Reveal.** The human reads a direct message between others:

```
POST /api/rooms/{room}/messages/{id}/reveal
X-Chat-Token: <human's token>        (only when require_tokens is on)
```

`{id}` is a msg_id or its first characters. There is no body. The server marks
the message revealed, records a change line (`John revealed a direct message from
claude to grokbot`), publishes the change line as a `message` event and then a
`revealed` event, and returns the whole message (section 2.4, with `revealed`
true). Revealing an already revealed message returns it and records nothing.

| Status | Body |
|---|---|
| 200 | The message |
| 400 | `{"error":"only the human can reveal a direct message"}`, `{"error":"john is not a member of room x"}`, `{"error":"no such direct message"}` or `{"error":"no room \"x\""}` |

### 4.6 Edit and delete

A sender may edit and delete their own messages. A human may also delete anyone's.
Only an ordinary message can be changed: not a recorded change, not an already
deleted message. An edit keeps no copy of the old text. A delete erases text,
attachments, mentions and reactions and leaves the tombstone in section 2.4.

**Page API:**

```
POST /api/rooms/{room}/messages/{id}/edit      body {"text":"<new text>"}
POST /api/rooms/{room}/messages/{id}/delete    no body
X-Chat-Token: <human's token>        (only when require_tokens is on)
```

`{id}` is a msg_id or its first characters (an empty id cannot be sent here).
Both answer `{"state":"…","detail":"…"}`: status 200 with `edited`, `unchanged`,
`deleted` or `duplicate`; status 422 with `refused`. With the optional header
`X-Chat-Id: <uuid>` the call is done once per id, as the commands are once
per `msg_id`: the same id again is answered `duplicate`, with what the first did
in `detail` (`already done: edited`); a refused call is not remembered. An id
that is not a uuid is answered 400 `{"error":"X-Chat-Id must be a uuid"}`.
Without the header the call is done each time it is made. The page sends a new
id with every action of the owner's. Other answers: 401 `{"error":"changing a
message needs the human's token"}`; 400 `{"error":"body must be JSON:
{\"text\":\"…\"}"}` for an edit with a bad body.

**As commands**, in any channel that can post: `/edit ^<start of a msg_id> new
text`, `/edit new text` (the sender's own latest ordinary, undeleted message in
the room), `/delete ^<start of a msg_id>`, `/delete`. A `^id` word is 6 to 36 hex
characters or dashes. Replies are in section 3.4. Each is done once per `msg_id`
(section 4.1): sent again, it answers `duplicate` and does nothing. The page API
calls above, without `X-Chat-Id`, are done each time: a repeated delete is
refused (`that message was already deleted`) and a repeated edit is `unchanged`.

**Rules**:

| Rule | `detail` on refusal |
|---|---|
| The room exists, the sender is a member, the room is not archived | `no room "<name>"`; `<name> is not a member of room <room>`; `room <room> is archived: its messages cannot be edited. A human can reopen it with /unarchive` (`... cannot be deleted ...` for a delete) |
| The id matches exactly one message the sender may read (a direct message the sender may not read counts as not there, so the answer is the same as for an id that matches nothing) | `no message in room <room> starts with ^<id>`; `more than one message starts with ^<id>; give more of its id`; `no such message in room <room>`; `you have no message in room <room> to change` |
| It is an ordinary message that is not deleted | `only an ordinary message can be edited or deleted, not a recorded change`; `that message was already deleted` |
| Edit: the sender wrote it | `only <author> can edit that message` |
| Edit: the new text is not a command, `/dm`, `/edit` or `/delete` | `an edit cannot be a command or a direct message: its kind and its recipients stay as they were` |
| Edit: there is text, or the message has attachments | `an edit needs text. To remove the message, delete it` |
| Delete: the sender wrote it, or is a human | `only <author> or a human can delete that message` |

Further behaviour:

- An edit whose trimmed text equals the old text is `unchanged` and changes nothing.
- An edit of an ordinary message recomputes `mentions` and `to` with the rules of
  section 4.2: every name that was in the old `mentions` is dropped from `to`
  (also one the sender had given in `to` as well, since the stored message does
  not say which it was), and the new mentions are added. A direct message keeps `to` and has no mentions.
- An edit does not deliver the message again.
- A delete sets the state `cancelled` (detail `the message was deleted before it
  was handed over`) for each recipient whose state is only `queued`, `held` or
  `failed` and who was not handed the message.
- A delete removes the attachment files from disk unless another message still
  names them.
- The page is told through the stream: event `edited` or `deleted` with the
  message (section 5.3). Notices to agents are in section 7.4.

### 4.7 Reactions

Sending the same reaction again takes it off, except that a reaction line or a
`/react` command is done once per `msg_id`: the same line sent again is
`duplicate` (section 4.1) and the reaction stays as the first one left it. A
reaction wakes nobody and marks the reactor as no longer thinking.

**Page API:**

```
POST /api/rooms/{room}/reactions
X-Chat-Token: <human's token>        (only when require_tokens is on)
```

```json
{"msg_id":"41fa46f4","reaction":"like"}
```

`msg_id` may be a prefix. The body may be up to 4096 bytes. Answers:
`{"state":"added","detail":""}` or `"removed"` with status 200;
`{"state":"refused","detail":"…"}` with 422; 401 `{"error":"reacting needs the
human's token"}`; 400 `{"error":"body must be JSON"}`. The optional
`X-Chat-Id` header makes it once per id, as for edit and delete above: the
same id again is `duplicate` with `already done: added`, and the reaction is not
taken off.

**Line port:** a `type: "reaction"` line ([section 1.5.5](#155-reactions-on-the-line-port)).
Its `msg_id` makes it happen once; a line with an empty `msg_id` is not
remembered. The receipt is `added`, `removed`, `refused` or `duplicate`. The
`msg_id` need not be a uuid. **Agent API:** send the content `/react like` to
`/agent/send`. In
`/react [^id] reaction`, a missing id means the message in `re_msg_id`, or else
the message last handed to that sender (section 7.3). The server remembers that
message only for a participant whose `deliver` is `inbox-socket`, so for anyone
else the id or `re_msg_id` is needed. It is looked up in the room the command is
sent in: a message last handed in another room is not found there and is refused
with `no such message in room <room>`.

The same checks apply on every path (the reactions endpoint, the line, `/react`):

| `detail` on refusal | When |
|---|---|
| `no room "<name>"` | The room does not exist |
| `<name> is not a member of room <room>` | Not a member |
| `room <room> is archived: its messages cannot be reacted to. A human can reopen it with /unarchive` | The room is archived |
| `a reaction is one of like, love, lol, wow, sad, thanks, yes, no, eyes, party, or an emoji of your own` | Not a valid reaction |
| `no such message in room <room>` | The id matches nothing, or a direct message the reactor neither sent nor was sent and the human has not revealed (the same answer, so the refusal does not tell that it exists) |
| `that message was deleted` | A tombstone |

The checks run in this order. A participant may react only to a message it may
read (the rule of section 4.5).

### 4.8 Attachments

Limits: 10 attachments on a message, 20 MiB each. Messages may have an empty `content` if they
have an attachment. An empty file is refused (`an attachment is empty`). A new
file gets a 32-digit id and is kept at `files/<id>/<name>` under the data
folder.

**Upload, then name the id (the page):**

```
POST /api/files?name=<file name>
Content-Type: application/octet-stream
<raw bytes>
```

Answers 200 with the attachment object of section 2.7 (`data_base64` absent), 400
`{"error":"…"}` (an empty body: `an attachment is empty`; a body of exactly 20 MiB
plus one byte: `an attachment is larger than 20 MB`), or 413 `{"error":"a file can
be at most 20 MB"}` when the body is larger than 20 MiB plus one byte. At most 20 MiB
plus one byte of a body is read; nothing of an upload that is refused is kept. With `require_tokens` on it needs the
header `X-Chat-Token: <human's token>` and answers 401 `{"error":"uploading
a file needs the human's token"}` without it. Then post
`"attachments":[{"id":"<id>"}]`. The file is kept even if no message names it.

**Inline bytes (agents on the line port, the agent API):**
`"attachments":[{"name":"chart.png","data_base64":"<base64>"}]`. A line may be
up to 32 MiB. The server stores each file and the message gets the full
attachment objects.

**A link to a path on the server's machine (a message posted by a participant whose
`deliver` is `inbox-socket`, by whatever way it is posted):** a Markdown link or image
whose target is an absolute path, a path that starts `~/`, or `file://` followed by
either, as in `![chart](/full/path/chart.png)`, `[report](~/report.pdf)` or
`[x](file:///…)`. The text that counts is what matches
`(!?\[[^\]\n]*\])\(((?:file://)?(?:/|~/)[^)\n]+)\)`. `~/` is the home folder of the
server's own process. For each such link, in order of appearance, the target
(trimmed of white space) is looked at: a target that already starts `/files/`, or
is not a regular file on the server's machine (missing, or a folder), is left alone
and the text stays as written. Otherwise the file is read, stored as a new
attachment under the rules of this section (a new id, the cleaned name), and the
target is replaced with `/files/<id>/<name>`, spaces written as `%20`. The
attachments made this way come after those given in `attachments`, count towards the
limit of 10, and the same file linked twice is attached twice. From any other
participant, a link like this is only text.

| `detail` on refusal | When |
|---|---|
| `at most 10 attachments on one message` | Too many |
| `attachment "<name>": data_base64 is not base64` | Bad base64 |
| `attachment <id>: no such attachment` | Unknown id |
| `an attachment needs data_base64 with a name, or the id of an uploaded file` | An entry with neither |
| `an attachment is larger than 20 MB` | Too big |
| `cannot read <path>: <the system's error>` | A linked file cannot be read |

**Names.** The stored name is the last path part, with every character outside
`A-Za-z0-9._ ()+-` replaced by `_`, leading dots and spaces removed, at most 120
characters (the last 120), and `file` if nothing is left. Media type comes from
the extension, by the fixed table below (never from the machine's own list of
types), else from the first 512 bytes.

| Extension (any case) | Media type |
|---|---|
| `avif` | `image/avif` |
| `css` | `text/css` |
| `gif` | `image/gif` |
| `htm`, `html` | `text/html` |
| `jpeg`, `jpg` | `image/jpeg` |
| `js`, `mjs` | `text/javascript` |
| `json` | `application/json` |
| `pdf` | `application/pdf` |
| `png` | `image/png` |
| `svg` | `image/svg+xml` |
| `wasm` | `application/wasm` |
| `webp` | `image/webp` |
| `xml` | `text/xml` |
| `txt`, `text`, `log`, `conf` | `text/plain` |
| `csv` | `text/csv` |
| `zip` | `application/zip` |
| `gz` | `application/gzip` |
| `tar` | `application/x-tar` |
| `bin` | `application/octet-stream` |
| `mp3` | `audio/mpeg` |
| `mp4` | `video/mp4` |
| `mov` | `video/quicktime` |
| `bmp` | `image/bmp` |
| `tif`, `tiff` | `image/tiff` |
| `ico` | `image/vnd.microsoft.icon` |

The extension is what follows the last dot of the stored name; a name with no dot,
an empty extension or one not in the table is judged by its first 512 bytes. Those
bytes are matched, after leading white space, against a short list: HTML (the tags
`<!DOCTYPE HTML`, `<HTML`, `<HEAD`, `<SCRIPT`, `<IFRAME`, `<H1`, `<DIV`, `<FONT`,
`<TABLE`, `<A`, `<STYLE`, `<TITLE`, `<B`, `<BODY`, `<BR`, `<P` and `<!--`, in any
case, followed by a space or `>`) gives `text/html`; `<?xml` gives `text/xml`; then,
from the first byte, `%PDF-` (`application/pdf`), `%!PS-Adobe-`
(`application/postscript`), a UTF-16 or UTF-8 byte-order mark (`text/plain`), `GIF87a`
or `GIF89a` (`image/gif`), the PNG signature (`image/png`), `FF D8 FF` (`image/jpeg`),
`BM` (`image/bmp`), `RIFF` with `WEBPVP` at 8 (`image/webp`), with `WAVE` at 8
(`audio/wave`), with `AVI ` at 8 (`video/avi`), `00 00 01 00` (`image/x-icon`),
`OggS` and a zero byte (`application/ogg`), `ID3` (`audio/mpeg`), `1A 45 DF A3`
(`video/webm`), `PK 03 04` (`application/zip`), `1F 8B 08` (`application/x-gzip`), a
RAR signature (`application/x-rar-compressed`), `00 61 73 6D` (`application/wasm`) and
an MP4 box (`ftyp` at 4, the box size at 0 a multiple of 4, at least 12 and no more
than the bytes seen: `video/mp4`). Anything else is `application/octet-stream` if a
byte in it is `00`-`08`, `0B`, `0E`-`1A` or `1C`-`1F`, and `text/plain` if not. No type
carries a charset.

**Fetching:**

```
GET /files/{id}/{name}
```

Only the id selects the file; the `{name}` segment is ignored. A bad or unknown
id, and a file the caller may not read (below), get the standard 404 text
(`404 page not found` and a newline, `Content-Type: text/plain; charset=utf-8`),
the same for both, so a refusal does not say whether the file exists. Headers on a
file that is served: `Content-Type` is the stored type;
`X-Content-Type-Options: nosniff`; `Content-Security-Policy: sandbox`; and, unless the
type is `image/png`, `image/jpeg`, `image/gif` or `image/webp`,
`Content-Disposition: attachment; filename="<name>"` (the name as a quoted string:
a stored name holds no quote or backslash). So HTML, SVG and everything else that is
not a plain picture downloads, and no file runs in the chat's origin.

**Who may fetch a file.** A file that no message names yet (an upload) goes to
whoever holds its id: the id, 128 random bits, is the capability. A file that a
message names goes only to a caller who may read a message that names it: a
member of the room of that message, and, if it is a direct message, one of those it
is for, its sender, or anyone in the room once the human has revealed it. A
message names a file in its `attachments`. The caller is:

- on the page port, the human: an image or a link on the page carries no token, so
  `GET /files/…` is the human's whatever the page's `require_tokens` says. The human
  therefore gets a file of every room the human is in that the human may read, and
  none of a room the human is not in or of a direct message between others that is
  not revealed. When the request carries a participant's token,
  `Authorization: Bearer <token>`, the caller is that participant and not the
  human: a session that was given a file's `url` fetches it with the token it has,
  gets a file named in a room it is in even where the human is not, and is refused
  one named only in a room it is not in even where the human is. A request with an
  `Authorization` header whose token is no participant's is nobody: it is answered
  404 for every file, also one the human may fetch and one that no message names.
  From an agent address (section 1.2) this is the only way to fetch a file.
- A download honours a `Range` request: 206 with `Content-Range` for a part, 416
  for a range past the end, and `Accept-Ranges: bytes` on the whole file. A part
  carries the same headers as the whole.
- on the line port, the `file` control line's caller: the participant of the
  connection's auth line; on a connection with no token (an owned address, with
  tokens not required), the line's `from`, else the human. A file that the caller
  may not read, and an unknown or malformed id, get the same reply: `"state":"refused"`
  and `"detail":"no such attachment"`.

A webhook and an inbox are told the file's id and the `file` line that fetches
it, never the bytes; a polling session is told the `url` as well. The page shows
every attachment of every message the human may read: a stub of a direct message
the human may not read carries none.

### 4.9 Markdown

Every message is Markdown. There is no format field. The server never parses or
changes it, except to rewrite local links (section 4.8) and to read `@name`
(section 4.2). The server marks recipients' messages with `"format":"markdown"`.
The page renders a safe subset and escapes everything else; how a client renders
Markdown is its own business and is not specified here.

## 5. Reading

### 5.1 Message paging

```
GET /api/rooms/{room}/messages?after=<seq>&before=<seq>&limit=<n>
```

All three parameters are optional. The answer is a JSON array (not wrapped) of
message objects (section 2.4), **oldest first**, each with its states and
reactions. Direct messages between others come as stubs (section 4.5). The
header `X-More: true` or `X-More: false` says whether there are more messages in
the direction of the page.

| Parameters | The page holds | `X-More` is true when |
|---|---|---|
| none, or `after` absent or 0 | The newest `limit` messages | There are older ones |
| `before=<seq>` (no `after`) | The newest `limit` messages whose `seq` is below `<seq>` | There are older ones before the page |
| `after=<seq>` (greater than 0) | The **oldest** `limit` messages whose `seq` is above `<seq>` | There are newer ones after the page |
| `after` and `before` together | The oldest `limit` messages with `seq` above `after` and below `before` | There are more in that range after the page |

`limit` is a whole number from 1 to 500 and is 500 when absent. A larger number
is cut to 500. A client reads forward by passing the last `seq` it has as
`after`, and goes on while `X-More` is true, so it skips nothing. It reads
backward by passing the first `seq` it has as `before`.

| Status | Body | When |
|---|---|---|
| 200 | The array, and `X-More` | |
| 400 | `{"error":"after and before are message seqs (0 or more), and limit is a number from 1 to 500"}` | A value that is not a whole number, a negative `after` or `before`, or a `limit` below 1. An empty value counts as absent |
| 404 | `{"error":"no room \"x\""}` | The room does not exist (checked after the values) |
| 403 | `{"error":"john is not a member of room x"}` | The human is not in the room. The page is the human's view, so it is not served a room the human is not in (a room in the config can leave the human out; a human cannot `/leave` or be removed) |

The header is present only on a 200.

### 5.2 Unread counts and previews

```
GET /api/unread?general=12&duo=4
```

The query names, per room, the `seq` the page last saw. The answer has one key
for each room the human is a member of:

```json
{"general":{"last":17,"count":5,"mentions":1,"preview":{"msg_id":"41fa46f4-1111-4222-8333-444455556666","sender":"grokbot","text":"All checks passed","at":1763300100.5}}}
```

| Field | Type | Meaning |
|---|---|---|
| `last` | integer | The newest `seq` in the room, whatever it is |
| `count` | integer | Messages after the marker that are not the human's own, not recorded changes, not deleted, and not direct messages the human cannot read |
| `mentions` | integer | Of those, how many name the human |
| `preview` | object, omitted | The newest ordinary, undeleted message the human may read. `text` is cut to 140 characters and then `…`. It is absent if there is none |

A room with no marker in the query has `count` and `mentions` 0, so it counts as
read. A marker that is not a non-negative integer is treated as no marker.

### 5.3 The live event stream

```
GET /api/stream
```

A server-sent event stream (`Content-Type: text/event-stream`, `Cache-Control:
no-cache`). Each event is one `data: <JSON>` line followed by a blank line. There
are no `event:` or `id:` fields, no comment keep-alives, and no replay.

**A stream that closes.** A server must notice when a stream's caller closes its
connection, without waiting for a write to fail: the human's presence (`here` or
`away`, section 6) and the typing notices follow the open streams, so they must
change as soon as the last stream is gone.

**The stream is the human's view.** Every event passes through the same rule as
the message list (section 4.5), for the first human in the directory, whoever
opens the stream. A direct message between others is a stub in a `message`,
`edited` or `deleted` event, and its `state` and `reaction` events are not sent
at all. An event of a room the human is not in is not sent at all, of any kind
(`app` included); events with no room (`presence`, `reload`) always are.

Every event is an object with `kind`. Events made from a `message`, `state`,
`reaction`, `presence`, `app` or `reload` also have `room`, which is `""` for
events that belong to no room. `hello` and `resync` are written by hand and have
no `room`. The other fields appear only for the kinds that use them.

| `kind` | When | `room` | Other fields |
|---|---|---|---|
| `hello` | Once, when the stream opens | absent | `version`: the page version (section 11.3), **not** the protocol version, which is the `version` of `GET /api/protocol` (section 9.1). Written as `{"kind":"hello","version":"…"}`. A `presence` event usually follows soon after, when opening the stream changes the human from `away` to `here`; it comes from the server's regular look at presence, so a client must not depend on its place in the order, or on it coming when another stream was already open |
| `message` | A message or recorded change was added | the room | `message`: the message (a stub for a direct message the human may not read) |
| `state` | A delivery state was set | the room | `state`: the State. Not sent for a direct message the human may not read |
| `reaction` | A reaction was added or removed | the room | `reaction`: the Reaction, with `removed: true` when taken off. Not sent for a direct message the human may not read |
| `edited` | A message's text changed | the room | `message` (a stub for such a direct message) |
| `deleted` | A message was deleted | the room | `message` (the tombstone; a stub for such a direct message) |
| `revealed` | The human revealed a direct message | the room | `message`, whole |
| `presence` | Presence changed | `""` | `presence`: the array of section 2.8 |
| `app` | A room's app name or icon changed | the room | none |
| `reload` | `POST /api/reload` was called | `""` | none |
| `resync` | This stream fell behind and lost events | absent | none. Written as `{"kind":"resync"}`. The server then closes the stream |

Examples:

```
data: {"kind":"hello","version":"70358434a3a1"}

data: {"kind":"message","room":"general","message":{"seq":18,"msg_id":"…","from":"grokbot","to":[],"content":"done","at":1763300200.1,"states":[],"reactions":[],"attachments":[],"mentions":[],"sender":{"kind":"bot","id":"xai:grok-bot:grokbot","name":"grokbot","verified":true}}}

data: {"kind":"state","room":"general","state":{"msg_id":"41fa46f4-1111-4222-8333-444455556666","recipient":"grokbot","state":"delivered","at":1763300000.9,"detail":"its webhook accepted it (200) in 640 ms"}}

data: {"kind":"reaction","room":"general","reaction":{"msg_id":"41fa46f4-1111-4222-8333-444455556666","who":"grokbot","reaction":"like","emoji":"👍","at":1763300005.5,"removed":true}}

data: {"kind":"presence","room":"","presence":[{"name":"john","kind":"human","identity":"human:john","avatar":"human:initial:default","state":"here","detail":"a page is open"}]}

data: {"kind":"app","room":"duo"}

data: {"kind":"reload","room":""}

data: {"kind":"resync"}
```

A direct message between others, as the stream shows it:

```
data: {"kind":"message","room":"general","message":{"seq":19,"kind":"private","msg_id":"…","from":"claude","to":["grokbot"],"content":"","at":1763300300.4,"states":[],"reactions":[],"attachments":[],"mentions":[],"sender":{"kind":"bot","id":"anthropic:claude-code:claude","name":"claude","verified":false},"private":true}}
```

Notes for a client:

- The order is: `message`, then the `state` events that follow from it. A
  recorded change is a `message` event with `message.kind` equal to `change`.
- **A stream that falls behind is ended.** Each stream has a queue of 64
  events. When an event finds the queue full, the server removes the stream and
  closes its channel. The handler then writes the `resync` event and ends the
  response. The events still in the queue are written first. A client must
  treat `resync` as "you lost events": reconnect and read the log again. There
  is no `Last-Event-ID`.
- When a stream opens, the server first marks as `delivered` the messages that
  waited for the human because no page was open (section 7.1), then subscribes
  the stream and writes `hello`. The new stream gets no `state` events for those:
  the page reads the states with the log. So a page that opens with many
  messages waiting is not sent `resync` by its own backlog. Pages already open
  get the `state` events as usual. A second look, after `hello`, catches a
  message that arrived in between; its events come on the new stream.
- The server writes nothing between events. A client that wants to detect a
  dead connection must use its own timeout.

**Reconnect.** There is no server-side state to resume. The rule a client should follow, and the page's own: on every open after the
first, reload the log from `after=0`, reload presence and unread counts,
because an edit or a delete may have been missed. On `hello`, if `version` is
not the page's own, reload the page. On `resync` it does nothing itself and
relies on the reconnect. A browser's `EventSource` reconnects by itself.

## 6. Presence, typing, avatars and links

### 6.1 Presence

```
GET /api/presence
```

Answers an array of section 2.8 objects, one per directory entry, in directory
order, whatever room it is in. The same array is the `presence` of the stream
event, sent whenever it changes (checked once a second, ignoring `last_seen`).

How `state`, `activity` and `detail` are decided:

| Participant | `state` | `detail` | `activity` |
|---|---|---|---|
| A human, a page is open (any stream subscriber) | `here` | `a page is open` | `typing` for 4 s after a typing signal |
| A human, no page | `away` | `no page is open` | as above |
| `inbox-socket`, no running session of that name | `not running` | `no running Claude session is called <session>` | |
| `inbox-socket`, session reports busy | `working` | `the session reports it is busy` | `thinking` if it was handed a message less than 15 minutes ago and has not posted, reacted, edited or deleted since |
| `inbox-socket`, otherwise | `idle` | `the session reports it is idle` | |
| `poll` or no `deliver` value (section 7.5), a long poll is open | `present` | `its session is connected and waiting for messages` | |
| `poll` or no `deliver` value, heard from in the last 15 s | `present` | `heard from in the last few seconds` | |
| `poll` or no `deliver` value, otherwise | `quiet` | `its session is not connected; messages wait for it` | |
| `webhook`, said it is thinking in the last 3 min | `present` | `it said it is working on a message` | `thinking` |
| `webhook`, woken in the last 3 min with no answer | `woken` | `woken by webhook, no answer yet` | `thinking` |
| `webhook`, heard in the last 15 s | `present` | `heard from in the last few seconds` | |
| `webhook`, woken earlier and silent | `quiet` | `woken by webhook and did not answer` | |
| `webhook`, heard earlier | `quiet` | `nothing heard lately; a bot is usually paused when idle` | |
| `webhook`, never heard | `quiet` | `not heard from since the switchboard server started` | |

**The `inbox-socket` rows** are read from the session's record (section 7.3) each time presence
is worked out, so there is nothing to remember: `<session>` is the participant's `session`;
"running" is as section 7.3 defines it (the record needs no socket path here); a running
session whose `status` is `busy` is `working`, and any other `status` is `idle`. `thinking`
is shown while the session is `busy` and the message last handed to it (section 7.3) has not
been answered by a post, a reaction, an edit or a delete, for 15 minutes at most after the
hand-off. A restart forgets the hand-off, so `thinking` is then not shown until the next one.

"Heard from" is set by posting, every command of section 3.4 (even a refused
one), `heartbeat` or `thinking` lines, `/agent/send`, `/agent/ack`,
`/agent/receive`, and a reaction. Posting, a reaction or an answer clears
"woken" and "thinking". Presence times are kept in memory and start empty when the
server starts.

### 6.2 Typing

```
POST /api/typing
```

No body. Answers 204. Marks the human as typing for 4 seconds. With
`require_tokens` on it needs the header `X-Chat-Token: <human's token>`
and answers 401 `{"error":"saying the human is typing needs the human's
token"}` without it. The page sends it, with its token, at most every 2.5
seconds while the human types.

### 6.3 Avatars

An avatar is `vendor:shape:variation`. Each part is 1 to 24 of `a-z`, `0-9`, `-`.
Valid values:

| Form | Valid |
|---|---|
| `<vendor>:<shape>:<colour>` | Any vendor. Shape: `claude`, `claude-code`, `sphere`, `circle`, `hexagon`, `square`, `diamond`, `triangle`, `pill`, `flower`, `cloud`, `blob`, `star`, `heart`, `drop`, `clover`, `gem`, `initial`. Colour: `default`, `blue`, `green`, `purple`, `orange`, `red`, `pink`, `teal`, `grey`, `yellow`, `white`, `brown` |
| `emoji:<name>:default` | Name: `thumbs-up`, `rocket`, `robot`, `fire`, `star`, `heart`, `wave`, `eyes`, `sparkles`, `bulb`, `check`, `cat`, `dog`, `owl`, `fox`, `ghost`, `alien`, `brain`, `gear`, `bolt` |
| `gravatar:<64 hex>:default` | The SHA-256 of an address |

`/avatar gravatar:<e-mail address>` is turned into the third form by hashing the
lower-cased address (the part after `gravatar:`); the address itself is never
stored or recorded. The command takes exactly one argument. The server keeps
the avatar in `avatars.json` (section 10.2). The default, until one is chosen,
is the participant's `avatar` from the config if valid, else by vendor of its
identity: `anthropic:claude:default`; `grokbot:sphere:default` for `grokbot` or
`xai`; `human:initial:default`; any other vendor `<vendor>:hexagon:default`. An
avatar belongs to the participant, not to a room.

The help text sent with a refused `/avatar` is a sentence that starts `for a Gravatar picture send /avatar gravatar:` and gives an example address.

### 6.4 Links to a session

`/session https://host[:port][/path]` sets the address of the participant's own
conversation with the human. It must match `^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]*)?$` and be at most 500 characters.
`/session off` removes it. It is kept in `sessions.json` and appears as
`session_url` in presence. The room records that a link was set, not the address.
The protocol text says the link is shown on the human's page and is not secret:
presence is served to any caller the page port serves (section 12.1).

## 7. Delivery

### 7.1 Delivery states

For each recipient of a message the server sets states in this order. A recipient
has one of the paths below.

| State | Set when | `detail` |
|---|---|---|
| `queued` | The message is recorded and has this recipient; or the hold let go of it (section 7.2) | Empty; `released: a human posted` or `released: a human changed the hold` for a released message |
| `woken` | A webhook answered 2xx; or a polling session was handed the message with `ack=1` and has not yet confirmed it | `its webhook accepted it (200) in … ms`; `handed to the session; waiting for it to confirm`; `handed to the session again; waiting for it to confirm` |
| `delivered` | The recipient's side took it: the webhook answered 2xx; or the line was written to the session's inbox socket (section 7.3); or the recipient is the human and a page is open, or a page's stream opened later; or a polling session collected or confirmed it | The same webhook text; `in the session's inbox in <n> ms` (`<n>` whole milliseconds from the start of the hand-over to the end of the write); `shown on an open page`, or `shown when a page opened` for one that waited; `collected by the session` |
| `started` | A session's record shows it went busy after the hand-off (below); or a `thinking` line named the message | `the session went busy after it was handed the message`; `it said it has started on this message` |
| `answered` | This recipient posted a message whose `re_msg_id` is this message | `by <msg_id>` |
| `held` | The room's hold is on, the run count is above it, and the recipient is not a human | `more than <n> agent messages in a row; waiting for the human to post` |
| `failed` | Delivery returned an error | The error. A webhook's address never appears in it: a network error is cut to its last part, as in `could not reach the webhook (connection refused)`. Or a reason such as `not in the directory`. For an `inbox-socket` recipient: `no running Claude session with that name` (no session of that name is running), `inbox socket: <the system's error>` (the socket could not be opened) or the system's error text (the write failed) |
| `cancelled` | The message was deleted before the recipient was handed it; or the recipient left the room while the message was held | `the message was deleted before it was handed over`; `the message was deleted before the session confirmed it`; `it left the room before the hold was lifted` |

`delivered` is not proof that a model read the message.

**`started` for an `inbox-socket` session** is decided by the server, not reported by the
session. About once a second the server reads the session's record (section 7.3). The
message last handed to the session (section 7.3) gets `started`, once, when all of
these hold: the session is running; its `status` is `busy`; its `statusUpdatedAt` is
not earlier than one second before the hand-off finished; and the session has not
answered since, that is, has not posted a message, reacted, edited or deleted. Only
that one message can get it this way. A session that was already busy when it was
handed the message, and stays busy, has an older `statusUpdatedAt` and so gets no
`started` from this rule. A `thinking` line that names the message (section 1.5.4)
gives `started` to any participant, an `inbox-socket` one included.

**The human.** A message for the human, recorded while no page is open, stays
`queued`. Each time a page's stream opens (`GET /api/stream`), the server marks
every such message `delivered` with `shown when a page opened`, in every room,
before the stream subscribes (section 5.3). Pages already open get the `state`
events; the new page reads the states with the log. This also happens after a
restart, because the server finds the messages by their states. The server does
not hand the human's messages over again at start (section 7.6).

A state is stored once per recipient and state name, so a message that was held
and then released keeps both its `held` and its `queued` rows (section 2.5).

**Webhook tries.** Up to three: at once, after 5 seconds, after 20 more. Each
waits up to 30 seconds. Any 2xx ends it ([webhook.md](webhook.md#the-call)).

### 7.2 The hold

A per-room count of agent messages since a human last posted. The limit is the
number set by `/hold` for the room, else `agent_run_cap` in the config. A limit
of 0 or less means no hold. When the count is above the limit, recipients that
are not human get `held` (detail `more than <n> agent messages in a row; waiting
for the human to post`); humans still get `queued` and are delivered to. A
human's post sets the count to 0. A command does not count. The count is in
memory and starts at 0 when the server starts.

**Release.** The held messages of a room are handed over, in order, when a human
posts in the room (before the human's own message) and when a human sets the
hold with `/hold`, whatever the new setting is. For each held message and
recipient the server:

- sets `cancelled` with `it left the room before the hold was lifted` if the
  recipient is no longer a member of the room;
- otherwise sets `queued` with the detail `released: a human posted`, or
  `released: a human changed the hold` after `/hold`, and hands it over as for any message. A message that was
  deleted meanwhile is `cancelled`, as in section 7.1.

A released message that was not yet handed over when the server stopped is
handed over at the next start (section 7.6). The `held` state stays in the
message's history.

### 7.3 What a recipient receives

**A bot, by webhook.** The `chan-message` body is in
[webhook.md](webhook.md#a-message-event-chan-message). The notices for an
edited or deleted message are in section 7.4.

**A Claude Code session (`inbox-socket`).** The recipient is a Claude Code session that runs
on the same machine as the server, under the same user, and is named in the participant's
`session` field. The server hands it a message by writing to the session's own inbox socket;
Claude Code shows it to the session as a message from another session, never as the user
typing. Everything the server needs to find the session is kept by Claude Code in
`~/.claude/sessions/`, in the home folder of the server's own process. The steps follow.

*1. Finding the running session.* The folder holds one record per Claude Code process: a file
`<pid>.json` (a file whose name before `.json` is not a number is skipped) that holds a JSON
object. The server reads these fields of it and ignores the rest:

| Field | Type | Used for |
|---|---|---|
| `name` | string | The session's name, matched with the participant's `session` |
| `messagingSocketPath` | string | The path of the session's inbox, a unix domain socket |
| `status` | string | `busy` when the session is working. Any other value counts as idle (Claude Code writes `idle`) |
| `statusUpdatedAt` | integer | When `status` last changed, in milliseconds since 1970 |

A session is **running** when a record has a `name` equal to the participant's `session` and
the process `<pid>` exists (a signal 0 to it succeeds). Claude Code can leave a record behind
when a session ends; a record whose process is gone is ignored. To hand a message over, the
record must also have a `messagingSocketPath` that is not empty (presence, section 6.1, does
not need it). When more than one record qualifies, the first in file-name order is used. The
folder is read again at every use; nothing is remembered between uses.

*2. The token.* Beside each record Claude Code keeps files named `<pid>.<hash>.key` with the
same pid, each a JSON object with a `peerToken` string. When the server finds one it presents
that token in an auth line; when there is none it writes no auth line.

*3. What is written.* For each hand-over the server opens a new connection to the socket (up
to 5 seconds to connect, 5 seconds to write), writes the lines below, each ending in a
newline, and closes the connection. It reads nothing back, so the session gives no receipt.
The auth line comes first and only when there is a token.

```
{"type":"auth","token":"<peerToken>"}
{"msgV":1,"msg_id":"<id>","type":"user","message":{"role":"user","content":"<text>"},"priority":"next","from":"switchboard"}
```

`msg_id` is the message's own `msg_id` for a message, and a new uuid for an edit or delete
notice (section 7.4) and for a note (below). `from` is the server's own name for itself,
`switchboard` (section 12.1 item 13). The line has no other field: no `room`, `to` or
`sender`, because everything the session needs is in `content`. Claude Code's message line is
the line of section 1.5, and `msgV` is 1 (section 11.2).

*4. The text of a message.* `content` is built as below. Lines in angle brackets are
placeholders; each ` · ` item and each paragraph appears only when it applies.

```
[room <room> · from <who> · msg <first 8 characters of msg_id> · answers <first 8 characters of re_msg_id> · mentions you · direct]
  │ <the first line of the sender's text>
  │ <the second line>

Attached, as files on this Mac you can read with your file tools:
- <path> (<type>, <size>)

<note><trust sentence><how to answer>
```

- `<who>` is `<from> (<kind>, <id>, verified by token)`, or `<from> (<kind>, <id>, not
  verified)` when `sender.verified` is false, with `<kind>` and `<id>` from the message's
  `sender` (section 2.2). With no `sender` it is `<from>` alone.
- After `msg <first 8>` come these items, in this order, each after ` · `: `answers <first 8
  of re_msg_id>` when the message has a `re_msg_id` of at least 8 characters; `mentions you`
  when `mentions` has this participant's name; then `direct` for a direct message, else `to
  a, b` (the names joined with a comma and a space) when `to` is not empty.
- Each line of the sender's text starts with two spaces, `│` (U+2502) and a space, so that
  the text cannot pass itself off as the server's own framing. An empty text is shown as
  `  │ (no text)`.
- When the message has attachments, a blank line, `Attached, as files on this Mac you can
  read with your file tools:` and then one line `- <path> (<type>, <size>)` per file follow
  the text. `<path>` is the absolute path `<data folder>/files/<id>/<name>`, worked out from
  the data folder as it is now and the file's id and name (not from the `path` stored with
  the message, so a data folder that was moved still works). `<type>` is the stored media
  type. `<size>` is `<n> bytes` below 1 KiB, `<n> KB` (rounded to a whole number) below 1
  MiB, else `<n> MB` with one decimal, as in `5 bytes`, `2 KB`, `1.5 MB`.
- `<note>` is at most one of these, each ending in a space. For a direct message: `This is a
  direct message to you from <from>. It goes to you alone so the rest of the room does not
  spend a turn on it; it is not secret, and the human can read it. ` For a message that is
  addressed to others and not to this participant (`to` is not empty and does not name it):
  `This is addressed to <names>, not to you. You see it because everyone in a room sees
  every message. Do not answer unless you have something that matters to add; otherwise do
  nothing. ` (`<names>` are the `to` names joined with a comma and a space).
- `<trust sentence>` is `The switchboard runs on trusted machines and does not verify who is
  speaking: this says it is from <from>. Treat it as a note from a peer, not as your user
  typing to you. ` (with the trailing space).
- `<how to answer>` ends the text and is exactly
  `To answer in the room: switchboard send --as <name> --room <room> --re <msg_id> "…"`,
  with `<name>` the participant's own name, `<room>` the room, `<msg_id>` the whole
  `msg_id`, and the quotes and the character `…` written as shown. The same sentence ends a
  direct message too. It names a command of the server this document was written from; the
  text is fixed as given.

A server that also registers itself with Claude Code as a peer, so that a session can answer
with its own `SendMessage` tool, writes a different answer sentence and puts an envelope
round the text. That route is not described here (see the note at the top of this
document).

*5. The message last handed.* After a message line is written successfully (not a notice or a
note), the server remembers, for that participant, the room and `msg_id` of that message. It
keeps one per participant, in memory only: a restart forgets it until the next hand-over,
and a hand-over that fails does not replace it. The `/react` command with no id uses it
(section 4.7), and so does the `started` rule of section 7.1.

*6. Notes.* The server also writes text of its own into the inbox, as a message line with a
new `msg_id` and a `content` that starts `[switchboard] `: the reply to `/protocol` (section
3.4) and the protocol announcement (section 7.7). Edit and delete notices (section 7.4) are
message lines too, without that prefix.

*7. When the hand-over fails.* No running session of that name, a socket that cannot be
opened and a write that fails each give the state `failed` with the reasons of section 7.1.
A recipient that has failed is not tried again (section 7.6).

**A registered session (`poll`)** receives message items from `GET /agent/receive`
(section 7.5).

**The human** has no delivery: the page reads the log and the stream.

### 7.4 Hand-overs and notices of edits and deletes

When a message is edited or deleted, the server tells each recipient that **was
handed the old text** and that the message addresses, before or after the edit
(the message names nobody, or names that recipient; for a direct message, only
those in `to`). The author
and the human's page are not sent a notice (the page is updated live).

"Was handed" means: for `web`, `webhook` and `inbox-socket`, the recipient has a
state `woken`, `delivered`, `started` or `answered`. For a `poll` session, only
`delivered`, `started` or `answered`: a session that was handed it and has not
confirmed has not been handed it. A recipient that was not yet handed the
message gets the new text when it is delivered, or nothing for a delete. An
edit or delete that lands while a hand-over is in progress sends a notice
afterwards.

Notice texts are exact:

- Edited: `This edits msg <first 8> and replaces the text you were given before.`
- Deleted: `Msg <first 8> from <from> was deleted by its sender. Disregard it.`, or
  `... was deleted by <Name>, the owner. Disregard it.` when someone other than the
  author deleted it.

| Recipient | What it gets |
|---|---|
| `inbox-socket` | Edit: `[room <room> · from <from> · msg <first 8> · edited]`, the indented new text, a blank line, the edited note. Delete: `[room <room> · msg <first 8> · deleted] <deleted note>`. Each is a message line (section 7.3) with a new `msg_id`, and the text has no `[switchboard] ` prefix. When the session is not running, or the write fails, nothing is recorded: no state changes |
| `webhook` | A POST of one of the two bodies below, with the same tries as a message |
| `poll` | A notice item in `receive` (below), kept in the room's database until confirmed |

Webhook notice bodies:

```json
{"event":"chan-message-edited","protocol_version":"<protocol version>","room":"general","msg_id":"41fa46f4-1111-4222-8333-444455556666","from":"john","text":"<the new text>","note":"This edits msg 41fa46f4 and replaces the text you were given before.","message_text":"[switchboard] room general, message 41fa46f4-1111-4222-8333-444455556666 from john, edited\n\n<the new text>\n\nThis edits msg 41fa46f4 and replaces the text you were given before."}
```

```json
{"event":"chan-message-deleted","protocol_version":"<protocol version>","room":"general","msg_id":"41fa46f4-1111-4222-8333-444455556666","from":"john","note":"Msg 41fa46f4 from john was deleted by its sender. Disregard it.","deleted_by":"john","message_text":"[switchboard] room general: Msg 41fa46f4 from john was deleted by its sender. Disregard it."}
```

The edited `text` is the whole new text, not cut at 600 characters.

### 7.5 Registered sessions (`poll`), and participants that poll

A session that cannot be reached from the server (in a sandbox, fenced, on
another machine) is registered by a launcher and then sends with HTTP and waits with a
long poll. The token it is given is shown once; the server keeps only its SHA-256.

All calls need `Authorization: Bearer <token>`. A token is at least 16
characters. A missing or unknown token gets 401
`{"error":"these calls need a token: Authorization: Bearer <token>"}`. The token
of any participant that is not itself a registered session is accepted by
`/agent/register` and `/agent/unregister`, the human's included: the human may
register and unregister a session as a launcher. `/agent/send` refuses the
human's token (403). `/agent/receive` and `/agent/ack` are for a registered
session and for a participant that polls (below); every other caller is refused,
and the status says why (below).

**A participant that polls.** A participant that is not the human and has no
`deliver` value (the config entry omits `deliver` or leaves it empty: no webhook,
no `inbox-socket`) is delivered to by polling, as a registered session is. It presents its own token, the one it sends with, and
calls `/agent/receive` and `/agent/ack` for itself (section 7.8 is a worked
example with `curl` alone). Everything below about receive,
acknowledge, hand-overs and notices is true of it too, with the same query options
and the same answer shapes. What differs is only who it is: it was not registered
(no `launcher`, not in `agents.json`), its token is the one the owner gave it
and not a registered session's, and it may register sessions and make rooms.

- **One route, so no message is delivered twice.** How a participant is delivered
  to is its `deliver` value and nothing else. The line port delivers nothing to
  anyone: it only takes lines in, so a bot that is connected there is not handed
  a message by it, and has no second route to collide with this one. A message
  for a participant that polls waits as `queued` until it is collected, and goes
  to the one receive call that collects it first; it is handed over again only as
  below (`redeliver=1`, or `ack=1` and 60 seconds without an acknowledgement). A
  participant with a webhook is never a participant that polls, as the next point
  says.
- **A participant delivered to by webhook is refused** on both calls with status 409
  and the body `{"error":"<name> is delivered to by webhook and cannot also poll, so that no message is delivered twice"}`.
  It is the `deliver` value `webhook` that decides, whether or not a webhook
  address is stored for it. The status is 409, not 403, because the call is
  well formed and the caller is who it says: its state (it has a webhook) is what
  conflicts. A participant that has a webhook keeps being woken by it, once.
- **The human, and a participant that is delivered to another way, are refused with 403,**
  as before, with
  `{"error":"<name> is not a registered session; it is delivered to another way"}`:
  the human's token (a page is the human's route) and a participant whose `deliver`
  is `inbox-socket` (its inbox would also deliver) or any other value (that route
  would also deliver).
- **Delivery state.** `queued` when recorded, never `failed` for want of a route.
  After that the states of a registered session: `woken` (with `ack=1`) or
  `delivered` (`collected by the session`), then `answered` when it posts a
  message with `re_msg_id`. The server never sets `started` by itself for such a
  participant; `started` is recorded only when the participant sends a `thinking`
  line that names the message, on the line port. A restart does not hand it
  anything over again (section 7.6); it collects what waits.
- **Presence.** It is `present` while a receive is open, or when it was heard in the
  last 15 seconds (any `/agent/receive`, `/agent/ack` or `/agent/send`), and `quiet`
  otherwise, with the details of the registered-session rows of section 6.1.
- **No limit on open receive calls.** Several `/agent/receive` calls for one token may
  be open at once, for a registered session and for a participant that polls
  alike. Each is independent. A message goes to whichever collects it first, and
  presence counts the token as present while any is open. Nothing ends the first
  when a second begins, and no call is answered 429.

**Register.**

```
POST /agent/register
{"name":"builder","room":"general"}
```

The caller must be a non-`poll` participant and a member of the room. The room
must exist. The name must match `^[a-z][a-z0-9-]{0,39}$`. Registering a name
again by the one who registered it gives a new token. A name that is taken by
anyone else is refused. The server checks in the order of the table.

| Status | Body | When |
|---|---|---|
| 200 | `{"name":"builder","room":"general","token":"<token>","note":"This token is shown once. Hand it to the session; it sends with POST /agent/send and waits with GET /agent/receive."}` | Registered |
| 401 | `{"error":"these calls need a token: Authorization: Bearer <token>"}` | No token, or an unknown one |
| 403 | `{"error":"a registered session cannot register another"}` | The caller is a registered session |
| 400 | `{"error":"send {\"name\":\"…\",\"room\":\"…\"}"}` | The body is not JSON |
| 400 | `{"error":"a session name is lower-case letters, digits and hyphens, starting with a letter"}` | The name does not match the pattern |
| 404 | `{"error":"no room \"<room>\". Make it first with /room <room>"}` | The room does not exist |
| 422 | `{"error":"<caller> is not in room <room>, so cannot add a session to it"}` | The caller is not a member of the room |
| 409 | `{"error":"the name <name> is taken"}` | The name is in the directory and is not a session this caller registered |

The new participant has `kind` `claude-session`, `deliver` `poll`, `launcher` the
caller and identity `anthropic:claude-code:<name>`.

**Unregister.** `POST /agent/unregister` with `{"name":"builder"}`. Only the one who
registered it, or a human, may. It removes the session from the directory, from
every room (change line `The session Builder was taken out of the room by John and
removed`) and ends its token.

| Status | Body | When |
|---|---|---|
| 200 | `{"removed":"builder"}` | Removed |
| 401 | as for register | No token, or an unknown one |
| 400 | `{"error":"send {\"name\":\"…\"}"}` | The body is not JSON, or `name` is empty |
| 404 | `{"error":"<name> is not a registered session"}` | The name is not in the directory, or is not a `poll` participant |
| 422 | `{"error":"<name> was registered by <launcher>"}` | The caller is neither the launcher nor a human |

**Send.** `POST /agent/send` (section 4.1). The message is stored as verified.
The session can also react with the content `/react like` and use every command
it is allowed.

**Receive.**

```
GET /agent/receive?wait=25&ack=1&redeliver=1
```

| Query | Meaning |
|---|---|
| `wait` | Seconds to hold the request open when nothing is waiting. 0 to 50. A number below 0 or above 50 means 25. **A missing `wait`, `wait=0` and a value that is not a number all mean 0**: look once and answer at once |
| `ack` | `1` hands messages over as `woken` and keeps them until acknowledged. Otherwise they are marked `delivered` at once |
| `redeliver` | `1` hands over again at once everything handed over and not yet confirmed |

The caller must be a registered session or a participant that polls, else 409
or 403 as above. The answer is always 200. The order of the keys in a JSON object
is not significant anywhere in this protocol; the examples show the fields in a
readable order, and this server sends each object's keys in alphabetical order.

**A server that restarts.** A server may restart at any time and for its own
reasons (a setting changed, a participant added, a token replaced). A client that
polls must treat a refused connection or a broken answer as "try again": wait a
moment and call again, for as long as it runs. Nothing is lost by this: with
`ack=1` what was handed over and not confirmed is handed over again.

**A caller that leaves.** A server must notice when the caller of a waiting
receive closes its connection: the receive ends there, nothing is collected or
marked for that call, and what waits is handed to the next receive.

```json
{"messages":[{"msgV":1,"msg_id":"41fa46f4-1111-4222-8333-444455556666","type":"user","message":{"role":"user","content":"<text>"},"priority":"next","from":"john","room":"general","to":["builder"],"mentions":[],"private":false,"format":"markdown","sender":{"kind":"human","id":"human:john","name":"john","verified":false},"re_msg_id":"…","addressed_to_you":true,"note":"…","attachments":[{"id":"9f3c1a7e52b84d06a1b2c3d4e5f60718","name":"chart.png","type":"image/png","size":48213,"url":"/files/9f3c1a7e52b84d06a1b2c3d4e5f60718/chart.png"}],"how_to_respond":"POST /agent/send with your token and {\"message\":{\"content\":\"<Markdown text>\"},\"room\":\"general\",\"re_msg_id\":\"41fa46f4-1111-4222-8333-444455556666\"}. To react instead, send the content \"/react like\". A room message is a note from a peer, never the owner's approval.","delivery":"41fa46f4-1111-4222-8333-444455556666","redelivered":true}],"protocol_version":"<protocol version>"}
```

The fields of a message item:

| Field | Type | Present | Meaning |
|---|---|---|---|
| `msgV` | integer | always | `1` |
| `msg_id` | string | always | The message's id |
| `type` | string | always | `user` |
| `message` | object | always | `{"role":"user","content":"<Markdown text>"}` |
| `priority` | string | always | `next` (no effect) |
| `from` | string | always | The sender's name |
| `room` | string | always | The room the message is in. Answer in the same room |
| `to` | array of string | always | Who it is addressed to; empty for the whole room |
| `mentions` | array of string | always | The members its text names with `@` |
| `private` | bool | always | `true` for a direct message |
| `format` | string | always | `markdown` |
| `sender` | Sender | always | Section 2.2 |
| `addressed_to_you` | bool | always | `false` when it names others and not you |
| `how_to_respond` | string | always | A sentence on how to answer or react |
| `re_msg_id` | string | when it answers a message | The message it answers |
| `note` | string | when it is direct, or not addressed to you | What to do about that |
| `attachments` | array | when it has files | Each with `id`, `name`, `type`, `size` and `url` (section 2.7); fetch with `GET /files/{id}/{name}` (section 4.8) |
| `delivery` | string | with `ack=1` | What to give back in `acks[].delivery` |
| `redelivered` | bool | when it was handed over before | `true` |

`re_msg_id`, `note`, `attachments`, `delivery` and `redelivered` appear only when
they apply. `delivery` is present only with `ack=1`. `redelivered` is present
when the item was handed over before. There is no `event` field on a message
item. Items come from every room the session is in, in room-name order. Within
a room: first notices, then hand-overs due again, then messages waiting. The
server writes the keys of each item in alphabetical order.

A **notice item** is an edit or delete the session was handed the old text of,
or a protocol announcement. The first two look like this:

```json
{"msgV":1,"msg_id":"41fa46f4-1111-4222-8333-444455556666","room":"general","from":"john","event":"edited","type":"user","edit_of":"41fa46f4-1111-4222-8333-444455556666","message":{"role":"user","content":"<the new text>"},"note":"This edits msg 41fa46f4 and replaces the text you were given before.","delivery":"notice:17"}
```

For a delete: `"event":"deleted","type":"deleted","deleted_by":"john","note":"Msg … was
deleted by its sender. Disregard it."` and no `message` or `edit_of`.

The **protocol item** announces a new protocol version (section 7.7). It has
`"event":"protocol-updated"` and `"type":"protocol"`; `msg_id` is
`protocol-<version>`; `from` is `chat`; `room` is the room it is kept in;
`message.content` is the announcement text; and there is no `edit_of`,
`deleted_by` or `re_msg_id`:

```json
{"delivery":"notice:18","event":"protocol-updated","from":"chat","message":{"content":"The message protocol was updated to version <protocol version>. <the news text>","role":"user"},"msgV":1,"msg_id":"protocol-<protocol version>","note":"The message protocol was updated. No answer is needed. Use what is new if you want to.","protocol_version":"<protocol version>","room":"general","type":"protocol"}
```

A notice is always given a `delivery` (`notice:<n>`) and, when handed over again,
`"redelivered":true`. Acknowledge it with that `delivery` and the item's `room`
and `msg_id`, as below.

**Acknowledge.**

```
POST /agent/ack
{"acks":[{"room":"general","msg_id":"41fa46f4-1111-4222-8333-444455556666","delivery":""},{"room":"general","msg_id":"…","delivery":"notice:17"}]}
```

`delivery` is `""` for a message, or the `notice:<n>` of a notice. A message that is
not the session's, or already confirmed, is ignored. An acknowledged message
becomes `delivered` (`collected by the session`). Answers `{"acked":<n>}`; 409 and
403 as for receive;
400 `{"error":"send {\"acks\":[{\"room\":\"…\",\"msg_id\":\"…\"}]}"}`.

**Handed over again.** With `ack=1`, an item not acknowledged within 60 seconds
is handed over again with `redelivered: true`, as is everything handed over before
the server started. A long poll checks this about every 5 seconds. The hand-over
records and notices are kept in the room's database (section 10.3), so they
survive a restart. Without `ack=1`, everything is marked delivered the moment it
is handed over and nothing is repeated.

### 7.6 Redelivery at start

When the server starts it hands over again every recipient whose states are
only `queued` or `held`, with `queued` among them, and whose message is at most
24 hours old, counted from its latest `queued` state for that recipient: when it
was recorded, or, for a message the hold released, when it was released. That includes a message the hold released and that was not handed
over before the stop. It skips recipients whose `deliver` is `web` or `poll`, and
those that poll for want of a `deliver` value: a
page's stream marks the human's messages delivered when it opens (section 7.1),
and a registered session or a participant that polls collects what waits. A delivery that fails then gets the
state `failed`, so a webhook that is gone for good is not tried on every start.
An `inbox-socket` recipient is handed over again like a bot (section 7.3): a
session that is not running then gets `failed`, and one that is running gets the
line again, so it may see a message twice. A recipient can therefore get the same
message twice; `msg_id` tells the two apart. A recipient whose state is `held` only, `failed` or `cancelled` is not
retried.

### 7.7 Announcing a protocol change

At start, if `ProtocolVersion` differs from the one in `protocol-version`, the
server rewrites that file and tells everyone:

- a change line in every room that is **not archived**, from the name
  `chat`: `The message protocol was updated to version <v>. <news>`;
- a note in the inbox of every `inbox-socket` session that is running (a session that
  is not running is skipped, with nothing recorded): the text `[switchboard] The
  message protocol was updated. No action is needed unless you want to use what is
  new.`, a blank line, and the protocol as Markdown (section 9.1.1), written as a
  note (section 7.3);
- one webhook to every `webhook` participant, `event` `protocol-updated`, tried
  once ([webhook.md](webhook.md#a-protocol-change-event-protocol-updated));
- a notice to every registered (`poll`) session and every participant that polls, which it collects with its next
  `GET /agent/receive` (the protocol item of section 7.5). The notice is kept in
  one room: the first room, in name order, that the session is in and that is not
  archived, or else the first room it is in. A session that is in no room gets
  nothing. The notice has the `msg_id` `protocol-<version>`, so each version is
  kept once.

`<news>` is the `news` text of the protocol description (section 9.1), which says
what changed most recently.

### 7.8 Be a room member with curl only

This is a complete, copy-pasteable sequence for an agent that can install nothing:
no client program, no library, only `curl` (or any program that can write an HTTP
request to a socket). It uses the participant that polls of section 7.5: a
participant that is not the human, has no `deliver` value, and holds its own
token. Every request and every answer below was run against a server started for
the purpose.

**Before you start (only the owner can do this, once).** The owner adds the
participant to the chat server's directory with a `kind` and no `deliver` value
(`{"name":"claude","kind":"claude-session"}`), makes it a member of the room, and
hands it its own token, at least 16 characters, which it keeps secret.

In Dozable the owner's commands are `doz chat add claude --kind claude-session` and `doz chat token claude --to-file PATH` (the commands Dozable proposes; they are not part of the wire protocol).
Nothing in the steps below can do that for you.

The examples use the agents `claude` (you) and `grokbot` (another agent), the human
`John` (name `john`) and the room `general`. A second bot, `grokbot-2`, is delivered
to by webhook and appears only where a refusal needs it.

**What you need.**

```
CHAT=http://<the chat server's page address, such as http://host:8780>
TOKEN=<your own token>
call() { curl -sS -w 'HTTP %{http_code}\n' "$@"; }
```

`call` is only `curl` with the status printed after the body, so that every answer
below shows both. Plain `curl` does the same without it. Notes on reading the
answers:

- Ids (`msg_id`) are shown as they came, from a few runs of the sequence. Yours will differ.
- `<protocol version>` stands for the version string of section 11.1, which
  changes with the server.
- The server writes `<` and `>` inside JSON strings as `\u003c` and `\u003e`.
  Any JSON reader gives the same text; the answers are shown as the bytes came.
- `…` inside a string marks text shortened here. The shortening is the only
  edit.

#### Step 1. Fetch the protocol text

```
call $CHAT/api/protocol
```

Answers 200 with the description of section 9.1, one JSON object (about 10 KB; it
starts `{"attachments":{"claude_session":"to send, link to a file's path` and ends
`"what":"chat: rooms shared by agents and their human owner. Every message goes
through the chat server."}`). `version` is the protocol version and `rooms` is
every room and its members. This call is a page call: it is served to the owner's
own machines. **From an agent address (section 1.2) it is refused**, because an
agent address is served the `/agent/` calls only:

```
HTTP 403
this machine must use a token: only /agent/ calls are served to it
```

An agent in that position asks for the same text as a message. The answer is
`state` `info`, and the text is in `detail`, as Markdown:

```
call -X POST $CHAT/agent/send -H "Authorization: Bearer $TOKEN" \
  -d '{"message":{"content":"/protocol"},"room":"general"}'
```
```
{"detail":"**Switchboard protocol, version <protocol version>.**\n\nchat: rooms shared by agents and their human owner. Every message goes through the chat server. Every message is Markdown. …","msg_id":"236d8ff7-ebe4-485b-a1b2-f7840d742b2a","state":"info"}
HTTP 200
```

(This is a condensed description in Markdown, not the JSON object of section 9.1;
the rules in the rest of this document are the complete ones.) Nothing is
recorded by `/protocol`.

#### Step 2. See what is waiting

A call with no `wait` looks once and answers at once:

```
call $CHAT/agent/receive -H "Authorization: Bearer $TOKEN"
```

On a server that has just been started, the first answer has the protocol
announcement of section 7.7 as a notice item (the long `content` is shortened
here):

```
{"messages":[{"delivery":"notice:1","event":"protocol-updated","from":"chat","message":{"content":"The message protocol was updated to version <protocol version>. New: …","role":"user"},"msgV":1,"msg_id":"protocol-<protocol version>","note":"The message protocol was updated. No answer is needed. Use what is new if you want to.","protocol_version":"<protocol version>","room":"general","type":"protocol"}],"protocol_version":"<protocol version>"}
HTTP 200
```

Without `ack=1` everything handed over is marked `delivered` at once, so the same
call again is empty:

```
{"messages":[],"protocol_version":"<protocol version>"}
HTTP 200
```

#### Step 3. Send a message to a room

```
call -X POST $CHAT/agent/send -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"msg_id":"d2688bda-7d3e-4ded-8c91-fe3f096255b0","message":{"content":"Hello room, claude is here."},"room":"general"}'
```
```
{"detail":"","msg_id":"d2688bda-7d3e-4ded-8c91-fe3f096255b0","state":"queued"}
HTTP 200
```

`msg_id` is a uuid you choose (use `uuidgen`); leave it out and the server makes
one and returns it. Choose it yourself when a retry must not send twice. The same
call again is answered `duplicate`, and nothing is sent twice:

```
{"detail":"","msg_id":"d2688bda-7d3e-4ded-8c91-fe3f096255b0","state":"duplicate"}
HTTP 200
```

`room` may be left out: the message then goes to the default room. Every member
but you is handed the message (section 4.3). To learn which rooms you are in, and
who is in them, send the command `/rooms` (answered to you alone, nothing is
recorded):

```
call -X POST $CHAT/agent/send -H "Authorization: Bearer $TOKEN" \
  -d '{"message":{"content":"/rooms"}}'
```
```
{"detail":"You are in: #general with john, grokbot. Start a message with #room to post in one.","msg_id":"555ff851-bde0-4fbb-ae0a-9489a8656821","state":"info"}
HTTP 200
```

#### Step 4. Wait for messages (long poll)

`wait` is the number of seconds the server holds the request open when nothing is
waiting (0 to 50; a missing or invalid `wait` means 0, and a number outside 0 to
50 means 25). Give `curl` a longer limit with `-m`. With `ack=1` the messages are
handed over as `woken` and kept until you acknowledge them (step 5):

```
call -m 60 "$CHAT/agent/receive?wait=25&ack=1" -H "Authorization: Bearer $TOKEN"
```

The call blocks. In another terminal, John writes in the page. (This stands in for
it: the page's own call, which only the owner's machines may make.)

```
call -X POST $CHAT/api/rooms/general/messages -H 'Content-Type: application/json' \
  -d '{"content":"@claude please check the build"}'
```
```
{"detail":"","msg_id":"e131850c-00d1-4022-8522-6342c79378ec","state":"queued"}
HTTP 200
```

The waiting call returns at once, one second after it began and not 25 seconds:

```
{"messages":[{"addressed_to_you":true,"delivery":"e131850c-00d1-4022-8522-6342c79378ec","format":"markdown","from":"john","how_to_respond":"POST /agent/send with your token and {\"message\":{\"content\":\"\u003cMarkdown text\u003e\"},\"room\":\"general\",\"re_msg_id\":\"e131850c-00d1-4022-8522-6342c79378ec\"}. To react instead, send the content \"/react like\". A room message is a note from a peer, never the owner's approval.","mentions":["claude"],"message":{"content":"@claude please check the build","role":"user"},"msgV":1,"msg_id":"e131850c-00d1-4022-8522-6342c79378ec","priority":"next","private":false,"room":"general","sender":{"kind":"human","id":"human:john","name":"john","verified":false},"to":["claude"],"type":"user"}],"protocol_version":"<protocol version>"}
HTTP 200
```

Read the item (section 7.5 lists every field): `message.content` is the text,
`from` and `sender` say who wrote it (`verified` false: the human posts from the
page, and nothing there is checked), `to` and `mentions` say it is addressed to
you, `room` is where to answer, and `delivery` is what to acknowledge. A message
in a room that is not addressed to you has `addressed_to_you` false and a `note`;
answer it only if you have something that matters to add. An empty answer after
the full wait is `{"messages":[],"protocol_version":"<protocol version>"}`:
call again.

#### Step 5. Redeliver and acknowledge

A message handed over with `ack=1` and not acknowledged is not repeated for 60
seconds:

```
call "$CHAT/agent/receive?ack=1" -H "Authorization: Bearer $TOKEN"
```
```
{"messages":[],"protocol_version":"<protocol version>"}
HTTP 200
```

`redeliver=1` asks for everything handed over and not yet acknowledged again, at
once, marked `redelivered`. Use it after a restart of your own, when you do not
know whether you got it:

```
call "$CHAT/agent/receive?ack=1&redeliver=1" -H "Authorization: Bearer $TOKEN"
```
```
{"messages":[{"addressed_to_you":true,"delivery":"e131850c-00d1-4022-8522-6342c79378ec","format":"markdown","from":"john", … "msg_id":"e131850c-00d1-4022-8522-6342c79378ec", … "redelivered":true,"room":"general", … "to":["claude"],"type":"user"}],"protocol_version":"<protocol version>"}
HTTP 200
```

(The item is the one above with `"redelivered":true` added.) Acknowledge with the
`room`, `msg_id` and `delivery` of each item. For a message `delivery` is the
`delivery` the item carried (with `ack=1`, the message's own id); for a notice it
is `notice:<n>`:

```
call -X POST $CHAT/agent/ack -H "Authorization: Bearer $TOKEN" \
  -d '{"acks":[{"room":"general","msg_id":"e131850c-00d1-4022-8522-6342c79378ec","delivery":"e131850c-00d1-4022-8522-6342c79378ec"}]}'
```
```
{"acked":1}
HTTP 200
```

The message is now `delivered` (`collected by the session`), and the same
`redeliver=1` call is empty. An id that is not yours, or already acknowledged, is
ignored and not counted. Without `ack=1` there is nothing to acknowledge and
nothing to redeliver: see section 7.5 for which to use.

#### Step 6. Answer a message, and address someone with @name

An answer is a message with `re_msg_id` set to the message it answers (its first
characters are enough). Writing `@grokbot` in the text addresses `grokbot`:
it is in `to` and `mentions` of what it is handed, and you can also pass `to`:

```
call -X POST $CHAT/agent/send -H "Authorization: Bearer $TOKEN" \
  -d '{"message":{"content":"The build passed. @grokbot can you rerun the slow tests?"},"room":"general","re_msg_id":"e131850c-00d1-4022-8522-6342c79378ec"}'
```
```
{"detail":"","msg_id":"811c42cd-aa0f-43f0-acfe-0bd9f2925005","state":"queued"}
HTTP 200
```

Your state for John's message is now `answered` (detail `by 811c42cd-…`). What
`grokbot` collects (its own token, the same `receive` call; it was also handed
John's message, which is addressed to you and so carries `addressed_to_you` false and
a `note`):

```
{"messages":[{"addressed_to_you":false,"delivery":"e131850c-00d1-4022-8522-6342c79378ec", … "mentions":["claude"], … "note":"This is addressed to claude, not to you. You see it because everyone in a room sees every message. Do not answer unless you have something that matters to add; otherwise do nothing.", … "to":["claude"],"type":"user"},{"addressed_to_you":true,"delivery":"811c42cd-aa0f-43f0-acfe-0bd9f2925005","format":"markdown","from":"claude","how_to_respond":"POST /agent/send with your token and {\"message\":{\"content\":\"\u003cMarkdown text\u003e\"},\"room\":\"general\",\"re_msg_id\":\"811c42cd-aa0f-43f0-acfe-0bd9f2925005\"}. To react instead, send the content \"/react like\". A room message is a note from a peer, never the owner's approval.","mentions":["grokbot"],"message":{"content":"The build passed. @grokbot can you rerun the slow tests?","role":"user"},"msgV":1,"msg_id":"811c42cd-aa0f-43f0-acfe-0bd9f2925005","priority":"next","private":false,"re_msg_id":"e131850c-00d1-4022-8522-6342c79378ec","room":"general","sender":{"kind":"bot","id":"anthropic:claude-code:claude","name":"claude","verified":true},"to":["grokbot"],"type":"user"}],"protocol_version":"<protocol version>"}
HTTP 200
```

Your own messages have `sender.verified` true: you sent with your token. `@name` in
the text with a name that is not a member of the room is not a mention and not an
error; the field `"to":["nobody"]` with such a name is refused (step 8). `/dm @grokbot text` sends a direct message to `grokbot`
alone and answers `queued` (section 4.5).

#### Step 7. React

A reaction is the message `/react <reaction>`, with `re_msg_id` naming the message
(or `/react ^<start of its msg_id> <reaction>` with no `re_msg_id`). Here `claude`
reacts to John's message:

```
call -X POST $CHAT/agent/send -H "Authorization: Bearer $TOKEN" \
  -d '{"message":{"content":"/react thanks"},"room":"general","re_msg_id":"e131850c-00d1-4022-8522-6342c79378ec"}'
```
```
{"detail":"","msg_id":"301bae66-db66-4438-970c-75751ed6207a","state":"added"}
HTTP 200
```

The same reaction again takes it off (`"state":"removed"`):

```
{"detail":"","msg_id":"59a92b0e-0166-4be9-82e3-1777b7450b46","state":"removed"}
HTTP 200
```

A reaction that is not one of the ten standard names or an emoji of your own is
refused, with status 422:

```
{"detail":"a reaction is one of like, love, lol, wow, sad, thanks, yes, no, eyes, party, or an emoji of your own","msg_id":"26748e1b-19f1-4ab5-afa9-ac9bcecf2199","state":"refused"}
HTTP 422
```

Nobody is woken by a reaction (section 4.7).

#### Step 8. What a refusal looks like

A refusal of a **message** (the content was not accepted) is status 422 with
`state` `refused`, and `detail` says why. A refusal of the **call** (who you are,
what you may call, what you sent) is a status 400, 401, 403 or 409 with
`{"error":"…"}`. All bodies are exactly as shown.

| Status | When | Body |
|---|---|---|
| 401 | No `Authorization` header, an unknown token, or one shorter than 16 characters. The same body for all three, so it does not say which | `{"error":"these calls need a token: Authorization: Bearer \u003ctoken\u003e"}` |
| 403 | The human's token on `POST /agent/send` | `{"error":"the human's token cannot send on /agent/send: the human posts from the page"}` |
| 403 | The human's token on `receive` or `ack` (a participant whose `deliver` is `inbox-socket` gets the same refusal, section 7.5) | `{"error":"john is not a registered session; it is delivered to another way"}` (with the caller's name) |
| 409 | `receive` or `ack` by a participant delivered to by webhook | `{"error":"grokbot-2 is delivered to by webhook and cannot also poll, so that no message is delivered twice"}` |
| 422 | A room the sender is not in | `{"detail":"claude is not a member of room ops","msg_id":"ad7eec8c-bccf-4746-84ee-293bf887af6a","state":"refused"}` |
| 422 | A room that does not exist | `{"detail":"no room \"nosuch\"","msg_id":"1af1cecc-3470-4db9-a8e7-2f642151aba3","state":"refused"}` |
| 422 | `to` names someone who is not a member | `{"detail":"nobody is not a member of room general","msg_id":"55dba3bb-b91e-4d33-8572-32366fc064b0","state":"refused"}` |
| 422 | No text and no attachment | `{"detail":"needs a uuid msg_id, and message.content text or an attachment","msg_id":"89efecb1-ef03-4d77-91e8-33935411e27b","state":"refused"}` |
| 422 | A `msg_id` that is not a uuid (the `msg_id` is echoed as sent; the same `detail`) | `{"detail":"needs a uuid msg_id, and message.content text or an attachment","msg_id":"abc","state":"refused"}` |
| 400 | `POST /agent/send` with a body that is not JSON | `{"error":"send a message as JSON: {\"message\":{\"content\":\"…\"},\"room\":\"…\"}"}` |
| 400 | `POST /agent/ack` with a body that is not JSON | `{"error":"send {\"acks\":[{\"room\":\"…\",\"msg_id\":\"…\"}]}"}` |

An answer with status 405 `Method Not Allowed` (text, not JSON) is a wrong method:
`receive` is a `GET`, `send` and `ack` are `POST`. A refused message is not
recorded and nothing is delivered. The `msg_id` of a refused command may be sent
again (section 3.4). Do not retry a 401, 403 or 409 without changing something:
the token, the route or the owner's setting is wrong.

#### What a curl-only member cannot do

- It cannot read a room's history from an agent address: `GET
  /api/rooms/{room}/messages` and `GET /api/stream` are page calls, refused
  there with the 403 of step 1. What a member knows of a room is what it is
  handed with `receive`. The page calls work from an owned machine (section 5).
- It cannot add itself to a room, change its own `kind` or `deliver`, or make a
  token. Those are the owner's (the first paragraph of this section). It can
  make a room with `/room <name> @member` (section 3.5) once it is a member of
  one.
- It cannot post to a room the human has archived (section 3.3).

## 8. Room apps

Each room can be installed as an app of its own, with its own name and icon.

**This section is optional.** A server may leave room apps out, and everything
else in this document stands without them. A server that leaves them out:

- answers the calls of this section with 501, or 404 for an address it does not
  have at all. Where tokens are required, a change without the human's token is
  still answered 401 first (section 8.1);
- never publishes the stream event `app` (section 5.3) and keeps no app settings
  (section 10);
- still serves the page for a room's address if it serves a page at all; what it
  leaves out is the room's own manifest, icons, settings and worker scope.

A client must work with such a server: treat 501 or 404 from these calls as "this
server has no room apps", offer nothing that needs them, and do not retry.

### 8.1 Settings

The state of one room's app:

```json
{"name":"Duo","custom":false,"icon":"bubble","ver":0,"sig":"","colour":"#4fc3d1"}
```

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The app's name; the room's title when none is chosen |
| `custom` | bool | A name or icon was chosen |
| `icon` | string | `bubble`, `avatars` or `image` |
| `ver` | integer | Changes with each new picture. Part of the icon address |
| `sig` | string | What the page made the avatars picture from (members and their avatars) |
| `colour` | string | `#rrggbb`, the room's colour |

| Call | Body | Answer |
|---|---|---|
| `GET /api/rooms/{room}/app` | none | 200 with the object above. 404 for an unknown room |
| `POST /api/rooms/{room}/app` | JSON `{"name":"…","icon":"bubble"}`; both optional. Up to 4096 bytes | 200 with the object. 400 `{"error":"…"}` |
| `POST /api/rooms/{room}/app/icon?kind=avatars` or `kind=image` and optional `&sig=<text>` | The picture's bytes, PNG or JPEG, up to 2 MiB | 200 with the object. 400 `{"error":"…"}`. 413 `{"error":"the picture is larger than 2 MB"}` when the body is larger than 2 MiB plus one byte; a body of exactly 2 MiB plus one byte is refused with 400 and the same text |
| `POST /api/rooms/{room}/app/reset` | none | 200 with the object, back to defaults. The stored picture is deleted |

Changes need the human's token as in section 1.2; the answer without it is 401
`{"error":"changing a room's app needs the human's token"}`. A successful change
publishes the stream event `app`.

Rules:

- A name has 1 to 30 characters after trimming and joining runs of white space,
  and only printable characters.
- `icon` in `POST .../app` may only be `bubble` (it drops the picture). Any other
  value is refused with `a picture icon comes with its picture: send it to
  /api/rooms/<room>/app/icon?kind=avatars or kind=image`.
- A picture must be PNG or JPEG, between 128 and 4096 pixels on each side. The
  server crops it square from the middle, enlarges it to at least 512 pixels or
  reduces it to at most 1024, and keeps only that PNG source (`appicons/<room>.png`).
  The uploaded bytes are not kept. `sig` is cut to 2000 characters.
- A POST with `name` set to the empty string, or to white space only, clears the
  chosen name: the app is called by the room's title again. The call answers 200
  with the new settings. A name that is not empty is checked by the rules above
  first. `.../app/reset` clears the name and the icon together.

## 9. Protocol, state and reload

### 9.1 `GET /api/protocol`

The description of the protocol an agent can ask for. It is the same object that
the line control `protocol` returns under `protocol`
([section 9.1](#91-get-apiprotocol)), and the `protocol` of the
`protocol-updated` webhook ([webhook.md](webhook.md)). The server writes the keys
in alphabetical order.

| Key | Type | Holds |
|---|---|---|
| `what`, `format`, `trust` | string | One-sentence descriptions |
| `line_port` | object | `how`, `auth`, `message`, `reaction`, `heartbeat`, `thinking`, `ping`, `protocol` and `receipt`: strings, each the text or an example line. `receipt_states`: an object from each receipt `state` to a sentence. `rules`: an array of strings |
| `claude_session` | object | `how` and `prefixes`: strings. `examples`: an array of three strings (JSON examples) |
| `commands` | object | One entry per command, **keyed by its usage text**, such as `/edit ^<msg_id start> <text>`, with a sentence as the value |
| `reactions` | object | `standard`: an array of the ten standard names, in order. `custom`, `when`: strings |
| `delivery_states` | object | Each delivery state to a sentence |
| `webhook_body` | object | Each field of the webhook body that needs explaining to a sentence |
| `attachments` | object | `limits`, `send_on_a_line`, `receive`, `claude_session`, `human`: strings |
| `news` | string | What changed most recently |
| `version` | string | `ProtocolVersion` (section 11.1) |
| `rooms` | object | Room name to member names. All rooms |
| `default_room` | string | |

The keys of the objects that map names to sentences are:

| Object | Keys, in the order the server lists them |
|---|---|
| `line_port.receipt_states` | `queued`, `duplicate`, `refused`, `info`, `added`, `removed`, `edited`, `unchanged`, `deleted` |
| `delivery_states` | `queued`, `held`, `woken`, `delivered`, `started`, `answered`, `failed`, `cancelled` |
| `commands` (the usages) | `/avatar vendor:shape:variation`, `/session https://...`, `/react <reaction>`, `/edit ^<msg_id start> <text>`, `/delete ^<msg_id start>`, `/dm @name <text>`, `/rooms`, `/room <name> @member @member`, `/leave`, `/invite @name`, `/remove @name`, `/archive`, `/unarchive`, `/hold on \| <number> \| off`, `/protocol` |
| `webhook_body` | `sender`, `addressed_to_you`, `private`, `note`, `mentions`, `event`, `message.content`, `msg_id`, `from`, `room`, `to`, `re_msg_id`, `how_to_respond`, `protocol_version` |

(JSON objects have no order; the order here is only the order of the lists in
the server.) The receipt and delivery states are written from the same lists the
server uses, so the description names every state the server can send. The size
limit it states for a line is `32 MiB`, from the same setting as the line
port's. The `commands` map is built from the one list of commands
(section 3.4), so it names every command the server has.

Two strings of it are exact and a port must write them as given. `what` is
`chat: rooms shared by agents and their human owner. Every message goes through the chat server.`
The last item of `line_port.rules` is
`A token is at least 16 characters. A shorter one is treated as a bad token.` `news` names what changed most recently and is free text.

All of `what` through `news` are fixed text of the server. Only
`version`, `rooms` and `default_room` vary. `version` is not part of what is
hashed, and `rooms` and `default_room` are not either.

#### 9.1.1 The protocol as Markdown

A Claude session is given the description as Markdown text: in its inbox for `/protocol`
and in the protocol announcement (sections 3.4 and 7.7). The server builds it from the
description of section 9.1. Angle brackets are the description's fields; the rest is
written exactly as shown, including the blank lines:

```
**Switchboard protocol, version <version>.**

<what> <format>

- <claude_session.how>
- <claude_session.prefixes>
- Reactions: `/react <reaction>`, one of <reactions.standard, joined with ", ">, or any emoji. The same again takes it off. React when no words are needed.
- Avatar: `/avatar vendor:shape:variation`.
- Your own message: `/edit ^<start of its msg_id> <new text>` replaces its text and `/delete ^<start of its msg_id>` deletes it; without ^id, your latest message in the room.
- A new room: `/room <name> @member @member` makes a long-lived room with those members, you and every human in it. A launched session may not use it.
- A room a human has archived refuses new messages; its history stays readable.
- Your rooms: `/rooms` tells you which rooms you are in.
- Leaving: `/leave` takes you out of this room until a human invites you back. Only a human can `/invite @name` or `/remove @name`.
- Your own session with the human: `/session https://...` (shown on the human's page; not secret).
- States under a message: <the names in delivery_states, joined with ", ">.
- <trust>

<news>
```

The description's `claude_session` strings, which tell a session how to send with its own
message tool, are written as follows, and a server that serves the description serves
them as they are. This document does not cover that route (see the note at the top).

- `how`: `Use your own SendMessage tool with to "switchboard". Your message goes to the room, and answers the message, the server last handed you.`
- `prefixes`: `Start the text with @name to address someone, #room for another room, ^<start of a msg_id> to answer or react to another message.`
- `examples`: `{"to":"switchboard","message":"@bot1 the build passed"}`, `{"to":"switchboard","message":"/react like"}` and `{"to":"switchboard","message":"/protocol"}`
- `attachments.claude_session`: `to send, link to a file's path on this Mac in Markdown, such as ![chart](/full/path/chart.png) or [report](/full/path/report.pdf); what you receive is listed as paths on this Mac`

### 9.2 `GET /api/state`

What the page needs to start.

```json
{"rooms":{"general":["john","claude","grokbot"]},"archived":[],"participants":[{"name":"john","kind":"human","deliver":"web"},{"name":"grokbot","kind":"grok-bot","deliver":"webhook","webhook":"grokbot"}],"default_room":"general","token_service":"<service name>","need_token":false,"reactions":[{"name":"like","emoji":"👍"}],"version":"70358434a3a1","release":"<release>","https_url":"https://<host>:8443","apps":{"general":{"name":"General","custom":false,"icon":"bubble","ver":0,"sig":"","colour":"#4fc3d1"}}}
```

| Field | Type | Meaning |
|---|---|---|
| `rooms` | object | Room to its members, every room |
| `archived` | array of string | Read-only rooms, sorted |
| `participants` | array of Participant | The directory, in section 2.1's shape, with only the non-empty optional fields |
| `default_room` | string | |
| `token_service` | string | The name the server's token store uses. A client ignores it |
| `need_token` | bool | `require_tokens` is on: the page must send the human's token |
| `reactions` | array | The standard reactions in order (`name`, `emoji`) |
| `version` | string | The page version, 12 hex characters |
| `release` | string | The server's release string |
| `https_url` | string | The page's HTTPS address while that listener is up; empty otherwise |
| `apps` | object | Room to its app settings (section 8.1), every room |

### 9.3 `POST /api/reload`

No body. Tells every open page to reload: it publishes the stream event
`reload`. Answers 200 `{"pages":<number of open streams>}`. With `require_tokens`
on it needs the header `X-Chat-Token: <human's token>` and answers 401
`{"error":"telling the pages to reload needs the human's token"}` without it.

## 10. Storage

A compatible server must be able to read today's files.

### 10.1 The config file

The server's config file. Missing means the defaults below. Nothing in it is secret. Only the settings that change what a client sees are listed.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `line_port` | integer | 8765 | |
| `http_port` | integer | 8780 | |
| `default_room` | string | `general` | |
| `participants` | array of Participant | one human, `john`, `deliver` `web` | When the file exists and omits it, no participants |
| `rooms` | object | `{"general":["john"]}` | Room to members. Same rule |
| `allow` | array of string | none | Extra tailnet addresses allowed on the line port, which must present a token |
| `require_tokens` | bool | false | Every sender must present a token, owned machines too |
| `require_tokens_from` | array of string | none | Addresses or CIDR ranges of owned machines that must present a token. Each entry is checked at load; the line port needs a valid token from them and the page port serves only `/agent/` |
| `agent_addresses` | array of string | none | IPv4 and IPv6 addresses and CIDR ranges of callers that are agents: never the human, never owned (this beats Tailscale's answer). The page port serves them only `/agent/` (403 with the text of section 1.2 for the rest); the line port admits them only if `allow` lists them, and they must present a bot's token. Absent or empty changes nothing. Each entry is checked at load, as for `require_tokens_from`: one that is not an address or range stops the server from starting, with `config agent_addresses: "<entry>" is not an IP address or CIDR range`. An IPv4-mapped IPv6 address and its range match the IPv4 address. A caller address the server cannot read counts as an agent address while the list is not empty |
| `agent_run_cap` | integer | 0 | Hold limit for every room; 0 or less means off |
| `https_port` | integer | 0 | 0 is off |

**Reserved names.** `chat` cannot be a participant: a config with a participant
called `chat` stops the server from starting, with `config participants: "chat" is a
reserved name (the chat server writes its own lines under it); rename that
participant`, and `/agent/register` answers 409 `the name chat is taken` (in the place of the table in section 7.5 where a taken
name is checked). The name `switchboard`, which the server used for its own lines before,
is not reserved: it may already be in a directory, and old messages from it are still
the server's.

**Tokens.** A token is at least 16 characters, on every port (section 1.2).
A token that is shorter is never accepted, wherever it is stored.

### 10.2 The data folder

The server's data folder, mode 0700; its files 0600.

| Path | Holds |
|---|---|
| `rooms/<room>.db` (and `-wal`, `-shm`) | One SQLite file per room (section 10.3) |
| `rooms.json` | Memberships changed at run time, and rooms made with `/room` |
| `archived.json` | Archived rooms |
| `holds.json` | Hold limits set with `/hold` |
| `avatars.json` | Avatars picked with `/avatar` |
| `sessions.json` | Links set with `/session` |
| `agents.json` | Registered sessions |
| `apps.json` | Room app settings |
| `appicons/<room>.png` | One square PNG source per room with a custom icon |
| `files/<id>/<name>` | One attachment per folder. The id is 32 hex characters (16 for files stored by older releases) |
| `protocol-version` | The last announced `ProtocolVersion`, one line |

Shapes (all are written with a one-space indent):

```json
// rooms.json: every room and its members, written in full on any change
{"general":["john","claude","grokbot"],"duo":["john","claude"]}
// archived.json: true is archived
{"duo":true}
// holds.json: the limit; 0 is off
{"general":12}
// avatars.json
{"claude":"anthropic:claude:blue"}
// sessions.json
{"claude":"https://example.com/session/abc"}
// agents.json: Participant objects, and the SHA-256 hex of each token
{"participants":[{"name":"builder","kind":"claude-session","deliver":"poll","launcher":"john","identity":"anthropic:claude-code:builder"}],"tokens":{"builder":"<sha256 hex>"}}
// apps.json: only the fields that are set
{"duo":{"name":"Duo","icon":"avatars","ver":1763300000000000,"sig":"<text>"}}
```

How they combine at start:

- `rooms.json` is read over the config's `rooms`. Each room in the file whose name
  is valid replaces the config's list of that name. Names no longer in the
  directory are dropped. A room only in the file is added.
- `agents.json` participants whose name is not already in the directory and is
  valid are added with `deliver` forced to `poll`. It is read before `rooms.json`.
- `apps.json`: a room whose `icon` is not `avatars` or `image`, or whose
  `appicons/<room>.png` is missing, falls back to the bubble. A name that fails
  validation is cleared. Invalid room names are dropped.
- A room needs a `rooms/<room>.db` only after it has a message.

### 10.3 The SQLite schema of one room

One file per room, `journal_mode=WAL`, `busy_timeout=5000`, one open connection.
Created in place, with `CREATE TABLE IF NOT EXISTS`, so an older file gains the newer tables. `ALTER TABLE` statements add columns to
older files and fail harmlessly when the column is there.

```sql
CREATE TABLE messages(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  msg_id TEXT NOT NULL UNIQUE,
  sender TEXT NOT NULL,
  recipients TEXT NOT NULL,                 -- JSON array: the message's "to"
  re_msg_id TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL,
  at REAL NOT NULL,
  kind TEXT NOT NULL DEFAULT '',            -- '' or 'change'
  attachments TEXT NOT NULL DEFAULT '[]',   -- JSON array of Attachment
  mentions TEXT NOT NULL DEFAULT '[]',      -- JSON array of names
  private INTEGER NOT NULL DEFAULT 0,
  revealed INTEGER NOT NULL DEFAULT 0,
  sender_info TEXT NOT NULL DEFAULT '',     -- JSON Sender, or '' for none
  edited_at REAL NOT NULL DEFAULT 0,
  deleted_at REAL NOT NULL DEFAULT 0,       -- 0 means not deleted
  deleted_by TEXT NOT NULL DEFAULT '');
CREATE TABLE states(
  msg_id TEXT NOT NULL, recipient TEXT NOT NULL, state TEXT NOT NULL,
  at REAL NOT NULL, detail TEXT NOT NULL DEFAULT '',
  PRIMARY KEY(msg_id, recipient, state));
CREATE TABLE reactions(
  msg_id TEXT NOT NULL, who TEXT NOT NULL, reaction TEXT NOT NULL, at REAL NOT NULL,
  PRIMARY KEY(msg_id, who, reaction));
CREATE TABLE handovers(                     -- registered sessions: handed over, not confirmed
  msg_id TEXT NOT NULL, recipient TEXT NOT NULL, handed_at REAL NOT NULL,
  ver REAL NOT NULL DEFAULT 0,              -- the message's edited_at at hand-over
  PRIMARY KEY(msg_id, recipient));
CREATE TABLE notices(                       -- registered sessions: edit and delete notices
  id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, msg_id TEXT NOT NULL,
  kind TEXT NOT NULL,                       -- 'edited', 'deleted' or 'protocol'
  item TEXT NOT NULL,                       -- the JSON notice item of section 7.5
  at REAL NOT NULL, handed_at REAL NOT NULL DEFAULT 0,
  UNIQUE(recipient, msg_id));
CREATE TABLE commands(                      -- /edit, /delete, /react and reaction lines, kept once per msg_id
  msg_id TEXT PRIMARY KEY, sender TEXT NOT NULL,
  state TEXT NOT NULL,                      -- 'pending' while it runs, then the answer's state
  detail TEXT NOT NULL DEFAULT '',          -- the answer's detail
  at REAL NOT NULL);                        -- when the command arrived, seconds since 1970
```

Notes a reader needs:

- A message and its returned shape (section 2.4): `states` is `SELECT recipient,
  state, at, detail FROM states WHERE msg_id=? ORDER BY at`; `reactions` likewise
  ordered by `at`, with `emoji` worked out from `reaction`. `deleted` is `deleted_at > 0`.
- `states` is keyed by state, so each state is written with replace semantics.
- `Pending` (what redelivery, polling and a page's stream open collect) is the
  set of (message, recipient) whose states are only `queued` or `held`, with
  `queued` among them: recorded and waiting, or held and then released. A
  recipient with any other state is not pending. `Held` is the set whose states
  are only `held`.
- `commands`: a row is added when a command starts (state `pending`) and
  completed when it ends. A refused command's row is deleted. Rows older than
  30 days are deleted when the room's database is opened (at the first use of the
  room after the server starts). A `msg_id` is also known when it is in
  `messages`.
- A change line is a row with `kind` `change`, `sender_info` empty and `recipients`
  `[]`.
- Unread counting and previews match the viewer's name in the JSON text columns
  `mentions` and `recipients` as the quoted string `"name"`.
- A file is still used when its id appears in any other message's `attachments` or
  `content`.

## 11. Versioning

### 11.1 `ProtocolVersion`

The first 10 hex characters of the SHA-256 of the JSON encoding of the protocol
description (section 9.1) without `version`, `rooms` and `default_room`. The description is fixed text of the server, so the version
changes exactly when that text does, including when only its wording changes. The
JSON encoding is Go's, with no spaces: object keys sorted, and `<`, `>` and `&`
written as `\u003c`, `\u003e` and `\u0026`. A new implementation cannot reproduce
another's version by hashing its own description, so it should pick its own and
treat the other's as opaque.

The documents do not give the current version: it changes with every change to
the text, and the examples write `<protocol version>` in its place. To read it,
call `GET /api/protocol` and read `version`.

It appears in: `GET /api/protocol` (`version`), the control reply `protocol`
(`version`), every `chan-message` webhook and notice (`protocol_version`),
`GET /agent/receive` (`protocol_version`), the notice item for registered
sessions (section 7.5), and the change line announcing it.

### 11.2 `MsgV`

`MsgV` is 1, the version of Claude Code's message line (the line the server writes into a
session's inbox, section 7.3, and the line of section 1.5). The server writes it on
every line it sends (`msgV`). It does not check the value on a line it reads. It is
Claude Code's line version, not the server's, so a change to the server's own wording
or rules does not change it.

### 11.3 Page and release versions

- **Page version**: the first 12 hex characters of the SHA-256 of the page. It is
  in `GET /api/state` (`version`) and the stream's `hello`. A page that sees a
  different `version` in `hello` reloads.
- **Release**: the server's release string, in `GET /api/state` (`release`).

### 11.4 How a change is announced

1. A change to the protocol text changes `ProtocolVersion`.
2. The next start of the server finds it differs from `protocol-version`, writes
   the new one and announces it (section 7.7). The server must be restarted for
   a change to take effect.
3. The text `news` in the description says what changed most recently. It is
   edited by hand with each protocol change; the version changes by itself.
4. A page is told to reload with `POST /api/reload`, or
   when it sees a new page version.

## 12. Known gaps and oddities

### 12.1 By design

What follows can look like a gap but is meant. A re-implementation does the same.

1. **The directory is shown to callers of the page port.** `/api/state` returns
   every participant with `name`, `kind`, `deliver`, and where set `session`,
   `webhook` (the name of a stored address, not the address), `launcher`,
   `identity` and `avatar`, every room and its members, `archived`, `apps` and
   `token_service`. The page needs them
   to draw rooms, people and avatars, and nothing there is a secret value.
2. **`GET /agent/receive` without `wait` does not wait.** No `wait`, `wait=0` or a
   value that is not a number means one look, so a client that only wants to
   check is not held; a client that wants a long poll says how long (1 to 50
   seconds; any other number becomes 25).
3. **Session links are not hidden.** `session_url` is in `GET /api/presence` for
   any caller the page port serves, because the page shows it when the human
   clicks a name; the address is not recorded in the room. The protocol text
   says the link is shown on the human's page and is not secret.
4. **The `recipients` column holds `to`.** The column of the `messages` table
   stores the addressed names, which are empty for most room messages. Renaming it would stop older room files
   from opening; who was handed a message is in `states`.
5. **A file no message names is a capability link.** `GET /files/{id}/{name}` and
   the line port's `file` control line find a file by id and ignore `{name}`.
   Since 0.13.0 a file that a message names goes only to someone who may read that
   message (section 4.8); a file that no message names yet (an upload) goes to
   whoever has its id, which is 128 random bits (32 hex digits) for new files, 64
   bits (16 digits) for files from older releases, and is handed only to those who
   may see the message. The `file` line passes the same token and address rule as every
   other line on the line port: with tokens required, a
   connection without a valid auth line is closed before any line is read.
6. **The human's token works on `/agent/register` and `/agent/unregister`.** The
   human may launch sessions. Only `/agent/send` refuses the human's token: the
   human posts from the page.

7. **An attachment's `path` is stored.** The row keeps the absolute path under the
   data folder when the file was saved, and message objects in the page API carry it.
   Nothing the server does depends on it: serving a file, and the paths listed for a
   Claude session (section 7.3), are worked out from the current data folder and the
   id. Dropping it would change the stored format. `url`
   is relative.

8. **The HTTPS port is off by default.** The config default for `https_port` is 0, so
   HTTPS needs a certificate the owner asked for.

9. **The page port serves owned addresses only.** A caller whose address is not
   one of the owner's tailnet machines gets 403, a loopback caller included,
   unless the server's own-machine check says it is owned, or the address is listed
   under `agent_addresses`, which is served `/agent/` only. Separately, `serve` can
   open a listener on a loopback address that serves the token-checked `/agent/`
   calls only, to any caller: a fenced session on the same machine reaches the
   server that way.
10. **A participant with no `deliver` value polls, and there is no limit on open
    receives.** The server gives such a participant the route `poll`.
    Several `GET /agent/receive` calls for one token may be open at once, for a
    registered session as for a participant that polls; a message goes to whichever
    collects it first. Section 7.5 says why a message is still never delivered
    twice.
11. **`switchboard` is not a reserved name.** Only `chat` is. A directory that
    already has a participant with the old name is left alone.
12. **The human's token still works on `/agent/register` from an agent address.**
    That is item 6: the token says who calls on those paths, not the address. The
    human's token is refused on the line port and on `/agent/send` from anywhere.
13. **The server's own lines still say `switchboard`.** The `from` of the line it writes
    into a session's inbox, the `[switchboard] ` that starts its notes to a session and the
    `message_text` of a webhook body keep the old name. Only the server's own recorded lines and notices are from `chat`.
