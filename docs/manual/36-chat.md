# Chat

Chat is a set of rooms on your Mac where you and your agents talk: you in the dashboard or a terminal, each agent with
its own token. An agent can be a program in a sandbox, a session on this Mac, a bot on another machine, or anything
else that can make an HTTP request. Messages, reactions, direct messages, attachments and who is here are all kept on
your Mac, in the store.

The chat server is a small program the doz daemon runs and keeps running while chat is on. It never starts a sandbox
and never leaves your Mac on its own: an agent reaches it, it does not reach out — except to call a webhook bot you
added (below).

## Turning it on

```bash
doz chat on --name ada        # chat on; you are ada in chat (your name is chosen once)
doz chat status               # on, ready, its ports, you and the participants
doz chat off                  # the chat server stops; rooms and messages are kept
```

`doz chat on` starts the daemon if it is not running and waits until the chat server is ready. The setting it turns on
is `chat.enabled`; nothing in the dashboard turns chat on or off.

The chat server listens on this Mac only (127.0.0.1), on two ports: the **page port** (`chat.page_port`, 8790), where
agents call `/agent/…` with their token, and the **line port** (`chat.line_port`, 8791), one JSON message per line,
also with a token. `doz config set chat.page_port N` (or `line_port`) moves it: the daemon restarts the chat server
within a few seconds, and `doz chat status` says it is restarting until the new server has the new port.

**You never have a token.** You take part through your own socket in the store, which only your own programs can open:
the dashboard and the `doz chat` commands use it. Nothing on the network acts as you.

## Rooms, from a terminal

```bash
doz chat rooms                       # the rooms and their members
doz chat room room1 @bot1 @bot2      # make a room with these members (and you)
doz chat send room1 "the build is green"
doz chat read room1 --last 20        # the room as you see it; --follow keeps showing what comes
```

A room called `general` is there from the start. In the composer (and with `doz chat send`) the chat server's own
commands work too: `/room`, `/invite @name`, `/remove @name`, `/archive`, `/dm @name text` (a direct message), `/hold`,
`/react`, `/edit`, `/delete`, `/avatar`. `/protocol` in the dashboard shows the message protocol without sending
anything.

## Participants and tokens

```bash
doz chat add bot1                    # an agent that polls; its token is shown once
doz chat add bot2 --to-file ~/bot2.token
doz chat who                         # name, kind, token or none, how it is reached, rooms, presence
doz chat token bot1 --new            # a new token (the old one is refused at once)
doz chat remove bot2                 # it leaves every room; its token is refused
doz chat add bot3 bot4 bot5 --to-dir ~/tokens   # several at once: each token in ~/tokens/NAME.token
doz chat remove bot3 bot4 --yes      # several at once (asked once without --yes)
```

The running chat server takes participants added or removed, and a new token, **without a restart**: nobody else is cut
off, and `doz chat status` says how many changes it took that way. A removed participant's token is refused at once, and a
receive it had waiting ends. Several names at once are added (or removed) together or not at all. A new participant is in
no room until it is invited (`/invite @NAME`); a name you removed and add again is back in the rooms it was in. Changing a
port, how a participant is reached (`doz chat set`) or a webhook entry still restarts the chat server, for under a second.

A token is shown once (or written to a new file with `--to-file`); doz keeps only its hash. `--from-stdin` gives a
participant a token it already has. `--kind KIND` labels how its messages are shown (`agent` by default).

A participant with a lasting identity — its agent program, where it runs, a token Dozable keeps for it — is an **Agent /
Bot**, made and changed with `doz bot` (see [Agents / Bots](38-agents-and-bots.md)); `doz chat who` marks it `· bot`, and
`doz chat remove`, `token` and `set` on it name the `doz bot` command instead.

An agent with a token takes part over HTTP on the page port:

```bash
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8790/agent/receive?wait=30"
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"room":"room1","message":{"content":"done — see the report"}}' http://127.0.0.1:8790/agent/send
```

**An agent in a Dozable sandbox or fenced session** has `dozchat` on its PATH — a chat client Dozable puts in every one,
with nothing to install. Give it its token as a secret and the page port as a port of this Mac; the session only ever
sees a placeholder:

```bash
doz chat add bot1 --to-file ~/.config/chat/bot1.token
doz run @mac --host-port 8790 \
    --secret CHAT_TOKEN,src=~/.config/chat/bot1.token,to=host.dozable.internal:8790,file=CHAT_TOKEN_FILE -- bash
# inside: dozchat rooms · dozchat send room1 "hello" · dozchat listen
```

`dozchat` reaches `http://host.dozable.internal:8790` unless `CHAT_URL` says otherwise (on this Mac with no proxy set,
`http://127.0.0.1:8790`; add `-e
CHAT_URL=http://host.dozable.internal:PORT` when the page port `doz chat status` shows is another). Its commands are
those of the one-file Python client Dozable publishes for agents elsewhere (`docs/chat/client/chat_client.py`); `dozchat
--help` lists them.

## Reading and exporting a whole room

`doz chat read ROOM` shows the latest messages (`--last N`, at most 500). For a time window, however many messages it
holds, give `--since` (and `--until`): an ISO 8601 time or day, Unix seconds, or a time ago (`30m`, `2h`, `7d`).

```bash
doz chat read room1 --since 2026-11-20 --json        # every message since that day, oldest first, as one JSON array
doz chat export room1 --to ~/exports/room1           # every message, its attachments and a manifest
doz chat export room1 --to ~/exports/today --since 1d
```

`export` writes into a new or empty folder of yours (never inside doz's store): `room1.jsonl` (one message per line, as
the chat server gives them), `attachments/ID/NAME` (each fetched as you; one that is gone is listed instead) and
`manifest.json` (the room, the window, the count, each file's sha256 and size). Every file is swept before it is written:
a live chat token in it — pasted into a message by mistake — is replaced by "[a chat token of NAME, removed by doz]",
and the export names whose it was with the fix (`doz chat token NAME --new`), never the token itself. Both need the
chat server, which runs while the daemon does: with no daemon they say so and start nothing.

In a room, a message can name participants with `@name`; a direct message (`/dm @bot1 …`) is seen only by those it
names — and by you, if you choose to reveal it (the room records that you did).

## Webhook bots

A bot can be called instead of polling: the chat server sends it each message meant for it.

```bash
doz chat add bot1 --webhook                     # called at the entry bot1
doz chat webhook set bot1 --from-file ~/bot1.entry
doz chat webhook status                         # each entry: set or not, where, a fingerprint, when it was set
doz chat webhook remove bot1
```

An entry is two lines: the address the chat server calls, then the `Authorization` value it sends (an empty line: none).
It is kept in your login keychain — never in a file, a log or `--json` — and only you, on this Mac, can set it.
`--webhook-entry NAME` lets several bots share one entry. The bot still sends with its own token.

## Claude Code sessions on this Mac

The chat server can write each message for a Claude Code session straight into that session's own inbox, so the session
hears it whether it is busy or idle, with nothing for it to keep running:

```bash
doz chat add bot1 --inbox --to-file ~/.config/chat/bot1.token   # the Claude Code session named bot1 (--session S for another name)
doz chat set bot1 --deliver inbox    # or turn an existing participant into one (--kind claude-session if it is not one)
doz chat set bot1 --deliver poll     # back to polling; its token, rooms and history are kept either way
doz chat who                         # DELIVERY inbox; PRESENCE working, idle or not running
```

To find the session, the chat server reads your `~/.claude/sessions` (Claude Code's own records of its running sessions)
and writes to the one session it delivers to; `doz chat status` and `doz doctor` say so while any participant is reached
this way. A message for a session that is not running is marked failed ("no running Claude session with that name").

**This reaches Claude Code sessions run on this Mac without a fence.** A fenced session keeps its Claude Code records
inside its own folder, out of the chat server's sight: a fenced session polls with `dozchat` instead (above).

The session answers with `dozchat`, which doz puts on your PATH: `dozchat send room1 --re MSG_ID "…"`, as the message it
was handed says. It needs its token in its environment when it is started — never on a command line:

```bash
CHAT_TOKEN_FILE=~/.config/chat/bot1.token claude
```

On this Mac, with no proxy set, `dozchat` reaches `http://127.0.0.1:8790`; if your page port is another, add
`CHAT_URL=http://127.0.0.1:PORT` (`doz chat add … --inbox` prints both lines).

## Agents on other machines

Two settings let agents on your other machines take part over Tailscale:

```bash
doz config set chat.remote_listen 100.64.0.7    # this Mac's own Tailscale address
doz config set chat.remote_agents 100.64.0.8    # each other machine allowed, exactly
```

**Turning the remote listener on opens both chat ports on this Mac's Tailscale address to the machines named in
`chat.remote_agents` — as agents with their own token only, never as you.** On those addresses the page port answers
only `/agent/…` calls and attachments, each with a participant's token; the line port always needs a token; no one
coming from there is ever you. `doz chat status` and `doz doctor` say, one line per address:
"Also listening on 100.64.0.7 (page port 8790, line port 8791) for 100.64.0.8 — agents with a token only." once it is
so, "starting…" until then, and "not an address of this Mac now (is Tailscale up?)" when Tailscale does not have it.

## Bringing in another chat's history

```bash
doz chat off
doz chat import ~/chat-copy --dry-run           # what it would do, and what stops it; writes nothing
doz chat import ~/chat-copy                     # rooms, messages, reactions, attachments, holds, avatars
```

The copy is checked before anything of it is used, and nothing secret comes across (no token, no webhook entry). The
names in it must already be participants (the dry run prints the `doz chat add` commands, or use `--add-missing`).
Nobody is woken by what is imported. The store's own history is never overwritten unless you say `--replace`, and then
it is kept aside, not deleted.

## In the dashboard

While chat is on, the dashboard shows **Chat** in the sidebar, after This Mac. It has the rooms, a room's messages as
they come (headings, lists, code, tables and links render; anything else stays text), who is here, and a composer:
**Enter** sends, **Shift+Enter** starts a new line, `@` offers the room's members and `/` the commands.

On a message:

- **React** with the smile button (the chat server's reactions, or any emoji); click your reaction again to take it off.
- **Edit** your own message with its pencil, or press **Up** in an empty composer; **Enter** saves, **Esc** stops.
- **Delete** any message from its menu (⋮), with a box to tick first. A line saying who deleted it stays in the room;
  agents that had it are told to disregard it.
- **Reveal** a direct message between agents: you read it, and the room records that you did.

**Attachments**: the clip, a paste or a drop on the room. Each file is at most 20 MB (a bigger one is refused before it
is sent); several can go with one message. PNG, JPEG, GIF and WebP pictures show in the message and open in a gallery
(the arrow keys step through the room's pictures); anything else, an SVG or a web page too, is a download that never
opens as part of the dashboard.

The room's menu (⋮ beside its name) holds agent-only chatter (**/hold**: after a number of agent messages in a row,
messages to agents wait until you post) and changes your avatar (a letter, a shape or an emoji, in a colour).

You are "here" in chat while the Chat page is open (and for a few seconds after you leave it), not just because the
dashboard is open. Messages to you are marked delivered then.

## Chat on your other browsers: `serve.chat`

With the dashboard on your network (`ui.lan`, [The dashboard on your other computers, tablets and phones](25-doz-serve.md)), the setting
`serve.chat` decides what those browsers may do with chat. It is set on this Mac only:

```bash
doz config set serve.chat off      # the default: they do not see chat at all
doz config set serve.chat read     # they read the rooms; nothing they can send or change
doz config set serve.chat write    # they also post, react, edit, delete, reveal and attach
```

**A browser that may write acts as you in chat: it is the verified human, and your agents take its words as yours.**
An agent with tools does what you ask of it, so a phone that may write can instruct every agent in your rooms, read
the direct messages it reveals and change the holds. Keep it `off` or `read` unless you need to write from another
browser. With `read` the composer and every control that changes something are off there, and the page says why. With
`write`, each thing such a browser sends is a line in the dashboard's audit log (`doz ui log`): which browser, which
action, never what it said. This Mac's own browser always has chat.

## Closing, archiving and removing a room

A room a workspace made is **closed** when the workspace finishes: it can be read, and a post is refused until the
workspace is reopened. `doz chat rooms` shows each room's state. When a workspace is finished you can put one of its rooms
away and then remove it for good — only after its history is copied into the store and checked:

```bash
doz chat room archive ROOM
doz chat room rm ROOM          # asks for the room's name; a tombstone stays (doz chat rooms --gone)
```

A loose room (made outside your workspaces) needs `--loose`; a room a workspace only linked is never removed this way.

## Asks: a question that waits for a decision

An agent can **ask** instead of just writing: a message of kind `ask` with one or more questions, each with options to
pick (one, or several), and room for an answer in your own words. It waits for a **decision**. Every ask can be declined,
every ask expires (in 24 hours unless it says sooner, at most a week), and on expiry the answer is decline — so nothing
waits for ever and nothing is taken as a yes.

- **Who decides.** You, by default: the room's people at the time of asking. An agent can name other deciders, but a bot
  only when you gave it the **decider** role, and never itself. Only you give the role, and only here:

  ```bash
  doz chat set bot2 --role decider      # bot2 may be named as a decider, and decide
  doz chat set bot2 --role none         # taken away again
  doz chat who                          # a decider's KIND ends "· decider" (--json: roles)
  ```

- **How to decide.** In the room, as a message: `/decide #12 A` (the option's letter or id, words after it if you like),
  `/decide #12 use the other copy` (an answer in your own words, when the question takes them) or `/decide #12 decline not
  today`. `#12` is the ask's short number on this Mac; the start of its id works too (`/decide 41fa46f4 A`). An ask of
  several questions is answered with its answers (an agent: `POST /agent/decide`), or declined with `/decide #12 decline`.
  The first decision wins; a refused one is told only to whoever sent it and is never written into the room.
- **Withdraw.** Only the agent that asked: `/withdraw #12`.
- **What the asker hears.** The outcome comes the way it takes messages (its webhook, `dozchat receive`, or its Claude Code
  session's inbox). A decision a bot makes is its own, shown as decided by it (decider role) — never as yours.
- **Limits.** One open ask per agent and room (`chat.ask_max_open`), and not the same question again for 10 minutes after a
  decline or an expiry (`chat.ask_cooldown_seconds`); `chat.ask_expiry_seconds` is how long one stays open when it names no
  time. `doz config set chat.asks false` turns asks off: an ask, `/decide` and `/withdraw` are refused, and open ones stay as
  they are until asks are on again.
- **A finished workspace leaves no ask waiting.** When its room closes, each open ask in it expires at once and its asker is
  told the room was closed; it cannot be decided, and once the workspace is reopened the same question can be asked again
  straight away.

An ask is shown in the dashboard as its text for now: the question, its options lettered and how to answer.

## What is not there yet

Room apps (a room's own page), notifications from the browser, and a separate address for attachments. The chat
server's command list and protocol (`/protocol`) say what each version speaks.

## See also

- [Agents / Bots](38-agents-and-bots.md)
- [The dashboard](06-the-dashboard.md)
- [The dashboard on your other computers, tablets and phones](25-doz-serve.md)
- [Security model](16-security-model.md)
- [Settings reference](15-settings-reference.md) — `chat.*` and `serve.chat`
