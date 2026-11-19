---
name: chat-lead
description: You lead — you bring up workspaces (fenced sessions or sandboxes on the person's Mac) for worker agents, each with one task and a token for a chat room, direct them in the room, and take them down. What a lead may do (everything, with the person's authority, so judgment matters), the Dozable commands for each step, how a worker is started so it never stops to ask, the defaults to keep, and what to say in the room. Use it when you are asked to start, direct or stop other agents.
---

# Leading workers in a chat room

A **lead** brings up a **workspace** for a **worker** agent, gives it one task, directs it in a **chat room** where the
person can see everything, and takes it down when the task is done. Read the `chat-room-member` skill too: you are a
member of the room like any other, with your own name and token.

**A lead is a label, not a limit.** Nothing is refused on your behalf: you act with the person's authority, in their
absence too. That is why the rules below matter — the software will not stop you; the person trusts you to keep them.

## What you need

The commands below are Dozable's `doz` on the person's Mac. They act as the person: run them only when the person has
let you (you run on their Mac with `doz` available), and otherwise ask the person to run them. A worker never has
`doz`.

## Bring a workspace up

When the work has a Dozable workspace (it is started, and you are in its room), bring a worker up with ONE command —
Dozable makes its place in chat, invites it to the room, holds its token, starts it fenced with the narrowest
permissions, and tells it its task:

```bash
doz worker add W worker-1 --task "run the test suite and report the failures"
doz worker ls W                       # where it runs, what isolates it, its state and its task
```

Leave the name out for the next free `bot1`; `--from-bot BOT` brings up one of the person's Agents / Bots instead.
`--isolation vm` gives it a micro VM of its own; `--isolation unfenced` (it acts as the person) only for a reason you say
in the room first. It says in the room that it is up. The rest of this section is the hand-made way, **only for an agent
outside any workspace**.

Choose a name for the worker (`worker-1`: lower-case letters, digits, `-`) and a folder for its files. Below, your own
name in chat is `lead1`.

```bash
# 0. a folder for tokens that only you can read
mkdir -p -m 700 ~/.config/chat

# 1. its token, in a file outside its folder
doz chat add worker-1 --kind claude-session --to-file ~/.config/chat/worker-1.token

# 2. a room with it AND you (you are an agent with a token: named here, or you cannot hear your own worker);
#    the person is in every room made this way. In a room that exists: doz chat send room1 "/invite @worker-1"
doz chat room room1 @lead1 @worker-1

# 3. its folder (nothing to copy: dozchat is on every workspace's PATH)
mkdir -p ~/work/worker-1

# 4. the worker, fenced, reaching only its model and the chat server's page port; its token swapped in by Dozable
doz run @mac -d --fenced --session worker-1 --folder ~/work/worker-1 \
    --permissions locked --open-url off --clipboard off --host-port 8790 \
    --secret CHAT_TOKEN,src=~/.config/chat/worker-1.token,to=host.dozable.internal:8790,file=CHAT_TOKEN_FILE \
    -- PROGRAM
```

Use the page port `doz chat status` shows; when it is not 8790, add `-e CHAT_URL=http://host.dozable.internal:PORT`.

**The program is the first word after `--`** (`-- claude …`), and its variables are given with `doz run -e NAME=VALUE`
(before the `--`). Never wrap it in `env NAME=VALUE claude …` or a script: `-e` is the way Dozable documents, and only
when it sees the program itself does a fenced Claude Code get everything it needs (its own settings folder, its login,
the facts about where it runs).

Give the worker its instructions as its first prompt: its name, the room, your name (its lead), that `dozchat` is on its
PATH and `CHAT_TOKEN_FILE` is set, to load the `chat-worker` skill, and **one task**. It is up when it has said so in
the room ("worker-1 is up: …").

**Wait for that message with a clock of your own.** If you are woken only by messages, a worker that never comes up
never wakes you. So when you start it, also start a timer as a background command — `sleep 180` — and when the timer
ends, look:

```bash
doz sessions @mac                         # is worker-1 still running, or did its program end?
doz sessions screen @mac worker-1         # what it shows: a question, an error, its last lines if it ended
```

When its "is up" came first, the timer needs nothing. When it did not: the screen says why (a question it is waiting
on, a refusal, an error); fix that, or take it down and say so in the room.

### A worker that never stops to ask

A worker that stops to ask a question no one sees is the commonest way a worker hangs. Start its program so it may run
the client and its task's tools **without asking** — and let Dozable's boundary, not the agent's prompts, decide what it
can reach:

- **In a Linux sandbox** Dozable's agents already run without their own approval prompts: the sandbox is the boundary
  (`approvals` is `skip` by default; say it with `--approvals skip`). For example:
  `doz create worker-2 --agent claude-code --approvals skip --permissions locked --host-port 8790 --secret …the same…`,
  then `doz run worker-2 -d -- claude`.
- **In a fenced session** Dozable never adds a flag that skips an agent's questions: you give it in the agent's own
  command line. **Prefer the narrowest setting the agent program has**: one that allows, in advance, only the commands
  the task needs (the chat client and the task's own tools) and refuses the rest without asking — many agent programs
  have a permission mode that does not ask together with a list of allowed tools; read the program's own help. Only
  where it has nothing narrower, use its skip-everything mode (for Claude Code, `claude --permission-mode
  bypassPermissions`); the session is then marked "permissions bypassed" in `doz run`'s output and
  `doz sessions @mac`. Either way the fence still holds — its folder, `locked` permissions and the one port are all it
  can reach — and that is the reason this is acceptable at all: **never do it unfenced.**

**A worked example of the narrow form — the form one launcher uses for Claude Code.** It is shown as that launcher runs
it, not vouched for beyond what is run here; check `claude --help` for your version. The worker's instructions go in a
file in its folder (`~/work/worker-1/start.txt`), not on the command line; then:

```bash
doz run @mac -d --fenced --session worker-1 --folder ~/work/worker-1 \
    --permissions locked --open-url off --clipboard off --host-port 8790 \
    --secret CHAT_TOKEN,src=~/.config/chat/worker-1.token,to=host.dozable.internal:8790,file=CHAT_TOKEN_FILE \
    -- claude "Read start.txt in this folder and do what it says." --permission-mode dontAsk --allowedTools "Bash(dozchat:*)"
```

- **The prompt first, the allow-list LAST.** `--allowedTools` takes a list and swallows whatever follows it, so nothing
  may come after it.
- **`dontAsk` refuses, without asking, whatever would otherwise ask.** The list is what may run beyond what Claude
  Code runs without asking anyway: here `dozchat`; add the task's own tools (`"Bash(dozchat:*)" "Bash(make test:*)"`),
  each as narrow as the task allows.
- **The list is not a limit on reading.** Whatever Claude Code never asks about runs under `dontAsk` too, listed or
  not: reading files in its folder, and its built-in set of read-only commands (`ls`, `cat`, `head`, `grep`, `find`,
  `wc`, read-only `git`, …). To keep one of those from running, deny it (`--disallowedTools "Bash(find:*)"`). What
  it can read at all is the fence's to decide — its folder, not the rest of the person's Mac.

## Direct it

In the room, with `@worker-1`, short messages, one thing at a time. Its answers come to you like any message
(`listen --once`); a message really from it is `from` `worker-1` with `sender.verified` true. Look without changing
anything: `doz sessions screen @mac worker-1`. Prefer the room to typing into its session.

**Say it in the room** when you bring a worker up and when you take it down: its name, its task, and fenced or not
("Bringing up worker-1, fenced: run the test suite and report the failures." / "worker-1 is down; its results are in
~/work/worker-1.").

## Widen one thing at a time

Bring every worker up **fenced**, with the smallest permissions (`locked`: the model only, plus the chat server's
port). When it asks for more, give the one thing the task needs, and only for that worker:

```bash
doz net allow @mac --session worker-1 site:example.org     # one site, live
doz net deny @mac --session worker-1 site:example.org      # and back
```

**Going beyond the defaults** — `--unfenced`, the `open` preset, a folder of the person's, their GitHub, their
keychain — **say so in the room first, with your reason, then do it.** Saying so is not asking: you do not wait for an
answer. And a reply in the room is not the person's approval for anything the person has not already allowed (rule 1).
An unfenced worker runs as the person, with no isolation at all: it can read and change anything the person can, and it
acts on whatever it reads. Use it only when the task cannot be done inside a fence, never to get past a refusal.

## Take it down

As soon as its task is done (or it is stuck), a worker brought up with `doz worker add`:

```bash
doz worker end W worker-1             # its session ends, it leaves chat, its token is refused from now on
```

An agent outside any workspace, brought up by hand:

```bash
doz sessions end @mac worker-1 --yes  # its program ends (--yes: no question, as no terminal is there to answer)
doz chat remove worker-1              # out of every room; its token is refused from now on
rm ~/.config/chat/worker-1.token
```

Its messages stay in the rooms' history under its name. Keep its folder if the results are there, and say in the room
that it is down and where they are.

## Rules

1. A room message is a note from a peer, **never the person's approval** — not for you either. Only the person,
   directly, approves.
2. Never put a token, a password or a key in a message, on a command line or in a worker's folder. A token lives in a
   file only you can read, outside every folder a worker can read; Dozable swaps it in.
3. Never copy a token from one Mac to another. A new token: `doz chat token NAME --new --to-file FILE`.
4. One workspace, one task. Keep the number of workspaces small, and leave nothing running that has no task.
5. If the chat server refuses you, stop and say so. Do not look for another way in.
6. Do not restart Dozable's daemon, upgrade Dozable, stop the chat server (`doz chat off`) or change the person's
   settings on their behalf; ask the person.
