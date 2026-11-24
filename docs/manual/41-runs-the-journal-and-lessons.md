# Runs, the journal and lessons

A **run** is one unit of work in a [workspace](37-workspaces.md), from its start to its finish: a goal, the agents
working on it, the conversation in its room, and a **journal** that records what was done. When a unit of work ends you
can draw a **lesson** from it, and once you approve it, every later unit of work carries it. Dozable records all of
this; it never decides what the entries mean or enforces a process. The process is yours: you write it in the brief
(see [Bring your own process](42-bring-your-own-process.md) for a worked example).

**On this page:** [Opening and finishing](#opening-and-finishing-a-unit-of-work) ·
[The journal](#the-journal) · [Kinds and their data](#kinds-and-their-data) ·
[Lessons](#lessons-and-the-work-description) · [What agents may write](#what-agents-may-write) ·
[How an agent writes the journal](#how-an-agent-writes-the-journal) · [Times](#times-utc-and-local)

## Opening and finishing a unit of work

The first `doz workspace start` opens the first run, with the brief as its goal; after a finish, `doz workspace run`
opens the next.

```bash
doz workspace run demo "Fix the failing test"   # a run with this goal
doz workspace run demo                          # a run whose goal is the brief
doz workspace run demo "Again" --follows 2026-11-23-1 --source run:2026-11-23-1
doz workspace run demo "Look first" --no-start  # open the run, start nothing
doz workspace runs demo                         # each run, its goal, its archive and its totals
doz workspace runs demo --archive RUN           # write a run's archive again
doz workspace finish demo                       # close the run and archive it (asks first; --yes in a script)
```

`run` posts the opening message in the workspace's room as your message — the brief, the lessons to apply, and this
run's goal when you gave one (below) — and then starts its agents as `doz workspace start` does; `--no-start` starts
nothing. A finished workspace is reopened first: its rooms open to new messages again. An archived one is refused (`doz
workspace restore` first).

**One run at a time.** While a run is open, `run` is refused — exit 3, `run-open`, with `doz workspace finish W` as the
fix. Finish it first.

**`reopen` opens a run too.** `doz workspace reopen W` is the old name of `run`: the same command (it prints a one-line
note on a terminal, never with `--json`). So a `run` straight after a `reopen` is refused with `run-open`: the reopen
already opened one. `--dry-run` still shows reopen's plan, and `--if-plan SHA` reopens on that plan as before, starting
nothing.

Each run records what it is for and where it came from: its **goal** (`goalFrom`: `given`, or `brief` when you gave none),
its **source** (`--source KIND` or `KIND:REF`: `given`, `brief`, `run:ID`, `ask:TEXT`, `schedule:TEXT`; another kind exits
65), the run it **follows** (`--follows RUN`, a run of this workspace, else 65), who opened it (`owner`, or an agent's
name), the **revision** of the brief it read (1 when the workspace was made, one more for each edit of the brief or its
references), and its length (`usage.durationMs`). `--json` answers `{"kind": "WorkspaceRun", "id", "state": "open",
"goal", "goalFrom", "source", "follows", "openedAt", "openedBy", "revision", "usage"}`, and `doz workspace runs W --json`
carries the same fields on each run — a run opened by an older version has only its length. `doz workspace state W
--json` says whether a run is open (`conditions.run`: `open`, `id`, `since`, and `state` `open` or `closed`).

`doz workspace up -f FILE` (a space file, [Space files](39-space-files.md)) opens a run each time it finds none open;
`up --no-run` sets everything up and starts its agents but opens no run — `doz workspace run W` opens one later (a space
with a scratch folder, which lives in a run, refuses it).

`doz workspace run` is not Docker Compose's `run`, which runs a one-off command in a service: here it opens a unit of
work.

**Finishing.** `doz workspace finish W` closes the run. It closes the workspace's own rooms to new messages — members can
still read them; the next `run` opens them again — and writes the run's evidence into Dozable's store: its messages, each
agent's conversations and last screen, its journal and the files attached to it, the usage and a timesheet. Nothing is
removed, and no program is run in your folders (commits are not collected). `--no-archive` writes none. What finish does
to each agent, and what it keeps, is on [Workspaces](37-workspaces.md#sleep-wake-finish-archive-and-delete).

## The journal

Each run has a **journal**: an append-only, ordered list of entries that you and the workspace's agents write as the work
goes — a task, a claim on it, a criterion, a review against it, a finding, the outcome. Dozable records each entry and its
order.

```bash
doz workspace journal demo add note "the build is green"                  # to the open run
doz workspace journal demo add review "c1 met" --data '{"criterion":"c1","met":"yes"}' --attach ~/src/demo/test.log
doz workspace journal demo add review "c1 not met after all" --data '{"criterion":"c1","met":"no"}' --supersedes 2
doz workspace journal demo                                                # the open run's entries (or: … demo RUN)
doz workspace journal demo --follow --json                                # one JSON line per event, as it happens
doz workspace wait demo --for journal.outcome --timeout 120               # until an outcome entry is written
```

- **Entries.** Dozable sets each entry's `id` (`RUN#SEQ`), `seq`, `at` and `by` (you are `owner`). A **kind** is any name
  of a–z 0–9 `.` `_` `-`; ten are known (below), and a known kind's `--data` fields are checked when present. Text and
  data pass the same leak sweep as exports: a chat token in them is replaced, and the entry says `"swept": true`. No agent
  may be named `owner`.
- **Corrections.** Nothing is edited. `--supersedes N` adds a correction of entry N: the same kind (another kind is exit
  65), by N's author — or by someone holding `journal.supersede`; you always may. The journal shows the original marked
  `superseded_by`.
- **Evidence.** `--attach FILE` copies a file from the run's folders into the run and records its hash, so a later edit
  never changes the record (10 MiB a file, 200 MiB a run, else exit 8). `--attach-ref FILE` records the hash of a large file
  without copying it (`"copied": false`). A file is read through no link and only from inside the workspace's folders.
  `--ref` points at another entry (`seq:N`, `entry:RUN#SEQ`), a message (`msg:SEQ`), a commit (`commit:SHA`, with whether
  its object is there) or an address (`url:…`, never fetched).
- **Only while a run is open.** With none open an entry is refused (exit 3, `no-open-run`); a finished run's journal never
  changes again. At finish the journal and its evidence go into the run's archive, and `doz workspace journal W RUN` still
  reads them.
- **Following.** `--follow` streams the workspace's lines: `hello` first, then each entry, each run opening and finishing,
  and the work description's changes and proposals, each with one cursor, `wseq` — resume with `--after-wseq N` and nothing
  is missed or repeated (`--after RUN#SEQ` for entries only; `--until-finish` ends at the run's finish). A clean close sends
  `end`; anything else means "reconnect". **`wait`** is level-triggered: an entry already written matches at once, and with
  `--after RUN#SEQ` only a later one does; it exits 124 on `--timeout`. Both need the daemon running and never start it
  (exit 3, `no-daemon` — `doz daemon start`).
- **Limits per run:** 10,000 entries; an entry's text and its data 64 KiB each; 32 references and 16 files on one entry.
  Past one, the entry is refused (exit 8), naming it.

## Kinds and their data

Any kind of your own is allowed; prefix it with your team's name (`acme.deploy`) so a kind Dozable adds later never
collides with it. The known kinds, and the `--data` fields Dozable checks when they are present (extra fields are kept):

| kind | what it records | `--data` |
|---|---|---|
| `note` | anything worth keeping | — |
| `task` | a piece of the work | `identity` (who it is for) |
| `claim` | someone takes a task | `task` (the task entry's id, `RUN#SEQ`) |
| `criterion` | what "done" means | `id` — **required**: `{"id":"c1"}`; `check` (a command for a process to run; Dozable never runs it) |
| `review` | a check against a criterion | `criterion` (its id), `met` (`yes`, `no` or `partly`), `subject` (the commit or tree reviewed) |
| `finding` | a problem found | `severity` (`low`, `medium` or `high`) |
| `outcome` | how the unit of work ended | `value` — **required**: `{"value":"accepted"}` (`accepted`, `accepted-with-issues` and `rejected` are the usual three) |
| `lesson` | a lesson drawn | `proposal` (a proposal's id) |
| `gate`, `hook` | Dozable's own | written by Dozable only |

`gate`, `hook` and every `dozable.` kind are written by Dozable only: anyone else, you included, is refused (exit 65). An
`outcome` or a `criterion` without its required field is refused (exit 65), saying which.

## Lessons and the work description

A workspace's **work description** is its brief plus its **addenda**: notes and lessons added after the brief without
rewriting it. **Every run carries the lessons**: its opening message in the room is the brief, then **Lessons to apply:**
with every accepted addendum (`- TEXT (from run R)`), then — when you gave the run a goal of its own — **This run's goal:
GOAL**. So a lesson learnt in one run is part of every later one, with or without a goal (`doz workspace run --json` says
how many it carried: `lessons`). `doz workspace doc W --json` shows them as `document.brief.addenda` — each `{run, at, by,
text}`.

```bash
doz workspace retro demo --propose --addendum "Run the linter before the tests"   # propose a lesson from the last run
doz workspace retro demo 2026-11-23-2 --propose --addendum "…"                   # …from that run
doz workspace proposals demo                       # every proposal: open, applied or declined
doz workspace decide demo pr-1a2b3c4d apply        # or decline
doz workspace edit demo --addendum "Keep the changelog" [--run RUN]   # add one directly: no proposal, no Ask
```

A **proposal** changes nothing until it is decided. Dozable asks you in the workspace's room — "Apply this lesson to the
work description of demo?" — even when the workspace is finished and its room closed. Answer **Apply** or decline there, in
the dashboard, with `doz chat decide`, or with `doz workspace decide`. Applied, the lesson becomes an addendum (from its
run, by whoever proposed it); declined, or left until the Ask expires, nothing changes. A proposal is decided once: deciding
it again exits 3 (`proposal-decided`). `--json` answers `{"kind": "WorkspaceProposal", "id", "origin": "retro", "state",
"change": {"addendum"}, "by", "at", "source": {"run"}}`; `proposals --json` is `{"kind": "WorkspaceProposals", "proposals"}`.

## What agents may write

You are never asked for permission. An agent is, and what it may do here comes from its **permissions**
([What agents may do](37-workspaces.md#what-agents-may-do)):

- **Reading** its own workspace's journal is on by default (`journal.read`); you can withdraw it:
  `doz grant AGENT journal.read=never --in W`.
- **Writing** an entry needs `journal.write` (or `journal.write:KIND` for one kind only), attaching a file
  `evidence.attach`, and correcting another's entry `journal.supersede`.
- **Lessons:** `description.propose` (proposing one), `description.decide` (deciding one — its own proposals too) and
  `description.edit` (adding an addendum directly).
- **Units of work:** opening one needs `run.open` (`run` and `reopen`), finishing one `run.finish`.

Apart from reading, none of these is allowed for an agent until you grant it: the roles a workspace gives its manager and
its workers do not allow them, and for an agent an answer of ask is still a refusal (exit 9, `not-permitted`, naming the
permission). The `trusted-manager` preset allows `run.finish`. The **reviewer** role gives
`journal.write`, `evidence.attach` and `description.propose`, the usual three:

```bash
doz grant bot1 reviewer --in demo                     # it may write the journal, attach evidence and propose lessons
doz grant mira description.decide=allow --in demo     # mira may also decide them
doz grant mira run.open=allow --in demo               # it may open the next unit of work
```

These are enforced today, because an agent reaches Dozable only here: through the journal and the work description. The
other permissions are shown (`doz permissions show`, the dashboard's Can do tab) but not yet enforced — see [What agents
may do](37-workspaces.md#what-agents-may-do). An unfenced agent acts as you: it has `doz` and is held by none of this.

A space file can ask for these in its own config — `x-dozable: {permissions: {helper: [reviewer, description.decide]}}` —
and `doz workspace plan` shows each as a request ("Requested, not granted"): the file never grants anything; you grant with
`doz grant`.

## How an agent writes the journal

An agent in a workspace — its manager, a worker, an adopted agent — has no `doz`: it writes and reads the journal, and
proposes lessons, with `dozchat` and its own chat token. Every agent Dozable starts has both, and this store's chat
address (`CHAT_URL`); an adopted agent gets them in each session Dozable starts in its place after the adoption
([Tokens and identity](43-tokens-and-identity.md)). Dozable knows who it is from the token, and decides by the same
permissions as above.

```bash
dozchat journal --json                                        # the open run's entries
dozchat journal add review "c1 met" --data '{"criterion":"c1","met":"yes"}' --attach /workspace/test.log
dozchat journal add outcome "accepted" --data '{"value":"accepted"}'
dozchat journal wait outcome --timeout 300                    # until an outcome entry is there (exit 124 at the timeout)
dozchat propose --addendum "Run the linter before the tests"  # a lesson: you decide it in the room's Ask
dozchat proposal decide pr-1a2b3c4d apply                     # needs description.decide
dozchat addendum "Keep the changelog current"                 # needs description.edit
```

An entry's `by` is the agent's name. A file to attach is named as the agent sees it — in a sandbox, a path inside a folder
the workspace mounts there — and is copied from that folder on this Mac; a path in no such folder is refused. An agent of
several workspaces names one with `--in W`. `dozchat`'s exit codes: 0 done; 2 usage; 3 refused — no open run, the run
closed, or a value refused; 4 not permitted (the permission is named) or the proposal decided already; 5 no answer from
the chat server; 124 a wait's timeout. With `--json` a refusal is `{"error":{"code","message","permission"}}` on stdout. A
chat participant that is no agent of a workspace is refused, and so is your own token: you use `doz`.

## Times: UTC and local

A journal entry's `at` — and every time in `--json`, `--follow` and a run's archive — is UTC, written as ISO 8601 with a
`Z` (`2026-11-24T03:12:09Z`). `doz workspace runs` prints its STARTED and ENDED columns in this Mac's local time, so the
two differ by your time zone.

## See also

- [Workspaces](37-workspaces.md) — the workspace, its lifecycle and what agents may do
- [Bring your own process](42-bring-your-own-process.md) — a worked example, three units of work
- [Chat](36-chat.md) — rooms and Asks
- [History and retention](40-history-and-retention.md) — `doz timeline` shows runs beside everything else
