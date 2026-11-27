# The engine and the daemon

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

The daemon is the code's "host": `HostServer`, `HostCore`, `HostClient`, `HostLauncher` and the `DozableHost` target keep that name.

## Where its code lives

A bare file name is in `Sources/DozableKit/`.

| Path | What |
|---|---|
| `Sources/DozableKit/Sandbox.swift` | The `Sandbox` actor: boot (images, golden-disk bake, APFS clone, VM), lifecycle via the planner, exec, sessions/attach |
| `Phase.swift` | `Phase` and `LifecyclePlanner` — each operation's steps as DATA (incl. stop / resetToImage / delete), so the invariants are unit tests |
| `VirtualMachine.swift` | Direct VZ ops; `PinnedIdentity` (machine id + MAC); `DozableVMM`, `AdoptingInstance`, `AdoptingAgent` — restore into a new process |
| `SessionConnection.swift` | One viewer's connection: HELLO/DATA/RESIZE out, SNAPSHOT/DATA/EXIT in; never delivers or sends after close |
| `DeckholdSocket.swift` | The same frames straight on a holder's unix socket (attach, watch, query, dump, send, capture, list) — the transport of the sessions on this Mac; the library knows nothing else of them |
| `Sources/DozableHost/MacSessions.swift`, `MacPlace.swift`, `HostCore+Mac.swift` | `@mac`: sessions held on THIS Mac by `deckhold-mac` — never a sandbox; fenced by default (`MacFence*`: a Seatbelt profile per session, its own proxy, folder and agent config — `--unfenced` opts out; a record keeps its mode across restart and adoption). See sessions.md, "Sessions on this Mac" |
| `DeckholdProtocol.swift` | Frame codec, `deckhold ls` parser, `GuestCommand` (every guest argv; the share re-mount script) |
| `StoreLayout.swift` | Storage layout under `storeRoot`; `PersistedSandbox` (what a new process needs to restore) |
| `DeckholdBinary.swift` | Finds the resource without `Bundle.module` |
| `EXT4Inspector.swift` | an ext4 image FILE read on the daemon — `has_journal`, clean state, the free-block bitmaps (== `dumpe2fs`'s list) |
| `DiskAccounting.swift` | per-disk unique / shared-with-parent / garbage / extents from APFS's extent map (`F_LOG2PHYS_EXT`), PRIVATESIZE cross-check; range helpers |
| `Maintenance.swift` | `reclaim()`, `rederive()`, `maintenanceAdvice()` (586's thresholds), `checkDisks()` — stopped sandboxes only |
| `RestorePoints.swift`, `FsckHelper.swift` | Restore points, custom images; e2fsck of a running-taken copy in a helper VM (on the file, over virtio-fs) |
| `KernelProvider.swift` | The pinned Linux kernel (`KernelArtifact.recommended`): override → verified cache → byte-identical seed (675: the copy a release carries in `libexec/doz/kernels/` first, then Apple's `container` copy) → download + verify archive + extract + verify kernel |
| `Resources/deckhold` | The committed static aarch64-linux-musl guest binary — see `Guest/deckhold/PROVENANCE.md` |
| `Guest/deckhold/` | deckhold's C source, `build.sh` (pinned Zig 0.16.0 + ghostty `b988efc`), `PROVENANCE.md` |
| `Sources/doz-vmtest/` | The VM integration suite (entitled executable); `NetworkSuite.swift` is `network`; `CLISuite.swift` is `cli` (`make test-cli`); `ClaudeSuite.swift` is `claude` (`make test-vm-claude`) |
| `Sources/DozableHost/HostProtocol.swift` | the daemon protocol (JSON lines, `HostOp`, results) — fields only ever added, except at a version step: 3 (0.51) renamed `workspace`→`folder` and a request's `workdir`→`cwd`/`folder`, and each side refuses the other's protocol (`HostProtocol.refusal`; `ping` and `host-stop` excepted, so either doz can see and stop the other's daemon; the CLI says `HostProtocol.skewMessage`). On-disk records keep their old keys (`doz.json` `workspace`, `sessions.json` `workdir`). |
| `Sources/DozableHost/HostCore.swift` | the daemon's model — every sandbox as a `Sandbox`, every operation, crash recovery, metrics rows; also used read-only in-process |
| `Sources/DozableHost/HostServer.swift` | `doz daemon` — the lock, the socket, the attach relay (held clients), streams, the idle loop (exit, restart in place, hand-over), quit = Hibernate |
| `Sources/DozableHost/ChatSupervisor.swift`, `ChatDirectory.swift`, `ChatOwnerClient.swift` | the chat server the daemon runs as its child while `chat.enabled` (stopped before the lock is let go; chat on keeps the daemon up and follows an upgrade) — [chat.md, "Under the daemon"](chat.md#under-the-daemon) |
| `Sources/DozableHost/IdleDecision.swift`, `StableExecutable.swift`, `ExecutableIdentity.swift` | 693: what an idle daemon does at each look (pure); the path a new daemon is started from (a keg's `opt` link); which program file the daemon runs and how it changed |
| `Sources/DozableHost/HostClient.swift`, `UnixSocket.swift` | the detached-child launcher, the client, socket plumbing, `ClientWire` (SandboxLab's attach wire) |
| `Sources/DozableHost/DaemonLoginItem.swift`, `LoginStart.swift`, `Launchctl.swift`; `Sources/DozableCLI/LoginItemCommands.swift` | 694: the daemon's login item — the plist, the install rule and its sync, status; the job `daemon start --login-item`, the held marker, `DaemonStarter` (a locked client kickstarts the item); launchctl and the LaunchAgents folder behind their seams; `doz daemon login-item`, the once-notice |
| `Sources/DozableHost/DozableStore.swift`, `Metrics.swift` | the CLI store's files, `SandboxConfig` (`doz.json`), images → specs; the metrics DB (SandboxLab's schema) |
| `Sources/DozableCLI/` | the commands (ArgumentParser), the attach client, `doctor`; `UICommand.swift` (`doz ui`, `ui link`); `HelpExitCodes.swift` (`doz help exit-codes`, taken by `DozableEntry` before ArgumentParser, which owns `help`) |
| `Sources/DozableHost/ExitCodes.swift` | THE exit-code contract: the table (exit → name → meaning → error codes), `exit(for:)`, `ErrorAnswer` (`{"error":{"code","message","exit"}}`), `PartialAnswer` |
| `Sources/DozableHost/Settings.swift`, `TOML.swift`; `Sources/DozableCLI/ConfigCommands.swift`; `Sources/DozableWeb/WebSettings.swift` | 591 settings: the CLOSED schema (`DozableSettings.schema`), `${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml` generated from it, our own strict TOML subset (no dependency), precedence flag > env > file > default with a source per value; `doz config`; the UI's Settings page route (`GET`/`POST /api/v1/settings`). 678 (`SettingsRest.swift`): a read checks Dozable's own keys at once against `coreIndexed` (no recipe read) and settles every other line — a recipe's key, a 0.37 name, an unknown key, a `defaults.image` naming a recipe agent — the first time one is asked for (`FileValues`' subscript of a core key, `resolve` of one, never do); `SettingsLazySchemaTests` pins that the result equals the eager read |
| `Tests/DozableKitTests/` | Unit tests — no VM |

## Rules that each cost a bug to learn here

- **The container's PID 1 reaps** (775): `GuestCommand.reapingInit` — `/bin/sh -c 'while :; do sleep infinity & wait $!; done'`
  — not a bare `sleep infinity`, which never reaped: what an exec or a session left behind (re-parented to PID 1) stayed
  `<defunct>` (a render killed at its deadline left 20 zombie browsers). Every shell's `wait` reaps any child while it waits.
  Not a VM input: a cold boot starts it; a restore adopts the PID 1 it had (a sandbox booted before keeps the old one until
  its next cold start). The bake and the e2fsck helper keep `sleep infinity` (short-lived). `make test-cli-exectimeout`.

- **Exit codes are ONE table, frozen** (`ExitCodes`, DozableHost): every command's exit comes from `ExitCodes.exit(for:)`
  of its error's code (`DozableExit` only names them; `fail(_:_:)` prints `ErrorAnswer`, whose `exit` is the exit the
  process takes) — no command maps a code locally. A code keeps its meaning; a new outcome gets a new `HostError.Code`,
  and the switch in `exit(for:)` is exhaustive, so it does not compile unplaced. 2 is not found only (`not-found`,
  `ambiguous`); 64 is usage (ArgumentParser's own errors, `usage`, `unclear-request`); every `invalid` value or document
  is 65 (a space file's errors: `invalid-document`); 3 carries distinct codes (`plan-changed` for a stale `ifPlan`,
  `file-changed` for a stale `ifMatch`/`ifBrief`); 75 is a partial result (`workspace up`/`down`: `partial` {done,
  remaining, retry}). Codes are only added — an older client decodes an unknown one as `failed`. A HostError no
  command caught exits through the table too (`DozableEntry`). Outside it, by design: the program's own code from
  `exec`/`run`/`attach`, `doz upgrade --check`'s 10, `doz chat ask --wait`'s 10/11/12 and the chat server process's own
  (chat.md). `ExitCodesTests`, `make test-cli` (the exit-code rows).

- **`session-transcripts` only reads** (`HostOp.isReadOnly`): `doz sessions @mac --transcripts S [--export DIR]` and the
  forget's `--dry-run` (`session-forget` with `dryRun`) answer in-process with no daemon and never start one; forgetting
  itself needs the daemon (`MacForgetTests`).

- **Every `doz exec` deadline is counted from process start and enforced by the daemon** (678: a `--timeout 3` exec
  once ran 40 s — the clock started after the client's start-up and the wake, and the guest program outlived it).
  `ExecDeadline` (DozableHost): `ProcessStart.date` is the kernel's `p_starttime`; `DozableEntry.main`'s FIRST line arms
  a watchdog THREAD (never GCD or Swift concurrency — a starved pool cannot hold it back) that `_exit(124)`s 2 s after
  the deadline. The client sends `HostRequest.deadline` (and `timeoutSeconds`, the time left, for an older daemon);
  `HostCore.exec` races the whole operation against it (`race(until:)`): at the deadline it answers
  `ExecOutput.timedOut(during: waking|starting|running)` — a wake or start under way is NEVER cancelled (it finishes in
  the background, its events gated off), the guest command is never started after the deadline, and a running one
  is killed then deleted (`Sandbox.exec`: a failed wait kills). Exit code 124 (`DozableExit.timedOut`); `--json`'s
  `timedOut` tells it from a program's own 124. `ExecDeadlineTests`, `make test-cli-exectimeout`.
- **One stuck guest never holds the daemon's answers** (678 B7: a starved guest made every exec time out, and `doz ls`
  and `doz down` hung behind it). `HostCore.guestRead` bounds a listing's guest read (`ls`'s session count,
  `sessions`) by 3 s; a guest that missed it is `unresponsive` (`SandboxInfo.unresponsive`, `ls` shows it, one note)
  and not asked again for 30 s (a lifecycle request asks again at once), and its balloon is given back. The dashboard
  says it too (`WebSandboxRow.unresponsive`: All sandboxes' "not answering" line, the sandbox page's callout). A graceful
  stop (`.stopContainer`) waits at most 30 s, then stops the VM at the VZ level and says so — the container goes to
  the Graveyard (never deallocated unclosed). `GuestReadTests`, `BalloonPressureTests`.
- **A daemon never keeps a background priority it inherited** (678: a 69 s hibernate from a daemon that a background
  agent worker had autostarted — Darwin's background state passes to every child). `HostServer.run` of a LAUNCHED daemon
  calls `ProcessPriority.liftInheritedBackground()` (`setpriority(PRIO_DARWIN_PROCESS, 0, 0)`; `daemon status`
  `priorityRestored`), and both launcher spawns ask for `QOS_CLASS_USER_INITIATED`; a person's `--foreground` daemon
  keeps what they chose. `doz doctor` warns (`priority`, `daemon priority`) when doz or its daemon is clamped
  (`ProcessPriority`: the Darwin background state, the background QoS, `pti_priority`). `ProcessPriorityTests`,
  `make test-cli-startup`.
  **Nor a utility QoS, and neither do its sessions** (788: a launchd `ProcessType Standard` daemon ran at utility, pri 20 —
  mostly the efficiency cores — and every session on this Mac it held inherited it; a terminal's ran at 31). The login
  items run as `ProcessType Interactive`; a launched daemon also calls `ProcessPriority.liftInheritedUtility()` (its
  thread asks for user-initiated: a no-op under a clamp); `MacSessions.spawnAndWait` spawns the holder at
  `QOS_CLASS_USER_INITIATED` (a clamp on the daemon still wins). `doz doctor` warns separately — `clamped` keeps its
  meaning — when the daemon runs at utility (`daemon priority`, `ProcessPriority.belowNormal`) and when a session's
  program does (`session QoS`, from `daemon status`'s `heldSessionPri`: each running session → its `pti_priority`).

- **The daemon is always on, and an update still reaches it** (693, owner: "yes always on (a new setting - default on).
  change timeout default to 0 (never times out)"). `daemon.always_on` (default on, `$DOZ_DAEMON_ALWAYS_ON`, applies now —
  the idle loop re-reads it at each look) keeps a daemon with nothing open; `daemon.idle_timeout_minutes` (default 5 —
  700; 0 disables it; listed right after `always_on`) is used only when it is off. `HostServer.idleLoop` gathers the inputs and `IdleDecision` (pure,
  `IdleDecisionTests`) decides, in order: a stopping daemon does nothing; its program changed (`ExecutableIdentity`) or
  a newer recipe catalogue waits, with NOTHING live and NO client connected → fenced (or kept) sessions on this Mac:
  `handOver`; always on and started by the launcher: `restartInPlace` (a person's `--foreground` daemon exits); else
  exit; idle past the effective timeout → exit. The loop never skips its look (it used to skip everything — the
  program-change exit included — when the timeout was 0: an always-on daemon would have run an old build forever). It
  looks every 5 s when it never idles out.
  - **A daemon whose login keychain is locked is NEVER always on** (one started over ssh cannot read the Mac's Claude
    login): it exits after at most 5 minutes with nothing live, whatever the settings say, and on a program change it
    exits rather than restart where the keychain is locked. `make test-cli-keychainlocked` rows 5.
  - **Restart in place keeps one owner.** It re-checks under the server's lock that no client connected (one that did
    cancels it), closes and unlinks the socket first (so the new daemon never takes it for a live one), spawns the new
    daemon through `HostLauncher.spawn` (detached, parent launchd — never this process's child) from the STABLE path,
    removes the pid file and releases the locks as its last act; the new daemon waits for the lock as every daemon does.
    A client arriving in between autostarts a daemon of its own, which gives up once the first answers (`takeLock`).
  - **The stable path** (`StableExecutable.path`): a Homebrew keg `…/Cellar/<formula>/<ver>/libexec/doz/doz` → the
    formula's `…/opt/<formula>/libexec/doz/doz` (doz, doz-beta, doz-canary; when it exists); a tarball or install-cli
    `<prefix>/libexec/doz/doz` stays itself (that folder is swapped in place); anything else its resolved path.
    `handOver` and `restartInPlace` start the new daemon from it (`brew cleanup` deletes the old keg), and a different
    file there counts as the program `replaced` (`ExecutableIdentity.change(now:stableNow:)`) — `brew upgrade` without
    a cleanup leaves the old keg in place, so by its own path alone the daemon saw no change. `StableExecutableTests`.
    `homebrewKeg`, `formula` and `installation` live there too (`doz uninstall` uses them).
  - **Status:** `HostStatus.alwaysOn` (effective — false for a locked daemon), `keepers` (sessions on this Mac kept
    running, which keep the daemon up whatever `alwaysOn` says; 0 until kept sessions exist), and `idleTimeoutMinutes`
    is the EFFECTIVE timeout (0 while always on). `doz daemon status` says it in one line; `doctor` says "always on".
    One warning, `DozableSettings.daemonIdleWarning` (nil unless always-on is off AND the timeout is 0: nothing then
    switches the daemon off by idling), in the same words in `doz config show` / `config set|unset` (of either key or
    `login_item`), under both rows of the Settings page (`SettingRow.warning`), in `doz daemon status` and as a doctor
    `.warn`. The defaults earn none.
  - **Tests never leave a daemon behind:** the Makefile's guarded environment sets `DOZ_DAEMON_ALWAYS_ON=off` (forced) and
    `DOZ_DAEMON_IDLE=5` (unless the run sets one) for every test target; a suite that tests always-on sets it on for its
    own daemons. `make test-cli-alwayson` (in `make test-cli` too): the default keeps a daemon up past 5× its timeout;
    `config set daemon.always_on off` makes the running one exit; a program renamed over it restarts it in place (one
    daemon, a new pid, parent launchd, the new file, no command typed). `make test-vm-upgrade` part F: the previous
    release's idle daemon and this build installed by rename (a release that predates the restart exits by itself), then
    this build's always-on daemon replaced by rename → it restarts in place; 694: its scratch LaunchAgents folder stays empty.

- **The login item: launchd never runs the daemon, and nothing is written without consent** (694; the owner approved ONE
  per-user login agent per store as the exception to "no launchd agent"). `daemon.login_item` (`ask` | `on` | `off`,
  default `ask`, NO environment variable — consent is never an environment value) — only `on` ever writes a plist; the
  default and an upgrade write nothing. `DaemonLoginItem` (pure `render` + `decide`, effectful `sync` / `status` /
  `remove`):
  - **The plist** `~/Library/LaunchAgents/com.dozable.daemon.<8 hex>.plist` (the store path's hash, as its socket folder —
    `MacPlace.storeHash`; doz-dev's store never collides), 0644, written atomically, an XML comment naming the store and
    how to remove it. `ProgramArguments = [<stable doz>, daemon, start, --login-item, --store, <store>]` (doz itself, never
    `sh`), `RunAtLoad`, `StartInterval 900`, `LimitLoadToSessionType Aqua`, `AbandonProcessGroup`, `ProcessType Interactive` (788: under `Standard` the daemon and every session it held ran at
    utility QoS, pri 20 — mostly the efficiency cores),
    `StandardOutPath`/`StandardErrorPath` = `<store>/login-item.log` (cut back above 256 KiB), `EnvironmentVariables
    {XDG_CONFIG_HOME}` only when set and not the default. Never `KeepAlive`, `Sockets` or `MachServices`.
    `DaemonLoginItemTests` round-trips it through `PropertyListSerialization`.
  - **The rule**: present ⇔ `login_item == on` AND (`always_on` OR ≥ 1 kept session — `HostServer.keepers`, 0 until kept
    sessions exist) AND no app-owned job (`com.dozable.app.daemon`, the menu bar app's SMAppService agent; loaded AND its program
    still on disk — one whose program is gone counts as absent. Its program is the app's own executable named RELATIVE
    to the bundle (`BundleProgram`), so `print` shows no absolute path: then it counts while a plist path in a bundle that
    `print` names, or an installed `Dozable.app` in /Applications or ~/Applications (`MenuBarAppPlaces`; a test run: the
    seam), is there — `DaemonLoginItem.appJob`, menu-bar-app.md "Start at Login"). `sync` is called by `doz daemon login-item on|off`,
    `doz config set|unset` of the daemon's settings, the web settings route (`daemon.always_on` only: `daemon.login_item` is `ui: false` — consent is given on the Mac, never
    from the dashboard, where under `doz ui --lan` another device could ask; the route refuses it and the Settings page
    shows it read-only; `ServeRulesTests.testTheWebUIRefusesTheLoginItem`),
    onboarding's answer, and each daemon's start — which ONLY rewrites a stale program path or removes (`Mode.daemonStart`;
    with no plist it looks at nothing). Load: `launchctl bootstrap gui/<uid> <plist>` (best effort: from ssh the file is
    still written and "it loads at your next login" said); unload: `bootout gui/<uid>/<label>`, then unlink.
  - **The job** (`LoginStart`, `doz daemon start --login-item`, hidden): (a) `<store>/daemon.held` newer than
    `kern.boottime` → nothing; (b) a daemon answers → nothing, unless it cannot read the login keychain and runs nothing
    (no sandbox, preparation, fenced or kept session — `HostStatus.fencedSessions`/`preparations`) while this session can:
    it is asked to stop, then (d); (c) always on off and nothing kept → nothing; (d) `HostLauncher.spawn` from the stable
    path, wait ≤ 90 s for the socket. One line in `login-item.log` per action (the app's job has no StandardOutPath, so doz
    writes its own); always exit 0; ≤ 300 ms when nothing is to do. `LoginStartTests`.
  - **The hold** (decision 7): `doz daemon stop` while `daemon.always_on` is on writes `daemon.held`; the job starts nothing
    until the next boot, or until any daemon starts (`HostServer.run` and `DaemonStarter.start` remove it). The answer
    says "it stays stopped until a doz command or your next login".
  - **The locked-Keychain guard** (decision 8, `DaemonStarter`): a client that would autostart a daemon from a session
    where the login keychain is locked (ssh), while a login item is LOADED (`launchctl print` = 0: this store's, or the
    app's), runs `launchctl kickstart gui/<uid>/<label>` instead, waits 15 s for the socket and says "doz: started the
    daemon in your desktop session (login item)"; on failure today's start with today's warning. `doz daemon restart` from
    such a session while the running daemon can read the keychain and no item is loaded is REFUSED (`HostRestart.
    lockedRefusal`); `stop` is allowed.
  - **Status, without a daemon too:** `doz daemon status --json` carries `loginItem` (`LoginItemStatus`: setting, owner
    doz|app|none, label, path, program, installed, loaded, disabled — `print-disabled` —, stale, wanted, note) and `held`,
    filled by the CLI (never the daemon's ping); with no daemon it is `{running: false, store, held, alwaysOn, loginItem}`.
    `doctor`'s "login item" row: not set up, missing, not loaded, switched off, stale, a locked daemon. All read only.
  - **The seams** (`Launchctl.swift`): `Launchctl` is `/bin/launchctl`, or `DOZ_TEST_LAUNCHCTL` in a test run;
    `LaunchAgentsFolder` is the real folder, or `DOZ_TEST_LAUNCH_AGENTS_DIR`; `DOZ_TEST_BOOT_TIME` stands in for the boot.
    `TestSafety` STOPS a guarded process that would run the real launchctl or touch the real folder; a LOOK with no seam
    (`forLooking`) looks at nothing. The Makefile sets a scratch folder and `Scripts/launchctl-refuse.sh` for every test
    target; `make test-cli-daemon` (`CLIDaemonSuite`, `Scripts/fake-launchctl.py`: records argv, keeps a state, runs a
    kickstarted job without `DOZ_TEST_KEYCHAIN_LOCKED`) checks rows 1–12. Uninstall and nuke boot out and remove THIS
    store's item (listed in what they remove) and list other stores' read-only.
- **A daemon stop shows its progress** (`HostStop.swift`): `host-stop` streams, per sandbox, a
  `started` "hibernating X" and a `step` "hibernated X (snapshot …)" / `failed` (why + "shut down
  instead") — `HostEvent.startedAs` ties an end to its differently-worded start — then the daemon's own
  last step, and answers `HostStopResult` (rows; an older daemon answers the string "stopped", still
  read). `Sandbox.prepareForExit` returns its `ExitOutcome`. Every stopping client uses
  `stopHostShowingProgress` (the CLI's progress view: animated on a tty, plain lines else) or, in the
  UI, Restart daemon's operation (`WebOperation.lines`). A daemon that dies mid-stop: the client reports
  what it saw (`HostStopView.seen`), never hangs. `make test-cli-hoststop` (in `test-cli` too).
- **A guarded stop ends its store's sessions** (751). The sessions on this Mac are NOT the daemon's to stop: their holders
  (`deckhold-mac serve`) daemonise and outlive it by design (sessions.md, "The holder"), so a person's `@mac` sessions —
  a workspace's fenced manager among them — keep running across `doz daemon stop`, an update and a restart, and the next
  daemon adopts them. A test that forgets `workspace finish` used to leak those holders on the runner. So in a guarded test
  run only, and only for a store that is not the default one (`TestSafety.endsHeldSessionsAtStop`: `guarded` and no
  `storeViolation`), `HostServer.shutdown` first ends every running session THIS store holds (`HostCore.macEndHeldAtTestStop`
  → `MacSessions.end`: by its record and the pid its own holder names on this store's socket folder — HUP, TERM, KILL to
  that group only, the requested end so no crash line — never a process found by name), and the holders exit with their
  programs; the log says "a guarded test run: ended N session(s) on this Mac this store held". Outside a test nothing
  changes. A test that proves the survival itself keeps them with `DOZ_TEST_KEEP_MAC_SESSIONS=1` in the daemon's
  environment (`TestSafety.keepMacSessionsVariable`): `make test-cli`'s harness (`CLIHarness`) sets it by default, since
  its suites check exactly that (e.g. `make test-cli-workspace` row 22, the fence's daemon-stop rows); its T9 row starts a
  daemon without it. `TestSafetyTests.testOnlyAGuardedStopOfAScratchStoreEndsItsHeldSessions`, `make test-cli-workspace` T9.
- **The sandbox follows the Mac's time zone**: `GuestTimeZone` — the zone's TZif bytes from
  THIS Mac's `/usr/share/zoneinfo` (portable to glibc and musl; the Alpine lab has no tzdata) — written to
  `/etc/localtime` (+ `/etc/timezone`) by `prepareGuest` at every fresh boot and by `.resyncClock` at
  every wake (best effort; no new planner step). The daemon sets it (`HostCore.guestTimeZone`: the setting
  `sandbox.timezone` = `mac`, read NOW with `NSTimeZone.resetSystemTimeZone()`, or a zone) at adopt,
  every named request and every `ensureRunning`. The facts say it (`sandbox.timezone`).
  `DOZ_TEST_MAC_TIMEZONE` (a name, or a file holding one, read at each look) stubs the Mac's zone;
  `make test-cli-timezone`.

## A sandbox's conversations for a run's archive

At finish, while a sandbox agent's VM still runs (`SandboxTranscriptExport`, the daemon's `DaemonSandboxTranscripts`): an exec
lists the regular `<uuid>.jsonl` files of `~/.claude/projects/<slug of /workspace>/` with their times, and each one modified
since the run began is read as a one-member tar on the guest stream (the `copy` operation's way; a link or anything but a
regular file is refused), then checked on the Mac by `TranscriptCopy`'s content rules. A sandbox not running is never woken
("not running: its conversations stay on its disk"); nothing in a VM is ever discarded.
