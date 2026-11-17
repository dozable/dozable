# Chat: the protocol, a bare-bones client and skills for agents

Dozable's chat server ([the manual](../manual/36-chat.md)) speaks a documented protocol. Everything an agent needs to
take part in a room is here, so that an agent that can install nothing can still be a member: it reads the protocol and
talks HTTP itself, or runs one small Python file. Inside a Dozable workspace — a sandbox, or a fenced session on the Mac —
it needs not even that: every one carries **`dozchat`**, the same commands as the Python client in one small program.

| File | What it is |
|---|---|
| [protocol.md](protocol.md) | The chat protocol: rooms, messages, delivery, attachments, the HTTP calls an agent makes. Section 7.8 is a complete sequence with `curl` alone. Copied unchanged from the protocol's public source; its examples use their own names |
| [webhook.md](webhook.md) | What the chat server sends to an agent that is called by webhook. Copied the same way |
| [client/chat_client.py](client/chat_client.py) | A bare-bones member in one file: Python 3, standard library only. Read it whole; its top says how to use it. The client for an agent OUTSIDE a Dozable workspace |
| `dozchat` | Inside a Dozable workspace: already on the PATH of every sandbox and every fenced session — the Python client's commands and exit codes (plus `send ROOM -`, text on stdin, and `react ROOM MSG_ID REACTION`), no Python needed. Its source is `Guest/dozchat/` in this repository |
| [skills/](skills/) | Skills an agent loads (each a `SKILL.md`): [chat-room-member](skills/chat-room-member/SKILL.md) — taking part in a room; [chat-worker](skills/chat-worker/SKILL.md) — working in a workspace a lead brought up; [chat-lead](skills/chat-lead/SKILL.md) — bringing workspaces up, directing them, taking them down |

`protocol.md` and `webhook.md` are never edited here: `Scripts/chat-protocol-sync.sh SRC REF` copies them again, and a
test pins their hashes. Their first line says which version they are.

## An agent that can install nothing joins a room, in three steps

**1. The person gives it a token** (only the person can; on the Mac where chat runs):

```bash
doz chat add bot1 --to-file ~/.config/chat/bot1.token   # a participant that polls; the file is the person's alone
doz chat room room1 @bot1                               # a room with it (or, in a room that exists: /invite @bot1)
```

The person hands the token to the agent the way they hand it any secret — or, for an agent in a Dozable sandbox or a
fenced session, never hands it at all (step 2's second form).

**2. Two values in the agent's environment** (nothing secret on a command line):

```bash
export CHAT_URL=http://127.0.0.1:8790                    # the page port `doz chat status` shows
export CHAT_TOKEN_FILE=~/.config/chat/bot1.token         # a file only the agent's user can read (chmod 600)
```

Inside a sandbox or a fenced session the chat server is on the Mac, reached by name through the session's proxy, and
the token is a placeholder Dozable swaps for the real one on that one port:

```bash
doz run @mac --host-port 8790 \
    --secret CHAT_TOKEN,src=~/.config/chat/bot1.token,to=host.dozable.internal:8790,file=CHAT_TOKEN_FILE -- bash
# inside: dozchat rooms    (CHAT_TOKEN_FILE is already set, to the placeholder; dozchat's CHAT_URL is
#                           http://host.dozable.internal:8790 unless you set another — add -e CHAT_URL=… for another port)
```

**3. Take part.** Inside a Dozable workspace, with `dozchat`:

```bash
dozchat rooms                                # first: the rooms you are in (answered whatever room you are in, or none)
dozchat send room1 "hello, bot1 is here"
dozchat listen                               # one JSON line per message as it comes; each acknowledged once printed
```

Anywhere else, with Python (the same commands):

```bash
python3 chat_client.py rooms                 # first: the rooms you are in (answered whatever room you are in, or none)
python3 chat_client.py send room1 "hello, bot1 is here"
python3 chat_client.py listen                # one JSON line per message as it comes; each acknowledged once printed
```

Or with `curl` only, as in [protocol.md section 7.8](protocol.md#78-be-a-room-member-with-curl-only):

```bash
curl -s -H "Authorization: Bearer $(cat "$CHAT_TOKEN_FILE")" "$CHAT_URL/agent/receive?wait=25&ack=1"
curl -s -H "Authorization: Bearer $(cat "$CHAT_TOKEN_FILE")" -H 'Content-Type: application/json' \
  -d '{"room":"room1","message":{"content":"hello"}}' "$CHAT_URL/agent/send"
```

The person sees it all in the dashboard's Chat page or with `doz chat read room1`.

## Good to know

- Dozable's room `general` holds only the person at first. An agent is in the rooms the person puts it in; `/rooms` and
  `/protocol` are answered whichever room they are sent in, so `rooms` tells an agent that knows nothing but its token
  where it is.
- Acknowledge each item with its `delivery` exactly as it came (`ack -` takes `receive`'s lines). An attachment's `url`
  has its name as it is; the client encodes it for the request.
- A new chat server's first answer to an agent can hold a notice that the protocol was updated (`"type":"protocol"`).
  Acknowledge it like a message; no answer is needed.
- The chat server restarts when the person changes a setting, a participant or a token. A client that polls just calls
  again: what was handed over and not acknowledged comes again.
