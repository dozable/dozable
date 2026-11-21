# The timeline: this Mac's history

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

Dozable's side of the timeline contract (version 1, vendored at its pin in `Tests/DozableCLITests/Fixtures/timeline`, `PIN`):
every record the daemon keeps, answered as one history — a catalogue, queries, a live feed — for the timeline view and
`doz timeline`. Everything stays on this Mac.

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/TimelineTypes.swift`, `TimelineSources.swift` | 747: the contract's documents as Codable types (custom Codable for an attr's value, a match, a metric, a view's range), scopes (`TimelineScope`), the one place forbidden attrs are refused (`TimelineAttrs`), the sources this Mac keeps and their kinds, attrs and sensitive attrs, the ported matcher (`TimelineMatcher`) |
| `Sources/DozableHost/MacDisplayName.swift` | the Mac's display name (`daemon.mac_name`, "this Mac"): the timeline's `host:` scope and SpaceState's `host` |
| `Sources/DozableHost/Metrics.swift` (migration 2), `TimelineRecords.swift`, `TimelineSampler.swift`; `Sources/DozableKit/ConnectionLog.swift` (`CredentialUse`) | the records the timeline added to `metrics.sqlite`: `host_events`, `egress`, `samples`, `key_use`; a daemon event's safe line (`HostEventSummary`); the resource sampler and the timeline's clock (`TimelineClock`) |
| `Sources/DozableHost/TimelineStore.swift`, `TimelineIndexer.swift`, `HostCore+Timeline.swift` | the derived store `<store>/timeline.sqlite` and the indexer that fills it; the daemon's start, pokes and timers; the ops and the live feed |
| `Sources/DozableHost/TimelineQuery.swift` | the query engine: the catalogue, a query compiled to SQL, bins in a time zone (`TimelineTime`), rollups, batches |
| `Sources/DozableHost/TimelineRetention.swift`, `TimelinePruner.swift` | the `timeline.<source>` settings and the pruner (14.5a's scope, below) |
| `Sources/DozableCLI/TimelineCommands.swift` | `doz timeline catalog · query · tail · retention · prune · rebuild` |
| `Tests/DozableCLITests/Timeline*.swift`, `JSONSchemaCheck.swift`; `Sources/doz-vmtest/CLITimelineSuite.swift` | `TimelineSchemaTests`, `TimelineMatchTests`, `TimelineRecordsTests`, `TimelineIndexerTests`, `TimelineQueryTests`, `TimelinePrunerTests`; `make test-cli-timeline`, `make test-cli-timeline-vm` |

## The records

The primary records are the sources of truth; the timeline adds four to `metrics.sqlite` (migration 2, additive — the
SandboxLab tables are unchanged):

- `host_events` — the daemon's own events of the kinds `phase`, `step`, `started`, `failed`, `note`, `host`. Never guest
  text (`progress`, `output`, `console`), a connection or a session's status. A step is its stable key
  (`MetricsStepKey`); a note's line has every path outside `~` as "a folder" and every host-like word as "a host"
  (`HostEventSummary`), ≤ 200 characters.
- `egress` — one row per closed connection, by its id (`uuid UNIQUE`): a host and port, the verdict, the rule, bytes,
  duration — never a method, path, query, header, detail or the credential's text. An allowed DNS lookup is counted, never
  kept. `recordNetwork` counts a connection in its minute only when its row is new, so a minute is never counted twice.
- `samples` — a running sandbox's CPU, memory and disk, one row per sandbox and minute.
- `key_use` — `ConnectionRecord.credentialUse` (`binding`, `via` ∈ injected · swapped · renewal · foreign · rejected ·
  refused · unavailable, `ok`), set beside each `credential =` in the proxy: a binding's name, never a value.

Sessions on this Mac get `sessions` rows (`sandbox = '@mac'`, the program's basename only).

**The sampler** (`ResourceSampler`): every `timeline.sample_seconds` (60; 10–3600; 0 off), each running sandbox that is
not busy: CPU = the VM helper's user + system time (`proc_pid_rusage`) over the wall time over the sandbox's CPUs;
memory = the helper's `ri_phys_footprint`, else the spec less what the balloon returned; disk = `allocatedBytes` of its
folder every 5 minutes. The helper — the `com.apple.Virtualization.VirtualMachine` process with exactly that sandbox's
root disk open (`proc_listallpids` + its open files) — is found once per boot, off the actor, and checked at each sample
with `proc_pidpath`. Never a guest command. Measured in `make test-cli-timeline-vm`: ~100 µs a sample, ~400 µs a
search; the row asserts < 2 ms.

## The derived store

`<store>/timeline.sqlite` (0600, WAL, its own connections; never a link — refused). Everything in it is made again from
the records; a Resources deletion of it, or `doz timeline rebuild --clean`, loses only the counts kept for time whose
records are gone.

- `events` — one row per event by its id, the scope host-relative (the `host:` segment is added when answered, so
  renaming the Mac relabels without rewriting), `sev` 0–4, the attrs, the sensitive attrs apart (`sattrs`), the links,
  `rev` (the order of changes) and `hay` (what free text searches: the summary, kind, source, full scope and the
  non-sensitive string attrs, lowercased, each apart). `events_fts` is a trigram FTS5 index over `hay`, by rowid.
- `scopes` (every ancestor, labels — a room's name for its `rm_` id —, `space`), `names` (renames: `renamed` lines),
  `rollups` (series × scope × bin × t: minutes from the records, hours and days written by retention), `ebins` (event
  counts by bin, kind and severity for time whose single events went), `cursors`, `kept` (each source's cut points and
  the newest `rev` retention removed), `meta`.

**Ids** (stable, never reused): `actions/<rowid>`, `sessions/<rowid>` (+ `/open`, `/end`), `daemon/<rowid>` (+ `/start`),
`daemon-events/<rowid>`, `egress/<rowid>`, `keys/<rowid>`, `workspace/<name>@<createdAt ms>/<byte offset>`,
`grants/_@<first line's ms>/<byte offset>`, `chat/<msg_id>`, `chat/<msg_id>/<recipient>/<state>`, `ask/#N`,
`runs/<workspace>/<run>` (+ `/open`, `/close`, `/<NNNNNN|last>`).

**Scopes**: a sandbox under the workspace that holds it now (`membership()`, cached), else under the host; a session
`…/session:<name>~<rowid>`; a room by its `rm_` id under its one live workspace, else the host; a run
`workspace:<w>/run:<id>`, `links.run` = `w/id`.

**The indexer** (`TimelineIndexer`, one serial utility queue — the daemon's actor only pokes): every source is read from
its cursor — metrics rows past the last rowid and every row still open; the network's recent minutes summed across
the daemon's runs; a log by its creation time, inode and byte offset (a removed-and-remade workspace starts again);
a room by its seq and times; a run's frames by name. So a write's poke (metrics writes, `WorkspaceStore.append`,
`write`, `create`, `GrantStore.append`, a frame — `TimelineSignal`), the start-up catch-up, the 30-second pass (chat,
frames), the hourly one and the first backfill are one path, and primary-first, derived-second loses nothing in a
crash. Upserts by id (a row unchanged is not rewritten): a rebuild gives the same ids and deletes nothing. A first
backfill (or a deleted file) indexes single events only inside each source's events retention, rollups over all
history, 10,000 rows per transaction; meanwhile results warn "indexing … %". An action or session left open by an
earlier daemon is closed at that daemon's end (the next run's start).

**Chat** is read only by the indexer, `mode=ro`, never selecting `content` or an Ask's question: ids, times, counts,
`json_extract(ask, '$.number')` and the decision's `by` and `option`. The owner's chat name is written `you`.

## Queries

`TimelineQueryEngine` answers from its own read-only connection, the same in the daemon and in-process (with no daemon a
look reads the file as it is, or an empty store). The parsed search compiles to SQL: text through the trigram index (and
`instr` on `hay`; under 3 characters `instr` alone), kind/source prefixes by `substr`, severity by rank, a scope from the
top as a range on the relative scope, by segments on `'/' || full scope || '/'`, links by column with the run rule, attrs
on `attrs` and `sattrs` (JSON types read as the contract's matcher reads them). `TimelineQueryTests` holds it to the
ported matcher on every vector of the contract against its week's recording.

Bins group by quarter hour (every zone's offset is whole quarters) and are placed in the query's zone (a day at local
midnight, `TimelineTime`); before a source's cut its event bins answer (only a search bins can answer: scope, source,
severity). Metrics: minutes where kept, then the stored hours (UTC) and days (the Mac's zone); another zone before the
minutes' cut is a warning. Sensitive attrs are returned only for an `attr.` search. Cursors are base64 `{t, id}`.

The live feed (`timeline-subscribe`, a stream like `events`): every second, the events and minute points with a `rev`
past the client's token, as a Batch with the new token; a token older than the newest `rev` retention removed ends it
with `{"reset": true}`.

The ops `timeline-catalog`, `-query`, `-subscribe`, `-retention`, `-rebuild` are Dozable's own (`ActionClasses`): an agent's
request is refused by the gate. `HostRequest.timeline` is decoded strictly (no unknown field) and is at most 256 KiB.

## Retention (14.5a)

One setting per kept source, `timeline.<source>` = `EVENTS/1M/1H/1D` in days or `kept` (0 refused; set in the file it is
the user's). **This step bounds only what the timeline added**: the derived store and the four new tables. No existing
`metrics.sqlite` row (`events`, `sessions`, `runs`, `network`), no workspace or grants log line, no chat message and no
frame is ever removed — `TimelinePrunerTests.testNoExistingRecordIsEverRemoved` and `make test-cli-timeline` T5 hold a
sentinel row of each table and a log line older than every cut. Pruning those (with their state settled first and an
upgrade hold) is a later step that waits for the owner.

`TimelinePruner` runs on the indexer's queue 5 minutes after the start, hourly, and soon after a retention changes. Per
source: counts first (event bins of exactly what goes; hours from minutes, days from hours), the cut recorded before
anything is deleted; then the single events (never an open span — the daemon's current run is one); then the source's
new primary rows; then each rollup level past its own days. Cuts are half-open at a local midnight, counted back from
the newest record or now, whichever is earlier (a clock behind or ahead removes nothing extra), 5,000 rows a
transaction; only the store's own regular files. Egress keeps at most 1,000,000 single connections. `doz timeline prune
--dry-run` says what each source would lose. The Resources metrics deletion clears their sources' history too
(`clearMetricsDerived`); `timeline.sqlite` is a Resources item of its own.

## Privacy, and what another computer gets

Sensitive attrs (`egress.dest` and `.rule`, a free-text `reason`, `actions.error`, `daemon.machine`) live in `sattrs`:
never in `hay`, a summary or a rollup (egress rollups are counts per sandbox). Forbidden attrs (`text`, `question`,
`command`, `url`, `path`, `headers`, …) are refused by `TimelineAttrs.Builder`. Nothing leaves the Mac: no sender reads
the files. Serving the timeline to another computer (`serve.timeline`) is a later step.
