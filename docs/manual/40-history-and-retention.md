# History and retention

Dozable keeps a history of what happened on this Mac — every action on a sandbox, sessions, the daemon's runs and its
events, each sandbox's connections and network by minute, CPU, memory and disk samples, the use of your keys (by name),
workspace and permission logs, runs and their frames, and the times of chat messages and the outcomes of Asks — and
answers it as one timeline: `doz timeline`.

**Nothing of it leaves your Mac.** It lives in your store, readable only by you. No message text, Ask question, command
line, path, URL, query string, header or key value is ever kept in it. The hosts a sandbox connected to are kept only as
hidden details: they are never searched as text, never in a summary, and only shown when you ask for them by name
(`attr.dest:`).

## Looking at it

```bash
doz timeline                 # this Mac's name, each source, how long it is kept, and since when
doz timeline retention       # each source's days, who set them, the history file's size
doz timeline query FILE      # answer a timeline query (a JSON document; - reads stdin)
doz timeline tail FILE       # follow a query live (needs the daemon)
```

Looking never starts the daemon: with none running, `doz timeline` answers from the store. The history is filled by the
daemon as things happen; the first time it starts after an update, it reads everything already recorded in the
background, and answers say "indexing … %" until it is done.

This Mac's name in the history is the setting `daemon.mac_name`, "this Mac" by default — a name you choose, never the
Mac's network name:

```bash
doz config set daemon.mac_name studio
```

## How long each kind is kept

Each source has a setting, `timeline.SOURCE`, with four parts in days: single events, then counts by minute, by hour and
by day. `kept` keeps it until you delete it; each part is at least a day.

| Setting | Default | What |
|---|---|---|
| `timeline.actions` | `30/30/365/kept` | actions on sandboxes (start, sleep, wake, …) |
| `timeline.sessions` | `30/30/365/kept` | sessions opened and ended |
| `timeline.daemon` | `30/30/365/kept` | the daemon's runs |
| `timeline.network` | `30/30/365/kept` | connections and bytes per sandbox per minute |
| `timeline.workspace` | `90/90/365/kept` | workspace logs |
| `timeline.grants` | `365/365/365/kept` | permission decisions and grants |
| `timeline.runs` | `kept/kept/kept/kept` | a workspace's runs and a space's frames |
| `timeline.chat` | `30/30/365/kept` | chat message times and Ask outcomes |
| `timeline.daemon_events` | `7/30/365/kept` | the daemon's own events |
| `timeline.egress` | `7/7/90/365` | each connection: its host is kept 7 days; counts per sandbox (never a host) longer |
| `timeline.resources` | `7/7/365/kept` | CPU, memory and disk samples |
| `timeline.keys` | `30/30/365/kept` | your keys' use, by name |

```bash
doz config set timeline.egress 3/3/30/365    # each connection's host for 3 days only
doz timeline prune --dry-run                 # what each source would lose now
doz timeline prune                           # the daemon does this hourly by itself
```

Counts are kept before single events go, so a zoomed-out timeline still shows the time; before a source's "since" it
shows "not kept", never quiet time. How often samples are taken is `timeline.sample_seconds` (60; 0 = never); they are
read from this Mac's side, never by running anything in the sandbox.

**What is not bounded yet.** These settings bound the history file and the records the history added (the daemon's
events, each connection, samples, key use). Dozable's older records — the metrics of actions, sessions, daemon runs and
the network, the workspace and permission logs — are not trimmed by them yet: they keep growing as before. You can
clear the metrics in Resources (see [Resources and disk space](13-resources-and-disk-space.md)).

## Starting the history again

```bash
doz timeline rebuild           # read every record again (removes nothing)
doz timeline rebuild --clean   # start the history file empty, then read every record again
```

The history file (`timeline.sqlite`) is made from the records, so deleting it — in Resources, or with `--clean` — loses
only the counts kept for time whose records are already gone.
