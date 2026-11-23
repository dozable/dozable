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
`chat.rooms`, `persist`, `archive`, …), space/3.1's first-class keys and the held ones under `x-dozable` (below). Always a
**lifetime**: every document Dozable writes is `doz: space/3.1` and carries `x-dozable.lifetime` (the lifetime is not a
3.1 key — below).

Never: a secret's value (a reference only), a token or a fingerprint, a grant (a record's `permissions` stay out), the
phase or any time (`flags`, runs, "running"), a run's scratch path. `doz workspace doc` and its `--write` follow this;
`WorkspaceDocumentTests.testNoSecretValueOrTokenInADocument` and `make test-cli-workspace` D3–D4 pin it.

## Lifetime

`standing | runs` — the default lifetime of what a workspace owns. **standing**: everything owned persists, scratch
folders included; finish removes nothing. **runs**: the space file's run model (owned things last one run unless
`persist:` keeps them). A record workspace (`new`, the wizard) is `standing`. A space file with no lifetime is read as
`runs` (today's meaning); `doc` prints and writes `x-dozable: { lifetime: runs }` for it. A written document always says
it, under `x-dozable` in either version; no file needs it. A top-level `lifetime:` is not a key of space/3 or 3.1 (in a
3.1 file it is refused with the fix: write it under `x-dozable`). Persistence gets its own key in a later version.

The lifetime is recorded at `up` and acted on since 0.52.36 (756): `down` ≡ `finish`, a standing workspace's finish
removes nothing it owns but what says `lifetime: run` itself, and its scratch folders are kept (workspaces.md, "The
lifecycle"). Since 0.52.43 (762) `plan -f` / `up` read it too — a standing file's plan says what `down` keeps, never
that it removes everything — and `show --json` / `ls --json` carry it as `lifetime` (`runs` or `standing`; a workspace
made without a space file is `standing`).

## The record → document mapping (`RecordDocument.generate`)

Pure, in DozableHost; it produces the ordered merged JSON the daemon already handles (no YAML in the daemon — the CLI's
`SpaceYAML` renders the text for `--write`).

| record | document |
|---|---|
| the name | `space:` (and the main room's key) |
| the person in chat | `owner:` (`you` while chat has no one) |
| — | `doz: space/3.1`, `x-dozable.lifetime: standing` |
| `brief.md` + `brief.refs` | `brief: {text, refs}` |
| `defaults.network` (a preset) | `network:` |
| `defaults.isolation` fenced / vm | `agent_defaults.isolation: fenced` / `agent_defaults.x-dozable.isolation: vm` (held) |
| each folder | `folders.NAME: {external: PATH, access: ro?}`; the main one `main: true` |
| the manager (a bot) | `agents.NAME: {external: {bot: B}, role: manager}` (its isolation: a note — not carried yet) |
| a worker from a bot | `agents.NAME: {external: {bot: B}, role: worker}` (its task: a note) |
| an anonymous worker | owned: `{kind: claude-code, role: worker, isolation: fenced/unfenced, folder: MAIN, prompt: TASK}` |
| a worker in a micro VM | owned: `{…, where: sandbox:S}` and `sandboxes.S: {}` |
| a declared worker (`new --worker`) | owned: `{kind, role: worker, prompt: TASK, folder: MAIN}` |
| an adopted `@mac` session | `agents.NAME: {external: {session: S}}` |
| an adopted sandbox | `agents.NAME: {external: {sandbox: S}}` |
| an agent elsewhere, an ended worker | left out (elsewhere: a note) |
| the main room, owned | `chat.rooms.W: {main: true}` |
| a room it linked | `chat.rooms.NAME: {external: doz://HOST/OWNER/room/R, main?}` — OWNER the workspace whose log says it made the room, else `_` (the shared-room rule) |
| a room gone for good; no room | left out; no `chat:` at all (a workspace with no room is valid) |
| grants, the phase, runs, times, fingerprints | never |

Names follow the format's rule (`[a-z][a-z0-9-]*`), one namespace across every section; a clash takes `-<kind>`, then a
number (a folder `~/work/app` in workspace `app` is `app-folder`: the main room holds `app`); a renamed one is a note.

A **space-file workspace**'s document is the spec its last `up` recorded (`space.json`: the file as the resolver merged it
— `extends:`, the override, `${VAR}`), in its 3.1 form (`SpaceDozable.lift`: the version line `space/3.1`, each
`x-dozable` spelling of a first-class key lifted to its place, a top-level `title:` moved into `about.title`; the rest —
the lifetime among them — as they are), with the record's **extras** merged in: each agent the
record holds (not ended) that the file names nowhere — by its name, bot, session or sandbox — mapped as above and added
under `agents` (a note each). Its lifetime is the file's, `runs` when it says none. A space recorded by an older doz
(no `space.json`) is generated from its record, with a note.

`generate` → validate passes for every record shape (`WorkspaceDocumentTests.testEveryRecordFixtureGeneratesAValidDocument`).
That the plan of a generated document against its own record is EMPTY — the zero-change gate — is a later stage.

## The space/3.1 keys

`doz: space/3.1` (the owner's go, 2026-11-23, cut to the model-neutral keys by model v3's option A the same day) is
space/3 with Dozable's model-neutral keys first-class; persistence (the lifetime) is not in 3.1. 755 accepted them only under
`x-dozable`, one rule for all: **the 3.1 key, unchanged in name and shape, one level down inside an `x-dozable` map at the
place 3.1 puts it** — so the 3.1 form is the key lifted out of its map. ONE table says which are first-class at each place
(`SpaceDozable.Place.firstClass`); the others are **held** (their design is open with the format's author) and stay
`x-dozable`-only, in either version, until it is settled. Moving a held key first-class is moving it in that table: the
validator checks a key by place and name whichever form it is in (`Schema.dozValue`), every reader asks
`SpaceDozable.member(_:_:at:)`, and `SpaceDozable.lift` writes the 3.1 form.

| where | first-class in 3.1 | held: `x-dozable` only |
|---|---|---|
| top level | `brief:` a path, `{text}` or `{file}` with `refs:`, `about: {title, summary, description, icon, tags, category, needs}` (`about.title` in place of the top-level `title:`), `layout: {…}` (never acted on), `network: locked\|standard\|open` or `{preset, allow: [HOST…]}` | `lifetime: standing\|runs` (never required) |
| a folder | `main: true` (at most one) | `lifetime: run` |
| an agent | `restart: no\|on-failure`, `network:`, `external: {sandbox: NAME}` | `lifetime: run` |
| a room, a sandbox | — | `lifetime: run` |
| `agent_defaults` | `where: sandbox` (the workspace's own VM: `mac` and `sandbox` are the keywords, `sandbox:NAME` a declared sandbox) | `isolation: fenced\|vm` (where a record's new workers run; `vm` gets a note naming `where: sandbox`) |

Rules (`SpaceValidator` + `SpaceDozable.swift`):

- The version line: `space/3` or `space/3.1` (a defaults file: `space-defaults/3` or `space-defaults/3.1`, which holds what a
  space-defaults/3 one does — never `lifetime`, `brief`, `about` or `layout`, which describe the space itself).
- No file needs a lifetime. A top-level `lifetime:` in a 3.1 file → 65 `"lifetime" is not a space/3.1 key: it stays under
  x-dozable`, the fix as the hint; in a space/3 file it is "unknown key" with its old hint, as before.
- A top-level `title:` in a 3.1 file still reads, with a note naming `about.title`; with `about.title` too → 65.
- A first-class key in a `doz: space/3` file whose value 3.1 would take is refused (65) with the fix in its message:
  `"brief" is a space/3.1 key: change the version line to doz: space/3.1` (an agent's `external: {sandbox}` likewise). A
  value 3.1 would refuse too stays "unknown key" with its old hint. A plain space/3 file reads exactly as before.
- The `x-dozable` form of a first-class key is still read for one release, in either version; each use is a note naming the
  3.1 key (`SpaceDozable.deprecatedUses`, in the plan's and up's notes and `--json` `notes`). `x-dozable.lifetime` is no
  such use and gets no note: the lifetime is not a 3.1 key. Both forms of one key → 65 (`"main" is written twice: …`; the brief
  keeps its own words: `the brief is written twice: brief: and x-dozable.brief`; an agent's external its own).
- `x-dozable` is checked strictly: an unknown key in it is an error with a suggestion. Every other `x-` key is still
  ignored, as space/3 says.
- A brief held in the document (`brief: {text}`, or `x-dozable.brief`): the workspace's brief: `up` keeps it in the store's
  `brief.md` (a brief FILE is still never copied) and posts it; `show --brief` reads it; an up after the text changed
  updates it. `brief: {text, file}` or neither → 65.
- `about` is strict; `params:` belongs to a template's envelope and is refused in a stored document.
- `external: {sandbox: NAME}` (or `x-dozable.external.sandbox`): the agent is external (adopted at `up`, never started,
  never stopped by `down`); it may not say what an external agent may not (`kind`, `where`, …), may not be written in both
  forms, and may not name a sandbox the file declares under `sandboxes:`.
- `agent_defaults.where: sandbox` (3.1 only; in space/3 → 65 `"where" is a space/3.1 key: …`, on an agent → `"sandbox" is
  not a place`): every owned agent that does not say where runs in the workspace's own VM, an owned sandbox of the run named
  `<space>-vm` (`SpaceModel.workspaceVM`, unique among the file's names), made by the first agent in it (`isolation: vm`).
- An agent's own `network`: an unfenced agent has none (65 at `/agents/NAME/network`); an agent in a VM — the workspace's or
  an owned sandbox — may only repeat the workspace's network (standard when the file says none; a name and its
  `{preset}` map are the same), else 65 at `/agents/NAME/network`. An existing sandbox (`external:`) keeps its own.
- `external: {sandbox}` with `restart` → 65 at `/agents/NAME/restart`. An empty `brief.refs`, `about.tags` or
  `network.allow` → 65 (`… can't be empty`). A per-resource `lifetime:` in a 3.1 file gets the lifetime's own words.
- A space/3 file extends only `space-defaults/3` files: a `space-defaults/3.1` one → 65 at its `/doz`.
- At most one folder with `main` (either form).
- `restart` is recorded and noted, not applied yet; `network`, `about`, `layout` and the per-resource `lifetime: run` are
  checked and kept, not acted on yet. The meaning of no space/3 key changes.
- Vectors: the reference's rows (vendored, read-only) and Dozable's own `Fixtures/space31/validation-errors-3.1.json`,
  through the same harness (`SpaceValidationTableTests`); `Space31Tests`.

## `doz workspace doc`

`workspace-doc` (read-only, `workspace.read` for an agent; in-process with no daemon) answers `WorkspaceDocumentAnswer
{workspace, from: record|space-file, document (ordered JSON text), notes}`; the CLI prints `{kind: "Document", schema: 1,
workspace, from, document, notes?}`. In the `--json` view `document.x-dozable.lifetime` is ALWAYS present (never a
top-level `document.lifetime`) and
`document.doz` is `space/3.1`; the YAML text and `--write` hold the same document (`RecordDocument.fileForm`), which
validates as space/3.1. `--write FILE` (`SpaceRecordFile.writeNew`): `~` is the
space file's home (`TestSafety.spaceHome`), the place rules of a recorded file (under the home, never the store,
`~/.claude` or `~/Library`; no link in the path), temp-and-rename, never over an existing file without `--force`
(`RENAME_EXCL`). Exits: 2 no workspace, 4 `already-exists`, 65 `invalid-value`.

## Test homes

In a guarded run (`DOZ_TEST_GUARD=1`) `DOZ_TEST_HOME` stands for `~` in a space file (its folders, brief, `extends:`,
`prompt_file`), in `--folder ~/…`, in `doc --write ~/…`, and as the home the recorded files must be under (after the older
`DOZ_TEST_BRIEF_HOME`). Unguarded it is always the real home. `TestSafetyTests.testASpaceFilesHome`, `make
test-cli-workspace` D1–D2.
