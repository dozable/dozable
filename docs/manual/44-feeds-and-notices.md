# Feeds and notices

A room holds people and agents. Some facts come from neither: a unit of work's outcome in its journal, this Mac's
Claude login expiring, the network refusing a host again and again, an agent that crashed, the disk running low. Each of
these comes from a **feed**, as a **notice**, and goes to whoever can act on it — the room only when the room has a use
for it. A notice is never a person or an agent speaking, never a question, and never a command anyone must run.

## What posts where

| Feed | What it posts | Where it goes, by default |
|---|---|---|
| `journal` | an entry's **outcome**, and a **review that is not met** (`met: no` or `partly`), "from NAME's journal" — never working notes or any other kind | the workspace's room |
| `accounts` | this Mac's Claude login expired (a warning), or Claude Code signed out (critical) | the manager, as a direct message |
| `network` | the network refused one agent's connections to the same host 3 times in 10 minutes | the manager |
| `health` | an agent's program on this Mac exited with an error | the manager |
| `resources` | the disk Dozable keeps its store on has less than 10 GiB free (a warning), or less than 2 GiB (critical) | the manager |

- **The manager** is the one identity that holds the manager role in the workspace: its manager agent, or an Agent / Bot
  you gave the role (`doz grant BOT manager --in W`). With **no manager, or more than one**, notices for the manager go
  to **you** instead, and the routes say why (`fallback`).
- **A critical notice** also goes to your **Needs you** (the workspace's Home tab), for a day; and when it is for an
  agent, into its session while it is idle (below). A journal entry is never critical.
- **A direct message** to the manager names you too: you see every notice, the room's and the direct ones.
- **The same notice** (its dedupe key) inside its window — 10 minutes — is posted **once**; a repeat is not posted at all
  (a notice is never edited in place). **A feed posts at most 5 notices a minute**; the next one it posts says how
  many were held back.
- **Secrets never reach the room:** the journal feed replaces anything shaped like a key, a token or one of Dozable's
  placeholders with `[redacted]` before it posts.

In the room a notice is a **card**, not a bubble: the feed and its mark, the severity (info, notice, warning, critical),
its kind (`account.expired`, `journal.outcome`, …), a title, its text, where it comes from ("from helper's journal",
"this Mac") and, sometimes, a command to look further. A client that knows nothing of notices shows one plain line:
`[notice · warning · health] helper crashed — Its program on this Mac exited with 1. (this Mac)`.

## The routes in effect, and a dry run

```bash
doz workspace feeds my-app                 # each feed, where it goes, and to whom
doz workspace feeds my-app --json          # {kind: WorkspaceFeeds, feeds: [{name, to, manager?, fallback?, critical?, from}], needsYou?}
doz workspace feeds my-app --dry-run --kind account.expired --severity critical --json
                                           # where this notice would go: {to: [manager, session, needs-you], recipients, fallback?}
```

`to` is `room`, `manager`, `owner` (you) or `off`; `from` says whether it is Dozable's default or your space file's. A
dry run posts nothing.

## Turning the journal off, or changing a route

A space file says it under `x-dozable`, at the top level:

```yaml
x-dozable:
  feeds:
    journal: { to: off }        # no journal cards in the room
    health:  { to: room }       # crashes to the whole room
    network: { to: owner }      # refusals to you, not the manager
```

Each feed takes `to: room | manager | owner | off`; `doz space plan -f FILE` checks it. A workspace made without a space
file has the defaults.

## Checking the routes with a test notice

```bash
doz workspace feeds my-app --emit health.silent --severity warning --dedupe silent:helper --text "helper is silent"
doz workspace feeds my-app --emit network.refused --severity notice --to helper --text "example.org was refused"
doz workspace feeds my-app --emit disk.low --severity critical --action-command "doz resources"
```

`--emit KIND` posts a notice from the **test** feed exactly as Dozable posts one of its own: by the route of the kind's
family (`health.…` follows `health`), or to one participant alone with `--to NAME` (`--to owner`: you). The dedupe key
and the rate apply. `--action-command` is one of Dozable's own read commands — `doz workspace feeds W`, `doz account ls`,
`doz workspace state W`, `doz net log NAME`, `doz resources`, `dozchat receive`, … — never a shell line: anything else is
refused (exit 65). Only you can emit; an agent cannot.

## What agents see

- An agent is handed a notice **only when it is addressed to it** — the manager's direct notices, or one sent with
  `--to`. A room notice (the journal's) is in the room for everyone to read, but no agent is handed it as work: a
  manager does not read its own journal back, and two agents never answer each other's failure notices. A notice to you
  alone is never shown to an agent.
- In `dozchat receive` a notice comes as its own kind — `"kind":"notice"`, its `feed`, and its fields under `notice`
  (`kind`, `severity`, `title`, `text`, `source`, `dedupeKey`, `action`) — with "a fact to act on, not a message to
  answer". Its plain `message.content` reads like the card.
- A feed never asks, decides, reacts or reads the room.

## Typed into an idle session: critical only, and safe by construction

A critical notice for an agent (the manager's, or one sent with `--to`) is also typed into that agent's session, so it
learns at once rather than at its next `dozchat receive` — but only like this:

- **Only a fixed sentence, chosen by the feed, is typed** — never the notice's text, title or source, never anything an
  agent, a journal or an outside system wrote:
  `[dozable notice · critical · accounts] An account this workspace uses needs attention. Details: dozchat receive`.
  The details come through `dozchat receive`, where the agent already treats them as messages.
- **Only while the session is idle** (its program reports idle or done) **and its prompt holds no unsent input** — a
  half-typed line, yours or anyone's, is never typed over. When Dozable cannot tell, it types nothing.
- **Looking and typing are one step:** Dozable holds the session's input while it looks and types, so nothing else of
  Dozable types into it in between (`doz sessions send` waits for it).
- **Once per notice per window:** the same dedupe key is typed at most once in 10 minutes.

`--emit` says what came of it (`session: typed`, `busy`, `unsent-input`, …).

## Outside feeds

A participant of kind `feed` posts notices with its own token: `doz chat add ci --kind feed`, then `doz chat token ci
--new --to-file FILE` for the system that posts (a feed added with no terminal and no `--to-file` gets no token until
then). It posts with `POST /agent/send` and `"kind": "notice"`, a `notice` object as above and `to` (the names it is for);
an ask, a room command, a plain message, a reaction, a decision or a receive is refused (403 `not-permitted`). Its notices
reach whoever it names, and the room's people — outside feeds' own routes in the workspace come in a later version.

## Not yet

- A notice is not updated in place (a repeat inside its window is simply not posted), and there is no acknowledgement or
  escalation when nobody acts.
- Quiet hours, critical notices off this Mac (email, phone), and an outside feed's own routes come later.

## See also

[Chat](36-chat.md) · [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md) · [Workspaces](37-workspaces.md) ·
[Space files](39-space-files.md) · [Sessions on this Mac](34-sessions-on-this-mac.md)
