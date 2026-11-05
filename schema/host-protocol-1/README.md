# The host protocol, version 1 — golden fixtures

The `doz` host serves one Unix socket per store, `<store>/host.sock`, speaking JSON lines (see the top of
`Sources/DozableHost/HostProtocol.swift`). These files are the contract between that host and any client: what a
client sends and what it reads, byte for byte.

**Every file here except this README is GENERATED** by `Tests/DozableCLITests/HostProtocolFixtureTests.swift` — by the
host's own encoder (`HostWire.encoder`) from its own types, and for `ping`, `ls`, `inspect`, `create`, `rename` and the
`not-found`, `version` and `unavailable` errors from a real in-process host over a scratch store. `make test` regenerates
them in memory and fails on any difference, so they cannot drift from the host. After a protocol change:

```bash
make protocol-fixtures        # writes them; review the diff and commit it with the change
make contract-check CLIENT=<path to a client package>   # runs that client's tests with DOZ_PROTOCOL_FIXTURES=<this directory>
```

## What is here

| Path | What it is |
|---|---|
| `MANIFEST.json` | `protocol`, the `dozable` version that last wrote the files (the one value the drift check ignores), and every generated file's sha256 |
| `ops.json` | Every op the host serves (`name`), its `tier`, how its answer is carried (`stream`, and `streamWhen`: the request field that makes it a stream), `readOnly` (answered from the store with no host running) and `answeredWithoutHost`; every event kind (and which are opt-in); every error code |
| `requests/<op>.<case>.json` | One request line, as the host's encoder writes it (sorted keys, `v: 1`) |
| `answers/<op>.<case>.jsonl` | The exact lines a client reads for that request: `event` lines, then the one line with `ok` set |
| `events/<kind>.json` | One `event` line for each event kind |
| `errors/<code>.json` | One `ok: false` line for each error code |
| `tolerance/*.jsonl` | Lines a client must still read: an unknown field, an unknown event kind, an unknown phase word, an unknown error code |
| `attach/*.json` | The attach wire: `bytes_hex` (and, host → client, `expect`: what a viewer draws, the notices it shows, how the session ended) |
| `copy/*.json` | The `copy` frames after its answer: data, finish, end |

A `requests/X.case.json` and an `answers/X.case.jsonl` with the same name belong together. An answer with no request of
its own (`ls.empty`, `shutdown.unchanged`, `attach.held`, …) answers that op's `default` request in another state.

## Tiers

- **Tier 1** — what a client app drives: `ping`, `ls`, `inspect`, `sessions`, `plan`, `plans`, `create`, `prepare`,
  `prepare-status`, `start`, `wake`, `pause`, `resume`, `sleep`, `hibernate`, `shutdown`, `reset`, `rm`, `open-session`,
  `session-end`, `session-restart`, `exec`, `rename`, `host-stop`, `account-ls`, `resources`, `ports`, `port-open`,
  `session-screen`, `session-grids`, and the streams `attach`, `events` and `copy`. Each has at least one request and one
  answer fixture; a typed client method is expected for each.
- **Tier 2** — everything else. Reached by name with the same request shape (`HostRequest`'s flat fields); its result is
  whatever the host's types say, with no fixture yet.

A new op must be given a tier (the test fails until `ops.json` lists it).

## Stream modes

- `none` — zero or more `event` lines (progress), then ONE line with `ok`; then the host closes the connection.
- `events` — `event` lines until the client hangs up (`events`; `net-log` and `console` with `follow`).
- `attach` — the `ok` line (`{state: attached | held, …}`), then the terminal: raw VT from the host, keystrokes and
  in-band frames from the client (`attach/client-*`), the ended notice and a close at the end (`attach/ended-*`).
- `frames` — the `ok` line (`CopyReady`), then `copy/` frames: one type byte, a 4-byte big-endian length, the payload.

## The rules a client relies on

- **Fields are only ever added**, never renamed or repurposed. A client ignores what it does not know (`tolerance/`).
- **Feature detection is by op, never by version**: `ping`'s `operations` lists every op the host serves.
- **`v`**: a request whose `v` the host does not speak gets `error.code = "version"` — for EVERY op, the streamed ones
  included, and for an op the host has never heard of. `ping` is the exception: it answers at any `v`, so a newer client
  can read `protocolVersion` and refuse cleanly.
- **Opt-in event kinds**: `session-status` is sent only to an `events` request with `sessionStatus: true` — an older
  client could not decode the kind. This host's own client is strict about event kinds and error codes; a new client
  should not be (`tolerance/unknown-event-kind.jsonl`, `tolerance/unknown-error-code.jsonl`): skip an unknown event,
  treat an unknown error code as `failed`.
- **Phases are words** (`off`, `booting`, `running`, `paused`, `asleep`, `hibernated`, `failed`); a client shows one it
  does not know as it is.

## Hygiene

The repository is public, so no fixture carries a real machine: the store is `/Users/example/doz-store`, a home folder
`/Users/example`, every time `2026-01-01T00:00:00.000Z`, every pid `4242`, and every id from the real host
`00000000-0000-0000-0000-00000000000N`. The test fails on a home folder, a user name, any other user folder, a temporary
folder, this process's pid or any other time.
