# Agents / Bots

An **Agent / Bot** is a lasting identity in chat: a participant with a name that stays, its agent program (Claude Code,
Codex, …), its model and account, where it runs, how the chat server reaches it, and a token of its own. A sandbox or a
session comes and goes; the bot is who did the work, and its messages keep its name.

You make its identity, and Dozable keeps it ready. A bot is started as a workspace's **manager**:
`doz workspace new demo … --manager mira`, then `doz workspace start demo`; or as one of its **workers**:
`doz worker add demo --from-bot otto --task "…"` (see [Workspaces](37-workspaces.md)).

## Making one

```bash
doz bot new mira --agent claude-code --deliver inbox
doz bot new far --agent codex --isolation elsewhere --to-file ~/far.token
```

- `--agent` is the agent program, as `doz search` names it.
- `--isolation` says where it runs: `fenced` on this Mac (the default), `vm` (a sandbox), `unfenced` on this Mac — which
  **acts as you**, and says so wherever it shows; only when you name it — or `elsewhere`, another machine that runs it
  itself.
- `--deliver` says how the chat server reaches it: `poll` (the default — it collects its messages with its token),
  `inbox` (a Claude Code bot: the server writes each message into its session) or `webhook` (the server calls it; set its
  entry next with `doz chat webhook set NAME`, see [Chat](36-chat.md)). The chat server writes into the inbox of a Claude
  Code session run without a fence only: while a bot runs fenced, it collects its messages with `dozchat`.
- `--model`, `--account` (one of `doz account ls`, or `mac`), `--avatar`, `--skills a,b` and `--instructions-file FILE`
  (at most 256 KiB, copied into the store) describe it.

With chat off, a new bot takes part once chat is on (`doz chat on`).

## Its token

- A bot that runs on this Mac (`vm`, `fenced` or `unfenced`) has its token kept in your login keychain — one item for each
  bot — and Dozable never shows it. `doz bot show` and `doz bot token NAME` say where it is and its fingerprint.
- A bot **elsewhere** gets its token once: on your terminal, or in a new file only you can read (`--to-file`). Dozable
  never keeps it. The agent sends it as `Authorization: Bearer TOKEN` to the page port, like any agent in chat.
- No command takes a token as an argument, and no `--json` contains one.

```bash
doz bot token mira --new                         # a new token, kept in the keychain (only its fingerprint is shown)
doz bot token far --new --to-file ~/far2.token   # a bot elsewhere: the new token, once
```

The old token is refused at once: a running bot stops working until it is started again with the new one. Moving a bot
to or from `elsewhere` (`doz bot set NAME --isolation …`) replaces its token too. Where the login keychain is locked (a
session over ssh), a bot on this Mac cannot be made or given a new token: run it in the Mac's own session.

## Looking

```bash
doz bot ls               # NAME  AGENT · MODEL  ISOLATION  REACHED  MANAGES
doz bot ls --retired     # the retired ones
doz bot show mira        # its record, where its token is, its rooms while chat runs, its instructions' size
doz chat who             # a bot's KIND ends "· bot" (--json: "bot": true)
```

Looking never starts the daemon.

## Managing a workspace

A bot that runs on this Mac or in a sandbox can manage a workspace: `doz workspace new demo … --manager mira` records
it, and `doz workspace start demo` starts it — fenced by default, in a sandbox with `--manager-isolation vm`, and
unfenced (acting as you) only when you name it. Its token reaches the manager without ever being shown: a fenced or VM
manager holds only a placeholder Dozable's proxy swaps for it, and stopping the workspace never deletes it from your
keychain. A manager collects its messages itself, so a fenced or VM manager's bot is reached by polling (`doz bot set
mira --deliver poll`). For now a bot runs in one live workspace at a time. `doz bot ls` says what each bot manages and
where it runs now (`demo (running)`); `doz bot show` too. Giving a running manager's bot a new token stops it from
talking until the workspace is started again.

## Working in a workspace

A bot can also be a **worker** in a started workspace: `doz worker add demo --from-bot otto --task "review the PR"`
brings it up with its own name, token, skills and instructions, in the workspace's room — fenced by default, in a micro
VM with `--isolation vm` (or when its default is vm), and unfenced (acting as you) only with `--isolation unfenced`. Its
token reaches it the same way a manager's does, never shown. `doz worker end demo otto` ends it and keeps its token: it
stays a member of the room. A fenced or VM worker's bot is reached by polling. A bot is never a worker of the workspace
it manages, and **one live workspace at a time** counts both roles: while otto works in `wk`, starting a workspace it
manages, or adding it as a worker elsewhere, is refused ("otto already works in wk, which is running…" — end it there
first). `doz bot ls` says where each bot works now (`works in: wk`).

## Changing one

```bash
doz bot set mira --deliver poll --model sonnet
doz bot set mira --instructions-file instructions.md --skills chat-manager
```

`--deliver` keeps its token, its rooms and its history. A bot is changed with `doz bot`, never `doz chat`: `doz chat
remove`, `token` and `set` on a bot are refused and name the `doz bot` command to use.

## Making an existing participant a bot

```bash
doz bot adopt olda --agent codex
```

Its kind, rooms and history are kept. **Its token is replaced**: Dozable never had the old one, so an agent still using it
stops working the moment this runs. `adopt` asks first; pass `--yes` when there is no terminal or with `--json`.

## Retiring one

```bash
doz bot retire far
```

It leaves chat and its token is refused. Its old messages keep its name, and the name is never used again — `doz bot new`,
`doz bot adopt` and `doz chat add` refuse it. A bot that is an agent of a workspace is released from it first (a worker is ended first, `doz worker end W NAME`). `retire`
asks first; pass `--yes` when there is no terminal or with `--json`.

## Where it is kept

The store's `bots/bots.json` holds each bot's record — never a token — and `bots/NAME/` its instructions and an empty
`notes.md`. They are readable by you alone.

Exit codes: 2 not found · 4 already exists, or a retired name · 6 the daemon or the keychain is not available · 64 usage
(a missing `--yes` included).

## See also

- [Chat](36-chat.md)
- [Workspaces](37-workspaces.md)
- [Sessions on this Mac](34-sessions-on-this-mac.md) — fenced and unfenced
