# The menu bar app — Dozable.app

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md). The person's page is
[the manual's chapter](../manual/35-the-menu-bar-app.md); the release side is in [updates-and-release.md](updates-and-release.md).

The app shows the daemon's state in the menu bar, starts, stops and restarts it, and opens the dashboard. It is a
**client of the `doz` command** — never of the daemon's socket, never of the engine — so every rule the commands keep
(looking never starts the daemon, the held marker, the locked-Keychain refusal, the double spawn that keeps the daemon
out of a client's tree) is the app's too, and an app built today keeps working after every `doz upgrade` (doz's `--json`
only gains fields).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableMenuBarCore/` — `DozStatus.swift`, `MenuModel.swift`, `SnapshotSource.swift`, `DozLocator.swift`, `CommandRunner.swift`, `Version.swift` | the target `DozableMenuBarCore` (Foundation, Security and os only): the app's own all-optional types for `doz daemon status --json` and `doz app status --json`, the menu as a pure function (`MenuModel.items(for:)`, `icon(for:)`, `header(for:)`), the refresh and the actions (`SnapshotSource`), finding doz (`DozLocator`, `FileIdentity`, `MenuBarSeams`), running it (`CommandRunner`, `DozCommand`), versions (`DozVersion`), the constants (`MenuBarApp.minimumDoz` 0.50.5) |
| `Sources/DozableMenuBar/` — `main.swift`, `MenuBarController.swift` | the executable target `DozableMenuBar`, product `Dozable` (AppKit + Core): the modes, `NSStatusItem` + `NSMenu` drawing the model, the timers, the Stop question |
| `Resources/MenuBar/Info.plist`, `Scripts/assemble-app.sh` | the bundle's Info.plist template and its assembly (no signing; every value checked with `plutil -extract`) |
| `Sources/DozableCLI/AppCommands.swift` | `doz app install|status|uninstall` (`MenuBarAppInstall`: the bundled copy, the destination, verify, the swap, the running copies, the open seam); `doz uninstall` lists and removes an installed copy (`UninstallCommand.swift`) |
| `Tests/DozableMenuBarTests/` | `StatusModelTests` (fixtures captured from a real doz), `MenuModelTests` (the state table; no secret shown; Quit runs nothing), `DozLocatorTests`, `CommandRunnerTests` (argv, no shell, stdin, cap, timeout, the log line, the dashboard's output never read), `SnapshotSourceTests`, `VersionTests` — Core only, so `make test` stays headless |
| `Tests/DozableCLITests/AppInstallTests.swift`, `TestSafetyTests` | the install's decisions and an install end to end into a scratch folder; the Applications folders refused in a guarded run |
| `Sources/doz-vmtest/CLIAppSuite.swift` (`make test-cli-app`) | the app with no screen, end to end (below) |

`Package.swift`: neither target depends on DozableKit, DozableHost, DozableCLI or any package (size: no containerization or
NIO in the app; and no UI framework near the engine). `Scripts/audit.sh` step 1c holds it: AppKit only under
`Sources/DozableMenuBar/`; Core imports only Foundation, Security and os; the app imports nothing of the engine; no other
target imports AppKit, SwiftUI or ServiceManagement; the manifest's dependencies of both targets.

## How it talks to doz

- **doz by absolute path, an argv array, never a shell**; stdin `/dev/null`; stdout read up to 1 MB (the rest drained and
  dropped); stderr to `/dev/null`; a timeout per command (SIGTERM, SIGKILL 2 s later): status, version and app status
  10 s, start 100 s, stop and restart 300 s, the dashboard 30 s, the app update 60 s.
- **Which doz** (`DozLocator`, a `stat` at every refresh): `/opt/homebrew/bin/doz`, `/usr/local/bin/doz`,
  `~/.local/bin/doz` — the path kept as is (a `bin/doz` link is not resolved, so a `brew upgrade` that re-points it is
  followed). Its version (`doz --version`) and the bundled app's (`doz app status --json`) are asked again only when the
  resolved file or the VERSION beside it is a different file (`FileIdentity`: inode, device, size, time) — the steady
  state is ONE process per refresh.
- **The refreshes are not the person's commands**: `daemon status` and `app status` carry
  `--no-send-anonymous-usage-stats` (an official build counts commands; a 60-second poll would count 1,440 a day). The
  person's clicks (start, stop, restart, the dashboard, the update) are counted like typed commands.
- **The dashboard's link never passes through the app**: Open Dashboard runs `doz ui --detach --open -q` with BOTH outputs
  to `/dev/null` — never read, never logged — and never `--print-url`; doz opens the one-use link through LaunchServices
  itself.
- **The log** (os_log, subsystem `com.dozable.app`, category `doz`, level notice): `doz <command words> → exit N in M ms`
  — never an output, a value or a path. `log show --predicate 'subsystem == "com.dozable.app"' --last 1h` reads it.
- **Nothing secret is shown**: the app's types have no field for argv, an environment or a session's screen (a later
  doz's fields are ignored); the Stop question names running sandboxes only.

## The menu (`MenuModel.items(for:)`)

| state | header (disabled) | lines (disabled) | enabled actions |
|---|---|---|---|
| no doz | doz is not installed | — | How to Install doz… (the manual's install page), Quit |
| status unreadable | Cannot read the daemon's state | why (no answer in 10 s, a failure, an answer it cannot read) | Start, Open Dashboard, Quit |
| stopped | Daemon stopped | — | Start, Open Dashboard |
| held (`doz daemon stop` while always on) | Daemon stopped until a doz command starts it (… or your next login, when a login item exists) | — | Start, Open Dashboard |
| running | Daemon running · VERSION | Always on / Stops when idle · N sandboxes running | Stop… (asks when sandboxes run: they hibernate; sessions on this Mac keep running), Restart, Open Dashboard |
| started from ssh / without a login session (`keychainLocked`) | Daemon started from ssh — it cannot read your Keychain | as running | as running — Restart is the remedy |
| an older build runs (`executableChange`, or its version ≠ `doz --version`) | Daemon runs an older build (V) — Restart to update | as running | as running |
| doz older than `MinimumDoz` (0.50.5) | the state above | doz V is older than this app needs (0.50.5 or later) — upgrade doz | everything that works on it: status, Start/Stop/Restart, the dashboard |
| an action under way | Starting… / Stopping… / Restarting… / Opening the dashboard… / Updating the menu bar app… | — | Quit only |

Always: "Starts at login (set by doz)" (disabled) when doz's own login item exists (`loginItem.owner == doz`, installed);
the last action's failure (doz's own `--json` message, one line) until the next action; "Update Menu Bar App (X → Y)"
when the copy that came with doz is newer than the running app (it runs `doz app install --open`); "Quit Dozable Menu"
quits the app only — never the daemon. The icon is an SF Symbol drawn as a template (a placeholder until there is art):
`cube.fill` running, `cube` stopped, `exclamationmark.triangle` when a Restart is due or the state cannot be read,
`cube.transparent` with no doz. This version has no login switch and no kept sessions.

## Refresh

With the menu closed: `doz daemon status --json` every 60 s (never faster: the command asks launchctl 2–3 times), at
wake (`NSWorkspace.didWakeNotification`) and after every action. `menuWillOpen`: at once, then every 2 s on a timer in
the common run-loop modes (it ticks while the menu tracks) until `menuDidClose`. ONE command at a time on a serial
queue; a tick that comes while one runs is skipped. Items update in place while the menu is open (rebuilt only when the
shape changes).

## Edge cases

- **No doz**: the hollow icon, the header and How to Install. A doz installed later is found at the next refresh.
- **doz older than 0.50.5**: its `daemon status --json` with no daemon is only `{"running": false}`; the menu says the
  daemon is stopped and that doz is older, and offers everything those versions have.
- **doz upgraded under the app**: the next refresh runs the new file (a new inode → its version asked again). A daemon
  of the older build says so in the header until restarted (an always-on daemon restarts itself in place when idle).
  The copy of the app that came with the new doz is offered as "Update Menu Bar App".
- **The app replaced by `doz app install`**: the running copy keeps its files (its inode) until it is opened again;
  `--open` quits it (SIGTERM to the processes whose program is inside the bundle) and opens the new one.

## `doz app install|status|uninstall`

- **The bundled copy** is `Dozable.app` beside the RESOLVED doz (`libexec/doz/Dozable.app`; `make app` puts one beside
  `.build/debug/doz`). Install verifies it — `codesign --verify --strict`, identifier `com.dozable.app`, Dozable's team
  (`Distribution.teamID`) when this doz is a release (its `RELEASE` marker; a guarded test may say ad hoc is fine with
  `DOZ_TEST_UPDATE_ALLOW_ADHOC=1`), its version = doz's — `ditto`s it to `DIR/.Dozable.app.new`, removes the quarantine
  mark, verifies the copy again, then ONE rename: `renamex_np(RENAME_SWAP)` over an installed copy (removed only after
  the swap) or a plain rename. A `Dozable.app` there with another identifier is never replaced.
- **Where**: `--dest DIR`, else `/Applications` when writable, else `~/Applications`. A guarded run: only `--dest` or
  `DOZ_TEST_APPLICATIONS_DIR` (the Makefile sets a scratch one for every test target); `TestSafety.applicationsViolation`
  STOPS one that would reach the real `/Applications` or `~/Applications`. Status and uninstall look only there too.
- **`--open`** in a guarded run writes `open <path>` to `DOZ_TEST_APP_OPEN_LOG` and opens nothing.
- `doz uninstall` lists an installed copy, quits it and removes it with the rest.

## The modes (no NSApplication, nothing drawn)

`Dozable --dump-menu` (the model as JSON — also useful over ssh), `--self-config` (identifier, version, the doz it needs —
the release's check), `--version`, `--help`; `--run-action start|stop|restart|dashboard` is a TEST seam (guarded runs
only). With no argument it is the menu — and a guarded run (`DOZ_TEST_GUARD=1`) refuses that (exit 70): a test never
shows anything on screen. `DOZ_MENUBAR_DOZ` (guarded only) is the ONE doz a test run uses — without it a test finds none,
never this Mac's own.

## `make test-cli-app`

`CLIAppSuite`, no VM, no GUI, a scratch store, settings, LaunchAgents and Applications folder: (1) no doz, then the real
doz on a fresh store — nothing started, nothing registered, the menu itself refused; (2) `--run-action start` in a
process group of its own → a daemon with parent 1 in neither its group nor its session, alive after the group is
killed; (3) stop → held; (5) a FAKE old doz → the too-old line, what still works, the argv it was run with; (7) the
dashboard through `DOZ_TEST_BROWSER_LOG` → one `open http://127.0.0.1:N`, no link anywhere (the os_log lines too, when
`log show` can read them); (8) doz replaced by rename in a scratch prefix → the next dump, and a newer bundled copy →
"Update Menu Bar App"; (9) `doz app install|status|uninstall --dest` (verified, quarantine gone, a running copy quit and
swapped by rename, opened through the seam, a tampered copy refused, no destination refused) and `doz uninstall`.

**Only a person at the screen can verify**: the menu itself, the icon in light and dark, the Stop question, Gatekeeper's
first open of the notarised app, and that Open Dashboard lands signed in.
