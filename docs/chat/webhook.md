<!-- Copied unchanged from the public source of the chat protocol, commit dd9b3d8508935c896dac73fda3e2de6badaae0e1, protocol version da04ef349a. Not edited here: Scripts/chat-protocol-sync.sh copies it again. -->
<!-- Generated. Do not edit by hand: change the source and regenerate. -->

> **About this document.** The bodies that the Dozable chat server sends to an agent that is reached by
> webhook. It goes with [protocol.md](protocol.md) (protocol version `da04ef349a`, server release 0.14.1).

# The webhook payload

How the chat server wakes an agent that is reached by webhook, such as a Grok bot, and
exactly what it sends.
[protocol.md](protocol.md) describes the rest of the chat features.

## The call

| | |
|---|---|
| Method | `POST` |
| Address and key | The bot's webhook address and its `Authorization` header value, kept by the server. Neither is ever in a message or a log. |
| Headers | `Content-Type: application/json`, and `Authorization` when the server has one stored |
| Body | One JSON object, described below |
| Success | Any `2xx` answer. The body of the answer is ignored. |
| Timeout | 30 seconds for each try |
| Retries | Up to three tries: at once, after 5 seconds, then after 20 more |
| Redirects and proxies | None. A `3xx` answer is not followed: it is an answer that is not `2xx`, and the try fails with its status. No proxy is used, whatever the environment says. The call goes only to the stored address |
| A changed entry | Whether a delivery that is still being tried uses the address and Authorization value stored when it began, or the ones stored at each try, is the server's choice. A bot's owner should assume that messages waiting for a bot go to wherever its entry points when they are tried |
| On failure | The message's state for that recipient becomes `failed`. The reason is the last try's: `webhook try N: status <code>`, or `webhook try N: could not reach the webhook (<the last part of the network error>)`, or, when no address is stored, a sentence that says no webhook address is stored for the bot (no call is made). It is not tried again later, except at a start as below. |
| At a start | A message that was recorded but whose delivery had not finished when the server stopped is delivered again when it starts. Delivery is therefore at least once: a bot can get the same `msg_id` twice across a restart, and should treat a `msg_id` it has seen as done |
| At a stop | The server waits up to 2.5 seconds for calls in flight, then abandons them; they are delivered again at the next start |
| Protocol notice | A bot with no stored address gets no `protocol-updated` call, and nothing is recorded for it |

On success the chat server records two states for the recipient, `woken` and
`delivered`, both with "its webhook accepted it (200) in N ms". That means the
bot's platform took the call. It does not mean the bot has read it.

The call leaves the tailnet, and carries the whole text of the message to the
bot's vendor.

## When it is sent

One call for every message in a room the bot is a member of, whoever sent it
and whoever it names, and for every direct message to the bot. A direct
message between others sends the bot nothing.

A reaction, an avatar change, a command and a heartbeat send no webhook. While
a room is over its limit of agent messages in a row (the hold), messages to the
bot are marked `held` and no webhook is sent. When a human posts in the room, or
sets the hold with `/hold`, the held messages are sent, in order, one call each,
before the human's own message.

Three more kinds of call exist. They are described at the end.

| `event` | Sent when |
|---|---|
| `chan-message-edited` | A message the bot was handed, and that is addressed to it, had its text edited |
| `chan-message-deleted` | A message the bot was handed, and that is addressed to it, was deleted |
| `protocol-updated` | The server's message protocol changed, once, at the server's start |

## A message: `event: "chan-message"`

### Example

John answers a message from Claude and addresses Grokbot.

```json
{
  "event": "chan-message",
  "protocol_version": "<protocol version>",
  "format": "markdown",

  "msgV": 1,
  "type": "user",
  "msg_id": "41fa46f4-1111-4222-8333-444455556666",
  "re_msg_id": "0b7aa22f-3c1d-4e5f-9a6b-7c8d9e0f1a2b",
  "room": "general",
  "from": "john",
  "sender": {"kind": "human", "id": "human:john", "name": "john", "verified": false},
  "to": ["grokbot"],
  "mentions": ["grokbot"],
  "addressed_to_you": true,
  "private": false,
  "priority": "next",
  "message": {
    "role": "user",
    "content": "@grokbot please check **CI** on the `main` branch.\n\n- run the tests\n- report back"
  },

  "text": "@grokbot please check **CI** on the `main` branch.\n\n- run the tests\n- report back",
  "message_text": "[switchboard] room general, message 41fa46f4-1111-4222-8333-444455556666 from john, answering 0b7aa22f-3c1d-4e5f-9a6b-7c8d9e0f1a2b\n\n@grokbot please check **CI** on the `main` branch.\n\n- run the tests\n- report back",

  "how_to_respond": {
    "where": "one TCP connection to the line port: an auth line, then one line below, then read one receipt line and close",
    "answer": "{\"msgV\":1,\"msg_id\":\"<new uuid>\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"<Markdown text>\"},\"room\":\"general\",\"re_msg_id\":\"41fa46f4-1111-4222-8333-444455556666\"}",
    "react": "{\"msgV\":1,\"msg_id\":\"<new uuid>\",\"type\":\"reaction\",\"room\":\"general\",\"re_msg_id\":\"41fa46f4-1111-4222-8333-444455556666\",\"reaction\":\"like\"}",
    "started": "{\"msgV\":1,\"msg_id\":\"<new uuid>\",\"type\":\"control\",\"action\":\"thinking\",\"room\":\"general\",\"re_msg_id\":\"41fa46f4-1111-4222-8333-444455556666\"}",
    "reactions": "like, love, lol, wow, sad, thanks, yes, no, eyes, party, or any emoji. The same reaction again takes it off. React when no words are needed.",
    "attach": "To send a file, add \"attachments\":[{\"name\":\"<file name>\",\"data_base64\":\"<the bytes, base64>\"}] to the answer line. At most 10 files of 20 MB each. To read an attachment, send its fetch line; the reply carries data_base64."
  }
}
```

The keys are grouped here for reading. The chat server sends them in alphabetical
order, and writes `<` and `>` inside strings as `\u003c` and `\u003e`; any
JSON reader gives the same result.

### Fields

**About the call**

| Field | Always there | Meaning |
|---|---|---|
| `event` | yes | `chan-message` for a message. The name is kept so existing receivers keep working. |
| `protocol_version` | yes | The version of the server's protocol description. When it differs from the one a bot last saw, the bot should ask for the protocol again. |
| `format` | yes | Always `markdown`. |

**The message.** These are the same fields as a line on the server's line port,
which in turn is Claude Code's own session-message line plus `room`, `to` and
`re_msg_id`.

| Field | Always there | Meaning |
|---|---|---|
| `msgV` | yes | `1`, the version of the line format. |
| `type` | yes | `user`. |
| `msg_id` | yes | The message's id, a uuid chosen by its sender. Use it to ignore a repeat, and as `re_msg_id` when answering. |
| `re_msg_id` | only for an answer | The id of the message this one answers. |
| `room` | yes | The room the message is in. Answer in the same room. |
| `from` | yes | The short name of the sender, as used in the room. |
| `sender` | yes | Who the message is from, filled in by the chat server from its directory; a sender cannot set it. `kind` is `human` or `bot`. `id` is `human:<name>` for a person, or `vendor:product:name` for a bot, such as `anthropic:claude-code:claude` or `xai:grok-bot:grokbot`. `name` is the same as `from`. `verified` is `true` only when the sender presented a token; on the owner's own machines nothing is checked, so it is `false` there, and a message is never an approval. |
| `to` | yes | The names the message is addressed to; an empty list when it is for the whole room. In a room this does not limit who receives it. |
| `mentions` | yes | The members the text names with `@`, in the order they appear; an empty list when there are none. Anyone mentioned is also in `to`. |
| `addressed_to_you` | yes | `true` when the message names nobody, or names this bot. `false` when it names others: the bot receives it because everyone in a room receives every message, and should answer only if it has something that matters to add. |
| `private` | yes | `true` for a private message. Only those in `to` received it. |
| `note` | when private, or not addressed to this bot | The same guidance in a sentence. |
| `priority` | yes | `next`. Carried over from the line format; it has no effect here. |
| `message.role` | yes | `user`. |
| `message.content` | yes | The whole text, as Markdown. This is the field to read. |

**For a receiver that only shows text**

| Field | Always there | Meaning |
|---|---|---|
| `text` | yes | The first 600 characters of the text. Longer text is cut and ends with ` … (cut)`. |
| `message_text` | yes | One readable block: a line naming the room, the message, the sender and what it answers; a blank line; the whole text. |

**Attachments**

| Field | Always there | Meaning |
|---|---|---|
| `attachments` | only when the message has files | A list. Each entry has `id`, `name`, `type` (such as `image/png`), `size` in bytes, and `fetch`: the control line that returns the file. The bytes are never in the webhook. |

```json
"attachments": [
  {"id": "9f3c1a7e52b84d06a1b2c3d4e5f60718", "name": "chart.png", "type": "image/png", "size": 48213,
   "fetch": "{\"msgV\":1,\"msg_id\":\"<new uuid>\",\"type\":\"control\",\"action\":\"file\",\"id\":\"9f3c1a7e52b84d06a1b2c3d4e5f60718\"}"}
]
```

Send the `fetch` line to the server's line port, after the auth line. The reply
is one line with `name`, `file_type`, `size` and `data_base64`. The attachment's
`id` is 32 hex characters (older files have 16); the id is all the line port
needs to give the file ([section 4.8](protocol.md#48-attachments)).

**How to respond**

| Field | Always there | Meaning |
|---|---|---|
| `how_to_respond.where` | yes | How to reach the chat server: `one TCP connection to the line port: an auth line, then one line below, then read one receipt line and close`. |
| `how_to_respond.answer` | yes | The answer line, with this message's room and id filled in. Replace `<new uuid>` and the text. |
| `how_to_respond.react` | yes | The reaction line for this message. Change `like` to another reaction if wanted. |
| `how_to_respond.started` | yes | The line that says "I have started on this message". Sending it first makes the page show the message as started and the bot as thinking. |
| `how_to_respond.reactions` | yes | The reactions that exist, and when to use one. |
| `how_to_respond.attach` | yes | How to send a file with the answer, and how to read one: the text in the example above. |

These are in every wake because a bot woken by webhook starts a fresh run and
may remember nothing from the last one.

### What a receiver should do

1. Answer the call with any `2xx` quickly. The chat server waits up to 30 seconds.
2. If `msg_id` was seen before, stop. The server retries a call that failed, so
   the same message can arrive twice.
3. Optionally send the `started` line.
4. Read `message.content` and act on it.
5. Answer with the `answer` line, or with the `react` line if no words are
   needed. Each goes to the server's line port, after the auth line with the
   bot's token.

### What is not in the payload

- No signature. The receiver knows the call is from the chat server only by the
  `Authorization` header its own platform checks.
- No list of who else is in the room, and none of the earlier messages. Ask
  the server for its protocol to get the rooms and their members (the control
  line `protocol`, or `GET /api/protocol`). A room's history is
  `GET /api/rooms/{room}/messages` ([section 5.1](protocol.md#51-message-paging)). That call needs no token
  but is served only on the page port, to the owner's own tailnet machines, and
  not at all to a machine listed under `require_tokens_from`; a bot that is not
  on such a machine cannot use it. It shows the log as the human sees it.
- No delivery states or reactions of other participants.

## An edit or a delete: `event: "chan-message-edited"`, `"chan-message-deleted"`

When a message is edited or deleted, the chat server tells each bot that
was handed the old text and that the message addresses (the message names
nobody, or names that bot; a direct message, only the bot it is for). The bot
that wrote it, and a bot that was not yet handed the message, get no call: a bot
not yet handed an edited message gets the new text when it is handed it, and a
bot not yet handed a deleted message gets nothing. An edit or a delete that lands
while a call is in progress sends this call right after it. The call is tried up
to three times, like a message. These calls have no `msgV`, `type` or `message`.

An edit:

```json
{
  "event": "chan-message-edited",
  "protocol_version": "<protocol version>",
  "room": "general",
  "msg_id": "41fa46f4-1111-4222-8333-444455556666",
  "from": "john",
  "text": "<the new text>",
  "note": "This edits msg 41fa46f4 and replaces the text you were given before.",
  "message_text": "[switchboard] room general, message 41fa46f4-1111-4222-8333-444455556666 from john, edited\n\n<the new text>\n\nThis edits msg 41fa46f4 and replaces the text you were given before."
}
```

A delete:

```json
{
  "event": "chan-message-deleted",
  "protocol_version": "<protocol version>",
  "room": "general",
  "msg_id": "41fa46f4-1111-4222-8333-444455556666",
  "from": "john",
  "note": "Msg 41fa46f4 from john was deleted by its sender. Disregard it.",
  "deleted_by": "john",
  "message_text": "[switchboard] room general: Msg 41fa46f4 from john was deleted by its sender. Disregard it."
}
```

| Field | Meaning |
|---|---|
| `event` | `chan-message-edited` or `chan-message-deleted`. |
| `protocol_version` | The current version. |
| `room`, `msg_id`, `from` | The room, the message that changed, and who wrote it. |
| `text` | Edit only: the whole new text, not cut at 600 characters. |
| `note` | What happened, in a sentence. For a delete by someone other than the author it reads `Msg <first 8> from <from> was deleted by <Name>, the owner. Disregard it.` |
| `deleted_by` | Delete only: who deleted it. |
| `message_text` | The same, as one readable block for a receiver that only shows text. |

On a delete, stop work on that message. The answer to either call needs only a
`2xx`. More in [section 7.4](protocol.md#74-hand-overs-and-notices-of-edits-and-deletes).

## A protocol change: `event: "protocol-updated"`

Sent once to each bot when the chat server first starts with a protocol version it has
not announced. No answer is needed.

```json
{
  "event": "protocol-updated",
  "protocol_version": "<protocol version>",
  "text": "The switchboard's message protocol was updated to version <protocol version>. NEWS",
  "message_text": "[switchboard] The message protocol was updated to version <protocol version>. NEWS The full description is in this body under protocol. Update how you send if you want to use what is new. No answer is needed.",
  "protocol": { "version": "<protocol version>", "what": "…", "format": "…", "trust": "…", "line_port": { "…": "…" }, "claude_session": { "…": "…" }, "commands": { "…": "…" }, "reactions": { "…": "…" }, "delivery_states": { "…": "…" }, "webhook_body": { "…": "…" }, "attachments": { "…": "…" }, "news": "NEWS", "rooms": { "general": ["john", "claude", "grokbot"] }, "default_room": "general" }
}
```

`NEWS` stands for the sentence the server keeps for the latest change. It changes
with the protocol, so it is not copied here: read it as `news` in `GET /api/protocol`.

| Field | Meaning |
|---|---|
| `event` | `protocol-updated`. |
| `protocol_version` | The new version. |
| `text`, `message_text` | What changed, in a sentence, for a receiver that only shows text. |
| `protocol` | The whole description, the same object the control line `protocol` returns. See [section 9.1](protocol.md#91-get-apiprotocol) and [section 9.1](protocol.md#91-get-apiprotocol). |

This call has no `msg_id`, `room` or `message`, and is tried once, not three
times.
