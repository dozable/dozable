# The workspace model — one document, a record, one controller

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md), the workspace code in
[workspaces.md](workspaces.md). This page is the model every workspace change is judged against. It is short on purpose.

## What a workspace is

**A workspace is one document plus what is true now.**

| | is | lives in | written by |
|---|---|---|---|
| the **document** (spec) | what should exist: name, brief, `lifetime`, defaults, folders, agents, rooms, sandboxes, secret *references*, *requests* | generated today (`RecordDocument`); a revision store later | the daemon only, through one pipeline (later stages) |
| the **record** (status) | runtime facts: places, the phase, runs, the log, the brief's hash | `<store>/workspaces/W/` (`workspace.json`, `log.jsonl`, `brief.md`) | the daemon only |
| the **controller** | turns document + phase + facts into a plan, the plan into actions | the daemon (`HostCore`) | — |

There is **one kind of workspace**. Store-held or kept in a file, standing or run-based: values, never kinds.

## The nouns

| noun | is | in the document? |
|---|---|---|
| workspace | the project: name, title, brief, `lifetime`, defaults, labels, `about` | yes |
| agent | a manager, worker or reviewer — **owned** (Dozable starts it) or **external** (`{bot}`, `{session}`, a sandbox) | yes |
| room | owned, or external (`doz://HOST/OWNER/room/NAME`, `_` for no owner) | yes |
| folder | an external path (`rw`/`ro`, at most one **main**), or an owned scratch folder | yes |
| sandbox | an owned micro VM, or one that exists already | yes |
| secret | a **reference** (`{keychain: ITEM}`, `{file: PATH}`) and where it may go (`to:`) | the reference only |
| grant | a role or permission in a scope | **never** — the document only *requests* |
| phase | setting up, running, asleep, stopped, finished, archived | **never** |
| run | one start…finish cycle | never (the record's, read-only) |

## Invariants

1. One kind of workspace.
2. One writer: only the daemon writes the record (and, later, the document), only through its own operations.
3. Spec, status and phase apart: a sleep is never a change of the document.
4. The file asks, the owner grants: a document never holds a grant, only requests.
5. Nothing moves by itself: the controller acts on a change or a verb; drift is shown, never fixed by itself.
6. Only what it owns: externals are never made or removed; owned things go only after their evidence is archived.
7. Idempotent: `--if-plan`, `--request-id`; the same plan twice does nothing the second time.
8. Secrets by reference only: no value in a document, an answer or a log — ever.

## What a document holds, and never holds

Holds: the space/3 keys (`doz`, `space`, `owner`, `brief`, `agent_defaults`, `folders`, `agents`, `sandboxes`, `secrets`,
`chat.rooms`, `persist`, `archive`, …) and Dozable's additions under `x-dozable` (below). Always a **lifetime**: every
document Dozable writes carries it (`x-dozable.lifetime` today).

Never: a secret's value (a reference only), a token or a fingerprint, a grant (a record's `permissions` stay out), the
phase or any time (`flags`, runs, "running"), a run's scratch path. `doz workspace doc` and its `--write` follow this;
`WorkspaceDocumentTests.testNoSecretValueOrTokenInADocument` and `make test-cli-workspace` D3–D4 pin it.

## Lifetime

`standing | runs` — the default lifetime of what a workspace owns. **standing**: everything owned persists, scratch
folders included; finish removes nothing. **runs**: the space file's run model (owned things last one run unless
`persist:` keeps them). A record workspace (`new`, the wizard) is `standing`. A space file with no lifetime is read as
`runs` (today's meaning); `doc` prints `lifetime: runs` for it and writes `x-dozable.lifetime: runs` with `--write`. A
written document always says it; an existing file without it is not refused yet (that comes with space/3.1).

Today the lifetime is recorded and shown; the lifecycle verbs that act on it (`down` ≡ `finish`, scratch kept when
standing) are a later stage.

## The record → document mapping (`RecordDocument.generate`)

Pure, in DozableHost; it produces the ordered merged JSON the daemon already handles (no YAML in the daemon — the CLI's
`SpaceYAML` renders the text for `--write`).

| record | document |
|---|---|
| the name | `space:` (and the main room's key) |
| the person in chat | `owner:` (`you` while chat has no one) |
| — | `x-dozable.lifetime: standing` |
| `brief.md` + `brief.refs` | `x-dozable.brief: {text, refs}` |
| `defaults.network` (a preset) | `x-dozable.network` |
| `defaults.isolation` fenced / vm | `agent_defaults.isolation: fenced` / `agent_defaults.x-dozable.isolation: vm` |
| each folder | `folders.NAME: {external: PATH, access: ro?}`; the main one `x-dozable: {main: true}` |
| the manager (a bot) | `agents.NAME: {external: {bot: B}, role: manager}` (its isolation: a note — not carried yet) |
| a worker from a bot | `agents.NAME: {external: {bot: B}, role: worker}` (its task: a note) |
| an anonymous worker | owned: `{kind: claude-code, role: worker, isolation: fenced/unfenced, folder: MAIN, prompt: TASK}` |
| a worker in a micro VM | owned: `{…, where: sandbox:S}` and `sandboxes.S: {}` |
| a declared worker (`new --worker`) | owned: `{kind, role: worker, prompt: TASK, folder: MAIN}` |
| an adopted `@mac` session | `agents.NAME: {external: {session: S}}` |
| an adopted sandbox | `agents.NAME: {x-dozable: {external: {sandbox: S}}}` |
| an agent elsewhere, an ended worker | left out (elsewhere: a note) |
| the main room, owned | `chat.rooms.W: {main: true}` |
| a room it linked | `chat.rooms.NAME: {external: doz://HOST/OWNER/room/R, main?}` — OWNER the workspace whose log says it made the room, else `_` (the shared-room rule) |
| a room gone for good; no room | left out; no `chat:` at all (a workspace with no room is valid) |
| grants, the phase, runs, times, fingerprints | never |

Names follow the format's rule (`[a-z][a-z0-9-]*`), one namespace across every section; a clash takes `-<kind>`, then a
number (a folder `~/work/app` in workspace `app` is `app-folder`: the main room holds `app`); a renamed one is a note.

A **space-file workspace**'s document is the spec its last `up` recorded (`space.json`: the file as the resolver merged it
— `extends:`, the override, `${VAR}`), its own keys as they are, with the record's **extras** merged in: each agent the
record holds (not ended) that the file names nowhere — by its name, bot, session or sandbox — mapped as above and added
under `agents` (a note each). Its lifetime is the file's, `runs` when it says none. A space recorded by an older doz
(no `space.json`) is generated from its record, with a note.

`generate` → validate passes for every record shape (`WorkspaceDocumentTests.testEveryRecordFixtureGeneratesAValidDocument`).
That the plan of a generated document against its own record is EMPTY — the zero-change gate — is a later stage.

## The x-dozable keys

Until the owner's go on space/3.1, the 3.1 keys are accepted ONLY under `x-dozable`. One rule spells all of them: **the
3.1 key, unchanged in name and shape, one level down inside an `x-dozable` map at the place 3.1 puts it** — so making them
first-class is a mechanical rename (lift each key out of its `x-dozable`).

| where | `x-dozable` holds | 3.1 spelling |
|---|---|---|
| top level | `lifetime: standing\|runs` | `lifetime:` |
| top level | `brief: {text: …}` or `{file: PATH}`, with `refs: [...]` | `brief: {text}` / `{file}` |
| top level | `network: locked\|standard\|open` or `{preset, allow: [HOST…]}` | `network:` |
| top level | `about: {title, summary, description, icon, tags, category, needs}` | `about:` |
| top level | `layout: {…}` (never acted on) | `layout:` |
| a folder | `main: true` (at most one), `lifetime: run` | `main:`, `lifetime:` |
| an agent | `restart: no\|on-failure`, `network:`, `external: {sandbox: NAME}`, `lifetime: run` | the same, on the agent |
| a room, a sandbox | `lifetime: run` | `lifetime:` |
| `agent_defaults` | `isolation: fenced\|vm` (where a record's new workers run; no 3.1 key yet) | — |

Rules (`SpaceValidator` + `SpaceDozable.swift`):

- `x-dozable` is checked strictly: an unknown key in it is an error with a suggestion. Every other `x-` key is still
  ignored, as space/3 says.
- `x-dozable.brief` present: the top-level `brief:` is no longer required; both given is an error naming both (65). The
  held text is the workspace's brief: `up` keeps it in the store's `brief.md` (a brief FILE is still never copied) and
  posts it; `show --brief` reads it; an up after the text changed updates it.
- `x-dozable.external.sandbox`: the agent is external (adopted at `up`, never started, never stopped by `down`); it may
  not say what an external agent may not (`kind`, `where`, …), may not also have `external:`, and may not name a
  sandbox the file declares under `sandboxes:`.
- At most one folder with `main: true`.
- `restart` is recorded and noted, not applied yet; `network`, `about`, `layout` and the per-resource `lifetime: run` are
  checked and kept, not acted on yet. The meaning of no space/3 key changes.

## `doz workspace doc`

`workspace-doc` (read-only, `workspace.read` for an agent; in-process with no daemon) answers `WorkspaceDocumentAnswer
{workspace, from: record|space-file, document (ordered JSON text), notes}`; the CLI prints `{kind: "Document", schema: 1,
workspace, from, document, notes?}`. In the `--json` view `document.lifetime` is ALWAYS present at the top (the 3.1
spelling, `RecordDocument.view`); the YAML text and `--write` hold the file form (`RecordDocument.fileForm`: the lifetime
only under `x-dozable`, so the file validates as space/3 today). `--write FILE` (`SpaceRecordFile.writeNew`): `~` is the
space file's home (`TestSafety.spaceHome`), the place rules of a recorded file (under the home, never the store,
`~/.claude` or `~/Library`; no link in the path), temp-and-rename, never over an existing file without `--force`
(`RENAME_EXCL`). Exits: 2 no workspace, 4 `already-exists`, 65 `invalid-value`.

## Test homes

In a guarded run (`DOZ_TEST_GUARD=1`) `DOZ_TEST_HOME` stands for `~` in a space file (its folders, brief, `extends:`,
`prompt_file`), in `--folder ~/…`, in `doc --write ~/…`, and as the home the recorded files must be under (after the older
`DOZ_TEST_BRIEF_HOME`). Unguarded it is always the real home. `TestSafetyTests.testASpaceFilesHome`, `make
test-cli-workspace` D1–D2.
