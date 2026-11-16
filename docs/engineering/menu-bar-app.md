# The menu bar app — Dozable.app

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md). The person's page is
[the manual's chapter](../manual/35-the-menu-bar-app.md); the release side is in [updates-and-release.md](updates-and-release.md).

The app shows the daemon's state in the menu bar, starts, stops and restarts it, opens the dashboard, and — on the
person's click — starts the daemon (and itself) at login ("Start at Login", below). It is a
**client of the `doz` command** — never of the daemon's socket, never of the engine — so every rule the commands keep
(looking never starts the daemon, the held marker, the locked-Keychain refusal, the double spawn that keeps the daemon
out of a client's tree) is the app's too, and an app built today keeps working after every `doz upgrade` (doz's `--json`
only gains fields).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableMenuBarCore/` — `DozStatus.swift`, `MenuModel.swift`, `SnapshotSource.swift`, `DozLocator.swift`, `CommandRunner.swift`, `Version.swift`, `LoginItem.swift`, `LaunchAgent.swift` | the target `DozableMenuBarCore` (Foundation, Security and os only): the app's own all-optional types for `doz daemon status --json` and `doz app status --json`, the menu as a pure function (`MenuModel.items(for:)`, `loginItem(for:)`, `icon(for:)`, `header(for:)`), the refresh and the actions (`SnapshotSource`), finding doz (`DozLocator`, `FileIdentity`, `MenuBarSeams`; the team check `DozSignature`), running it (`CommandRunner`, `DozCommand`), versions (`DozVersion`), Start at Login without SMAppService (`AgentPlist`, the `LoginItemService` protocol, `RecordingLoginItemService`, `LaunchdLook`, `LoginItemFlow`, `LoginPlace`), the login agent's mode (`LaunchAgent`), the constants (`MenuBarApp.minimumDoz` 0.50.5, `minimumDozForLogin` 0.50.8) |
| `Sources/DozableMenuBar/` — `main.swift`, `MenuBarController.swift`, `LoginService.swift` | the executable target `DozableMenuBar`, product `Dozable` (AppKit + Core): the modes, `NSStatusItem` + `NSMenu` drawing the model, the timers, the Stop question; `LoginService.swift` is the ONE file that imports ServiceManagement (`SystemLoginItemService`: `SMAppService.agent(plistName:)` + `SMAppService.mainApp`) |
| `Resources/MenuBar/Info.plist`, `Resources/MenuBar/com.dozable.app.daemon.plist`, `Scripts/assemble-app.sh`, `Scripts/check-agent-plist.py` | the bundle's Info.plist template, the login agent's plist (copied as is to `Contents/Library/LaunchAgents/`), the assembly (no signing; every Info.plist value checked with `plutil -extract`, the agent plist with `check-agent-plist.py`: exactly its keys, its label doz's reserved one) |
| `Sources/DozableCLI/AppCommands.swift` | `doz app install|status|uninstall` (`MenuBarAppInstall`: the bundled copy, the destination, verify, the swap, the running copies, the open seam); `doz uninstall` lists and removes an installed copy (`UninstallCommand.swift`) |
| `Tests/DozableMenuBarTests/` | `StatusModelTests` (fixtures captured from a real doz), `MenuModelTests` (the state table; no secret shown; Quit runs nothing), `LoginItemStateTests` (the login row: SMAppService's status × doz's owner × doz's version × where the app runs; the flow's order; the recording service; a test run never reaches SMAppService or launchctl), `AgentPlistTests` (the plist's exact keys; the script agrees), `DozLocatorTests` (+ the team check with an injected verifier), `CommandRunnerTests` (argv, no shell, stdin, cap, timeout, the log line, the dashboard's output never read), `SnapshotSourceTests`, `VersionTests` — Core only, so `make test` stays headless |
| `Tests/DozableCLITests/AppInstallTests.swift`, `TestSafetyTests`, `DaemonLoginItemTests` | the install's decisions and an install end to end into a scratch folder; the Applications folders refused in a guarded run; doz's side of the hand-over (the agent plist's label is `DaemonLoginItem.appLabel`; an SMAppService-shaped job counts while the app is installed) |
| `Sources/doz-vmtest/CLIAppSuite.swift` (`make test-cli-app`) | the app with no screen, end to end (below) |

`Package.swift`: neither target depends on DozableKit, DozableHost, DozableCLI or any package (size: no containerization or
NIO in the app; and no UI framework near the engine). `Scripts/audit.sh` step 1c holds it: AppKit only under
`Sources/DozableMenuBar/`, ServiceManagement only in its `LoginService.swift`; Core imports only Foundation, Security and
os; the app imports nothing of the engine; no other target imports AppKit, SwiftUI or ServiceManagement; the manifest's
dependencies of both targets.

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

Between Restart and Open Dashboard (separators around it): the Start at Login row (below). Always: the last action's failure (doz's own `--json` message, one line) until the next action; "Update Menu Bar App (X → Y)"
when the copy that came with doz is newer than the running app (it runs `doz app install --open`); "Quit Dozable Menu"
quits the app only — never the daemon. The icon is an SF Symbol drawn as a template (a placeholder until there is art):
`cube.fill` running, `cube` stopped, `exclamationmark.triangle` when a Restart is due or the state cannot be read,
`cube.transparent` with no doz. This version has no kept sessions.

## Start at Login

ONE switch (the owner's choice: the daemon AND the menu). It registers, only on the person's click — never at a first
launch, never by itself:

- **the agent `com.dozable.app.daemon`** — `SMAppService.agent(plistName: "com.dozable.app.daemon.plist")`, its plist at
  `Contents/Library/LaunchAgents/` inside the bundle, SEALED by the signature. Exactly these keys and no others (the same
  as doz's own item but the program): `Label com.dozable.app.daemon` (doz's reserved `DaemonLoginItem.appLabel`),
  `BundleProgram Contents/MacOS/Dozable`, `ProgramArguments ["Dozable", "--launch-daemon"]`, `RunAtLoad`, `StartInterval
  900`, `LimitLoadToSessionType Aqua`, `AbandonProcessGroup`, `ProcessType Standard`. Never `KeepAlive`, `Sockets` or
  `MachServices`. Why the app's own executable and not doz: a sealed plist cannot name where doz is installed (Homebrew
  on either prefix, any channel, or `~/.local`).
- **the app itself** — `SMAppService.mainApp`: the menu comes back at login.

**`Dozable --launch-daemon`** (what launchd runs; `LaunchAgent`): no NSApplication, Core only. It finds doz with the
standard candidates, and in a RELEASE build (`swift build -c release` — `--self-config` says `requireTeam: true`)
accepts only one whose signature satisfies `anchor apple generic and certificate leaf[subject.OU] = "KJ8QMLWB97"`
(`SecStaticCodeCheckValidity`, strict; a link followed to its file). Then it `execv`s `doz daemon start --login-item` —
the agent's process BECOMES doz's login job, which starts the daemon the usual way (the double spawn: parent launchd,
never this job) and exits (≤ 300 ms with a daemon up). No doz, or one refused: one os_log line (category `login`) and
exit 0 — never a failing job every 15 minutes. It runs the default store only (launchd gives no `DOZ_STORE` or
`XDG_CONFIG_HOME`).

**The order** (`LoginItemFlow`). ON: register the agent, then the app (each skipped when SMAppService says it is
registered already) → SMAppService must say `.enabled` → `launchctl print gui/<uid>/com.dozable.app.daemon` must show the
job loaded (polled ≤ 10 s; the app's ONLY launchctl verb, a look) → THEN `doz config set daemon.login_item on --json`,
whose sync sees the app's job and removes doz's own item (owner `app`). Never two login items: doz is not told before the
job is loaded. `.requiresApproval` (the person switched Dozable off in System Settings): stop there — the row says so and
opens System Settings › Login Items (`SMAppService.openSystemSettingsLoginItems()`). OFF: unregister both, then
`doz config set daemon.login_item off`.

**The row** (`MenuModel.loginItem(for:)`), in this order:

| state | title | click |
|---|---|---|
| doz older than 0.50.8 (`minimumDozForLogin`: the first doz that sees an SMAppService job as the owner) | Start at Login — needs doz 0.50.8 (disabled) | — |
| either service `.requiresApproval` | Start at Login — needs approval: Open System Settings… | opens System Settings › Login Items |
| the agent `.enabled` | ✓ Start at Login | off |
| this copy is not directly in /Applications or ~/Applications (`LoginPlace`) | Start at Login — open the copy in Applications (doz app install) (disabled) | — |
| doz holds its own item (`loginItem.owner == doz`, installed) | ✓ Start at Login (set by doz — click to let this app hold it) | on (the hand-over) |
| otherwise | Start at Login | on |

**Why Applications only.** Background Task Management records the bundle's path; a Homebrew keg's path changes with every
upgrade and a translocated copy has none. And doz must be able to tell the app's job is real: launchd's `print` of an
SMAppService job names no absolute program (`path = (submitted by smd.N)`, `arguments` starting with the bare
`Dozable`), so doz counts it while an installed copy is in its place (`MenuBarAppPlaces`) — the same places the app
requires.

**doz's side** (`DaemonLoginItem.appJob`, decision 13): the app's job is loaded AND its program exists — an absolute
program is checked as itself; a plist path inside a bundle checks that bundle's executable; the SMAppService shape counts
while `/Applications/Dozable.app` or `~/Applications/Dozable.app` (identifier `com.dozable.app`, an executable
`Contents/MacOS/Dozable`) is there. An app deleted without unregistering is ABSENT, so `doz daemon login-item on` adds
doz's own again (a daemon's start never adds one).

**Removal.** `doz app uninstall` and `doz uninstall` run the installed copy's `Dozable --unregister` first (an argv, ≤ 15 s;
SMAppService takes back only what that app registered; an older copy without the mode changes nothing) and say when it
held one; `daemon.login_item` stays as it was, and `doz daemon login-item on` starts the daemon at login again.

**Test runs** (`MenuBarSeams.testRun`: `DOZ_TEST_GUARD=1`, or even `DOZ_TEST_REAL_MAC=1`) never reach SMAppService or
`/bin/launchctl`: the service is `RecordingLoginItemService` — it appends `would register agent com.dozable.app.daemon` /
`would register mainApp` / `would unregister …` to `DOZ_TEST_LOGIN_ITEM_LOG` and keeps its state in
`DOZ_TEST_LOGIN_ITEM_STATE` (`DOZ_TEST_LOGIN_ITEM_RESULT=requiresApproval` makes a registration wait for approval); the
look runs `DOZ_TEST_LAUNCHCTL` only (none: not loaded). `Scripts/fake-launchctl.py` shows the app's job, in the
SMAppService shape, once that state says the agent is registered. `DOZ_TEST_MENUBAR_REQUIRE_TEAM=1` (guarded) makes a
development build require the team.

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
- **`--open`** in a guarded run writes `open <path>` to `DOZ_TEST_APP_OPEN_LOG` and opens nothing; WITHOUT that seam it is
  stopped before anything is installed (`TestSafety.appOpenViolation`). A test never asks macOS to open an app and never
  runs a program inside a scratch bundle that is not the whole, signed app: LaunchServices registers what it opens and
  Gatekeeper judges it — a stand-in inside a bundle claiming `com.dozable.app` broke its seal and put "“Dozable” is
  damaged and can't be opened" on a person's screen. A "running copy" in a guarded run is ONLY a process running the
  stand-in file `DOZ_TEST_APP_STANDIN` (outside any bundle). Running the real app's modes in a test is fine: a whole,
  signed copy is allowed by Gatekeeper without a word.
- `doz uninstall` lists an installed copy, runs its `--unregister`, quits it and removes it with the rest; so does
  `doz app uninstall`.

## The modes (no NSApplication, nothing drawn)

`Dozable --dump-menu` (the model as JSON, with SMAppService's states under `loginItem` — also useful over ssh),
`--self-config` (identifier, version, the doz it needs, `requireTeam`, the agent's label — the release's check),
`--login-status` (SMAppService's two states, whether launchd has the job loaded, the bundle and whether it is in a place
that may hold it — a look), `--launch-daemon` (launchd's job, above), `--unregister` (doz's uninstall), `--version`,
`--help`; `--run-action start|stop|restart|dashboard|login-on|login-off` is a TEST seam (guarded runs only — there is no
way to register Start at Login without the click). With no argument it is the menu — and a guarded run (`DOZ_TEST_GUARD=1`) refuses that (exit 70): a test never
shows anything on screen. `DOZ_MENUBAR_DOZ` (guarded only) is the ONE doz a test run uses — without it a test finds none,
never this Mac's own.

## `make test-cli-app`

`CLIAppSuite`, no VM, no GUI, a scratch store, settings, LaunchAgents and Applications folder: (1) no doz, then the real
doz on a fresh store — nothing started, nothing registered, the menu itself refused; (2) `--run-action start` in a
process group of its own → a daemon with parent 1 in neither its group nor its session, alive after the group is
killed; (3) stop → held; (4) `--launch-daemon`: a fake doz exec'd in the same process with exactly
`daemon start --login-item`, no doz and a refused doz → exit 0 and nothing run, the real doz held → nothing, after a
"reboot" → a daemon with parent 1, a second run < 300 ms with the same pid; (5) a FAKE old doz → the too-old line, what still works, the argv it was run with; (7) the
dashboard through `DOZ_TEST_BROWSER_LOG` → one `open http://127.0.0.1:N`, no link anywhere (the os_log lines too, when
`log show` can read them); (8) doz replaced by rename in a scratch prefix → the next dump, and a newer bundled copy →
"Update Menu Bar App"; (9) `doz app install|status|uninstall --dest` (verified, quarantine gone, a running copy quit and
swapped by rename, opened through the seam, a tampered copy refused, no destination refused) and `doz uninstall`; (10)
Start at Login through the recording service and the fake launchctl: doz's own item → the hand-over offered; login-on →
"would register" agent + mainApp, the job loaded, THEN `daemon.login_item on` (doz's plist gone, owner app); login-off;
needs approval (doz not told); `doz app uninstall` running `--unregister`. `make test-cli-daemon` row 12 checks doz's side
with the SMAppService-shaped job.

**Only a person at the screen can verify**: the menu itself, the icon in light and dark, the Stop question, Gatekeeper's
first open of the notarised app, that Open Dashboard lands signed in — and everything SMAppService does for real: the
"Login Item Added" notice, Dozable's row in System Settings › General › Login Items & Extensions and its switch, the exact
shape of `launchctl print` for the real job, and a login after a reboot (the test Mac). Over ssh:
`launchctl print gui/$(id -u)/com.dozable.app.daemon`, `doz daemon status --json | jq .loginItem`,
`/Applications/Dozable.app/Contents/MacOS/Dozable --login-status`, `log show --predicate 'subsystem == "com.dozable.app"'`.
