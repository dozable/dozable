---
name: doz
description: Drive Dozable (`doz`) on a person's Mac for them — make a workspace (agents working on a brief, in the person's folders) in one command, see its state, add or end a helper agent, and read doz's answers (--json, the frozen exit codes, the error JSON) without ever waiting on a prompt. Use it when you are asked to set up or run work in a Dozable workspace, or to use doz at all.
---

# Driving doz for a person

`doz` is Dozable's command on this Mac. You run it for the person, with their permissions: treat every command as if
they typed it. Always pass `--json` and read the answer; never run a command that waits for a terminal.

## What a workspace is

A **workspace** is work set up to get done: a **brief** (what the work is for), the **folders** it works on (the first is
the main one), a chat **room**, and its **agents** — **workers** (each an agent with one task) and, optionally, a
manager. Its agents run **fenced** on this Mac by default: they reach their folders, the network their permissions
allow and the room, and nothing else. When the person asks you to "make a workspace", "set up an environment" or "get
agents working on" something, they mean this — not a sandbox.

## Make one: one command

```sh
doz workspace new NAME --brief "Fix the build" --folder ~/code/app --worker "Fix the failing test" --json
```

- `NAME`: 1–40 of a-z 0-9 -. `--brief TEXT`, or `--brief -` to read it from standard input (its last line break
  dropped), or `--prompt-file FILE` (not with `--brief`). A brief is required.
- `--folder DIR` (repeatable; `DIR:ro` for read-only). The first is the main one.
- `--worker "TASK"` (repeatable) declares a worker now; the start starts it.
- `--preset NAME` starts from a preset: `blank`, `research`, `swift-tests`, `mac-admin`, `remotion-video`. A flag you
  give wins over the preset. An unknown preset exits 65 (`invalid-value`) and its message names the real ones.
- `--start` starts it once it is made (or run `doz workspace start NAME --json` later). Declared workers need chat on:
  if the start says so (exit 3), tell the person — `doz chat on` is theirs to run.
- `--dry-run --json` shows what would be made, every refusal and what the start would still need, and makes nothing.
- `doz workspace create` is the same command as `doz workspace new`.
- `--request-id ID` makes it safe to retry: make up one id per request (a UUID) and pass it. If you lost the answer (a
  timeout, a dropped connection), run the SAME command with the SAME id: you get the first answer with
  `"replayed": true` and nothing is made twice. The same id with other arguments exits 3 (`request-id-reused`); a
  failed first try is not kept, so the retry runs for real. Ids are kept 24 h, per command.

The answer (`--json`) is the workspace: `{"kind":"Workspace","schema":1,"name":…,"state":…,…}`. A new workspace is
`setting-up` until it is started.

## See it

```sh
doz workspace state NAME --json
```

`{"kind":"WorkspaceState","schema":1,…,"phase":…,"agents":{"NAME":{"condition","reason","role","place","since"}},"conditions":{"ready":…,"allocated":…,"hot":…,"run":…,"archived":…}}`

- `phase` is the workspace's: `setting-up`, `running`, `asleep`, `stopped`, `finished` or `archived`.

- Each agent's `condition` is one of `running`, `asleep`, `stopped`, `crashed`, `not-started`, `unknown`; `reason` says
  why in words (a declared worker before the start: `not-started`).
- `conditions.ready` is true only when the workspace is neither finished nor archived, has at least one agent, and every
  agent is running.
- Beside it, one condition per layer: `conditions.allocated` `{value, since, reason?}` (what the workspace holds:
  true from new until archive or delete — a space file with `lifetime: runs` releases it at down; `reason` is `down` or
  `archived`), `conditions.hot` `{value: all|some|none, sessions: {NAME: {condition, since}}}` (each session `starting`,
  `running`, `asleep`, `stopped`, `ended` or `unknown`), `conditions.run` `{open, id, since, state}` and
  `conditions.archived` `{value, at}`. `doz workspace ls --json` rows carry `conditions` `{allocated, hot: {value}, run}`.
- With no daemon running none is started: every condition is then `unknown`. Looking never changes anything.
- More: `doz workspace show NAME --json` (its brief with `--brief`), `doz worker ls NAME --json`, `doz workspace ls --json`.

## Read its document

```sh
doz workspace doc NAME --json
```

`{"kind":"Document","schema":1,"workspace":…,"from":"record"|"space-file","document":{…},"notes":[…]}` — what the
workspace should be, as a space file: its brief, folders, agents, rooms and `document.x-dozable.lifetime` (always there:
`standing` — what it owns stays — or `runs`). `state` is what is true now; the document is what it is for. It never
holds a secret's value, a grant or the phase. It is `doz: space/3.1` (`document.doz`): `brief`, `about` (with
`about.title`), `layout`, `network`, a folder's `main` and an agent's `restart`, `network` and `external: {sandbox}` are
keys of the format; keys under `x-dozable` — the lifetime among them — are Dozable's additions it does not carry yet (writing one of those first-class keys under `x-dozable` still works this release, with a note). `notes`
names what it cannot say yet. `--write FILE` saves it as a space file for the person (exit 4 if FILE exists — only
with `--force` when they asked to replace it); it applies nothing.

## Stop, sleep, finish

```sh
doz workspace stop NAME --yes --json      # every agent's process ends; each becomes stopped; nothing is removed
doz workspace sleep NAME --json           # every agent asleep (memory given back); wake brings them back
doz workspace wake NAME --json
doz workspace finish NAME --yes --json    # the work is done; `doz workspace down NAME` is the same command
```

- `stop` stops EVERY agent (the manager and each worker), not only the manager — `doz workspace manager stop NAME` is
  the manager alone. A stop of a stopped or asleep workspace does nothing and exits 0.
- `finish` and `down` answer `{"kind":"WorkspaceFinish","schema":1,"removed":[…],"kept":[…],"archive":…}`: folders by
  their absolute path, rooms `room/NAME`, agents `agent/NAME`, sandboxes `sandbox/NAME`. A workspace made with `new`
  is standing: it removes nothing. A space file's run things go only after their archived copy verifies.
- `stop` and `finish` ask first: without `--yes` they exit 5 and `error.fix` is the command to run once the person said
  yes.

## Runs: one unit of work at a time

```sh
doz workspace run NAME "Fix the failing test" --json   # a new run with this goal: posted in the room, its agents started
doz workspace run NAME --json                          # a new run whose goal is the brief
doz workspace runs NAME --json                         # each run: goal, goalFrom, source, follows, revision, openedBy, usage
```

- `run` answers `{"kind":"WorkspaceRun","id","state":"open","goal","goalFrom":"given"|"brief","source":{"kind",…},
  "openedAt","openedBy","revision","usage":{"durationMs"}}`. `--source KIND[:REF]` (given, brief, run:ID, ask:TEXT,
  schedule:TEXT) and `--follows RUN` say where it came from; `--no-start` opens it and starts nothing.
- One run at a time: while one is open, `run` exits 3 with `error.code` `run-open` and `error.fix` `doz workspace finish
  NAME` — finishing is the person's call: ask them first. A finished workspace is reopened by `run`; an archived one is
  refused (3). `doz workspace reopen NAME` is the old name of `run`.

## Lessons: the work description

```sh
doz workspace retro NAME --propose --addendum "Run the linter before the tests" --json   # propose a lesson from the last run
doz workspace proposals NAME --json                    # every proposal: open, applied or declined
doz workspace decide NAME PROPOSAL apply --json        # or decline — needs description.decide
doz workspace edit NAME --addendum "TEXT" --json       # add one directly, no proposal — needs description.edit
```

- The work description is the brief plus its addenda (`doz workspace doc NAME --json`: `document.brief.addenda`, each
  `{run, at, by, text}`). A run with no goal takes the brief and every addendum.
- `retro --propose` answers `{"kind":"WorkspaceProposal","id","origin":"retro","state":"open","change":{"addendum"},"by",
  "at","source":{"run"}}` and asks the person in the room; nothing changes until it is decided. Deciding twice exits 3
  (`proposal-decided`).
- Each is a permission an agent holds only when granted: `description.propose` (the `reviewer` role has it),
  `description.decide`, `description.edit`. Without it: exit 9, `not-permitted`. Never ask the person to grant one for you
  unprompted; propose instead, and let them decide.

## Add or end a worker

```sh
doz worker add NAME --task "Review the fix" --request-id ID --json     # a started workspace only
doz worker end NAME WORKER --json
```

- Pass `--request-id ID` (one new id per worker you mean to add): retrying with the same id and arguments answers the
  first answer (`"replayed": true`) and adds no second worker.

- `worker add` is refused (exit 3) while the workspace is setting up: start it first, or declare the worker with
  `--worker` at `new`. `--dry-run --json` shows what it would be — or what would be refused — and adds nothing.
- A worker runs fenced on this Mac unless told otherwise: `--isolation vm` gives it a micro VM of its own.
- `worker end` ends it; its record (or its own sandbox) is kept unless `--rm`.

## Exit codes and errors

The exit codes are frozen: a code keeps its meaning, and a new outcome gets a new code. `doz help exit-codes --json`
prints the table (`{"kind":"ExitCodes","schema":1,"codes":[{"exit","name","meaning","errorCodes"}…]}`).

| exit | meaning |
|---|---|
| 0 | done |
| 1 | failed |
| 2 | not found — only that (or several match: the message lists them) |
| 3 | not possible now (the state is wrong, it changed since you looked, or a `--request-id` was used with other arguments) |
| 4 | already exists |
| 5 | not confirmed: it asks first and you passed no `--yes` |
| 6 | the daemon is unavailable (`doz doctor --json`) |
| 7 | not implemented yet |
| 8 | supported, but not with what was asked |
| 9 | not permitted (an agent's request) |
| 64 | usage: an unknown command or flag, a missing argument |
| 65 | an invalid document or value |
| 75 | partly done: `partial` says `done`, `remaining` and `retry` (the command that does the rest) |
| 124 | timed out |
| 125 | doz itself failed around a program (`exec`, `run`, `attach` otherwise exit with the program's own code) |

With `--json` a failure is `{"error":{"code":"not-found","message":"…","exit":2}}` on stdout: decide on `error.code`
and `error.exit`, show the person `error.message`. Fields are only ever added.

## Never wait on a prompt

- With `--json`, nothing asks: a command that would ask exits 5 (`needs-confirmation`) and does nothing.
- Exit 5 means the command needs the person's yes — stopping, finishing, archiving or deleting a workspace, for example. Ask the
  person; only once they have said yes, run it again with `--yes`. Use `--dry-run --json` first to show them what it
  would do.
- Never `doz attach`, and never `doz up` without `--detach`: they take over a terminal.

## What not to do

- **Never run an agent unfenced without the person.** `--isolation unfenced` and `--manager-isolation unfenced` run a
  program that acts as them, with their files, keys and logins. Only when they asked for it in so many words.
- **Never `doz create` when a workspace is meant.** `doz create` makes a single sandbox (a Linux VM), not a workspace.
  Use `doz workspace new`.
- Never `--yes` a delete, archive, finish or stop the person did not ask for; never widen a permission or network yourself —
  say what you need and why, and let them decide.
