# The run journal — journal/1

The contract every bring-your-own-process tool depends on: what a run's journal is, what an entry holds, who may write,
correct, read and follow it, and what Dozable guarantees. This is the format as built; the code's side (files, ops, the
gate) is in [workspaces.md](workspaces.md), "The run journal". Normative words: MUST, MUST NOT, SHOULD, MAY.

| Path | What |
|---|---|
| `Sources/DozableHost/RunJournal.swift` | the shapes (`JournalEntry`, `WorkspaceJournal`, `JournalEvidence`), `JournalLimits`, `JournalKinds` (journal-kinds/1), `JournalRefs`, `JournalCorrection`, `JournalSweep`, `JournalRead`, the store (`RunJournalStore`, `wseq`), `JournalFollower` |
| `Sources/DozableHost/HostCore+Journal.swift` | `workspace-journal`, `-journal-add` (staging, the commit), the follower's making, the archive's part |
| `Sources/DozableCLI/WorkspaceJournalCommands.swift` | `doz workspace journal`, `doz workspace wait` |
| `Tests/DozableCLITests/RunJournalTests.swift` | the rules, the store, the daemon end to end, the permissions, the archive |

## 1. What the journal is

- Each run of a workspace has **one journal**: an append-only, ordered list of entries.
- People and agents write entries; anything permitted reads, follows and waits on them.
- Dozable **records** entries and guarantees their order and integrity. It never enforces a process: which kinds to write,
  in what order and who reviews is the workspace's own.
- Entries are written only while their run is open: none open → exit 3, `no-open-run`; a run that closed while the entry
  was written → exit 3, `run-closed`. Every entry belongs to a run; there are no entries outside runs.
- At `finish` the journal and its evidence are frozen into the run's archive. A closed run's journal never changes.

## 2. An entry

```json
{
  "id": "2026-11-24-1#12",
  "seq": 12,
  "at": "2026-11-24T10:41:07.512Z",
  "by": "manager",
  "kind": "review",
  "text": "c2 not met: the hover test still flickers",
  "refs": ["seq:9", "msg:4413"],
  "data": { "criterion": "c2", "met": "no" },
  "evidence": [ { "ref": "file:shots/hover.png", "sha256": "…", "bytes": 48211, "stored": "evidence/3f2a…-hover.png" } ],
  "supersedes": 11
}
```

| Field | Set by | Rules |
|---|---|---|
| `id` | Dozable | `RUN#SEQ`; unique in the workspace forever |
| `seq` | Dozable | from 1 per run, +1 per entry, no gaps; it IS the order |
| `at` | Dozable | ISO 8601, UTC, milliseconds, at the append |
| `by` | Dozable | the caller's identity name, or `owner` — never from the request. No identity may be named `owner` (65) |
| `kind` | writer | required; `^[a-z][a-z0-9._-]{0,63}$` (section 4) |
| `text` | writer | optional, at most 64 KiB UTF-8; swept (section 8) |
| `refs` | writer | optional, at most 32 (section 5) |
| `data` | writer | optional JSON object, at most 64 KiB serialised; a known kind's documented fields are checked; swept |
| `evidence` | Dozable | `[{ref, sha256, bytes, copied?, stored?, swept?}]`, from `--attach` / `--attach-ref` only |
| `refDetails` | Dozable | `[{ref, present?, sha256?, verified?}]`: what Dozable found about a ref when it was written |
| `supersedes` | writer | optional, a `seq`: this entry corrects that one (section 3) |
| `swept` | Dozable | `true` when the sweep replaced a token in the text or data |
| `superseded_by` | computed | in a `WorkspaceJournal` answer only: the seq of the correction; never stored |

## 3. Append-only, and corrections

- An entry MUST NOT be edited or deleted once appended, by anyone, the owner included.
- A **correction** is a new entry with `supersedes: N`, N an earlier entry of the same run. Chains are allowed; the
  effective entry is the last in its chain. Readers SHOULD show the correction instead of the original and keep the
  original visible on request; gates read effective entries only.

| A write with `--supersedes N` | Result |
|---|---|
| N is missing, or not earlier than this entry | 65 |
| a different kind from entry N | 65 (the wrong shape, whoever sends it) |
| no write permission for that kind | 9, naming `journal.write:KIND` |
| the same `by` as entry N | appended |
| another identity holding `journal.supersede` | appended |
| another identity without it | 9, naming `journal.supersede` |
| the owner | appended (the owner is never gated) |

## 4. Kinds — journal-kinds/1

`kind` is any name of the pattern; Dozable never refuses an unknown kind. For a **known kind** it checks the documented
`data` fields that are present (extra fields allowed; a field is optional unless marked required):

| Kind | `data` |
|---|---|
| `note` | — |
| `task` | `identity` (string) |
| `claim` | `task` (string, an entry id) |
| `criterion` | `id` (**required**, string), `check` (string: a command for a playbook; Dozable never runs it) |
| `review` | `criterion` (string), `met` (`yes` \| `no` \| `partly`), `subject` (string: the commit or tree reviewed) |
| `finding` | `severity` (`low` \| `medium` \| `high`) |
| `outcome` | `value` (**required**, string; gates read `accepted`, `accepted-with-issues`, `rejected`) |
| `lesson` | `proposal` (string, a proposal id) |
| `gate` | written by Dozable only |
| `hook` | written by Dozable only |

`gate`, `hook` and every `dozable.` kind are reserved: 65 from anyone else, the owner included. The ten bare names are
frozen — a new known kind comes only as `dozable.KIND` — so a team's own kind (SHOULD be prefixed: `acme.deploy`) never
collides with a later known one. A known kind's `data` only ever gains optional fields within journal-kinds/1.

## 5. References and evidence

| Ref | Means | Checked and stored |
|---|---|---|
| `seq:N` | an earlier entry of this run | must exist (65) |
| `entry:RUN#SEQ` | an entry of another run | as text |
| `msg:SEQ` | a message in the run's room slice | must be inside the slice (65); as text (the message's sha256 is not recorded yet — see section 11) |
| `commit:SHA[@FOLDER]` | a commit in one of the run's folders | the id, plus `present` (the loose object exists in the folder's `.git/objects`) — read without git; packfiles are never parsed; nothing said for a short sha |
| `url:URL` | anything else | as text, `verified: false`; never fetched |

- **`--attach FILE`** (needs `evidence.attach`): FILE MUST be inside one of the workspace's folders, read through no link
  (`O_NOFOLLOW_ANY` below the folder; no `..`), a regular file of yours with one name; at most 10 MiB, and at most 200 MiB of
  copies per run (else 8 `limited`). It is swept, **copied** into the run's `evidence/` and hashed: `{ref: "file:PATH",
  sha256, bytes, stored}`, PATH relative to its folder. Later edits to the original never change the record.
- **`--attach-ref FILE`** (needs `evidence.attach`): the same file rules, hashed in place, not copied: `{ref, sha256, bytes,
  copied: false}` — for render outputs and screen captures too large to copy. The hash shows whether the file still matches.
- Evidence content follows `journal.read`: whoever may read the journal may read the evidence.

## 6. Commands

| Command | An agent needs | Answer |
|---|---|---|
| `doz workspace journal W [RUN] --json` | `journal.read` | `{kind: "WorkspaceJournal", schema: 1, format: "journal/1", workspace, run, open, entries}`; RUN the open run by default (else the last), or any run, archived ones included |
| `doz workspace journal W add KIND [TEXT] [--data JSON] [--ref R]… [--attach FILE]… [--attach-ref FILE]… [--supersedes N] --json` | `journal.write` or `journal.write:KIND`; `evidence.attach` to attach; `journal.supersede` to correct another's entry | the appended entry; 3 `no-open-run` / `run-closed` · 8 `limited` · 9 `not-permitted` naming the permission · 65 invalid |
| `doz workspace journal W --follow [--after-wseq N \| --after RUN#SEQ] [--until-finish] --json` | `journal.read` | an NDJSON stream (section 7); 3 `no-daemon` · 9 · 65 an unknown cursor |
| `doz workspace wait W --for journal.KIND [--after RUN#SEQ] [--timeout S] --json` | `journal.read` | the first matching entry; 124 on the timeout; 3 `no-daemon` · 9 · 65 an unknown `--after` |

- **`wait` is level-triggered.** With no `--after`, an effective entry of that kind already in the open run matches at once.
  With `--after`, only entries after that point (across later runs) match. A script can act, then wait, and never miss an
  entry written in between.
- **Reads never start a daemon.** `--follow` and `wait` without one exit 3, `no-daemon`, with the fix `doz daemon start`. A
  plain read reads what is stored.
- **An unknown cursor is an error** (65), never a silent replay from the start.

### Permissions

The owner is never gated. For an agent:

| Permission | Lets it | Default |
|---|---|---|
| `journal.read` | read, follow and wait on the journal and its evidence | **on** for an agent in its own workspace (agents there already read its room); a grant or a never withdraws it |
| `journal.write` | append entries of any kind except the reserved ones | off |
| `journal.write:KIND` | append entries of that kind only (`journal.write` answers for every kind) | off |
| `journal.supersede` | correct an entry written by someone else (same kind, with the write permission for it) | off |
| `evidence.attach` | use `--attach` and `--attach-ref` | off |

A workspace grants them by role — the `reviewer` role bundles `journal.write`, `evidence.attach` and `description.propose`
— or by permission: `doz grant AGENT journal.write:review=allow --in W`.

## 7. Following

`journal W --follow` is a **workspace follow**: one NDJSON stream for the whole workspace — the entries of every run, the
run boundaries and the workspace-level events — continuing from one run into the next. Each line is one JSON object with a
`type`; a reader MUST skip a type it does not know.

| Line | Shape | When |
|---|---|---|
| `hello` | `{type, format: "journal/1", workspace, run, after}` | always first; `run` the open run (or null), `after` the cursor it starts after |
| `entry` | `{type, wseq, run, entry: {…}}` | each entry, in order |
| `run` | `{type, wseq, event: "opened" \| "finished", run, at}` | at run boundaries |
| `workspace` | `{type, wseq, event, at, revision?, proposal?, decision?}` | `description.changed` (an addendum or an edit of the brief or its references; `revision` the description's), `proposal.made`, `proposal.decided` (`decision`: applied or declined) |
| `heartbeat` | `{type, at, after}` | after 30 s with nothing sent |
| `end` | `{type, reason, after}` | a clean close: `daemon-stopping`, or `run-finished` under `--until-finish` |
| `error` | `{type, code: "follow-lagged", after}` | reserved (see below) |

- **One cursor, `wseq`.** Every `entry`, `run` and `workspace` line carries `wseq`: one number per workspace, monotonic, no
  gaps, kept in the store, so it holds across runs and daemon restarts. Resume with `--after-wseq N` (0: from the start):
  everything after N, then live — nothing missed, nothing repeated. `--after RUN#SEQ` follows entries only, after that entry
  (`RUN#0`: from the run's start). Without a cursor the follow starts live. On `hello`, `heartbeat`, `end` and `error`,
  `after` is the follow's own cursor: the last `wseq` sent, or in an entries-only follow the last entry id.
- **A clean end versus a drop.** On a graceful close the stream sends `end`. A bare EOF always means "reconnect with the
  cursor you last saw".
- **A slow follower.** This build reads every line from the store at the follower's own pace: nothing is buffered for a
  follower and a writer never waits for a reader, so a follow is never `follow-lagged` (the line type is reserved for a
  later in-memory fan-out, which would buffer 1,000 live lines).
- `--follow` and `wait` speak only to the owner's socket; an agent (`--as`) follows under its own `journal.read`.

## 8. Storage, limits and privacy

- An open run's journal: `<store>/workspaces/<W>/runs/<RUN>/journal.jsonl`, 0600 in a 0700 folder, each line fsynced before
  the answer; copied evidence beside it in `evidence/`. The workspace's follow lines: `<store>/workspaces/<W>/follow.jsonl`.
- At `finish` both go into the run's archive (`journal.jsonl`, `evidence/…`), swept and hashed like everything in it; once
  the archive verifies, reads come from there. A journal outlives `delete` with its run's archive.
- Limits per run: 10,000 entries · `text` 64 KiB · `data` 64 KiB serialised · 32 refs · 16 files on one entry · copied
  evidence 10 MiB a file and 200 MiB a run. Past any → 8 `limited`, naming it.
- **No secret is stored.** Every entry's `text` and `data` pass the same sweep as exports and archives: a live chat token,
  found by its hash, is replaced with a marker naming its owner, never its value, and the entry says `"swept": true`. A
  copied file is swept as archives are (its `sha256` is the stored copy's, marked `swept`).

## 9. Versioning

- The format is `journal/1`, named in every `WorkspaceJournal` answer and in the stream's `hello`.
- Within journal/1: new optional fields, new line types and new known kinds (only as `dozable.KIND`).
- Anything a reader could misread is journal/2: a field's meaning changed, an order guarantee weakened, a field removed.

## 10. What it does not do, by design

It doesn't deliver tasks, post to the room, run `criterion.check` commands or decide anything — those belong to a process,
done by agents or followers. It doesn't mirror into the room (a follower may). It doesn't hold the work description: that is
the document's (`brief`, `brief.addenda`), and the follow only reports its changes.

## 11. Not yet

Parts of journal/1 this version does not do. A reader must not rely on them.

- `msg:SEQ` is checked against the run's room slice and stored as text; the message's **sha256 at write time is not
  recorded yet**, so a later reader cannot prove which message text the entry referred to.
- The per-workspace `limits:` setting that raises the evidence copy limits.
- `error follow-lagged` is never sent: a follower reads the stored journal at its own pace, so nothing is buffered for it
  and no writer waits. The line type stays reserved.
- The `process.applied` workspace line, which comes with the recommended processes.
